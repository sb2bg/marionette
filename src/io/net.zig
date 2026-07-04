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

        /// Deliver an armed cancellation request at a net cancellation point.
        fn takeCancel(backend: *Backend) Io.Cancelable!void {
            const runtime = backend.task_runtime orelse return;
            if (runtime.takeCancelRequest()) return error.Canceled;
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
                const event = network_module.internal.receiveReadyStreamEventFromControl(backend.network_control, node) catch |err| {
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
            return network_module.internal.nextStreamDeliveryAtForControl(backend.network_control, node) catch |err| {
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
            if (backend.findOpenListenerRef(address) != null) return error.AddressInUse;

            const node = backend.allocateNetworkNode() catch return error.NetworkDown;
            const listener = backend.allocator.create(Backend.ListenerState) catch return error.SystemResources;
            errdefer backend.allocator.destroy(listener);
            listener.* = .{ .address = address.*, .node = node };
            errdefer listener.pending.deinit(backend.allocator);

            const handle = backend.createHandle(.{ .listener = listener }) catch return error.SystemResources;
            errdefer _ = backend.handles.pop();
            backend.registerListener(handle, address.*) catch return error.SystemResources;
            return .{
                .handle = handle,
                .address = address.*,
            };
        }

        /// Deterministic host-name lookup for address literals only.
        ///
        /// Resolves IPv4/IPv6 literals and RFC 6761 `localhost` names
        /// without consulting any host state; real DNS, `/etc/hosts`, and
        /// search domains are host behavior and stay explicitly
        /// unsupported (`error.UnknownHostName`). The result protocol
        /// mirrors `std.Io.Threaded.netLookup`: push `.address` results
        /// (plus `.canonical_name` when a buffer is supplied), then close
        /// the queue.
        pub fn simNetLookup(
            userdata: ?*anyopaque,
            host_name: Io.net.HostName,
            resolved: *Io.Queue(Io.net.HostName.LookupResult),
            options: Io.net.HostName.LookupOptions,
        ) Io.net.HostName.LookupError!void {
            const backend = backendFromUserdata(userdata);
            const backend_io = backend.io();
            defer resolved.close(backend_io);
            lookupLiterals(backend, backend_io, host_name, resolved, options) catch |err| switch (err) {
                error.Closed => unreachable, // `resolved` must not be closed until lookup returns
                else => |other| return other,
            };
        }

        const LookupPutError = Io.net.HostName.LookupError || error{Closed};

        fn lookupLiterals(
            backend: *Backend,
            backend_io: Io,
            host_name: Io.net.HostName,
            resolved: *Io.Queue(Io.net.HostName.LookupResult),
            options: Io.net.HostName.LookupOptions,
        ) LookupPutError!void {
            const name = host_name.bytes;

            if (Io.net.IpAddress.parseIp6(name, options.port)) |address| {
                if (options.family == .ip4) return error.UnknownHostName;
                try putLiteral(backend, backend_io, resolved, options, address, name);
                return;
            } else |_| {}

            if (Io.net.IpAddress.parseIp4(name, options.port)) |address| {
                if (options.family == .ip6) return error.UnknownHostName;
                try putLiteral(backend, backend_io, resolved, options, address, name);
                return;
            } else |_| {}

            // RFC 6761 Section 6.3.3: `localhost` names resolve to loopback
            // without consulting DNS. IPv6 loopback goes first, matching
            // the host resolver's ordering; a v6 connect attempt finds no
            // simulated listener and fails cleanly while v4 wins.
            const suffix = if (name.len > 0 and name[name.len - 1] == '.') "localhost." else "localhost";
            if (std.mem.endsWith(u8, name, suffix) and
                (name.len == suffix.len or name[name.len - suffix.len] == '.'))
            {
                var results: [3]Io.net.HostName.LookupResult = undefined;
                var count: usize = 0;
                if (options.family != .ip4) {
                    results[count] = .{ .address = .{ .ip6 = .loopback(options.port) } };
                    count += 1;
                }
                if (options.family != .ip6) {
                    results[count] = .{ .address = .{ .ip4 = .loopback(options.port) } };
                    count += 1;
                }
                if (copyCanonicalName(options.canonical_name_buffer, "localhost")) |canonical| {
                    results[count] = .{ .canonical_name = canonical };
                    count += 1;
                }
                backend.world.record(
                    "io.net.lookup host={s} port={} results={}",
                    .{ name, options.port, count },
                ) catch return error.NameServerFailure;
                try resolved.putAll(backend_io, results[0..count]);
                return;
            }

            return error.UnknownHostName;
        }

        fn putLiteral(
            backend: *Backend,
            backend_io: Io,
            resolved: *Io.Queue(Io.net.HostName.LookupResult),
            options: Io.net.HostName.LookupOptions,
            address: Io.net.IpAddress,
            name: []const u8,
        ) LookupPutError!void {
            backend.world.record(
                "io.net.lookup host={s} port={} results=1",
                .{ name, options.port },
            ) catch return error.NameServerFailure;
            if (copyCanonicalName(options.canonical_name_buffer, name)) |canonical| {
                try resolved.putAll(backend_io, &.{
                    .{ .address = address },
                    .{ .canonical_name = canonical },
                });
            } else {
                try resolved.putOne(backend_io, .{ .address = address });
            }
        }

        fn copyCanonicalName(buffer: ?*[Io.net.HostName.max_len]u8, name: []const u8) ?Io.net.HostName {
            const destination_buffer = buffer orelse return null;
            const destination = destination_buffer[0..name.len];
            @memcpy(destination, name);
            return .{ .bytes = destination };
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
            const listener_ref = backend.findOpenListenerRef(address) orelse return error.ConnectionRefused;
            const listener_backend = listener_ref.backend;
            const listener = listener_ref.state;
            const client_node = backend.allocateNetworkNode() catch return error.NetworkDown;

            const client = backend.allocator.create(Backend.ConnectionState) catch return error.SystemResources;
            errdefer backend.allocator.destroy(client);
            client.* = .{ .address = address.*, .node = client_node };
            errdefer client.inbox.deinit(backend.allocator);

            const server = listener_backend.allocator.create(Backend.ConnectionState) catch return error.SystemResources;
            errdefer listener_backend.allocator.destroy(server);
            server.* = .{ .address = listener.address, .node = listener.node };
            errdefer server.inbox.deinit(listener_backend.allocator);

            const client_handle = backend.createHandle(.{ .connection = client }) catch return error.SystemResources;
            errdefer _ = backend.handles.pop();
            const server_handle = listener_backend.createHandle(.{ .connection = server }) catch return error.SystemResources;
            errdefer _ = listener_backend.handles.pop();

            client.peer = .{ .backend = listener_backend, .handle = server_handle };
            server.peer = .{ .backend = backend, .handle = client_handle };

            listener.pending.append(listener_backend.allocator, server_handle) catch return error.SystemResources;
            listener_backend.wakeListener(listener_ref.handle, 1);
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
            try takeCancel(backend);
            const state = backend.listener(server) orelse return error.SocketNotListening;
            if (state.closed) return error.SocketNotListening;
            while (state.pending.items.len == 0) {
                const wait_set = backend.futex_wait_set orelse return error.WouldBlock;
                state.waiters += 1;
                const wait_result = wait_set.blockUntilCancelable(backend.listenerWaitKey(server), null);
                state.waiters -= 1;
                switch (wait_result) {
                    .woken => {},
                    .timed_out => unreachable,
                    .canceled => {
                        // The listener may have been closed between the
                        // cancel unpark and this task resuming; a closed
                        // handle with no remaining waiters must still retire.
                        if (state.closed) backend.retireClosedNetHandleIfIdle(server);
                        return error.Canceled;
                    },
                }
                if (state.closed) {
                    backend.retireClosedNetHandleIfIdle(server);
                    return error.SocketNotListening;
                }
            }

            const handle = state.pending.orderedRemove(0);
            return .{
                .handle = handle,
                .address = state.address,
            };
        }

        pub fn simNetRead(userdata: ?*anyopaque, src: SocketHandle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
            const backend = backendFromUserdata(userdata);
            try takeCancel(backend);
            const connection = backend.connection(src) orelse return error.SocketUnconnected;
            if (connection.closed) {
                backend.retireClosedNetHandleIfIdle(src);
                return error.SocketUnconnected;
            }
            if (connection.node) |node| try drainNetworkReady(backend, node);
            while (connection.inbox.items.len == 0) {
                const deadline_ns = if (connection.node) |node| try nextNetworkDeliveryAt(backend, node) else null;
                if (connection.read_error) |err| {
                    connection.read_error = null;
                    return err;
                }
                const peer_closed = if (connection.peer) |peer_ref|
                    if (peer_ref.backend.connection(peer_ref.handle)) |peer| peer.closed else true
                else
                    true;
                if (peer_closed and deadline_ns == null) return 0;
                const wait_set = backend.futex_wait_set orelse return error.Timeout;
                connection.waiters += 1;
                const wait_result = wait_set.blockUntilCancelable(backend.connectionWaitKey(src), deadline_ns);
                connection.waiters -= 1;
                switch (wait_result) {
                    .woken => {},
                    .timed_out => {},
                    .canceled => {
                        // Same closed-while-canceled race as the accept park:
                        // never skip retiring a closed idle handle.
                        if (connection.closed) backend.retireClosedNetHandleIfIdle(src);
                        return error.Canceled;
                    },
                }
                if (connection.closed) {
                    backend.retireClosedNetHandleIfIdle(src);
                    return error.SocketUnconnected;
                }
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
            try takeCancel(backend);
            const connection = backend.connection(dest) orelse return error.SocketUnconnected;
            if (connection.closed) return error.SocketUnconnected;
            const peer_ref = connection.peer orelse return error.SocketUnconnected;
            const peer = peer_ref.backend.connection(peer_ref.handle) orelse return error.ConnectionResetByPeer;
            if (peer.closed) return error.ConnectionResetByPeer;

            if (connection.node) |from_node| {
                if (peer.node) |to_node| {
                    var frame: std.ArrayList(u8) = .empty;
                    defer frame.deinit(backend.allocator);

                    const payload_len = try appendStreamFrame(backend, &frame, peer_ref.handle, header, data, splat);
                    if (payload_len == 0) return 0;

                    const send_result = network_module.internal.sendStreamBytesFromControl(
                        backend.network_control,
                        from_node,
                        to_node,
                        frame.items,
                        connection.delivery_floor_ns,
                    ) catch |err| return errors.mapNetworkWriteError(err);

                    switch (send_result) {
                        .queued => |deliver_at| {
                            connection.delivery_floor_ns = deliver_at;
                            peer_ref.backend.wakeConnection(peer_ref.handle, 1);
                        },
                        .dropped => {
                            if (peer.read_error == null) peer.read_error = error.Timeout;
                            peer_ref.backend.wakeConnection(peer_ref.handle, 1);
                        },
                    }
                    return payload_len;
                }
            }

            const start_len = peer.inbox.items.len;
            errdefer peer.inbox.shrinkRetainingCapacity(start_len);

            try appendWritevPayload(peer_ref.backend, &peer.inbox, header, data, splat);
            peer_ref.backend.wakeConnection(peer_ref.handle, 1);
            return peer.inbox.items.len - start_len;
        }

        pub fn simNetClose(userdata: ?*anyopaque, handles: []const SocketHandle) void {
            const backend = backendFromUserdata(userdata);
            for (handles) |handle| {
                backend.retireNetHandle(handle);
            }
        }

        pub fn simNetShutdown(userdata: ?*anyopaque, handle: SocketHandle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
            _ = how;
            simNetClose(userdata, (&handle)[0..1]);
        }
    };
}
