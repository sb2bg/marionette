//! Scenario runner with built-in deterministic replay verification.

const std = @import("std");
const builtin = @import("builtin");

const env_module = @import("env.zig");
const run_types = @import("run_types.zig");
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

const watchdog_supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

const WatchdogStatus = enum(u8) {
    running,
    passed,
    failed,
    out_of_memory,
    invalid_trace,
    trace_too_large,
    result_too_large,
};

const max_watchdog_identity_len = 512;

const WatchdogHeader = extern struct {
    done: std.atomic.Value(u8) = .init(0),
    progress: std.atomic.Value(u64) = .init(0),
    trace_len: std.atomic.Value(usize) = .init(0),
    event_count: std.atomic.Value(u64) = .init(0),
    task_running: std.atomic.Value(u8) = .init(0),
    task_id: std.atomic.Value(u64) = .init(0),
    trace_truncated: std.atomic.Value(u8) = .init(0),
    status: WatchdogStatus = .running,
    failure_kind: RunFailureKind = .scenario_error,
    error_name_len: u16 = 0,
    check_name_len: u16 = 0,
    error_name: [max_watchdog_identity_len]u8 = @splat(0),
    check_name: [max_watchdog_identity_len]u8 = @splat(0),
};

const WatchdogShared = struct {
    mapping: []align(std.heap.page_size_min) u8,
    header: *WatchdogHeader,
    trace: []u8,

    fn init(options: WatchdogOptions) RunError!WatchdogShared {
        const trace_offset = std.mem.alignForward(usize, @sizeOf(WatchdogHeader), @alignOf(u64));
        const raw_len = std.math.add(usize, trace_offset, options.trace_capacity) catch
            return error.InvalidWatchdogOptions;
        const page_size = std.heap.pageSize();
        const padded_len = std.math.add(usize, raw_len, page_size - 1) catch
            return error.InvalidWatchdogOptions;
        const mapping_len = std.mem.alignBackward(usize, padded_len, page_size);
        const mapping = std.posix.mmap(
            null,
            mapping_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.WatchdogUnavailable;
        errdefer std.posix.munmap(mapping);

        const header: *WatchdogHeader = @ptrCast(@alignCast(mapping.ptr));
        header.* = .{};
        return .{
            .mapping = mapping,
            .header = header,
            .trace = mapping[trace_offset..raw_len],
        };
    }

    fn deinit(self: *WatchdogShared) void {
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }

    fn observer(self: *WatchdogShared) world_module.ExecutionObserver {
        return .{ .ptr = self, .vtable = &watchdog_observer_vtable };
    }

    fn publishTrace(raw: *anyopaque, trace: []const u8, event_count: u64, replace_from: usize) void {
        const self: *WatchdogShared = @ptrCast(@alignCast(raw));
        const copy_len = @min(trace.len, self.trace.len);
        const copy_from = @min(replace_from, copy_len);
        if (copy_len > copy_from) @memcpy(self.trace[copy_from..copy_len], trace[copy_from..copy_len]);
        if (trace.len > self.trace.len) self.header.trace_truncated.store(1, .release);
        self.header.event_count.store(event_count, .release);
        self.header.trace_len.store(copy_len, .release);
        _ = self.header.progress.fetchAdd(1, .release);
    }

    fn taskStart(raw: *anyopaque, task_id: u64) void {
        const self: *WatchdogShared = @ptrCast(@alignCast(raw));
        self.header.task_id.store(task_id, .release);
        self.header.task_running.store(1, .release);
        _ = self.header.progress.fetchAdd(1, .release);
    }

    fn taskStop(raw: *anyopaque, task_id: u64) void {
        const self: *WatchdogShared = @ptrCast(@alignCast(raw));
        std.debug.assert(self.header.task_id.load(.acquire) == task_id);
        self.header.task_running.store(0, .release);
        _ = self.header.progress.fetchAdd(1, .release);
    }

    fn copyIdentity(destination: []u8, source: ?[]const u8) u16 {
        const text = source orelse return 0;
        if (text.len > destination.len) return std.math.maxInt(u16);
        @memcpy(destination[0..text.len], text);
        return @intCast(text.len);
    }

    fn publishResult(self: *WatchdogShared, result: RunOnceResult) void {
        if (self.header.trace_truncated.load(.acquire) != 0) {
            self.header.status = .trace_too_large;
            self.header.done.store(1, .release);
            return;
        }
        switch (result) {
            .passed => |passed| {
                self.header.status = .passed;
                self.header.event_count.store(passed.event_count, .release);
            },
            .failed => |failure| {
                const error_len = copyIdentity(&self.header.error_name, failure.error_name);
                const check_len = copyIdentity(&self.header.check_name, failure.check_name);
                if (error_len == std.math.maxInt(u16) or check_len == std.math.maxInt(u16)) {
                    self.header.status = .result_too_large;
                    self.header.done.store(1, .release);
                    return;
                }
                self.header.status = .failed;
                self.header.failure_kind = failure.kind;
                self.header.error_name_len = error_len;
                self.header.check_name_len = check_len;
                self.header.event_count.store(failure.first_event_count, .release);
            },
        }
        self.header.done.store(1, .release);
    }

    fn publishRunError(self: *WatchdogShared, err: RunError) void {
        self.header.status = switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.InvalidTracePayload => .invalid_trace,
            else => .result_too_large,
        };
        self.header.done.store(1, .release);
    }
};

