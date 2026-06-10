//! Production endpoint adapters and runtimes.

const std = @import("std");

const clock_module = @import("../clock.zig");
const endpoint_module = @import("endpoint.zig");
const message_pool_module = @import("../message_pool.zig");
const network_io_module = @import("io.zig");
const network_transport_module = @import("transport.zig");
const types = @import("types.zig");

const ByteEndpoint = endpoint_module.ByteEndpoint;
const Endpoint = endpoint_module.Endpoint;
const NodeId = types.NodeId;
const default_byte_pool_options = types.default_byte_pool_options;

/// One peer in a production network topology.
pub const ProductionPeer = struct {
    id: NodeId,
    address: []const u8,
};

/// Production endpoint construction options.
///
/// The current production runtime is still an in-process FIFO. These options
/// are the socket-backed shape it will grow into: one local process id, one
/// listener address, and the full peer table used to resolve remote ids.
pub const ProductionEndpointOptions = struct {
    self: NodeId,
    peers: []const ProductionPeer,
    listen: ?[]const u8 = null,
};

/// Bulk helper options for same-process production parity tests.
pub const ProductionEndpointsOptions = struct {
    first_node: NodeId,
    peers: []const ProductionPeer,
};

pub const ProductionNetworkError = std.mem.Allocator.Error || error{
    ProductionTopologyEmpty,
    ProductionTopologyDuplicatePeer,
    ProductionTopologyMissingSelf,
};

pub const ProductionByteEndpointError = ProductionNetworkError || message_pool_module.PoolError || network_io_module.NetworkIoError;

pub const ProductionNetworkTeardown = struct {
    ptr: *anyopaque,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub const ProductionNetworkEntry = struct {
    payload_name: []const u8,
    ptr: *anyopaque,
    teardown: ProductionNetworkTeardown,
};

pub fn productionEndpoint(
    comptime Payload: type,
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(ProductionNetworkEntry),
    options: ProductionEndpointOptions,
) ProductionNetworkError!Endpoint(Payload) {
    try validateProductionEndpointOptions(options);

    const payload_name = @typeName(Payload);
    // TODO(roadmap item 15): linear lookup is acceptable while Production is a
    // same-process parity adapter with only a few payload types. Replace this
    // registry with an indexed map if production endpoints become numerous.
    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.payload_name, payload_name)) {
            const runtime: *ProductionRuntime(Payload) = @ptrCast(@alignCast(entry.ptr));
            return runtime.handle(options.self);
        }
    }

    const runtime = try ProductionRuntime(Payload).init(allocator);
    errdefer runtime.deinit();

    try entries.append(allocator, .{
        .payload_name = payload_name,
        .ptr = runtime,
        .teardown = .{ .ptr = runtime, .deinit = ProductionRuntime(Payload).deinitOpaque },
    });

    return runtime.handle(options.self);
}

const production_byte_runtime_name = "marionette.ByteEndpoint";

pub fn productionByteEndpoint(
    allocator: std.mem.Allocator,
    io: ?network_io_module.NetworkIo,
    entries: *std.ArrayList(ProductionNetworkEntry),
    options: ProductionEndpointOptions,
) ProductionByteEndpointError!ByteEndpoint {
    try validateProductionEndpointOptions(options);

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.payload_name, production_byte_runtime_name)) {
            const runtime: *ProductionByteRuntime = @ptrCast(@alignCast(entry.ptr));
            return runtime.handle(options.self);
        }
    }

    const runtime = try ProductionByteRuntime.init(allocator, default_byte_pool_options, io, options);
    errdefer runtime.deinit();

    try entries.append(allocator, .{
        .payload_name = production_byte_runtime_name,
        .ptr = runtime,
        .teardown = .{ .ptr = runtime, .deinit = ProductionByteRuntime.deinitOpaque },
    });

    return runtime.handle(options.self);
}

fn validateProductionEndpointOptions(options: ProductionEndpointOptions) ProductionNetworkError!void {
    if (options.peers.len == 0) return error.ProductionTopologyEmpty;

    var found_self = false;
    for (options.peers, 0..) |peer, index| {
        if (peer.id == options.self) found_self = true;

        for (options.peers[0..index]) |previous| {
            if (previous.id == peer.id) return error.ProductionTopologyDuplicatePeer;
        }
    }

    if (!found_self) return error.ProductionTopologyMissingSelf;
}

