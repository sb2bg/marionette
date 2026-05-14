//! Production network frame encoding.
//!
//! This module is intentionally socket-free. It owns only the stable byte
//! format that the future production bus will write to and read from streams.

const std = @import("std");

pub const node_id_size = 2;
pub const size_size = 4;
pub const checksum_size = 16;
pub const reserved_size = 4;

pub const size_offset = 0;
pub const checksum_header_offset = size_offset + size_size;
pub const checksum_body_offset = checksum_header_offset + checksum_size;
pub const from_offset = checksum_body_offset + checksum_size;
pub const to_offset = from_offset + node_id_size;
pub const reserved_offset = to_offset + node_id_size;
pub const payload_offset = reserved_offset + reserved_size;

pub const header_len = payload_offset;
pub const max_frame_size = std.math.maxInt(u32);

// marionette-net01 in hex
const checksum_key: [16]u8 = .{
    0x6d, 0x61, 0x72, 0x69, 0x6f, 0x6e, 0x65, 0x74,
    0x74, 0x65, 0x2d, 0x6e, 0x65, 0x74, 0x30, 0x31,
};

const SipHash128 = std.crypto.auth.siphash.SipHash128(2, 4);

pub const FrameError = error{
    BufferTooSmall,
    FrameTooSmall,
    FrameTooLarge,
    InvalidSize,
    ReservedNonZero,
    HeaderChecksumMismatch,
    BodyChecksumMismatch,
};

pub const EncodeOptions = struct {
    from: u16,
    to: u16,
    payload: []const u8,
};

pub const Decoded = struct {
    from: u16,
    to: u16,
    payload: []const u8,
};

pub const Header = struct {
    frame_len: u32,
    payload_len: usize,
    from: u16,
    to: u16,
};

pub fn encodedLen(payload_len: usize) FrameError!usize {
    if (payload_len > max_frame_size - header_len) return error.FrameTooLarge;
    return header_len + payload_len;
}

pub fn encode(buffer: []u8, options: EncodeOptions) FrameError![]u8 {
    const frame_len = try encodedLen(options.payload.len);
    if (buffer.len < frame_len) return error.BufferTooSmall;

    const frame = buffer[0..frame_len];
    @memset(frame[0..header_len], 0);
    @memcpy(frame[payload_offset..], options.payload);

    std.mem.writeInt(u32, frame[size_offset..][0..size_size], @intCast(frame_len), .little);
    std.mem.writeInt(u128, frame[checksum_body_offset..][0..checksum_size], checksum(options.payload), .little);
    std.mem.writeInt(u16, frame[from_offset..][0..node_id_size], options.from, .little);
    std.mem.writeInt(u16, frame[to_offset..][0..node_id_size], options.to, .little);
    std.mem.writeInt(u32, frame[reserved_offset..][0..reserved_size], 0, .little);
    std.mem.writeInt(u128, frame[checksum_header_offset..][0..checksum_size], headerChecksum(frame[0..header_len]), .little);

    return frame;
}

pub fn decode(frame: []const u8) FrameError!Decoded {
    if (frame.len < header_len) return error.FrameTooSmall;

    const header_bytes = frame[0..header_len];
    const header = try decodeHeader(header_bytes);
    if (header.frame_len != frame.len) return error.InvalidSize;

    return try decodeParts(header_bytes, frame[payload_offset..]);
}

pub fn decodeParts(header_bytes: []const u8, payload: []const u8) FrameError!Decoded {
    if (header_bytes.len < header_len) return error.FrameTooSmall;

    const header = try decodeHeader(header_bytes);
    if (payload.len != header.payload_len) return error.InvalidSize;

    const expected_body_checksum = std.mem.readInt(u128, header_bytes[checksum_body_offset..][0..checksum_size], .little);
    if (checksum(payload) != expected_body_checksum) {
        return error.BodyChecksumMismatch;
    }

    return .{
        .from = header.from,
        .to = header.to,
        .payload = payload,
    };
}

pub fn decodeHeader(bytes: []const u8) FrameError!Header {
    if (bytes.len < header_len) return error.FrameTooSmall;

    const header = bytes[0..header_len];
    const declared_size = std.mem.readInt(u32, header[size_offset..][0..size_size], .little);
    if (declared_size < header_len) return error.InvalidSize;

    const reserved = std.mem.readInt(u32, header[reserved_offset..][0..reserved_size], .little);
    if (reserved != 0) return error.ReservedNonZero;

    const expected_header_checksum = std.mem.readInt(u128, header[checksum_header_offset..][0..checksum_size], .little);
    if (headerChecksum(header) != expected_header_checksum) {
        return error.HeaderChecksumMismatch;
    }

    return .{
        .frame_len = declared_size,
        .payload_len = declared_size - header_len,
        .from = std.mem.readInt(u16, header[from_offset..][0..node_id_size], .little),
        .to = std.mem.readInt(u16, header[to_offset..][0..node_id_size], .little),
    };
}

