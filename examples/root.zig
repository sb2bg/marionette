//! Example services used by Marionette tests and documentation.

const std = @import("std");
const mar = @import("marionette");

pub const retry_queue = @import("retry_queue.zig");
pub const replicated_register = @import("replicated_register.zig");
pub const kv_store = @import("kv_store.zig");
pub const idempotency_bug = @import("idempotency_bug.zig");

test "examples: retry queue scenario is replayable" {
    const a = try retry_queue.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(a);
    const b = try retry_queue.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "run.profile name=retry-queue-late-ack") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "queue.complete job=7 worker=1 accepted=false reason=stale_ack") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "queue.check completed_at_most_once=ok job=7 completions=1") != null);
}

test "examples: retry queue checker catches duplicate completion" {
    var report = try retry_queue.runBuggyScenario(std.testing.allocator, 0xC0FFEE);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(mar.RunFailureKind.check_failed, failure.kind);
            try std.testing.expectEqualStrings("job completed at most once", failure.check_name.?);
            try std.testing.expectEqualStrings("JobCompletedTwice", failure.error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "queue.complete job=7 worker=1 accepted=true reason=stale_ack_bug completions=1") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "queue.complete job=7 worker=2 accepted=true reason=current_lease completions=2") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "queue.invariant_violation job=7 completions=2") != null);
        },
    }
}

test "examples: replicated register scenario is replayable" {
    const a = try replicated_register.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(a);
    const b = try replicated_register.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "run.profile name=replicated-register-smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "network.faults drop_rate=20/100") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "register.write.quorum") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "register.check committed_agreement=ok") != null);
}

test "examples: replicated register checker catches committed divergence" {
    var report = try replicated_register.runBuggyScenario(std.testing.allocator, 0xC0FFEE);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(mar.RunFailureKind.check_failed, failure.kind);
            try std.testing.expectEqualStrings("committed register is safe", failure.check_name.?);
            try std.testing.expectEqualStrings("CommittedDivergence", failure.error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "register.invariant_violation") != null);
        },
    }
}

test "examples: replicated register partition scenario is replayable" {
    const a = try replicated_register.runPartitionScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(a);
    const b = try replicated_register.runPartitionScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "run.profile name=replicated-register-partition") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "network.partition left_count=1 right_count=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "reason=link_disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "network.heal disabled_count=6 down_count=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "replica.commit replica=0 version=1 value=41 committed=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "register.check replica_committed=ok replica=0 version=1 value=41") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "register.check committed_quorum=ok") != null);
}

test "examples: replicated register rejects same-version conflicts" {
    const trace = try replicated_register.runConflictScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(trace);

    try std.testing.expect(std.mem.indexOf(u8, trace, "value=42 accepted=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "register.write.no_quorum version=1 acks=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "register.check committed_agreement=ok") != null);
}

test "examples: kv store recovery scenario is replayable" {
    const a = try runKvStoreTrace(std.testing.allocator, 0xC0FFEE, kv_store.scenario);
    defer std.testing.allocator.free(a);
    const b = try runKvStoreTrace(std.testing.allocator, 0xC0FFEE, kv_store.scenario);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "disk.fault op=2 path=kv.wal kind=crash_lost_write rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "disk.read op=4 path=kv.wal offset=16 len=16 status=corrupt") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "kv.check recovery=ok committed_key=1 committed_value=41 recovered_records=1") != null);
}

test "examples: kv store checker catches torn record recovery" {
    var report = try runKvStoreReport(std.testing.allocator, 0xC0FFEE, kv_store.buggyScenario);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(mar.RunFailureKind.check_failed, failure.kind);
            try std.testing.expectEqualStrings("synced records recover and unsynced records are rejected", failure.check_name.?);
            try std.testing.expectEqualStrings("UnsyncedRecordRecovered", failure.error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "disk.crash_write op=2 path=kv.wal offset=16 len=16 result=torn") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "kv.recover.record offset=16 key=2 value=0 mode=buggy_accept_magic_only") != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "kv.invariant_violation reason=unsynced_record_recovered") != null);
        },
    }
}

test "examples: idempotency bug is seed-sensitive" {
    try mar.expectPass(.{
        .allocator = std.testing.allocator,
        .seed = idempotency_bug.passing_seed,
        .init = idempotency_bug.Harness.init,
        .scenario = idempotency_bug.scenario,
        .checks = &idempotency_bug.checks,
    });

    try mar.expectFailure(.{
        .allocator = std.testing.allocator,
        .seed = idempotency_bug.failing_seed,
        .init = idempotency_bug.Harness.init,
        .scenario = idempotency_bug.scenario,
        .checks = &idempotency_bug.checks,
    });
}

test "examples: idempotency bug failing seed is replayable" {
    var a = try idempotency_bug.runReport(std.testing.allocator, idempotency_bug.failing_seed);
    defer a.deinit();
    var b = try idempotency_bug.runReport(std.testing.allocator, idempotency_bug.failing_seed);
    defer b.deinit();

    const a_trace = switch (a) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| failure.first_trace,
    };
    const b_trace = switch (b) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| failure.first_trace,
    };

    try std.testing.expectEqualStrings(a_trace, b_trace);
    try std.testing.expect(std.mem.indexOf(u8, a_trace, "idempotency.deposit account=bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, a_trace, "reason=global_duplicate") != null);
    try std.testing.expect(std.mem.indexOf(u8, a_trace, "idempotency.invariant_violation") != null);
}

test "examples: idempotency seed search finds the bug" {
    var found_failure = false;

    for (0..32) |seed| {
        var report = try idempotency_bug.runReport(std.testing.allocator, seed);
        defer report.deinit();

        switch (report) {
            .passed => {},
            .failed => |failure| {
                try std.testing.expectEqual(mar.RunFailureKind.check_failed, failure.kind);
                try std.testing.expectEqualStrings("AccountDepositLost", failure.error_name.?);
                found_failure = true;
                break;
            },
        }
    }

    try std.testing.expect(found_failure);
}

fn runKvStoreTrace(
    allocator: std.mem.Allocator,
    seed: u64,
    comptime scenario_fn: fn (*kv_store.Harness) anyerror!void,
) ![]u8 {
    var report = try runKvStoreReport(allocator, seed, scenario_fn);
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.UnexpectedRunFailure;
        },
    }
}

fn runKvStoreReport(
    allocator: std.mem.Allocator,
    seed: u64,
    comptime scenario_fn: fn (*kv_store.Harness) anyerror!void,
) !mar.RunReport {
    return mar.runCase(.{
        .allocator = allocator,
        .seed = seed,
        .tick_ns = kv_store.tick_ns,
        .init = kv_store.Harness.init,
        .scenario = scenario_fn,
        .checks = &kv_store.checks,
    });
}
