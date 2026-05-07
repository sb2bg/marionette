//! Unstable deterministic network primitive.
//!
//! This is the first simulation-kernel slice inspired by TigerBeetle's VOPR
//! packet simulator: messages enter deterministic per-link queues, seeded
//! decisions choose loss and latency, link filters and node state can drop
//! packets, and delivery order is keyed by `(deliver_at, packet_id)`.

const std = @import("std");

const clock_module = @import("clock.zig");
const disk_module = @import("disk.zig");
const env_module = @import("env.zig");
const scheduler = @import("scheduler.zig");
const World = @import("world.zig").World;

/// Stable simulated node/process identifier.
pub const NodeId = u16;

/// Errors returned by unstable network runtime validation.
pub const NetworkError = error{
    /// The simulation was not configured with a network.
    NetworkUnavailable,
    /// A typed network handle for this payload already exists in the simulation.
    NetworkHandleAlreadyExists,
    /// A node/process id is outside the configured topology.
    InvalidNode,
    /// A duration is zero where progress requires a positive interval, not
    /// aligned to the world's tick, or would overflow simulated time.
    InvalidDuration,
    /// A send drop rate has an invalid numerator/denominator pair.
    InvalidRate,
    /// A directed path queue is at capacity.
    EventQueueFull,
};

fn validateRate(rate: env_module.BuggifyRate) NetworkError!void {
    if (rate.denominator == 0) return error.InvalidRate;
    if (rate.numerator > rate.denominator) return error.InvalidRate;
}

/// Fixed topology and per-path capacity for one unstable network instance.
pub const NetworkOptions = struct {
    /// Number of simulated service/replica nodes.
    node_count: usize,
    /// Number of simulated client processes. Client ids follow node ids.
    client_count: usize = 0,
    /// Maximum packets queued on one directed path.
    path_capacity: usize,
};

/// Runtime fault configuration for app-facing network sends.
pub const NetworkFaultOptions = struct {
    drop_rate: env_module.BuggifyRate = .never(),
    min_latency_ns: clock_module.Duration = 0,
    latency_jitter_ns: clock_module.Duration = 0,
    path_clog_rate: env_module.BuggifyRate = .never(),
    path_clog_duration_ns: clock_module.Duration = 0,
    partition_rate: env_module.BuggifyRate = .never(),
    unpartition_rate: env_module.BuggifyRate = .never(),
    partition_stability_min_ns: clock_module.Duration = 0,
    unpartition_stability_min_ns: clock_module.Duration = 0,
};

pub const NetworkLossOptions = struct {
    drop_rate: env_module.BuggifyRate = .never(),
};

pub const NetworkLatencyOptions = struct {
    min_latency_ns: clock_module.Duration = 0,
    latency_jitter_ns: clock_module.Duration = 0,
};

pub const NetworkClogOptions = struct {
    path_clog_rate: env_module.BuggifyRate = .never(),
    path_clog_duration_ns: clock_module.Duration = 0,
};

pub const NetworkPartitionDynamicsOptions = struct {
    partition_rate: env_module.BuggifyRate = .never(),
    unpartition_rate: env_module.BuggifyRate = .never(),
    partition_stability_min_ns: clock_module.Duration = 0,
    unpartition_stability_min_ns: clock_module.Duration = 0,
};

/// Runtime topology for a composition-root network simulation.
pub const SimNetworkOptions = struct {
    /// Total simulated processes/nodes.
    nodes: usize,
    /// Prefix of process ids eligible for automatic node-isolating partitions.
    /// Use this when the topology includes client ids that should experience
    /// partitions but should not be selected as the isolated service node.
    /// Defaults to all configured processes when zero.
    service_nodes: usize = 0,
    /// Maximum packets queued on one directed path.
    path_capacity: usize = 64,
};

/// Type-erased simulator-control view for network fault orchestration.
pub const AnyNetworkControl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        set_faults: *const fn (*anyopaque, NetworkFaultOptions) anyerror!void,
        set_lossiness: *const fn (*anyopaque, NetworkLossOptions) anyerror!void,
        set_latency: *const fn (*anyopaque, NetworkLatencyOptions) anyerror!void,
        set_clogs: *const fn (*anyopaque, NetworkClogOptions) anyerror!void,
        set_partition_dynamics: *const fn (*anyopaque, NetworkPartitionDynamicsOptions) anyerror!void,
        set_node: *const fn (*anyopaque, NodeId, bool) anyerror!void,
        set_link: *const fn (*anyopaque, NodeId, NodeId, bool) anyerror!void,
        clog: *const fn (*anyopaque, NodeId, NodeId, clock_module.Duration) anyerror!void,
        unclog: *const fn (*anyopaque, NodeId, NodeId) anyerror!void,
        unclog_all: *const fn (*anyopaque) anyerror!void,
        partition: *const fn (*anyopaque, []const NodeId, []const NodeId) anyerror!void,
        heal: *const fn (*anyopaque) anyerror!void,
        heal_links: *const fn (*anyopaque) anyerror!void,
        evolve_tick_faults: *const fn (*anyopaque) anyerror!void,
        world: *const fn (*anyopaque) ?*World,
        shared: *const fn (*anyopaque) ?*SharedRuntime,
    };

    pub fn unavailable() AnyNetworkControl {
        return .{ .ptr = &unavailable_network_control_ctx, .vtable = &unavailable_network_control_vtable };
    }

    pub fn setFaults(self: AnyNetworkControl, faults: NetworkFaultOptions) !void {
        try self.vtable.set_faults(self.ptr, faults);
    }

    pub fn setLossiness(self: AnyNetworkControl, options: NetworkLossOptions) !void {
        try self.vtable.set_lossiness(self.ptr, options);
    }

    pub fn setLatency(self: AnyNetworkControl, options: NetworkLatencyOptions) !void {
        try self.vtable.set_latency(self.ptr, options);
    }

    pub fn setClogs(self: AnyNetworkControl, options: NetworkClogOptions) !void {
        try self.vtable.set_clogs(self.ptr, options);
    }

    pub fn setPartitionDynamics(self: AnyNetworkControl, options: NetworkPartitionDynamicsOptions) !void {
        try self.vtable.set_partition_dynamics(self.ptr, options);
    }

    pub fn setNode(self: AnyNetworkControl, node: NodeId, up: bool) !void {
        try self.vtable.set_node(self.ptr, node, up);
    }

    pub fn setLink(self: AnyNetworkControl, from: NodeId, to: NodeId, enabled: bool) !void {
        try self.vtable.set_link(self.ptr, from, to, enabled);
    }

    pub fn clog(self: AnyNetworkControl, from: NodeId, to: NodeId, duration_ns: clock_module.Duration) !void {
        try self.vtable.clog(self.ptr, from, to, duration_ns);
    }

    pub fn unclog(self: AnyNetworkControl, from: NodeId, to: NodeId) !void {
        try self.vtable.unclog(self.ptr, from, to);
    }

    pub fn unclogAll(self: AnyNetworkControl) !void {
        try self.vtable.unclog_all(self.ptr);
    }

    pub fn partition(self: AnyNetworkControl, left: []const NodeId, right: []const NodeId) !void {
        try self.vtable.partition(self.ptr, left, right);
    }

    pub fn heal(self: AnyNetworkControl) !void {
        try self.vtable.heal(self.ptr);
    }

    pub fn healLinks(self: AnyNetworkControl) !void {
        try self.vtable.heal_links(self.ptr);
    }

    pub fn evolveTickFaults(self: AnyNetworkControl) !void {
        try self.vtable.evolve_tick_faults(self.ptr);
    }
};

/// Typed app-facing network handle.
pub fn TypedNetwork(comptime Payload: type) type {
    return struct {
        const Self = @This();

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const Packet = struct {
            id: u64,
            from: NodeId,
            to: NodeId,
            deliver_at: clock_module.Timestamp,
            payload: Payload,
        };

        pub const VTable = struct {
            send: *const fn (*anyopaque, NodeId, NodeId, Payload) anyerror!void,
            next_delivery: *const fn (*anyopaque) anyerror!?Packet,
        };

        pub fn send(self: Self, from: NodeId, to: NodeId, payload: Payload) !void {
            try self.vtable.send(self.ptr, from, to, payload);
        }

        pub fn nextDelivery(self: Self) !?Packet {
            return try self.vtable.next_delivery(self.ptr);
        }
    };
}

