//! External SUT validation: the unmodified dusty HTTP library under
//! Marionette's deterministic `std.Io`.
//!
//! The SUT (`lalinsky/dusty`) is an HTTP/1.1 client/server library written
//! against the injectable `std.Io` interface plus its vendored llhttp parser.
//! Marionette owns the harness side: world, seed, simulated network, latency,
//! trace, and the response oracle.
//!
//! The harness runs dusty's real `Server.listen` accept loop as a simulated
//! task and shuts it down through cooperative cancellation in two shapes:
//!
//! - Clean shutdown: all clients have disconnected, so canceling the listen
//!   task delivers `error.Canceled` inside `accept`, the connection drain
//!   sees nothing active, and `listen` returns `error.Canceled`.
//! - Hung-connection shutdown: a keep-alive handler is still parked in a
//!   stream read. The drain times out (`listen` returns `error.Timeout`,
//!   dusty's contract for shutdown with connections that never drained) and
//!   dusty's deferred `Group.cancel` unparks the handler with
//!   `error.Canceled` on its way out.

const std = @import("std");
const mar = @import("marionette");
const http = @import("dusty");

const Io = std.Io;

const hello_body = "hello from the simulation\n";
const echo_payload = "determinism";
const base_url = "http://127.0.0.1:4580";
const dusty_task_stack_size = 8 * 1024 * 1024;
const chunk_len = 4 * 1024;
const total_chunks = 16;
const chunk_pattern: [chunk_len]u8 = @splat('x');
const max_retry_attempts = 3;

fn handleHello(req: *http.Request, res: *http.Response) !void {
    _ = req;
    res.body = hello_body;
}

fn handleEcho(req: *http.Request, res: *http.Response) !void {
    var reader = req.reader();
    const payload = try reader.interface.allocRemaining(req.arena, .limited(4096));
    res.body = try std.fmt.allocPrint(req.arena, "echo:{s}", .{payload});
}

pub const Outcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    hello_status: u32,
    hello_body: []u8,
    echo_status: u32,
    echo_body: []u8,
    second_hello_status: u32,
    graceful_shutdown: bool,

    pub fn deinit(self: *Outcome) void {
        self.allocator.free(self.trace);
        self.allocator.free(self.hello_body);
        self.allocator.free(self.echo_body);
        self.* = undefined;
    }
};

pub const FaultMode = enum {
    before_response,
    mid_response,
};

pub const FaultOptions = struct {
    pre_chunks: usize = total_chunks / 2,
};

pub const FaultOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    first_error_name: []u8,
    retry_attempts: u32,
    final_status: u32,
    final_body: []u8,
    shutdown_ok: bool,

    pub fn deinit(self: *FaultOutcome) void {
        self.allocator.free(self.trace);
        self.allocator.free(self.first_error_name);
        self.allocator.free(self.final_body);
        self.* = undefined;
    }
};

