//! `std.Io.net` stream operations over the `tcp_v1` engine.
//!
//! The engine owns every socket's protocol state. This layer maps handles to
//! engine sockets, parks callers on their handle's wait key until the engine
//! reports readiness, and translates engine outcomes into `std.Io` errors.

const std = @import("std");

const network_module = @import("../network/root.zig");
const Io = std.Io;
const SocketHandle = Io.net.Socket.Handle;
const Engine = network_module.internal.TcpEngine;

pub fn Ops(comptime Backend: type) type {
    return struct {
        fn takeCancel(backend: *Backend) Io.Cancelable!void {
            const runtime = backend.task_runtime orelse return;
            if (runtime.takeCancelRequest()) return error.Canceled;
        }

        fn host(backend: *Backend) error{NetworkDown}!network_module.NodeId {
            return (try backend.allocateNetworkNode()) orelse error.NetworkDown;
        }

        fn deadlineFor(backend: *Backend, timeout: Io.Timeout) ?u64 {
            const timestamp = switch (timeout) {
                .none => return null,
                .duration => |duration| Io.Timestamp.fromNanoseconds(
                    std.math.add(i96, @intCast(backend.world.now()), duration.raw.nanoseconds) catch std.math.maxInt(i96),
                ),
                .deadline => |deadline| deadline.raw,
            };
            if (timestamp.nanoseconds <= 0) return 0;
            return std.math.cast(u64, timestamp.nanoseconds) orelse std.math.maxInt(u64);
        }

        fn timeoutClockSupported(timeout: Io.Timeout) bool {
            const clock = switch (timeout) {
                .none => return true,
                .duration => |duration| duration.clock,
                .deadline => |deadline| deadline.clock,
            };
            return switch (clock) {
                .real, .awake, .boot => true,
                .cpu_process, .cpu_thread => false,
            };
        }

        pub fn listen(
            backend: *Backend,
            engine: *Engine,
            address: *const Io.net.IpAddress,
            options: Io.net.IpAddress.ListenOptions,
        ) Io.net.IpAddress.ListenError!Io.net.Socket {
            try takeCancel(backend);
            if (!backend.processIsAlive()) return error.NetworkDown;
            const node = try host(backend);
            const listener = backend.allocator.create(Backend.ListenerState) catch return error.SystemResources;
            errdefer backend.allocator.destroy(listener);
            listener.* = .{ .address = address.*, .node = node, .backlog = options.kernel_backlog };
            const handle = backend.createHandle(.{ .listener = listener }) catch return error.SystemResources;
            errdefer _ = backend.handles.pop();
            const bound = engine.listen(node, address.*, options.kernel_backlog, @intCast(handle)) catch |err| return switch (err) {
                error.AddressInUse => error.AddressInUse,
                error.AddressUnavailable => error.AddressUnavailable,
                error.NetworkDown => error.NetworkDown,
                error.OutOfMemory, error.InvalidTracePayload => error.SystemResources,
            };
            listener.tcp = bound.id;
            listener.address = bound.address;
            return .{ .handle = handle, .address = bound.address };
        }

        pub fn accept(backend: *Backend, engine: *Engine, server: SocketHandle) Io.net.Server.AcceptError!Io.net.Socket {
            try takeCancel(backend);
            const state = backend.listener(server) orelse return error.SocketNotListening;
            if (state.closed) return error.SocketNotListening;
            const listener_id = state.tcp.?;
            while (true) {
                switch (engine.accept(listener_id)) {
                    .accepted => |accepted| {
                        const connection = backend.allocator.create(Backend.ConnectionState) catch {
                            engine.abort(accepted.conn);
                            return error.SystemResources;
                        };
                        connection.* = .{ .address = accepted.remote, .node = state.node, .tcp = accepted.conn };
                        const handle = backend.createHandle(.{ .connection = connection }) catch {
                            backend.allocator.destroy(connection);
                            engine.abort(accepted.conn);
                            return error.SystemResources;
                        };
                        engine.attach(accepted.conn, @intCast(handle), listener_id);
                        return .{ .handle = handle, .address = accepted.remote };
                    },
                    .not_listening => return error.SocketNotListening,
                    .would_block => {},
                }
                const wait_set = backend.futex_wait_set orelse return error.WouldBlock;
                state.waiters += 1;
                const result = wait_set.blockUntilCancelable(backend.listenerWaitKey(server), null);
                state.waiters -= 1;
                switch (result) {
                    .woken, .timed_out => {},
                    .canceled, .failed => {
                        if (state.closed) backend.retireClosedNetHandleIfIdle(server);
                        return error.Canceled;
                    },
                }
                if (state.closed) {
                    backend.retireClosedNetHandleIfIdle(server);
                    return error.SocketNotListening;
                }
            }
        }

        pub fn connect(
            backend: *Backend,
            engine: *Engine,
            address: *const Io.net.IpAddress,
            options: Io.net.IpAddress.ConnectOptions,
        ) Io.net.IpAddress.ConnectError!Io.net.Socket {
            try takeCancel(backend);
            if (!backend.processIsAlive()) return error.NetworkDown;
            if (!timeoutClockSupported(options.timeout)) return error.OptionUnsupported;
            const deadline = deadlineFor(backend, options.timeout);
            if (deadline) |at| if (at <= backend.world.now()) return error.Timeout;
            const node = try host(backend);

            const connection = backend.allocator.create(Backend.ConnectionState) catch return error.SystemResources;
            connection.* = .{ .address = address.*, .node = node };
            const handle = backend.createHandle(.{ .connection = connection }) catch {
                backend.allocator.destroy(connection);
                return error.SystemResources;
            };
            const conn_id = engine.connect(node, address.*, @intCast(handle)) catch |err| {
                backend.retireNetHandle(handle);
                return switch (err) {
                    error.NetworkUnreachable => error.NetworkUnreachable,
                    error.AddressUnavailable => error.AddressUnavailable,
                    error.NetworkDown => error.NetworkDown,
                    error.OutOfMemory, error.InvalidTracePayload => error.SystemResources,
                };
            };
            connection.tcp = conn_id;

            while (true) {
                switch (engine.connectStatus(conn_id)) {
                    .established => {
                        backend.world.record("io.net.connect handle={} port={}", .{ handle, address.getPort() }) catch {};
                        return .{ .handle = handle, .address = address.* };
                    },
                    .failed => |failure| {
                        backend.retireNetHandle(handle);
                        return switch (failure) {
                            .refused => error.ConnectionRefused,
                            .timed_out => error.Timeout,
                            .host_unreachable => error.HostUnreachable,
                            .network_unreachable => error.NetworkUnreachable,
                            .reset => error.ConnectionResetByPeer,
                            .network_down => error.NetworkDown,
                        };
                    },
                    .pending => {},
                }
                if (deadline) |at| if (at <= backend.world.now()) {
                    backend.world.record("io.net.connect_timeout handle={} conn={}", .{ handle, conn_id }) catch {};
                    engine.abort(conn_id);
                    backend.retireNetHandle(handle);
                    return error.Timeout;
                };
                const wait_set = backend.futex_wait_set orelse {
                    engine.abort(conn_id);
                    backend.retireNetHandle(handle);
                    return error.WouldBlock;
                };
                connection.waiters += 1;
                const result = wait_set.blockUntilCancelable(backend.connectionWaitKey(handle), deadline);
                connection.waiters -= 1;
                switch (result) {
                    .woken, .timed_out => {},
                    .canceled, .failed => {
                        engine.abort(conn_id);
                        backend.retireNetHandle(handle);
                        return error.Canceled;
                    },
                }
                if (!backend.processIsAlive() or connection.closed) {
                    backend.retireClosedNetHandleIfIdle(handle);
                    return error.NetworkDown;
                }
            }
        }

        fn readErrorFor(failure: network_module.internal.TcpEngine.SocketErrorKind) Io.net.Stream.Reader.Error {
            return switch (failure) {
                .reset, .refused => error.ConnectionResetByPeer,
                .timed_out, .host_unreachable, .network_unreachable => error.ConnectionTimedOut,
                .network_down => error.NetworkDown,
            };
        }

        fn writeErrorFor(failure: network_module.internal.TcpEngine.SocketErrorKind) Io.net.Stream.Writer.Error {
            return switch (failure) {
                .reset, .refused => error.ConnectionResetByPeer,
                .timed_out => error.ConnectionTimedOut,
                .host_unreachable => error.HostUnreachable,
                .network_unreachable => error.NetworkUnreachable,
                .network_down => error.NetworkDown,
            };
        }

        /// Readiness for a batch: whether a read would not block.
        pub fn readReady(engine: *Engine, connection: *Backend.ConnectionState) bool {
            const conn = engine.connection(connection.tcp.?) orelse return true;
            return conn.recv_buf.items.len > 0 or conn.err != null or conn.fin_received or
                conn.read_shutdown or conn.state == .closed;
        }

        pub fn read(
            backend: *Backend,
            engine: *Engine,
            src: SocketHandle,
            connection: *Backend.ConnectionState,
            data: [][]u8,
            deadline: ?u64,
        ) (Io.net.Stream.Reader.Error || error{Timeout})!usize {
            while (true) {
                switch (engine.read(connection.tcp.?, data)) {
                    .bytes => |count| return count,
                    .end_of_stream => return 0,
                    .failed => |failure| return readErrorFor(failure),
                    .not_connected => return error.SocketUnconnected,
                    .would_block => {},
                }
                if (deadline) |at| if (at <= backend.world.now()) return error.Timeout;
                const wait_set = backend.futex_wait_set orelse return error.ConnectionTimedOut;
                connection.waiters += 1;
                const result = wait_set.blockUntilCancelable(backend.connectionWaitKey(src), deadline);
                connection.waiters -= 1;
                switch (result) {
                    .woken, .timed_out => {},
                    .canceled, .failed => {
                        if (connection.closed) backend.retireClosedNetHandleIfIdle(src);
                        return error.Canceled;
                    },
                }
                if (connection.closed) {
                    backend.retireClosedNetHandleIfIdle(src);
                    return error.SocketUnconnected;
                }
            }
        }

        pub fn write(
            backend: *Backend,
            engine: *Engine,
            dest: SocketHandle,
            connection: *Backend.ConnectionState,
            header: []const u8,
            data: []const []const u8,
            splat: usize,
            deadline: ?u64,
        ) (Io.net.Stream.Writer.Error || error{Timeout})!usize {
            while (true) {
                const outcome = engine.write(connection.tcp.?, header, data, splat) catch return error.SystemResources;
                switch (outcome) {
                    .accepted => |count| return count,
                    .failed => |failure| return writeErrorFor(failure),
                    .not_connected => return error.SocketUnconnected,
                    .would_block => {},
                }
                if (deadline) |at| if (at <= backend.world.now()) return error.Timeout;
                const wait_set = backend.futex_wait_set orelse return error.SystemResources;
                connection.waiters += 1;
                const result = wait_set.blockUntilCancelable(backend.connectionWaitKey(dest), deadline);
                connection.waiters -= 1;
                switch (result) {
                    .woken, .timed_out => {},
                    .canceled, .failed => {
                        if (connection.closed) backend.retireClosedNetHandleIfIdle(dest);
                        return error.Canceled;
                    },
                }
                if (connection.closed) {
                    backend.retireClosedNetHandleIfIdle(dest);
                    return error.SocketUnconnected;
                }
            }
        }

        pub fn shutdown(backend: *Backend, engine: *Engine, handle: SocketHandle, connection: *Backend.ConnectionState, how: Io.net.ShutdownHow) Io.net.ShutdownError!void {
            backend.world.record("io.net.shutdown handle={} how={s}", .{ handle, @tagName(how) }) catch return error.SystemResources;
            const ok = engine.shutdown(connection.tcp.?, switch (how) {
                .recv => .recv,
                .send => .send,
                .both => .both,
            });
            if (!ok) return error.SocketUnconnected;
            backend.wakeConnection(handle, std.math.maxInt(usize));
        }
    };
}
