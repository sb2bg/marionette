//! External-style validation for the `std.Io.net` KV example, run through
//! `mar.Harness`: the runner executes every seed twice and compares traces.
//!
//! The SUT imports only `std`. Scenario tasks also use only `std.Io`:
//! `Io.async` for task structure and futex flags for the fault-injection
//! handshake. Marionette owns the harness side: runner, network control,
//! seed, trace, and the exact retry/idempotency oracle.

const std = @import("std");
const mar = @import("marionette");
const sut = @import("examples").std_io_net_kv;

const Io = std.Io;

pub const ScenarioMode = enum {
    happy,
    retry_safe,
    retry_buggy,
};

pub const Outcome = struct {
    allocator: std.mem.Allocator,
    trace: []u8,
    first_response_timed_out: bool,
    final_value: ?i64,
    revision: u64,
    applied_puts: usize,
    invariant_violated: bool,

    pub fn deinit(self: *Outcome) void {
        self.allocator.free(self.trace);
        self.* = undefined;
    }
};

/// The client gives each response one simulated millisecond.
const client_options: sut.Client.Options = .{
    .response_timeout = .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } },
};

const Scenario = struct {
    server_io: Io,
    client_io: Io,
    harness_io: Io,
    control: mar.Control,
    address: Io.net.IpAddress,
    listener: Io.net.Server = undefined,
    mode: ScenarioMode,
    server: sut.Server,
    first_response_timed_out: bool = false,
    // Handshake flags for the fault choreography, signaled through the
    // simulated `std.Io` futex path.
    accept_waiting: u32 = 0,
    response_queued: u32 = 0,
    client_timed_out: u32 = 0,
    network_healed: u32 = 0,

    fn faulted(self: *const Scenario) bool {
        return self.mode != .happy;
    }

    fn requestLimit(self: *const Scenario) usize {
        return switch (self.mode) {
            .happy => 2,
            .retry_safe, .retry_buggy => 3,
        };
    }

    fn signal(self: *Scenario, flag: *u32) void {
        flag.* = 1;
        self.harness_io.futexWake(u32, flag, 1);
    }

    fn waitFor(self: *Scenario, flag: *u32) void {
        while (flag.* == 0) {
            self.harness_io.futexWait(u32, flag, 0) catch return;
        }
    }

    fn serverTask(self: *Scenario) void {
        // Signal immediately before accept. Cooperative execution guarantees
        // no client task can run between this signal and accept parking.
        self.record("std_io_net_kv.server.accept_waiting", .{});
        self.signal(&self.accept_waiting);
        var request_index: usize = 0;
        while (request_index < self.requestLimit()) {
            const stream = self.listener.accept(self.server_io) catch |err| return self.control.failRun(err);
            self.record("std_io_net_kv.server.accepted", .{});

            const connection_limit: usize = if (self.faulted() and request_index == 0) 1 else self.requestLimit() - request_index;
            for (0..connection_limit) |_| {
                self.server.serveOne(self.server_io, stream) catch |err| return self.control.failRun(err);
                self.record(
                    "std_io_net_kv.server.response request_index={} revision={} applied_puts={}",
                    .{ request_index, self.server.revision, self.server.applied_puts },
                );
                if (request_index == 0 and self.faulted()) self.signal(&self.response_queued);
                request_index += 1;
            }
            stream.close(self.server_io);
        }
    }

    fn clientTask(self: *Scenario) void {
        self.waitFor(&self.accept_waiting);
        var client = sut.Client.connectWith(self.client_io, self.address, client_options) catch |err| return self.control.failRun(err);
        defer client.deinit();
        self.record("std_io_net_kv.client.connected", .{});

        switch (self.mode) {
            .happy => {
                const put_response = client.put(1, 11, 41) catch |err| return self.control.failRun(err);
                self.record(
                    "std_io_net_kv.client.put request_id=1 revision={} duplicate={}",
                    .{ put_response.revision, put_response.duplicate },
                );
            },
            .retry_safe, .retry_buggy => {
                _ = client.put(7, 11, 41) catch |err| switch (err) {
                    // The client's own deadline ends the wait. The network
                    // only stays silent: the reply waits behind the partition.
                    error.ResponseTimeout => {
                        self.first_response_timed_out = true;
                        self.record("std_io_net_kv.client.timeout request_id=7", .{});
                        self.signal(&self.client_timed_out);
                        self.waitFor(&self.network_healed);
                        client.deinit();
                        client = sut.Client.connectWith(self.client_io, self.address, client_options) catch |reconnect_err|
                            return self.control.failRun(reconnect_err);
                        self.record("std_io_net_kv.client.reconnected", .{});
                    },
                    else => return self.control.failRun(err),
                };
                if (!self.first_response_timed_out) return self.control.failRun(error.FaultedPutReturned);

                const retry_response = client.put(7, 11, 41) catch |err| return self.control.failRun(err);
                self.record(
                    "std_io_net_kv.client.retry request_id=7 revision={} duplicate={}",
                    .{ retry_response.revision, retry_response.duplicate },
                );
            },
        }

        const get_response = client.get(8, 11) catch |err| return self.control.failRun(err);
        self.record(
            "std_io_net_kv.client.get key=11 value={} revision={}",
            .{ get_response.value, get_response.revision },
        );
    }

    fn faultController(self: *Scenario) void {
        self.waitFor(&self.response_queued);

        const server_side = [_]mar.NodeId{0};
        const client_side = [_]mar.NodeId{1};
        _ = self.control.network.partition(&server_side, &client_side, .{}) catch |err| return self.control.failRun(err);
        self.record("std_io_net_kv.fault partitioned=true", .{});

        self.waitFor(&self.client_timed_out);
        self.control.network.heal() catch |err| return self.control.failRun(err);
        self.record("std_io_net_kv.fault healed=true", .{});
        self.signal(&self.network_healed);
    }

    fn record(self: *Scenario, comptime fmt: []const u8, args: anytype) void {
        self.control.record(fmt, args);
    }
};

