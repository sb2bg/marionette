//! Fixed-topology packet core and compatibility simulation wrapper.

const std = @import("std");

const clock_module = @import("../clock.zig");
const disk_module = @import("../disk/root.zig");
const env_module = @import("../env.zig");
const scheduler = @import("../scheduler.zig");
const types = @import("types.zig");
const World = @import("../world.zig").World;

const NetworkError = types.NetworkError;
const NetworkFaultOptions = types.NetworkFaultOptions;
const NetworkOptions = types.NetworkOptions;
const NodeId = types.NodeId;
const validateRate = types.validateRate;

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
            /// A duration that is not a whole number of ticks is harness
            /// misuse and asserts, matching `World.runFor`.
            pub fn runFor(self: Control, duration_ns: clock_module.Duration) !void {
                const tick_ns = self.world.clock().tick_ns;
                std.debug.assert(duration_ns % tick_ns == 0);

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
            std.debug.assert(duration_ns % tick_ns == 0);

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
