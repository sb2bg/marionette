//! External SUT validation: the unmodified beanstalkz queue client under
//! Marionette's deterministic `std.Io`.
//!
//! The SUT (`g41797/beanstalkz`) is a beanstalkd work-queue client written
//! against the injectable `std.Io` interface: `IpAddress.resolve` +
//! `connect`, stream reader/writer adapters, `Io.Mutex` locking, and
//! `shutdown(.both)` on disconnect. Marionette owns the harness side:
//! runner, seed, simulated network, a minimal in-memory beanstalkd server
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
//! - a server-process crash while the client is parked in reserve: the dead
//!   server's kernel closes the stream, which the client surfaces as the
//!   pinned `error.CommunicationFailure`, and a registered process restart
//!   brings up a fresh, empty server incarnation for recovery.
//!
//! Every scenario is a `mar.Harness`: tasks fail the run with
//! `Control.failRun` instead of panicking, outcomes are named checks, and
//! the runner's exact second execution replaces hand-compared traces, so a
//! failure leaves a capsule that replays and reduces.

const std = @import("std");
const mar = @import("marionette");
const bean = @import("beanstalkz");

const Io = std.Io;
const Client = bean.client;
const Job = bean.Job;

const server_port: u16 = 11300;
const server_addr = "10.0.0.1";
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
    control: mar.Control,
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
        self.control.record(fmt, args);
    }

    fn signalReady(self: *QueueServer) void {
        self.ready_flag = 1;
        self.io.futexWake(u32, &self.ready_flag, std.math.maxInt(u32));
    }

    /// Clients wait on the server process's futex namespace, so waits use
    /// the server io handle (same pattern as the dusty validation).
    fn waitReady(self: *QueueServer) std.Io.Cancelable!void {
        while (self.ready_flag == 0) {
            try self.io.futexWait(u32, &self.ready_flag, 0);
        }
    }

    fn acceptTask(self: *QueueServer) void {
        const address = Io.net.IpAddress.parseIp4(server_addr, server_port) catch unreachable;
        var listener = address.listen(self.io, .{}) catch |err| return self.control.failRun(err);
        defer listener.deinit(self.io);
        self.record("beanstalkz.server.listening port={}", .{server_port});
        self.signalReady();

        var handlers: [max_connections]?Io.Future(void) = @splat(null);
        defer for (&handlers) |*handler| {
            if (handler.*) |*future| future.await(self.io);
        };

        for (0..self.expected_connections) |index| {
            const stream = listener.accept(self.io) catch |err| return self.control.failRun(err);
            self.record("beanstalkz.server.accepted connection={}", .{index});
            handlers[index] = Io.concurrent(self.io, connectionTask, .{ self, stream }) catch |err| return self.control.failRun(err);
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

/// Every scenario: two nodes (server on node 0, clients on node 1), 30 ns
/// links, 10 ns ticks, and a harness-owned arena for server state.
const simulate: mar.World.SimulateOptions = .{
    .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 32 },
};
const tick_ns = 10;

/// Shared per-run state: the arena, the simulated server, and the client Io.
fn Base(comptime Self: type) type {
    return struct {
        fn initBase(sim: mar.Sim, expected_connections: usize) !Self {
            var self: Self = .{
                .control = sim.control,
                // Server state lives in node 0's simulated memory and is
                // freed by `deinit`.
                .arena_state = std.heap.ArenaAllocator.init((try sim.envForNode(0)).allocator()),
                .client_io = (try sim.envForNode(1)).io(),
                // The SUT allocates through the simulation's authority.
                .allocator = (try sim.envForNode(1)).allocator(),
                .server = undefined,
            };
            self.server = .{
                .arena = undefined,
                .control = sim.control,
                .io = (try sim.envForNode(0)).io(),
                .expected_connections = expected_connections,
            };
            try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
            return self;
        }
    };
}

fn fail(control: mar.Control, err: anyerror) void {
    control.failRun(err);
}

// --- Round trip -------------------------------------------------------------

const round_trip_bodies = [_][]const u8{ "job-alpha", "job-bravo", "job-charlie" };

const RoundTrip = struct {
    control: mar.Control,
    arena_state: std.heap.ArenaAllocator,
    server: QueueServer,
    client_io: Io,
    allocator: std.mem.Allocator,
    produced: u32 = 0,
    reserved_ids: [3]u32 = @splat(0),
    bodies_exact: bool = true,
    buried_state_seen: bool = false,
    kicked_state_seen: bool = false,
    empty_reserve_timed_out: bool = false,

    fn init(sim: mar.Sim) !RoundTrip {
        return Base(RoundTrip).initBase(sim, 2);
    }

    pub fn deinit(self: *RoundTrip) void {
        self.arena_state.deinit();
    }

    fn scenario(case: *mar.SimCase(RoundTrip)) !void {
        const self = &case.app;
        self.server.arena = self.arena_state.allocator();
        var server_future = try Io.concurrent(self.server.io, QueueServer.acceptTask, .{&self.server});
        var producer_future = try Io.concurrent(self.client_io, producerTask, .{self});
        var consumer_future = try Io.concurrent(self.client_io, consumerTask, .{self});
        producer_future.await(self.client_io);
        consumer_future.await(self.client_io);
        server_future.await(self.server.io);
        if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
    }

    fn producerTask(self: *RoundTrip) void {
        self.server.waitReady() catch return;
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();

        client.connect(server_addr, server_port) catch |err| return fail(self.control, err);
        client.use(orders_tube) catch |err| return fail(self.control, err);
        for (round_trip_bodies) |body| {
            const id = client.put(bean.DefaultPriority, 0, bean.DefaultTTR, body) catch |err| return fail(self.control, err);
            self.control.record("beanstalkz.client.put id={} bytes={}", .{ id, body.len });
        }
        self.produced = 1;
        self.client_io.futexWake(u32, &self.produced, 1);
    }

    fn consumerTask(self: *RoundTrip) void {
        self.server.waitReady() catch return;
        while (self.produced == 0) {
            self.client_io.futexWait(u32, &self.produced, 0) catch return;
        }

        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| return fail(self.control, err);

        const watching = client.watch(orders_tube) catch |err| return fail(self.control, err);
        if (watching != 2) return fail(self.control, error.UnexpectedWatchCount);
        _ = client.ignore("default") catch |err| return fail(self.control, err);

        var job: Job = .{};
        job.init(self.allocator) catch |err| return fail(self.control, err);
        defer job.deinit();

        for (round_trip_bodies, 0..) |expected_body, index| {
            client.reserve(5, &job) catch |err| return fail(self.control, err);
            const id = job.id() orelse return fail(self.control, error.JobWithoutId);
            self.reserved_ids[index] = id;
            if (!std.mem.eql(u8, job.body() orelse "", expected_body)) {
                self.bodies_exact = false;
            }
            self.control.record("beanstalkz.client.reserved id={} bytes={}", .{ id, job.actual_len });

            if (index == 1) {
                // Exercise the failure-state transitions on the middle job.
                client.bury(id, bean.DefaultPriority) catch |err| return fail(self.control, err);
                const buried = client.state(id) catch |err| return fail(self.control, err);
                self.buried_state_seen = buried == .buried;
                client.kick_job(id) catch |err| return fail(self.control, err);
                const kicked = client.state(id) catch |err| return fail(self.control, err);
                self.kicked_state_seen = kicked == .ready;
                // Take it back out of the ready queue before moving on.
                client.reserve(5, &job) catch |err| return fail(self.control, err);
            }
            client.delete(id) catch |err| return fail(self.control, err);
        }

        // Pinned contract: reserving from a drained queue surfaces the
        // protocol TIMED_OUT response as `error.Timeout`.
        if (client.reserve(1, &job)) |_| {
            return fail(self.control, error.EmptyReserveSucceeded);
        } else |err| {
            self.empty_reserve_timed_out = err == bean.ReturnedError.Timeout;
        }
    }

    fn fifoIds(case: *const mar.SimCase(RoundTrip)) !void {
        if (!std.mem.eql(u32, &case.app.reserved_ids, &.{ 1, 2, 3 })) return error.ReservedOutOfOrder;
        if (!case.app.bodies_exact) return error.BodyMismatch;
    }

    fn buryKick(case: *const mar.SimCase(RoundTrip)) !void {
        if (!case.app.buried_state_seen) return error.BuriedStateMissing;
        if (!case.app.kicked_state_seen) return error.KickedStateMissing;
    }

    fn emptyReserve(case: *const mar.SimCase(RoundTrip)) !void {
        if (!case.app.empty_reserve_timed_out) return error.EmptyReserveDidNotTimeOut;
    }

    const checks = [_]mar.StateCheck(mar.SimCase(RoundTrip)){
        .{ .name = "beanstalkz.fifo_exact", .check = fifoIds, .phase = .after_scenario },
        .{ .name = "beanstalkz.bury_kick", .check = buryKick, .phase = .after_scenario },
        .{ .name = "beanstalkz.empty_reserve_timeout", .check = emptyReserve, .phase = .after_scenario },
    };
};

pub const RoundTripHarness = mar.Harness(.{
    .init = RoundTrip.init,
    .scenario = RoundTrip.scenario,
    .checks = &RoundTrip.checks,
    .simulate = simulate,
    .name = "beanstalkz.round_trip",
});

// --- Connection churn --------------------------------------------------------

const churn_producer_count = 4;

const Churn = struct {
    control: mar.Control,
    arena_state: std.heap.ArenaAllocator,
    server: QueueServer,
    client_io: Io,
    allocator: std.mem.Allocator,
    drained_ids: [churn_producer_count]u32 = @splat(0),
    drained_exact: bool = true,

    fn init(sim: mar.Sim) !Churn {
        return Base(Churn).initBase(sim, churn_producer_count + 1);
    }

    pub fn deinit(self: *Churn) void {
        self.arena_state.deinit();
    }

    fn scenario(case: *mar.SimCase(Churn)) !void {
        const self = &case.app;
        self.server.arena = self.arena_state.allocator();
        var server_future = try Io.concurrent(self.server.io, QueueServer.acceptTask, .{&self.server});
        var client_future = try Io.concurrent(self.client_io, runTask, .{self});
        client_future.await(self.client_io);
        server_future.await(self.server.io);
        if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
    }

    fn runTask(self: *Churn) void {
        self.server.waitReady() catch return;

        // Fresh connection per job: connect, put, quit + shutdown + close.
        for (0..churn_producer_count) |index| {
            var client = Client.init(self.allocator, self.client_io);
            client.connect(server_addr, server_port) catch |err| return fail(self.control, err);
            client.use(orders_tube) catch |err| return fail(self.control, err);
            var body_buffer: [16]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buffer, "churn-{}", .{index}) catch unreachable;
            _ = client.put(bean.DefaultPriority, 0, bean.DefaultTTR, body) catch |err| return fail(self.control, err);
            client.disconnect();
            self.control.record("beanstalkz.client.churn_cycle index={}", .{index});
        }

        // One consumer connection drains everything in FIFO id order.
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| return fail(self.control, err);
        _ = client.watch(orders_tube) catch |err| return fail(self.control, err);

        var job: Job = .{};
        job.init(self.allocator) catch |err| return fail(self.control, err);
        defer job.deinit();

        for (0..churn_producer_count) |index| {
            client.reserve(5, &job) catch |err| return fail(self.control, err);
            const id = job.id() orelse return fail(self.control, error.JobWithoutId);
            self.drained_ids[index] = id;
            var expected_buffer: [16]u8 = undefined;
            const expected = std.fmt.bufPrint(&expected_buffer, "churn-{}", .{index}) catch unreachable;
            if (!std.mem.eql(u8, job.body() orelse "", expected)) {
                self.drained_exact = false;
            }
            client.delete(id) catch |err| return fail(self.control, err);
        }
    }

    fn fifoDrain(case: *const mar.SimCase(Churn)) !void {
        if (!std.mem.eql(u32, &case.app.drained_ids, &.{ 1, 2, 3, 4 })) return error.DrainOutOfOrder;
        if (!case.app.drained_exact) return error.BodyMismatch;
    }

    const checks = [_]mar.StateCheck(mar.SimCase(Churn)){
        .{ .name = "beanstalkz.churn_fifo_drain", .check = fifoDrain, .phase = .after_scenario },
    };
};

