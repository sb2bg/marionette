//! Durable broadcast: a tiny disk + network cross-product example.
//!
//! Demonstrates the invariant that a request acknowledged by a replica quorum
//! must also be recoverable from local durable storage after crash/restart.

const std = @import("std");
const mar = @import("marionette");

pub const tick_ns: mar.Duration = 1_000_000;
const log_path = "durable_broadcast.wal";
const RecordFrame = mar.wal.FixedRecord(16);
const record_size = RecordFrame.record_size;
const magic: u32 = 0x4d444231; // MDB1
const replica_count = 3;
const quorum = 2;
const client_node_id: mar.NodeId = replica_count;
const max_messages = 96;

const Op = struct {
    id: u64,
    value: u64,
};

const MessagePayload = struct {
    kind: enum { replicate, ack },
    op_id: u64,
    value: u64,
};

const Network = mar.Network(MessagePayload);
const Packet = Network.Packet;

pub const checks = [_]mar.StateCheck(Harness){
    .{ .name = "quorum acknowledgements are durable", .check = quorumAcknowledgementsAreDurable },
};

pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    return runTrace(allocator, seed, "durable-broadcast-smoke", scenario);
}

pub fn runBuggyScenario(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return mar.runCase(.{
        .allocator = allocator,
        .seed = seed,
        .tick_ns = tick_ns,
        .name = "durable-broadcast-bug",
        .init = Harness.init,
        .scenario = buggyScenario,
        .checks = &checks,
    });
}

fn runTrace(
    allocator: std.mem.Allocator,
    seed: u64,
    name: []const u8,
    comptime scenario_fn: fn (*Harness) anyerror!void,
) ![]u8 {
    var report = try mar.runCase(.{
        .allocator = allocator,
        .seed = seed,
        .tick_ns = tick_ns,
        .name = name,
        .init = Harness.init,
        .scenario = scenario_fn,
        .checks = &checks,
    });
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.DurableBroadcastScenarioFailed;
        },
    }
}

pub const Harness = struct {
    service: DurableBroadcast,
    control: mar.Control,

    pub fn init(world: *mar.World) !Harness {
        const sim = try world.simulate(.{
            .disk = .{
                .sector_size = record_size,
                .min_latency_ns = tick_ns,
            },
            .network = .{
                .nodes = replica_count + 1,
                .service_nodes = replica_count,
                .path_capacity = max_messages,
            },
        });

        return .{
            .service = DurableBroadcast.init(sim.env, try sim.network(MessagePayload)),
            .control = sim.control,
        };
    }
};

pub fn scenario(harness: *Harness) !void {
    try harness.control.network.setFaults(.{
        .drop_rate = .percent(10),
        .min_latency_ns = tick_ns,
        .latency_jitter_ns = 2 * tick_ns,
        .path_clog_rate = .percent(5),
        .path_clog_duration_ns = 2 * tick_ns,
        .partition_rate = .percent(5),
        .unpartition_rate = .percent(20),
        .partition_stability_min_ns = 2 * tick_ns,
        .unpartition_stability_min_ns = 2 * tick_ns,
    });

    try harness.control.tick();
    try harness.service.submit(.{
        .op = .{ .id = 1, .value = 41 },
        .retry_limit = 8,
        .sync_before_broadcast = true,
    });

    try harness.control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try harness.control.disk.crash();
    try harness.control.disk.restart();
    try harness.service.recover();

    try harness.control.network.heal();
    try harness.service.broadcastRecovered(3);
}

pub fn buggyScenario(harness: *Harness) !void {
    try harness.control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try harness.service.submit(.{
        .op = .{ .id = 1, .value = 99 },
        .retry_limit = 1,
        .sync_before_broadcast = false,
    });

    try harness.control.disk.crash();
    try harness.control.disk.restart();
    try harness.service.recover();
}

const SyncMode = enum {
    no_sync,
    sync,
};

const Replica = struct {
    accepted_op_id: u64 = 0,
    accepted_value: u64 = 0,

    fn accept(self: *Replica, op: Op) bool {
        if (op.id < self.accepted_op_id) return false;
        if (op.id == self.accepted_op_id and self.accepted_op_id != 0 and op.value != self.accepted_value) {
            return false;
        }

        self.accepted_op_id = op.id;
        self.accepted_value = op.value;
        return true;
    }

    fn accepted(self: Replica) ?Op {
        if (self.accepted_op_id == 0) return null;
        return .{ .id = self.accepted_op_id, .value = self.accepted_value };
    }
};

