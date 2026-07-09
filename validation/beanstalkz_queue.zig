//! External SUT validation: the unmodified beanstalkz queue client under
//! Marionette's deterministic `std.Io`.
//!
//! The SUT (`g41797/beanstalkz`) is a beanstalkd work-queue client written
//! against the injectable `std.Io` interface: `IpAddress.resolve` +
//! `connect`, stream reader/writer adapters, `Io.Mutex` locking, and
//! `shutdown(.both)` on disconnect. Marionette owns the harness side:
//! world, seed, simulated network, a minimal in-memory beanstalkd server
//! speaking the text protocol, and the job-payload oracle.
//!
//! Scenario coverage:
//! - produce/consume round trip over two concurrent connections, including
//!   bury/kick state transitions and the pinned `error.Timeout` contract
//!   for an empty reserve;
//! - sequential connection churn: fresh producer connections (connect,
//!   put, quit, `shutdown(.both)`, close) followed by a drain that must
//!   observe FIFO order;
//! - a blocking `reserve-with-timeout` that parks the client in a stream
//!   read across a virtual-time gap until a delayed producer publishes;
//! - a server-process crash while the client is parked in reserve: the
//!   surviving peer wakes with a reset that surfaces as the pinned
//!   `error.CommunicationFailure`, and a registered process restart brings
//!   up a fresh, empty server incarnation for recovery.

const std = @import("std");
const mar = @import("marionette");
const bean = @import("beanstalkz");

const Io = std.Io;
const Client = bean.client;
const Job = bean.Job;

const server_port: u16 = 11300;
const server_addr = "127.0.0.1";
const orders_tube = "orders";
const max_connections = 8;
const poll_interval_ns = 10_000_000; // 10 virtual milliseconds

const reserve_poll_slices_per_second = 1_000_000_000 / poll_interval_ns;

const JobPhase = enum { ready, reserved, buried };

const ServerJob = struct {
    id: u32,
    tube: []const u8,
    body: []const u8,
    phase: JobPhase,
    live: bool,
};

