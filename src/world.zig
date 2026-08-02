//! Deterministic simulation engine state.
//!
//! A `World` owns one fake clock, one seeded PRNG, one trace log, and the
//! registered disk, network, I/O, and scheduler resources for a simulation.

const std = @import("std");

const allocation_module = @import("allocation.zig");
const clock_module = @import("clock.zig");
const disk_module = @import("disk/root.zig");
const env_module = @import("env.zig");
const io_module = @import("io/root.zig");
const network_module = @import("network/root.zig");
const random_module = @import("random.zig");
const scheduler_module = @import("scheduler.zig");

/// Errors returned while writing deterministic trace records.
pub const TraceError = error{
    /// The formatted trace payload is not a valid line-oriented trace event.
    InvalidTracePayload,
};

/// One structured trace field written by `World.recordFields`.
pub const TraceField = struct {
    key: []const u8,
    value: TraceValue,
};

/// Replay-safe scalar trace value.
pub const TraceValue = union(enum) {
    /// Already-encoded stable value text. It is still validated before writing.
    literal: []const u8,
    /// User text encoded with Marionette percent escaping.
    text: []const u8,
    /// User text prefixed by a stable type name, such as `string:<text>`.
    typed_text: TypedText,
    int: i64,
    uint: u64,
    boolean: bool,
    float: f64,

    pub const TypedText = struct {
        type_name: []const u8,
        value: []const u8,
    };
};

/// Build one structured trace field.
pub fn traceField(key: []const u8, value: TraceValue) TraceField {
    return .{ .key = key, .value = value };
}

/// Type-erased logical-process lifecycle callbacks.
///
/// Register one of these with `World.Simulation.registerProcess`. `on_kill`
/// is where harness-owned volatile state is discarded; `restart` is the
/// process initializer rerun after a kill/crash against surviving durable
/// state.
pub const ProcessLifecycle = struct {
    ptr: *anyopaque,
    on_kill: ?*const fn (*anyopaque) void = null,
    restart: *const fn (*anyopaque, env_module.Env) anyerror!void,
};

const TransactionCheckpoint = struct {
    trace_len: usize,
    event_index: u64,
    rng: random_module.Random,
};

/// Internal hooks shared by simulator components and white-box tests.
pub const internal = struct {
    pub fn ioRuntime(sim: World.Simulation) *io_module.internal.ProcessRuntime {
        return sim.ioRuntime();
    }

    pub fn transactionCheckpoint(world: *const World) TransactionCheckpoint {
        return world.transactionCheckpoint();
    }

    pub fn rollbackTransaction(world: *World, checkpoint: TransactionCheckpoint) void {
        world.rollbackTransaction(checkpoint);
    }
};

