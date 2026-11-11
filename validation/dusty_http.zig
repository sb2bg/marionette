//! External SUT validation: the unmodified dusty HTTP library under
//! Marionette's deterministic `std.Io`.
//!
//! The SUT (`lalinsky/dusty`) is an HTTP/1.1 client/server library written
//! against the injectable `std.Io` interface plus its vendored llhttp parser.
//! Marionette owns the harness side: runner, seed, simulated network, latency,
//! trace, and the response oracle.
//!
//! Every scenario is a `mar.Harness`: tasks fail the run with
//! `Control.failRun` instead of panicking, `capture` returns each scenario's
//! outcome, and the runner's exact second execution replaces hand-compared
//! traces.
//!
//! The harness runs dusty's real `Server.run` accept loop as a simulated
//! task and shuts it down through cooperative cancellation in two shapes:
//!
//! - Clean shutdown: all clients have disconnected, so canceling the listen
//!   task delivers `error.Canceled` inside `accept`, the connection drain
//!   sees nothing active, and `run` returns `error.Canceled`.
//! - Hung-connection shutdown: a keep-alive handler is still parked in a
//!   stream read. Dusty cancels idle connections during shutdown and returns
//!   `error.Canceled` after joining the remaining handlers.
//!
//! The pool scenarios cover 16d: keep-alive reuse across virtual-time idle
//! gaps and concurrent pool growth (dials counted via `io.net.connect`),
//! and pool recovery across a server crash and registered restart, which
//! preserve regressions for two fixed dusty bugs (FOUND_BUGS DUSTY-001/002). The
//! before-response partition scenario additionally pins the failure chain
//! under partition: the server's response send is dropped by the severed link
//! and surfaces as the client's read failure.

const std = @import("std");
const mar = @import("marionette");
const http = @import("dusty");

const Io = std.Io;

const hello_body = "hello from the simulation\n";
const echo_payload = "determinism";
const base_url = "http://10.0.0.1:4580";
/// Application deadline for the fetch a partition interrupts.
const first_fetch_timeout: std.Io.Duration = .fromMilliseconds(5);
const dusty_task_stack_size = 8 * 1024 * 1024;
const chunk_len = 4 * 1024;
const total_chunks = 16;
const chunk_pattern: [chunk_len]u8 = @splat('x');
const max_retry_attempts = 3;
const large_chunk_len = 4 * 1024;
const large_total_chunks = 256;
const large_download_len = large_chunk_len * large_total_chunks;
const large_upload_len = 512 * 1024;

/// Position-dependent transfer pattern: unlike a constant fill, it catches
/// reordered, duplicated, or aliased regions, not just wrong lengths.
fn transferPatternByte(index: usize) u8 {
    return @truncate(index *% 31 +% 7);
}

fn handleHello(req: *http.Request, res: *http.Response) !void {
    _ = req;
    res.body = hello_body;
}

