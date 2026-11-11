//! Capability validation for Marionette's cooperative `std.Io`
//! `Mutex` / `Condition` path.
//!
//! This is not an external SUT finding. It is a canonical bounded-buffer
//! scenario with an exact FIFO oracle, plus one deliberately buggy close path
//! that demonstrates deterministic lost-wakeup/deadlock detection.
//!
//! Scenario tasks use only `std.Io` (`Io.async`, `Io.Mutex`/`Io.Condition`,
//! `Io.sleep`); Marionette appears as the harness: a `mar.Harness` per
//! scenario, `runTasksUntilIdle` for deadlock detection, and traces.

const std = @import("std");
const mar = @import("marionette");

const Io = std.Io;
const Item = u32;

const queue_capacity = 2;
const producer_count = 3;
const consumer_count = 4;
const max_items_per_producer = 6;
const max_items = producer_count * max_items_per_producer;
const close_only_consumers = 3;

const CloseMode = enum {
    broadcast,
    signal_one,
};

const BoundedQueue = struct {
    io: Io,
    close_mode: CloseMode,
    mutex: Io.Mutex = .init,
    not_empty: Io.Condition = .init,
    not_full: Io.Condition = .init,
    buffer: [queue_capacity]Item = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    closed: bool = false,

    fn init(io: Io, close_mode: CloseMode) BoundedQueue {
        return .{
            .io = io,
            .close_mode = close_mode,
        };
    }

    fn push(self: *BoundedQueue, value: Item) error{Closed}!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.count == queue_capacity and !self.closed) {
            self.not_full.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) return error.Closed;

        self.buffer[self.tail] = value;
        self.tail = (self.tail + 1) % queue_capacity;
        self.count += 1;
        self.not_empty.signal(self.io);
    }

    fn pop(self: *BoundedQueue) ?Item {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.count == 0 and !self.closed) {
            self.not_empty.waitUncancelable(self.io, &self.mutex);
        }
        if (self.count == 0) return null;

        const value = self.buffer[self.head];
        self.head = (self.head + 1) % queue_capacity;
        self.count -= 1;
        self.not_full.signal(self.io);
        return value;
    }

    fn close(self: *BoundedQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closed) return;
        self.closed = true;
        switch (self.close_mode) {
            .broadcast => {
                self.not_empty.broadcast(self.io);
                self.not_full.broadcast(self.io);
            },
            .signal_one => {
                // Deliberately buggy: closing a queue must wake every waiter.
                // Waking one consumer strands the rest in `pop()` forever.
                self.not_empty.signal(self.io);
                self.not_full.signal(self.io);
            },
        }
    }
};

const ProducerArg = struct {
    scenario: *QueueScenario,
    id: usize,
    items: usize,
};

const ConsumerArg = struct {
    scenario: *QueueScenario,
    id: usize,
};