/// World-owned logical-process lifecycle supervisor.
pub const ProcessSupervisor = struct {
    allocator: std.mem.Allocator,
    world: *World,
    base_env: env_module.Env,
    io_runtime: *io_module.internal.ProcessRuntime,
    lifecycles: []?ProcessLifecycle,
    states: []ProcessState,
    dynamics: []env_module.ProcessDynamicsOptions,
    state_changed_at_ns: []clock_module.Timestamp,
    transition_schedules: []TransitionSchedule,
    last_fault_evolution_ns: clock_module.Timestamp,

    const ProcessState = enum {
        alive,
        killed,
    };

    const TransitionSchedule = union(enum) {
        pending,
        none,
        beyond_clock,
        at: clock_module.Timestamp,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        world: *World,
        base_env: env_module.Env,
        io_runtime: *io_module.internal.ProcessRuntime,
    ) std.mem.Allocator.Error!ProcessSupervisor {
        const process_count = io_runtime.processCount();
        const lifecycles = try allocator.alloc(?ProcessLifecycle, process_count);
        errdefer allocator.free(lifecycles);
        @memset(lifecycles, null);

        const states = try allocator.alloc(ProcessState, process_count);
        errdefer allocator.free(states);
        @memset(states, .alive);

        const dynamics = try allocator.alloc(env_module.ProcessDynamicsOptions, process_count);
        errdefer allocator.free(dynamics);
        @memset(dynamics, .{});

        const state_changed_at_ns = try allocator.alloc(clock_module.Timestamp, process_count);
        errdefer allocator.free(state_changed_at_ns);
        @memset(state_changed_at_ns, world.now());

        const transition_schedules = try allocator.alloc(TransitionSchedule, process_count);
        errdefer allocator.free(transition_schedules);
        @memset(transition_schedules, .pending);

        return .{
            .allocator = allocator,
            .world = world,
            .base_env = base_env,
            .io_runtime = io_runtime,
            .lifecycles = lifecycles,
            .states = states,
            .dynamics = dynamics,
            .state_changed_at_ns = state_changed_at_ns,
            .transition_schedules = transition_schedules,
            .last_fault_evolution_ns = world.now(),
        };
    }

    pub fn deinit(self: *ProcessSupervisor) void {
        self.allocator.free(self.transition_schedules);
        self.allocator.free(self.state_changed_at_ns);
        self.allocator.free(self.dynamics);
        self.allocator.free(self.states);
        self.allocator.free(self.lifecycles);
        self.* = undefined;
    }

    fn control(self: *ProcessSupervisor) env_module.ProcessControl {
        return .{ .ptr = self, .vtable = &process_control_vtable };
    }

    /// Register lifecycle callbacks for one node.
    pub fn registerProcess(
        self: *ProcessSupervisor,
        node: network_module.NodeId,
        lifecycle: ProcessLifecycle,
    ) error{InvalidNode}!void {
        const index = try self.nodeIndex(node);
        self.lifecycles[index] = lifecycle;
    }

    fn setDynamics(
        self: *ProcessSupervisor,
        node: network_module.NodeId,
        options: env_module.ProcessDynamicsOptions,
    ) !void {
        try self.validateDynamics(options);
        const index = try self.nodeIndex(node);
        self.dynamics[index] = options;
        self.transition_schedules[index] = .pending;
        try self.world.record(
            "process.dynamics node={} crash_rate={}/{} restart_rate={}/{} crash_stability_min_ns={} restart_stability_min_ns={}",
            .{
                node,
                options.crash_rate.numerator,
                options.crash_rate.denominator,
                options.restart_rate.numerator,
                options.restart_rate.denominator,
                options.crash_stability_min_ns,
                options.restart_stability_min_ns,
            },
        );
    }

    /// Kill one process's tasks and handles and run its `on_kill` once.
    pub fn killProcess(self: *ProcessSupervisor, node: network_module.NodeId) !void {
        _ = try self.nodeIndex(node);
        try self.io_runtime.kill(node);
        try self.noteKilled(node, "manual");
    }

    /// Rerun one node's registered lifecycle, killing it first if alive.
    pub fn restartProcess(self: *ProcessSupervisor, node: network_module.NodeId) !void {
        try self.restartProcessInternal(node, false);
    }

    /// Restart one process only if it is currently killed; alive processes
    /// keep their current incarnation. Used by the liveness transition.
    fn reviveKilled(self: *ProcessSupervisor, node: network_module.NodeId) !void {
        const index = try self.nodeIndex(node);
        if (self.states[index] != .killed) return;
        try self.restartProcessInternal(node, false);
    }

    fn restartProcessInternal(self: *ProcessSupervisor, node: network_module.NodeId, automatic: bool) !void {
        const index = try self.nodeIndex(node);
        const lifecycle = self.lifecycles[index] orelse return error.ProcessNotRegistered;

        if (self.states[index] == .alive) {
            try self.io_runtime.kill(node);
            try self.noteKilled(node, "restart");
        }

        try self.io_runtime.revive(node);
        errdefer {
            self.io_runtime.kill(node) catch @panic("failed to roll back partial process restart");
            if (lifecycle.on_kill) |on_kill| on_kill(lifecycle.ptr);
        }

        var env = self.base_env;
        env.io_backend = try self.io_runtime.io(node);
        try lifecycle.restart(lifecycle.ptr, env);
        try self.world.recordFields("process.restart", &.{
            traceField("node", .{ .uint = node }),
            traceField("automatic", .{ .boolean = automatic }),
        });
        self.states[index] = .alive;
        self.state_changed_at_ns[index] = self.world.now();
        self.transition_schedules[index] = .pending;
    }

    /// Publish the fallible half of a disk-crash notification before either
    /// disk or process state changes. The enclosing disk transaction rolls
    /// all of these records back if any one fails.
    pub fn prepareDiskCrash(self: *ProcessSupervisor) disk_module.DiskError!void {
        for (self.states, 0..) |state, index| {
            if (state != .alive) continue;
            try self.world.recordFields("process.kill", &.{
                traceField("node", .{ .uint = @intCast(index) }),
                traceField("reason", .{ .literal = "disk_crash" }),
            });
        }
    }

    /// Commit the infallible half of a prepared disk-crash notification.
    pub fn commitDiskCrash(self: *ProcessSupervisor) void {
        self.io_runtime.onDiskCrash();
        for (self.states, 0..) |state, index| {
            if (state != .alive) continue;
            if (self.lifecycles[index]) |lifecycle| {
                if (lifecycle.on_kill) |on_kill| on_kill(lifecycle.ptr);
            }
            self.states[index] = .killed;
            self.state_changed_at_ns[index] = self.world.now();
            self.transition_schedules[index] = .pending;
        }
    }

    fn evolveTickFaults(self: *ProcessSupervisor) !void {
        try self.ensureAutoSchedules();
        try self.fireDueTransitions();
        self.last_fault_evolution_ns = self.world.now();
    }

    fn nextFaultBoundaryBeforeOrAt(self: *ProcessSupervisor, end_ns: clock_module.Timestamp) !?clock_module.Timestamp {
        try self.ensureAutoSchedules();
        var next: ?clock_module.Timestamp = null;
        for (self.transition_schedules) |schedule| {
            const at_ns = switch (schedule) {
                .at => |value| value,
                .pending, .none, .beyond_clock => continue,
            };
            if (at_ns > self.world.now() and at_ns <= end_ns) {
                next = minOptionalTimestamp(next, at_ns);
            }
        }
        return next;
    }

    fn finishRunFor(self: *ProcessSupervisor) !void {
        self.last_fault_evolution_ns = self.world.now();
    }

    fn noteKilled(
        self: *ProcessSupervisor,
        node: network_module.NodeId,
        reason: []const u8,
    ) !void {
        const index = try self.nodeIndex(node);
        if (self.states[index] == .killed) return;

        if (self.lifecycles[index]) |lifecycle| {
            if (lifecycle.on_kill) |on_kill| on_kill(lifecycle.ptr);
        }
        self.states[index] = .killed;
        self.state_changed_at_ns[index] = self.world.now();
        self.transition_schedules[index] = .pending;
        try self.world.recordFields("process.kill", &.{
            traceField("node", .{ .uint = node }),
            traceField("reason", .{ .literal = reason }),
        });
    }

    fn validateDynamics(self: *const ProcessSupervisor, options: env_module.ProcessDynamicsOptions) !void {
        try options.crash_rate.validate();
        try options.restart_rate.validate();
        try self.validateTickAlignedDuration(options.crash_stability_min_ns);
        try self.validateTickAlignedDuration(options.restart_stability_min_ns);
    }

    fn validateTickAlignedDuration(self: *const ProcessSupervisor, duration_ns: clock_module.Duration) error{InvalidDuration}!void {
        if (duration_ns % self.world.clock().tick_ns != 0) return error.InvalidDuration;
    }

    fn ensureAutoSchedules(self: *ProcessSupervisor) !void {
        const now_ns = self.world.now();
        const tick_ns = self.world.clock().tick_ns;
        const from_ns = if (now_ns >= self.last_fault_evolution_ns and now_ns - self.last_fault_evolution_ns == tick_ns)
            self.last_fault_evolution_ns
        else
            now_ns;
        for (self.transition_schedules, 0..) |schedule, index| {
            if (schedule == .pending) {
                try self.scheduleTransitionFrom(index, from_ns);
            }
        }
    }

    fn scheduleTransitionFrom(
        self: *ProcessSupervisor,
        index: usize,
        from_ns: clock_module.Timestamp,
    ) !void {
        const options = self.dynamics[index];
        const rate = switch (self.states[index]) {
            .alive => options.crash_rate,
            .killed => options.restart_rate,
        };
        if (rate.numerator == 0) {
            self.transition_schedules[index] = .none;
            return;
        }

        const stability_ns = switch (self.states[index]) {
            .alive => options.crash_stability_min_ns,
            .killed => options.restart_stability_min_ns,
        };
        const floor_ns = addTimestamp(self.state_changed_at_ns[index], stability_ns) catch {
            self.transition_schedules[index] = .beyond_clock;
            return;
        };
        const eligible_from = if (floor_ns <= from_ns) from_ns else floor_ns - self.world.clock().tick_ns;
        const ticks = try self.sampleNextOccurrenceTicks(rate);
        const at_ns = addDurationTicks(eligible_from, ticks, self.world.clock().tick_ns) catch {
            self.transition_schedules[index] = .beyond_clock;
            return;
        };
        self.transition_schedules[index] = .{ .at = at_ns };
    }

    fn fireDueTransitions(self: *ProcessSupervisor) !void {
        const now_ns = self.world.now();
        for (self.transition_schedules, 0..) |schedule, index| {
            const at_ns = switch (schedule) {
                .at => |value| value,
                .pending, .none, .beyond_clock => continue,
            };
            if (at_ns > now_ns) continue;

            self.transition_schedules[index] = .pending;
            const node: network_module.NodeId = @intCast(index);
            switch (self.states[index]) {
                .alive => {
                    try self.io_runtime.kill(node);
                    try self.noteKilled(node, "auto_crash");
                },
                .killed => {
                    try self.restartProcessInternal(node, true);
                },
            }
        }
    }

    fn sampleNextOccurrenceTicks(self: *ProcessSupervisor, rate: env_module.BuggifyRate) !u64 {
        std.debug.assert(rate.numerator > 0);
        std.debug.assert(rate.numerator <= rate.denominator);
        if (rate.numerator == rate.denominator) return 1;

        const random_space: u64 = 1 << 53;
        const draw = try self.world.randomIntLessThan(u64, random_space);
        const uniform = (@as(f64, @floatFromInt(draw)) + 1.0) / (@as(f64, @floatFromInt(random_space)) + 1.0);
        const failure_probability =
            @as(f64, @floatFromInt(rate.denominator - rate.numerator)) /
            @as(f64, @floatFromInt(rate.denominator));
        const ticks = @ceil(std.math.log(f64, failure_probability, uniform));
        return @max(@as(u64, 1), @as(u64, @intFromFloat(ticks)));
    }

    fn nodeIndex(self: *const ProcessSupervisor, node: network_module.NodeId) error{InvalidNode}!usize {
        const index: usize = @intCast(node);
        if (index >= self.states.len) return error.InvalidNode;
        return index;
    }
};

