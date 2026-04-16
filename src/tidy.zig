//! AST-based determinism linter.

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
    const sentinel_source = try allocator.dupeZ(u8, source);
    defer allocator.free(sentinel_source);

    var tree = try std.zig.Ast.parse(allocator, sentinel_source, .zig);
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) return error.ParseError;

    var aliases: std.ArrayList(Alias) = .empty;
    defer aliases.deinit(allocator);
    try collectAliases(allocator, tree, options, &aliases);

    for (0..tree.nodes.len) |node_index| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(node_index);
        if (tree.nodeTag(node) != .field_access) continue;

        for (options.patterns) |pattern| {
            if (!fieldAccessMatches(tree, node, pattern.needle, aliases.items)) continue;
            if (isAllowed(path, pattern.needle)) continue;

            const token = tree.firstToken(node);
            const location = lineColumn(source, tree.tokenStart(token));
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

const max_path_parts = 8;

const PathParts = struct {
    items: [max_path_parts][]const u8 = undefined,
    len: usize = 0,

    fn append(self: *PathParts, part: []const u8) !void {
        if (self.len == self.items.len) return error.TooManyPathParts;
        self.items[self.len] = part;
        self.len += 1;
    }

    fn slice(self: *const PathParts) []const []const u8 {
        return self.items[0..self.len];
    }
};

const Alias = struct {
    name: []const u8,
    parts: PathParts,
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

fn collectAliases(
    allocator: std.mem.Allocator,
    tree: std.zig.Ast,
    options: Options,
    aliases: *std.ArrayList(Alias),
) !void {
    for (0..tree.nodes.len) |node_index| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(node_index);
        const var_decl = tree.fullVarDecl(node) orelse continue;

        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        var init_parts: PathParts = .{};
        collectPathParts(tree, init_node, &init_parts) catch continue;

        for (options.patterns) |pattern| {
            if (!pathPartsAreNeedlePrefix(init_parts.slice(), pattern.needle)) continue;

            const name_token = var_decl.ast.mut_token + 1;
            const name = tree.tokenSlice(name_token);
            try aliases.append(allocator, .{ .name = name, .parts = init_parts });
            break;
        }
    }
}

fn fieldAccessMatches(
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    needle: []const u8,
    aliases: []const Alias,
) bool {
    var parts: PathParts = .{};
    collectPathParts(tree, node, &parts) catch return false;
    return pathPartsMatchNeedle(parts.slice(), needle) or pathPartsMatchAlias(parts, needle, aliases);
}

fn collectPathParts(
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    parts: *PathParts,
) !void {
    switch (tree.nodeTag(node)) {
        .field_access => {
            const lhs, const field_token = tree.nodeData(node).node_and_token;
            try collectPathParts(tree, lhs, parts);
            try parts.append(tree.tokenSlice(field_token));
        },
        .identifier => try parts.append(tree.tokenSlice(tree.nodeMainToken(node))),
        else => return error.UnsupportedPath,
    }
}

fn pathPartsAreNeedlePrefix(parts: []const []const u8, needle: []const u8) bool {
    if (parts.len == 0) return false;
    var index: usize = 0;
    var split = std.mem.splitScalar(u8, needle, '.');
    while (index < parts.len) : (index += 1) {
        const expected = split.next() orelse return false;
        if (!std.mem.eql(u8, expected, parts[index])) return false;
    }
    return true;
}

fn pathPartsMatchNeedle(parts: []const []const u8, needle: []const u8) bool {
    var index: usize = 0;
    var split = std.mem.splitScalar(u8, needle, '.');
    while (split.next()) |expected| : (index += 1) {
        if (index == parts.len) return false;
        if (!std.mem.eql(u8, expected, parts[index])) return false;
    }
    return index == parts.len;
}

fn pathPartsMatchAlias(parts: PathParts, needle: []const u8, aliases: []const Alias) bool {
    const actual = parts.slice();
    if (actual.len == 0) return false;

    for (aliases) |alias| {
        if (!std.mem.eql(u8, alias.name, actual[0])) continue;

        var expanded = alias.parts;
        for (actual[1..]) |part| {
            expanded.append(part) catch return false;
        }
        return pathPartsMatchNeedle(expanded.slice(), needle);
    }
    return false;
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

test "tidy ignores comments and string literals" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/comment.zig",
        \\// std.time.nanoTimestamp()
        \\const text = "std.crypto.random";
        \\
    ,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 0), result.violations.items.len);
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

test "tidy identifies aliases when matching patterns" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/alias.zig",
        \\const time = std.time;
        \\const now = time.nanoTimestamp();
        \\
    ,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqual(@as(usize, 2), result.violations.items[0].line);
    try std.testing.expectEqual(@as(usize, 13), result.violations.items[0].column);
}
