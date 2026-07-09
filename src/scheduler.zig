//! Deterministic scheduler building blocks.

const std = @import("std");

const disk_module = @import("disk/root.zig");
const fiber = @import("fiber.zig");
const futex_module = @import("io/futex.zig");
const io_internal = @import("io/root.zig").internal;
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

/// Default stack for scheduled tasks. Overridable per simulation through
/// `SimulateOptions.task_stack_size`.
///
/// Scheduler tasks run normal Marionette code, including trace formatting and
/// allocator calls, so they need more room than the primitive fiber smoke test.
/// Real SUT code paths can be deep: the dusty HTTP validation's Debug-mode
/// client `fetch` needs just over 640 KiB. Stacks are lazily paged mmap
/// regions on guard-page targets, so this size costs address space, not
/// resident memory, and overflows land in a 256 KiB PROT_NONE guard region
/// below the stack instead of corrupting neighboring mappings.
pub const default_task_stack_size = 1024 * 1024;

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
    /// The wait was interrupted by a consumed cancellation request. Only
    /// cancelable waits resume with this result.
    canceled,
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
    completed_task_count: usize = 0,
    /// Cancel-protection state for the main (non-task) context. Nothing can
    /// cancel the main context, but `swapCancelProtection` must round-trip
    /// the previous value faithfully regardless of caller context.
    main_cancel_protection: Io.CancelProtection = .unblocked,
    /// Stack size for tasks spawned through the type-erased `std.Io` runtime
    /// seam. Direct `spawn` callers can still override per task.
    task_stack_size: usize = default_task_stack_size,
    /// Maximum seeded initial task delay; see
    /// `SimulateOptions.task_start_jitter_ns`. Zero draws nothing and
    /// records nothing.
    task_start_jitter_ns: u64 = 0,
    /// Whether task fibers register their guard regions with the
    /// stack-overflow diagnostics signal handler. See
    /// `SimulateOptions.fiber_overflow_diagnostics`.
    overflow_diagnostics: bool = true,

    const MainWait = struct {
        key: WaitKey,
        woken: bool = false,
    };

    pub const Entry = *const fn (scheduler: *Self, arg: *anyopaque) void;

    pub const SpawnOptions = struct {
        stack_size: usize = default_task_stack_size,
        entry: Entry,
        arg: *anyopaque,
        process_id: ?io_internal.ProcessId = null,
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
        cancelable: bool = false,
        wait_result: WaitResult = .woken,
    };

    const Task = struct {
        id: TaskId,
        scheduler: *Self,
        entry: Entry,
        arg: *anyopaque,
        process_id: ?io_internal.ProcessId = null,
        /// Null once the task has completed: the fiber (and its stack) is
        /// reclaimed eagerly so long-lived worlds spawning many tasks do not
        /// accumulate dead stacks until teardown.
        fiber_instance: ?*fiber.Fiber,
        state: TaskState = .ready,
        blocked_key: ?WaitKey = null,
        blocked_deadline_ns: ?u64 = null,
        /// Whether the active blocked wait is a cancellation point that a
        /// `requestCancel` may interrupt. Only meaningful while blocked.
        blocked_cancelable: bool = false,
        wait_result: WaitResult = .woken,
        kill_requested: bool = false,
        /// An armed cancellation request. Consumed (reset to false) when
        /// `error.Canceled` is delivered at a cancellation point; `recancel`
        /// re-arms it.
        cancel_requested: bool = false,
        /// Whether a cancellation was delivered and not yet re-armed. Backs
        /// the `recancel` precondition assert.
        cancel_delivered: bool = false,
        cancel_protection: Io.CancelProtection = .unblocked,
        /// Seeded initial delay drawn at spawn when start jitter is
        /// enabled; the task parks this long before its entry runs.
        start_delay_ns: u64 = 0,

        fn run(arg: *anyopaque) void {
            const task: *Task = @ptrCast(@alignCast(arg));
            if (task.start_delay_ns > 0) {
                const scheduler = task.scheduler;
                const wake_at = std.math.add(u64, scheduler.world.now(), task.start_delay_ns) catch
                    @panic("task start jitter deadline exceeds clock range");
                // The park shares the sleep key namespace (keyed by task id,
                // so nothing wakes it); a spurious wake must not start the
                // task early. Not a cancellation point: an armed cancel is
                // delivered at the task's first real one.
                while (scheduler.world.now() < wake_at) {
                    _ = scheduler.blockCurrentUntil(
                        futex_module.waitKey(.sleep, task.id + 1),
                        wake_at,
                    );
                }
            }
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
            self.blocked_cancelable = false;
            self.wait_result = result;
        }

        /// Park the task on `key`, optionally with a timeout deadline.
        fn block(self: *Task, key: WaitKey, deadline_ns: ?u64, cancelable: bool) void {
            self.state = .blocked;
            self.blocked_key = key;
            self.blocked_deadline_ns = deadline_ns;
            self.blocked_cancelable = cancelable;
            self.wait_result = .woken;
        }

        /// Whether an armed cancellation request can be delivered right now.
        fn cancelDeliverable(self: *const Task) bool {
            return self.cancel_requested and self.cancel_protection == .unblocked;
        }

        /// Consume the armed cancellation request: one delivery per request.
        fn consumeCancel(self: *Task) void {
            std.debug.assert(self.cancelDeliverable());
            self.cancel_requested = false;
            self.cancel_delivered = true;
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
        return try self.spawnOpaqueForProcess(null, entry, arg);
    }

    /// Spawn a type-erased task owned by `process_id`.
    pub fn spawnOpaqueForProcess(
        self: *Self,
        process_id: ?io_internal.ProcessId,
        entry: *const fn (*anyopaque) void,
        arg: *anyopaque,
    ) TaskSchedulerError!TaskId {
        const adapter = try self.allocator.create(OpaqueEntry);
        errdefer self.allocator.destroy(adapter);
        adapter.* = .{ .entry = entry, .arg = arg };
        try self.opaque_entries.append(self.allocator, adapter);
        errdefer _ = self.opaque_entries.pop();

        return try self.spawn(.{
            .stack_size = self.task_stack_size,
            .entry = OpaqueEntry.run,
            .arg = adapter,
            .process_id = process_id,
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
            .process_id = options.process_id,
            .fiber_instance = null,
        };

        const fiber_instance = try fiber.Fiber.create(self.allocator, .{
            .stack_size = options.stack_size,
            .finish_context = &self.main_context,
            .entry = Task.run,
            .arg = task,
            .diagnostic = if (self.overflow_diagnostics) .{
                .task_id = task_id,
                .process_id = if (options.process_id) |process_id| @as(u64, process_id) else null,
            } else null,
        });
        errdefer fiber_instance.destroy();
        task.fiber_instance = fiber_instance;

        try self.tasks.append(self.allocator, task);
        errdefer _ = self.tasks.pop();

        try self.ready.append(self.allocator, task_id);
        errdefer _ = self.ready.pop();

        try self.recordSpawn(task_id, options.process_id);
        if (self.task_start_jitter_ns > 0) {
            // The bound is inclusive, so `maxInt(u64)` means a full-range
            // draw; `+ 1` would overflow before reaching the bounded draw.
            task.start_delay_ns = if (self.task_start_jitter_ns == std.math.maxInt(u64))
                try self.world.randomU64()
            else
                try self.world.randomIntLessThan(u64, self.task_start_jitter_ns + 1);
            try self.recordStartJitter(task_id, task.start_delay_ns);
        }
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
        return self.blockCurrentImpl(key, deadline_ns, false);
    }

    /// Park the current task on `key` as a cancellation point.
    ///
    /// If a deliverable cancellation request is already armed, it is consumed
    /// and `.canceled` is returned without parking. A `requestCancel` against
    /// the parked task consumes the request and resumes the wait with
    /// `.canceled`. Main-context waits are never cancelable.
    // Same optimizer boundary rule as `yieldCurrent`.
    pub noinline fn blockCurrentCancelableUntil(self: *Self, key: WaitKey, deadline_ns: ?u64) WaitResult {
        if (self.current) |task| {
            if (task.cancelDeliverable()) {
                task.consumeCancel();
                self.recordCancelDeliver(task.id) catch @panic("failed to record cancel delivery");
                return .canceled;
            }
        }
        return self.blockCurrentImpl(key, deadline_ns, true);
    }

    // Same optimizer boundary rule as `yieldCurrent`.
    noinline fn blockCurrentImpl(self: *Self, key: WaitKey, deadline_ns: ?u64, cancelable: bool) WaitResult {
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
            .cancelable = cancelable,
        };
        const resume_message = fiber.contextSwitchMessage(SwitchMessage, &message);
        return resume_message.wait_result;
    }

    /// Arm a cancellation request against `task_id`.
    ///
    /// Unknown ids (completed and retired tasks) and repeat requests are
    /// idempotent no-ops. A task parked in a cancelable wait with delivery
    /// unprotected is resumed immediately with `.canceled` and the request is
    /// consumed; otherwise the request stays armed until the task reaches its
    /// next cancellation point.
    pub fn requestCancel(self: *Self, task_id: TaskId) void {
        const task = self.findTask(task_id) orelse return;
        if (task.state == .completed) return;
        if (task.cancel_requested) return;

        task.cancel_requested = true;
        self.recordCancelRequest(task.id) catch @panic("failed to record cancel request");

        if (task.state != .blocked) return;
        if (!task.blocked_cancelable) return;
        if (task.cancel_protection != .unblocked) return;

        task.consumeCancel();
        task.clearBlock(.ready, .canceled);
        self.ready.append(self.allocator, task.id) catch @panic("failed to ready canceled task");
        self.recordCancelDeliver(task.id) catch @panic("failed to record cancel delivery");
    }

    /// Consume a deliverable cancellation request on the current task.
    ///
    /// Returns true when the caller must surface `error.Canceled`. Main-context
    /// callers are never canceled.
    pub fn takeCancelRequest(self: *Self) bool {
        const task = self.current orelse return false;
        if (!task.cancelDeliverable()) return false;
        task.consumeCancel();
        self.recordCancelDeliver(task.id) catch @panic("failed to record cancel delivery");
        return true;
    }

    /// Re-arm the cancellation request after a delivered `error.Canceled`.
    pub fn recancelCurrent(self: *Self) void {
        const task = self.current orelse
            @panic("recancel outside a scheduled task: the main context cannot be canceled");
        std.debug.assert(task.cancel_delivered); // recancel requires a prior delivered cancellation
        task.cancel_delivered = false;
        task.cancel_requested = true;
    }

    /// Swap the cancel-protection state of the calling context.
    pub fn swapCancelProtection(self: *Self, new: Io.CancelProtection) Io.CancelProtection {
        if (self.current) |task| {
            const old = task.cancel_protection;
            task.cancel_protection = new;
            return old;
        }
        const old = self.main_cancel_protection;
        self.main_cancel_protection = new;
        return old;
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
                if (returned_task.kill_requested) {
                    try scheduler.completeKilledTask(returned_task);
                } else {
                    returned_task.clearBlock(.ready, .woken);
                    try scheduler.ready.append(scheduler.allocator, returned_task.id);
                    try scheduler.recordYield(returned_task.id);
                }
            },
            .blocked => {
                if (returned_task.kill_requested) {
                    try scheduler.completeKilledTask(returned_task);
                } else {
                    returned_task.block(
                        returned_message.key,
                        returned_message.deadline_ns,
                        returned_message.cancelable,
                    );
                    try scheduler.recordBlock(returned_task.id, returned_message.key, returned_message.deadline_ns);
                }
            },
            .completed => {
                returned_task.clearBlock(.completed, .woken);
                try scheduler.recordComplete(
                    returned_task.id,
                    if (returned_task.kill_requested) "killed" else "ok",
                );
                scheduler.retireCompletedTask(returned_task);
            },
        }
        return .ran;
    }

    /// Cancel every non-completed task owned by `process_id`.
    ///
    /// Running fibers cannot be preempted safely; if the current fiber belongs
    /// to the target process, it is marked and converted to `killed` at its
    /// next scheduler suspension/completion boundary.
    pub fn killProcess(self: *Self, process_id: io_internal.ProcessId) void {
        var index: usize = 0;
        while (index < self.tasks.items.len) {
            const task = self.tasks.items[index];
            if (task.process_id != @as(?io_internal.ProcessId, process_id) or task.state == .completed) {
                index += 1;
                continue;
            }
            if (task == self.current) {
                task.kill_requested = true;
                index += 1;
                continue;
            }
            self.completeKilledTask(task) catch @panic("failed to kill process task");
        }
    }

    fn completeKilledTask(self: *Self, task: *Task) TaskSchedulerError!void {
        if (task.state == .completed) return;

        self.removeReadyTask(task.id);
        task.clearBlock(.completed, .woken);
        task.kill_requested = true;
        try self.recordComplete(task.id, "killed");
        self.retireCompletedTask(task);
    }

    fn retireCompletedTask(self: *Self, task: *Task) void {
        std.debug.assert(task.state == .completed);

        // The fiber is either naturally finished or explicitly killed, and we
        // are back on the scheduler stack. Nothing can resume this task, so the
        // active table can forget the full record while stable task ids remain
        // represented by `next_task_id` and `completed_task_count`.
        if (task.fiber_instance) |fiber_instance| fiber_instance.destroy();

        for (self.tasks.items, 0..) |candidate, index| {
            if (candidate == task) {
                _ = self.tasks.orderedRemove(index);
                self.completed_task_count += 1;
                self.allocator.destroy(task);
                return;
            }
        }
        unreachable;
    }

    fn removeReadyTask(self: *Self, task_id: TaskId) void {
        for (self.ready.items, 0..) |ready_id, index| {
            if (ready_id == task_id) {
                _ = self.ready.orderedRemove(index);
                return;
            }
        }
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
        return self.completed_task_count + self.countState(.completed);
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

    fn recordSpawn(
        self: *Self,
        task_id: TaskId,
        process_id: ?io_internal.ProcessId,
    ) (std.mem.Allocator.Error || world_module.TraceError)!void {
        const fields = [_]world_module.TraceField{
            traceField("task", .{ .uint = task_id }),
            traceField("process", .{ .uint = process_id orelse 0 }),
        };
        try self.world.recordFields(
            "scheduler.spawn",
            fields[0..if (process_id != null) 2 else 1],
        );
    }

    fn recordStartJitter(
        self: *Self,
        task_id: TaskId,
        delay_ns: u64,
    ) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.start_jitter", &.{
            traceField("task", .{ .uint = task_id }),
            traceField("delay_ns", .{ .uint = delay_ns }),
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

    fn recordCancelRequest(self: *Self, task_id: TaskId) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.cancel_request", &.{
            traceField("task", .{ .uint = task_id }),
        });
    }

    fn recordCancelDeliver(self: *Self, task_id: TaskId) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields("scheduler.cancel_deliver", &.{
            traceField("task", .{ .uint = task_id }),
        });
    }

    fn recordCensus(self: *Self, event: []const u8) (std.mem.Allocator.Error || world_module.TraceError)!void {
        try self.world.recordFields(event, &.{
            traceField("tasks", .{ .uint = @intCast(self.next_task_id) }),
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

pub fn futexWaitSet(self: *TaskScheduler) io_internal.FutexWaitSet {
    return .{
        .ptr = self,
        .vtable = &futex_wait_set_vtable,
    };
}

fn waitSetBlock(ptr: *anyopaque, key: usize) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    scheduler.blockCurrent(key);
}

fn waitSetBlockUntil(ptr: *anyopaque, key: usize, deadline_ns: ?u64) io_internal.FutexWaitResult {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return switch (scheduler.blockCurrentUntil(key, deadline_ns)) {
        .woken => .woken,
        .timed_out => .timed_out,
        // Only cancelable parks resume with `.canceled`.
        .canceled => unreachable,
    };
}

fn waitSetBlockUntilCancelable(ptr: *anyopaque, key: usize, deadline_ns: ?u64) io_internal.FutexWaitResult {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return switch (scheduler.blockCurrentCancelableUntil(key, deadline_ns)) {
        .woken => .woken,
        .timed_out => .timed_out,
        .canceled => .canceled,
    };
}

fn waitSetWake(ptr: *anyopaque, key: usize, max_count: usize) usize {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.wake(key, max_count) catch @panic("scheduler wake failed");
}

const futex_wait_set_vtable: io_internal.FutexWaitSet.VTable = .{
    .block = waitSetBlock,
    .block_until = waitSetBlockUntil,
    .block_until_cancelable = waitSetBlockUntilCancelable,
    .wake = waitSetWake,
};

/// Tear down a world-owned scheduler registered via `World.registerTeardown`.
pub fn deinitTaskSchedulerOpaque(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    scheduler.deinit();
    allocator.destroy(scheduler);
}

/// Build the `std.Io` task runtime view over a scheduler.
pub fn taskRuntime(self: *TaskScheduler) io_internal.TaskRuntime {
    return .{
        .ptr = self,
        .vtable = &task_runtime_vtable,
    };
}

/// Build the disk-latency suspension view over a scheduler.
pub fn diskLatencyRuntime(self: *TaskScheduler) disk_module.DiskLatencyRuntime {
    return .{
        .ptr = self,
        .vtable = &disk_latency_runtime_vtable,
    };
}

const disk_latency_wait_key = futex_module.waitKey(.disk, 0);

fn diskLatencyInTask(ptr: *anyopaque) bool {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.current != null;
}

fn diskLatencyWaitUntil(ptr: *anyopaque, deadline_ns: u64) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    while (scheduler.world.now() < deadline_ns) {
        switch (scheduler.blockCurrentUntil(disk_latency_wait_key, deadline_ns)) {
            .timed_out => {},
            .woken => continue,
            // Only cancelable parks resume with `.canceled`.
            .canceled => unreachable,
        }
    }
}

const disk_latency_runtime_vtable: disk_module.DiskLatencyRuntime.VTable = .{
    .in_task = diskLatencyInTask,
    .wait_until = diskLatencyWaitUntil,
};

/// Build the harness-facing control view over this scheduler.
pub fn taskControl(self: *TaskScheduler) io_internal.TaskControl {
    return .{
        .ptr = self,
        .vtable = &task_control_vtable,
    };
}

/// Build the process-lifecycle task control view over this scheduler.
pub fn processTaskControl(self: *TaskScheduler) io_internal.ProcessTaskControl {
    return .{
        .ptr = self,
        .vtable = &process_task_control_vtable,
    };
}

fn taskControlRunUntilIdle(ptr: *anyopaque) anyerror!void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    try scheduler.runUntilIdle();
}

