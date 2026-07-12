//! Deterministic network fault core and simulation runtimes.

const std = @import("std");

const clock_module = @import("../clock.zig");
const control_module = @import("control.zig");
const endpoint_module = @import("endpoint.zig");
const env_module = @import("../env.zig");
const message_pool_module = @import("../message_pool.zig");
const types = @import("types.zig");
const World = @import("../world.zig").World;

const AnyNetworkControl = control_module.AnyNetworkControl;
const ByteEndpoint = endpoint_module.ByteEndpoint;
const Endpoint = endpoint_module.Endpoint;
const NetworkClogOptions = types.NetworkClogOptions;
const NetworkError = types.NetworkError;
const NetworkFaultOptions = types.NetworkFaultOptions;
const NetworkLatencyOptions = types.NetworkLatencyOptions;
const NetworkLossOptions = types.NetworkLossOptions;
const NetworkOptions = types.NetworkOptions;
const NetworkPartitionDynamicsOptions = types.NetworkPartitionDynamicsOptions;
const NodeId = types.NodeId;
const SimNetworkOptions = types.SimNetworkOptions;
const default_byte_pool_options = types.default_byte_pool_options;
const validateRate = types.validateRate;

const AutoSchedule = union(enum) {
    pending,
    beyond_clock,
    at: clock_module.Timestamp,
};

pub const SimByteSendResult = union(enum) {
    dropped,
    queued: clock_module.Timestamp,
};

pub const SimByteDropReason = enum {
    destination_down,
    link_disabled,
};

pub const SimByteDroppedEnvelope = struct {
    from: NodeId,
    to: NodeId,
    reason: SimByteDropReason,
    message: ByteEndpoint.Message,
};

pub const SimByteReceiveResult = union(enum) {
    delivered: ByteEndpoint.Envelope,
    dropped: SimByteDroppedEnvelope,
};

