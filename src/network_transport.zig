//! Socket-agnostic framed transport helpers for production networking.
//!
//! This layer binds `network_frame` to `network_io` without knowing whether the
//! connection is fake IO or a real socket.

const std = @import("std");

const message_pool = @import("message_pool.zig");
const network_frame = @import("network_frame.zig");
const network_io = @import("network_io.zig");

pub const TransportError = network_io.NetworkIoError || network_frame.FrameError || message_pool.PoolError;

pub const ReceivedFrame = struct {
    from: u16,
    to: u16,
    message: message_pool.Message,
};

pub fn sendFrame(
    connection: network_io.Connection,
    scratch: []u8,
    from: u16,
    to: u16,
    payload: []const u8,
) TransportError!void {
    const frame = try network_frame.encode(scratch, .{
        .from = from,
        .to = to,
        .payload = payload,
    });
    try network_io.writeAll(connection, frame);
}

pub fn receiveFrame(
    connection: network_io.Connection,
    pool: *message_pool.Pool,
) TransportError!ReceivedFrame {
    var header_bytes: [network_frame.header_len]u8 = undefined;
    try network_io.readExact(connection, &header_bytes);

    const header = try network_frame.decodeHeader(&header_bytes);
    const message = try pool.acquire(header.payload_len);
    errdefer message.release();

    try network_io.readExact(connection, message.bytes());
    const decoded = try network_frame.decodeParts(&header_bytes, message.bytes());

    return .{
        .from = decoded.from,
        .to = decoded.to,
        .message = message,
    };
}

test "network transport: sends frame over fake io with partial operations" {
    var fake = network_io.Fake.init(std.testing.allocator, .{
        .max_read_bytes = 2,
        .max_write_bytes = 3,
    });
    defer fake.deinit();

    const io = fake.io();
    const listener = try io.listen("127.0.0.1:4240");
    defer listener.close();

    const client = try io.connect("127.0.0.1:4240");
    defer client.close();
    const server = (try listener.accept()).?;
    defer server.close();

    var scratch: [network_frame.header_len + 5]u8 = undefined;
    try sendFrame(client, &scratch, 1, 2, "hello");

    var pool = try message_pool.Pool.init(std.testing.allocator, .{
        .buffers = 1,
        .buffer_size = 16,
    });
    defer pool.deinit();

    const received = try receiveFrame(server, &pool);
    defer received.message.release();

    try std.testing.expectEqual(@as(u16, 1), received.from);
    try std.testing.expectEqual(@as(u16, 2), received.to);
    try std.testing.expectEqualStrings("hello", received.message.bytes());
}

test "network transport: sends frame over host loopback socket" {
    var host = network_io.Host.init(std.testing.allocator, std.testing.io);
    const io = host.io();

    const address = "127.0.0.1:43157";
    const listener = io.listen(address) catch |err| switch (err) {
        error.AddressInUse => return error.SkipZigTest,
        error.NetworkUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    defer listener.close();

    const client = io.connect(address) catch |err| switch (err) {
        error.NetworkUnavailable => return error.SkipZigTest,
        else => |e| return e,
    };
    defer client.close();

    const server = (try listener.accept()).?;
    defer server.close();

    var scratch: [network_frame.header_len + 4]u8 = undefined;
    try sendFrame(client, &scratch, 7, 9, "prod");

    var pool = try message_pool.Pool.init(std.testing.allocator, .{
        .buffers = 1,
        .buffer_size = 16,
    });
    defer pool.deinit();

    const received = try receiveFrame(server, &pool);
    defer received.message.release();

    try std.testing.expectEqual(@as(u16, 7), received.from);
    try std.testing.expectEqual(@as(u16, 9), received.to);
    try std.testing.expectEqualStrings("prod", received.message.bytes());
}