/// Minimal in-memory beanstalkd: enough of the text protocol to serve the
/// SUT's command subset (use, put, watch, ignore, reserve-with-timeout,
/// stats-job, bury, kick-job, delete, quit). All state lives in a
/// harness-owned arena so a killed server process leaks nothing.
const QueueServer = struct {
    arena: std.mem.Allocator,
    world: *mar.World,
    io: Io,
    expected_connections: usize,
    next_id: u32 = 1,
    jobs: std.ArrayList(ServerJob) = .empty,
    ready_flag: u32 = 0,

    const Conn = struct {
        server: *QueueServer,
        stream: Io.net.Stream,
        used_tube: []const u8 = "default",
        watched: [4][]const u8 = .{ "default", "", "", "" },
        watched_count: usize = 1,
        read_cache: [1024]u8 = undefined,
        write_cache: [1024]u8 = undefined,
        line: [512]u8 = undefined,
    };

    fn record(self: *QueueServer, comptime fmt: []const u8, args: anytype) void {
        self.world.record(fmt, args) catch @panic("beanstalkz trace record failed");
    }

    fn signalReady(self: *QueueServer) void {
        self.ready_flag = 1;
        self.io.futexWake(u32, &self.ready_flag, std.math.maxInt(u32));
    }

    /// Clients wait on the server process's futex namespace, so waits use
    /// the server io handle (same pattern as the dusty validation).
    fn waitReady(self: *QueueServer) void {
        while (self.ready_flag == 0) {
            self.io.futexWait(u32, &self.ready_flag, 0) catch
                @panic("beanstalkz ready wait failed");
        }
    }

    fn acceptTask(self: *QueueServer) void {
        const address = Io.net.IpAddress.parseIp4(server_addr, server_port) catch unreachable;
        var listener = address.listen(self.io, .{}) catch |err| {
            std.debug.panic("beanstalkz listen failed: {}", .{err});
        };
        defer listener.deinit(self.io);
        self.record("beanstalkz.server.listening port={}", .{server_port});
        self.signalReady();

        var handlers: [max_connections]?Io.Future(void) = @splat(null);
        defer for (&handlers) |*handler| {
            if (handler.*) |*future| future.await(self.io);
        };

        for (0..self.expected_connections) |index| {
            const stream = listener.accept(self.io) catch |err| {
                std.debug.panic("beanstalkz accept failed: {}", .{err});
            };
            self.record("beanstalkz.server.accepted connection={}", .{index});
            handlers[index] = Io.concurrent(self.io, connectionTask, .{ self, stream }) catch |err| {
                std.debug.panic("beanstalkz handler spawn failed: {}", .{err});
            };
        }
    }

    /// Same accept loop with the future intentionally dropped: the crash
    /// scenario joins the restarted incarnation through
    /// `runTasksUntilIdle` instead of an await handle.
    fn acceptTaskDetached(self: *QueueServer) void {
        self.acceptTask();
    }

    fn connectionTask(self: *QueueServer, stream: Io.net.Stream) void {
        var conn: Conn = .{ .server = self, .stream = stream };
        defer conn.stream.close(self.io);

        var reader = conn.stream.reader(self.io, &conn.read_cache);
        var writer = conn.stream.writer(self.io, &conn.write_cache);

        while (true) {
            const line = readLine(&reader.interface, &conn.line) catch return;
            self.dispatch(&conn, &reader.interface, &writer.interface, line) catch return;
        }
    }

    const CommandError = error{ Quit, Protocol };

    fn dispatch(
        self: *QueueServer,
        conn: *Conn,
        reader: *Io.Reader,
        writer: *Io.Writer,
        line: []const u8,
    ) !void {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const command = parts.next() orelse return error.Protocol;

        if (std.mem.eql(u8, command, "quit")) return error.Quit;

        if (std.mem.eql(u8, command, "use")) {
            const tube = parts.next() orelse return error.Protocol;
            conn.used_tube = try self.arena.dupe(u8, tube);
            try respond(writer, "USING {s}", .{tube});
            return;
        }

        if (std.mem.eql(u8, command, "put")) {
            _ = parts.next() orelse return error.Protocol; // pri
            _ = parts.next() orelse return error.Protocol; // delay
            _ = parts.next() orelse return error.Protocol; // ttr
            const size_text = parts.next() orelse return error.Protocol;
            const size = try std.fmt.parseInt(usize, size_text, 10);

            const body = try self.arena.alloc(u8, size);
            try reader.readSliceAll(body);
            var trailer: [2]u8 = undefined;
            try reader.readSliceAll(&trailer);

            const id = self.next_id;
            self.next_id += 1;
            try self.jobs.append(self.arena, .{
                .id = id,
                .tube = conn.used_tube,
                .body = body,
                .phase = .ready,
                .live = true,
            });
            self.record("beanstalkz.server.put id={} tube={s} bytes={}", .{ id, conn.used_tube, size });
            try respond(writer, "INSERTED {}", .{id});
            return;
        }

        if (std.mem.eql(u8, command, "watch")) {
            const tube = parts.next() orelse return error.Protocol;
            if (conn.watched_count >= conn.watched.len) return error.Protocol;
            conn.watched[conn.watched_count] = try self.arena.dupe(u8, tube);
            conn.watched_count += 1;
            try respond(writer, "WATCHING {}", .{conn.watched_count});
            return;
        }

        if (std.mem.eql(u8, command, "ignore")) {
            const tube = parts.next() orelse return error.Protocol;
            if (conn.watched_count == 1) {
                try respond(writer, "NOT_IGNORED", .{});
                return;
            }
            for (conn.watched[0..conn.watched_count], 0..) |watched, index| {
                if (std.mem.eql(u8, watched, tube)) {
                    conn.watched[index] = conn.watched[conn.watched_count - 1];
                    conn.watched_count -= 1;
                    break;
                }
            }
            try respond(writer, "WATCHING {}", .{conn.watched_count});
            return;
        }

        if (std.mem.eql(u8, command, "reserve-with-timeout")) {
            const seconds_text = parts.next() orelse return error.Protocol;
            const seconds = try std.fmt.parseInt(u64, seconds_text, 10);
            var slices_left = seconds * reserve_poll_slices_per_second;

            while (true) {
                if (self.takeReadyJob(conn)) |job| {
                    self.record("beanstalkz.server.reserved id={}", .{job.id});
                    try respond(writer, "RESERVED {} {}", .{ job.id, job.body.len });
                    try writer.writeAll(job.body);
                    try writer.writeAll("\r\n");
                    try writer.flush();
                    return;
                }
                if (slices_left == 0) {
                    try respond(writer, "TIMED_OUT", .{});
                    return;
                }
                slices_left -= 1;
                Io.sleep(self.io, .fromNanoseconds(poll_interval_ns), .awake) catch return error.Quit;
            }
        }

        if (std.mem.eql(u8, command, "stats-job")) {
            const id = try std.fmt.parseInt(u32, parts.next() orelse return error.Protocol, 10);
            const job = self.findJob(id) orelse {
                try respond(writer, "NOT_FOUND", .{});
                return;
            };
            const phase_name = switch (job.phase) {
                .ready => "ready",
                .reserved => "reserved",
                .buried => "buried",
            };
            var yaml_buffer: [64]u8 = undefined;
            const yaml = std.fmt.bufPrint(&yaml_buffer, "---\nstate: {s}\n", .{phase_name}) catch unreachable;
            try respond(writer, "OK {}", .{yaml.len});
            try writer.writeAll(yaml);
            try writer.writeAll("\r\n");
            try writer.flush();
            return;
        }

        if (std.mem.eql(u8, command, "bury")) {
            const id = try std.fmt.parseInt(u32, parts.next() orelse return error.Protocol, 10);
            const job = self.findJob(id) orelse {
                try respond(writer, "NOT_FOUND", .{});
                return;
            };
            job.phase = .buried;
            try respond(writer, "BURIED", .{});
            return;
        }

        if (std.mem.eql(u8, command, "kick-job")) {
            const id = try std.fmt.parseInt(u32, parts.next() orelse return error.Protocol, 10);
            const job = self.findJob(id) orelse {
                try respond(writer, "NOT_FOUND", .{});
                return;
            };
            if (job.phase != .buried) {
                try respond(writer, "NOT_FOUND", .{});
                return;
            }
            job.phase = .ready;
            try respond(writer, "KICKED", .{});
            return;
        }

        if (std.mem.eql(u8, command, "delete")) {
            const id = try std.fmt.parseInt(u32, parts.next() orelse return error.Protocol, 10);
            const job = self.findJob(id) orelse {
                try respond(writer, "NOT_FOUND", .{});
                return;
            };
            job.live = false;
            self.record("beanstalkz.server.deleted id={}", .{id});
            try respond(writer, "DELETED", .{});
            return;
        }

        try respond(writer, "UNKNOWN_COMMAND", .{});
    }

    fn takeReadyJob(self: *QueueServer, conn: *Conn) ?*ServerJob {
        for (self.jobs.items) |*job| {
            if (!job.live or job.phase != .ready) continue;
            for (conn.watched[0..conn.watched_count]) |watched| {
                if (std.mem.eql(u8, watched, job.tube)) {
                    job.phase = .reserved;
                    return job;
                }
            }
        }
        return null;
    }

    fn findJob(self: *QueueServer, id: u32) ?*ServerJob {
        for (self.jobs.items) |*job| {
            if (job.live and job.id == id) return job;
        }
        return null;
    }
};