const SharedRuntime = struct {
    world: *World,
    process_count: usize,
    service_node_count: usize,
    path_capacity: usize,
    faults: NetworkFaultOptions,
    links: []Link,
    down_nodes: []bool,
    typed_handles: std.ArrayList([]const u8) = .empty,
    auto_partitioned_node: ?NodeId = null,
    auto_partition_changed_at_ns: clock_module.Timestamp = 0,

    const Link = struct {
        manual_enabled: bool = true,
        auto_enabled: bool = true,
        clogged_until: clock_module.Timestamp = 0,

        fn enabled(self: Link) bool {
            return self.manual_enabled and self.auto_enabled;
        }
    };

    fn init(world: *World, options: SimNetworkOptions) !*SharedRuntime {
        const service_node_count = try validateTopology(options.nodes, options.service_nodes, options.path_capacity);

        const runtime = try world.allocator.create(SharedRuntime);
        errdefer world.allocator.destroy(runtime);

        const path_count = options.nodes * options.nodes;
        const links = try world.allocator.alloc(Link, path_count);
        errdefer world.allocator.free(links);
        const down_nodes = try world.allocator.alloc(bool, options.nodes);
        errdefer world.allocator.free(down_nodes);

        @memset(links, .{});
        @memset(down_nodes, false);

        runtime.* = .{
            .world = world,
            .process_count = options.nodes,
            .service_node_count = service_node_count,
            .path_capacity = options.path_capacity,
            .faults = .{ .min_latency_ns = world.clock().tick_ns },
            .links = links,
            .down_nodes = down_nodes,
            .auto_partition_changed_at_ns = world.now(),
        };
        try world.registerTeardown(runtime, deinitSharedRuntime);
        return runtime;
    }

    fn deinit(self: *SharedRuntime, allocator: std.mem.Allocator) void {
        self.typed_handles.deinit(allocator);
        allocator.free(self.links);
        allocator.free(self.down_nodes);
        self.* = undefined;
    }

    fn control(self: *SharedRuntime) AnyNetworkControl {
        return .{ .ptr = self, .vtable = &shared_control_vtable };
    }

    fn claimTypedHandle(self: *SharedRuntime, comptime Payload: type) !void {
        const payload_name = @typeName(Payload);
        for (self.typed_handles.items) |existing| {
            if (std.mem.eql(u8, existing, payload_name)) return error.NetworkHandleAlreadyExists;
        }
        try self.typed_handles.append(self.world.allocator, payload_name);
    }

    fn releaseTypedHandle(self: *SharedRuntime, comptime Payload: type) void {
        const payload_name = @typeName(Payload);
        for (self.typed_handles.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, payload_name)) {
                _ = self.typed_handles.swapRemove(index);
                return;
            }
        }
    }

    fn pathIndex(self: *const SharedRuntime, from: NodeId, to: NodeId) NetworkError!usize {
        try self.validateNode(from);
        try self.validateNode(to);
        return @as(usize, from) * self.process_count + @as(usize, to);
    }

    fn validateNode(self: *const SharedRuntime, node: NodeId) NetworkError!void {
        if (@as(usize, node) >= self.process_count) return error.InvalidNode;
    }

    fn validateNodes(self: *const SharedRuntime, nodes: []const NodeId) NetworkError!void {
        for (nodes) |node| try self.validateNode(node);
    }

    fn validatePositiveTickDuration(self: *const SharedRuntime, duration_ns: clock_module.Duration) NetworkError!void {
        if (duration_ns == 0) return error.InvalidDuration;
        if (duration_ns % self.world.clock().tick_ns != 0) return error.InvalidDuration;
    }

    fn validateFaultLatency(self: *const SharedRuntime, faults: NetworkFaultOptions) NetworkError!void {
        const tick_ns = self.world.clock().tick_ns;
        if (faults.min_latency_ns % tick_ns != 0) return error.InvalidDuration;
        if (faults.latency_jitter_ns % tick_ns != 0) return error.InvalidDuration;
    }

    fn validateFaultProfile(self: *const SharedRuntime, faults: NetworkFaultOptions) !void {
        try validateRate(faults.drop_rate);
        try validateRate(faults.path_clog_rate);
        try validateRate(faults.partition_rate);
        try validateRate(faults.unpartition_rate);
        try self.validateFaultLatency(faults);
        if (faults.path_clog_rate.numerator > 0) {
            try self.validatePositiveTickDuration(faults.path_clog_duration_ns);
        } else if (faults.path_clog_duration_ns != 0 and faults.path_clog_duration_ns % self.world.clock().tick_ns != 0) {
            return error.InvalidDuration;
        }
        try self.validateTickAlignedDuration(faults.partition_stability_min_ns);
        try self.validateTickAlignedDuration(faults.unpartition_stability_min_ns);
    }

    fn validateTickAlignedDuration(self: *const SharedRuntime, duration_ns: clock_module.Duration) NetworkError!void {
        if (duration_ns % self.world.clock().tick_ns != 0) return error.InvalidDuration;
    }

    fn validateClogs(self: *const SharedRuntime, options: NetworkClogOptions) !void {
        try validateRate(options.path_clog_rate);
        if (options.path_clog_rate.numerator > 0) {
            try self.validatePositiveTickDuration(options.path_clog_duration_ns);
        } else if (options.path_clog_duration_ns != 0 and options.path_clog_duration_ns % self.world.clock().tick_ns != 0) {
            return error.InvalidDuration;
        }
    }

    fn validatePartitionDynamics(self: *const SharedRuntime, options: NetworkPartitionDynamicsOptions) !void {
        try validateRate(options.partition_rate);
        try validateRate(options.unpartition_rate);
        try self.validateTickAlignedDuration(options.partition_stability_min_ns);
        try self.validateTickAlignedDuration(options.unpartition_stability_min_ns);
    }

    fn setFaults(self: *SharedRuntime, faults: NetworkFaultOptions) !void {
        try self.validateFaultProfile(faults);
        self.faults = faults;
        try self.world.record(
            "network.faults drop_rate={}/{} min_latency_ns={} latency_jitter_ns={} path_clog_rate={}/{} path_clog_duration_ns={} partition_rate={}/{} unpartition_rate={}/{} partition_stability_min_ns={} unpartition_stability_min_ns={}",
            .{
                faults.drop_rate.numerator,
                faults.drop_rate.denominator,
                faults.min_latency_ns,
                faults.latency_jitter_ns,
                faults.path_clog_rate.numerator,
                faults.path_clog_rate.denominator,
                faults.path_clog_duration_ns,
                faults.partition_rate.numerator,
                faults.partition_rate.denominator,
                faults.unpartition_rate.numerator,
                faults.unpartition_rate.denominator,
                faults.partition_stability_min_ns,
                faults.unpartition_stability_min_ns,
            },
        );
    }

    fn setLossiness(self: *SharedRuntime, options: NetworkLossOptions) !void {
        try validateRate(options.drop_rate);
        self.faults.drop_rate = options.drop_rate;
        try self.world.record(
            "network.lossiness drop_rate={}/{}",
            .{ options.drop_rate.numerator, options.drop_rate.denominator },
        );
    }

    fn setLatency(self: *SharedRuntime, options: NetworkLatencyOptions) !void {
        var faults = self.faults;
        faults.min_latency_ns = options.min_latency_ns;
        faults.latency_jitter_ns = options.latency_jitter_ns;
        try self.validateFaultLatency(faults);
        self.faults.min_latency_ns = options.min_latency_ns;
        self.faults.latency_jitter_ns = options.latency_jitter_ns;
        try self.world.record(
            "network.latency min_latency_ns={} latency_jitter_ns={}",
            .{ options.min_latency_ns, options.latency_jitter_ns },
        );
    }

    fn setClogs(self: *SharedRuntime, options: NetworkClogOptions) !void {
        try self.validateClogs(options);
        self.faults.path_clog_rate = options.path_clog_rate;
        self.faults.path_clog_duration_ns = options.path_clog_duration_ns;
        try self.world.record(
            "network.clog_faults path_clog_rate={}/{} path_clog_duration_ns={}",
            .{ options.path_clog_rate.numerator, options.path_clog_rate.denominator, options.path_clog_duration_ns },
        );
    }

    fn setPartitionDynamics(self: *SharedRuntime, options: NetworkPartitionDynamicsOptions) !void {
        try self.validatePartitionDynamics(options);
        self.faults.partition_rate = options.partition_rate;
        self.faults.unpartition_rate = options.unpartition_rate;
        self.faults.partition_stability_min_ns = options.partition_stability_min_ns;
        self.faults.unpartition_stability_min_ns = options.unpartition_stability_min_ns;
        try self.world.record(
            "network.partition_dynamics partition_rate={}/{} unpartition_rate={}/{} partition_stability_min_ns={} unpartition_stability_min_ns={}",
            .{
                options.partition_rate.numerator,
                options.partition_rate.denominator,
                options.unpartition_rate.numerator,
                options.unpartition_rate.denominator,
                options.partition_stability_min_ns,
                options.unpartition_stability_min_ns,
            },
        );
    }

    fn setNode(self: *SharedRuntime, node: NodeId, up: bool) !void {
        try self.validateNode(node);
        self.down_nodes[@intCast(node)] = !up;
        try self.world.record("network.node node={} up={}", .{ node, up });
    }

    fn setLink(self: *SharedRuntime, from: NodeId, to: NodeId, enabled: bool) !void {
        self.links[try self.pathIndex(from, to)].manual_enabled = enabled;
        try self.world.record("network.link from={} to={} enabled={}", .{ from, to, enabled });
    }

    fn clog(self: *SharedRuntime, from: NodeId, to: NodeId, duration_ns: clock_module.Duration) !void {
        try self.validatePositiveTickDuration(duration_ns);
        if (std.math.maxInt(clock_module.Timestamp) - self.world.now() < duration_ns) {
            return error.InvalidDuration;
        }

        const until = self.world.now() + duration_ns;
        const link = &self.links[try self.pathIndex(from, to)];
        link.clogged_until = @max(link.clogged_until, until);
        try self.world.record(
            "network.clog from={} to={} duration_ns={} until_ns={}",
            .{ from, to, duration_ns, link.clogged_until },
        );
    }

    fn unclog(self: *SharedRuntime, from: NodeId, to: NodeId) !void {
        const link = &self.links[try self.pathIndex(from, to)];
        const active = link.clogged_until > self.world.now();
        link.clogged_until = 0;
        try self.world.record("network.unclog from={} to={} active={}", .{ from, to, active });
    }

    fn unclogAll(self: *SharedRuntime) !void {
        const clogged_count = self.cloggedLinkCount();
        for (self.links) |*link| link.clogged_until = 0;
        try self.world.record("network.unclog_all clogged_count={}", .{clogged_count});
    }

    fn partition(self: *SharedRuntime, left: []const NodeId, right: []const NodeId) !void {
        try self.validateNodes(left);
        try self.validateNodes(right);
        try self.world.record("network.partition left_count={} right_count={}", .{ left.len, right.len });
        for (left) |from| {
            for (right) |to| {
                self.links[try self.pathIndex(from, to)].manual_enabled = false;
                self.links[try self.pathIndex(to, from)].manual_enabled = false;
            }
        }
    }

    fn heal(self: *SharedRuntime) !void {
        const disabled_count = self.disabledLinkCount();
        const down_count = self.downNodeCount();
        const clogged_count = self.cloggedLinkCount();
        for (self.links) |*link| {
            link.manual_enabled = true;
            link.auto_enabled = true;
            link.clogged_until = 0;
        }
        @memset(self.down_nodes, false);
        self.auto_partitioned_node = null;
        self.auto_partition_changed_at_ns = self.world.now();
        try self.world.record(
            "network.heal disabled_count={} down_count={} clogged_count={}",
            .{ disabled_count, down_count, clogged_count },
        );
    }

    fn healLinks(self: *SharedRuntime) !void {
        const disabled_count = self.disabledLinkCount();
        for (self.links) |*link| {
            link.manual_enabled = true;
            link.auto_enabled = true;
        }
        self.auto_partitioned_node = null;
        self.auto_partition_changed_at_ns = self.world.now();
        try self.world.record("network.heal_links disabled_count={}", .{disabled_count});
    }

    fn expireDeterministicFaults(self: *SharedRuntime) !void {
        const now_ns = self.world.now();
        for (self.links, 0..) |*link, index| {
            if (link.clogged_until == 0 or link.clogged_until > now_ns) continue;
            const from: NodeId = @intCast(index / self.process_count);
            const to: NodeId = @intCast(index % self.process_count);
            link.clogged_until = 0;
            try self.world.record("network.unclog from={} to={} active=false", .{ from, to });
        }
    }

    fn evolveTickFaults(self: *SharedRuntime) !void {
        try self.expireDeterministicFaults();
        try self.evolveAutoPartition();
        try self.evolveAutoClogs();
    }

    fn evolveAutoClogs(self: *SharedRuntime) !void {
        const faults = self.faults;
        if (faults.path_clog_rate.numerator == 0) return;

        const now_ns = self.world.now();
        for (self.links, 0..) |*link, index| {
            if (link.clogged_until > now_ns) continue;
            if (!try self.roll(faults.path_clog_rate)) continue;
            if (std.math.maxInt(clock_module.Timestamp) - now_ns < faults.path_clog_duration_ns) {
                return error.InvalidDuration;
            }

            const from: NodeId = @intCast(index / self.process_count);
            const to: NodeId = @intCast(index % self.process_count);
            link.clogged_until = now_ns + faults.path_clog_duration_ns;
            try self.world.record(
                "network.clog from={} to={} duration_ns={} until_ns={} automatic=true",
                .{ from, to, faults.path_clog_duration_ns, link.clogged_until },
            );
        }
    }

    fn evolveAutoPartition(self: *SharedRuntime) !void {
        const faults = self.faults;
        if (self.auto_partitioned_node) |node| {
            if (!self.durationSinceAutoPartitionChangeAtLeast(faults.unpartition_stability_min_ns)) return;
            if (faults.unpartition_rate.numerator == 0 or !try self.roll(faults.unpartition_rate)) return;
            self.clearAutoPartitionLinks();
            self.auto_partitioned_node = null;
            self.auto_partition_changed_at_ns = self.world.now();
            try self.world.record("network.auto_heal node={}", .{node});
            return;
        }

        if (!self.durationSinceAutoPartitionChangeAtLeast(faults.partition_stability_min_ns)) return;
        if (faults.partition_rate.numerator == 0 or !try self.roll(faults.partition_rate)) return;

        const isolated_index = try self.world.randomIntLessThan(usize, self.service_node_count);
        const isolated: NodeId = @intCast(isolated_index);
        self.applyAutoPartition(isolated);
        self.auto_partitioned_node = isolated;
        self.auto_partition_changed_at_ns = self.world.now();
        try self.world.record(
            "network.auto_partition node={} isolated_count=1 connected_count={}",
            .{ isolated, self.process_count - 1 },
        );
    }

    fn durationSinceAutoPartitionChangeAtLeast(self: *SharedRuntime, duration_ns: clock_module.Duration) bool {
        return self.world.now() - self.auto_partition_changed_at_ns >= duration_ns;
    }

    fn roll(self: *SharedRuntime, rate: env_module.BuggifyRate) !bool {
        const roll_value = try self.world.randomIntLessThan(u32, rate.denominator);
        return roll_value < rate.numerator;
    }

    fn clearAutoPartitionLinks(self: *SharedRuntime) void {
        for (self.links) |*link| link.auto_enabled = true;
    }

    fn applyAutoPartition(self: *SharedRuntime, isolated: NodeId) void {
        self.clearAutoPartitionLinks();
        for (0..self.process_count) |other_index| {
            if (other_index == isolated) continue;
            const other: NodeId = @intCast(other_index);
            self.links[self.pathIndex(isolated, other) catch unreachable].auto_enabled = false;
            self.links[self.pathIndex(other, isolated) catch unreachable].auto_enabled = false;
        }
    }

    fn disabledLinkCount(self: *const SharedRuntime) usize {
        var count: usize = 0;
        for (self.links) |link| {
            if (!link.enabled()) count += 1;
        }
        return count;
    }

    fn downNodeCount(self: *const SharedRuntime) usize {
        var count: usize = 0;
        for (self.down_nodes) |down| {
            if (down) count += 1;
        }
        return count;
    }

    fn cloggedLinkCount(self: *const SharedRuntime) usize {
        var count: usize = 0;
        const now_ns = self.world.now();
        for (self.links) |link| {
            if (link.clogged_until > now_ns) count += 1;
        }
        return count;
    }
};

