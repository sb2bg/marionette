//! AST-based determinism linter.

const std = @import("std");

const max_file_size = 10 * 1024 * 1024;

pub const Pattern = struct {
    pub const Match = enum {
        exact,
        prefix,
    };

    needle: []const u8,
    reason: []const u8,
    match: Match = .exact,
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

pub const Allow = struct {
    path: []const u8,
    needle: ?[]const u8 = null,
};

// Keep this growing toward a small rules engine, not a pile of one-off string
// checks. Tidy should encode Marionette's determinism contract as project law:
// named bans, clear replacements, narrow allowlist entries, and tests for each
// rule shape. Marionette should stay focused on deterministic-simulation hazards first.
pub const default_patterns = [_]Pattern{
    .{ .needle = "std.Thread", .reason = "use Marionette cooperative tasks; do not use host threads in simulated code", .match = .prefix },
    .{ .needle = "std.posix", .reason = "route host access through Marionette authorities or caller-provided std.Io", .match = .prefix },
    .{ .needle = "std.os", .reason = "route host access through Marionette authorities or caller-provided std.Io", .match = .prefix },
    .{ .needle = "std.Io.Threaded", .reason = "use Env.io(); do not construct a second host I/O authority", .match = .prefix },
    .{ .needle = "std.Io.Evented", .reason = "use Env.io(); do not construct a second host I/O authority", .match = .prefix },
    .{ .needle = "std.Io.Dispatch", .reason = "use Env.io(); do not construct a second host I/O authority", .match = .prefix },
    .{ .needle = "std.Io.Kqueue", .reason = "use Env.io(); do not construct a second host I/O authority", .match = .prefix },
    .{ .needle = "std.Io.Uring", .reason = "use Env.io(); do not construct a second host I/O authority", .match = .prefix },
    .{ .needle = "std.process.getUserInfo", .reason = "receive host user state from the composition root" },
    .{ .needle = "std.process.getBaseAddress", .reason = "host address state is nondeterministic" },
    .{ .needle = "std.process.totalSystemMemory", .reason = "receive host resource state from the composition root" },
    .{ .needle = "std.process.cleanExit", .reason = "process termination belongs at the composition root" },
    .{ .needle = "std.process.raiseFileDescriptorLimit", .reason = "host process mutation belongs at the composition root" },
    .{ .needle = "std.process.fatal", .reason = "process termination belongs at the composition root" },
    .{ .needle = "std.process.abort", .reason = "process termination belongs at the composition root" },
    .{ .needle = "std.process.exit", .reason = "process termination belongs at the composition root" },
    .{ .needle = "std.process.lockMemory", .reason = "host process mutation belongs at the composition root" },
    .{ .needle = "std.process.unlockMemory", .reason = "host process mutation belongs at the composition root" },
    .{ .needle = "std.process.lockMemoryAll", .reason = "host process mutation belongs at the composition root" },
    .{ .needle = "std.process.unlockMemoryAll", .reason = "host process mutation belongs at the composition root" },
    .{ .needle = "std.process.protectMemory", .reason = "host process mutation belongs at the composition root" },
    .{ .needle = "std.heap.page_allocator", .reason = "pass an allocator explicitly" },
    .{ .needle = "std.heap.smp_allocator", .reason = "pass an allocator explicitly" },
    .{ .needle = "std.heap.c_allocator", .reason = "pass an allocator explicitly" },
    .{ .needle = "std.heap.wasm_allocator", .reason = "pass an allocator explicitly" },
    .{ .needle = "std.heap.brk_allocator", .reason = "pass an allocator explicitly" },
    .{ .needle = "std.Options.debug_io", .reason = "use the std.Io provided by the composition root" },
    .{ .needle = "std.debug.print", .reason = "record through Env or write through an injected std.Io stream" },
    .{ .needle = "std.log", .reason = "configure logging with an injected deterministic sink", .match = .prefix },
};

pub const default_allowed = [_]Allow{
    .{ .path = "src/tidy.zig" },
    // Fiber stacks come from mmap so a guard page can sit below them; a
    // documented exception to allocator discipline.
    .{ .path = "src/fiber.zig", .needle = "std.posix" },
    .{ .path = "src/fiber_guard_diagnostics.zig", .needle = "std.posix" },
    // Composition roots and reporting harnesses own exit status and stderr.
    .{ .path = "src/main_run.zig", .needle = "std.process.exit" },
    .{ .path = "src/main_run.zig", .needle = "std.debug.print" },
    .{ .path = "src/main_tidy.zig", .needle = "std.process.exit" },
    .{ .path = "src/main_tidy.zig", .needle = "std.debug.print" },
    .{ .path = "src/run.zig", .needle = "std.debug.print" },
    .{ .path = "tests/determinism.zig", .needle = "std.debug.print" },
    .{ .path = "tests/fiber_overflow_check.zig", .needle = "std.debug.print" },
    .{ .path = "tests/fuzz.zig", .needle = "std.debug.print" },
    .{ .path = "tests/switch_inline_bench.zig", .needle = "std.debug.print" },
    .{ .path = "validation/dusty_http.zig", .needle = "std.debug.print" },
    .{ .path = "validation/nightly_seed_sweep.zig", .needle = "std.debug.print" },
    .{ .path = "validation/xitdb_durability.zig", .needle = "std.debug.print" },
};

pub const Options = struct {
    patterns: []const Pattern = &default_patterns,
    allowed: []const Allow = &default_allowed,
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
            if (!fieldAccessMatches(tree, node, pattern, aliases.items)) continue;
            if (isAllowed(path, pattern, options.allowed)) continue;

            const token = tree.firstToken(node);
            const location = lineColumn(source, tree.tokenStart(token));
            if (hasViolation(result.*, path, location, pattern)) continue;
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
    pattern: Pattern,
    aliases: []const Alias,
) bool {
    var parts: PathParts = .{};
    collectPathParts(tree, node, &parts) catch return false;
    return pathPartsMatchPattern(parts.slice(), pattern) or pathPartsMatchAlias(parts, pattern, aliases);
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

fn pathPartsMatchPattern(parts: []const []const u8, pattern: Pattern) bool {
    return switch (pattern.match) {
        .exact => pathPartsMatchNeedle(parts, pattern.needle),
        .prefix => pathPartsHaveNeedlePrefix(parts, pattern.needle),
    };
}

fn pathPartsHaveNeedlePrefix(parts: []const []const u8, needle: []const u8) bool {
    var index: usize = 0;
    var split = std.mem.splitScalar(u8, needle, '.');
    while (split.next()) |expected| : (index += 1) {
        if (index == parts.len) return false;
        if (!std.mem.eql(u8, expected, parts[index])) return false;
    }
    return true;
}

fn pathPartsMatchAlias(parts: PathParts, pattern: Pattern, aliases: []const Alias) bool {
    const actual = parts.slice();
    if (actual.len == 0) return false;

    for (aliases) |alias| {
        if (!std.mem.eql(u8, alias.name, actual[0])) continue;

        var expanded = alias.parts;
        for (actual[1..]) |part| {
            expanded.append(part) catch return false;
        }
        return pathPartsMatchPattern(expanded.slice(), pattern);
    }
    return false;
}

fn isAllowed(path: []const u8, pattern: Pattern, allowed: []const Allow) bool {
    const normalized = normalizePath(path);
    for (allowed) |allow| {
        if (!std.mem.eql(u8, normalized, normalizePath(allow.path))) continue;
        const allowed_needle = allow.needle orelse return true;
        if (std.mem.eql(u8, allowed_needle, pattern.needle)) return true;
    }
    return false;
}

fn normalizePath(path: []const u8) []const u8 {
    var normalized = path;
    while (std.mem.startsWith(u8, normalized, "./")) {
        normalized = normalized[2..];
    }
    return normalized;
}

fn hasViolation(result: ScanResult, path: []const u8, location: Location, pattern: Pattern) bool {
    const normalized = normalizePath(path);
    for (result.violations.items) |violation| {
        if (violation.line != location.line) continue;
        if (violation.column != location.column) continue;
        if (!std.mem.eql(u8, violation.path, normalized)) continue;
        if (!std.mem.eql(u8, violation.pattern.needle, pattern.needle)) continue;
        return true;
    }
    return false;
}

test "tidy flags banned patterns" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/bad.zig",
        "const host = std.os;\n",
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.violations.items[0].line);
    try std.testing.expectEqualStrings("std.os", result.violations.items[0].pattern.needle);
}

