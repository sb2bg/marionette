//! Deterministic step budgets turn yielding livelocks into exact failures.
const std = @import("std");
const mar = @import("marionette");

const identity: mar.ReplayIdentity = .{ .build = "test-build-080", .sut = "step-budget-v1" };
const budgeted: mar.World.SimulateOptions = .{ .step_budget = 500 };

const App = struct {
    io: std.Io,
    noise_count: u32 = 0,

    fn init(sim: mar.Sim) @This() {
        return .{ .io = sim.env.io() };
    }

    fn sleeper(io: std.Io) void {
        while (true) std.Io.sleep(io, .fromNanoseconds(10), .awake) catch return;
    }

    /// Hand the turn to the other player and wait for it back, forever.
    fn player(io: std.Io, turn: *u32, me: u32) void {
        while (true) {
            while (turn.* != me) io.futexWait(u32, turn, 1 - me) catch return;
            turn.* = 1 - me;
            io.futexWake(u32, turn, 1);
        }
    }

    fn noise(case: *mar.SimCase(@This())) !void {
        case.app.noise_count += 1;
        try case.env().record("app.noise count={}", .{case.app.noise_count});
    }

    fn spin(case: *mar.SimCase(@This())) !void {
        var future = try std.Io.concurrent(case.app.io, sleeper, .{case.app.io});
        future.await(case.app.io);
    }

    /// A sleeping task that never finishes, awaited from the scenario.
    fn awaitSleeper(case: *mar.SimCase(@This())) !void {
        try spin(case);
    }

    /// The scenario itself sleeps forever; no task is ever dispatched.
    fn mainSleeps(case: *mar.SimCase(@This())) !void {
        while (true) try std.Io.sleep(case.app.io, .fromNanoseconds(10), .awake);
    }

    /// Two tasks keep waking each other without advancing time.
    fn yieldPair(case: *mar.SimCase(@This())) !void {
        var turn: u32 = 0;
        var first = try std.Io.concurrent(case.app.io, player, .{ case.app.io, &turn, 0 });
        var second = try std.Io.concurrent(case.app.io, player, .{ case.app.io, &turn, 1 });
        first.await(case.app.io);
        second.await(case.app.io);
    }

    /// Removable noise in front of the livelock, for reduction.
    fn noisySpin(case: *mar.SimCase(@This())) !void {
        try case.action("noise.first", noise);
        try case.action("noise.second", noise);
        try case.action("spin", spin);
    }

    /// Bounded work that finishes well inside the budget.
    fn finite(case: *mar.SimCase(@This())) !void {
        for (0..8) |_| try std.Io.sleep(case.app.io, .fromNanoseconds(10), .awake);
    }
};

fn config(comptime scenario: anytype, simulate: mar.World.SimulateOptions) Config(scenario) {
    return .{ .allocator = std.testing.allocator, .simulate = simulate };
}

fn Config(comptime scenario_fn: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        seed: u64 = 0x57E9,
        tick_ns: u64 = 10,
        simulate: mar.World.SimulateOptions,
        comptime init: @TypeOf(App.init) = App.init,
        comptime scenario: @TypeOf(scenario_fn) = scenario_fn,
    };
}

fn expectBudgetFailure(report: mar.RunReport) !void {
    try std.testing.expect(report == .failed);
    const failure = report.failed;
    try std.testing.expectEqual(mar.RunFailureKind.step_budget_exceeded, failure.kind);
    try std.testing.expectEqualStrings("StepBudgetExceeded", failure.error_name.?);
    // Both executions reach the same step: complete tape, no second trace.
    try std.testing.expect(failure.tape_complete);
    try std.testing.expectEqual(@as(usize, 0), failure.second_trace.len);
    try mar.expectTraceContains(failure.first_trace, "scheduler.step_budget_exceeded budget=500");
}

test "step budget: a sleeping livelock fails exactly instead of hanging" {
    var report = try mar.runSimCase(config(App.awaitSleeper, budgeted));
    defer report.deinit();
    try expectBudgetFailure(report);
}

test "step budget: counts clock advances when the scenario sleeps forever" {
    var report = try mar.runSimCase(config(App.mainSleeps, budgeted));
    defer report.deinit();
    try expectBudgetFailure(report);
}

test "step budget: counts dispatches when tasks yield without advancing time" {
    var report = try mar.runSimCase(config(App.yieldPair, budgeted));
    defer report.deinit();
    try expectBudgetFailure(report);
}

test "step budget: a generous budget leaves passing traces unchanged" {
    var unbounded = try mar.runSimCase(config(App.finite, .{}));
    defer unbounded.deinit();
    var bounded = try mar.runSimCase(config(App.finite, budgeted));
    defer bounded.deinit();
    try std.testing.expect(unbounded == .passed and bounded == .passed);
    try std.testing.expectEqualStrings(unbounded.passed.trace, bounded.passed.trace);
}

