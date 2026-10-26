//! Crash-point sweeps run a scenario once per disk operation, crashing
//! before it, so ordering bugs in durable code fail at an exact point.
const std = @import("std");
const builtin = @import("builtin");
const mar = @import("marionette");

const identity: mar.ReplayIdentity = .{ .build = "test-build-081", .sut = "crash-points-v1" };
const watchdog_supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};
const watchdog_modes = .{
    @as(?mar.WatchdogOptions, null),
    if (watchdog_supported) @as(?mar.WatchdogOptions, .{}) else null,
};

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

const UnrelatedCrash = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        // An existing harness fault does not arm the sweep's current point.
        try case.control().disk.crashAfterOps(100);
        try case.env().disk.write(.{ .path = "data", .offset = 0, .bytes = "DATA" });
        _ = try case.control().disk.disarmCrash();
    }
};

test "crash points: ordinary disk arming does not satisfy sweep arming" {
    inline for (watchdog_modes) |watchdog| {
        try std.testing.expectError(error.CrashPointNotArmed, mar.sweepCrashPoints(.{
            .allocator = std.testing.allocator,
            .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
            .init = UnrelatedCrash.init,
            .scenario = UnrelatedCrash.scenario,
            .watchdog = watchdog,
        }, .{}));
    }
}

const ScopedCrash = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }

    fn crashAndRecover(case: *mar.SimCase(@This())) !void {
        const control = case.control();
        try control.disk.crashAfterOps(0);
        try std.testing.expectError(error.DiskCrashed, case.env().disk.write(.{ .path = "other", .offset = 0, .bytes = "DATA" }));
        try control.disk.restart();
        try control.process.restart(0);
    }

    fn scenario(case: *mar.SimCase(@This())) !void {
        try crashAndRecover(case);
        try case.armCrashPoint();
        const committed = case.env().disk.write(.{ .path = "commit", .offset = 0, .bytes = "DATA" });
        const fired = try case.finishCrashPoint();
        committed catch |err| {
            if (err != error.DiskCrashed) return err;
            try std.testing.expect(fired);
            try case.control().disk.restart();
            try case.control().process.restart(0);
        };
        try crashAndRecover(case);
    }

    fn finishOnReturn(case: *mar.SimCase(@This())) !void {
        try case.armCrashPoint();
        case.env().disk.write(.{ .path = "commit", .offset = 0, .bytes = "DATA" }) catch |err| {
            if (err != error.DiskCrashed) return err;
            try case.control().disk.restart();
            try case.control().process.restart(0);
        };
        // The runner finishes the armed region when this scenario returns.
    }
};

test "crash points: setup and recovery crashes do not extend the sweep" {
    inline for (watchdog_modes) |watchdog| {
        var result = try mar.sweepCrashPoints(.{
            .allocator = std.testing.allocator,
            .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
            .init = ScopedCrash.init,
            .scenario = ScopedCrash.scenario,
            .watchdog = watchdog,
        }, .{ .max_points = 4 });
        defer result.deinit();
        try std.testing.expect(result.failure == null);
        try std.testing.expectEqual(@as(u64, 2), result.points);
    }
}

test "crash points: passing sweep outcomes survive capsule replay" {
    inline for (watchdog_modes) |watchdog| {
        for (0..2) |point| {
            var report = try mar.runSimCase(.{
                .allocator = std.testing.allocator,
                .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
                .init = ScopedCrash.init,
                .scenario = ScopedCrash.scenario,
                .attributes = &.{mar.runAttribute(mar.crash_point_attribute, point)},
                .watchdog = watchdog,
            });
            defer report.deinit();
            try std.testing.expect(report == .passed);
            try std.testing.expectEqual(@as(?bool, point == 0), report.passed.crash_point_fired);

            const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
            defer std.testing.allocator.free(bytes);
            var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
            defer capsule.deinit();
            var replayed = try mar.replaySimCase(.{
                .allocator = std.testing.allocator,
                .init = ScopedCrash.init,
                .scenario = ScopedCrash.scenario,
            }, &capsule, identity);
            defer replayed.deinit();
            try std.testing.expect(replayed == .passed);
            try std.testing.expectEqual(@as(?bool, point == 0), replayed.passed.crash_point_fired);
        }
    }
}

test "crash points: returning from the scenario retains the sweep outcome" {
    var result = try mar.sweepCrashPoints(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
        .init = ScopedCrash.init,
        .scenario = ScopedCrash.finishOnReturn,
    }, .{ .max_points = 4 });
    defer result.deinit();
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqual(@as(u64, 2), result.points);
}

/// Arms a crash point, then fails; cleanup still writes to the disk.
const FailsBeforeCleanup = struct {
    disk: mar.Disk,

    fn init(sim: mar.Sim) @This() {
        return .{ .disk = sim.env.disk };
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        try case.armCrashPoint();
        return error.PlantedFailure;
    }
    pub fn deinit(self: *@This()) void {
        self.disk.write(.{ .path = "cleanup", .offset = 0, .bytes = "DONE" }) catch {};
    }
};

test "crash points: a failed scenario's cleanup runs with the crash disarmed" {
    var result = try mar.sweepCrashPoints(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
        .init = FailsBeforeCleanup.init,
        .scenario = FailsBeforeCleanup.scenario,
    }, .{});
    defer result.deinit();
    const failure = result.failure.?.failed;
    try std.testing.expectEqualStrings("PlantedFailure", failure.error_name.?);
    try mar.expectTraceContains(failure.first_trace, "disk.fault kind=armed_crash disarmed=true");
    try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "armed_crash fired=true") == null);
}

fn reversedWithArtifacts(dir: std.Io.Dir, include_passes: bool) ReversedArtifactsConfig {
    return .{ .allocator = std.testing.allocator, .artifacts = .{
        .io = std.testing.io,
        .parent = dir,
        .name = "failing-point",
        .identity = identity,
        .include_passes = include_passes,
    } };
}
const ReversedArtifactsConfig = struct {
    allocator: std.mem.Allocator,
    seed: u64 = 0x081,
    simulate: mar.World.SimulateOptions = .{ .disk = .{ .sector_size = 4 } },
    comptime init: @TypeOf(Reversed.init) = Reversed.init,
    comptime scenario: @TypeOf(Reversed.scenario) = Reversed.scenario,
    comptime checks: []const mar.StateCheck(mar.SimCase(Reversed)) = &Reversed.checks,
    artifacts: mar.ArtifactOptions,
};

test "crash points: the failing point is written to the configured artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.ExpectedRunPass, mar.expectCrashPointsPass(reversedWithArtifacts(tmp.dir, false), .{}));

    var dir = try tmp.dir.openDir(std.testing.io, "failing-point", .{});
    defer dir.close(std.testing.io);
    const bytes = try dir.readFileAlloc(std.testing.io, "replay.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try mar.replaySimCase(Reversed.config(), &capsule, identity);
    defer replayed.deinit();
    try std.testing.expectEqualStrings("SecondWithoutFirst", replayed.failed.error_name.?);
    try mar.expectTraceContains(replayed.failed.first_trace, "key=marionette.crash_point value=uint:3");
}

test "crash points: artifacts for every passing point are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.InvalidCrashSweepArtifacts, mar.sweepCrashPoints(reversedWithArtifacts(tmp.dir, true), .{}));
}