test "tidy flags prefix patterns" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/bad.zig",
        "fn bad() void { std.posix.getpid(); }\n",
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqualStrings("std.posix", result.violations.items[0].pattern.needle);
}

test "tidy flags host threads" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/bad_thread.zig",
        \\fn worker() void {}
        \\fn bad() !void {
        \\    _ = try std.Thread.spawn(.{}, worker, .{});
        \\}
        \\
    ,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqualStrings("std.Thread", result.violations.items[0].pattern.needle);
}

test "tidy flags construction of another host io backend" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/bad_io.zig",
        "const host = std.Io.Threaded.global_single_threaded;\n",
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqualStrings("std.Io.Threaded", result.violations.items[0].pattern.needle);
}

test "tidy ignores comments and string literals" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/comment.zig",
        \\// std.os.linux.getpid()
        \\const text = "std.debug.print";
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
        "./src/host_clock.zig",
        "const pid = std.os.linux.getpid();\n",
        .{ .allowed = &.{.{ .path = "src/host_clock.zig" }} },
    );

    try std.testing.expectEqual(@as(usize, 0), result.violations.items.len);
}

test "tidy allows specific patterns without exempting the whole file" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/custom_host.zig",
        \\const pid = std.os.linux.getpid();
        \\const debug_io = std.Options.debug_io;
        \\
    ,
        .{ .allowed = &.{.{ .path = "src/custom_host.zig", .needle = "std.os" }} },
    );

    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqualStrings("std.Options.debug_io", result.violations.items[0].pattern.needle);
}

