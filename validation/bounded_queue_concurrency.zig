//! Capability validation for Marionette's cooperative `std.Io`
//! `Mutex` / `Condition` path.
//!
//! This is not an external SUT finding. It is a canonical bounded-buffer
//! scenario with an exact FIFO oracle, plus one deliberately buggy close path
//! that demonstrates deterministic lost-wakeup/deadlock detection.
//!
//! Scenario tasks use only `std.Io` (`Io.async`, `Io.Mutex`/`Io.Condition`,
//! `Io.sleep`); Marionette appears as the harness: world construction,
//! `sim.control.runTasksUntilIdle` for deadlock detection, and traces.

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

    fn push(self: *BoundedQueue, value: Item) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (self.count == queue_capacity and !self.closed) {
            self.not_full.waitUncancelable(self.io, &self.mutex);
        }
        if (self.closed) @panic("push after close");

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
    world: *mar.World,
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

    fn init(world: *mar.World, io: Io, close_mode: CloseMode) QueueScenario {
        return .{
            .world = world,
            .queue = BoundedQueue.init(io, close_mode),
        };
    }

    fn record(self: *QueueScenario, comptime fmt: []const u8, args: anytype) void {
        self.world.record(fmt, args) catch @panic("failed to record queue trace event");
    }

    fn appendAccepted(self: *QueueScenario, item: Item) void {
        if (self.accepted_count >= self.accepted.len) @panic("accepted model overflow");
        self.accepted[self.accepted_count] = item;
        self.accepted_count += 1;
    }

    fn appendConsumed(self: *QueueScenario, item: Item) void {
        if (self.consumed_count >= self.consumed.len) @panic("consumed model overflow");
        self.consumed[self.consumed_count] = item;
        self.consumed_count += 1;
    }

    fn producer(producer_arg: *ProducerArg) void {
        const scenario = producer_arg.scenario;

        for (0..producer_arg.items) |i| {
            // One-tick sleep between pushes widens the interleaving window
            // the seeded scheduler explores, like the yield it replaces.
            Io.sleep(scenario.queue.io, .fromNanoseconds(10), .awake) catch unreachable;
            const item: Item = @intCast((producer_arg.id + 1) * 1000 + i);
            scenario.queue.push(item);
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
        if (scenario.queue.pop() != null) @panic("close-only consumer unexpectedly received an item");
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
        Io.sleep(scenario.queue.io, .fromNanoseconds(10), .awake) catch unreachable;
        if (scenario.close_only_started != close_only_consumers) {
            @panic("close-only consumers did not all start before the close");
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

const TraceResult = struct {
    bytes: []u8,
    deadlocked: bool,

    fn deinit(self: TraceResult, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

fn runModelTrace(allocator: std.mem.Allocator, seed: u64) !TraceResult {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var scenario = QueueScenario.init(&world, io, .broadcast);

    for (0..producer_count) |i| {
        const extra = try world.randomIntLessThan(usize, max_items_per_producer);
        scenario.producers[i] = .{
            .scenario = &scenario,
            .id = i,
            .items = 1 + extra,
        };
        _ = try Io.concurrent(io, QueueScenario.producer, .{&scenario.producers[i]});
    }

    for (0..consumer_count) |i| {
        scenario.consumers[i] = .{
            .scenario = &scenario,
            .id = i,
        };
        _ = try Io.concurrent(io, QueueScenario.consumer, .{&scenario.consumers[i]});
    }

    const run_result = sim.control.runTasksUntilIdle();
    const deadlocked = if (run_result) false else |err| switch (err) {
        error.Deadlock => true,
        else => return err,
    };
    try std.testing.expect(!deadlocked);
    try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
    try scenario.verify();

    return .{
        .bytes = try allocator.dupe(u8, world.traceBytes()),
        .deadlocked = deadlocked,
    };
}

fn runCloseOnlyTrace(allocator: std.mem.Allocator, seed: u64, close_mode: CloseMode) !TraceResult {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();

    const sim = try world.simulate(.{});
    const io = sim.env.io();

    var scenario = QueueScenario.init(&world, io, close_mode);

    for (0..close_only_consumers) |i| {
        scenario.close_only[i] = .{
            .scenario = &scenario,
            .id = i,
        };
        _ = try Io.concurrent(io, QueueScenario.closeOnlyConsumer, .{&scenario.close_only[i]});
    }
    _ = try Io.concurrent(io, QueueScenario.closeOnlyCloser, .{&scenario});

    const run_result = sim.control.runTasksUntilIdle();
    const deadlocked = if (run_result) false else |err| switch (err) {
        error.Deadlock => true,
        else => return err,
    };

    switch (close_mode) {
        .broadcast => {
            try std.testing.expect(!deadlocked);
            try std.testing.expectEqual(close_only_consumers, scenario.close_only_started);
            try std.testing.expectEqual(close_only_consumers, scenario.close_only_exited);
            try std.testing.expectEqual(@as(usize, 0), sim.control.blockedTaskCount());
        },
        .signal_one => {
            try std.testing.expect(deadlocked);
            try std.testing.expectEqual(close_only_consumers, scenario.close_only_started);
            try std.testing.expectEqual(@as(usize, 1), scenario.close_only_exited);
            try std.testing.expect(sim.control.blockedTaskCount() > 0);
        },
    }

    return .{
        .bytes = try allocator.dupe(u8, world.traceBytes()),
        .deadlocked = deadlocked,
    };
}

test "bounded queue model oracle replays deterministically" {
    const first = try runModelTrace(std.testing.allocator, 0xB011D);
    defer first.deinit(std.testing.allocator);
    const second = try runModelTrace(std.testing.allocator, 0xB011D);
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(!first.deadlocked);
    try std.testing.expectEqualStrings(first.bytes, second.bytes);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "bounded_queue.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "bounded_queue.pop") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "scheduler.block") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "scheduler.idle") != null);
}

test "bounded queue model oracle survives seed sweep" {
    for (0..256) |i| {
        const trace = try runModelTrace(std.testing.allocator, 0xB011D_0000 + i);
        try std.testing.expect(!trace.deadlocked);
        trace.deinit(std.testing.allocator);
    }
}

test "bounded queue close broadcasts to all waiting consumers" {
    const trace = try runCloseOnlyTrace(std.testing.allocator, 0xB011D_C105E, .broadcast);
    defer trace.deinit(std.testing.allocator);

    try std.testing.expect(!trace.deadlocked);
    try std.testing.expect(std.mem.indexOf(u8, trace.bytes, "bounded_queue.close mode=broadcast") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace.bytes, "bounded_queue.close_only_started consumer=2 started=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace.bytes, "bounded_queue.close_only_exited consumer=") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace.bytes, "scheduler.deadlock") == null);
}

test "bounded queue close broadcast survives same close-path seed sweep" {
    for (0..256) |i| {
        const trace = try runCloseOnlyTrace(std.testing.allocator, 0xB011D_C105E_0000 + i, .broadcast);
        try std.testing.expect(!trace.deadlocked);
        trace.deinit(std.testing.allocator);
    }
}

test "buggy bounded queue close loses wakeup and deadlocks deterministically" {
    const first = try runCloseOnlyTrace(std.testing.allocator, 0xB011D_BAD, .signal_one);
    defer first.deinit(std.testing.allocator);
    const second = try runCloseOnlyTrace(std.testing.allocator, 0xB011D_BAD, .signal_one);
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(first.deadlocked);
    try std.testing.expectEqualStrings(first.bytes, second.bytes);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "bounded_queue.close mode=signal_one") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "bounded_queue.close_only_started consumer=2 started=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "bounded_queue.close_only_exited consumer=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "scheduler.deadlock") != null);
}
