//! Internal IO seam for the future production network bus.
//!
//! This module is intentionally below `Endpoint(Message)` and `ByteEndpoint`.
//! App code should not see listen/connect/read/write; production transport code
//! uses this seam to keep socket behavior testable.

const std = @import("std");

const clock_module = @import("clock.zig");

pub const NetworkIoError = std.mem.Allocator.Error || error{
    AddressInUse,
    AddressNotFound,
    ConnectionClosed,
    InvalidAddress,
    ListenerClosed,
    NetworkUnavailable,
};

pub const NetworkIo = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        listen: *const fn (*anyopaque, []const u8) NetworkIoError!Listener,
        connect: *const fn (*anyopaque, []const u8) NetworkIoError!Connection,
        now: *const fn (*anyopaque) clock_module.Timestamp,
        sleep: *const fn (*anyopaque, clock_module.Duration) NetworkIoError!void,
    };

    pub fn listen(self: NetworkIo, address: []const u8) NetworkIoError!Listener {
        return try self.vtable.listen(self.ptr, address);
    }

    pub fn connect(self: NetworkIo, address: []const u8) NetworkIoError!Connection {
        return try self.vtable.connect(self.ptr, address);
    }

    pub fn now(self: NetworkIo) clock_module.Timestamp {
        return self.vtable.now(self.ptr);
    }

    pub fn sleep(self: NetworkIo, duration_ns: clock_module.Duration) NetworkIoError!void {
        try self.vtable.sleep(self.ptr, duration_ns);
    }
};

pub const Listener = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        accept: *const fn (*anyopaque) NetworkIoError!?Connection,
        close: *const fn (*anyopaque) void,
    };

    pub fn accept(self: Listener) NetworkIoError!?Connection {
        return try self.vtable.accept(self.ptr);
    }

    pub fn close(self: Listener) void {
        self.vtable.close(self.ptr);
    }
};

pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque, []u8) NetworkIoError!usize,
        write: *const fn (*anyopaque, []const u8) NetworkIoError!usize,
        close: *const fn (*anyopaque) void,
    };

    pub fn read(self: Connection, buffer: []u8) NetworkIoError!usize {
        return try self.vtable.read(self.ptr, buffer);
    }

    pub fn write(self: Connection, bytes: []const u8) NetworkIoError!usize {
        return try self.vtable.write(self.ptr, bytes);
    }

    pub fn close(self: Connection) void {
        self.vtable.close(self.ptr);
    }
};

pub fn readExact(connection: Connection, buffer: []u8) NetworkIoError!void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const read_count = try connection.read(buffer[offset..]);
        if (read_count == 0) return error.ConnectionClosed;
        offset += read_count;
    }
}

pub fn writeAll(connection: Connection, bytes: []const u8) NetworkIoError!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = try connection.write(bytes[offset..]);
        if (written == 0) return error.ConnectionClosed;
        offset += written;
    }
}

