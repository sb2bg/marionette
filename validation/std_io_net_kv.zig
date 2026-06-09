//! External-style validation for the `std.Io.net` KV example.
//!
//! The SUT imports only `std`. This harness owns Marionette's scheduler,
//! network control, seed, trace, and exact retry/idempotency oracle.

const std = @import("std");
const mar = @import("marionette");
const sut = @import("examples").std_io_net_kv;

const Io = std.Io;
const response_queued_key: usize = 710_001;
const client_timed_out_key: usize = 710_002;
const network_healed_key: usize = 710_003;

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

const Scenario = struct {
    io: Io,
    world: *mar.World,
    control: mar.Control,
    address: Io.net.IpAddress,
    listener: Io.net.Server,
    mode: ScenarioMode,
    server: sut.Server,
    controller_waiting: bool = false,
    first_response_timed_out: bool = false,
    retry_response: ?sut.Response = null,
    get_response: ?sut.Response = null,
    client_yields: u8 = 0,

    fn requestLimit(self: *const Scenario) usize {
        return switch (self.mode) {
            .happy => 2,
            .retry_safe, .retry_buggy => 3,
        };
    }

    fn faulted(self: *const Scenario) bool {
        return self.mode != .happy;
    }

    fn serverTask(scheduler: *mar.UnstableTaskScheduler, arg: *anyopaque) void {
        const self: *Scenario = @ptrCast(@alignCast(arg));
        const stream = self.listener.accept(self.io) catch @panic("std_io_net_kv accept failed");
        defer stream.close(self.io);
        self.record("std_io_net_kv.server.accepted", .{});

        for (0..self.requestLimit()) |request_index| {
            self.server.serveOne(self.io, stream) catch @panic("std_io_net_kv serve failed");
            self.record(
                "std_io_net_kv.server.response request_index={} revision={} applied_puts={}",
                .{ request_index, self.server.revision, self.server.applied_puts },
            );

            if (request_index == 0 and self.faulted()) {
                while (!self.controller_waiting) scheduler.yieldCurrent();
                _ = scheduler.wake(response_queued_key, 1) catch @panic("response wake failed");
            }
        }
    }

    fn clientTask(scheduler: *mar.UnstableTaskScheduler, arg: *anyopaque) void {
        const self: *Scenario = @ptrCast(@alignCast(arg));
        while (scheduler.blockedCount() < 1) {
            self.client_yields += 1;
            if (self.client_yields > 32) @panic("server did not block on accept");
            scheduler.yieldCurrent();
        }

        var client = sut.Client.connect(self.io, self.address) catch @panic("std_io_net_kv connect failed");
        defer client.deinit();
        self.record("std_io_net_kv.client.connected", .{});

        switch (self.mode) {
            .happy => {
                const put_response = client.put(1, 11, 41) catch @panic("happy PUT failed");
                self.record(
                    "std_io_net_kv.client.put request_id=1 revision={} duplicate={}",
                    .{ put_response.revision, put_response.duplicate },
                );
            },
            .retry_safe, .retry_buggy => {
                _ = client.put(7, 11, 41) catch |err| switch (err) {
                    error.Timeout => {
                        self.first_response_timed_out = true;
                        self.record("std_io_net_kv.client.timeout request_id=7", .{});
                        _ = scheduler.wake(client_timed_out_key, 1) catch @panic("timeout wake failed");
                        scheduler.blockCurrent(network_healed_key);
                    },
                    else => @panic("unexpected first PUT error"),
                };
                if (!self.first_response_timed_out) @panic("faulted PUT unexpectedly returned");

                self.retry_response = client.put(7, 11, 41) catch @panic("retry PUT failed");
                self.record(
                    "std_io_net_kv.client.retry request_id=7 revision={} duplicate={}",
                    .{ self.retry_response.?.revision, self.retry_response.?.duplicate },
                );
            },
        }

        self.get_response = client.get(8, 11) catch @panic("GET failed");
        self.record(
            "std_io_net_kv.client.get key=11 value={} revision={}",
            .{ self.get_response.?.value, self.get_response.?.revision },
        );
    }

    fn faultController(scheduler: *mar.UnstableTaskScheduler, arg: *anyopaque) void {
        const self: *Scenario = @ptrCast(@alignCast(arg));
        self.controller_waiting = true;
        scheduler.blockCurrent(response_queued_key);

        const server_side = [_]mar.NodeId{0};
        const client_side = [_]mar.NodeId{1};
        self.control.network.partition(&server_side, &client_side) catch @panic("partition failed");
        self.record("std_io_net_kv.fault partitioned=true", .{});

        scheduler.blockCurrent(client_timed_out_key);
        self.control.network.heal() catch @panic("heal failed");
        self.record("std_io_net_kv.fault healed=true", .{});
        _ = scheduler.wake(network_healed_key, 1) catch @panic("heal wake failed");
    }

    fn record(self: *Scenario, comptime fmt: []const u8, args: anytype) void {
        self.world.record(fmt, args) catch @panic("std_io_net_kv trace record failed");
    }
};

