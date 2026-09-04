//! Scenario runner with built-in deterministic replay verification.

const std = @import("std");
const builtin = @import("builtin");

const decision_module = @import("decision.zig");
const env_module = @import("env.zig");
const run_types = @import("run_types.zig");
const seed_module = @import("seed.zig");
const world_module = @import("world.zig");
const World = @import("world.zig").World;

pub const RunAttribute = run_types.RunAttribute;
pub const RunAttributeValue = run_types.RunAttributeValue;
pub const FailureExpectation = run_types.FailureExpectation;
pub const RunFailure = run_types.RunFailure;
pub const RunFailureKind = run_types.RunFailureKind;
pub const RunOptions = run_types.RunOptions;
pub const RunReport = run_types.RunReport;
pub const RunResult = run_types.RunResult;
pub const WatchdogOptions = run_types.WatchdogOptions;
pub const StateCheck = run_types.StateCheck;
pub const runAttribute = run_types.runAttribute;
pub const TraceError = world_module.TraceError;

/// Infrastructure errors from the runners themselves; scenario failures
/// are reported through `RunReport`, not as errors.
pub const RunError = std.mem.Allocator.Error || TraceError || error{
    InvalidSeedSchedule,
    InvalidWatchdogOptions,
    WatchdogUnavailable,
    WatchdogTraceTooLarge,
};
/// Errors specific to the `expect*` wrappers: outcome mismatches and invalid
/// expectation configuration.
pub const ExpectError = error{
    ExpectedRunFailure,
    ExpectedRunPass,
    UnexpectedRunFailure,
    InvalidSeedCount,
};
pub const ExpectRunError = RunError || ExpectError;

const cloneRunOptions = run_types.cloneRunOptions;
const deinitRunOptions = run_types.deinitRunOptions;
const traceField = world_module.traceField;

const execution = @import("execution.zig");
const RunOnceResult = execution.Result;
const watchdog_module = @import("watchdog.zig");
const watchdog_supported = watchdog_module.supported;

/// Standard simulation scenario state: the world-owned simulator handles plus
/// user application state initialized from `mar.Sim`.
pub fn SimCase(comptime App: type) type {
    return struct {
        const Self = @This();

        sim: World.Simulation,
        app: App,

        /// The node-0 app-facing environment.
        pub fn env(self: *const Self) env_module.Env {
            return self.sim.env;
        }

        /// The harness-facing simulator controls.
        pub fn control(self: *const Self) env_module.SimControl {
            return self.sim.control;
        }

        /// Deinitialize the app state if it defines `deinit`; the
        /// runner tears down world-owned simulator state itself.
        pub fn deinit(self: *Self) void {
            if (comptime appHasDeinit(App)) {
                self.app.deinit();
            }
            self.* = undefined;
        }
    };
}

/// Run one simulation case.
///
/// Required fields:
/// - `allocator`
/// - `simulate: mar.World.SimulateOptions`
/// - `init: fn (mar.Sim) App` or `fn (mar.Sim) !App`
/// - `scenario: fn (*mar.SimCase(App)) !void`
///
/// Optional fields are `seed`, `seed_schedule`, `start_ns`, `tick_ns`,
/// `name`, `tags`, `attributes`, `checks`, `watchdog`, and `check_resources`.
pub fn runSimCase(config: anytype) RunError!RunReport {
    return runSimCaseWithSeed(config, null);
}

/// Execute a saved capsule against the exact harness build/input identity.
/// Config supplies allocator, init, scenario, and optional compile-time checks.
/// Runtime options and simulation configuration come exclusively from the capsule.
pub fn replaySimCase(config: anytype, capsule: *const @import("replay.zig").Capsule, identity: @import("replay.zig").Identity) !RunReport {
    try capsule.validateIdentity(identity);
    const App = appTypeFromSimInit(config.init);
    const Case = SimCase(App);
    validateSimScenario(Case, config.scenario);
    const no_checks = [_]StateCheck(Case){};
    const checks = if (@hasField(@TypeOf(config), "checks")) config.checks else &no_checks;
    var expected = try capsule.executionResult(config.allocator);
    errdefer expected.deinit();
    const options = capsule.options();
    const actual = try runOnceDispatched(config.allocator, options, capsule.simulateOptions(), App, fallibleSimInit(App, config.init), fallibleSimScenario(Case, config.scenario), checks, .{ .replay = expected.decision_tape.entries });
    const result = compareRunOnceResults(config.allocator, options, capsule.simulateOptions(), expected, actual);
    expected = .{ .allocator = config.allocator, .trace = &.{}, .event_count = 0 };
    return result;
}

/// Expect a simulation case to pass. Prints the failure summary otherwise.
pub fn expectSimPass(config: anytype) ExpectRunError!void {
    var report = try runSimCase(config);
    defer report.deinit();

    switch (report) {
        .passed => {},
        .failed => |failure| {
            failure.print();
            return error.ExpectedRunPass;
        },
    }
}

/// Expect a simulation case to fail. An optional `failure` field constrains
/// the accepted kind, error name, and/or check name. Use `runSimCase` directly
/// when the test needs to inspect the full failure details.
pub fn expectSimFailure(config: anytype) ExpectRunError!void {
    var report = try runSimCase(config);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            const expectation: FailureExpectation = if (@hasField(@TypeOf(config), "failure")) config.failure else .{};
            if (!expectation.matches(failure)) {
                failure.print();
                return error.UnexpectedRunFailure;
            }
        },
    }
}

/// Run a simulation case over many deterministic seeds.
///
/// Required extra field: `seeds`, which must be greater than zero. Optional
/// `seed` acts as the base seed.
pub fn expectSimFuzz(config: anytype) ExpectRunError!void {
    if (!@hasField(@TypeOf(config), "seeds")) {
        @compileError("expectSimFuzz config requires a `seeds` field");
    }
    if (config.seeds == 0) return error.InvalidSeedCount;

    for (0..config.seeds) |iteration| {
        const seed = fuzzSeed(configSeed(config), iteration);
        var report = try runSimCaseWithSeed(config, seed);
        defer report.deinit();

        switch (report) {
            .passed => {},
            .failed => |failure| {
                std.debug.print("marionette sim fuzz failure: seed={} iteration={}\n", .{ seed, iteration });
                failure.print();
                return error.ExpectedRunPass;
            },
        }
    }
}

/// Expect `trace` to contain `needle`; on failure, print the needle and the
/// tail of the trace so the mismatch is diagnosable from test output.
pub fn expectTraceContains(trace: []const u8, needle: []const u8) error{TraceNeedleMissing}!void {
    if (std.mem.indexOf(u8, trace, needle) != null) return;
    const tail_len = @min(trace.len, 4096);
    std.debug.print(
        "trace does not contain \"{s}\"; trace tail ({} of {} bytes):\n{s}\n",
        .{ needle, tail_len, trace.len, trace[trace.len - tail_len ..] },
    );
    return error.TraceNeedleMissing;
}