const Scenario = struct {
    allocator: std.mem.Allocator,
    world: *mar.World,
    server_io: Io,
    client_io: Io,
    server: *http.Server(void),
    hello_status: u32 = 0,
    hello_body_copy: []u8 = &.{},
    echo_status: u32 = 0,
    echo_body_copy: []u8 = &.{},
    second_hello_status: u32 = 0,
    graceful_shutdown: bool = false,
    timeout_shutdown: bool = false,
    /// Client deliberately left open across shutdown so its keep-alive
    /// handler stays parked in a read. Owned by the scenario runner.
    hung_client: ?http.Client = null,

    fn record(self: *Scenario, comptime fmt: []const u8, args: anytype) void {
        self.world.record(fmt, args) catch @panic("dusty_http trace record failed");
    }

    fn serverTask(self: *Scenario) void {
        self.record("dusty_http.server.listen_start", .{});
        const address: http.Address = .{
            .ip = Io.net.IpAddress.parseIp4("127.0.0.1", 4580) catch unreachable,
        };
        self.server.listen(address) catch |err| switch (err) {
            error.Canceled => {
                self.graceful_shutdown = true;
                self.record("dusty_http.server.graceful_shutdown", .{});
                return;
            },
            error.Timeout => {
                // dusty's contract for shutdown while a connection never
                // drained: the drain wait times out and the deferred group
                // cancel sweeps the remaining handlers on the way out.
                self.timeout_shutdown = true;
                self.record("dusty_http.server.timeout_shutdown", .{});
                return;
            },
            else => std.debug.panic("dusty_http listen failed: {}", .{err}),
        };
        @panic("dusty_http listen returned without a shutdown request");
    }

    fn clientTask(self: *Scenario) void {
        // The ready event lives in the server process's futex namespace, so
        // the harness waits on it with the server's io handle.
        self.server.ready.wait(self.server_io) catch @panic("dusty_http ready wait failed");
        self.record("dusty_http.client.server_ready", .{});

        // First connection: two requests over dusty's keep-alive pool.
        {
            var client = http.Client.init(self.allocator, self.client_io, .{});
            defer client.deinit();

            {
                var response = client.fetch(base_url ++ "/hello", .{}) catch |err| {
                    std.debug.panic("dusty_http GET /hello failed: {}", .{err});
                };
                defer response.deinit();
                self.hello_status = @intFromEnum(response.status());
                const payload = (response.body() catch @panic("hello body read failed")) orelse "";
                self.hello_body_copy = self.allocator.dupe(u8, payload) catch @panic("dusty_http oom");
                self.record(
                    "dusty_http.client.hello status={} bytes={}",
                    .{ self.hello_status, payload.len },
                );
            }

            {
                var response = client.fetch(base_url ++ "/echo", .{
                    .method = .post,
                    .body = echo_payload,
                }) catch |err| {
                    std.debug.panic("dusty_http POST /echo failed: {}", .{err});
                };
                defer response.deinit();
                self.echo_status = @intFromEnum(response.status());
                const payload = (response.body() catch @panic("echo body read failed")) orelse "";
                self.echo_body_copy = self.allocator.dupe(u8, payload) catch @panic("dusty_http oom");
                self.record(
                    "dusty_http.client.echo status={} bytes={}",
                    .{ self.echo_status, payload.len },
                );
            }
        }

        // Second connection: proves the accept loop serves more than one
        // connection before shutdown.
        {
            var client = http.Client.init(self.allocator, self.client_io, .{});
            defer client.deinit();

            var response = client.fetch(base_url ++ "/hello", .{}) catch |err| {
                std.debug.panic("dusty_http second GET /hello failed: {}", .{err});
            };
            defer response.deinit();
            self.second_hello_status = @intFromEnum(response.status());
            self.record(
                "dusty_http.client.second_hello status={}",
                .{self.second_hello_status},
            );
        }
    }

    fn hungClientTask(self: *Scenario) void {
        self.server.ready.wait(self.server_io) catch @panic("dusty_http ready wait failed");
        self.record("dusty_http.client.server_ready", .{});

        // One keep-alive request, then leave the connection open: the
        // server-side handler parks in a read waiting for a next request
        // that never comes.
        self.hung_client = http.Client.init(self.allocator, self.client_io, .{});
        var response = self.hung_client.?.fetch(base_url ++ "/hello", .{}) catch |err| {
            std.debug.panic("dusty_http hung GET /hello failed: {}", .{err});
        };
        defer response.deinit();
        self.hello_status = @intFromEnum(response.status());
        self.record("dusty_http.client.hello status={}", .{self.hello_status});
    }
};