fn validateTopology(nodes: usize, service_nodes: usize, path_capacity: usize) NetworkError!usize {
    if (nodes == 0 or nodes > @as(usize, std.math.maxInt(NodeId)) + 1) return error.InvalidNode;
    if (service_nodes > nodes) return error.InvalidNode;
    if (path_capacity == 0) return error.EventQueueFull;
    return if (service_nodes == 0) nodes else service_nodes;
}

fn deinitSharedRuntime(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const runtime: *SharedRuntime = @ptrCast(@alignCast(ptr));
    runtime.deinit(allocator);
    allocator.destroy(runtime);
}

fn sharedControl(ptr: *anyopaque) *SharedRuntime {
    return @ptrCast(@alignCast(ptr));
}

const shared_control_vtable: AnyNetworkControl.VTable = .{
    .set_faults = sharedControlSetFaults,
    .set_lossiness = sharedControlSetLossiness,
    .set_latency = sharedControlSetLatency,
    .set_clogs = sharedControlSetClogs,
    .set_partition_dynamics = sharedControlSetPartitionDynamics,
    .set_node = sharedControlSetNode,
    .set_link = sharedControlSetLink,
    .clog = sharedControlClog,
    .unclog = sharedControlUnclog,
    .unclog_all = sharedControlUnclogAll,
    .partition = sharedControlPartition,
    .heal = sharedControlHeal,
    .heal_links = sharedControlHealLinks,
    .evolve_tick_faults = sharedControlEvolveTickFaults,
    .world = sharedControlWorld,
    .shared = sharedControlShared,
};

fn sharedControlSetFaults(ptr: *anyopaque, faults: NetworkFaultOptions) anyerror!void {
    try sharedControl(ptr).setFaults(faults);
}

fn sharedControlSetLossiness(ptr: *anyopaque, options: NetworkLossOptions) anyerror!void {
    try sharedControl(ptr).setLossiness(options);
}

fn sharedControlSetLatency(ptr: *anyopaque, options: NetworkLatencyOptions) anyerror!void {
    try sharedControl(ptr).setLatency(options);
}

fn sharedControlSetClogs(ptr: *anyopaque, options: NetworkClogOptions) anyerror!void {
    try sharedControl(ptr).setClogs(options);
}

fn sharedControlSetPartitionDynamics(ptr: *anyopaque, options: NetworkPartitionDynamicsOptions) anyerror!void {
    try sharedControl(ptr).setPartitionDynamics(options);
}

fn sharedControlSetNode(ptr: *anyopaque, node: NodeId, up: bool) anyerror!void {
    try sharedControl(ptr).setNode(node, up);
}

fn sharedControlSetLink(ptr: *anyopaque, from: NodeId, to: NodeId, enabled: bool) anyerror!void {
    try sharedControl(ptr).setLink(from, to, enabled);
}

fn sharedControlClog(ptr: *anyopaque, from: NodeId, to: NodeId, duration_ns: clock_module.Duration) anyerror!void {
    try sharedControl(ptr).clog(from, to, duration_ns);
}

fn sharedControlUnclog(ptr: *anyopaque, from: NodeId, to: NodeId) anyerror!void {
    try sharedControl(ptr).unclog(from, to);
}

fn sharedControlUnclogAll(ptr: *anyopaque) anyerror!void {
    try sharedControl(ptr).unclogAll();
}

fn sharedControlPartition(ptr: *anyopaque, left: []const NodeId, right: []const NodeId) anyerror!void {
    try sharedControl(ptr).partition(left, right);
}

fn sharedControlHeal(ptr: *anyopaque) anyerror!void {
    try sharedControl(ptr).heal();
}

fn sharedControlHealLinks(ptr: *anyopaque) anyerror!void {
    try sharedControl(ptr).healLinks();
}

fn sharedControlEvolveTickFaults(ptr: *anyopaque) anyerror!void {
    try sharedControl(ptr).evolveTickFaults();
}

fn sharedControlWorld(ptr: *anyopaque) ?*World {
    return sharedControl(ptr).world;
}

fn sharedControlShared(ptr: *anyopaque) ?*SharedRuntime {
    return sharedControl(ptr);
}

var unavailable_network_control_ctx: u8 = 0;

