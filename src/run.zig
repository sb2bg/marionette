//! Scenario runner with built-in deterministic replay verification.

const std = @import("std");

const run_types = @import("run_types.zig");
const World = @import("world.zig").World;

pub const Check = run_types.Check;
pub const RunAttribute = run_types.RunAttribute;
pub const RunAttributeValue = run_types.RunAttributeValue;
pub const RunFailure = run_types.RunFailure;
pub const RunFailureKind = run_types.RunFailureKind;
pub const RunOptions = run_types.RunOptions;
pub const RunReport = run_types.RunReport;
pub const RunResult = run_types.RunResult;
pub const StateCheck = run_types.StateCheck;
pub const runAttribute = run_types.runAttribute;
pub const runAttributesFrom = run_types.runAttributesFrom;

const RunOnceResult = union(enum) {
    passed: RunResult,
    failed: RunFailure,

    fn deinit(self: *RunOnceResult) void {
        switch (self.*) {
            .passed => |*passed| passed.deinit(),
            .failed => |*failed| failed.deinit(),
        }
        self.* = undefined;
    }
};

/// Run `scenario` twice with the same seed and compare byte-identical traces.
///
/// Scenario errors are returned as `RunReport.failed` with the partial trace
/// preserved. Allocation failures while setting up or copying runner-owned
/// traces are returned as normal Zig errors.
pub fn run(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime scenario: fn (*World) anyerror!void,
) std.mem.Allocator.Error!RunReport {
    const no_state_checks = [_]StateCheck(NoState){};
    return runTwiceWithState(
        allocator,
        options,
        NoState,
        initNoState,
        scenarioWithoutState(scenario),
        &no_state_checks,
    );
}

/// Run a stateful scenario twice with fresh state and compare traces.
///
/// `init_state` is called once per replay attempt. Scenario state is not owned
/// by `RunReport`, and Phase 0 state must not require a deinitializer.
pub fn runWithState(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime State: type,
    comptime init_state: fn () State,
    comptime scenario: fn (*World, *State) anyerror!void,
    comptime state_checks: []const StateCheck(State),
) std.mem.Allocator.Error!RunReport {
    return runTwiceWithState(allocator, options, State, init_state, scenario, state_checks);
}

const NoState = struct {};

fn initNoState() NoState {
    return .{};
}

fn scenarioWithoutState(
    comptime scenario: fn (*World) anyerror!void,
) fn (*World, *NoState) anyerror!void {
    return struct {
        fn runScenario(world: *World, _: *NoState) anyerror!void {
            try scenario(world);
        }
    }.runScenario;
}

fn runTwiceWithState(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime State: type,
    comptime init_state: fn () State,
    comptime scenario: fn (*World, *State) anyerror!void,
    comptime state_checks: []const StateCheck(State),
) std.mem.Allocator.Error!RunReport {
    var first = try runOnceWithState(allocator, options, State, init_state, scenario, state_checks);
    switch (first) {
        .failed => |failure| return .{ .failed = failure },
        .passed => {},
    }
    errdefer first.deinit();

    var second = try runOnceWithState(allocator, options, State, init_state, scenario, state_checks);
    switch (second) {
        .failed => |failure| {
            const passed = first.passed;
            return .{ .failed = .{
                .allocator = allocator,
                .options = options,
                .first_trace = passed.trace,
                .second_trace = failure.first_trace,
                .first_event_count = passed.event_count,
                .second_event_count = failure.first_event_count,
                .kind = failure.kind,
                .error_name = failure.error_name,
                .check_name = failure.check_name,
            } };
        },
        .passed => {},
    }
    errdefer second.deinit();

    const first_passed = first.passed;
    const second_passed = second.passed;
    if (!std.mem.eql(u8, first_passed.trace, second_passed.trace)) {
        return .{ .failed = .{
            .allocator = allocator,
            .options = options,
            .kind = .determinism_mismatch,
            .first_trace = first_passed.trace,
            .second_trace = second_passed.trace,
            .first_event_count = first_passed.event_count,
            .second_event_count = second_passed.event_count,
        } };
    }

    allocator.free(second_passed.trace);
    return .{ .passed = first_passed };
}

