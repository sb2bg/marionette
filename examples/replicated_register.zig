//! Replicated register: a tiny VOPR-shaped distributed example.
//!
//! Demonstrates Marionette's network API direction: typed messaging,
//! deterministic delivery, partition injection, and a separate checker.

const std = @import("std");
const mar = @import("marionette");
const support = @import("support.zig");

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

const RegisterValue = struct {
    version: u64,
    value: u64,
};

const Endpoint = mar.Endpoint(MessagePayload);
const Case = mar.SimCase(Replicas);

const simulate_options: mar.World.SimulateOptions = .{ .network = .{
    .nodes = replica_count + 1,
    .service_nodes = replica_count,
    .path_capacity = max_messages,
} };

fn swarmProfile() mar.SimProfile.Expanded {
    return mar.SimProfile.swarm(.{
        .tick_ns = tick_ns,
        .network = .{
            .nodes = replica_count + 1,
            .service_nodes = replica_count,
            .path_capacity = max_messages,
        },
    }).expand();
}

pub const checks = [_]mar.StateCheck(Case){
    .{ .name = "committed register is safe", .check = committedRegisterIsSafe },
};

/// Run the correct replicated-register scenario and return an owned trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    return runTrace(allocator, seed, "replicated-register-smoke", scenario);
}

/// Run a deliberately buggy scenario. Tests use this to prove the checker
/// catches divergent committed state without making the normal suite fail.
pub fn runBuggyScenarioReport(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return runReport(allocator, seed, "replicated-register-bug", buggyScenario);
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
    comptime scenario_fn: fn (*Case) anyerror!void,
) ![]u8 {
    var report = try runReport(allocator, seed, name, scenario_fn);
    defer report.deinit();

    return support.takePassedTrace(&report);
}

fn runReport(
    allocator: std.mem.Allocator,
    seed: u64,
    name: []const u8,
    comptime scenario_fn: fn (*Case) anyerror!void,
) !mar.RunReport {
    return mar.runSimCase(.{
        .allocator = allocator,
        .seed = seed,
        .tick_ns = tick_ns,
        .name = name,
        .simulate = simulate_options,
        .init = initReplicas,
        .scenario = scenario_fn,
        .checks = &checks,
    });
}

fn initReplicas(sim: mar.Sim) !Replicas {
    return Replicas.init(
        sim.env,
        try sim.endpoint(MessagePayload, client_node_id),
        try sim.endpoints(MessagePayload, replica_count, 0),
    );
}

fn committedRegisterIsSafe(case: *const Case) !void {
    try checkCommittedAgreement(&case.app);
    try checkCommittedQuorumAccepted(&case.app);
}

pub fn scenario(case: *Case) !void {
    try case.control().network.setLossiness(.{ .drop_rate = .percent(20) });
    try case.app.write(.{ .version = 1, .value = 41, .retry_limit = 8 });
}

pub fn buggyScenario(case: *Case) !void {
    try case.app.forceCommit(0, 1, 41);
    try case.app.forceCommit(1, 1, 42);
}

pub fn partitionScenario(case: *Case) !void {
    const isolated = [_]mar.NodeId{0};
    const majority = [_]mar.NodeId{ 1, 2, client_node_id };

    try case.control().network.partition(&isolated, &majority);
    try case.app.write(.{ .version = 1, .value = 41, .retry_limit = 2 });

    try case.control().network.heal();
    try case.app.write(.{ .version = 1, .value = 41, .retry_limit = 1 });

    try checkReplicaCommitted(&case.app, 0, 1, 41);
}

pub fn conflictScenario(case: *Case) !void {
    try case.app.write(.{ .version = 1, .value = 41 });
    try case.app.write(.{ .version = 1, .value = 42 });
}

