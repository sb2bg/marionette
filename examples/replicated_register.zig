//! Tiny VOPR-inspired replicated register showcase.
//!
//! This is not a real consensus protocol. It is a compact example of the
//! shapes Marionette needs for distributed simulation: seeded message faults,
//! deterministic delivery order, traceable decisions, and a separate checker.

const std = @import("std");
const mar = @import("marionette");

const ns_per_ms: mar.Duration = 1_000_000;
const replica_count = 3;
const quorum = 2;
const max_messages = 64;
const client_node_id: mar.NodeId = replica_count;

const NormalRunProfile = struct {
    replicas: u64,
    quorum: u64,
    max_messages: u64,
    proposal_drop_percent: u8,
    retry_limit: u8,
};

const CommonRunProfile = struct {
    replicas: u64,
    quorum: u64,
};

const PartitionRunProfile = struct {
    replicas: u64,
    quorum: u64,
    max_messages: u64,
    client_node_id: u64,
    partitioned_replica: u64,
    retry_limit: u8,
    catchup_retry_limit: u8,
};

const normal_profile: NormalRunProfile = .{
    .replicas = replica_count,
    .quorum = quorum,
    .max_messages = max_messages,
    .proposal_drop_percent = 20,
    .retry_limit = 8,
};

const common_profile: CommonRunProfile = .{
    .replicas = replica_count,
    .quorum = quorum,
};

const partition_profile: PartitionRunProfile = .{
    .replicas = replica_count,
    .quorum = quorum,
    .max_messages = max_messages,
    .client_node_id = client_node_id,
    .partitioned_replica = 0,
    .retry_limit = 2,
    .catchup_retry_limit = 1,
};

const checks = [_]mar.StateCheck(Cluster){
    .{ .name = "committed register is safe", .check = committedRegisterIsSafe },
};

const normal_tags = [_][]const u8{
    "example:replicated_register",
    "scenario:smoke",
};

const normal_attributes = mar.runAttributesFrom(normal_profile);

const buggy_tags = [_][]const u8{
    "example:replicated_register",
    "scenario:bug",
    "bug:forced_divergent_commit",
};

const common_attributes = mar.runAttributesFrom(common_profile);

const partition_tags = [_][]const u8{
    "example:replicated_register",
    "scenario:partition",
};

const partition_attributes = mar.runAttributesFrom(partition_profile);

const conflict_tags = [_][]const u8{
    "example:replicated_register",
    "scenario:conflict",
    "conflict:same_version_different_value",
};

/// Run the correct replicated-register scenario and return an owned trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try mar.runWithStateInit(
        allocator,
        .{
            .seed = seed,
            .tick_ns = ns_per_ms,
            .profile_name = "replicated-register-smoke",
            .tags = &normal_tags,
            .attributes = &normal_attributes,
        },
        Cluster,
        Cluster.init,
        scenario,
        &checks,
    );
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.ReplicatedRegisterScenarioFailed;
        },
    }
}

/// Run a deliberately buggy scenario. Tests use this to prove the checker
/// catches divergent committed state without making the normal suite fail.
pub fn runBuggyScenario(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return mar.runWithStateInit(
        allocator,
        .{
            .seed = seed,
            .tick_ns = ns_per_ms,
            .profile_name = "replicated-register-bug",
            .tags = &buggy_tags,
            .attributes = &common_attributes,
        },
        Cluster,
        Cluster.init,
        buggyScenario,
        &checks,
    );
}

/// Run a scenario that writes through a partition and return an owned trace.
pub fn runPartitionScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try mar.runWithStateInit(
        allocator,
        .{
            .seed = seed,
            .tick_ns = ns_per_ms,
            .profile_name = "replicated-register-partition",
            .tags = &partition_tags,
            .attributes = &partition_attributes,
        },
        Cluster,
        Cluster.init,
        partitionScenario,
        &checks,
    );
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.ReplicatedRegisterScenarioFailed;
        },
    }
}

/// Run a same-version conflict scenario and return an owned trace.
pub fn runConflictScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try mar.runWithStateInit(
        allocator,
        .{
            .seed = seed,
            .tick_ns = ns_per_ms,
            .profile_name = "replicated-register-conflict",
            .tags = &conflict_tags,
            .attributes = &common_attributes,
        },
        Cluster,
        Cluster.init,
        conflictScenario,
        &checks,
    );
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.ReplicatedRegisterScenarioFailed;
        },
    }
}

