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

    var patterns: std.ArrayList(tidy.Pattern) = .empty;
    defer patterns.deinit(allocator);
    try patterns.appendSlice(allocator, &tidy.default_patterns);

    var allowed: std.ArrayList(tidy.Allow) = .empty;
    defer allowed.deinit(allocator);
    try allowed.appendSlice(allocator, &tidy.default_allowed);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ban")) {
            const needle = args.next() orelse return usage(exe_name);
            const reason = args.next() orelse return usage(exe_name);
            try patterns.append(allocator, .{ .needle = needle, .reason = reason });
        } else if (std.mem.eql(u8, arg, "--ban-prefix")) {
            const needle = args.next() orelse return usage(exe_name);
            const reason = args.next() orelse return usage(exe_name);
            try patterns.append(allocator, .{
                .needle = needle,
                .reason = reason,
                .match = .prefix,
            });
        } else if (std.mem.eql(u8, arg, "--allow")) {
            const path = args.next() orelse return usage(exe_name);
            try allowed.append(allocator, .{ .path = path });
        } else if (std.mem.eql(u8, arg, "--allow-pattern")) {
            const path = args.next() orelse return usage(exe_name);
            const needle = args.next() orelse return usage(exe_name);
            try allowed.append(allocator, .{ .path = path, .needle = needle });
        } else if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |path| {
                try paths.append(allocator, path);
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return usage(exe_name);
        } else {
            try paths.append(allocator, arg);
        }
    }

    if (paths.items.len == 0) {
        return usage(exe_name);
    }

    var result = try tidy.scanPaths(allocator, paths.items, .{
        .patterns = patterns.items,
        .allowed = allowed.items,
    });
    defer result.deinit(allocator);

    if (result.violations.items.len > 0) {
        tidy.printViolations(result);
        std.process.exit(1);
    }
}

fn usage(exe_name: []const u8) noreturn {
    std.debug.print(
        \\usage: {s} [options] <path>...
        \\
        \\options:
        \\  --ban <needle> <reason>          ban an exact dotted AST path
        \\  --ban-prefix <needle> <reason>   ban a dotted AST path prefix
        \\  --allow <path>                   allow all bans in a file
        \\  --allow-pattern <path> <needle>  allow one banned needle in a file
        \\
    ,
        .{exe_name},
    );
    std.process.exit(2);
}