fn handleEcho(req: *http.Request, res: *http.Response) !void {
    var reader = try req.reader(&.{});
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
    control: mar.Control,
    server_io: Io,
    client_io: Io,
    server: *http.Server(void),
    hello_status: u32 = 0,
    hello_body_copy: []u8 = &.{},
    echo_status: u32 = 0,
    echo_body_copy: []u8 = &.{},
    second_hello_status: u32 = 0,
    graceful_shutdown: bool = false,
    /// Client deliberately left open across shutdown so its keep-alive
    /// handler stays parked in a read. Owned by the scenario runner.
    hung_client: ?http.Client = null,

    fn record(self: *Scenario, comptime fmt: []const u8, args: anytype) void {
        self.control.record(fmt, args);
    }

    fn serverTask(self: *Scenario) void {
        self.record("dusty_http.server.listen_start", .{});
        const address: http.Address = .{
            .ip = Io.net.IpAddress.parseIp4("10.0.0.1", 4580) catch unreachable,
        };
        self.server.config.listen = &.{.{ .address = address, .acceptors = 1 }};
        self.server.run() catch |err| switch (err) {
            error.Canceled => {
                self.graceful_shutdown = true;
                self.record("dusty_http.server.graceful_shutdown", .{});
                return;
            },
            else => return self.control.failRun(err),
        };
        return self.control.failRun(error.ListenReturnedWithoutShutdown);
    }

    fn clientTask(self: *Scenario) void {
        // The ready event lives in the server process's futex namespace, so
        // the harness waits on it with the server's io handle.
        self.server.ready.wait(self.server_io) catch |err| return self.control.failRun(err);
        self.record("dusty_http.client.server_ready", .{});

        // First connection: two requests over dusty's keep-alive pool.
        {
            var client = http.Client.init(self.allocator, self.client_io, .{});
            defer client.deinit();

            {
                var response = client.fetch(base_url ++ "/hello", .{}) catch |err| return self.control.failRun(err);
                defer response.deinit();
                self.hello_status = @backingInt(response.status());
                const payload = (response.body() catch |err| return self.control.failRun(err)) orelse "";
                self.hello_body_copy = self.allocator.dupe(u8, payload) catch |err| return self.control.failRun(err);
                self.record(
                    "dusty_http.client.hello status={} bytes={}",
                    .{ self.hello_status, payload.len },
                );
            }

            {
                var response = client.fetch(base_url ++ "/echo", .{
                    .method = .post,
                    .body = echo_payload,
                }) catch |err| return self.control.failRun(err);
                defer response.deinit();
                self.echo_status = @backingInt(response.status());
                const payload = (response.body() catch |err| return self.control.failRun(err)) orelse "";
                self.echo_body_copy = self.allocator.dupe(u8, payload) catch |err| return self.control.failRun(err);
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

            var response = client.fetch(base_url ++ "/hello", .{}) catch |err| return self.control.failRun(err);
            defer response.deinit();
            self.second_hello_status = @backingInt(response.status());
            self.record(
                "dusty_http.client.second_hello status={}",
                .{self.second_hello_status},
            );
        }
    }

    fn hungClientTask(self: *Scenario) void {
        self.server.ready.wait(self.server_io) catch |err| return self.control.failRun(err);
        self.record("dusty_http.client.server_ready", .{});

        // One keep-alive request, then leave the connection open: the
        // server-side handler parks in a read waiting for a next request
        // that never comes.
        self.hung_client = http.Client.init(self.allocator, self.client_io, .{});
        var response = self.hung_client.?.fetch(base_url ++ "/hello", .{}) catch |err| return self.control.failRun(err);
        defer response.deinit();
        self.hello_status = @backingInt(response.status());
        self.record("dusty_http.client.hello status={}", .{self.hello_status});
    }
};

fn handleLargeDownload(req: *http.Request, res: *http.Response) !void {
    _ = req;
    var body = try res.stream(&.{});
    errdefer body.end() catch {};
    var chunk: [large_chunk_len]u8 = undefined;
    for (0..large_total_chunks) |chunk_index| {
        const base = chunk_index * large_chunk_len;
        for (&chunk, 0..) |*byte, offset| {
            byte.* = transferPatternByte(base + offset);
        }
        try body.interface.writeAll(&chunk);
    }
    try body.end();
}

fn handleLargeUpload(req: *http.Request, res: *http.Response) !void {
    var reader = try req.reader(&.{});
    const payload = try reader.interface.allocRemaining(
        req.arena,
        .limited(large_upload_len + 1024),
    );
    var pattern_ok = payload.len == large_upload_len;
    if (pattern_ok) {
        for (payload, 0..) |byte, index| {
            if (byte != transferPatternByte(index)) {
                pattern_ok = false;
                break;
            }
        }
    }
    res.body = try std.fmt.allocPrint(req.arena, "upload:{s}:{}", .{
        if (pattern_ok) "ok" else "bad", payload.len,
    });
}

/// Large transfers over one keep-alive connection: a patterned upload the
/// server verifies byte-for-byte, then a chunked download the client
/// verifies byte-for-byte. Both directions span many simulated packets,
/// exercising partial reads and writes through the `Io.Reader`/`Io.Writer`
/// adapters.
const LargeTransferScenario = struct {
    allocator: std.mem.Allocator,
    control: mar.Control,
    server_io: Io,
    client_io: Io,
    server: *http.Server(void),
    client: ?http.Client = null,
    upload_status: u32 = 0,
    upload_reply_copy: []u8 = &.{},
    download_status: u32 = 0,
    download_len: usize = 0,
    download_pattern_ok: bool = false,
    graceful_shutdown: bool = false,

    fn record(self: *LargeTransferScenario, comptime fmt: []const u8, args: anytype) void {
        self.control.record(fmt, args);
    }

    fn serverTask(self: *LargeTransferScenario) void {
        self.record("dusty_large.server.listen_start", .{});
        const address: http.Address = .{
            .ip = Io.net.IpAddress.parseIp4("10.0.0.1", 4580) catch unreachable,
        };
        self.server.config.listen = &.{.{ .address = address, .acceptors = 1 }};
        self.server.run() catch |err| switch (err) {
            error.Canceled => {
                self.graceful_shutdown = true;
                self.record("dusty_large.server.graceful_shutdown", .{});
                return;
            },
            else => return self.control.failRun(err),
        };
        return self.control.failRun(error.ListenReturnedWithoutShutdown);
    }

    fn clientTask(self: *LargeTransferScenario) void {
        self.server.ready.wait(self.server_io) catch |err| return self.control.failRun(err);
        self.record("dusty_large.client.server_ready", .{});

        self.client = http.Client.init(self.allocator, self.client_io, .{
            .max_response_size = large_download_len + 4096,
        });

        // Upload: the client writes half a MiB through the stream writer;
        // the server verifies every byte and echoes a verdict.
        {
            const body = self.allocator.alloc(u8, large_upload_len) catch |err|
                return self.control.failRun(err);
            defer self.allocator.free(body);
            for (body, 0..) |*byte, index| {
                byte.* = transferPatternByte(index);
            }

            var response = self.client.?.fetch(base_url ++ "/upload", .{
                .method = .post,
                .body = body,
            }) catch |err| return self.control.failRun(err);
            defer response.deinit();
            self.upload_status = @backingInt(response.status());
            const reply = (response.body() catch |err| return self.control.failRun(err)) orelse "";
            self.upload_reply_copy = self.allocator.dupe(u8, reply) catch |err| return self.control.failRun(err);
            self.record("dusty_large.client.upload status={} reply={s}", .{
                self.upload_status, reply,
            });
        }

        // Download on the same keep-alive connection: a 1 MiB chunked body
        // the client verifies byte-for-byte.
        {
            var response = self.client.?.fetch(base_url ++ "/download", .{
                .decompress = false,
            }) catch |err| return self.control.failRun(err);
            defer response.deinit();
            self.download_status = @backingInt(response.status());
            const payload = (response.body() catch |err| return self.control.failRun(err)) orelse "";
            self.download_len = payload.len;
            self.download_pattern_ok = payload.len == large_download_len;
            if (self.download_pattern_ok) {
                for (payload, 0..) |byte, index| {
                    if (byte != transferPatternByte(index)) {
                        self.download_pattern_ok = false;
                        break;
                    }
                }
            }
            self.record("dusty_large.client.download status={} bytes={} pattern_ok={}", .{
                self.download_status, self.download_len, self.download_pattern_ok,
            });
        }
    }
};

pub const LargeTransferOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    upload_status: u32,
    upload_reply: []u8,
    download_status: u32,
    download_len: usize,
    download_pattern_ok: bool,
    deliver_count: usize,
    connect_count: usize,
    graceful_shutdown: bool,

    pub fn deinit(self: *LargeTransferOutcome) void {
        self.allocator.free(self.trace);
        self.allocator.free(self.upload_reply);
        self.* = undefined;
    }
};

/// Large patterned transfers in both directions over one connection.
const LargeTransferApp = struct {
    scenario: LargeTransferScenario,
    server: ?http.Server(void) = null,

    fn init(sim: mar.Sim) !LargeTransferApp {
        try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
        return .{ .scenario = .{
            .allocator = sim.control.harnessAllocator(),
            .control = sim.control,
            .server_io = (try sim.envForNode(0)).io(),
            .client_io = (try sim.envForNode(1)).io(),
            .server = undefined,
        } };
    }

    pub fn deinit(self: *LargeTransferApp) void {
        if (self.scenario.client) |*client| client.deinit();
        if (self.server) |*server| server.deinit();
        self.scenario.allocator.free(self.scenario.upload_reply_copy);
    }

    fn run(case: *mar.SimCase(LargeTransferApp)) !void {
        const app = &case.app;
        const scenario = &app.scenario;
        app.server = http.Server(void).init(scenario.allocator, scenario.server_io, .{}, {});
        scenario.server = &app.server.?;
        scenario.server.router.post("/upload", handleLargeUpload);
        scenario.server.router.get("/download", handleLargeDownload);

        var server_future = try Io.concurrent(scenario.server_io, LargeTransferScenario.serverTask, .{scenario});
        var client_future = try Io.concurrent(scenario.client_io, LargeTransferScenario.clientTask, .{scenario});

        client_future.await(scenario.client_io);
        // Closing the pooled connection first lets its parked keep-alive
        // handler drain, so listen cancellation shuts down gracefully.
        if (scenario.client) |*client| {
            client.deinit();
            scenario.client = null;
        }
        server_future.cancel(scenario.server_io);
        if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
    }

    fn capture(case: *mar.SimCase(LargeTransferApp), allocator: std.mem.Allocator) !LargeTransferOutcome {
        const scenario = &case.app.scenario;
        const trace = case.control().traceBytes();
        return .{
            .allocator = allocator,
            .trace = &.{},
            .upload_status = scenario.upload_status,
            .upload_reply = try allocator.dupe(u8, scenario.upload_reply_copy),
            .download_status = scenario.download_status,
            .download_len = scenario.download_len,
            .download_pattern_ok = scenario.download_pattern_ok,
            .deliver_count = std.mem.count(u8, trace, "net.deliver pkt="),
            .connect_count = std.mem.count(u8, trace, "io.net.connect handle="),
            .graceful_shutdown = scenario.graceful_shutdown,
        };
    }
};

