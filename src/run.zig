//! Scenario runner with built-in deterministic replay verification.

const std = @import("std");

const run_types = @import("run_types.zig");
const world_module = @import("world.zig");
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
pub const TraceError = world_module.TraceError;

pub const RunError = std.mem.Allocator.Error || TraceError;

const cloneRunOptions = run_types.cloneRunOptions;
const deinitRunOptions = run_types.deinitRunOptions;
const traceField = world_module.traceField;

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
) RunError!RunReport {
    const no_state_checks = [_]StateCheck(NoState){};
    return runTwiceWithStateLifecycle(
        allocator,
        options,
        NoState,
        infallibleStateInit(NoState, initNoState),
        noopStateDeinit(NoState),
        scenarioWithoutState(scenario),
        &no_state_checks,
    );
}

/// Run a stateful scenario twice with fresh state and compare traces.
///
/// `init_state` is called once per replay attempt. Stateful scenarios receive
/// only `*State`; store any environment authorities needed by the scenario in
/// the state initializer.
pub fn runWithState(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime State: type,
    comptime init_state: fn (*World) State,
    comptime scenario: fn (*State) anyerror!void,
    comptime state_checks: []const StateCheck(State),
) RunError!RunReport {
    return runTwiceWithStateLifecycle(
        allocator,
        options,
        State,
        infallibleStateInit(State, init_state),
        noopStateDeinit(State),
        scenario,
        state_checks,
    );
}

/// Run a stateful scenario with fallible initialization and world-owned teardown.
///
/// Use this when state initialization can fail, but any simulator resources it
/// creates are owned by `World` through `world.simulate`.
pub fn runWithStateInit(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime State: type,
    comptime init_state: fn (*World) anyerror!State,
    comptime scenario: fn (*State) anyerror!void,
    comptime state_checks: []const StateCheck(State),
) RunError!RunReport {
    return runTwiceWithStateLifecycle(
        allocator,
        options,
        State,
        init_state,
        noopStateDeinit(State),
        scenario,
        state_checks,
    );
}

/// Run a stateful scenario with fallible initialization and explicit teardown.
///
/// `init_state` and `deinit_state` are called once per replay attempt. Init,
/// scenario, and check errors are returned as `RunReport.failed` with the
/// partial trace preserved. Teardown must be infallible.
pub fn runWithStateLifecycle(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime State: type,
    comptime init_state: fn (*World) anyerror!State,
    comptime deinit_state: fn (*State) void,
    comptime scenario: fn (*State) anyerror!void,
    comptime state_checks: []const StateCheck(State),
) RunError!RunReport {
    return runTwiceWithStateLifecycle(
        allocator,
        options,
        State,
        init_state,
        deinit_state,
        scenario,
        state_checks,
    );
}

const NoState = struct {
    world: *World,
};

fn initNoState(world: *World) NoState {
    return .{ .world = world };
}

fn scenarioWithoutState(
    comptime scenario: fn (*World) anyerror!void,
) fn (*NoState) anyerror!void {
    return struct {
        fn runScenario(state: *NoState) anyerror!void {
            try scenario(state.world);
        }
    }.runScenario;
}

fn infallibleStateInit(
    comptime State: type,
    comptime init_state: fn (*World) State,
) fn (*World) anyerror!State {
    return struct {
        fn init(world: *World) anyerror!State {
            return init_state(world);
        }
    }.init;
}

fn noopStateDeinit(comptime State: type) fn (*State) void {
    return struct {
        fn deinit(_: *State) void {}
    }.deinit;
}