fn committedRegisterIsSafe(cluster: *const Cluster) !void {
    try cluster.checkCommittedAgreement();
    try cluster.checkCommittedQuorumAccepted();
}

fn scenario(cluster: *Cluster) !void {
    try cluster.write(.{
        .version = 1,
        .value = 41,
        .proposal_drop_percent = normal_profile.proposal_drop_percent,
        .retry_limit = normal_profile.retry_limit,
    });
}

fn buggyScenario(cluster: *Cluster) !void {
    try cluster.forceCommit(0, 1, 41);
    try cluster.forceCommit(1, 1, 42);
}

fn partitionScenario(cluster: *Cluster) !void {
    std.debug.assert(partition_profile.partitioned_replica < replica_count);

    const partitioned_replica: mar.NodeId = @intCast(partition_profile.partitioned_replica);
    const isolated = [_]mar.NodeId{partitioned_replica};
    var majority_side: [replica_count]mar.NodeId = undefined;
    const majority_side_len = buildMajoritySide(partitioned_replica, &majority_side);

    try cluster.sim.network().partition(&isolated, majority_side[0..majority_side_len]);
    try cluster.write(.{
        .version = 1,
        .value = 41,
        .retry_limit = partition_profile.retry_limit,
    });
    try cluster.sim.network().heal();
    try cluster.write(.{
        .version = 1,
        .value = 41,
        .retry_limit = partition_profile.catchup_retry_limit,
    });
    try cluster.checkReplicaCommitted(partitioned_replica, 1, 41);
}