fn runSimCaseWithSeed(config: anytype, seed_override: ?u64) RunError!RunReport {
    if (!@hasField(@TypeOf(config), "simulate")) {
        @compileError("runSimCase config requires a `simulate` field");
    }

    const App = appTypeFromSimInit(config.init);
    const Case = SimCase(App);
    validateSimScenario(Case, config.scenario);

    const no_case_checks = [_]StateCheck(Case){};
    const case_checks = if (@hasField(@TypeOf(config), "checks")) config.checks else &no_case_checks;

    var options = try runOptionsFromConfig(config, seed_override);
    defer deinitRunOptions(config.allocator, &options);
    return runTwiceWithSimCase(
        config.allocator,
        options,
        config.simulate,
        App,
        fallibleSimInit(App, config.init),
        fallibleSimScenario(Case, config.scenario),
        case_checks,
    );
}

fn runOptionsFromConfig(config: anytype, seed_override: ?u64) std.mem.Allocator.Error!RunOptions {
    const schedule = if (@hasField(@TypeOf(config), "seed_schedule"))
        try normalizeSchedule(config.allocator, config.seed_schedule)
    else
        try config.allocator.alloc(seed_module.SeedCutover, 0);
    defer config.allocator.free(schedule);
    // Coerce collection literals here and clone while their backing storage is live.
    const borrowed: RunOptions = .{
        .seed = seed_override orelse configSeed(config),
        .seed_schedule = schedule,
        .start_ns = fieldOrDefault(config, "start_ns", @as(u64, 0)),
        .tick_ns = fieldOrDefault(config, "tick_ns", @import("clock.zig").default_tick_ns),
        .name = if (@hasField(@TypeOf(config), "name")) config.name else null,
        .tags = if (@hasField(@TypeOf(config), "tags")) config.tags else &.{},
        .attributes = if (@hasField(@TypeOf(config), "attributes")) config.attributes else &.{},
        .watchdog = fieldOrDefault(config, "watchdog", @as(?WatchdogOptions, null)),
        .check_resources = fieldOrDefault(config, "check_resources", false),
    };
    return cloneRunOptions(config.allocator, borrowed);
}

fn normalizeSchedule(allocator: std.mem.Allocator, input: anytype) ![]seed_module.SeedCutover {
    const result = try allocator.alloc(seed_module.SeedCutover, input.len);
    const pointer = @typeInfo(@TypeOf(input)).pointer;
    const tuple = pointer.size == .one and @typeInfo(pointer.child) == .@"struct";
    if (comptime tuple) {
        inline for (input.*, 0..) |cutover, index| result[index] = coerceCutover(cutover);
    } else {
        for (input, 0..) |cutover, index| result[index] = coerceCutover(cutover);
    }
    return result;
}

fn coerceCutover(value: anytype) seed_module.SeedCutover {
    return .{ .seed = value.seed, .at = .{
        .sim_time_ns = value.at.sim_time_ns,
        .microstep = if (@hasField(@TypeOf(value.at), "microstep")) value.at.microstep else 0,
    } };
}

fn configSeed(config: anytype) u64 {
    return fieldOrDefault(config, "seed", @as(u64, 0));
}

fn fieldOrDefault(config: anytype, comptime name: []const u8, default: anytype) @TypeOf(default) {
    return if (@hasField(@TypeOf(config), name)) @field(config, name) else default;
}

/// Derive the seed for one fuzz iteration.
///
/// A keyed two-dimensional derivation, not plain XOR or addition: XOR with
/// the iteration makes bases differing only in their low log2(seed_count)
/// bits cover identical seed sets, and `splitmix64(base + iteration)` makes
/// adjacent bases overlap by all but one seed. Hashing the iteration before
/// mixing makes cross-base collisions birthday-bound instead of structural.
fn fuzzSeed(base_seed: u64, iteration: usize) u64 {
    return splitmix64(base_seed ^ splitmix64(@intCast(iteration)));
}

fn splitmix64(input: u64) u64 {
    var z = input +% 0x9E37_79B9_7F4A_7C15;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

fn appTypeFromSimInit(comptime init_app: anytype) type {
    const Return = simInitReturnType(init_app);
    return switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload,
        else => Return,
    };
}

fn simInitReturnType(comptime init_app: anytype) type {
    const Init = @TypeOf(init_app);
    const info = switch (@typeInfo(Init)) {
        .@"fn" => |fn_info| fn_info,
        else => @compileError("runSimCase config.init must be a function"),
    };
    if (info.params.len != 1 or info.params[0].type != World.Simulation) {
        @compileError("runSimCase config.init must take `mar.Sim`");
    }
    return info.return_type orelse @compileError("runSimCase config.init must return app state");
}

fn validateSimScenario(comptime Case: type, comptime scenario: anytype) void {
    const info = switch (@typeInfo(@TypeOf(scenario))) {
        .@"fn" => |fn_info| fn_info,
        else => @compileError("runSimCase config.scenario must be a function"),
    };
    if (info.params.len != 1 or info.params[0].type != *Case) {
        @compileError("runSimCase config.scenario must take `*mar.SimCase(App)`");
    }
    const Return = info.return_type orelse @compileError("runSimCase config.scenario must return void or !void");
    switch (@typeInfo(Return)) {
        .error_union => |error_union| if (error_union.payload != void) {
            @compileError("runSimCase config.scenario must return void or !void");
        },
        else => if (Return != void) {
            @compileError("runSimCase config.scenario must return void or !void");
        },
    }
}

fn fallibleSimScenario(comptime Case: type, comptime scenario: anytype) fn (*Case) anyerror!void {
    const Return = @typeInfo(@TypeOf(scenario)).@"fn".return_type.?;
    return switch (@typeInfo(Return)) {
        .error_union => struct {
            fn run(case: *Case) anyerror!void {
                try scenario(case);
            }
        }.run,
        else => struct {
            fn run(case: *Case) anyerror!void {
                scenario(case);
            }
        }.run,
    };
}

fn fallibleSimInit(comptime App: type, comptime init_app: anytype) fn (World.Simulation) anyerror!App {
    const Return = simInitReturnType(init_app);
    return switch (@typeInfo(Return)) {
        .error_union => struct {
            fn init(sim: World.Simulation) anyerror!App {
                return try init_app(sim);
            }
        }.init,
        else => struct {
            fn init(sim: World.Simulation) anyerror!App {
                return init_app(sim);
            }
        }.init,
    };
}

fn appHasDeinit(comptime App: type) bool {
    return switch (@typeInfo(App)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(App, "deinit"),
        .pointer => |pointer| pointer.size == .one and appHasDeinit(pointer.child),
        else => false,
    };
}

