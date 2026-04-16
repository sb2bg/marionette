//! Deterministic simulation state.
//!
//! A `World` owns the Phase 0 simulation state: one fake clock and one
//! seeded PRNG. Later phases will add schedulers, disk, and network here.

const std = @import("std");

const clock_module = @import("clock.zig");
const random_module = @import("random.zig");

/// Container for deterministic simulation state.
///
/// `World` is the entry point for simulation tests. It owns the fake
/// clock and seeded random stream used by services under test. In Phase 0
/// it is deliberately single-node and single-threaded.
pub const World = struct {
    /// Fake clock advanced explicitly by the world.
    sim_clock: clock_module.SimClock,
    /// Seeded pseudorandom number generator for reproducible choices.
    rng: random_module.Random,

    /// Configuration for a simulation world.
    pub const Options = struct {
        /// Seed for the world's random stream.
        seed: u64,
        /// Initial simulated timestamp in nanoseconds.
        start_ns: clock_module.Timestamp = 0,
        /// Nanoseconds advanced by one world tick.
        tick_ns: clock_module.Duration = clock_module.default_tick_ns,
    };

    /// Construct a world with deterministic time and randomness.
    pub fn init(options: Options) World {
        return .{
            .sim_clock = .init(.{
                .start_ns = options.start_ns,
                .tick_ns = options.tick_ns,
            }),
            .rng = .init(options.seed),
        };
    }

    /// Return the world's simulated clock.
    ///
    /// Services that depend on time should receive this pointer instead
    /// of reading `std.time` directly.
    pub fn clock(self: *World) *clock_module.SimClock {
        return &self.sim_clock;
    }

    /// Return a `std.Random` view over the world's seeded PRNG.
    pub fn random(self: *World) std.Random {
        return self.rng.random();
    }

    /// Advance the world by one simulation tick.
    pub fn tick(self: *World) void {
        self.sim_clock.tick();
    }

    /// Advance the world by a duration measured in nanoseconds.
    ///
    /// `duration_ns` must be an exact multiple of the world's tick size.
    pub fn runFor(self: *World, duration_ns: clock_module.Duration) void {
        self.sim_clock.runFor(duration_ns);
    }

    /// Return the world's current simulated timestamp in nanoseconds.
    pub fn now(self: *const World) clock_module.Timestamp {
        return self.sim_clock.now();
    }
};

test "world: owns seeded random and simulated clock" {
    var a: World = .init(.{ .seed = 1234, .tick_ns = 10 });
    var b: World = .init(.{ .seed = 1234, .tick_ns = 10 });

    a.tick();
    b.tick();

    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), a.now());
    try std.testing.expectEqual(a.now(), b.now());

    const random_a = a.random();
    const random_b = b.random();
    for (0..128) |_| {
        try std.testing.expectEqual(random_a.int(u64), random_b.int(u64));
    }
}

test "world: runFor advances whole simulated ticks" {
    var world: World = .init(.{ .seed = 0, .tick_ns = 3 });

    world.runFor(12);

    try std.testing.expectEqual(@as(clock_module.Timestamp, 12), world.now());
}
