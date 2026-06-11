//! Deterministic scheduler building blocks.

const std = @import("std");

const disk_module = @import("disk/root.zig");
const fiber = @import("fiber.zig");
const io_module = @import("io/root.zig");
const network_module = @import("network/root.zig");
const world_module = @import("world.zig");

const Io = std.Io;
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

/// Reason a blocked task resumed.
pub const WaitResult = enum {
    woken,
    timed_out,
};

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
    opaque_entries: std.ArrayList(*OpaqueEntry) = .empty,
    current: ?*Task = null,
    /// Active main-context wait, if the harness/scenario itself is blocked
    /// inside a wait-set call and driving the scheduler. See `driveMainUntil`.
    main_wait: ?MainWait = null,
    next_task_id: TaskId = 0,

    const MainWait = struct {
        key: WaitKey,
        woken: bool = false,
    };

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
        deadline_ns: ?u64 = null,
        wait_result: WaitResult = .woken,
    };

    const Task = struct {
        id: TaskId,
        scheduler: *Self,
        entry: Entry,
        arg: *anyopaque,
        /// Null once the task has completed: the fiber (and its stack) is
        /// reclaimed eagerly so long-lived worlds spawning many tasks do not
        /// accumulate dead stacks until teardown.
        fiber_instance: ?*fiber.Fiber,
        state: TaskState = .ready,
        blocked_key: ?WaitKey = null,
        blocked_deadline_ns: ?u64 = null,
        wait_result: WaitResult = .woken,

        fn run(arg: *anyopaque) void {
            const task: *Task = @ptrCast(@alignCast(arg));
            task.entry(task.scheduler, task.arg);
            task.scheduler.completeCurrent(task);
            unreachable;
        }

        /// Move the task out of the blocked state into `state`, clearing the
        /// block bookkeeping. `blocked_key`/`blocked_deadline_ns` are only
        /// meaningful while blocked, so every non-blocked transition must
        /// clear them; centralizing that keeps the invariant in one place.
        fn clearBlock(self: *Task, state: TaskState, result: WaitResult) void {
            self.state = state;
            self.blocked_key = null;
            self.blocked_deadline_ns = null;
            self.wait_result = result;
        }

        /// Park the task on `key`, optionally with a timeout deadline.
        fn block(self: *Task, key: WaitKey, deadline_ns: ?u64) void {
            self.state = .blocked;
            self.blocked_key = key;
            self.blocked_deadline_ns = deadline_ns;
            self.wait_result = .woken;
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
            if (task.fiber_instance) |fiber_instance| fiber_instance.destroy();
            self.allocator.destroy(task);
        }
        self.tasks.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        for (self.opaque_entries.items) |adapter| self.allocator.destroy(adapter);
        self.opaque_entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Spawn a task from a bare function pointer and context pointer.
    ///
    /// This is the type-erased entry used by the `std.Io` backend; the
    /// scheduler parameter of `Entry` is dropped because opaque callers
    /// hold capabilities through their own context instead.
    pub fn spawnOpaque(
        self: *Self,
        entry: *const fn (*anyopaque) void,
        arg: *anyopaque,
    ) TaskSchedulerError!TaskId {
        const adapter = try self.allocator.create(OpaqueEntry);
        errdefer self.allocator.destroy(adapter);
        adapter.* = .{ .entry = entry, .arg = arg };
        try self.opaque_entries.append(self.allocator, adapter);
        errdefer _ = self.opaque_entries.pop();

        return try self.spawn(.{
            .entry = OpaqueEntry.run,
            .arg = adapter,
        });
    }

    const OpaqueEntry = struct {
        entry: *const fn (*anyopaque) void,
        arg: *anyopaque,

        fn run(scheduler: *Self, raw: *anyopaque) void {
            const adapter: *OpaqueEntry = @ptrCast(@alignCast(raw));
            const entry = adapter.entry;
            const arg = adapter.arg;
            // The adapter only exists to ferry the entry across `spawn`;
            // release it as soon as the task is running so only never-run
            // adapters remain for `deinit` to sweep.
            for (scheduler.opaque_entries.items, 0..) |candidate, index| {
                if (candidate == adapter) {
                    _ = scheduler.opaque_entries.swapRemove(index);
                    break;
                }
            }
            scheduler.allocator.destroy(adapter);
            entry(arg);
        }
    };

    pub fn spawn(self: *Self, options: SpawnOptions) TaskSchedulerError!TaskId {
        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);

        const task_id = self.next_task_id;
        task.* = .{
            .id = task_id,
            .scheduler = self,
            .entry = options.entry,
            .arg = options.arg,
            .fiber_instance = null,
        };

        const fiber_instance = try fiber.Fiber.create(self.allocator, .{
            .stack_size = options.stack_size,
            .finish_context = &self.main_context,
            .entry = Task.run,
            .arg = task,
        });
        errdefer fiber_instance.destroy();
        task.fiber_instance = fiber_instance;

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
                .old = task.fiber_instance.?.contextPtr(),
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
        _ = self.blockCurrentUntil(key, null);
    }

    // Same optimizer boundary rule as `yieldCurrent`.
    pub noinline fn blockCurrentUntil(self: *Self, key: WaitKey, deadline_ns: ?u64) WaitResult {
        const task = self.current orelse return self.driveMainUntil(key, deadline_ns);
        if (task.state != .running) @panic("block from a non-running task");
        const effective_deadline_ns = if (deadline_ns) |deadline| b: {
            const now = self.world.now();
            if (deadline <= now) return .timed_out;
            const duration = self.world.clock().ceilDuration(deadline - now);
            break :b std.math.add(u64, now, duration) catch
                @panic("scheduled deadline exceeds clock range");
        } else null;

        var message: SwitchMessage = .{
            .contexts = .{
                .old = task.fiber_instance.?.contextPtr(),
                .new = &self.main_context,
            },
            .scheduler = self,
            .task = task,
            .reason = .blocked,
            .key = key,
            .deadline_ns = effective_deadline_ns,
        };
        const resume_message = fiber.contextSwitchMessage(SwitchMessage, &message);
        return resume_message.wait_result;
    }

    /// Service a wait-set block issued from the main (non-task) context by
    /// driving the scheduler: ready tasks run, time advances to the next
    /// deadline, and the wait ends when a `wake` hits `key` or the caller's
    /// own deadline is reached. The main context blocking forever with no
    /// runnable work and no pending deadline is a deterministic deadlock and
    /// fails loudly.
    fn driveMainUntil(self: *Self, key: WaitKey, deadline_ns: ?u64) WaitResult {
        std.debug.assert(self.main_wait == null); // main-context waits cannot nest

        const effective_deadline_ns = if (deadline_ns) |deadline| b: {
            const now = self.world.now();
            if (deadline <= now) return .timed_out;
            const duration = self.world.clock().ceilDuration(deadline - now);
            break :b std.math.add(u64, now, duration) catch
                @panic("scheduled deadline exceeds clock range");
        } else null;

        self.main_wait = .{ .key = key };
        defer self.main_wait = null;

        while (true) {
            if (self.main_wait.?.woken) return .woken;

            switch (self.stepOnce() catch @panic("scheduler failed during main-context wait")) {
                .ran => continue,
                .idle => {},
            }
            if (self.main_wait.?.woken) return .woken;

            // Nothing is runnable: advance time to the nearest deadline,
            // capped by the caller's own.
            const task_deadline = self.nextDeadline();
            const target = if (task_deadline) |task_ns|
                if (effective_deadline_ns) |main_ns| @min(task_ns, main_ns) else task_ns
            else
                effective_deadline_ns orelse
                    @panic("deterministic deadlock: main-context wait can never be satisfied");

            const now = self.world.now();
            if (target > now) {
                self.world.runFor(target - now) catch @panic("failed to advance to main wait deadline");
            }
            self.wakeDueTasks() catch @panic("failed to wake due tasks during main-context wait");

            if (effective_deadline_ns) |main_ns| {
                if (self.world.now() >= main_ns) return .timed_out;
            }
        }
    }

    /// Move every blocked task whose deadline has passed into the ready set.
    fn wakeDueTasks(self: *Self) TaskSchedulerError!void {
        var due: std.ArrayList(TaskId) = .empty;
        defer due.deinit(self.allocator);

        const now = self.world.now();
        for (self.tasks.items) |task| {
            if (task.state == .blocked and task.blocked_deadline_ns != null and task.blocked_deadline_ns.? <= now) {
                try due.append(self.allocator, task.id);
            }
        }
        sortTaskIds(due.items);

        for (due.items) |task_id| {
            const task = self.findTask(task_id).?;
            if (task.state != .blocked) return error.TaskNotBlocked;
            const task_deadline = task.blocked_deadline_ns.?;
            task.clearBlock(.ready, .timed_out);
            try self.ready.append(self.allocator, task.id);
            try self.recordTimeout(task.id, task_deadline);
        }
    }

    // Same optimizer boundary rule as `yieldCurrent`.
    noinline fn completeCurrent(self: *Self, task: *Task) void {
        var message: SwitchMessage = .{
            .contexts = .{
                .old = task.fiber_instance.?.contextPtr(),
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
        var remaining = max_count;

        // A main-context waiter is woken before task waiters; it is the
        // caller that everything else is ultimately making progress for, and
        // the fixed priority keeps wake order deterministic.
        var main_woken: usize = 0;
        if (self.main_wait) |*waiting| {
            if (!waiting.woken and waiting.key == key) {
                waiting.woken = true;
                try self.recordWakeMain(key);
                main_woken = 1;
                remaining -= 1;
                if (remaining == 0) return main_woken;
            }
        }

        var candidates: std.ArrayList(TaskId) = .empty;
        defer candidates.deinit(self.allocator);

        for (self.tasks.items) |task| {
            if (task.state == .blocked and task.blocked_key != null and task.blocked_key.? == key) {
                try candidates.append(self.allocator, task.id);
            }
        }
        sortTaskIds(candidates.items);

        var woken: usize = 0;
        while (woken < remaining and candidates.items.len > 0) : (woken += 1) {
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
            task.clearBlock(.ready, .woken);
            try self.ready.append(self.allocator, selected);
        }

        if (woken == 0 and main_woken == 0) try self.recordWakeEmpty(key, max_count);
        return woken + main_woken;
    }

    const StepOutcome = enum {
        /// One task was selected, run to its next suspension, and accounted.
        ran,
        /// No task is ready (timers may still be pending).
        idle,
    };

    // This function switches between the scheduler stack and task stacks.
    // Keep it opaque for the same reason as task-side yield/block boundaries:
    // optimized callers must treat the switch as a control-flow discontinuity.
    noinline fn stepOnce(self: *Self) TaskSchedulerError!StepOutcome {
        var scheduler = self;
        if (scheduler.ready.items.len == 0) return .idle;

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
                .new = task.fiber_instance.?.contextPtr(),
            },
            .scheduler = scheduler,
            .task = task,
            .reason = .yielded,
            .wait_result = task.wait_result,
        };
        const returned_message = fiber.contextSwitchMessage(SwitchMessage, &message);

        scheduler = returned_message.scheduler;
        const returned_task = returned_message.task;
        scheduler.current = null;
        if (!returned_task.fiber_instance.?.canaryIntact()) {
            @panic("fiber stack overflow: task smashed its stack canary");
        }
        switch (returned_message.reason) {
            .yielded => {
                returned_task.clearBlock(.ready, .woken);
                try scheduler.ready.append(scheduler.allocator, returned_task.id);
                try scheduler.recordYield(returned_task.id);
            },
            .blocked => {
                returned_task.block(returned_message.key, returned_message.deadline_ns);
                try scheduler.recordBlock(returned_task.id, returned_message.key, returned_message.deadline_ns);
            },
            .completed => {
                returned_task.clearBlock(.completed, .woken);
                try scheduler.recordComplete(returned_task.id, "ok");
                // The fiber finished and we are back on the scheduler stack:
                // its stack can never run again, so reclaim it now instead of
                // holding every dead stack until world teardown.
                returned_task.fiber_instance.?.destroy();
                returned_task.fiber_instance = null;
            },
        }
        return .ran;
    }

    pub fn runUntilIdle(self: *Self) !void {
        while (true) {
            switch (try self.stepOnce()) {
                .ran => {},
                .idle => {
                    if (try self.advanceToNextTimer()) continue;
                    break;
                },
            }
        }

        if (self.blockedCount() > 0) {
            try self.recordCensus("scheduler.deadlock");
            return error.Deadlock;
        }

        try self.recordCensus("scheduler.idle");
    }

    /// Drive the scheduler from the main (non-task) context until `done.*`.
    ///
    /// Used by `Io.await` when the awaiting caller is the scenario itself
    /// rather than a scheduled task. Panics on deterministic deadlock: if no
    /// task is runnable, no timer is pending, and the flag is still unset,
    /// the awaited work can never complete.
    pub fn runUntilDone(self: *Self, done: *const bool) TaskSchedulerError!void {
        while (!done.*) {
            switch (try self.stepOnce()) {
                .ran => {},
                .idle => {
                    if (try self.advanceToNextTimer()) continue;
                    try self.recordCensus("scheduler.deadlock");
                    return error.Deadlock;
                },
            }
        }
    }

    fn countState(self: *const Self, state: TaskState) usize {
        var count: usize = 0;
        for (self.tasks.items) |task| {
            if (task.state == state) count += 1;
        }
        return count;
    }

    pub fn completedCount(self: *const Self) usize {
        return self.countState(.completed);
    }

    pub fn blockedCount(self: *const Self) usize {
        return self.countState(.blocked);
    }

    /// Test-harness helper: yield until at least `count` tasks are blocked.
    ///
    /// Cooperative code cannot be signaled by a peer *after* it suspends,
    /// so "wait until the peer is parked" is necessarily a poll. The bound
    /// exists to fail loudly when the awaited suspension can never happen;
    /// at this size, a fair random schedule starving the poller is
    /// negligible even across large seed sweeps.
    pub fn yieldUntilBlockedCount(self: *Self, count: usize) void {
        var yields: u16 = 0;
        while (self.blockedCount() < count) {
            yields += 1;
            if (yields > max_poll_yields) @panic("awaited tasks never blocked");
            self.yieldCurrent();
        }
    }

    fn advanceToNextTimer(self: *Self) TaskSchedulerError!bool {
        const deadline = self.nextDeadline() orelse return false;
        const now = self.world.now();
        if (deadline > now) {
            try self.world.runFor(self.world.clock().ceilDuration(deadline - now));
        }
        const wake_at = self.world.now();

        var due: std.ArrayList(TaskId) = .empty;
        defer due.deinit(self.allocator);

        for (self.tasks.items) |task| {
            if (task.state == .blocked and task.blocked_deadline_ns != null and task.blocked_deadline_ns.? <= wake_at) {
                try due.append(self.allocator, task.id);
            }
        }
        sortTaskIds(due.items);

        for (due.items) |task_id| {
            const task = self.findTask(task_id).?;
            if (task.state != .blocked) return error.TaskNotBlocked;
            const task_deadline = task.blocked_deadline_ns.?;
            task.clearBlock(.ready, .timed_out);
            try self.ready.append(self.allocator, task.id);
            try self.recordTimeout(task.id, task_deadline);
        }

        return due.items.len > 0;
    }

    fn nextDeadline(self: *const Self) ?u64 {
        var best: ?u64 = null;
        for (self.tasks.items) |task| {
            if (task.state != .blocked) continue;
            const deadline = task.blocked_deadline_ns orelse continue;
            if (best == null or deadline < best.?) best = deadline;
        }
        return best;
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
        deadline_ns: ?u64,
    ) (std.mem.Allocator.Error || world_module.TraceError)!void {
        const fields = [_]world_module.TraceField{
            traceField("task", .{ .uint = task_id }),
            traceField("key", .{ .uint = key }),
            traceField("deadline_ns", .{ .uint = deadline_ns orelse 0 }),
        };
        const count: usize = if (deadline_ns != null) 3 else 2;
        try self.world.recordFields("scheduler.block", fields[0..count]);
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

    fn recordWakeMain(self: *Self, key: WaitKey) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.wake_main", &.{
            traceField("key", .{ .uint = key }),
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

    fn recordTimeout(
        self: *Self,
        task_id: TaskId,
        deadline_ns: u64,
    ) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.timeout", &.{
            traceField("task", .{ .uint = task_id }),
            traceField("deadline_ns", .{ .uint = deadline_ns }),
        });
    }

    fn recordCensus(self: *Self, event: []const u8) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields(event, &.{
            traceField("tasks", .{ .uint = @intCast(self.tasks.items.len) }),
            traceField("completed", .{ .uint = @intCast(self.completedCount()) }),
            traceField("blocked", .{ .uint = @intCast(self.blockedCount()) }),
        });
    }
};