fn ProductionRuntime(comptime Payload: type) type {
    const Handle = Endpoint(Payload);
    const Envelope = Handle.Envelope;

    const Packet = struct {
        id: u64,
        from: NodeId,
        to: NodeId,
        deliver_at: clock_module.Timestamp,
        payload: Payload,
    };

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        queue: std.ArrayList(Packet) = .empty,
        next_packet_id: u64 = 0,

        // FIXME(roadmap item 15): this typed production runtime is still an
        // in-process FIFO. The byte endpoint has the socket-backed path; typed
        // payloads need either codec-backed sockets or a clear parity-only label.
        fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Self {
            const runtime = try allocator.create(Self);
            runtime.* = .{ .allocator = allocator };
            return runtime;
        }

        fn handle(self: *Self, node: NodeId) Handle {
            return .{ .ptr = self, .self_node = node, .vtable = &vtable };
        }

        fn send(self: *Self, from: NodeId, to: NodeId, payload: Payload) !void {
            const packet: Packet = .{
                .id = self.next_packet_id,
                .from = from,
                .to = to,
                .deliver_at = 0,
                .payload = payload,
            };
            self.next_packet_id += 1;
            try self.queue.append(self.allocator, packet);
        }

        fn receive(self: *Self, node: NodeId) !?Envelope {
            for (self.queue.items, 0..) |packet, index| {
                if (packet.to != node) continue;
                const ready = self.queue.orderedRemove(index);
                return .{
                    .from = ready.from,
                    .message = ready.payload,
                };
            }
            return null;
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
            const allocator = self.allocator;
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn deinitOpaque(ptr: *anyopaque, _: std.mem.Allocator) void {
            fromOpaque(ptr).deinit();
        }

        fn fromOpaque(ptr: *anyopaque) *Self {
            return @ptrCast(@alignCast(ptr));
        }

        fn vtableSend(ptr: *anyopaque, from: NodeId, to: NodeId, payload: Payload) anyerror!void {
            try fromOpaque(ptr).send(from, to, payload);
        }

        fn vtableReceive(ptr: *anyopaque, node: NodeId) anyerror!?Envelope {
            return try fromOpaque(ptr).receive(node);
        }

        const vtable: Handle.VTable = .{
            .send = vtableSend,
            .receive = vtableReceive,
        };
    };
}

