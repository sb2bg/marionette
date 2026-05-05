//! Public run data types and metadata helpers.

const std = @import("std");

const clock_module = @import("clock.zig");
const world_module = @import("world.zig");
const World = world_module.World;

/// Named scenario check run by `mar.run`.
///
/// Checks are the Phase 0 invariant hook. They should return an error when a
/// property is violated so the runner can preserve the partial trace.
pub const Check = struct {
    /// Stable name included in failure reports.
    name: []const u8,
    /// Check function. It may inspect and record through the world.
    check: *const fn (*World) anyerror!void,
};

/// Replay-visible scalar attribute value.
pub const RunAttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    uint: u64,
    boolean: bool,
    float: f64,

    fn write(self: RunAttributeValue, writer: anytype) !void {
        switch (self) {
            .string => |value| {
                try writer.print("string:", .{});
                try world_module.writeEscapedTraceText(writer, value, true);
            },
            .int => |value| try writer.print("int:{}", .{value}),
            .uint => |value| try writer.print("uint:{}", .{value}),
            .boolean => |value| try writer.print("bool:{}", .{value}),
            .float => |value| try writer.print("float:{d}", .{value}),
        }
    }
};

/// Replay-visible typed attribute attached to a run.
///
/// Keys should be stable scalar text. Values keep their type so tooling does
/// not need to infer meaning from presentation strings.
pub const RunAttribute = struct {
    key: []const u8,
    value: RunAttributeValue,
};

/// Build one replay-visible typed attribute from a scalar value.
pub fn runAttribute(key: []const u8, value: anytype) RunAttribute {
    return .{ .key = key, .value = runAttributeValue(value) };
}

/// Build run attributes from a scalar-only run config struct.
///
/// Contract:
/// - Only deterministic scalar fields are supported: ints, floats, bools, and
///   UTF-8 string slices/literals.
/// - Fields are emitted in declaration order.
/// - Field names become exported attribute keys.
/// - Runtime behavior must depend on the original config, not on the derived
///   attributes.
///
/// Use `runAttribute` when a stable exported key should differ from an
/// internal field name.
pub fn runAttributesFrom(config: anytype) [runAttributeFieldCount(@TypeOf(config))]RunAttribute {
    const Config = @TypeOf(config);
    const fields = switch (@typeInfo(Config)) {
        .@"struct" => |struct_info| struct_info.fields,
        else => @compileError("runAttributesFrom expects a struct"),
    };

    var attributes: [fields.len]RunAttribute = undefined;
    inline for (fields, 0..) |field, index| {
        attributes[index] = runAttribute(field.name, @field(config, field.name));
    }
    return attributes;
}

fn runAttributeFieldCount(comptime Config: type) comptime_int {
    return switch (@typeInfo(Config)) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                @compileError("runAttributesFrom expects a named-field struct");
            }
            return struct_info.fields.len;
        },
        else => @compileError("runAttributesFrom expects a struct"),
    };
}

fn runAttributeValue(value: anytype) RunAttributeValue {
    const Value = @TypeOf(value);
    return switch (@typeInfo(Value)) {
        .bool => .{ .boolean = value },
        .int => |int_info| switch (int_info.signedness) {
            .signed => .{ .int = @intCast(value) },
            .unsigned => .{ .uint = @intCast(value) },
        },
        .comptime_int => if (value < 0)
            .{ .int = @intCast(value) }
        else
            .{ .uint = @intCast(value) },
        .float, .comptime_float => .{ .float = @floatCast(value) },
        .pointer => |pointer_info| stringAttributeValue(Value, pointer_info, value),
        .array => |array_info| {
            if (array_info.child != u8) {
                @compileError("run attribute arrays must be u8 strings");
            }
            return .{ .string = value[0..array_info.len] };
        },
        else => @compileError("unsupported run attribute value type: " ++ @typeName(Value)),
    };
}

fn stringAttributeValue(comptime Value: type, comptime pointer_info: std.builtin.Type.Pointer, value: Value) RunAttributeValue {
    switch (pointer_info.size) {
        .slice => {
            if (pointer_info.child != u8) {
                @compileError("run attribute slices must be []const u8 strings");
            }
            return .{ .string = value };
        },
        .one => switch (@typeInfo(pointer_info.child)) {
            .array => |array_info| {
                if (array_info.child != u8) {
                    @compileError("run attribute pointers-to-array must point to u8 strings");
                }
                return .{ .string = value[0..array_info.len] };
            },
            else => @compileError("unsupported run attribute pointer type: " ++ @typeName(Value)),
        },
        else => @compileError("unsupported run attribute pointer type: " ++ @typeName(Value)),
    }
}