const FaultScenario = struct {
    allocator: std.mem.Allocator,
    world: *mar.World,
    control: mar.Control,
    server_io: Io,
    client_io: Io,
    harness_io: Io,
    server: *http.Server(FaultScenario),
    mode: FaultMode,
    pre_chunks: usize,
    request_reached: u32 = 0,
    mid_response_reached: u32 = 0,
    partitioned: u32 = 0,
    client_failed: u32 = 0,
    healed: u32 = 0,
    first_error_name: []u8 = &.{},
    retry_attempts: u32 = 0,
    final_status: u32 = 0,
    final_body_copy: []u8 = &.{},
    graceful_shutdown: bool = false,
    timeout_shutdown: bool = false,
    fetch_succeeded_before_cut: bool = false,
    short_success: bool = false,
    retry_failed: bool = false,
    retry_body_mismatch: bool = false,

    fn shutdownOk(self: *const FaultScenario) bool {
        return self.graceful_shutdown or self.timeout_shutdown;
    }

    fn signal(self: *FaultScenario, flag: *u32) void {
        flag.* = 1;
        self.harness_io.futexWake(u32, flag, 1);
    }

    fn waitFor(self: *FaultScenario, flag: *u32) std.Io.Cancelable!void {
        while (flag.* == 0) {
            try self.harness_io.futexWait(u32, flag, 0);
        }
    }

    fn record(self: *FaultScenario, comptime fmt: []const u8, args: anytype) void {
        self.world.record(fmt, args) catch @panic("dusty_fault trace record failed");
    }

    fn storeFirstError(self: *FaultScenario, err: anyerror) void {
        const name = @errorName(err);
        if (self.first_error_name.len != 0) self.allocator.free(self.first_error_name);
        self.first_error_name = self.allocator.dupe(u8, name) catch @panic("dusty_fault oom");
        self.record("dusty_fault.client.fetch_error err={s}", .{name});
    }

    fn setFinalBody(self: *FaultScenario, bytes: []const u8) void {
        if (self.final_body_copy.len != 0) self.allocator.free(self.final_body_copy);
        self.final_body_copy = self.allocator.dupe(u8, bytes) catch @panic("dusty_fault oom");
    }

    fn serverTask(self: *FaultScenario) void {
        self.record("dusty_fault.server.listen_start", .{});
        const address: http.Address = .{
            .ip = Io.net.IpAddress.parseIp4("127.0.0.1", 4580) catch unreachable,
        };
        self.server.listen(address) catch |err| switch (err) {
            error.Canceled => {
                self.graceful_shutdown = true;
                self.record("dusty_fault.server.graceful_shutdown", .{});
                return;
            },
            error.Timeout => {
                self.timeout_shutdown = true;
                self.record("dusty_fault.server.timeout_shutdown", .{});
                return;
            },
            else => std.debug.panic("dusty_fault listen failed: {}", .{err}),
        };
        @panic("dusty_fault listen returned without a shutdown request");
    }

    fn faultController(self: *FaultScenario) std.Io.Cancelable!void {
        switch (self.mode) {
            .before_response => try self.waitFor(&self.request_reached),
            .mid_response => try self.waitFor(&self.mid_response_reached),
        }

        const server_side = [_]mar.NodeId{0};
        const client_side = [_]mar.NodeId{1};
        self.control.network.partition(&server_side, &client_side) catch @panic("dusty_fault partition failed");
        self.record("dusty_fault.partition", .{});
        self.signal(&self.partitioned);

        try self.waitFor(&self.client_failed);
        self.control.network.heal() catch @panic("dusty_fault heal failed");
        self.record("dusty_fault.heal", .{});
        self.signal(&self.healed);
    }

    fn clientTask(self: *FaultScenario) std.Io.Cancelable!void {
        self.server.ready.wait(self.server_io) catch @panic("dusty_fault ready wait failed");
        self.record("dusty_fault.client.server_ready", .{});

        self.firstFetch();
        if (self.fetch_succeeded_before_cut or self.short_success) return;

        try self.waitFor(&self.healed);
        self.retryAfterHeal();
    }

    fn firstFetch(self: *FaultScenario) void {
        var client = http.Client.init(self.allocator, self.client_io, .{
            .max_idle_connections = 0,
            .max_response_size = total_chunks * chunk_len + 1024,
        });
        defer client.deinit();

        const url = switch (self.mode) {
            .before_response => base_url ++ "/held",
            .mid_response => base_url ++ "/large",
        };

        var response = client.fetch(url, .{ .decompress = false }) catch |err| {
            self.storeFirstError(err);
            self.signal(&self.client_failed);
            return;
        };
        defer response.deinit();

        const payload = response.body() catch |err| {
            self.storeFirstError(err);
            self.signal(&self.client_failed);
            return;
        } orelse "";

        switch (self.mode) {
            .before_response => {
                self.fetch_succeeded_before_cut = true;
                self.record("dusty_fault.client.unexpected_success bytes={}", .{payload.len});
            },
            .mid_response => {
                if (payloadIsFullChunkOracle(payload)) {
                    self.fetch_succeeded_before_cut = true;
                    self.record("dusty_fault.client.unexpected_success bytes={}", .{payload.len});
                } else {
                    self.short_success = true;
                    self.record("dusty_fault.client.short_success bytes={}", .{payload.len});
                }
            },
        }
        self.signal(&self.client_failed);
    }

    fn retryAfterHeal(self: *FaultScenario) void {
        const url = switch (self.mode) {
            .before_response => base_url ++ "/held",
            .mid_response => base_url ++ "/large",
        };

        var attempt: u32 = 1;
        while (attempt <= max_retry_attempts) : (attempt += 1) {
            // Fresh client per attempt: dusty's pool may retain dead keep-alive
            // connections, and pool recovery belongs to the later 16d slice.
            var client = http.Client.init(self.allocator, self.client_io, .{
                .max_idle_connections = 0,
                .max_response_size = total_chunks * chunk_len + 1024,
            });
            defer client.deinit();

            var response = client.fetch(url, .{ .decompress = false }) catch |err| {
                self.record("dusty_fault.client.retry attempt={} outcome={s}", .{ attempt, @errorName(err) });
                continue;
            };
            defer response.deinit();

            const payload = response.body() catch |err| {
                self.record("dusty_fault.client.retry attempt={} outcome={s}", .{ attempt, @errorName(err) });
                continue;
            } orelse "";

            const status: u32 = @intFromEnum(response.status());
            const body_ok = switch (self.mode) {
                .before_response => std.mem.eql(u8, payload, hello_body),
                .mid_response => payloadIsFullChunkOracle(payload),
            };
            if (status != 200 or !body_ok) {
                self.retry_body_mismatch = true;
                self.record(
                    "dusty_fault.client.retry attempt={} outcome=bad_response status={} bytes={}",
                    .{ attempt, status, payload.len },
                );
                return;
            }

            self.retry_attempts = attempt;
            self.final_status = status;
            self.setFinalBody(payload);
            self.record("dusty_fault.client.retry attempt={} outcome=ok", .{attempt});
            return;
        }

        self.retry_failed = true;
    }
};