const DurableBroadcast = struct {
    env: mar.Env,
    net: Network,
    replicas: [replica_count]Replica,
    durable_op: ?Op = null,
    last_quorum_op: ?Op = null,

    fn init(env: mar.Env, net: Network) DurableBroadcast {
        return .{
            .env = env,
            .net = net,
            .replicas = @splat(.{}),
        };
    }

    const SubmitOptions = struct {
        op: Op,
        retry_limit: u8 = 1,
        sync_before_broadcast: bool = true,
    };

    fn submit(self: *DurableBroadcast, options: SubmitOptions) !void {
        std.debug.assert(options.retry_limit > 0);

        try self.append(options.op, if (options.sync_before_broadcast) .sync else .no_sync);
        try self.broadcast(options.op, options.retry_limit);
    }

    fn broadcastRecovered(self: *DurableBroadcast, retry_limit: u8) !void {
        const op = self.durable_op orelse {
            try self.env.record("durable.broadcast.skip reason=no_recovered_op", .{});
            return;
        };
        try self.broadcast(op, retry_limit);
    }

    fn append(self: *DurableBroadcast, op: Op, sync_mode: SyncMode) !void {
        var bytes: [record_size]u8 = @splat(0);
        encodeRecord(&bytes, op);

        try self.env.disk.write(.{
            .path = log_path,
            .offset = 0,
            .bytes = &bytes,
        });

        if (sync_mode == .sync) {
            try self.env.disk.sync(.{ .path = log_path });
            self.durable_op = op;
        }

        try self.env.record(
            "durable.append op={} value={} sync={s}",
            .{ op.id, op.value, @tagName(sync_mode) },
        );
    }

    fn recover(self: *DurableBroadcast) !void {
        self.durable_op = null;

        var bytes: [record_size]u8 = @splat(0);
        try self.env.disk.read(.{
            .path = log_path,
            .offset = 0,
            .buffer = &bytes,
        });

        const op = decodeRecord(&bytes) orelse {
            try self.env.record("durable.recover.reject offset=0", .{});
            return;
        };

        self.durable_op = op;
        try self.env.record("durable.recover.record op={} value={}", .{ op.id, op.value });
    }

    fn broadcast(self: *DurableBroadcast, op: Op, retry_limit: u8) !void {
        var acked: [replica_count]bool = @splat(false);
        try self.env.record(
            "durable.broadcast.start op={} value={} retry_limit={}",
            .{ op.id, op.value, retry_limit },
        );

        for (0..retry_limit) |attempt| {
            if (countTrue(&acked) >= quorum) break;

            try self.env.record("durable.broadcast.attempt index={}", .{attempt});
            for (0..replica_count) |replica_index| {
                if (acked[replica_index]) continue;
                try self.send(client_node_id, @intCast(replica_index), .{
                    .kind = .replicate,
                    .op_id = op.id,
                    .value = op.value,
                });
            }
            try self.drainAndAck(&acked);
        }

        const ack_count = countTrue(&acked);
        if (ack_count >= quorum) {
            self.last_quorum_op = op;
            try self.env.record("durable.broadcast.quorum op={} value={} acks={}", .{ op.id, op.value, ack_count });
        } else {
            try self.env.record("durable.broadcast.no_quorum op={} value={} acks={}", .{ op.id, op.value, ack_count });
        }
    }

    fn send(self: *DurableBroadcast, from: mar.NodeId, to: mar.NodeId, payload: MessagePayload) !void {
        try self.net.send(from, to, payload);
        try self.env.record(
            "durable.message kind={s} from={} to={} op={} value={}",
            .{ @tagName(payload.kind), from, to, payload.op_id, payload.value },
        );
    }

    fn drainAndAck(self: *DurableBroadcast, acked: *[replica_count]bool) !void {
        while (try self.net.nextDelivery()) |packet| {
            try self.apply(packet, acked);
        }
    }

    fn apply(self: *DurableBroadcast, packet: Packet, acked: *[replica_count]bool) !void {
        switch (packet.payload.kind) {
            .replicate => {
                if (packet.to >= replica_count) return;

                const replica_index: usize = @intCast(packet.to);
                const accepted = self.replicas[replica_index].accept(.{
                    .id = packet.payload.op_id,
                    .value = packet.payload.value,
                });
                try self.env.record(
                    "durable.replica_accept replica={} op={} value={} accepted={}",
                    .{ packet.to, packet.payload.op_id, packet.payload.value, accepted },
                );

                if (accepted) {
                    try self.send(packet.to, client_node_id, .{
                        .kind = .ack,
                        .op_id = packet.payload.op_id,
                        .value = packet.payload.value,
                    });
                }
            },
            .ack => {
                if (packet.to != client_node_id or packet.from >= replica_count) return;
                const replica_index: usize = @intCast(packet.from);
                acked[replica_index] = true;
                try self.env.record(
                    "durable.ack replica={} op={} value={}",
                    .{ packet.from, packet.payload.op_id, packet.payload.value },
                );
            },
        }
    }
};

