const std = @import("std");
const mar = @import("marionette");
const identity: mar.ReplayIdentity = .{ .build = "test-build-070", .sut = "workload-v1" };
const App = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        _ = try case.control().world.chooseBool("workload.flip");
        var bytes: [256]u8 = undefined;
        case.env().io().random(&bytes);
        try case.env().record("app.digest value={}", .{std.hash.Wyhash.hash(0, &bytes)});
    }
    fn fail(case: *mar.SimCase(@This())) !void {
        try scenario(case);
        return error.PlantedFailure;
    }
};

fn decodeWithAllocator(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var capsule = try mar.ReplayCapsule.decode(allocator, bytes);
    defer capsule.deinit();
}

test "replay capsule: owned byte decisions survive JSON roundtrip and execute again" {
    inline for (.{ App.scenario, App.fail }) |scenario| {
        var report = try mar.runSimCase(.{
            .allocator = std.testing.allocator,
            .seed = 1234,
            .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 16 } },
            .init = App.init,
            .scenario = scenario,
            .seed_schedule = &.{.{ .at = .{ .sim_time_ns = 0, .microstep = 1 }, .seed = @as(u64, 99) }},
            .attributes = &.{
                mar.runAttribute("fraction", @as(f64, 1e200)),
                mar.runAttribute("count", @as(u64, 7)),
                mar.runAttribute("tiny", @as(f64, -1e-300)),
                mar.runAttribute("infinity", std.math.inf(f64)),
                mar.runAttribute("negative_infinity", -std.math.inf(f64)),
                mar.runAttribute("nan", std.math.nan(f64)),
                mar.runAttribute("negative_zero", @as(f64, -0.0)),
            },
            .tags = &.{ "replay", "owned" },
        });
        const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
        defer std.testing.allocator.free(bytes);
        report.deinit();
        var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
        defer capsule.deinit();
        try std.testing.expectEqual(@as(u64, 16), capsule.simulateOptions().disk.sector_size);
        var replay = try mar.replaySimCase(.{ .allocator = std.testing.allocator, .init = App.init, .scenario = scenario }, &capsule, identity);
        defer replay.deinit();
        if (scenario == App.scenario) {
            try std.testing.expect(replay == .passed);
            try mar.expectTraceContains(replay.passed.trace, "key=count value=uint:7");
        } else {
            try std.testing.expect(replay == .failed);
            try std.testing.expectEqual(mar.RunFailureKind.scenario_error, replay.failed.kind);
            try std.testing.expectEqualStrings("PlantedFailure", replay.failed.error_name.?);
        }
        try std.testing.expectError(error.IncompatibleReplay, mar.replaySimCase(.{
            .allocator = std.testing.allocator,
            .init = App.init,
            .scenario = scenario,
        }, &capsule, .{ .build = "changed-build", .sut = identity.sut }));
        try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeWithAllocator, .{bytes});
    }
}

test "replay capsule: reject unsupported version and incomplete watchdog tape" {
    var report = try mar.runSimCase(.{ .allocator = std.testing.allocator, .simulate = mar.World.SimulateOptions{}, .init = App.init, .scenario = App.scenario });
    defer report.deinit();
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"version\":1", "\"version\":999");
    defer std.testing.allocator.free(changed);
    try std.testing.expectError(error.UnsupportedReplayVersion, mar.ReplayCapsule.decode(std.testing.allocator, changed));
    report.passed.tape_complete = false;
    try std.testing.expectError(error.IncompleteDecisionTape, mar.ReplayCapsule.encode(std.testing.allocator, &report, identity));
}

test "watchdog completed result retains the same replay capsule" {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux) return error.SkipZigTest;
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = App.init,
        .scenario = App.scenario,
        .watchdog = mar.WatchdogOptions{},
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
    try std.testing.expect(report.passed.tape_complete);
    try std.testing.expectEqual(@as(usize, 2), report.passed.decision_tape.entries.len);
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replay = try mar.replaySimCase(.{ .allocator = std.testing.allocator, .init = App.init, .scenario = App.scenario }, &capsule, identity);
    defer replay.deinit();
    try std.testing.expect(replay == .passed);
}

test "replay: changed random byte request is a structured divergence" {
    const Changing = struct {
        var count: usize = 0;
        fn init(_: mar.Sim) @This() {
            return .{};
        }
        fn scenario(case: *mar.SimCase(@This())) void {
            var bytes: [2]u8 = undefined;
            count += 1;
            case.env().io().random(bytes[0..@min(count, bytes.len)]);
        }
    };
    Changing.count = 0;
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = Changing.init,
        .scenario = Changing.scenario,
    });
    defer report.deinit();
    try std.testing.expect(report == .failed);
    try std.testing.expectEqual(mar.RunFailureKind.replay_diverged, report.failed.kind);
    try std.testing.expectEqual(mar.DecisionDivergenceKind.alternatives_mismatch, report.failed.replay_divergence.?.kind);
}

test "watchdog reports a worker exit as a crash rather than a stall" {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const Crashing = struct {
        fn scenario(_: *mar.SimCase(App)) void {
            std.process.exit(42);
        }
    };
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = App.init,
        .scenario = Crashing.scenario,
        .watchdog = mar.WatchdogOptions{},
    });
    defer report.deinit();
    try std.testing.expect(report == .failed);
    try std.testing.expectEqual(mar.RunFailureKind.worker_crashed, report.failed.kind);
    try std.testing.expect(!report.failed.tape_complete);
}

test "replay capsule rejects corrupt trace, invalid clock, and truncated JSON" {
    var report = try mar.runSimCase(.{ .allocator = std.testing.allocator, .simulate = mar.World.SimulateOptions{}, .init = App.init, .scenario = App.scenario });
    defer report.deinit();
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    inline for (.{ .{ "event=0", "event=9" }, .{ "\"tick_ns\":1", "\"tick_ns\":0" } }) |mutation| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, mutation[0], mutation[1]);
        defer std.testing.allocator.free(changed);
        try std.testing.expectError(error.InvalidReplayArtifact, mar.ReplayCapsule.decode(std.testing.allocator, changed));
    }
    try std.testing.expectError(error.UnexpectedEndOfInput, mar.ReplayCapsule.decode(std.testing.allocator, bytes[0 .. bytes.len - 1]));
}

test "byte tape overrides a different generated seed and rejects damaged bytes" {
    var original = try mar.World.init(std.testing.allocator, .{ .seed = 1 });
    defer original.deinit();
    var expected: [32]u8 = undefined;
    try original.randomBytes(&expected);
    var tape = try original.cloneDecisionTape(std.testing.allocator);
    defer tape.deinit();
    var replay = try mar.World.init(std.testing.allocator, .{ .seed = 9876, .decisions = .{ .replay = tape.entries } });
    defer replay.deinit();
    var actual: [32]u8 = undefined;
    try replay.randomBytes(&actual);
    try replay.finishDecisionReplay();
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    @constCast(tape.entries[0].byte_value)[0] ^= 1;
    var damaged = try mar.World.init(std.testing.allocator, .{ .seed = 1, .decisions = .{ .replay = tape.entries } });
    defer damaged.deinit();
    try std.testing.expectError(error.DecisionReplayDiverged, damaged.randomBytes(&actual));
    try std.testing.expectEqual(mar.DecisionDivergenceKind.invalid_tape_entry, damaged.decisionDivergence().?.kind);
}
