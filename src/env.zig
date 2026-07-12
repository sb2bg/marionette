//! Composition-root environment for production and simulation authorities.
//!
//! Application code should receive an environment from its caller instead of
//! auto-detecting whether it is running in production or simulation.

const std = @import("std");

const allocation_module = @import("allocation.zig");
const clock_module = @import("clock.zig");
const disk_module = @import("disk/root.zig");
const fault_module = @import("fault.zig");
const fault_evolution_module = @import("fault_evolution.zig");
const io_task_module = @import("io/task.zig");
const network_io_module = @import("network/io.zig");
const network_module = @import("network/root.zig");
const world_module = @import("world.zig");
const World = world_module.World;

pub const ClockError = std.mem.Allocator.Error || world_module.TraceError;
pub const RandomError = std.mem.Allocator.Error || world_module.TraceError;
pub const TracerError = std.mem.Allocator.Error || world_module.TraceError;

pub const BuggifyError = fault_module.BuggifyError;
pub const BuggifyRate = fault_module.BuggifyRate;
pub const AllocationFaultOptions = allocation_module.FaultOptions;
pub const AllocationStats = allocation_module.Stats;
pub const AllocationControl = allocation_module.Control;

/// Per-node automatic crash/restart rates, applied through
/// `SimControl.process.setDynamics` and evolved at simulated-time fault
/// boundaries. Zero rates schedule nothing and consume no randomness.
pub const ProcessDynamicsOptions = struct {
    /// Per-tick chance that an alive process is killed.
    crash_rate: BuggifyRate = .never(),
    /// Per-tick chance that a killed process reruns its registered lifecycle.
    restart_rate: BuggifyRate = .never(),
    /// Minimum simulated time a process stays alive before an automatic
    /// crash may fire. Must be tick-aligned.
    crash_stability_min_ns: clock_module.Duration = 0,
    /// Minimum simulated time a process stays killed before an automatic
    /// restart may fire. Must be tick-aligned.
    restart_stability_min_ns: clock_module.Duration = 0,
};

/// App-facing time authority. Simulation clocks read and advance the
/// world's virtual time; production clocks read host time.
pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now: *const fn (*anyopaque) clock_module.Timestamp,
        sleep: *const fn (*anyopaque, clock_module.Duration) ClockError!void,
    };

    /// Current timestamp in nanoseconds: virtual time in simulation,
    /// host monotonic time in production.
    pub fn now(self: Clock) clock_module.Timestamp {
        return self.vtable.now(self.ptr);
    }

    /// Sleep for `duration_ns`. In simulation this advances virtual time
    /// (rounded up to the clock's tick resolution) without blocking the
    /// host; in production it blocks the calling thread.
    pub fn sleep(self: Clock, duration_ns: clock_module.Duration) ClockError!void {
        try self.vtable.sleep(self.ptr, duration_ns);
    }

    /// Build the simulation clock view over a world's virtual time.
    pub fn fromWorld(world: *World) Clock {
        return .{ .ptr = world, .vtable = &world_clock_vtable };
    }

    /// Build the production clock view over host time.
    pub fn fromProduction(clock: *clock_module.ProductionClock) Clock {
        return .{ .ptr = clock, .vtable = &production_clock_vtable };
    }

    const world_clock_vtable: VTable = .{
        .now = worldClockNow,
        .sleep = worldClockSleep,
    };

    const production_clock_vtable: VTable = .{
        .now = productionClockNow,
        .sleep = productionClockSleep,
    };

    fn worldClock(ptr: *anyopaque) *World {
        return @ptrCast(@alignCast(ptr));
    }

    fn productionClock(ptr: *anyopaque) *clock_module.ProductionClock {
        return @ptrCast(@alignCast(ptr));
    }

    fn worldClockNow(ptr: *anyopaque) clock_module.Timestamp {
        return worldClock(ptr).now();
    }

    fn worldClockSleep(ptr: *anyopaque, duration_ns: clock_module.Duration) ClockError!void {
        const world = worldClock(ptr);
        try world.runFor(world.clock().ceilDuration(duration_ns));
    }

    fn productionClockNow(ptr: *anyopaque) clock_module.Timestamp {
        return productionClock(ptr).now();
    }

    fn productionClockSleep(ptr: *anyopaque, duration_ns: clock_module.Duration) ClockError!void {
        productionClock(ptr).sleep(duration_ns);
    }
};

