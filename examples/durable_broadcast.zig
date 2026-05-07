//! Durable broadcast: a tiny disk + network cross-product example.
//!
//! Demonstrates the invariant that a request acknowledged by a replica quorum
//! must also be recoverable from local durable storage after crash/restart.

const std = @import("std");
const mar = @import("marionette");

pub const tick_ns: mar.Duration = 1_000_000;
const log_path = "durable_broadcast.wal";
const record_size = 24;
const magic: u32 = 0x4d444231;
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

const Endpoint = mar.Endpoint(MessagePayload);

pub const checks = [_]mar.StateCheck(Harness){
    .{ .name = "quorum acknowledgements are durable", .check = quorumAcknowledgementsAreDurable },
};

pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    return runTrace(allocator, seed, "durable-broadcast-smoke", scenario);
}

pub fn runScenarioReport(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return runReport(allocator, seed, "durable-broadcast-smoke", scenario);
}

pub fn runBuggyScenarioReport(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return runReport(allocator, seed, "durable-broadcast-bug", buggyScenario);
}

fn runTrace(
    allocator: std.mem.Allocator,
    seed: u64,
    name: []const u8,
    comptime scenario_fn: fn (*Harness) anyerror!void,
) ![]u8 {
    var report = try runReport(allocator, seed, name, scenario_fn);
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.DurableBroadcastScenarioFailed;
        },
    }
}

fn runReport(
    allocator: std.mem.Allocator,
    seed: u64,
    name: []const u8,
    comptime scenario_fn: fn (*Harness) anyerror!void,
) !mar.RunReport {
    return mar.runCase(.{
        .allocator = allocator,
        .seed = seed,
        .tick_ns = tick_ns,
        .name = name,
        .init = Harness.init,
        .scenario = scenario_fn,
        .checks = &checks,
    });
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
            .service = DurableBroadcast.init(
                sim.env,
                try sim.endpoint(MessagePayload, client_node_id),
                try sim.endpointRange(MessagePayload, replica_count, 0),
            ),
            .control = sim.control,
        };
    }
};

pub fn scenario(harness: *Harness) !void {
    try harness.control.network.setLossiness(.{ .drop_rate = .percent(10) });
    try harness.control.network.setLatency(.{
        .min_latency_ns = tick_ns,
        .latency_jitter_ns = 2 * tick_ns,
    });
    try harness.control.network.setClogs(.{
        .path_clog_rate = .percent(5),
        .path_clog_duration_ns = 2 * tick_ns,
    });
    try harness.control.network.setPartitionDynamics(.{
        .partition_rate = .percent(5),
        .unpartition_rate = .percent(20),
        .partition_stability_min_ns = 2 * tick_ns,
        .unpartition_stability_min_ns = 2 * tick_ns,
    });

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
    accepted_op: ?Op = null,

    fn accept(self: *Replica, op: Op) bool {
        if (self.accepted_op) |current| {
            if (op.id < current.id) return false;
            if (op.id == current.id and op.value != current.value) return false;
        }

        self.accepted_op = op;
        return true;
    }

    fn accepted(self: Replica) ?Op {
        return self.accepted_op;
    }
};

