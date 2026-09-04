//! Versioned execution payload shared by replay capsules and watchdog transport.
const std = @import("std");
const decision = @import("decision.zig");
const execution = @import("execution.zig");

pub const Wire = struct {
    version: u32 = 1,
    decision_version: u32 = decision.format_version,
    trace: []const u8,
    event_count: u64,
    decisions: []const decision.Decision,
    tape_complete: bool,
    failure: ?execution.Failure,

    pub fn fromResult(result: *const execution.Result) Wire {
        return .{
            .trace = result.trace,
            .event_count = result.event_count,
            .decisions = result.decision_tape.entries,
            .tape_complete = result.tape_complete,
            .failure = if (result.outcome == .failed) result.outcome.failed else null,
        };
    }

    pub fn validate(self: Wire) !void {
        if (self.version != 1 or self.decision_version != decision.format_version) return error.UnsupportedReplayVersion;
        var lines = std.mem.splitScalar(u8, self.trace, '\n');
        if (!std.mem.eql(u8, lines.next() orelse return error.InvalidReplayArtifact, "marionette.trace format=text version=3")) return error.UnsupportedReplayVersion;
        var count: u64 = 0;
        while (lines.next()) |line| {
            if (line.len == 0 and lines.index == null) break;
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidReplayArtifact;
            if (!std.mem.startsWith(u8, line, "event=")) return error.InvalidReplayArtifact;
            const index = std.fmt.parseInt(u64, line[6..space], 10) catch return error.InvalidReplayArtifact;
            if (index != count or !@import("world.zig").isValidTracePayload(line[space + 1 ..])) return error.InvalidReplayArtifact;
            count = std.math.add(u64, count, 1) catch return error.InvalidReplayArtifact;
        }
        if (!std.mem.endsWith(u8, self.trace, "\n") or count != self.event_count) return error.InvalidReplayArtifact;
        var previous: ?decision.Decision = null;
        for (self.decisions) |entry| {
            if (entry.preceding_event_index) |event| {
                if (event >= self.event_count) return error.InvalidReplayArtifact;
            }
            if (entry.microstep == std.math.maxInt(u64)) return error.InvalidReplayArtifact;
            if (previous) |prior| {
                if (entry.logical_time_ns < prior.logical_time_ns) return error.InvalidReplayArtifact;
                const step = if (entry.logical_time_ns == prior.logical_time_ns) prior.microstep + 1 else 0;
                if (entry.microstep != step) return error.InvalidReplayArtifact;
            } else if (entry.microstep != 0) return error.InvalidReplayArtifact;
            previous = entry;
            if (!decision.validDecision(entry) or !entry.alternatives.accepts(entry.selected)) return error.InvalidReplayArtifact;
        }
    }

    pub fn cloneResult(self: Wire, allocator: std.mem.Allocator) !execution.Result {
        try self.validate();
        var result: execution.Result = .{
            .allocator = allocator,
            .trace = try allocator.dupe(u8, self.trace),
            .event_count = self.event_count,
            .tape_complete = self.tape_complete,
        };
        errdefer result.deinit();
        result.decision_tape = try decision.Tape.clone(allocator, self.decisions);
        if (self.failure) |failure| {
            const owned = try failure.clone(allocator);
            result.outcome = .{ .failed = owned };
        }
        return result;
    }
};

pub fn encode(allocator: std.mem.Allocator, result: *const execution.Result) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, Wire.fromResult(result), .{});
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !execution.Result {
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return parsed.value.cloneResult(allocator);
}