/// Named scenario check over user-owned scenario state.
pub fn StateCheck(comptime State: type) type {
    return struct {
        /// Stable name included in failure reports.
        name: []const u8,
        /// Check function. It may inspect state and record through authorities
        /// owned by the state.
        check: *const fn (*const State) anyerror!void,
    };
}

/// Configuration for one deterministic scenario run.
pub const RunOptions = struct {
    /// Seed for the world's random stream.
    seed: u64,
    /// Initial simulated timestamp in nanoseconds.
    start_ns: clock_module.Timestamp = 0,
    /// Nanoseconds advanced by one world tick.
    tick_ns: clock_module.Duration = clock_module.default_tick_ns,
    /// Optional stable run name, such as "smoke", "swarm", or "replay".
    name: ?[]const u8 = null,
    /// Loose searchable labels.
    tags: []const []const u8 = &.{},
    /// Expanded typed run facts needed to reproduce the scenario.
    attributes: []const RunAttribute = &.{},
    /// Checks run after a successful scenario body.
    checks: []const Check = &.{},

    pub fn worldOptions(self: RunOptions) World.Options {
        return .{
            .seed = self.seed,
            .start_ns = self.start_ns,
            .tick_ns = self.tick_ns,
        };
    }
};

pub fn cloneRunOptions(allocator: std.mem.Allocator, options: RunOptions) std.mem.Allocator.Error!RunOptions {
    var cloned: RunOptions = .{
        .seed = options.seed,
        .start_ns = options.start_ns,
        .tick_ns = options.tick_ns,
    };
    errdefer deinitRunOptions(allocator, &cloned);

    if (options.name) |name| {
        cloned.name = try allocator.dupe(u8, name);
    }

    if (options.tags.len > 0) {
        const tags = try allocator.alloc([]const u8, options.tags.len);
        cloned.tags = tags;
        for (tags) |*tag| tag.* = &.{};
        for (options.tags, 0..) |tag, index| {
            tags[index] = try allocator.dupe(u8, tag);
        }
    }

    if (options.attributes.len > 0) {
        const attributes = try allocator.alloc(RunAttribute, options.attributes.len);
        cloned.attributes = attributes;
        for (attributes) |*attribute| {
            attribute.* = .{ .key = &.{}, .value = .{ .uint = 0 } };
        }
        for (options.attributes, 0..) |attribute, index| {
            attributes[index].key = try allocator.dupe(u8, attribute.key);
            attributes[index].value = try cloneRunAttributeValue(allocator, attribute.value);
        }
    }

    if (options.checks.len > 0) {
        const checks = try allocator.alloc(Check, options.checks.len);
        cloned.checks = checks;
        for (checks) |*check| {
            check.* = .{ .name = &.{}, .check = undefined };
        }
        for (options.checks, 0..) |check, index| {
            checks[index] = .{
                .name = try allocator.dupe(u8, check.name),
                .check = check.check,
            };
        }
    }

    return cloned;
}

pub fn deinitRunOptions(allocator: std.mem.Allocator, options: *RunOptions) void {
    if (options.name) |name| allocator.free(name);
    for (options.tags) |tag| allocator.free(tag);
    allocator.free(options.tags);
    for (options.attributes) |attribute| {
        allocator.free(attribute.key);
        deinitRunAttributeValue(allocator, attribute.value);
    }
    allocator.free(options.attributes);
    for (options.checks) |check| allocator.free(check.name);
    allocator.free(options.checks);
    options.* = undefined;
}

fn cloneRunAttributeValue(
    allocator: std.mem.Allocator,
    value: RunAttributeValue,
) std.mem.Allocator.Error!RunAttributeValue {
    return switch (value) {
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .int => |int| .{ .int = int },
        .uint => |uint| .{ .uint = uint },
        .boolean => |boolean| .{ .boolean = boolean },
        .float => |float| .{ .float = float },
    };
}

fn deinitRunAttributeValue(allocator: std.mem.Allocator, value: RunAttributeValue) void {
    switch (value) {
        .string => |string| allocator.free(string),
        .int, .uint, .boolean, .float => {},
    }
}

/// Successful scenario result.
pub const RunResult = struct {
    allocator: std.mem.Allocator,
    options: RunOptions,
    owns_options: bool = false,
    trace: []u8,
    event_count: u64,

    /// Release the owned trace.
    pub fn deinit(self: *RunResult) void {
        self.allocator.free(self.trace);
        if (self.owns_options) deinitRunOptions(self.allocator, &self.options);
        self.* = undefined;
    }

    /// Transfer ownership of the trace to the caller.
    pub fn takeTrace(self: *RunResult) []u8 {
        const trace = self.trace;
        self.trace = &.{};
        self.event_count = 0;
        return trace;
    }
};