/// Yield bound for harness polling loops. See `yieldUntilBlockedCount`.
pub const max_poll_yields = 256;

fn sortTaskIds(task_ids: []TaskId) void {
    std.mem.sort(TaskId, task_ids, {}, std.sort.asc(TaskId));
}

pub fn futexWaitSet(self: *TaskScheduler) io_module.FutexWaitSet {
    return .{
        .ptr = self,
        .vtable = &futex_wait_set_vtable,
    };
}

fn waitSetBlock(ptr: *anyopaque, key: usize) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    scheduler.blockCurrent(key);
}

fn waitSetBlockUntil(ptr: *anyopaque, key: usize, deadline_ns: ?u64) io_module.FutexWaitResult {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return switch (scheduler.blockCurrentUntil(key, deadline_ns)) {
        .woken => .woken,
        .timed_out => .timed_out,
    };
}

fn waitSetWake(ptr: *anyopaque, key: usize, max_count: usize) usize {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.wake(key, max_count) catch @panic("scheduler wake failed");
}

const futex_wait_set_vtable: io_module.FutexWaitSet.VTable = .{
    .block = waitSetBlock,
    .block_until = waitSetBlockUntil,
    .wake = waitSetWake,
};

/// Tear down a world-owned scheduler registered via `World.registerTeardown`.
pub fn deinitTaskSchedulerOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    scheduler.deinit();
    allocator.destroy(scheduler);
}

