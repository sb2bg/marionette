//! Long-running deterministic coverage for representative passing examples.
//!
//! This is intentionally separate from the normal test graph. CI schedules it
//! with thousands of seeds, while local runs can lower `-Dseed-sweep-count`.

const std = @import("std");
const examples = @import("examples");
const mar = @import("marionette");
const options = @import("seed_sweep_options");

const base_seed: u64 = 0x4e49_4748_544c_5900;

test "nightly deterministic seed sweep" {
    if (options.count == 0) return error.SeedSweepCountMustBePositive;

    try sweepRetryQueue();
    try expectSimFuzzScenario("kv-store-recovery", .{
        .allocator = std.testing.allocator,
        .seed = base_seed + 1,
        .seeds = options.count,
        .tick_ns = examples.kv_store.tick_ns,
        .name = "kv-store-recovery",
        .simulate = examples.kv_store.simulateOptions(),
        .init = examples.kv_store.init,
        .scenario = examples.kv_store.scenario,
        .checks = &examples.kv_store.checks,
    });
    try expectSimFuzzScenario("durable-broadcast-network-faults", .{
        .allocator = std.testing.allocator,
        .seed = base_seed + 2,
        .seeds = options.count,
        .tick_ns = examples.durable_broadcast.tick_ns,
        .name = "durable-broadcast-network-faults",
        .simulate = examples.durable_broadcast.simulateOptions(),
        .init = examples.durable_broadcast.init,
        .scenario = examples.durable_broadcast.scenario,
        .checks = &examples.durable_broadcast.checks,
    });
}

fn sweepRetryQueue() !void {
    const scenario = "retry-queue-late-ack";

    for (0..options.count) |iteration| {
        const seed = base_seed +% @as(u64, @intCast(iteration));
        var report = examples.retry_queue.runScenarioReport(
            std.testing.allocator,
            seed,
        ) catch |err| {
            printFailureContext(scenario, seed, iteration, err);
            return err;
        };
        defer report.deinit();

        switch (report) {
            .passed => {},
            .failed => |failure| {
                printFailureContext(scenario, seed, iteration, error.ExpectedRunPass);
                failure.print();
                return error.ExpectedRunPass;
            },
        }
    }
}

fn expectSimFuzzScenario(
    comptime scenario: []const u8,
    config: anytype,
) !void {
    mar.expectSimFuzz(config) catch |err| {
        std.debug.print("seed sweep failed: scenario={s} error={s}\n", .{
            scenario,
            @errorName(err),
        });
        return err;
    };
}

fn printFailureContext(
    scenario: []const u8,
    seed: u64,
    iteration: usize,
    err: anyerror,
) void {
    std.debug.print(
        "seed sweep failed: scenario={s} seed={} iteration={} error={s}\n",
        .{ scenario, seed, iteration, @errorName(err) },
    );
}
