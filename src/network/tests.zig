const std = @import("std");

const clock_module = @import("../clock.zig");
const endpoint_module = @import("endpoint.zig");
const packet_core = @import("packet_core.zig");
const production = @import("production.zig");
const sim_module = @import("sim.zig");
const types = @import("types.zig");
const World = @import("../world.zig").World;

const Endpoint = endpoint_module.Endpoint;
const NetworkOptions = types.NetworkOptions;
const NodeId = types.NodeId;
const ProductionNetworkEntry = production.ProductionNetworkEntry;
const ProductionPeer = production.ProductionPeer;
const NetworkSimulation = packet_core.NetworkSimulation;
const UnstableNetwork = packet_core.UnstableNetwork;
const initSimControl = sim_module.initSimControl;
const sendStreamBytesFromControl = sim_module.sendStreamBytesFromControl;
const productionByteEndpoint = production.productionByteEndpoint;
const productionEndpoint = production.productionEndpoint;

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
    // Misaligned `runFor` durations are harness misuse and assert rather
    // than returning an error; see the runFor misuse contract.
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

test "composition network: endpoints for the same payload share one runtime" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const node_0 = try sim.endpoint(TestPayload, 0);
    const node_1 = try sim.endpoint(TestPayload, 1);
    _ = try sim.endpoint(OtherTestPayload, 1);

    try node_0.send(1, .{ .value = 42 });
    const envelope = (try node_1.receive()).?;
    try std.testing.expectEqual(@as(NodeId, 0), envelope.from);
    try std.testing.expectEqual(@as(u64, 42), envelope.message.value);
}

test "production endpoint: requires declared topology" {
    var entries: std.ArrayList(ProductionNetworkEntry) = .empty;
    defer entries.deinit(std.testing.allocator);

    try std.testing.expectError(error.ProductionTopologyEmpty, productionEndpoint(TestPayload, std.testing.allocator, &entries, .{
        .self = 0,
        .peers = &.{},
    }));

    const missing_self = [_]ProductionPeer{
        .{ .id = 1, .address = "127.0.0.1:4241" },
    };
    try std.testing.expectError(error.ProductionTopologyMissingSelf, productionEndpoint(TestPayload, std.testing.allocator, &entries, .{
        .self = 0,
        .peers = &missing_self,
    }));

    const duplicate_peer = [_]ProductionPeer{
        .{ .id = 0, .address = "127.0.0.1:4240" },
        .{ .id = 0, .address = "127.0.0.1:4241" },
    };
    try std.testing.expectError(error.ProductionTopologyDuplicatePeer, productionEndpoint(TestPayload, std.testing.allocator, &entries, .{
        .self = 0,
        .peers = &duplicate_peer,
    }));
}

test "production endpoint: topology-shaped handles still share in-process runtime" {
    var entries: std.ArrayList(ProductionNetworkEntry) = .empty;
    defer {
        var index = entries.items.len;
        while (index > 0) {
            index -= 1;
            const teardown = entries.items[index].teardown;
            teardown.deinit(teardown.ptr, std.testing.allocator);
        }
        entries.deinit(std.testing.allocator);
    }

    const peers = [_]ProductionPeer{
        .{ .id = 0, .address = "127.0.0.1:4240" },
        .{ .id = 1, .address = "127.0.0.1:4241" },
    };

    const node_0 = try productionEndpoint(TestPayload, std.testing.allocator, &entries, .{
        .self = 0,
        .peers = &peers,
        .listen = peers[0].address,
    });
    const node_1 = try productionEndpoint(TestPayload, std.testing.allocator, &entries, .{
        .self = 1,
        .peers = &peers,
        .listen = peers[1].address,
    });

    try node_0.send(1, .{ .value = 42 });
    const envelope = (try node_1.receive()).?;
    try std.testing.expectEqual(@as(NodeId, 0), envelope.from);
    try std.testing.expectEqual(@as(u64, 42), envelope.message.value);
}