/// Build the `std.Io` task runtime view over a scheduler.
pub fn taskRuntime(self: *TaskScheduler) io_module.TaskRuntime {
    return .{
        .ptr = self,
        .vtable = &task_runtime_vtable,
    };
}

fn taskRuntimeSpawn(
    ptr: *anyopaque,
    entry: *const fn (*anyopaque) void,
    arg: *anyopaque,
) io_module.TaskRuntime.SpawnError!u64 {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.spawnOpaque(entry, arg) catch return error.ConcurrencyUnavailable;
}

fn taskRuntimeInTask(ptr: *anyopaque) bool {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.current != null;
}

fn taskRuntimeBlock(ptr: *anyopaque, key: usize) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    scheduler.blockCurrent(key);
}

fn taskRuntimeWake(ptr: *anyopaque, key: usize, max_count: usize) usize {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.wake(key, max_count) catch @panic("scheduler wake failed");
}

fn taskRuntimeRunUntilDone(ptr: *anyopaque, done: *const bool) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    scheduler.runUntilDone(done) catch |err| switch (err) {
        error.Deadlock => @panic("await deadlock: awaited async task can never complete"),
        else => @panic("scheduler failed while driving awaited task"),
    };
}

const task_runtime_vtable: io_module.TaskRuntime.VTable = .{
    .spawn = taskRuntimeSpawn,
    .in_task = taskRuntimeInTask,
    .block = taskRuntimeBlock,
    .wake = taskRuntimeWake,
    .run_until_done = taskRuntimeRunUntilDone,
};

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