fn respond(writer: *Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writer.print(fmt, args);
    try writer.writeAll("\r\n");
    try writer.flush();
}

fn readLine(reader: *Io.Reader, buffer: []u8) ![]const u8 {
    var length: usize = 0;
    while (length < buffer.len) {
        var byte: [1]u8 = undefined;
        const got = try reader.readSliceShort(&byte);
        if (got == 0) return error.EndOfStream;
        if (byte[0] == '\n') {
            if (length > 0 and buffer[length - 1] == '\r') length -= 1;
            return buffer[0..length];
        }
        buffer[length] = byte[0];
        length += 1;
    }
    return error.StreamTooLong;
}

// --- Round trip -------------------------------------------------------------

pub const RoundTripOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    reserved_ids: [3]u32,
    bodies_exact: bool,
    buried_state_seen: bool,
    kicked_state_seen: bool,
    empty_reserve_timed_out: bool,

    pub fn deinit(self: *RoundTripOutcome) void {
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

const round_trip_bodies = [_][]const u8{ "job-alpha", "job-bravo", "job-charlie" };

const RoundTrip = struct {
    world: *mar.World,
    server: *QueueServer,
    client_io: Io,
    allocator: std.mem.Allocator,
    produced: u32 = 0,
    reserved_ids: [3]u32 = @splat(0),
    bodies_exact: bool = true,
    buried_state_seen: bool = false,
    kicked_state_seen: bool = false,
    empty_reserve_timed_out: bool = false,

    fn producerTask(self: *RoundTrip) void {
        self.server.waitReady();
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();

        client.connect(server_addr, server_port) catch |err| {
            std.debug.panic("beanstalkz producer connect failed: {}", .{err});
        };
        client.use(orders_tube) catch |err| {
            std.debug.panic("beanstalkz use failed: {}", .{err});
        };
        for (round_trip_bodies) |body| {
            const id = client.put(bean.DefaultPriority, 0, bean.DefaultTTR, body) catch |err| {
                std.debug.panic("beanstalkz put failed: {}", .{err});
            };
            self.world.record("beanstalkz.client.put id={} bytes={}", .{ id, body.len }) catch
                @panic("trace failed");
        }
        self.produced = 1;
        self.client_io.futexWake(u32, &self.produced, 1);
    }

    fn consumerTask(self: *RoundTrip) void {
        self.server.waitReady();
        while (self.produced == 0) {
            self.client_io.futexWait(u32, &self.produced, 0) catch
                @panic("beanstalkz produced wait failed");
        }

        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| {
            std.debug.panic("beanstalkz consumer connect failed: {}", .{err});
        };

        const watching = client.watch(orders_tube) catch |err| {
            std.debug.panic("beanstalkz watch failed: {}", .{err});
        };
        std.debug.assert(watching == 2);
        _ = client.ignore("default") catch |err| {
            std.debug.panic("beanstalkz ignore failed: {}", .{err});
        };

        var job: Job = .{};
        job.init(self.allocator) catch unreachable;
        defer job.deinit();

        for (round_trip_bodies, 0..) |expected_body, index| {
            client.reserve(5, &job) catch |err| {
                std.debug.panic("beanstalkz reserve failed: {}", .{err});
            };
            const id = job.id() orelse @panic("reserved job without id");
            self.reserved_ids[index] = id;
            if (!std.mem.eql(u8, job.body() orelse "", expected_body)) {
                self.bodies_exact = false;
            }
            self.world.record("beanstalkz.client.reserved id={} bytes={}", .{ id, job.actual_len }) catch
                @panic("trace failed");

            if (index == 1) {
                // Exercise the failure-state transitions on the middle job.
                client.bury(id, bean.DefaultPriority) catch |err| {
                    std.debug.panic("beanstalkz bury failed: {}", .{err});
                };
                const buried = client.state(id) catch |err| {
                    std.debug.panic("beanstalkz stats-job failed: {}", .{err});
                };
                self.buried_state_seen = buried == .buried;
                client.kick_job(id) catch |err| {
                    std.debug.panic("beanstalkz kick failed: {}", .{err});
                };
                const kicked = client.state(id) catch |err| {
                    std.debug.panic("beanstalkz stats-job failed: {}", .{err});
                };
                self.kicked_state_seen = kicked == .ready;
                // Take it back out of the ready queue before moving on.
                client.reserve(5, &job) catch |err| {
                    std.debug.panic("beanstalkz re-reserve failed: {}", .{err});
                };
            }
            client.delete(id) catch |err| {
                std.debug.panic("beanstalkz delete failed: {}", .{err});
            };
        }

        // Pinned contract: reserving from a drained queue surfaces the
        // protocol TIMED_OUT response as `error.Timeout`.
        if (client.reserve(1, &job)) |_| {
            @panic("beanstalkz reserve on empty queue unexpectedly succeeded");
        } else |err| {
            self.empty_reserve_timed_out = err == bean.ReturnedError.Timeout;
        }
    }
};

pub fn runRoundTrip(allocator: std.mem.Allocator, seed: u64) !RoundTripOutcome {
    var world = try mar.World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 32 },
    });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    var server: QueueServer = .{
        .arena = arena_state.allocator(),
        .world = &world,
        .io = server_io,
        .expected_connections = 2,
    };
    var scenario: RoundTrip = .{
        .world = &world,
        .server = &server,
        .client_io = client_io,
        .allocator = allocator,
    };

    var server_future = try Io.concurrent(server_io, QueueServer.acceptTask, .{&server});
    var producer_future = try Io.concurrent(client_io, RoundTrip.producerTask, .{&scenario});
    var consumer_future = try Io.concurrent(client_io, RoundTrip.consumerTask, .{&scenario});

    producer_future.await(client_io);
    consumer_future.await(client_io);
    server_future.await(server_io);
    if (sim.control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;

    const trace = try allocator.dupe(u8, world.traceBytes());
    return .{
        .allocator = allocator,
        .trace = trace,
        .reserved_ids = scenario.reserved_ids,
        .bodies_exact = scenario.bodies_exact,
        .buried_state_seen = scenario.buried_state_seen,
        .kicked_state_seen = scenario.kicked_state_seen,
        .empty_reserve_timed_out = scenario.empty_reserve_timed_out,
    };
}