/// App-facing randomness authority. Simulation draws come from the world's
/// seeded stream and are traced for replay; production draws come from host
/// entropy and are untraced.
pub const Random = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        random_u64: *const fn (*anyopaque) RandomError!u64,
        boolean: *const fn (*anyopaque) RandomError!bool,
        int_less_than_u64: *const fn (*anyopaque, u64) RandomError!u64,
    };

    /// Draw a `u64` from this environment's random authority.
    ///
    /// Simulation draws come from the world's seeded stream and are traced;
    /// production draws come from host entropy and are untraced.
    pub fn randomU64(self: Random) RandomError!u64 {
        return self.vtable.random_u64(self.ptr);
    }

    /// Draw a boolean from this environment's random authority.
    ///
    /// Simulation draws come from the world's seeded stream and are traced;
    /// production draws come from host entropy and are untraced.
    pub fn boolean(self: Random) RandomError!bool {
        return self.vtable.boolean(self.ptr);
    }

    /// Draw an unbiased integer in the range `0 <= value < less_than`.
    pub fn intLessThan(self: Random, comptime T: type, less_than: T) RandomError!T {
        const value = try self.vtable.int_less_than_u64(self.ptr, @intCast(less_than));
        return @intCast(value);
    }

    /// Build the simulation random view over a world's seeded stream.
    pub fn fromWorld(world: *World) Random {
        return .{ .ptr = world, .vtable = &world_random_vtable };
    }

    /// Build the production random view over a host entropy source.
    pub fn fromProduction(source: *std.Random.IoSource) Random {
        return .{ .ptr = source, .vtable = &production_random_vtable };
    }

    const world_random_vtable: VTable = .{
        .random_u64 = worldRandomU64,
        .boolean = worldRandomBool,
        .int_less_than_u64 = worldRandomIntLessThanU64,
    };

    const production_random_vtable: VTable = .{
        .random_u64 = productionRandomU64,
        .boolean = productionRandomBool,
        .int_less_than_u64 = productionRandomIntLessThanU64,
    };

    fn worldRandom(ptr: *anyopaque) *World {
        return @ptrCast(@alignCast(ptr));
    }

    fn productionRandom(ptr: *anyopaque) *std.Random.IoSource {
        return @ptrCast(@alignCast(ptr));
    }

    fn worldRandomU64(ptr: *anyopaque) RandomError!u64 {
        return worldRandom(ptr).randomU64();
    }

    fn worldRandomBool(ptr: *anyopaque) RandomError!bool {
        return worldRandom(ptr).randomBool();
    }

    fn worldRandomIntLessThanU64(ptr: *anyopaque, less_than: u64) RandomError!u64 {
        return worldRandom(ptr).randomIntLessThan(u64, less_than);
    }

    fn productionRandomU64(ptr: *anyopaque) RandomError!u64 {
        return productionRandom(ptr).interface().int(u64);
    }

    fn productionRandomBool(ptr: *anyopaque) RandomError!bool {
        return productionRandom(ptr).interface().boolean();
    }

    fn productionRandomIntLessThanU64(ptr: *anyopaque, less_than: u64) RandomError!u64 {
        return productionRandom(ptr).interface().intRangeLessThan(u64, 0, less_than);
    }
};