fn runTwiceWithSimCase(
    allocator: std.mem.Allocator,
    options: RunOptions,
    simulate_options: World.SimulateOptions,
    comptime App: type,
    comptime init_app: fn (World.Simulation) anyerror!App,
    comptime scenario: fn (*SimCase(App)) anyerror!void,
    comptime state_checks: []const StateCheck(SimCase(App)),
) RunError!RunReport {
    // Validate runner configuration before optional watchdog isolation. Runner
    // errors discovered only in the worker must cross a deliberately narrow
    // shared-memory result channel, so configuration errors belong here.
    try seed_module.validateSeedSchedule(options.seed_schedule);

    // Always execute both runs, even when the first fails: a failure that
    // does not reproduce with the same seed is itself a determinism leak,
    // and a failure that does reproduce is verified replayable.
    var first = try runOnceDispatched(
        allocator,
        options,
        simulate_options,
        App,
        init_app,
        scenario,
        state_checks,
        .record,
    );
    errdefer first.deinit();

    // A watchdog worker may be killed before it can publish an owned tape.
    // Keep its existing same-seed replay until the capsule transport can
    // mirror partial decisions out of process. Ordinary runs exact-replay the
    // first execution's semantic decisions.
    const second_mode: decision_module.Mode = if (first.tape_complete)
        .{ .replay = first.decisionEntries() }
    else
        .record;
    const second = runOnceDispatched(
        allocator,
        options,
        simulate_options,
        App,
        init_app,
        scenario,
        state_checks,
        second_mode,
    ) catch |err| return err;

    // Ownership passes to the comparator, including its error path.
    const result = compareRunOnceResults(allocator, options, simulate_options, first, second);
    first = .{ .allocator = allocator, .trace = &.{}, .event_count = 0 };
    return result;
}

fn runOnceDispatched(
    allocator: std.mem.Allocator,
    options: RunOptions,
    simulate_options: World.SimulateOptions,
    comptime App: type,
    comptime init_app: fn (World.Simulation) anyerror!App,
    comptime scenario: fn (*SimCase(App)) anyerror!void,
    comptime state_checks: []const StateCheck(SimCase(App)),
    decision_mode: decision_module.Mode,
) RunError!RunOnceResult {
    if (options.watchdog) |watchdog| {
        try watchdog.validate();
        const Bridge = struct {
            fn execute(a: std.mem.Allocator, o: RunOptions, so: World.SimulateOptions, observer: ?world_module.ExecutionObserver, mode: decision_module.Mode) RunError!RunOnceResult {
                return runOnceWithSimCase(a, o, so, App, init_app, scenario, state_checks, observer, mode);
            }
        };
        return watchdog_module.run(allocator, options, simulate_options, Bridge.execute, watchdog, decision_mode);
    }
    return runOnceWithSimCase(
        allocator,
        options,
        simulate_options,
        App,
        init_app,
        scenario,
        state_checks,
        null,
        decision_mode,
    );
}

fn compareRunOnceResults(
    allocator: std.mem.Allocator,
    options: RunOptions,
    simulate_options: World.SimulateOptions,
    first_result: RunOnceResult,
    second_result: RunOnceResult,
) RunError!RunReport {
    var first = first_result;
    defer first.deinit();
    var second = second_result;
    defer second.deinit();
    const equal_trace = std.mem.eql(u8, first.trace, second.trace);
    const first_failure: ?execution.Failure = if (first.outcome == .failed) first.outcome.failed else null;
    const second_failure: ?execution.Failure = if (second.outcome == .failed) second.outcome.failed else null;
    const reproduced = if (first_failure) |a| if (second_failure) |b|
        a.kind == b.kind and optionalTextEqual(a.error_name, b.error_name) and optionalTextEqual(a.check_name, b.check_name) and
            (equal_trace or (isWatchdogFailure(a.kind) and watchdogTracePrefixesCompatible(first.trace, second.trace)))
    else
        false else second_failure == null and equal_trace;
    const owned_options = try cloneRunOptions(allocator, options);
    const trace = first.trace;
    first.trace = &.{};
    const tape = first.decision_tape;
    first.decision_tape = .empty();
    if (reproduced and first_failure == null) return .{ .passed = .{
        .allocator = allocator,
        .options = owned_options,
        .simulate_options = simulate_options,
        .owns_options = true,
        .trace = trace,
        .event_count = first.event_count,
        .decision_tape = tape,
        .tape_complete = first.tape_complete,
    } };
    const kind: RunFailureKind = if (second_failure != null and second_failure.?.kind == .replay_diverged) .replay_diverged else if (reproduced) first_failure.?.kind else if (first_failure == null and second_failure != null) .second_run_failed else if (first_failure != null and second_failure == null) .first_run_failed else .determinism_mismatch;
    var report: RunFailure = .{
        .allocator = allocator,
        .options = owned_options,
        .simulate_options = simulate_options,
        .owns_options = true,
        .kind = kind,
        .first_trace = trace,
        .first_event_count = first.event_count,
        .decision_tape = tape,
        .tape_complete = first.tape_complete,
    };
    if (!reproduced) {
        report.second_trace = second.trace;
        second.trace = &.{};
        report.second_event_count = second.event_count;
    }
    const primary = if (first_failure != null) &first else &second;
    if (primary.outcome == .failed) {
        const failure = &primary.outcome.failed;
        report.error_name = failure.error_name;
        report.owns_error_name = failure.error_name != null;
        failure.error_name = null;
        report.check_name = failure.check_name;
        report.owns_check_name = failure.check_name != null;
        failure.check_name = null;
    }
    if (!reproduced and first_failure != null and second_failure != null) {
        const failure = &second.outcome.failed;
        report.second_error_name = failure.error_name;
        report.owns_second_error_name = failure.error_name != null;
        failure.error_name = null;
        report.second_check_name = failure.check_name;
        report.owns_second_check_name = failure.check_name != null;
        failure.check_name = null;
    }
    const diagnostic = if (second_failure != null and second_failure.?.divergence != null) &second else &first;
    if (diagnostic.outcome == .failed) {
        report.replay_divergence = diagnostic.outcome.failed.divergence;
        diagnostic.outcome.failed.divergence = null;
    }
    return .{ .failed = report };
}

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn isWatchdogFailure(kind: RunFailureKind) bool {
    return kind == .non_yielding or kind == .livelock;
}

fn watchdogTracePrefixesCompatible(first: []const u8, second: []const u8) bool {
    const first_prefix = traceBeforeFinalEvent(first);
    const second_prefix = traceBeforeFinalEvent(second);
    const common_len = @min(first_prefix.len, second_prefix.len);
    return std.mem.eql(u8, first_prefix[0..common_len], second_prefix[0..common_len]);
}

fn traceBeforeFinalEvent(trace: []const u8) []const u8 {
    const without_final_newline = if (std.mem.endsWith(u8, trace, "\n"))
        trace[0 .. trace.len - 1]
    else
        trace;
    const final_line_start = std.mem.lastIndexOfScalar(u8, without_final_newline, '\n') orelse return &.{};
    return trace[0 .. final_line_start + 1];
}