const QueueScenario = struct {
    control: mar.Control,
    queue: BoundedQueue,
    producers: [producer_count]ProducerArg = undefined,
    consumers: [consumer_count]ConsumerArg = undefined,
    close_only: [close_only_consumers]ConsumerArg = undefined,
    accepted: [max_items]Item = undefined,
    consumed: [max_items]Item = undefined,
    accepted_count: usize = 0,
    consumed_count: usize = 0,
    producers_done: usize = 0,
    consumers_done: usize = 0,
    close_only_started: usize = 0,
    close_only_exited: usize = 0,

    fn init(control: mar.Control, io: Io, close_mode: CloseMode) QueueScenario {
        return .{
            .control = control,
            .queue = BoundedQueue.init(io, close_mode),
        };
    }

    fn record(self: *QueueScenario, comptime fmt: []const u8, args: anytype) void {
        self.control.record(fmt, args);
    }

    fn appendAccepted(self: *QueueScenario, item: Item) void {
        if (self.accepted_count >= self.accepted.len) return self.control.failRun(error.AcceptedModelOverflow);
        self.accepted[self.accepted_count] = item;
        self.accepted_count += 1;
    }

    fn appendConsumed(self: *QueueScenario, item: Item) void {
        if (self.consumed_count >= self.consumed.len) return self.control.failRun(error.ConsumedModelOverflow);
        self.consumed[self.consumed_count] = item;
        self.consumed_count += 1;
    }

    fn producer(producer_arg: *ProducerArg) void {
        const scenario = producer_arg.scenario;

        for (0..producer_arg.items) |i| {
            // One-tick sleep between pushes widens the interleaving window
            // the seeded scheduler explores, like the yield it replaces.
            Io.sleep(scenario.queue.io, .fromNanoseconds(10), .awake) catch return;
            const item: Item = @intCast((producer_arg.id + 1) * 1000 + i);
            scenario.queue.push(item) catch |err| return scenario.control.failRun(err);
            scenario.appendAccepted(item);
            scenario.record("bounded_queue.push producer={} value={}", .{ producer_arg.id, item });
        }

        scenario.producers_done += 1;
        scenario.record("bounded_queue.producer_done producer={} done={}", .{ producer_arg.id, scenario.producers_done });
        if (scenario.producers_done == producer_count) {
            scenario.record("bounded_queue.close mode=broadcast reason=producers_done", .{});
            scenario.queue.close();
        }
    }

    fn consumer(consumer_arg: *ConsumerArg) void {
        const scenario = consumer_arg.scenario;

        while (scenario.queue.pop()) |item| {
            scenario.appendConsumed(item);
            scenario.record("bounded_queue.pop consumer={} value={}", .{ consumer_arg.id, item });
        }
        scenario.consumers_done += 1;
        scenario.record("bounded_queue.consumer_done consumer={} done={}", .{ consumer_arg.id, scenario.consumers_done });
    }

    fn closeOnlyConsumer(consumer_arg: *ConsumerArg) void {
        const scenario = consumer_arg.scenario;

        scenario.close_only_started += 1;
        scenario.record("bounded_queue.close_only_started consumer={} started={}", .{
            consumer_arg.id,
            scenario.close_only_started,
        });
        if (scenario.queue.pop() != null) return scenario.control.failRun(error.CloseOnlyConsumerReceivedItem);
        scenario.close_only_exited += 1;
        scenario.record("bounded_queue.close_only_exited consumer={} exited={}", .{
            consumer_arg.id,
            scenario.close_only_exited,
        });
    }

    fn closeOnlyCloser(scenario: *QueueScenario) void {
        // Sleep one tick before closing: simulated time only advances once
        // every non-timed task has parked, so all close-only consumers are
        // guaranteed to be blocked inside `pop()` when the close fires.
        Io.sleep(scenario.queue.io, .fromNanoseconds(10), .awake) catch return;
        if (scenario.close_only_started != close_only_consumers) {
            return scenario.control.failRun(error.CloseOnlyConsumersNotStarted);
        }
        scenario.record("bounded_queue.close mode={s} reason=close_only", .{
            switch (scenario.queue.close_mode) {
                .broadcast => "broadcast",
                .signal_one => "signal_one",
            },
        });
        scenario.queue.close();
    }

    fn verify(self: *const QueueScenario) !void {
        try std.testing.expectEqual(producer_count, self.producers_done);
        try std.testing.expectEqual(consumer_count, self.consumers_done);
        try std.testing.expectEqual(self.accepted_count, self.consumed_count);

        for (self.accepted[0..self.accepted_count], self.consumed[0..self.consumed_count]) |expected, actual| {
            try std.testing.expectEqual(expected, actual);
        }
    }
};

const ModelApp = struct {
    scenario: QueueScenario,

    fn init(sim: mar.Sim) ModelApp {
        return .{ .scenario = QueueScenario.init(sim.control, sim.env.io(), .broadcast) };
    }

    fn run(case: *mar.SimCase(ModelApp)) !void {
        const scenario = &case.app.scenario;
        const io = scenario.queue.io;
        for (0..producer_count) |i| {
            const extra = try case.control().chooseIntLessThan("bounded_queue.extra_items", usize, max_items_per_producer);
            scenario.producers[i] = .{ .scenario = scenario, .id = i, .items = 1 + extra };
            _ = try Io.concurrent(io, QueueScenario.producer, .{&scenario.producers[i]});
        }
        for (0..consumer_count) |i| {
            scenario.consumers[i] = .{ .scenario = scenario, .id = i };
            _ = try Io.concurrent(io, QueueScenario.consumer, .{&scenario.consumers[i]});
        }
        try case.control().runTasksUntilIdle();
        if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
    }

    fn fifo(case: *const mar.SimCase(ModelApp)) !void {
        try case.app.scenario.verify();
    }

    const checks = [_]mar.StateCheck(mar.SimCase(ModelApp)){
        .{ .name = "bounded_queue.fifo_model", .check = fifo, .phase = .after_scenario },
    };
};