test "step budget: the failure round-trips through a replay capsule" {
    var report = try mar.runSimCase(config(App.awaitSleeper, budgeted));
    defer report.deinit();
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"step_budget\":500") != null);

    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    try std.testing.expectEqual(@as(?u64, 500), capsule.simulateOptions().step_budget);
    var replayed = try mar.replaySimCase(config(App.awaitSleeper, .{}), &capsule, identity);
    defer replayed.deinit();
    try expectBudgetFailure(replayed);
}

test "step budget: an unset budget is omitted from capsules" {
    var report = try mar.runSimCase(config(App.finite, .{}));
    defer report.deinit();
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "step_budget") == null);
}

test "step budget: reduction removes work that does not cause the livelock" {
    var reduced = try mar.reduceSimCase(config(App.noisySpin, budgeted), .{});
    defer reduced.deinit();
    try std.testing.expect(reduced.minimized != null);
    try std.testing.expect(reduced.one_minimal);
    try expectBudgetFailure(reduced.report().*);
    try std.testing.expect(std.mem.indexOf(u8, reduced.report().failed.first_trace, "app.noise") == null);
}

/// Work that outlives the scenario: cleanup and initialization run past the
/// budget instead of the scenario body.
const Lingering = struct {
    io: std.Io,
    parked: ?std.Io.Future(void) = null,
    gate: u32 = 0,

    fn sleepUntilRefused(io: std.Io) void {
        while (true) std.Io.sleep(io, .fromNanoseconds(10), .awake) catch return;
    }

    /// Parks with no deadline and is never woken.
    fn parkForever(io: std.Io, gate: *u32) void {
        while (gate.* == 0) io.futexWait(u32, gate, 0) catch return;
    }

    fn init(sim: mar.Sim) @This() {
        return .{ .io = sim.env.io() };
    }

    fn initSleepsPastBudget(sim: mar.Sim) !@This() {
        sleepUntilRefused(sim.env.io());
        return error.InitGaveUp;
    }

    fn passes(_: *mar.SimCase(@This())) !void {}

    /// Spend the budget, then await a task that can never finish.
    fn awaitParkedAfterBudget(case: *mar.SimCase(@This())) !void {
        var parked = try std.Io.concurrent(case.app.io, parkForever, .{ case.app.io, &case.app.gate });
        sleepUntilRefused(case.app.io);
        parked.await(case.app.io);
    }

    pub fn deinit(self: *@This()) void {
        sleepUntilRefused(self.io);
        if (self.parked) |*parked| parked.await(self.io);
    }
};

const LingeringWithParkedTask = struct {
    inner: Lingering,
    // App state moves out of `init`, so the parked task's gate needs storage
    // that outlives the initializer's frame.
    var gate: u32 = 0;

    fn init(sim: mar.Sim) !@This() {
        var self: @This() = .{ .inner = Lingering.init(sim) };
        self.inner.parked = try std.Io.concurrent(self.inner.io, Lingering.parkForever, .{ self.inner.io, &gate });
        return self;
    }
    fn passes(_: *mar.SimCase(@This())) !void {}
    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
    }
};

fn lingeringConfig(comptime init_fn: anytype, comptime scenario_fn: anytype) LingeringConfig(init_fn, scenario_fn) {
    return .{ .allocator = std.testing.allocator };
}

fn LingeringConfig(comptime init_fn: anytype, comptime scenario_fn: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        seed: u64 = 0x57E9,
        tick_ns: u64 = 10,
        simulate: mar.World.SimulateOptions = budgeted,
        comptime init: @TypeOf(init_fn) = init_fn,
        comptime scenario: @TypeOf(scenario_fn) = scenario_fn,
    };
}

test "step budget: exhaustion during cleanup fails the run" {
    var report = try mar.runSimCase(lingeringConfig(Lingering.init, Lingering.passes));
    defer report.deinit();
    try expectBudgetFailure(report);
}

test "step budget: exhaustion during initialization is not a scenario error" {
    var report = try mar.runSimCase(lingeringConfig(Lingering.initSleepsPastBudget, Lingering.passes));
    defer report.deinit();
    try expectBudgetFailure(report);
}

test "step budget: awaiting a parked task afterwards keeps the budget failure" {
    var report = try mar.runSimCase(lingeringConfig(Lingering.init, Lingering.awaitParkedAfterBudget));
    defer report.deinit();
    try expectBudgetFailure(report);
}

test "step budget: cleanup that awaits a parked task keeps the budget failure" {
    var report = try mar.runSimCase(lingeringConfig(LingeringWithParkedTask.init, LingeringWithParkedTask.passes));
    defer report.deinit();
    try expectBudgetFailure(report);
}
