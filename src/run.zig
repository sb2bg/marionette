//! Scenario runner with built-in deterministic replay verification.

const std = @import("std");

const env_module = @import("env.zig");
const network_module = @import("network/root.zig");
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
pub const TraceError = world_module.TraceError;

/// Infrastructure errors from the runners themselves; scenario failures
/// are reported through `RunReport`, not as errors.
pub const RunError = std.mem.Allocator.Error || TraceError;
/// The `expect*` wrappers' outcome mismatches: the run passed where a
/// failure was required, or failed where a pass was required.
pub const ExpectError = error{
    ExpectedRunFailure,
    ExpectedRunPass,
};
pub const ExpectRunError = RunError || ExpectError;

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

        /// An environment whose `std.Io` is bound to one node's process.
        pub fn envForNode(self: *const Self, node: network_module.NodeId) !env_module.Env {
            return try self.sim.envForNode(node);
        }

        /// The node-0 deterministic `std.Io`.
        pub fn io(self: *const Self) std.Io {
            return self.env().io();
        }

        /// The deterministic `std.Io` bound to one node's process.
        pub fn ioForNode(self: *const Self, node: network_module.NodeId) !std.Io {
            return (try self.envForNode(node)).io();
        }

        /// Open one typed simulated endpoint on `node`.
        pub fn endpoint(self: *const Self, comptime Payload: type, node: network_module.NodeId) !network_module.Endpoint(Payload) {
            return try self.sim.endpoint(Payload, node);
        }

        /// Open one byte-payload simulated endpoint on `node`.
        pub fn byteEndpoint(self: *const Self, node: network_module.NodeId) !network_module.ByteEndpoint {
            return try self.sim.byteEndpoint(node);
        }

        /// Open typed endpoints on `count` consecutive nodes starting at
        /// `first_node`.
        pub fn endpoints(
            self: *const Self,
            comptime Payload: type,
            comptime count: usize,
            first_node: network_module.NodeId,
        ) ![count]network_module.Endpoint(Payload) {
            return try self.sim.endpoints(Payload, count, first_node);
        }

        /// Open byte-payload endpoints on `count` consecutive nodes
        /// starting at `first_node`.
        pub fn byteEndpoints(
            self: *const Self,
            comptime count: usize,
            first_node: network_module.NodeId,
        ) ![count]network_module.ByteEndpoint {
            return try self.sim.byteEndpoints(count, first_node);
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

/// Run one simulation case.
///
/// Required fields:
/// - `allocator`
/// - `simulate: mar.World.SimulateOptions`
/// - `init: fn (mar.Sim) App` or `fn (mar.Sim) !App`
/// - `scenario: fn (*mar.SimCase(App)) !void`
///
/// Optional fields mirror `RunOptions`: `seed`, `start_ns`, `tick_ns`,
/// `name`, `tags`, `attributes`, `world_checks`, and `checks`.
pub fn runSimCase(config: anytype) RunError!RunReport {
    return runSimCaseWithSeed(config, null);
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

/// Expect a simulation case to fail. Use `runSimCase` directly when the test
/// needs to inspect the failure details.
pub fn expectSimFailure(config: anytype) ExpectRunError!void {
    var report = try runSimCase(config);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => {},
    }
}

/// Run a simulation case over many deterministic seeds.
///
/// Required extra field: `seeds`, the number of seeds to run. Optional `seed`
/// acts as the base seed.
pub fn expectSimFuzz(config: anytype) ExpectRunError!void {
    if (!@hasField(@TypeOf(config), "seeds")) {
        @compileError("expectSimFuzz config requires a `seeds` field");
    }

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

fn runSimCaseWithSeed(config: anytype, seed_override: ?u64) RunError!RunReport {
    if (!@hasField(@TypeOf(config), "simulate")) {
        @compileError("runSimCase config requires a `simulate` field");
    }

    const App = appTypeFromSimInit(config.init);
    const Case = SimCase(App);
    validateSimScenario(Case, config.scenario);

    const no_case_checks = [_]StateCheck(Case){};
    const case_checks = if (@hasField(@TypeOf(config), "checks")) config.checks else &no_case_checks;

    return runTwiceWithSimCase(
        config.allocator,
        runOptionsFromConfig(config, seed_override),
        simulateOptionsFromConfig(config.simulate),
        App,
        fallibleSimInit(App, config.init),
        config.scenario,
        case_checks,
    );
}

fn runOptionsFromConfig(config: anytype, seed_override: ?u64) RunOptions {
    return .{
        .seed = seed_override orelse configSeed(config),
        .start_ns = fieldOrDefault(config, "start_ns", @as(u64, 0)),
        .tick_ns = fieldOrDefault(config, "tick_ns", @import("clock.zig").default_tick_ns),
        .name = configRunName(config),
        .tags = fieldOrDefault(config, "tags", @as([]const []const u8, &.{})),
        .attributes = fieldOrDefault(config, "attributes", @as([]const RunAttribute, &.{})),
        .checks = fieldOrDefault(config, "world_checks", @as([]const Check, &.{})),
    };
}

fn configSeed(config: anytype) u64 {
    return fieldOrDefault(config, "seed", @as(u64, 0));
}

fn configRunName(config: anytype) ?[]const u8 {
    return fieldOrDefault(config, "name", @as(?[]const u8, null));
}

fn fieldOrDefault(config: anytype, comptime name: []const u8, default: anytype) @TypeOf(default) {
    return if (@hasField(@TypeOf(config), name)) @field(config, name) else default;
}

fn simulateOptionsFromConfig(simulate: anytype) World.SimulateOptions {
    const Simulate = @TypeOf(simulate);
    return .{
        .disk = if (@hasField(Simulate, "disk")) diskOptionsFromConfig(simulate.disk) else .{},
        .network = if (@hasField(Simulate, "network")) networkOptionsFromConfig(simulate.network) else null,
    };
}

fn diskOptionsFromConfig(disk: anytype) @import("disk/root.zig").DiskOptions {
    return .{
        .sector_size = fieldOrDefault(disk, "sector_size", @as(u64, 4096)),
        .min_latency_ns = fieldOrDefault(disk, "min_latency_ns", @as(?@import("clock.zig").Duration, null)),
        .latency_jitter_ns = fieldOrDefault(disk, "latency_jitter_ns", @as(@import("clock.zig").Duration, 0)),
    };
}

fn networkOptionsFromConfig(network: anytype) ?network_module.SimNetworkOptions {
    const Network = @TypeOf(network);
    return switch (@typeInfo(Network)) {
        .null => null,
        .optional => if (network) |options| networkOptionsFromConfig(options) else null,
        else => .{
            .nodes = if (@hasField(Network, "nodes"))
                network.nodes
            else
                @compileError("runSimCase config.simulate.network requires a `nodes` field"),
            .service_nodes = fieldOrDefault(network, "service_nodes", @as(usize, 0)),
            .path_capacity = fieldOrDefault(network, "path_capacity", @as(usize, 64)),
        },
    };
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
        else => false,
    };
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
    // Always execute both runs, even when the first fails: a failure that
    // does not reproduce with the same seed is itself a determinism leak,
    // and a failure that does reproduce is verified replayable.
    var first = try runOnceWithStateLifecycle(allocator, options, State, init_state, deinit_state, scenario, state_checks);
    errdefer first.deinit();

    const second = try runOnceWithStateLifecycle(allocator, options, State, init_state, deinit_state, scenario, state_checks);

    return compareRunOnceResults(allocator, first, second);
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
    // Always execute both runs, even when the first fails: a failure that
    // does not reproduce with the same seed is itself a determinism leak,
    // and a failure that does reproduce is verified replayable.
    var first = try runOnceWithSimCase(allocator, options, simulate_options, App, init_app, scenario, state_checks);
    errdefer first.deinit();

    const second = try runOnceWithSimCase(allocator, options, simulate_options, App, init_app, scenario, state_checks);

    return compareRunOnceResults(allocator, first, second);
}

fn compareRunOnceResults(
    allocator: std.mem.Allocator,
    first_result: RunOnceResult,
    second_result: RunOnceResult,
) RunReport {
    const first = first_result;
    var second = second_result;

    switch (first) {
        .passed => |first_passed| switch (second) {
            .passed => |*second_passed| {
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

                second.deinit();
                return .{ .passed = first_passed };
            },
            .failed => |second_failure| {
                // The first run passed, so the second run's failure is a
                // determinism leak surfaced through an error.
                var failure_options = second_failure.options;
                if (second_failure.owns_options) deinitRunOptions(allocator, &failure_options);
                return .{ .failed = .{
                    .allocator = allocator,
                    .options = first_passed.options,
                    .owns_options = first_passed.owns_options,
                    .first_trace = first_passed.trace,
                    .second_trace = second_failure.first_trace,
                    .first_event_count = first_passed.event_count,
                    .second_event_count = second_failure.first_event_count,
                    .kind = .second_run_failed,
                    .error_name = second_failure.error_name,
                    .check_name = second_failure.check_name,
                    .owns_check_name = second_failure.owns_check_name,
                } };
            },
        },
        .failed => |first_failure| switch (second) {
            .passed => |second_passed| {
                // The failure did not reproduce: a determinism leak.
                var passed_options = second_passed.options;
                if (second_passed.owns_options) deinitRunOptions(allocator, &passed_options);
                return .{ .failed = .{
                    .allocator = allocator,
                    .options = first_failure.options,
                    .owns_options = first_failure.owns_options,
                    .kind = .first_run_failed,
                    .first_trace = first_failure.first_trace,
                    .second_trace = second_passed.trace,
                    .first_event_count = first_failure.first_event_count,
                    .second_event_count = second_passed.event_count,
                    .error_name = first_failure.error_name,
                    .check_name = first_failure.check_name,
                    .owns_check_name = first_failure.owns_check_name,
                } };
            },
            .failed => |second_failure| {
                const reproduced = first_failure.kind == second_failure.kind and
                    optionalTextEqual(first_failure.error_name, second_failure.error_name) and
                    optionalTextEqual(first_failure.check_name, second_failure.check_name) and
                    std.mem.eql(u8, first_failure.first_trace, second_failure.first_trace);
                if (reproduced) {
                    // Verified replayable failure: report the first run's
                    // failure as-is.
                    second.deinit();
                    return .{ .failed = first_failure };
                }

                // Same seed, two different failures: a determinism leak.
                // Keep both runs' diagnostics.
                var failure_options = second_failure.options;
                if (second_failure.owns_options) deinitRunOptions(allocator, &failure_options);
                return .{ .failed = .{
                    .allocator = allocator,
                    .options = first_failure.options,
                    .owns_options = first_failure.owns_options,
                    .kind = .determinism_mismatch,
                    .first_trace = first_failure.first_trace,
                    .second_trace = second_failure.first_trace,
                    .first_event_count = first_failure.first_event_count,
                    .second_event_count = second_failure.first_event_count,
                    .error_name = first_failure.error_name,
                    .check_name = first_failure.check_name,
                    .owns_check_name = first_failure.owns_check_name,
                    .second_error_name = second_failure.error_name,
                    .second_check_name = second_failure.check_name,
                    .owns_second_check_name = second_failure.owns_check_name,
                } };
            },
        },
    }
}

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn runOnceWithSimCase(
    allocator: std.mem.Allocator,
    options: RunOptions,
    simulate_options: World.SimulateOptions,
    comptime App: type,
    comptime init_app: fn (World.Simulation) anyerror!App,
    comptime scenario: fn (*SimCase(App)) anyerror!void,
    comptime state_checks: []const StateCheck(SimCase(App)),
) RunError!RunOnceResult {
    var world = try World.init(allocator, options.worldOptions());
    defer world.deinit();
    try recordRunContext(&world, options);

    const sim = world.simulate(simulate_options) catch |err| {
        return .{ .failed = try failureFromWorld(
            allocator,
            options,
            .scenario_error,
            &world,
            err,
            null,
        ) };
    };

    var state: SimCase(App) = .{
        .sim = sim,
        .app = init_app(sim) catch |err| {
            return .{ .failed = try failureFromWorld(
                allocator,
                options,
                .scenario_error,
                &world,
                err,
                null,
            ) };
        },
    };
    defer state.deinit();

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

var flaky_counter: u64 = 0;

fn passThenFailScenario(world: *World) !void {
    try world.record("scenario.flaky", .{});
    flaky_counter += 1;
    if (flaky_counter >= 2) return error.SecondRunBoom;
}

fn failThenPassScenario(world: *World) !void {
    try world.record("scenario.flaky", .{});
    flaky_counter += 1;
    if (flaky_counter == 1) return error.FirstRunBoom;
}

test "run: fail-then-pass is reported as a determinism leak" {
    flaky_counter = 0;
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, failThenPassScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.first_run_failed, failure.kind);
            try std.testing.expectEqualStrings("FirstRunBoom", failure.error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scenario.flaky") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.second_trace, "scenario.flaky") != null);
        },
    }
}