fn runTwiceWithStateLifecycle(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime State: type,
    comptime init_state: fn (*World) anyerror!State,
    comptime deinit_state: fn (*State) void,
    comptime scenario: fn (*State) anyerror!void,
    comptime state_checks: []const StateCheck(State),
) RunError!RunReport {
    var first = try runOnceWithStateLifecycle(allocator, options, State, init_state, deinit_state, scenario, state_checks);
    switch (first) {
        .failed => |failure| return .{ .failed = failure },
        .passed => {},
    }
    errdefer first.deinit();

    var second = try runOnceWithStateLifecycle(allocator, options, State, init_state, deinit_state, scenario, state_checks);
    switch (second) {
        .failed => |failure| {
            const passed = first.passed;
            var failure_options = failure.options;
            if (failure.owns_options) deinitRunOptions(allocator, &failure_options);
            return .{ .failed = .{
                .allocator = allocator,
                .options = passed.options,
                .owns_options = passed.owns_options,
                .first_trace = passed.trace,
                .second_trace = failure.first_trace,
                .first_event_count = passed.event_count,
                .second_event_count = failure.first_event_count,
                .kind = failure.kind,
                .error_name = failure.error_name,
                .check_name = failure.check_name,
                .owns_check_name = failure.owns_check_name,
            } };
        },
        .passed => {},
    }
    errdefer second.deinit();

    const first_passed = first.passed;
    var second_passed = second.passed;
    if (!std.mem.eql(u8, first_passed.trace, second_passed.trace)) {
        if (second_passed.owns_options) deinitRunOptions(allocator, &second_passed.options);
        return .{ .failed = .{
            .allocator = allocator,
            .options = first_passed.options,
            .owns_options = first_passed.owns_options,
            .kind = .determinism_mismatch,
            .first_trace = first_passed.trace,
            .second_trace = second_passed.trace,
            .first_event_count = first_passed.event_count,
            .second_event_count = second_passed.event_count,
        } };
    }

    second_passed.deinit();
    return .{ .passed = first_passed };
}

fn runOnceWithStateLifecycle(
    allocator: std.mem.Allocator,
    options: RunOptions,
    comptime State: type,
    comptime init_state: fn (*World) anyerror!State,
    comptime deinit_state: fn (*State) void,
    comptime scenario: fn (*State) anyerror!void,
    comptime state_checks: []const StateCheck(State),
) RunError!RunOnceResult {
    var world = try World.init(allocator, options.worldOptions());
    defer world.deinit();
    try recordRunContext(&world, options);

    var state = init_state(&world) catch |err| {
        return .{ .failed = try failureFromWorld(
            allocator,
            options,
            .scenario_error,
            &world,
            err,
            null,
        ) };
    };
    defer deinit_state(&state);

    scenario(&state) catch |err| {
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
        check.check(&state) catch |err| {
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

    const trace = try allocator.dupe(u8, world.traceBytes());
    errdefer allocator.free(trace);
    const owned_options = try cloneRunOptions(allocator, options);

    return .{ .passed = .{
        .allocator = allocator,
        .options = owned_options,
        .owns_options = true,
        .trace = trace,
        .event_count = world.nextEventIndex(),
    } };
}

fn recordRunContext(world: *World, options: RunOptions) RunError!void {
    if (options.profile_name) |profile_name| {
        try world.recordFields("run.profile", &.{
            traceField("name", .{ .text = profile_name }),
        });
    }
    for (options.tags) |tag| {
        try world.recordFields("run.tag", &.{
            traceField("value", .{ .text = tag }),
        });
    }
    for (options.attributes) |attribute| {
        switch (attribute.value) {
            .string => |value| try world.recordFields("run.attribute", &.{
                traceField("key", .{ .text = attribute.key }),
                traceField("value", .{ .typed_text = .{ .type_name = "string", .value = value } }),
            }),
            .int => |value| {
                var buffer: [64]u8 = undefined;
                const literal = std.fmt.bufPrint(&buffer, "int:{}", .{value}) catch unreachable;
                try world.recordFields("run.attribute", &.{
                    traceField("key", .{ .text = attribute.key }),
                    traceField("value", .{ .literal = literal }),
                });
            },
            .uint => |value| {
                var buffer: [64]u8 = undefined;
                const literal = std.fmt.bufPrint(&buffer, "uint:{}", .{value}) catch unreachable;
                try world.recordFields("run.attribute", &.{
                    traceField("key", .{ .text = attribute.key }),
                    traceField("value", .{ .literal = literal }),
                });
            },
            .boolean => |value| {
                var buffer: [64]u8 = undefined;
                const literal = std.fmt.bufPrint(&buffer, "bool:{}", .{value}) catch unreachable;
                try world.recordFields("run.attribute", &.{
                    traceField("key", .{ .text = attribute.key }),
                    traceField("value", .{ .literal = literal }),
                });
            },
            .float => |value| {
                var buffer: [128]u8 = undefined;
                const literal = std.fmt.bufPrint(&buffer, "float:{d}", .{value}) catch unreachable;
                try world.recordFields("run.attribute", &.{
                    traceField("key", .{ .text = attribute.key }),
                    traceField("value", .{ .literal = literal }),
                });
            },
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
    const trace = try allocator.dupe(u8, world.traceBytes());
    errdefer allocator.free(trace);

    var owned_options = try cloneRunOptions(allocator, options);
    errdefer deinitRunOptions(allocator, &owned_options);

    const owned_check_name = if (check_name) |name| try allocator.dupe(u8, name) else null;
    errdefer if (owned_check_name) |name| allocator.free(name);

    return .{
        .allocator = allocator,
        .options = owned_options,
        .owns_options = true,
        .kind = kind,
        .first_trace = trace,
        .first_event_count = world.nextEventIndex(),
        .error_name = @errorName(err),
        .check_name = owned_check_name,
        .owns_check_name = owned_check_name != null,
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

test "run: replay metadata text is escaped before scenario code" {
    const tags = [_][]const u8{"invalid tag"};

    var report = try run(std.testing.allocator, .{
        .seed = 1234,
        .tags = &tags,
    }, deterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "run.tag value=invalid%20tag") != null);
        },
        .failed => return error.UnexpectedRunFailure,
    }
}

fn invalidTraceScenario(world: *World) !void {
    try world.record("scenario.message value={s}", .{"hello world"});
}

test "run: invalid scenario trace is reported as scenario failure" {
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, invalidTraceScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.scenario_error, failure.kind);
            try std.testing.expectEqualStrings("InvalidTracePayload", failure.error_name.?);
            try std.testing.expectEqual(@as(u64, 1), failure.first_event_count);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "hello world") == null);
        },
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