// --- Connection churn --------------------------------------------------------

const churn_producer_count = 4;

const Churn = struct {
    world: *mar.World,
    server: *QueueServer,
    client_io: Io,
    allocator: std.mem.Allocator,
    drained_ids: [churn_producer_count]u32 = @splat(0),
    drained_exact: bool = true,

    fn runTask(self: *Churn) void {
        self.server.waitReady();

        // Fresh connection per job: connect, put, quit + shutdown + close.
        for (0..churn_producer_count) |index| {
            var client = Client.init(self.allocator, self.client_io);
            client.connect(server_addr, server_port) catch |err| {
                std.debug.panic("beanstalkz churn connect {} failed: {}", .{ index, err });
            };
            client.use(orders_tube) catch |err| {
                std.debug.panic("beanstalkz churn use failed: {}", .{err});
            };
            var body_buffer: [16]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buffer, "churn-{}", .{index}) catch unreachable;
            _ = client.put(bean.DefaultPriority, 0, bean.DefaultTTR, body) catch |err| {
                std.debug.panic("beanstalkz churn put failed: {}", .{err});
            };
            client.disconnect();
            self.world.record("beanstalkz.client.churn_cycle index={}", .{index}) catch
                @panic("trace failed");
        }

        // One consumer connection drains everything in FIFO id order.
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| {
            std.debug.panic("beanstalkz drain connect failed: {}", .{err});
        };
        _ = client.watch(orders_tube) catch |err| {
            std.debug.panic("beanstalkz drain watch failed: {}", .{err});
        };

        var job: Job = .{};
        job.init(self.allocator) catch unreachable;
        defer job.deinit();

        for (0..churn_producer_count) |index| {
            client.reserve(5, &job) catch |err| {
                std.debug.panic("beanstalkz drain reserve failed: {}", .{err});
            };
            const id = job.id() orelse @panic("drained job without id");
            self.drained_ids[index] = id;
            var expected_buffer: [16]u8 = undefined;
            const expected = std.fmt.bufPrint(&expected_buffer, "churn-{}", .{index}) catch unreachable;
            if (!std.mem.eql(u8, job.body() orelse "", expected)) {
                self.drained_exact = false;
            }
            client.delete(id) catch |err| {
                std.debug.panic("beanstalkz drain delete failed: {}", .{err});
            };
        }
    }
};

