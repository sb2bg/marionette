//! Ownership-safe convenience transport over byte endpoints.

const endpoint_module = @import("endpoint.zig");
const ByteEndpoint = endpoint_module.ByteEndpoint;
const NodeId = @import("types.zig").NodeId;

/// Convenience wrapper for protocol adapters built on top of `ByteEndpoint`.
///
/// Adapter authors can use this instead of touching pool messages directly:
/// received messages have `deinit`, borrowed sends copy bytes, and builders
/// transfer an acquired buffer on successful send.
pub const ByteTransport = struct {
    endpoint: ByteEndpoint,

    pub const Received = struct {
        from_node: NodeId,
        message: ByteEndpoint.Message,

        pub fn from(self: Received) NodeId {
            return self.from_node;
        }

        pub fn bytes(self: Received) []const u8 {
            return self.message.bytes();
        }

        pub fn deinit(self: *Received) void {
            self.message.release();
            self.* = undefined;
        }
    };

    pub const Builder = struct {
        endpoint: ByteEndpoint,
        message: ByteEndpoint.Message,
        sent: bool = false,

        pub fn bytes(self: Builder) []u8 {
            return self.message.bytes();
        }

        pub fn send(self: *Builder, to: NodeId) !void {
            try self.endpoint.sendMessage(to, self.message);
            self.sent = true;
        }

        pub fn deinit(self: *Builder) void {
            if (!self.sent) self.message.release();
            self.* = undefined;
        }
    };

    pub fn init(endpoint: ByteEndpoint) ByteTransport {
        return .{ .endpoint = endpoint };
    }

    pub fn node(self: ByteTransport) NodeId {
        return self.endpoint.node();
    }

    pub fn send(self: ByteTransport, to: NodeId, bytes: []const u8) !void {
        try self.endpoint.send(to, bytes);
    }

    pub fn receive(self: ByteTransport) !?Received {
        const envelope = (try self.endpoint.receive()) orelse return null;
        return .{
            .from_node = envelope.from,
            .message = envelope.message,
        };
    }

    pub fn acquire(self: ByteTransport, len: usize) !Builder {
        return .{
            .endpoint = self.endpoint,
            .message = try self.endpoint.acquire(len),
        };
    }
};