pub fn swarmScenario(case: *Case) !void {
    const profile = swarmProfile();
    try profile.apply(case.control());

    try case.control().runFor(4 * tick_ns);
    try case.app.write(.{ .version = 1, .value = 41, .retry_limit = 6 });

    try case.control().runFor(4 * tick_ns);
    try case.app.write(.{ .version = 2, .value = 42, .retry_limit = 6 });

    try case.control().network.heal();
    try case.control().network.setLossiness(.{});
    try case.control().network.setClogs(.{});
    try case.control().network.setPartitionDynamics(.{});
    try case.app.write(.{ .version = 2, .value = 42, .retry_limit = 2 });
}

const Replica = struct {
    accepted: ?RegisterValue = null,
    committed: ?RegisterValue = null,

    fn accept(self: *Replica, version: u64, value: u64) bool {
        if (self.accepted) |current| {
            if (version < current.version) return false;
            if (version == current.version and value != current.value) return false;
        }

        self.accepted = .{ .version = version, .value = value };
        return true;
    }

    fn commit(self: *Replica, version: u64, value: u64) bool {
        if (self.committed) |current| {
            if (version < current.version) return false;
            if (version == current.version and value != current.value) return false;
        }

        self.committed = .{ .version = version, .value = value };
        return true;
    }
};

const Replicas = struct {
    env: mar.Env,
    client: Endpoint,
    replicas: [replica_count]Endpoint,
    state: [replica_count]Replica,

    fn init(env: mar.Env, client: Endpoint, replicas: [replica_count]Endpoint) Replicas {
        return .{
            .env = env,
            .client = client,
            .replicas = replicas,
            .state = @splat(.{}),
        };
    }

    const WriteOptions = struct {
        version: u64,
        value: u64,
        retry_limit: u8 = 1,
    };

    fn write(self: *Replicas, options: WriteOptions) !void {
        std.debug.assert(options.retry_limit > 0);

        var acked: [replica_count]bool = @splat(false);
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
        try self.client.send(to, payload);
        try self.env.record(
            "register.message kind={s} to={} version={} value={}",
            .{ @tagName(payload.kind), to, payload.version, payload.value },
        );
    }

    fn drainAndAck(self: *Replicas, acked: ?*[replica_count]bool) !void {
        while (true) {
            var progressed = false;

            for (self.replicas, 0..) |endpoint, replica_index| {
                while (try endpoint.receive()) |envelope| {
                    progressed = true;
                    const accepted = try self.apply(replica_index, envelope);
                    if (accepted) {
                        if (acked) |acks| {
                            acks[replica_index] = true;
                        }
                    }
                }
            }

            if (!progressed) break;
        }
    }

    fn apply(self: *Replicas, replica_index: usize, envelope: Endpoint.Envelope) !bool {
        const replica_node: mar.NodeId = @intCast(replica_index);
        switch (envelope.message.kind) {
            .propose => {
                const accepted = self.state[replica_index].accept(envelope.message.version, envelope.message.value);
                try self.env.record(
                    "replica.accept replica={} version={} value={} accepted={}",
                    .{ replica_node, envelope.message.version, envelope.message.value, accepted },
                );
                return accepted;
            },
            .commit => {
                const committed = self.state[replica_index].commit(envelope.message.version, envelope.message.value);
                try self.env.record(
                    "replica.commit replica={} version={} value={} committed={}",
                    .{ replica_node, envelope.message.version, envelope.message.value, committed },
                );
                return false;
            },
        }
    }

    fn forceCommit(self: *Replicas, replica_index: usize, version: u64, value: u64) !void {
        self.state[replica_index].committed = .{ .version = version, .value = value };
        try self.env.record(
            "replica.commit replica={} version={} value={} forced=true",
            .{ replica_index, version, value },
        );
    }
};

