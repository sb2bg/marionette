//! One owned execution, independent of runner metadata and watchdog transport.
const std = @import("std");
const decision = @import("decision.zig");
const types = @import("run_types.zig");
const World = @import("world.zig").World;

pub const Failure = struct {
    kind: types.RunFailureKind,
    error_name: ?[]const u8 = null,
    check_name: ?[]const u8 = null,
    divergence: ?decision.Divergence = null,

    pub fn clone(self: Failure, allocator: std.mem.Allocator) !Failure {
        var result: Failure = .{ .kind = self.kind };
        errdefer result.deinit(allocator);
        if (self.error_name) |name| result.error_name = try allocator.dupe(u8, name);
        if (self.check_name) |name| result.check_name = try allocator.dupe(u8, name);
        if (self.divergence) |value| {
            const owned = try value.clone(allocator);
            result.divergence = owned;
        }
        return result;
    }

    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        if (self.error_name) |name| allocator.free(name);
        if (self.check_name) |name| allocator.free(name);
        if (self.divergence) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    event_count: u64,
    decision_tape: decision.Tape = .{},
    tape_complete: bool = true,
    outcome: union(enum) { passed, failed: Failure } = .passed,

    pub fn capture(allocator: std.mem.Allocator, world: *World, failure: ?Failure) !Result {
        var result: Result = .{ .allocator = allocator, .trace = try allocator.dupe(u8, world.traceBytes()), .event_count = world.nextEventIndex() };
        errdefer result.deinit();
        result.decision_tape = try world.cloneDecisionTape(allocator);
        if (failure) |value| {
            // A fallible clone must not use the destination union as its result
            // location: cleanup may observe the new tag before cloning succeeds.
            const owned = try value.clone(allocator);
            result.outcome = .{ .failed = owned };
        }
        return result;
    }

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.trace);
        self.decision_tape.deinit();
        switch (self.outcome) {
            .passed => {},
            .failed => |*failure| failure.deinit(self.allocator),
        }
        self.* = undefined;
    }

    pub fn decisionEntries(self: *const Result) []const decision.Decision {
        return self.decision_tape.entries;
    }
};

fn cloneFailureAllocationCase(allocator: std.mem.Allocator) !void {
    const original: Failure = .{
        .kind = .replay_diverged,
        .error_name = "DecisionReplayDiverged",
        .check_name = "owned check",
        .divergence = .{
            .kind = .site_mismatch,
            .tape_index = 0,
            .expected = .{ .site_id = "expected.choice", .logical_time_ns = 0, .microstep = 0, .preceding_event_index = null, .alternatives = .boolean, .selected = 1 },
            .actual = .{ .site_id = "actual.choice", .logical_time_ns = 0, .microstep = 0, .preceding_event_index = null, .alternatives = .boolean },
        },
    };
    var owned = try original.clone(allocator);
    defer owned.deinit(allocator);
    try std.testing.expectEqualStrings("actual.choice", owned.divergence.?.actual.?.site_id);
}

test "execution: failure diagnostics remain unowned until cloning succeeds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneFailureAllocationCase, .{});
}