pub const ChurnOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    drained_ids: [churn_producer_count]u32,
    drained_exact: bool,

    pub fn deinit(self: *ChurnOutcome) void {
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

pub fn runChurn(allocator: std.mem.Allocator, seed: u64) !ChurnOutcome {
    var world = try mar.World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 32 },
    });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    var server: QueueServer = .{
        .arena = arena_state.allocator(),
        .world = &world,
        .io = server_io,
        .expected_connections = churn_producer_count + 1,
    };
    var scenario: Churn = .{
        .world = &world,
        .server = &server,
        .client_io = client_io,
        .allocator = allocator,
    };

    var server_future = try Io.concurrent(server_io, QueueServer.acceptTask, .{&server});
    var client_future = try Io.concurrent(client_io, Churn.runTask, .{&scenario});

    client_future.await(client_io);
    server_future.await(server_io);
    if (sim.control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;

    const trace = try allocator.dupe(u8, world.traceBytes());
    return .{
        .allocator = allocator,
        .trace = trace,
        .drained_ids = scenario.drained_ids,
        .drained_exact = scenario.drained_exact,
    };
}

// --- Blocking reserve across virtual time -------------------------------------

const delayed_body = "published-after-five-seconds";
const publish_delay_ns = 5_000_000_000; // 5 virtual seconds