const process_control_vtable: env_module.ProcessControl.VTable = .{
    .set_dynamics = processControlSetDynamics,
    .kill = processControlKill,
    .restart = processControlRestart,
    .evolve_tick_faults = processControlEvolveAtBoundary,
    .next_fault_boundary_before_or_at = processControlNextBoundaryBeforeOrAt,
    .finish_run_for = processControlFinishRunFor,
};

fn processControl(ptr: *anyopaque) *ProcessSupervisor {
    return @ptrCast(@alignCast(ptr));
}

fn allocationTraceRecord(ptr: *anyopaque, payload: []const u8) !void {
    const world: *World = @ptrCast(@alignCast(ptr));
    try world.recordPayload(payload);
}

fn allocationRandomIntLessThan(ptr: *anyopaque, less_than: u32) !u32 {
    const world: *World = @ptrCast(@alignCast(ptr));
    return try world.randomIntLessThan(u32, less_than);
}

fn processControlSetDynamics(
    ptr: *anyopaque,
    node: network_module.NodeId,
    options: env_module.ProcessDynamicsOptions,
) anyerror!void {
    try processControl(ptr).setDynamics(node, options);
}

fn processControlKill(ptr: *anyopaque, node: network_module.NodeId) anyerror!void {
    try processControl(ptr).killProcess(node);
}

fn processControlRestart(ptr: *anyopaque, node: network_module.NodeId) anyerror!void {
    try processControl(ptr).restartProcess(node);
}

fn processControlEvolveAtBoundary(ptr: *anyopaque) anyerror!void {
    try processControl(ptr).evolveTickFaults();
}

fn processControlNextBoundaryBeforeOrAt(
    ptr: *anyopaque,
    end_ns: clock_module.Timestamp,
) anyerror!?clock_module.Timestamp {
    return try processControl(ptr).nextFaultBoundaryBeforeOrAt(end_ns);
}

fn processControlFinishRunFor(ptr: *anyopaque) anyerror!void {
    try processControl(ptr).finishRunFor();
}

fn addTimestamp(
    timestamp: clock_module.Timestamp,
    duration_ns: clock_module.Duration,
) error{InvalidDuration}!clock_module.Timestamp {
    return std.math.add(clock_module.Timestamp, timestamp, duration_ns) catch error.InvalidDuration;
}

fn addDurationTicks(
    timestamp: clock_module.Timestamp,
    ticks: u64,
    tick_ns: clock_module.Duration,
) error{InvalidDuration}!clock_module.Timestamp {
    const duration_ns = std.math.mul(clock_module.Duration, ticks, tick_ns) catch return error.InvalidDuration;
    return addTimestamp(timestamp, duration_ns);
}

fn minOptionalTimestamp(
    current: ?clock_module.Timestamp,
    candidate: clock_module.Timestamp,
) ?clock_module.Timestamp {
    return if (current) |value| @min(value, candidate) else candidate;
}

/// Write text as an unambiguous trace value fragment.
///
/// Spaces, `=`, `%`, backslash, control bytes, and non-ASCII bytes are encoded
/// as `%HH`. Empty bare text values are rejected because trace values must be
/// non-empty; typed text may pass `allow_empty = true` because the type prefix
/// keeps the final value non-empty.
pub fn writeEscapedTraceText(writer: anytype, bytes: []const u8, allow_empty: bool) TraceError!void {
    if (bytes.len == 0 and !allow_empty) return error.InvalidTracePayload;

    const hex = "0123456789ABCDEF";
    for (bytes) |byte| {
        if (isPlainTraceTextByte(byte)) {
            writer.writeByte(byte) catch return error.InvalidTracePayload;
        } else {
            writer.writeByte('%') catch return error.InvalidTracePayload;
            writer.writeByte(hex[byte >> 4]) catch return error.InvalidTracePayload;
            writer.writeByte(hex[byte & 0x0f]) catch return error.InvalidTracePayload;
        }
    }
}