/// Failure kind captured by the runner.
pub const RunFailureKind = enum {
    /// The scenario returned an error. The first trace is the partial trace.
    scenario_error,
    /// A named check returned an error. The first trace is the partial trace.
    check_failed,
    /// Two executions with the same seed produced different traces.
    determinism_mismatch,
};

/// Data-bearing failure report.
pub const RunFailure = struct {
    allocator: std.mem.Allocator,
    options: RunOptions,
    owns_options: bool = false,
    kind: RunFailureKind,
    first_trace: []u8,
    second_trace: []u8 = &.{},
    first_event_count: u64,
    second_event_count: u64 = 0,
    error_name: ?[]const u8 = null,
    check_name: ?[]const u8 = null,
    owns_check_name: bool = false,

    /// Release owned traces.
    pub fn deinit(self: *RunFailure) void {
        self.allocator.free(self.first_trace);
        self.allocator.free(self.second_trace);
        if (self.owns_options) deinitRunOptions(self.allocator, &self.options);
        if (self.owns_check_name) {
            if (self.check_name) |name| self.allocator.free(name);
        }
        self.* = undefined;
    }

    /// Write a compact, stable failure summary.
    pub fn writeSummary(self: RunFailure, writer: anytype) !void {
        try writer.print(
            "marionette failure: kind={s} seed={}",
            .{ @tagName(self.kind), self.options.seed },
        );
        if (self.options.name) |name| {
            try writer.print(" name=", .{});
            try world_module.writeEscapedTraceText(writer, name, false);
        }
        try writer.print(
            " start_ns={} tick_ns={} first_events={} second_events={}",
            .{
                self.options.start_ns,
                self.options.tick_ns,
                self.first_event_count,
                self.second_event_count,
            },
        );
        for (self.options.tags) |tag| {
            try writer.print(" tag=", .{});
            try world_module.writeEscapedTraceText(writer, tag, false);
        }
        for (self.options.attributes) |attribute| {
            try writer.writeByte(' ');
            try world_module.writeEscapedTraceText(writer, attribute.key, false);
            try writer.writeByte('=');
            try attribute.value.write(writer);
        }
        if (self.error_name) |name| {
            try writer.print(" error={s}", .{name});
        }
        if (self.check_name) |name| {
            try writer.print(" check=", .{});
            try world_module.writeEscapedTraceText(writer, name, false);
        }
        try writer.writeByte('\n');
    }

    /// Print a compact failure report.
    pub fn print(self: RunFailure) void {
        var buffer: [1024]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();
        self.writeSummary(&stderr.file_writer.interface) catch {};
    }
};

/// Result of `run`: either a verified replay or a data-bearing failure.
pub const RunReport = union(enum) {
    passed: RunResult,
    failed: RunFailure,

    /// Release any owned traces.
    pub fn deinit(self: *RunReport) void {
        switch (self.*) {
            .passed => |*passed| passed.deinit(),
            .failed => |*failed| failed.deinit(),
        }
        self.* = undefined;
    }
};

test "runAttributesFrom: derives typed attributes from config structs" {
    const Profile = struct {
        replicas: u8,
        retry_limit: i16,
        faults_enabled: bool,
        mode: []const u8,
        weight: f32,
    };

    const attributes = runAttributesFrom(Profile{
        .replicas = 3,
        .retry_limit = -1,
        .faults_enabled = true,
        .mode = "smoke",
        .weight = 1.5,
    });

    try std.testing.expectEqual(@as(usize, 5), attributes.len);
    try std.testing.expectEqualStrings("replicas", attributes[0].key);
    try std.testing.expectEqual(@as(u64, 3), attributes[0].value.uint);
    try std.testing.expectEqualStrings("retry_limit", attributes[1].key);
    try std.testing.expectEqual(@as(i64, -1), attributes[1].value.int);
    try std.testing.expectEqualStrings("faults_enabled", attributes[2].key);
    try std.testing.expectEqual(true, attributes[2].value.boolean);
    try std.testing.expectEqualStrings("mode", attributes[3].key);
    try std.testing.expectEqualStrings("smoke", attributes[3].value.string);
    try std.testing.expectEqualStrings("weight", attributes[4].key);
    try std.testing.expectEqual(@as(f64, 1.5), attributes[4].value.float);
}

test "runAttribute: accepts string literals" {
    const attribute = runAttribute("profile", "smoke");

    try std.testing.expectEqualStrings("profile", attribute.key);
    try std.testing.expectEqualStrings("smoke", attribute.value.string);
}