pub const ChurnHarness = mar.Harness(.{
    .init = Churn.init,
    .scenario = Churn.scenario,
    .checks = &Churn.checks,
    .simulate = simulate,
    .name = "beanstalkz.churn",
});

// --- Blocking reserve across virtual time -------------------------------------

const delayed_body = "published-after-five-seconds";
const publish_delay_ns = 5_000_000_000; // 5 virtual seconds

const DelayedPublish = struct {
    control: mar.Control,
    arena_state: std.heap.ArenaAllocator,
    server: QueueServer,
    client_io: Io,
    allocator: std.mem.Allocator,
    reserved_body_exact: bool = false,
    elapsed_ns: u64 = 0,

    fn init(sim: mar.Sim) !DelayedPublish {
        return Base(DelayedPublish).initBase(sim, 2);
    }

    pub fn deinit(self: *DelayedPublish) void {
        self.arena_state.deinit();
    }

    fn scenario(case: *mar.SimCase(DelayedPublish)) !void {
        const self = &case.app;
        self.server.arena = self.arena_state.allocator();
        var server_future = try Io.concurrent(self.server.io, QueueServer.acceptTask, .{&self.server});
        var producer_future = try Io.concurrent(self.client_io, producerTask, .{self});
        var consumer_future = try Io.concurrent(self.client_io, consumerTask, .{self});
        producer_future.await(self.client_io);
        consumer_future.await(self.client_io);
        server_future.await(self.server.io);
        self.elapsed_ns = case.control().now();
        if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
    }

    fn producerTask(self: *DelayedPublish) void {
        self.server.waitReady() catch return;
        Io.sleep(self.client_io, .fromNanoseconds(publish_delay_ns), .awake) catch return;

        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| return fail(self.control, err);
        client.use(orders_tube) catch |err| return fail(self.control, err);
        _ = client.put(bean.DefaultPriority, 0, bean.DefaultTTR, delayed_body) catch |err| return fail(self.control, err);
    }

    fn consumerTask(self: *DelayedPublish) void {
        self.server.waitReady() catch return;
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| return fail(self.control, err);
        _ = client.watch(orders_tube) catch |err| return fail(self.control, err);

        var job: Job = .{};
        job.init(self.allocator) catch |err| return fail(self.control, err);
        defer job.deinit();

        // Parks in the response read while virtual time crosses the
        // producer's five-second publish delay.
        client.reserve(30, &job) catch |err| return fail(self.control, err);
        self.reserved_body_exact = std.mem.eql(u8, job.body() orelse "", delayed_body);
        client.delete(job.id() orelse return fail(self.control, error.JobWithoutId)) catch |err| return fail(self.control, err);
    }

    fn reservedAfterDelay(case: *const mar.SimCase(DelayedPublish)) !void {
        if (!case.app.reserved_body_exact) return error.BodyMismatch;
        if (case.app.elapsed_ns < publish_delay_ns) return error.ReservedBeforePublish;
    }

    const checks = [_]mar.StateCheck(mar.SimCase(DelayedPublish)){
        .{ .name = "beanstalkz.reserve_crosses_delay", .check = reservedAfterDelay, .phase = .after_scenario },
    };
};