test "composition byte endpoint: send copies borrowed bytes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const node_0 = try sim.byteEndpoint(0);
    const node_1 = try sim.byteEndpoint(1);

    var bytes = [_]u8{ 'p', 'i', 'n', 'g' };
    try node_0.send(1, &bytes);
    bytes[0] = 'x';

    const envelope = (try node_1.receive()).?;
    defer envelope.message.release();

    try std.testing.expectEqual(@as(NodeId, 0), envelope.from);
    try std.testing.expectEqualStrings("ping", envelope.message.bytes());
}

test "composition byte endpoint: send acquired message transfers ownership" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const node_0 = try sim.byteEndpoint(0);
    const node_1 = try sim.byteEndpoint(1);

    const message = try node_0.acquire(4);
    @memcpy(message.bytes(), "pong");
    try node_0.sendMessage(1, message);

    const envelope = (try node_1.receive()).?;
    defer envelope.message.release();

    try std.testing.expectEqual(@as(NodeId, 0), envelope.from);
    try std.testing.expectEqualStrings("pong", envelope.message.bytes());
}

fn byteEndpointTraceAllocationFailureSweep(allocator: std.mem.Allocator) !void {
    var world = try World.init(allocator, .{ .seed = 0xA110C, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const sender = try sim.byteEndpoint(0);
    const receiver = try sim.byteEndpoint(1);

    const message = try sender.acquire(4);
    var caller_owns_message = true;
    defer if (caller_owns_message) message.release();
    @memcpy(message.bytes(), "safe");

    try sender.sendMessage(1, message);
    caller_owns_message = false;
    try world.runFor(10);

    const envelope = (try receiver.receive()).?;
    defer envelope.message.release();
    try std.testing.expectEqualStrings("safe", envelope.message.bytes());
}

test "composition byte endpoint: trace allocation failures preserve message ownership" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        byteEndpointTraceAllocationFailureSweep,
        .{},
    );
}

test "stream byte sends preserve delivery order under jitter" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0x51EA, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 64 } });
    try sim.control.network.setLatency(.{
        .min_latency_ns = 10,
        .latency_jitter_ns = 100,
    });

    var delivery_floor: clock_module.Timestamp = 0;
    for (0..32) |_| {
        const result = try sendStreamBytesFromControl(
            sim.control.network,
            0,
            1,
            1000,
            "frame",
            delivery_floor,
        );
        const deliver_at = switch (result) {
            .queued => |timestamp| timestamp,
            .dropped => return error.TestUnexpectedResult,
        };
        try std.testing.expect(deliver_at >= delivery_floor);
        delivery_floor = deliver_at;
    }
}

test "production byte endpoint: topology-shaped handles share byte runtime" {
    var entries: std.ArrayList(ProductionNetworkEntry) = .empty;
    defer {
        var index = entries.items.len;
        while (index > 0) {
            index -= 1;
            const teardown = entries.items[index].teardown;
            teardown.deinit(teardown.ptr, std.testing.allocator);
        }
        entries.deinit(std.testing.allocator);
    }

    const peers = [_]ProductionPeer{
        .{ .id = 0, .address = "127.0.0.1:4240" },
        .{ .id = 1, .address = "127.0.0.1:4241" },
    };

    const node_0 = try productionByteEndpoint(std.testing.allocator, null, &entries, .{
        .self = 0,
        .peers = &peers,
    });
    const node_1 = try productionByteEndpoint(std.testing.allocator, null, &entries, .{
        .self = 1,
        .peers = &peers,
    });

    try node_0.send(1, "prod");
    const envelope = (try node_1.receive()).?;
    defer envelope.message.release();

    try std.testing.expectEqual(@as(NodeId, 0), envelope.from);
    try std.testing.expectEqualStrings("prod", envelope.message.bytes());
}