const LargeTransferHarness = mar.Harness(.{
    .init = LargeTransferApp.init,
    .scenario = LargeTransferApp.run,
    .capture = LargeTransferApp.capture,
    .simulate = simulateOptions(4096),
    .name = "dusty.large_transfer",
});

pub fn runLargeTransferScenario(allocator: std.mem.Allocator, seed: u64) !LargeTransferOutcome {
    return finish(LargeTransferHarness, allocator, seed);
}

/// Pooled keep-alive reuse: one shared client, connections idle across
/// virtual-time gaps, concurrent fetches that force the pool to grow, and
/// sequential fetches that must reuse both pooled connections.
///
/// New connections are counted through `io.net.connect` events: dusty only
/// dials when the pool has no reusable connection, so the connect count
/// equals the connection count.
const PoolScenario = struct {
    allocator: std.mem.Allocator,
    control: mar.Control,
    server_io: Io,
    client_io: Io,
    server: *http.Server(void),
    client: ?http.Client = null,
    statuses: [6]u32 = @splat(0),
    graceful_shutdown: bool = false,

    fn record(self: *PoolScenario, comptime fmt: []const u8, args: anytype) void {
        self.control.record(fmt, args);
    }

    fn serverTask(self: *PoolScenario) void {
        self.record("dusty_pool.server.listen_start", .{});
        const address: http.Address = .{
            .ip = Io.net.IpAddress.parseIp4("10.0.0.1", 4580) catch unreachable,
        };
        self.server.config.listen = &.{.{ .address = address, .acceptors = 1 }};
        self.server.run() catch |err| switch (err) {
            error.Canceled => {
                self.graceful_shutdown = true;
                self.record("dusty_pool.server.graceful_shutdown", .{});
                return;
            },
            else => return self.control.failRun(err),
        };
        return self.control.failRun(error.ListenReturnedWithoutShutdown);
    }

    fn fetchHello(self: *PoolScenario, slot: usize) void {
        var response = self.client.?.fetch(base_url ++ "/hello", .{}) catch |err| return self.control.failRun(err);
        defer response.deinit();
        self.statuses[slot] = @backingInt(response.status());
        const payload = (response.body() catch |err| return self.control.failRun(err)) orelse "";
        self.record("dusty_pool.client.fetch slot={} status={} bytes={}", .{
            slot, self.statuses[slot], payload.len,
        });
    }

    fn clientTask(self: *PoolScenario) void {
        self.server.ready.wait(self.server_io) catch |err| return self.control.failRun(err);
        self.record("dusty_pool.client.server_ready", .{});

        self.client = http.Client.init(self.allocator, self.client_io, .{});

        // Connection 1: first fetch, then reuse across an idle gap in
        // virtual time.
        self.fetchHello(0);
        Io.sleep(self.client_io, .fromNanoseconds(idle_gap_ns), .awake) catch |err|
            return self.control.failRun(err);
        self.record("dusty_pool.client.idle_gap_over", .{});
        self.fetchHello(1);

        // Two concurrent fetches: one reuses the single pooled connection,
        // the other must grow the pool to a second connection.
        var first = Io.concurrent(self.client_io, PoolScenario.fetchHello, .{ self, 2 }) catch |err|
            return self.control.failRun(err);
        var second = Io.concurrent(self.client_io, PoolScenario.fetchHello, .{ self, 3 }) catch |err|
            return self.control.failRun(err);
        first.await(self.client_io);
        second.await(self.client_io);
        self.record("dusty_pool.client.concurrent_done", .{});

        // Both connections are back in the pool: two sequential fetches must
        // reuse them without opening a third.
        self.fetchHello(4);
        self.fetchHello(5);
    }
};

const idle_gap_ns = 1_000_000;

/// Pool recovery after a server crash: a healthy fetch parks a keep-alive
/// connection in the pool, then the server process is killed. Failed reuse
/// must evict that connection so the same client can dial the restarted
/// incarnation.
const PoolCrashScenario = struct {
    allocator: std.mem.Allocator,
    /// Arena for everything the killable server process allocates: a killed
    /// process never runs defers, so its allocations must die with the
    /// harness arena instead of leaking (same pattern as the beanstalkz
    /// validation).
    server_allocator: std.mem.Allocator,
    control: mar.Control,
    server_io: Io,
    client_io: Io,
    restart_io: ?Io = null,
    server: *http.Server(void),
    restarted_server: ?http.Server(void) = null,
    client: ?http.Client = null,
    first_status: u32 = 0,
    dead_error_name: []u8 = &.{},
    poisoned_attempts: u32 = 0,
    recovery_attempts: u32 = 0,
    post_restart_error_name: []u8 = &.{},
    fresh_status: u32 = 0,

    fn record(self: *PoolCrashScenario, comptime fmt: []const u8, args: anytype) void {
        self.control.record(fmt, args);
    }

    fn storeError(self: *PoolCrashScenario, slot: *[]u8, err: anyerror) void {
        if (slot.len != 0) self.allocator.free(slot.*);
        slot.* = &.{};
        slot.* = self.allocator.dupe(u8, @errorName(err)) catch |alloc_err| return self.control.failRun(alloc_err);
    }

    /// Killed by the harness rather than shut down; listen never returns
    /// in this scenario.
    fn serverTask(self: *PoolCrashScenario) void {
        self.record("dusty_pool_crash.server.listen_start", .{});
        const address: http.Address = .{
            .ip = Io.net.IpAddress.parseIp4("10.0.0.1", 4580) catch unreachable,
        };
        self.server.config.listen = &.{.{ .address = address, .acceptors = 1 }};
        self.server.run() catch |err| return self.control.failRun(err);
        return self.control.failRun(error.ListenReturnedWithoutShutdown);
    }

    fn restartedServerTask(self: *PoolCrashScenario) void {
        self.record("dusty_pool_crash.server.restart_listen_start", .{});
        const address: http.Address = .{
            .ip = Io.net.IpAddress.parseIp4("10.0.0.1", 4580) catch unreachable,
        };
        self.restarted_server.?.config.listen = &.{.{ .address = address, .acceptors = 1 }};
        self.restarted_server.?.run() catch |err| return self.control.failRun(err);
        return self.control.failRun(error.ListenReturnedWithoutShutdown);
    }

    /// Healthy fetch: the connection goes back to the pool and the
    /// server-side handler parks in a keep-alive read.
    fn healthyFetchTask(self: *PoolCrashScenario) void {
        self.server.ready.wait(self.server_io) catch |err| return self.control.failRun(err);
        self.record("dusty_pool_crash.client.server_ready", .{});

        self.client = http.Client.init(self.allocator, self.client_io, .{});
        var response = self.client.?.fetch(base_url ++ "/hello", .{}) catch |err| return self.control.failRun(err);
        defer response.deinit();
        self.first_status = @backingInt(response.status());
        _ = (response.body() catch |err| return self.control.failRun(err)) orelse "";
        self.record("dusty_pool_crash.client.first_fetch status={}", .{self.first_status});
    }

    /// Fetch attempts while the server is dead. They must all fail regardless
    /// of whether the first failure evicts the pooled connection.
    fn poisonedAttemptsTask(self: *PoolCrashScenario) void {
        var attempt: u32 = 1;
        while (attempt <= max_retry_attempts) : (attempt += 1) {
            if (self.client.?.fetch(base_url ++ "/hello", .{})) |response| {
                var owned = response;
                defer owned.deinit();
                self.recovery_attempts = attempt;
                self.record("dusty_pool_crash.client.attempt attempt={} outcome=ok", .{attempt});
                return;
            } else |err| {
                if (attempt == 1) self.storeError(&self.dead_error_name, err);
                self.poisoned_attempts = attempt;
                self.record("dusty_pool_crash.client.attempt attempt={} outcome={s}", .{
                    attempt, @errorName(err),
                });
            }
        }
    }

    /// The restarted incarnation is listening again. The same client must
    /// recover by dialing, and a fresh client independently proves reachability.
    fn postRestartTask(self: *PoolCrashScenario) void {
        self.restarted_server.?.ready.wait(self.restart_io.?) catch |err|
            return self.control.failRun(err);
        self.record("dusty_pool_crash.client.restart_ready", .{});

        if (self.client.?.fetch(base_url ++ "/hello", .{})) |response| {
            var owned = response;
            defer owned.deinit();
            self.record("dusty_pool_crash.client.post_restart outcome=ok", .{});
        } else |err| {
            self.storeError(&self.post_restart_error_name, err);
            self.record("dusty_pool_crash.client.post_restart outcome={s}", .{@errorName(err)});
        }

        var fresh = http.Client.init(self.allocator, self.client_io, .{});
        defer fresh.deinit();
        if (fresh.fetch(base_url ++ "/hello", .{})) |response| {
            var owned = response;
            defer owned.deinit();
            self.fresh_status = @backingInt(owned.status());
            _ = (owned.body() catch |err| return self.control.failRun(err)) orelse "";
            self.record("dusty_pool_crash.client.fresh_fetch status={}", .{self.fresh_status});
        } else |err| {
            self.record("dusty_pool_crash.client.fresh_fetch_error err={s}", .{@errorName(err)});
        }
    }
};