const watchdog_observer_vtable: world_module.ExecutionObserver.VTable = .{
    .trace = WatchdogShared.publishTrace,
    .task_start = WatchdogShared.taskStart,
    .task_stop = WatchdogShared.taskStop,
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
/// `attributes`, `checks`, and `watchdog`.
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

/// Expect a simulation case to fail. An optional `failure` field constrains
/// the accepted kind, error name, and/or check name. Use `runSimCase` directly
/// when the test needs to inspect the full failure details.
pub fn expectSimFailure(config: anytype) ExpectRunError!void {
    var report = try runSimCase(config);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            const expectation: FailureExpectation = fieldOrDefault(
                config,
                "failure",
                FailureExpectation{},
            );
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
        .watchdog = fieldOrDefault(config, "watchdog", @as(?WatchdogOptions, null)),
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
    var first = try runOnceDispatched(allocator, options, simulate_options, App, init_app, scenario, state_checks);
    errdefer first.deinit();

    const second = try runOnceDispatched(allocator, options, simulate_options, App, init_app, scenario, state_checks);

    return compareRunOnceResults(allocator, first, second);
}

fn runOnceDispatched(
    allocator: std.mem.Allocator,
    options: RunOptions,
    simulate_options: World.SimulateOptions,
    comptime App: type,
    comptime init_app: fn (World.Simulation) anyerror!App,
    comptime scenario: fn (*SimCase(App)) anyerror!void,
    comptime state_checks: []const StateCheck(SimCase(App)),
) RunError!RunOnceResult {
    if (options.watchdog) |watchdog| {
        try watchdog.validate();
        return runOnceWithWatchdog(
            allocator,
            options,
            simulate_options,
            App,
            init_app,
            scenario,
            state_checks,
            watchdog,
        );
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
    );
}

fn runOnceWithWatchdog(
    allocator: std.mem.Allocator,
    options: RunOptions,
    simulate_options: World.SimulateOptions,
    comptime App: type,
    comptime init_app: fn (World.Simulation) anyerror!App,
    comptime scenario: fn (*SimCase(App)) anyerror!void,
    comptime state_checks: []const StateCheck(SimCase(App)),
    watchdog: WatchdogOptions,
) RunError!RunOnceResult {
    if (comptime !watchdog_supported) return error.WatchdogUnavailable;

    var shared = try WatchdogShared.init(watchdog);
    defer shared.deinit();

    const pid = try forkWatchdogWorker();
    if (pid == 0) {
        var child_result = runOnceWithSimCase(
            allocator,
            options,
            simulate_options,
            App,
            init_app,
            scenario,
            state_checks,
            shared.observer(),
        ) catch |err| {
            shared.publishRunError(err);
            exitWatchdogWorker();
        };
        shared.publishResult(child_result);
        child_result.deinit();
        exitWatchdogWorker();
    }

    const started_at = watchdogNowNs();
    var last_progress_at = started_at;
    var last_progress = shared.header.progress.load(.acquire);
    while (shared.header.done.load(.acquire) == 0) {
        const now = watchdogNowNs();
        const progress = shared.header.progress.load(.acquire);
        if (progress != last_progress) {
            last_progress = progress;
            last_progress_at = now;
        }

        const stalled = now -| last_progress_at >= watchdog.stall_timeout_ns;
        const expired = now -| started_at >= watchdog.run_timeout_ns;
        const trace_full = shared.header.trace_truncated.load(.acquire) != 0;
        if (stalled or expired or trace_full) {
            killWatchdogWorker(pid);
            return watchdogFailureFromShared(
                allocator,
                options,
                &shared,
                if (stalled) .non_yielding else .livelock,
            );
        }

        std.Io.sleep(
            std.Options.debug_io,
            .fromMilliseconds(1),
            .awake,
        ) catch {};
    }

    waitWatchdogWorker(pid);
    return resultFromWatchdogShared(allocator, options, &shared);
}

fn forkWatchdogWorker() RunError!std.posix.pid_t {
    const rc = std.posix.system.fork();
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => error.WatchdogUnavailable,
    };
}