test "composition network: receive advances only to global next delivery" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 3, .path_capacity = 4 } });
    const node_0 = try sim.endpoint(TestPayload, 0);
    const node_1 = try sim.endpoint(TestPayload, 1);
    const node_2 = try sim.endpoint(TestPayload, 2);

    try sim.control.network.setLatency(.{ .min_latency_ns = 10 });
    try node_2.send(1, .{ .value = 10 });
    try sim.control.network.setLatency(.{ .min_latency_ns = 20 });
    try node_2.send(0, .{ .value = 20 });

    try std.testing.expectEqual(@as(?Endpoint(TestPayload).Envelope, null), try node_0.receive());
    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), world.now());

    const earlier = (try node_1.receive()).?;
    try std.testing.expectEqual(@as(NodeId, 2), earlier.from);
    try std.testing.expectEqual(@as(u64, 10), earlier.message.value);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), world.now());

    const later = (try node_0.receive()).?;
    try std.testing.expectEqual(@as(NodeId, 2), later.from);
    try std.testing.expectEqual(@as(u64, 20), later.message.value);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 20), world.now());
}

fn runCompositionClogTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var world = try World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    _ = try sim.endpoint(TestPayload, 0);
    try sim.control.network.setClogs(.{
        .path_clog_rate = .percent(10),
        .path_clog_duration_ns = 20,
    });
    try sim.control.runFor(50);

    return try allocator.dupe(u8, world.traceBytes());
}

test "composition network: probabilistic clogs are scheduled and deterministic" {
    const a = try runCompositionClogTrace(std.testing.allocator, 1234);
    defer std.testing.allocator.free(a);
    const b = try runCompositionClogTrace(std.testing.allocator, 1234);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "world.random_int_less_than") != null);
}

test "composition network: runFor jumps when no fault boundary is pending" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    _ = try sim.endpoint(TestPayload, 0);

    try sim.control.runFor(1_000);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 1_000), world.now());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, world.traceBytes(), "world.tick"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, world.traceBytes(), "world.run_for"));
}

test "composition network: runFor zero duration does not evolve faults" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 4, .service_nodes = 1, .path_capacity = 4 } });
    _ = try sim.endpoint(TestPayload, 0);
    try sim.control.network.setClogs(.{
        .path_clog_rate = .percent(10),
        .path_clog_duration_ns = 20,
    });
    try sim.control.network.setPartitionDynamics(.{ .partition_rate = .always() });

    const before_len = world.traceBytes().len;
    try sim.control.runFor(0);
    const after = world.traceBytes()[before_len..];

    try std.testing.expectEqual(@as(clock_module.Timestamp, 0), world.now());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, after, "world.run_for"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, after, "world.random_int_less_than"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, after, "network.auto_partition"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, after, "network.clog from="));
}

fn randomAfterManualClogExpiry(advance_with_ticks: bool) !u64 {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    try sim.control.network.setClogs(.{
        .path_clog_rate = .percent(50),
        .path_clog_duration_ns = 20,
    });
    try sim.control.network.clog(0, 1, 20);

    if (advance_with_ticks) {
        try sim.control.tick();
        try sim.control.tick();
    } else {
        try sim.control.runFor(20);
    }

    return try world.randomU64();
}

test "composition network: tick and runFor preserve RNG state across clog expiry" {
    try std.testing.expectEqual(
        try randomAfterManualClogExpiry(true),
        try randomAfterManualClogExpiry(false),
    );
}

test "composition network: runFor advances through deterministic clog expiries" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    _ = try sim.endpoint(TestPayload, 0);

    try sim.control.network.clog(0, 1, 20);
    try sim.control.runFor(50);

    const trace = world.traceBytes();
    try std.testing.expectEqual(@as(clock_module.Timestamp, 50), world.now());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, trace, "world.tick"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, trace, "world.run_for"));

    const run_to_expiry = std.mem.indexOf(u8, trace, "world.run_for start_ns=0 duration_ns=20 end_ns=20").?;
    const unclog = std.mem.indexOf(u8, trace, "network.unclog from=0 to=1 active=false").?;
    try std.testing.expect(unclog > run_to_expiry);
}

test "composition network: probabilistic clogs are scheduled without per-tick RNG" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0x51EA, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    _ = try sim.endpoint(TestPayload, 0);

    try sim.control.network.setClogs(.{
        .path_clog_rate = .percent(1),
        .path_clog_duration_ns = 10,
    });
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, world.traceBytes(), "world.random_int_less_than"));

    try sim.control.runFor(10_000);

    const trace = world.traceBytes();
    try std.testing.expectEqual(@as(clock_module.Timestamp, 10_000), world.now());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, trace, "world.tick"));
    try std.testing.expect(std.mem.count(u8, trace, "world.random_int_less_than") < 200);
    try std.testing.expect(std.mem.indexOf(u8, trace, "network.clog from=") != null);
}