/// App-facing trace authority. Simulation tracers append to the world's
/// deterministic byte trace; production tracers drop everything.
pub const Tracer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        should_record: *const fn (*anyopaque) bool,
        allocator: ?*const fn (*anyopaque) std.mem.Allocator,
        record_payload: *const fn (*anyopaque, []const u8) TracerError!void,
    };

    /// A tracer that records nothing and formats nothing.
    pub fn none() Tracer {
        return .{ .ptr = &noop_tracer_ctx, .vtable = &noop_tracer_vtable };
    }

    /// Build the simulation tracer over a world's byte trace.
    pub fn fromWorld(world: *World) Tracer {
        return .{ .ptr = world, .vtable = &world_tracer_vtable };
    }

    /// Format and append one trace event. Payloads must follow the trace
    /// format contract (`docs/trace-format.md`); a disabled tracer skips
    /// formatting entirely.
    pub fn record(self: Tracer, comptime fmt: []const u8, args: anytype) TracerError!void {
        if (!self.vtable.should_record(self.ptr)) return;
        const allocator = self.vtable.allocator.?(self.ptr);
        const payload = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(payload);
        try self.vtable.record_payload(self.ptr, payload);
    }

    const world_tracer_vtable: VTable = .{
        .should_record = worldTracerShouldRecord,
        .allocator = worldTracerAllocator,
        .record_payload = worldTracerRecordPayload,
    };

    const noop_tracer_vtable: VTable = .{
        .should_record = noopTracerShouldRecord,
        .allocator = null,
        .record_payload = noopTracerRecordPayload,
    };

    fn worldTracer(ptr: *anyopaque) *World {
        return @ptrCast(@alignCast(ptr));
    }

    fn worldTracerShouldRecord(_: *anyopaque) bool {
        return true;
    }

    fn worldTracerAllocator(ptr: *anyopaque) std.mem.Allocator {
        return worldTracer(ptr).allocator;
    }

    fn worldTracerRecordPayload(ptr: *anyopaque, payload: []const u8) TracerError!void {
        try worldTracer(ptr).recordPayload(payload);
    }

    fn noopTracerShouldRecord(_: *anyopaque) bool {
        return false;
    }

    fn noopTracerRecordPayload(_: *anyopaque, _: []const u8) TracerError!void {}
};

/// Thin app-facing wrapper over `Tracer` for user service events.
pub const Recorder = struct {
    tracer: Tracer,

    /// A recorder that drops everything.
    pub fn none() Recorder {
        return .{ .tracer = .none() };
    }

    /// Wrap an existing tracer.
    pub fn fromTracer(tracer: Tracer) Recorder {
        return .{ .tracer = tracer };
    }

    /// Format and append one user trace event.
    pub fn record(self: Recorder, comptime fmt: []const u8, args: anytype) TracerError!void {
        try self.tracer.record(fmt, args);
    }
};

var noop_tracer_ctx: u8 = 0;

/// The capability bundle handed to application code: I/O, allocation, disk,
/// clock, randomness, and tracing, each backed by simulation or production
/// authorities without the app knowing which. See the API doc's `Env`
/// section for the full contract.
pub const Env = struct {
    io_backend: std.Io = .failing,
    memory: std.mem.Allocator,
    disk: disk_module.Disk,
    clock: Clock,
    random: Random,
    tracer: Tracer,
    buggify_enabled: bool = false,

    /// Return the std.Io backing this environment.
    ///
    /// Production envs return their host `std.Io`. Simulation envs return
    /// Marionette's current deterministic `std.Io` backend.
    pub fn io(self: Env) std.Io {
        return self.io_backend;
    }

    /// Return the app-facing allocator backing this environment.
    ///
    /// Production envs return the caller-provided allocator. Simulation envs
    /// return a deterministic allocation authority that can inject and trace
    /// modeled app OOMs without using addresses in the trace.
    pub fn allocator(self: Env) std.mem.Allocator {
        return self.memory;
    }

    pub fn recorder(self: Env) Recorder {
        return .fromTracer(self.tracer);
    }

    pub fn record(self: Env, comptime fmt: []const u8, args: anytype) !void {
        try self.recorder().record(fmt, args);
    }

    /// Draw and trace a simulation-only fault hook.
    ///
    /// User code places these hooks at domain-specific fault points. The
    /// simulator owns the randomness and records the decision so failures are
    /// replayable. Production envs always return false.
    pub fn buggify(self: Env, comptime hook: anytype, rate: BuggifyRate) !bool {
        if (!self.buggify_enabled) {
            _ = hookName(hook);
            return false;
        }
        try rate.validate();
        // Disabled-fault convention: a zero rate consumes no randomness and
        // emits no trace, matching the disk model's `rollFault`. Toggling a
        // fault off therefore never shifts unrelated draws through hooks
        // that would have rolled zero.
        if (rate.numerator == 0) return false;

        const roll = try self.random.intLessThan(u32, rate.denominator);
        const fired = roll < rate.numerator;
        try self.record(
            "buggify hook={s} rate={}/{} roll={} fired={}",
            .{ hookName(hook), rate.numerator, rate.denominator, roll, fired },
        );
        return fired;
    }
};