fn runOnceWithSimCase(
    allocator: std.mem.Allocator,
    options: RunOptions,
    simulate_options: World.SimulateOptions,
    comptime App: type,
    comptime init_app: fn (World.Simulation) anyerror!App,
    comptime scenario: fn (*SimCase(App)) anyerror!void,
    comptime state_checks: []const StateCheck(SimCase(App)),
    observer: ?world_module.ExecutionObserver,
    decision_mode: decision_module.Mode,
) RunError!RunOnceResult {
    var world_options = options.worldOptions();
    world_options.decisions = decision_mode;
    var world = try World.init(allocator, world_options);
    defer world.deinit();
    if (observer) |execution_observer| world.attachExecutionObserver(execution_observer);
    try recordRunContext(&world, options);

    const sim = world.simulate(simulate_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            return try failureFromWorld(
                allocator,
                options,
                .scenario_error,
                &world,
                err,
                null,
            );
        },
    };

    var state: SimCase(App) = .{
        .sim = sim,
        .app = init_app(sim) catch |err| {
            return try failureFromWorld(
                allocator,
                options,
                .scenario_error,
                &world,
                err,
                null,
            );
        },
    };
    var state_live = true;
    defer if (state_live) state.deinit();

    scenario(&state) catch |err| {
        const scheduler_failure = state.control().tasks.failure();
        state.deinit();
        state_live = false;
        if (scheduler_failure) |failure| {
            return try schedulerFailureFromWorld(
                allocator,
                options,
                &world,
                failure,
            );
        }
        return try failureFromWorld(allocator, options, .scenario_error, &world, err, null);
    };

    if (state.control().tasks.failure()) |failure| {
        state.deinit();
        state_live = false;
        return try schedulerFailureFromWorld(
            allocator,
            options,
            &world,
            failure,
        );
    }

    for (state_checks) |check| {
        check.check(&state) catch |err| {
            const scheduler_failure = state.control().tasks.failure();
            state.deinit();
            state_live = false;
            if (scheduler_failure) |failure| {
                return try schedulerFailureFromWorld(
                    allocator,
                    options,
                    &world,
                    failure,
                );
            }
            return try failureFromWorld(
                allocator,
                options,
                .check_failed,
                &world,
                err,
                check.name,
            );
        };
    }

    state.deinit();
    state_live = false;
    if (options.check_resources) {
        sim.control.checkResources() catch |err| switch (err) {
            error.ResourceLeak => return try failureFromWorld(
                allocator,
                options,
                .resource_leak,
                &world,
                err,
                null,
            ),
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTracePayload => return error.InvalidTracePayload,
            else => unreachable,
        };
    }
    world.finishDecisionReplay() catch |err| {
        return try failureFromWorld(
            allocator,
            options,
            .replay_diverged,
            &world,
            err,
            null,
        );
    };
    return execution.Result.capture(allocator, &world, null);
}

fn schedulerFailureFromWorld(
    allocator: std.mem.Allocator,
    options: RunOptions,
    world: *World,
    failure: @import("io/root.zig").internal.TaskControl.Failure,
) RunError!RunOnceResult {
    return switch (failure) {
        .deadlock => failureFromWorldName(
            allocator,
            options,
            .scheduler_deadlock,
            world,
            "Deadlock",
            null,
        ),
        .scheduler_error => |error_name| failureFromWorldName(
            allocator,
            options,
            .scheduler_error,
            world,
            error_name,
            null,
        ),
    };
}

fn recordRunContext(world: *World, options: RunOptions) RunError!void {
    if (options.check_resources) try world.record("run.resources enabled=true", .{});
    if (options.name) |name| {
        try world.recordFields("run.name", &.{
            traceField("value", .{ .text = name }),
        });
    }
    for (options.tags) |tag| {
        try world.recordFields("run.tag", &.{
            traceField("value", .{ .text = tag }),
        });
    }
    for (options.attributes) |attribute| {
        var line = std.Io.Writer.Allocating.init(world.allocator);
        defer line.deinit();
        attribute.write(&line.writer) catch return error.OutOfMemory;
        try world.recordPayload(line.written());
    }
    if (options.watchdog) |watchdog| {
        try world.recordFields("run.watchdog", &.{
            traceField("stall_timeout_ns", .{ .uint = watchdog.stall_timeout_ns }),
            traceField("run_timeout_ns", .{ .uint = watchdog.run_timeout_ns }),
            traceField("trace_capacity", .{ .uint = @intCast(watchdog.trace_capacity) }),
            traceField("result_capacity", .{ .uint = @intCast(watchdog.result_capacity) }),
        });
    }
}

fn failureFromWorld(
    allocator: std.mem.Allocator,
    options: RunOptions,
    kind: RunFailureKind,
    world: *World,
    err: anyerror,
    check_name: ?[]const u8,
) std.mem.Allocator.Error!RunOnceResult {
    return failureFromWorldName(
        allocator,
        options,
        kind,
        world,
        @errorName(err),
        check_name,
    );
}

fn failureFromWorldName(
    allocator: std.mem.Allocator,
    options: RunOptions,
    kind: RunFailureKind,
    world: *World,
    error_name: ?[]const u8,
    check_name: ?[]const u8,
) std.mem.Allocator.Error!RunOnceResult {
    _ = options;
    // A failing execution must also consume its entire supplied tape.
    world.finishDecisionReplay() catch {};
    const divergence = world.decisionDivergence();
    return execution.Result.capture(allocator, world, .{
        .kind = if (divergence != null) .replay_diverged else kind,
        .error_name = if (divergence != null) "DecisionReplayDiverged" else error_name,
        .check_name = check_name,
        .divergence = divergence,
    });
}

test "resource checks: opt in, cleanup boundary, replay and primary errors" {
    const App = struct {
        io: std.Io,
        file: std.Io.File,
        close: bool = false,

        fn init(sim: World.Simulation) !@This() {
            const io = sim.env.io();
            return .{ .io = io, .file = try std.Io.Dir.cwd().createFile(io, "leaked file", .{}) };
        }
        fn deinit(self: *@This()) void {
            if (self.close) self.file.close(self.io);
        }
        fn leaveOpen(_: *SimCase(@This())) void {}
        fn clean(case: *SimCase(@This())) void {
            case.app.close = true;
        }
        fn fail(_: *SimCase(@This())) !void {
            return error.PrimaryFailure;
        }
    };
    try expectSimPass(.{ .allocator = std.testing.allocator, .simulate = World.SimulateOptions{}, .init = App.init, .scenario = App.leaveOpen });
    try expectSimPass(.{ .allocator = std.testing.allocator, .simulate = World.SimulateOptions{}, .init = App.init, .scenario = App.clean, .check_resources = true });
    try expectSimFailure(.{ .allocator = std.testing.allocator, .simulate = World.SimulateOptions{}, .init = App.init, .scenario = App.fail, .check_resources = true, .failure = FailureExpectation{ .kind = .scenario_error, .error_name = "PrimaryFailure" } });
    inline for (.{ @as(?WatchdogOptions, null), if (watchdog_supported) @as(?WatchdogOptions, .{}) else null }) |watchdog| {
        var report = try runSimCase(.{ .allocator = std.testing.allocator, .simulate = World.SimulateOptions{}, .init = App.init, .scenario = App.leaveOpen, .check_resources = true, .watchdog = watchdog });
        defer report.deinit();
        switch (report) {
            .passed => return error.ExpectedLeak,
            .failed => |failure| {
                try std.testing.expectEqual(RunFailureKind.resource_leak, failure.kind);
                try std.testing.expectEqualStrings("ResourceLeak", failure.error_name.?);
                try std.testing.expect(failure.options.check_resources);
                try expectTraceContains(failure.first_trace, "resource.leak node=0 kind=file handle=1000 path=leaked%20file");
            },
        }
    }
}

