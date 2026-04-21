//! Test suite entry point.

const std = @import("std");

pub const determinism = @import("determinism.zig");
pub const fuzz = @import("fuzz.zig");
pub const trace_summary = @import("trace_summary.zig");

test "tests: fixed-seed determinism" {
    try determinism.expectRateLimiterDeterministic(std.testing.allocator);
}

test "tests: many-seed fuzz smoke" {
    try fuzz.expectRateLimiterFuzz(std.testing.allocator);
}

test "tests: replicated register trace summary snapshot" {
    try trace_summary.expectReplicatedRegisterSummary(std.testing.allocator);
}
