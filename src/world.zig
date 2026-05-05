//! Deterministic simulation engine state.
//!
//! A `World` owns the Phase 0 simulation state: one fake clock, one
//! seeded PRNG, and a trace log. Later phases will add schedulers, disk,
//! and network here.

const std = @import("std");

const clock_module = @import("clock.zig");
const disk_module = @import("disk.zig");
const env_module = @import("env.zig");
const network_module = @import("network.zig");
const random_module = @import("random.zig");

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
    /// Simulator resources owned by the world and torn down in reverse order.
    teardowns: std.ArrayList(Teardown),

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
            .teardowns = .empty,
        };
        errdefer world.deinit();

        try world.trace_log.appendSlice(allocator, "marionette.trace format=text version=0\n");
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

    pub const SimulateOptions = struct {
        disk: disk_module.DiskOptions = .{},
        network: ?network_module.SimNetworkOptions = null,
    };

    pub const Simulation = struct {
        env: env_module.Env,
        control: env_module.SimControl,

        pub fn network(self: Simulation, comptime Payload: type) !network_module.TypedNetwork(Payload) {
            return try network_module.networkFromControl(Payload, self.control.network);
        }
    };

    /// Build app and harness views over world-owned simulator resources.
    pub fn simulate(self: *World, options: SimulateOptions) !Simulation {
        const sim_disk = try self.allocator.create(disk_module.SimDisk);
        errdefer self.allocator.destroy(sim_disk);

        sim_disk.* = try disk_module.SimDisk.init(self, options.disk);
        errdefer sim_disk.deinit();

        try self.registerTeardown(sim_disk, deinitSimDisk);

        const network_control = if (options.network) |network_options|
            try network_module.initSimControl(self, network_options)
        else
            network_module.AnyNetworkControl.unavailable();

        return .{
            .env = .{
                .disk = sim_disk.disk(),
                .clock = env_module.Clock.fromWorld(self),
                .random = env_module.Random.fromWorld(self),
                .tracer = env_module.Tracer.fromWorld(self),
                .buggify_enabled = true,
            },
            .control = .{
                .disk = sim_disk.control(),
                .network = network_control,
                .world = self,
            },
        };
    }

    fn deinitSimDisk(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const sim_disk: *disk_module.SimDisk = @ptrCast(@alignCast(ptr));
        sim_disk.deinit();
        allocator.destroy(sim_disk);
    }

    /// Return the world's simulated clock.
    ///
    /// Prefer `Env.clock` in application code. This is a
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