fn runOnceWithState(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime State: type,
    comptime init_state: fn () State,
    comptime scenario: fn (*World, *State) anyerror!void,
    comptime state_checks: []const StateCheck(State),
) std.mem.Allocator.Error!RunOnceResult {
    var world = try World.init(allocator, options.worldOptions());
    defer world.deinit();
    try recordRunContext(&world, options);

    var state = init_state();
    scenario(&world, &state) catch |err| {
        return .{ .failed = try failureFromWorld(
            allocator,
            options,
            .scenario_error,
            &world,
            err,
            null,
        ) };
    };

    for (state_checks) |check| {
        check.check(&world, &state) catch |err| {
            return .{ .failed = try failureFromWorld(
                allocator,
                options,
                .check_failed,
                &world,
                err,
                check.name,
            ) };
        };
    }

    for (options.checks) |check| {
        check.check(&world) catch |err| {
            return .{ .failed = try failureFromWorld(
                allocator,
                options,
                .check_failed,
                &world,
                err,
                check.name,
            ) };
        };
    }

    return .{ .passed = .{
        .allocator = allocator,
        .options = options,
        .trace = try allocator.dupe(u8, world.traceBytes()),
        .event_count = world.nextEventIndex(),
    } };
}

fn recordRunContext(world: *World, options: RunOptions) std.mem.Allocator.Error!void {
    if (options.profile_name) |profile_name| {
        try world.record("run.profile name={s}", .{profile_name});
    }
    for (options.tags) |tag| {
        try world.record("run.tag value={s}", .{tag});
    }
    for (options.attributes) |attribute| {
        switch (attribute.value) {
            .string => |value| try world.record(
                "run.attribute key={s} value=string:{s}",
                .{ attribute.key, value },
            ),
            .int => |value| try world.record(
                "run.attribute key={s} value=int:{}",
                .{ attribute.key, value },
            ),
            .uint => |value| try world.record(
                "run.attribute key={s} value=uint:{}",
                .{ attribute.key, value },
            ),
            .boolean => |value| try world.record(
                "run.attribute key={s} value=bool:{}",
                .{ attribute.key, value },
            ),
            .float => |value| try world.record(
                "run.attribute key={s} value=float:{d}",
                .{ attribute.key, value },
            ),
        }
    }
}

fn failureFromWorld(
    allocator: std.mem.Allocator,
    options: RunOptions,
    kind: RunFailureKind,
    world: *World,
    err: anyerror,
    check_name: ?[]const u8,
) std.mem.Allocator.Error!RunFailure {
    return .{
        .allocator = allocator,
        .options = options,
        .kind = kind,
        .first_trace = try allocator.dupe(u8, world.traceBytes()),
        .first_event_count = world.nextEventIndex(),
        .error_name = @errorName(err),
        .check_name = check_name,
    };
}

fn deterministicScenario(world: *World) !void {
    try world.tick();
    _ = try world.randomIntLessThan(u64, 100);
    try world.record("scenario.done", .{});
}

test "run: deterministic scenario passes with one owned trace" {
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, deterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expectEqual(@as(u64, 4), passed.event_count);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "scenario.done") != null);
        },
        .failed => return error.UnexpectedRunFailure,
    }
}

var leak_counter: u64 = 0;

fn nondeterministicScenario(world: *World) !void {
    leak_counter += 1;
    try world.record("scenario.leak value={}", .{leak_counter});
}

test "run: same-seed trace mismatch is reported" {
    leak_counter = 0;
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, nondeterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.determinism_mismatch, failure.kind);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "value=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.second_trace, "value=2") != null);
        },
    }
}

const ScenarioError = error{Boom};

fn failingScenario(world: *World) !void {
    try world.record("scenario.before_error", .{});
    return ScenarioError.Boom;
}

test "run: scenario errors preserve partial trace" {
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, failingScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.scenario_error, failure.kind);
            try std.testing.expectEqualStrings("Boom", failure.error_name.?);
            try std.testing.expectEqual(@as(u64, 2), failure.first_event_count);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scenario.before_error") != null);
        },
    }
}

test "run: attributes and tags are traced before scenario code" {
    const tags = [_][]const u8{ "example:replicated_register", "scenario:smoke" };
    const attributes = [_]RunAttribute{
        .{ .key = "replicas", .value = .{ .uint = 3 } },
        .{ .key = "proposal_drop_percent", .value = .{ .uint = 20 } },
        .{ .key = "faults_enabled", .value = .{ .boolean = true } },
    };

    var report = try run(std.testing.allocator, .{
        .seed = 1234,
        .profile_name = "smoke",
        .tags = &tags,
        .attributes = &attributes,
    }, deterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expectEqual(@as(u64, 10), passed.event_count);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "run.profile name=smoke") != null);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "run.tag value=example:replicated_register") != null);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "run.attribute key=replicas value=uint:3") != null);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "run.attribute key=proposal_drop_percent value=uint:20") != null);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "run.attribute key=faults_enabled value=bool:true") != null);
        },
        .failed => return error.UnexpectedRunFailure,
    }
}

