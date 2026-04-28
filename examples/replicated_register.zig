//! Replicated register: a tiny VOPR-shaped distributed example.
//!
//! Demonstrates Marionette's network API direction: typed messaging,
//! deterministic delivery, partition injection, and a separate checker.

const std = @import("std");
const mar = @import("marionette");

const tick_ns: mar.Duration = 1_000_000;
const replica_count = 3;
const quorum = 2;
const max_messages = 64;
const client_node_id: mar.NodeId = replica_count;

const MessagePayload = struct {
    kind: enum { propose, commit },
    version: u64,
    value: u64,
};

const network_options: mar.NetworkOptions = .{
    .node_count = replica_count,
    .client_count = 1,
    .path_capacity = max_messages,
};

const Simulation = mar.NetworkSimulation(MessagePayload, network_options);
const Network = Simulation.Network;
const Packet = Simulation.PacketCore.Packet;

pub const checks = [_]mar.StateCheck(Harness){
    .{ .name = "committed register is safe", .check = committedRegisterIsSafe },
};

/// Run the correct replicated-register scenario and return an owned trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    return runTrace(allocator, seed, "replicated-register-smoke", scenario);
}

/// Run a deliberately buggy scenario. Tests use this to prove the checker
/// catches divergent committed state without making the normal suite fail.
pub fn runBuggyScenario(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return mar.runCase(.{
        .allocator = allocator,
        .seed = seed,
        .tick_ns = tick_ns,
        .name = "replicated-register-bug",
        .init = Harness.init,
        .scenario = buggyScenario,
        .checks = &checks,
    });
}

/// Run a scenario that writes through a partition and return an owned trace.
pub fn runPartitionScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    return runTrace(allocator, seed, "replicated-register-partition", partitionScenario);
}

/// Run a same-version conflict scenario and return an owned trace.
pub fn runConflictScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    return runTrace(allocator, seed, "replicated-register-conflict", conflictScenario);
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
            return error.ReplicatedRegisterScenarioFailed;
        },
    }
}

pub const Harness = struct {
    replicas: Replicas,
    control: Simulation.Control,
    sim: Simulation,

    pub fn init(world: *mar.World) !Harness {
        const sim_env = try world.simulate(.{});
        var sim = try Simulation.init(sim_env.control);

        return .{
            .replicas = Replicas.init(sim_env.env, sim.network()),
            .control = sim.control(),
            .sim = sim,
        };
    }
};

fn committedRegisterIsSafe(harness: *const Harness) !void {
    try checkCommittedAgreement(&harness.replicas);
    try checkCommittedQuorumAccepted(&harness.replicas);
}

pub fn scenario(harness: *Harness) !void {
    try harness.control.network.setFaults(.{ .drop_rate = .percent(20) });
    try harness.replicas.write(.{ .version = 1, .value = 41, .retry_limit = 8 });
}

pub fn buggyScenario(harness: *Harness) !void {
    try harness.replicas.forceCommit(0, 1, 41);
    try harness.replicas.forceCommit(1, 1, 42);
}

pub fn partitionScenario(harness: *Harness) !void {
    const isolated = [_]mar.NodeId{0};
    const majority = [_]mar.NodeId{ 1, 2, client_node_id };

    try harness.control.network.partition(&isolated, &majority);
    try harness.replicas.write(.{ .version = 1, .value = 41, .retry_limit = 2 });

    try harness.control.network.heal();
    try harness.replicas.write(.{ .version = 1, .value = 41, .retry_limit = 1 });

    try checkReplicaCommitted(&harness.replicas, 0, 1, 41);
}

pub fn conflictScenario(harness: *Harness) !void {
    try harness.replicas.write(.{ .version = 1, .value = 41 });
    try harness.replicas.write(.{ .version = 1, .value = 42 });
}

const Replica = struct {
    accepted_version: u64 = 0,
    accepted_value: u64 = 0,
    committed_version: u64 = 0,
    committed_value: u64 = 0,

    fn accept(self: *Replica, version: u64, value: u64) bool {
        if (version < self.accepted_version) return false;
        if (version == self.accepted_version and self.accepted_version != 0 and value != self.accepted_value) {
            return false;
        }
        self.accepted_version = version;
        self.accepted_value = value;
        return true;
    }

    fn commit(self: *Replica, version: u64, value: u64) bool {
        if (version < self.committed_version) return false;
        if (version == self.committed_version and self.committed_version != 0 and value != self.committed_value) {
            return false;
        }
        self.committed_version = version;
        self.committed_value = value;
        return true;
    }
};

