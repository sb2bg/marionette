//! Deterministic trace summary renderer.

const std = @import("std");

/// Errors returned while parsing a Marionette trace.
pub const TraceSummaryError = error{
    InvalidTraceLine,
    InvalidTraceEvent,
};

const Counter = struct {
    name: []u8,
    count: u64,
};

const RunAttribute = struct {
    key: []u8,
    value: []u8,
};

const LinkCounter = struct {
    from: u16,
    to: u16,
    sends: u64 = 0,
    deliveries: u64 = 0,
    drops: u64 = 0,
};

const ParsedEvent = struct {
    index: u64,
    name: []const u8,
    /// Space-separated `key=value` fields after the name, already validated.
    /// Kept as text so events of any width parse without parser state.
    fields: []const u8,

    fn field(self: ParsedEvent, key: []const u8) ?[]const u8 {
        var items = std.mem.splitScalar(u8, self.fields, ' ');
        while (items.next()) |item| {
            const equals_index = std.mem.indexOfScalar(u8, item, '=') orelse continue;
            if (std.mem.eql(u8, item[0..equals_index], key)) return item[equals_index + 1 ..];
        }
        return null;
    }
};

/// Injected faults counted from one execution's trace. Crashes and partitions
/// are injections; every other count is an effect the application could
/// observe, such as a write lost by a crash or a read that returned an error.
pub const FaultCoverage = struct {
    disk_crashes: u64 = 0,
    crash_lost_writes: u64 = 0,
    crash_torn_writes: u64 = 0,
    crash_reordered_writes: u64 = 0,
    crash_lost_metadata: u64 = 0,
    disk_read_errors: u64 = 0,
    disk_write_errors: u64 = 0,
    disk_corrupt_reads: u64 = 0,
    network_partitions: u64 = 0,
    network_drops: u64 = 0,
    process_kills: u64 = 0,
    allocation_failures: u64 = 0,

    /// Whether any injected fault had an observable effect. A crash with no
    /// pending writes or a partition that dropped nothing does not count, so
    /// a passing run where nothing fired is not evidence of fault tolerance.
    pub fn fired(self: FaultCoverage) bool {
        inline for (@typeInfo(FaultCoverage).@"struct".field_names) |name| {
            if (comptime isInjection(name)) continue;
            if (@field(self, name) != 0) return true;
        }
        return false;
    }

    pub fn add(self: *FaultCoverage, other: FaultCoverage) void {
        inline for (@typeInfo(FaultCoverage).@"struct".field_names) |name| {
            @field(self, name) += @field(other, name);
        }
    }

    fn isInjection(comptime name: []const u8) bool {
        return std.mem.eql(u8, name, "disk_crashes") or std.mem.eql(u8, name, "network_partitions");
    }

    fn record(self: *FaultCoverage, event: ParsedEvent) TraceSummaryError!void {
        const name = event.name;
        if (std.mem.eql(u8, name, "disk.crash")) {
            self.disk_crashes += 1;
            self.crash_lost_writes += try requiredU64(event, "lost");
            self.crash_torn_writes += try requiredU64(event, "torn");
            self.crash_reordered_writes += try requiredU64(event, "reordered");
            self.crash_lost_metadata += try requiredU64(event, "metadata_lost");
        } else if (std.mem.eql(u8, name, "disk.fault")) {
            // Crash-time rolls are totalled by the `disk.crash` event.
            if (!std.mem.eql(u8, event.field("fired") orelse return, "true")) return;
            const kind = event.field("kind") orelse return error.InvalidTraceEvent;
            if (std.mem.eql(u8, kind, "read_error")) self.disk_read_errors += 1;
            if (std.mem.eql(u8, kind, "write_error")) self.disk_write_errors += 1;
        } else if (std.mem.eql(u8, name, "disk.read") or std.mem.eql(u8, name, "disk.read_some")) {
            // Scripted and probabilistic corruption both surface here. A read
            // that transferred no bytes returned nothing the corruption changed.
            if (!std.mem.eql(u8, event.field("status") orelse return error.InvalidTraceEvent, "corrupt")) return;
            const transferred = if (std.mem.eql(u8, name, "disk.read_some")) "read_len" else "len";
            if (try requiredU64(event, transferred) != 0) self.disk_corrupt_reads += 1;
        } else if (std.mem.eql(u8, name, "network.partition") or std.mem.eql(u8, name, "network.auto_partition")) {
            self.network_partitions += 1;
        } else if (std.mem.eql(u8, name, "network.drop")) {
            self.network_drops += 1;
        } else if (std.mem.eql(u8, name, "process.kill")) {
            // A disk crash restarts every process; those kills are part of
            // the crash, so a crash with nothing pending is a clean restart.
            const reason = event.field("reason") orelse return error.InvalidTraceEvent;
            if (!std.mem.eql(u8, reason, "disk_crash")) self.process_kills += 1;
        } else if (std.mem.startsWith(u8, name, "allocation.")) {
            if (!std.mem.eql(u8, event.field("status") orelse return, "fail")) return;
            // Overflow and unsupported in-place resizes are not injected.
            const reason = event.field("reason") orelse return error.InvalidTraceEvent;
            for ([_][]const u8{ "fail_after", "quota", "buggify" }) |injected| {
                if (std.mem.eql(u8, reason, injected)) self.allocation_failures += 1;
            }
        }
    }
};

