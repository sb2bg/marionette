//! Retry queue showcase with a deliberately buggy late-ack path.
//!
//! This is the README-facing example: a leased job times out, gets leased to a
//! second worker, and a late completion from the first worker races with the
//! second completion. The checker proves a job is completed at most once.

const std = @import("std");
const mar = @import("marionette");

const ns_per_ms: mar.Duration = 1_000_000;

const Profile = struct {
    job_id: u64,
    lease_ticks: u64,
    first_worker: u64,
    second_worker: u64,
};

const profile: Profile = .{
    .job_id = 7,
    .lease_ticks = 5,
    .first_worker = 1,
    .second_worker = 2,
};

const tags = [_][]const u8{
    "example:retry_queue",
    "scenario:late_ack",
};

const attributes = mar.runAttributesFrom(profile);

const checks = [_]mar.StateCheck(RetryQueue){
    .{ .name = "job completed at most once", .check = jobCompletedAtMostOnce },
};

/// Run the correct retry-queue scenario and return an owned trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try mar.runWithState(
        allocator,
        .{
            .seed = seed,
            .tick_ns = ns_per_ms,
            .profile_name = "retry-queue-late-ack",
            .tags = &tags,
            .attributes = &attributes,
        },
        RetryQueue,
        RetryQueue.init,
        scenario,
        &checks,
    );
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.RetryQueueScenarioFailed;
        },
    }
}

/// Run the deliberately buggy late-ack scenario.
pub fn runBuggyScenario(allocator: std.mem.Allocator, seed: u64) !mar.RunReport {
    return mar.runWithState(
        allocator,
        .{
            .seed = seed,
            .tick_ns = ns_per_ms,
            .profile_name = "retry-queue-late-ack-bug",
            .tags = &tags,
            .attributes = &attributes,
        },
        RetryQueue,
        RetryQueue.init,
        buggyScenario,
        &checks,
    );
}

fn scenario(world: *mar.World, queue: *RetryQueue) !void {
    var env = mar.SimulationEnv.init(world);
    try runLateAckScenario(&env, queue, .strict);
}

fn buggyScenario(world: *mar.World, queue: *RetryQueue) !void {
    var env = mar.SimulationEnv.init(world);
    try runLateAckScenario(&env, queue, .buggy_accept_stale_ack);
}

const CompletionMode = enum {
    strict,
    buggy_accept_stale_ack,
};

fn runLateAckScenario(env: *mar.SimulationEnv, queue: *RetryQueue, mode: CompletionMode) !void {
    try queue.makeReady(env, profile.job_id);

    const first_worker: u8 = @intCast(profile.first_worker);
    const second_worker: u8 = @intCast(profile.second_worker);
    const lease_duration_ns = profile.lease_ticks * ns_per_ms;

    _ = try queue.lease(env, first_worker, lease_duration_ns);

    const extra_delay_ticks = 1 + try env.random().intLessThan(u8, 3);
    try env.runFor((profile.lease_ticks + extra_delay_ticks) * ns_per_ms);
    try queue.expireDue(env);

    _ = try queue.lease(env, second_worker, lease_duration_ns);

    switch (mode) {
        .strict => {
            try queue.completeStrict(env, first_worker);
            try queue.completeStrict(env, second_worker);
        },
        .buggy_accept_stale_ack => {
            try queue.completeBuggy(env, first_worker);
            try queue.completeBuggy(env, second_worker);
        },
    }
}

fn jobCompletedAtMostOnce(world: *mar.World, queue: *const RetryQueue) !void {
    if (queue.completion_count > 1) {
        try world.record(
            "queue.invariant_violation job={} completions={}",
            .{ queue.job_id, queue.completion_count },
        );
        return error.JobCompletedTwice;
    }

    try world.record(
        "queue.check completed_at_most_once=ok job={} completions={}",
        .{ queue.job_id, queue.completion_count },
    );
}

const JobState = enum {
    empty,
    ready,
    leased,
    completed,
};

const RetryQueue = struct {
    job_id: u64 = 0,
    state: JobState = .empty,
    lease_owner: u8 = 0,
    lease_deadline_ns: mar.Timestamp = 0,
    completion_count: u8 = 0,

    fn init() RetryQueue {
        return .{};
    }

    fn makeReady(self: *RetryQueue, env: *mar.SimulationEnv, job_id: u64) !void {
        self.* = .{
            .job_id = job_id,
            .state = .ready,
        };
        try env.record("queue.job_ready job={}", .{job_id});
    }

    fn lease(self: *RetryQueue, env: *mar.SimulationEnv, worker: u8, duration_ns: mar.Duration) !bool {
        if (self.state != .ready) {
            try env.record(
                "queue.lease_denied job={} worker={} state={s}",
                .{ self.job_id, worker, @tagName(self.state) },
            );
            return false;
        }

        self.state = .leased;
        self.lease_owner = worker;
        self.lease_deadline_ns = env.clock().now() + duration_ns;
        try env.record(
            "queue.lease job={} worker={} deadline_ns={}",
            .{ self.job_id, worker, self.lease_deadline_ns },
        );
        return true;
    }

    fn expireDue(self: *RetryQueue, env: *mar.SimulationEnv) !void {
        if (self.state != .leased or env.clock().now() < self.lease_deadline_ns) return;

        const previous_owner = self.lease_owner;
        self.state = .ready;
        self.lease_owner = 0;
        self.lease_deadline_ns = 0;
        try env.record(
            "queue.timeout job={} worker={} now_ns={}",
            .{ self.job_id, previous_owner, env.clock().now() },
        );
    }

    fn completeStrict(self: *RetryQueue, env: *mar.SimulationEnv, worker: u8) !void {
        if (self.state == .leased and self.lease_owner == worker) {
            self.state = .completed;
            self.completion_count += 1;
            try env.record(
                "queue.complete job={} worker={} accepted=true reason=current_lease completions={}",
                .{ self.job_id, worker, self.completion_count },
            );
            return;
        }

        try env.record(
            "queue.complete job={} worker={} accepted=false reason=stale_ack completions={}",
            .{ self.job_id, worker, self.completion_count },
        );
    }

    fn completeBuggy(self: *RetryQueue, env: *mar.SimulationEnv, worker: u8) !void {
        if (self.state != .leased) {
            try env.record(
                "queue.complete job={} worker={} accepted=false reason=not_leased completions={}",
                .{ self.job_id, worker, self.completion_count },
            );
            return;
        }

        const owner_matches = self.lease_owner == worker;
        self.completion_count += 1;
        if (owner_matches) self.state = .completed;

        try env.record(
            "queue.complete job={} worker={} accepted=true reason={s} completions={}",
            .{
                self.job_id,
                worker,
                if (owner_matches) "current_lease" else "stale_ack_bug",
                self.completion_count,
            },
        );
    }
};
