//! Regression coverage for defects fixed in 0.8.1.
const std = @import("std");
const mar = @import("marionette");

/// Reads that hit a read-error fault, then a failure that does not depend on
/// them. The faults are noise that reduction should be able to remove.
const NoisyReads = struct {
    fn init(_: mar.Sim) @This() {
        return .{};
    }
    fn scenario(case: *mar.SimCase(@This())) !void {
        const disk = case.env().disk;
        try disk.write(.{ .path = "data", .offset = 0, .bytes = "abcd" });
        try case.control().disk.setFaults(.{ .read_error_rate = .oneIn(2) });
        var buffer: [4]u8 = undefined;
        for (0..8) |_| disk.read(.{ .path = "data", .offset = 0, .buffer = &buffer }) catch {};
        return error.PlantedFailure;
    }
};

test "reduction removes fault rolls instead of injecting them" {
    var reduced = try mar.reduceSimCase(.{
        .allocator = std.testing.allocator,
        .seed = 0x081,
        .simulate = mar.World.SimulateOptions{ .disk = .{ .sector_size = 4 } },
        .init = NoisyReads.init,
        .scenario = NoisyReads.scenario,
    }, .{});
    defer reduced.deinit();

    const original = try mar.faultCoverage(reduced.original.failed.first_trace);
    try std.testing.expect(original.disk_read_errors > 0);
    const minimized = try mar.faultCoverage(reduced.report().failed.first_trace);
    try std.testing.expectEqual(@as(u64, 0), minimized.disk_read_errors);
    try std.testing.expectEqualStrings("PlantedFailure", reduced.report().failed.error_name.?);
}

test "a zero fault roll never fires" {
    for ([_]mar.BuggifyRate{ .oneIn(2), .oneIn(1000), .percent(99), .always() }) |rate| {
        try std.testing.expect(!rate.fires(0) or rate.numerator == rate.denominator);
        try std.testing.expect(rate.fires(rate.denominator - 1));
    }
    try std.testing.expect(!mar.BuggifyRate.never().fires(0));
}