fn taskControlBlockedCount(ptr: *const anyopaque) usize {
    const scheduler: *const TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.blockedCount();
}

const task_control_vtable: io_internal.TaskControl.VTable = .{
    .run_until_idle = taskControlRunUntilIdle,
    .blocked_count = taskControlBlockedCount,
};

fn processTaskControlKillProcess(ptr: *anyopaque, process_id: io_internal.ProcessId) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    scheduler.killProcess(process_id);
}

fn processTaskControlTaskActive(ptr: *const anyopaque, task_id: u64) bool {
    const scheduler: *const TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.findTask(task_id) != null;
}

const process_task_control_vtable: io_internal.ProcessTaskControl.VTable = .{
    .kill_process = processTaskControlKillProcess,
    .task_active = processTaskControlTaskActive,
};

fn taskRuntimeSpawn(
    ptr: *anyopaque,
    process_id: ?io_internal.ProcessId,
    entry: *const fn (*anyopaque) void,
    arg: *anyopaque,
) io_internal.TaskRuntime.SpawnError!u64 {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.spawnOpaqueForProcess(process_id, entry, arg) catch return error.ConcurrencyUnavailable;
}

fn taskRuntimeInTask(ptr: *anyopaque) bool {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.current != null;
}

fn taskRuntimeCurrentTaskId(ptr: *anyopaque) ?u64 {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return if (scheduler.current) |task| task.id else null;
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

fn taskRuntimeRequestCancel(ptr: *anyopaque, task_id: u64) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    scheduler.requestCancel(task_id);
}

