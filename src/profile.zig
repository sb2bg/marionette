//! Named simulation profiles.
//!
//! Profiles collect the run metadata, static simulator options, and runtime
//! fault controls that define a scenario class. Callers still apply each part
//! explicitly so traces and failure summaries show the expanded values.

const std = @import("std");

const clock_module = @import("clock.zig");
const disk_module = @import("disk/root.zig");
const env_module = @import("env.zig");
const network_module = @import("network/root.zig");
const run_types = @import("run_types.zig");
const World = @import("world.zig").World;

/// A named scenario class: static `World.simulate` options plus the
/// runtime fault controls that define it. Expand with `expand()` and apply
/// each part explicitly so traces and failure summaries show the values.
pub const SimProfile = struct {
    kind: Kind,
    simulate: World.SimulateOptions,
    disk_faults: disk_module.DiskFaultOptions = .{},
    network_loss: network_module.NetworkLossOptions = .{},
    network_latency: network_module.NetworkLatencyOptions = .{},
    network_clogs: network_module.NetworkClogOptions = .{},
    network_partitions: network_module.NetworkPartitionDynamicsOptions = .{},
    process_dynamics: env_module.ProcessDynamicsOptions = .{},

    /// The built-in profile families.
    pub const Kind = enum {
        baseline,
        swarm,
        replay,
        performance,
    };

    /// Inputs shared by the built-in profiles.
    ///
    /// Runtime fields are optional so a profile's defaults can be overridden
    /// one control surface at a time without restating every other value.
    pub const Options = struct {
        tick_ns: clock_module.Duration = clock_module.default_tick_ns,
        disk: disk_module.DiskOptions = .{},
        network: ?network_module.SimNetworkOptions = null,
        disk_faults: ?disk_module.DiskFaultOptions = null,
        network_loss: ?network_module.NetworkLossOptions = null,
        network_latency: ?network_module.NetworkLatencyOptions = null,
        network_clogs: ?network_module.NetworkClogOptions = null,
        network_partitions: ?network_module.NetworkPartitionDynamicsOptions = null,
        process_dynamics: ?env_module.ProcessDynamicsOptions = null,
    };

    /// The runtime fault controls a profile applies through
    /// `apply(control)`, as concrete values after defaults resolve.
    pub const RuntimeOptions = struct {
        disk_faults: disk_module.DiskFaultOptions = .{},
        network_loss: network_module.NetworkLossOptions = .{},
        network_latency: network_module.NetworkLatencyOptions = .{},
        network_clogs: network_module.NetworkClogOptions = .{},
        network_partitions: network_module.NetworkPartitionDynamicsOptions = .{},
        process_dynamics: env_module.ProcessDynamicsOptions = .{},
    };

    /// Number of run attributes `Expanded` reports for every profile.
    pub const attribute_count = 41;

    /// A profile flattened into run metadata: one `profile:<name>` tag
    /// and a fixed attribute set covering every fault knob, so two runs
    /// with the same profile name but different values are distinguishable.
    pub const Expanded = struct {
        profile: SimProfile,
        tags: [1][]const u8,
        attributes: [attribute_count]run_types.RunAttribute,

        fn init(profile: SimProfile) Expanded {
            var attributes: [attribute_count]run_types.RunAttribute = undefined;
            var index: usize = 0;

            put(&attributes, &index, "profile.name", profile.name());
            put(&attributes, &index, "profile.network.enabled", profile.simulate.network != null);
            if (profile.simulate.network) |network| {
                put(&attributes, &index, "profile.network.nodes", network.nodes);
                put(&attributes, &index, "profile.network.service_nodes", network.service_nodes);
                put(&attributes, &index, "profile.network.path_capacity", network.path_capacity);
            } else {
                put(&attributes, &index, "profile.network.nodes", @as(u64, 0));
                put(&attributes, &index, "profile.network.service_nodes", @as(u64, 0));
                put(&attributes, &index, "profile.network.path_capacity", @as(u64, 0));
            }

            put(&attributes, &index, "profile.disk.sector_size", profile.simulate.disk.sector_size);
            put(&attributes, &index, "profile.disk.min_latency_ns", profile.simulate.disk.min_latency_ns orelse @as(u64, 0));
            put(&attributes, &index, "profile.disk.latency_jitter_ns", profile.simulate.disk.latency_jitter_ns);

            putRate(&attributes, &index, "profile.disk.read_error_rate", profile.disk_faults.read_error_rate);
            putRate(&attributes, &index, "profile.disk.write_error_rate", profile.disk_faults.write_error_rate);
            putRate(&attributes, &index, "profile.disk.corrupt_read_rate", profile.disk_faults.corrupt_read_rate);
            putRate(&attributes, &index, "profile.disk.crash_lost_write_rate", profile.disk_faults.crash_lost_write_rate);
            putRate(&attributes, &index, "profile.disk.crash_torn_write_rate", profile.disk_faults.crash_torn_write_rate);
            putRate(&attributes, &index, "profile.disk.crash_reordered_write_rate", profile.disk_faults.crash_reordered_write_rate);
            putRate(&attributes, &index, "profile.disk.crash_lost_metadata_rate", profile.disk_faults.crash_lost_metadata_rate);

            putRate(&attributes, &index, "profile.network.drop_rate", profile.network_loss.drop_rate);
            put(&attributes, &index, "profile.network.min_latency_ns", profile.network_latency.min_latency_ns);
            put(&attributes, &index, "profile.network.latency_jitter_ns", profile.network_latency.latency_jitter_ns);
            putRate(&attributes, &index, "profile.network.path_clog_rate", profile.network_clogs.path_clog_rate);
            put(&attributes, &index, "profile.network.path_clog_duration_ns", profile.network_clogs.path_clog_duration_ns);
            putRate(&attributes, &index, "profile.network.partition_rate", profile.network_partitions.partition_rate);
            putRate(&attributes, &index, "profile.network.unpartition_rate", profile.network_partitions.unpartition_rate);
            put(&attributes, &index, "profile.network.partition_stability_min_ns", profile.network_partitions.partition_stability_min_ns);
            put(&attributes, &index, "profile.network.unpartition_stability_min_ns", profile.network_partitions.unpartition_stability_min_ns);

            putRate(&attributes, &index, "profile.process.crash_rate", profile.process_dynamics.crash_rate);
            putRate(&attributes, &index, "profile.process.restart_rate", profile.process_dynamics.restart_rate);
            put(&attributes, &index, "profile.process.crash_stability_min_ns", profile.process_dynamics.crash_stability_min_ns);
            put(&attributes, &index, "profile.process.restart_stability_min_ns", profile.process_dynamics.restart_stability_min_ns);

            std.debug.assert(index == attribute_count);
            return .{
                .profile = profile,
                .tags = .{profile.tag()},
                .attributes = attributes,
            };
        }

        /// The profile name, e.g. "swarm".
        pub fn name(self: *const Expanded) []const u8 {
            return self.profile.name();
        }

        /// Run tags to pass to the case runner (`profile:<name>`).
        pub fn runTags(self: *const Expanded) []const []const u8 {
            return self.tags[0..];
        }

        /// Expanded run attributes to pass to the case runner.
        pub fn runAttributes(self: *const Expanded) []const run_types.RunAttribute {
            return self.attributes[0..];
        }

        /// Static options to pass to `World.simulate`.
        pub fn simulateOptions(self: *const Expanded) World.SimulateOptions {
            return self.profile.simulateOptions();
        }

        /// Apply the profile's runtime fault controls; see
        /// `SimProfile.apply`.
        pub fn apply(self: *const Expanded, control: env_module.SimControl) !void {
            try self.profile.apply(control);
        }
    };

    /// Fault-free defaults: no network faults, no disk faults, no
    /// process dynamics.
    pub fn baseline(options: Options) SimProfile {
        return init(.baseline, options, .{});
    }

    /// Hostile-network defaults: packet loss, latency jitter, automatic
    /// clogs, and automatic node-isolating partitions, scaled to the tick.
    pub fn swarm(options: Options) SimProfile {
        const tick_ns = options.tick_ns;
        return init(.swarm, options, .{
            .network_loss = .{ .drop_rate = .percent(10) },
            .network_latency = .{
                .min_latency_ns = tick_ns,
                .latency_jitter_ns = 2 * tick_ns,
            },
            .network_clogs = .{
                .path_clog_rate = .percent(10),
                .path_clog_duration_ns = 2 * tick_ns,
            },
            .network_partitions = .{
                .partition_rate = .percent(5),
                .unpartition_rate = .percent(20),
                .partition_stability_min_ns = 3 * tick_ns,
                .unpartition_stability_min_ns = 3 * tick_ns,
            },
        });
    }

    /// Fault-free defaults intended for replaying a recorded scenario;
    /// pass the original run's explicit fault values as overrides.
    pub fn replay(options: Options) SimProfile {
        return init(.replay, options, .{});
    }

    /// Throughput-oriented defaults: zero disk latency unless overridden
    /// and no network perturbations.
    pub fn performance(options: Options) SimProfile {
        var performance_options = options;
        if (performance_options.disk.min_latency_ns == null) {
            performance_options.disk.min_latency_ns = 0;
        }
        return init(.performance, performance_options, .{
            .network_latency = .{},
            .network_clogs = .{},
            .network_partitions = .{},
        });
    }

    /// Flatten this profile into run tags and attributes.
    pub fn expand(self: SimProfile) Expanded {
        return Expanded.init(self);
    }

    /// The profile name, e.g. "swarm".
    pub fn name(self: SimProfile) []const u8 {
        return switch (self.kind) {
            .baseline => "baseline",
            .swarm => "swarm",
            .replay => "replay",
            .performance => "performance",
        };
    }

    /// The run tag form of the name, e.g. "profile:swarm".
    pub fn tag(self: SimProfile) []const u8 {
        return switch (self.kind) {
            .baseline => "profile:baseline",
            .swarm => "profile:swarm",
            .replay => "profile:replay",
            .performance => "profile:performance",
        };
    }

    /// Static options to pass to `World.simulate`.
    pub fn simulateOptions(self: SimProfile) World.SimulateOptions {
        return self.simulate;
    }

    /// Apply the profile's runtime fault controls to a live simulation:
    /// disk faults, the four network fault surfaces when a network is
    /// configured, and process dynamics on every node.
    pub fn apply(self: SimProfile, control: env_module.SimControl) !void {
        try control.disk.setFaults(self.disk_faults);

        if (self.simulate.network != null) {
            try control.network.setLossiness(self.network_loss);
            try control.network.setLatency(self.network_latency);
            try control.network.setClogs(self.network_clogs);
            try control.network.setPartitionDynamics(self.network_partitions);
        }

        for (0..processCount(self.simulate.network)) |index| {
            const node = std.math.cast(network_module.NodeId, index) orelse return error.InvalidNode;
            try control.process.setDynamics(node, self.process_dynamics);
        }
    }

    fn init(kind: Kind, options: Options, defaults: RuntimeOptions) SimProfile {
        const runtime = effectiveRuntimeOptions(options, defaults);
        return .{
            .kind = kind,
            .simulate = .{
                .disk = expandDiskOptions(options.tick_ns, options.disk),
                .network = options.network,
            },
            .disk_faults = runtime.disk_faults,
            .network_loss = runtime.network_loss,
            .network_latency = runtime.network_latency,
            .network_clogs = runtime.network_clogs,
            .network_partitions = runtime.network_partitions,
            .process_dynamics = runtime.process_dynamics,
        };
    }
};