fn waitWatchdogWorker(pid: std.posix.pid_t) void {
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
        var status: u32 = 0;
        while (true) {
            const rc = std.os.linux.waitpid(pid, &status, 0);
            if (std.posix.errno(rc) == .SUCCESS) return;
        }
    } else {
        var status: c_int = 0;
        while (std.c.waitpid(pid, &status, 0) < 0) {}
    }
}

fn exitWatchdogWorker() noreturn {
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
        std.os.linux.exit(0);
    } else {
        std.c._exit(0);
    }
}

fn killWatchdogWorker(pid: std.posix.pid_t) void {
    std.posix.kill(pid, .KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => {},
    };
    waitWatchdogWorker(pid);
}

fn watchdogNowNs() u64 {
    const timestamp = std.Io.Clock.awake.now(std.Options.debug_io).nanoseconds;
    return @intCast(@max(timestamp, 0));
}

fn resultFromWatchdogShared(
    allocator: std.mem.Allocator,
    options: RunOptions,
    shared: *const WatchdogShared,
) RunError!RunOnceResult {
    const header = shared.header;
    switch (header.status) {
        .out_of_memory => return error.OutOfMemory,
        .invalid_trace => return error.InvalidTracePayload,
        .trace_too_large => return watchdogFailureFromShared(allocator, options, shared, .livelock),
        .result_too_large => return error.WatchdogTraceTooLarge,
        .running => return error.WatchdogUnavailable,
        .passed => {
            const trace = try allocator.dupe(u8, shared.trace[0..header.trace_len.load(.acquire)]);
            errdefer allocator.free(trace);
            const owned_options = try cloneRunOptions(allocator, options);
            return .{ .passed = .{
                .allocator = allocator,
                .options = owned_options,
                .owns_options = true,
                .trace = trace,
                .event_count = header.event_count.load(.acquire),
            } };
        },
        .failed => {
            const trace = try allocator.dupe(u8, shared.trace[0..header.trace_len.load(.acquire)]);
            errdefer allocator.free(trace);
            var owned_options = try cloneRunOptions(allocator, options);
            errdefer deinitRunOptions(allocator, &owned_options);

            const error_name = if (header.error_name_len == 0)
                null
            else
                try allocator.dupe(u8, header.error_name[0..header.error_name_len]);
            errdefer if (error_name) |name| allocator.free(name);
            const check_name = if (header.check_name_len == 0)
                null
            else
                try allocator.dupe(u8, header.check_name[0..header.check_name_len]);
            errdefer if (check_name) |name| allocator.free(name);

            return .{ .failed = .{
                .allocator = allocator,
                .options = owned_options,
                .owns_options = true,
                .kind = header.failure_kind,
                .first_trace = trace,
                .first_event_count = header.event_count.load(.acquire),
                .error_name = error_name,
                .owns_error_name = error_name != null,
                .check_name = check_name,
                .owns_check_name = check_name != null,
            } };
        },
    }
}

