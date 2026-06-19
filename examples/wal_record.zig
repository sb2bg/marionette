//! Example-local fixed-size WAL record framing.
//!
//! Record layout:
//!
//! - `magic`: 4-byte little-endian example identifier (`MKV1`, `MDB1`, ...).
//! - `id`: little-endian sequence/op id chosen by the caller.
//! - `payload`: fixed-size caller-owned bytes.
//! - `checksum`: 4-byte little-endian checksum over magic, id, and payload.
//!
//! Marionette's disk simulator models storage effects. These examples use this
//! file to show that application recovery code still validates torn or corrupt
//! records explicitly.

const std = @import("std");

/// Fixed-size record codec with caller-owned storage and recovery policy.
pub fn Fixed(comptime Id: type, comptime payload_size: usize) type {
    return struct {
        pub const id_size = switch (@typeInfo(Id)) {
            .int => @sizeOf(Id),
            else => @compileError("WAL record ids must be integer types"),
        };
        pub const record_size = 4 + id_size + payload_size + 4;
        pub const Payload = [payload_size]u8;

        pub const Decoded = struct {
            id: Id,
            payload: Payload,
        };

        const Self = @This();

        /// Encode one full fixed-size record.
        pub fn encode(magic: u32, id: Id, payload: Payload) [record_size]u8 {
            var bytes: [record_size]u8 = @splat(0);
            std.mem.writeInt(u32, bytes[0..4], magic, .little);
            std.mem.writeInt(Id, bytes[4..][0..id_size], id, .little);
            @memcpy(bytes[payloadOffset()..checksumOffset()], &payload);
            std.mem.writeInt(u32, bytes[checksumOffset()..][0..4], checksum(magic, id, &payload), .little);
            return bytes;
        }

        /// Decode and validate magic plus checksum.
        pub fn decodeStrict(bytes: *const [record_size]u8, magic: u32) ?Decoded {
            const decoded = decodeMagicOnly(bytes, magic) orelse return null;
            const expected = checksum(magic, decoded.id, &decoded.payload);
            if (std.mem.readInt(u32, bytes[checksumOffset()..][0..4], .little) != expected) return null;
            return decoded;
        }

        /// Decode after checking only the magic value.
        ///
        /// This exists so examples can model deliberately buggy recovery code.
        pub fn decodeMagicOnly(bytes: *const [record_size]u8, magic: u32) ?Decoded {
            if (std.mem.readInt(u32, bytes[0..4], .little) != magic) return null;
            var payload: Payload = undefined;
            @memcpy(&payload, bytes[payloadOffset()..checksumOffset()]);
            return .{
                .id = std.mem.readInt(Id, bytes[4..][0..id_size], .little),
                .payload = payload,
            };
        }

        pub fn payloadOffset() usize {
            return 4 + id_size;
        }

        pub fn checksumOffset() usize {
            return 4 + id_size + payload_size;
        }

        fn checksum(magic: u32, id: Id, payload: []const u8) u32 {
            var value = magic ^ 0xa5a5_5a5a;
            value ^= std.math.rotl(u32, foldInt(id), 7);
            value ^= std.math.rotl(u32, foldBytes(payload), 17);
            value ^= @as(u32, @intCast(Self.record_size));
            return value;
        }
    };
}

fn foldInt(value: anytype) u32 {
    const T = @TypeOf(value);
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    return foldBytes(&bytes);
}

fn foldBytes(bytes: []const u8) u32 {
    var folded: u32 = 0;
    for (bytes, 0..) |byte, index| {
        folded ^= @as(u32, byte) << @intCast((index % 4) * 8);
    }
    return folded;
}

test "wal record: strict decode rejects corrupt payload" {
    const Record = Fixed(u32, 4);
    const magic = 0x4d4b5631; // MKV1
    var payload: Record.Payload = @splat(0);
    std.mem.writeInt(u32, &payload, 41, .little);

    var bytes = Record.encode(magic, 1, payload);
    const decoded = Record.decodeStrict(&bytes, magic).?;
    try std.testing.expectEqual(@as(u32, 1), decoded.id);
    try std.testing.expectEqual(@as(u32, 41), std.mem.readInt(u32, &decoded.payload, .little));

    bytes[Record.payloadOffset()] ^= 0xff;
    try std.testing.expectEqual(@as(?Record.Decoded, null), Record.decodeStrict(&bytes, magic));
    try std.testing.expect(Record.decodeMagicOnly(&bytes, magic) != null);
}
