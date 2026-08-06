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
const network_module = @import("network/root.zig");
const world_module = @import("world.zig");
const World = world_module.World;

const RecorderError = std.mem.Allocator.Error || world_module.TraceError;

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

/// Narrow app-facing trace capability. Simulation recorders append to the
/// world's deterministic trace; production recorders may be disabled.
pub const Recorder = struct {
    world: ?*World,

    /// A recorder that drops everything.
    pub fn none() Recorder {
        return .{ .world = null };
    }

    /// Build a recorder over a world's byte trace.
    pub fn fromWorld(world: *World) Recorder {
        return .{ .world = world };
    }

    /// Format and append one user trace event.
    pub fn record(self: Recorder, comptime fmt: []const u8, args: anytype) RecorderError!void {
        if (self.world) |world| try world.record(fmt, args);
    }
};

/// The capability bundle handed to application code. `io_backend` is the
/// authority for I/O, clocks, sleeps, and randomness; allocation, modeled
/// disk operations, and tracing remain explicit sibling capabilities.
pub const Env = struct {
    io_backend: std.Io = .failing,
    memory: std.mem.Allocator,
    disk: disk_module.Disk,
    trace: Recorder,
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
        return self.trace;
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

        var source: std.Random.IoSource = .{ .io = self.io() };
        const roll: u32 = @intCast(source.interface().intRangeLessThan(
            u64,
            0,
            rate.denominator,
        ));
        const fired = roll < rate.numerator;
        try self.record(
            "buggify hook={s} rate={}/{} roll={} fired={}",
            .{ hookName(hook), rate.numerator, rate.denominator, roll, fired },
        );
        return fired;
    }
};

/// Composition root for production capabilities: host I/O, a real disk
/// rooted below a caller-owned directory, allocation, and tracing.
/// `env()` returns the app-facing view.
pub const Production = struct {
    allocator: std.mem.Allocator,
    io_backend: std.Io,
    disk: disk_module.RealDisk,
    recorder: Recorder,

    pub const Options = struct {
        allocator: std.mem.Allocator,
        /// Root directory that production disk paths are resolved beneath.
        /// The caller owns this directory and must keep it alive.
        root_dir: std.Io.Dir,
        /// Host I/O backend used by production capabilities.
        io: std.Io,
        disk: disk_module.RealDisk.Options = .{},
        recorder: ?Recorder = null,
    };

    /// Construct production capabilities over host resources. The caller
    /// keeps `options.root_dir` alive for the lifetime of the value.
    pub fn init(options: Options) disk_module.DiskError!Production {
        return .{
            .allocator = options.allocator,
            .io_backend = options.io,
            .disk = try disk_module.RealDisk.init(options.root_dir, options.io, options.disk),
            .recorder = options.recorder orelse .none(),
        };
    }

    /// Return the app-facing environment over these production
    /// capabilities. `Env.buggify` hooks never fire in production.
    pub fn env(self: *Production) Env {
        return .{
            .io_backend = self.io_backend,
            .memory = self.allocator,
            .disk = self.disk.disk(),
            .trace = self.recorder,
        };
    }

    /// Tear down production capabilities.
    pub fn deinit(self: *Production) void {
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
    var random_source: std.Random.IoSource = .{ .io = sim.env.io() };
    _ = random_source.interface().intRangeLessThan(u64, 0, 100);

    try std.testing.expectEqual(
        @as(i96, 10),
        std.Io.Clock.awake.now(sim.env.io()).nanoseconds,
    );
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.tick now_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "io.random len=8 digest=") != null);
}

test "env: simulation clock sleep rounds up to tick resolution" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    try std.Io.sleep(sim.env.io(), .fromNanoseconds(15), .awake);

    try std.testing.expectEqual(
        @as(i96, 20),
        std.Io.Clock.awake.now(sim.env.io()).nanoseconds,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        world.traceBytes(),
        "world.run_for start_ns=0 duration_ns=20 end_ns=20",
    ) != null);
}

test "env: simulation clock sleep runs tasks and automatic fault boundaries" {
    if (!@import("fiber.zig").supported) return error.SkipZigTest;

    const State = struct {
        world: *World,
        io: std.Io,
        woke_at_ns: ?clock_module.Timestamp = null,

        fn sleeper(self: *@This()) void {
            std.Io.sleep(self.io, .fromNanoseconds(20), .awake) catch
                @panic("background sleep failed");
            self.woke_at_ns = self.world.now();
        }
    };

    var world = try World.init(std.testing.allocator, .{ .seed = 0xC10C, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .service_nodes = 2, .path_capacity = 4 },
    });
    try sim.control.process.setDynamics(1, .{
        .crash_rate = .always(),
        .crash_stability_min_ns = 10,
    });

    var state: State = .{ .world = &world, .io = sim.env.io() };
    var future = std.Io.async(state.io, State.sleeper, .{&state});

    try std.Io.sleep(sim.env.io(), .fromNanoseconds(40), .awake);
    future.await(state.io);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 40), world.now());
    try std.testing.expectEqual(@as(?clock_module.Timestamp, 20), state.woke_at_ns);
    const trace = world.traceBytes();
    const process_kill = std.mem.indexOf(u8, trace, "process.kill node=1 reason=auto_crash").?;
    const task_timeout = std.mem.indexOf(u8, trace, "scheduler.timeout task=0 deadline_ns=20").?;
    try std.testing.expect(process_kill < task_timeout);
}

test "env: killed node clock rejects sleep through stale capability" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0xC10D, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2 } });
    const node_env = try sim.envForNode(1);
    try sim.killProcess(1);

    try std.testing.expectError(
        error.Canceled,
        std.Io.sleep(node_env.io(), .fromNanoseconds(10), .awake),
    );
    try std.testing.expectEqual(@as(clock_module.Timestamp, 0), world.now());
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
    _ = std.Io.Clock.awake.now(env.io());
    var random_source: std.Random.IoSource = .{ .io = env.io() };
    _ = random_source.interface().intRangeLessThan(u8, 0, 10);
    try env.disk.write(.{ .path = "prod/wal.log", .offset = 0, .bytes = "abcd" });
    try env.disk.sync(.{ .path = "prod/wal.log" });
    var buffer: [4]u8 = @splat(0);
    try env.disk.read(.{ .path = "prod/wal.log", .offset = 0, .buffer = &buffer });
    try std.testing.expectEqualStrings("abcd", &buffer);
    try std.testing.expect(!try env.buggify(.drop_packet, .percent(50)));
}

test "env: simulation buggify is traced" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    _ = try sim.env.buggify(.drop_packet, .percent(20));

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "io.random len=8 digest=") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "io.random") == null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "buggify hook=bad_rate") == null);
}