fn headerChecksum(header: []const u8) u128 {
    std.debug.assert(header.len == header_len);
    var canonical: [header_len]u8 = undefined;
    @memcpy(&canonical, header);
    @memset(canonical[checksum_header_offset..][0..checksum_size], 0);
    return checksum(&canonical);
}

fn checksum(bytes: []const u8) u128 {
    return SipHash128.toInt(bytes, &checksum_key);
}

test "network frame: round trips empty payload" {
    var buffer: [header_len]u8 = undefined;

    const frame = try encode(&buffer, .{
        .from = 7,
        .to = 9,
        .payload = "",
    });
    const decoded = try decode(frame);

    try std.testing.expectEqual(@as(usize, header_len), frame.len);
    try std.testing.expectEqual(@as(u16, 7), decoded.from);
    try std.testing.expectEqual(@as(u16, 9), decoded.to);
    try std.testing.expectEqualStrings("", decoded.payload);
}

test "network frame: round trips payload" {
    const payload = "hello";
    var buffer: [header_len + payload.len]u8 = undefined;

    const frame = try encode(&buffer, .{
        .from = 1,
        .to = 2,
        .payload = payload,
    });
    const decoded = try decode(frame);

    try std.testing.expectEqual(@as(u16, 1), decoded.from);
    try std.testing.expectEqual(@as(u16, 2), decoded.to);
    try std.testing.expectEqualStrings(payload, decoded.payload);
}

test "network frame: decodes header before body" {
    const payload = "hello";
    var buffer: [header_len + payload.len]u8 = undefined;

    const frame = try encode(&buffer, .{
        .from = 1,
        .to = 2,
        .payload = payload,
    });
    const header = try decodeHeader(frame[0..header_len]);

    try std.testing.expectEqual(@as(u32, @intCast(frame.len)), header.frame_len);
    try std.testing.expectEqual(@as(usize, payload.len), header.payload_len);
    try std.testing.expectEqual(@as(u16, 1), header.from);
    try std.testing.expectEqual(@as(u16, 2), header.to);
}

test "network frame: decodes header and payload parts" {
    const payload = "hello";
    var buffer: [header_len + payload.len]u8 = undefined;

    const frame = try encode(&buffer, .{
        .from = 1,
        .to = 2,
        .payload = payload,
    });
    const decoded = try decodeParts(frame[0..header_len], frame[payload_offset..]);

    try std.testing.expectEqual(@as(u16, 1), decoded.from);
    try std.testing.expectEqual(@as(u16, 2), decoded.to);
    try std.testing.expectEqualStrings(payload, decoded.payload);
}

test "network frame: rejects too-small buffers" {
    var buffer: [header_len - 1]u8 = undefined;

    try std.testing.expectError(error.BufferTooSmall, encode(&buffer, .{
        .from = 1,
        .to = 2,
        .payload = "",
    }));
    try std.testing.expectError(error.FrameTooSmall, decode(&buffer));
    try std.testing.expectError(error.FrameTooSmall, decodeHeader(&buffer));
}

test "network frame: rejects declared size mismatch" {
    var buffer: [header_len]u8 = undefined;
    const frame = try encode(&buffer, .{
        .from = 1,
        .to = 2,
        .payload = "",
    });

    std.mem.writeInt(u32, frame[size_offset..][0..size_size], header_len - 1, .little);

    try std.testing.expectError(error.InvalidSize, decode(frame));
    try std.testing.expectError(error.InvalidSize, decodeHeader(frame[0..header_len]));
}

test "network frame: rejects header corruption" {
    var buffer: [header_len]u8 = undefined;
    const frame = try encode(&buffer, .{
        .from = 1,
        .to = 2,
        .payload = "",
    });

    frame[to_offset] = 3;

    try std.testing.expectError(error.HeaderChecksumMismatch, decode(frame));
    try std.testing.expectError(error.HeaderChecksumMismatch, decodeHeader(frame[0..header_len]));
}

test "network frame: rejects body corruption" {
    var buffer: [header_len + 5]u8 = undefined;
    const frame = try encode(&buffer, .{
        .from = 1,
        .to = 2,
        .payload = "hello",
    });

    frame[payload_offset] = 'j';

    try std.testing.expectError(error.BodyChecksumMismatch, decode(frame));
}

test "network frame: rejects reserved bytes" {
    var buffer: [header_len]u8 = undefined;
    const frame = try encode(&buffer, .{
        .from = 1,
        .to = 2,
        .payload = "",
    });

    std.mem.writeInt(u32, frame[reserved_offset..][0..reserved_size], 1, .little);

    try std.testing.expectError(error.ReservedNonZero, decode(frame));
    try std.testing.expectError(error.ReservedNonZero, decodeHeader(frame[0..header_len]));
}

test "network frame: rejects payload lengths that cannot fit in u32 frame size" {
    try std.testing.expectError(error.FrameTooLarge, encodedLen(max_frame_size - header_len + 1));
}
