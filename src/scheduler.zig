//! Deterministic scheduler building blocks.

const std = @import("std");

const fiber = @import("fiber.zig");
const world_module = @import("world.zig");

const World = world_module.World;
const traceField = world_module.traceField;

/// Errors returned by fixed-capacity event queues.
pub const EventQueueError = error{
    EventQueueFull,
};

/// Stable task identifier assigned by the deterministic scheduler.
pub const TaskId = u64;

/// Default stack for scheduled tasks.
///
/// Scheduler tasks run normal Marionette code, including trace formatting and
/// allocator calls, so they need more room than the primitive fiber smoke test.
pub const default_task_stack_size = 256 * 1024;

/// Errors returned by the experimental cooperative scheduler itself.
pub const TaskSchedulerError = error{
    Deadlock,
    NoCurrentTask,
    TaskNotBlocked,
    TaskNotReady,
    TaskNotRunning,
    TaskSuspendedWithoutYield,
} || fiber.Error || std.mem.Allocator.Error || world_module.TraceError;

/// Opaque wait-set key. Futexes will key this by address; timers and I/O can
/// use scheduler-owned identifiers.
pub const WaitKey = usize;

/// Experimental seeded cooperative scheduler.
///
/// This is intentionally isolated from the `std.Io` backend for now. It exists
/// to prove deterministic scheduling policy over Marionette fibers before
/// futexes, timers, or real SUTs sit on top of it.
pub const TaskScheduler = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    world: *World,
    main_context: fiber.Context = undefined,
    tasks: std.ArrayList(*Task) = .empty,
    ready: std.ArrayList(TaskId) = .empty,
    current: ?*Task = null,
    next_task_id: TaskId = 0,

    pub const Entry = *const fn (scheduler: *Self, arg: *anyopaque) void;

    pub const SpawnOptions = struct {
        stack_size: usize = default_task_stack_size,
        entry: Entry,
        arg: *anyopaque,
    };

    const TaskState = enum {
        ready,
        running,
        blocked,
        completed,
    };

    const SwitchReason = enum {
        yielded,
        blocked,
        completed,
    };

    const SwitchMessage = struct {
        contexts: fiber.Switch,
        scheduler: *Self,
        task: *Task,
        reason: SwitchReason,
        key: WaitKey = 0,
    };

    const Task = struct {
        id: TaskId,
        scheduler: *Self,
        entry: Entry,
        arg: *anyopaque,
        fiber_instance: *fiber.Fiber,
        state: TaskState = .ready,
        blocked_key: ?WaitKey = null,

        fn run(arg: *anyopaque) void {
            const task: *Task = @ptrCast(@alignCast(arg));
            task.entry(task.scheduler, task.arg);
            task.scheduler.completeCurrent(task);
            unreachable;
        }
    };

    pub fn init(allocator: std.mem.Allocator, world: *World) Self {
        return .{
            .allocator = allocator,
            .world = world,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.tasks.items) |task| {
            task.fiber_instance.destroy();
            self.allocator.destroy(task);
        }
        self.tasks.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn spawn(self: *Self, options: SpawnOptions) TaskSchedulerError!TaskId {
        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);

        const task_id = self.next_task_id;
        task.* = .{
            .id = task_id,
            .scheduler = self,
            .entry = options.entry,
            .arg = options.arg,
            .fiber_instance = undefined,
        };

        task.fiber_instance = try fiber.Fiber.create(self.allocator, .{
            .stack_size = options.stack_size,
            .finish_context = &self.main_context,
            .entry = Task.run,
            .arg = task,
        });
        errdefer task.fiber_instance.destroy();

        try self.tasks.append(self.allocator, task);
        errdefer _ = self.tasks.pop();

        try self.ready.append(self.allocator, task_id);
        errdefer _ = self.ready.pop();

        try self.recordSpawn(task_id);
        self.next_task_id += 1;
        return task_id;
    }

    // This boundary is load-bearing: ReleaseSafe corrupted task state when the
    // optimizer inlined across the context switch. Keep suspension points
    // opaque so the switch is treated as a real control-flow discontinuity.
    pub noinline fn yieldCurrent(self: *Self) void {
        const task = self.current orelse @panic("yield outside a scheduled task");
        if (task.state != .running) @panic("yield from a non-running task");

        var message: SwitchMessage = .{
            .contexts = .{
                .old = task.fiber_instance.contextPtr(),
                .new = &self.main_context,
            },
            .scheduler = self,
            .task = task,
            .reason = .yielded,
        };
        _ = fiber.contextSwitch(&message.contexts);
    }

    // Same optimizer boundary rule as `yieldCurrent`.
    pub noinline fn blockCurrent(self: *Self, key: WaitKey) void {
        const task = self.current orelse @panic("block outside a scheduled task");
        if (task.state != .running) @panic("block from a non-running task");

        var message: SwitchMessage = .{
            .contexts = .{
                .old = task.fiber_instance.contextPtr(),
                .new = &self.main_context,
            },
            .scheduler = self,
            .task = task,
            .reason = .blocked,
            .key = key,
        };
        _ = fiber.contextSwitch(&message.contexts);
    }

    // Same optimizer boundary rule as `yieldCurrent`.
    noinline fn completeCurrent(self: *Self, task: *Task) void {
        var message: SwitchMessage = .{
            .contexts = .{
                .old = task.fiber_instance.contextPtr(),
                .new = &self.main_context,
            },
            .scheduler = self,
            .task = task,
            .reason = .completed,
        };
        _ = fiber.contextSwitch(&message.contexts);
    }

    pub fn wake(self: *Self, key: WaitKey, max_count: usize) TaskSchedulerError!usize {
        if (max_count == 0) return 0;

        var candidates: std.ArrayList(TaskId) = .empty;
        defer candidates.deinit(self.allocator);

        for (self.tasks.items) |task| {
            if (task.state == .blocked and task.blocked_key != null and task.blocked_key.? == key) {
                try candidates.append(self.allocator, task.id);
            }
        }
        sortTaskIds(candidates.items);

        var woken: usize = 0;
        while (woken < max_count and candidates.items.len > 0) : (woken += 1) {
            const selected = selected: {
                var formatted = try self.formatTaskIds(candidates.items);
                defer formatted.deinit(self.allocator);

                const draw = try self.world.randomIntLessThan(usize, candidates.items.len);
                const selected = candidates.items[draw];
                try self.recordWake(key, formatted.items, candidates.items.len, draw, selected);
                _ = candidates.orderedRemove(draw);
                break :selected selected;
            };

            const task = self.findTask(selected).?;
            if (task.state != .blocked) return error.TaskNotBlocked;
            task.state = .ready;
            task.blocked_key = null;
            try self.ready.append(self.allocator, selected);
        }

        if (woken == 0) try self.recordWakeEmpty(key, max_count);
        return woken;
    }

    pub fn runUntilIdle(self: *Self) !void {
        var scheduler = self;
        while (scheduler.ready.items.len > 0) {
            sortTaskIds(scheduler.ready.items);

            const selected = selected: {
                var candidates = try scheduler.formatReadySet();
                defer candidates.deinit(scheduler.allocator);

                const draw = try scheduler.world.randomIntLessThan(usize, scheduler.ready.items.len);
                const selected = scheduler.ready.items[draw];
                try scheduler.recordSelect(candidates.items, draw, selected);
                _ = scheduler.ready.orderedRemove(draw);
                break :selected selected;
            };

            const task = scheduler.findTask(selected).?;
            if (task.state != .ready) return error.TaskNotReady;
            task.state = .running;
            scheduler.current = task;
            var message: SwitchMessage = .{
                .contexts = .{
                    .old = &scheduler.main_context,
                    .new = task.fiber_instance.contextPtr(),
                },
                .scheduler = scheduler,
                .task = task,
                .reason = .yielded,
            };
            const returned_message = fiber.contextSwitchMessage(SwitchMessage, &message);

            scheduler = returned_message.scheduler;
            const returned_task = returned_message.task;
            scheduler.current = null;
            switch (returned_message.reason) {
                .yielded => {
                    returned_task.state = .ready;
                    returned_task.blocked_key = null;
                    try scheduler.ready.append(scheduler.allocator, returned_task.id);
                    try scheduler.recordYield(returned_task.id);
                },
                .blocked => {
                    returned_task.state = .blocked;
                    returned_task.blocked_key = returned_message.key;
                    try scheduler.recordBlock(returned_task.id, returned_message.key);
                },
                .completed => {
                    returned_task.state = .completed;
                    returned_task.blocked_key = null;
                    try scheduler.recordComplete(returned_task.id, "ok");
                },
            }
        }

        if (scheduler.blockedCount() > 0) {
            try scheduler.recordDeadlock();
            return error.Deadlock;
        }

        try scheduler.recordIdle();
    }

    pub fn completedCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.tasks.items) |task| {
            if (task.state == .completed) count += 1;
        }
        return count;
    }

    pub fn blockedCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.tasks.items) |task| {
            if (task.state == .blocked) count += 1;
        }
        return count;
    }

    fn findTask(self: *const Self, task_id: TaskId) ?*Task {
        for (self.tasks.items) |task| {
            if (task.id == task_id) return task;
        }
        return null;
    }

    fn formatReadySet(self: *Self) std.mem.Allocator.Error!std.ArrayList(u8) {
        return self.formatTaskIds(self.ready.items);
    }

    fn formatTaskIds(self: *Self, task_ids: []const TaskId) std.mem.Allocator.Error!std.ArrayList(u8) {
        var candidates: std.ArrayList(u8) = .empty;
        errdefer candidates.deinit(self.allocator);

        for (task_ids, 0..) |task_id, index| {
            if (index > 0) try candidates.append(self.allocator, ',');
            try candidates.print(self.allocator, "{}", .{task_id});
        }

        return candidates;
    }

    fn recordSpawn(self: *Self, task_id: TaskId) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.spawn", &.{
            traceField("task", .{ .uint = task_id }),
        });
    }

    fn recordYield(self: *Self, task_id: TaskId) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.yield", &.{
            traceField("task", .{ .uint = task_id }),
        });
    }

    fn recordSelect(
        self: *Self,
        candidates: []const u8,
        draw: usize,
        selected: TaskId,
    ) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.select", &.{
            traceField("candidates", .{ .text = candidates }),
            traceField("ready_count", .{ .uint = @intCast(self.ready.items.len) }),
            traceField("draw", .{ .uint = @intCast(draw) }),
            traceField("selected", .{ .uint = selected }),
        });
    }

    fn recordBlock(
        self: *Self,
        task_id: TaskId,
        key: WaitKey,
    ) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.block", &.{
            traceField("task", .{ .uint = task_id }),
            traceField("key", .{ .uint = key }),
        });
    }

    fn recordWake(
        self: *Self,
        key: WaitKey,
        candidates: []const u8,
        candidate_count: usize,
        draw: usize,
        selected: TaskId,
    ) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.wake", &.{
            traceField("key", .{ .uint = key }),
            traceField("candidates", .{ .text = candidates }),
            traceField("blocked_count", .{ .uint = @intCast(candidate_count) }),
            traceField("draw", .{ .uint = @intCast(draw) }),
            traceField("selected", .{ .uint = selected }),
        });
    }

    fn recordWakeEmpty(
        self: *Self,
        key: WaitKey,
        max_count: usize,
    ) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.wake_empty", &.{
            traceField("key", .{ .uint = key }),
            traceField("max", .{ .uint = @intCast(max_count) }),
        });
    }

    fn recordComplete(
        self: *Self,
        task_id: TaskId,
        status: []const u8,
    ) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.complete", &.{
            traceField("task", .{ .uint = task_id }),
            traceField("status", .{ .literal = status }),
        });
    }

    fn recordIdle(self: *Self) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.idle", &.{
            traceField("tasks", .{ .uint = @intCast(self.tasks.items.len) }),
            traceField("completed", .{ .uint = @intCast(self.completedCount()) }),
            traceField("blocked", .{ .uint = @intCast(self.blockedCount()) }),
        });
    }

    fn recordDeadlock(self: *Self) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.deadlock", &.{
            traceField("tasks", .{ .uint = @intCast(self.tasks.items.len) }),
            traceField("completed", .{ .uint = @intCast(self.completedCount()) }),
            traceField("blocked", .{ .uint = @intCast(self.blockedCount()) }),
        });
    }
};