fn quorumAcknowledgementsAreDurable(harness: *const Harness) !void {
    try durableServiceIsSafe(&harness.service);
}

fn durableServiceIsSafe(service: *const DurableBroadcast) !void {
    if (service.last_quorum_op) |op| {
        if (!sameOp(service.durable_op, op)) {
            try service.env.record(
                "durable.invariant_violation reason=quorum_without_durable op={} value={} durable_present={}",
                .{ op.id, op.value, service.durable_op != null },
            );
            return error.QuorumWithoutDurableRecord;
        }
    }

    var accepted_count: u8 = 0;
    for (service.replicas, 0..) |replica, replica_index| {
        const accepted = replica.accepted() orelse continue;
        accepted_count += 1;

        if (!sameOp(service.durable_op, accepted)) {
            try service.env.record(
                "durable.invariant_violation reason=replica_without_durable replica={} op={} value={} durable_present={}",
                .{ replica_index, accepted.id, accepted.value, service.durable_op != null },
            );
            return error.ReplicaAcceptedUndurableRecord;
        }
    }

    try service.env.record(
        "durable.check quorum_durable=ok accepted_count={} durable_present={}",
        .{ accepted_count, service.durable_op != null },
    );
}

fn sameOp(maybe_op: ?Op, expected: Op) bool {
    const actual = maybe_op orelse return false;
    return actual.id == expected.id and actual.value == expected.value;
}

fn encodeRecord(bytes: *[record_size]u8, op: Op) void {
    var body: [RecordFrame.body_size]u8 = undefined;
    mar.wal.putU64(body[0..8], op.id);
    mar.wal.putU64(body[8..16], op.value);
    RecordFrame.encode(bytes, magic, &body);
}

fn decodeRecord(bytes: *const [record_size]u8) ?Op {
    const decoded = RecordFrame.decode(bytes, magic) orelse return null;

    const op: Op = .{
        .id = mar.wal.readU64(decoded.body[0..8]),
        .value = mar.wal.readU64(decoded.body[8..16]),
    };
    if (op.id == 0) return null;
    return op;
}

fn countTrue(values: *const [replica_count]bool) u8 {
    var count: u8 = 0;
    for (values) |value| {
        if (value) count += 1;
    }
    return count;
}

fn writeBroadcastRecover(env: mar.Env, net: Network) !DurableBroadcast {
    var service = DurableBroadcast.init(env, net);
    try service.submit(.{
        .op = .{ .id = 1, .value = 41 },
        .retry_limit = 2,
        .sync_before_broadcast = true,
    });
    try service.recover();
    return service;
}

test "durable broadcast: smoke" {
    try mar.expectPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "durable broadcast: swarm fuzz" {
    try mar.expectFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 64,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "durable broadcast: bug detected" {
    try mar.expectFailure(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .scenario = buggyScenario,
        .checks = &checks,
    });
}

test "durable broadcast: same app code on simulated and production handles" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 0xC0FFEE, .tick_ns = tick_ns });
    defer world.deinit();

    const sim = try world.simulate(.{
        .disk = .{ .sector_size = record_size, .min_latency_ns = tick_ns },
        .network = .{
            .nodes = replica_count + 1,
            .service_nodes = replica_count,
            .path_capacity = max_messages,
        },
    });
    var sim_service = try writeBroadcastRecover(sim.env, try sim.network(MessagePayload));
    try durableServiceIsSafe(&sim_service);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var production = try mar.Production.init(.{
        .root_dir = tmp.dir,
        .io = std.testing.io,
        .disk = .{ .sector_size = record_size },
    });
    defer production.deinit();

    var prod_service = try writeBroadcastRecover(production.env(), try production.network(MessagePayload));
    try durableServiceIsSafe(&prod_service);
}