/// Composition root for production capabilities: host I/O, a real disk
/// rooted below a caller-owned directory, host clock and entropy, and
/// socket-backed endpoints. `env()` returns the app-facing view.
pub const Production = struct {
    allocator: std.mem.Allocator,
    io_backend: std.Io,
    disk: disk_module.RealDisk,
    clock: clock_module.ProductionClock,
    random_source: std.Random.IoSource,
    tracer: Tracer,
    network_io: network_io_module.Host,
    network_entries: std.ArrayList(network_module.internal.ProductionNetworkEntry) = .empty,

    pub const Options = struct {
        allocator: std.mem.Allocator,
        /// Root directory that production disk paths are resolved beneath.
        /// The caller owns this directory and must keep it alive.
        root_dir: std.Io.Dir,
        /// Host I/O backend used by production capabilities.
        io: std.Io,
        disk: disk_module.RealDisk.Options = .{},
        tracer: ?Tracer = null,
    };

    /// Construct production capabilities over host resources. The caller
    /// keeps `options.root_dir` alive for the lifetime of the value.
    pub fn init(options: Options) disk_module.DiskError!Production {
        return .{
            .allocator = options.allocator,
            .io_backend = options.io,
            .disk = try disk_module.RealDisk.init(options.root_dir, options.io, options.disk),
            .clock = .init(options.io),
            .random_source = .{ .io = options.io },
            .tracer = options.tracer orelse .none(),
            .network_io = .init(options.allocator, options.io),
        };
    }

    /// Open one typed production endpoint. Teardown is owned by this
    /// `Production` and runs in `deinit`.
    pub fn endpoint(
        self: *Production,
        comptime Payload: type,
        options: network_module.ProductionEndpointOptions,
    ) network_module.ProductionNetworkError!network_module.Endpoint(Payload) {
        return try network_module.internal.productionEndpoint(Payload, self.allocator, &self.network_entries, options);
    }

    /// Open one byte-payload production endpoint. Teardown is owned by
    /// this `Production` and runs in `deinit`.
    pub fn byteEndpoint(
        self: *Production,
        options: network_module.ProductionEndpointOptions,
    ) network_module.ProductionByteEndpointError!network_module.ByteEndpoint {
        return try network_module.internal.productionByteEndpoint(self.allocator, self.network_io.io(), &self.network_entries, options);
    }

    /// Open `count` typed production endpoints on consecutive node ids
    /// starting at `options.first_node`.
    pub fn endpoints(
        self: *Production,
        comptime Payload: type,
        comptime count: usize,
        options: network_module.ProductionEndpointsOptions,
    ) network_module.ProductionNetworkError![count]network_module.Endpoint(Payload) {
        var handles: [count]network_module.Endpoint(Payload) = undefined;
        for (&handles, 0..) |*endpoint_handle, index| {
            endpoint_handle.* = try self.endpoint(Payload, .{
                .self = options.first_node + @as(network_module.NodeId, @intCast(index)),
                .peers = options.peers,
            });
        }
        return handles;
    }

    /// Open `count` byte-payload production endpoints on consecutive node
    /// ids starting at `options.first_node`.
    pub fn byteEndpoints(
        self: *Production,
        comptime count: usize,
        options: network_module.ProductionEndpointsOptions,
    ) network_module.ProductionByteEndpointError![count]network_module.ByteEndpoint {
        var handles: [count]network_module.ByteEndpoint = undefined;
        for (&handles, 0..) |*endpoint_handle, index| {
            endpoint_handle.* = try self.byteEndpoint(.{
                .self = options.first_node + @as(network_module.NodeId, @intCast(index)),
                .peers = options.peers,
            });
        }
        return handles;
    }

    /// Return the app-facing environment over these production
    /// capabilities. `Env.buggify` hooks never fire in production.
    pub fn env(self: *Production) Env {
        return .{
            .io_backend = self.io_backend,
            .memory = self.allocator,
            .disk = self.disk.disk(),
            .clock = .fromProduction(&self.clock),
            .random = .fromProduction(&self.random_source),
            .tracer = self.tracer,
        };
    }

    /// Tear down endpoints in reverse open order, then the disk.
    pub fn deinit(self: *Production) void {
        var index = self.network_entries.items.len;
        while (index > 0) {
            index -= 1;
            const teardown = self.network_entries.items[index].teardown;
            teardown.deinit(teardown.ptr, self.allocator);
        }
        self.network_entries.deinit(self.allocator);
        self.disk.deinit();
        self.* = undefined;
    }
};

