const std = @import("std");

const clock_module = @import("../clock.zig");
const endpoint_module = @import("endpoint.zig");
const sim_module = @import("sim.zig");
const types = @import("types.zig");
const World = @import("../world.zig").World;

const Endpoint = endpoint_module.Endpoint;
const NodeId = types.NodeId;
const commitReadyStreamEventFromControl = sim_module.commitReadyStreamEventFromControl;
const initSimControl = sim_module.initSimControl;
const peekReadyStreamEventFromControl = sim_module.peekReadyStreamEventFromControl;
const sendStreamBytesFromControl = sim_module.sendStreamBytesFromControl;

const TestPayload = struct {
    value: u64,
};

const OtherTestPayload = struct {
    value: u64,
};

test "network: full-range latency jitter does not overflow its draw bound" {
    var world = try World.init(std.testing.allocator, .{ .seed = 0x1A7E, .tick_ns = 1 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    try sim.control.network.setLatency(.{
        .min_latency_ns = 0,
        .latency_jitter_ns = std.math.maxInt(clock_module.Duration),
    });
    const sender = try sim.endpoint(TestPayload, 0);
    try sender.send(1, .{ .value = 1 });

    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "world.random_u64") != null);
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

test "stream byte send copies borrowed bytes" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });

    var bytes = [_]u8{ 'p', 'i', 'n', 'g' };
    _ = try sendStreamBytesFromControl(sim.control.network, 0, 1, 1, &bytes, 0);
    bytes[0] = 'x';
    try world.runFor(10);

    const ready = (try peekReadyStreamEventFromControl(sim.control.network, 1)).?;
    const message = try commitReadyStreamEventFromControl(sim.control.network, 1, ready.id(), .none);
    defer message.release();

    try std.testing.expectEqualStrings("ping", message.bytes());
}

fn streamTraceAllocationFailureSweep(allocator: std.mem.Allocator) !void {
    var world = try World.init(allocator, .{ .seed = 0xA110C, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });

    _ = try sendStreamBytesFromControl(sim.control.network, 0, 1, 1, "safe", 0);
    try world.runFor(10);
    const ready = (try peekReadyStreamEventFromControl(sim.control.network, 1)).?;
    const message = try commitReadyStreamEventFromControl(sim.control.network, 1, ready.id(), .none);
    defer message.release();
    try std.testing.expectEqualStrings("safe", message.bytes());
}

test "stream byte transport: trace allocation failures preserve message ownership" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        streamTraceAllocationFailureSweep,
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
            .queued => |queued| queued.deliver_at,
            .dropped => return error.TestUnexpectedResult,
        };
        try std.testing.expect(deliver_at >= delivery_floor);
        delivery_floor = deliver_at;
    }
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

test "composition network: successful send may be fault-dropped" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const sender = try sim.endpoint(TestPayload, 0);
    const receiver = try sim.endpoint(TestPayload, 1);

    try sim.control.network.setLossiness(.{ .drop_rate = .always() });
    try sender.send(1, .{ .value = 42 });

    try std.testing.expectEqual(@as(?Endpoint(TestPayload).Envelope, null), try receiver.receive());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "reason=send_drop") != null);
}

test "composition network: path capacity returns EventQueueFull" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 3, .path_capacity = 1 } });
    const sender = try sim.endpoint(TestPayload, 0);

    try sim.control.network.setLatency(.{ .min_latency_ns = 20 });
    try sender.send(1, .{ .value = 1 });
    try std.testing.expectError(error.EventQueueFull, sender.send(1, .{ .value = 2 }));
    try sender.send(2, .{ .value = 3 });
}

test "composition network: ready packet uses node state when consumed" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const sender = try sim.endpoint(TestPayload, 0);
    const receiver = try sim.endpoint(TestPayload, 1);

    try sim.control.network.setLatency(.{ .min_latency_ns = 10 });
    try sender.send(1, .{ .value = 42 });
    try sim.control.network.setNode(1, false);
    try sim.control.runFor(10);
    try sim.control.network.setNode(1, true);

    const envelope = (try receiver.receive()).?;
    try std.testing.expectEqual(@as(u64, 42), envelope.message.value);
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.deliver") != null);
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