const Replicas = struct {
    env: mar.Env,
    net: Network,
    state: [replica_count]Replica,

    fn init(env: mar.Env, net: Network) Replicas {
        return .{
            .env = env,
            .net = net,
            .state = [_]Replica{.{}} ** replica_count,
        };
    }

    const WriteOptions = struct {
        version: u64,
        value: u64,
        retry_limit: u8 = 1,
    };

    fn write(self: *Replicas, options: WriteOptions) !void {
        std.debug.assert(options.retry_limit > 0);

        var acked = [_]bool{false} ** replica_count;
        try self.env.record(
            "register.write.start version={} value={} retry_limit={}",
            .{ options.version, options.value, options.retry_limit },
        );

        for (0..options.retry_limit) |attempt| {
            if (countTrue(&acked) >= quorum) break;

            try self.env.record("register.write.attempt index={}", .{attempt});
            for (0..replica_count) |replica_index| {
                if (acked[replica_index]) continue;
                try self.send(@intCast(replica_index), .{
                    .kind = .propose,
                    .version = options.version,
                    .value = options.value,
                });
            }
            try self.drainAndAck(&acked);
        }

        const ack_count = countTrue(&acked);
        if (ack_count < quorum) {
            try self.env.record(
                "register.write.no_quorum version={} acks={}",
                .{ options.version, ack_count },
            );
            return;
        }

        try self.env.record(
            "register.write.quorum version={} value={} acks={}",
            .{ options.version, options.value, ack_count },
        );
        for (0..replica_count) |replica_index| {
            try self.send(@intCast(replica_index), .{
                .kind = .commit,
                .version = options.version,
                .value = options.value,
            });
        }
        try self.drainAndAck(null);
    }

    fn send(self: *Replicas, to: mar.NodeId, payload: MessagePayload) !void {
        try self.net.send(client_node_id, to, payload);
        try self.env.record(
            "register.message kind={s} to={} version={} value={}",
            .{ @tagName(payload.kind), to, payload.version, payload.value },
        );
    }

    fn drainAndAck(self: *Replicas, acked: ?*[replica_count]bool) !void {
        while (try self.net.nextDelivery()) |packet| {
            const accepted = try self.apply(packet);
            if (accepted) {
                if (acked) |acks| {
                    const replica_index: usize = @intCast(packet.to);
                    acks[replica_index] = true;
                }
            }
        }
    }

    fn apply(self: *Replicas, packet: Packet) !bool {
        const replica_index: usize = @intCast(packet.to);
        switch (packet.payload.kind) {
            .propose => {
                const accepted = self.state[replica_index].accept(packet.payload.version, packet.payload.value);
                try self.env.record(
                    "replica.accept replica={} version={} value={} accepted={}",
                    .{ packet.to, packet.payload.version, packet.payload.value, accepted },
                );
                return accepted;
            },
            .commit => {
                const committed = self.state[replica_index].commit(packet.payload.version, packet.payload.value);
                try self.env.record(
                    "replica.commit replica={} version={} value={} committed={}",
                    .{ packet.to, packet.payload.version, packet.payload.value, committed },
                );
                return false;
            },
        }
    }

    fn forceCommit(self: *Replicas, replica_index: usize, version: u64, value: u64) !void {
        self.state[replica_index].committed_version = version;
        self.state[replica_index].committed_value = value;
        try self.env.record(
            "replica.commit replica={} version={} value={} forced=true",
            .{ replica_index, version, value },
        );
    }
};

fn checkCommittedAgreement(replicas: *const Replicas) !void {
    var committed_count: u8 = 0;
    var expected_version: u64 = 0;
    var expected_value: u64 = 0;
    var have_expected = false;

    for (replicas.state, 0..) |replica, replica_index| {
        if (replica.committed_version == 0) continue;
        committed_count += 1;

        if (!have_expected) {
            expected_version = replica.committed_version;
            expected_value = replica.committed_value;
            have_expected = true;
            continue;
        }

        if (replica.committed_version != expected_version or
            replica.committed_value != expected_value)
        {
            try replicas.env.record(
                "register.invariant_violation kind=committed_divergence replica={} expected_version={} expected_value={} actual_version={} actual_value={}",
                .{
                    replica_index,
                    expected_version,
                    expected_value,
                    replica.committed_version,
                    replica.committed_value,
                },
            );
            return error.CommittedDivergence;
        }
    }

    try replicas.env.record(
        "register.check committed_agreement=ok committed_count={}",
        .{committed_count},
    );
}

fn checkCommittedQuorumAccepted(replicas: *const Replicas) !void {
    for (replicas.state, 0..) |replica, replica_index| {
        if (replica.committed_version == 0) continue;

        const accepted_count = countAccepted(replicas, replica.committed_version, replica.committed_value);
        if (accepted_count < quorum) {
            try replicas.env.record(
                "register.invariant_violation kind=commit_without_accepted_quorum replica={} version={} value={} accepted_count={}",
                .{ replica_index, replica.committed_version, replica.committed_value, accepted_count },
            );
            return error.CommitWithoutAcceptedQuorum;
        }
    }

    try replicas.env.record("register.check committed_quorum=ok", .{});
}

fn checkReplicaCommitted(
    replicas: *const Replicas,
    replica_id: mar.NodeId,
    version: u64,
    value: u64,
) !void {
    const replica_index: usize = @intCast(replica_id);
    const replica = replicas.state[replica_index];
    if (replica.committed_version != version or replica.committed_value != value) {
        try replicas.env.record(
            "register.invariant_violation kind=replica_not_committed replica={} expected_version={} expected_value={} actual_version={} actual_value={}",
            .{ replica_id, version, value, replica.committed_version, replica.committed_value },
        );
        return error.ReplicaNotCommitted;
    }

    try replicas.env.record(
        "register.check replica_committed=ok replica={} version={} value={}",
        .{ replica_id, version, value },
    );
}

fn countAccepted(replicas: *const Replicas, version: u64, value: u64) u8 {
    var count: u8 = 0;
    for (replicas.state) |replica| {
        if (replica.accepted_version == version and replica.accepted_value == value) {
            count += 1;
        }
    }
    return count;
}

fn countTrue(values: *const [replica_count]bool) u8 {
    var count: u8 = 0;
    for (values) |value| {
        if (value) count += 1;
    }
    return count;
}

test "register: smoke" {
    try mar.expectPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "register: smoke fuzz" {
    try mar.expectFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 32,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "register: bug detected" {
    try mar.expectFailure(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .scenario = buggyScenario,
        .checks = &checks,
    });
}

test "register: partition" {
    try mar.expectPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .scenario = partitionScenario,
        .checks = &checks,
    });
}

test "register: conflict" {
    try mar.expectPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .init = Harness.init,
        .scenario = conflictScenario,
        .checks = &checks,
    });
}