const unavailable_network_control_vtable: AnyNetworkControl.VTable = .{
    .set_faults = unavailableControlSetFaults,
    .set_lossiness = unavailableControlSetLossiness,
    .set_latency = unavailableControlSetLatency,
    .set_clogs = unavailableControlSetClogs,
    .set_partition_dynamics = unavailableControlSetPartitionDynamics,
    .set_node = unavailableControlSetNode,
    .set_link = unavailableControlSetLink,
    .clog = unavailableControlClog,
    .unclog = unavailableControlUnclog,
    .unclog_all = unavailableControlUnclogAll,
    .partition = unavailableControlPartition,
    .heal = unavailableControlHeal,
    .heal_links = unavailableControlHealLinks,
    .evolve_tick_faults = unavailableControlEvolveTickFaults,
    .world = unavailableControlWorld,
    .shared = unavailableControlShared,
};

fn unavailableControlSetFaults(_: *anyopaque, _: NetworkFaultOptions) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetLossiness(_: *anyopaque, _: NetworkLossOptions) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetLatency(_: *anyopaque, _: NetworkLatencyOptions) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetClogs(_: *anyopaque, _: NetworkClogOptions) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetPartitionDynamics(_: *anyopaque, _: NetworkPartitionDynamicsOptions) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetNode(_: *anyopaque, _: NodeId, _: bool) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlSetLink(_: *anyopaque, _: NodeId, _: NodeId, _: bool) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlClog(_: *anyopaque, _: NodeId, _: NodeId, _: clock_module.Duration) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlUnclog(_: *anyopaque, _: NodeId, _: NodeId) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlUnclogAll(_: *anyopaque) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlPartition(_: *anyopaque, _: []const NodeId, _: []const NodeId) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlHeal(_: *anyopaque) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlHealLinks(_: *anyopaque) anyerror!void {
    return error.NetworkUnavailable;
}

fn unavailableControlEvolveTickFaults(_: *anyopaque) anyerror!void {}

fn unavailableControlWorld(_: *anyopaque) ?*World {
    return null;
}

fn unavailableControlShared(_: *anyopaque) ?*SharedRuntime {
    return null;
}

pub fn initSimControl(world: *World, options: SimNetworkOptions) !AnyNetworkControl {
    const shared = try SharedRuntime.init(world, options);
    return shared.control();
}

pub fn networkFromControl(comptime Payload: type, control: AnyNetworkControl) !TypedNetwork(Payload) {
    const shared = control.vtable.shared(control.ptr) orelse return error.NetworkUnavailable;
    return try TypedRuntime(Payload).init(shared);
}

pub const ProductionNetworkTeardown = struct {
    ptr: *anyopaque,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub fn ProductionNetworkInit(comptime Payload: type) type {
    return struct {
        network: TypedNetwork(Payload),
        teardown: ProductionNetworkTeardown,
    };
}

pub fn initProductionNetwork(comptime Payload: type, allocator: std.mem.Allocator) std.mem.Allocator.Error!ProductionNetworkInit(Payload) {
    return try ProductionRuntime(Payload).init(allocator);
}

fn TypedRuntime(comptime Payload: type) type {
    const Handle = TypedNetwork(Payload);
    const Packet = Handle.Packet;

    return struct {
        const Self = @This();

        shared: *SharedRuntime,
        queues: []std.ArrayList(Packet),
        next_packet_id: u64 = 0,

        fn init(shared: *SharedRuntime) !Handle {
            try shared.claimTypedHandle(Payload);
            errdefer shared.releaseTypedHandle(Payload);

            const allocator = shared.world.allocator;
            const runtime = try allocator.create(Self);
            errdefer allocator.destroy(runtime);

            const path_count = shared.process_count * shared.process_count;
            const queues = try allocator.alloc(std.ArrayList(Packet), path_count);
            errdefer allocator.free(queues);
            @memset(queues, .empty);

            runtime.* = .{
                .shared = shared,
                .queues = queues,
            };
            try shared.world.registerTeardown(runtime, deinit);

            return .{ .ptr = runtime, .vtable = &vtable };
        }

        fn send(self: *Self, from: NodeId, to: NodeId, payload: Payload) !void {
            const shared = self.shared;
            try shared.validateNode(from);
            try shared.validateNode(to);
            try validateRate(shared.faults.drop_rate);
            try shared.validateFaultLatency(shared.faults);

            const packet_id = self.next_packet_id;
            self.next_packet_id += 1;

            if (shared.down_nodes[@intCast(from)]) {
                try shared.world.record("network.drop id={} from={} to={} reason=source_down", .{ packet_id, from, to });
                return;
            }

            const drop_roll = try shared.world.randomIntLessThan(u32, shared.faults.drop_rate.denominator);
            if (drop_roll < shared.faults.drop_rate.numerator) {
                try shared.world.record(
                    "network.drop id={} from={} to={} drop_rate={}/{} roll={} reason=send_drop",
                    .{ packet_id, from, to, shared.faults.drop_rate.numerator, shared.faults.drop_rate.denominator, drop_roll },
                );
                return;
            }

            const latency_ns = try self.latency();
            if (std.math.maxInt(clock_module.Timestamp) - shared.world.now() < latency_ns) {
                return error.InvalidDuration;
            }

            const packet: Packet = .{
                .id = packet_id,
                .from = from,
                .to = to,
                .deliver_at = shared.world.now() + latency_ns,
                .payload = payload,
            };

            const queue = &self.queues[try shared.pathIndex(from, to)];
            if (queue.items.len >= shared.path_capacity) return error.EventQueueFull;
            try queue.append(shared.world.allocator, packet);
            var index = queue.items.len - 1;
            while (index > 0 and packetLessThan(queue.items[index], queue.items[index - 1])) : (index -= 1) {
                std.mem.swap(Packet, &queue.items[index], &queue.items[index - 1]);
            }

            try shared.world.record(
                "network.send id={} from={} to={} deliver_at={} latency_ns={}",
                .{ packet.id, packet.from, packet.to, packet.deliver_at, latency_ns },
            );
        }

        fn nextDelivery(self: *Self) !?Packet {
            while (true) {
                try self.shared.expireDeterministicFaults();
                if (try self.popReady()) |packet| return packet;

                const deliver_at = self.nextDeliveryAt() orelse return null;
                const now_ns = self.shared.world.now();
                if (deliver_at <= now_ns) return null;
                try self.runForDeterministicFaults(deliver_at - now_ns);
            }
        }

        fn popReady(self: *Self) !?Packet {
            while (true) {
                const link_index = self.nextReadyLinkIndex() orelse return null;
                const ready = self.queues[link_index].orderedRemove(0);

                if (self.shared.down_nodes[@intCast(ready.to)]) {
                    try self.shared.world.record("network.drop id={} from={} to={} reason=destination_down", .{ ready.id, ready.from, ready.to });
                    continue;
                }

                const link = self.shared.links[try self.shared.pathIndex(ready.from, ready.to)];
                if (!link.enabled()) {
                    try self.shared.world.record("network.drop id={} from={} to={} reason=link_disabled", .{ ready.id, ready.from, ready.to });
                    continue;
                }

                try self.shared.world.record("network.deliver id={} from={} to={} now_ns={}", .{ ready.id, ready.from, ready.to, self.shared.world.now() });
                return ready;
            }
        }

        fn nextDeliveryAt(self: *const Self) ?clock_module.Timestamp {
            var best: ?clock_module.Timestamp = null;
            for (self.queues, 0..) |queue, index| {
                const packet = if (queue.items.len == 0) continue else queue.items[0];
                const ready_at = @max(packet.deliver_at, self.shared.links[index].clogged_until);
                if (best == null or ready_at < best.?) best = ready_at;
            }
            return best;
        }

        fn nextReadyLinkIndex(self: *const Self) ?usize {
            var best_index: ?usize = null;
            var best_packet: Packet = undefined;
            for (self.queues, 0..) |queue, index| {
                if (queue.items.len == 0) continue;
                const packet = queue.items[0];
                if (packet.deliver_at > self.shared.world.now()) continue;
                if (self.shared.links[index].clogged_until > self.shared.world.now()) continue;
                if (best_index == null or packetLessThan(packet, best_packet)) {
                    best_index = index;
                    best_packet = packet;
                }
            }
            return best_index;
        }

        fn latency(self: *Self) !clock_module.Duration {
            const faults = self.shared.faults;
            const tick_ns = self.shared.world.clock().tick_ns;
            if (faults.latency_jitter_ns == 0) return faults.min_latency_ns;

            const jitter_ticks = try self.shared.world.randomIntLessThan(
                clock_module.Duration,
                faults.latency_jitter_ns / tick_ns + 1,
            );
            return faults.min_latency_ns + jitter_ticks * tick_ns;
        }

        fn runForDeterministicFaults(self: *Self, duration_ns: clock_module.Duration) !void {
            const tick_ns = self.shared.world.clock().tick_ns;
            if (duration_ns % tick_ns != 0) return error.InvalidDuration;
            var remaining = duration_ns;
            while (remaining > 0) : (remaining -= tick_ns) {
                try self.shared.world.tick();
                try self.shared.expireDeterministicFaults();
            }
        }

        fn packetLessThan(a: Packet, b: Packet) bool {
            return a.deliver_at < b.deliver_at or
                (a.deliver_at == b.deliver_at and a.id < b.id);
        }

        fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const runtime: *Self = @ptrCast(@alignCast(ptr));
            for (runtime.queues) |*queue| queue.deinit(allocator);
            allocator.free(runtime.queues);
            runtime.shared.releaseTypedHandle(Payload);
            allocator.destroy(runtime);
        }

        fn fromOpaque(ptr: *anyopaque) *Self {
            return @ptrCast(@alignCast(ptr));
        }

        fn vtableSend(ptr: *anyopaque, from: NodeId, to: NodeId, payload: Payload) anyerror!void {
            try fromOpaque(ptr).send(from, to, payload);
        }

        fn vtableNextDelivery(ptr: *anyopaque) anyerror!?Packet {
            return try fromOpaque(ptr).nextDelivery();
        }

        const vtable: Handle.VTable = .{
            .send = vtableSend,
            .next_delivery = vtableNextDelivery,
        };
    };
}