const DelayedPublish = struct {
    world: *mar.World,
    server: *QueueServer,
    client_io: Io,
    allocator: std.mem.Allocator,
    reserved_body_exact: bool = false,

    fn producerTask(self: *DelayedPublish) void {
        self.server.waitReady();
        Io.sleep(self.client_io, .fromNanoseconds(publish_delay_ns), .awake) catch
            @panic("beanstalkz delayed sleep failed");

        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| {
            std.debug.panic("beanstalkz delayed connect failed: {}", .{err});
        };
        client.use(orders_tube) catch |err| {
            std.debug.panic("beanstalkz delayed use failed: {}", .{err});
        };
        _ = client.put(bean.DefaultPriority, 0, bean.DefaultTTR, delayed_body) catch |err| {
            std.debug.panic("beanstalkz delayed put failed: {}", .{err});
        };
    }

    fn consumerTask(self: *DelayedPublish) void {
        self.server.waitReady();
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| {
            std.debug.panic("beanstalkz waiting connect failed: {}", .{err});
        };
        _ = client.watch(orders_tube) catch |err| {
            std.debug.panic("beanstalkz waiting watch failed: {}", .{err});
        };

        var job: Job = .{};
        job.init(self.allocator) catch unreachable;
        defer job.deinit();

        // Parks in the response read while virtual time crosses the
        // producer's five-second publish delay.
        client.reserve(30, &job) catch |err| {
            std.debug.panic("beanstalkz blocking reserve failed: {}", .{err});
        };
        self.reserved_body_exact = std.mem.eql(u8, job.body() orelse "", delayed_body);
        client.delete(job.id() orelse @panic("job without id")) catch |err| {
            std.debug.panic("beanstalkz delayed delete failed: {}", .{err});
        };
    }
};

pub const DelayedOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    reserved_body_exact: bool,
    elapsed_ns: u64,

    pub fn deinit(self: *DelayedOutcome) void {
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

pub fn runDelayedPublish(allocator: std.mem.Allocator, seed: u64) !DelayedOutcome {
    var world = try mar.World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 32 },
    });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    var server: QueueServer = .{
        .arena = arena_state.allocator(),
        .world = &world,
        .io = server_io,
        .expected_connections = 2,
    };
    var scenario: DelayedPublish = .{
        .world = &world,
        .server = &server,
        .client_io = client_io,
        .allocator = allocator,
    };

    var server_future = try Io.concurrent(server_io, QueueServer.acceptTask, .{&server});
    var producer_future = try Io.concurrent(client_io, DelayedPublish.producerTask, .{&scenario});
    var consumer_future = try Io.concurrent(client_io, DelayedPublish.consumerTask, .{&scenario});

    producer_future.await(client_io);
    consumer_future.await(client_io);
    server_future.await(server_io);
    if (sim.control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;

    const trace = try allocator.dupe(u8, world.traceBytes());
    return .{
        .allocator = allocator,
        .trace = trace,
        .reserved_body_exact = scenario.reserved_body_exact,
        .elapsed_ns = world.now(),
    };
}

// --- Server crash during a parked reserve -------------------------------------

const recovery_body = "job-after-restart";