const PoolCrashLifecycle = struct {
    scenario: *PoolCrashScenario,

    fn onKill(_: *anyopaque) void {}

    fn restart(raw: *anyopaque, env: mar.Env) anyerror!void {
        const self: *PoolCrashLifecycle = @ptrCast(@alignCast(raw));
        const scenario = self.scenario;
        // Fresh incarnation: a restarted process starts a new server value;
        // the killed one's state died with the process.
        scenario.restart_io = env.io();
        scenario.restarted_server = http.Server(void).init(scenario.server_allocator, env.io(), .{}, {});
        scenario.restarted_server.?.router.get("/hello", handleHello);
        _ = try Io.concurrent(env.io(), PoolCrashScenario.restartedServerTask, .{scenario});
    }
};

const FaultScenario = struct {
    allocator: std.mem.Allocator,
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
    fetch_succeeded_before_cut: bool = false,
    short_success: bool = false,
    retry_failed: bool = false,
    retry_body_mismatch: bool = false,

    fn shutdownOk(self: *const FaultScenario) bool {
        return self.graceful_shutdown;
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
        self.control.record(fmt, args);
    }

    fn storeFirstError(self: *FaultScenario, err: anyerror) void {
        const name = @errorName(err);
        if (self.first_error_name.len != 0) self.allocator.free(self.first_error_name);
        self.first_error_name = &.{};
        self.first_error_name = self.allocator.dupe(u8, name) catch |alloc_err| return self.control.failRun(alloc_err);
        self.record("dusty_fault.client.fetch_error err={s}", .{name});
    }

    fn setFinalBody(self: *FaultScenario, bytes: []const u8) void {
        if (self.final_body_copy.len != 0) self.allocator.free(self.final_body_copy);
        self.final_body_copy = self.allocator.dupe(u8, bytes) catch |err| return self.control.failRun(err);
    }

    fn serverTask(self: *FaultScenario) void {
        self.record("dusty_fault.server.listen_start", .{});
        const address: http.Address = .{
            .ip = Io.net.IpAddress.parseIp4("10.0.0.1", 4580) catch unreachable,
        };
        self.server.config.listen = &.{.{ .address = address, .acceptors = 1 }};
        self.server.run() catch |err| switch (err) {
            error.Canceled => {
                self.graceful_shutdown = true;
                self.record("dusty_fault.server.graceful_shutdown", .{});
                return;
            },
            else => return self.control.failRun(err),
        };
        return self.control.failRun(error.ListenReturnedWithoutShutdown);
    }

    fn faultController(self: *FaultScenario) std.Io.Cancelable!void {
        switch (self.mode) {
            .before_response => try self.waitFor(&self.request_reached),
            .mid_response => try self.waitFor(&self.mid_response_reached),
        }

        const server_side = [_]mar.NodeId{0};
        const client_side = [_]mar.NodeId{1};
        _ = self.control.network.partition(&server_side, &client_side, .{}) catch |err| return self.control.failRun(err);
        self.record("dusty_fault.partition", .{});
        self.signal(&self.partitioned);

        try self.waitFor(&self.client_failed);
        self.control.network.heal() catch |err| return self.control.failRun(err);
        self.record("dusty_fault.heal", .{});
        self.signal(&self.healed);
    }

    fn clientTask(self: *FaultScenario) std.Io.Cancelable!void {
        self.server.ready.wait(self.server_io) catch |err| return self.control.failRun(err);
        self.record("dusty_fault.client.server_ready", .{});

        self.firstFetch();
        if (self.fetch_succeeded_before_cut or self.short_success) return;

        try self.waitFor(&self.healed);
        self.retryAfterHeal();
    }

    fn firstFetch(self: *FaultScenario) void {
        // The client's own deadline ends a fetch the partition silences.
        var client = http.Client.init(self.allocator, self.client_io, .{
            .max_idle_connections = 0,
            .max_response_size = total_chunks * chunk_len + 1024,
            .timeout = first_fetch_timeout,
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
            // A fresh client avoids retaining dead keep-alive connections.
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

            const status: u32 = @backingInt(response.status());
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
    var body = try res.stream(&.{});
    errdefer body.end() catch {};
    for (0..total_chunks) |i| {
        try body.interface.writeAll(&chunk_pattern);
        if (i + 1 == scenario.pre_chunks) {
            scenario.record("dusty_fault.server.mid_response chunks_sent={}", .{i + 1});
            scenario.signal(&scenario.mid_response_reached);
            try scenario.waitFor(&scenario.partitioned);
        }
    }
    try body.end();
}

fn payloadIsFullChunkOracle(payload: []const u8) bool {
    if (payload.len != total_chunks * chunk_len) return false;
    for (payload) |byte| {
        if (byte != 'x') return false;
    }
    return true;
}

/// Two nodes (server 0, client 1), dusty's deep task stacks, and enough
/// path capacity for its bursts.
fn simulateOptions(path_capacity: usize) mar.World.SimulateOptions {
    return .{
        .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = path_capacity },
        // dusty's Debug-mode fetch frames are platform-sensitive and deep;
        // Linux/x86_64 needs more than the default stack to enter fetchInternal.
        .task_stack_size = dusty_task_stack_size,
    };
}

/// Run a harness once (the runner adds its exact second execution) and
/// return its captured outcome with the trace attached.
fn finish(comptime H: type, allocator: std.mem.Allocator, seed: u64) !H.CapturedOutcome {
    var captured = try H.runCapture(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer captured.deinit();
    switch (captured.report) {
        .passed => |passed| {
            var outcome = captured.outcome orelse return error.OutcomeNotCaptured;
            captured.outcome = null;
            errdefer outcome.deinit();
            outcome.trace = try allocator.dupe(u8, passed.trace);
            return outcome;
        },
        .failed => |failure| {
            failure.print();
            if (failure.error_name) |name| {
                inline for (scenario_errors) |candidate| {
                    if (std.mem.eql(u8, name, @errorName(candidate))) return candidate;
                }
            }
            return error.ScenarioFailed;
        },
    }
}

const scenario_errors = .{
    error.FetchSucceededBeforeCut,
    error.ShortSuccess,
    error.RetryDidNotConverge,
    error.RetryBodyMismatch,
    error.ServerShutdownDidNotComplete,
    error.FirstFetchDidNotFail,
    error.RetryDidNotRun,
    error.InvalidPreChunkCount,
    error.PoisonedFetchDidNotFail,
    error.ScenarioDeadlocked,
};

fn serveBasic(scenario: *Scenario, server_slot: *?http.Server(void), routes: enum { hello_echo, hello }) void {
    server_slot.* = http.Server(void).init(scenario.allocator, scenario.server_io, .{}, {});
    scenario.server = &server_slot.*.?;
    scenario.server.router.get("/hello", handleHello);
    if (routes == .hello_echo) scenario.server.router.post("/echo", handleEcho);
}

fn basicScenario(sim: mar.Sim) !Scenario {
    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
    return .{
        .allocator = sim.control.harnessAllocator(),
        .control = sim.control,
        .server_io = (try sim.envForNode(0)).io(),
        .client_io = (try sim.envForNode(1)).io(),
        .server = undefined,
    };
}

const BasicApp = struct {
    scenario: Scenario,
    server: ?http.Server(void) = null,

    fn init(sim: mar.Sim) !BasicApp {
        return .{ .scenario = try basicScenario(sim) };
    }

    pub fn deinit(self: *BasicApp) void {
        if (self.server) |*server| server.deinit();
        self.scenario.allocator.free(self.scenario.hello_body_copy);
        self.scenario.allocator.free(self.scenario.echo_body_copy);
    }

    fn run(case: *mar.SimCase(BasicApp)) !void {
        const scenario = &case.app.scenario;
        serveBasic(scenario, &case.app.server, .hello_echo);
        var server_future = try Io.concurrent(scenario.server_io, Scenario.serverTask, .{scenario});
        var client_future = try Io.concurrent(scenario.client_io, Scenario.clientTask, .{scenario});

        client_future.await(scenario.client_io);
        // Graceful shutdown: cancellation lands in dusty's accept park, the
        // server drains its connections, and its group cancel sweeps handlers.
        server_future.cancel(scenario.server_io);
        if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
    }

    fn capture(case: *mar.SimCase(BasicApp), allocator: std.mem.Allocator) !Outcome {
        const scenario = &case.app.scenario;
        const hello = try allocator.dupe(u8, scenario.hello_body_copy);
        errdefer allocator.free(hello);
        return .{
            .allocator = allocator,
            .trace = &.{},
            .hello_status = scenario.hello_status,
            .hello_body = hello,
            .echo_status = scenario.echo_status,
            .echo_body = try allocator.dupe(u8, scenario.echo_body_copy),
            .second_hello_status = scenario.second_hello_status,
            .graceful_shutdown = scenario.graceful_shutdown,
        };
    }
};

const BasicHarness = mar.Harness(.{
    .init = BasicApp.init,
    .scenario = BasicApp.run,
    .capture = BasicApp.capture,
    .simulate = simulateOptions(32),
    .name = "dusty.basic",
});

pub fn runScenario(allocator: std.mem.Allocator, seed: u64) !Outcome {
    return finish(BasicHarness, allocator, seed);
}

pub const PoolOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    statuses: [6]u32,
    connect_count: usize,
    graceful_shutdown: bool,

    pub fn deinit(self: *PoolOutcome) void {
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

/// Pooled keep-alive reuse across idle gaps and concurrent pool growth.
const PoolApp = struct {
    scenario: PoolScenario,
    server: ?http.Server(void) = null,

    fn init(sim: mar.Sim) !PoolApp {
        try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
        return .{ .scenario = .{
            .allocator = sim.control.harnessAllocator(),
            .control = sim.control,
            .server_io = (try sim.envForNode(0)).io(),
            .client_io = (try sim.envForNode(1)).io(),
            .server = undefined,
        } };
    }

    pub fn deinit(self: *PoolApp) void {
        if (self.scenario.client) |*client| client.deinit();
        if (self.server) |*server| server.deinit();
    }

    fn run(case: *mar.SimCase(PoolApp)) !void {
        const app = &case.app;
        const scenario = &app.scenario;
        app.server = http.Server(void).init(scenario.allocator, scenario.server_io, .{}, {});
        scenario.server = &app.server.?;
        scenario.server.router.get("/hello", handleHello);

        var server_future = try Io.concurrent(scenario.server_io, PoolScenario.serverTask, .{scenario});
        var client_future = try Io.concurrent(scenario.client_io, PoolScenario.clientTask, .{scenario});

        client_future.await(scenario.client_io);
        // Closing the pooled connections first lets their parked keep-alive
        // handlers drain, so listen cancellation shuts down gracefully.
        if (scenario.client) |*client| {
            client.deinit();
            scenario.client = null;
        }
        server_future.cancel(scenario.server_io);
        if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
    }

    fn capture(case: *mar.SimCase(PoolApp), allocator: std.mem.Allocator) !PoolOutcome {
        const scenario = &case.app.scenario;
        return .{
            .allocator = allocator,
            .trace = &.{},
            .statuses = scenario.statuses,
            .connect_count = std.mem.count(u8, case.control().traceBytes(), "io.net.connect handle="),
            .graceful_shutdown = scenario.graceful_shutdown,
        };
    }
};

const PoolHarness = mar.Harness(.{
    .init = PoolApp.init,
    .scenario = PoolApp.run,
    .capture = PoolApp.capture,
    .simulate = simulateOptions(64),
    .name = "dusty.pool_reuse",
});

pub fn runPoolReuseScenario(allocator: std.mem.Allocator, seed: u64) !PoolOutcome {
    return finish(PoolHarness, allocator, seed);
}

pub const PoolCrashOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    first_status: u32,
    dead_error_name: []u8,
    poisoned_attempts: u32,
    recovery_attempts: u32,
    post_restart_error_name: []u8,
    fresh_status: u32,
    connect_count: usize,

    pub fn deinit(self: *PoolCrashOutcome) void {
        self.allocator.free(self.trace);
        self.allocator.free(self.dead_error_name);
        self.allocator.free(self.post_restart_error_name);
        self.* = undefined;
    }
};

/// Pool poisoning across a server crash and registered restart.
const PoolCrashApp = struct {
    scenario: PoolCrashScenario,
    arena_state: std.heap.ArenaAllocator,
    server: ?http.Server(void) = null,
    lifecycle: PoolCrashLifecycle = undefined,

    fn init(sim: mar.Sim) !PoolCrashApp {
        try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
        const allocator = sim.control.harnessAllocator();
        return .{
            .arena_state = std.heap.ArenaAllocator.init(allocator),
            .scenario = .{
                .allocator = allocator,
                .server_allocator = undefined,
                .control = sim.control,
                .server_io = (try sim.envForNode(0)).io(),
                .client_io = (try sim.envForNode(1)).io(),
                .server = undefined,
            },
        };
    }

    pub fn deinit(self: *PoolCrashApp) void {
        const scenario = &self.scenario;
        if (scenario.client) |*client| client.deinit();
        if (scenario.restarted_server) |*restarted| restarted.deinit();
        if (self.server) |*server| server.deinit();
        scenario.allocator.free(scenario.dead_error_name);
        scenario.allocator.free(scenario.post_restart_error_name);
        self.arena_state.deinit();
    }

    fn run(case: *mar.SimCase(PoolCrashApp)) !void {
        const app = &case.app;
        const scenario = &app.scenario;
        const control = case.control();
        scenario.server_allocator = app.arena_state.allocator();
        app.server = http.Server(void).init(scenario.server_allocator, scenario.server_io, .{}, {});
        scenario.server = &app.server.?;
        scenario.server.router.get("/hello", handleHello);

        app.lifecycle = .{ .scenario = scenario };
        try case.sim.registerProcess(0, .{
            .ptr = &app.lifecycle,
            .on_kill = PoolCrashLifecycle.onKill,
            .restart = PoolCrashLifecycle.restart,
        });

        // The listen task's future is intentionally dropped: it dies with the
        // killed process, and the restarted incarnation is joined through
        // `runTasksUntilIdle`.
        _ = try Io.concurrent(scenario.server_io, PoolCrashScenario.serverTask, .{scenario});

        var healthy_future = try Io.concurrent(scenario.client_io, PoolCrashScenario.healthyFetchTask, .{scenario});
        healthy_future.await(scenario.client_io);

        // Crash the server: its listener, accept task, and the keep-alive
        // handler parked on the pooled connection die with the process.
        try control.process.kill(0);

        var poisoned_future = try Io.concurrent(scenario.client_io, PoolCrashScenario.poisonedAttemptsTask, .{scenario});
        poisoned_future.await(scenario.client_io);

        try control.process.restart(0);
        var post_restart_future = try Io.concurrent(scenario.client_io, PoolCrashScenario.postRestartTask, .{scenario});
        post_restart_future.await(scenario.client_io);

        if (scenario.client) |*client| {
            client.deinit();
            scenario.client = null;
        }
        // Tear the restarted incarnation down through the same process
        // lifecycle used to create it, keeping this crash scenario
        // independent of shutdown.
        try control.process.kill(0);
        try control.runTasksUntilIdle();
        if (control.blockedTaskCount() != 0) return error.ScenarioDeadlocked;
        if (scenario.dead_error_name.len == 0) return error.PoisonedFetchDidNotFail;
    }

    fn capture(case: *mar.SimCase(PoolCrashApp), allocator: std.mem.Allocator) !PoolCrashOutcome {
        const scenario = &case.app.scenario;
        const dead = try allocator.dupe(u8, scenario.dead_error_name);
        errdefer allocator.free(dead);
        return .{
            .allocator = allocator,
            .trace = &.{},
            .first_status = scenario.first_status,
            .dead_error_name = dead,
            .poisoned_attempts = scenario.poisoned_attempts,
            .recovery_attempts = scenario.recovery_attempts,
            .post_restart_error_name = try allocator.dupe(u8, scenario.post_restart_error_name),
            .fresh_status = scenario.fresh_status,
            .connect_count = std.mem.count(u8, case.control().traceBytes(), "io.net.connect handle="),
        };
    }
};

const PoolCrashHarness = mar.Harness(.{
    .init = PoolCrashApp.init,
    .scenario = PoolCrashApp.run,
    .capture = PoolCrashApp.capture,
    .simulate = simulateOptions(64),
    .name = "dusty.pool_crash",
});

pub fn runPoolCrashScenario(allocator: std.mem.Allocator, seed: u64) !PoolCrashOutcome {
    return finish(PoolCrashHarness, allocator, seed);
}

pub const HungOutcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    hello_status: u32,
    graceful_shutdown: bool,
    cancel_deliveries: usize,

    pub fn deinit(self: *HungOutcome) void {
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

/// Shutdown while a keep-alive handler is still parked in a stream read.
const HungApp = struct {
    scenario: Scenario,
    server: ?http.Server(void) = null,

    fn init(sim: mar.Sim) !HungApp {
        return .{ .scenario = try basicScenario(sim) };
    }

    pub fn deinit(self: *HungApp) void {
        if (self.scenario.hung_client) |*client| client.deinit();
        if (self.server) |*server| server.deinit();
        self.scenario.allocator.free(self.scenario.hello_body_copy);
        self.scenario.allocator.free(self.scenario.echo_body_copy);
    }

    fn run(case: *mar.SimCase(HungApp)) !void {
        const scenario = &case.app.scenario;
        serveBasic(scenario, &case.app.server, .hello);
        var server_future = try Io.concurrent(scenario.server_io, Scenario.serverTask, .{scenario});
        var client_future = try Io.concurrent(scenario.client_io, Scenario.hungClientTask, .{scenario});

        client_future.await(scenario.client_io);
        // The handler for the hung client is still parked in a keep-alive
        // read. Cancellation stops the accept loop and must sweep it.
        server_future.cancel(scenario.server_io);
        if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
    }

    fn capture(case: *mar.SimCase(HungApp), allocator: std.mem.Allocator) !HungOutcome {
        const scenario = &case.app.scenario;
        return .{
            .allocator = allocator,
            .trace = &.{},
            .hello_status = scenario.hello_status,
            .graceful_shutdown = scenario.graceful_shutdown,
            .cancel_deliveries = std.mem.count(u8, case.control().traceBytes(), "scheduler.cancel_deliver task="),
        };
    }
};

const HungHarness = mar.Harness(.{
    .init = HungApp.init,
    .scenario = HungApp.run,
    .capture = HungApp.capture,
    .simulate = simulateOptions(32),
    .name = "dusty.hung_shutdown",
});

pub fn runHungShutdownScenario(allocator: std.mem.Allocator, seed: u64) !HungOutcome {
    return finish(HungHarness, allocator, seed);
}

pub fn runBeforeResponsePartitionScenario(allocator: std.mem.Allocator, seed: u64) !FaultOutcome {
    return finish(FaultHarness(.before_response, total_chunks / 2), allocator, seed);
}

pub fn runMidResponsePartitionScenario(
    allocator: std.mem.Allocator,
    seed: u64,
    options: FaultOptions,
) !FaultOutcome {
    if (options.pre_chunks == 0 or options.pre_chunks >= total_chunks) return error.InvalidPreChunkCount;
    // Each cut point is its own harness, so its capsules replay against it.
    @setEvalBranchQuota(100_000);
    inline for (1..total_chunks) |pre_chunks| {
        if (options.pre_chunks == pre_chunks) return finish(FaultHarness(.mid_response, pre_chunks), allocator, seed);
    }
    unreachable;
}

/// A partition at a structural point of one fetch, then a retry after heal.
fn FaultApp(comptime mode: FaultMode, comptime pre_chunks: usize) type {
    return struct {
        const Self = @This();

        scenario: FaultScenario,
        server: ?http.Server(FaultScenario) = null,

        fn init(sim: mar.Sim) !Self {
            try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
            return .{ .scenario = .{
                .allocator = sim.control.harnessAllocator(),
                .control = sim.control,
                .server_io = (try sim.envForNode(0)).io(),
                .client_io = (try sim.envForNode(1)).io(),
                .harness_io = sim.env.io(),
                .server = undefined,
                .mode = mode,
                .pre_chunks = pre_chunks,
            } };
        }

        pub fn deinit(self: *Self) void {
            if (self.server) |*server| server.deinit();
            self.scenario.allocator.free(self.scenario.first_error_name);
            self.scenario.allocator.free(self.scenario.final_body_copy);
        }

        fn run(case: *mar.SimCase(Self)) !void {
            const app = &case.app;
            const scenario = &app.scenario;
            app.server = http.Server(FaultScenario).init(scenario.allocator, scenario.server_io, .{}, scenario);
            scenario.server = &app.server.?;
            switch (mode) {
                .before_response => scenario.server.router.get("/held", handleHeld),
                .mid_response => scenario.server.router.get("/large", handleLarge),
            }

            var server_future = Io.async(scenario.server_io, FaultScenario.serverTask, .{scenario});
            var client_future = Io.async(scenario.client_io, FaultScenario.clientTask, .{scenario});
            var controller_future = Io.async(scenario.harness_io, FaultScenario.faultController, .{scenario});
            var tasks_running = true;
            errdefer if (tasks_running) {
                _ = client_future.cancel(scenario.client_io) catch {};
                _ = controller_future.cancel(scenario.harness_io) catch {};
                server_future.cancel(scenario.server_io);
            };

            try client_future.await(scenario.client_io);
            try controller_future.await(scenario.harness_io);
            server_future.cancel(scenario.server_io);
            tasks_running = false;
            if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;

            if (scenario.fetch_succeeded_before_cut) return error.FetchSucceededBeforeCut;
            if (scenario.short_success) return error.ShortSuccess;
            if (scenario.retry_failed) return error.RetryDidNotConverge;
            if (scenario.retry_body_mismatch) return error.RetryBodyMismatch;
            if (!scenario.shutdownOk()) return error.ServerShutdownDidNotComplete;
            if (scenario.first_error_name.len == 0) return error.FirstFetchDidNotFail;
            if (scenario.retry_attempts == 0) return error.RetryDidNotRun;
        }

        fn capture(case: *mar.SimCase(Self), allocator: std.mem.Allocator) !FaultOutcome {
            const scenario = &case.app.scenario;
            const first_error = try allocator.dupe(u8, scenario.first_error_name);
            errdefer allocator.free(first_error);
            return .{
                .allocator = allocator,
                .trace = &.{},
                .first_error_name = first_error,
                .retry_attempts = scenario.retry_attempts,
                .final_status = scenario.final_status,
                .final_body = try allocator.dupe(u8, scenario.final_body_copy),
                .shutdown_ok = scenario.shutdownOk(),
            };
        }
    };
}

fn FaultHarness(comptime mode: FaultMode, comptime pre_chunks: usize) type {
    const App = FaultApp(mode, pre_chunks);
    return mar.Harness(.{
        .init = App.init,
        .scenario = App.run,
        .capture = App.capture,
        // A 16-chunk response emits many segments before the cooperative
        // client drains them; keep capacity above the full response.
        .simulate = simulateOptions(512),
        .name = switch (mode) {
            .before_response => "dusty.partition_before_response",
            .mid_response => "dusty.partition_mid_response",
        },
    });
}

fn expectMidResponseNetworkOracle(trace: []const u8) !void {
    const partition = std.mem.indexOf(u8, trace, "dusty_fault.partition") orelse return error.PartitionTraceMissing;
    const heal = std.mem.indexOfPos(u8, trace, partition, "dusty_fault.heal") orelse return error.HealTraceMissing;
    if (!traceLineContainsAll(trace, 0, partition, &.{ "net.send", "from=0", "to=1" })) {
        return error.PreCutResponseSendMissing;
    }

    // Response segments that reach the cut vanish; the partition itself
    // produces only silence.
    if (!traceLineContainsAll(trace, partition, heal, &.{ "net.drop", "from=0", "to=1", "reason=fault", "mode=drop" })) {
        return error.PartitionDropMissing;
    }
}

fn expectBeforeResponseNetworkOracle(trace: []const u8) !void {
    const partition = std.mem.indexOf(u8, trace, "dusty_fault.partition") orelse return error.PartitionTraceMissing;
    // Healing waits for the client failure, so bound by the failure itself:
    // ordering against `dusty_fault.heal` would hold by construction.
    const failure = std.mem.indexOfPos(u8, trace, partition, "dusty_fault.client.fetch_error") orelse
        return error.ReadDidNotFailUnderPartition;

    // The held handler writes its response only after the cut, so the server's
    // send is dropped by the partition and the client hears nothing; its own
    // fetch deadline ends the wait.
    if (!traceLineContainsAll(trace, partition, failure, &.{ "net.send", "from=0", "to=1" })) {
        return error.HeldResponseSendMissing;
    }
    if (!traceLineContainsAll(trace, partition, failure, &.{ "net.drop", "from=0", "to=1", "reason=fault", "mode=drop" })) {
        return error.PartitionDropMissing;
    }
    if (traceLineContainsAll(trace, partition, failure, &.{"tcp.error"})) {
        return error.NetworkInventedAnError;
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

test "dusty HTTP scenario pins its schedule-visible events" {
    var first = try runScenario(std.testing.allocator, 0xC0FFEE);
    defer first.deinit();

    try std.testing.expect(std.mem.indexOf(u8, first.trace, "dusty_http.client.echo status=200") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "scheduler.cancel_request") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "scheduler.cancel_deliver") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "dusty_http.server.graceful_shutdown") != null);
}

test "dusty HTTP shutdown sweeps a handler parked in a keep-alive read" {
    var outcome = try runHungShutdownScenario(std.testing.allocator, 0xC0FFEE);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u32, 200), outcome.hello_status);
    try std.testing.expect(outcome.graceful_shutdown);
    // The server now owns separate accept, connection, and deadline tasks.
    // Pin the cleanup behavior, not the upstream task count.
    try std.testing.expect(outcome.cancel_deliveries >= 1);
    try mar.expectTraceContains(outcome.trace, "dusty_http.server.graceful_shutdown");
}

test "dusty HTTP hung shutdown pins its schedule-visible events" {
    var first = try runHungShutdownScenario(std.testing.allocator, 0xC0FFEE);
    defer first.deinit();

    try mar.expectTraceContains(first.trace, "dusty_http.server.graceful_shutdown");
}

test "dusty HTTP partition before response fails deterministically and retry converges" {
    var outcome = try runBeforeResponsePartitionScenario(std.testing.allocator, 0xC0FFEE);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u32, 200), outcome.final_status);
    try std.testing.expectEqualStrings(hello_body, outcome.final_body);
    try std.testing.expect(outcome.retry_attempts >= 1);
    try std.testing.expect(outcome.shutdown_ok);
    // The network stays silent; dusty's own fetch deadline fails the request.
    try std.testing.expectEqualStrings("Timeout", outcome.first_error_name);
    try mar.expectTraceContains(outcome.trace, "dusty_fault.client.fetch_error");
    try mar.expectTraceContains(outcome.trace, "dusty_fault.heal");

    try expectBeforeResponseNetworkOracle(outcome.trace);
}

