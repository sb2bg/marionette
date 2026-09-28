//! Logical-process supervision and world-owned volatile application state.
//! World constructs the supervisor; simulation entry points delegate here.
const std = @import("std");
const clock_module = @import("clock.zig");
const disk_module = @import("disk/root.zig");
const env_module = @import("env.zig");
const io_module = @import("io/root.zig");
const network_module = @import("network/root.zig");
const world_module = @import("world.zig");
const World = world_module.World;
const traceField = world_module.traceField;

/// Type-erased logical-process lifecycle callbacks.
///
/// Register one of these with `World.Simulation.registerProcess`. `on_kill`
/// is where harness-owned volatile state is discarded; `restart` is the
/// process initializer rerun after a kill/crash against surviving durable
/// state.
pub const ProcessLifecycle = struct {
    ptr: *anyopaque,
    cleanup_at_run_end: bool = false,
    on_kill: ?*const fn (*anyopaque) void = null,
    restart: *const fn (*anyopaque, env_module.Env) anyerror!void,
};

/// World-owned volatile application state for one logical process. A successful
/// reopen publishes a whole new App; kill and failed restart clear it once.
pub fn ManagedProcess(comptime App: type) type {
    return struct {
        const Self = @This();
        app: ?App = null,
        initialize: *const fn (env_module.Env) anyerror!App,
        runtime: *io_module.internal.ProcessRuntime,
        node: network_module.NodeId,

        pub fn state(self: *Self) ?*App {
            return if (self.app) |*value| value else null;
        }
        fn killed(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.app) |*value| {
                if (@hasDecl(App, "deinit")) value.deinit();
                self.app = null;
            }
        }
        fn reopened(ptr: *anyopaque, env: env_module.Env) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const fresh = try self.initialize(env);
            self.app = fresh;
        }
        fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            // Stop every task before freeing the state it may reference.
            if (self.app != null) self.runtime.kill(self.node) catch unreachable;
            killed(ptr);
            allocator.destroy(self);
        }
    };
}

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

    pub fn control(self: *ProcessSupervisor) env_module.ProcessControl {
        return .{ .ptr = self, .vtable = &process_control_vtable };
    }

    /// Own volatile app state and publish its lifecycle only after initialization.
    pub fn manageProcess(self: *ProcessSupervisor, comptime App: type, node: network_module.NodeId, comptime initialize: fn (env_module.Env) anyerror!App, base_env: env_module.Env) !*ManagedProcess(App) {
        const index = try self.nodeIndex(node);
        if (self.lifecycles[index] != null) return error.ProcessAlreadyRegistered;
        const world = self.world;
        const managed = try world.allocator.create(ManagedProcess(App));
        errdefer world.allocator.destroy(managed);
        managed.* = .{ .initialize = initialize, .runtime = self.io_runtime, .node = node };
        // Reserve ownership before initialization can start tasks. No
        // allocation may fail between publishing App and its lifecycle.
        const teardown_index = world.teardowns.items.len;
        try world.registerTeardown(managed, ManagedProcess(App).destroy);
        errdefer _ = world.teardowns.orderedRemove(teardown_index);
        managed.app = try initialize(try self.environmentForNode(base_env, node));
        // Initializers may register dependencies: destroy App before them.
        const teardown = world.teardowns.orderedRemove(teardown_index);
        world.teardowns.appendAssumeCapacity(teardown);
        // Registration cannot fail after validating the node above.
        self.lifecycles[index] = .{ .ptr = managed, .cleanup_at_run_end = true, .on_kill = ManagedProcess(App).killed, .restart = ManagedProcess(App).reopened };
        return managed;
    }

    fn environmentForNode(self: *ProcessSupervisor, base_env: env_module.Env, node: network_module.NodeId) !env_module.Env {
        var env = base_env;
        env.io_backend = try self.io_runtime.io(node);
        return env;
    }

    /// Finish owned lifecycles before runner trace capture and resource checks.
    pub fn finishManagedProcesses(self: *ProcessSupervisor) (std.mem.Allocator.Error || world_module.TraceError)!void {
        for (self.lifecycles, 0..) |maybe_lifecycle, index| {
            const lifecycle = maybe_lifecycle orelse continue;
            if (!lifecycle.cleanup_at_run_end or self.states[index] == .killed) continue;
            self.killProcess(@intCast(index)) catch |err| switch (err) {
                error.InvalidNode => unreachable,
                else => |failure| return failure,
            };
        }
    }

    pub fn validateCore(self: *const ProcessSupervisor, core: []const network_module.NodeId) !void {
        for (core) |node| {
            const index = try self.nodeIndex(node);
            if (self.states[index] == .killed and self.lifecycles[index] == null) return error.ProcessNotRegistered;
        }
    }

    pub fn disableDynamics(self: *ProcessSupervisor) !void {
        for (0..self.states.len) |index| try self.setDynamics(@intCast(index), .{});
    }

    pub fn reviveCore(self: *ProcessSupervisor, core: []const network_module.NodeId) !void {
        for (core) |node| try self.reviveKilled(node);
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
        const ticks = switch (self.states[index]) {
            .alive => try self.sampleNextOccurrenceTicks("process.crash_schedule", rate),
            .killed => try self.sampleNextOccurrenceTicks("process.restart_schedule", rate),
        };
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

    fn sampleNextOccurrenceTicks(
        self: *ProcessSupervisor,
        comptime site_id: []const u8,
        rate: env_module.BuggifyRate,
    ) !u64 {
        std.debug.assert(rate.numerator > 0);
        std.debug.assert(rate.numerator <= rate.denominator);
        if (rate.numerator == rate.denominator) return 1;

        const random_space: u64 = 1 << 53;
        const draw = try self.world.chooseIntLessThan(
            site_id,
            u64,
            random_space,
        );
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
    .check_resources = processControlCheckResources,
};

fn processControlCheckResources(ptr: *anyopaque) anyerror!void {
    const supervisor = processControl(ptr);
    const checkpoint = world_module.internal.transactionCheckpoint(supervisor.world);
    supervisor.io_runtime.checkResources() catch |err| {
        if (err != error.ResourceLeak) world_module.internal.rollbackTransaction(supervisor.world, checkpoint);
        return err;
    };
}

fn processControl(ptr: *anyopaque) *ProcessSupervisor {
    return @ptrCast(@alignCast(ptr));
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