test "RunFailure: owns replay metadata used by summaries" {
    var profile_buf = [_]u8{ 's', 'm', 'o', 'k', 'e' };
    var tag_buf = [_]u8{ 't', 'a', 'g', '_', 'a' };
    var key_buf = [_]u8{ 'm', 'o', 'd', 'e' };
    var value_buf = [_]u8{ 'f', 'a', 's', 't' };
    var check_name_buf = [_]u8{ 'f', 'a', 'i', 'l', 's' };

    const attributes = [_]RunAttribute{
        .{
            .key = key_buf[0..],
            .value = .{ .string = value_buf[0..] },
        },
    };
    const tags = [_][]const u8{tag_buf[0..]};
    const checks = [_]Check{.{ .name = check_name_buf[0..], .check = failingCheck }};

    var report = try run(std.testing.allocator, .{
        .seed = 1234,
        .profile_name = profile_buf[0..],
        .tags = &tags,
        .attributes = &attributes,
        .checks = &checks,
    }, deterministicScenario);
    defer report.deinit();

    @memcpy(profile_buf[0..], "other");
    @memcpy(tag_buf[0..], "tag_b");
    @memcpy(key_buf[0..], "xxxx");
    @memcpy(value_buf[0..], "slow");
    @memcpy(check_name_buf[0..], "nope!");

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            var buffer: [512]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try failure.writeSummary(&writer);
            const summary = writer.buffered();

            try std.testing.expect(std.mem.indexOf(u8, summary, "profile=smoke") != null);
            try std.testing.expect(std.mem.indexOf(u8, summary, "tag=tag_a") != null);
            try std.testing.expect(std.mem.indexOf(u8, summary, "mode=string:fast") != null);
            try std.testing.expect(std.mem.indexOf(u8, summary, "check=fails") != null);
        },
    }
}