fn effectiveRuntimeOptions(options: SimProfile.Options, defaults: SimProfile.RuntimeOptions) SimProfile.RuntimeOptions {
    var runtime: SimProfile.RuntimeOptions = .{
        .disk_faults = options.disk_faults orelse defaults.disk_faults,
        .network_loss = options.network_loss orelse defaults.network_loss,
        .network_latency = options.network_latency orelse defaults.network_latency,
        .network_clogs = options.network_clogs orelse defaults.network_clogs,
        .network_partitions = options.network_partitions orelse defaults.network_partitions,
        .process_dynamics = options.process_dynamics orelse defaults.process_dynamics,
    };

    if (options.network == null) {
        runtime.network_loss = .{};
        runtime.network_latency = .{};
        runtime.network_clogs = .{};
        runtime.network_partitions = .{};
    }

    return runtime;
}

fn expandDiskOptions(tick_ns: clock_module.Duration, disk: disk_module.DiskOptions) disk_module.DiskOptions {
    return .{
        .sector_size = disk.sector_size,
        .min_latency_ns = disk.min_latency_ns orelse tick_ns,
        .latency_jitter_ns = disk.latency_jitter_ns,
    };
}

fn processCount(network: ?network_module.SimNetworkOptions) usize {
    return if (network) |options| options.nodes else 1;
}

