//! Example services used by Marionette tests and documentation.

const std = @import("std");
const mar = @import("marionette");

pub const rate_limiter = @import("rate_limiter.zig");
pub const replicated_register = @import("replicated_register.zig");
pub const buggify_zero_cost = @import("buggify_zero_cost.zig");

test "examples: rate limiter scenario is replayable" {
    const a = try rate_limiter.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(a);
    const b = try rate_limiter.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
}

test "examples: replicated register scenario is replayable" {
    const a = try replicated_register.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(a);
    const b = try replicated_register.runScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(b);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.indexOf(u8, a, "register.write.quorum") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "register.check committed_agreement=ok") != null);
}

test "examples: replicated register checker catches committed divergence" {
    var report = try replicated_register.runBuggyScenario(std.testing.allocator, 0xC0FFEE);
    defer report.deinit();

    switch (report) {
        .passed => return error.ExpectedRunFailure,
        .failed => |failure| {
            try std.testing.expectEqual(mar.RunFailureKind.check_failed, failure.kind);
            try std.testing.expectEqualStrings("committed register is safe", failure.check_name.?);
            try std.testing.expectEqualStrings("CommittedDivergence", failure.error_name.?);
            try std.testing.expect(std.mem.indexOf(u8, failure.first_trace, "register.invariant_violation") != null);
        },
    }
}

test "examples: replicated register rejects same-version conflicts" {
    const trace = try replicated_register.runConflictScenario(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(trace);

    try std.testing.expect(std.mem.indexOf(u8, trace, "value=42 accepted=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "register.write.no_quorum version=1 acks=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "register.check committed_agreement=ok") != null);
}
