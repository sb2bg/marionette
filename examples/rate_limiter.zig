//! Rate limiter service used by Phase 0 determinism tests.

const std = @import("std");
const mar = @import("marionette");

const ns_per_ms: mar.Duration = 1_000_000;

/// Token-bucket limiter with jittered refill scheduling.
pub fn RateLimiter(comptime ClockType: type) type {
    return struct {
        const Self = @This();

        clock: *ClockType,
        random: mar.World.TracedRandom,
        capacity: u32,
        tokens: u32,
        refill_amount: u32,
        refill_interval_ns: mar.Duration,
        next_refill_ns: mar.Timestamp,

        pub const Options = struct { capacity: u32, refill_amount: u32, refill_interval_ns: mar.Duration };

        pub fn init(clock: *ClockType, random: mar.World.TracedRandom, options: Options) Self {
            std.debug.assert(options.capacity > 0);
            std.debug.assert(options.refill_amount > 0);
            std.debug.assert(options.refill_interval_ns > 0);

            return .{
                .clock = clock,
                .random = random,
                .capacity = options.capacity,
                .tokens = options.capacity,
                .refill_amount = options.refill_amount,
                .refill_interval_ns = options.refill_interval_ns,
                .next_refill_ns = clock.now() + options.refill_interval_ns,
            };
        }

        pub fn allow(self: *Self) !bool {
            try self.refillDue();
            if (self.tokens == 0) return false;
            self.tokens -= 1;
            return true;
        }

        fn refillDue(self: *Self) !void {
            const now = self.clock.now();
            while (now >= self.next_refill_ns) {
                self.tokens = @min(self.capacity, self.tokens + self.refill_amount);
                self.next_refill_ns += self.refill_interval_ns + try self.jitter();
            }
        }

        fn jitter(self: *Self) !mar.Duration {
            return self.random.intLessThan(mar.Duration, self.refill_interval_ns / 4 + 1);
        }
    };
}

/// Run a deterministic scenario and return an owned trace.
pub fn runScenario(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var report = try mar.run(allocator, .{ .seed = seed, .tick_ns = ns_per_ms }, scenario);
    defer report.deinit();

    switch (report) {
        .passed => |*passed| return passed.takeTrace(),
        .failed => |failure| {
            failure.print();
            return error.RateLimiterScenarioFailed;
        },
    }
}

fn scenario(world: *mar.World) !void {
    const Limiter = RateLimiter(mar.Clock(.simulation));
    var limiter = Limiter.init(world.clock(), world.tracedRandom(), .{
        .capacity = 3,
        .refill_amount = 2,
        .refill_interval_ns = 5 * ns_per_ms,
    });

    var allowed: u32 = 0;
    for (0..24) |request_index| {
        const ok = try limiter.allow();
        if (ok) allowed += 1;
        try world.record(
            "rate_limiter.request index={} allowed={} tokens={} next_refill_ns={}",
            .{ request_index, ok, limiter.tokens, limiter.next_refill_ns },
        );
        try world.tick();
    }

    try world.record("rate_limiter.summary allowed={}", .{allowed});
}
