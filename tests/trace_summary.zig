const std = @import("std");
const examples = @import("examples");
const mar = @import("marionette");

test "trace summary reports core replicated-register fields" {
    const allocator = std.testing.allocator;
    const trace = try examples.replicated_register.runScenario(allocator, 0xC0FFEE);
    defer allocator.free(trace);

    var summary = try mar.summarize(allocator, trace);
    defer summary.deinit();

    try std.testing.expectEqual(@as(u64, 39), summary.total_events);
    try std.testing.expectEqualStrings("replicated-register-smoke", summary.name.?);
    try std.testing.expectEqual(@as(u64, 5), summary.network_sends);
    try std.testing.expectEqual(@as(u64, 5), summary.network_deliveries);
    try std.testing.expectEqual(@as(u64, 1), summary.network_drops);
}