pub fn runScenario(
    allocator: std.mem.Allocator,
    seed: u64,
    mode: ScenarioMode,
) !Outcome {
    const runtime_allocator = std.heap.page_allocator;

    const world = try runtime_allocator.create(mar.World);
    errdefer runtime_allocator.destroy(world);
    world.* = try mar.World.init(runtime_allocator, .{
        .seed = seed,
        .tick_ns = 10,
    });
    defer {
        world.deinit();
        runtime_allocator.destroy(world);
    }

    const scheduler = try runtime_allocator.create(mar.UnstableTaskScheduler);
    errdefer runtime_allocator.destroy(scheduler);
    scheduler.* = mar.UnstableTaskScheduler.init(runtime_allocator, world);
    defer {
        scheduler.deinit();
        runtime_allocator.destroy(scheduler);
    }

    const sim = try world.simulate(.{ .network = .{
        .nodes = 2,
        .service_nodes = 1,
        .path_capacity = 16,
    } });
    const io = sim.env.io();
    const backend: *mar.SimIo.Backend = @ptrCast(@alignCast(io.userdata.?));
    backend.attachFutexWaitSet(mar.unstableTaskSchedulerFutexWaitSet(scheduler));

    try sim.control.network.setLatency(.{ .min_latency_ns = 30 });

    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4570) catch unreachable;
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);

    const server_mode: sut.ServerMode = switch (mode) {
        .happy, .retry_safe => .deduplicate,
        .retry_buggy => .apply_every_put,
    };
    const scenario = try runtime_allocator.create(Scenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{
        .io = io,
        .world = world,
        .control = sim.control,
        .address = address,
        .listener = listener,
        .mode = mode,
        .server = sut.Server.init(server_mode),
    };

    _ = try scheduler.spawn(.{
        .entry = Scenario.serverTask,
        .arg = scenario,
    });
    _ = try scheduler.spawn(.{
        .entry = Scenario.clientTask,
        .arg = scenario,
    });
    if (mode != .happy) {
        _ = try scheduler.spawn(.{
            .entry = Scenario.faultController,
            .arg = scenario,
        });
    }

    try scheduler.runUntilIdle();
    if (scheduler.blockedCount() != 0) return error.ScenarioDeadlocked;
    const expected_completed: usize = if (mode == .happy) 2 else 3;
    if (scheduler.completedCount() != expected_completed) {
        return error.ScenarioTaskCountMismatch;
    }

    const final_value = scenario.server.get(11);
    const invariant_violated =
        final_value != 41 or
        scenario.server.revision != 1 or
        scenario.server.applied_puts != 1;

    if (invariant_violated) {
        try world.record(
            "std_io_net_kv.invariant_violation expected_value=41 actual_value={?} expected_revision=1 actual_revision={} expected_applied_puts=1 actual_applied_puts={}",
            .{ final_value, scenario.server.revision, scenario.server.applied_puts },
        );
    } else {
        try world.record(
            "std_io_net_kv.check retry_idempotent=ok value=41 revision=1 applied_puts=1",
            .{},
        );
    }

    const trace = try allocator.dupe(u8, world.traceBytes());
    errdefer allocator.free(trace);
    const first_response_timed_out = scenario.first_response_timed_out;
    const revision = scenario.server.revision;
    const applied_puts = scenario.server.applied_puts;

    return .{
        .allocator = allocator,
        .trace = trace,
        .first_response_timed_out = first_response_timed_out,
        .final_value = final_value,
        .revision = revision,
        .applied_puts = applied_puts,
        .invariant_violated = invariant_violated,
    };
}

test "std Io net KV happy path replays byte-identically" {
    var first = try runScenario(std.testing.allocator, 0xC0FFEE, .happy);
    defer first.deinit();
    var second = try runScenario(std.testing.allocator, 0xC0FFEE, .happy);
    defer second.deinit();

    try std.testing.expectEqualStrings(first.trace, second.trace);
    try std.testing.expect(!first.first_response_timed_out);
    try std.testing.expect(!first.invariant_violated);
    try std.testing.expectEqual(@as(?i64, 41), first.final_value);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.client.get key=11 value=41 revision=1") != null);
}

test "std Io net KV retry remains idempotent across partition and heal" {
    var first = try runScenario(std.testing.allocator, 0xC0FFEE, .retry_safe);
    defer first.deinit();
    var second = try runScenario(std.testing.allocator, 0xC0FFEE, .retry_safe);
    defer second.deinit();

    try std.testing.expectEqualStrings(first.trace, second.trace);
    try std.testing.expect(first.first_response_timed_out);
    try std.testing.expect(!first.invariant_violated);
    try std.testing.expectEqual(@as(u64, 1), first.revision);
    try std.testing.expectEqual(@as(usize, 1), first.applied_puts);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "reason=link_disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.client.timeout request_id=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.fault healed=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.client.retry request_id=7 revision=1 duplicate=true") != null);
}

test "std Io net KV planted retry bug is replayable and detected" {
    var first = try runScenario(std.testing.allocator, 0xC0FFEE, .retry_buggy);
    defer first.deinit();
    var second = try runScenario(std.testing.allocator, 0xC0FFEE, .retry_buggy);
    defer second.deinit();

    try std.testing.expectEqualStrings(first.trace, second.trace);
    try std.testing.expect(first.first_response_timed_out);
    try std.testing.expect(first.invariant_violated);
    try std.testing.expectEqual(@as(u64, 2), first.revision);
    try std.testing.expectEqual(@as(usize, 2), first.applied_puts);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.client.retry request_id=7 revision=2 duplicate=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.trace, "std_io_net_kv.invariant_violation") != null);
}
