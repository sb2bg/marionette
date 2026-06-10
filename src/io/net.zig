//! `std.Io.net` stream operations backed by Marionette network faults.

const std = @import("std");

const errors = @import("errors.zig");
const network_module = @import("../network/root.zig");
const Io = std.Io;
const SocketHandle = Io.net.Socket.Handle;
const stream_frame_handle_size = @sizeOf(u64);

pub fn Ops(comptime Backend: type) type {
    return struct {
        fn backendFromUserdata(userdata: ?*anyopaque) *Backend {
            return @ptrCast(@alignCast(userdata.?));
        }

        /// Append a writev-style payload to `list`: the header, then each data
        /// slice, then `splat` repetitions of the final slice. Mirrors std.Io's
        /// scatter/splat write encoding.
        fn appendWritevPayload(
            backend: *Backend,
            list: *std.ArrayList(u8),
            header: []const u8,
            data: []const []const u8,
            splat: usize,
        ) error{SystemResources}!void {
            list.appendSlice(backend.allocator, header) catch return error.SystemResources;
            if (data.len > 0) {
                for (data[0 .. data.len - 1]) |bytes| {
                    list.appendSlice(backend.allocator, bytes) catch return error.SystemResources;
                }
                const pattern = data[data.len - 1];
                for (0..splat) |_| {
                    list.appendSlice(backend.allocator, pattern) catch return error.SystemResources;
                }
            }
        }

        fn appendStreamFrame(
            backend: *Backend,
            frame: *std.ArrayList(u8),
            target: SocketHandle,
            header: []const u8,
            data: []const []const u8,
            splat: usize,
        ) Io.net.Stream.Writer.Error!usize {
            frame.appendNTimes(backend.allocator, 0, stream_frame_handle_size) catch return error.SystemResources;
            std.mem.writeInt(u64, frame.items[0..stream_frame_handle_size], @intCast(target), .little);

            try appendWritevPayload(backend, frame, header, data, splat);
            return frame.items.len - stream_frame_handle_size;
        }

        fn drainNetworkReady(backend: *Backend, node: network_module.NodeId) Io.net.Stream.Reader.Error!void {
            while (true) {
                const event = network_module.receiveReadyStreamEventFromControl(backend.network_control, node) catch |err| {
                    return errors.mapNetworkReadError(err);
                } orelse return;

                switch (event) {
                    .delivered => |envelope| {
                        defer envelope.message.release();

                        const bytes = envelope.message.bytes();
                        if (bytes.len < stream_frame_handle_size) continue;

                        const target_raw = std.mem.readInt(u64, bytes[0..stream_frame_handle_size], .little);
                        const target_handle = std.math.cast(SocketHandle, target_raw) orelse continue;
                        const target = backend.connection(target_handle) orelse continue;
                        if (target.closed) continue;

                        target.inbox.appendSlice(backend.allocator, bytes[stream_frame_handle_size..]) catch return error.SystemResources;
                        backend.world.record(
                            "io.net.deliver from={} to={} handle={} len={}",
                            .{ envelope.from, node, target_handle, bytes.len - stream_frame_handle_size },
                        ) catch return error.SystemResources;

                        backend.wakeConnection(target_handle, 1);
                    },
                    .dropped => |dropped| {
                        defer dropped.message.release();

                        const bytes = dropped.message.bytes();
                        if (bytes.len < stream_frame_handle_size) continue;

                        const target_raw = std.mem.readInt(u64, bytes[0..stream_frame_handle_size], .little);
                        const target_handle = std.math.cast(SocketHandle, target_raw) orelse continue;
                        const target = backend.connection(target_handle) orelse continue;
                        if (target.closed) continue;

                        const read_error: Io.net.Stream.Reader.Error = switch (dropped.reason) {
                            .destination_down => error.NetworkDown,
                            .link_disabled => error.Timeout,
                        };
                        if (target.read_error == null) target.read_error = read_error;
                        backend.world.record(
                            "io.net.delivery_error from={} to={} handle={} reason={s} error={s}",
                            .{ dropped.from, dropped.to, target_handle, @tagName(dropped.reason), @errorName(read_error) },
                        ) catch return error.SystemResources;

                        backend.wakeConnection(target_handle, 1);
                    },
                }
            }
        }

        fn nextNetworkDeliveryAt(backend: *Backend, node: network_module.NodeId) Io.net.Stream.Reader.Error!?u64 {
            return network_module.nextStreamDeliveryAtForControl(backend.network_control, node) catch |err| {
                return errors.mapNetworkReadError(err);
            };
        }
        pub fn simNetListenIp(
            userdata: ?*anyopaque,
            address: *const Io.net.IpAddress,
            options: Io.net.IpAddress.ListenOptions,
        ) Io.net.IpAddress.ListenError!Io.net.Socket {
            if (options.mode != .stream) return error.SocketModeUnsupported;
            if (options.protocol != .tcp) return error.ProtocolUnsupportedBySystem;

            const backend = backendFromUserdata(userdata);
            if (backend.findOpenListener(address) != null) return error.AddressInUse;

            const node = backend.allocateNetworkNode() catch return error.NetworkDown;
            const listener = backend.allocator.create(Backend.ListenerState) catch return error.SystemResources;
            errdefer backend.allocator.destroy(listener);
            listener.* = .{ .address = address.*, .node = node };
            errdefer listener.pending.deinit(backend.allocator);

            const handle = backend.createHandle(.{ .listener = listener }) catch return error.SystemResources;
            return .{
                .handle = handle,
                .address = address.*,
            };
        }

        pub fn simNetConnectIp(
            userdata: ?*anyopaque,
            address: *const Io.net.IpAddress,
            options: Io.net.IpAddress.ConnectOptions,
        ) Io.net.IpAddress.ConnectError!Io.net.Socket {
            if (options.mode != .stream) return error.SocketModeUnsupported;
            if (options.protocol) |protocol| {
                if (protocol != .tcp) return error.ProtocolUnsupportedBySystem;
            }

            const backend = backendFromUserdata(userdata);
            const listener_entry = backend.findOpenListener(address) orelse return error.ConnectionRefused;
            const listener = listener_entry.state.listener;
            const client_node = backend.allocateNetworkNode() catch return error.NetworkDown;

            const client = backend.allocator.create(Backend.ConnectionState) catch return error.SystemResources;
            errdefer backend.allocator.destroy(client);
            client.* = .{ .address = address.*, .node = client_node };
            errdefer client.inbox.deinit(backend.allocator);

            const server = backend.allocator.create(Backend.ConnectionState) catch return error.SystemResources;
            errdefer backend.allocator.destroy(server);
            server.* = .{ .address = listener.address, .node = listener.node };
            errdefer server.inbox.deinit(backend.allocator);

            const client_handle = backend.createHandle(.{ .connection = client }) catch return error.SystemResources;
            errdefer _ = backend.handles.pop();
            const server_handle = backend.createHandle(.{ .connection = server }) catch return error.SystemResources;
            errdefer _ = backend.handles.pop();

            client.peer = server_handle;
            server.peer = client_handle;

            listener.pending.append(backend.allocator, server_handle) catch return error.SystemResources;
            backend.wakeListener(listener_entry.handle, 1);
            return .{
                .handle = client_handle,
                .address = address.*,
            };
        }

        pub fn simNetAccept(
            userdata: ?*anyopaque,
            server: SocketHandle,
            options: Io.net.Server.AcceptOptions,
        ) Io.net.Server.AcceptError!Io.net.Socket {
            _ = options;

            const backend = backendFromUserdata(userdata);
            const state = backend.listener(server) orelse return error.SocketNotListening;
            if (state.closed) return error.SocketNotListening;
            while (state.pending.items.len == 0) {
                const wait_set = backend.futex_wait_set orelse return error.WouldBlock;
                switch (wait_set.blockUntil(backend.listenerWaitKey(server), null)) {
                    .woken => {},
                    .timed_out => unreachable,
                }
                if (state.closed) return error.SocketNotListening;
            }

            const handle = state.pending.orderedRemove(0);
            return .{
                .handle = handle,
                .address = state.address,
            };
        }

        pub fn simNetRead(userdata: ?*anyopaque, src: SocketHandle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
            const backend = backendFromUserdata(userdata);
            const connection = backend.connection(src) orelse return error.SocketUnconnected;
            if (connection.closed) return error.SocketUnconnected;
            if (connection.node) |node| try drainNetworkReady(backend, node);
            while (connection.inbox.items.len == 0) {
                const deadline_ns = if (connection.node) |node| try nextNetworkDeliveryAt(backend, node) else null;
                if (connection.read_error) |err| {
                    connection.read_error = null;
                    return err;
                }
                const peer_closed = if (connection.peer) |peer_handle|
                    if (backend.connection(peer_handle)) |peer| peer.closed else true
                else
                    true;
                if (peer_closed and deadline_ns == null) return 0;
                const wait_set = backend.futex_wait_set orelse return error.Timeout;
                switch (wait_set.blockUntil(backend.connectionWaitKey(src), deadline_ns)) {
                    .woken => {},
                    .timed_out => {},
                }
                if (connection.closed) return error.SocketUnconnected;
                if (connection.node) |node| try drainNetworkReady(backend, node);
            }

            var total_read: usize = 0;
            for (data) |buffer| {
                if (buffer.len == 0) continue;
                const read_count = @min(buffer.len, connection.inbox.items.len - total_read);
                @memcpy(buffer[0..read_count], connection.inbox.items[total_read..][0..read_count]);
                total_read += read_count;
                if (total_read == connection.inbox.items.len) break;
            }

            connection.inbox.replaceRangeAssumeCapacity(0, total_read, &.{});
            return total_read;
        }

        pub fn simNetWrite(
            userdata: ?*anyopaque,
            dest: SocketHandle,
            header: []const u8,
            data: []const []const u8,
            splat: usize,
        ) Io.net.Stream.Writer.Error!usize {
            const backend = backendFromUserdata(userdata);
            const connection = backend.connection(dest) orelse return error.SocketUnconnected;
            if (connection.closed) return error.SocketUnconnected;
            const peer_handle = connection.peer orelse return error.SocketUnconnected;
            const peer = backend.connection(peer_handle) orelse return error.ConnectionResetByPeer;
            if (peer.closed) return error.ConnectionResetByPeer;

            if (connection.node) |from_node| {
                if (peer.node) |to_node| {
                    var frame: std.ArrayList(u8) = .empty;
                    defer frame.deinit(backend.allocator);

                    const payload_len = try appendStreamFrame(backend, &frame, peer_handle, header, data, splat);
                    if (payload_len == 0) return 0;

                    const send_result = network_module.sendStreamBytesFromControl(
                        backend.network_control,
                        from_node,
                        to_node,
                        frame.items,
                        connection.delivery_floor_ns,
                    ) catch |err| return errors.mapNetworkWriteError(err);

                    switch (send_result) {
                        .queued => |deliver_at| {
                            connection.delivery_floor_ns = deliver_at;
                            backend.wakeConnection(peer_handle, 1);
                        },
                        .dropped => {
                            if (peer.read_error == null) peer.read_error = error.Timeout;
                            backend.wakeConnection(peer_handle, 1);
                        },
                    }
                    return payload_len;
                }
            }

            const start_len = peer.inbox.items.len;
            errdefer peer.inbox.shrinkRetainingCapacity(start_len);

            try appendWritevPayload(backend, &peer.inbox, header, data, splat);
            backend.wakeConnection(peer_handle, 1);
            return peer.inbox.items.len - start_len;
        }

        pub fn simNetClose(userdata: ?*anyopaque, handles: []const SocketHandle) void {
            const backend = backendFromUserdata(userdata);
            for (handles) |handle| {
                const entry = backend.findEntry(handle) orelse continue;
                switch (entry.state) {
                    .listener => |listener| {
                        listener.closed = true;
                        backend.wakeListener(handle, std.math.maxInt(usize));
                    },
                    .connection => |connection| {
                        connection.closed = true;
                        backend.wakeConnection(handle, std.math.maxInt(usize));
                        if (connection.peer) |peer_handle| {
                            backend.wakeConnection(peer_handle, std.math.maxInt(usize));
                        }
                    },
                    .file => |file| file.closed = true,
                }
            }
        }

        pub fn simNetShutdown(userdata: ?*anyopaque, handle: SocketHandle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
            _ = how;
            simNetClose(userdata, (&handle)[0..1]);
        }
    };
}