/// Simulator-control view over logical process lifecycles. Obtained as
/// `sim.control.process`; invalid nodes return `error.InvalidNode`.
pub const ProcessControl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        set_dynamics: *const fn (*anyopaque, network_module.NodeId, ProcessDynamicsOptions) anyerror!void,
        kill: *const fn (*anyopaque, network_module.NodeId) anyerror!void,
        restart: *const fn (*anyopaque, network_module.NodeId) anyerror!void,
        evolve_tick_faults: *const fn (*anyopaque) anyerror!void,
        next_fault_boundary_before_or_at: *const fn (*anyopaque, clock_module.Timestamp) anyerror!?clock_module.Timestamp,
        finish_run_for: *const fn (*anyopaque) anyerror!void,
    };

    /// Configure automatic crash/restart rates for one node. Replaces any
    /// previous dynamics and reschedules from the current time. Invalid
    /// rates return `error.InvalidRate`; misaligned stability durations
    /// return `error.InvalidDuration`. Traced as `process.dynamics`.
    pub fn setDynamics(self: ProcessControl, node: network_module.NodeId, options: ProcessDynamicsOptions) !void {
        try self.vtable.set_dynamics(self.ptr, node, options);
    }

    /// Kill one logical process: cancel its scheduler tasks, close its
    /// process-local handles, and run its `on_kill` callback once. Killing
    /// an already-killed process is a no-op. Traced as `process.kill`.
    pub fn kill(self: ProcessControl, node: network_module.NodeId) !void {
        try self.vtable.kill(self.ptr, node);
    }

    /// Restart one logical process by rerunning its registered lifecycle;
    /// an alive process is killed first so restart always creates a fresh
    /// incarnation. Returns `error.ProcessNotRegistered` without a
    /// registered lifecycle. Traced as `process.restart`.
    pub fn restart(self: ProcessControl, node: network_module.NodeId) !void {
        try self.vtable.restart(self.ptr, node);
    }

    fn faultEvolutionParticipant(self: ProcessControl) fault_evolution_module.Participant {
        return .{
            .ptr = self.ptr,
            .evolve_at_boundary = self.vtable.evolve_tick_faults,
            .next_boundary_before_or_at = self.vtable.next_fault_boundary_before_or_at,
            .finish_run_for = self.vtable.finish_run_for,
        };
    }
};