test "dusty HTTP partition scenario pins its schedule-visible events" {
    var first = try runBeforeResponsePartitionScenario(std.testing.allocator, 0xC0FFEE);
    defer first.deinit();
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
    // The network stays silent; dusty's own fetch deadline fails the request.
    try std.testing.expectEqualStrings("Timeout", outcome.first_error_name);
    try mar.expectTraceContains(outcome.trace, "dusty_fault.client.fetch_error");
    try expectMidResponseNetworkOracle(outcome.trace);
}

test "dusty HTTP mid-response partition pins its schedule-visible events" {
    var first = try runMidResponsePartitionScenario(std.testing.allocator, 0xC0FFEE, .{
        .pre_chunks = total_chunks / 2,
    });
    defer first.deinit();
}

test "dusty HTTP large transfers survive byte-exact in both directions" {
    var outcome = try runLargeTransferScenario(std.testing.allocator, 0xC0FFEE);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u32, 200), outcome.upload_status);
    try std.testing.expectEqualStrings("upload:ok:524288", outcome.upload_reply);
    try std.testing.expectEqual(@as(u32, 200), outcome.download_status);
    try std.testing.expectEqual(@as(usize, large_download_len), outcome.download_len);
    try std.testing.expect(outcome.download_pattern_ok);

    // Both transfers ride one keep-alive connection, and the payloads span
    // many simulated packets rather than one oversized frame.
    try std.testing.expectEqual(@as(usize, 1), outcome.connect_count);
    try std.testing.expect(outcome.deliver_count >= 64);
    try std.testing.expect(outcome.graceful_shutdown);
}

