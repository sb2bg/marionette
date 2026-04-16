//! Test suite entry point.

const std = @import("std");

pub const determinism = @import("determinism.zig");

test "tests: fixed-seed determinism" {
    try determinism.expectRateLimiterDeterministic(std.testing.allocator);
}
