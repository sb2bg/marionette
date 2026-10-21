//! Campaign workload: pinned, unmodified lalinsky/redis.zig against a RESP2
//! peer that applies INCR and may lose replies. The peer's applied count is an
//! independent oracle for what the client acknowledged.
//!
//! `at_least_once_checks` states the client's documented retry behavior and is
//! expected to hold. `exactly_once_checks` is deliberately stronger than the
//! client promises: lost replies are retried and reexecuted, so a campaign
//! finds, retains, and reduces that characterized behavior. It is not a bug
//! claim against the client.
const std = @import("std");
const mar = @import("marionette");
const redis = @import("redis");
const Io = std.Io;

const address = Io.net.IpAddress.parseIp4("127.0.0.1", 6379) catch unreachable;
const incr = "*2\r\n$4\r\nINCR\r\n$7\r\ncounter\r\n";
const ping = "*1\r\n$4\r\nPING\r\n";
const max_incrs = 4;

pub const tick_ns: u64 = 10;

pub fn simulateOptions() mar.World.SimulateOptions {
    return .{
        .network = .{ .nodes = 2, .service_nodes = 1, .path_capacity = 32 },
        // Generous for a few commands with retries; a stuck exchange fails
        // as a reproducible step-budget failure instead of hanging.
        .step_budget = 50_000,
    };
}

pub const App = struct {
    allocator: std.mem.Allocator,
    world: *mar.World,
    server_io: Io,
    client_io: Io,
    ready: u32 = 0,
    /// INCRs the peer applied, counted independently of the client.
    applied: u32 = 0,
    /// INCR calls that returned a value to the caller.
    acknowledged: u32 = 0,
    /// INCR calls that returned an error to the caller.
    failed_calls: u32 = 0,
    /// Each acknowledged value must be the counter after a real application.
    max_acknowledged_value: i64 = 0,
    out_of_order_value: bool = false,
    /// The peer received bytes that were not the exact expected command.
    protocol_violation: bool = false,
    client_done: bool = false,
    client: ?redis.Client = null,

    pub fn init(sim: mar.Sim) !App {
        try sim.control.network.setLatency(.{ .min_latency_ns = 30 });
        return .{
            .allocator = sim.env.allocator(),
            .world = sim.control.world,
            .server_io = (try sim.envForNode(0)).io(),
            .client_io = (try sim.envForNode(1)).io(),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.client) |*client| client.deinit();
    }

    fn serve(self: *App) !void {
        var listener = try address.listen(self.server_io, .{});
        defer listener.deinit(self.server_io);
        self.ready = 1;
        self.server_io.futexWake(u32, &self.ready, 1);
        // A connection ends when the client hangs up, the peer loses a reply,
        // or shutdown cancels its read; only the client's hang-up is final.
        while (!self.client_done) {
            const stream = listener.accept(self.server_io) catch |err| switch (err) {
                error.Canceled => return,
                else => |other| return other,
            };
            self.serveConnection(stream) catch |err| switch (err) {
                error.UnexpectedCommand => self.protocol_violation = true,
                else => {},
            };
        }
    }

    fn serveConnection(self: *App, stream: Io.net.Stream) !void {
        defer stream.close(self.server_io);
        var rb: [256]u8 = undefined;
        var wb: [64]u8 = undefined;
        var reader = stream.reader(self.server_io, &rb);
        var writer = stream.writer(self.server_io, &wb);
        const r = &reader.interface;
        const w = &writer.interface;
        while (true) {
            const header = r.takeArray(4) catch |err| switch (err) {
                error.EndOfStream => return,
                else => |other| return other,
            };
            if (std.mem.eql(u8, header, incr[0..4])) {
                if (!std.mem.eql(u8, try r.takeArray(incr.len - 4), incr[4..])) return error.UnexpectedCommand;
                self.applied += 1;
                try self.world.record("redis.peer.applied count={d}", .{self.applied});
                // Zero delivers; reduction removes losses by zeroing this site.
                if (try self.world.chooseIntLessThan("redis.peer.lose_reply", u8, 4) == 3) {
                    try self.world.record("redis.peer.lost_reply count={d}", .{self.applied});
                    return;
                }
                try w.print(":{d}\r\n", .{self.applied});
            } else if (std.mem.eql(u8, header, ping[0..4])) {
                if (!std.mem.eql(u8, try r.takeArray(ping.len - 4), ping[4..])) return error.UnexpectedCommand;
                try w.writeAll("+PONG\r\n");
            } else return error.UnexpectedCommand;
            try w.flush();
        }
    }

    fn incrOnce(case: *mar.SimCase(App)) !void {
        const self = &case.app;
        const value = self.client.?.incr("counter") catch {
            self.failed_calls += 1;
            try self.world.record("redis.client.incr_failed", .{});
            return;
        };
        self.acknowledged += 1;
        if (value <= self.max_acknowledged_value) self.out_of_order_value = true;
        self.max_acknowledged_value = value;
        try self.world.record("redis.client.acknowledged value={d}", .{value});
    }

    fn connectClient(self: *App) !void {
        while (self.ready == 0) try self.server_io.futexWait(u32, &self.ready, 0);
        self.client = try redis.Client.init(self.allocator, self.client_io, "127.0.0.1:6379", .{ .retry_attempts = 2 });
    }
};

const Case = mar.SimCase(App);

/// Up to four INCRs, each a removable action, then the client hangs up.
pub fn scenario(case: *Case) !void {
    const app = &case.app;
    var server = try Io.concurrent(app.server_io, App.serve, .{app});
    defer server.cancel(app.server_io) catch {};
    var connect = try Io.concurrent(app.client_io, App.connectClient, .{app});
    try connect.await(app.client_io);

    inline for (0..max_incrs) |index| {
        try case.action(std.fmt.comptimePrint("redis.incr.{d}", .{index}), App.incrOnce);
    }
    app.client_done = true;
    app.client.?.deinit();
    app.client = null;
}

fn atLeastOnce(case: *const Case) !void {
    const app = &case.app;
    if (app.protocol_violation) return error.UnexpectedCommand;
    // Every acknowledged value came from a real application, in order.
    if (app.acknowledged > app.applied) return error.AcknowledgedUnappliedIncrement;
    if (app.max_acknowledged_value > app.applied) return error.AcknowledgedFutureValue;
    if (app.out_of_order_value) return error.AcknowledgedValuesOutOfOrder;
}

fn exactlyOnce(case: *const Case) !void {
    const app = &case.app;
    if (app.applied != app.acknowledged) return error.IncrementAppliedWithoutSingleAcknowledgment;
}

pub const at_least_once_checks = [_]mar.StateCheck(Case){
    .{ .name = "redis.incr.at_least_once", .check = atLeastOnce },
};

pub const exactly_once_checks = [_]mar.StateCheck(Case){
    .{ .name = "redis.incr.at_least_once", .check = atLeastOnce },
    .{ .name = "redis.incr.exactly_once", .check = exactlyOnce },
};