/// Count injected faults in trace bytes without allocating. Accepts the
/// partial trace of a watchdog-terminated run.
pub fn faultCoverage(trace_bytes: []const u8) TraceSummaryError!FaultCoverage {
    var coverage: FaultCoverage = .{};
    var lines = std.mem.splitScalar(u8, trace_bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "marionette.trace ")) continue;
        try coverage.record(try parseEventLine(line));
    }
    return coverage;
}

fn requiredU64(event: ParsedEvent, key: []const u8) TraceSummaryError!u64 {
    const value = event.field(key) orelse return error.InvalidTraceEvent;
    return std.fmt.parseInt(u64, value, 10) catch error.InvalidTraceLine;
}

/// Owned summary of one Marionette trace.
pub const Summary = struct {
    allocator: std.mem.Allocator,
    total_events: u64 = 0,
    final_timestamp: ?u64 = null,
    name: ?[]u8 = null,
    tags: std.ArrayList([]u8) = .empty,
    attributes: std.ArrayList(RunAttribute) = .empty,
    subsystem_counts: std.ArrayList(Counter) = .empty,
    event_counts: std.ArrayList(Counter) = .empty,
    network_sends: u64 = 0,
    network_deliveries: u64 = 0,
    network_drops: u64 = 0,
    network_drop_reasons: std.ArrayList(Counter) = .empty,
    network_links: std.ArrayList(LinkCounter) = .empty,
    faults: FaultCoverage = .{},

    /// Release summary-owned memory.
    pub fn deinit(self: *Summary) void {
        if (self.name) |name| self.allocator.free(name);
        for (self.tags.items) |tag| self.allocator.free(tag);
        self.tags.deinit(self.allocator);
        for (self.attributes.items) |attribute| {
            self.allocator.free(attribute.key);
            self.allocator.free(attribute.value);
        }
        self.attributes.deinit(self.allocator);
        deinitCounters(self.allocator, &self.subsystem_counts);
        deinitCounters(self.allocator, &self.event_counts);
        deinitCounters(self.allocator, &self.network_drop_reasons);
        self.network_links.deinit(self.allocator);
        self.* = undefined;
    }

    /// Write a stable, grep-friendly summary.
    pub fn writeSummary(self: Summary, writer: anytype) !void {
        try writer.print("trace.events total={}", .{self.total_events});
        if (self.final_timestamp) |timestamp| {
            try writer.print(" final_time_ns={}", .{timestamp});
        }
        try writer.writeByte('\n');

        if (self.name) |name| {
            try writer.print("trace.run name={s}\n", .{name});
        }
        for (self.tags.items) |tag| {
            try writer.print("trace.run tag={s}\n", .{tag});
        }
        for (self.attributes.items) |attribute| {
            try writer.print(
                "trace.run attribute.{s}={s}\n",
                .{ attribute.key, attribute.value },
            );
        }

        try writeCounters(writer, "trace.subsystem", self.subsystem_counts.items);
        try writeTopEvents(self.allocator, writer, self.event_counts.items, 8);
        try writeSingletons(writer, self.event_counts.items);

        try writer.print(
            "trace.network sends={} deliveries={} drops={}\n",
            .{ self.network_sends, self.network_deliveries, self.network_drops },
        );
        try writeCounters(writer, "trace.network.drop_reason", self.network_drop_reasons.items);
        for (self.network_links.items) |link| {
            try writer.print(
                "trace.network.link from={} to={} sends={} deliveries={} drops={}\n",
                .{ link.from, link.to, link.sends, link.deliveries, link.drops },
            );
        }
        try writer.print("trace.faults fired={}", .{self.faults.fired()});
        inline for (@typeInfo(FaultCoverage).@"struct".field_names) |name| {
            try writer.print(" {s}={}", .{ name, @field(self.faults, name) });
        }
        try writer.writeByte('\n');
    }
};

