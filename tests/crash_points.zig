//! Crash-point sweeps run a scenario once per disk operation, crashing
//! before it, so ordering bugs in durable code fail at an exact point.
const std = @import("std");
const mar = @import("marionette");

const identity: mar.ReplayIdentity = .{ .build = "test-build-081", .sut = "crash-points-v1" };

/// Two durable files with the invariant: if `second` exists, `first` does.
fn TwoFileCommit(comptime first: []const u8, comptime second: []const u8) type {
    return struct {
        const App = @This();

        fn init(_: mar.Sim) @This() {
            return .{};
        }

        fn writeDurably(disk: mar.Disk, path: []const u8) !void {
            try disk.write(.{ .path = path, .offset = 0, .bytes = "DATA" });
            try disk.sync(.{ .path = path });
            try disk.syncDir(.{ .path = "." });
        }

        fn scenario(case: *mar.SimCase(@This())) !void {
            const control = case.control();
            // A crash loses everything not yet synced.
            try control.disk.setFaults(.{ .crash_lost_write_rate = .always(), .crash_lost_metadata_rate = .always() });
            try case.armCrashPoint();
            const disk = case.env().disk;
            const committed = blk: {
                writeDurably(disk, first) catch |err| break :blk err;
                writeDurably(disk, second) catch |err| break :blk err;
            };
            // Recovery below must not be crashed by a point the commit left unused.
            const fired = try case.finishCrashPoint();
            committed catch |err| switch (err) {
                error.DiskCrashed => {
                    try std.testing.expect(fired);
                    try control.disk.restart();
                    try control.process.restart(0);
                },
                else => return err,
            };
            if (committed) |_| try std.testing.expect(!fired) else |_| {}
            for ([_][]const u8{ first, second }) |path| _ = disk.stat(.{ .path = path }) catch {};
        }

        fn ordered(case: *const mar.SimCase(@This())) !void {
            const disk = case.env().disk;
            _ = disk.stat(.{ .path = "second" }) catch return;
            _ = disk.stat(.{ .path = "first" }) catch return error.SecondWithoutFirst;
        }

        const checks = [_]mar.StateCheck(mar.SimCase(@This())){.{ .name = "commit.ordered", .check = ordered }};

        fn config() Config {
            return .{ .allocator = std.testing.allocator };
        }
        const Config = struct {
            allocator: std.mem.Allocator,
            seed: u64 = 0x081,
            simulate: mar.World.SimulateOptions = .{ .disk = .{ .sector_size = 4 } },
            comptime init: @TypeOf(init) = init,
            comptime scenario: @TypeOf(scenario) = scenario,
            comptime checks: []const mar.StateCheck(mar.SimCase(App)) = &checks,
        };
    };
}

const Correct = TwoFileCommit("first", "second");
const Reversed = TwoFileCommit("second", "first");

test "crash points: every point of a correctly ordered commit passes" {
    var result = try mar.sweepCrashPoints(Correct.config(), .{});
    defer result.deinit();
    try std.testing.expect(result.failure == null);
    // Six operations (write, sync, and directory sync per file), each crashed
    // before, then one run where the commit finishes.
    try std.testing.expectEqual(@as(u64, 7), result.points);
    try mar.expectCrashPointsPass(Correct.config(), .{});
}

test "crash points: a misordered commit fails at its exact point and replays" {
    // Without a sweep the armed point does nothing and the bug stays hidden.
    try mar.expectSimPass(Reversed.config());

    var result = try mar.sweepCrashPoints(Reversed.config(), .{});
    defer result.deinit();
    const failure = result.failure.?.failed;
    try std.testing.expectEqual(mar.RunFailureKind.check_failed, failure.kind);
    try std.testing.expectEqualStrings("SecondWithoutFirst", failure.error_name.?);
    // `second` is durable after its three operations; crashing before the
    // fourth leaves it without `first`.
    try std.testing.expectEqual(@as(u64, 4), result.points);
    try mar.expectTraceContains(failure.first_trace, "run.attribute key=marionette.crash_point value=uint:3");

    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &result.failure.?, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try mar.replaySimCase(Reversed.config(), &capsule, identity);
    defer replayed.deinit();
    try std.testing.expect(replayed == .failed);
    try std.testing.expectEqualStrings("SecondWithoutFirst", replayed.failed.error_name.?);
}

const Unarmed = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        try case.env().disk.write(.{ .path = "data", .offset = 0, .bytes = "DATA" });
    }
};

test "crash points: a scenario that never arms is reported" {
    try std.testing.expectError(error.CrashPointNotArmed, mar.sweepCrashPoints(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
        .init = Unarmed.init,
        .scenario = Unarmed.scenario,
    }, .{}));
}