test "composition network: automatic clog schedule beyond clock range stays inert" {
    const start_ns = std.math.maxInt(clock_module.Timestamp) - 25;
    var world = try World.init(std.testing.allocator, .{
        .seed = 0xC106,
        .start_ns = start_ns,
        .tick_ns = 10,
    });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 1, .path_capacity = 1 } });
    try sim.control.network.setClogs(.{
        .path_clog_rate = .always(),
        .path_clog_duration_ns = 10,
    });

    try sim.control.runFor(20);

    try std.testing.expectEqual(start_ns + 20, world.now());
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, world.traceBytes(), "automatic=true"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, world.traceBytes(), "active=false"));
}

test "composition network: automatic clog end beyond clock range stays inert" {
    const start_ns = std.math.maxInt(clock_module.Timestamp) - 15;
    var world = try World.init(std.testing.allocator, .{
        .seed = 0xC106,
        .start_ns = start_ns,
        .tick_ns = 10,
    });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 1, .path_capacity = 1 } });
    try sim.control.network.setClogs(.{
        .path_clog_rate = .always(),
        .path_clog_duration_ns = 20,
    });

    try sim.control.runFor(10);

    try std.testing.expectEqual(start_ns + 10, world.now());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "automatic=true") == null);
}

test "composition network: automatic partition beyond clock range stays inert" {
    const start_ns = std.math.maxInt(clock_module.Timestamp) - 25;
    var world = try World.init(std.testing.allocator, .{
        .seed = 0xA661,
        .start_ns = start_ns,
        .tick_ns = 10,
    });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 1 } });
    try sim.control.network.setPartitionDynamics(.{
        .partition_rate = .always(),
        .partition_stability_min_ns = 30,
    });

    try sim.control.runFor(10);

    try std.testing.expectEqual(start_ns + 10, world.now());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "network.auto_partition") == null);
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

// Coverage migrated from the deleted fixed-topology packet implementation.
test "network contract: invalid node rate and duration validation" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 3 } });
    const control = sim.control.network;
    const sender = try sim.endpoint(TestPayload, 0);
    try std.testing.expectError(error.InvalidNode, sim.endpoint(TestPayload, 3));
    try std.testing.expectError(error.InvalidNode, sender.send(3, .{ .value = 1 }));
    try std.testing.expectError(error.InvalidNode, control.setNode(3, false));
    try std.testing.expectError(error.InvalidNode, control.setLink(0, 3, false));
    try std.testing.expectError(error.InvalidDuration, control.clog(0, 1, 0));
    try std.testing.expectError(error.InvalidDuration, control.clog(0, 1, 11));
    try std.testing.expectError(error.InvalidDuration, control.setLatency(.{ .min_latency_ns = 11 }));
    try std.testing.expectError(error.InvalidDuration, control.setLatency(.{ .latency_jitter_ns = 11 }));
    try std.testing.expectError(error.InvalidDuration, control.setLatency(.{ .min_latency_ns = 10, .latency_jitter_ns = std.math.maxInt(u64) - 9 }));
    try std.testing.expectError(error.InvalidRate, control.setLossiness(.{ .drop_rate = .{ .numerator = 1, .denominator = 0 } }));
    try std.testing.expectError(error.InvalidRate, control.setLossiness(.{ .drop_rate = .{ .numerator = 2, .denominator = 1 } }));
}