/// Container for deterministic simulation engine state.
///
/// `World` owns the fake clock, seeded random stream, and trace log used by
/// simulation tests. Application code should usually receive `Env` rather than
/// `World` directly; `World` is the harness-owned engine.
pub const World = struct {
    /// Allocator used for the trace log.
    allocator: std.mem.Allocator,
    /// Fake clock advanced explicitly by the world.
    sim_clock: clock_module.SimClock,
    /// Seeded pseudorandom number generator for reproducible choices.
    rng: random_module.Random,
    /// Byte trace compared by determinism tests.
    trace_log: std.ArrayList(u8),
    /// Next event index to write into the trace.
    event_index: u64,
    /// Whether this world has successfully constructed its simulation.
    simulation_created: bool,
    /// Whether the one-shot liveness transition has already run.
    liveness_transitioned: bool,
    /// Simulator resources owned by the world and torn down in reverse order.
    teardowns: std.ArrayList(Teardown),

    /// Destructor signature for world-owned simulator resources.
    pub const TeardownFn = *const fn (*anyopaque, std.mem.Allocator) void;

    const Teardown = struct {
        ptr: *anyopaque,
        deinit: TeardownFn,
    };

    /// Configuration for a simulation world.
    pub const Options = struct {
        /// Seed for the world's random stream.
        seed: u64,
        /// Initial simulated timestamp in nanoseconds.
        start_ns: clock_module.Timestamp = 0,
        /// Nanoseconds advanced by one world tick.
        tick_ns: clock_module.Duration = clock_module.default_tick_ns,
    };

    /// Construct a world with deterministic time, randomness, and tracing.
    pub fn init(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!World {
        var world: World = .{
            .allocator = allocator,
            .sim_clock = .init(.{
                .start_ns = options.start_ns,
                .tick_ns = options.tick_ns,
            }),
            .rng = .init(options.seed),
            .trace_log = .empty,
            .event_index = 0,
            .simulation_created = false,
            .liveness_transitioned = false,
            .teardowns = .empty,
        };
        errdefer world.deinit();

        try world.trace_log.appendSlice(allocator, "marionette.trace format=text version=2\n");
        world.record(
            "world.init seed={} start_ns={} tick_ns={}",
            .{ options.seed, options.start_ns, options.tick_ns },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTracePayload => unreachable,
        };

        return world;
    }

    /// Release memory owned by the world.
    pub fn deinit(self: *World) void {
        var index = self.teardowns.items.len;
        while (index > 0) {
            index -= 1;
            const teardown = self.teardowns.items[index];
            teardown.deinit(teardown.ptr, self.allocator);
        }
        self.teardowns.deinit(self.allocator);
        self.trace_log.deinit(self.allocator);
        self.* = undefined;
    }

    /// Register a world-owned resource to tear down when the world exits.
    ///
    /// Simulator capabilities use this for stable storage that can be safely
    /// referenced by copied app/control bundles.
    pub fn registerTeardown(
        self: *World,
        ptr: *anyopaque,
        teardown_fn: TeardownFn,
    ) std.mem.Allocator.Error!void {
        try self.teardowns.append(self.allocator, .{
            .ptr = ptr,
            .deinit = teardown_fn,
        });
    }

    /// Tear down and unregister every resource added after `checkpoint`.
    ///
    /// Construction paths use this as a transaction rollback so a failed
    /// composition cannot leave stale world-owned pointers behind.
    fn rollbackTeardowns(self: *World, checkpoint: usize) void {
        std.debug.assert(checkpoint <= self.teardowns.items.len);
        var index = self.teardowns.items.len;
        while (index > checkpoint) {
            index -= 1;
            const teardown = self.teardowns.items[index];
            teardown.deinit(teardown.ptr, self.allocator);
        }
        self.teardowns.shrinkRetainingCapacity(checkpoint);
    }

    /// Static configuration for `World.simulate`, fixed for the life of
    /// the simulation. Runtime fault rates live on `SimControl` instead.
    pub const SimulateOptions = struct {
        allocation: allocation_module.FaultOptions = .{},
        disk: disk_module.DiskOptions = .{},
        network: ?network_module.SimNetworkOptions = null,
        /// Stack size for scheduler-backed `std.Io` tasks. Raise this when a
        /// simulated SUT's call chains outgrow the default; stacks cost
        /// address space, not resident memory, on guard-page targets.
        task_stack_size: usize = scheduler_module.default_task_stack_size,
        /// Maximum seeded initial delay for scheduler-backed tasks, in
        /// nanoseconds. When nonzero, every spawned task draws a uniform
        /// delay in `[0, max]` from the world PRNG and becomes runnable
        /// only after that much virtual time, so seeds explore start
        /// orderings (for example connect-before-listen races) that the
        /// cooperative scheduler otherwise masks structurally. Zero (the
        /// default) consumes no randomness and emits no trace, leaving
        /// existing traces unchanged. Draws are trace-visible as
        /// `scheduler.start_jitter`.
        task_start_jitter_ns: u64 = 0,
        /// Whether a task fiber overflowing its guarded stack produces a
        /// targeted stderr diagnostic (task id, process, configured stack
        /// size, the `task_stack_size` fix) before the fault chains to the
        /// previously installed signal handler. Installs a process-global
        /// `SIGSEGV`/`SIGBUS` handler on first task spawn; embedders that
        /// own their signal dispositions should disable this. POSIX
        /// guard-page targets only; elsewhere it is inert.
        fiber_overflow_diagnostics: bool = true,
    };

    /// The two views over one simulation: the app-facing `env` and the
    /// harness-facing `control`. Returned by `World.simulate`.
    pub const Simulation = struct {
        env: env_module.Env,
        control: env_module.SimControl,

        /// An environment whose `std.Io` is bound to one node's logical
        /// process, so handles and tasks are killed with that process.
        pub fn envForNode(self: Simulation, node: network_module.NodeId) !env_module.Env {
            var env = self.env;
            env.io_backend = try self.ioRuntime().io(node);
            return env;
        }

        /// Open one typed simulated endpoint on `node`. Requires a
        /// configured network (`error.NetworkUnavailable` otherwise).
        pub fn endpoint(self: Simulation, comptime Payload: type, node: network_module.NodeId) !network_module.Endpoint(Payload) {
            return try network_module.internal.endpointFromControl(Payload, self.control.network, node);
        }

        /// Open typed endpoints on `count` consecutive nodes starting at
        /// `first_node`.
        pub fn endpoints(
            self: Simulation,
            comptime Payload: type,
            comptime count: usize,
            first_node: network_module.NodeId,
        ) ![count]network_module.Endpoint(Payload) {
            var handles: [count]network_module.Endpoint(Payload) = undefined;
            for (&handles, 0..) |*endpoint_handle, index| {
                endpoint_handle.* = try self.endpoint(Payload, first_node + @as(network_module.NodeId, @intCast(index)));
            }
            return handles;
        }

        /// Register lifecycle callbacks for one logical process.
        pub fn registerProcess(self: Simulation, node: network_module.NodeId, lifecycle: ProcessLifecycle) !void {
            try self.processSupervisor().registerProcess(node, lifecycle);
        }

        /// Kill one logical process: cancel its scheduler tasks, close its
        /// process-local handles, and run its `on_kill` callback once.
        pub fn killProcess(self: Simulation, node: network_module.NodeId) !void {
            try self.processSupervisor().killProcess(node);
        }

        /// Restart one logical process by rerunning its registered initializer.
        ///
        /// If the process is still alive, it is killed first so restart always
        /// creates a fresh incarnation.
        pub fn restartProcess(self: Simulation, node: network_module.NodeId) !void {
            try self.processSupervisor().restartProcess(node);
        }

        /// One-shot transition into liveness mode, following the VOPR
        /// `transition_to_liveness_mode` shape: zero every probabilistic
        /// simulator fault rate, restore links, clogs, and node state
        /// inside the core, bring killed core processes back up, and leave
        /// non-core failures permanent so a bounded run can prove the core
        /// makes progress.
        ///
        /// A crashed disk restarts before core processes revive. Killed
        /// core processes need a registered lifecycle
        /// (`error.ProcessNotRegistered` otherwise); alive core processes
        /// keep their current incarnation. Core validity and lifecycles
        /// are checked before any state changes, so a failed call leaves
        /// the transition unconsumed and retryable after the harness
        /// corrects it. Harness-owned deterministic
        /// faults stay in place: an armed `crashAfterOps` budget is not
        /// disarmed, and app-level `Env.buggify` rates are the app
        /// harness's own to zero.
        pub fn transitionToLiveness(self: Simulation, core: []const network_module.NodeId) !void {
            const world = self.control.world;
            // Misuse contract: the transition is one-shot; a second call
            // is a harness bug and asserts.
            std.debug.assert(!world.liveness_transitioned);

            // Preflight recoverable errors before consuming the one-shot
            // flag or touching any fault state, so a failed call leaves
            // the simulation unchanged and the transition retryable.
            const supervisor = self.processSupervisor();
            for (core) |node| {
                const index = try supervisor.nodeIndex(node);
                if (supervisor.states[index] == .killed and supervisor.lifecycles[index] == null) {
                    return error.ProcessNotRegistered;
                }
            }
            try world.record("liveness.transition core_count={}", .{core.len});

            // Zero probabilistic rates first so no new fault schedules
            // while the core is restored.
            for (0..supervisor.states.len) |index| {
                try supervisor.setDynamics(@intCast(index), .{});
            }
            try self.control.allocation.setFaults(.{});
            try self.control.disk.setFaults(.{});
            if (network_module.internal.processCountFromControl(self.control.network) != null) {
                try self.control.network.setLossiness(.{});
                try self.control.network.setClogs(.{});
                try self.control.network.setPartitionDynamics(.{});
                try self.control.network.restoreCoreLiveness(core);
            }

            if (self.simDisk().crashed) {
                try self.control.disk.restart();
            }
            for (core) |node| {
                try supervisor.reviveKilled(node);
            }
            world.liveness_transitioned = true;
        }

        fn processSupervisor(self: Simulation) *ProcessSupervisor {
            return @ptrCast(@alignCast(self.control.process.ptr));
        }

        fn simDisk(self: Simulation) *disk_module.SimDisk {
            return @ptrCast(@alignCast(self.control.disk.ptr));
        }

        fn ioRuntime(self: Simulation) *io_module.internal.ProcessRuntime {
            return self.processSupervisor().io_runtime;
        }
    };

    /// Build app and harness views over world-owned simulator resources.
    ///
    /// A world may construct one simulation. Failed construction rolls back
    /// registered resources and leaves the world available for another attempt.
    pub fn simulate(self: *World, options: SimulateOptions) !Simulation {
        if (self.simulation_created) return error.SimulationAlreadyCreated;
        try options.allocation.validate();

        const transaction_checkpoint = self.transactionCheckpoint();
        errdefer self.rollbackTransaction(transaction_checkpoint);

        self.simulation_created = true;
        errdefer self.simulation_created = false;

        const teardown_checkpoint = self.teardowns.items.len;
        errdefer self.rollbackTeardowns(teardown_checkpoint);

        const sim_disk = try self.allocator.create(disk_module.SimDisk);
        var sim_disk_registered = false;
        errdefer if (!sim_disk_registered) self.allocator.destroy(sim_disk);

        sim_disk.* = try disk_module.SimDisk.init(self, options.disk);
        errdefer if (!sim_disk_registered) sim_disk.deinit();

        try self.registerTeardown(sim_disk, deinitSimDisk);
        sim_disk_registered = true;

        const sim_allocation = try self.allocator.create(allocation_module.Authority);
        var sim_allocation_registered = false;
        errdefer if (!sim_allocation_registered) self.allocator.destroy(sim_allocation);

        sim_allocation.* = allocation_module.Authority.init(self.allocator, .{
            .faults = options.allocation,
            .trace = .{ .ptr = self, .record = allocationTraceRecord },
            .random = .{ .ptr = self, .int_less_than = allocationRandomIntLessThan },
        });

        try self.registerTeardown(sim_allocation, deinitAllocationAuthority);
        sim_allocation_registered = true;

        const network_control = if (options.network) |network_options|
            try network_module.internal.initSimControl(self, network_options)
        else
            network_module.AnyNetworkControl.unavailable();
        const process_count = network_module.internal.processCountFromControl(network_control) orelse 1;

        const sim_io = try self.allocator.create(io_module.internal.ProcessRuntime);
        var sim_io_registered = false;
        errdefer if (!sim_io_registered) self.allocator.destroy(sim_io);

        try sim_io.init(self.allocator, self, sim_disk.disk(), sim_disk.sectorSize(), process_count);
        errdefer if (!sim_io_registered) sim_io.deinit();

        try self.registerTeardown(sim_io, io_module.internal.deinitProcessRuntimeOpaque);
        sim_io_registered = true;

        sim_io.attachNetworkControl(network_control);

        // The simulation gets a cooperative scheduler owned by the world,
        // so `Io.async`, `Io.concurrent`, and scheduler-backed waits (futex,
        // net, sleep) work out of the box without caller setup.
        const scheduler = try self.allocator.create(scheduler_module.TaskScheduler);
        var scheduler_registered = false;
        errdefer if (!scheduler_registered) self.allocator.destroy(scheduler);

        scheduler.* = scheduler_module.TaskScheduler.init(self.allocator, self);
        scheduler.task_stack_size = options.task_stack_size;
        scheduler.task_start_jitter_ns = options.task_start_jitter_ns;
        scheduler.overflow_diagnostics = options.fiber_overflow_diagnostics;
        errdefer if (!scheduler_registered) scheduler.deinit();

        try self.registerTeardown(scheduler, scheduler_module.deinitTaskSchedulerOpaque);
        scheduler_registered = true;

        sim_io.attachFutexWaitSet(scheduler_module.futexWaitSet(scheduler));
        sim_io.attachTaskRuntime(scheduler_module.taskRuntime(scheduler));
        sim_io.attachProcessTaskControl(scheduler_module.processTaskControl(scheduler));
        network_module.internal.attachStreamWaitObserverFromControl(
            network_control,
            io_module.internal.streamWaitObserver(sim_io),
        );
        sim_disk.attachLatencyRuntime(scheduler_module.diskLatencyRuntime(scheduler));

        const base_env: env_module.Env = .{
            .io_backend = try sim_io.io(0),
            .memory = sim_allocation.allocator(),
            .disk = sim_disk.disk(),
            .tracer = env_module.Tracer.fromWorld(self),
            .buggify_enabled = true,
        };

        const process_supervisor = try self.allocator.create(ProcessSupervisor);
        var process_supervisor_registered = false;
        errdefer if (!process_supervisor_registered) self.allocator.destroy(process_supervisor);

        process_supervisor.* = try ProcessSupervisor.init(self.allocator, self, base_env, sim_io);
        errdefer if (!process_supervisor_registered) process_supervisor.deinit();

        try self.registerTeardown(process_supervisor, deinitProcessSupervisorOpaque);
        process_supervisor_registered = true;

        sim_disk.setCrashObserver(.{
            .ptr = process_supervisor,
            .prepare = prepareProcessSupervisorDiskCrashOpaque,
            .commit = commitProcessSupervisorDiskCrashOpaque,
        });

        const control: env_module.SimControl = .{
            .allocation = sim_allocation.control(),
            .disk = sim_disk.control(),
            .network = network_control,
            .process = process_supervisor.control(),
            .tasks = scheduler_module.taskControl(scheduler),
            .world = self,
        };
        scheduler.attachFaultEvolution(control.faultEvolution());

        return .{
            .env = base_env,
            .control = control,
        };
    }

    fn deinitAllocationAuthority(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const authority: *allocation_module.Authority = @ptrCast(@alignCast(ptr));
        allocator.destroy(authority);
    }

    fn deinitSimDisk(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const sim_disk: *disk_module.SimDisk = @ptrCast(@alignCast(ptr));
        sim_disk.deinit();
        allocator.destroy(sim_disk);
    }

    fn deinitProcessSupervisorOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const process_supervisor: *ProcessSupervisor = @ptrCast(@alignCast(ptr));
        process_supervisor.deinit();
        allocator.destroy(process_supervisor);
    }

    fn prepareProcessSupervisorDiskCrashOpaque(ptr: *anyopaque) disk_module.DiskError!void {
        const process_supervisor: *ProcessSupervisor = @ptrCast(@alignCast(ptr));
        try process_supervisor.prepareDiskCrash();
    }

    fn commitProcessSupervisorDiskCrashOpaque(ptr: *anyopaque) void {
        const process_supervisor: *ProcessSupervisor = @ptrCast(@alignCast(ptr));
        process_supervisor.commitDiskCrash();
    }

    /// Return the world's simulated clock.
    ///
    /// Application code should read time through `std.Io.Clock` over
    /// `Env.io()`. This is a low-level world authority for harnesses and
    /// simulator internals.
    pub fn clock(self: *World) *clock_module.SimClock {
        return &self.sim_clock;
    }

    /// Return an untraced raw `std.Random` view over the world's seeded PRNG.
    ///
    /// This is useful for code that needs the full `std.Random` API, but
    /// individual draws through the returned value are not automatically
    /// traced. Prefer `randomU64()`, `randomBool()`, or `randomIntLessThan()`
    /// for simulator choices.
    pub fn unsafeUntracedRandom(self: *World) std.Random {
        return self.rng.random();
    }

    /// Draw a traced `u64` from the world's seeded random stream.
    pub fn randomU64(self: *World) !u64 {
        const rng_before = self.rng;
        errdefer self.rng = rng_before;
        const value = self.rng.random().int(u64);
        try self.record("world.random_u64 value={}", .{value});
        return value;
    }

    /// Draw a traced boolean from the world's seeded random stream.
    pub fn randomBool(self: *World) !bool {
        const rng_before = self.rng;
        errdefer self.rng = rng_before;
        const value = self.rng.random().boolean();
        try self.record("world.random_bool value={}", .{value});
        return value;
    }

    /// Draw a traced unbiased integer in the range `0 <= value < less_than`.
    pub fn randomIntLessThan(self: *World, comptime T: type, less_than: T) !T {
        const rng_before = self.rng;
        errdefer self.rng = rng_before;
        const value = self.rng.random().intRangeLessThan(T, 0, less_than);
        try self.record(
            "world.random_int_less_than type={s} less_than={} value={}",
            .{ @typeName(T), less_than, value },
        );
        return value;
    }

    /// Snapshot the trace and seeded-choice state for a larger simulator
    /// transaction. Callers that perform several traced choices before one
    /// externally visible commit use this to make the entire sequence
    /// retryable after trace or allocator failure.
    fn transactionCheckpoint(self: *const World) TransactionCheckpoint {
        return .{
            .trace_len = self.trace_log.items.len,
            .event_index = self.event_index,
            .rng = self.rng,
        };
    }

    /// Roll back a checkpoint created by `transactionCheckpoint`.
    fn rollbackTransaction(self: *World, checkpoint: TransactionCheckpoint) void {
        std.debug.assert(checkpoint.trace_len <= self.trace_log.items.len);
        self.trace_log.shrinkRetainingCapacity(checkpoint.trace_len);
        self.event_index = checkpoint.event_index;
        self.rng = checkpoint.rng;
    }

    /// Advance the world by one simulation tick.
    pub fn tick(self: *World) !void {
        const now_before = self.now();
        errdefer self.sim_clock.now_ns = now_before;
        self.sim_clock.tick();
        try self.record("world.tick now_ns={}", .{self.now()});
    }

    /// Advance the world by a duration measured in nanoseconds.
    ///
    /// `duration_ns` must be an exact multiple of the world's tick size.
    pub fn runFor(self: *World, duration_ns: clock_module.Duration) !void {
        const start_ns = self.now();
        errdefer self.sim_clock.now_ns = start_ns;
        self.sim_clock.runFor(duration_ns);
        try self.record(
            "world.run_for start_ns={} duration_ns={} end_ns={}",
            .{ start_ns, duration_ns, self.now() },
        );
    }

    /// Return the world's current simulated timestamp in nanoseconds.
    pub fn now(self: *const World) clock_module.Timestamp {
        return self.sim_clock.now();
    }

    /// Append one line to the world's trace.
    ///
    /// The format string should not include a trailing newline; `record`
    /// adds one so trace records stay line-oriented and comparable.
    pub fn record(self: *World, comptime fmt: []const u8, args: anytype) (std.mem.Allocator.Error || TraceError)!void {
        const start_len = self.trace_log.items.len;
        errdefer self.trace_log.shrinkRetainingCapacity(start_len);

        try self.trace_log.print(self.allocator, "event={} ", .{self.event_index});
        const payload_start = self.trace_log.items.len;
        try self.trace_log.print(self.allocator, fmt, args);
        if (!isValidTracePayload(self.trace_log.items[payload_start..])) {
            return error.InvalidTracePayload;
        }
        try self.trace_log.append(self.allocator, '\n');
        self.event_index += 1;
    }

    /// Append two trace records as one transaction. If either record fails,
    /// neither remains visible and the next event index is restored.
    pub fn recordPair(
        self: *World,
        comptime first_fmt: []const u8,
        first_args: anytype,
        comptime second_fmt: []const u8,
        second_args: anytype,
    ) (std.mem.Allocator.Error || TraceError)!void {
        const start_len = self.trace_log.items.len;
        const start_event_index = self.event_index;
        errdefer {
            self.trace_log.shrinkRetainingCapacity(start_len);
            self.event_index = start_event_index;
        }

        try self.record(first_fmt, first_args);
        try self.record(second_fmt, second_args);
    }

    /// Append one preformatted line to the world's trace.
    ///
    /// This is for type-erased callbacks that cannot take a comptime format
    /// string. The payload still uses the same trace validation as `record`.
    pub fn recordPayload(self: *World, payload: []const u8) (std.mem.Allocator.Error || TraceError)!void {
        const start_len = self.trace_log.items.len;
        errdefer self.trace_log.shrinkRetainingCapacity(start_len);

        if (!isValidTracePayload(payload)) return error.InvalidTracePayload;
        try self.trace_log.print(self.allocator, "event={} ", .{self.event_index});
        try self.trace_log.appendSlice(self.allocator, payload);
        try self.trace_log.append(self.allocator, '\n');
        self.event_index += 1;
    }

    /// Append one event with structured fields.
    ///
    /// Text values are percent-encoded so caller-provided strings can appear in
    /// traces without breaking the line-oriented parser.
    pub fn recordFields(
        self: *World,
        name: []const u8,
        fields: []const TraceField,
    ) (std.mem.Allocator.Error || TraceError)!void {
        const start_len = self.trace_log.items.len;
        errdefer self.trace_log.shrinkRetainingCapacity(start_len);

        if (!isValidTraceName(name)) return error.InvalidTracePayload;

        try self.trace_log.print(self.allocator, "event={} {s}", .{ self.event_index, name });
        for (fields) |field| {
            if (!isValidTraceKey(field.key)) return error.InvalidTracePayload;

            try self.trace_log.print(self.allocator, " {s}=", .{field.key});
            try self.writeTraceValue(field.value);
        }
        try self.trace_log.append(self.allocator, '\n');
        self.event_index += 1;
    }

    /// Return the trace bytes recorded so far.
    ///
    /// The returned slice is invalidated by later trace writes.
    pub fn traceBytes(self: *const World) []const u8 {
        return self.trace_log.items;
    }

    /// Return the index that will be assigned to the next trace event.
    pub fn nextEventIndex(self: *const World) u64 {
        return self.event_index;
    }

    fn writeTraceValue(self: *World, value: TraceValue) (std.mem.Allocator.Error || TraceError)!void {
        switch (value) {
            .literal => |literal| {
                if (!isValidTraceValue(literal)) return error.InvalidTracePayload;
                try self.trace_log.appendSlice(self.allocator, literal);
            },
            .text => |text| try self.appendEscapedTraceText(text, false),
            .typed_text => |typed| {
                if (!isValidTraceValue(typed.type_name)) return error.InvalidTracePayload;
                try self.trace_log.print(self.allocator, "{s}:", .{typed.type_name});
                try self.appendEscapedTraceText(typed.value, true);
            },
            .int => |int| try self.trace_log.print(self.allocator, "{}", .{int}),
            .uint => |uint| try self.trace_log.print(self.allocator, "{}", .{uint}),
            .boolean => |boolean| try self.trace_log.print(self.allocator, "{}", .{boolean}),
            .float => |float| try self.trace_log.print(self.allocator, "{d}", .{float}),
        }
    }

    fn appendEscapedTraceText(
        self: *World,
        bytes: []const u8,
        allow_empty: bool,
    ) (std.mem.Allocator.Error || TraceError)!void {
        if (bytes.len == 0 and !allow_empty) return error.InvalidTracePayload;

        const hex = "0123456789ABCDEF";
        for (bytes) |byte| {
            if (isPlainTraceTextByte(byte)) {
                try self.trace_log.append(self.allocator, byte);
            } else {
                try self.trace_log.append(self.allocator, '%');
                try self.trace_log.append(self.allocator, hex[byte >> 4]);
                try self.trace_log.append(self.allocator, hex[byte & 0x0f]);
            }
        }
    }
};