pub const Host = struct {
    allocator: std.mem.Allocator,
    io_backend: std.Io,

    const ListenerState = struct {
        allocator: std.mem.Allocator,
        io_backend: std.Io,
        server: std.Io.net.Server,
        closed: bool = false,
    };

    const ConnectionState = struct {
        allocator: std.mem.Allocator,
        io_backend: std.Io,
        stream: std.Io.net.Stream,
        closed: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, io_backend: std.Io) Host {
        return .{
            .allocator = allocator,
            .io_backend = io_backend,
        };
    }

    pub fn io(self: *Host) NetworkIo {
        return .{ .ptr = self, .vtable = &network_io_vtable };
    }

    fn listen(self: *Host, address_text: []const u8) NetworkIoError!Listener {
        const address = parseAddress(address_text) catch return error.InvalidAddress;
        const server = std.Io.net.IpAddress.listen(&address, self.io_backend, .{
            .reuse_address = true,
        }) catch |err| return mapListenError(err);
        errdefer server.socket.close(self.io_backend);

        const state = try self.allocator.create(ListenerState);
        state.* = .{
            .allocator = self.allocator,
            .io_backend = self.io_backend,
            .server = server,
        };
        return .{ .ptr = state, .vtable = &listener_vtable };
    }

    fn connect(self: *Host, address_text: []const u8) NetworkIoError!Connection {
        const address = parseAddress(address_text) catch return error.InvalidAddress;
        const stream = std.Io.net.IpAddress.connect(&address, self.io_backend, .{
            .mode = .stream,
            .protocol = .tcp,
        }) catch |err| return mapConnectError(err);
        errdefer stream.close(self.io_backend);

        const state = try self.allocator.create(ConnectionState);
        state.* = .{
            .allocator = self.allocator,
            .io_backend = self.io_backend,
            .stream = stream,
        };
        return .{ .ptr = state, .vtable = &connection_vtable };
    }

    fn now(self: *Host) clock_module.Timestamp {
        const timestamp = std.Io.Clock.real.now(self.io_backend);
        std.debug.assert(timestamp.nanoseconds >= 0);
        return @intCast(timestamp.nanoseconds);
    }

    fn sleep(self: *Host, duration_ns: clock_module.Duration) NetworkIoError!void {
        std.Io.sleep(self.io_backend, .fromNanoseconds(duration_ns), .awake) catch {
            return error.NetworkUnavailable;
        };
    }

    fn listenerAccept(listener: *ListenerState) NetworkIoError!?Connection {
        if (listener.closed) return error.ListenerClosed;
        const stream = listener.server.accept(listener.io_backend) catch |err| return mapAcceptError(err);
        errdefer stream.close(listener.io_backend);

        const state = try listener.allocator.create(ConnectionState);
        state.* = .{
            .allocator = listener.allocator,
            .io_backend = listener.io_backend,
            .stream = stream,
        };
        return .{ .ptr = state, .vtable = &connection_vtable };
    }

    fn listenerClose(listener: *ListenerState) void {
        if (!listener.closed) {
            listener.server.deinit(listener.io_backend);
            listener.closed = true;
        }
        const allocator = listener.allocator;
        allocator.destroy(listener);
    }

    fn connectionRead(connection: *ConnectionState, buffer: []u8) NetworkIoError!usize {
        if (connection.closed) return error.ConnectionClosed;
        if (buffer.len == 0) return 0;
        var data: [1][]u8 = .{buffer};
        return connection.io_backend.vtable.netRead(
            connection.io_backend.userdata,
            connection.stream.socket.handle,
            &data,
        ) catch |err| return mapReadError(err);
    }

    fn connectionWrite(connection: *ConnectionState, bytes: []const u8) NetworkIoError!usize {
        if (connection.closed) return error.ConnectionClosed;
        if (bytes.len == 0) return 0;
        const data: [1][]const u8 = .{bytes};
        return connection.io_backend.vtable.netWrite(
            connection.io_backend.userdata,
            connection.stream.socket.handle,
            "",
            &data,
            1,
        ) catch |err| return mapWriteError(err);
    }

    fn connectionClose(connection: *ConnectionState) void {
        if (!connection.closed) {
            connection.stream.close(connection.io_backend);
            connection.closed = true;
        }
        const allocator = connection.allocator;
        allocator.destroy(connection);
    }

    fn parseAddress(address_text: []const u8) !std.Io.net.IpAddress {
        return std.Io.net.IpAddress.parseLiteral(address_text);
    }

    fn mapListenError(err: anyerror) NetworkIoError {
        return switch (err) {
            error.AddressInUse => error.AddressInUse,
            error.AddressUnavailable,
            error.AddressFamilyUnsupported,
            => error.InvalidAddress,
            error.NetworkDown => error.NetworkUnavailable,
            else => error.NetworkUnavailable,
        };
    }

    fn mapConnectError(err: anyerror) NetworkIoError {
        return switch (err) {
            error.ConnectionRefused,
            error.HostUnreachable,
            error.NetworkUnreachable,
            => error.AddressNotFound,
            error.AddressUnavailable,
            error.AddressFamilyUnsupported,
            => error.InvalidAddress,
            error.ConnectionResetByPeer,
            error.SocketUnconnected,
            => error.ConnectionClosed,
            error.NetworkDown => error.NetworkUnavailable,
            else => error.NetworkUnavailable,
        };
    }

    fn mapAcceptError(err: anyerror) NetworkIoError {
        return switch (err) {
            error.WouldBlock => error.AddressNotFound,
            error.SocketNotListening => error.ListenerClosed,
            error.ConnectionAborted => error.ConnectionClosed,
            error.NetworkDown => error.NetworkUnavailable,
            else => error.NetworkUnavailable,
        };
    }

    fn mapReadError(err: anyerror) NetworkIoError {
        return switch (err) {
            error.ConnectionResetByPeer,
            error.SocketUnconnected,
            error.EndOfStream,
            => error.ConnectionClosed,
            error.NetworkDown => error.NetworkUnavailable,
            else => error.NetworkUnavailable,
        };
    }

    fn mapWriteError(err: anyerror) NetworkIoError {
        return switch (err) {
            error.ConnectionResetByPeer,
            error.ConnectionRefused,
            error.SocketUnconnected,
            => error.ConnectionClosed,
            error.NetworkDown,
            error.NetworkUnreachable,
            error.HostUnreachable,
            => error.NetworkUnavailable,
            else => error.NetworkUnavailable,
        };
    }

    fn vtableListen(ptr: *anyopaque, address: []const u8) NetworkIoError!Listener {
        const host: *Host = @ptrCast(@alignCast(ptr));
        return try host.listen(address);
    }

    fn vtableConnect(ptr: *anyopaque, address: []const u8) NetworkIoError!Connection {
        const host: *Host = @ptrCast(@alignCast(ptr));
        return try host.connect(address);
    }

    fn vtableNow(ptr: *anyopaque) clock_module.Timestamp {
        const host: *Host = @ptrCast(@alignCast(ptr));
        return host.now();
    }

    fn vtableSleep(ptr: *anyopaque, duration_ns: clock_module.Duration) NetworkIoError!void {
        const host: *Host = @ptrCast(@alignCast(ptr));
        try host.sleep(duration_ns);
    }

    fn vtableAccept(ptr: *anyopaque) NetworkIoError!?Connection {
        const listener: *ListenerState = @ptrCast(@alignCast(ptr));
        return try listenerAccept(listener);
    }

    fn vtableListenerClose(ptr: *anyopaque) void {
        const listener: *ListenerState = @ptrCast(@alignCast(ptr));
        listenerClose(listener);
    }

    fn vtableRead(ptr: *anyopaque, buffer: []u8) NetworkIoError!usize {
        const connection: *ConnectionState = @ptrCast(@alignCast(ptr));
        return try connectionRead(connection, buffer);
    }

    fn vtableWrite(ptr: *anyopaque, bytes: []const u8) NetworkIoError!usize {
        const connection: *ConnectionState = @ptrCast(@alignCast(ptr));
        return try connectionWrite(connection, bytes);
    }

    fn vtableConnectionClose(ptr: *anyopaque) void {
        const connection: *ConnectionState = @ptrCast(@alignCast(ptr));
        connectionClose(connection);
    }

    const network_io_vtable: NetworkIo.VTable = .{
        .listen = vtableListen,
        .connect = vtableConnect,
        .now = vtableNow,
        .sleep = vtableSleep,
    };

    const listener_vtable: Listener.VTable = .{
        .accept = vtableAccept,
        .close = vtableListenerClose,
    };

    const connection_vtable: Connection.VTable = .{
        .read = vtableRead,
        .write = vtableWrite,
        .close = vtableConnectionClose,
    };
};

