//! Scenario runner with built-in deterministic replay verification.

const std = @import("std");

const env_module = @import("env.zig");
const run_types = @import("run_types.zig");
const world_module = @import("world.zig");
const World = @import("world.zig").World;

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
/// Errors specific to the `expect*` wrappers: outcome mismatches and invalid
/// expectation configuration.
pub const ExpectError = error{
    ExpectedRunFailure,
    ExpectedRunPass,
    InvalidSeedCount,
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
/// Optional fields are `seed`, `start_ns`, `tick_ns`, `name`, `tags`,
/// `attributes`, and `checks`.
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

    return runTwiceWithSimCase(
        config.allocator,
        runOptionsFromConfig(config, seed_override),
        config.simulate,
        App,
        fallibleSimInit(App, config.init),
        fallibleSimScenario(Case, config.scenario),
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

    const sim = world.simulate(simulate_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
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
    var state_live = true;
    defer if (state_live) state.deinit();

    scenario(&state) catch |err| {
        state.deinit();
        state_live = false;
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
            state.deinit();
            state_live = false;
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

    state.deinit();
    state_live = false;
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
