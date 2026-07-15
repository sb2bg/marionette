//! App-facing typed endpoint handle.

const NodeId = @import("types.zig").NodeId;

/// Experimental typed, simulation-only process endpoint.
///
/// `Message` is copied with ordinary Zig value semantics. Marionette does not
/// serialize it, deep-copy referenced storage, or manage pointee lifetimes.
/// Prefer value-only messages. If a message contains pointers or slices, their
/// storage must remain valid and immutable for the simulation lifetime.
///
/// This models protocol-level message delivery. Use simulated `std.Io.net`
/// when the system under test must also exercise its wire format, framing,
/// partial I/O, or connection lifecycle.
pub fn Endpoint(comptime Message: type) type {
    return struct {
        const Self = @This();

        ptr: *anyopaque,
        self_node: NodeId,
        vtable: *const VTable,

        /// One received message and the node that sent it.
        pub const Envelope = struct {
            from: NodeId,
            message: Message,
        };

        pub const VTable = struct {
            send: *const fn (*anyopaque, NodeId, NodeId, Message) anyerror!void,
            receive: *const fn (*anyopaque, NodeId) anyerror!?Envelope,
        };

        /// This endpoint's own node id.
        pub fn node(self: Self) NodeId {
            return self.self_node;
        }

        /// Submit one message to `to` without waiting for delivery.
        ///
        /// Success does not imply that the message was queued or delivered:
        /// simulated loss and a down source silently drop it and record a
        /// trace event. A queued message can still be dropped when received if
        /// its destination is down or its directed link is disabled.
        pub fn send(self: Self, to: NodeId, message: Message) !void {
            try self.vtable.send(self.ptr, self.self_node, to, message);
        }

        /// Return one message delivered to this endpoint.
        ///
        /// When none is ready, simulation may advance to the earliest delivery
        /// anywhere on this `Message` bus. `null` means that no message for this
        /// endpoint is available at that scheduling boundary; it does not mean
        /// the endpoint has no later packet, is closed, or reached EOF.
        pub fn receive(self: Self) !?Envelope {
            return try self.vtable.receive(self.ptr, self.self_node);
        }
    };
}
