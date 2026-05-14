//! Small codecs for `CodecTransport`.

const std = @import("std");

/// How long decoded receive values may depend on the received byte message.
pub const RecvLifetime = enum {
    /// `Recv` may borrow from the received byte buffer.
    borrowed,

    /// `Recv` is independent of the received byte buffer.
    owned,
};

/// Pass-through byte codec.
///
/// Received byte slices borrow from the received message and are valid until
/// the surrounding received handle is deinitialized.
pub const bytes = struct {
    pub const Send = []const u8;
    pub const Recv = []const u8;
    pub const recv_lifetime: RecvLifetime = .borrowed;

    pub fn encodedLen(value: Send) !usize {
        return value.len;
    }

    pub fn encode(buffer: []u8, value: Send) ![]const u8 {
        if (value.len > buffer.len) return error.NoSpaceLeft;
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }

    pub fn decode(data: []const u8) !Recv {
        return data;
    }

    pub fn cloneRecv(allocator: std.mem.Allocator, value: Recv) ![]u8 {
        return try allocator.dupe(u8, value);
    }

    pub fn deinitTaken(allocator: std.mem.Allocator, value: []u8) void {
        allocator.free(value);
    }
};

/// Raw fixed-size byte codec for fixed-layout values.
///
/// This is intentionally a low-level codec: it copies the in-memory bytes of
/// `Send` and `Recv`. Use it only for stable fixed-layout types where that is
/// an acceptable wire format.
pub fn fixed(comptime SendType: type, comptime RecvType: type) type {
    return struct {
        pub const Send = SendType;
        pub const Recv = RecvType;
        pub const recv_lifetime: RecvLifetime = .owned;

        pub fn encodedLen(_: Send) !usize {
            return @sizeOf(Send);
        }

        pub fn encode(buffer: []u8, value: Send) ![]const u8 {
            const raw = std.mem.asBytes(&value);
            if (raw.len > buffer.len) return error.NoSpaceLeft;
            @memcpy(buffer[0..raw.len], raw);
            return buffer[0..raw.len];
        }

        pub fn decode(data: []const u8) !Recv {
            if (data.len != @sizeOf(Recv)) return error.InvalidEncodedLength;
            var value: Recv = undefined;
            @memcpy(std.mem.asBytes(&value), data);
            return value;
        }
    };
}

test "codec.bytes clones borrowed receive bytes" {
    const cloned = try bytes.cloneRecv(std.testing.allocator, "hello");
    defer bytes.deinitTaken(std.testing.allocator, cloned);

    try std.testing.expectEqualStrings("hello", cloned);
}

test "codec.fixed round trips fixed-layout values" {
    const Payload = packed struct {
        id: u32,
        value: u16,
    };
    const Codec = fixed(Payload, Payload);

    var buffer: [@sizeOf(Payload)]u8 = undefined;
    const encoded = try Codec.encode(&buffer, .{ .id = 7, .value = 41 });
    const decoded = try Codec.decode(encoded);

    try std.testing.expectEqual(@as(u32, 7), decoded.id);
    try std.testing.expectEqual(@as(u16, 41), decoded.value);
}
