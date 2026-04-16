//! Example services used by Marionette tests and documentation.

const std = @import("std");

pub const rate_limiter = @import("rate_limiter.zig");
pub const buggify_zero_cost = @import("buggify_zero_cost.zig");

test "examples: rate limiter scenario is replayable" {
    const a = try rate_limiter.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(a);
    const b = try rate_limiter.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
}
