//! Deterministic simulation engine state.
//!
//! A `World` owns the Phase 0 simulation state: one fake clock, one
//! seeded PRNG, and a trace log. Later phases will add schedulers, disk,
//! and network here.

const std = @import("std");

const clock_module = @import("clock.zig");
const random_module = @import("random.zig");

/// Container for deterministic simulation engine state.
///
/// `World` owns the fake clock, seeded random stream, and trace log used by
/// simulation tests. Application code should usually receive `SimulationEnv`
/// rather than `World` directly; `World` is the harness-owned engine.
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

    /// Configuration for a simulation world.
    pub const Options = struct {
        /// Seed for the world's random stream.
        seed: u64,
        /// Initial simulated timestamp in nanoseconds.
        start_ns: clock_module.Timestamp = 0,
        /// Nanoseconds advanced by one world tick.
        tick_ns: clock_module.Duration = clock_module.default_tick_ns,
    };

    /// Narrow traced-random authority derived from a world.
    pub const TracedRandom = struct {
        world: *World,

        /// Draw a traced `u64`.
        pub fn randomU64(self: TracedRandom) !u64 {
            return self.world.randomU64();
        }

        /// Draw a traced boolean.
        pub fn boolean(self: TracedRandom) !bool {
            return self.world.randomBool();
        }

        /// Draw a traced unbiased integer in the range `0 <= value < less_than`.
        pub fn intLessThan(self: TracedRandom, comptime T: type, less_than: T) !T {
            return self.world.randomIntLessThan(T, less_than);
        }
    };

    /// Construct a world with deterministic time, randomness, and tracing.
    pub fn init(allocator: std.mem.Allocator, options: Options) !World {
        var world: World = .{
            .allocator = allocator,
            .sim_clock = .init(.{
                .start_ns = options.start_ns,
                .tick_ns = options.tick_ns,
            }),
            .rng = .init(options.seed),
            .trace_log = .empty,
            .event_index = 0,
        };
        errdefer world.deinit();

        try world.trace_log.appendSlice(allocator, "marionette.trace format=text version=0\n");
        try world.record(
            "world.init seed={} start_ns={} tick_ns={}",
            .{ options.seed, options.start_ns, options.tick_ns },
        );

        return world;
    }

    /// Release memory owned by the world.
    pub fn deinit(self: *World) void {
        self.trace_log.deinit(self.allocator);
        self.* = undefined;
    }

    /// Return the world's simulated clock.
    ///
    /// Prefer `SimulationEnv.clock()` in application code. This is a
    /// low-level world authority for harnesses and env implementations.
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

    /// Return the traced random authority.
    ///
    /// Prefer `SimulationEnv.random()` in application code. This is a
    /// low-level world authority for harnesses and env implementations.
    pub fn tracedRandom(self: *World) TracedRandom {
        return .{ .world = self };
    }

    /// Draw a traced `u64` from the world's seeded random stream.
    pub fn randomU64(self: *World) !u64 {
        const value = self.rng.random().int(u64);
        try self.record("world.random_u64 value={}", .{value});
        return value;
    }

    /// Draw a traced boolean from the world's seeded random stream.
    pub fn randomBool(self: *World) !bool {
        const value = self.rng.random().boolean();
        try self.record("world.random_bool value={}", .{value});
        return value;
    }

    /// Draw a traced unbiased integer in the range `0 <= value < less_than`.
    pub fn randomIntLessThan(self: *World, comptime T: type, less_than: T) !T {
        const value = self.rng.random().intRangeLessThan(T, 0, less_than);
        try self.record(
            "world.random_int_less_than type={s} less_than={} value={}",
            .{ @typeName(T), less_than, value },
        );
        return value;
    }

    /// Advance the world by one simulation tick.
    pub fn tick(self: *World) !void {
        self.sim_clock.tick();
        try self.record("world.tick now_ns={}", .{self.now()});
    }

    /// Advance the world by a duration measured in nanoseconds.
    ///
    /// `duration_ns` must be an exact multiple of the world's tick size.
    pub fn runFor(self: *World, duration_ns: clock_module.Duration) !void {
        const start_ns = self.now();
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
    pub fn record(self: *World, comptime fmt: []const u8, args: anytype) !void {
        const start_len = self.trace_log.items.len;
        errdefer self.trace_log.shrinkRetainingCapacity(start_len);

        try self.trace_log.print(self.allocator, "event={} ", .{self.event_index});
        const payload_start = self.trace_log.items.len;
        try self.trace_log.print(self.allocator, fmt, args);
        std.debug.assert(isValidTracePayload(self.trace_log.items[payload_start..]));
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
};

fn isValidTracePayload(payload: []const u8) bool {
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
        \\marionette.trace format=text version=0
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