fn isPlainTraceTextByte(byte: u8) bool {
    if (byte <= ' ' or byte >= 0x7f) return false;
    return switch (byte) {
        '=', '%', '\\' => false,
        else => true,
    };
}

pub fn isValidTracePayload(payload: []const u8) bool {
    if (payload.len == 0) return false;
    if (payload[0] == ' ' or payload[payload.len - 1] == ' ') return false;

    var fields = std.mem.splitScalar(u8, payload, ' ');
    const name = fields.next() orelse return false;
    if (!isValidTraceName(name)) return false;

    while (fields.next()) |field| {
        if (field.len == 0) return false;

        const equals_index = std.mem.indexOfScalar(u8, field, '=') orelse return false;
        if (std.mem.indexOfScalar(u8, field[equals_index + 1 ..], '=') != null) return false;

        const key = field[0..equals_index];
        const value = field[equals_index + 1 ..];
        if (!isValidTraceKey(key) or !isValidTraceValue(value)) return false;
    }

    return true;
}

fn isValidTraceName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| {
        switch (char) {
            'a'...'z', '0'...'9', '_', '.' => {},
            else => return false,
        }
    }
    return true;
}

fn isValidTraceKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |char| {
        switch (char) {
            'a'...'z', '0'...'9', '_' => {},
            else => return false,
        }
    }
    return true;
}