test "resource checkpoints: failed diagnostics roll back without closing handles" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var world = try World.init(failing.allocator(), .{ .seed = 1 });
    defer world.deinit();
    const sim = try world.simulate(.{});
    const io = sim.env.io();
    const file = try std.Io.Dir.cwd().createFile(io, "still open", .{});
    const original = try std.testing.allocator.dupe(u8, world.traceBytes());
    defer std.testing.allocator.free(original);
    const events = world.nextEventIndex();
    // Force the next diagnostic to grow the trace, then fail that allocation.
    try world.trace_log.appendNTimes(failing.allocator(), 'x', world.trace_log.capacity - world.trace_log.items.len);
    const checkpoint_len = world.trace_log.items.len;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, sim.control.checkResources());
    try std.testing.expectEqual(checkpoint_len, world.trace_log.items.len);
    try std.testing.expectEqual(events, world.nextEventIndex());
    world.trace_log.shrinkRetainingCapacity(original.len);
    try std.testing.expectEqualStrings(original, world.traceBytes());
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try std.testing.expectError(error.ResourceLeak, sim.control.checkResources());
    file.close(io);
    try sim.control.checkResources();
}

test "resource checkpoints: directories, sockets, close and process kill" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const io = sim.env.io();
    const other_io = (try sim.envForNode(1)).io();
    try sim.control.checkResources();
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    try std.testing.expectError(error.ResourceLeak, sim.control.checkResources());
    try expectTraceContains(world.traceBytes(), "kind=directory");
    dir.close(io);
    try sim.control.checkResources();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 1244);
    var server = try address.listen(io, .{});
    const client = try address.connect(other_io, .{ .mode = .stream, .protocol = .tcp });
    const before = world.nextEventIndex();
    try std.testing.expectError(error.ResourceLeak, sim.control.checkResources());
    // Listener and client are owned by the application; pending accept is not.
    try std.testing.expectEqual(before + 2, world.nextEventIndex());
    const accepted = try server.accept(io);
    const after_accept = world.nextEventIndex();
    try std.testing.expectError(error.ResourceLeak, sim.control.checkResources());
    try std.testing.expectEqual(after_accept + 3, world.nextEventIndex());
    accepted.close(io);
    client.close(other_io);
    server.deinit(io);
    try sim.control.checkResources();
    _ = try std.Io.Dir.cwd().createFile(other_io, "killed", .{});
    try sim.control.process.kill(1);
    try sim.control.checkResources();
}

test "fuzzSeed: distinct within a run and across related bases" {
    const seed_count = 8;

    // Distinct seeds within one run.
    var seeds: [seed_count]u64 = undefined;
    for (0..seed_count) |iteration| {
        seeds[iteration] = fuzzSeed(1234, iteration);
    }
    for (seeds, 0..) |seed, i| {
        for (seeds[i + 1 ..]) |other| {
            try std.testing.expect(seed != other);
        }
    }

    // Bases differing only in low bits must not cover the same seed set.
    // The old XOR derivation made base and base ^ 1 identical sets.
    for (0..seed_count) |iteration| {
        const other = fuzzSeed(1235, iteration);
        for (seeds) |seed| {
            try std.testing.expect(seed != other);
        }
    }
}

const FailSimDiskAllocation = struct {
    backing: std.mem.Allocator,
    failed: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (!self.failed and len == @sizeOf(@import("disk/root.zig").SimDisk)) {
            self.failed = true;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

test "runSimCase: simulation setup allocation errors remain runner errors" {
    const App = struct {};
    const Functions = struct {
        fn init(_: World.Simulation) App {
            return .{};
        }

        fn scenario(_: *SimCase(App)) !void {}
    };

    var failing = FailSimDiskAllocation{ .backing = std.testing.allocator };
    try std.testing.expectError(error.OutOfMemory, runSimCase(.{
        .allocator = failing.allocator(),
        .seed = 1234,
        .simulate = World.SimulateOptions{},
        .init = Functions.init,
        .scenario = Functions.scenario,
    }));
    try std.testing.expect(failing.failed);
}

const SeedScheduleApp = struct {
    world: *World,

    fn init(sim: World.Simulation) SeedScheduleApp {
        return .{ .world = sim.control.world };
    }
};

fn seedScheduleScenario(case: *SimCase(SeedScheduleApp)) !void {
    _ = try case.app.world.randomU64();
    _ = try case.app.world.randomU64();
}

test "runSimCase: applies seed schedules at exact random microsteps" {
    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 1,
        .seed_schedule = @as(seed_module.SeedSchedule, &.{
            .{ .at = .{ .sim_time_ns = 0, .microstep = 1 }, .seed = 2 },
        }),
        .simulate = World.SimulateOptions{},
        .init = SeedScheduleApp.init,
        .scenario = seedScheduleScenario,
    });
    defer report.deinit();

    switch (report) {
        .passed => |passed| try expectTraceContains(
            passed.trace,
            "world.seed_cutover at_ns=0 microstep=1 applied_ns=0 applied_microstep=1 seed=2",
        ),
        .failed => return error.UnexpectedRunFailure,
    }
}

test "runSimCase: rejects unordered seed schedules" {
    const App = struct {};
    const Functions = struct {
        fn init(_: World.Simulation) App {
            return .{};
        }

        fn scenario(_: *SimCase(App)) !void {}
    };

    try std.testing.expectError(error.InvalidSeedSchedule, runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 1,
        .seed_schedule = @as(seed_module.SeedSchedule, &.{
            .{ .at = .{ .sim_time_ns = 10 }, .seed = 2 },
            .{ .at = .{ .sim_time_ns = 5 }, .seed = 3 },
        }),
        .simulate = World.SimulateOptions{},
        .init = Functions.init,
        .scenario = Functions.scenario,
    }));
}

test "runSimCase: rejects unordered seed schedules before watchdog isolation" {
    const App = struct {};
    const Functions = struct {
        fn init(_: World.Simulation) App {
            return .{};
        }

        fn scenario(_: *SimCase(App)) !void {}
    };

    try std.testing.expectError(error.InvalidSeedSchedule, runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 1,
        .seed_schedule = @as(seed_module.SeedSchedule, &.{
            .{ .at = .{ .sim_time_ns = 10 }, .seed = 2 },
            .{ .at = .{ .sim_time_ns = 5 }, .seed = 3 },
        }),
        .watchdog = WatchdogOptions{},
        .simulate = World.SimulateOptions{},
        .init = Functions.init,
        .scenario = Functions.scenario,
    }));
}

var sim_case_deinit_count: u8 = 0;

const SimCaseApp = struct {
    env: env_module.Env,
    value: u8 = 0,

    fn init(sim: World.Simulation) !SimCaseApp {
        _ = try sim.endpoint(u8, 0);
        return .{ .env = sim.env };
    }

    fn deinit(_: *SimCaseApp) void {
        sim_case_deinit_count += 1;
    }
};