/// Narrow time authority shared by harness-driven and scheduler-driven clock
/// jumps so automatic faults evolve identically regardless of who advances
/// the clock.
pub const FaultEvolutionControl = struct {
    network: network_module.AnyNetworkControl,
    process: ProcessControl,
    world: *World,

    pub fn runFor(self: FaultEvolutionControl, duration_ns: clock_module.Duration) !void {
        const tick_ns = self.world.clock().tick_ns;
        std.debug.assert(duration_ns % tick_ns == 0);
        if (duration_ns == 0) return;

        const end_ns = std.math.add(clock_module.Timestamp, self.world.now(), duration_ns) catch
            @panic("simulated duration exceeds clock range");
        try self.evolveAtCurrentBoundary();
        while (try self.nextBoundaryBeforeOrAt(end_ns)) |boundary_ns| {
            if (boundary_ns > self.world.now()) {
                try self.world.runFor(boundary_ns - self.world.now());
            }
            try self.evolveAtCurrentBoundary();
        }

        if (end_ns > self.world.now()) {
            try self.world.runFor(end_ns - self.world.now());
            try self.evolveAtCurrentBoundary();
        }
        for (self.participants()) |participant| {
            try participant.finishRunFor();
        }
    }

    /// Advance toward `end_ns`, stopping after the first automatic-fault
    /// boundary. Returns whether the requested end was reached. The scheduler
    /// uses this to run tasks made ready by a fault transition before time
    /// advances again.
    pub fn advanceOneBoundaryToward(
        self: FaultEvolutionControl,
        end_ns: clock_module.Timestamp,
        current_boundary_evolved: bool,
    ) !bool {
        const now_ns = self.world.now();
        std.debug.assert(end_ns > now_ns);
        std.debug.assert((end_ns - now_ns) % self.world.clock().tick_ns == 0);

        if (!current_boundary_evolved) try self.evolveAtCurrentBoundary();
        const target_ns = (try self.nextBoundaryBeforeOrAt(end_ns)) orelse end_ns;
        if (target_ns > self.world.now()) {
            try self.world.runFor(target_ns - self.world.now());
        }
        try self.evolveAtCurrentBoundary();

        const reached_end = target_ns == end_ns;
        if (reached_end) {
            for (self.participants()) |participant| {
                try participant.finishRunFor();
            }
        }
        return reached_end;
    }

    fn participants(self: FaultEvolutionControl) [2]fault_evolution_module.Participant {
        return .{
            network_module.internal.faultEvolutionParticipantFromControl(self.network),
            self.process.faultEvolutionParticipant(),
        };
    }

    fn evolveAtCurrentBoundary(self: FaultEvolutionControl) !void {
        try self.world.record("fault_evolution.boundary now_ns={}", .{self.world.now()});
        for (self.participants()) |participant| {
            try participant.evolveAtBoundary();
        }
    }

    fn nextBoundaryBeforeOrAt(self: FaultEvolutionControl, end_ns: clock_module.Timestamp) !?clock_module.Timestamp {
        var next: ?clock_module.Timestamp = null;
        for (self.participants()) |participant| {
            const candidate = (try participant.nextBoundaryBeforeOrAt(end_ns)) orelse continue;
            next = minOptionalTimestamp(next, candidate);
        }
        return next;
    }
};

/// Harness-facing simulator controls: time movement plus the fault
/// authorities for allocation, disk, network, processes, and tasks.
/// Application code receives `Env` instead and never sees this.
pub const SimControl = struct {
    allocation: allocation_module.Control,
    disk: disk_module.DiskControl,
    network: network_module.AnyNetworkControl,
    process: ProcessControl,
    tasks: io_task_module.TaskControl,
    world: *World,

    /// Advance simulated time by one tick, then evolve time-based faults
    /// at the new boundary.
    pub fn tick(self: SimControl) !void {
        try self.world.tick();
        try self.faultEvolution().evolveAtCurrentBoundary();
    }

    /// Run scheduled `Io.async`/`Io.concurrent` tasks until none is
    /// runnable. Returns `error.Deadlock` when blocked tasks remain; use
    /// this instead of awaiting a future the scenario expects to strand.
    pub fn runTasksUntilIdle(self: SimControl) !void {
        try self.tasks.runUntilIdle();
    }

    /// Count of scheduler tasks currently blocked on a wait key or timer.
    pub fn blockedTaskCount(self: SimControl) usize {
        return self.tasks.blockedCount();
    }

    /// Advance simulated time by `duration_ns`, stopping at every
    /// scheduled fault boundary so time-based faults fire at their exact
    /// timestamps. The duration must be a whole number of ticks; a
    /// misaligned duration asserts as harness misuse.
    pub fn runFor(self: SimControl, duration_ns: clock_module.Duration) !void {
        // Misuse contract: like `World.runFor` and `SimClock.runFor`, a
        // duration that is not a whole number of ticks is a harness bug and
        // asserts instead of returning an error.
        try self.faultEvolution().runFor(duration_ns);
    }

    pub fn faultEvolution(self: SimControl) FaultEvolutionControl {
        return .{
            .network = self.network,
            .process = self.process,
            .world = self.world,
        };
    }
};