/// Build an owned summary from line-oriented trace bytes.
pub fn summarize(allocator: std.mem.Allocator, trace_bytes: []const u8) !Summary {
    var summary: Summary = .{ .allocator = allocator };
    errdefer summary.deinit();

    var lines = std.mem.splitScalar(u8, trace_bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "marionette.trace ")) continue;

        const event = try parseEventLine(line);
        if (event.index != summary.total_events) return error.InvalidTraceEvent;

        summary.total_events += 1;
        try incrementCounter(allocator, &summary.event_counts, event.name);
        try incrementCounter(allocator, &summary.subsystem_counts, subsystemName(event.name));
        try recordRunContext(&summary, event);
        try recordTime(&summary, event);
        try recordNetwork(&summary, event);
        try summary.faults.record(event);
    }

    sortCounters(summary.subsystem_counts.items);
    sortCounters(summary.event_counts.items);
    sortCounters(summary.network_drop_reasons.items);
    sortLinks(summary.network_links.items);
    return summary;
}

/// Parse an event line, rejecting fields that are not `key=value`. Events may
/// carry any number of fields, since applications record their own.
fn parseEventLine(line: []const u8) TraceSummaryError!ParsedEvent {
    var iterator = std.mem.splitScalar(u8, line, ' ');
    const event_field = iterator.next() orelse return error.InvalidTraceLine;
    if (!std.mem.startsWith(u8, event_field, "event=")) return error.InvalidTraceLine;
    const index = std.fmt.parseInt(u64, event_field["event=".len..], 10) catch {
        return error.InvalidTraceLine;
    };
    const name = iterator.next() orelse return error.InvalidTraceLine;
    const fields = iterator.rest();
    if (fields.len != 0) {
        var items = std.mem.splitScalar(u8, fields, ' ');
        while (items.next()) |item| {
            if (std.mem.indexOfScalar(u8, item, '=') == null) return error.InvalidTraceLine;
        }
    }

    return .{ .index = index, .name = name, .fields = fields };
}

fn subsystemName(name: []const u8) []const u8 {
    const dot_index = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot_index];
}

fn incrementCounter(
    allocator: std.mem.Allocator,
    counters: *std.ArrayList(Counter),
    name: []const u8,
) !void {
    for (counters.items) |*counter| {
        if (std.mem.eql(u8, counter.name, name)) {
            counter.count += 1;
            return;
        }
    }
    try counters.ensureUnusedCapacity(allocator, 1);
    const owned_name = try allocator.dupe(u8, name);
    counters.appendAssumeCapacity(.{
        .name = owned_name,
        .count = 1,
    });
}

fn deinitCounters(allocator: std.mem.Allocator, counters: *std.ArrayList(Counter)) void {
    for (counters.items) |counter| allocator.free(counter.name);
    counters.deinit(allocator);
}

