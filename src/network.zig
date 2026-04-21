//! Unstable deterministic network primitive.
//!
//! This is the first simulation-kernel slice inspired by TigerBeetle's VOPR
//! packet simulator: messages enter a deterministic queue, seeded decisions
//! choose loss and latency, link filters and node state can drop packets, and
//! delivery order is keyed by `(deliver_at, packet_id)`.

const std = @import("std");

const env_module = @import("env.zig");
const scheduler = @import("scheduler.zig");
const clock_module = @import("clock.zig");
const World = @import("world.zig").World;

/// Stable simulated node/process identifier.
pub const NodeId = u16;

/// Fixed capacities for one unstable network instance.
pub const NetworkOptions = struct {
    packet_capacity: usize,
    max_disabled_links: usize,
    max_down_nodes: usize,
};

/// Build a fixed-capacity deterministic network for one payload type.
pub fn UnstableNetwork(comptime Payload: type, comptime network_options: NetworkOptions) type {
    return struct {
        const Self = @This();

        pub const Error = error{
            LinkFilterFull,
            NodeStateFull,
        } || scheduler.EventQueueError;

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

        const Queue = scheduler.EventQueue(Packet, network_options.packet_capacity, packetLessThan);

        const DisabledLink = struct {
            from: NodeId,
            to: NodeId,
        };

        world: *World,
        pending: Queue = .init(),
        disabled_links: [network_options.max_disabled_links]DisabledLink = undefined,
        disabled_link_count: usize = 0,
        down_nodes: [network_options.max_down_nodes]NodeId = undefined,
        down_node_count: usize = 0,
        next_packet_id: u64 = 0,

        /// Construct an empty network.
        pub fn init(world: *World) Self {
            return .{ .world = world };
        }

        /// Count queued, undelivered packets.
        pub fn pendingCount(self: *const Self) usize {
            return self.pending.count();
        }

        /// Return the timestamp of the next queued packet, if any.
        pub fn nextDeliveryAt(self: *const Self) ?clock_module.Timestamp {
            const packet = self.pending.peek() orelse return null;
            return packet.deliver_at;
        }

        /// Return whether a directed link is currently enabled.
        pub fn linkEnabled(self: *const Self, from: NodeId, to: NodeId) bool {
            return self.disabledLinkIndex(from, to) == null;
        }

        /// Return whether a simulated node/process is currently up.
        pub fn nodeUp(self: *const Self, node: NodeId) bool {
            return self.downNodeIndex(node) == null;
        }

        /// Mark one simulated node/process up or down.
        pub fn setNode(self: *Self, node: NodeId, up: bool) !void {
            if (up) {
                if (self.downNodeIndex(node)) |index| {
                    self.removeDownNodeAt(index);
                }
            } else if (self.downNodeIndex(node) == null) {
                if (self.down_node_count == self.down_nodes.len) return error.NodeStateFull;
                self.down_nodes[self.down_node_count] = node;
                self.down_node_count += 1;
            }

            try self.world.record(
                "network.node node={} up={}",
                .{ node, up },
            );
        }

        /// Enable or disable one directed link.
        pub fn setLink(self: *Self, from: NodeId, to: NodeId, enabled: bool) !void {
            try self.setLinkState(from, to, enabled);
            try self.world.record(
                "network.link from={} to={} enabled={}",
                .{ from, to, enabled },
            );
        }

        /// Disable all directed links crossing between two groups.
        pub fn partition(
            self: *Self,
            left: []const NodeId,
            right: []const NodeId,
        ) !void {
            const links_needed = self.partitionLinksNeeded(left, right);
            if (links_needed > self.disabled_links.len - self.disabled_link_count) {
                return error.LinkFilterFull;
            }

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

        /// Re-enable every disabled link and mark every node up.
        pub fn heal(self: *Self) !void {
            const disabled_count = self.disabled_link_count;
            const down_count = self.down_node_count;
            self.clearDisabledLinks();
            self.clearDownNodes();
            try self.world.record(
                "network.heal disabled_count={} down_count={}",
                .{ disabled_count, down_count },
            );
        }

        /// Re-enable every disabled link without changing node state.
        pub fn healLinks(self: *Self) !void {
            const disabled_count = self.disabled_link_count;
            self.clearDisabledLinks();
            try self.world.record(
                "network.heal_links disabled_count={}",
                .{disabled_count},
            );
        }

        fn setLinkState(self: *Self, from: NodeId, to: NodeId, enabled: bool) !void {
            if (enabled) {
                if (self.disabledLinkIndex(from, to)) |index| {
                    self.removeDisabledLinkAt(index);
                }
            } else if (self.disabledLinkIndex(from, to) == null) {
                if (self.disabled_link_count == self.disabled_links.len) return error.LinkFilterFull;
                self.disabled_links[self.disabled_link_count] = .{ .from = from, .to = to };
                self.disabled_link_count += 1;
            }
        }

        fn partitionLinksNeeded(self: *const Self, left: []const NodeId, right: []const NodeId) usize {
            var needed: usize = 0;
            for (left) |from| {
                for (right) |to| {
                    if (!self.linkChangeAlreadyApplied(from, to, false)) needed += 1;
                    if (!self.linkChangeAlreadyApplied(to, from, false)) needed += 1;
                }
            }
            return needed;
        }

        fn linkChangeAlreadyApplied(self: *const Self, from: NodeId, to: NodeId, enabled: bool) bool {
            return self.linkEnabled(from, to) == enabled;
        }

        fn clearDisabledLinks(self: *Self) void {
            for (0..self.disabled_link_count) |index| {
                self.disabled_links[index] = .{ .from = 0, .to = 0 };
            }
            self.disabled_link_count = 0;
        }

        fn clearDownNodes(self: *Self) void {
            for (0..self.down_node_count) |index| {
                self.down_nodes[index] = 0;
            }
            self.down_node_count = 0;
        }

        fn removeDisabledLinkAt(self: *Self, index: usize) void {
            self.disabled_link_count -= 1;
            self.disabled_links[index] = self.disabled_links[self.disabled_link_count];
            self.disabled_links[self.disabled_link_count] = .{ .from = 0, .to = 0 };
        }

        fn removeDownNodeAt(self: *Self, index: usize) void {
            self.down_node_count -= 1;
            self.down_nodes[index] = self.down_nodes[self.down_node_count];
            self.down_nodes[self.down_node_count] = 0;
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
            options.drop_rate.validate();

            const packet_id = self.next_packet_id;
            self.next_packet_id += 1;

            if (!self.nodeUp(from)) {
                try self.world.record(
                    "network.drop id={} from={} to={} reason=source_down",
                    .{ packet_id, from, to },
                );
                return;
            }

            const drop_roll = try self.world.randomIntLessThan(u32, options.drop_rate.denominator);
            if (drop_roll < options.drop_rate.numerator) {
                try self.world.record(
                    "network.drop id={} from={} to={} drop_rate={}/{} roll={}",
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
            const deliver_at = self.world.now() + latency_ns;
            const packet: Packet = .{
                .id = packet_id,
                .from = from,
                .to = to,
                .deliver_at = deliver_at,
                .payload = payload,
            };
            try self.pending.push(packet);

            try self.world.record(
                "network.send id={} from={} to={} deliver_at={} latency_ns={}",
                .{ packet.id, packet.from, packet.to, packet.deliver_at, latency_ns },
            );
        }

        /// Pop the next ready packet and record its delivery.
        pub fn popReady(self: *Self) !?Packet {
            while (true) {
                const packet = self.pending.peek() orelse return null;
                if (packet.deliver_at > self.world.now()) return null;

                const ready = self.pending.pop().?;
                if (!self.nodeUp(ready.to)) {
                    try self.world.record(
                        "network.drop id={} from={} to={} reason=destination_down",
                        .{ ready.id, ready.from, ready.to },
                    );
                    continue;
                }

                if (!self.linkEnabled(ready.from, ready.to)) {
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

        /// Drive queued packets until the network has no pending work.
        ///
        /// The delivery callback may enqueue more packets. This helper keeps
        /// advancing simulated time to the next packet and delivering ready
        /// packets until the queue is empty.
        pub fn drainUntilIdle(
            self: *Self,
            context: anytype,
            comptime deliver: fn (@TypeOf(context), *World, Packet) anyerror!void,
        ) !void {
            while (true) {
                while (try self.popReady()) |packet| {
                    try deliver(context, self.world, packet);
                }

                const deliver_at = self.nextDeliveryAt() orelse break;
                if (deliver_at > self.world.now()) {
                    try self.world.runFor(deliver_at - self.world.now());
                }
            }
        }

        // These linear scans are fine for Phase 0 capacities. If link/node
        // limits grow, replace them with indexed state keyed by NodeId/path.
        fn disabledLinkIndex(self: *const Self, from: NodeId, to: NodeId) ?usize {
            for (self.disabled_links[0..self.disabled_link_count], 0..) |link, index| {
                if (link.from == from and link.to == to) return index;
            }
            return null;
        }

        fn downNodeIndex(self: *const Self, node: NodeId) ?usize {
            for (self.down_nodes[0..self.down_node_count], 0..) |down_node, index| {
                if (down_node == node) return index;
            }
            return null;
        }

        fn latency(self: *Self, options: SendOptions) !clock_module.Duration {
            const tick_ns = self.world.clock().tick_ns;
            std.debug.assert(options.min_latency_ns % tick_ns == 0);
            std.debug.assert(options.latency_jitter_ns % tick_ns == 0);

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
    };
}

const TestPayload = struct {
    value: u64,
};

const test_options: NetworkOptions = .{
    .packet_capacity = 8,
    .max_disabled_links = 8,
    .max_down_nodes = 8,
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

test "network: packet, link, and node capacities are independent" {
    const Network = UnstableNetwork(TestPayload, .{
        .packet_capacity = 4,
        .max_disabled_links = 1,
        .max_down_nodes = 1,
    });

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try network.setLink(0, 1, false);
    try std.testing.expectError(error.LinkFilterFull, network.setLink(0, 2, false));

    try network.setNode(1, false);
    try std.testing.expectError(error.NodeStateFull, network.setNode(2, false));

    try network.send(0, 3, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try network.send(0, 3, .{ .value = 2 }, .{ .min_latency_ns = 10 });
    try std.testing.expectEqual(@as(usize, 2), network.pendingCount());
}

test "network: disabled links drop ready packets at delivery" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try network.setLink(0, 1, false);
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

    try network.partition(&left, &right);
    try network.setNode(2, false);
    try std.testing.expect(!network.linkEnabled(0, 1));
    try std.testing.expect(!network.linkEnabled(1, 0));
    try std.testing.expect(!network.linkEnabled(0, 2));
    try std.testing.expect(!network.linkEnabled(2, 0));
    try std.testing.expect(network.linkEnabled(1, 2));
    try std.testing.expect(!network.nodeUp(2));

    try network.heal();
    try std.testing.expect(network.linkEnabled(0, 1));
    try std.testing.expect(network.linkEnabled(1, 0));
    try std.testing.expect(network.nodeUp(2));

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
    try network.setLink(0, 1, false);
    try network.setNode(1, false);

    try network.healLinks();
    try std.testing.expect(network.linkEnabled(0, 1));
    try std.testing.expect(!network.nodeUp(1));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.heal_links disabled_count=1") != null);
}

test "network: partition capacity failure does not partially disable links" {
    const Network = UnstableNetwork(TestPayload, .{
        .packet_capacity = 4,
        .max_disabled_links = 1,
        .max_down_nodes = 1,
    });

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    const left = [_]NodeId{0};
    const right = [_]NodeId{1};

    try std.testing.expectError(error.LinkFilterFull, network.partition(&left, &right));
    try std.testing.expect(network.linkEnabled(0, 1));
    try std.testing.expect(network.linkEnabled(1, 0));
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.partition") == null);
}

test "network: down source cannot send" {
    const Network = UnstableNetwork(TestPayload, test_options);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    try std.testing.expect(network.nodeUp(0));

    try network.setNode(0, false);
    try std.testing.expect(!network.nodeUp(0));

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
    try network.setNode(1, false);
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
    try network.setNode(1, false);
    try world.runFor(10);
    try network.setNode(1, true);
    try world.runFor(10);

    const packet = (try network.popReady()).?;
    try std.testing.expectEqual(@as(NodeId, 1), packet.to);
    try std.testing.expectEqual(@as(u64, 1), packet.payload.value);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.node node=1 up=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.node node=1 up=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.deliver id=0 from=0 to=1") != null);
}

test "network: drainUntilIdle advances time and delivers queued packets" {
    const Network = UnstableNetwork(TestPayload, test_options);

    const DeliveryLog = struct {
        values: [4]u64 = undefined,
        count: usize = 0,

        fn deliver(self: *@This(), _: *World, packet: Network.Packet) !void {
            self.values[self.count] = packet.payload.value;
            self.count += 1;
        }
    };

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init(&world);
    var log: DeliveryLog = .{};

    try network.send(0, 1, .{ .value = 1 }, .{ .min_latency_ns = 20 });
    try network.send(0, 1, .{ .value = 2 }, .{ .min_latency_ns = 10 });
    try network.drainUntilIdle(&log, DeliveryLog.deliver);

    try std.testing.expectEqual(@as(usize, 2), log.count);
    try std.testing.expectEqual(@as(u64, 2), log.values[0]);
    try std.testing.expectEqual(@as(u64, 1), log.values[1]);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 20), world.now());
    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
}