const CrashRecovery = struct {
    world: *mar.World,
    server: *QueueServer,
    client_io: Io,
    allocator: std.mem.Allocator,
    parked: u32 = 0,
    reserve_error_name: []const u8 = "",
    recovered_body_exact: bool = false,

    fn victimTask(self: *CrashRecovery) void {
        self.server.waitReady();
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| {
            std.debug.panic("beanstalkz victim connect failed: {}", .{err});
        };
        _ = client.watch(orders_tube) catch |err| {
            std.debug.panic("beanstalkz victim watch failed: {}", .{err});
        };

        var job: Job = .{};
        job.init(self.allocator) catch unreachable;
        defer job.deinit();

        self.parked = 1;
        self.client_io.futexWake(u32, &self.parked, 1);

        // The queue is empty, so this parks in the stream read until the
        // harness kills the server process; the surviving peer wakes with a
        // reset that beanstalkz surfaces as CommunicationFailure.
        if (client.reserve(60, &job)) |_| {
            @panic("beanstalkz reserve against a crashing server succeeded");
        } else |err| {
            self.reserve_error_name = @errorName(err);
        }
        self.world.record("beanstalkz.client.reserve_interrupted error={s}", .{self.reserve_error_name}) catch
            @panic("trace failed");
    }

    fn recoveryTask(self: *CrashRecovery) void {
        self.server.waitReady();
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| {
            std.debug.panic("beanstalkz recovery connect failed: {}", .{err});
        };
        client.use(orders_tube) catch |err| {
            std.debug.panic("beanstalkz recovery use failed: {}", .{err});
        };
        _ = client.put(bean.DefaultPriority, 0, bean.DefaultTTR, recovery_body) catch |err| {
            std.debug.panic("beanstalkz recovery put failed: {}", .{err});
        };
        _ = client.watch(orders_tube) catch |err| {
            std.debug.panic("beanstalkz recovery watch failed: {}", .{err});
        };

        var job: Job = .{};
        job.init(self.allocator) catch unreachable;
        defer job.deinit();
        client.reserve(5, &job) catch |err| {
            std.debug.panic("beanstalkz recovery reserve failed: {}", .{err});
        };
        self.recovered_body_exact = std.mem.eql(u8, job.body() orelse "", recovery_body);
        client.delete(job.id() orelse @panic("job without id")) catch |err| {
            std.debug.panic("beanstalkz recovery delete failed: {}", .{err});
        };
    }
};

const ServerLifecycle = struct {
    server: *QueueServer,

    fn onKill(_: *anyopaque) void {}

    fn restart(raw: *anyopaque, env: mar.Env) anyerror!void {
        const self: *ServerLifecycle = @ptrCast(@alignCast(raw));
        // Fresh incarnation: beanstalkd's default is non-persistent, so a
        // crashed server restarts empty.
        self.server.jobs.clearRetainingCapacity();
        self.server.next_id = 1;
        self.server.ready_flag = 0;
        self.server.io = env.io();
        self.server.expected_connections = 1;
        _ = try Io.concurrent(self.server.io, QueueServer.acceptTaskDetached, .{self.server});
    }
};

pub const CrashOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    reserve_error_name: []u8,
    recovered_body_exact: bool,

    pub fn deinit(self: *CrashOutcome) void {
        self.allocator.free(self.trace);
        self.allocator.free(self.reserve_error_name);
        self.* = undefined;
    }
};