fn simCaseScenario(case: *SimCase(SimCaseApp)) !void {
    case.app.value += 1;
    try case.control().network.setLossiness(.{});
    _ = case.env().io();
    _ = (try case.sim.envForNode(0)).io();
    _ = try case.sim.endpoint(u8, 0);
    try case.control().tick();
    try case.env().record("simcase.value value={}", .{case.app.value});
}

fn simCaseCheck(case: *const SimCase(SimCaseApp)) !void {
    if (case.app.value != 1) return error.BadSimCaseState;
    try case.env().record("simcase.check value={}", .{case.app.value});
}

test "runSimCase: initializes app from simulation and deinitializes each replay" {
    sim_case_deinit_count = 0;
    const case_checks = [_]StateCheck(SimCase(SimCaseApp)){
        .{ .name = "sim case is one", .check = simCaseCheck },
    };

    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = World.SimulateOptions{ .network = .{ .nodes = 1 } },
        .init = SimCaseApp.init,
        .scenario = simCaseScenario,
        .checks = &case_checks,
    });
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expectEqual(@as(u8, 2), sim_case_deinit_count);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "simcase.value value=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "simcase.check value=1") != null);
        },
        .failed => return error.UnexpectedRunFailure,
    }
}

test "runSimCase: accepts an infallible scenario" {
    const App = struct { calls: u8 = 0 };
    const Functions = struct {
        fn init(_: World.Simulation) App {
            return .{};
        }

        fn scenario(case: *SimCase(App)) void {
            case.app.calls += 1;
        }
    };

    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = World.SimulateOptions{},
        .init = Functions.init,
        .scenario = Functions.scenario,
    });
    defer report.deinit();

    switch (report) {
        .passed => {},
        .failed => return error.UnexpectedRunFailure,
    }
}

var pointer_sim_app_deinit_count: u8 = 0;

const PointerSimApp = struct {
    allocator: std.mem.Allocator,

    fn init(_: World.Simulation) !*PointerSimApp {
        const app = try std.testing.allocator.create(PointerSimApp);
        app.* = .{ .allocator = std.testing.allocator };
        return app;
    }

    fn deinit(self: *PointerSimApp) void {
        pointer_sim_app_deinit_count += 1;
        self.allocator.destroy(self);
    }
};

fn pointerSimAppScenario(_: *SimCase(*PointerSimApp)) !void {}

test "runSimCase: deinitializes pointer-valued apps after each replay" {
    pointer_sim_app_deinit_count = 0;

    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = World.SimulateOptions{},
        .init = PointerSimApp.init,
        .scenario = pointerSimAppScenario,
    });
    defer report.deinit();

    switch (report) {
        .passed => try std.testing.expectEqual(@as(u8, 2), pointer_sim_app_deinit_count),
        .failed => return error.UnexpectedRunFailure,
    }
}

var teardown_trace_count: u8 = 0;

const TeardownTraceApp = struct {
    env: env_module.Env,

    fn init(sim: World.Simulation) TeardownTraceApp {
        return .{ .env = sim.env };
    }

    fn deinit(self: *TeardownTraceApp) void {
        teardown_trace_count += 1;
        self.env.record("app.deinit count={}", .{teardown_trace_count}) catch unreachable;
    }
};

fn teardownTraceScenario(_: *SimCase(TeardownTraceApp)) !void {}

test "runSimCase: includes app teardown in replay comparison" {
    teardown_trace_count = 0;

    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = World.SimulateOptions{},
        .init = TeardownTraceApp.init,
        .scenario = teardownTraceScenario,
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedDeterminismMismatch,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.determinism_mismatch, failure.kind);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "app.deinit count=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.second_trace, "app.deinit count=2") != null);
        },
    }
}

test "expectSimPass and expectSimFuzz accept passing cases" {
    const case_checks = [_]StateCheck(SimCase(SimCaseApp)){
        .{ .name = "sim case is one", .check = simCaseCheck },
    };

    try expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = World.SimulateOptions{ .network = .{ .nodes = 1 } },
        .init = SimCaseApp.init,
        .scenario = simCaseScenario,
        .checks = &case_checks,
    });

    try expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .seeds = 4,
        .simulate = World.SimulateOptions{ .network = .{ .nodes = 1 } },
        .init = SimCaseApp.init,
        .scenario = simCaseScenario,
        .checks = &case_checks,
    });
}

test "expectSimFuzz rejects zero-run campaigns" {
    const App = struct {};
    const Functions = struct {
        fn init(_: World.Simulation) App {
            return .{};
        }

        fn scenario(_: *SimCase(App)) !void {}
    };
    const seed_count: usize = 0;

    try std.testing.expectError(error.InvalidSeedCount, expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .seeds = seed_count,
        .simulate = World.SimulateOptions{},
        .init = Functions.init,
        .scenario = Functions.scenario,
    }));
}

fn failingSimCaseCheck(case: *const SimCase(SimCaseApp)) !void {
    try case.env().record("simcase.check.fail value={}", .{case.app.value});
    return error.SimCaseInvariantBroken;
}

test "expectSimFailure accepts failing simulation cases" {
    const case_checks = [_]StateCheck(SimCase(SimCaseApp)){
        .{ .name = "sim case fails", .check = failingSimCaseCheck },
    };

    try expectSimFailure(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = World.SimulateOptions{ .network = .{ .nodes = 1 } },
        .init = SimCaseApp.init,
        .scenario = simCaseScenario,
        .checks = &case_checks,
        .failure = FailureExpectation{
            .kind = .check_failed,
            .error_name = "SimCaseInvariantBroken",
            .check_name = "sim case fails",
        },
    });
}

test "expectSimFailure rejects a replayable failure with the wrong identity" {
    const case_checks = [_]StateCheck(SimCase(SimCaseApp)){
        .{ .name = "sim case fails", .check = failingSimCaseCheck },
    };

    try std.testing.expectError(error.UnexpectedRunFailure, expectSimFailure(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = World.SimulateOptions{ .network = .{ .nodes = 1 } },
        .init = SimCaseApp.init,
        .scenario = simCaseScenario,
        .checks = &case_checks,
        .failure = FailureExpectation{ .error_name = "DifferentFailure" },
    }));
}

const DeadlockApp = struct {
    io: std.Io,

    fn init(sim: World.Simulation) DeadlockApp {
        return .{ .io = sim.env.io() };
    }
};

fn neverCompletes(io: std.Io, word: *u32) void {
    io.futexWaitUncancelable(u32, word, 0);
}

fn awaitDeadlockedFuture(case: *SimCase(DeadlockApp)) !void {
    var word: u32 = 0;
    var future = try std.Io.concurrent(case.app.io, neverCompletes, .{ case.app.io, &word });
    future.await(case.app.io);
}

test "runSimCase: main-context await deadlock is a structured replayable failure" {
    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0xDEAD10CC,
        .simulate = World.SimulateOptions{},
        .init = DeadlockApp.init,
        .scenario = awaitDeadlockedFuture,
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.scheduler_deadlock, failure.kind);
            try std.testing.expectEqualStrings("Deadlock", failure.error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scheduler.wait_state waits=0:") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scheduler.deadlock") != null);
        },
    }
}

