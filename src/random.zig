//! Deterministic PRNG wrapper.
//!
//! `std.Random` without an explicit seed is banned in Marionette
//! This module provides the only sanctioned entry point: passing a
//! `u64` seed, and the same seed always produces the same sequence.

const std = @import("std");

/// Seeded, reproducible pseudorandom number generator.
///
/// Wraps `std.Random.DefaultPrng` (currently Xoshiro256++) behind an
/// interface that forces the caller to choose a seed. The wrapper is
/// intentionally thin; later we may grow it for time-travel
/// debugging, but today its only job is to make unseeded randomness
/// impossible by construction.
pub const Random = struct {
    prng: std.Random.DefaultPrng,

    /// Initialize with an explicit seed. The same seed yields the
    /// same stream of values within a single Zig version.
    pub fn init(seed: u64) Random {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    /// Borrow a `std.Random` interface view. Valid only while `self`
    /// lives and is not moved.
    pub fn random(self: *Random) std.Random {
        return self.prng.random();
    }
};

test "random: same seed produces identical u64 sequence" {
    var a: Random = .init(0xCAFE_BABE_DEAD_BEEF);
    var b: Random = .init(0xCAFE_BABE_DEAD_BEEF);
    const ra = a.random();
    const rb = b.random();
    for (0..1024) |_| {
        try std.testing.expectEqual(ra.int(u64), rb.int(u64));
    }
}

test "random: different seeds produce different sequences" {
    var a: Random = .init(1);
    var b: Random = .init(2);
    const ra = a.random();
    const rb = b.random();
    // If seeding were ignored, every draw would match. Odds of 64
    // honest u64 collisions are ~2^-4096, so one mismatch is proof.
    var any_differ = false;
    for (0..64) |_| {
        if (ra.int(u64) != rb.int(u64)) {
            any_differ = true;
            break;
        }
    }
    try std.testing.expect(any_differ);
}

test "random: sequence is stable across method kinds" {
    // Drawing ints of different widths from the same generator must
    // still be a function of the seed alone,  i.e. two generators
    // seeded the same way produce the same mixed-width stream.
    var a: Random = .init(42);
    var b: Random = .init(42);
    const ra = a.random();
    const rb = b.random();
    for (0..256) |i| {
        switch (i % 3) {
            0 => try std.testing.expectEqual(ra.int(u8), rb.int(u8)),
            1 => try std.testing.expectEqual(ra.int(u32), rb.int(u32)),
            2 => try std.testing.expectEqual(ra.boolean(), rb.boolean()),
            else => unreachable,
        }
    }
}
