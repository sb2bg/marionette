//! Composition-root environment for production and simulation authorities.
//!
//! Application code should receive an environment from its caller instead of
//! auto-detecting whether it is running in production or simulation.

const std = @import("std");

const clock_module = @import("clock.zig");
const disk_module = @import("disk.zig");
const network_module = @import("network.zig");
const world_module = @import("world.zig");
const World = world_module.World;

pub const ClockError = std.mem.Allocator.Error || world_module.TraceError;
pub const RandomError = std.mem.Allocator.Error || world_module.TraceError;
pub const TracerError = std.mem.Allocator.Error || world_module.TraceError;

pub const BuggifyError = error{
    InvalidRate,
};

/// Probability that a BUGGIFY hook fires in simulation.
pub const BuggifyRate = struct {
    numerator: u32,
    denominator: u32,

    /// Disabled hook.
    pub fn never() BuggifyRate {
        return .{ .numerator = 0, .denominator = 1 };
    }

    /// Always-on hook.
    pub fn always() BuggifyRate {
        return .{ .numerator = 1, .denominator = 1 };
    }

    /// Percentage chance in the closed range `0..100`.
    pub fn percent(value: u8) BuggifyRate {
        std.debug.assert(value <= 100);
        return .{ .numerator = value, .denominator = 100 };
    }

    /// One-in-N chance.
    pub fn oneIn(denominator: u32) BuggifyRate {
        std.debug.assert(denominator > 0);
        return .{ .numerator = 1, .denominator = denominator };
    }

    pub fn validate(self: BuggifyRate) BuggifyError!void {
        if (self.denominator == 0) return error.InvalidRate;
        if (self.numerator > self.denominator) return error.InvalidRate;
    }
};

pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now: *const fn (*anyopaque) clock_module.Timestamp,
        sleep: *const fn (*anyopaque, clock_module.Duration) ClockError!void,
    };

    pub fn now(self: Clock) clock_module.Timestamp {
        return self.vtable.now(self.ptr);
    }

    pub fn sleep(self: Clock, duration_ns: clock_module.Duration) ClockError!void {
        try self.vtable.sleep(self.ptr, duration_ns);
    }

    pub fn fromWorld(world: *World) Clock {
        return .{ .ptr = world, .vtable = &world_clock_vtable };
    }

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
        try worldClock(ptr).runFor(duration_ns);
    }

    fn productionClockNow(ptr: *anyopaque) clock_module.Timestamp {
        return productionClock(ptr).now();
    }

    fn productionClockSleep(ptr: *anyopaque, duration_ns: clock_module.Duration) ClockError!void {
        productionClock(ptr).sleep(duration_ns);
    }
};

pub const Random = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        random_u64: *const fn (*anyopaque) RandomError!u64,
        boolean: *const fn (*anyopaque) RandomError!bool,
        int_less_than_u64: *const fn (*anyopaque, u64) RandomError!u64,
    };

    /// Draw an untraced `u64` from host entropy.
    pub fn randomU64(self: Random) RandomError!u64 {
        return self.vtable.random_u64(self.ptr);
    }

    /// Draw an untraced boolean from host entropy.
    pub fn boolean(self: Random) RandomError!bool {
        return self.vtable.boolean(self.ptr);
    }

    /// Draw an unbiased integer in the range `0 <= value < less_than`.
    pub fn intLessThan(self: Random, comptime T: type, less_than: T) RandomError!T {
        const value = try self.vtable.int_less_than_u64(self.ptr, @intCast(less_than));
        return @intCast(value);
    }

    pub fn fromWorld(world: *World) Random {
        return .{ .ptr = world, .vtable = &world_random_vtable };
    }

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

pub const Tracer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        should_record: *const fn (*anyopaque) bool,
        allocator: *const fn (*anyopaque) std.mem.Allocator,
        record_payload: *const fn (*anyopaque, []const u8) TracerError!void,
    };

    pub fn none() Tracer {
        return .{ .ptr = &noop_tracer_ctx, .vtable = &noop_tracer_vtable };
    }

    pub fn fromWorld(world: *World) Tracer {
        return .{ .ptr = world, .vtable = &world_tracer_vtable };
    }

    pub fn record(self: Tracer, comptime fmt: []const u8, args: anytype) TracerError!void {
        if (!self.vtable.should_record(self.ptr)) return;
        const allocator = self.vtable.allocator(self.ptr);
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
        .allocator = noopTracerAllocator,
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
        const world = worldTracer(ptr);
        const start_len = world.trace_log.items.len;
        errdefer world.trace_log.shrinkRetainingCapacity(start_len);

        if (!world_module.isValidTracePayload(payload)) return error.InvalidTracePayload;
        try world.trace_log.print(world.allocator, "event={} ", .{world.event_index});
        try world.trace_log.appendSlice(world.allocator, payload);
        try world.trace_log.append(world.allocator, '\n');
        world.event_index += 1;
    }

    fn noopTracerShouldRecord(_: *anyopaque) bool {
        return false;
    }

    fn noopTracerAllocator(_: *anyopaque) std.mem.Allocator {
        return std.heap.smp_allocator;
    }

    fn noopTracerRecordPayload(_: *anyopaque, _: []const u8) TracerError!void {}
};