test "composition network: runFor honors automatic partition stability boundary" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 4, .service_nodes = 3, .path_capacity = 4 } });
    _ = try sim.endpoint(TestPayload, 0);
    try sim.control.network.setPartitionDynamics(.{
        .partition_rate = .always(),
        .partition_stability_min_ns = 30,
    });

    try sim.control.runFor(30);

    const trace = world.traceBytes();
    try std.testing.expectEqual(@as(clock_module.Timestamp, 30), world.now());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, trace, "world.tick"));
    const run_to_boundary = std.mem.indexOf(u8, trace, "world.run_for start_ns=0 duration_ns=30 end_ns=30").?;
    const partition = std.mem.indexOf(u8, trace, "network.auto_partition").?;
    try std.testing.expect(partition > run_to_boundary);
}

test "composition network: receive jump does not strand due automatic partition" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 4, .service_nodes = 1, .path_capacity = 4 } });
    const node_2 = try sim.endpoint(TestPayload, 2);
    const node_3 = try sim.endpoint(TestPayload, 3);

    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
    try sim.control.network.setPartitionDynamics(.{
        .partition_rate = .always(),
        .partition_stability_min_ns = 30,
    });
    try sim.control.runFor(10);

    try node_2.send(3, .{ .value = 20 });
    const envelope = (try node_3.receive()).?;
    try std.testing.expectEqual(@as(u64, 20), envelope.message.value);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 40), world.now());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.auto_partition") == null);

    try sim.control.runFor(10);

    const trace = world.traceBytes();
    const deliver = std.mem.indexOf(u8, trace, "network.deliver").?;
    const partition = std.mem.indexOf(u8, trace, "network.auto_partition").?;
    try std.testing.expect(partition > deliver);
    try std.testing.expect(partition < std.mem.indexOf(u8, trace, "world.run_for start_ns=40 duration_ns=10 end_ns=50").?);
}

test "composition network: automatic partition honors unpartition stability" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 4, .service_nodes = 3, .path_capacity = 4 } });
    _ = try sim.endpoint(TestPayload, 0);
    try sim.control.network.setPartitionDynamics(.{
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
    const node_0 = try sim.endpoint(TestPayload, 0);
    const node_1 = try sim.endpoint(TestPayload, 1);
    try sim.control.network.setPartitionDynamics(.{ .partition_rate = .always() });

    try node_0.send(1, .{ .value = 1 });
    const random_events_before = std.mem.count(u8, world.traceBytes(), "world.random_int_less_than");
    const envelope = (try node_1.receive()).?;
    try std.testing.expectEqual(@as(NodeId, 0), envelope.from);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.auto_partition") == null);
    try std.testing.expectEqual(random_events_before, std.mem.count(u8, world.traceBytes(), "world.random_int_less_than"));
}

test "composition network: automatic partition honors partition stability" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 4, .service_nodes = 3, .path_capacity = 4 } });
    _ = try sim.endpoint(TestPayload, 0);
    try sim.control.network.setPartitionDynamics(.{
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
    const node_1 = try sim.endpoint(TestPayload, 1);
    const node_2 = try sim.endpoint(TestPayload, 2);
    const isolated = [_]NodeId{1};
    const other = [_]NodeId{2};

    // service_nodes = 1 pins automatic partition selection to node 0, making
    // the auto/manual overlap deterministic without depending on RNG output.
    try sim.control.network.setPartitionDynamics(.{ .partition_rate = .always() });
    try sim.control.network.partition(&isolated, &other);
    try sim.control.tick();
    try sim.control.network.setPartitionDynamics(.{ .unpartition_rate = .always() });
    try sim.control.tick();

    try node_1.send(2, .{ .value = 1 });
    try std.testing.expectEqual(@as(?Endpoint(TestPayload).Envelope, null), try node_2.receive());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.auto_heal") != null);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "reason=link_disabled") != null);
}