test "dusty HTTP large transfers pin their schedule-visible events" {
    var first = try runLargeTransferScenario(std.testing.allocator, 0xC0FFEE);
    defer first.deinit();

    try mar.expectTraceContains(first.trace, "dusty_large.client.download status=200");
}

test "dusty HTTP pool reuses keep-alive connections across idle gaps and concurrency" {
    var outcome = try runPoolReuseScenario(std.testing.allocator, 0xC0FFEE);
    defer outcome.deinit();

    for (outcome.statuses) |status| {
        try std.testing.expectEqual(@as(u32, 200), status);
    }
    // Six fetches, exactly two connections: the first fetch dials, the idle
    // gap and both trailing fetches reuse, and only the second concurrent
    // fetch grows the pool.
    try std.testing.expectEqual(@as(usize, 2), outcome.connect_count);
    try std.testing.expect(outcome.graceful_shutdown);
}

test "dusty HTTP pool reuse pins its schedule-visible events" {
    var first = try runPoolReuseScenario(std.testing.allocator, 0xC0FFEE);
    defer first.deinit();

    try mar.expectTraceContains(first.trace, "dusty_pool.client.idle_gap_over");
    try mar.expectTraceContains(first.trace, "dusty_pool.client.concurrent_done");
}

test "dusty HTTP pool evicts a dead connection and redials after restart" {
    var outcome = try runPoolCrashScenario(std.testing.allocator, 0xC0FFEE);
    defer outcome.deinit();

    try std.testing.expectEqual(@as(u32, 200), outcome.first_status);

    // No attempt can converge while the server is down. Once it restarts,
    // the same client must recover instead of retaining a poisoned pool.
    try std.testing.expectEqual(@as(u32, max_retry_attempts), outcome.poisoned_attempts);
    try std.testing.expectEqual(@as(u32, 0), outcome.recovery_attempts);
    try std.testing.expectEqual(@as(usize, 0), outcome.post_restart_error_name.len);
    try mar.expectTraceContains(outcome.trace, "dusty_pool_crash.client.post_restart outcome=ok");

    // Three successful dials: the initial client, the recovered client, and
    // the fresh reachability probe.
    try std.testing.expectEqual(@as(u32, 200), outcome.fresh_status);
    try std.testing.expectEqual(@as(usize, 3), outcome.connect_count);

    try mar.expectTraceContains(outcome.trace, "process.kill node=0");
    try mar.expectTraceContains(outcome.trace, "process.restart node=0");
}