const UnwindScenario = struct {
    allocations: u8 = 0,

    fn run(_: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        // The testing allocator captures a stack trace on every alloc and
        // free; capturing from a fiber stack requires the sentinel root
        // frame at fiber entry to terminate unwinding. This crashed inside
        // the unwinder before that frame existed.
        const buffer = std.testing.allocator.alloc(u8, 64) catch @panic("alloc failed");
        std.testing.allocator.free(buffer);
        self.allocations += 1;
    }
};

test "TaskScheduler: fiber stacks are unwind-safe for stack-tracing allocators" {
    if (!fiber.supported) return error.SkipZigTest;

    const runtime_allocator = std.heap.page_allocator;

    const world = try runtime_allocator.create(World);
    errdefer runtime_allocator.destroy(world);
    world.* = try World.init(runtime_allocator, .{ .seed = 0x1B4D, .tick_ns = 10 });
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

    var scenario: UnwindScenario = .{};
    _ = try scheduler.spawn(.{ .entry = UnwindScenario.run, .arg = &scenario });
    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(u8, 1), scenario.allocations);
}

test "TaskScheduler: completed tasks release their fibers eagerly" {
    if (!fiber.supported) return error.SkipZigTest;

    const runtime_allocator = std.heap.page_allocator;

    const world = try runtime_allocator.create(World);
    errdefer runtime_allocator.destroy(world);
    world.* = try World.init(runtime_allocator, .{ .seed = 0xF1BE, .tick_ns = 10 });
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

    var tasks: [3]ToyTask = .{
        .{ .remaining = 1 },
        .{ .remaining = 2 },
        .{ .remaining = 1 },
    };
    for (&tasks) |*task| {
        _ = try scheduler.spawn(.{ .entry = ToyTask.run, .arg = task });
    }
    try scheduler.runUntilIdle();

    try std.testing.expectEqual(@as(usize, 3), scheduler.completedCount());
    for (scheduler.tasks.items) |task| {
        try std.testing.expectEqual(@as(?*fiber.Fiber, null), task.fiber_instance);
    }
    try std.testing.expectEqual(@as(usize, 0), scheduler.opaque_entries.items.len);
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

    fn waiter(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        self.waiting += 1;
        scheduler.blockCurrent(self.key);
        self.resumed += 1;
    }

    fn waker(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        scheduler.yieldUntilBlockedCount(2);

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

const TimeoutScenario = struct {
    key: WaitKey = 0xC10C,
    deadline_ns: u64 = 30,
    waiting: u8 = 0,
    timed_out: u8 = 0,
    woken: u8 = 0,

    fn timedWaiter(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        self.waiting += 1;
        switch (scheduler.blockCurrentUntil(self.key, self.deadline_ns)) {
            .woken => self.woken += 1,
            .timed_out => self.timed_out += 1,
        }
    }

    fn waker(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        scheduler.yieldUntilBlockedCount(1);

        const woken = scheduler.wake(self.key, 1) catch @panic("wake failed");
        if (woken != 1) @panic("unexpected wake count");
    }
};

fn runTimeoutTrace(allocator: std.mem.Allocator, seed: u64, spawn_waker: bool, waiter_count: usize) ![]u8 {
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

    const scenario = try runtime_allocator.create(TimeoutScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{};

    for (0..waiter_count) |_| {
        _ = try scheduler.spawn(.{
            .entry = TimeoutScenario.timedWaiter,
            .arg = scenario,
        });
    }
    if (spawn_waker) {
        _ = try scheduler.spawn(.{
            .entry = TimeoutScenario.waker,
            .arg = scenario,
        });
    }

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(waiter_count + @intFromBool(spawn_waker), scheduler.completedCount());
    try std.testing.expectEqual(@as(usize, 0), scheduler.blockedCount());

    if (spawn_waker) {
        try std.testing.expectEqual(@as(u64, 0), world.now());
        try std.testing.expectEqual(@as(u8, 1), scenario.woken);
        try std.testing.expectEqual(@as(u8, 0), scenario.timed_out);
    } else {
        try std.testing.expectEqual(scenario.deadline_ns, world.now());
        try std.testing.expectEqual(@as(u8, @intCast(waiter_count)), scenario.timed_out);
        try std.testing.expectEqual(@as(u8, 0), scenario.woken);
    }

    return try allocator.dupe(u8, world.traceBytes());
}

test "TaskScheduler: timed wait advances to deadline and returns timeout" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runTimeoutTrace(std.testing.allocator, 0xD1A1, false, 1);
    defer std.testing.allocator.free(first);
    const second = try runTimeoutTrace(std.testing.allocator, 0xD1A1, false, 1);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "world.run_for start_ns=0 duration_ns=30 end_ns=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.timeout task=0 deadline_ns=30") != null);
}