fn conflictScenario(cluster: *Cluster) !void {
    try cluster.write(.{
        .version = 1,
        .value = 41,
        .retry_limit = 1,
    });
    try cluster.write(.{
        .version = 1,
        .value = 42,
        .retry_limit = 1,
    });
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

const MessageKind = enum {
    propose,
    commit,
};

const MessagePayload = struct {
    kind: MessageKind,
    version: u64,
    value: u64,
};

const network_options: mar.UnstableNetworkOptions = .{
    .node_count = replica_count,
    .client_count = 1,
    .path_capacity = max_messages,
};

const Simulation = mar.UnstableNetworkSimulation(MessagePayload, network_options);
const Network = Simulation.PacketCore;

const Cluster = struct {
    env: mar.AppEnv,
    control: mar.SimControl,
    replicas: [replica_count]Replica,
    sim: Simulation,

    const WriteOptions = struct {
        version: u64,
        value: u64,
        proposal_drop_percent: u8 = 0,
        commit_drop_percent: u8 = 0,
        retry_limit: u8 = 1,
    };

    fn init(world: *mar.World) !Cluster {
        const sim_env = try world.simulate(.{});
        return .{
            .env = sim_env.env,
            .control = sim_env.control,
            .replicas = [_]Replica{.{}} ** replica_count,
            .sim = Simulation.init(world),
        };
    }

    fn write(self: *Cluster, options: WriteOptions) !void {
        std.debug.assert(options.proposal_drop_percent <= 100);
        std.debug.assert(options.commit_drop_percent <= 100);
        std.debug.assert(options.retry_limit > 0);

        var acked = [_]bool{false} ** replica_count;
        try self.env.record(
            "register.write.start version={} value={} proposal_drop_percent={} retry_limit={}",
            .{ options.version, options.value, options.proposal_drop_percent, options.retry_limit },
        );

        for (0..options.retry_limit) |attempt| {
            if (countAcks(&acked) >= quorum) break;

            try self.env.record("register.write.attempt index={}", .{attempt});
            for (0..replica_count) |replica_index| {
                if (acked[replica_index]) continue;
                try self.send(
                    @intCast(replica_index),
                    .propose,
                    options.version,
                    options.value,
                    options.proposal_drop_percent,
                );
            }
            try self.drain(&acked);
        }

        const ack_count = countAcks(&acked);
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
            try self.send(
                @intCast(replica_index),
                .commit,
                options.version,
                options.value,
                options.commit_drop_percent,
            );
        }
        try self.drain(null);
    }

    fn send(
        self: *Cluster,
        to: mar.NodeId,
        kind: MessageKind,
        version: u64,
        value: u64,
        drop_percent: u8,
    ) !void {
        try self.sim.packetCore().send(client_node_id, to, .{
            .kind = kind,
            .version = version,
            .value = value,
        }, .{
            .drop_rate = .percent(drop_percent),
            .min_latency_ns = ns_per_ms,
            .latency_jitter_ns = 2 * ns_per_ms,
        });
        try self.env.record("register.message kind={s} to={} version={} value={}", .{
            @tagName(kind),
            to,
            version,
            value,
        });
    }

    fn drain(self: *Cluster, acked: ?*[replica_count]bool) !void {
        var context: DeliveryContext = .{
            .cluster = self,
            .acked = acked,
        };
        try self.sim.drainUntilIdle(&context, DeliveryContext.deliver);
    }

    const DeliveryContext = struct {
        cluster: *Cluster,
        acked: ?*[replica_count]bool,

        fn deliver(self: *@This(), _: *mar.World, packet: Network.Packet) !void {
            try self.cluster.apply(packet, self.acked);
        }
    };

    fn apply(
        self: *Cluster,
        packet: Network.Packet,
        acked: ?*[replica_count]bool,
    ) !void {
        const replica_index: usize = @intCast(packet.to);
        switch (packet.payload.kind) {
            .propose => {
                const accepted = self.replicas[replica_index].accept(packet.payload.version, packet.payload.value);
                if (accepted) {
                    if (acked) |acks| acks[replica_index] = true;
                }
                try self.env.record(
                    "replica.accept replica={} version={} value={} accepted={}",
                    .{ packet.to, packet.payload.version, packet.payload.value, accepted },
                );
            },
            .commit => {
                const committed = self.replicas[replica_index].commit(packet.payload.version, packet.payload.value);
                try self.env.record(
                    "replica.commit replica={} version={} value={} committed={}",
                    .{ packet.to, packet.payload.version, packet.payload.value, committed },
                );
            },
        }
    }

    fn forceCommit(self: *Cluster, replica_index: usize, version: u64, value: u64) !void {
        self.replicas[replica_index].committed_version = version;
        self.replicas[replica_index].committed_value = value;
        try self.env.record(
            "replica.commit replica={} version={} value={} forced=true",
            .{ replica_index, version, value },
        );
    }

    fn checkCommittedAgreement(self: *const Cluster) !void {
        var committed_count: u8 = 0;
        var expected_version: u64 = 0;
        var expected_value: u64 = 0;
        var have_expected = false;

        for (self.replicas, 0..) |replica, replica_index| {
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
                try self.env.record(
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

        try self.env.record(
            "register.check committed_agreement=ok committed_count={}",
            .{committed_count},
        );
    }

    fn checkCommittedQuorumAccepted(self: *const Cluster) !void {
        for (self.replicas, 0..) |replica, replica_index| {
            if (replica.committed_version == 0) continue;

            const accepted_count = self.countAccepted(replica.committed_version, replica.committed_value);
            if (accepted_count < quorum) {
                try self.env.record(
                    "register.invariant_violation kind=commit_without_accepted_quorum replica={} version={} value={} accepted_count={}",
                    .{ replica_index, replica.committed_version, replica.committed_value, accepted_count },
                );
                return error.CommitWithoutAcceptedQuorum;
            }
        }

        try self.env.record("register.check committed_quorum=ok", .{});
    }

    fn checkReplicaCommitted(
        self: *const Cluster,
        replica_id: mar.NodeId,
        version: u64,
        value: u64,
    ) !void {
        const replica_index: usize = @intCast(replica_id);
        const replica = self.replicas[replica_index];
        if (replica.committed_version != version or replica.committed_value != value) {
            try self.env.record(
                "register.invariant_violation kind=replica_not_committed replica={} expected_version={} expected_value={} actual_version={} actual_value={}",
                .{ replica_id, version, value, replica.committed_version, replica.committed_value },
            );
            return error.ReplicaNotCommitted;
        }

        try self.env.record(
            "register.check replica_committed=ok replica={} version={} value={}",
            .{ replica_id, version, value },
        );
    }

    fn countAccepted(self: *const Cluster, version: u64, value: u64) u8 {
        var count: u8 = 0;
        for (self.replicas) |replica| {
            if (replica.accepted_version == version and replica.accepted_value == value) {
                count += 1;
            }
        }
        return count;
    }
};

fn buildMajoritySide(partitioned_replica: mar.NodeId, output: *[replica_count]mar.NodeId) usize {
    output[0] = client_node_id;
    var len: usize = 1;
    for (0..replica_count) |replica_index| {
        const replica_id: mar.NodeId = @intCast(replica_index);
        if (replica_id == partitioned_replica) continue;
        output[len] = replica_id;
        len += 1;
    }
    return len;
}

fn countAcks(acked: *const [replica_count]bool) u8 {
    var count: u8 = 0;
    for (acked) |accepted| {
        if (accepted) count += 1;
    }
    return count;
}