fn put(
    attributes: *[SimProfile.attribute_count]run_types.RunAttribute,
    index: *usize,
    comptime key: []const u8,
    value: anytype,
) void {
    attributes[index.*] = run_types.runAttribute(key, value);
    index.* += 1;
}

fn putRate(
    attributes: *[SimProfile.attribute_count]run_types.RunAttribute,
    index: *usize,
    comptime key: []const u8,
    rate: env_module.BuggifyRate,
) void {
    put(attributes, index, key ++ ".numerator", rate.numerator);
    put(attributes, index, key ++ ".denominator", rate.denominator);
}

test "SimProfile: swarm expands network controls into attributes" {
    const profile = SimProfile.swarm(.{
        .tick_ns = 10,
        .network = .{
            .nodes = 4,
            .service_nodes = 3,
            .path_capacity = 96,
        },
    }).expand();

    try std.testing.expectEqualStrings("swarm", profile.name());
    try std.testing.expectEqualStrings("profile:swarm", profile.runTags()[0]);
    try std.testing.expectEqual(@as(usize, SimProfile.attribute_count), profile.runAttributes().len);
    try std.testing.expectEqual(@as(?clock_module.Duration, 10), profile.simulateOptions().disk.min_latency_ns);
    try std.testing.expectEqual(@as(usize, 4), profile.simulateOptions().network.?.nodes);

    const attributes = profile.runAttributes();
    try expectAttribute(attributes, "profile.name", .{ .string = "swarm" });
    try expectAttribute(attributes, "profile.network.nodes", .{ .uint = 4 });
    try expectAttribute(attributes, "profile.network.path_capacity", .{ .uint = 96 });
    try expectAttribute(attributes, "profile.network.drop_rate.numerator", .{ .uint = 10 });
    try expectAttribute(attributes, "profile.network.min_latency_ns", .{ .uint = 10 });
    try expectAttribute(attributes, "profile.network.latency_jitter_ns", .{ .uint = 20 });
    try expectAttribute(attributes, "profile.network.path_clog_rate.numerator", .{ .uint = 10 });
    try expectAttribute(attributes, "profile.network.partition_rate.numerator", .{ .uint = 5 });
    try expectAttribute(attributes, "profile.network.unpartition_rate.numerator", .{ .uint = 20 });
    try expectAttribute(attributes, "profile.network.partition_stability_min_ns", .{ .uint = 30 });
}