fn isValidTraceValue(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |char| {
        switch (char) {
            ' ', '=', '\n', '\r', '\t', '\\' => return false,
            else => {},
        }
    }
    return true;
}

test "world: trace payload validation rejects ambiguous fields" {
    try std.testing.expect(isValidTracePayload("request.accepted id=42"));
    try std.testing.expect(isValidTracePayload("buggify hook=drop_packet rate=20/100 roll=73 fired=false"));

    try std.testing.expect(!isValidTracePayload("request accepted id=42"));
    try std.testing.expect(!isValidTracePayload("request.accepted message=hello world"));
    try std.testing.expect(!isValidTracePayload("request.accepted message=a=b"));
    try std.testing.expect(!isValidTracePayload("request.accepted message=line\nbreak"));
    try std.testing.expect(!isValidTracePayload("request.accepted path=C:\\tmp"));
}

fn simulateAllocationFailureSweep(allocator: std.mem.Allocator) !void {
    var world = try World.init(allocator, .{ .seed = 0xA110C });
    defer world.deinit();

    _ = try world.simulate(.{
        .network = .{
            .nodes = 2,
            .path_capacity = 4,
        },
    });
}

test "world: simulate rolls back teardown registrations on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        simulateAllocationFailureSweep,
        .{},
    );
}