pub const Fake = struct {
    allocator: std.mem.Allocator,
    listeners: std.ArrayList(*ListenerState) = .empty,
    connections: std.ArrayList(*ConnectionState) = .empty,
    now_ns: clock_module.Timestamp = 0,
    max_read_bytes: usize,
    max_write_bytes: usize,

    pub const Options = struct {
        max_read_bytes: usize = 0,
        max_write_bytes: usize = 0,
    };

    const ListenerState = struct {
        owner: *Fake,
        address: []u8,
        pending: std.ArrayList(*ConnectionState) = .empty,
        closed: bool = false,
    };

    const ConnectionState = struct {
        owner: *Fake,
        inbox: std.ArrayList(u8) = .empty,
        peer: ?*ConnectionState = null,
        closed: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) Fake {
        return .{
            .allocator = allocator,
            .max_read_bytes = options.max_read_bytes,
            .max_write_bytes = options.max_write_bytes,
        };
    }

    pub fn deinit(self: *Fake) void {
        for (self.listeners.items) |listener| {
            self.allocator.free(listener.address);
            listener.pending.deinit(self.allocator);
            self.allocator.destroy(listener);
        }
        self.listeners.deinit(self.allocator);

        for (self.connections.items) |connection| {
            connection.inbox.deinit(self.allocator);
            self.allocator.destroy(connection);
        }
        self.connections.deinit(self.allocator);

        self.* = undefined;
    }

    pub fn io(self: *Fake) NetworkIo {
        return .{ .ptr = self, .vtable = &network_io_vtable };
    }

    fn listen(self: *Fake, address: []const u8) NetworkIoError!Listener {
        if (self.openListener(address) != null) return error.AddressInUse;

        const listener = try self.allocator.create(ListenerState);
        errdefer self.allocator.destroy(listener);

        const owned_address = try self.allocator.dupe(u8, address);
        errdefer self.allocator.free(owned_address);

        listener.* = .{
            .owner = self,
            .address = owned_address,
        };
        errdefer listener.pending.deinit(self.allocator);

        try self.listeners.append(self.allocator, listener);
        return .{ .ptr = listener, .vtable = &listener_vtable };
    }

    fn connect(self: *Fake, address: []const u8) NetworkIoError!Connection {
        const listener = self.openListener(address) orelse return error.AddressNotFound;

        const client = try self.allocator.create(ConnectionState);
        errdefer self.allocator.destroy(client);
        client.* = .{ .owner = self };
        errdefer client.inbox.deinit(self.allocator);

        const server = try self.allocator.create(ConnectionState);
        errdefer self.allocator.destroy(server);
        server.* = .{ .owner = self };
        errdefer server.inbox.deinit(self.allocator);

        client.peer = server;
        server.peer = client;

        try self.connections.append(self.allocator, client);
        errdefer _ = self.connections.pop();
        try self.connections.append(self.allocator, server);
        errdefer _ = self.connections.pop();

        try listener.pending.append(self.allocator, server);
        return .{ .ptr = client, .vtable = &connection_vtable };
    }

    fn openListener(self: *Fake, address: []const u8) ?*ListenerState {
        for (self.listeners.items) |listener| {
            if (!listener.closed and std.mem.eql(u8, listener.address, address)) return listener;
        }
        return null;
    }

    fn sleep(self: *Fake, duration_ns: clock_module.Duration) NetworkIoError!void {
        if (std.math.maxInt(clock_module.Timestamp) - self.now_ns < duration_ns) {
            return error.ConnectionClosed;
        }
        self.now_ns += duration_ns;
    }

    fn listenerAccept(listener: *ListenerState) NetworkIoError!?Connection {
        if (listener.closed) return error.ListenerClosed;
        if (listener.pending.items.len == 0) return null;
        const connection = listener.pending.orderedRemove(0);
        return .{ .ptr = connection, .vtable = &connection_vtable };
    }

    fn listenerClose(listener: *ListenerState) void {
        listener.closed = true;
    }

    fn connectionRead(connection: *ConnectionState, buffer: []u8) NetworkIoError!usize {
        if (connection.closed) return error.ConnectionClosed;
        if (buffer.len == 0) return 0;
        if (connection.inbox.items.len == 0) return 0;

        const limit = limitedCount(buffer.len, connection.owner.max_read_bytes);
        const read_count = @min(limit, connection.inbox.items.len);
        @memcpy(buffer[0..read_count], connection.inbox.items[0..read_count]);
        connection.inbox.replaceRangeAssumeCapacity(0, read_count, &.{});
        return read_count;
    }

    fn connectionWrite(connection: *ConnectionState, bytes: []const u8) NetworkIoError!usize {
        if (connection.closed) return error.ConnectionClosed;
        const peer = connection.peer orelse return error.ConnectionClosed;
        if (peer.closed) return error.ConnectionClosed;
        if (bytes.len == 0) return 0;

        const write_count = limitedCount(bytes.len, connection.owner.max_write_bytes);
        try peer.inbox.appendSlice(connection.owner.allocator, bytes[0..write_count]);
        return write_count;
    }

    fn connectionClose(connection: *ConnectionState) void {
        connection.closed = true;
    }

    fn limitedCount(requested: usize, configured_limit: usize) usize {
        if (configured_limit == 0) return requested;
        return @min(requested, configured_limit);
    }

    fn vtableListen(ptr: *anyopaque, address: []const u8) NetworkIoError!Listener {
        const fake: *Fake = @ptrCast(@alignCast(ptr));
        return try fake.listen(address);
    }

    fn vtableConnect(ptr: *anyopaque, address: []const u8) NetworkIoError!Connection {
        const fake: *Fake = @ptrCast(@alignCast(ptr));
        return try fake.connect(address);
    }

    fn vtableNow(ptr: *anyopaque) clock_module.Timestamp {
        const fake: *Fake = @ptrCast(@alignCast(ptr));
        return fake.now_ns;
    }

    fn vtableSleep(ptr: *anyopaque, duration_ns: clock_module.Duration) NetworkIoError!void {
        const fake: *Fake = @ptrCast(@alignCast(ptr));
        try fake.sleep(duration_ns);
    }

    fn vtableAccept(ptr: *anyopaque) NetworkIoError!?Connection {
        const listener: *ListenerState = @ptrCast(@alignCast(ptr));
        return try listenerAccept(listener);
    }

    fn vtableListenerClose(ptr: *anyopaque) void {
        const listener: *ListenerState = @ptrCast(@alignCast(ptr));
        listenerClose(listener);
    }

    fn vtableRead(ptr: *anyopaque, buffer: []u8) NetworkIoError!usize {
        const connection: *ConnectionState = @ptrCast(@alignCast(ptr));
        return try connectionRead(connection, buffer);
    }

    fn vtableWrite(ptr: *anyopaque, bytes: []const u8) NetworkIoError!usize {
        const connection: *ConnectionState = @ptrCast(@alignCast(ptr));
        return try connectionWrite(connection, bytes);
    }

    fn vtableConnectionClose(ptr: *anyopaque) void {
        const connection: *ConnectionState = @ptrCast(@alignCast(ptr));
        connectionClose(connection);
    }

    const network_io_vtable: NetworkIo.VTable = .{
        .listen = vtableListen,
        .connect = vtableConnect,
        .now = vtableNow,
        .sleep = vtableSleep,
    };

    const listener_vtable: Listener.VTable = .{
        .accept = vtableAccept,
        .close = vtableListenerClose,
    };

    const connection_vtable: Connection.VTable = .{
        .read = vtableRead,
        .write = vtableWrite,
        .close = vtableConnectionClose,
    };
};

