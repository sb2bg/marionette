//! Fixed-seed replay tests.

const std = @import("std");
const examples = @import("examples");

const iterations = 1000;
const seed = 0xC0FFEE;

pub fn expectRetryQueueDeterministic(allocator: std.mem.Allocator) !void {
    const baseline = try examples.retry_queue.runScenario(allocator, seed);
    defer allocator.free(baseline);

    for (1..iterations) |iteration| {
        const replay = try examples.retry_queue.runScenario(allocator, seed);
        defer allocator.free(replay);

        std.testing.expectEqualStrings(baseline, replay) catch |err| {
            std.debug.print(
                "determinism failure: seed={} iteration={} baseline_len={} replay_len={}\n",
                .{ seed, iteration, baseline.len, replay.len },
            );
            return err;
        };
    }
}