test "network contract: same destination orders by delivery time then packet id and drains" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 3 } });
    const first = try sim.endpoint(TestPayload, 0);
    const second = try sim.endpoint(TestPayload, 1);
    const receiver = try sim.endpoint(TestPayload, 2);
    try sim.control.network.setLatency(.{ .min_latency_ns = 20 });
    try first.send(2, .{ .value = 3 });
    try sim.control.network.setLatency(.{ .min_latency_ns = 10 });
    try second.send(2, .{ .value = 1 });
    try first.send(2, .{ .value = 2 });
    for ([_]u64{ 1, 2, 3 }) |value| {
        try std.testing.expectEqual(value, (try receiver.receive()).?.message.value);
    }
    try std.testing.expectEqual(@as(u64, 20), world.now());
    try std.testing.expect((try receiver.receive()) == null);
}

test "network contract: clog isolation expiry explicit unclog and heal" {
    for (0..4) |mode| {
        var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
        defer world.deinit();
        const sim = try world.simulate(.{ .network = .{ .nodes = 3 } });
        const sender = try sim.endpoint(TestPayload, 0);
        const blocked = try sim.endpoint(TestPayload, 1);
        const other = try sim.endpoint(TestPayload, 2);
        try sim.control.network.setLatency(.{ .min_latency_ns = 10 });
        try sim.control.network.clog(0, 1, 30);
        try sender.send(1, .{ .value = 1 });
        try sender.send(2, .{ .value = 2 });
        try std.testing.expectEqual(@as(u64, 2), (try other.receive()).?.message.value);
        try std.testing.expectEqual(@as(u64, 10), world.now());
        switch (mode) {
            0 => {},
            1 => try sim.control.network.unclog(0, 1),
            2 => try sim.control.network.heal(),
            3 => {
                try sim.control.tick();
                try sim.control.tick();
            },
            else => unreachable,
        }
        try std.testing.expectEqual(@as(u64, 1), (try blocked.receive()).?.message.value);
        try std.testing.expectEqual(@as(u64, if (mode == 0 or mode == 3) 30 else 10), world.now());
    }
}

test "network contract: partition healLinks and node lifecycle retain distinct meanings" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 3 } });
    const a = try sim.endpoint(TestPayload, 0);
    const b = try sim.endpoint(TestPayload, 1);
    const c = try sim.endpoint(TestPayload, 2);
    const control = sim.control.network;
    try control.partition(&.{0}, &.{1});
    try a.send(1, .{ .value = 1 });
    try std.testing.expect((try b.receive()) == null);
    try b.send(0, .{ .value = 2 });
    try std.testing.expect((try a.receive()) == null);
    try a.send(2, .{ .value = 3 });
    try std.testing.expectEqual(@as(u64, 3), (try c.receive()).?.message.value);
    try control.setNode(1, false);
    try control.healLinks();
    try b.send(0, .{ .value = 4 });
    try std.testing.expect((try a.receive()) == null); // source still down
    try a.send(1, .{ .value = 5 });
    try std.testing.expect((try b.receive()) == null); // destination still down
    try control.heal();
    try a.send(1, .{ .value = 6 });
    try std.testing.expectEqual(@as(u64, 6), (try b.receive()).?.message.value);
    try control.setNode(1, false);
    try a.send(1, .{ .value = 7 });
    try control.setNode(1, true);
    try std.testing.expectEqual(@as(u64, 7), (try b.receive()).?.message.value);
    try control.setLink(0, 1, false);
    try a.send(1, .{ .value = 8 });
    try std.testing.expect((try b.receive()) == null);
}

test "network: disabled loss consumes no decision for typed and stream sends" {
    var world = try World.init(std.testing.allocator, .{ .seed = 1234 });
    defer world.deinit();
    const sim = try world.simulate(.{ .network = .{ .nodes = 2, .path_capacity = 4 } });
    const sender = try sim.endpoint(TestPayload, 0);
    const before = world.decisions.recorded.items.len;
    try sender.send(1, .{ .value = 1 });
    _ = try sendStreamBytesFromControl(sim.control.network, 0, 1, 1, "hello", 0);
    try std.testing.expectEqual(before, world.decisions.recorded.items.len);
}