const DurableBroadcast = struct {
    env: mar.Env,
    client: Endpoint,
    replica_endpoints: [replica_count]Endpoint,
    replicas: [replica_count]Replica,
    durable_op: ?Op = null,
    last_quorum_op: ?Op = null,

    fn init(env: mar.Env, client: Endpoint, replica_endpoints: [replica_count]Endpoint) DurableBroadcast {
        return .{
            .env = env,
            .client = client,
            .replica_endpoints = replica_endpoints,
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
        if (from == client_node_id) {
            try self.client.send(to, payload);
        } else {
            const replica_index: usize = @intCast(from);
            try self.replica_endpoints[replica_index].send(to, payload);
        }
        try self.env.record(
            "durable.message kind={s} from={} to={} op={} value={}",
            .{ @tagName(payload.kind), from, to, payload.op_id, payload.value },
        );
    }

    fn drainAndAck(self: *DurableBroadcast, acked: *[replica_count]bool) !void {
        while (true) {
            var progressed = false;

            for (self.replica_endpoints, 0..) |endpoint, replica_index| {
                while (try endpoint.receive()) |envelope| {
                    progressed = true;
                    try self.apply(@intCast(replica_index), envelope, acked);
                }
            }

            while (try self.client.receive()) |envelope| {
                progressed = true;
                try self.apply(client_node_id, envelope, acked);
            }

            if (!progressed) break;
        }
    }

    fn apply(self: *DurableBroadcast, to: mar.NodeId, envelope: Endpoint.Envelope, acked: *[replica_count]bool) !void {
        switch (envelope.message.kind) {
            .replicate => {
                if (to >= replica_count) return;

                const replica_index: usize = @intCast(to);
                const accepted = self.replicas[replica_index].accept(.{
                    .id = envelope.message.op_id,
                    .value = envelope.message.value,
                });
                try self.env.record(
                    "durable.replica_accept replica={} op={} value={} accepted={}",
                    .{ to, envelope.message.op_id, envelope.message.value, accepted },
                );

                if (accepted) {
                    try self.send(to, client_node_id, .{
                        .kind = .ack,
                        .op_id = envelope.message.op_id,
                        .value = envelope.message.value,
                    });
                }
            },
            .ack => {
                if (to != client_node_id or envelope.from >= replica_count) return;
                const replica_index: usize = @intCast(envelope.from);
                acked[replica_index] = true;
                try self.env.record(
                    "durable.ack replica={} op={} value={}",
                    .{ envelope.from, envelope.message.op_id, envelope.message.value },
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
    putU32(bytes[0..4], magic);
    putU64(bytes[4..12], op.id);
    putU64(bytes[12..20], op.value);
    putU32(bytes[20..24], checksum(op));
}

fn decodeRecord(bytes: *const [record_size]u8) ?Op {
    if (readU32(bytes[0..4]) != magic) return null;

    const op: Op = .{
        .id = readU64(bytes[4..12]),
        .value = readU64(bytes[12..20]),
    };
    if (op.id == 0) return null;
    if (readU32(bytes[20..24]) != checksum(op)) return null;
    return op;
}

fn checksum(op: Op) u32 {
    const folded_id: u32 = @truncate(op.id ^ (op.id >> 32));
    const folded_value: u32 = @truncate(op.value ^ (op.value >> 32));
    return magic ^ std.math.rotl(u32, folded_id, 7) ^ std.math.rotl(u32, folded_value, 17) ^ 0x5a5a_a5a5;
}

fn putU32(bytes: []u8, value: u32) void {
    std.debug.assert(bytes.len == 4);
    bytes[0] = @as(u8, @truncate(value));
    bytes[1] = @as(u8, @truncate(value >> 8));
    bytes[2] = @as(u8, @truncate(value >> 16));
    bytes[3] = @as(u8, @truncate(value >> 24));
}

fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn putU64(bytes: []u8, value: u64) void {
    std.debug.assert(bytes.len == 8);
    for (0..8) |index| {
        bytes[index] = @as(u8, @truncate(value >> @intCast(index * 8)));
    }
}

fn readU64(bytes: []const u8) u64 {
    std.debug.assert(bytes.len == 8);
    var value: u64 = 0;
    for (0..8) |index| {
        value |= @as(u64, bytes[index]) << @intCast(index * 8);
    }
    return value;
}

fn countTrue(values: *const [replica_count]bool) u8 {
    var count: u8 = 0;
    for (values) |value| {
        if (value) count += 1;
    }
    return count;
}

fn writeBroadcastRecover(
    env: mar.Env,
    client: Endpoint,
    replica_endpoints: [replica_count]Endpoint,
) !DurableBroadcast {
    var service = DurableBroadcast.init(env, client, replica_endpoints);
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
    var sim_service = try writeBroadcastRecover(
        sim.env,
        try sim.endpoint(MessagePayload, client_node_id),
        try sim.endpointRange(MessagePayload, replica_count, 0),
    );
    try durableServiceIsSafe(&sim_service);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var production = try mar.Production.init(.{
        .root_dir = tmp.dir,
        .io = std.testing.io,
        .disk = .{ .sector_size = record_size },
    });
    defer production.deinit();

    var prod_service = try writeBroadcastRecover(
        production.env(),
        try production.endpoint(MessagePayload, client_node_id),
        try production.endpointRange(MessagePayload, replica_count, 0),
    );
    try durableServiceIsSafe(&prod_service);
}
