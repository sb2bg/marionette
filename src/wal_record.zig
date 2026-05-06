//! Small fixed-size WAL record framing helpers.
//!
//! This is intentionally not a WAL framework. It only centralizes the repeated
//! magic/body/checksum framing pattern used by examples.

const std = @import("std");

pub fn FixedRecord(comptime body_len: usize) type {
    comptime {
        if (body_len == 0) @compileError("WAL record body must not be empty");
    }

    return struct {
        const Self = @This();

        pub const body_size = body_len;
        pub const record_size = 4 + body_size + 4;

        pub const Decoded = struct {
            body: [body_size]u8,
        };

        pub fn encode(bytes: *[record_size]u8, magic: u32, body: *const [body_size]u8) void {
            putU32(bytes[0..4], magic);
            @memcpy(bytes[4..][0..body_size], body[0..]);
            putU32(bytes[4 + body_size .. record_size], checksum(magic, body[0..]));
        }

        pub fn decode(bytes: *const [record_size]u8, magic: u32) ?Decoded {
            const decoded = Self.decodeMagicOnly(bytes, magic) orelse return null;
            if (readU32(bytes[4 + body_size .. record_size]) != checksum(magic, decoded.body[0..])) return null;
            return decoded;
        }

        pub fn decodeMagicOnly(bytes: *const [record_size]u8, magic: u32) ?Decoded {
            if (readU32(bytes[0..4]) != magic) return null;

            var body: [body_size]u8 = undefined;
            @memcpy(body[0..], bytes[4..][0..body_size]);
            return .{ .body = body };
        }
    };
}

pub fn checksum(magic: u32, body: []const u8) u32 {
    var value = magic ^ @as(u32, @intCast(body.len)) ^ 0xa5a5_5a5a;
    for (body, 0..) |byte, index| {
        const mixed = @as(u32, byte) | (@as(u32, @truncate(index)) << 8);
        value = std.math.rotl(u32, value ^ mixed, 5) *% 0x9e37_79b1;
    }
    return value;
}

pub fn putU32(bytes: []u8, value: u32) void {
    std.debug.assert(bytes.len == 4);
    bytes[0] = @as(u8, @truncate(value));
    bytes[1] = @as(u8, @truncate(value >> 8));
    bytes[2] = @as(u8, @truncate(value >> 16));
    bytes[3] = @as(u8, @truncate(value >> 24));
}

pub fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len == 4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

pub fn putU64(bytes: []u8, value: u64) void {
    std.debug.assert(bytes.len == 8);
    for (0..8) |index| {
        bytes[index] = @as(u8, @truncate(value >> @intCast(index * 8)));
    }
}

pub fn readU64(bytes: []const u8) u64 {
    std.debug.assert(bytes.len == 8);
    var value: u64 = 0;
    for (0..8) |index| {
        value |= @as(u64, bytes[index]) << @intCast(index * 8);
    }
    return value;
}

test "wal record: strict decode rejects checksum mismatch" {
    const Record = FixedRecord(8);
    const magic: u32 = 0x4d574131; // MWA1
    var body: [Record.body_size]u8 = @splat(0);
    putU32(body[0..4], 7);
    putU32(body[4..8], 41);

    var bytes: [Record.record_size]u8 = undefined;
    Record.encode(&bytes, magic, &body);
    try std.testing.expect(Record.decode(&bytes, magic) != null);

    bytes[8] ^= 0xff;
    try std.testing.expect(Record.decode(&bytes, magic) == null);
    try std.testing.expect(Record.decodeMagicOnly(&bytes, magic) != null);
}

test "wal record: little endian integer helpers round trip" {
    var bytes: [12]u8 = undefined;
    putU32(bytes[0..4], 0x1122_3344);
    putU64(bytes[4..12], 0x1122_3344_5566_7788);

    try std.testing.expectEqual(@as(u32, 0x1122_3344), readU32(bytes[0..4]));
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), readU64(bytes[4..12]));
}