test "SimProfile: replay preserves explicit runtime controls" {
    const profile = SimProfile.replay(.{
        .tick_ns = 5,
        .disk = .{ .sector_size = 512, .min_latency_ns = 15 },
        .network = .{ .nodes = 2, .path_capacity = 8 },
        .network_loss = .{ .drop_rate = .oneIn(7) },
        .network_latency = .{ .min_latency_ns = 10, .latency_jitter_ns = 5 },
    }).expand();

    try std.testing.expectEqualStrings("replay", profile.name());
    try std.testing.expectEqual(@as(u64, 512), profile.simulateOptions().disk.sector_size);
    try expectAttribute(profile.runAttributes(), "profile.disk.min_latency_ns", .{ .uint = 15 });
    try expectAttribute(profile.runAttributes(), "profile.network.drop_rate.denominator", .{ .uint = 7 });
    try expectAttribute(profile.runAttributes(), "profile.network.min_latency_ns", .{ .uint = 10 });
}

test "SimProfile: network controls are only reported with a network topology" {
    const profile = SimProfile.swarm(.{
        .network_loss = .{ .drop_rate = .percent(50) },
        .network_latency = .{ .min_latency_ns = 10, .latency_jitter_ns = 5 },
    }).expand();

    try expectAttribute(profile.runAttributes(), "profile.network.enabled", .{ .boolean = false });
    try expectAttribute(profile.runAttributes(), "profile.network.drop_rate.numerator", .{ .uint = 0 });
    try expectAttribute(profile.runAttributes(), "profile.network.drop_rate.denominator", .{ .uint = 1 });
    try expectAttribute(profile.runAttributes(), "profile.network.min_latency_ns", .{ .uint = 0 });
    try expectAttribute(profile.runAttributes(), "profile.network.latency_jitter_ns", .{ .uint = 0 });
}

test "SimProfile: performance defaults to zero disk latency" {
    const baseline = SimProfile.baseline(.{ .tick_ns = 10 }).expand();
    const performance = SimProfile.performance(.{ .tick_ns = 10 }).expand();

    try expectAttribute(baseline.runAttributes(), "profile.disk.min_latency_ns", .{ .uint = 10 });
    try expectAttribute(performance.runAttributes(), "profile.disk.min_latency_ns", .{ .uint = 0 });
    try std.testing.expectEqual(@as(?clock_module.Duration, 0), performance.simulateOptions().disk.min_latency_ns);
}

fn expectAttribute(
    attributes: []const run_types.RunAttribute,
    key: []const u8,
    expected: run_types.RunAttributeValue,
) !void {
    for (attributes) |attribute| {
        if (!std.mem.eql(u8, attribute.key, key)) continue;
        try expectAttributeValue(expected, attribute.value);
        return;
    }
    return error.AttributeMissing;
}

fn expectAttributeValue(expected: run_types.RunAttributeValue, actual: run_types.RunAttributeValue) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .string => |value| try std.testing.expectEqualStrings(value, actual.string),
        .int => |value| try std.testing.expectEqual(value, actual.int),
        .uint => |value| try std.testing.expectEqual(value, actual.uint),
        .boolean => |value| try std.testing.expectEqual(value, actual.boolean),
        .float => |value| try std.testing.expectEqual(value, actual.float),
    }
}