test "TaskScheduler: wake before deadline cancels timed wait" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runTimeoutTrace(std.testing.allocator, 0xD1A2, true, 1);
    defer std.testing.allocator.free(first);
    const second = try runTimeoutTrace(std.testing.allocator, 0xD1A2, true, 1);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.wake key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.timeout") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "world.run_for") == null);
}

test "TaskScheduler: same-deadline timeouts wake in task id order" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runTimeoutTrace(std.testing.allocator, 0xD1A3, false, 2);
    defer std.testing.allocator.free(first);
    const second = try runTimeoutTrace(std.testing.allocator, 0xD1A3, false, 2);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    const first_timeout = std.mem.indexOf(u8, first, "scheduler.timeout task=0 deadline_ns=30").?;
    const second_timeout = std.mem.indexOf(u8, first, "scheduler.timeout task=1 deadline_ns=30").?;
    try std.testing.expect(first_timeout < second_timeout);
}

const TimedFutexScenario = struct {
    io: Io,
    value: u32 = 0,
    returned: bool = false,

    fn waiter(_: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        self.io.futexWaitTimeout(
            u32,
            &self.value,
            0,
            .{ .duration = .{
                .raw = .fromNanoseconds(15),
                .clock = .awake,
            } },
        ) catch unreachable;
        self.returned = true;
    }
};

fn runTimedFutexTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
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

    var backend = io_module.Backend.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096);
    defer backend.deinit();
    backend.attachFutexWaitSet(futexWaitSet(scheduler));

    const scenario = try runtime_allocator.create(TimedFutexScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{
        .io = backend.io(),
    };

    _ = try scheduler.spawn(.{
        .entry = TimedFutexScenario.waiter,
        .arg = scenario,
    });

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(u64, 20), world.now());
    try std.testing.expect(scenario.returned);

    return try allocator.dupe(u8, world.traceBytes());
}

test "TaskScheduler: std.Io timed futex wait rounds to clock resolution" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runTimedFutexTrace(std.testing.allocator, 0xF17E);
    defer std.testing.allocator.free(first);
    const second = try runTimedFutexTrace(std.testing.allocator, 0xF17E);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "world.run_for start_ns=0 duration_ns=20 end_ns=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.timeout task=0 deadline_ns=20") != null);
}

const SleepOrderingScenario = struct {
    io: Io,
    timer_value: u32 = 0,
    timer_wake_at: ?u64 = null,
    sleep_wake_at: ?u64 = null,

    fn sleeper(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        Io.sleep(self.io, .fromNanoseconds(100), .awake) catch unreachable;
        self.sleep_wake_at = scheduler.world.now();
    }

    fn earlierTimer(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        self.io.futexWaitTimeout(
            u32,
            &self.timer_value,
            0,
            .{ .duration = .{
                .raw = .fromNanoseconds(50),
                .clock = .awake,
            } },
        ) catch unreachable;
        self.timer_wake_at = scheduler.world.now();
    }
};

fn runSleepOrderingTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
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

    var backend = io_module.Backend.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096);
    defer backend.deinit();
    backend.attachFutexWaitSet(futexWaitSet(scheduler));

    const scenario = try runtime_allocator.create(SleepOrderingScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{ .io = backend.io() };

    _ = try scheduler.spawn(.{
        .entry = SleepOrderingScenario.sleeper,
        .arg = scenario,
    });
    _ = try scheduler.spawn(.{
        .entry = SleepOrderingScenario.earlierTimer,
        .arg = scenario,
    });

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(?u64, 50), scenario.timer_wake_at);
    try std.testing.expectEqual(@as(?u64, 100), scenario.sleep_wake_at);

    return try allocator.dupe(u8, world.traceBytes());
}

test "TaskScheduler: std.Io sleep parks behind an earlier deadline" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runSleepOrderingTrace(std.testing.allocator, 0x51EE);
    defer std.testing.allocator.free(first);
    const second = try runSleepOrderingTrace(std.testing.allocator, 0x51EE);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    const earlier_timeout = std.mem.indexOf(u8, first, "scheduler.timeout task=1 deadline_ns=50").?;
    const sleep_timeout = std.mem.indexOf(u8, first, "scheduler.timeout task=0 deadline_ns=100").?;
    try std.testing.expect(earlier_timeout < sleep_timeout);
}

