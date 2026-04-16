//! CLI entry point for `marionette-tidy`.

const std = @import("std");
const tidy = @import("tidy.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    const exe_name = args.next() orelse "marionette-tidy";

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    while (args.next()) |arg| {
        try paths.append(allocator, arg);
    }

    if (paths.items.len == 0) {
        std.debug.print("usage: {s} <path>...\n", .{exe_name});
        std.process.exit(2);
    }

    var result = try tidy.scanPaths(allocator, paths.items, .{});
    defer result.deinit(allocator);

    if (result.violations.items.len > 0) {
        tidy.printViolations(result);
        std.process.exit(1);
    }
}