test "world: failed simulation construction leaves the world retryable" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0x51A });
    defer world.deinit();

    const teardown_checkpoint = world.teardowns.items.len;
    const trace_checkpoint = try std.testing.allocator.dupe(u8, world.traceBytes());
    defer std.testing.allocator.free(trace_checkpoint);
    const event_checkpoint = world.nextEventIndex();
    try std.testing.expectError(
        error.InvalidNode,
        world.simulate(.{ .network = .{ .nodes = 0 } }),
    );
    try std.testing.expectEqual(teardown_checkpoint, world.teardowns.items.len);
    try std.testing.expect(!world.simulation_created);
    try std.testing.expectEqualStrings(trace_checkpoint, world.traceBytes());
    try std.testing.expectEqual(event_checkpoint, world.nextEventIndex());

    _ = try world.simulate(.{});
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, world.traceBytes(), " disk.model "),
    );
    const before_teardown_count = world.teardowns.items.len;
    const before_now = world.now();
    var expected_rng = world.rng;

    try std.testing.expectError(error.SimulationAlreadyCreated, world.simulate(.{}));
    try std.testing.expectEqual(before_teardown_count, world.teardowns.items.len);
    try std.testing.expectEqual(before_now, world.now());
    try std.testing.expectEqual(
        expected_rng.random().int(u64),
        world.rng.random().int(u64),
    );
}

test "world: owns seeded random and simulated clock" {
    var a = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer b.deinit();

    try a.tick();
    try b.tick();

    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), a.now());
    try std.testing.expectEqual(a.now(), b.now());

    const random_a = a.unsafeUntracedRandom();
    const random_b = b.unsafeUntracedRandom();
    for (0..128) |_| {
        try std.testing.expectEqual(random_a.int(u64), random_b.int(u64));
    }
}

