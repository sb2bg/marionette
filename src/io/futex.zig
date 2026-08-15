//! Cooperative futex wait-set handle and `std.Io` futex operations.

const std = @import("std");
const Io = std.Io;

const wait_key_tag_bits = 3;

pub const WaitKeyError = error{WaitKeyPayloadOutOfRange};

pub const WaitKeyTag = enum(usize) {
    futex = 0,
    listener = 1,
    connection = 2,
    sleep = 3,
    /// Async task completion, keyed by scheduler task id.
    task = 4,
    /// Simulated disk operation completion deadline.
    disk = 5,
    /// `Io.Group` completion, keyed by backend-local group id.
    group = 6,
    /// Advisory file-lock availability, keyed by registry-local lock id.
    file_lock = 7,
};

pub const FutexWaitResult = enum {
    woken,
    timed_out,
    /// The wait was interrupted by a consumed cancellation request. Only
    /// cancelable waits resume with this result.
    canceled,
    /// The scheduler latched a terminal failure while the main context drove
    /// this wait. Task-side waits never produce this result.
    failed,
};

pub const FutexWaitSet = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        block: *const fn (ptr: *anyopaque, key: usize) void,
        block_until: *const fn (ptr: *anyopaque, key: usize, deadline_ns: ?u64) FutexWaitResult,
        /// Park as a cancellation point: an armed cancellation request is
        /// consumed and delivered as `.canceled`, either at entry or by
        /// interrupting the wait.
        block_until_cancelable: *const fn (ptr: *anyopaque, key: usize, deadline_ns: ?u64) FutexWaitResult,
        wake: *const fn (ptr: *anyopaque, key: usize, max_count: usize) usize,
    };

    pub fn block(self: FutexWaitSet, key: usize) void {
        self.vtable.block(self.ptr, key);
    }

    pub fn blockUntil(self: FutexWaitSet, key: usize, deadline_ns: ?u64) FutexWaitResult {
        return self.vtable.block_until(self.ptr, key, deadline_ns);
    }

    pub fn blockUntilCancelable(self: FutexWaitSet, key: usize, deadline_ns: ?u64) FutexWaitResult {
        return self.vtable.block_until_cancelable(self.ptr, key, deadline_ns);
    }

    pub fn wake(self: FutexWaitSet, key: usize, max_count: usize) usize {
        return self.vtable.wake(self.ptr, key, max_count);
    }
};

pub const max_wait_key_payload = std.math.maxInt(usize) >> wait_key_tag_bits;

pub fn waitKeyChecked(comptime tag: WaitKeyTag, id: usize) WaitKeyError!usize {
    if (id > max_wait_key_payload) return error.WaitKeyPayloadOutOfRange;
    return (id << wait_key_tag_bits) | @intFromEnum(tag);
}

pub fn waitKey(comptime tag: WaitKeyTag, id: usize) usize {
    return waitKeyChecked(tag, id) catch std.debug.panic(
        "wait-key payload {} for tag {s} exceeds maximum {}",
        .{ id, @tagName(tag), max_wait_key_payload },
    );
}

/// Sleep-tagged task-start and connect-probe waits are both timer-shaped, but
/// probes can also be explicitly woken when a harness clears a clog early.
/// Keep them in disjoint even/odd payload subspaces so a probe wake cannot
/// accidentally start a jittered task before its deadline.
pub fn taskStartWaitKeyChecked(task_id: u64) WaitKeyError!usize {
    const narrowed = std.math.cast(usize, task_id) orelse
        return error.WaitKeyPayloadOutOfRange;
    const doubled = std.math.mul(usize, narrowed, 2) catch
        return error.WaitKeyPayloadOutOfRange;
    const payload = std.math.add(usize, doubled, 2) catch
        return error.WaitKeyPayloadOutOfRange;
    return waitKeyChecked(.sleep, payload);
}

pub fn taskStartWaitKey(task_id: u64) usize {
    return taskStartWaitKeyChecked(task_id) catch std.debug.panic(
        "task id {} exceeds tagged wait-key capacity",
        .{task_id},
    );
}

pub fn connectProbeWaitKeyChecked(packet_id: u64) WaitKeyError!usize {
    const narrowed = std.math.cast(usize, packet_id) orelse
        return error.WaitKeyPayloadOutOfRange;
    const doubled = std.math.mul(usize, narrowed, 2) catch
        return error.WaitKeyPayloadOutOfRange;
    const payload = std.math.add(usize, doubled, 1) catch
        return error.WaitKeyPayloadOutOfRange;
    return waitKeyChecked(.sleep, payload);
}

pub fn connectProbeWaitKey(packet_id: u64) usize {
    return connectProbeWaitKeyChecked(packet_id) catch std.debug.panic(
        "packet id {} exceeds tagged wait-key capacity",
        .{packet_id},
    );
}

