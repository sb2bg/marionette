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

const checks = [_]mar.Check{
    .{ .name = "committed replicas agree", .check = noCommittedDivergence },
};

/// Run the correct replicated-register scenario and return an owned trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try mar.run(allocator, .{
        .seed = seed,
        .tick_ns = ns_per_ms,
        .checks = &checks,
    }, scenario);
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
    return mar.run(allocator, .{
        .seed = seed,
        .tick_ns = ns_per_ms,
        .checks = &checks,
    }, buggyScenario);
}

fn noCommittedDivergence(world: *mar.World) !void {
    if (std.mem.indexOf(u8, world.traceBytes(), "register.invariant_violation") != null) {
        return error.CommittedDivergence;
    }
}

fn scenario(world: *mar.World) !void {
    var cluster = Cluster.init();
    try cluster.write(world, .{
        .version = 1,
        .value = 41,
        .proposal_drop_percent = 20,
        .retry_limit = 8,
    });
}

fn buggyScenario(world: *mar.World) !void {
    var cluster = Cluster.init();
    try cluster.forceCommit(world, 0, 1, 41);
    try cluster.forceCommit(world, 1, 1, 42);
    try cluster.recordCommittedAgreement(world);
}

const Replica = struct {
    accepted_version: u64 = 0,
    accepted_value: u64 = 0,
    committed_version: u64 = 0,
    committed_value: u64 = 0,

    fn accept(self: *Replica, version: u64, value: u64) bool {
        if (version < self.accepted_version) return false;
        self.accepted_version = version;
        self.accepted_value = value;
        return true;
    }

    fn commit(self: *Replica, version: u64, value: u64) void {
        if (version < self.committed_version) return;
        self.committed_version = version;
        self.committed_value = value;
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

const Cluster = struct {
    replicas: [replica_count]Replica,
    pending: [max_messages]Message,
    pending_len: usize,
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
            .pending = undefined,
            .pending_len = 0,
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
            try self.recordCommittedAgreement(world);
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
        try self.recordCommittedAgreement(world);
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

        std.debug.assert(self.pending_len < self.pending.len);
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
        self.pending[self.pending_len] = message;
        self.pending_len += 1;

        try world.record(
            "network.send id={} kind={s} to={} version={} value={} deliver_at={}",
            .{ message.id, @tagName(kind), to, version, value, message.deliver_at },
        );
    }

    fn drain(self: *Cluster, world: *mar.World, acked: ?*[replica_count]bool) !void {
        while (self.pending_len > 0) {
            const index = self.nextMessageIndex();
            const message = self.removeMessage(index);
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

    fn nextMessageIndex(self: *const Cluster) usize {
        std.debug.assert(self.pending_len > 0);

        var best: usize = 0;
        for (self.pending[1..self.pending_len], 1..) |message, index| {
            const current = self.pending[best];
            if (message.deliver_at < current.deliver_at or
                (message.deliver_at == current.deliver_at and message.id < current.id))
            {
                best = index;
            }
        }
        return best;
    }

    fn removeMessage(self: *Cluster, index: usize) Message {
        const message = self.pending[index];
        std.mem.copyForwards(
            Message,
            self.pending[index .. self.pending_len - 1],
            self.pending[index + 1 .. self.pending_len],
        );
        self.pending_len -= 1;
        return message;
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
                self.replicas[replica_index].commit(message.version, message.value);
                try world.record(
                    "replica.commit replica={} version={} value={}",
                    .{ message.to, message.version, message.value },
                );
            },
        }
    }

    fn forceCommit(self: *Cluster, world: *mar.World, replica_index: usize, version: u64, value: u64) !void {
        self.replicas[replica_index].commit(version, value);
        try world.record(
            "replica.commit replica={} version={} value={} forced=true",
            .{ replica_index, version, value },
        );
    }

    fn recordCommittedAgreement(self: *const Cluster, world: *mar.World) !void {
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
                return;
            }
        }

        try world.record(
            "register.check committed_agreement=ok committed_count={}",
            .{committed_count},
        );
    }
};

fn countAcks(acked: *const [replica_count]bool) u8 {
    var count: u8 = 0;
    for (acked) |accepted| {
        if (accepted) count += 1;
    }
    return count;
}
