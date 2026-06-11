//! Type-erased cooperative task runtime seam for the `std.Io` backend.
//!
//! The backend implements `Io.async`/`Io.concurrent`/`Io.await` against this
//! interface so the scheduler can depend on the io module without a cycle.
//! `TaskScheduler.taskRuntime` provides the deterministic implementation.

pub const TaskRuntime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const SpawnError = error{ConcurrencyUnavailable};

    pub const VTable = struct {
        /// Spawn a cooperative task running `entry(arg)`. Returns a stable
        /// task id usable as a wait-key payload.
        spawn: *const fn (ptr: *anyopaque, entry: *const fn (*anyopaque) void, arg: *anyopaque) SpawnError!u64,
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
        return self.vtable.spawn(self.ptr, entry, arg);
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