/// World-global wait key for stream writers parked on backpressure. The
/// byte pool and path queues are shared resources, so a writer blocked
/// because another connection filled them must be woken by any drain or
/// any connection teardown, not only by its own peer. All backends in a
/// world share one scheduler wait set, and socket handles start at 1000,
/// so the connection-tagged key for handle 0 can never collide with a
/// real connection.
pub const stream_backpressure_wait_key = waitKey(.connection, 0);

test "tagged wait keys preserve the maximum payload and reject the first invalid payload" {
    try std.testing.expectEqual(
        std.math.maxInt(usize),
        try waitKeyChecked(.file_lock, max_wait_key_payload),
    );
    try std.testing.expectError(
        error.WaitKeyPayloadOutOfRange,
        waitKeyChecked(.file_lock, max_wait_key_payload + 1),
    );
}

test "task-start and connect-probe wait keys are bounded and disjoint" {
    const max_task_id: u64 = @intCast((max_wait_key_payload - 2) / 2);
    const max_probe_id: u64 = @intCast((max_wait_key_payload - 1) / 2);

    const max_task_key = try taskStartWaitKeyChecked(max_task_id);
    const max_probe_key = try connectProbeWaitKeyChecked(max_probe_id);
    try std.testing.expect(max_task_key != max_probe_key);
    try std.testing.expect(taskStartWaitKey(0) != connectProbeWaitKey(0));
    try std.testing.expectError(
        error.WaitKeyPayloadOutOfRange,
        taskStartWaitKeyChecked(max_task_id + 1),
    );
    try std.testing.expectError(
        error.WaitKeyPayloadOutOfRange,
        connectProbeWaitKeyChecked(max_probe_id + 1),
    );
}

pub fn Ops(comptime Backend: type) type {
    return struct {
        fn backendFromUserdata(userdata: ?*anyopaque) *Backend {
            return @ptrCast(@alignCast(userdata.?));
        }

        fn supportsClock(clock: Io.Clock) bool {
            return switch (clock) {
                .real, .awake, .boot => true,
                .cpu_process, .cpu_thread => false,
            };
        }

        pub fn simFutexWait(
            userdata: ?*anyopaque,
            ptr: *const u32,
            expected: u32,
            timeout: Io.Timeout,
        ) Io.Cancelable!void {
            const backend = backendFromUserdata(userdata);
            if (!backend.processIsAlive()) return error.Canceled;
            // A cancellation point delivers an armed request even when the
            // wait would otherwise complete without parking.
            if (backend.task_runtime) |runtime| {
                if (runtime.takeCancelRequest()) return error.Canceled;
            }
            if (@atomicLoad(u32, ptr, .monotonic) != expected) return;
            const deadline_ns = simFutexDeadline(backend, timeout);
            if (deadline_ns != null and deadline_ns.? <= backend.world.now()) return;

            // Cooperative atomicity: no task can run between this value check
            // and the park unless this function yields.
            const wait_set = backend.futex_wait_set orelse @panic("sim futex wait requires an attached scheduler");
            const key = backend.beginFutexWait(ptr);
            defer backend.endFutexWait(ptr);
            switch (wait_set.blockUntilCancelable(key, deadline_ns)) {
                .woken => {},
                .timed_out => {},
                .canceled => return error.Canceled,
                .failed => return error.Canceled,
            }
        }

        fn simFutexDeadline(backend: *Backend, timeout: Io.Timeout) ?u64 {
            return switch (timeout) {
                .none => null,
                .duration => |duration| {
                    if (!supportsClock(duration.clock)) return null;
                    if (duration.raw.nanoseconds <= 0) return backend.world.now();

                    const now = backend.world.now();
                    const delta: u64 = std.math.cast(u64, duration.raw.nanoseconds) orelse return null;
                    if (std.math.maxInt(u64) - now < delta) return null;
                    return now + delta;
                },
                .deadline => |deadline| {
                    if (!supportsClock(deadline.clock)) return null;
                    return std.math.cast(u64, deadline.raw.nanoseconds) orelse backend.world.now();
                },
            };
        }

        pub fn simFutexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
            const backend = backendFromUserdata(userdata);
            if (!backend.processIsAlive()) return;
            if (@atomicLoad(u32, ptr, .monotonic) != expected) return;

            const wait_set = backend.futex_wait_set orelse @panic("sim futex wait requires an attached scheduler");
            const key = backend.beginFutexWait(ptr);
            defer backend.endFutexWait(ptr);
            switch (wait_set.blockUntil(key, null)) {
                .woken => {},
                .timed_out => {},
                .canceled => unreachable,
                .failed => return,
            }
        }

        pub fn simFutexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
            if (max_waiters == 0) return;
            const backend = backendFromUserdata(userdata);
            if (!backend.processIsAlive()) return;
            const wait_set = backend.futex_wait_set orelse return;
            const key = backend.futexWakeKey(ptr) orelse return;
            _ = wait_set.wake(key, max_waiters);
        }
    };
}
