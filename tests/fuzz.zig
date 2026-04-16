//! Many-seed smoke tests.

const std = @import("std");
const examples = @import("examples");

const iterations = 1000;

pub fn expectRateLimiterFuzz(allocator: std.mem.Allocator) !void {
    for (0..iterations) |iteration| {
        const seed = seedForIteration(iteration);
        const trace = examples.rate_limiter.runScenario(allocator, seed) catch |err| {
            std.debug.print("fuzz failure: seed={} iteration={}\n", .{ seed, iteration });
            return err;
        };
        defer allocator.free(trace);

        std.testing.expect(trace.len > 0) catch |err| {
            std.debug.print("fuzz failure: seed={} iteration={}\n", .{ seed, iteration });
            return err;
        };
    }
}

fn seedForIteration(iteration: usize) u64 {
    return 0x9E37_79B9_7F4A_7C15 ^ @as(u64, @intCast(iteration));
}