const ProductionByteRuntime = struct {
    const Self = @This();

    const Packet = struct {
        id: u64,
        from: NodeId,
        to: NodeId,
        payload: ByteEndpoint.Message,
    };

    const SocketPeer = struct {
        id: NodeId,
        address: []u8,
    };

    const Outbound = struct {
        peer: NodeId,
        connection: network_io_module.Connection,
    };

    const Mode = union(enum) {
        fifo: Fifo,
        socket: Socket,
    };

    const Fifo = struct {
        queue: std.ArrayList(Packet) = .empty,
        next_packet_id: u64 = 0,
    };

    const Socket = struct {
        io: network_io_module.NetworkIo,
        self: NodeId,
        peers: []SocketPeer,
        listener: ?network_io_module.Listener,
        inbound: ?network_io_module.Connection = null,
        outbound: ?Outbound = null,
    };

    allocator: std.mem.Allocator,
    pool: message_pool_module.Pool,
    mode: Mode,

    fn init(
        allocator: std.mem.Allocator,
        pool_options: message_pool_module.Options,
        io: ?network_io_module.NetworkIo,
        options: ProductionEndpointOptions,
    ) !*Self {
        const runtime = try allocator.create(Self);
        errdefer allocator.destroy(runtime);

        var pool = try message_pool_module.Pool.init(allocator, pool_options);
        var pool_moved = false;
        errdefer if (!pool_moved) pool.deinit();

        if (options.listen) |listen_address| {
            const network_io = io orelse return error.NetworkUnavailable;
            var socket = try initSocket(allocator, network_io, options, listen_address);
            errdefer deinitSocket(allocator, &socket);

            runtime.* = .{
                .allocator = allocator,
                .pool = pool,
                .mode = .{ .socket = socket },
            };
        } else {
            runtime.* = .{
                .allocator = allocator,
                .pool = pool,
                .mode = .{ .fifo = .{} },
            };
        }
        pool_moved = true;
        return runtime;
    }

    fn handle(self: *Self, node: NodeId) ByteEndpoint {
        return .{ .ptr = self, .self_node = node, .vtable = &vtable };
    }

    fn acquire(self: *Self, len: usize) !ByteEndpoint.Message {
        return try self.pool.acquire(len);
    }

    fn sendBytes(self: *Self, from: NodeId, to: NodeId, bytes: []const u8) !void {
        const message = try self.acquire(bytes.len);
        var sent = false;
        defer if (!sent) message.release();

        @memcpy(message.bytes(), bytes);
        try self.sendMessage(from, to, message);
        sent = true;
    }

    fn sendMessage(self: *Self, from: NodeId, to: NodeId, message: ByteEndpoint.Message) !void {
        switch (self.mode) {
            .fifo => |*fifo| try self.sendFifo(fifo, from, to, message),
            .socket => |*socket| try self.sendSocket(socket, from, to, message),
        }
    }

    fn receive(self: *Self, node: NodeId) !?ByteEndpoint.Envelope {
        return switch (self.mode) {
            .fifo => |*fifo| self.receiveFifo(fifo, node),
            .socket => |*socket| try self.receiveSocket(socket, node),
        };
    }

    fn sendFifo(self: *Self, fifo: *Fifo, from: NodeId, to: NodeId, message: ByteEndpoint.Message) !void {
        const packet: Packet = .{
            .id = fifo.next_packet_id,
            .from = from,
            .to = to,
            .payload = message,
        };
        fifo.next_packet_id += 1;
        try fifo.queue.append(self.allocator, packet);
    }

    fn receiveFifo(_: *Self, fifo: *Fifo, node: NodeId) ?ByteEndpoint.Envelope {
        for (fifo.queue.items, 0..) |packet, index| {
            if (packet.to != node) continue;
            const ready = fifo.queue.orderedRemove(index);
            return .{
                .from = ready.from,
                .message = ready.payload,
            };
        }
        return null;
    }

    fn sendSocket(self: *Self, socket: *Socket, from: NodeId, to: NodeId, message: ByteEndpoint.Message) !void {
        std.debug.assert(from == socket.self);

        const connection = try outboundConnection(socket, to);
        const frame_len = try network_transport_module.frameLen(message.bytes().len);
        const scratch = try self.allocator.alloc(u8, frame_len);
        defer self.allocator.free(scratch);

        var sent = false;
        defer if (sent) message.release();

        try network_transport_module.sendFrame(connection, scratch, from, to, message.bytes());
        sent = true;
    }

    fn receiveSocket(self: *Self, socket: *Socket, node: NodeId) !?ByteEndpoint.Envelope {
        std.debug.assert(node == socket.self);

        const connection = try self.inboundConnection(socket);
        const received = try network_transport_module.receiveFrame(connection, &self.pool);
        if (received.to != node) {
            received.message.release();
            return null;
        }

        return .{
            .from = received.from,
            .message = received.message,
        };
    }

    fn outboundConnection(socket: *Socket, to: NodeId) !network_io_module.Connection {
        if (socket.outbound) |outbound| {
            if (outbound.peer == to) return outbound.connection;
            outbound.connection.close();
            socket.outbound = null;
        }

        const address = peerAddress(socket, to) orelse return error.AddressNotFound;
        const connection = try socket.io.connect(address);
        socket.outbound = .{ .peer = to, .connection = connection };
        return connection;
    }

    fn inboundConnection(_: *Self, socket: *Socket) !network_io_module.Connection {
        if (socket.inbound) |connection| return connection;
        const listener = socket.listener orelse return error.ConnectionClosed;
        const connection = (try listener.accept()) orelse return error.ConnectionClosed;
        socket.inbound = connection;
        return connection;
    }

    pub fn deinit(self: *Self) void {
        switch (self.mode) {
            .fifo => |*fifo| deinitFifo(self.allocator, fifo),
            .socket => |*socket| deinitSocket(self.allocator, socket),
        }
        self.pool.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn initSocket(
        allocator: std.mem.Allocator,
        io: network_io_module.NetworkIo,
        options: ProductionEndpointOptions,
        listen_address: []const u8,
    ) !Socket {
        const peers = try allocator.alloc(SocketPeer, options.peers.len);
        var copied: usize = 0;
        errdefer {
            for (peers[0..copied]) |peer| allocator.free(peer.address);
            allocator.free(peers);
        }

        for (options.peers, 0..) |peer, index| {
            peers[index] = .{
                .id = peer.id,
                .address = try allocator.dupe(u8, peer.address),
            };
            copied += 1;
        }

        const listener = try io.listen(listen_address);
        errdefer listener.close();

        return .{
            .io = io,
            .self = options.self,
            .peers = peers,
            .listener = listener,
        };
    }

    fn deinitFifo(allocator: std.mem.Allocator, fifo: *Fifo) void {
        for (fifo.queue.items) |packet| packet.payload.release();
        fifo.queue.deinit(allocator);
    }

    fn deinitSocket(allocator: std.mem.Allocator, socket: *Socket) void {
        if (socket.outbound) |outbound| outbound.connection.close();
        if (socket.inbound) |connection| connection.close();
        if (socket.listener) |listener| listener.close();
        for (socket.peers) |peer| allocator.free(peer.address);
        allocator.free(socket.peers);
    }

    fn peerAddress(socket: *const Socket, id: NodeId) ?[]const u8 {
        for (socket.peers) |peer| {
            if (peer.id == id) return peer.address;
        }
        return null;
    }

    pub fn deinitOpaque(ptr: *anyopaque, _: std.mem.Allocator) void {
        fromOpaque(ptr).deinit();
    }

    fn fromOpaque(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    fn vtableAcquire(ptr: *anyopaque, len: usize) anyerror!ByteEndpoint.Message {
        return try fromOpaque(ptr).acquire(len);
    }

    fn vtableSendBytes(ptr: *anyopaque, from: NodeId, to: NodeId, bytes: []const u8) anyerror!void {
        try fromOpaque(ptr).sendBytes(from, to, bytes);
    }

    fn vtableSendMessage(ptr: *anyopaque, from: NodeId, to: NodeId, message: ByteEndpoint.Message) anyerror!void {
        try fromOpaque(ptr).sendMessage(from, to, message);
    }

    fn vtableReceive(ptr: *anyopaque, node: NodeId) anyerror!?ByteEndpoint.Envelope {
        return try fromOpaque(ptr).receive(node);
    }

    const vtable: ByteEndpoint.VTable = .{
        .acquire = vtableAcquire,
        .send_bytes = vtableSendBytes,
        .send_message = vtableSendMessage,
        .receive = vtableReceive,
    };
};