fn divergingFailureScenario(world: *World) !void {
    flaky_counter += 1;
    try world.record("scenario.attempt value={}", .{flaky_counter});
    return if (flaky_counter == 1) error.FirstBoom else error.SecondBoom;
}

test "run: failures that do not replay byte-identically are a determinism mismatch" {
    flaky_counter = 0;
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, divergingFailureScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.determinism_mismatch, failure.kind);
            try std.testing.expectEqualStrings("FirstBoom", failure.error_name.?);
            try std.testing.expectEqualStrings("SecondBoom", failure.second_error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "value=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.second_trace, "value=2") != null);

            var buffer: [512]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try failure.writeSummary(&writer);
            const summary = writer.buffered();
            try std.testing.expect(std.mem.indexOf(u8, summary, "error=FirstBoom") != null);
            try std.testing.expect(std.mem.indexOf(u8, summary, "second_error=SecondBoom") != null);
        },
    }
}

test "run: pass-then-fail is reported as a determinism leak" {
    flaky_counter = 0;
    var report = try run(std.testing.allocator, .{ .seed = 1234 }, passThenFailScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(RunFailureKind.second_run_failed, failure.kind);
            try std.testing.expectEqualStrings("SecondRunBoom", failure.error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scenario.flaky") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.second_trace, "scenario.flaky") != null);
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
        .name = "smoke",
        .tags = &tags,
        .attributes = &attributes,
    }, deterministicScenario);
    defer report.deinit();

    switch (report) {
        .passed => |passed| {
            try std.testing.expectEqual(@as(u64, 10), passed.event_count);
            try std.testing.expect(std.mem.indexOf(u8, passed.trace, "run.name value=smoke") != null);
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
        .name = "smoke",
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
                "marionette failure: kind=scenario_error seed=1234 name=smoke start_ns=0 tick_ns=1 first_events=7 second_events=0 tag=example:replicated_register tag=scenario:smoke replicas=uint:3 proposal_drop_percent=uint:20 error=Boom\n",
                summary,
            );
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "run.name value=smoke") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "scenario.before_error") != null);
        },
    }
}

