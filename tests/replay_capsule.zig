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

const PropertyApp = struct {
    sim: mar.Sim,
    value: u8 = 0,

    fn init(sim: mar.Sim) @This() {
        return .{ .sim = sim };
    }
    fn brokenInit(_: mar.Sim) !@This() {
        return error.InitFailed;
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        case.app.value = 1;
        try case.env().record("property.scenario", .{});
    }
    fn brokenScenario(case: *mar.SimCase(@This())) !void {
        try scenario(case);
        return error.ScenarioFailed;
    }
    fn initial(case: *const mar.SimCase(@This())) !void {
        if (case.app.value != 0) return error.BadInitialState;
        try case.env().record("property.initial", .{});
    }
    fn final(case: *const mar.SimCase(@This())) !void {
        if (case.app.value != 1) return error.BadFinalState;
        try case.env().record("property.final", .{});
    }
    fn invariant(case: *const mar.SimCase(@This())) !void {
        try case.env().record("property.invariant value={}", .{case.app.value});
    }
    fn fail(_: *const mar.SimCase(@This())) !void {
        return error.InvariantBroken;
    }
    pub fn deinit(self: *@This()) void {
        self.sim.env.record("property.cleanup", .{}) catch {};
    }
};

test "properties: lifecycle order, default phase, and capsule replay" {
    const checks = [_]mar.StateCheck(mar.SimCase(PropertyApp)){
        .{ .name = "initial", .phase = .after_init, .check = PropertyApp.initial },
        .{ .name = "invariant", .phase = .both, .check = PropertyApp.invariant },
        .{ .name = "final", .check = PropertyApp.final },
    };
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{},
        .init = PropertyApp.init,
        .scenario = PropertyApp.scenario,
        .checks = &checks,
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report.passed.trace, "property.cleanup"));
    var remaining = report.passed.trace;
    for ([_][]const u8{
        "property.initial",           "property.invariant value=0", "property.scenario",
        "property.invariant value=1", "property.final",             "property.cleanup",
    }) |needle| {
        const index = std.mem.indexOf(u8, remaining, needle) orelse return error.MissingLifecycleEvent;
        remaining = remaining[index + needle.len ..];
    }
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replay = try mar.replaySimCase(.{
        .allocator = std.testing.allocator,
        .init = PropertyApp.init,
        .scenario = PropertyApp.scenario,
        .checks = &checks,
    }, &capsule, identity);
    defer replay.deinit();
    try std.testing.expect(replay == .passed);
    const invalid = [_]mar.StateCheck(mar.SimCase(PropertyApp)){
        .{ .name = "", .check = PropertyApp.fail },
    };
    try std.testing.expectError(error.InvalidStateChecks, mar.replaySimCase(.{
        .allocator = std.testing.allocator,
        .init = PropertyApp.brokenInit,
        .scenario = PropertyApp.scenario,
        .checks = &invalid,
    }, &capsule, identity));
    const legacy = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "version=4", "version=3");
    defer std.testing.allocator.free(legacy);
    try std.testing.expectError(error.UnsupportedReplayVersion, mar.ReplayCapsule.decode(std.testing.allocator, legacy));
}

test "properties: first failure stops lifecycle and survives watchdog and capsule" {
    inline for (.{ @as(?mar.WatchdogOptions, null), @as(?mar.WatchdogOptions, .{}) }) |watchdog| {
        if (watchdog != null and !@import("builtin").os.tag.isDarwin() and @import("builtin").os.tag != .linux) continue;
        const checks = [_]mar.StateCheck(mar.SimCase(PropertyApp)){
            .{ .name = "service.safety", .phase = .both, .check = PropertyApp.fail },
            .{ .name = "must.not.run", .phase = .both, .check = PropertyApp.invariant },
        };
        var report = try mar.runSimCase(.{
            .allocator = std.testing.allocator,
            .simulate = mar.World.SimulateOptions{},
            .init = PropertyApp.init,
            .scenario = PropertyApp.scenario,
            .checks = &checks,
            .watchdog = watchdog,
        });
        defer report.deinit();
        try std.testing.expect(report == .failed);
        try std.testing.expectEqual(mar.RunFailureKind.check_failed, report.failed.kind);
        try std.testing.expectEqualStrings("service.safety", report.failed.check_name.?);
        try std.testing.expectEqualStrings("InvariantBroken", report.failed.error_name.?);
        try std.testing.expectEqual(@as(usize, 0), report.failed.second_trace.len);
        try mar.expectTraceContains(report.failed.first_trace, "phase=after_init");
        try mar.expectTraceContains(report.failed.first_trace, "property.cleanup");
        try std.testing.expect(std.mem.indexOf(u8, report.failed.first_trace, "property.scenario") == null);
        try std.testing.expect(std.mem.indexOf(u8, report.failed.first_trace, "must.not.run") == null);
        const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
        defer std.testing.allocator.free(bytes);
        var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
        defer capsule.deinit();
        var replay = try mar.replaySimCase(.{
            .allocator = std.testing.allocator,
            .init = PropertyApp.init,
            .scenario = PropertyApp.scenario,
            .checks = &checks,
        }, &capsule, identity);
        defer replay.deinit();
        try std.testing.expect(replay == .failed);
        try std.testing.expectEqual(mar.RunFailureKind.check_failed, replay.failed.kind);
        try std.testing.expectEqualStrings("service.safety", replay.failed.check_name.?);
    }
}

test "properties: invalid IDs are rejected before initialization or watchdog validation" {
    inline for (.{
        &[_]mar.StateCheck(mar.SimCase(PropertyApp)){
            .{ .name = "", .check = PropertyApp.fail },
        },
        &[_]mar.StateCheck(mar.SimCase(PropertyApp)){
            .{ .name = "duplicate", .phase = .after_init, .check = PropertyApp.fail },
            .{ .name = "duplicate", .check = PropertyApp.fail },
        },
    }) |checks| {
        try std.testing.expectError(error.InvalidStateChecks, mar.runSimCase(.{
            .allocator = std.testing.allocator,
            .simulate = mar.World.SimulateOptions{},
            .init = PropertyApp.brokenInit,
            .scenario = PropertyApp.scenario,
            .checks = checks,
            .watchdog = mar.WatchdogOptions{ .trace_capacity = 0 },
        }));
    }
}

test "properties: initialization and scenario errors skip later checks" {
    const checks = [_]mar.StateCheck(mar.SimCase(PropertyApp)){
        .{ .name = "initial", .phase = .after_init, .check = PropertyApp.initial },
        .{ .name = "final", .check = PropertyApp.fail },
    };
    inline for (.{ PropertyApp.brokenInit, PropertyApp.init }, 0..) |init, index| {
        var report = try mar.runSimCase(.{
            .allocator = std.testing.allocator,
            .simulate = mar.World.SimulateOptions{},
            .init = init,
            .scenario = PropertyApp.brokenScenario,
            .checks = &checks,
        });
        defer report.deinit();
        try std.testing.expect(report == .failed);
        try std.testing.expectEqual(mar.RunFailureKind.scenario_error, report.failed.kind);
        try std.testing.expectEqualStrings(if (index == 0) "InitFailed" else "ScenarioFailed", report.failed.error_name.?);
        try std.testing.expect(std.mem.indexOf(u8, report.failed.first_trace, "phase=after_scenario") == null);
    }
}