fn minOptionalTimestamp(
    current: ?clock_module.Timestamp,
    candidate: clock_module.Timestamp,
) ?clock_module.Timestamp {
    return if (current) |value| @min(value, candidate) else candidate;
}

fn hookName(comptime hook: anytype) []const u8 {
    const Hook = @TypeOf(hook);
    return switch (@typeInfo(Hook)) {
        .enum_literal, .@"enum" => @tagName(hook),
        else => @compileError("buggify hook must be an enum literal or enum value"),
    };
}

test "env: simulation routes through world capabilities" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    try sim.control.tick();
    _ = try sim.env.random.intLessThan(u64, 100);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), sim.env.clock.now());
    _ = sim.env.io();
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.tick now_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.random_int_less_than") != null);
}

test "env: simulation clock sleep rounds up to tick resolution" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    try sim.env.clock.sleep(15);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 20), sim.env.clock.now());
    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "world.run_for start_ns=0 duration_ns=20 end_ns=20",
    ) != null);
}

test "env: simulation runFor without network jumps time in one event" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    try sim.control.runFor(1_000);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 1_000), world.now());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.run_for start_ns=0 duration_ns=1000 end_ns=1000") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, world.traceBytes(), "world.tick"));
}

test "env: simulation runFor zero duration is a no-op" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    try sim.control.runFor(0);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 0), world.now());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, world.traceBytes(), "world.run_for"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, world.traceBytes(), "world.tick"));
}

test "env: recorder is a narrow trace capability" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const recorder = sim.env.recorder();

    try recorder.record("recorder.message value={}", .{42});
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "recorder.message value=42") != null);
}

test "env: simulation exposes allocation authority" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .allocation = .{ .fail_after = 1 } });
    const allocator = sim.env.allocator();

    const first = try allocator.alloc(u8, 16);
    defer allocator.free(first);

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    const stats = sim.control.allocation.stats();

    try std.testing.expectEqual(@as(usize, 1), stats.successful_allocations);
    try std.testing.expectEqual(@as(usize, 16), stats.live_bytes);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "allocation.alloc op=0 len=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "allocation.alloc op=1 len=1 align=1 status=fail reason=fail_after") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "0x") == null);
}

test "env: allocation control updates runtime fault options" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const allocator = sim.env.allocator();

    const first = try allocator.alloc(u8, 4);
    allocator.free(first);

    try sim.control.allocation.setFaults(.{ .quota_bytes = 4 });
    const second = try allocator.alloc(u8, 4);
    defer allocator.free(second);

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "status=fail reason=quota") != null);
}

test "env: simulation rejects invalid allocation buggify rates" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    try std.testing.expectError(
        error.InvalidRate,
        world.simulate(.{ .allocation = .{ .buggify_rate = .{ .numerator = 1, .denominator = 0 } } }),
    );
    try std.testing.expect(!world.simulation_created);
}

test "env: simulation exposes app-facing disk operations" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{ .disk = .{
        .sector_size = 4,
        .min_latency_ns = 1,
    } });
    try sim.env.disk.write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = "abcd",
    });

    var buffer: [4]u8 = @splat(0);
    try sim.env.disk.read(.{
        .path = "wal.log",
        .offset = 0,
        .buffer = &buffer,
    });

    try std.testing.expectEqualStrings("abcd", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.write op=0 path=wal.log offset=0 len=4 status=ok latency_ns=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "disk.read op=1 path=wal.log offset=0 len=4 status=ok latency_ns=1") != null);
}