const SharedRuntime = struct {
    world: *World,
    process_count: usize,
    service_node_count: usize,
    path_capacity: usize,
    faults: NetworkFaultOptions,
    links: []Link,
    down_nodes: []bool,
    typed_runtimes: std.ArrayList(TypedRuntimeEntry) = .empty,
    byte_runtime: ?*SimByteRuntime = null,
    auto_partitioned_node: ?NodeId = null,
    auto_partition_changed_at_ns: clock_module.Timestamp = 0,
    auto_partition_schedule: AutoSchedule = .pending,
    last_fault_evolution_ns: clock_module.Timestamp = 0,

    const Link = struct {
        manual_enabled: bool = true,
        auto_enabled: bool = true,
        clogged_until: clock_module.Timestamp = 0,
        auto_clog_schedule: AutoSchedule = .pending,

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
            .last_fault_evolution_ns = world.now(),
        };
        try world.registerTeardown(runtime, deinitSharedRuntime);
        return runtime;
    }

    const TypedRuntimeEntry = struct {
        payload_name: []const u8,
        ptr: *anyopaque,
    };

    fn deinit(self: *SharedRuntime, allocator: std.mem.Allocator) void {
        self.typed_runtimes.deinit(allocator);
        allocator.free(self.links);
        allocator.free(self.down_nodes);
        self.* = undefined;
    }

    fn control(self: *SharedRuntime) AnyNetworkControl {
        return .{ .ptr = self, .vtable = &shared_control_vtable };
    }

    fn typedRuntime(self: *SharedRuntime, comptime Payload: type) ?*TypedRuntime(Payload) {
        const payload_name = @typeName(Payload);
        for (self.typed_runtimes.items) |entry| {
            if (std.mem.eql(u8, entry.payload_name, payload_name)) {
                return @ptrCast(@alignCast(entry.ptr));
            }
        }
        return null;
    }

    fn registerTypedRuntime(self: *SharedRuntime, comptime Payload: type, ptr: *TypedRuntime(Payload)) !void {
        std.debug.assert(self.typedRuntime(Payload) == null);
        try self.typed_runtimes.append(self.world.allocator, .{
            .payload_name = @typeName(Payload),
            .ptr = ptr,
        });
    }

    fn unregisterTypedRuntime(self: *SharedRuntime, comptime Payload: type) void {
        const payload_name = @typeName(Payload);
        for (self.typed_runtimes.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.payload_name, payload_name)) {
                _ = self.typed_runtimes.swapRemove(index);
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
        if (std.math.maxInt(clock_module.Duration) - faults.min_latency_ns < faults.latency_jitter_ns) {
            return error.InvalidDuration;
        }
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
        self.clearAutoClogSchedules();
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
        self.auto_partition_schedule = .pending;
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
        link.auto_clog_schedule = .pending;
        try self.world.record(
            "network.clog from={} to={} duration_ns={} until_ns={}",
            .{ from, to, duration_ns, link.clogged_until },
        );
    }

    fn unclog(self: *SharedRuntime, from: NodeId, to: NodeId) !void {
        const link = &self.links[try self.pathIndex(from, to)];
        const active = link.clogged_until > self.world.now();
        link.clogged_until = 0;
        link.auto_clog_schedule = .pending;
        try self.world.record("network.unclog from={} to={} active={}", .{ from, to, active });
    }

    fn unclogAll(self: *SharedRuntime) !void {
        const clogged_count = self.cloggedLinkCount();
        for (self.links) |*link| {
            link.clogged_until = 0;
            link.auto_clog_schedule = .pending;
        }
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
        self.clearAutoClogSchedules();
        self.auto_partition_schedule = .pending;
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
        self.auto_partition_schedule = .pending;
        try self.world.record("network.heal_links disabled_count={}", .{disabled_count});
    }

    fn restoreCoreLiveness(self: *SharedRuntime, core: []const NodeId) !void {
        try self.validateNodes(core);
        const now_ns = self.world.now();
        var restored_links: usize = 0;
        var cleared_clogs: usize = 0;
        for (core) |from| {
            for (core) |to| {
                if (from == to) continue;
                const link = &self.links[try self.pathIndex(from, to)];
                if (!link.enabled()) restored_links += 1;
                if (link.clogged_until > now_ns) cleared_clogs += 1;
                link.manual_enabled = true;
                link.auto_enabled = true;
                link.clogged_until = 0;
                link.auto_clog_schedule = .pending;
            }
        }
        var revived_nodes: usize = 0;
        for (core) |node| {
            if (self.down_nodes[@intCast(node)]) revived_nodes += 1;
            self.down_nodes[@intCast(node)] = false;
        }
        try self.world.record(
            "network.liveness_restore core_count={} restored_links={} cleared_clogs={} revived_nodes={}",
            .{ core.len, restored_links, cleared_clogs, revived_nodes },
        );
    }

    fn expireDeterministicFaults(self: *SharedRuntime) !void {
        const now_ns = self.world.now();
        for (self.links, 0..) |*link, index| {
            if (link.clogged_until == 0 or link.clogged_until > now_ns) continue;
            const from: NodeId = @intCast(index / self.process_count);
            const to: NodeId = @intCast(index % self.process_count);
            link.clogged_until = 0;
            link.auto_clog_schedule = .pending;
            try self.world.record("network.unclog from={} to={} active=false", .{ from, to });
        }
    }

    fn evolveTickFaults(self: *SharedRuntime) !void {
        try self.ensureAutoSchedules();
        try self.expireDeterministicFaults();
        try self.ensureAutoClogSchedulesFrom(self.world.now());
        try self.fireDueAutoPartition();
        try self.fireDueAutoClogs();
        self.last_fault_evolution_ns = self.world.now();
    }

    fn evolveFor(self: *SharedRuntime, duration_ns: clock_module.Duration) !void {
        // Retained for VTable source compatibility. Composition code uses the
        // shared fault-evolution participant through SimControl.
        const tick_ns = self.world.clock().tick_ns;
        if (duration_ns % tick_ns != 0) return error.InvalidDuration;
        if (duration_ns == 0) return;

        const end_ns = try addTimestamp(self.world.now(), duration_ns);
        try self.evolveTickFaults();
        while (true) {
            const boundary_ns = (try self.nextFaultBoundaryBeforeOrAt(end_ns)) orelse break;
            if (boundary_ns > self.world.now()) {
                try self.world.runFor(boundary_ns - self.world.now());
            }
            try self.evolveTickFaults();
        }

        if (end_ns > self.world.now()) {
            try self.world.runFor(end_ns - self.world.now());
            try self.evolveTickFaults();
        }
        try self.finishRunFor();
    }

    fn finishRunFor(self: *SharedRuntime) !void {
        try self.expireDeterministicFaults();
        self.last_fault_evolution_ns = self.world.now();
    }

    fn fireDueAutoClogs(self: *SharedRuntime) !void {
        const faults = self.faults;
        if (faults.path_clog_rate.numerator == 0) return;

        const now_ns = self.world.now();
        for (self.links, 0..) |*link, index| {
            const at_ns = switch (link.auto_clog_schedule) {
                .at => |value| value,
                .pending, .beyond_clock => continue,
            };
            if (at_ns > now_ns) continue;
            link.auto_clog_schedule = .pending;
            if (link.clogged_until > now_ns) continue;
            if (std.math.maxInt(clock_module.Timestamp) - now_ns < faults.path_clog_duration_ns) {
                link.auto_clog_schedule = .beyond_clock;
                continue;
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

    fn fireDueAutoPartition(self: *SharedRuntime) !void {
        const faults = self.faults;
        if (self.auto_partitioned_node) |node| {
            const at_ns = switch (self.auto_partition_schedule) {
                .at => |value| value,
                .pending, .beyond_clock => return,
            };
            if (at_ns > self.world.now()) return;
            self.clearAutoPartitionLinks();
            self.auto_partitioned_node = null;
            self.auto_partition_changed_at_ns = self.world.now();
            self.auto_partition_schedule = .pending;
            try self.world.record("network.auto_heal node={}", .{node});
            return;
        }

        if (faults.partition_rate.numerator == 0) return;
        const at_ns = switch (self.auto_partition_schedule) {
            .at => |value| value,
            .pending, .beyond_clock => return,
        };
        if (at_ns > self.world.now()) return;

        const isolated_index = try self.world.randomIntLessThan(usize, self.service_node_count);
        const isolated: NodeId = @intCast(isolated_index);
        self.applyAutoPartition(isolated);
        self.auto_partitioned_node = isolated;
        self.auto_partition_changed_at_ns = self.world.now();
        self.auto_partition_schedule = .pending;
        try self.world.record(
            "network.auto_partition node={} isolated_count=1 connected_count={}",
            .{ isolated, self.process_count - 1 },
        );
    }

    fn ensureAutoSchedules(self: *SharedRuntime) !void {
        const now_ns = self.world.now();
        const tick_ns = self.world.clock().tick_ns;
        const from_ns = if (now_ns >= self.last_fault_evolution_ns and now_ns - self.last_fault_evolution_ns == tick_ns)
            self.last_fault_evolution_ns
        else
            now_ns;
        try self.ensureAutoClogSchedulesFrom(from_ns);
        if (self.auto_partition_schedule == .pending) {
            try self.scheduleAutoPartitionFrom(from_ns);
        }
    }

    fn ensureAutoClogSchedulesFrom(self: *SharedRuntime, from_ns: clock_module.Timestamp) !void {
        for (self.links) |*link| {
            if (link.auto_clog_schedule == .pending) {
                try self.scheduleAutoClogFrom(link, from_ns);
            }
        }
    }

    fn clearAutoClogSchedules(self: *SharedRuntime) void {
        for (self.links) |*link| link.auto_clog_schedule = .pending;
    }

    fn scheduleAutoClogFrom(self: *SharedRuntime, link: *Link, from_ns: clock_module.Timestamp) !void {
        link.auto_clog_schedule = .pending;
        if (self.faults.path_clog_rate.numerator == 0) return;
        if (link.clogged_until != 0 and link.clogged_until >= from_ns) return;
        const ticks = try self.sampleNextOccurrenceTicks(self.faults.path_clog_rate);
        const at_ns = addDurationTicks(from_ns, ticks, self.world.clock().tick_ns) catch {
            link.auto_clog_schedule = .beyond_clock;
            return;
        };
        link.auto_clog_schedule = .{ .at = at_ns };
    }

    fn scheduleAutoPartitionFrom(self: *SharedRuntime, from_ns: clock_module.Timestamp) !void {
        self.auto_partition_schedule = .pending;
        const rate = if (self.auto_partitioned_node == null)
            self.faults.partition_rate
        else
            self.faults.unpartition_rate;
        if (rate.numerator == 0) return;

        const stability_ns = if (self.auto_partitioned_node == null)
            self.faults.partition_stability_min_ns
        else
            self.faults.unpartition_stability_min_ns;
        const floor_ns = addTimestamp(self.auto_partition_changed_at_ns, stability_ns) catch {
            self.auto_partition_schedule = .beyond_clock;
            return;
        };
        const eligible_from = if (floor_ns <= from_ns) from_ns else floor_ns - self.world.clock().tick_ns;
        const ticks = try self.sampleNextOccurrenceTicks(rate);
        const at_ns = addDurationTicks(eligible_from, ticks, self.world.clock().tick_ns) catch {
            self.auto_partition_schedule = .beyond_clock;
            return;
        };
        self.auto_partition_schedule = .{ .at = at_ns };
    }

    fn sampleNextOccurrenceTicks(self: *SharedRuntime, rate: env_module.BuggifyRate) !u64 {
        std.debug.assert(rate.numerator > 0);
        std.debug.assert(rate.numerator <= rate.denominator);
        if (rate.numerator == rate.denominator) return 1;

        const random_space: u64 = 1 << 53;
        const draw = try self.world.randomIntLessThan(u64, random_space);
        const uniform = (@as(f64, @floatFromInt(draw)) + 1.0) / (@as(f64, @floatFromInt(random_space)) + 1.0);
        const failure_probability =
            @as(f64, @floatFromInt(rate.denominator - rate.numerator)) /
            @as(f64, @floatFromInt(rate.denominator));
        const ticks = @ceil(std.math.log(f64, failure_probability, uniform));
        return @max(@as(u64, 1), @as(u64, @intFromFloat(ticks)));
    }

    fn nextFaultBoundaryBeforeOrAt(self: *SharedRuntime, end_ns: clock_module.Timestamp) !?clock_module.Timestamp {
        try self.ensureAutoSchedules();
        return self.nextScheduledFaultBoundaryBeforeOrAt(end_ns);
    }

    fn nextScheduledFaultBoundaryBeforeOrAt(self: *const SharedRuntime, end_ns: clock_module.Timestamp) ?clock_module.Timestamp {
        var next: ?clock_module.Timestamp = null;
        for (self.links) |link| {
            if (link.clogged_until > self.world.now() and link.clogged_until <= end_ns) {
                next = minOptionalTimestamp(next, link.clogged_until);
            }
            const auto_clog_at_ns = switch (link.auto_clog_schedule) {
                .at => |value| value,
                .pending, .beyond_clock => continue,
            };
            if (auto_clog_at_ns > self.world.now() and auto_clog_at_ns <= end_ns) {
                next = minOptionalTimestamp(next, auto_clog_at_ns);
            }
        }
        const auto_partition_at_ns = switch (self.auto_partition_schedule) {
            .at => |value| value,
            .pending, .beyond_clock => return next,
        };
        if (auto_partition_at_ns > self.world.now() and auto_partition_at_ns <= end_ns) {
            next = minOptionalTimestamp(next, auto_partition_at_ns);
        }
        return next;
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
    .restore_core_liveness = sharedControlRestoreCoreLiveness,
    .evolve_tick_faults = sharedControlEvolveTickFaults,
    .evolve_for = sharedControlEvolveFor,
    .next_fault_boundary_before_or_at = sharedControlNextFaultBoundaryBeforeOrAt,
    .finish_run_for = sharedControlFinishRunFor,
    .world = sharedControlWorld,
    .shared = sharedControlShared,
};

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

fn sharedControlRestoreCoreLiveness(ptr: *anyopaque, core: []const NodeId) anyerror!void {
    try sharedControl(ptr).restoreCoreLiveness(core);
}

fn sharedControlEvolveTickFaults(ptr: *anyopaque) anyerror!void {
    try sharedControl(ptr).evolveTickFaults();
}

fn sharedControlEvolveFor(ptr: *anyopaque, duration_ns: clock_module.Duration) anyerror!void {
    try sharedControl(ptr).evolveFor(duration_ns);
}

fn sharedControlNextFaultBoundaryBeforeOrAt(ptr: *anyopaque, end_ns: clock_module.Timestamp) anyerror!?clock_module.Timestamp {
    return try sharedControl(ptr).nextFaultBoundaryBeforeOrAt(end_ns);
}

fn sharedControlFinishRunFor(ptr: *anyopaque) anyerror!void {
    try sharedControl(ptr).finishRunFor();
}

fn sharedControlWorld(ptr: *anyopaque) ?*World {
    return sharedControl(ptr).world;
}

fn sharedControlShared(ptr: *anyopaque) ?*anyopaque {
    return sharedControl(ptr);
}

pub fn initSimControl(world: *World, options: SimNetworkOptions) !AnyNetworkControl {
    const shared = try SharedRuntime.init(world, options);
    return shared.control();
}

fn sharedFromControl(control: AnyNetworkControl) ?*SharedRuntime {
    const ptr = control.vtable.shared(control.ptr) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn addTimestamp(
    timestamp: clock_module.Timestamp,
    duration_ns: clock_module.Duration,
) NetworkError!clock_module.Timestamp {
    return std.math.add(clock_module.Timestamp, timestamp, duration_ns) catch error.InvalidDuration;
}

fn addDurationTicks(
    timestamp: clock_module.Timestamp,
    ticks: u64,
    tick_ns: clock_module.Duration,
) NetworkError!clock_module.Timestamp {
    const duration_ns = std.math.mul(clock_module.Duration, ticks, tick_ns) catch return error.InvalidDuration;
    return addTimestamp(timestamp, duration_ns);
}

fn minOptionalTimestamp(
    current: ?clock_module.Timestamp,
    candidate: clock_module.Timestamp,
) ?clock_module.Timestamp {
    return if (current) |value| @min(value, candidate) else candidate;
}

pub fn endpointFromControl(comptime Payload: type, control: AnyNetworkControl, node: NodeId) !Endpoint(Payload) {
    const shared = sharedFromControl(control) orelse return error.NetworkUnavailable;
    try shared.validateNode(node);
    return try TypedRuntime(Payload).endpoint(shared, node);
}

pub fn byteEndpointFromControl(control: AnyNetworkControl, node: NodeId) !ByteEndpoint {
    const shared = sharedFromControl(control) orelse return error.NetworkUnavailable;
    try shared.validateNode(node);
    return try SimByteRuntime.endpoint(shared, node);
}

pub fn processCountFromControl(control: AnyNetworkControl) ?usize {
    const shared = sharedFromControl(control) orelse return null;
    return shared.process_count;
}

pub fn sendStreamBytesFromControl(
    control: AnyNetworkControl,
    from: NodeId,
    to: NodeId,
    target: u64,
    bytes: []const u8,
    minimum_delivery_at: clock_module.Timestamp,
) !SimByteSendResult {
    const shared = sharedFromControl(control) orelse return error.NetworkUnavailable;
    const runtime = try SimByteRuntime.getOrInit(shared);
    return try runtime.sendBytesAtOrAfter(from, to, bytes, minimum_delivery_at, target);
}

pub fn discardStreamFramesFromControl(control: AnyNetworkControl, node: NodeId, target: u64) usize {
    const shared = sharedFromControl(control) orelse return 0;
    const runtime = shared.byte_runtime orelse return 0;
    return runtime.discardStreamFrames(node, target);
}

pub fn receiveReadyStreamEventFromControl(control: AnyNetworkControl, node: NodeId) !?SimByteReceiveResult {
    const shared = sharedFromControl(control) orelse return error.NetworkUnavailable;
    const runtime = try SimByteRuntime.getOrInit(shared);
    return try runtime.receiveReadyEvent(node);
}

pub fn nextStreamDeliveryAtForControl(control: AnyNetworkControl, node: NodeId) !?clock_module.Timestamp {
    const shared = sharedFromControl(control) orelse return error.NetworkUnavailable;
    const runtime = try SimByteRuntime.getOrInit(shared);
    return try runtime.nextDeliveryAtFor(node);
}

fn sampleLatency(shared: *SharedRuntime) !clock_module.Duration {
    const faults = shared.faults;
    const tick_ns = shared.world.clock().tick_ns;
    if (faults.latency_jitter_ns == 0) return faults.min_latency_ns;

    const max_jitter_ticks = faults.latency_jitter_ns / tick_ns;
    const jitter_ticks = if (max_jitter_ticks == std.math.maxInt(clock_module.Duration))
        try shared.world.randomU64()
    else
        try shared.world.randomIntLessThan(clock_module.Duration, max_jitter_ticks + 1);
    const jitter_ns = std.math.mul(clock_module.Duration, jitter_ticks, tick_ns) catch unreachable;
    return std.math.add(clock_module.Duration, faults.min_latency_ns, jitter_ns) catch unreachable;
}

fn TypedRuntime(comptime Payload: type) type {
    const Handle = Endpoint(Payload);
    const Envelope = Handle.Envelope;

    const Packet = struct {
        id: u64,
        from: NodeId,
        to: NodeId,
        deliver_at: clock_module.Timestamp,
        payload: Payload,
    };

    return struct {
        const Self = @This();

        shared: *SharedRuntime,
        queues: []std.ArrayList(Packet),
        next_packet_id: u64 = 0,

        fn endpoint(shared: *SharedRuntime, node: NodeId) !Handle {
            const runtime = try getOrInit(shared);
            return runtime.handle(node);
        }

        fn getOrInit(shared: *SharedRuntime) !*Self {
            if (shared.typedRuntime(Payload)) |existing| return existing;

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
            errdefer runtime.free(allocator);

            try shared.registerTypedRuntime(Payload, runtime);
            errdefer shared.unregisterTypedRuntime(Payload);

            try shared.world.registerTeardown(runtime, deinit);
            return runtime;
        }

        fn handle(self: *Self, node: NodeId) Handle {
            return .{ .ptr = self, .self_node = node, .vtable = &vtable };
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
            try queue.ensureUnusedCapacity(shared.world.allocator, 1);

            try shared.world.record(
                "network.send id={} from={} to={} deliver_at={} latency_ns={}",
                .{ packet.id, packet.from, packet.to, packet.deliver_at, latency_ns },
            );

            queue.appendAssumeCapacity(packet);
            var index = queue.items.len - 1;
            while (index > 0 and packetLessThan(queue.items[index], queue.items[index - 1])) : (index -= 1) {
                std.mem.swap(Packet, &queue.items[index], &queue.items[index - 1]);
            }
        }

        fn receive(self: *Self, node: NodeId) !?Envelope {
            try self.shared.validateNode(node);

            while (true) {
                try self.shared.expireDeterministicFaults();
                if (try self.popReadyFor(node)) |packet| {
                    return .{
                        .from = packet.from,
                        .message = packet.payload,
                    };
                }

                const deliver_at = self.nextDeliveryAt() orelse return null;
                const now_ns = self.shared.world.now();
                if (deliver_at <= now_ns) return null;
                try self.runForDeterministicFaults(deliver_at - now_ns);
            }
        }

        fn popReadyFor(self: *Self, node: NodeId) !?Packet {
            while (true) {
                const link_index = self.nextReadyLinkIndexFor(node) orelse return null;
                const ready = self.queues[link_index].items[0];

                if (self.shared.down_nodes[@intCast(ready.to)]) {
                    try self.shared.world.record("network.drop id={} from={} to={} reason=destination_down", .{ ready.id, ready.from, ready.to });
                    _ = self.queues[link_index].orderedRemove(0);
                    continue;
                }

                const link = self.shared.links[try self.shared.pathIndex(ready.from, ready.to)];
                if (!link.enabled()) {
                    try self.shared.world.record("network.drop id={} from={} to={} reason=link_disabled", .{ ready.id, ready.from, ready.to });
                    _ = self.queues[link_index].orderedRemove(0);
                    continue;
                }

                try self.shared.world.record("network.deliver id={} from={} to={} now_ns={}", .{ ready.id, ready.from, ready.to, self.shared.world.now() });
                return self.queues[link_index].orderedRemove(0);
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

        fn nextReadyLinkIndexFor(self: *const Self, node: NodeId) ?usize {
            var best_index: ?usize = null;
            var best_packet: Packet = undefined;
            for (self.queues, 0..) |queue, index| {
                if (queue.items.len == 0) continue;
                const packet = queue.items[0];
                if (packet.to != node) continue;
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
            return try sampleLatency(self.shared);
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
            runtime.free(allocator);
        }

        fn free(runtime: *Self, allocator: std.mem.Allocator) void {
            for (runtime.queues) |*queue| queue.deinit(allocator);
            allocator.free(runtime.queues);
            allocator.destroy(runtime);
        }

        fn fromOpaque(ptr: *anyopaque) *Self {
            return @ptrCast(@alignCast(ptr));
        }

        fn vtableSend(ptr: *anyopaque, from: NodeId, to: NodeId, payload: Payload) anyerror!void {
            try fromOpaque(ptr).send(from, to, payload);
        }

        fn vtableReceive(ptr: *anyopaque, node: NodeId) anyerror!?Envelope {
            return try fromOpaque(ptr).receive(node);
        }

        const vtable: Handle.VTable = .{
            .send = vtableSend,
            .receive = vtableReceive,
        };
    };
}

const SimByteRuntime = struct {
    const Self = @This();
    const Packet = struct {
        id: u64,
        from: NodeId,
        to: NodeId,
        deliver_at: clock_module.Timestamp,
        stream_target: ?u64,
        payload: ByteEndpoint.Message,
    };

    const DroppedPacket = struct {
        packet: Packet,
        reason: SimByteDropReason,
    };

    const ReadyEvent = union(enum) {
        delivered: Packet,
        dropped: DroppedPacket,
    };

    shared: *SharedRuntime,
    pool: message_pool_module.Pool,
    queues: []std.ArrayList(Packet),
    next_packet_id: u64 = 0,

    fn endpoint(shared: *SharedRuntime, node: NodeId) !ByteEndpoint {
        const runtime = try getOrInit(shared);
        return runtime.handle(node);
    }

    fn getOrInit(shared: *SharedRuntime) !*Self {
        if (shared.byte_runtime) |existing| return existing;

        const allocator = shared.world.allocator;
        const runtime = try allocator.create(Self);
        var runtime_initialized = false;
        errdefer if (!runtime_initialized) allocator.destroy(runtime);

        const path_count = shared.process_count * shared.process_count;
        const queues = try allocator.alloc(std.ArrayList(Packet), path_count);
        var queues_moved = false;
        errdefer if (!queues_moved) allocator.free(queues);
        @memset(queues, .empty);

        var pool = try message_pool_module.Pool.init(allocator, default_byte_pool_options);
        var pool_moved = false;
        errdefer if (!pool_moved) pool.deinit();

        runtime.* = .{
            .shared = shared,
            .pool = pool,
            .queues = queues,
        };
        queues_moved = true;
        pool_moved = true;
        runtime_initialized = true;
        errdefer runtime.free(allocator);

        shared.byte_runtime = runtime;
        errdefer shared.byte_runtime = null;

        try shared.world.registerTeardown(runtime, deinit);
        return runtime;
    }

    fn handle(self: *Self, node: NodeId) ByteEndpoint {
        return .{ .ptr = self, .self_node = node, .vtable = &vtable };
    }

    fn acquire(self: *Self, len: usize) !ByteEndpoint.Message {
        return try self.pool.acquire(len);
    }

    fn sendBytes(self: *Self, from: NodeId, to: NodeId, bytes: []const u8) !SimByteSendResult {
        return try self.sendBytesAtOrAfter(from, to, bytes, 0, null);
    }

    fn sendBytesAtOrAfter(
        self: *Self,
        from: NodeId,
        to: NodeId,
        bytes: []const u8,
        minimum_delivery_at: clock_module.Timestamp,
        stream_target: ?u64,
    ) !SimByteSendResult {
        const message = try self.acquire(bytes.len);
        var sent = false;
        defer if (!sent) message.release();

        @memcpy(message.bytes(), bytes);
        const result = try self.sendMessageAtOrAfter(from, to, message, minimum_delivery_at, stream_target);
        sent = true;
        return result;
    }

    fn sendMessage(self: *Self, from: NodeId, to: NodeId, message: ByteEndpoint.Message) !SimByteSendResult {
        return try self.sendMessageAtOrAfter(from, to, message, 0, null);
    }

    fn sendMessageAtOrAfter(
        self: *Self,
        from: NodeId,
        to: NodeId,
        message: ByteEndpoint.Message,
        minimum_delivery_at: clock_module.Timestamp,
        stream_target: ?u64,
    ) !SimByteSendResult {
        const shared = self.shared;
        try shared.validateNode(from);
        try shared.validateNode(to);
        try validateRate(shared.faults.drop_rate);
        try shared.validateFaultLatency(shared.faults);

        const packet_id = self.next_packet_id;
        self.next_packet_id += 1;

        if (shared.down_nodes[@intCast(from)]) {
            try shared.world.record("network.drop id={} from={} to={} reason=source_down", .{ packet_id, from, to });
            message.release();
            return .dropped;
        }

        const drop_roll = try shared.world.randomIntLessThan(u32, shared.faults.drop_rate.denominator);
        if (drop_roll < shared.faults.drop_rate.numerator) {
            try shared.world.record(
                "network.drop id={} from={} to={} drop_rate={}/{} roll={} reason=send_drop",
                .{ packet_id, from, to, shared.faults.drop_rate.numerator, shared.faults.drop_rate.denominator, drop_roll },
            );
            message.release();
            return .dropped;
        }

        const latency_ns = try self.latency();
        if (std.math.maxInt(clock_module.Timestamp) - shared.world.now() < latency_ns) {
            return error.InvalidDuration;
        }

        const deliver_at = @max(shared.world.now() + latency_ns, minimum_delivery_at);
        const packet: Packet = .{
            .id = packet_id,
            .from = from,
            .to = to,
            .deliver_at = deliver_at,
            .stream_target = stream_target,
            .payload = message,
        };

        const queue = &self.queues[try shared.pathIndex(from, to)];
        if (queue.items.len >= shared.path_capacity) return error.EventQueueFull;
        try queue.ensureUnusedCapacity(shared.world.allocator, 1);

        try shared.world.record(
            "network.send id={} from={} to={} deliver_at={} latency_ns={}",
            .{ packet.id, packet.from, packet.to, packet.deliver_at, latency_ns },
        );

        queue.appendAssumeCapacity(packet);
        var index = queue.items.len - 1;
        while (index > 0 and packetLessThan(queue.items[index], queue.items[index - 1])) : (index -= 1) {
            std.mem.swap(Packet, &queue.items[index], &queue.items[index - 1]);
        }
        return .{ .queued = deliver_at };
    }

    fn discardStreamFrames(self: *Self, node: NodeId, target: u64) usize {
        var discarded: usize = 0;
        for (self.queues) |*queue| {
            var index: usize = 0;
            while (index < queue.items.len) {
                const packet = queue.items[index];
                if (packet.to != node or packet.stream_target != target) {
                    index += 1;
                    continue;
                }
                const removed = queue.orderedRemove(index);
                removed.payload.release();
                discarded += 1;
            }
        }
        return discarded;
    }

    fn receive(self: *Self, node: NodeId) !?ByteEndpoint.Envelope {
        try self.shared.validateNode(node);

        while (true) {
            try self.shared.expireDeterministicFaults();
            if (try self.popReadyFor(node)) |packet| {
                return .{
                    .from = packet.from,
                    .message = packet.payload,
                };
            }

            const deliver_at = self.nextDeliveryAt() orelse return null;
            const now_ns = self.shared.world.now();
            if (deliver_at <= now_ns) return null;
            try self.runForDeterministicFaults(deliver_at - now_ns);
        }
    }

    fn receiveReadyEvent(self: *Self, node: NodeId) !?SimByteReceiveResult {
        try self.shared.validateNode(node);
        try self.shared.expireDeterministicFaults();
        const event = try self.popReadyEventFor(node) orelse return null;
        return switch (event) {
            .delivered => |packet| .{ .delivered = .{
                .from = packet.from,
                .message = packet.payload,
            } },
            .dropped => |dropped| .{ .dropped = .{
                .from = dropped.packet.from,
                .to = dropped.packet.to,
                .reason = dropped.reason,
                .message = dropped.packet.payload,
            } },
        };
    }

    fn nextDeliveryAtFor(self: *const Self, node: NodeId) !?clock_module.Timestamp {
        try self.shared.validateNode(node);

        var best: ?clock_module.Timestamp = null;
        for (self.queues, 0..) |queue, index| {
            const packet = if (queue.items.len == 0) continue else queue.items[0];
            if (packet.to != node) continue;
            const ready_at = @max(packet.deliver_at, self.shared.links[index].clogged_until);
            if (best == null or ready_at < best.?) best = ready_at;
        }
        return best;
    }

    fn popReadyFor(self: *Self, node: NodeId) !?Packet {
        while (true) {
            const event = try self.popReadyEventFor(node) orelse return null;
            switch (event) {
                .delivered => |packet| return packet,
                .dropped => |dropped| dropped.packet.payload.release(),
            }
        }
    }

    fn popReadyEventFor(self: *Self, node: NodeId) !?ReadyEvent {
        const link_index = self.nextReadyLinkIndexFor(node) orelse return null;
        const ready = self.queues[link_index].items[0];

        if (self.shared.down_nodes[@intCast(ready.to)]) {
            try self.shared.world.record("network.drop id={} from={} to={} reason=destination_down", .{ ready.id, ready.from, ready.to });
            return .{ .dropped = .{
                .packet = self.queues[link_index].orderedRemove(0),
                .reason = .destination_down,
            } };
        }

        const link = self.shared.links[try self.shared.pathIndex(ready.from, ready.to)];
        if (!link.enabled()) {
            try self.shared.world.record("network.drop id={} from={} to={} reason=link_disabled", .{ ready.id, ready.from, ready.to });
            return .{ .dropped = .{
                .packet = self.queues[link_index].orderedRemove(0),
                .reason = .link_disabled,
            } };
        }

        try self.shared.world.record("network.deliver id={} from={} to={} now_ns={}", .{ ready.id, ready.from, ready.to, self.shared.world.now() });
        return .{ .delivered = self.queues[link_index].orderedRemove(0) };
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

    fn nextReadyLinkIndexFor(self: *const Self, node: NodeId) ?usize {
        var best_index: ?usize = null;
        var best_packet: Packet = undefined;
        for (self.queues, 0..) |queue, index| {
            if (queue.items.len == 0) continue;
            const packet = queue.items[0];
            if (packet.to != node) continue;
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
        return try sampleLatency(self.shared);
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
        runtime.free(allocator);
    }

    fn free(self: *Self, allocator: std.mem.Allocator) void {
        for (self.queues) |*queue| {
            for (queue.items) |packet| packet.payload.release();
            queue.deinit(allocator);
        }
        allocator.free(self.queues);
        self.pool.deinit();
        allocator.destroy(self);
    }

    fn fromOpaque(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtableAcquire(ptr: *anyopaque, len: usize) anyerror!ByteEndpoint.Message {
        return try fromOpaque(ptr).acquire(len);
    }

    fn vtableSendBytes(ptr: *anyopaque, from: NodeId, to: NodeId, bytes: []const u8) anyerror!void {
        _ = try fromOpaque(ptr).sendBytes(from, to, bytes);
    }

    fn vtableSendMessage(ptr: *anyopaque, from: NodeId, to: NodeId, message: ByteEndpoint.Message) anyerror!void {
        _ = try fromOpaque(ptr).sendMessage(from, to, message);
    }

    fn vtableReceive(ptr: *anyopaque, node: NodeId) anyerror!?ByteEndpoint.Envelope {
        return try fromOpaque(ptr).receive(node);
    }

    const vtable: ByteEndpoint.VTable = .{
        .acquire = vtableAcquire,
        .send_bytes = vtableSendBytes,
        .send_message = vtableSendMessage,
        .receive = vtableReceive,
    };
};