fn taskRuntimeTakeCancelRequest(ptr: *anyopaque) bool {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.takeCancelRequest();
}

fn taskRuntimeRecancel(ptr: *anyopaque) void {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    scheduler.recancelCurrent();
}

fn taskRuntimeSwapCancelProtection(ptr: *anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const scheduler: *TaskScheduler = @ptrCast(@alignCast(ptr));
    return scheduler.swapCancelProtection(new);
}

const task_runtime_vtable: io_internal.TaskRuntime.VTable = .{
    .spawn = taskRuntimeSpawn,
    .in_task = taskRuntimeInTask,
    .current_task_id = taskRuntimeCurrentTaskId,
    .block = taskRuntimeBlock,
    .wake = taskRuntimeWake,
    .run_until_done = taskRuntimeRunUntilDone,
    .request_cancel = taskRuntimeRequestCancel,
    .take_cancel_request = taskRuntimeTakeCancelRequest,
    .recancel = taskRuntimeRecancel,
    .swap_cancel_protection = taskRuntimeSwapCancelProtection,
};

/// Fixed-capacity deterministic event queue.
///
/// This is not the final Marionette scheduler. It is a small shared primitive
/// for examples and early designs that need stable event ordering.
/// TODO(roadmap "Scheduler Scale"): `pop` does a linear scan, which is fine for Phase 0.
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
    const runtime_allocator = std.testing.allocator;

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

