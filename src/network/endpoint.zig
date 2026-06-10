//! App-facing typed and byte endpoint handles.

const message_pool_module = @import("../message_pool.zig");
const NodeId = @import("types.zig").NodeId;

/// Typed app-facing process endpoint.
pub fn Endpoint(comptime Message: type) type {
    return struct {
        const Self = @This();

        ptr: *anyopaque,
        self_node: NodeId,
        vtable: *const VTable,

        pub const Envelope = struct {
            from: NodeId,
            message: Message,
        };

        pub const VTable = struct {
            send: *const fn (*anyopaque, NodeId, NodeId, Message) anyerror!void,
            receive: *const fn (*anyopaque, NodeId) anyerror!?Envelope,
        };

        pub fn node(self: Self) NodeId {
            return self.self_node;
        }

        pub fn send(self: Self, to: NodeId, message: Message) !void {
            try self.vtable.send(self.ptr, self.self_node, to, message);
        }

        pub fn receive(self: Self) !?Envelope {
            return try self.vtable.receive(self.ptr, self.self_node);
        }
    };
}

/// App-facing byte endpoint with explicit message ownership.
pub const ByteEndpoint = struct {
    ptr: *anyopaque,
    self_node: NodeId,
    vtable: *const VTable,

    pub const Message = message_pool_module.Message;

    pub const Envelope = struct {
        from: NodeId,
        message: Message,
    };

    pub const VTable = struct {
        acquire: *const fn (*anyopaque, usize) anyerror!Message,
        send_bytes: *const fn (*anyopaque, NodeId, NodeId, []const u8) anyerror!void,
        send_message: *const fn (*anyopaque, NodeId, NodeId, Message) anyerror!void,
        receive: *const fn (*anyopaque, NodeId) anyerror!?Envelope,
    };

    pub fn node(self: ByteEndpoint) NodeId {
        return self.self_node;
    }

    /// Acquire an owned message buffer from this endpoint's runtime pool.
    pub fn acquire(self: ByteEndpoint, len: usize) !Message {
        return try self.vtable.acquire(self.ptr, len);
    }

    /// Copy borrowed bytes into the endpoint runtime before enqueueing.
    pub fn send(self: ByteEndpoint, to: NodeId, bytes: []const u8) !void {
        try self.vtable.send_bytes(self.ptr, self.self_node, to, bytes);
    }

    /// Enqueue an acquired message without copying.
    ///
    /// On success the endpoint runtime owns `message`; on error the caller
    /// still owns it and must release it.
    pub fn sendMessage(self: ByteEndpoint, to: NodeId, message: Message) !void {
        try self.vtable.send_message(self.ptr, self.self_node, to, message);
    }

    /// Return the next message for this endpoint. The caller owns the returned
    /// message and must release it.
    pub fn receive(self: ByteEndpoint) !?Envelope {
        return try self.vtable.receive(self.ptr, self.self_node);
    }
};
