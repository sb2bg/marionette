//! External SUT validation: the unmodified dusty HTTP library under
//! Marionette's deterministic `std.Io`.
//!
//! The SUT (`lalinsky/dusty`) is an HTTP/1.1 client/server library written
//! against the injectable `std.Io` interface plus its vendored llhttp parser.
//! Marionette owns the harness side: world, seed, simulated network, latency,
//! trace, and the response oracle.
//!
//! The harness runs dusty's real `Server.listen` accept loop as a simulated
//! task and shuts it down through cooperative cancellation: canceling the
//! listen task delivers `error.Canceled` inside `accept`, dusty drains active
//! connections, and its deferred `Group.cancel` unparks any handler still
//! blocked in a read.

const std = @import("std");
const mar = @import("marionette");
const http = @import("dusty");

const Io = std.Io;

const hello_body = "hello from the simulation\n";
const echo_payload = "determinism";
const base_url = "http://127.0.0.1:4580";

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
};

pub fn runScenario(allocator: std.mem.Allocator, seed: u64) !Outcome {
    var world = try mar.World.init(allocator, .{
        .seed = seed,
        .tick_ns = 10,
    });
    defer world.deinit();

    const sim = try world.simulate(.{ .network = .{
        .nodes = 2,
        .service_nodes = 1,
        .path_capacity = 32,
    } });
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