test "RunFailure: summary escapes replay metadata text" {
    const tags = [_][]const u8{"tag with space"};
    const attributes = [_]RunAttribute{
        .{ .key = "mode name", .value = .{ .string = "fast mode" } },
    };
    const checks = [_]Check{.{ .name = "check name", .check = failingCheck }};

    var report = try run(std.testing.allocator, .{
        .seed = 1234,
        .profile_name = "smoke test",
        .tags = &tags,
        .attributes = &attributes,
        .checks = &checks,
    }, deterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            var buffer: [512]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try failure.writeSummary(&writer);
            const summary = writer.buffered();

            try std.testing.expect(std.mem.indexOf(u8, summary, "profile=smoke%20test") != null);
            try std.testing.expect(std.mem.indexOf(u8, summary, "tag=tag%20with%20space") != null);
            try std.testing.expect(std.mem.indexOf(u8, summary, "mode%20name=string:fast%20mode") != null);
            try std.testing.expect(std.mem.indexOf(u8, summary, "check=check%20name") != null);
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
    env: @import("env.zig").AppEnv,
    value: u8 = 0,

    fn init(world: *World) CounterState {
        const sim = world.simulate(.{}) catch unreachable;
        return .{ .env = sim.env };
    }
};

fn counterScenario(state: *CounterState) !void {
    state.value += 1;
    try state.env.record("state.value value={}", .{state.value});
}

fn counterCheck(state: *const CounterState) !void {
    if (state.value != 1) return error.BadCounter;
    try state.env.record("state.check value={}", .{state.value});
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

fn failingCounterCheck(state: *const CounterState) !void {
    try state.env.record("state.check.fail value={}", .{state.value});
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

var lifecycle_deinit_count: u8 = 0;

const LifecycleState = struct {
    env: @import("env.zig").AppEnv,
    value: u8 = 0,

    fn init(world: *World) !LifecycleState {
        const sim = try world.simulate(.{});
        return .{ .env = sim.env };
    }

    fn deinit(_: *LifecycleState) void {
        lifecycle_deinit_count += 1;
    }
};

fn lifecycleScenario(state: *LifecycleState) !void {
    state.value += 1;
    try state.env.record("lifecycle.value value={}", .{state.value});
}

fn lifecycleCheck(state: *const LifecycleState) !void {
    if (state.value != 1) return error.BadLifecycleState;
    try state.env.record("lifecycle.check value={}", .{state.value});
}

test "runWithStateLifecycle: deinitializes each replay attempt" {
    lifecycle_deinit_count = 0;
    const state_checks = [_]StateCheck(LifecycleState){
        .{ .name = "lifecycle is one", .check = lifecycleCheck },
    };

    var report = try runWithStateLifecycle(
        std.testing.allocator,
        .{ .seed = 1234 },
        LifecycleState,
        LifecycleState.init,
        LifecycleState.deinit,
        lifecycleScenario,
        &state_checks,
    );
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expectEqual(@as(u8, 2), lifecycle_deinit_count);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "lifecycle.value value=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "lifecycle.check value=1") != null);
        },
        .failed => return error.UnexpectedRunFailure,
    }
}

const FallibleInitState = struct {
    fn init(_: *World) !FallibleInitState {
        return error.InitFailed;
    }

    fn deinit(_: *FallibleInitState) void {
        lifecycle_deinit_count += 1;
    }
};

fn unreachableLifecycleScenario(_: *FallibleInitState) !void {
    return error.UnreachableScenario;
}

test "runWithStateLifecycle: init errors become scenario failures" {
    lifecycle_deinit_count = 0;
    const state_checks = [_]StateCheck(FallibleInitState){};

    var report = try runWithStateLifecycle(
        std.testing.allocator,
        .{ .seed = 1234 },
        FallibleInitState,
        FallibleInitState.init,
        FallibleInitState.deinit,
        unreachableLifecycleScenario,
        &state_checks,
    );
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.scenario_error, failure.kind);
            try std.testing.expectEqualStrings("InitFailed", failure.error_name.?);
            try std.testing.expectEqual(@as(u8, 0), lifecycle_deinit_count);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "world.init") != null);
        },
    }
}