test "RunFailure: writeSummary includes replay attributes and tags" {
    const tags = [_][]const u8{ "example:replicated_register", "scenario:smoke" };
    const attributes = [_]RunAttribute{
        .{ .key = "replicas", .value = .{ .uint = 3 } },
        .{ .key = "proposal_drop_percent", .value = .{ .uint = 20 } },
    };

    var report = try run(std.testing.allocator, .{
        .seed = 1234,
        .profile_name = "smoke",
        .tags = &tags,
        .attributes = &attributes,
    }, failingScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            var buffer: [512]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try failure.writeSummary(&writer);
            const summary = writer.buffered();

            try std.testing.expectEqualStrings(
                "marionette failure: kind=scenario_error seed=1234 profile=smoke start_ns=0 tick_ns=1 first_events=7 second_events=0 tag=example:replicated_register tag=scenario:smoke replicas=uint:3 proposal_drop_percent=uint:20 error=Boom\n",
                summary,
            );
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "run.profile name=smoke") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scenario.before_error") != null);
        },
    }
}

fn passingCheck(world: *World) !void {
    try world.record("check.pass", .{});
}

test "run: checks run after the scenario" {
    const checks = [_]Check{.{ .name = "passes", .check = passingCheck }};

    var report = try run(std.testing.allocator, .{
        .seed = 1234,
        .checks = &checks,
    }, deterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expectEqual(@as(u64, 5), passed.event_count);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "scenario.done") != null);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "check.pass") != null);
        },
        .failed => return error.UnexpectedRunFailure,
    }
}

const CheckError = error{InvariantBroken};

fn failingCheck(world: *World) !void {
    try world.record("check.fail", .{});
    return CheckError.InvariantBroken;
}

test "run: check failures preserve partial trace and check name" {
    const checks = [_]Check{.{ .name = "always_fails", .check = failingCheck }};

    var report = try run(std.testing.allocator, .{
        .seed = 1234,
        .checks = &checks,
    }, deterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.check_failed, failure.kind);
            try std.testing.expectEqualStrings("InvariantBroken", failure.error_name.?);
            try std.testing.expectEqualStrings("always_fails", failure.check_name.?);
            try std.testing.expectEqual(@as(u64, 5), failure.first_event_count);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scenario.done") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "check.fail") != null);
        },
    }
}

const CounterState = struct {
    value: u8 = 0,

    fn init() CounterState {
        return .{};
    }
};

fn counterScenario(world: *World, state: *CounterState) !void {
    state.value += 1;
    try world.record("state.value value={}", .{state.value});
}

fn counterCheck(world: *World, state: *const CounterState) !void {
    if (state.value != 1) return error.BadCounter;
    try world.record("state.check value={}", .{state.value});
}

test "runWithState: checks inspect fresh scenario state" {
    const state_checks = [_]StateCheck(CounterState){
        .{ .name = "counter is one", .check = counterCheck },
    };

    var report = try runWithState(
        std.testing.allocator,
        .{ .seed = 1234 },
        CounterState,
        CounterState.init,
        counterScenario,
        &state_checks,
    );
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expectEqual(@as(u64, 3), passed.event_count);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "state.value value=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "state.check value=1") != null);
        },
        .failed => return error.UnexpectedRunFailure,
    }
}

fn failingCounterCheck(world: *World, state: *const CounterState) !void {
    try world.record("state.check.fail value={}", .{state.value});
    return error.StateInvariantBroken;
}

test "runWithState: check failures preserve partial trace and check name" {
    const state_checks = [_]StateCheck(CounterState){
        .{ .name = "counter fails", .check = failingCounterCheck },
    };

    var report = try runWithState(
        std.testing.allocator,
        .{ .seed = 1234 },
        CounterState,
        CounterState.init,
        counterScenario,
        &state_checks,
    );
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.check_failed, failure.kind);
            try std.testing.expectEqualStrings("StateInvariantBroken", failure.error_name.?);
            try std.testing.expectEqualStrings("counter fails", failure.check_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "state.value value=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "state.check.fail value=1") != null);
        },
    }
}