fn groupMemberThatCannotCancel(io: std.Io, word: *u32) std.Io.Cancelable!void {
    io.futexWaitUncancelable(u32, word, 0);
}

fn cancelDeadlockedGroup(case: *SimCase(DeadlockApp)) !void {
    var word: u32 = 0;
    var group: std.Io.Group = .init;
    try group.concurrent(case.app.io, groupMemberThatCannotCancel, .{ case.app.io, &word });
    try std.Io.sleep(case.app.io, .fromNanoseconds(10), .awake);
    group.cancel(case.app.io);
}

test "runSimCase: Group.cancel preserves a scheduler deadlock as a structured failure" {
    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0xCACE1,
        .tick_ns = 10,
        .simulate = World.SimulateOptions{},
        .init = DeadlockApp.init,
        .scenario = cancelDeadlockedGroup,
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.scheduler_deadlock, failure.kind);
            try std.testing.expectEqualStrings("Deadlock", failure.error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scheduler.wait_state") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scheduler.deadlock") != null);
        },
    }
}

fn nonYieldingTask() void {
    var counter: u64 = 0;
    while (true) {
        counter +%= 1;
        std.mem.doNotOptimizeAway(counter);
    }
}

fn awaitNonYieldingTask(case: *SimCase(DeadlockApp)) !void {
    var future = try std.Io.concurrent(case.app.io, nonYieldingTask, .{});
    future.await(case.app.io);
}

fn runNonYieldingOnMain(case: *SimCase(DeadlockApp)) !void {
    try case.env().record("app.progress event=payload", .{});
    nonYieldingTask();
}

fn noOpDeadlockScenario(_: *SimCase(DeadlockApp)) !void {}

fn livelockedTask(io: std.Io) void {
    while (true) {
        std.Io.sleep(io, .fromNanoseconds(10), .awake) catch return;
    }
}

fn awaitLivelockedTask(case: *SimCase(DeadlockApp)) !void {
    var future = try std.Io.concurrent(case.app.io, livelockedTask, .{case.app.io});
    future.await(case.app.io);
}

test "runSimCase: watchdog classifies a non-yielding task and preserves its trace" {
    if (!watchdog_supported) return error.SkipZigTest;

    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0xBAD1009,
        .simulate = World.SimulateOptions{},
        .init = DeadlockApp.init,
        .scenario = awaitNonYieldingTask,
        .watchdog = WatchdogOptions{
            .stall_timeout_ns = 20 * std.time.ns_per_ms,
            .run_timeout_ns = 500 * std.time.ns_per_ms,
            .trace_capacity = 64 * 1024,
        },
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.non_yielding, failure.kind);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scheduler.select") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "watchdog.non_yielding task=0") != null);
        },
    }
}

test "runSimCase: watchdog contains non-yielding main-context application code" {
    if (!watchdog_supported) return error.SkipZigTest;

    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0xBAD1CA11,
        .simulate = World.SimulateOptions{},
        .init = DeadlockApp.init,
        .scenario = runNonYieldingOnMain,
        .watchdog = WatchdogOptions{
            .stall_timeout_ns = 20 * std.time.ns_per_ms,
            .run_timeout_ns = 500 * std.time.ns_per_ms,
            .trace_capacity = 64 * 1024,
        },
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.non_yielding, failure.kind);
            try std.testing.expectEqual(watchdog_module.retainedTraceEventCount(failure.first_trace), failure.first_event_count);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "app.progress event=payload") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "watchdog.non_yielding task=main") != null);
        },
    }
}

test "runSimCase: watchdog wait tolerates inherited SIGCHLD ignore" {
    if (comptime !watchdog_supported or std.posix.Sigaction == void) return error.SkipZigTest;

    var old_action: std.posix.Sigaction = undefined;
    const ignored_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &ignored_action, &old_action);
    defer std.posix.sigaction(.CHLD, &old_action, null);

    try expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0x51C41D,
        .simulate = World.SimulateOptions{},
        .init = DeadlockApp.init,
        .scenario = noOpDeadlockScenario,
        .watchdog = WatchdogOptions{
            .stall_timeout_ns = 100 * std.time.ns_per_ms,
            .run_timeout_ns = 1 * std.time.ns_per_s,
            .trace_capacity = 64 * 1024,
        },
    });
}

test "expectSimFailure keeps exact failure identity across watchdog isolation" {
    if (!watchdog_supported) return error.SkipZigTest;

    const case_checks = [_]StateCheck(SimCase(SimCaseApp)){
        .{ .name = "sim case fails", .check = failingSimCaseCheck },
    };
    try expectSimFailure(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = World.SimulateOptions{ .network = .{ .nodes = 1 } },
        .init = SimCaseApp.init,
        .scenario = simCaseScenario,
        .checks = &case_checks,
        .failure = FailureExpectation{
            .kind = .check_failed,
            .error_name = "SimCaseInvariantBroken",
            .check_name = "sim case fails",
        },
        .watchdog = WatchdogOptions{
            .stall_timeout_ns = 100 * std.time.ns_per_ms,
            .run_timeout_ns = 1 * std.time.ns_per_s,
            .trace_capacity = 64 * 1024,
        },
    });
}

test "runSimCase: watchdog distinguishes a yielding livelock" {
    if (!watchdog_supported) return error.SkipZigTest;

    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0x11FE10CC,
        .tick_ns = 10,
        .simulate = World.SimulateOptions{},
        .init = DeadlockApp.init,
        .scenario = awaitLivelockedTask,
        .watchdog = WatchdogOptions{
            .stall_timeout_ns = 100 * std.time.ns_per_ms,
            .run_timeout_ns = 1 * std.time.ns_per_s,
            .trace_capacity = 4 * 1024,
        },
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.livelock, failure.kind);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scheduler.timeout") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "watchdog.livelock task=0") != null);
        },
    }
}

test "runSimCase: watchdog total-time livelock replays compatible trace prefixes" {
    if (!watchdog_supported) return error.SkipZigTest;

    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0x71AE0CC,
        .tick_ns = 10,
        .simulate = World.SimulateOptions{},
        .init = DeadlockApp.init,
        .scenario = awaitLivelockedTask,
        .watchdog = WatchdogOptions{
            .stall_timeout_ns = 100 * std.time.ns_per_ms,
            .run_timeout_ns = 100 * std.time.ns_per_ms,
            .trace_capacity = 64 * 1024 * 1024,
        },
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.livelock, failure.kind);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "watchdog.livelock task=0") != null);
        },
    }
}

const FallibleSimApp = struct {
    fn init(_: World.Simulation) !FallibleSimApp {
        return error.SimInitFailed;
    }
};

fn unreachableSimCaseScenario(_: *SimCase(FallibleSimApp)) !void {
    return error.UnreachableSimScenario;
}