var noop_tracer_ctx: u8 = 0;

pub const Env = struct {
    disk: disk_module.Disk,
    clock: Clock,
    random: Random,
    tracer: Tracer,
    buggify_enabled: bool = false,

    pub fn record(self: Env, comptime fmt: []const u8, args: anytype) !void {
        try self.tracer.record(fmt, args);
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

        const roll = try self.random.intLessThan(u32, rate.denominator);
        const fired = roll < rate.numerator;
        try self.record(
            "buggify hook={s} rate={}/{} roll={} fired={}",
            .{ hookName(hook), rate.numerator, rate.denominator, roll, fired },
        );
        return fired;
    }
};

pub const Production = struct {
    allocator: std.mem.Allocator,
    disk: disk_module.RealDisk,
    clock: clock_module.ProductionClock,
    random_source: std.Random.IoSource,
    tracer: Tracer,
    network_teardowns: std.ArrayList(network_module.ProductionNetworkTeardown) = .empty,

    pub const Options = struct {
        allocator: std.mem.Allocator = std.heap.smp_allocator,
        /// Root directory that production disk paths are resolved beneath.
        /// The caller owns this directory and must keep it alive.
        root_dir: std.Io.Dir,
        /// Host I/O backend used by production capabilities.
        io: std.Io,
        disk: disk_module.RealDisk.Options = .{},
        tracer: ?Tracer = null,
    };

    pub fn init(options: Options) disk_module.DiskError!Production {
        return .{
            .allocator = options.allocator,
            .disk = try disk_module.RealDisk.init(options.root_dir, options.io, options.disk),
            .clock = .init(),
            .random_source = .{ .io = options.io },
            .tracer = options.tracer orelse .none(),
        };
    }

    pub fn network(self: *Production, comptime Payload: type) std.mem.Allocator.Error!network_module.TypedNetwork(Payload) {
        const created = try network_module.initProductionNetwork(Payload, self.allocator);
        errdefer created.teardown.deinit(created.teardown.ptr, self.allocator);
        try self.network_teardowns.append(self.allocator, created.teardown);
        return created.network;
    }

    pub fn env(self: *Production) Env {
        return .{
            .disk = self.disk.disk(),
            .clock = .fromProduction(&self.clock),
            .random = .fromProduction(&self.random_source),
            .tracer = self.tracer,
        };
    }

    pub fn deinit(self: *Production) void {
        var index = self.network_teardowns.items.len;
        while (index > 0) {
            index -= 1;
            const teardown = self.network_teardowns.items[index];
            teardown.deinit(teardown.ptr, self.allocator);
        }
        self.network_teardowns.deinit(self.allocator);
        self.disk.deinit();
        self.* = undefined;
    }
};

pub const SimControl = struct {
    disk: disk_module.DiskControl,
    network: network_module.AnyNetworkControl,
    world: *World,

    pub fn tick(self: SimControl) !void {
        try self.world.tick();
    }

    pub fn runFor(self: SimControl, duration_ns: clock_module.Duration) !void {
        try self.world.runFor(duration_ns);
    }
};

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
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.tick now_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.random_int_less_than") != null);
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

    var buffer = [_]u8{0} ** 4;
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
        .root_dir = tmp.dir,
        .io = std.testing.io,
        .disk = .{ .sector_size = 4 },
    });
    defer production.deinit();

    const env = production.env();

    _ = env.clock.now();
    _ = try env.random.intLessThan(u8, 10);
    try env.disk.write(.{ .path = "prod/wal.log", .offset = 0, .bytes = "abcd" });
    try env.disk.sync(.{ .path = "prod/wal.log" });
    var buffer = [_]u8{0} ** 4;
    try env.disk.read(.{ .path = "prod/wal.log", .offset = 0, .buffer = &buffer });
    try std.testing.expectEqualStrings("abcd", &buffer);
    try std.testing.expect(!try env.buggify(.drop_packet, .percent(50)));
}

test "env: simulation buggify is traced" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    _ = try sim.env.buggify(.drop_packet, .percent(20));

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.random_int_less_than type=u64 less_than=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "buggify hook=drop_packet rate=20/100 roll=") != null);
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