pub const DelayedPublishHarness = mar.Harness(.{
    .init = DelayedPublish.init,
    .scenario = DelayedPublish.scenario,
    .checks = &DelayedPublish.checks,
    .simulate = simulate,
    .name = "beanstalkz.delayed_publish",
});

// --- Server crash during a parked reserve -------------------------------------

const recovery_body = "job-after-restart";

const CrashRecovery = struct {
    control: mar.Control,
    arena_state: std.heap.ArenaAllocator,
    server: QueueServer,
    client_io: Io,
    allocator: std.mem.Allocator,
    lifecycle: ServerLifecycle = undefined,
    parked: u32 = 0,
    reserve_error: ?anyerror = null,
    recovered_body_exact: bool = false,

    fn init(sim: mar.Sim) !CrashRecovery {
        return Base(CrashRecovery).initBase(sim, 1);
    }

    pub fn deinit(self: *CrashRecovery) void {
        self.arena_state.deinit();
    }

    fn scenario(case: *mar.SimCase(CrashRecovery)) !void {
        const self = &case.app;
        const control = case.control();
        self.server.arena = self.arena_state.allocator();
        self.lifecycle = .{ .server = &self.server };
        try case.sim.registerProcess(0, .{
            .ptr = &self.lifecycle,
            .on_kill = ServerLifecycle.onKill,
            .restart = ServerLifecycle.restart,
        });

        _ = try Io.concurrent(self.server.io, QueueServer.acceptTaskDetached, .{&self.server});
        var victim_future = try Io.concurrent(self.client_io, victimTask, .{self});

        // Let the victim connect and park in its reserve read.
        while (self.parked == 0) {
            self.client_io.futexWait(u32, &self.parked, 0) catch break;
        }
        try control.runFor(1_000_000);

        // Crash the server process: its listener, accept task, and handler
        // die; the kernel's FIN reaches the parked client.
        try control.process.kill(0);
        victim_future.await(self.client_io);

        // Restart through the registered lifecycle and prove recovery works
        // against the fresh incarnation.
        try control.process.restart(0);
        var recovery_future = try Io.concurrent(self.client_io, recoveryTask, .{self});
        recovery_future.await(self.client_io);
        try control.runTasksUntilIdle();
        if (control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;
    }

    fn victimTask(self: *CrashRecovery) void {
        self.server.waitReady() catch return;
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| return fail(self.control, err);
        _ = client.watch(orders_tube) catch |err| return fail(self.control, err);

        var job: Job = .{};
        job.init(self.allocator) catch |err| return fail(self.control, err);
        defer job.deinit();

        self.parked = 1;
        self.client_io.futexWake(u32, &self.parked, 1);

        // The queue is empty, so this parks in the stream read until the
        // harness kills the server process; the client then reads the end of
        // the stream that the dead server's kernel closed.
        if (client.reserve(60, &job)) |_| {
            return fail(self.control, error.ReserveAgainstCrashedServerSucceeded);
        } else |err| {
            self.reserve_error = err;
        }
        self.control.record("beanstalkz.client.reserve_interrupted error={s}", .{@errorName(self.reserve_error.?)});
    }

    fn recoveryTask(self: *CrashRecovery) void {
        self.server.waitReady() catch return;
        var client = Client.init(self.allocator, self.client_io);
        defer client.disconnect();
        client.connect(server_addr, server_port) catch |err| return fail(self.control, err);
        client.use(orders_tube) catch |err| return fail(self.control, err);
        _ = client.put(bean.DefaultPriority, 0, bean.DefaultTTR, recovery_body) catch |err| return fail(self.control, err);
        _ = client.watch(orders_tube) catch |err| return fail(self.control, err);

        var job: Job = .{};
        job.init(self.allocator) catch |err| return fail(self.control, err);
        defer job.deinit();
        client.reserve(5, &job) catch |err| return fail(self.control, err);
        self.recovered_body_exact = std.mem.eql(u8, job.body() orelse "", recovery_body);
        client.delete(job.id() orelse return fail(self.control, error.JobWithoutId)) catch |err| return fail(self.control, err);
    }

    /// Pinned contract: a server death under a parked reserve surfaces as
    /// beanstalkz's CommunicationFailure, not a hang or a success.
    fn interruptedReserve(case: *const mar.SimCase(CrashRecovery)) !void {
        const err = case.app.reserve_error orelse return error.ReserveNotInterrupted;
        if (err != error.CommunicationFailure) return error.UnexpectedReserveError;
    }

    fn recovered(case: *const mar.SimCase(CrashRecovery)) !void {
        if (!case.app.recovered_body_exact) return error.RecoveryFailed;
    }

    const checks = [_]mar.StateCheck(mar.SimCase(CrashRecovery)){
        .{ .name = "beanstalkz.crash_interrupts_reserve", .check = interruptedReserve, .phase = .after_scenario },
        .{ .name = "beanstalkz.restart_recovers", .check = recovered, .phase = .after_scenario },
    };
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

pub const CrashRecoveryHarness = mar.Harness(.{
    .init = CrashRecovery.init,
    .scenario = CrashRecovery.scenario,
    .checks = &CrashRecovery.checks,
    .simulate = simulate,
    .name = "beanstalkz.crash_recovery",
});

// --- Tests --------------------------------------------------------------------
// Every run executes twice and compares traces, so passing runs also prove
// byte-identical replay; no test compares traces by hand.

test "beanstalkz produce/consume round trip over concurrent connections" {
    var report = try RoundTripHarness.run(std.testing.allocator, .{ .seed = 0xBEA0, .tick_ns = tick_ns });
    defer report.deinit();
    if (report == .failed) report.failed.print();
    try std.testing.expect(report == .passed);
    try mar.expectTraceContains(report.passed.trace, "beanstalkz.server.put id=1");
    try mar.expectTraceContains(report.passed.trace, "beanstalkz.client.reserved id=3");
}

test "beanstalkz sequential connection churn drains in FIFO order" {
    var report = try ChurnHarness.run(std.testing.allocator, .{ .seed = 0xBEA2, .tick_ns = tick_ns });
    defer report.deinit();
    if (report == .failed) report.failed.print();
    try std.testing.expect(report == .passed);
    try std.testing.expectEqual(
        @as(usize, churn_producer_count),
        std.mem.count(u8, report.passed.trace, "beanstalkz.client.churn_cycle"),
    );
}

test "beanstalkz blocking reserve crosses the virtual publish delay" {
    try DelayedPublishHarness.expectPass(std.testing.allocator, .{ .seed = 0xBEA3, .tick_ns = tick_ns });
}

test "beanstalkz server crash interrupts a parked reserve and restart recovers" {
    var report = try CrashRecoveryHarness.run(std.testing.allocator, .{ .seed = 0xBEA4, .tick_ns = tick_ns });
    defer report.deinit();
    if (report == .failed) report.failed.print();
    try std.testing.expect(report == .passed);
    try mar.expectTraceContains(report.passed.trace, "process.kill node=0 reason=manual");
    try mar.expectTraceContains(report.passed.trace, "process.restart node=0");
}

test "beanstalkz validations fuzz across seeds and replay from capsules" {
    try RoundTripHarness.fuzz(std.testing.allocator, .{ .seed = 0xBEA6, .tick_ns = tick_ns }, .{ .seeds = 8 });
    var report = try CrashRecoveryHarness.run(std.testing.allocator, .{ .seed = 0xBEA5, .tick_ns = tick_ns });
    defer report.deinit();
    const identity: mar.ReplayIdentity = .{ .build = "beanstalkz-validation", .sut = "beanstalkz@d8ac61183d80b4cf0e15c52ab4edaea69cb3a56c" };
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try CrashRecoveryHarness.replay(std.testing.allocator, &capsule, identity);
    defer replayed.deinit();
    try std.testing.expect(replayed == .passed);
}