pub fn runCrashRecovery(allocator: std.mem.Allocator, seed: u64) !CrashOutcome {
    var world = try mar.World.init(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const sim = try world.simulate(.{
        .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 32 },
    });
    const server_io = (try sim.envForNode(0)).io();
    const client_io = (try sim.envForNode(1)).io();
    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    var server: QueueServer = .{
        .arena = arena_state.allocator(),
        .world = &world,
        .io = server_io,
        .expected_connections = 1,
    };
    var scenario: CrashRecovery = .{
        .world = &world,
        .server = &server,
        .client_io = client_io,
        .allocator = allocator,
    };
    var lifecycle: ServerLifecycle = .{ .server = &server };
    try sim.registerProcess(0, .{
        .ptr = &lifecycle,
        .on_kill = ServerLifecycle.onKill,
        .restart = ServerLifecycle.restart,
    });

    _ = try Io.concurrent(server_io, QueueServer.acceptTaskDetached, .{&server});
    var victim_future = try Io.concurrent(client_io, CrashRecovery.victimTask, .{&scenario});

    // Let the victim connect and park in its reserve read.
    while (scenario.parked == 0) {
        client_io.futexWait(u32, &scenario.parked, 0) catch break;
    }
    try sim.control.runFor(1_000_000);

    // Crash the server process: its listener, accept task, and handler die;
    // the surviving client peer wakes with a reset.
    try sim.killProcess(0);
    victim_future.await(client_io);

    // Restart through the registered lifecycle and prove recovery works
    // against the fresh incarnation.
    try sim.restartProcess(0);
    var recovery_future = try Io.concurrent(client_io, CrashRecovery.recoveryTask, .{&scenario});
    recovery_future.await(client_io);
    try sim.control.runTasksUntilIdle();
    if (sim.control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;

    const trace = try allocator.dupe(u8, world.traceBytes());
    errdefer allocator.free(trace);
    const error_name = try allocator.dupe(u8, scenario.reserve_error_name);
    return .{
        .allocator = allocator,
        .trace = trace,
        .reserve_error_name = error_name,
        .recovered_body_exact = scenario.recovered_body_exact,
    };
}

// --- Tests --------------------------------------------------------------------

test "beanstalkz produce/consume round trip over concurrent connections" {
    var outcome = try runRoundTrip(std.testing.allocator, 0xBEA0);
    defer outcome.deinit();

    try std.testing.expectEqual([3]u32{ 1, 2, 3 }, outcome.reserved_ids);
    try std.testing.expect(outcome.bodies_exact);
    try std.testing.expect(outcome.buried_state_seen);
    try std.testing.expect(outcome.kicked_state_seen);
    try std.testing.expect(outcome.empty_reserve_timed_out);
    try std.testing.expect(std.mem.indexOf(u8, outcome.trace, "beanstalkz.server.put id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.trace, "beanstalkz.client.reserved id=3") != null);
}

test "beanstalkz round trip replays byte-identically from the same seed" {
    var first = try runRoundTrip(std.testing.allocator, 0xBEA1);
    defer first.deinit();
    var second = try runRoundTrip(std.testing.allocator, 0xBEA1);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.trace, second.trace);
}

test "beanstalkz sequential connection churn drains in FIFO order" {
    var outcome = try runChurn(std.testing.allocator, 0xBEA2);
    defer outcome.deinit();

    try std.testing.expectEqual([churn_producer_count]u32{ 1, 2, 3, 4 }, outcome.drained_ids);
    try std.testing.expect(outcome.drained_exact);
    try std.testing.expectEqual(
        @as(usize, churn_producer_count),
        std.mem.count(u8, outcome.trace, "beanstalkz.client.churn_cycle"),
    );
}

test "beanstalkz blocking reserve crosses the virtual publish delay" {
    var outcome = try runDelayedPublish(std.testing.allocator, 0xBEA3);
    defer outcome.deinit();

    try std.testing.expect(outcome.reserved_body_exact);
    try std.testing.expect(outcome.elapsed_ns >= publish_delay_ns);
}

test "beanstalkz server crash interrupts a parked reserve and restart recovers" {
    var outcome = try runCrashRecovery(std.testing.allocator, 0xBEA4);
    defer outcome.deinit();

    // Pinned contract: a server death under a parked reserve surfaces as
    // beanstalkz's CommunicationFailure, not a hang or a success.
    try std.testing.expectEqualStrings("CommunicationFailure", outcome.reserve_error_name);
    try std.testing.expect(outcome.recovered_body_exact);
    try std.testing.expect(std.mem.indexOf(u8, outcome.trace, "process.kill node=0 reason=manual") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.trace, "process.restart node=0") != null);
}

test "beanstalkz crash recovery replays byte-identically from the same seed" {
    var first = try runCrashRecovery(std.testing.allocator, 0xBEA5);
    defer first.deinit();
    var second = try runCrashRecovery(std.testing.allocator, 0xBEA5);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.trace, second.trace);
}