fn checkCommittedAgreement(replicas: *const Replicas) !void {
    var committed_count: u8 = 0;
    var expected: ?RegisterValue = null;

    for (replicas.state, 0..) |replica, replica_index| {
        const committed = replica.committed orelse continue;
        committed_count += 1;

        if (expected == null) {
            expected = committed;
            continue;
        }

        if (committed.version != expected.?.version or
            committed.value != expected.?.value)
        {
            try replicas.env.record(
                "register.invariant_violation kind=committed_divergence replica={} expected_version={} expected_value={} actual_version={} actual_value={}",
                .{
                    replica_index,
                    expected.?.version,
                    expected.?.value,
                    committed.version,
                    committed.value,
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
        const committed = replica.committed orelse continue;

        const accepted_count = countAccepted(replicas, committed.version, committed.value);
        if (accepted_count < quorum) {
            try replicas.env.record(
                "register.invariant_violation kind=commit_without_accepted_quorum replica={} version={} value={} accepted_count={}",
                .{ replica_index, committed.version, committed.value, accepted_count },
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
    const committed = replica.committed orelse {
        try replicas.env.record(
            "register.invariant_violation kind=replica_not_committed replica={} expected_version={} expected_value={} actual_version=null actual_value=null",
            .{ replica_id, version, value },
        );
        return error.ReplicaNotCommitted;
    };

    if (committed.version != version or committed.value != value) {
        try replicas.env.record(
            "register.invariant_violation kind=replica_not_committed replica={} expected_version={} expected_value={} actual_version={} actual_value={}",
            .{ replica_id, version, value, committed.version, committed.value },
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
        const accepted = replica.accepted orelse continue;
        if (accepted.version == version and accepted.value == value) {
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
    try mar.expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .simulate = simulate_options,
        .init = initReplicas,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "register: smoke fuzz" {
    try mar.expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 32,
        .tick_ns = tick_ns,
        .simulate = simulate_options,
        .init = initReplicas,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "register: bug detected" {
    try mar.expectSimFailure(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .simulate = simulate_options,
        .init = initReplicas,
        .scenario = buggyScenario,
        .checks = &checks,
    });
}

test "register: partition" {
    try mar.expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .simulate = simulate_options,
        .init = initReplicas,
        .scenario = partitionScenario,
        .checks = &checks,
    });
}

test "register: conflict" {
    try mar.expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .tick_ns = tick_ns,
        .simulate = simulate_options,
        .init = initReplicas,
        .scenario = conflictScenario,
        .checks = &checks,
    });
}

test "register: swarm fuzz" {
    const profile = swarmProfile();
    try mar.expectSimFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 100,
        .tick_ns = tick_ns,
        .name = "replicated-register-swarm",
        .tags = profile.runTags(),
        .attributes = profile.runAttributes(),
        .simulate = profile.simulateOptions(),
        .init = initReplicas,
        .scenario = swarmScenario,
        .checks = &checks,
    });
}

test "register: swarm fuzz exercises tick-evolved network faults" {
    var saw_auto_partition = false;
    var saw_auto_clog = false;

    for (0..100) |iteration| {
        const profile = swarmProfile();
        var report = try mar.runSimCase(.{
            .allocator = std.testing.allocator,
            .seed = 0xC0FFEE + @as(u64, @intCast(iteration)),
            .tick_ns = tick_ns,
            .name = "replicated-register-swarm",
            .tags = profile.runTags(),
            .attributes = profile.runAttributes(),
            .simulate = profile.simulateOptions(),
            .init = initReplicas,
            .scenario = swarmScenario,
            .checks = &checks,
        });
        defer report.deinit();

        switch (report) {
            .passed => |passed| {
                saw_auto_partition = saw_auto_partition or
                    std.mem.indexOf(u8, passed.trace, "network.auto_partition") != null;
                saw_auto_clog = saw_auto_clog or
                    std.mem.indexOf(u8, passed.trace, "automatic=true") != null;
            },
            .failed => |failure| {
                failure.print();
                return error.ExpectedRunPass;
            },
        }

        if (saw_auto_partition and saw_auto_clog) break;
    }

    try std.testing.expect(saw_auto_partition);
    try std.testing.expect(saw_auto_clog);
}