test "world: runFor advances whole simulated ticks" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0, .tick_ns = 3 });
    defer world.deinit();

    try world.runFor(12);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 12), world.now());
}

test "world: trace records deterministic actions" {
    var world = try World.init(std.testing.allocator, .{
        .seed = 0xC0FFEE,
        .start_ns = 5,
        .tick_ns = 2,
    });
    defer world.deinit();

    try world.tick();
    try world.runFor(4);
    try world.record("service.allowed request_id={}", .{7});

    try std.testing.expectEqualStrings(
        \\marionette.trace format=text version=2
        \\event=0 world.init seed=12648430 start_ns=5 tick_ns=2
        \\event=1 world.tick now_ns=7
        \\event=2 world.run_for start_ns=7 duration_ns=4 end_ns=11
        \\event=3 service.allowed request_id=7
        \\
    , world.traceBytes());
}

test "world: same seed and actions produce identical traces" {
    var a = try World.init(std.testing.allocator, .{ .seed = 42, .tick_ns = 10 });
    defer a.deinit();
    var b = try World.init(std.testing.allocator, .{ .seed = 42, .tick_ns = 10 });
    defer b.deinit();

    try a.tick();
    try b.tick();

    _ = try a.randomU64();
    _ = try b.randomU64();

    try a.record("service.count value={}", .{3});
    try b.record("service.count value={}", .{3});

    try std.testing.expectEqualStrings(a.traceBytes(), b.traceBytes());
}

test "world: randomIntLessThan records unbiased bounded draws" {
    var world = try World.init(std.testing.allocator, .{ .seed = 99 });
    defer world.deinit();

    for (0..128) |_| {
        const value = try world.randomIntLessThan(u64, 1_000_000);
        try std.testing.expect(value < 1_000_000);
    }
}

const TracedChoice = enum { integer, boolean, bounded };

fn drawTracedChoice(world: *World, choice: TracedChoice) !u64 {
    return switch (choice) {
        .integer => try world.randomU64(),
        .boolean => @intFromBool(try world.randomBool()),
        .bounded => try world.randomIntLessThan(u64, 1_000_000),
    };
}

fn fillTraceCapacity(world: *World) !void {
    try world.trace_log.appendNTimes(
        world.allocator,
        0,
        world.trace_log.capacity - world.trace_log.items.len,
    );
}

test "world: trace allocation failure rolls back random draws" {
    for (std.enums.values(TracedChoice)) |choice| {
        var expected = try World.init(std.testing.allocator, .{ .seed = 0xA110C });
        defer expected.deinit();
        const expected_value = try drawTracedChoice(&expected, choice);

        var world = try World.init(std.testing.allocator, .{ .seed = 0xA110C });
        defer world.deinit();
        try fillTraceCapacity(&world);

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        world.allocator = failing.allocator();
        try std.testing.expectError(error.OutOfMemory, drawTracedChoice(&world, choice));
        world.allocator = std.testing.allocator;

        try std.testing.expectEqual(expected_value, try drawTracedChoice(&world, choice));
    }
}

test "world: recordPair rolls back both records when the second allocation fails" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0xA70C });
    defer world.deinit();

    // Leave room for the short first record while forcing the much larger
    // second record to grow the trace buffer.
    const first_record_room = 32;
    try world.trace_log.appendNTimes(
        world.allocator,
        0,
        world.trace_log.capacity - world.trace_log.items.len - first_record_room,
    );
    const trace_before = try std.testing.allocator.dupe(u8, world.traceBytes());
    defer std.testing.allocator.free(trace_before);
    const event_before = world.nextEventIndex();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    world.allocator = failing.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        world.recordPair("first", .{}, "second payload={s}", .{"x" ** 1024}),
    );
    world.allocator = std.testing.allocator;

    try std.testing.expectEqualStrings(trace_before, world.traceBytes());
    try std.testing.expectEqual(event_before, world.nextEventIndex());
    try world.record("retry", .{});
    try std.testing.expectEqual(event_before + 1, world.nextEventIndex());
}

test "world: trace allocation failure rolls back clock movement" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0xA110C, .tick_ns = 10 });
    defer world.deinit();
    try fillTraceCapacity(&world);

    var tick_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    world.allocator = tick_failing.allocator();
    try std.testing.expectError(error.OutOfMemory, world.tick());
    try std.testing.expectEqual(@as(clock_module.Timestamp, 0), world.now());

    world.allocator = std.testing.allocator;
    try fillTraceCapacity(&world);
    var run_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    world.allocator = run_failing.allocator();
    try std.testing.expectError(error.OutOfMemory, world.runFor(20));
    try std.testing.expectEqual(@as(clock_module.Timestamp, 0), world.now());
    world.allocator = std.testing.allocator;
}

test "world: failed record rolls back bytes and event index" {
    var buffer: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);

    var world = try World.init(fixed.allocator(), .{ .seed = 99 });
    defer world.deinit();

    const before_trace = try std.testing.allocator.dupe(u8, world.traceBytes());
    defer std.testing.allocator.free(before_trace);
    const before_event_index = world.nextEventIndex();

    var large_value: [512]u8 = undefined;
    @memset(&large_value, 'a');

    try std.testing.expectError(
        error.OutOfMemory,
        world.record("service.large value={s}", .{large_value[0..]}),
    );
    try std.testing.expectEqual(before_event_index, world.nextEventIndex());
    try std.testing.expectEqualStrings(before_trace, world.traceBytes());
}

test "world: invalid trace payload returns error and rolls back" {
    var world = try World.init(std.testing.allocator, .{ .seed = 99 });
    defer world.deinit();

    const before_trace = try std.testing.allocator.dupe(u8, world.traceBytes());
    defer std.testing.allocator.free(before_trace);
    const before_event_index = world.nextEventIndex();

    try std.testing.expectError(
        error.InvalidTracePayload,
        world.record("service.message value={s}", .{"hello world"}),
    );
    try std.testing.expectEqual(before_event_index, world.nextEventIndex());
    try std.testing.expectEqualStrings(before_trace, world.traceBytes());
}

test "world: structured fields escape ambiguous text bytes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 99 });
    defer world.deinit();

    try world.recordFields("service.path", &.{
        traceField("path", .{ .text = "a b=c%\\\n" }),
        traceField("label", .{ .typed_text = .{ .type_name = "string", .value = "" } }),
    });

    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "service.path path=a%20b%3Dc%25%5C%0A label=string:",
    ) != null);
}

test "world: empty bare structured text rolls back" {
    var world = try World.init(std.testing.allocator, .{ .seed = 99 });
    defer world.deinit();

    const before_trace = try std.testing.allocator.dupe(u8, world.traceBytes());
    defer std.testing.allocator.free(before_trace);
    const before_event_index = world.nextEventIndex();

    try std.testing.expectError(
        error.InvalidTracePayload,
        world.recordFields("service.path", &.{
            traceField("path", .{ .text = "" }),
        }),
    );
    try std.testing.expectEqual(before_event_index, world.nextEventIndex());
    try std.testing.expectEqualStrings(before_trace, world.traceBytes());
}