fn sortTaskIds(task_ids: []TaskId) void {
    std.mem.sort(TaskId, task_ids, {}, struct {
        fn lessThan(_: void, a: TaskId, b: TaskId) bool {
            return a < b;
        }
    }.lessThan);
}

/// Fixed-capacity deterministic event queue.
///
/// This is not the final Marionette scheduler. It is a small shared primitive
/// for examples and early designs that need stable event ordering.
/// TODO(roadmap item 11): `pop` does a linear scan, which is fine for Phase 0.
/// Replace this with a heap once the scheduler becomes hot or user-facing.
pub fn EventQueue(
    comptime Event: type,
    comptime capacity: usize,
    comptime lessThan: fn (Event, Event) bool,
) type {
    return struct {
        const Self = @This();

        items: [capacity]Event = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn peek(self: *const Self) ?Event {
            if (self.len == 0) return null;
            return self.items[self.nextIndex()];
        }

        pub fn push(self: *Self, event: Event) EventQueueError!void {
            if (self.len == self.items.len) return error.EventQueueFull;
            self.items[self.len] = event;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?Event {
            if (self.len == 0) return null;

            const index = self.nextIndex();
            const event = self.items[index];
            std.mem.copyForwards(
                Event,
                self.items[index .. self.len - 1],
                self.items[index + 1 .. self.len],
            );
            self.len -= 1;
            return event;
        }

        fn nextIndex(self: *const Self) usize {
            std.debug.assert(self.len > 0);

            var best: usize = 0;
            for (self.items[1..self.len], 1..) |event, index| {
                if (lessThan(event, self.items[best])) {
                    best = index;
                }
            }
            return best;
        }
    };
}

const TestEvent = struct {
    ready_at: u64,
    id: u64,
};

fn testEventLessThan(a: TestEvent, b: TestEvent) bool {
    return a.ready_at < b.ready_at or (a.ready_at == b.ready_at and a.id < b.id);
}

test "EventQueue: pops events in deterministic order" {
    const Queue = EventQueue(TestEvent, 4, testEventLessThan);
    var queue = Queue.init();

    try queue.push(.{ .ready_at = 20, .id = 2 });
    try queue.push(.{ .ready_at = 10, .id = 3 });
    try queue.push(.{ .ready_at = 10, .id = 1 });

    try std.testing.expectEqual(@as(usize, 3), queue.count());
    try std.testing.expectEqual(TestEvent{ .ready_at = 10, .id = 1 }, queue.pop().?);
    try std.testing.expectEqual(TestEvent{ .ready_at = 10, .id = 3 }, queue.pop().?);
    try std.testing.expectEqual(TestEvent{ .ready_at = 20, .id = 2 }, queue.pop().?);
    try std.testing.expectEqual(@as(?TestEvent, null), queue.pop());
}

test "EventQueue: peeks without popping" {
    const Queue = EventQueue(TestEvent, 4, testEventLessThan);
    var queue = Queue.init();

    try queue.push(.{ .ready_at = 20, .id = 2 });
    try queue.push(.{ .ready_at = 10, .id = 1 });

    try std.testing.expectEqual(TestEvent{ .ready_at = 10, .id = 1 }, queue.peek().?);
    try std.testing.expectEqual(@as(usize, 2), queue.count());
    try std.testing.expectEqual(TestEvent{ .ready_at = 10, .id = 1 }, queue.pop().?);
}

test "EventQueue: reports capacity overflow" {
    const Queue = EventQueue(TestEvent, 1, testEventLessThan);
    var queue = Queue.init();

    try queue.push(.{ .ready_at = 1, .id = 1 });
    try std.testing.expectError(
        EventQueueError.EventQueueFull,
        queue.push(.{ .ready_at = 2, .id = 2 }),
    );
}

const ToyTask = struct {
    remaining: u8,

    fn run(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *ToyTask = @ptrCast(@alignCast(arg));

        while (self.remaining > 0) {
            self.remaining -= 1;
            scheduler.yieldCurrent();
        }
    }
};

fn runToySchedulerTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    const runtime_allocator = std.heap.page_allocator;

    const world = try runtime_allocator.create(World);
    errdefer runtime_allocator.destroy(world);
    world.* = try World.init(runtime_allocator, .{ .seed = seed, .tick_ns = 10 });
    defer {
        world.deinit();
        runtime_allocator.destroy(world);
    }

    const scheduler = try runtime_allocator.create(TaskScheduler);
    errdefer runtime_allocator.destroy(scheduler);
    scheduler.* = TaskScheduler.init(runtime_allocator, world);
    defer {
        scheduler.deinit();
        runtime_allocator.destroy(scheduler);
    }

    const tasks = try runtime_allocator.alloc(ToyTask, 3);
    defer runtime_allocator.free(tasks);
    tasks[0] = .{ .remaining = 3 };
    tasks[1] = .{ .remaining = 2 };
    tasks[2] = .{ .remaining = 4 };

    for (tasks) |*task| {
        _ = try scheduler.spawn(.{
            .entry = ToyTask.run,
            .arg = task,
        });
    }

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(usize, tasks.len), scheduler.completedCount());
    return try allocator.dupe(u8, world.traceBytes());
}