fn handleHeld(scenario: *FaultScenario, req: *http.Request, res: *http.Response) !void {
    _ = req;
    res.keepalive = false;
    scenario.record("dusty_fault.server.request_reached", .{});
    scenario.signal(&scenario.request_reached);
    try scenario.waitFor(&scenario.partitioned);
    res.body = hello_body;
}

fn handleLarge(scenario: *FaultScenario, req: *http.Request, res: *http.Response) !void {
    _ = req;
    res.keepalive = false;
    for (0..total_chunks) |i| {
        try res.chunk(&chunk_pattern);
        if (i + 1 == scenario.pre_chunks) {
            scenario.record("dusty_fault.server.mid_response chunks_sent={}", .{i + 1});
            scenario.signal(&scenario.mid_response_reached);
            try scenario.waitFor(&scenario.partitioned);
        }
    }
}

fn payloadIsFullChunkOracle(payload: []const u8) bool {
    if (payload.len != total_chunks * chunk_len) return false;
    for (payload) |byte| {
        if (byte != 'x') return false;
    }
    return true;
}

pub fn runScenario(allocator: std.mem.Allocator, seed: u64) !Outcome {
    var world = try mar.World.init(allocator, .{
        .seed = seed,
        .tick_ns = 10,
    });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{
            .nodes = 2,
            .service_nodes = 1,
            .path_capacity = 32,
        },
        // dusty's Debug-mode fetch frames are platform-sensitive and deep;
        // Linux/x86_64 needs more than the default stack to enter fetchInternal.
        .task_stack_size = dusty_task_stack_size,
    });
    const server_env = try sim.envForNode(0);
    const client_env = try sim.envForNode(1);
    const server_io = server_env.io();
    const client_io = client_env.io();

    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    var server = http.Server(void).init(allocator, server_io, .{}, {});
    defer server.deinit();
    server.router.get("/hello", handleHello);
    server.router.post("/echo", handleEcho);

    var scenario = Scenario{
        .allocator = allocator,
        .world = &world,
        .server_io = server_io,
        .client_io = client_io,
        .server = &server,
    };

    var server_future = try Io.concurrent(server_io, Scenario.serverTask, .{&scenario});
    var client_future = try Io.concurrent(client_io, Scenario.clientTask, .{&scenario});

    client_future.await(client_io);
    // Graceful shutdown: cancellation lands in dusty's accept park, the
    // server drains its connections, and its group cancel sweeps handlers.
    server_future.cancel(server_io);
    if (sim.control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;

    const trace = try allocator.dupe(u8, world.traceBytes());
    errdefer allocator.free(trace);

    return .{
        .allocator = allocator,
        .trace = trace,
        .hello_status = scenario.hello_status,
        .hello_body = scenario.hello_body_copy,
        .echo_status = scenario.echo_status,
        .echo_body = scenario.echo_body_copy,
        .second_hello_status = scenario.second_hello_status,
        .graceful_shutdown = scenario.graceful_shutdown,
    };
}

