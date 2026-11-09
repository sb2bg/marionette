//! Regressions for scheduler failure, scoped crash sweeps, and fault reduction.
const std = @import("std");
const builtin = @import("builtin");
const mar = @import("marionette");

const watchdog_supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};
const watchdog_modes = .{
    @as(?mar.WatchdogOptions, null),
    if (watchdog_supported) @as(?mar.WatchdogOptions, .{}) else null,
};
const identity: mar.ReplayIdentity = .{ .build = "test-build-082", .sut = "terminal-await-v1" };

const PointerResult = struct {
    io: std.Io,
    cleanup_awaits: bool = false,
    var value: u32 = 42;
    var gate: u32 = 0;

    fn init(sim: mar.Sim) @This() {
        return .{ .io = sim.env.io() };
    }
    fn initAwait(sim: mar.Sim) !@This() {
        var app = init(sim);
        try app.awaitValue();
        return app;
    }
    fn initCleanup(sim: mar.Sim) @This() {
        return .{ .io = sim.env.io(), .cleanup_awaits = true };
    }
    fn worker(io: std.Io) *u32 {
        std.Io.sleep(io, .fromNanoseconds(10), .awake) catch {};
        return &value;
    }
    fn parked(io: std.Io) *u32 {
        io.futexWait(u32, &gate, 0) catch {};
        return &value;
    }
    fn deadlocked(case: *mar.SimCase(@This())) !void {
        var future = try std.Io.concurrent(case.app.io, parked, .{case.app.io});
        try std.testing.expectEqual(@as(u32, 42), future.await(case.app.io).*);
    }
    fn awaitValue(self: *@This()) !void {
        var future = try std.Io.concurrent(self.io, worker, .{self.io});
        const result = future.await(self.io);
        // Returning zero bytes as a pointer used to crash here.
        try std.testing.expectEqual(@as(u32, 42), result.*);
    }
    fn parent(io: std.Io) *u32 {
        var future = std.Io.concurrent(io, worker, .{io}) catch return &value;
        return future.await(io);
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        try case.app.awaitValue();
    }
    fn nested(case: *mar.SimCase(@This())) !void {
        var future = try std.Io.concurrent(case.app.io, parent, .{case.app.io});
        try std.testing.expectEqual(@as(u32, 42), future.await(case.app.io).*);
    }
    fn cancel(case: *mar.SimCase(@This())) !void {
        var future = try std.Io.concurrent(case.app.io, worker, .{case.app.io});
        try std.testing.expectEqual(@as(u32, 42), future.cancel(case.app.io).*);
    }
    fn passes(_: *mar.SimCase(@This())) !void {}
    fn check(case: *const mar.SimCase(@This())) !void {
        var future = try std.Io.concurrent(case.app.io, worker, .{case.app.io});
        try std.testing.expectEqual(@as(u32, 42), future.await(case.app.io).*);
    }
    pub fn deinit(self: *@This()) void {
        if (self.cleanup_awaits) self.awaitValue() catch {};
    }
};

fn expectBudgetFailure(report: *const mar.RunReport) !void {
    try std.testing.expect(report.* == .failed);
    try std.testing.expectEqual(mar.RunFailureKind.step_budget_exceeded, report.failed.kind);
    try std.testing.expectEqualStrings("StepBudgetExceeded", report.failed.error_name.?);
    try std.testing.expect(report.failed.tape_complete);
    try std.testing.expectEqual(@as(usize, 0), report.failed.second_trace.len);
    try mar.expectTraceContains(report.failed.first_trace, "scheduler.step_budget_exceeded");
}

test "082: terminal awaits preserve typed results and replay budget failures" {
    inline for (watchdog_modes) |watchdog| {
        inline for (.{ PointerResult.scenario, PointerResult.nested, PointerResult.cancel }) |scenario| {
            var report = try mar.runSimCase(.{
                .allocator = std.testing.allocator,
                .seed = 1234,
                .simulate = mar.World.SimulateOptions{ .step_budget = if (scenario == PointerResult.cancel) 0 else 1 },
                .watchdog = watchdog,
                .init = PointerResult.init,
                .scenario = scenario,
            });
            defer report.deinit();
            try expectBudgetFailure(&report);

            const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
            defer std.testing.allocator.free(bytes);
            var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
            defer capsule.deinit();
            var replayed = try mar.replaySimCase(.{
                .allocator = std.testing.allocator,
                .init = PointerResult.init,
                .scenario = scenario,
            }, &capsule, identity);
            defer replayed.deinit();
            try expectBudgetFailure(&replayed);
        }
    }
}