fn watchdogFailureFromShared(
    allocator: std.mem.Allocator,
    options: RunOptions,
    shared: *const WatchdogShared,
    kind: RunFailureKind,
) RunError!RunOnceResult {
    var prefix = shared.trace[0..shared.header.trace_len.load(.acquire)];
    if (shared.header.trace_truncated.load(.acquire) != 0) {
        if (std.mem.lastIndexOfScalar(u8, prefix, '\n')) |last_newline| {
            prefix = prefix[0 .. last_newline + 1];
        } else {
            prefix = &.{};
        }
    }
    const event_count: u64 = @intCast(std.mem.count(u8, prefix, "event="));
    const task_id = shared.header.task_id.load(.acquire);
    const task_running = shared.header.task_running.load(.acquire) != 0;
    const suffix = if (kind == .non_yielding and !task_running)
        try std.fmt.allocPrint(
            allocator,
            "event={} watchdog.{s} task=main\n",
            .{ event_count, @tagName(kind) },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "event={} watchdog.{s} task={}\n",
            .{ event_count, @tagName(kind), task_id },
        );
    defer allocator.free(suffix);
    const trace = try std.mem.concat(allocator, u8, &.{ prefix, suffix });
    errdefer allocator.free(trace);
    const owned_options = try cloneRunOptions(allocator, options);

    return .{ .failed = .{
        .allocator = allocator,
        .options = owned_options,
        .owns_options = true,
        .kind = kind,
        .first_trace = trace,
        .first_event_count = event_count + 1,
        .error_name = if (kind == .non_yielding) "WatchdogStall" else "WatchdogTimeout",
    } };
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
                    .owns_error_name = second_failure.owns_error_name,
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
                    .owns_error_name = first_failure.owns_error_name,
                    .check_name = first_failure.check_name,
                    .owns_check_name = first_failure.owns_check_name,
                } };
            },
            .failed => |second_failure| {
                const traces_reproduced = std.mem.eql(
                    u8,
                    first_failure.first_trace,
                    second_failure.first_trace,
                ) or (first_failure.kind == second_failure.kind and
                    isWatchdogFailure(first_failure.kind) and
                    watchdogTracePrefixesCompatible(
                        first_failure.first_trace,
                        second_failure.first_trace,
                    ));
                const reproduced = first_failure.kind == second_failure.kind and
                    optionalTextEqual(first_failure.error_name, second_failure.error_name) and
                    optionalTextEqual(first_failure.check_name, second_failure.check_name) and
                    traces_reproduced;
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
                    .owns_error_name = first_failure.owns_error_name,
                    .check_name = first_failure.check_name,
                    .owns_check_name = first_failure.owns_check_name,
                    .second_error_name = second_failure.error_name,
                    .owns_second_error_name = second_failure.owns_error_name,
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
) RunError!RunOnceResult {
    var world = try World.init(allocator, options.worldOptions());
    defer world.deinit();
    if (observer) |execution_observer| world.attachExecutionObserver(execution_observer);
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
        const scheduler_failure = state.control().tasks.failure();
        state.deinit();
        state_live = false;
        if (scheduler_failure) |failure| {
            return .{ .failed = try schedulerFailureFromWorld(
                allocator,
                options,
                &world,
                failure,
            ) };
        }
        return .{ .failed = try failureFromWorld(allocator, options, .scenario_error, &world, err, null) };
    };

    if (state.control().tasks.failure()) |failure| {
        state.deinit();
        state_live = false;
        return .{ .failed = try schedulerFailureFromWorld(
            allocator,
            options,
            &world,
            failure,
        ) };
    }

    for (state_checks) |check| {
        check.check(&state) catch |err| {
            const scheduler_failure = state.control().tasks.failure();
            state.deinit();
            state_live = false;
            if (scheduler_failure) |failure| {
                return .{ .failed = try schedulerFailureFromWorld(
                    allocator,
                    options,
                    &world,
                    failure,
                ) };
            }
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

fn schedulerFailureFromWorld(
    allocator: std.mem.Allocator,
    options: RunOptions,
    world: *World,
    failure: @import("io/root.zig").internal.TaskControl.Failure,
) RunError!RunFailure {
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
    if (options.watchdog) |watchdog| {
        try world.recordFields("run.watchdog", &.{
            traceField("stall_timeout_ns", .{ .uint = watchdog.stall_timeout_ns }),
            traceField("run_timeout_ns", .{ .uint = watchdog.run_timeout_ns }),
            traceField("trace_capacity", .{ .uint = @intCast(watchdog.trace_capacity) }),
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
) std.mem.Allocator.Error!RunFailure {
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
        .error_name = error_name,
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

fn runNonYieldingOnMain(_: *SimCase(DeadlockApp)) !void {
    nonYieldingTask();
}

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
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "watchdog.non_yielding task=main") != null);
        },
    }
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
