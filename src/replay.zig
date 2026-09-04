//! Durable, versioned replay capsules. Seeds explore; capsules retain decisions.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("run_types.zig");
const world_module = @import("world.zig");
const execution = @import("execution.zig");
const codec = @import("execution_codec.zig");
const disk = @import("disk/root.zig");

pub const Identity = struct {
    /// Exact simulator/application build identifier supplied by the harness.
    build: []const u8,
    /// SUT revision plus input/workload identity supplied by the harness.
    sut: []const u8,
    zig: []const u8 = builtin.zig_version_string,
    target: []const u8 = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi),
    optimize: []const u8 = @tagName(builtin.mode),
    disk_version: u32 = disk.disk_semantic_version,

    pub fn compatible(self: Identity, other: Identity) bool {
        return self.build.len != 0 and self.sut.len != 0 and
            std.mem.eql(u8, self.build, other.build) and std.mem.eql(u8, self.sut, other.sut) and
            std.mem.eql(u8, self.zig, other.zig) and std.mem.eql(u8, self.target, other.target) and
            std.mem.eql(u8, self.optimize, other.optimize) and self.disk_version == other.disk_version;
    }
};

pub const Capsule = struct {
    const Envelope = struct {
        format: []const u8 = "marionette.replay",
        version: u32 = 1,
        identity: Identity,
        options: types.RunOptions,
        simulate: world_module.World.SimulateOptions,
        result: codec.Wire,
    };

    parsed: std.json.Parsed(Envelope),

    /// Serialize a completed, reproducible report. Caller owns the returned bytes.
    /// Write bytes with caller-provided std.Io; the codec never accesses the host.
    pub fn encode(
        allocator: std.mem.Allocator,
        report: *const types.RunReport,
        identity: Identity,
    ) ![]u8 {
        if (identity.build.len == 0 or identity.sut.len == 0) return error.InvalidReplayIdentity;
        const run_options, const simulate, const wire: codec.Wire = switch (report.*) {
            .passed => |value| .{ value.options, value.simulate_options, .{
                .trace = value.trace,
                .event_count = value.event_count,
                .decisions = value.decision_tape.entries,
                .tape_complete = value.tape_complete,
                .failure = null,
            } },
            .failed => |value| block: {
                if (value.second_trace.len != 0 or value.replay_divergence != null) return error.UnreproducibleRun;
                break :block .{ value.options, value.simulate_options, .{
                    .trace = value.first_trace,
                    .event_count = value.first_event_count,
                    .decisions = value.decision_tape.entries,
                    .tape_complete = value.tape_complete,
                    .failure = .{ .kind = value.kind, .error_name = value.error_name, .check_name = value.check_name },
                } };
            },
        };
        if (!wire.tape_complete) return error.IncompleteDecisionTape;
        try wire.validate();
        return std.json.Stringify.valueAlloc(allocator, Envelope{
            .identity = identity,
            .options = run_options,
            .simulate = simulate,
            .result = wire,
        }, .{});
    }

    /// Parse owned storage, rejecting unsupported versions and malformed decisions.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Capsule {
        const parsed = try std.json.parseFromSlice(Envelope, allocator, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const value = parsed.value;
        if (!std.mem.eql(u8, value.format, "marionette.replay") or value.version != 1) return error.UnsupportedReplayVersion;
        if (!value.result.tape_complete) return error.IncompleteDecisionTape;
        if (value.identity.build.len == 0 or value.identity.sut.len == 0) return error.InvalidReplayIdentity;
        if (value.options.tick_ns == 0) return error.InvalidReplayArtifact;
        if (value.options.watchdog) |watchdog| try watchdog.validate();
        if (value.result.failure) |failure| {
            if (failure.divergence != null) return error.UnreproducibleRun;
        }
        try @import("seed.zig").validateSeedSchedule(value.options.seed_schedule);
        var verified = try value.result.cloneResult(allocator);
        verified.deinit();
        return .{ .parsed = parsed };
    }

    pub fn deinit(self: *Capsule) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn validateIdentity(self: *const Capsule, identity: Identity) !void {
        if (!self.parsed.value.identity.compatible(identity)) return error.IncompatibleReplay;
    }

    pub fn options(self: *const Capsule) types.RunOptions {
        return self.parsed.value.options;
    }

    pub fn simulateOptions(self: *const Capsule) world_module.World.SimulateOptions {
        return self.parsed.value.simulate;
    }

    pub fn executionResult(self: *const Capsule, allocator: std.mem.Allocator) !execution.Result {
        return self.parsed.value.result.cloneResult(allocator);
    }
};