pub const HungOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    hello_status: u32,
    timeout_shutdown: bool,
    cancel_deliveries: usize,

    pub fn deinit(self: *HungOutcome) void {
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

/// Shutdown while a keep-alive handler is still parked in a stream read.
pub fn runHungShutdownScenario(allocator: std.mem.Allocator, seed: u64) !HungOutcome {
    var world = try mar.World.init(allocator, .{
        .seed = seed,
        .tick_ns = 10,
    });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{
            .nodes = 2,
            .service_nodes = 1,
            .path_capacity = 32,
        },
        // dusty's Debug-mode fetch frames are platform-sensitive and deep;
        // Linux/x86_64 needs more than the default stack to enter fetchInternal.
        .task_stack_size = dusty_task_stack_size,
    });
    const server_env = try sim.envForNode(0);
    const client_env = try sim.envForNode(1);
    const server_io = server_env.io();
    const client_io = client_env.io();

    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    var server = http.Server(void).init(allocator, server_io, .{}, {});
    defer server.deinit();
    server.router.get("/hello", handleHello);

    var scenario = Scenario{
        .allocator = allocator,
        .world = &world,
        .server_io = server_io,
        .client_io = client_io,
        .server = &server,
    };
    defer if (scenario.hung_client) |*client| client.deinit();

    var server_future = try Io.concurrent(server_io, Scenario.serverTask, .{&scenario});
    var client_future = try Io.concurrent(client_io, Scenario.hungClientTask, .{&scenario});

    client_future.await(client_io);
    // The handler for the hung client is still parked in a keep-alive read.
    // Cancellation lands in accept, the drain times out, and dusty's
    // deferred group cancel must sweep the parked handler.
    server_future.cancel(server_io);
    if (sim.control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;

    const trace = try allocator.dupe(u8, world.traceBytes());
    errdefer allocator.free(trace);

    return .{
        .allocator = allocator,
        .trace = trace,
        .hello_status = scenario.hello_status,
        .timeout_shutdown = scenario.timeout_shutdown,
        .cancel_deliveries = std.mem.count(u8, trace, "scheduler.cancel_deliver task="),
    };
}

pub fn runBeforeResponsePartitionScenario(allocator: std.mem.Allocator, seed: u64) !FaultOutcome {
    return runFaultScenario(allocator, seed, .before_response, .{});
}

pub fn runMidResponsePartitionScenario(
    allocator: std.mem.Allocator,
    seed: u64,
    options: FaultOptions,
) !FaultOutcome {
    return runFaultScenario(allocator, seed, .mid_response, options);
}