test "TaskScheduler: same seed produces byte-identical schedule trace" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runToySchedulerTrace(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(first);
    const second = try runToySchedulerTrace(std.testing.allocator, 0xC0FFEE);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.select candidates=0,1,2") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.yield task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.complete task=") != null);
}

const WakeSetScenario = struct {
    key: WaitKey = 0xABCD,
    waiting: u8 = 0,
    resumed: u8 = 0,
    waker_yields: u8 = 0,

    fn waiter(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        self.waiting += 1;
        scheduler.blockCurrent(self.key);
        self.resumed += 1;
    }

    fn waker(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        while (self.waiting < 2) {
            self.waker_yields += 1;
            if (self.waker_yields > 32) @panic("waiters did not block");
            scheduler.yieldCurrent();
        }

        const woken = scheduler.wake(self.key, 2) catch @panic("wake failed");
        if (woken != 2) @panic("unexpected wake count");
    }
};

fn runWakeSetSchedulerTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    const runtime_allocator = std.heap.page_allocator;

    const world = try runtime_allocator.create(World);
    errdefer runtime_allocator.destroy(world);
    world.* = try World.init(runtime_allocator, .{ .seed = seed, .tick_ns = 10 });
    defer {
        world.deinit();
        runtime_allocator.destroy(world);
    }

    const scheduler = try runtime_allocator.create(TaskScheduler);
    errdefer runtime_allocator.destroy(scheduler);
    scheduler.* = TaskScheduler.init(runtime_allocator, world);
    defer {
        scheduler.deinit();
        runtime_allocator.destroy(scheduler);
    }

    const scenario = try runtime_allocator.create(WakeSetScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{};

    _ = try scheduler.spawn(.{
        .entry = WakeSetScenario.waiter,
        .arg = scenario,
    });
    _ = try scheduler.spawn(.{
        .entry = WakeSetScenario.waiter,
        .arg = scenario,
    });
    _ = try scheduler.spawn(.{
        .entry = WakeSetScenario.waker,
        .arg = scenario,
    });

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(usize, 3), scheduler.completedCount());
    try std.testing.expectEqual(@as(usize, 0), scheduler.blockedCount());
    try std.testing.expectEqual(@as(u8, 2), scenario.resumed);

    return try allocator.dupe(u8, world.traceBytes());
}