const MutexConditionScenario = struct {
    io: Io,
    scheduler: *TaskScheduler,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    condition_met: bool = false,
    waiter_observed: bool = false,

    fn waiter(_: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (!self.condition_met) {
            self.condition.waitUncancelable(self.io, &self.mutex);
        }
        self.waiter_observed = true;
    }

    fn signaler(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        // Wait for the waiter to park on the condition (releasing the mutex).
        scheduler.yieldUntilBlockedCount(1);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.condition_met = true;
        self.condition.signal(self.io);
    }
};

fn runMutexConditionTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
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

    var backend = io_module.Backend.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096);
    defer backend.deinit();
    backend.attachFutexWaitSet(futexWaitSet(scheduler));

    const scenario = try runtime_allocator.create(MutexConditionScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{
        .io = backend.io(),
        .scheduler = scheduler,
    };

    _ = try scheduler.spawn(.{
        .entry = MutexConditionScenario.waiter,
        .arg = scenario,
    });
    _ = try scheduler.spawn(.{
        .entry = MutexConditionScenario.signaler,
        .arg = scenario,
    });

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(usize, 2), scheduler.completedCount());
    try std.testing.expectEqual(@as(usize, 0), scheduler.blockedCount());
    try std.testing.expect(scenario.waiter_observed);

    return try allocator.dupe(u8, world.traceBytes());
}

test "TaskScheduler: std.Io Mutex and Condition replay through sim futexes" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runMutexConditionTrace(std.testing.allocator, 0xF00D);
    defer std.testing.allocator.free(first);
    const second = try runMutexConditionTrace(std.testing.allocator, 0xF00D);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.block task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.wake key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.idle tasks=2 completed=2 blocked=0") != null);
}

const NetScenarioKind = enum {
    accept,
    exchange,
    latency,
    latency_close,
    drop,
};

const NetScenario = struct {
    io: Io,
    world: *World,
    address: Io.net.IpAddress,
    server: Io.net.Server,
    accepted: bool = false,
    reader_started: bool = false,
    close_client: bool = true,
    client_yields: u16 = 0,
    read_bytes: [4]u8 = undefined,
    read_len: usize = 0,
    read_error: ?Io.net.Stream.Reader.Error = null,

    fn acceptor(_: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        const stream = self.server.accept(self.io) catch @panic("accept failed");
        defer stream.close(self.io);
        self.accepted = true;
        self.world.record("io.net.accepted", .{}) catch @panic("record failed");
    }

    fn connector(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        scheduler.yieldUntilBlockedCount(1);

        const stream = self.address.connect(self.io, .{ .mode = .stream, .protocol = .tcp }) catch @panic("connect failed");
        defer stream.close(self.io);
        self.world.record("io.net.connected", .{}) catch @panic("record failed");
    }

    fn exchangeServer(_: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        const stream = self.server.accept(self.io) catch @panic("accept failed");
        defer stream.close(self.io);
        self.accepted = true;
        self.world.record("io.net.accepted", .{}) catch @panic("record failed");

        self.reader_started = true;
        var buffers: [1][]u8 = .{&self.read_bytes};
        self.read_len = self.io.vtable.netRead(self.io.userdata, stream.socket.handle, &buffers) catch |err| {
            self.read_error = err;
            self.world.record("io.net.read_error error={s}", .{@errorName(err)}) catch @panic("record failed");
            return;
        };
        self.world.record("io.net.read len={}", .{self.read_len}) catch @panic("record failed");
    }

    fn exchangeClient(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        scheduler.yieldUntilBlockedCount(1);

        const stream = self.address.connect(self.io, .{ .mode = .stream, .protocol = .tcp }) catch @panic("connect failed");
        defer {
            if (self.close_client) stream.close(self.io);
        }

        while (!self.reader_started) {
            self.client_yields += 1;
            if (self.client_yields > max_poll_yields) @panic("server did not start reading");
            scheduler.yieldCurrent();
        }
        scheduler.yieldUntilBlockedCount(1);

        const chunks: [1][]const u8 = .{"ping"};
        const written = self.io.vtable.netWrite(self.io.userdata, stream.socket.handle, "", &chunks, 1) catch @panic("write failed");
        if (written != 4) @panic("short write");
        self.world.record("io.net.wrote len={}", .{written}) catch @panic("record failed");
    }
};

const partition_retry_key: WaitKey = 900_001;
const partition_done_key: WaitKey = 900_002;

const NetPartitionScenario = struct {
    io: Io,
    world: *World,
    network_control: network_module.AnyNetworkControl,
    address: Io.net.IpAddress,
    server: Io.net.Server,
    reader_started: bool = false,
    client_yields: u16 = 0,
    first_read_error: ?Io.net.Stream.Reader.Error = null,
    second_read_bytes: [4]u8 = undefined,
    second_read_len: usize = 0,

    fn serverTask(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        const stream = self.server.accept(self.io) catch @panic("accept failed");
        defer stream.close(self.io);
        self.world.record("io.net.partition.accepted", .{}) catch @panic("record failed");

        self.reader_started = true;
        var first_read_bytes: [4]u8 = undefined;
        var first_buffers: [1][]u8 = .{&first_read_bytes};
        const first_read_len = self.io.vtable.netRead(
            self.io.userdata,
            stream.socket.handle,
            &first_buffers,
        ) catch |err| read_error: {
            self.first_read_error = err;
            self.world.record("io.net.partition.read_error error={s}", .{@errorName(err)}) catch @panic("record failed");
            break :read_error 0;
        };
        if (self.first_read_error == null) {
            _ = first_read_len;
            @panic("partitioned read unexpectedly succeeded");
        }

        _ = scheduler.wake(partition_retry_key, 1) catch @panic("retry wake failed");

        var second_buffers: [1][]u8 = .{&self.second_read_bytes};
        self.second_read_len = self.io.vtable.netRead(
            self.io.userdata,
            stream.socket.handle,
            &second_buffers,
        ) catch @panic("read after heal failed");
        self.world.record("io.net.partition.read_after_heal len={}", .{self.second_read_len}) catch @panic("record failed");

        _ = scheduler.wake(partition_done_key, 1) catch @panic("done wake failed");
    }

    fn clientTask(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        scheduler.yieldUntilBlockedCount(1);

        const stream = self.address.connect(self.io, .{ .mode = .stream, .protocol = .tcp }) catch @panic("connect failed");
        defer stream.close(self.io);

        while (!self.reader_started) {
            self.client_yields += 1;
            if (self.client_yields > max_poll_yields) @panic("server did not start reading");
            scheduler.yieldCurrent();
        }
        scheduler.yieldUntilBlockedCount(1);

        const first_chunks: [1][]const u8 = .{"ping"};
        const first_written = self.io.vtable.netWrite(
            self.io.userdata,
            stream.socket.handle,
            "",
            &first_chunks,
            1,
        ) catch @panic("partition probe write failed");
        if (first_written != 4) @panic("short partition probe write");

        const server_side = [_]network_module.NodeId{0};
        const client_side = [_]network_module.NodeId{1};
        self.network_control.partition(&server_side, &client_side) catch @panic("partition failed");
        scheduler.blockCurrent(partition_retry_key);

        self.network_control.heal() catch @panic("heal failed");
        const retry_chunks: [1][]const u8 = .{"pong"};
        const retry_written = self.io.vtable.netWrite(
            self.io.userdata,
            stream.socket.handle,
            "",
            &retry_chunks,
            1,
        ) catch @panic("retry write failed");
        if (retry_written != 4) @panic("short retry write");
        scheduler.blockCurrent(partition_done_key);
    }
};

