//! `std.Io.net` stream operations backed by Marionette network faults.

const std = @import("std");

const errors = @import("errors.zig");
const futex_module = @import("futex.zig");
const network_module = @import("../network/root.zig");
const Io = std.Io;
const SocketHandle = Io.net.Socket.Handle;
const stream_frame_handle_size = @sizeOf(u64);

/// Maximum stream payload carried by one simulated network frame. Larger
/// writes are segmented like a real transport instead of rejected by the
/// byte pool's fixed per-message capacity; per-link `(deliver_at,
/// packet_id)` ordering keeps segments in order for inbox reassembly.
const max_stream_segment_len = 16 * 1024;

/// See `futex.stream_backpressure_wait_key`: writers parked on shared
/// backpressure wait world-globally, and both frame drains (here) and
/// connection teardown (`Backend.closeConnectionState`) must wake them.
const stream_backpressure_wait_key = futex_module.stream_backpressure_wait_key;

pub fn Ops(comptime Backend: type) type {
    return struct {
        const StreamTarget = struct {
            handle: SocketHandle,
            connection: *Backend.ConnectionState,
            payload: []const u8,
        };

        fn backendFromUserdata(userdata: ?*anyopaque) *Backend {
            return @ptrCast(@alignCast(userdata.?));
        }

        /// Deliver an armed cancellation request at a net cancellation point.
        fn takeCancel(backend: *Backend) Io.Cancelable!void {
            const runtime = backend.task_runtime orelse return;
            if (runtime.takeCancelRequest()) return error.Canceled;
        }

        fn connectTimeoutDeadlineNs(
            backend: *Backend,
            timeout: Io.Timeout,
        ) error{OptionUnsupported}!?u64 {
            const timestamp = switch (timeout) {
                .none => return null,
                .duration => |duration| blk: {
                    if (!simulatedClockSupported(duration.clock)) return error.OptionUnsupported;
                    break :blk Io.Timestamp.fromNanoseconds(
                        std.math.add(
                            i96,
                            @intCast(backend.world.now()),
                            duration.raw.nanoseconds,
                        ) catch std.math.maxInt(i96),
                    );
                },
                .deadline => |deadline| blk: {
                    if (!simulatedClockSupported(deadline.clock)) return error.OptionUnsupported;
                    break :blk deadline.raw;
                },
            };
            if (timestamp.nanoseconds <= 0) return 0;
            return std.math.cast(u64, timestamp.nanoseconds) orelse std.math.maxInt(u64);
        }

        fn simulatedClockSupported(clock: Io.Clock) bool {
            return switch (clock) {
                .real, .awake, .boot => true,
                .cpu_process, .cpu_thread => false,
            };
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
                const ready = network_module.internal.peekReadyStreamEventFromControl(backend.network_control, node) catch |err| {
                    return errors.mapNetworkReadError(err);
                } orelse return;

                switch (ready) {
                    .delivered => |borrowed| {
                        const target = streamTarget(backend, borrowed.message.bytes()) orelse {
                            try discardReadyStreamEvent(backend, node, ready.id());
                            continue;
                        };

                        target.connection.inbox.ensureUnusedCapacity(backend.allocator, target.payload.len) catch
                            return error.SystemResources;

                        const message = network_module.internal.commitReadyStreamEventFromControl(
                            backend.network_control,
                            node,
                            ready.id(),
                            .{ .delivered = .{ .target = @intCast(target.handle), .len = target.payload.len } },
                        ) catch |err| return errors.mapNetworkReadError(err);
                        // Draining releases the pooled message and frees a
                        // path-queue slot even when the frame's target is
                        // gone or closed; the pool and queues are shared,
                        // so wake every backpressured writer in the world
                        // for every drained frame.
                        defer wakeBackpressuredWriters(backend);
                        defer message.release();

                        target.connection.inbox.appendSliceAssumeCapacity(target.payload);

                        backend.wakeConnection(target.handle, 1);
                    },
                    .dropped => |borrowed| {
                        const target = streamTarget(backend, borrowed.message.bytes()) orelse {
                            try discardReadyStreamEvent(backend, node, ready.id());
                            continue;
                        };

                        const read_error: Io.net.Stream.Reader.Error = switch (borrowed.reason) {
                            .destination_down => error.NetworkDown,
                            .link_disabled => error.Timeout,
                        };
                        const message = network_module.internal.commitReadyStreamEventFromControl(
                            backend.network_control,
                            node,
                            ready.id(),
                            .{ .delivery_error = .{
                                .target = @intCast(target.handle),
                                .error_name = @errorName(read_error),
                            } },
                        ) catch |err| return errors.mapNetworkReadError(err);
                        // A dropped envelope also releases its pooled
                        // message; same rule as `.delivered`.
                        defer wakeBackpressuredWriters(backend);
                        defer message.release();
                        if (target.connection.read_error == null) target.connection.read_error = read_error;
                        target.connection.read_failed = true;
                        _ = network_module.internal.discardStreamFramesFromControl(
                            backend.network_control,
                            node,
                            @intCast(target.handle),
                        );

                        backend.wakeConnection(target.handle, 1);
                    },
                }
            }
        }

        fn streamTarget(backend: *Backend, bytes: []const u8) ?StreamTarget {
            if (bytes.len < stream_frame_handle_size) return null;
            const raw = std.mem.readInt(u64, bytes[0..stream_frame_handle_size], .little);
            const handle = std.math.cast(SocketHandle, raw) orelse return null;
            const connection = backend.connection(handle) orelse return null;
            if (connection.closed or
                connection.read_shutdown or
                connection.read_error != null or
                connection.read_failed) return null;
            return .{
                .handle = handle,
                .connection = connection,
                .payload = bytes[stream_frame_handle_size..],
            };
        }

        fn discardReadyStreamEvent(backend: *Backend, node: network_module.NodeId, id: u64) Io.net.Stream.Reader.Error!void {
            const message = network_module.internal.commitReadyStreamEventFromControl(
                backend.network_control,
                node,
                id,
                .none,
            ) catch |err| return errors.mapNetworkReadError(err);
            defer wakeBackpressuredWriters(backend);
            message.release();
        }

        fn wakeBackpressuredWriters(backend: *Backend) void {
            if (backend.futex_wait_set) |wait_set| {
                _ = wait_set.wake(stream_backpressure_wait_key, std.math.maxInt(usize));
            }
        }

        fn discardConnectProbe(
            backend: *Backend,
            destination_backend: *Backend,
            destination_node: network_module.NodeId,
            id: u64,
        ) void {
            if (!network_module.internal.discardStreamPacketFromControl(
                backend.network_control,
                id,
            )) return;
            wakeBackpressuredWriters(backend);
            destination_backend.wakeConnectionsForNode(destination_node);
        }

        fn wakeAfterConnectProbeRemoval(
            backend: *Backend,
            destination_backend: *Backend,
            destination_node: network_module.NodeId,
        ) void {
            wakeBackpressuredWriters(backend);
            destination_backend.wakeConnectionsForNode(destination_node);
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
            try takeCancel(backend);
            if (!backend.processIsAlive()) return error.NetworkDown;
            // Port 0 asks for an ephemeral port, per POSIX bind semantics;
            // the assigned port is surfaced through the returned socket's
            // address so callers can connect to it.
            var bound_address = address.*;
            if (bound_address.getPort() == 0) {
                bound_address.setPort(try backend.allocateEphemeralPort(&bound_address));
            } else if (backend.findOpenListenerRef(&bound_address) != null) {
                return error.AddressInUse;
            }

            const node = backend.allocateNetworkNode() catch return error.NetworkDown;
            const listener = backend.allocator.create(Backend.ListenerState) catch return error.SystemResources;
            errdefer backend.allocator.destroy(listener);
            listener.* = .{
                .address = bound_address,
                .node = node,
                .backlog = options.kernel_backlog,
            };
            errdefer listener.pending.deinit(backend.allocator);

            const handle = backend.createHandle(.{ .listener = listener }) catch return error.SystemResources;
            errdefer _ = backend.handles.pop();
            backend.registerListener(handle, bound_address) catch return error.SystemResources;
            return .{
                .handle = handle,
                .address = bound_address,
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
            if (!backend.processIsAlive()) return error.NetworkDown;
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
            try takeCancel(backend);
            if (!backend.processIsAlive()) return error.NetworkDown;
            const timeout_at = try connectTimeoutDeadlineNs(backend, options.timeout);
            if (timeout_at) |deadline| {
                if (deadline <= backend.world.now()) return error.Timeout;
            }

            const initial_listener_ref = backend.findOpenListenerRef(address) orelse return error.ConnectionRefused;
            const listener_backend = initial_listener_ref.backend;
            const listener_handle = initial_listener_ref.handle;
            const listener_node = initial_listener_ref.state.node;
            if (initial_listener_ref.state.pending.items.len >= initial_listener_ref.state.backlog)
                return error.ConnectionRefused;
            const client_node = backend.allocateNetworkNode() catch return error.NetworkDown;
            if (client_node) |from_node| {
                if (listener_node) |to_node| {
                    const path_state = network_module.internal.streamPathStateFromControl(
                        backend.network_control,
                        from_node,
                        to_node,
                    ) catch return error.NetworkDown;
                    switch (path_state) {
                        .available => {},
                        .source_down => return error.NetworkDown,
                        .destination_down, .link_disabled => return error.HostUnreachable,
                    }

                    const send_result = network_module.internal.sendStreamProbeFromControl(
                        backend.network_control,
                        from_node,
                        to_node,
                    ) catch |err| return errors.mapNetworkConnectError(err);
                    switch (send_result) {
                        .dropped => return error.NetworkDown,
                        .queued => |queued| {
                            backend.registerConnectProbe(
                                queued.id,
                                listener_backend,
                                to_node,
                            ) catch {
                                discardConnectProbe(
                                    backend,
                                    listener_backend,
                                    to_node,
                                    queued.id,
                                );
                                return error.SystemResources;
                            };
                            defer backend.releaseConnectProbe(queued.id);
                            var probe_pending = true;
                            defer if (probe_pending) {
                                discardConnectProbe(
                                    backend,
                                    listener_backend,
                                    to_node,
                                    queued.id,
                                );
                            };

                            probe_wait: while (true) {
                                const ready_at = network_module.internal.streamProbeReadyAtFromControl(
                                    backend.network_control,
                                    queued.id,
                                ) catch return error.NetworkDown;
                                const wait_until = if (timeout_at) |deadline|
                                    @min(deadline, ready_at)
                                else
                                    ready_at;
                                if (wait_until > backend.world.now()) {
                                    if (backend.futex_wait_set) |wait_set| {
                                        const wait_result = wait_set.blockUntilCancelable(
                                            backend.connectProbeWaitKey(queued.id),
                                            wait_until,
                                        );
                                        switch (wait_result) {
                                            .woken => {},
                                            .timed_out => {},
                                            .canceled => return error.Canceled,
                                        }
                                    } else {
                                        backend.world.runFor(wait_until - backend.world.now()) catch
                                            return error.NetworkDown;
                                    }
                                    if (!backend.processIsAlive()) return error.NetworkDown;
                                    // Explicit wakes are spurious for probes,
                                    // and clogs may have changed while time
                                    // advanced. Recompute readiness and timeout
                                    // ordering before committing anything.
                                    continue;
                                }
                                if (!backend.processIsAlive()) return error.NetworkDown;
                                if (timeout_at) |deadline| {
                                    // Scheduler deadlines round up to the world
                                    // tick. Preserve the requested ordering
                                    // even when a sub-tick timeout and probe
                                    // readiness become runnable together.
                                    if (deadline < ready_at and deadline <= backend.world.now())
                                        return error.Timeout;
                                }
                                if (ready_at > backend.world.now()) continue;

                                const probe_result = network_module.internal.commitReadyStreamProbeFromControl(
                                    backend.network_control,
                                    to_node,
                                    queued.id,
                                ) catch return error.NetworkDown;
                                probe_pending = false;
                                wakeAfterConnectProbeRemoval(
                                    backend,
                                    listener_backend,
                                    to_node,
                                );
                                switch (probe_result) {
                                    .delivered => break :probe_wait,
                                    .dropped => return error.HostUnreachable,
                                }
                            }
                        },
                    }
                }
            }

            const listener = listener_backend.listener(listener_handle) orelse return error.ConnectionRefused;
            if (listener.closed) return error.ConnectionRefused;
            if (listener.pending.items.len >= listener.backlog) return error.ConnectionRefused;

            const client = backend.allocator.create(Backend.ConnectionState) catch return error.SystemResources;
            errdefer backend.allocator.destroy(client);
            var client_address = address.*;
            client_address.setPort(
                backend.allocateEphemeralPort(&client_address) catch return error.AddressUnavailable,
            );
            client.* = .{ .address = address.*, .node = client_node };
            errdefer client.inbox.deinit(backend.allocator);

            const server = listener_backend.allocator.create(Backend.ConnectionState) catch return error.SystemResources;
            errdefer listener_backend.allocator.destroy(server);
            server.* = .{ .address = client_address, .node = listener.node };
            errdefer server.inbox.deinit(listener_backend.allocator);

            const client_handle = backend.createHandle(.{ .connection = client }) catch return error.SystemResources;
            errdefer _ = backend.handles.pop();
            const server_handle = listener_backend.createHandle(.{ .connection = server }) catch return error.SystemResources;
            errdefer _ = listener_backend.handles.pop();

            client.peer = .{ .backend = listener_backend, .handle = server_handle };
            server.peer = .{ .backend = backend, .handle = client_handle };

            listener.pending.append(listener_backend.allocator, server_handle) catch return error.SystemResources;
            // A failed record must unpublish the handle, or accept would
            // hand out a socket whose state the errdefers destroyed. The
            // pop is safe because no suspension point sits between the
            // append and the record, so the entry is still last; recording
            // after the append keeps a failed connect out of the trace.
            errdefer _ = listener.pending.pop();
            backend.world.record(
                "io.net.connect handle={} port={}",
                .{ client_handle, address.getPort() },
            ) catch return error.SystemResources;
            listener_backend.wakeListener(listener_handle, 1);
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
                .address = (backend.connection(handle) orelse return error.SocketNotListening).address,
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
            if (connection.read_shutdown) return 0;
            if (connection.node) |node| try drainNetworkReady(backend, node);
            while (connection.inbox.items.len == 0) {
                const deadline_ns = if (connection.node) |node| try nextNetworkDeliveryAt(backend, node) else null;
                if (connection.read_error) |err| {
                    connection.read_error = null;
                    return err;
                }
                if (connection.read_failed) return 0;
                const peer_closed = if (connection.peer) |peer_ref|
                    if (peer_ref.backend.connection(peer_ref.handle)) |peer|
                        peer.closed or peer.write_shutdown
                    else
                        true
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
            if (connection.closed or connection.write_shutdown) return error.SocketUnconnected;
            const peer_ref = connection.peer orelse return error.SocketUnconnected;
            const peer = peer_ref.backend.connection(peer_ref.handle) orelse return error.ConnectionResetByPeer;
            if (peer.closed) return error.ConnectionResetByPeer;

            if (connection.node) |from_node| {
                if (peer.node) |to_node| {
                    var frame: std.ArrayList(u8) = .empty;
                    defer frame.deinit(backend.allocator);

                    const payload_len = try appendStreamFrame(backend, &frame, peer_ref.handle, header, data, splat);
                    if (payload_len == 0) return 0;

                    const payload = frame.items[stream_frame_handle_size..];
                    var segment: std.ArrayList(u8) = .empty;
                    defer segment.deinit(backend.allocator);

                    var offset: usize = 0;
                    while (offset < payload.len) {
                        const segment_len = @min(max_stream_segment_len, payload.len - offset);
                        const bytes = if (offset == 0 and segment_len == payload.len)
                            frame.items
                        else blk: {
                            segment.clearRetainingCapacity();
                            segment.appendNTimes(backend.allocator, 0, stream_frame_handle_size) catch {
                                if (offset > 0) return offset;
                                return error.SystemResources;
                            };
                            std.mem.writeInt(
                                u64,
                                segment.items[0..stream_frame_handle_size],
                                @intCast(peer_ref.handle),
                                .little,
                            );
                            segment.appendSlice(backend.allocator, payload[offset..][0..segment_len]) catch {
                                if (offset > 0) return offset;
                                return error.SystemResources;
                            };
                            break :blk segment.items;
                        };

                        while (true) {
                            // The peer can close or die while this writer is
                            // parked on backpressure; re-resolve and validate
                            // it before every attempt so a stale pointer is
                            // never dereferenced and a dead peer surfaces as
                            // a reset instead of a silent retry.
                            const live_peer = peer_ref.backend.connection(peer_ref.handle) orelse {
                                if (offset > 0) return offset;
                                return error.ConnectionResetByPeer;
                            };
                            if (live_peer.closed or
                                live_peer.read_shutdown or
                                live_peer.read_error != null or
                                live_peer.read_failed)
                            {
                                if (offset > 0) return offset;
                                return error.ConnectionResetByPeer;
                            }

                            const send_result = network_module.internal.sendStreamBytesFromControl(
                                backend.network_control,
                                from_node,
                                to_node,
                                @intCast(peer_ref.handle),
                                bytes,
                                connection.delivery_floor_ns,
                            ) catch |err| switch (err) {
                                // Backpressure: a real transport blocks the
                                // writer when the in-flight window is full,
                                // whether the byte pool or the directed path
                                // queue is what filled up. Park on the
                                // world-global backpressure key until any
                                // receiver drains a frame, then retry. Two
                                // peers both blocked writing at each other
                                // is a real deadlock, exactly as it is on
                                // TCP, and surfaces through deadlock
                                // detection.
                                error.PoolExhausted, error.EventQueueFull => {
                                    const wait_set = backend.futex_wait_set orelse {
                                        if (offset > 0) return offset;
                                        return errors.mapNetworkWriteError(err);
                                    };
                                    connection.waiters += 1;
                                    const wait_result = wait_set.blockUntilCancelable(
                                        stream_backpressure_wait_key,
                                        null,
                                    );
                                    connection.waiters -= 1;
                                    switch (wait_result) {
                                        .woken, .timed_out => {},
                                        .canceled => {
                                            // Same closed-while-canceled race
                                            // as the read park: never skip
                                            // retiring a closed idle handle.
                                            if (connection.closed) backend.retireClosedNetHandleIfIdle(dest);
                                            if (offset > 0) return offset;
                                            return error.Canceled;
                                        },
                                    }
                                    if (connection.closed) {
                                        backend.retireClosedNetHandleIfIdle(dest);
                                        if (offset > 0) return offset;
                                        return error.SocketUnconnected;
                                    }
                                    continue;
                                },
                                else => {
                                    if (offset > 0) return offset;
                                    return errors.mapNetworkWriteError(err);
                                },
                            };

                            switch (send_result) {
                                .queued => |queued| {
                                    connection.delivery_floor_ns = queued.deliver_at;
                                    peer_ref.backend.wakeConnection(peer_ref.handle, 1);
                                    offset += segment_len;
                                },
                                .dropped => {
                                    if (live_peer.read_error == null) live_peer.read_error = error.Timeout;
                                    live_peer.read_failed = true;
                                    peer_ref.backend.wakeConnection(peer_ref.handle, 1);
                                    // The transport accepted this segment but
                                    // cannot preserve a reliable byte stream.
                                    // Stop before any suffix can be exposed.
                                    offset += segment_len;
                                    return offset;
                                },
                            }
                            break;
                        }
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

        /// Shutdown is local-only in simulation: direction state changes
        /// immediately, without a FIN traversing the network model.
        pub fn simNetShutdown(userdata: ?*anyopaque, handle: SocketHandle, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
            const backend = backendFromUserdata(userdata);
            try takeCancel(backend);
            if (!backend.processIsAlive()) return error.NetworkDown;
            const connection = backend.connection(handle) orelse return error.SocketUnconnected;
            if (connection.closed) return error.SocketUnconnected;
            backend.world.record(
                "io.net.shutdown handle={} how={s}",
                .{ handle, @tagName(how) },
            ) catch return error.SystemResources;
            switch (how) {
                .recv => connection.read_shutdown = true,
                .send => connection.write_shutdown = true,
                .both => {
                    connection.read_shutdown = true;
                    connection.write_shutdown = true;
                },
            }
            if (connection.read_shutdown) {
                connection.inbox.clearRetainingCapacity();
                if (connection.node) |node| {
                    _ = network_module.internal.discardStreamFramesFromControl(
                        backend.network_control,
                        node,
                        @intCast(handle),
                    );
                }
            }
            backend.wakeConnection(handle, std.math.maxInt(usize));
            if (connection.peer) |peer| {
                peer.backend.wakeConnection(peer.handle, std.math.maxInt(usize));
            }
            wakeBackpressuredWriters(backend);
        }
    };
}
