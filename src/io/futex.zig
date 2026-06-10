//! Cooperative futex wait-set handle and `std.Io` futex operations.

const std = @import("std");
const Io = std.Io;

const wait_key_tag_bits = 2;

pub const WaitKeyTag = enum(usize) {
    futex = 0,
    listener = 1,
    connection = 2,
};

pub const FutexWaitResult = enum {
    woken,
    timed_out,
};

pub const FutexWaitSet = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        block: *const fn (ptr: *anyopaque, key: usize) void,
        block_until: *const fn (ptr: *anyopaque, key: usize, deadline_ns: ?u64) FutexWaitResult,
        wake: *const fn (ptr: *anyopaque, key: usize, max_count: usize) usize,
    };

    pub fn block(self: FutexWaitSet, key: usize) void {
        self.vtable.block(self.ptr, key);
    }

    pub fn blockUntil(self: FutexWaitSet, key: usize, deadline_ns: ?u64) FutexWaitResult {
        return self.vtable.block_until(self.ptr, key, deadline_ns);
    }

    pub fn wake(self: FutexWaitSet, key: usize, max_count: usize) usize {
        return self.vtable.wake(self.ptr, key, max_count);
    }
};

pub fn waitKey(comptime tag: WaitKeyTag, id: usize) usize {
    return (id << wait_key_tag_bits) | @intFromEnum(tag);
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
            if (@atomicLoad(u32, ptr, .monotonic) != expected) return;
            const deadline_ns = simFutexDeadline(backend, timeout);
            if (deadline_ns != null and deadline_ns.? <= backend.world.now()) return;

            // Cooperative atomicity: no task can run between this value check
            // and the park unless this function yields.
            const wait_set = backend.futex_wait_set orelse @panic("sim futex wait requires an attached scheduler");
            switch (wait_set.blockUntil(backend.futexKey(ptr), deadline_ns)) {
                .woken => {},
                .timed_out => {},
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
            simFutexWait(userdata, ptr, expected, .none) catch |err| switch (err) {
                error.Canceled => unreachable,
            };
        }

        pub fn simFutexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
            if (max_waiters == 0) return;
            const backend = backendFromUserdata(userdata);
            const wait_set = backend.futex_wait_set orelse return;
            _ = wait_set.wake(backend.futexKey(ptr), max_waiters);
        }
    };
}
