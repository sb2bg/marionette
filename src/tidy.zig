//! Substring-based determinism linter.

const std = @import("std");

const max_file_size = 10 * 1024 * 1024;

pub const Pattern = struct {
    needle: []const u8,
    reason: []const u8,
};

pub const Violation = struct {
    path: []const u8,
    line: usize,
    column: usize,
    pattern: Pattern,
};

pub const ScanResult = struct {
    violations: std.ArrayList(Violation) = .empty,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        for (self.violations.items) |violation| {
            allocator.free(violation.path);
        }
        self.violations.deinit(allocator);
        self.* = undefined;
    }
};

pub const default_patterns = [_]Pattern{
    .{ .needle = "std.time.nanoTimestamp", .reason = "use ProductionClock or World.clock()" },
    .{ .needle = "std.time.milliTimestamp", .reason = "use ProductionClock or World.clock()" },
    .{ .needle = "std.Thread.spawn", .reason = "simulated components must be single-threaded" },
    .{ .needle = "std.crypto.random", .reason = "use seeded Marionette randomness" },
};

pub const Options = struct {
    patterns: []const Pattern = &default_patterns,
};

pub fn scanPaths(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    options: Options,
) !ScanResult {
    var result: ScanResult = .{};
    errdefer result.deinit(allocator);

    for (paths) |path| {
        try scanPath(allocator, &result, path, options);
    }

    return result;
}

pub fn scanSourceForPath(
    allocator: std.mem.Allocator,
    result: *ScanResult,
    path: []const u8,
    source: []const u8,
    options: Options,
) !void {
    for (options.patterns) |pattern| {
        var offset: usize = 0;
        while (std.mem.indexOfPos(u8, source, offset, pattern.needle)) |index| {
            offset = index + pattern.needle.len;
            if (isAllowed(path, pattern.needle)) continue;

            const location = lineColumn(source, index);
            try result.violations.append(allocator, .{
                .path = try allocator.dupe(u8, normalizePath(path)),
                .line = location.line,
                .column = location.column,
                .pattern = pattern,
            });
        }
    }
}

pub fn printViolations(result: ScanResult) void {
    for (result.violations.items) |violation| {
        std.debug.print(
            "{s}:{}:{}: banned pattern `{s}`: {s}\n",
            .{
                violation.path,
                violation.line,
                violation.column,
                violation.pattern.needle,
                violation.pattern.reason,
            },
        );
    }
}

fn scanPath(
    allocator: std.mem.Allocator,
    result: *ScanResult,
    path: []const u8,
    options: Options,
) !void {
    if (std.mem.endsWith(u8, path, ".zig")) {
        return scanFile(allocator, result, path, options);
    }

    const io = std.Options.debug_io;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const joined = try std.fs.path.join(allocator, &.{ path, entry.path });
        defer allocator.free(joined);
        try scanFile(allocator, result, joined, options);
    }
}

fn scanFile(
    allocator: std.mem.Allocator,
    result: *ScanResult,
    path: []const u8,
    options: Options,
) !void {
    const io = std.Options.debug_io;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(source);

    try scanSourceForPath(allocator, result, path, source, options);
}

const Location = struct {
    line: usize,
    column: usize,
};

fn lineColumn(source: []const u8, index: usize) Location {
    var location: Location = .{ .line = 1, .column = 1 };
    for (source[0..index]) |byte| {
        if (byte == '\n') {
            location.line += 1;
            location.column = 1;
        } else {
            location.column += 1;
        }
    }
    return location;
}

fn isAllowed(path: []const u8, needle: []const u8) bool {
    _ = needle;
    const normalized = normalizePath(path);
    return std.mem.eql(u8, normalized, "src/clock.zig") or
        std.mem.eql(u8, normalized, "src/tidy.zig");
}

fn normalizePath(path: []const u8) []const u8 {
    var normalized = path;
    while (std.mem.startsWith(u8, normalized, "./")) {
        normalized = normalized[2..];
    }
    return normalized;
}

test "tidy flags banned patterns" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/bad.zig",
        "const now = std.time.nanoTimestamp();\n",
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.violations.items[0].line);
    try std.testing.expectEqual(@as(usize, 13), result.violations.items[0].column);
}

test "tidy allows wrapper files to mention banned patterns" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "./src/clock.zig",
        "const now = std.time.nanoTimestamp();\n",
        .{},
    );

    try std.testing.expectEqual(@as(usize, 0), result.violations.items.len);
}