fn ProductionRuntime(comptime Payload: type) type {
    const Handle = TypedNetwork(Payload);
    const Packet = Handle.Packet;

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        queue: std.ArrayList(Packet) = .empty,
        next_packet_id: u64 = 0,

        fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!ProductionNetworkInit(Payload) {
            const runtime = try allocator.create(Self);
            runtime.* = .{ .allocator = allocator };

            return .{
                .network = .{ .ptr = runtime, .vtable = &vtable },
                .teardown = .{ .ptr = runtime, .deinit = deinitOpaque },
            };
        }

        fn send(self: *Self, from: NodeId, to: NodeId, payload: Payload) !void {
            const packet: Packet = .{
                .id = self.next_packet_id,
                .from = from,
                .to = to,
                .deliver_at = 0,
                .payload = payload,
            };
            self.next_packet_id += 1;
            try self.queue.append(self.allocator, packet);
        }

        fn nextDelivery(self: *Self) !?Packet {
            if (self.queue.items.len == 0) return null;
            return self.queue.orderedRemove(0);
        }

        fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
            const allocator = self.allocator;
            self.* = undefined;
            allocator.destroy(self);
        }

        fn deinitOpaque(ptr: *anyopaque, _: std.mem.Allocator) void {
            fromOpaque(ptr).deinit();
        }

        fn fromOpaque(ptr: *anyopaque) *Self {
            return @ptrCast(@alignCast(ptr));
        }

        fn vtableSend(ptr: *anyopaque, from: NodeId, to: NodeId, payload: Payload) anyerror!void {
            try fromOpaque(ptr).send(from, to, payload);
        }

        fn vtableNextDelivery(ptr: *anyopaque) anyerror!?Packet {
            return try fromOpaque(ptr).nextDelivery();
        }

        const vtable: Handle.VTable = .{
            .send = vtableSend,
            .next_delivery = vtableNextDelivery,
        };
    };
}

/// Build a fixed-topology deterministic network for one payload type.
pub fn UnstableNetwork(comptime Payload: type, comptime network_options: NetworkOptions) type {
    const configured_process_count = network_options.node_count + network_options.client_count;
    comptime {
        if (network_options.node_count == 0) {
            @compileError("network_options.node_count must be greater than zero");
        }
        if (network_options.path_capacity == 0) {
            @compileError("network_options.path_capacity must be greater than zero");
        }
        if (configured_process_count == 0 or configured_process_count > @as(usize, std.math.maxInt(NodeId)) + 1) {
            @compileError("network topology does not fit in NodeId");
        }
    }

    return struct {
        const Self = @This();

        pub const process_count = configured_process_count;
        pub const path_count = process_count * process_count;
        pub const Error = NetworkError || scheduler.EventQueueError;

        /// Simulator-control view for network fault orchestration.
        pub const Control = struct {
            network: *Self,

            /// Mark one simulated node/process up or down.
            pub fn setNode(self: Control, node: NodeId, up: bool) !void {
                try self.network.setNode(node, up);
            }

            /// Enable or disable one directed link.
            pub fn setLink(self: Control, from: NodeId, to: NodeId, enabled: bool) !void {
                try self.network.setLink(from, to, enabled);
            }

            /// Clog one directed path until simulated time advances by `duration_ns`.
            pub fn clog(self: Control, from: NodeId, to: NodeId, duration_ns: clock_module.Duration) !void {
                try self.network.clog(from, to, duration_ns);
            }

            /// Clear one directed path clog.
            pub fn unclog(self: Control, from: NodeId, to: NodeId) !void {
                try self.network.unclog(from, to);
            }

            /// Clear every directed path clog.
            pub fn unclogAll(self: Control) !void {
                try self.network.unclogAll();
            }

            /// Disable all directed links crossing between two groups.
            pub fn partition(
                self: Control,
                left: []const NodeId,
                right: []const NodeId,
            ) !void {
                try self.network.partition(left, right);
            }

            /// Re-enable every disabled link and mark every node/process up.
            pub fn heal(self: Control) !void {
                try self.network.heal();
            }

            /// Re-enable every disabled link without changing node state.
            pub fn healLinks(self: Control) !void {
                try self.network.healLinks();
            }
        };

        /// Packet delivered by `popReady`.
        pub const Packet = struct {
            id: u64,
            from: NodeId,
            to: NodeId,
            deliver_at: clock_module.Timestamp,
            payload: Payload,
        };

        /// Send-time network fault and latency options.
        pub const SendOptions = struct {
            drop_rate: env_module.BuggifyRate = .never(),
            min_latency_ns: clock_module.Duration = clock_module.default_tick_ns,
            latency_jitter_ns: clock_module.Duration = 0,
        };

        const Queue = scheduler.EventQueue(Packet, network_options.path_capacity, packetLessThan);

        const Link = struct {
            enabled: bool = true,
            clogged_until: clock_module.Timestamp = 0,
            pending: Queue = .init(),
        };

        world: *World,
        links: [path_count]Link = defaultLinks(),
        down_nodes: [process_count]bool = @splat(false),
        next_packet_id: u64 = 0,

        /// Construct an empty network.
        pub fn init(world: *World) Self {
            return .{ .world = world };
        }

        /// Return the simulator-control view for network faults.
        pub fn control(self: *Self) Control {
            return .{ .network = self };
        }

        /// Count configured service/replica nodes.
        pub fn nodeCount(_: *const Self) usize {
            return network_options.node_count;
        }

        /// Count configured client processes.
        pub fn clientCount(_: *const Self) usize {
            return network_options.client_count;
        }

        /// Count all configured processes.
        pub fn processCount(_: *const Self) usize {
            return process_count;
        }

        /// Count queued, undelivered packets across every directed path.
        pub fn pendingCount(self: *const Self) usize {
            var count: usize = 0;
            for (&self.links) |*link| count += link.pending.count();
            return count;
        }

        /// Return the timestamp of the next queued packet, if any.
        pub fn nextDeliveryAt(self: *const Self) ?clock_module.Timestamp {
            var best: ?clock_module.Timestamp = null;
            for (&self.links) |*link| {
                const packet = link.pending.peek() orelse continue;
                const ready_at = @max(packet.deliver_at, link.clogged_until);
                if (best == null or ready_at < best.?) best = ready_at;
            }
            return best;
        }

        /// Return whether a directed link is currently enabled.
        pub fn linkEnabled(self: *const Self, from: NodeId, to: NodeId) NetworkError!bool {
            return self.links[try self.pathIndex(from, to)].enabled;
        }

        /// Return whether a simulated node/process is currently up.
        pub fn nodeUp(self: *const Self, node: NodeId) NetworkError!bool {
            try self.validateNode(node);
            return !self.down_nodes[@intCast(node)];
        }

        fn setNode(self: *Self, node: NodeId, up: bool) !void {
            try self.validateNode(node);
            self.down_nodes[@intCast(node)] = !up;

            try self.world.record(
                "network.node node={} up={}",
                .{ node, up },
            );
        }

        fn setLink(self: *Self, from: NodeId, to: NodeId, enabled: bool) !void {
            try self.setLinkState(from, to, enabled);
            try self.world.record(
                "network.link from={} to={} enabled={}",
                .{ from, to, enabled },
            );
        }

        fn clog(self: *Self, from: NodeId, to: NodeId, duration_ns: clock_module.Duration) !void {
            try self.validatePositiveTickDuration(duration_ns);
            if (std.math.maxInt(clock_module.Timestamp) - self.world.now() < duration_ns) {
                return error.InvalidDuration;
            }

            const until = self.world.now() + duration_ns;
            const link = &self.links[try self.pathIndex(from, to)];
            link.clogged_until = @max(link.clogged_until, until);

            try self.world.record(
                "network.clog from={} to={} duration_ns={} until_ns={}",
                .{ from, to, duration_ns, link.clogged_until },
            );
        }

        fn unclog(self: *Self, from: NodeId, to: NodeId) !void {
            const link = &self.links[try self.pathIndex(from, to)];
            const active = link.clogged_until > self.world.now();
            link.clogged_until = 0;

            try self.world.record(
                "network.unclog from={} to={} active={}",
                .{ from, to, active },
            );
        }

        fn unclogAll(self: *Self) !void {
            const clogged_count = self.cloggedLinkCount();
            self.clearClogs();
            try self.world.record(
                "network.unclog_all clogged_count={}",
                .{clogged_count},
            );
        }

        fn partition(
            self: *Self,
            left: []const NodeId,
            right: []const NodeId,
        ) !void {
            try self.validateNodes(left);
            try self.validateNodes(right);

            try self.world.record(
                "network.partition left_count={} right_count={}",
                .{ left.len, right.len },
            );
            for (left) |from| {
                for (right) |to| {
                    try self.setLinkState(from, to, false);
                    try self.setLinkState(to, from, false);
                }
            }
        }

        fn heal(self: *Self) !void {
            const disabled_count = self.disabledLinkCount();
            const down_count = self.downNodeCount();
            const clogged_count = self.cloggedLinkCount();
            self.clearDisabledLinks();
            self.clearClogs();
            self.clearDownNodes();
            try self.world.record(
                "network.heal disabled_count={} down_count={} clogged_count={}",
                .{ disabled_count, down_count, clogged_count },
            );
        }

        fn healLinks(self: *Self) !void {
            const disabled_count = self.disabledLinkCount();
            self.clearDisabledLinks();
            try self.world.record(
                "network.heal_links disabled_count={}",
                .{disabled_count},
            );
        }

        fn evolveFaults(self: *Self) !void {
            try self.expireClogs();
        }

        /// Submit one packet through the simulated network.
        ///
        /// The packet id is consumed even when the packet is dropped, which
        /// makes the trace easier to reason about and keeps later packet ids
        /// independent from the branch shape after the send decision.
        pub fn send(
            self: *Self,
            from: NodeId,
            to: NodeId,
            payload: Payload,
            options: SendOptions,
        ) !void {
            try self.validateNode(from);
            try self.validateNode(to);
            try validateRate(options.drop_rate);
            try self.validateLatencyOptions(options);

            const packet_id = self.next_packet_id;
            self.next_packet_id += 1;

            if (!try self.nodeUp(from)) {
                try self.world.record(
                    "network.drop id={} from={} to={} reason=source_down",
                    .{ packet_id, from, to },
                );
                return;
            }

            const drop_roll = try self.world.randomIntLessThan(u32, options.drop_rate.denominator);
            if (drop_roll < options.drop_rate.numerator) {
                try self.world.record(
                    "network.drop id={} from={} to={} drop_rate={}/{} roll={} reason=send_drop",
                    .{
                        packet_id,
                        from,
                        to,
                        options.drop_rate.numerator,
                        options.drop_rate.denominator,
                        drop_roll,
                    },
                );
                return;
            }

            const latency_ns = try self.latency(options);
            if (std.math.maxInt(clock_module.Timestamp) - self.world.now() < latency_ns) {
                return error.InvalidDuration;
            }
            const deliver_at = self.world.now() + latency_ns;
            const packet: Packet = .{
                .id = packet_id,
                .from = from,
                .to = to,
                .deliver_at = deliver_at,
                .payload = payload,
            };
            try self.links[try self.pathIndex(from, to)].pending.push(packet);

            try self.world.record(
                "network.send id={} from={} to={} deliver_at={} latency_ns={}",
                .{ packet.id, packet.from, packet.to, packet.deliver_at, latency_ns },
            );
        }

        /// Pop the next ready packet and record its delivery.
        pub fn popReady(self: *Self) !?Packet {
            while (true) {
                try self.evolveFaults();
                const link_index = self.nextReadyLinkIndex() orelse return null;
                const ready = self.links[link_index].pending.pop().?;

                if (!try self.nodeUp(ready.to)) {
                    try self.world.record(
                        "network.drop id={} from={} to={} reason=destination_down",
                        .{ ready.id, ready.from, ready.to },
                    );
                    continue;
                }

                if (!try self.linkEnabled(ready.from, ready.to)) {
                    try self.world.record(
                        "network.drop id={} from={} to={} reason=link_disabled",
                        .{ ready.id, ready.from, ready.to },
                    );
                    continue;
                }

                try self.world.record(
                    "network.deliver id={} from={} to={} now_ns={}",
                    .{ ready.id, ready.from, ready.to, self.world.now() },
                );
                return ready;
            }
        }

        // Scanning per-link heads is deliberate for Phase 0 capacities. A
        // later scheduler can add an index/heap over active paths without
        // changing the per-link queue model needed for clogging.
        fn nextReadyLinkIndex(self: *const Self) ?usize {
            var best_index: ?usize = null;
            var best_packet: Packet = undefined;
            for (&self.links, 0..) |*link, index| {
                const packet = link.pending.peek() orelse continue;
                if (packet.deliver_at > self.world.now()) continue;
                if (link.clogged_until > self.world.now()) continue;
                if (best_index == null or packetLessThan(packet, best_packet)) {
                    best_index = index;
                    best_packet = packet;
                }
            }
            return best_index;
        }

        fn setLinkState(self: *Self, from: NodeId, to: NodeId, enabled: bool) NetworkError!void {
            self.links[try self.pathIndex(from, to)].enabled = enabled;
        }

        fn clearDisabledLinks(self: *Self) void {
            for (&self.links) |*link| link.enabled = true;
        }

        fn clearClogs(self: *Self) void {
            for (&self.links) |*link| link.clogged_until = 0;
        }

        fn clearDownNodes(self: *Self) void {
            for (&self.down_nodes) |*down| down.* = false;
        }

        fn disabledLinkCount(self: *const Self) usize {
            var count: usize = 0;
            for (&self.links) |*link| {
                if (!link.enabled) count += 1;
            }
            return count;
        }

        fn cloggedLinkCount(self: *const Self) usize {
            var count: usize = 0;
            const now_ns = self.world.now();
            for (&self.links) |*link| {
                if (link.clogged_until > now_ns) count += 1;
            }
            return count;
        }

        fn expireClogs(self: *Self) !void {
            const now_ns = self.world.now();
            for (&self.links, 0..) |*link, index| {
                if (link.clogged_until == 0 or link.clogged_until > now_ns) continue;
                const from: NodeId = @intCast(index / process_count);
                const to: NodeId = @intCast(index % process_count);
                link.clogged_until = 0;
                try self.world.record(
                    "network.unclog from={} to={} active=false",
                    .{ from, to },
                );
            }
        }

        fn downNodeCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.down_nodes) |down| {
                if (down) count += 1;
            }
            return count;
        }

        fn pathIndex(self: *const Self, from: NodeId, to: NodeId) NetworkError!usize {
            try self.validateNode(from);
            try self.validateNode(to);
            return @as(usize, from) * process_count + @as(usize, to);
        }

        fn validateNodes(self: *const Self, nodes: []const NodeId) NetworkError!void {
            for (nodes) |node| try self.validateNode(node);
        }

        fn validateNode(_: *const Self, node: NodeId) NetworkError!void {
            if (@as(usize, node) >= process_count) return error.InvalidNode;
        }

        fn validatePositiveTickDuration(self: *const Self, duration_ns: clock_module.Duration) NetworkError!void {
            if (duration_ns == 0) return error.InvalidDuration;
            if (duration_ns % self.world.clock().tick_ns != 0) return error.InvalidDuration;
        }

        fn validateLatencyOptions(self: *const Self, options: SendOptions) NetworkError!void {
            const tick_ns = self.world.clock().tick_ns;
            if (options.min_latency_ns % tick_ns != 0) return error.InvalidDuration;
            if (options.latency_jitter_ns % tick_ns != 0) return error.InvalidDuration;
        }

        fn latency(self: *Self, options: SendOptions) !clock_module.Duration {
            const tick_ns = self.world.clock().tick_ns;

            if (options.latency_jitter_ns == 0) return options.min_latency_ns;

            const jitter_ticks = try self.world.randomIntLessThan(
                clock_module.Duration,
                options.latency_jitter_ns / tick_ns + 1,
            );
            return options.min_latency_ns + jitter_ticks * tick_ns;
        }

        fn packetLessThan(a: Packet, b: Packet) bool {
            return a.deliver_at < b.deliver_at or
                (a.deliver_at == b.deliver_at and a.id < b.id);
        }

        fn defaultLinks() [path_count]Link {
            return @splat(.{});
        }
    };
}