fn runNetTrace(allocator: std.mem.Allocator, seed: u64, kind: NetScenarioKind) ![]u8 {
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

    var backend = io_module.Backend.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096);
    defer backend.deinit();
    backend.attachFutexWaitSet(futexWaitSet(scheduler));

    const io = backend.io();
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4567) catch unreachable;
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const scenario = try runtime_allocator.create(NetScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{
        .io = io,
        .world = world,
        .address = address,
        .server = server,
    };

    switch (kind) {
        .accept => {
            _ = try scheduler.spawn(.{
                .entry = NetScenario.acceptor,
                .arg = scenario,
            });
            _ = try scheduler.spawn(.{
                .entry = NetScenario.connector,
                .arg = scenario,
            });
        },
        .exchange => {
            _ = try scheduler.spawn(.{
                .entry = NetScenario.exchangeServer,
                .arg = scenario,
            });
            _ = try scheduler.spawn(.{
                .entry = NetScenario.exchangeClient,
                .arg = scenario,
            });
        },
        .latency, .latency_close, .drop => unreachable,
    }

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(usize, 2), scheduler.completedCount());
    try std.testing.expectEqual(@as(usize, 0), scheduler.blockedCount());
    try std.testing.expect(scenario.accepted);

    switch (kind) {
        .accept => {},
        .exchange, .latency, .latency_close => {
            try std.testing.expect(scenario.read_error == null);
            try std.testing.expectEqual(@as(usize, 4), scenario.read_len);
            try std.testing.expectEqualStrings("ping", &scenario.read_bytes);
        },
        .drop => {
            try std.testing.expectEqual(@as(usize, 0), scenario.read_len);
        },
    }

    return try allocator.dupe(u8, world.traceBytes());
}

fn runNetworkFaultTrace(allocator: std.mem.Allocator, seed: u64, kind: NetScenarioKind) ![]u8 {
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

    const network_control = try network_module.initSimControl(world, .{ .nodes = 2 });
    switch (kind) {
        .latency, .latency_close => try network_control.setLatency(.{ .min_latency_ns = 30 }),
        .drop => try network_control.setLossiness(.{ .drop_rate = .always() }),
        .accept, .exchange => {},
    }

    var backend = io_module.Backend.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096);
    defer backend.deinit();
    backend.attachFutexWaitSet(futexWaitSet(scheduler));
    backend.attachNetworkControl(network_control);

    const io = backend.io();
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4568) catch unreachable;
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const scenario = try runtime_allocator.create(NetScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{
        .io = io,
        .world = world,
        .address = address,
        .server = server,
        .close_client = kind == .latency_close,
    };

    _ = try scheduler.spawn(.{
        .entry = NetScenario.exchangeServer,
        .arg = scenario,
    });
    _ = try scheduler.spawn(.{
        .entry = NetScenario.exchangeClient,
        .arg = scenario,
    });

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(usize, 2), scheduler.completedCount());
    try std.testing.expectEqual(@as(usize, 0), scheduler.blockedCount());
    try std.testing.expect(scenario.accepted);

    switch (kind) {
        .latency, .latency_close => {
            try std.testing.expect(scenario.read_error == null);
            try std.testing.expectEqual(@as(usize, 4), scenario.read_len);
            try std.testing.expectEqualStrings("ping", &scenario.read_bytes);
            try std.testing.expectEqual(@as(u64, 30), world.now());
        },
        .drop => {
            try std.testing.expectEqual(error.Timeout, scenario.read_error.?);
            try std.testing.expectEqual(@as(usize, 0), scenario.read_len);
        },
        .accept, .exchange => unreachable,
    }

    return try allocator.dupe(u8, world.traceBytes());
}