fn runFaultScenario(
    allocator: std.mem.Allocator,
    seed: u64,
    mode: FaultMode,
    options: FaultOptions,
) !FaultOutcome {
    if (mode == .mid_response and (options.pre_chunks == 0 or options.pre_chunks >= total_chunks)) {
        return error.InvalidPreChunkCount;
    }

    var world = try mar.World.init(allocator, .{
        .seed = seed,
        .tick_ns = 10,
    });
    defer world.deinit();

    const sim = try world.simulate(.{
        .network = .{
            .nodes = 2,
            .service_nodes = 1,
            // A 16-chunk response emits many stream frames before the
            // cooperative client can drain them; keep this above the full
            // response frame count so the oracle tests partition behavior,
            // not queue capacity.
            .path_capacity = 512,
        },
        // dusty's Debug-mode fetch frames are platform-sensitive and deep;
        // Linux/x86_64 needs more than the default stack to enter fetchInternal.
        .task_stack_size = dusty_task_stack_size,
    });
    const server_env = try sim.envForNode(0);
    const client_env = try sim.envForNode(1);
    const server_io = server_env.io();
    const client_io = client_env.io();
    const harness_io = sim.env.io();

    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    var scenario = FaultScenario{
        .allocator = allocator,
        .world = &world,
        .control = sim.control,
        .server_io = server_io,
        .client_io = client_io,
        .harness_io = harness_io,
        .server = undefined,
        .mode = mode,
        .pre_chunks = options.pre_chunks,
    };
    errdefer allocator.free(scenario.first_error_name);
    errdefer allocator.free(scenario.final_body_copy);

    var server = http.Server(FaultScenario).init(allocator, server_io, .{}, &scenario);
    defer server.deinit();
    scenario.server = &server;

    switch (mode) {
        .before_response => server.router.get("/held", handleHeld),
        .mid_response => server.router.get("/large", handleLarge),
    }

    var server_future = Io.async(server_io, FaultScenario.serverTask, .{&scenario});
    var client_future = Io.async(client_io, FaultScenario.clientTask, .{&scenario});
    var controller_future = Io.async(harness_io, FaultScenario.faultController, .{&scenario});
    var tasks_running = true;
    errdefer if (tasks_running) {
        _ = client_future.cancel(client_io) catch {};
        _ = controller_future.cancel(harness_io) catch {};
        server_future.cancel(server_io);
    };

    try client_future.await(client_io);
    try controller_future.await(harness_io);
    server_future.cancel(server_io);
    tasks_running = false;
    if (sim.control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;

    if (scenario.fetch_succeeded_before_cut) return error.FetchSucceededBeforeCut;
    if (scenario.short_success) return error.ShortSuccess;
    if (scenario.retry_failed) return error.RetryDidNotConverge;
    if (scenario.retry_body_mismatch) return error.RetryBodyMismatch;
    if (!scenario.shutdownOk()) return error.ServerShutdownDidNotComplete;
    if (scenario.first_error_name.len == 0) return error.FirstFetchDidNotFail;
    if (scenario.retry_attempts == 0) return error.RetryDidNotRun;

    const trace = try allocator.dupe(u8, world.traceBytes());
    errdefer allocator.free(trace);

    const first_error_name = scenario.first_error_name;
    scenario.first_error_name = &.{};
    const final_body = scenario.final_body_copy;
    scenario.final_body_copy = &.{};

    return .{
        .allocator = allocator,
        .trace = trace,
        .first_error_name = first_error_name,
        .retry_attempts = scenario.retry_attempts,
        .final_status = scenario.final_status,
        .final_body = final_body,
        .shutdown_ok = scenario.shutdownOk(),
    };
}

fn expectTraceContains(trace: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, trace, needle) != null);
}

fn expectMidResponseNetworkOracle(trace: []const u8) !void {
    const partition = std.mem.indexOf(u8, trace, "dusty_fault.partition") orelse return error.PartitionTraceMissing;
    const heal = std.mem.indexOfPos(u8, trace, partition, "dusty_fault.heal") orelse return error.HealTraceMissing;
    if (!traceLineContainsAll(trace, 0, partition, &.{ "network.send", "from=0", "to=1" })) {
        return error.PreCutResponseSendMissing;
    }

    // Observed simulator contract for a queued response frame made unreachable
    // by the structural partition.
    if (!traceLineContainsAll(trace, partition, heal, &.{ "network.drop", "from=0", "to=1", "reason=link_disabled" })) {
        return error.PartitionDropMissing;
    }
}

fn traceLineContainsAll(
    trace: []const u8,
    start: usize,
    end: usize,
    needles: []const []const u8,
) bool {
    var offset = start;
    while (offset < end) {
        const line_end = std.mem.indexOfScalarPos(u8, trace, offset, '\n') orelse trace.len;
        const bounded_end = @min(line_end, end);
        const line = trace[offset..bounded_end];
        var matched = true;
        for (needles) |needle| {
            if (std.mem.indexOf(u8, line, needle) == null) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
        if (line_end >= end or line_end == trace.len) break;
        offset = line_end + 1;
    }
    return false;
}

fn expectLargeBody(body: []const u8) !void {
    try std.testing.expectEqual(total_chunks * chunk_len, body.len);
    for (body) |byte| {
        try std.testing.expectEqual(@as(u8, 'x'), byte);
    }
}

test "dusty HTTP serves requests through its real listen loop under simulation" {
    var outcome = try runScenario(std.testing.allocator, 0xC0FFEE);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u32, 200), outcome.hello_status);
    try std.testing.expectEqualStrings(hello_body, outcome.hello_body);
    try std.testing.expectEqual(@as(u32, 200), outcome.echo_status);
    try std.testing.expectEqualStrings("echo:" ++ echo_payload, outcome.echo_body);
    try std.testing.expectEqual(@as(u32, 200), outcome.second_hello_status);
    try std.testing.expect(outcome.graceful_shutdown);
}

test "dusty HTTP scenario replays byte-identically from the same seed" {
    var first = try runScenario(std.testing.allocator, 0xC0FFEE);
    defer first.deinit();
    var second = try runScenario(std.testing.allocator, 0xC0FFEE);
    defer second.deinit();

    try std.testing.expectEqualStrings(first.trace, second.trace);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "dusty_http.client.echo status=200") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "scheduler.cancel_request") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "scheduler.cancel_deliver") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "dusty_http.server.graceful_shutdown") != null);
}

