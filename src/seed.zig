//! Seed parsing helpers.

const std = @import("std");

/// Errors returned when parsing a user-supplied seed.
pub const SeedParseError = error{
    /// The seed is neither a decimal `u64` nor a 40-character Git hash.
    InvalidSeed,
    /// The decimal seed does not fit in `u64`.
    SeedOverflow,
};

/// Parse a decimal `u64` seed or a 40-character Git hash.
///
/// Git hashes are parsed as `u160` hexadecimal values and truncated to the low
/// 64 bits. A 40-character all-decimal string is therefore treated as a Git
/// hash, not as a decimal seed.
pub fn parseSeed(bytes: []const u8) SeedParseError!u64 {
    if (bytes.len == 40) {
        const hash = std.fmt.parseUnsigned(u160, bytes, 16) catch |err| switch (err) {
            error.InvalidCharacter => return error.InvalidSeed,
            error.Overflow => return error.InvalidSeed,
        };
        return @as(u64, @truncate(hash));
    }

    return std.fmt.parseUnsigned(u64, bytes, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidSeed,
        error.Overflow => return error.SeedOverflow,
    };
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