fn App(comptime mode: ScenarioMode) type {
    return struct {
        const Self = @This();
        const Case = mar.SimCase(Self);

        scenario: Scenario,

        fn init(sim: mar.Sim) !Self {
            try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
            const server_mode: sut.ServerMode = switch (mode) {
                .happy, .retry_safe => .deduplicate,
                .retry_buggy => .apply_every_put,
            };
            return .{
                .scenario = .{
                    .server_io = (try sim.envForNode(0)).io(),
                    .client_io = (try sim.envForNode(1)).io(),
                    .harness_io = sim.env.io(),
                    .control = sim.control,
                    // Node 0 owns its address; the client reaches it across the fabric.
                    .address = mar.AnyNetworkControl.hostIp4(0, 4570),
                    .mode = mode,
                    .server = sut.Server.init(server_mode),
                },
            };
        }

        fn run(case: *Case) !void {
            const scenario = &case.app.scenario;
            scenario.listener = try scenario.address.listen(scenario.server_io, .{});
            defer scenario.listener.deinit(scenario.server_io);

            var server_future = Io.async(scenario.server_io, Scenario.serverTask, .{scenario});
            var client_future = Io.async(scenario.client_io, Scenario.clientTask, .{scenario});
            var controller_future: ?Io.Future(void) = if (mode != .happy)
                Io.async(scenario.harness_io, Scenario.faultController, .{scenario})
            else
                null;

            server_future.await(scenario.server_io);
            client_future.await(scenario.client_io);
            if (controller_future) |*future| future.await(scenario.harness_io);
            if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;

            const final_value = scenario.server.get(11);
            const invariant_violated =
                final_value != 41 or
                scenario.server.revision != 1 or
                scenario.server.applied_puts != 1;
            if (invariant_violated) {
                case.control().record(
                    "std_io_net_kv.invariant_violation expected_value=41 actual_value={?} expected_revision=1 actual_revision={} expected_applied_puts=1 actual_applied_puts={}",
                    .{ final_value, scenario.server.revision, scenario.server.applied_puts },
                );
            } else {
                case.control().record("std_io_net_kv.check retry_idempotent=ok value=41 revision=1 applied_puts=1", .{});
            }
        }

        fn capture(case: *Case, allocator: std.mem.Allocator) !Outcome {
            const scenario = &case.app.scenario;
            const final_value = scenario.server.get(11);
            return .{
                .allocator = allocator,
                .trace = &.{},
                .first_response_timed_out = scenario.first_response_timed_out,
                .final_value = final_value,
                .revision = scenario.server.revision,
                .applied_puts = scenario.server.applied_puts,
                .invariant_violated = final_value != 41 or scenario.server.revision != 1 or scenario.server.applied_puts != 1,
            };
        }
    };
}