test "082: initialization, checks, and cleanup cannot return a fabricated future result" {
    inline for (watchdog_modes) |watchdog| {
        inline for (.{ PointerResult.initAwait, PointerResult.init, PointerResult.initCleanup }, 0..) |initialize, phase| {
            var report = try mar.runSimCase(.{
                .allocator = std.testing.allocator,
                .seed = 1234,
                .simulate = mar.World.SimulateOptions{ .step_budget = 1 },
                .watchdog = watchdog,
                .init = initialize,
                .scenario = PointerResult.passes,
                .checks = if (phase == 1) &[_]mar.StateCheck(mar.SimCase(PointerResult)){
                    .{ .name = "await.value", .phase = .after_scenario, .check = PointerResult.check },
                } else &.{},
            });
            defer report.deinit();
            try expectBudgetFailure(&report);
        }
    }
}

test "082: a completed future still returns its actual pointer" {
    var report = try mar.runSimCase(.{
        .allocator = std.testing.allocator,
        .simulate = mar.World.SimulateOptions{ .step_budget = 100 },
        .init = PointerResult.init,
        .scenario = PointerResult.scenario,
    });
    defer report.deinit();
    try std.testing.expect(report == .passed);
}

test "082: an unreachable pointer-valued future reports deadlock with a complete tape" {
    inline for (watchdog_modes) |watchdog| {
        var report = try mar.runSimCase(.{
            .allocator = std.testing.allocator,
            .simulate = mar.World.SimulateOptions{},
            .watchdog = watchdog,
            .init = PointerResult.init,
            .scenario = PointerResult.deadlocked,
        });
        defer report.deinit();
        try std.testing.expect(report == .failed);
        try std.testing.expectEqual(mar.RunFailureKind.scheduler_deadlock, report.failed.kind);
        try std.testing.expect(report.failed.tape_complete);
        try std.testing.expectEqual(@as(usize, 0), report.failed.second_trace.len);
    }
}

const ManagedCleanup = struct {
    const Child = struct {
        io: std.Io,
        future: std.Io.Future(*u32),
        self_ptr: ?*@This() = null,

        fn init(env: mar.Env) !@This() {
            const io = env.io();
            return .{ .io = io, .future = try std.Io.concurrent(io, PointerResult.worker, .{io}) };
        }
        pub fn deinit(self: *@This()) void {
            std.debug.assert(self == self.self_ptr.?);
            _ = self.future.await(self.io).*;
        }
    };
    fn init(sim: mar.Sim) !@This() {
        const managed = try sim.manageProcess(Child, 0, Child.init);
        managed.state().?.self_ptr = managed.state().?;
        return .{};
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        try std.Io.sleep(case.env().io(), .fromNanoseconds(10), .awake);
    }
};

test "082: managed cleanup interrupted by a terminal await is never retried" {
    inline for (watchdog_modes) |watchdog| {
        var report = try mar.runSimCase(.{
            .allocator = std.testing.allocator,
            .simulate = mar.World.SimulateOptions{ .step_budget = 0 },
            .watchdog = watchdog,
            .init = ManagedCleanup.init,
            .scenario = ManagedCleanup.scenario,
        });
        defer report.deinit();
        try expectBudgetFailure(&report);
    }
}

const Sweep = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }
    fn rearmRecovery(case: *mar.SimCase(@This())) !void {
        try case.armCrashPoint();
        case.env().disk.write(.{ .path = "data", .offset = 0, .bytes = "DATA" }) catch |err| {
            if (err != error.DiskCrashed) return err;
            try case.control().disk.restart();
            try case.control().process.restart(0);
            try case.control().disk.crashAfterOps(1000);
            // Finishing the sweep must neither forget its firing nor cancel
            // this separate request made by recovery code.
            try std.testing.expect(try case.finishCrashPoint());
            try std.testing.expect(try case.control().disk.disarmCrash());
        };
    }
    fn rearmOnReturn(case: *mar.SimCase(@This())) !void {
        try case.armCrashPoint();
        case.env().disk.write(.{ .path = "data", .offset = 0, .bytes = "DATA" }) catch |err| {
            if (err != error.DiskCrashed) return err;
            try case.control().disk.restart();
            try case.control().process.restart(0);
            try case.control().disk.crashAfterOps(1000);
        };
    }
    fn manualCrash(case: *mar.SimCase(@This())) !void {
        try case.armCrashPoint();
        try case.control().disk.crash();
        try case.control().disk.restart();
        try case.control().process.restart(0);
    }
    fn replacedCrash(case: *mar.SimCase(@This())) !void {
        try case.armCrashPoint();
        try case.control().disk.crashAfterOps(0);
        try std.testing.expectError(error.DiskCrashed, case.env().disk.write(.{ .path = "other", .offset = 0, .bytes = "DATA" }));
        try case.control().disk.restart();
        try case.control().process.restart(0);
    }
    fn replacedTrackedCrash(case: *mar.SimCase(@This())) !void {
        try case.armCrashPoint();
        var replacement: mar.DiskControl.CrashTrigger = .{};
        try case.control().disk.crashAfterOpsTracked(0, &replacement);
        try std.testing.expectError(error.DiskCrashed, case.env().disk.write(.{ .path = "other", .offset = 0, .bytes = "DATA" }));
        try std.testing.expect(replacement.fired);
        try case.control().disk.restart();
        try case.control().process.restart(0);
    }
};

