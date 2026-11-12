//! Text diagnostics for failure reports: where two executions first differ,
//! a bounded tail of the failing execution, focused histories, and the fault
//! effects an application observed. Everything is derived from trace bytes,
//! so it works on capsules and watchdog partial traces too.

const std = @import("std");
const world_module = @import("world.zig");

/// A focused history: every event that names this node, operation, path, or
/// fault.
pub const Focus = union(enum) {
    /// `node=`, `from=`, `to=`, or `owner=` fields.
    node: u64,
    /// Disk operation ids (`op=`).
    op: u64,
    /// `path=` or `new_path=`, compared after trace escaping.
    path: []const u8,
    /// Network fault handles (`fault=`) and fault effects naming the
    /// fault's trace event (`fault_event=`).
    fault: u64,

    /// Parse `node:3`, `op:12`, `path:wal.log`, or `fault:2`.
    pub fn parse(text: []const u8) error{InvalidFocus}!Focus {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidFocus;
        const kind = text[0..colon];
        const value = text[colon + 1 ..];
        if (value.len == 0) return error.InvalidFocus;
        if (std.mem.eql(u8, kind, "path")) return .{ .path = value };
        const number = std.fmt.parseInt(u64, value, 10) catch return error.InvalidFocus;
        if (std.mem.eql(u8, kind, "node")) return .{ .node = number };
        if (std.mem.eql(u8, kind, "op")) return .{ .op = number };
        if (std.mem.eql(u8, kind, "fault")) return .{ .fault = number };
        return error.InvalidFocus;
    }

    fn matches(self: Focus, payload: []const u8) bool {
        var fields = std.mem.splitScalar(u8, payload, ' ');
        _ = fields.next();
        while (fields.next()) |field| {
            const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            const key = field[0..equals];
            const value = field[equals + 1 ..];
            switch (self) {
                .node => |node| if (isAny(key, &.{ "node", "from", "to", "owner" }) and uintEquals(value, node)) return true,
                .op => |op| if (std.mem.eql(u8, key, "op") and uintEquals(value, op)) return true,
                .path => |path| if (isAny(key, &.{ "path", "new_path" }) and escapedEquals(value, path)) return true,
                .fault => |fault| if (isAny(key, &.{ "fault", "fault_event" }) and uintEquals(value, fault)) return true,
            }
        }
        return false;
    }
};

fn isAny(key: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |name| if (std.mem.eql(u8, key, name)) return true;
    return false;
}

fn uintEquals(text: []const u8, value: u64) bool {
    return (std.fmt.parseInt(u64, text, 10) catch return false) == value;
}

fn escapedEquals(escaped: []const u8, raw: []const u8) bool {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    world_module.writeEscapedTraceText(&writer, raw, false) catch return false;
    return std.mem.eql(u8, escaped, writer.buffered());
}

/// One trace line split into its event index and payload.
const Line = struct {
    text: []const u8,
    payload: []const u8,
};

fn eventLine(line: []const u8) ?Line {
    if (!std.mem.startsWith(u8, line, "event=")) return null;
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    return .{ .text = line, .payload = line[space + 1 ..] };
}

fn isEmptyWake(payload: []const u8) bool {
    return std.mem.startsWith(u8, payload, "scheduler.wake_empty ");
}

/// Write every event matching `focus`. Returns how many matched.
pub fn writeHistory(writer: *std.Io.Writer, trace: []const u8, focus: Focus) std.Io.Writer.Error!u64 {
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |raw| {
        const line = eventLine(raw) orelse continue;
        if (!focus.matches(line.payload)) continue;
        try writer.print("{s}\n", .{line.text});
        count += 1;
    }
    return count;
}

/// Write the last `limit` events, leaving out empty scheduler wakes, which
/// carry no causal information; the raw trace keeps them.
pub fn writeTail(writer: *std.Io.Writer, trace: []const u8, limit: usize) std.Io.Writer.Error!void {
    var total: usize = 0;
    var empty_wakes: usize = 0;
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |raw| {
        const line = eventLine(raw) orelse continue;
        if (isEmptyWake(line.payload)) empty_wakes += 1 else total += 1;
    }
    const skip = total -| limit;
    try writer.print("trace tail: last {} of {} events ({} empty wakes omitted)\n", .{ total - skip, total, empty_wakes });
    var seen: usize = 0;
    lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |raw| {
        const line = eventLine(raw) orelse continue;
        if (isEmptyWake(line.payload)) continue;
        seen += 1;
        if (seen > skip) try writer.print("  {s}\n", .{line.text});
    }
}

/// The first event where two traces differ.
pub const Difference = struct {
    /// Zero-based event position.
    position: usize,
    first: ?[]const u8,
    second: ?[]const u8,
};