fn runNetworkPartitionTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
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

    const network_control = try network_module.initSimControl(world, .{ .nodes = 2 });
    try network_control.setLatency(.{ .min_latency_ns = 30 });

    var backend = io_module.Backend.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096);
    defer backend.deinit();
    backend.attachFutexWaitSet(futexWaitSet(scheduler));
    backend.attachNetworkControl(network_control);

    const io = backend.io();
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4569) catch unreachable;
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    const scenario = try runtime_allocator.create(NetPartitionScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{
        .io = io,
        .world = world,
        .network_control = network_control,
        .address = address,
        .server = server,
    };

    _ = try scheduler.spawn(.{
        .entry = NetPartitionScenario.serverTask,
        .arg = scenario,
    });
    _ = try scheduler.spawn(.{
        .entry = NetPartitionScenario.clientTask,
        .arg = scenario,
    });

    try scheduler.runUntilIdle();
    try std.testing.expectEqual(@as(usize, 2), scheduler.completedCount());
    try std.testing.expectEqual(@as(usize, 0), scheduler.blockedCount());
    try std.testing.expectEqual(error.Timeout, scenario.first_read_error.?);
    try std.testing.expectEqual(@as(usize, 4), scenario.second_read_len);
    try std.testing.expectEqualStrings("pong", &scenario.second_read_bytes);
    try std.testing.expectEqual(@as(u64, 60), world.now());

    return try allocator.dupe(u8, world.traceBytes());
}

fn expectTraceOrder(trace: []const u8, before: []const u8, after: []const u8) !void {
    const before_index = std.mem.indexOf(u8, trace, before) orelse return error.TestExpectedEqual;
    const after_index = std.mem.indexOf(u8, trace, after) orelse return error.TestExpectedEqual;
    try std.testing.expect(before_index < after_index);
}

fn expectTraceOrderAfter(trace: []const u8, start: usize, before: []const u8, after: []const u8) !usize {
    const before_index = std.mem.indexOfPos(u8, trace, start, before) orelse return error.TestExpectedEqual;
    const after_index = std.mem.indexOfPos(u8, trace, before_index + before.len, after) orelse return error.TestExpectedEqual;
    try std.testing.expect(before_index < after_index);
    return after_index;
}

test "TaskScheduler: std.Io.net accept suspends and replays" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runNetTrace(std.testing.allocator, 0xAACE97, .accept);
    defer std.testing.allocator.free(first);
    const second = try runNetTrace(std.testing.allocator, 0xAACE97, .accept);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.block task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.wake key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.accepted") != null);
    try expectTraceOrder(first, "scheduler.block task=", "scheduler.wake key=");
    try expectTraceOrder(first, "scheduler.wake key=", "io.net.connected");
    try expectTraceOrder(first, "io.net.connected", "io.net.accepted");
}

test "TaskScheduler: std.Io.net read suspends and replays" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runNetTrace(std.testing.allocator, 0xAACE98, .exchange);
    defer std.testing.allocator.free(first);
    const second = try runNetTrace(std.testing.allocator, 0xAACE98, .exchange);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.block task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.wake key=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.read len=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.idle tasks=2 completed=2 blocked=0") != null);
    const accepted_index = std.mem.indexOf(u8, first, "io.net.accepted").?;
    const read_block_wake = try expectTraceOrderAfter(first, accepted_index, "scheduler.block task=", "scheduler.wake key=");
    const wrote_index = try expectTraceOrderAfter(first, read_block_wake, "io.net.wrote len=4", "io.net.read len=4");
    try std.testing.expect(wrote_index > read_block_wake);
}

test "TaskScheduler: std.Io.net latency uses network delivery deadline" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runNetworkFaultTrace(std.testing.allocator, 0xAACE99, .latency);
    defer std.testing.allocator.free(first);
    const second = try runNetworkFaultTrace(std.testing.allocator, 0xAACE99, .latency);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "network.send id=0 from=1 to=0 deliver_at=30 latency_ns=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "scheduler.timeout task=") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.deliver from=1 to=0") != null);
    try expectTraceOrder(first, "network.send id=0 from=1 to=0", "scheduler.timeout task=");
    try expectTraceOrder(first, "scheduler.timeout task=", "io.net.deliver from=1 to=0");
    try expectTraceOrder(first, "io.net.deliver from=1 to=0", "io.net.read len=4");
}

test "TaskScheduler: std.Io.net graceful close drains delayed bytes before EOF" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runNetworkFaultTrace(std.testing.allocator, 0xAACE9C, .latency_close);
    defer std.testing.allocator.free(first);
    const second = try runNetworkFaultTrace(std.testing.allocator, 0xAACE9C, .latency_close);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "network.send id=0 from=1 to=0 deliver_at=30 latency_ns=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.deliver from=1 to=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.read len=4") != null);
}

test "TaskScheduler: std.Io.net dropped write replays and surfaces read timeout" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runNetworkFaultTrace(std.testing.allocator, 0xAACE9A, .drop);
    defer std.testing.allocator.free(first);
    const second = try runNetworkFaultTrace(std.testing.allocator, 0xAACE9A, .drop);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "network.drop id=0 from=1 to=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.deliver") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.read_error error=Timeout") != null);
}

test "TaskScheduler: std.Io.net partition drops in-flight bytes and heal permits retry" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runNetworkPartitionTrace(std.testing.allocator, 0xAACE9B);
    defer std.testing.allocator.free(first);
    const second = try runNetworkPartitionTrace(std.testing.allocator, 0xAACE9B);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "network.partition left_count=1 right_count=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "network.drop id=0 from=1 to=0 reason=link_disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.delivery_error from=1 to=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.partition.read_error error=Timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "network.heal disabled_count=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "network.deliver id=1 from=1 to=0 now_ns=60") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "io.net.partition.read_after_heal len=4") != null);
    try expectTraceOrder(first, "network.send id=0 from=1 to=0", "network.partition left_count=1 right_count=1");
    try expectTraceOrder(first, "network.partition left_count=1 right_count=1", "network.drop id=0 from=1 to=0 reason=link_disabled");
    try expectTraceOrder(first, "network.drop id=0 from=1 to=0 reason=link_disabled", "io.net.partition.read_error error=Timeout");
    try expectTraceOrder(first, "io.net.partition.read_error error=Timeout", "network.heal disabled_count=2");
    try expectTraceOrder(first, "network.heal disabled_count=2", "network.deliver id=1 from=1 to=0 now_ns=60");
}
