//! Compile-time record formats. `record(fmt, args)` splits its format at
//! compile time into literal text and placeholders, rejects literal text that
//! could not form a valid trace payload, and writes `{s}` string arguments
//! with trace escaping, so an ordinary string value cannot break trace syntax.

const std = @import("std");

pub const Segment = struct {
    kind: Kind,
    /// Literal text, or the placeholder's specifier for `.value`.
    text: []const u8,
    /// Argument index for placeholders.
    arg: usize = 0,

    pub const Kind = enum { literal, value, escaped };
};

fn isStringType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn argTypes(comptime Args: type) []const type {
    return switch (@typeInfo(Args)) {
        .@"struct" => |info| info.field_types,
        else => @compileError("record arguments must be a tuple, found " ++ @typeName(Args)),
    };
}

/// Parse and validate `fmt` against `Args`. Compile errors name the problem.
pub fn segments(comptime fmt: []const u8, comptime Args: type) []const Segment {
    comptime {
        @setEvalBranchQuota(20_000 + fmt.len * 200);
        const types = argTypes(Args);
        var result: []const Segment = &.{};
        var literal: []const u8 = "";
        // Shape: literal text with each placeholder replaced by `X`, checked
        // against the trace payload grammar below.
        var shape: []const u8 = "";
        var next_arg: usize = 0;
        var index: usize = 0;
        while (index < fmt.len) {
            const char = fmt[index];
            if (char == '{' and index + 1 < fmt.len and fmt[index + 1] == '{') {
                literal = literal ++ "{";
                shape = shape ++ "{";
                index += 2;
                continue;
            }
            if (char == '}' and index + 1 < fmt.len and fmt[index + 1] == '}') {
                literal = literal ++ "}";
                shape = shape ++ "}";
                index += 2;
                continue;
            }
            if (char == '}') @compileError("record format has an unmatched '}': " ++ fmt);
            if (char != '{') {
                literal = literal ++ fmt[index .. index + 1];
                shape = shape ++ fmt[index .. index + 1];
                index += 1;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, fmt, index, '}') orelse
                @compileError("record format has an unmatched '{': " ++ fmt);
            const spec = fmt[index + 1 .. close];
            if (spec.len != 0 and (spec[0] == '[' or std.ascii.isDigit(spec[0])))
                @compileError("record formats take positional placeholders only: " ++ fmt);
            if (next_arg >= types.len) @compileError("record format has more placeholders than arguments: " ++ fmt);
            if (literal.len != 0) result = result ++ &[_]Segment{.{ .kind = .literal, .text = literal }};
            literal = "";
            const escaped = std.mem.eql(u8, spec, "s") and isStringType(types[next_arg]);
            result = result ++ &[_]Segment{.{
                .kind = if (escaped) .escaped else .value,
                .text = spec,
                .arg = next_arg,
            }};
            shape = shape ++ "X";
            next_arg += 1;
            index = close + 1;
        }
        if (literal.len != 0) result = result ++ &[_]Segment{.{ .kind = .literal, .text = literal }};
        if (next_arg != types.len) @compileError("record format has fewer placeholders than arguments: " ++ fmt);
        validateShape(fmt, shape);
        return result;
    }
}

fn validateShape(comptime fmt: []const u8, comptime shape: []const u8) void {
    comptime {
        if (shape.len == 0) @compileError("record format is empty");
        if (shape[0] == ' ' or shape[shape.len - 1] == ' ')
            @compileError("record format has a leading or trailing space: " ++ fmt);
        var tokens = std.mem.splitScalar(u8, shape, ' ');
        const name = tokens.next().?;
        for (name) |char| switch (char) {
            'a'...'z', '0'...'9', '_', '.' => {},
            'X' => @compileError("record event names must be literal: " ++ fmt),
            else => @compileError("record event name has an invalid character: " ++ fmt),
        };
        while (tokens.next()) |token| {
            if (token.len == 0) @compileError("record format has a doubled space: " ++ fmt);
            const equals = std.mem.indexOfScalar(u8, token, '=') orelse
                @compileError("record field is not key=value: " ++ fmt);
            const key = token[0..equals];
            const value = token[equals + 1 ..];
            if (key.len == 0) @compileError("record field has an empty key: " ++ fmt);
            for (key) |char| switch (char) {
                'a'...'z', '0'...'9', '_' => {},
                'X' => @compileError("record field keys must be literal: " ++ fmt),
                else => @compileError("record field key has an invalid character: " ++ fmt),
            };
            if (value.len == 0) @compileError("record field has an empty value: " ++ fmt);
            for (value) |char| switch (char) {
                '=', '\n', '\r', '\t', '\\' => @compileError("record field value has an invalid literal character: " ++ fmt),
                else => {},
            };
        }
    }
}

const hex = "0123456789ABCDEF";

fn isPlain(byte: u8) bool {
    if (byte <= ' ' or byte >= 0x7f) return false;
    return switch (byte) {
        '=', '%', '\\' => false,
        else => true,
    };
}

/// Append one record payload to `list`. Empty escaped strings write nothing,
/// so payload validation still rejects the empty value.
pub fn appendRecord(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!void {
    const parts = comptime segments(fmt, @TypeOf(args));
    inline for (parts) |part| switch (part.kind) {
        .literal => try list.appendSlice(allocator, part.text),
        .value => try list.print(allocator, "{" ++ part.text ++ "}", .{args[part.arg]}),
        .escaped => {
            const bytes: []const u8 = args[part.arg];
            for (bytes) |byte| {
                if (isPlain(byte)) {
                    try list.append(allocator, byte);
                } else {
                    try list.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
                }
            }
        },
    };
}

/// Write one record payload to a fixed writer.
pub fn writeRecord(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
    const parts = comptime segments(fmt, @TypeOf(args));
    inline for (parts) |part| switch (part.kind) {
        .literal => try writer.writeAll(part.text),
        .value => try writer.print("{" ++ part.text ++ "}", .{args[part.arg]}),
        .escaped => {
            const bytes: []const u8 = args[part.arg];
            for (bytes) |byte| {
                if (isPlain(byte)) {
                    try writer.writeByte(byte);
                } else {
                    try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
                }
            }
        },
    };
}

test "record format escapes string arguments" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendRecord(&list, std.testing.allocator, "app.note text={s} n={} tag={s}", .{ "hello world=1", @as(u64, 7), "ok" });
    try std.testing.expectEqualStrings("app.note text=hello%20world%3D1 n=7 tag=ok", list.items);
}

test "record format keeps non-string specifiers and literal braces" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    const Kind = enum { put, get };
    try appendRecord(&list, std.testing.allocator, "app.op kind={s} set={{a}} x={d}", .{ @tagName(Kind.put), 3 });
    try std.testing.expectEqualStrings("app.op kind=put set={a} x=3", list.items);
}
