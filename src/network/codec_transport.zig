//! Typed codec transport layered over byte endpoints.

const std = @import("std");

const codec_module = @import("../codec.zig");
const ByteTransport = @import("byte_transport.zig").ByteTransport;
const types = @import("types.zig");

pub const CodecRecvLifetime = codec_module.RecvLifetime;
pub const default_codec_encode_buffer_size = types.default_byte_pool_options.buffer_size;
const NodeId = types.NodeId;

/// Typed transport facade backed by a `ByteTransport` and a user-supplied codec.
///
/// `Codec` declares `Send`, `Recv`, `recv_lifetime`, `encode`, and `decode`.
/// Optional declarations:
///
/// - `encodedLen(value) !usize`: enables direct encoding into the byte pool.
/// - `deinitRecv(value)`: releases owned decoded values.
/// - `cloneRecv(allocator, value)`: lets `Received.take` escape borrowed values.
/// - `deinitTaken(allocator, value)`: releases values returned by `take`.
pub fn CodecTransport(comptime Codec: type) type {
    comptime validateCodec(Codec);

    return struct {
        transport: ByteTransport,

        const Self = @This();

        pub const Send = Codec.Send;
        pub const Recv = Codec.Recv;
        pub const recv_lifetime: CodecRecvLifetime = Codec.recv_lifetime;
        pub const TakenRecv = if (@hasDecl(Codec, "TakenRecv"))
            Codec.TakenRecv
        else if (@hasDecl(Codec, "cloneRecv"))
            errorUnionPayload(@typeInfo(@TypeOf(Codec.cloneRecv)).@"fn".return_type.?)
        else
            Recv;

        pub const Received = struct {
            raw: ByteTransport.Received,
            decoded: Recv,
            taken: bool = false,

            pub fn from(self: Received) NodeId {
                return self.raw.from();
            }

            pub fn value(self: Received) Recv {
                return self.decoded;
            }

            pub fn deinit(self: *Received) void {
                if (!self.taken and recv_lifetime == .owned) deinitRecv(self.decoded);
                self.raw.deinit();
                self.* = undefined;
            }

            /// Return a value that can outlive this received handle.
            ///
            /// For owned codecs this transfers the decoded value out of the
            /// handle. For borrowed codecs the codec must provide `cloneRecv`.
            pub fn take(self: *Received, allocator: std.mem.Allocator) !TakenRecv {
                switch (recv_lifetime) {
                    .owned => {
                        self.taken = true;
                        return self.decoded;
                    },
                    .borrowed => {
                        if (!@hasDecl(Codec, "cloneRecv")) {
                            @compileError("borrowed codec must provide cloneRecv to support Received.take");
                        }
                        return try Codec.cloneRecv(allocator, self.decoded);
                    },
                }
            }
        };

        pub fn init(transport: ByteTransport) Self {
            return .{ .transport = transport };
        }

        pub fn node(self: Self) NodeId {
            return self.transport.node();
        }

        pub fn send(self: Self, to: NodeId, value: Send) !void {
            if (@hasDecl(Codec, "encodedLen")) {
                const len = try Codec.encodedLen(value);
                var builder = try self.transport.acquire(len);
                defer builder.deinit();

                const encoded = try Codec.encode(builder.bytes(), value);
                if (encoded.ptr != builder.bytes().ptr or encoded.len != len) {
                    return error.InvalidEncodedLength;
                }

                try builder.send(to);
            } else {
                var buffer: [default_codec_encode_buffer_size]u8 = undefined;
                const encoded = try Codec.encode(&buffer, value);
                try self.transport.send(to, encoded);
            }
        }

        pub fn receive(self: Self) !?Received {
            var raw = (try self.transport.receive()) orelse return null;
            errdefer raw.deinit();

            return .{
                .raw = raw,
                .decoded = try Codec.decode(raw.bytes()),
            };
        }

        /// Receive one message and invoke `handler(context, from, value)`.
        ///
        /// The decoded value is only valid for the duration of the handler when
        /// the codec's receive lifetime is `.borrowed`.
        pub fn handleNext(self: Self, context: anytype, comptime handler: anytype) !bool {
            var received = (try self.receive()) orelse return false;
            defer received.deinit();

            try handler(context, received.from(), received.value());
            return true;
        }

        pub fn deinitTaken(allocator: std.mem.Allocator, value: TakenRecv) void {
            if (@hasDecl(Codec, "deinitTaken")) {
                Codec.deinitTaken(allocator, value);
            } else if (recv_lifetime == .owned and @hasDecl(Codec, "deinitRecv")) {
                Codec.deinitRecv(value);
            }
        }

        fn deinitRecv(value: Recv) void {
            if (@hasDecl(Codec, "deinitRecv")) Codec.deinitRecv(value);
        }
    };
}

fn validateCodec(comptime Codec: type) void {
    if (!@hasDecl(Codec, "Send")) @compileError("CodecTransport codec must declare Send");
    if (!@hasDecl(Codec, "Recv")) @compileError("CodecTransport codec must declare Recv");
    if (!@hasDecl(Codec, "recv_lifetime")) @compileError("CodecTransport codec must declare recv_lifetime");
    if (!@hasDecl(Codec, "encode")) @compileError("CodecTransport codec must declare encode");
    if (!@hasDecl(Codec, "decode")) @compileError("CodecTransport codec must declare decode");

    const lifetime: CodecRecvLifetime = Codec.recv_lifetime;
    _ = lifetime;
}

fn errorUnionPayload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |info| info.payload,
        else => T,
    };
}
