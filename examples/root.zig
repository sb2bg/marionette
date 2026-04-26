//! Example services used by Marionette tests and documentation.

const std = @import("std");
const mar = @import("marionette");

pub const retry_queue = @import("retry_queue.zig");
pub const replicated_register = @import("replicated_register.zig");
pub const kv_store = @import("kv_store.zig");

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
    try std.testing.expect(std.mem.indexOf(u8, a, "run.tag value=scenario:smoke") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "run.attribute key=proposal_drop_percent value=uint:20") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, a, "run.tag value=scenario:partition") != null);
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
    const a = try kv_store.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(a);
    const b = try kv_store.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "run.profile name=kv-store-wal-recovery") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "disk.fault op=2 path=kv.wal kind=crash_lost_write rate=1/1 roll=0 fired=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "disk.read op=4 path=kv.wal offset=16 len=16 status=corrupt") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "kv.check recovery=ok committed_key=1 committed_value=41 recovered_records=1") != null);
}

test "examples: kv store checker catches torn record recovery" {
    var report = try kv_store.runBuggyScenario(std.testing.allocator, 0xC0FFEE);
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