test "dusty HTTP shutdown sweeps a handler parked in a keep-alive read" {
    var outcome = try runHungShutdownScenario(std.testing.allocator, 0xC0FFEE);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u32, 200), outcome.hello_status);
    try std.testing.expect(outcome.timeout_shutdown);
    // Two deliveries: one interrupting the listen task's accept park, one
    // from the deferred group cancel sweeping the parked handler.
    try std.testing.expectEqual(@as(usize, 2), outcome.cancel_deliveries);
}

test "dusty HTTP hung shutdown replays byte-identically from the same seed" {
    var first = try runHungShutdownScenario(std.testing.allocator, 0xC0FFEE);
    defer first.deinit();
    var second = try runHungShutdownScenario(std.testing.allocator, 0xC0FFEE);
    defer second.deinit();

    try std.testing.expectEqualStrings(first.trace, second.trace);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "dusty_http.server.timeout_shutdown") != null);
}

test "dusty HTTP partition before response fails deterministically and retry converges" {
    var outcome = try runBeforeResponsePartitionScenario(std.testing.allocator, 0xC0FFEE);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u32, 200), outcome.final_status);
    try std.testing.expectEqualStrings(hello_body, outcome.final_body);
    try std.testing.expect(outcome.retry_attempts >= 1);
    try std.testing.expect(outcome.shutdown_ok);
    // dusty's observed contract under a severed link before response bytes.
    try std.testing.expectEqualStrings("Timeout", outcome.first_error_name);
    try expectTraceContains(outcome.trace, "dusty_fault.client.fetch_error");
    try expectTraceContains(outcome.trace, "dusty_fault.heal");
}

test "dusty HTTP partition scenario replays byte-identically from the same seed" {
    var first = try runBeforeResponsePartitionScenario(std.testing.allocator, 0xC0FFEE);
    defer first.deinit();
    var second = try runBeforeResponsePartitionScenario(std.testing.allocator, 0xC0FFEE);
    defer second.deinit();

    try std.testing.expectEqualStrings(first.trace, second.trace);
    try std.testing.expectEqualStrings(first.first_error_name, second.first_error_name);
}

test "dusty HTTP partition mid-response never yields a short success" {
    var outcome = try runMidResponsePartitionScenario(std.testing.allocator, 0xC0FFEE, .{
        .pre_chunks = total_chunks / 2,
    });
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u32, 200), outcome.final_status);
    try expectLargeBody(outcome.final_body);
    try std.testing.expect(outcome.retry_attempts >= 1);
    try std.testing.expect(outcome.shutdown_ok);
    // dusty's observed contract under a severed link.
    try std.testing.expectEqualStrings("Timeout", outcome.first_error_name);
    try expectTraceContains(outcome.trace, "dusty_fault.client.fetch_error");
    try expectMidResponseNetworkOracle(outcome.trace);
}

test "dusty HTTP mid-response partition replays byte-identically from the same seed" {
    var first = try runMidResponsePartitionScenario(std.testing.allocator, 0xC0FFEE, .{
        .pre_chunks = total_chunks / 2,
    });
    defer first.deinit();
    var second = try runMidResponsePartitionScenario(std.testing.allocator, 0xC0FFEE, .{
        .pre_chunks = total_chunks / 2,
    });
    defer second.deinit();

    try std.testing.expectEqualStrings(first.trace, second.trace);
    try std.testing.expectEqualStrings(first.first_error_name, second.first_error_name);
}

test "dusty HTTP partition sweep converges for every cut point" {
    var seed: u64 = 0;
    while (seed < 16) : (seed += 1) {
        const pre_chunks = 1 + @as(usize, @intCast(seed)) % (total_chunks - 1);
        var outcome = runMidResponsePartitionScenario(std.testing.allocator, seed, .{
            .pre_chunks = pre_chunks,
        }) catch |err| {
            std.debug.print("dusty HTTP partition sweep failed seed={} pre_chunks={} err={}\n", .{ seed, pre_chunks, err });
            return err;
        };
        defer outcome.deinit();

        try std.testing.expectEqual(@as(u32, 200), outcome.final_status);
        try std.testing.expectEqual(total_chunks * chunk_len, outcome.final_body.len);
    }
}