pub fn ScenarioHarness(comptime mode: ScenarioMode) type {
    return mar.Harness(.{
        .init = App(mode).init,
        .scenario = App(mode).run,
        .capture = App(mode).capture,
        .simulate = mar.World.SimulateOptions{ .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 16 } },
        .name = "std_io_net_kv." ++ @tagName(mode),
    });
}

/// Run one scenario through its harness. The runner has already executed it
/// twice and compared the traces.
pub fn runScenario(
    allocator: std.mem.Allocator,
    seed: u64,
    mode: ScenarioMode,
) !Outcome {
    return switch (mode) {
        inline else => |comptime_mode| runHarness(ScenarioHarness(comptime_mode), allocator, seed),
    };
}

fn runHarness(comptime H: type, allocator: std.mem.Allocator, seed: u64) !Outcome {
    var captured = try H.runCapture(allocator, .{ .seed = seed, .tick_ns = 10 });
    defer captured.deinit();
    switch (captured.report) {
        .passed => |passed| {
            var outcome = captured.outcome orelse return error.OutcomeNotCaptured;
            captured.outcome = null;
            outcome.trace = try allocator.dupe(u8, passed.trace);
            return outcome;
        },
        .failed => |failure| {
            failure.print();
            return error.ScenarioFailed;
        },
    }
}

test "std Io net KV happy path replays byte-identically" {
    var first = try runScenario(std.testing.allocator, 0xC0FFEE, .happy);
    defer first.deinit();

    try std.testing.expect(!first.first_response_timed_out);
    try std.testing.expect(!first.invariant_violated);
    try std.testing.expectEqual(@as(?i64, 41), first.final_value);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.client.get key=11 value=41 revision=1") != null);

    const accept_waiting = std.mem.indexOf(u8, first.trace, "std_io_net_kv.server.accept_waiting").?;
    const accept_blocked = std.mem.indexOfPos(u8, first.trace, accept_waiting, "scheduler.block task=").?;
    const client_connected = std.mem.indexOfPos(u8, first.trace, accept_blocked, "std_io_net_kv.client.connected").?;
    try std.testing.expect(accept_waiting < accept_blocked);
    try std.testing.expect(accept_blocked < client_connected);
}

test "std Io net KV retry remains idempotent across partition and heal" {
    var first = try runScenario(std.testing.allocator, 0xC0FFEE, .retry_safe);
    defer first.deinit();

    try std.testing.expect(first.first_response_timed_out);
    try std.testing.expect(!first.invariant_violated);
    try std.testing.expectEqual(@as(u64, 1), first.revision);
    try std.testing.expectEqual(@as(usize, 1), first.applied_puts);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "reason=fault fault=1 mode=drop") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.client.timeout request_id=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.fault healed=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.client.retry request_id=7 revision=1 duplicate=true") != null);
}

test "std Io net KV planted retry bug is replayable and detected" {
    var first = try runScenario(std.testing.allocator, 0xC0FFEE, .retry_buggy);
    defer first.deinit();

    try std.testing.expect(first.first_response_timed_out);
    try std.testing.expect(first.invariant_violated);
    try std.testing.expectEqual(@as(u64, 2), first.revision);
    try std.testing.expectEqual(@as(usize, 2), first.applied_puts);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.client.retry request_id=7 revision=2 duplicate=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.invariant_violation") != null);
}
