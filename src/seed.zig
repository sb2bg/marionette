//! Seed parsing and deterministic seed-schedule state.

const std = @import("std");

const clock_module = @import("clock.zig");

/// Errors returned when parsing a user-supplied seed.
pub const SeedParseError = error{
    /// The seed is neither a decimal `u64` nor a 40-character Git hash.
    InvalidSeed,
    /// The decimal seed does not fit in `u64`.
    SeedOverflow,
};

/// Errors returned when validating a seed schedule.
pub const SeedScheduleError = error{
    /// Cutovers are not strictly ordered by `(sim_time_ns, microstep)`.
    InvalidSeedSchedule,
};

/// One superdense logical point in the deterministic choice stream.
///
/// `microstep` is the zero-based traced-random draw index at `sim_time_ns`.
/// Points are ordered lexicographically, so `(t, 0)` means "before the first
/// traced draw at or after time `t`".
pub const DecisionPoint = struct {
    sim_time_ns: clock_module.Timestamp,
    microstep: u64 = 0,

    pub fn isBefore(lhs: DecisionPoint, rhs: DecisionPoint) bool {
        return lhs.sim_time_ns < rhs.sim_time_ns or
            (lhs.sim_time_ns == rhs.sim_time_ns and lhs.microstep < rhs.microstep);
    }

    pub fn isAtOrBefore(lhs: DecisionPoint, rhs: DecisionPoint) bool {
        return lhs.sim_time_ns < rhs.sim_time_ns or
            (lhs.sim_time_ns == rhs.sim_time_ns and lhs.microstep <= rhs.microstep);
    }
};

/// Switch the world's random stream to `seed` at one logical point.
pub const SeedCutover = struct {
    at: DecisionPoint,
    seed: u64,
};

/// Strictly ordered seed cutovers for one run.
pub const SeedSchedule = []const SeedCutover;

/// Validate that every cutover has one unambiguous predecessor.
pub fn validateSeedSchedule(schedule: SeedSchedule) SeedScheduleError!void {
    if (schedule.len < 2) return;
    for (schedule[1..], 1..) |cutover, index| {
        if (!schedule[index - 1].at.isBefore(cutover.at)) {
            return error.InvalidSeedSchedule;
        }
    }
}

/// Copyable world-owned state for one scheduled pseudorandom stream.
///
/// Keeping the PRNG, cutover cursor, and logical point together makes a plain
/// value copy a complete rollback checkpoint.
pub const RandomState = struct {
    rng: std.Random.DefaultPrng,
    schedule: SeedSchedule,
    next_cutover: usize = 0,
    point: DecisionPoint,

    pub fn init(
        initial_seed: u64,
        schedule: SeedSchedule,
        start_ns: clock_module.Timestamp,
    ) SeedScheduleError!RandomState {
        try validateSeedSchedule(schedule);
        return .{
            .rng = .init(initial_seed),
            .schedule = schedule,
            .point = .{ .sim_time_ns = start_ns },
        };
    }

    /// Move to a new simulated timestamp, resetting its random microstep.
    pub fn syncTime(self: *RandomState, now_ns: clock_module.Timestamp) void {
        if (self.point.sim_time_ns == now_ns) return;
        self.point = .{ .sim_time_ns = now_ns };
    }

    /// Return the next cutover that must fire before the current draw.
    pub fn nextDueCutover(self: *const RandomState) ?SeedCutover {
        if (self.next_cutover >= self.schedule.len) return null;
        const cutover = self.schedule[self.next_cutover];
        return if (cutover.at.isAtOrBefore(self.point)) cutover else null;
    }

    /// Apply the due cutover and return it for trace recording.
    pub fn applyNextCutover(self: *RandomState) SeedCutover {
        const cutover = self.schedule[self.next_cutover];
        std.debug.assert(cutover.at.isAtOrBefore(self.point));
        self.next_cutover += 1;
        self.rng = .init(cutover.seed);
        return cutover;
    }

    pub fn random(self: *RandomState) std.Random {
        return self.rng.random();
    }

    /// Commit one successfully traced random draw.
    pub fn finishDraw(self: *RandomState) void {
        self.point.microstep = std.math.add(u64, self.point.microstep, 1) catch
            @panic("random decision microstep overflow");
    }
};