fn sortCounters(counters: []Counter) void {
    std.mem.sort(Counter, counters, {}, struct {
        fn lessThan(_: void, a: Counter, b: Counter) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

fn sortLinks(links: []LinkCounter) void {
    std.mem.sort(LinkCounter, links, {}, struct {
        fn lessThan(_: void, a: LinkCounter, b: LinkCounter) bool {
            return a.from < b.from or (a.from == b.from and a.to < b.to);
        }
    }.lessThan);
}

fn writeCounters(writer: anytype, prefix: []const u8, counters: []const Counter) !void {
    for (counters) |counter| {
        try writer.print("{s} name={s} count={}\n", .{ prefix, counter.name, counter.count });
    }
}

fn writeTopEvents(
    allocator: std.mem.Allocator,
    writer: anytype,
    events: []const Counter,
    limit: usize,
) !void {
    const ranked = try allocator.dupe(Counter, events);
    defer allocator.free(ranked);

    std.mem.sort(Counter, ranked, {}, struct {
        fn lessThan(_: void, a: Counter, b: Counter) bool {
            return a.count > b.count or
                (a.count == b.count and std.mem.lessThan(u8, a.name, b.name));
        }
    }.lessThan);

    const emitted_count = @min(ranked.len, limit);
    for (ranked[0..emitted_count], 0..) |event, rank| {
        try writer.print(
            "trace.event_top rank={} name={s} count={}\n",
            .{ rank + 1, event.name, event.count },
        );
    }
}

fn writeSingletons(writer: anytype, events: []const Counter) !void {
    for (events) |event| {
        if (event.count == 1) {
            try writer.print("trace.singleton name={s}\n", .{event.name});
        }
    }
}

fn parseU16(value: []const u8) TraceSummaryError!u16 {
    return std.fmt.parseInt(u16, value, 10) catch error.InvalidTraceLine;
}

fn linkFor(summary: *Summary, from: u16, to: u16) !*LinkCounter {
    for (summary.network_links.items) |*link| {
        if (link.from == from and link.to == to) return link;
    }
    try summary.network_links.append(summary.allocator, .{ .from = from, .to = to });
    return &summary.network_links.items[summary.network_links.items.len - 1];
}

fn recordRunContext(summary: *Summary, event: ParsedEvent) !void {
    if (std.mem.eql(u8, event.name, "run.name")) {
        const value = event.field("value") orelse return error.InvalidTraceEvent;
        const owned_value = try summary.allocator.dupe(u8, value);
        if (summary.name) |name| summary.allocator.free(name);
        summary.name = owned_value;
    } else if (std.mem.eql(u8, event.name, "run.profile")) {
        const value = event.field("name") orelse return error.InvalidTraceEvent;
        const owned_value = try summary.allocator.dupe(u8, value);
        if (summary.name) |name| summary.allocator.free(name);
        summary.name = owned_value;
    } else if (std.mem.eql(u8, event.name, "run.tag")) {
        const value = event.field("value") orelse return error.InvalidTraceEvent;
        try summary.tags.ensureUnusedCapacity(summary.allocator, 1);
        const owned_value = try summary.allocator.dupe(u8, value);
        summary.tags.appendAssumeCapacity(owned_value);
    } else if (std.mem.eql(u8, event.name, "run.attribute")) {
        const key = event.field("key") orelse return error.InvalidTraceEvent;
        const value = event.field("value") orelse return error.InvalidTraceEvent;
        try summary.attributes.ensureUnusedCapacity(summary.allocator, 1);
        const owned_key = try summary.allocator.dupe(u8, key);
        errdefer summary.allocator.free(owned_key);
        const owned_value = try summary.allocator.dupe(u8, value);
        summary.attributes.appendAssumeCapacity(.{
            .key = owned_key,
            .value = owned_value,
        });
    }
}

fn recordTime(summary: *Summary, event: ParsedEvent) !void {
    if (std.mem.eql(u8, event.name, "world.tick")) {
        const now_ns = event.field("now_ns") orelse return error.InvalidTraceEvent;
        summary.final_timestamp = std.fmt.parseInt(u64, now_ns, 10) catch {
            return error.InvalidTraceLine;
        };
    } else if (std.mem.eql(u8, event.name, "world.run_for")) {
        const end_ns = event.field("end_ns") orelse return error.InvalidTraceEvent;
        summary.final_timestamp = std.fmt.parseInt(u64, end_ns, 10) catch {
            return error.InvalidTraceLine;
        };
    }
}

fn recordNetwork(summary: *Summary, event: ParsedEvent) !void {
    // Keep this parser in lockstep with the current network trace schema in
    // docs/network.md; missing required fields should surface as schema drift.
    if (std.mem.eql(u8, event.name, "network.send")) {
        summary.network_sends += 1;
        const from = try parseU16(event.field("from") orelse return error.InvalidTraceEvent);
        const to = try parseU16(event.field("to") orelse return error.InvalidTraceEvent);
        (try linkFor(summary, from, to)).sends += 1;
    } else if (std.mem.eql(u8, event.name, "network.deliver")) {
        summary.network_deliveries += 1;
        const from = try parseU16(event.field("from") orelse return error.InvalidTraceEvent);
        const to = try parseU16(event.field("to") orelse return error.InvalidTraceEvent);
        (try linkFor(summary, from, to)).deliveries += 1;
    } else if (std.mem.eql(u8, event.name, "network.drop")) {
        summary.network_drops += 1;
        const from = try parseU16(event.field("from") orelse return error.InvalidTraceEvent);
        const to = try parseU16(event.field("to") orelse return error.InvalidTraceEvent);
        (try linkFor(summary, from, to)).drops += 1;
        const reason = event.field("reason") orelse return error.InvalidTraceEvent;
        try incrementCounter(summary.allocator, &summary.network_drop_reasons, reason);
    }
}

test "trace summary: summarizes run context and network events" {
    const trace =
        "marionette.trace format=text version=2\n" ++
        "event=0 world.init seed=1 start_ns=0 tick_ns=10\n" ++
        "event=1 run.name value=smoke\n" ++
        "event=2 run.tag value=example:replicated_register\n" ++
        "event=3 run.attribute key=replicas value=uint:3\n" ++
        "event=4 network.send id=0 from=3 to=0 deliver_at=10 latency_ns=10\n" ++
        "event=5 world.tick now_ns=10\n" ++
        "event=6 network.deliver id=0 from=3 to=0 now_ns=10\n" ++
        "event=7 network.drop id=1 from=3 to=1 reason=link_disabled\n" ++
        "event=8 register.check committed_agreement=ok\n";

    var summary = try summarize(std.testing.allocator, trace);
    defer summary.deinit();

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try summary.writeSummary(&writer);
    const output = writer.buffered();

    try std.testing.expectEqualStrings(
        \\trace.events total=9 final_time_ns=10
        \\trace.run name=smoke
        \\trace.run tag=example:replicated_register
        \\trace.run attribute.replicas=uint:3
        \\trace.subsystem name=network count=3
        \\trace.subsystem name=register count=1
        \\trace.subsystem name=run count=3
        \\trace.subsystem name=world count=2
        \\trace.event_top rank=1 name=network.deliver count=1
        \\trace.event_top rank=2 name=network.drop count=1
        \\trace.event_top rank=3 name=network.send count=1
        \\trace.event_top rank=4 name=register.check count=1
        \\trace.event_top rank=5 name=run.attribute count=1
        \\trace.event_top rank=6 name=run.name count=1
        \\trace.event_top rank=7 name=run.tag count=1
        \\trace.event_top rank=8 name=world.init count=1
        \\trace.singleton name=network.deliver
        \\trace.singleton name=network.drop
        \\trace.singleton name=network.send
        \\trace.singleton name=register.check
        \\trace.singleton name=run.attribute
        \\trace.singleton name=run.name
        \\trace.singleton name=run.tag
        \\trace.singleton name=world.init
        \\trace.singleton name=world.tick
        \\trace.network sends=1 deliveries=1 drops=1
        \\trace.network.drop_reason name=link_disabled count=1
        \\trace.network.link from=3 to=0 sends=1 deliveries=1 drops=0
        \\trace.network.link from=3 to=1 sends=0 deliveries=0 drops=1
        \\trace.faults fired=true disk_crashes=0 crash_lost_writes=0 crash_torn_writes=0 crash_reordered_writes=0 crash_lost_metadata=0 disk_read_errors=0 disk_write_errors=0 disk_corrupt_reads=0 network_partitions=0 network_drops=1 process_kills=0 allocation_failures=0
        \\
    , output);
}

fn summarizeAllocationFailureSweep(allocator: std.mem.Allocator) !void {
    const trace =
        "event=0 run.name value=first\n" ++
        "event=1 run.profile name=replacement\n" ++
        "event=2 run.tag value=smoke\n" ++
        "event=3 run.attribute key=replicas value=uint:3\n" ++
        "event=4 network.drop id=1 from=3 to=1 reason=link_disabled\n";
    var summary = try summarize(allocator, trace);
    defer summary.deinit();
}

test "trace summary: allocation failures roll back owned fields" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        summarizeAllocationFailureSweep,
        .{},
    );
}

test "trace summary: rejects malformed event prefix" {
    try std.testing.expectError(
        error.InvalidTraceLine,
        summarize(std.testing.allocator, "world.init seed=1\n"),
    );
}

test "trace summary: rejects malformed field" {
    try std.testing.expectError(
        error.InvalidTraceLine,
        summarize(std.testing.allocator, "event=0 world.init seed=1 broken\n"),
    );
}

test "trace summary: rejects missing required event field" {
    try std.testing.expectError(
        error.InvalidTraceEvent,
        summarize(std.testing.allocator, "event=0 world.tick\n"),
    );
}

test "trace summary: rejects non-monotonic event index" {
    try std.testing.expectError(
        error.InvalidTraceEvent,
        summarize(std.testing.allocator, "event=1 world.init seed=1\n"),
    );
}

test "trace summary: rejects network drop without reason" {
    try std.testing.expectError(
        error.InvalidTraceEvent,
        summarize(std.testing.allocator, "event=0 network.drop id=1 from=0 to=1\n"),
    );
}