/// Build a small simulator wrapper that owns one unstable packet core.
pub fn NetworkSimulation(comptime Payload: type, comptime network_options: NetworkOptions) type {
    return struct {
        const Self = @This();

        pub const PacketCore = UnstableNetwork(Payload, network_options);
        pub const Network = struct {
            packet_core: *PacketCore,
            faults: *NetworkFaultOptions,

            /// Submit one packet through the simulated network.
            pub fn send(
                self: Network,
                from: NodeId,
                to: NodeId,
                payload: Payload,
            ) !void {
                try self.packet_core.send(from, to, payload, .{
                    .drop_rate = self.faults.drop_rate,
                    .min_latency_ns = self.faults.min_latency_ns,
                    .latency_jitter_ns = self.faults.latency_jitter_ns,
                });
            }

            /// Return the next deliverable packet, advancing simulated time when needed.
            pub fn nextDelivery(self: Network) !?PacketCore.Packet {
                while (true) {
                    if (try self.packet_core.popReady()) |packet| return packet;

                    const deliver_at = self.packet_core.nextDeliveryAt() orelse return null;
                    const now_ns = self.packet_core.world.now();
                    if (deliver_at <= now_ns) return null;

                    try runNetworkFor(self.packet_core, deliver_at - now_ns);
                }
            }
        };

        pub const SimulationNetworkControl = struct {
            packet_core: *PacketCore,
            faults: *NetworkFaultOptions,

            /// Configure runtime send faults for subsequent app-facing sends.
            pub fn setFaults(self: SimulationNetworkControl, faults: NetworkFaultOptions) !void {
                try validateRate(faults.drop_rate);
                try validateFaultLatency(self.packet_core, faults);
                self.faults.* = faults;
                try self.packet_core.world.record(
                    "network.faults drop_rate={}/{} min_latency_ns={} latency_jitter_ns={}",
                    .{
                        faults.drop_rate.numerator,
                        faults.drop_rate.denominator,
                        faults.min_latency_ns,
                        faults.latency_jitter_ns,
                    },
                );
            }

            /// Mark one simulated node/process up or down.
            pub fn setNode(self: SimulationNetworkControl, node: NodeId, up: bool) !void {
                try self.packet_core.control().setNode(node, up);
            }

            /// Enable or disable one directed link.
            pub fn setLink(self: SimulationNetworkControl, from: NodeId, to: NodeId, enabled: bool) !void {
                try self.packet_core.control().setLink(from, to, enabled);
            }

            /// Clog one directed path until simulated time advances by `duration_ns`.
            pub fn clog(self: SimulationNetworkControl, from: NodeId, to: NodeId, duration_ns: clock_module.Duration) !void {
                try self.packet_core.control().clog(from, to, duration_ns);
            }

            /// Clear one directed path clog.
            pub fn unclog(self: SimulationNetworkControl, from: NodeId, to: NodeId) !void {
                try self.packet_core.control().unclog(from, to);
            }

            /// Clear every directed path clog.
            pub fn unclogAll(self: SimulationNetworkControl) !void {
                try self.packet_core.control().unclogAll();
            }

            /// Disable all directed links crossing between two groups.
            pub fn partition(self: SimulationNetworkControl, left: []const NodeId, right: []const NodeId) !void {
                try self.packet_core.control().partition(left, right);
            }

            /// Re-enable every disabled link and mark every node/process up.
            pub fn heal(self: SimulationNetworkControl) !void {
                try self.packet_core.control().heal();
            }

            /// Re-enable every disabled link without changing node state.
            pub fn healLinks(self: SimulationNetworkControl) !void {
                try self.packet_core.control().healLinks();
            }
        };

        pub const Control = struct {
            disk: disk_module.DiskControl,
            network: SimulationNetworkControl,
            world: *World,

            /// Advance simulated time by one tick and evolve network fault state.
            pub fn tick(self: Control) !void {
                try self.world.tick();
                try self.network.packet_core.evolveFaults();
            }

            /// Advance simulated time by whole ticks and evolve network faults.
            pub fn runFor(self: Control, duration_ns: clock_module.Duration) !void {
                const tick_ns = self.world.clock().tick_ns;
                if (duration_ns % tick_ns != 0) return error.InvalidDuration;

                var remaining = duration_ns;
                while (remaining > 0) : (remaining -= tick_ns) {
                    try self.tick();
                }
            }
        };

        const Runtime = struct {
            packet_core: PacketCore,
            faults: NetworkFaultOptions,
        };

        packet_core: *PacketCore,
        faults: *NetworkFaultOptions,
        control_bundle: Control,

        /// Construct a simulation wrapper around a world-owned authority set.
        pub fn init(sim_control: env_module.SimControl) std.mem.Allocator.Error!Self {
            const runtime = try sim_control.world.allocator.create(Runtime);
            errdefer sim_control.world.allocator.destroy(runtime);

            runtime.* = .{
                .packet_core = .init(sim_control.world),
                .faults = .{ .min_latency_ns = sim_control.world.clock().tick_ns },
            };
            try sim_control.world.registerTeardown(runtime, deinitRuntime);

            const packet_core = &runtime.packet_core;
            const faults = &runtime.faults;

            return .{
                .packet_core = packet_core,
                .faults = faults,
                .control_bundle = .{
                    .disk = sim_control.disk,
                    .network = .{
                        .packet_core = packet_core,
                        .faults = faults,
                    },
                    .world = sim_control.world,
                },
            };
        }

        /// Return the low-level packet core for harness send/delivery code.
        pub fn packetCore(self: *Self) *PacketCore {
            return self.packet_core;
        }

        /// Return the app-facing network view for packet sends.
        pub fn network(self: *Self) Network {
            return .{ .packet_core = self.packet_core, .faults = self.faults };
        }

        /// Return the simulator-control view for fault orchestration.
        pub fn control(self: *Self) Control {
            return self.control_bundle;
        }

        /// Advance simulated time by one tick and evolve network fault state.
        pub fn tick(self: *Self) !void {
            try self.control_bundle.tick();
        }

        /// Advance simulated time by whole ticks and evolve network faults.
        pub fn runFor(self: *Self, duration_ns: clock_module.Duration) !void {
            try self.control_bundle.runFor(duration_ns);
        }

        fn deinitRuntime(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const runtime: *Runtime = @ptrCast(@alignCast(ptr));
            allocator.destroy(runtime);
        }

        fn runNetworkFor(packet_core: *PacketCore, duration_ns: clock_module.Duration) !void {
            const tick_ns = packet_core.world.clock().tick_ns;
            if (duration_ns % tick_ns != 0) return error.InvalidDuration;

            var remaining = duration_ns;
            while (remaining > 0) : (remaining -= tick_ns) {
                try packet_core.world.tick();
                try packet_core.evolveFaults();
            }
        }

        fn validateFaultLatency(packet_core: *PacketCore, faults: NetworkFaultOptions) NetworkError!void {
            const tick_ns = packet_core.world.clock().tick_ns;
            if (faults.min_latency_ns % tick_ns != 0) return error.InvalidDuration;
            if (faults.latency_jitter_ns % tick_ns != 0) return error.InvalidDuration;
        }
    };
}