test "TaskScheduler: maximum task start jitter draws full-range without overflow" {
    if (!fiber.supported) return error.SkipZigTest;

    const runtime_allocator = std.testing.allocator;

    const world = try runtime_allocator.create(World);
    errdefer runtime_allocator.destroy(world);
    world.* = try World.init(runtime_allocator, .{ .seed = 0x717E4, .tick_ns = 10 });
    defer {
        world.deinit();
        runtime_allocator.destroy(world);
    }

    const scheduler = try runtime_allocator.create(TaskScheduler);
    errdefer runtime_allocator.destroy(scheduler);
    scheduler.* = TaskScheduler.init(runtime_allocator, world);
    scheduler.task_start_jitter_ns = std.math.maxInt(u64);
    defer {
        scheduler.deinit();
        runtime_allocator.destroy(scheduler);
    }

    // The inclusive-bound draw wrapped on `maxInt(u64) + 1` before reaching
    // the PRNG; the spawn itself is the regression. The task is deliberately
    // never run: its drawn delay may sit anywhere in the u64 range and would
    // advance the clock accordingly.
    var task = ToyTask{ .remaining = 1 };
    _ = try scheduler.spawn(.{ .entry = ToyTask.run, .arg = &task });
    try std.testing.expect(
        std.mem.indexOf(u8, world.traceBytes(), "scheduler.start_jitter") != null,
    );
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

    const runtime_allocator = std.testing.allocator;

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

test "TaskScheduler: completed tasks retire their active records" {
    if (!fiber.supported) return error.SkipZigTest;

    const runtime_allocator = std.testing.allocator;

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
    try std.testing.expectEqual(@as(usize, 0), scheduler.tasks.items.len);
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
    const runtime_allocator = std.testing.allocator;

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

    const runtime_allocator = std.testing.allocator;

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
            .canceled => unreachable,
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
    const runtime_allocator = std.testing.allocator;

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
    const runtime_allocator = std.testing.allocator;

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

    var backend = io_internal.Backend.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096);
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
    const runtime_allocator = std.testing.allocator;

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

    var backend = io_internal.Backend.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096);
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

