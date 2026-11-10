//! App-facing typed endpoint handle.

const NodeId = @import("types.zig").NodeId;

/// Whether `T` holds a pointer or slice anywhere in its value. Function
/// pointers name static code and are allowed.
pub fn containsBorrowedMemory(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| @typeInfo(pointer.child) != .@"fn",
        .array => |array| containsBorrowedMemory(array.child),
        .vector => |vector| containsBorrowedMemory(vector.child),
        .optional => |optional| containsBorrowedMemory(optional.child),
        .error_union => |error_union| containsBorrowedMemory(error_union.payload),
        .@"struct" => |info| inline for (info.field_types) |field_type| {
            if (containsBorrowedMemory(field_type)) break true;
        } else false,
        .@"union" => |info| inline for (info.field_types) |field_type| {
            if (containsBorrowedMemory(field_type)) break true;
        } else false,
        .@"opaque", .frame, .@"anyframe" => true,
        else => false,
    };
}

/// Reject borrowed-memory payloads unless the caller opted in explicitly.
pub fn requireValuePayload(comptime Message: type) void {
    if (comptime containsBorrowedMemory(Message)) @compileError(
        "Endpoint(" ++ @typeName(Message) ++ ") payloads are copied by value and must not contain " ++
            "pointers or slices; encode the data into the message, or opt in with " ++
            "sim.borrowedEndpoint when the referenced storage outlives the simulation and stays immutable",
    );
}

/// Experimental typed, simulation-only process endpoint.
///
/// Delivery contract: each `send` is delivered at most once, never
/// duplicated, to `to`'s endpoint for the same `Message` type. A message can be
/// lost at send (configured loss, a down source) or when it becomes due (a
/// down destination, a disabled link, a dropping or rejecting fault); every
/// loss records `network.drop` with its reason. Ready messages are delivered
/// in order of delivery time, then send order, so latency can reorder
/// messages on different paths but never on one path. Clogs and holding
/// faults delay without dropping. A full directed path returns
/// `error.EventQueueFull` from `send`; there is no other backpressure.
///
/// Ownership contract: `send` copies `Message` by value into the queue, and
/// the receiver owns its copy. Marionette does not serialize, deep-copy, or
/// manage referenced storage, so `sim.endpoint` rejects at compile time any
/// `Message` that contains pointers or slices. `sim.borrowedEndpoint` is the
/// explicit opt-in for borrowed memory, whose storage must remain valid and
/// immutable for the simulation lifetime.
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
            poll: *const fn (*anyopaque, NodeId) anyerror!?Envelope,
            await_delivery: *const fn (*anyopaque, NodeId) anyerror!?Envelope,
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

        /// Return one message ready for this endpoint now, or null. Never
        /// advances virtual time; the harness or a sleeping task moves time.
        pub fn poll(self: Self) !?Envelope {
            return try self.vtable.poll(self.ptr, self.self_node);
        }

        /// Advance virtual time to this endpoint's next pending delivery and
        /// return it. Returns null, without advancing, when nothing is in
        /// flight to this endpoint. A harness-driver operation: it moves the
        /// clock explicitly, so tasks should poll and sleep instead.
        pub fn awaitDelivery(self: Self) !?Envelope {
            return try self.vtable.await_delivery(self.ptr, self.self_node);
        }

        /// Deprecated; removed in 0.10. Use `poll`, or `awaitDelivery` to move
        /// time explicitly. When none is ready, this may advance virtual time
        /// to the earliest delivery anywhere on this `Message` bus, and `null`
        /// means only that nothing for this endpoint was ready at that
        /// boundary.
        pub fn receive(self: Self) !?Envelope {
            return try self.vtable.receive(self.ptr, self.self_node);
        }
    };
}