const TestPayload = struct {
    value: u64,
};

const OtherTestPayload = struct {
    value: u64,
};

const test_options: NetworkOptions = .{
    .node_count = 3,
    .client_count = 1,
    .path_capacity = 8,
};

test "network: delivers ready packets by time then packet id" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try network.send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try network.send(0, 2, .{ .value = 2 }, .{ .min_latency_ns = 10 });

    try std.testing.expectEqual(@as(?clock_module.Timestamp, 10), network.nextDeliveryAt());
    try std.testing.expectEqual(@as(?Network.Packet, null), try network.popReady());

    try world.runFor(10);
    const first = (try network.popReady()).?;
    const second = (try network.popReady()).?;

    try std.testing.expectEqual(@as(u64, 0), first.id);
    try std.testing.expectEqual(@as(u64, 1), second.id);
    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.send id=0 from=0 to=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.deliver id=1 from=0 to=2") != null);
}

test "network: traces deterministic drops" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var network = Network.init(&world);
    try network.send(0, 1, .{ .value = 1 }, .{ .drop_rate = .always() });

    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.drop id=0 from=0 to=1 drop_rate=1/1") != null);
}

test "network: queue capacity is per directed path" {
    const Network = UnstableNetwork(TestPayload, .{
        .node_count = 3,
        .client_count = 1,
        .path_capacity = 1,
    });

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try network.send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try std.testing.expectError(error.EventQueueFull, network.send(0, 1, .{ .value = 2 }, .{ .min_latency_ns = 10 }));

    try network.send(0, 2, .{ .value = 3 }, .{ .min_latency_ns = 10 });
    try std.testing.expectEqual(@as(usize, 2), network.pendingCount());
}

test "network: invalid nodes are runtime errors" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    const invalid_node: NodeId = @intCast(Network.process_count);

    try std.testing.expectError(error.InvalidNode, network.nodeUp(invalid_node));
    try std.testing.expectError(error.InvalidNode, network.linkEnabled(0, invalid_node));
    try std.testing.expectError(error.InvalidNode, network.control().setNode(invalid_node, false));
    try std.testing.expectError(
        error.InvalidNode,
        network.send(0, invalid_node, .{ .value = 1 }, .{ .min_latency_ns = 10 }),
    );
}

test "network: invalid durations are runtime errors" {
    const Sim = NetworkSimulation(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const authorities = try world.simulate(.{});
    var sim = try Sim.init(authorities.control);

    try std.testing.expectError(error.InvalidDuration, sim.control().network.clog(0, 1, 0));
    try std.testing.expectError(error.InvalidDuration, sim.control().network.clog(0, 1, 11));
    try std.testing.expectError(
        error.InvalidDuration,
        sim.packetCore().send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 11 }),
    );
    try std.testing.expectError(
        error.InvalidDuration,
        sim.packetCore().send(0, 1, .{ .value = 1 }, .{
            .min_latency_ns = 10,
            .latency_jitter_ns = 11,
        }),
    );
    try std.testing.expectError(error.InvalidDuration, sim.runFor(11));
}

test "network: invalid drop rates are runtime errors" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);

    try std.testing.expectError(
        error.InvalidRate,
        network.send(0, 1, .{ .value = 1 }, .{
            .drop_rate = .{ .numerator = 1, .denominator = 0 },
            .min_latency_ns = 10,
        }),
    );
    try std.testing.expectError(
        error.InvalidRate,
        network.send(0, 1, .{ .value = 1 }, .{
            .drop_rate = .{ .numerator = 2, .denominator = 1 },
            .min_latency_ns = 10,
        }),
    );
}

test "network simulation: control view owns fault orchestration" {
    const Sim = NetworkSimulation(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const authorities = try world.simulate(.{});
    var sim = try Sim.init(authorities.control);
    try sim.control().network.setLink(0, 1, false);
    try sim.packetCore().send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try sim.runFor(10);

    try std.testing.expectEqual(@as(?Sim.PacketCore.Packet, null), try sim.packetCore().popReady());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.link from=0 to=1 enabled=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.drop id=0 from=0 to=1 reason=link_disabled") != null);
}

test "network: clogged path waits while other paths deliver" {
    const Sim = NetworkSimulation(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const authorities = try world.simulate(.{});
    var sim = try Sim.init(authorities.control);
    try sim.control().network.clog(0, 1, 30);
    try sim.packetCore().send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try sim.packetCore().send(0, 2, .{ .value = 2 }, .{ .min_latency_ns = 10 });

    try std.testing.expectEqual(@as(?clock_module.Timestamp, 10), sim.packetCore().nextDeliveryAt());
    try world.runFor(10);
    const first = (try sim.packetCore().popReady()).?;
    try std.testing.expectEqual(@as(NodeId, 2), first.to);
    try std.testing.expectEqual(@as(u64, 1), first.id);

    try std.testing.expectEqual(@as(?Sim.PacketCore.Packet, null), try sim.packetCore().popReady());
    try std.testing.expectEqual(@as(?clock_module.Timestamp, 30), sim.packetCore().nextDeliveryAt());

    try sim.runFor(20);
    const second = (try sim.packetCore().popReady()).?;
    try std.testing.expectEqual(@as(NodeId, 1), second.to);
    try std.testing.expectEqual(@as(u64, 0), second.id);

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.clog from=0 to=1 duration_ns=30 until_ns=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.unclog from=0 to=1 active=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.deliver id=1 from=0 to=2 now_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.deliver id=0 from=0 to=1 now_ns=30") != null);
}

test "network: explicit unclog releases queued packets early" {
    const Sim = NetworkSimulation(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const authorities = try world.simulate(.{});
    var sim = try Sim.init(authorities.control);
    try sim.control().network.clog(0, 1, 30);
    try sim.packetCore().send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });

    try sim.runFor(10);
    try std.testing.expectEqual(@as(?Sim.PacketCore.Packet, null), try sim.packetCore().popReady());
    try sim.control().network.unclog(0, 1);

    const packet = (try sim.packetCore().popReady()).?;
    try std.testing.expectEqual(@as(NodeId, 1), packet.to);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.unclog from=0 to=1 active=true") != null);
}

test "network simulation: outer tick advances time and faults" {
    const Sim = NetworkSimulation(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const authorities = try world.simulate(.{});
    var sim = try Sim.init(authorities.control);
    try sim.control().network.clog(0, 1, 10);
    try sim.packetCore().send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });

    try sim.tick();

    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), world.now());
    const packet = (try sim.packetCore().popReady()).?;
    try std.testing.expectEqual(@as(NodeId, 1), packet.to);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.tick now_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.unclog from=0 to=1 active=false") != null);
}