test "RunFailure: owns replay metadata used by summaries" {
    var name_buf = [_]u8{ 's', 'm', 'o', 'k', 'e' };
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
        .name = name_buf[0..],
        .tags = &tags,
        .attributes = &attributes,
        .checks = &checks,
    }, deterministicScenario);
    defer report.deinit();

    @memcpy(name_buf[0..], "other");
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

            try std.testing.expect(std.mem.indexOf(u8, summary, "name=smoke") != null);
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
        .name = "smoke test",
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

            try std.testing.expect(std.mem.indexOf(u8, summary, "name=smoke%20test") != null);
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
    _ = case.io();
    _ = try case.ioForNode(0);
    _ = try case.endpoint(u8, 0);
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
        .simulate = .{ .network = .{ .nodes = 1 } },
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

test "expectSimPass and expectSimFuzz accept passing cases" {
    const case_checks = [_]StateCheck(SimCase(SimCaseApp)){
        .{ .name = "sim case is one", .check = simCaseCheck },
    };

    try expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .simulate = .{ .network = .{ .nodes = 1 } },
        .init = SimCaseApp.init,
        .scenario = simCaseScenario,
        .checks = &case_checks,
    });

    try expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 1234,
        .seeds = 4,
        .simulate = .{ .network = .{ .nodes = 1 } },
        .init = SimCaseApp.init,
        .scenario = simCaseScenario,
        .checks = &case_checks,
    });
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
        .simulate = .{ .network = .{ .nodes = 1 } },
        .init = SimCaseApp.init,
        .scenario = simCaseScenario,
        .checks = &case_checks,
    });
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
        .simulate = .{},
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

