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

const conflict_tags = [_][]const u8{
    "example:replicated_register",
    "scenario:conflict",
    "conflict:same_version_different_value",
};

/// Run the correct replicated-register scenario and return an owned trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try mar.runWithState(
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
    return mar.runWithState(
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

/// Run a same-version conflict scenario and return an owned trace.
pub fn runConflictScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try mar.runWithState(
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

fn committedRegisterIsSafe(world: *mar.World, cluster: *const Cluster) !void {
    try cluster.checkCommittedAgreement(world);
    try cluster.checkCommittedQuorumAccepted(world);
}

fn scenario(world: *mar.World, cluster: *Cluster) !void {
    try cluster.write(world, .{
        .version = 1,
        .value = 41,
        .proposal_drop_percent = normal_profile.proposal_drop_percent,
        .retry_limit = normal_profile.retry_limit,
    });
}

fn buggyScenario(world: *mar.World, cluster: *Cluster) !void {
    try cluster.forceCommit(world, 0, 1, 41);
    try cluster.forceCommit(world, 1, 1, 42);
}

fn conflictScenario(world: *mar.World, cluster: *Cluster) !void {
    try cluster.write(world, .{
        .version = 1,
        .value = 41,
        .retry_limit = 1,
    });
    try cluster.write(world, .{
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

const Message = struct {
    id: u64,
    deliver_at: mar.Timestamp,
    to: u8,
    kind: MessageKind,
    version: u64,
    value: u64,
};

fn messageLessThan(a: Message, b: Message) bool {
    return a.deliver_at < b.deliver_at or (a.deliver_at == b.deliver_at and a.id < b.id);
}

const MessageQueue = mar.EventQueue(Message, max_messages, messageLessThan);

const Cluster = struct {
    replicas: [replica_count]Replica,
    pending: MessageQueue,
    next_message_id: u64,

    const WriteOptions = struct {
        version: u64,
        value: u64,
        proposal_drop_percent: u8 = 0,
        commit_drop_percent: u8 = 0,
        retry_limit: u8 = 1,
    };

    fn init() Cluster {
        return .{
            .replicas = [_]Replica{.{}} ** replica_count,
            .pending = MessageQueue.init(),
            .next_message_id = 0,
        };
    }

    fn write(self: *Cluster, world: *mar.World, options: WriteOptions) !void {
        std.debug.assert(options.proposal_drop_percent <= 100);
        std.debug.assert(options.commit_drop_percent <= 100);
        std.debug.assert(options.retry_limit > 0);

        var acked = [_]bool{false} ** replica_count;
        try world.record(
            "register.write.start version={} value={} proposal_drop_percent={} retry_limit={}",
            .{ options.version, options.value, options.proposal_drop_percent, options.retry_limit },
        );

        for (0..options.retry_limit) |attempt| {
            if (countAcks(&acked) >= quorum) break;

            try world.record("register.write.attempt index={}", .{attempt});
            for (0..replica_count) |replica_index| {
                if (acked[replica_index]) continue;
                try self.send(
                    world,
                    @intCast(replica_index),
                    .propose,
                    options.version,
                    options.value,
                    options.proposal_drop_percent,
                );
            }
            try self.drain(world, &acked);
        }

        const ack_count = countAcks(&acked);
        if (ack_count < quorum) {
            try world.record(
                "register.write.no_quorum version={} acks={}",
                .{ options.version, ack_count },
            );
            return;
        }

        try world.record(
            "register.write.quorum version={} value={} acks={}",
            .{ options.version, options.value, ack_count },
        );
        for (0..replica_count) |replica_index| {
            try self.send(
                world,
                @intCast(replica_index),
                .commit,
                options.version,
                options.value,
                options.commit_drop_percent,
            );
        }
        try self.drain(world, null);
    }

    fn send(
        self: *Cluster,
        world: *mar.World,
        to: u8,
        kind: MessageKind,
        version: u64,
        value: u64,
        drop_percent: u8,
    ) !void {
        const roll = try world.randomIntLessThan(u8, 100);
        if (roll < drop_percent) {
            try world.record(
                "network.drop kind={s} to={} version={} roll={} drop_percent={}",
                .{ @tagName(kind), to, version, roll, drop_percent },
            );
            return;
        }

        const latency_ticks = 1 + try world.randomIntLessThan(u64, 3);
        const message: Message = .{
            .id = self.next_message_id,
            .deliver_at = world.now() + latency_ticks * ns_per_ms,
            .to = to,
            .kind = kind,
            .version = version,
            .value = value,
        };
        self.next_message_id += 1;
        try self.pending.push(message);

        try world.record(
            "network.send id={} kind={s} to={} version={} value={} deliver_at={}",
            .{ message.id, @tagName(kind), to, version, value, message.deliver_at },
        );
    }

    fn drain(self: *Cluster, world: *mar.World, acked: ?*[replica_count]bool) !void {
        while (self.pending.pop()) |message| {
            if (message.deliver_at > world.now()) {
                try world.runFor(message.deliver_at - world.now());
            }

            try world.record(
                "network.deliver id={} kind={s} to={} now_ns={}",
                .{ message.id, @tagName(message.kind), message.to, world.now() },
            );
            try self.apply(world, message, acked);
        }
    }

    fn apply(
        self: *Cluster,
        world: *mar.World,
        message: Message,
        acked: ?*[replica_count]bool,
    ) !void {
        const replica_index: usize = message.to;
        switch (message.kind) {
            .propose => {
                const accepted = self.replicas[replica_index].accept(message.version, message.value);
                if (accepted) {
                    if (acked) |acks| acks[replica_index] = true;
                }
                try world.record(
                    "replica.accept replica={} version={} value={} accepted={}",
                    .{ message.to, message.version, message.value, accepted },
                );
            },
            .commit => {
                const committed = self.replicas[replica_index].commit(message.version, message.value);
                try world.record(
                    "replica.commit replica={} version={} value={} committed={}",
                    .{ message.to, message.version, message.value, committed },
                );
            },
        }
    }

    fn forceCommit(self: *Cluster, world: *mar.World, replica_index: usize, version: u64, value: u64) !void {
        self.replicas[replica_index].committed_version = version;
        self.replicas[replica_index].committed_value = value;
        try world.record(
            "replica.commit replica={} version={} value={} forced=true",
            .{ replica_index, version, value },
        );
    }

    fn checkCommittedAgreement(self: *const Cluster, world: *mar.World) !void {
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
                try world.record(
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

        try world.record(
            "register.check committed_agreement=ok committed_count={}",
            .{committed_count},
        );
    }

    fn checkCommittedQuorumAccepted(self: *const Cluster, world: *mar.World) !void {
        for (self.replicas, 0..) |replica, replica_index| {
            if (replica.committed_version == 0) continue;

            const accepted_count = self.countAccepted(replica.committed_version, replica.committed_value);
            if (accepted_count < quorum) {
                try world.record(
                    "register.invariant_violation kind=commit_without_accepted_quorum replica={} version={} value={} accepted_count={}",
                    .{ replica_index, replica.committed_version, replica.committed_value, accepted_count },
                );
                return error.CommitWithoutAcceptedQuorum;
            }
        }

        try world.record("register.check committed_quorum=ok", .{});
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

fn countAcks(acked: *const [replica_count]bool) u8 {
    var count: u8 = 0;
    for (acked) |accepted| {
        if (accepted) count += 1;
    }
    return count;
}