test "network: heal clears active clogs" {
    const Sim = NetworkSimulation(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const authorities = try world.simulate(.{});
    var sim = try Sim.init(authorities.control);
    try sim.control().network.clog(0, 1, 30);
    try sim.control().network.heal();

    try sim.packetCore().send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try sim.runFor(10);
    const packet = (try sim.packetCore().popReady()).?;
    try std.testing.expectEqual(@as(NodeId, 1), packet.to);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.heal disabled_count=0 down_count=0 clogged_count=1") != null);
}

test "network: disabled links drop ready packets at delivery" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try network.control().setLink(0, 1, false);
    try network.send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try world.runFor(10);

    try std.testing.expectEqual(@as(?Network.Packet, null), try network.popReady());
    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.link from=0 to=1 enabled=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.drop id=0 from=0 to=1 reason=link_disabled") != null);
}

test "network: partition disables crossing links and heal resets network state" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    const left = [_]NodeId{0};
    const right = [_]NodeId{ 1, 2 };

    try network.control().partition(&left, &right);
    try network.control().setNode(2, false);
    try std.testing.expect(!try network.linkEnabled(0, 1));
    try std.testing.expect(!try network.linkEnabled(1, 0));
    try std.testing.expect(!try network.linkEnabled(0, 2));
    try std.testing.expect(!try network.linkEnabled(2, 0));
    try std.testing.expect(try network.linkEnabled(1, 2));
    try std.testing.expect(!try network.nodeUp(2));

    try network.control().heal();
    try std.testing.expect(try network.linkEnabled(0, 1));
    try std.testing.expect(try network.linkEnabled(1, 0));
    try std.testing.expect(try network.nodeUp(2));

    try network.send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try world.runFor(10);
    const packet = (try network.popReady()).?;
    try std.testing.expectEqual(@as(NodeId, 1), packet.to);

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.partition left_count=1 right_count=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.link from=0 to=1 enabled=false") == null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.heal disabled_count=4 down_count=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.deliver id=0 from=0 to=1") != null);
}

test "network: healLinks leaves node state unchanged" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try network.control().setLink(0, 1, false);
    try network.control().setNode(1, false);

    try network.control().healLinks();
    try std.testing.expect(try network.linkEnabled(0, 1));
    try std.testing.expect(!try network.nodeUp(1));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.heal_links disabled_count=1") != null);
}

test "network: down source cannot send" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try std.testing.expect(try network.nodeUp(0));

    try network.control().setNode(0, false);
    try std.testing.expect(!try network.nodeUp(0));

    try network.send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.node node=0 up=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.drop id=0 from=0 to=1 reason=source_down") != null);
}

test "network: down destination drops ready packets at delivery" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try network.send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try network.control().setNode(1, false);
    try world.runFor(10);

    try std.testing.expectEqual(@as(?Network.Packet, null), try network.popReady());
    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.drop id=0 from=0 to=1 reason=destination_down") != null);
}

test "network: restarted destination can receive queued packets" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try network.send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 20 });
    try network.control().setNode(1, false);
    try world.runFor(10);
    try network.control().setNode(1, true);
    try world.runFor(10);

    const packet = (try network.popReady()).?;
    try std.testing.expectEqual(@as(NodeId, 1), packet.to);
    try std.testing.expectEqual(@as(u64, 1), packet.payload.value);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.node node=1 up=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.node node=1 up=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.deliver id=0 from=0 to=1") != null);
}

test "network simulation: nextDelivery drains queued packets" {
    const Sim = NetworkSimulation(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const authorities = try world.simulate(.{});
    var sim = try Sim.init(authorities.control);
    const network = sim.network();
    var values: [4]u64 = undefined;
    var count: usize = 0;

    try sim.control().network.setFaults(.{ .min_latency_ns = 10 });
    try network.send(0, 1, .{ .value = 1 });
    try network.send(0, 1, .{ .value = 2 });
    while (try network.nextDelivery()) |packet| {
        values[count] = packet.payload.value;
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u64, 1), values[0]);
    try std.testing.expectEqual(@as(u64, 2), values[1]);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), world.now());
    try std.testing.expectEqual(@as(usize, 0), sim.packetCore().pendingCount());
}

test "network simulation: nextDelivery advances time and returns packets" {
    const Sim = NetworkSimulation(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const authorities = try world.simulate(.{});
    var sim = try Sim.init(authorities.control);
    const network = sim.network();

    try sim.control().network.setFaults(.{ .min_latency_ns = 20 });
    try network.send(0, 1, .{ .value = 1 });

    const packet = (try network.nextDelivery()).?;
    try std.testing.expectEqual(@as(u64, 1), packet.payload.value);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 20), world.now());
    try std.testing.expectEqual(@as(?Sim.PacketCore.Packet, null), try network.nextDelivery());
}

test "composition network: duplicate payload handles are rejected" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    _ = try sim.network(TestPayload);

    try std.testing.expectError(error.NetworkHandleAlreadyExists, sim.network(TestPayload));
    _ = try sim.network(OtherTestPayload);
}

fn runCompositionClogTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var world = try World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    _ = try sim.network(TestPayload);
    try sim.control.network.setFaults(.{
        .path_clog_rate = .percent(10),
        .path_clog_duration_ns = 20,
    });
    try sim.control.runFor(50);

    return try allocator.dupe(u8, world.traceBytes());
}

test "composition network: probabilistic clogs are tick evolved and deterministic" {
    const a = try runCompositionClogTrace(std.testing.allocator, 1234);
    defer std.testing.allocator.free(a);
    const b = try runCompositionClogTrace(std.testing.allocator, 1234);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "world.random_int_less_than") != null);
}

test "composition network: automatic partition honors unpartition stability" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 4, .service_nodes = 3, .path_capacity = 4 } });
    _ = try sim.network(TestPayload);
    try sim.control.network.setFaults(.{
        .partition_rate = .always(),
        .unpartition_rate = .always(),
        .unpartition_stability_min_ns = 30,
    });

    try sim.control.tick();
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.auto_partition") != null);

    try sim.control.tick();
    try sim.control.tick();
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.auto_heal") == null);

    try sim.control.tick();
    const tick_40 = std.mem.indexOf(u8, world.traceBytes(), "world.tick now_ns=40").?;
    const heal = std.mem.indexOf(u8, world.traceBytes(), "network.auto_heal").?;
    try std.testing.expect(heal > tick_40);
}

test "composition network: nextDelivery wait does not evolve probabilistic faults" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 3, .service_nodes = 1, .path_capacity = 4 } });
    const net = try sim.network(TestPayload);
    try sim.control.network.setFaults(.{ .partition_rate = .always() });

    try net.send(0, 1, .{ .value = 1 });
    const random_events_before = std.mem.count(u8, world.traceBytes(), "world.random_int_less_than");
    const packet = (try net.nextDelivery()).?;
    try std.testing.expectEqual(@as(NodeId, 0), packet.from);
    try std.testing.expectEqual(@as(NodeId, 1), packet.to);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.auto_partition") == null);
    try std.testing.expectEqual(random_events_before, std.mem.count(u8, world.traceBytes(), "world.random_int_less_than"));
}

test "composition network: automatic partition honors partition stability" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 4, .service_nodes = 3, .path_capacity = 4 } });
    _ = try sim.network(TestPayload);
    try sim.control.network.setFaults(.{
        .partition_rate = .always(),
        .partition_stability_min_ns = 30,
    });

    try sim.control.tick();
    try sim.control.tick();
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.auto_partition") == null);

    try sim.control.tick();
    const tick_30 = std.mem.indexOf(u8, world.traceBytes(), "world.tick now_ns=30").?;
    const partition = std.mem.indexOf(u8, world.traceBytes(), "network.auto_partition").?;
    try std.testing.expect(partition > tick_30);
}

test "composition network: manual and automatic partitions compose" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 3, .service_nodes = 1, .path_capacity = 4 } });
    const net = try sim.network(TestPayload);
    const isolated = [_]NodeId{1};
    const other = [_]NodeId{2};

    // service_nodes = 1 pins automatic partition selection to node 0, making
    // the auto/manual overlap deterministic without depending on RNG output.
    try sim.control.network.setFaults(.{ .partition_rate = .always() });
    try sim.control.network.partition(&isolated, &other);
    try sim.control.tick();
    try sim.control.network.setFaults(.{ .unpartition_rate = .always() });
    try sim.control.tick();

    try net.send(1, 2, .{ .value = 1 });
    try std.testing.expectEqual(@as(?TypedNetwork(TestPayload).Packet, null), try net.nextDelivery());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.auto_heal") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "reason=link_disabled") != null);
}