/// Parse a decimal `u64` seed or a 40-character Git hash.
///
/// Git hashes are parsed as `u160` hexadecimal values and truncated to the low
/// 64 bits. A 40-character all-decimal string is therefore treated as a Git
/// hash, not as a decimal seed.
pub fn parseSeed(bytes: []const u8) SeedParseError!u64 {
    if (bytes.len == 40) {
        const hash = std.fmt.parseUnsigned(u160, bytes, 16) catch
            return error.InvalidSeed;
        return @truncate(hash);
    }

    return std.fmt.parseUnsigned(u64, bytes, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidSeed,
        error.Overflow => return error.SeedOverflow,
    };
}

test "decision points are lexicographically ordered" {
    const first = DecisionPoint{ .sim_time_ns = 10 };
    const second = DecisionPoint{ .sim_time_ns = 10, .microstep = 1 };
    const later = DecisionPoint{ .sim_time_ns = 11 };

    try std.testing.expect(first.isBefore(second));
    try std.testing.expect(second.isBefore(later));
    try std.testing.expect(first.isAtOrBefore(first));
    try std.testing.expect(!later.isAtOrBefore(second));
}

test "seed schedules require strictly increasing cutovers" {
    try validateSeedSchedule(&.{});
    try validateSeedSchedule(&.{
        .{ .at = .{ .sim_time_ns = 10 }, .seed = 1 },
        .{ .at = .{ .sim_time_ns = 10, .microstep = 1 }, .seed = 2 },
        .{ .at = .{ .sim_time_ns = 20 }, .seed = 3 },
    });

    try std.testing.expectError(error.InvalidSeedSchedule, validateSeedSchedule(&.{
        .{ .at = .{ .sim_time_ns = 10 }, .seed = 1 },
        .{ .at = .{ .sim_time_ns = 10 }, .seed = 2 },
    }));
    try std.testing.expectError(error.InvalidSeedSchedule, validateSeedSchedule(&.{
        .{ .at = .{ .sim_time_ns = 20 }, .seed = 1 },
        .{ .at = .{ .sim_time_ns = 10 }, .seed = 2 },
    }));
}

test "random state applies cutovers at superdense points" {
    var state = try RandomState.init(0, &.{
        .{ .at = .{ .sim_time_ns = 10 }, .seed = 1 },
        .{ .at = .{ .sim_time_ns = 10, .microstep = 2 }, .seed = 2 },
    }, 0);

    state.syncTime(9);
    try std.testing.expect(state.nextDueCutover() == null);

    state.syncTime(10);
    try std.testing.expectEqual(@as(u64, 1), state.applyNextCutover().seed);
    state.finishDraw();
    try std.testing.expect(state.nextDueCutover() == null);
    state.finishDraw();
    try std.testing.expectEqual(@as(u64, 2), state.applyNextCutover().seed);
}

test "parseSeed: decimal seeds" {
    try std.testing.expectEqual(@as(u64, 0), try parseSeed("0"));
    try std.testing.expectEqual(@as(u64, 42), try parseSeed("42"));
    try std.testing.expectEqual(std.math.maxInt(u64), try parseSeed("18446744073709551615"));
}

test "parseSeed: rejects invalid and overflowing decimal seeds" {
    try std.testing.expectError(SeedParseError.InvalidSeed, parseSeed(""));
    try std.testing.expectError(SeedParseError.InvalidSeed, parseSeed("0x2a"));
    try std.testing.expectError(SeedParseError.InvalidSeed, parseSeed("not-a-seed"));
    try std.testing.expectError(SeedParseError.SeedOverflow, parseSeed("18446744073709551616"));
}

test "parseSeed: git hashes truncate to low 64 bits" {
    try std.testing.expectEqual(
        @as(u64, 42),
        try parseSeed("000000000000000000000000000000000000002a"),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try parseSeed("ffffffffffffffffffffffffffffffffffffffff"),
    );
}

test "parseSeed: rejects invalid git hashes" {
    try std.testing.expectError(
        SeedParseError.InvalidSeed,
        parseSeed("00000000000000000000000000000000000000xz"),
    );
}