const disk_latency_operation_count = 11;

const DiskLatencyOrderingScenario = struct {
    world: *World,
    io: Io,
    disk: disk_module.Disk,
    control: disk_module.DiskControl,
    operation_times: [disk_latency_operation_count]u64 = @splat(0),
    timer_times: [disk_latency_operation_count]u64 = @splat(0),

    fn recordOperation(self: *@This(), index: usize) void {
        self.operation_times[index] = self.world.now();
    }

    fn operations(self: *@This()) void {
        self.disk.write(.{ .path = "alpha", .offset = 0, .bytes = "abcd" }) catch
            @panic("disk write failed");
        self.recordOperation(0);

        var read_buffer: [4]u8 = undefined;
        self.disk.read(.{ .path = "alpha", .offset = 0, .buffer = &read_buffer }) catch
            @panic("disk read failed");
        if (!std.mem.eql(u8, &read_buffer, "abcd")) @panic("disk read mismatch");
        self.recordOperation(1);

        var some_buffer: [2]u8 = undefined;
        const read_len = self.disk.readSome(.{
            .path = "alpha",
            .offset = 1,
            .buffer = &some_buffer,
        }) catch @panic("disk readSome failed");
        if (read_len != 2 or !std.mem.eql(u8, &some_buffer, "bc")) @panic("disk readSome mismatch");
        self.recordOperation(2);

        const stat = self.disk.stat(.{ .path = "alpha" }) catch @panic("disk stat failed");
        if (stat.size != 4) @panic("disk stat mismatch");
        self.recordOperation(3);

        self.disk.setLength(.{ .path = "alpha", .len = 2 }) catch
            @panic("disk setLength failed");
        self.recordOperation(4);

        self.disk.sync(.{ .path = "alpha" }) catch @panic("disk sync failed");
        self.recordOperation(5);

        self.disk.rename(.{ .old_path = "alpha", .new_path = "archive/alpha" }) catch
            @panic("disk rename failed");
        self.recordOperation(6);

        self.disk.syncDir(.{ .path = "." }) catch @panic("disk syncDir failed");
        self.recordOperation(7);

        self.disk.delete(.{ .path = "archive/alpha" }) catch @panic("disk delete failed");
        self.recordOperation(8);

        self.control.setFaults(.{ .write_error_rate = .always() }) catch
            @panic("failed to set disk faults");
        self.disk.write(.{ .path = "faulted", .offset = 0, .bytes = "x" }) catch |err| {
            if (err != error.WriteError) @panic("unexpected faulted write error");
        };
        self.recordOperation(9);

        _ = self.disk.stat(.{ .path = "missing" }) catch |err| {
            if (err != error.FileNotFound) @panic("unexpected missing stat error");
            self.recordOperation(10);
            return;
        };
        @panic("missing stat unexpectedly succeeded");
    }

    fn earlierTimers(self: *@This()) void {
        for (0..disk_latency_operation_count) |index| {
            const duration_ns: u64 = if (index == 0) 50 else 100;
            Io.sleep(self.io, .fromNanoseconds(duration_ns), .awake) catch
                @panic("disk ordering timer failed");
            self.timer_times[index] = self.world.now();
        }
    }
};

