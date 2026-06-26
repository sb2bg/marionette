//! Type-erased cooperative task runtime seam for the `std.Io` backend.
//!
//! The backend implements `Io.async`/`Io.concurrent`/`Io.await` against this
//! interface so the scheduler can depend on the io module without a cycle.
//! `TaskScheduler.taskRuntime` provides the deterministic implementation.

/// Logical process identifier used by the task/runtime seam.
///
/// This intentionally mirrors `network.NodeId` without importing the network
/// module here; `env.zig` imports both network and io task interfaces.
pub const ProcessId = u16;

pub const TaskRuntime = struct {
    ptr: *anyopaque,
    process_id: ?ProcessId = null,
    vtable: *const VTable,

    pub const SpawnError = error{ConcurrencyUnavailable};

    pub const VTable = struct {
        /// Spawn a cooperative task running `entry(arg)`. Returns a stable
        /// task id usable as a wait-key payload.
        spawn: *const fn (ptr: *anyopaque, process_id: ?ProcessId, entry: *const fn (*anyopaque) void, arg: *anyopaque) SpawnError!u64,
        /// Whether the caller is currently running inside a scheduled task
        /// (as opposed to the harness/main context driving the scheduler).
        in_task: *const fn (ptr: *anyopaque) bool,
        /// Park the current task on `key`. Must only be called in-task.
        block: *const fn (ptr: *anyopaque, key: usize) void,
        /// Wake up to `max_count` tasks parked on `key`.
        wake: *const fn (ptr: *anyopaque, key: usize, max_count: usize) usize,
        /// Drive the scheduler from the main context until `done.*` is true.
        /// Panics on deterministic deadlock (no runnable work, flag unset).
        run_until_done: *const fn (ptr: *anyopaque, done: *const bool) void,
    };

    pub fn spawn(self: TaskRuntime, entry: *const fn (*anyopaque) void, arg: *anyopaque) SpawnError!u64 {
        return self.vtable.spawn(self.ptr, self.process_id, entry, arg);
    }

    pub fn inTask(self: TaskRuntime) bool {
        return self.vtable.in_task(self.ptr);
    }

    pub fn block(self: TaskRuntime, key: usize) void {
        self.vtable.block(self.ptr, key);
    }

    pub fn wake(self: TaskRuntime, key: usize, max_count: usize) usize {
        return self.vtable.wake(self.ptr, key, max_count);
    }

    pub fn runUntilDone(self: TaskRuntime, done: *const bool) void {
        self.vtable.run_until_done(self.ptr, done);
    }
};

/// Process-level control over scheduler-owned work.
///
/// The I/O backend owns handles and futures; the scheduler owns fibers. This
/// seam lets process kill close both sides without making the backend depend on
/// scheduler internals.
pub const ProcessTaskControl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        kill_process: *const fn (ptr: *anyopaque, process_id: ProcessId) void,
        task_active: *const fn (ptr: *const anyopaque, task_id: u64) bool,
    };

    pub fn killProcess(self: ProcessTaskControl, process_id: ProcessId) void {
        self.vtable.kill_process(self.ptr, process_id);
    }

    pub fn taskActive(self: ProcessTaskControl, task_id: u64) bool {
        return self.vtable.task_active(self.ptr, task_id);
    }
};

/// Harness-facing control over one simulation's cooperative task scheduler.
///
/// This is separate from `TaskRuntime`: application-facing `std.Io` uses the
/// runtime to spawn and await tasks, while `SimControl` uses this view to
/// inspect or drain the scheduler belonging to that specific simulation.
pub const TaskControl = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run_until_idle: *const fn (ptr: *anyopaque) anyerror!void,
        blocked_count: *const fn (ptr: *const anyopaque) usize,
    };

    pub fn runUntilIdle(self: TaskControl) !void {
        try self.vtable.run_until_idle(self.ptr);
    }

    pub fn blockedCount(self: TaskControl) usize {
        return self.vtable.blocked_count(self.ptr);
    }
};