test "runSimCase: init errors become scenario failures" {
    const case_checks = [_]StateCheck(SimCase(FallibleSimApp)){};

    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = World.SimulateOptions{},
        .init = FallibleSimApp.init,
        .scenario = unreachableSimCaseScenario,
        .checks = &case_checks,
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.scenario_error, failure.kind);
            try std.testing.expectEqualStrings("SimInitFailed", failure.error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "world.init") != null);
        },
    }
}

const ReplaySiteDivergenceApp = struct {
    second_execution: bool,
    var execution_count: usize = 0;

    fn init(_: World.Simulation) ReplaySiteDivergenceApp {
        const second_execution = execution_count != 0;
        execution_count += 1;
        return .{ .second_execution = second_execution };
    }
};

fn divergeAtSemanticSite(case: *SimCase(ReplaySiteDivergenceApp)) !void {
    if (case.app.second_execution) {
        _ = try case.control().world.chooseIntLessThan("scheduler.wake", usize, 3);
    } else {
        _ = try case.control().world.chooseIntLessThan("scheduler.select", usize, 3);
    }
}

test "runSimCase: second execution exact-replays the first decision tape" {
    ReplaySiteDivergenceApp.execution_count = 0;
    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0xDEC1DE,
        .simulate = World.SimulateOptions{},
        .init = ReplaySiteDivergenceApp.init,
        .scenario = divergeAtSemanticSite,
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.replay_diverged, failure.kind);
            try std.testing.expectEqual(@as(usize, 1), failure.decision_tape.entries.len);
            try std.testing.expectEqualStrings(
                "scheduler.select",
                failure.decision_tape.entries[0].site_id,
            );
            const divergence = failure.replay_divergence.?;
            try std.testing.expectEqual(
                decision_module.DivergenceKind.site_mismatch,
                divergence.kind,
            );
            try std.testing.expectEqual(@as(usize, 0), divergence.tape_index);
            try std.testing.expectEqualStrings("scheduler.select", divergence.expected.?.site_id);
            try std.testing.expectEqualStrings("scheduler.wake", divergence.actual.?.site_id);
            try std.testing.expectEqual(
                divergence.expected.?.preceding_event_index,
                divergence.actual.?.preceding_event_index,
            );
        },
    }
}

const ReplayRemainingApp = struct {
    second_execution: bool,
    var execution_count: usize = 0;

    fn init(_: World.Simulation) ReplayRemainingApp {
        const second_execution = execution_count != 0;
        execution_count += 1;
        return .{ .second_execution = second_execution };
    }
};

fn leaveDecisionUnconsumed(case: *SimCase(ReplayRemainingApp)) !void {
    if (!case.app.second_execution) {
        _ = try case.control().world.chooseBool("network.drop");
    }
}

test "runSimCase: exact replay rejects an unconsumed tape suffix" {
    ReplayRemainingApp.execution_count = 0;
    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0xDEC1DE,
        .simulate = World.SimulateOptions{},
        .init = ReplayRemainingApp.init,
        .scenario = leaveDecisionUnconsumed,
    });
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.replay_diverged, failure.kind);
            try std.testing.expectEqual(
                decision_module.DivergenceKind.tape_remaining,
                failure.replay_divergence.?.kind,
            );
            try std.testing.expectEqualStrings(
                "network.drop",
                failure.replay_divergence.?.expected.?.site_id,
            );
            try std.testing.expectEqual(@as(?decision_module.Request, null), failure.replay_divergence.?.actual);
        },
    }
}

const DecisionTapePassApp = struct {
    fn init(_: World.Simulation) DecisionTapePassApp {
        return .{};
    }
};

fn recordPassingDecision(case: *SimCase(DecisionTapePassApp)) !void {
    _ = try case.control().world.chooseBool("network.drop");
}

test "runSimCase: passing report owns the first execution decision tape" {
    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0x7A9E,
        .simulate = World.SimulateOptions{},
        .init = DecisionTapePassApp.init,
        .scenario = recordPassingDecision,
    });
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expectEqual(@as(usize, 1), passed.decision_tape.entries.len);
            try std.testing.expectEqualStrings(
                "network.drop",
                passed.decision_tape.entries[0].site_id,
            );
        },
        .failed => return error.ExpectedRunPass,
    }
}

const SchedulerTapeApp = struct {
    io: std.Io,
    first: u8 = 0,
    second: u8 = 0,

    fn init(sim: World.Simulation) SchedulerTapeApp {
        return .{ .io = sim.env.io() };
    }
};

fn incrementTapeValue(value: *u8) void {
    value.* += 1;
}

fn runSchedulerTapeScenario(case: *SimCase(SchedulerTapeApp)) !void {
    var first = try std.Io.concurrent(case.app.io, incrementTapeValue, .{&case.app.first});
    var second = try std.Io.concurrent(case.app.io, incrementTapeValue, .{&case.app.second});
    first.await(case.app.io);
    second.await(case.app.io);
}

test "runSimCase: scheduler decisions use stable tape sites" {
    var report = try runSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0x5C4ED,
        .simulate = World.SimulateOptions{ .task_start_jitter_ns = 3 },
        .init = SchedulerTapeApp.init,
        .scenario = runSchedulerTapeScenario,
    });
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            var start_jitter_count: usize = 0;
            var select_count: usize = 0;
            for (passed.decision_tape.entries) |entry| {
                if (std.mem.eql(u8, entry.site_id, "scheduler.start_jitter")) {
                    start_jitter_count += 1;
                } else if (std.mem.eql(u8, entry.site_id, "scheduler.select")) {
                    select_count += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 2), start_jitter_count);
            try std.testing.expect(select_count >= 2);
        },
        .failed => return error.ExpectedRunPass,
    }
}

fn compareOwnershipAllocationCase(allocator: std.mem.Allocator, first_failed: bool, second_failed: bool, differs: bool) !void {
    var world = try World.init(std.testing.allocator, .{ .seed = 7 });
    defer world.deinit();
    _ = try world.chooseBool("ownership.choice");
    var first = try execution.Result.capture(allocator, &world, if (first_failed) .{ .kind = .check_failed, .error_name = "Primary", .check_name = "owned check" } else null);
    errdefer first.deinit();
    if (differs) try world.record("ownership.second", .{});
    const second = try execution.Result.capture(allocator, &world, if (second_failed) .{ .kind = .check_failed, .error_name = "Primary", .check_name = "owned check" } else null);
    const result = compareRunOnceResults(allocator, .{ .seed = 7, .name = "owned options", .tags = &.{"tag"}, .attributes = &.{runAttribute("key", "value")} }, .{}, first, second);
    first = .{ .allocator = allocator, .trace = &.{}, .event_count = 0 };
    var report = try result;
    defer report.deinit();
    try std.testing.expect((report == .passed) == (!first_failed and !second_failed and !differs));
}

test "execution result comparison owns all outcome pairs across allocation failure" {
    for ([_]bool{ false, true }) |first_failed| {
        for ([_]bool{ false, true }) |second_failed| {
            for ([_]bool{ false, true }) |differs| {
                try std.testing.checkAllAllocationFailures(std.testing.allocator, compareOwnershipAllocationCase, .{ first_failed, second_failed, differs });
            }
        }
    }
}