test "env: production exposes production authorities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var production = try Production.init(.{
        .allocator = std.testing.allocator,
        .root_dir = tmp.dir,
        .io = std.testing.io,
        .disk = .{ .sector_size = 4 },
    });
    defer production.deinit();

    const env = production.env();

    _ = env.io();
    const memory = try env.allocator().alloc(u8, 4);
    defer env.allocator().free(memory);
    _ = env.clock.now();
    _ = try env.random.intLessThan(u8, 10);
    try env.disk.write(.{ .path = "prod/wal.log", .offset = 0, .bytes = "abcd" });
    try env.disk.sync(.{ .path = "prod/wal.log" });
    var buffer: [4]u8 = @splat(0);
    try env.disk.read(.{ .path = "prod/wal.log", .offset = 0, .buffer = &buffer });
    try std.testing.expectEqualStrings("abcd", &buffer);
    try std.testing.expect(!try env.buggify(.drop_packet, .percent(50)));
}

test "env: production byte endpoints use loopback sockets when listen is configured" {
    var server_tmp = std.testing.tmpDir(.{});
    defer server_tmp.cleanup();
    var client_tmp = std.testing.tmpDir(.{});
    defer client_tmp.cleanup();

    var server = try Production.init(.{
        .allocator = std.testing.allocator,
        .root_dir = server_tmp.dir,
        .io = std.testing.io,
    });
    defer server.deinit();

    var client = try Production.init(.{
        .allocator = std.testing.allocator,
        .root_dir = client_tmp.dir,
        .io = std.testing.io,
    });
    defer client.deinit();

    const peers = [_]network_module.ProductionPeer{
        .{ .id = 0, .address = "127.0.0.1:43158" },
        .{ .id = 1, .address = "127.0.0.1:43159" },
    };

    const server_endpoint = server.byteEndpoint(.{
        .self = 0,
        .peers = &peers,
        .listen = peers[0].address,
    }) catch |err| switch (err) {
        error.AddressInUse, error.NetworkUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };

    const client_endpoint = client.byteEndpoint(.{
        .self = 1,
        .peers = &peers,
        .listen = peers[1].address,
    }) catch |err| switch (err) {
        error.AddressInUse, error.NetworkUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };

    try client_endpoint.send(0, "sock");
    const envelope = (try server_endpoint.receive()).?;
    defer envelope.message.release();

    try std.testing.expectEqual(@as(network_module.NodeId, 1), envelope.from);
    try std.testing.expectEqualStrings("sock", envelope.message.bytes());
}

test "env: simulation buggify is traced" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    _ = try sim.env.buggify(.drop_packet, .percent(20));

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.random_int_less_than type=u64 less_than=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "buggify hook=drop_packet rate=20/100 roll=") != null);
}

test "env: world rejects a second simulation without changing trace state" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0x51A });
    defer world.deinit();

    _ = try world.simulate(.{});
    const before_trace = try std.testing.allocator.dupe(u8, world.traceBytes());
    defer std.testing.allocator.free(before_trace);
    const before_event_index = world.nextEventIndex();

    try std.testing.expectError(error.SimulationAlreadyCreated, world.simulate(.{}));
    try std.testing.expectEqual(before_event_index, world.nextEventIndex());
    try std.testing.expectEqualStrings(before_trace, world.traceBytes());
}

test "env: buggify accepts typed enum hooks" {
    const Hook = enum { drop_packet };

    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    _ = try sim.env.buggify(Hook.drop_packet, .percent(20));

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "buggify hook=drop_packet") != null);
}

test "env: buggify supports always and never rates" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});

    try std.testing.expect(try sim.env.buggify(.always_fault, .always()));
    try std.testing.expect(!try sim.env.buggify(.never_fault, .never()));
}

test "env: simulation buggify rejects invalid runtime rates" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});

    try std.testing.expectError(
        error.InvalidRate,
        sim.env.buggify(.bad_rate, .{ .numerator = 1, .denominator = 0 }),
    );
    try std.testing.expectError(
        error.InvalidRate,
        sim.env.buggify(.bad_rate, .{ .numerator = 2, .denominator = 1 }),
    );
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.random_int_less_than") == null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "buggify hook=bad_rate") == null);
}
