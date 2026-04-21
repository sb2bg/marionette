//! Unstable deterministic network primitive.
//!
//! This is the first simulation-kernel slice inspired by TigerBeetle's VOPR
//! packet simulator: messages enter a deterministic queue, seeded decisions
//! choose loss and latency, link filters can drop packets at delivery, and
//! delivery order is keyed by `(deliver_at, packet_id)`.

const std = @import("std");

const env_module = @import("env.zig");
const scheduler = @import("scheduler.zig");
const clock_module = @import("clock.zig");
const World = @import("world.zig").World;

/// Stable simulated node/process identifier.
pub const NodeId = u16;

/// Build a fixed-capacity deterministic network for one payload type.
pub fn UnstableNetwork(comptime Payload: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Error = error{
            LinkFilterFull,
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

        const Queue = scheduler.EventQueue(Packet, capacity, packetLessThan);

        const DisabledLink = struct {
            from: NodeId,
            to: NodeId,
        };

        pending: Queue = .init(),
        disabled_links: [capacity]DisabledLink = undefined,
        disabled_link_count: usize = 0,
        next_packet_id: u64 = 0,

        /// Construct an empty network.
        pub fn init() Self {
            return .{};
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

        /// Enable or disable one directed link.
        pub fn setLink(self: *Self, world: *World, from: NodeId, to: NodeId, enabled: bool) !void {
            if (enabled) {
                if (self.disabledLinkIndex(from, to)) |index| {
                    self.disabled_link_count -= 1;
                    self.disabled_links[index] = self.disabled_links[self.disabled_link_count];
                }
            } else if (self.disabledLinkIndex(from, to) == null) {
                if (self.disabled_link_count == self.disabled_links.len) return error.LinkFilterFull;
                self.disabled_links[self.disabled_link_count] = .{ .from = from, .to = to };
                self.disabled_link_count += 1;
            }

            try world.record(
                "network.link from={} to={} enabled={}",
                .{ from, to, enabled },
            );
        }

        /// Disable all directed links crossing between two groups.
        pub fn partition(
            self: *Self,
            world: *World,
            left: []const NodeId,
            right: []const NodeId,
        ) !void {
            try world.record(
                "network.partition left_count={} right_count={}",
                .{ left.len, right.len },
            );
            for (left) |from| {
                for (right) |to| {
                    try self.setLink(world, from, to, false);
                    try self.setLink(world, to, from, false);
                }
            }
        }

        /// Re-enable every disabled link.
        pub fn heal(self: *Self, world: *World) !void {
            const disabled_count = self.disabled_link_count;
            self.disabled_link_count = 0;
            try world.record(
                "network.heal disabled_count={}",
                .{disabled_count},
            );
        }

        /// Submit one packet through the simulated network.
        ///
        /// The packet id is consumed even when the packet is dropped, which
        /// makes the trace easier to reason about and keeps later packet ids
        /// independent from the branch shape after the send decision.
        pub fn send(
            self: *Self,
            world: *World,
            from: NodeId,
            to: NodeId,
            payload: Payload,
            options: SendOptions,
        ) !void {
            options.drop_rate.validate();

            const packet_id = self.next_packet_id;
            self.next_packet_id += 1;

            const drop_roll = try world.randomIntLessThan(u32, options.drop_rate.denominator);
            if (drop_roll < options.drop_rate.numerator) {
                try world.record(
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

            const latency_ns = try self.latency(world, options);
            const deliver_at = world.now() + latency_ns;
            const packet: Packet = .{
                .id = packet_id,
                .from = from,
                .to = to,
                .deliver_at = deliver_at,
                .payload = payload,
            };
            try self.pending.push(packet);

            try world.record(
                "network.send id={} from={} to={} deliver_at={} latency_ns={}",
                .{ packet.id, packet.from, packet.to, packet.deliver_at, latency_ns },
            );
        }

        /// Pop the next ready packet and record its delivery.
        pub fn popReady(self: *Self, world: *World) !?Packet {
            while (true) {
                const packet = self.pending.peek() orelse return null;
                if (packet.deliver_at > world.now()) return null;

                const ready = self.pending.pop().?;
                if (!self.linkEnabled(ready.from, ready.to)) {
                    try world.record(
                        "network.drop id={} from={} to={} reason=link_disabled",
                        .{ ready.id, ready.from, ready.to },
                    );
                    continue;
                }

                try world.record(
                    "network.deliver id={} from={} to={} now_ns={}",
                    .{ ready.id, ready.from, ready.to, world.now() },
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
            world: *World,
            context: anytype,
            comptime deliver: fn (@TypeOf(context), *World, Packet) anyerror!void,
        ) !void {
            while (true) {
                while (try self.popReady(world)) |packet| {
                    try deliver(context, world, packet);
                }

                const deliver_at = self.nextDeliveryAt() orelse break;
                if (deliver_at > world.now()) {
                    try world.runFor(deliver_at - world.now());
                }
            }
        }

        fn disabledLinkIndex(self: *const Self, from: NodeId, to: NodeId) ?usize {
            for (self.disabled_links[0..self.disabled_link_count], 0..) |link, index| {
                if (link.from == from and link.to == to) return index;
            }
            return null;
        }

        fn latency(self: *Self, world: *World, options: SendOptions) !clock_module.Duration {
            _ = self;

            const tick_ns = world.clock().tick_ns;
            std.debug.assert(options.min_latency_ns % tick_ns == 0);
            std.debug.assert(options.latency_jitter_ns % tick_ns == 0);

            if (options.latency_jitter_ns == 0) return options.min_latency_ns;

            const jitter_ticks = try world.randomIntLessThan(
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

test "network: delivers ready packets by time then packet id" {
    const Network = UnstableNetwork(TestPayload, 4);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init();
    try network.send(&world, 0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try network.send(&world, 0, 2, .{ .value = 2 }, .{ .min_latency_ns = 10 });

    try std.testing.expectEqual(@as(?clock_module.Timestamp, 10), network.nextDeliveryAt());
    try std.testing.expectEqual(@as(?Network.Packet, null), try network.popReady(&world));

    try world.runFor(10);
    const first = (try network.popReady(&world)).?;
    const second = (try network.popReady(&world)).?;

    try std.testing.expectEqual(@as(u64, 0), first.id);
    try std.testing.expectEqual(@as(u64, 1), second.id);
    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.send id=0 from=0 to=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.deliver id=1 from=0 to=2") != null);
}

test "network: traces deterministic drops" {
    const Network = UnstableNetwork(TestPayload, 4);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();

    var network = Network.init();
    try network.send(&world, 0, 1, .{ .value = 1 }, .{ .drop_rate = .always() });

    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.drop id=0 from=0 to=1 drop_rate=1/1") != null);
}

test "network: disabled links drop ready packets at delivery" {
    const Network = UnstableNetwork(TestPayload, 4);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init();
    try network.setLink(&world, 0, 1, false);
    try network.send(&world, 0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try world.runFor(10);

    try std.testing.expectEqual(@as(?Network.Packet, null), try network.popReady(&world));
    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.link from=0 to=1 enabled=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.drop id=0 from=0 to=1 reason=link_disabled") != null);
}

test "network: partition disables crossing links and heal restores them" {
    const Network = UnstableNetwork(TestPayload, 8);

    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    var network = Network.init();
    const left = [_]NodeId{0};
    const right = [_]NodeId{ 1, 2 };

    try network.partition(&world, &left, &right);
    try std.testing.expect(!network.linkEnabled(0, 1));
    try std.testing.expect(!network.linkEnabled(1, 0));
    try std.testing.expect(!network.linkEnabled(0, 2));
    try std.testing.expect(!network.linkEnabled(2, 0));
    try std.testing.expect(network.linkEnabled(1, 2));

    try network.heal(&world);
    try std.testing.expect(network.linkEnabled(0, 1));
    try std.testing.expect(network.linkEnabled(1, 0));

    try network.send(&world, 0, 1, .{ .value = 1 }, .{ .min_latency_ns = 10 });
    try world.runFor(10);
    const packet = (try network.popReady(&world)).?;
    try std.testing.expectEqual(@as(NodeId, 1), packet.to);

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.partition left_count=1 right_count=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.heal disabled_count=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.deliver id=0 from=0 to=1") != null);
}

test "network: drainUntilIdle advances time and delivers queued packets" {
    const Network = UnstableNetwork(TestPayload, 4);

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

    var network = Network.init();
    var log: DeliveryLog = .{};

    try network.send(&world, 0, 1, .{ .value = 1 }, .{ .min_latency_ns = 20 });
    try network.send(&world, 0, 1, .{ .value = 2 }, .{ .min_latency_ns = 10 });
    try network.drainUntilIdle(&world, &log, DeliveryLog.deliver);

    try std.testing.expectEqual(@as(usize, 2), log.count);
    try std.testing.expectEqual(@as(u64, 2), log.values[0]);
    try std.testing.expectEqual(@as(u64, 1), log.values[1]);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 20), world.now());
    try std.testing.expectEqual(@as(usize, 0), network.pendingCount());
}