test "dusty HTTP pool recovery pins its schedule-visible events" {
    var first = try runPoolCrashScenario(std.testing.allocator, 0xC0FFEE);
    defer first.deinit();
}

test "dusty HTTP pool recovery holds across seeds" {
    var seed: u64 = 0;
    while (seed < 8) : (seed += 1) {
        var outcome = runPoolCrashScenario(std.testing.allocator, seed) catch |err| {
            std.debug.print("dusty pool recovery sweep failed seed={} err={}\n", .{ seed, err });
            return err;
        };
        defer outcome.deinit();

        try std.testing.expectEqual(@as(u32, max_retry_attempts), outcome.poisoned_attempts);
        try std.testing.expectEqual(@as(u32, 0), outcome.recovery_attempts);
        try std.testing.expectEqual(@as(usize, 0), outcome.post_restart_error_name.len);
        try std.testing.expectEqual(@as(u32, 200), outcome.fresh_status);
        try std.testing.expectEqual(@as(usize, 3), outcome.connect_count);
    }
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

test "dusty HTTP failures leave capsules: a passing run replays exactly from its capsule" {
    // Every run above already executed twice and compared traces. This one
    // also round-trips the evidence a failure would leave behind.
    var report = try BasicHarness.run(std.testing.allocator, .{ .seed = 0xC0FFEE, .tick_ns = 10 });
    defer report.deinit();
    const identity: mar.ReplayIdentity = .{ .build = "dusty-validation", .sut = "dusty@6f7544f99ec2540e93b0e864d618f8b9f771a414" };
    const bytes = try mar.ReplayCapsule.encode(std.testing.allocator, &report, identity);
    defer std.testing.allocator.free(bytes);
    var capsule = try mar.ReplayCapsule.decode(std.testing.allocator, bytes);
    defer capsule.deinit();
    var replayed = try BasicHarness.replay(std.testing.allocator, &capsule, identity);
    defer replayed.deinit();
    try std.testing.expect(replayed == .passed);
}