test "network io fake: listen connect accept and exact transfer" {
    var fake = Fake.init(std.testing.allocator, .{
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

    try writeAll(client, "hello");

    var buffer: [5]u8 = undefined;
    try readExact(server, &buffer);
    try std.testing.expectEqualStrings("hello", &buffer);
    try std.testing.expect((try listener.accept()) == null);
}

test "network io fake: rejects missing and duplicate listeners" {
    var fake = Fake.init(std.testing.allocator, .{});
    defer fake.deinit();

    const io = fake.io();
    try std.testing.expectError(error.AddressNotFound, io.connect("127.0.0.1:4240"));

    const listener = try io.listen("127.0.0.1:4240");
    defer listener.close();
    try std.testing.expectError(error.AddressInUse, io.listen("127.0.0.1:4240"));

    listener.close();
    const replacement = try io.listen("127.0.0.1:4240");
    replacement.close();
}

test "network io fake: readExact reports closed connection" {
    var fake = Fake.init(std.testing.allocator, .{});
    defer fake.deinit();

    const io = fake.io();
    const listener = try io.listen("127.0.0.1:4240");
    defer listener.close();

    const client = try io.connect("127.0.0.1:4240");
    const server = (try listener.accept()).?;
    defer server.close();

    client.close();
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.ConnectionClosed, readExact(server, &buffer));
}

test "network io fake: writeAll reports closed peer" {
    var fake = Fake.init(std.testing.allocator, .{});
    defer fake.deinit();

    const io = fake.io();
    const listener = try io.listen("127.0.0.1:4240");
    defer listener.close();

    const client = try io.connect("127.0.0.1:4240");
    defer client.close();
    const server = (try listener.accept()).?;
    server.close();

    try std.testing.expectError(error.ConnectionClosed, writeAll(client, "x"));
}

test "network io fake: clock is advanced through seam" {
    var fake = Fake.init(std.testing.allocator, .{});
    defer fake.deinit();

    const io = fake.io();
    try std.testing.expectEqual(@as(clock_module.Timestamp, 0), io.now());
    try io.sleep(10);
    try std.testing.expectEqual(@as(clock_module.Timestamp, 10), io.now());
}