test "082: sweep outcomes belong to the sweep's particular armed crash" {
    inline for (watchdog_modes) |watchdog| {
        inline for (.{ Sweep.rearmRecovery, Sweep.rearmOnReturn, Sweep.manualCrash, Sweep.replacedCrash, Sweep.replacedTrackedCrash }, 0..) |scenario, index| {
            var result = try mar.sweepCrashPoints(.{
                .allocator = std.testing.allocator,
                .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
                .init = Sweep.init,
                .scenario = scenario,
                .watchdog = watchdog,
            }, .{ .profile = .clean, .max_points = 4 });
            defer result.deinit();
            try std.testing.expect(result.failure == null);
            try std.testing.expectEqual(@as(u64, if (index < 2) 2 else 1), result.points);
            try std.testing.expectEqual(@as(u64, if (index < 2) 1 else 0), result.injected);
            try std.testing.expectEqual(result.injected, result.effects.injected);
        }
    }
}

const AutomaticFaults = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }
    fn process(case: *mar.SimCase(@This())) !void {
        try case.control().process.setDynamics(0, .{ .crash_rate = .percent(50), .restart_rate = .percent(50) });
        try case.control().runFor(1000);
        return error.PlantedFailure;
    }
    fn network(case: *mar.SimCase(@This())) !void {
        try case.control().network.setPartitionDynamics(.{ .partition_rate = .percent(50), .unpartition_rate = .percent(50) });
        try case.control().network.setClogs(.{ .path_clog_rate = .percent(50), .path_clog_duration_ns = 2 });
        try case.control().runFor(1000);
        return error.PlantedFailure;
    }
};

test "082: reduction removes automatic process and network schedules" {
    inline for (.{ AutomaticFaults.process, AutomaticFaults.network }, 0..) |scenario, index| {
        var reduced = try mar.reduceSimCase(.{
            .allocator = std.testing.allocator,
            .seed = 1234,
            .simulate = mar.World.SimulateOptions{ .network = .{ .semantics = .legacy_v0, .nodes = 2 } },
            .init = AutomaticFaults.init,
            .scenario = scenario,
        }, .{});
        defer reduced.deinit();
        const original = try mar.faultCoverage(reduced.original.failed.first_trace);
        try std.testing.expect(if (index == 0) original.process_kills > 0 else original.network_partitions > 0);
        if (index == 1) try mar.expectTraceContains(reduced.original.failed.first_trace, "network.clog from=");
        const minimized = reduced.report();
        const faults = try mar.faultCoverage(minimized.failed.first_trace);
        try std.testing.expectEqual(@as(usize, 0), reduced.remaining_groups);
        try std.testing.expect(reduced.one_minimal);
        try std.testing.expectEqual(@as(u64, 0), faults.process_kills);
        try std.testing.expectEqual(@as(u64, 0), faults.network_partitions);
        try std.testing.expect(std.mem.indexOf(u8, minimized.failed.first_trace, "network.clog from=") == null);

        const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, minimized, identity);
        defer std.testing.allocator.free(bytes);
        var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
        defer capsule.deinit();
        var replayed = try mar.replaySimCase(.{
            .allocator = std.testing.allocator,
            .init = AutomaticFaults.init,
            .scenario = scenario,
        }, &capsule, identity);
        defer replayed.deinit();
        try std.testing.expect(replayed == .failed);
        try std.testing.expectEqualStrings(minimized.failed.first_trace, replayed.failed.first_trace);
    }
}