test "TaskScheduler: wait-set wake order replays deterministically" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runWakeSetSchedulerTrace(std.testing.allocator, 0xB10C);
    defer std.testing.allocator.free(first);
    const second = try runWakeSetSchedulerTrace(std.testing.allocator, 0xB10C);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.block task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.wake key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.idle tasks=3 completed=3 blocked=0") != null);
}

test "TaskScheduler: blocked tasks without a wake report deadlock" {
    if (!fiber.supported) return error.SkipZigTest;

    const runtime_allocator = std.heap.page_allocator;

    const world = try runtime_allocator.create(World);
    errdefer runtime_allocator.destroy(world);
    world.* = try World.init(runtime_allocator, .{ .seed = 0xDEAD10CC, .tick_ns = 10 });
    defer {
        world.deinit();
        runtime_allocator.destroy(world);
    }

    const scheduler = try runtime_allocator.create(TaskScheduler);
    errdefer runtime_allocator.destroy(scheduler);
    scheduler.* = TaskScheduler.init(runtime_allocator, world);
    defer {
        scheduler.deinit();
        runtime_allocator.destroy(scheduler);
    }

    var scenario: WakeSetScenario = .{};
    _ = try scheduler.spawn(.{
        .entry = WakeSetScenario.waiter,
        .arg = &scenario,
    });

    try std.testing.expectError(error.Deadlock, scheduler.runUntilIdle());
    try std.testing.expectEqual(@as(usize, 1), scheduler.blockedCount());
    try std.testing.expect(std.mem.indexOf(u8, world.traceBytes(), "scheduler.deadlock") != null);

    try std.testing.expectEqual(@as(usize, 1), try scheduler.wake(scenario.key, 1));
    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(usize, 1), scheduler.completedCount());
    try std.testing.expectEqual(@as(usize, 0), scheduler.blockedCount());
}