const ModelHarness = mar.Harness(.{
    .init = ModelApp.init,
    .scenario = ModelApp.run,
    .checks = &ModelApp.checks,
    .name = "bounded_queue.model",
});

fn CloseOnlyApp(comptime close_mode: CloseMode) type {
    return struct {
        const Self = @This();

        scenario: QueueScenario,

        fn init(sim: mar.Sim) Self {
            return .{ .scenario = QueueScenario.init(sim.control, sim.env.io(), close_mode) };
        }

        /// The broadcast close must release every waiter. The planted
        /// signal-one close must strand two consumers in a detected deadlock.
        fn run(case: *mar.SimCase(Self)) !void {
            const scenario = &case.app.scenario;
            const io = scenario.queue.io;
            for (0..close_only_consumers) |i| {
                scenario.close_only[i] = .{ .scenario = scenario, .id = i };
                _ = try Io.concurrent(io, QueueScenario.closeOnlyConsumer, .{&scenario.close_only[i]});
            }
            _ = try Io.concurrent(io, QueueScenario.closeOnlyCloser, .{scenario});

            const deadlocked = if (case.control().runTasksUntilIdle()) false else |err| switch (err) {
                error.Deadlock => true,
                else => return err,
            };
            if (scenario.close_only_started != close_only_consumers) return error.ConsumersDidNotStart;
            switch (close_mode) {
                .broadcast => {
                    if (deadlocked) return error.UnexpectedDeadlock;
                    if (scenario.close_only_exited != close_only_consumers) return error.ConsumersStranded;
                    if (case.control().blockedTaskCount() != 0) return error.ScenarioDeadlocked;
                },
                .signal_one => {
                    if (!deadlocked) return error.LostWakeupNotDetected;
                    if (scenario.close_only_exited != 1) return error.UnexpectedExits;
                    if (case.control().blockedTaskCount() == 0) return error.NoStrandedConsumers;
                },
            }
        }
    };
}

fn CloseOnlyHarness(comptime close_mode: CloseMode) type {
    return mar.Harness(.{
        .init = CloseOnlyApp(close_mode).init,
        .scenario = CloseOnlyApp(close_mode).run,
        .name = "bounded_queue.close_" ++ @tagName(close_mode),
    });
}

fn passingTrace(comptime H: type, seed: u64) ![]u8 {
    var report = try H.run(std.testing.allocator, .{ .seed = seed, .tick_ns = 10 });
    defer report.deinit();
    switch (report) {
        .passed => |passed| return std.testing.allocator.dupe(u8, passed.trace),
        .failed => |failure| {
            failure.print();
            return error.ScenarioFailed;
        },
    }
}

test "bounded queue model oracle replays deterministically" {
    const trace = try passingTrace(ModelHarness, 0xB011D);
    defer std.testing.allocator.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "bounded_queue.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "bounded_queue.pop") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "scheduler.block") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "scheduler.idle") != null);
}

test "bounded queue model oracle survives seed sweep" {
    try ModelHarness.fuzz(std.testing.allocator, .{ .seed = 0xB011D_0000, .tick_ns = 10 }, .{ .seeds = 256 });
}

test "bounded queue close broadcasts to all waiting consumers" {
    const trace = try passingTrace(CloseOnlyHarness(.broadcast), 0xB011D_C105E);
    defer std.testing.allocator.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "bounded_queue.close mode=broadcast") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "bounded_queue.close_only_started consumer=2 started=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "bounded_queue.close_only_exited consumer=") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "scheduler.deadlock") == null);
}

test "bounded queue close broadcast survives same close-path seed sweep" {
    try CloseOnlyHarness(.broadcast).fuzz(std.testing.allocator, .{ .seed = 0xB011D_C105E_0000, .tick_ns = 10 }, .{ .seeds = 256 });
}

test "buggy bounded queue close loses wakeup and deadlocks deterministically" {
    const trace = try passingTrace(CloseOnlyHarness(.signal_one), 0xB011D_BAD);
    defer std.testing.allocator.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "bounded_queue.close mode=signal_one") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "bounded_queue.close_only_started consumer=2 started=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "bounded_queue.close_only_exited consumer=") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "scheduler.deadlock") != null);
}