test "tidy identifies aliases when matching patterns" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/alias.zig",
        \\const os = std.os;
        \\const pid = os.linux.getpid();
        \\
    ,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 2), result.violations.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.violations.items[0].line);
    try std.testing.expectEqual(@as(usize, 12), result.violations.items[0].column);
    try std.testing.expectEqual(@as(usize, 2), result.violations.items[1].line);
    try std.testing.expectEqual(@as(usize, 13), result.violations.items[1].column);
}

test "tidy identifies aliases to host threads" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/thread_alias.zig",
        \\const Thread = std.Thread;
        \\fn worker() void {}
        \\fn bad() !void {
        \\    _ = try Thread.spawn(.{}, worker, .{});
        \\}
        \\
    ,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 2), result.violations.items.len);
    try std.testing.expectEqualStrings("std.Thread", result.violations.items[0].pattern.needle);
    try std.testing.expectEqualStrings("std.Thread", result.violations.items[1].pattern.needle);
}

test "tidy allows time constants and caller-provided io clocks and randomness" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/capabilities.zig",
        \\const second = std.time.ns_per_s;
        \\fn work(io: std.Io) void {
        \\    _ = std.Io.Dir.cwd();
        \\    _ = std.Io.File.stdout();
        \\    _ = std.Io.Clock.awake.now(io);
        \\    var source: std.Random.IoSource = .{ .io = io };
        \\    _ = source.interface().int(u64);
        \\}
        \\
    ,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 0), result.violations.items.len);
}

test "tidy allows io-backed process operations but flags ambient host queries" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/process.zig",
        \\fn work(io: std.Io, buffer: []u8) !void {
        \\    _ = try std.process.currentPath(io, buffer);
        \\    _ = try std.process.totalSystemMemory();
        \\}
        \\
    ,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqualStrings("std.process.totalSystemMemory", result.violations.items[0].pattern.needle);
}

test "tidy flags global debug and log sinks" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/output.zig",
        \\fn bad() void {
        \\    std.debug.print("bad", .{});
        \\    std.log.info("bad", .{});
        \\}
        \\
    ,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 2), result.violations.items.len);
    try std.testing.expectEqualStrings("std.debug.print", result.violations.items[0].pattern.needle);
    try std.testing.expectEqualStrings("std.log", result.violations.items[1].pattern.needle);
}

test "tidy flags ambient allocator singletons" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/allocation.zig",
        \\const a = std.heap.page_allocator;
        \\const b = std.heap.smp_allocator;
        \\const c = std.heap.c_allocator;
        \\const d = std.heap.wasm_allocator;
        \\const e = std.heap.brk_allocator;
        \\
    ,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 5), result.violations.items.len);
}

test "tidy accepts caller-provided patterns" {
    var result: ScanResult = .{};
    defer result.deinit(std.testing.allocator);

    const patterns = [_]Pattern{
        .{ .needle = "std.heap.page_allocator", .reason = "pass an allocator explicitly" },
    };

    try scanSourceForPath(
        std.testing.allocator,
        &result,
        "src/custom.zig",
        "const allocator = std.heap.page_allocator;\n",
        .{ .patterns = &patterns },
    );

    try std.testing.expectEqual(@as(usize, 1), result.violations.items.len);
    try std.testing.expectEqualStrings("std.heap.page_allocator", result.violations.items[0].pattern.needle);
}