fn runDiskLatencyOrderingTrace(allocator: std.mem.Allocator, seed: u64) ![]u8 {
    var world = try World.init(std.testing.allocator, .{ .seed = seed, .tick_ns = 10 });
    defer world.deinit();
    const sim = try world.simulate(.{
        .disk = .{
            .sector_size = 1,
            .min_latency_ns = 100,
        },
    });
    const io = sim.env.io();

    var scenario: DiskLatencyOrderingScenario = .{
        .world = &world,
        .io = io,
        .disk = sim.env.disk,
        .control = sim.control.disk,
    };

    var operations = Io.async(io, DiskLatencyOrderingScenario.operations, .{&scenario});
    var timers = Io.async(io, DiskLatencyOrderingScenario.earlierTimers, .{&scenario});
    operations.await(io);
    timers.await(io);
    for (0..disk_latency_operation_count) |index| {
        try std.testing.expectEqual(
            @as(u64, @intCast((index + 1) * 100)),
            scenario.operation_times[index],
        );
        try std.testing.expectEqual(
            @as(u64, @intCast(50 + index * 100)),
            scenario.timer_times[index],
        );
    }

    return try allocator.dupe(u8, world.traceBytes());
}

test "TaskScheduler: disk latency parks every operation behind earlier deadlines" {
    if (!fiber.supported) return error.SkipZigTest;

    const first = try runDiskLatencyOrderingTrace(std.testing.allocator, 0xD15C);
    defer std.testing.allocator.free(first);
    const second = try runDiskLatencyOrderingTrace(std.testing.allocator, 0xD15C);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "disk.write op=9 path=faulted offset=0 len=1 status=io_error latency_ns=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "disk.stat op=10 path=missing status=not_found latency_ns=100") != null);
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
    const runtime_allocator = std.testing.allocator;

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

    var backend = io_internal.Backend.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096);
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
    server_io: Io,
    client_io: Io,
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
        const stream = self.server.accept(self.server_io) catch @panic("accept failed");
        defer stream.close(self.server_io);
        self.accepted = true;
        self.world.record("io.net.accepted", .{}) catch @panic("record failed");
    }

    fn connector(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        scheduler.yieldUntilBlockedCount(1);

        const stream = self.address.connect(self.client_io, .{ .mode = .stream, .protocol = .tcp }) catch @panic("connect failed");
        defer stream.close(self.client_io);
        self.world.record("io.net.connected", .{}) catch @panic("record failed");
    }

    fn exchangeServer(_: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        const stream = self.server.accept(self.server_io) catch @panic("accept failed");
        defer stream.close(self.server_io);
        self.accepted = true;
        self.world.record("io.net.accepted", .{}) catch @panic("record failed");

        self.reader_started = true;
        var buffers: [1][]u8 = .{&self.read_bytes};
        self.read_len = self.server_io.vtable.netRead(self.server_io.userdata, stream.socket.handle, &buffers) catch |err| {
            self.read_error = err;
            self.world.record("io.net.read_error error={s}", .{@errorName(err)}) catch @panic("record failed");
            return;
        };
        self.world.record("io.net.read len={}", .{self.read_len}) catch @panic("record failed");
    }

    fn exchangeClient(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        scheduler.yieldUntilBlockedCount(1);

        const stream = self.address.connect(self.client_io, .{ .mode = .stream, .protocol = .tcp }) catch @panic("connect failed");
        defer {
            if (self.close_client) stream.close(self.client_io);
        }

        while (!self.reader_started) {
            self.client_yields += 1;
            if (self.client_yields > max_poll_yields) @panic("server did not start reading");
            scheduler.yieldCurrent();
        }
        scheduler.yieldUntilBlockedCount(1);

        const chunks: [1][]const u8 = .{"ping"};
        const written = self.client_io.vtable.netWrite(self.client_io.userdata, stream.socket.handle, "", &chunks, 1) catch @panic("write failed");
        if (written != 4) @panic("short write");
        self.world.record("io.net.wrote len={}", .{written}) catch @panic("record failed");
    }
};