pub fn firstDifference(first: []const u8, second: []const u8) ?Difference {
    var a = std.mem.splitScalar(u8, first, '\n');
    var b = std.mem.splitScalar(u8, second, '\n');
    var position: usize = 0;
    while (true) {
        const left = nextEvent(&a);
        const right = nextEvent(&b);
        if (left == null and right == null) return null;
        if (left == null or right == null or !std.mem.eql(u8, left.?, right.?)) {
            return .{ .position = position, .first = left, .second = right };
        }
        position += 1;
    }
}

fn nextEvent(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (lines.next()) |raw| {
        if (eventLine(raw) != null) return raw;
    }
    return null;
}

/// Write the fault effects an application observed: each `io.fault_effect`
/// with the fault event it names, so a reader can follow cause to error.
pub fn writeFaultEffects(writer: *std.Io.Writer, trace: []const u8, limit: usize) std.Io.Writer.Error!void {
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |raw| {
        const line = eventLine(raw) orelse continue;
        if (std.mem.startsWith(u8, line.payload, "io.fault_effect ")) total += 1;
    }
    if (total == 0) return;
    try writer.print("fault effects: {} observed by the application\n", .{total});
    var written: usize = 0;
    lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |raw| {
        const line = eventLine(raw) orelse continue;
        if (!std.mem.startsWith(u8, line.payload, "io.fault_effect ")) continue;
        if (written == limit) {
            try writer.print("  ... {} more\n", .{total - written});
            break;
        }
        try writer.print("  {s}\n", .{line.text});
        if (fieldValue(line.payload, "fault_event")) |event| {
            if (findEvent(trace, event)) |cause| try writer.print("    caused by {s}\n", .{cause});
        }
        written += 1;
    }
}

fn fieldValue(payload: []const u8, key: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, payload, ' ');
    _ = fields.next();
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..equals], key)) return field[equals + 1 ..];
    }
    return null;
}

fn findEvent(trace: []const u8, index_text: []const u8) ?[]const u8 {
    const wanted = std.fmt.parseInt(u64, index_text, 10) catch return null;
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |raw| {
        if (!std.mem.startsWith(u8, raw, "event=")) continue;
        const space = std.mem.indexOfScalar(u8, raw, ' ') orelse continue;
        const index = std.fmt.parseInt(u64, raw[6..space], 10) catch continue;
        if (index == wanted) return raw;
        if (index > wanted) return null;
    }
    return null;
}

test "diagnosis: focused histories follow nodes, operations, paths, and faults" {
    const trace =
        \\marionette.trace format=text version=5
        \\event=0 disk.write op=0 path=wal%20a status=ok
        \\event=1 network.send from=1 to=2 fault=3
        \\event=2 io.fault_effect node=2 incarnation=1 operation=write cause=WriteError error=InputOutput fault_event=0 decision=none
        \\event=3 scheduler.wake_empty key=9
        \\
    ;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectEqual(@as(u64, 2), try writeHistory(&writer, trace, try Focus.parse("node:2")));
    try std.testing.expectEqual(@as(u64, 1), try writeHistory(&writer, trace, try Focus.parse("path:wal a")));
    try std.testing.expectEqual(@as(u64, 1), try writeHistory(&writer, trace, try Focus.parse("op:0")));
    try std.testing.expectEqual(@as(u64, 1), try writeHistory(&writer, trace, .{ .fault = 3 }));
    try std.testing.expectError(error.InvalidFocus, Focus.parse("node:x"));

    writer = .fixed(&buffer);
    try writeTail(&writer, trace, 2);
    try std.testing.expectEqualStrings(
        \\trace tail: last 2 of 3 events (1 empty wakes omitted)
        \\  event=1 network.send from=1 to=2 fault=3
        \\  event=2 io.fault_effect node=2 incarnation=1 operation=write cause=WriteError error=InputOutput fault_event=0 decision=none
        \\
    , writer.buffered());

    writer = .fixed(&buffer);
    try writeFaultEffects(&writer, trace, 4);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "caused by event=0 disk.write") != null);
}

test "diagnosis: first difference names both events" {
    const a = "marionette.trace format=text version=5\nevent=0 a.x v=1\nevent=1 a.y v=2\n";
    const b = "marionette.trace format=text version=5\nevent=0 a.x v=1\nevent=1 a.y v=3\nevent=2 a.z v=1\n";
    const difference = firstDifference(a, b).?;
    try std.testing.expectEqual(@as(usize, 1), difference.position);
    try std.testing.expectEqualStrings("event=1 a.y v=2", difference.first.?);
    try std.testing.expectEqualStrings("event=1 a.y v=3", difference.second.?);
    try std.testing.expect(firstDifference(a, a) == null);
    const shorter = firstDifference(a, "marionette.trace format=text version=5\nevent=0 a.x v=1\n").?;
    try std.testing.expect(shorter.second == null);
}
