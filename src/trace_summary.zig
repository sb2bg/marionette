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
    fields: []const []const u8,

    fn field(self: ParsedEvent, key: []const u8) ?[]const u8 {
        for (self.fields) |item| {
            const equals_index = std.mem.indexOfScalar(u8, item, '=') orelse continue;
            if (std.mem.eql(u8, item[0..equals_index], key)) return item[equals_index + 1 ..];
        }
        return null;
    }
};

/// Owned summary of one Marionette trace.
pub const Summary = struct {
    allocator: std.mem.Allocator,
    total_events: u64 = 0,
    final_timestamp: ?u64 = null,
    profile_name: ?[]u8 = null,
    tags: std.ArrayList([]u8) = .empty,
    attributes: std.ArrayList(RunAttribute) = .empty,
    subsystem_counts: std.ArrayList(Counter) = .empty,
    event_counts: std.ArrayList(Counter) = .empty,
    network_sends: u64 = 0,
    network_deliveries: u64 = 0,
    network_drops: u64 = 0,
    network_drop_reasons: std.ArrayList(Counter) = .empty,
    network_links: std.ArrayList(LinkCounter) = .empty,

    /// Release summary-owned memory.
    pub fn deinit(self: *Summary) void {
        if (self.profile_name) |profile_name| self.allocator.free(profile_name);
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

        if (self.profile_name) |profile_name| {
            try writer.print("trace.run profile={s}\n", .{profile_name});
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

        // Current events have <=8 fields; keep a generous fixed cap so malformed
        // traces fail loudly instead of allocating unbounded parser state.
        var fields_buffer: [32][]const u8 = undefined;
        const event = try parseEventLine(line, &fields_buffer);
        if (event.index != summary.total_events) return error.InvalidTraceEvent;

        summary.total_events += 1;
        try incrementCounter(allocator, &summary.event_counts, event.name);
        try incrementCounter(allocator, &summary.subsystem_counts, subsystemName(event.name));
        try recordRunContext(&summary, event);
        try recordTime(&summary, event);
        try recordNetwork(&summary, event);
    }

    sortCounters(summary.subsystem_counts.items);
    sortCounters(summary.event_counts.items);
    sortCounters(summary.network_drop_reasons.items);
    sortLinks(summary.network_links.items);
    return summary;
}

fn parseEventLine(line: []const u8, buffer: *[32][]const u8) TraceSummaryError!ParsedEvent {
    var iterator = std.mem.splitScalar(u8, line, ' ');
    const event_field = iterator.next() orelse return error.InvalidTraceLine;
    if (!std.mem.startsWith(u8, event_field, "event=")) return error.InvalidTraceLine;
    const index = std.fmt.parseInt(u64, event_field["event=".len..], 10) catch {
        return error.InvalidTraceLine;
    };
    const name = iterator.next() orelse return error.InvalidTraceLine;

    var field_count: usize = 0;
    while (iterator.next()) |field| {
        if (field_count == buffer.len) return error.InvalidTraceLine;
        if (std.mem.indexOfScalar(u8, field, '=') == null) return error.InvalidTraceLine;
        buffer[field_count] = field;
        field_count += 1;
    }

    return .{
        .index = index,
        .name = name,
        .fields = buffer[0..field_count],
    };
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
    try counters.append(allocator, .{
        .name = try allocator.dupe(u8, name),
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
    if (std.mem.eql(u8, event.name, "run.profile")) {
        const name = event.field("name") orelse return error.InvalidTraceEvent;
        if (summary.profile_name) |profile_name| summary.allocator.free(profile_name);
        summary.profile_name = try summary.allocator.dupe(u8, name);
    } else if (std.mem.eql(u8, event.name, "run.tag")) {
        const value = event.field("value") orelse return error.InvalidTraceEvent;
        try summary.tags.append(summary.allocator, try summary.allocator.dupe(u8, value));
    } else if (std.mem.eql(u8, event.name, "run.attribute")) {
        const key = event.field("key") orelse return error.InvalidTraceEvent;
        const value = event.field("value") orelse return error.InvalidTraceEvent;
        try summary.attributes.append(summary.allocator, .{
            .key = try summary.allocator.dupe(u8, key),
            .value = try summary.allocator.dupe(u8, value),
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
        "marionette.trace format=text version=0\n" ++
        "event=0 world.init seed=1 start_ns=0 tick_ns=10\n" ++
        "event=1 run.profile name=smoke\n" ++
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
        \\trace.run profile=smoke
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
        \\trace.event_top rank=6 name=run.profile count=1
        \\trace.event_top rank=7 name=run.tag count=1
        \\trace.event_top rank=8 name=world.init count=1
        \\trace.singleton name=network.deliver
        \\trace.singleton name=network.drop
        \\trace.singleton name=network.send
        \\trace.singleton name=register.check
        \\trace.singleton name=run.attribute
        \\trace.singleton name=run.profile
        \\trace.singleton name=run.tag
        \\trace.singleton name=world.init
        \\trace.singleton name=world.tick
        \\trace.network sends=1 deliveries=1 drops=1
        \\trace.network.drop_reason name=link_disabled count=1
        \\trace.network.link from=3 to=0 sends=1 deliveries=1 drops=0
        \\trace.network.link from=3 to=1 sends=0 deliveries=0 drops=1
        \\
    , output);
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