const partition_retry_key: WaitKey = 900_001;
const partition_done_key: WaitKey = 900_002;

const NetPartitionScenario = struct {
    server_io: Io,
    client_io: Io,
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
        const stream = self.server.accept(self.server_io) catch @panic("accept failed");
        defer stream.close(self.server_io);
        self.world.record("io.net.partition.accepted", .{}) catch @panic("record failed");

        self.reader_started = true;
        var first_read_bytes: [4]u8 = undefined;
        var first_buffers: [1][]u8 = .{&first_read_bytes};
        const first_read_len = self.server_io.vtable.netRead(
            self.server_io.userdata,
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
        self.second_read_len = self.server_io.vtable.netRead(
            self.server_io.userdata,
            stream.socket.handle,
            &second_buffers,
        ) catch @panic("read after heal failed");
        self.world.record("io.net.partition.read_after_heal len={}", .{self.second_read_len}) catch @panic("record failed");

        _ = scheduler.wake(partition_done_key, 1) catch @panic("done wake failed");
    }

    fn clientTask(scheduler: *TaskScheduler, arg: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(arg));
        scheduler.yieldUntilBlockedCount(1);

        const stream = self.address.connect(self.client_io, .{ .mode = .stream, .protocol = .tcp }) catch @panic("connect failed");
        defer stream.close(self.client_io);

        while (!self.reader_started) {
            self.client_yields += 1;
            if (self.client_yields > max_poll_yields) @panic("server did not start reading");
            scheduler.yieldCurrent();
        }
        scheduler.yieldUntilBlockedCount(1);

        const first_chunks: [1][]const u8 = .{"ping"};
        const first_written = self.client_io.vtable.netWrite(
            self.client_io.userdata,
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
        const retry_written = self.client_io.vtable.netWrite(
            self.client_io.userdata,
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
    const runtime_allocator = std.testing.allocator;

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

    var io_runtime: io_internal.ProcessRuntime = undefined;
    try io_runtime.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096, 2);
    defer io_runtime.deinit();
    io_runtime.attachFutexWaitSet(futexWaitSet(scheduler));

    const server_io = try io_runtime.io(0);
    const client_io = try io_runtime.io(1);
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4567) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    const scenario = try runtime_allocator.create(NetScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{
        .server_io = server_io,
        .client_io = client_io,
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
    const runtime_allocator = std.testing.allocator;

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

    const network_control = try network_module.internal.initSimControl(world, .{ .nodes = 2 });
    switch (kind) {
        .latency, .latency_close => try network_control.setLatency(.{ .min_latency_ns = 30 }),
        .drop => try network_control.setLossiness(.{ .drop_rate = .always() }),
        .accept, .exchange => {},
    }

    var io_runtime: io_internal.ProcessRuntime = undefined;
    try io_runtime.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096, 2);
    defer io_runtime.deinit();
    io_runtime.attachFutexWaitSet(futexWaitSet(scheduler));
    io_runtime.attachNetworkControl(network_control);

    const server_io = try io_runtime.io(0);
    const client_io = try io_runtime.io(1);
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4568) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    const scenario = try runtime_allocator.create(NetScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{
        .server_io = server_io,
        .client_io = client_io,
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
    const runtime_allocator = std.testing.allocator;

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

    const network_control = try network_module.internal.initSimControl(world, .{ .nodes = 2 });
    try network_control.setLatency(.{ .min_latency_ns = 30 });

    var io_runtime: io_internal.ProcessRuntime = undefined;
    try io_runtime.init(runtime_allocator, world, disk_module.Disk.unavailable(), 4096, 2);
    defer io_runtime.deinit();
    io_runtime.attachFutexWaitSet(futexWaitSet(scheduler));
    io_runtime.attachNetworkControl(network_control);

    const server_io = try io_runtime.io(0);
    const client_io = try io_runtime.io(1);
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", 4569) catch unreachable;
    var server = try address.listen(server_io, .{});
    defer server.deinit(server_io);

    const scenario = try runtime_allocator.create(NetPartitionScenario);
    defer runtime_allocator.destroy(scenario);
    scenario.* = .{
        .server_io = server_io,
        .client_io = client_io,
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
