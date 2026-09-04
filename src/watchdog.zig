//! POSIX worker isolation and bounded execution-result transport.
const std = @import("std");
const builtin = @import("builtin");
const world_module = @import("world.zig");
const World = world_module.World;
const decision_module = @import("decision.zig");
const execution = @import("execution.zig");
const codec = @import("execution_codec.zig");
const types = @import("run_types.zig");
const RunOptions = types.RunOptions;
const WatchdogOptions = types.WatchdogOptions;
const RunFailureKind = types.RunFailureKind;
const RunOnceResult = execution.Result;
pub const Error = error{ InvalidWatchdogOptions, WatchdogUnavailable, WatchdogTraceTooLarge, OutOfMemory, InvalidTracePayload, InvalidSeedSchedule };
const RunError = Error;

pub const supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

const WatchdogStatus = enum(u8) {
    running,
    passed,
    failed,
    out_of_memory,
    invalid_trace,
    trace_too_large,
    result_too_large,
};

const WatchdogHeader = extern struct {
    done: std.atomic.Value(u8) = .init(0),
    progress: std.atomic.Value(u64) = .init(0),
    trace_len: std.atomic.Value(usize) = .init(0),
    event_count: std.atomic.Value(u64) = .init(0),
    task_running: std.atomic.Value(u8) = .init(0),
    task_id: std.atomic.Value(u64) = .init(0),
    trace_truncated: std.atomic.Value(u8) = .init(0),
    result_len: usize = 0,
    status: WatchdogStatus = .running,
};

const WatchdogShared = struct {
    mapping: []align(std.heap.page_size_min) u8,
    header: *WatchdogHeader,
    trace: []u8,
    result: []u8,

    fn init(options: WatchdogOptions) RunError!WatchdogShared {
        const trace_offset = std.mem.alignForward(usize, @sizeOf(WatchdogHeader), @alignOf(u64));
        const raw_len = std.math.add(usize, trace_offset, options.trace_capacity) catch
            return error.InvalidWatchdogOptions;
        const total_len = std.math.add(usize, raw_len, options.result_capacity) catch return error.InvalidWatchdogOptions;
        const page_size = std.heap.pageSize();
        const padded_len = std.math.add(usize, total_len, page_size - 1) catch
            return error.InvalidWatchdogOptions;
        const mapping_len = std.mem.alignBackward(usize, padded_len, page_size);
        const mapping = std.posix.mmap(
            null,
            mapping_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.WatchdogUnavailable;
        errdefer std.posix.munmap(mapping);

        const header: *WatchdogHeader = @ptrCast(@alignCast(mapping.ptr));
        header.* = .{};
        return .{
            .mapping = mapping,
            .header = header,
            .trace = mapping[trace_offset..raw_len],
            .result = mapping[raw_len..total_len],
        };
    }

    fn deinit(self: *WatchdogShared) void {
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }

    fn observer(self: *WatchdogShared) world_module.ExecutionObserver {
        return .{ .ptr = self, .vtable = &watchdog_observer_vtable };
    }

    fn publishTrace(raw: *anyopaque, trace: []const u8, event_count: u64, replace_from: usize) void {
        const self: *WatchdogShared = @ptrCast(@alignCast(raw));
        const copy_len = @min(trace.len, self.trace.len);
        const copy_from = @min(replace_from, copy_len);
        if (copy_len > copy_from) @memcpy(self.trace[copy_from..copy_len], trace[copy_from..copy_len]);
        if (trace.len > self.trace.len) self.header.trace_truncated.store(1, .release);
        self.header.event_count.store(event_count, .release);
        self.header.trace_len.store(copy_len, .release);
        _ = self.header.progress.fetchAdd(1, .release);
    }

    fn taskStart(raw: *anyopaque, task_id: u64) void {
        const self: *WatchdogShared = @ptrCast(@alignCast(raw));
        self.header.task_id.store(task_id, .release);
        self.header.task_running.store(1, .release);
        _ = self.header.progress.fetchAdd(1, .release);
    }

    fn taskStop(raw: *anyopaque, task_id: u64) void {
        const self: *WatchdogShared = @ptrCast(@alignCast(raw));
        std.debug.assert(self.header.task_id.load(.acquire) == task_id);
        self.header.task_running.store(0, .release);
        _ = self.header.progress.fetchAdd(1, .release);
    }

    fn publishResult(self: *WatchdogShared, result: RunOnceResult) void {
        if (self.header.trace_truncated.load(.acquire) != 0) {
            self.header.status = .trace_too_large;
            self.header.done.store(1, .release);
            return;
        }
        const encoded = codec.encode(result.allocator, &result) catch {
            self.publishRunError(error.OutOfMemory);
            return;
        };
        defer result.allocator.free(encoded);
        if (encoded.len > self.result.len) {
            self.header.status = .result_too_large;
        } else {
            @memcpy(self.result[0..encoded.len], encoded);
            self.header.result_len = encoded.len;
            self.header.status = .passed;
        }
        self.header.done.store(1, .release);
    }

    fn publishRunError(self: *WatchdogShared, err: RunError) void {
        self.header.status = switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.InvalidTracePayload => .invalid_trace,
            else => .result_too_large,
        };
        self.header.done.store(1, .release);
    }
};

const watchdog_observer_vtable: world_module.ExecutionObserver.VTable = .{
    .trace = WatchdogShared.publishTrace,
    .task_start = WatchdogShared.taskStart,
    .task_stop = WatchdogShared.taskStop,
};

pub fn run(
    allocator: std.mem.Allocator,
    options: RunOptions,
    simulate_options: World.SimulateOptions,
    comptime execute: anytype,
    watchdog: WatchdogOptions,
    decision_mode: decision_module.Mode,
) RunError!RunOnceResult {
    if (comptime !supported) return error.WatchdogUnavailable;

    var shared = try WatchdogShared.init(watchdog);
    defer shared.deinit();

    const pid = try forkWatchdogWorker();
    if (pid == 0) {
        var child_result = execute(
            allocator,
            options,
            simulate_options,
            shared.observer(),
            decision_mode,
        ) catch |err| {
            shared.publishRunError(err);
            exitWatchdogWorker();
        };
        shared.publishResult(child_result);
        child_result.deinit();
        exitWatchdogWorker();
    }

    const started_at = watchdogNowNs();
    var last_progress_at = started_at;
    var last_progress = shared.header.progress.load(.acquire);
    while (shared.header.done.load(.acquire) == 0) {
        // Reap an exited worker promptly; a crash is not a scheduler stall.
        if (watchdogWorkerExited(pid)) {
            if (shared.header.done.load(.acquire) != 0) return resultFromWatchdogShared(allocator, options, &shared);
            return watchdogFailureFromShared(allocator, options, &shared, .worker_crashed);
        }
        const now = watchdogNowNs();
        const progress = shared.header.progress.load(.acquire);
        if (progress != last_progress) {
            last_progress = progress;
            last_progress_at = now;
        }

        const stalled = now -| last_progress_at >= watchdog.stall_timeout_ns;
        const expired = now -| started_at >= watchdog.run_timeout_ns;
        const trace_full = shared.header.trace_truncated.load(.acquire) != 0;
        if (stalled or expired or trace_full) {
            killWatchdogWorker(pid);
            return watchdogFailureFromShared(
                allocator,
                options,
                &shared,
                if (stalled) .non_yielding else .livelock,
            );
        }

        std.Io.sleep(
            std.Options.debug_io,
            .fromMilliseconds(1),
            .awake,
        ) catch {};
    }

    waitWatchdogWorker(pid);
    return resultFromWatchdogShared(allocator, options, &shared);
}

fn forkWatchdogWorker() RunError!std.posix.pid_t {
    const rc = std.posix.system.fork();
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => error.WatchdogUnavailable,
    };
}

fn watchdogWorkerExited(pid: std.posix.pid_t) bool {
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
        var status: u32 = 0;
        const rc = std.os.linux.waitpid(pid, &status, std.posix.W.NOHANG);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => rc != 0,
            .CHILD => true,
            else => false,
        };
    } else {
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, std.posix.W.NOHANG);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => rc != 0,
            .CHILD => true,
            else => false,
        };
    }
}

fn waitWatchdogWorker(pid: std.posix.pid_t) void {
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
        var status: u32 = 0;
        while (true) {
            const rc = std.os.linux.waitpid(pid, &status, 0);
            switch (std.posix.errno(rc)) {
                .SUCCESS, .CHILD => return,
                .INTR => continue,
                else => return,
            }
        }
    } else {
        var status: c_int = 0;
        while (true) {
            const rc = std.c.waitpid(pid, &status, 0);
            switch (std.posix.errno(rc)) {
                .SUCCESS, .CHILD => return,
                .INTR => continue,
                else => return,
            }
        }
    }
}

fn exitWatchdogWorker() noreturn {
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
        std.os.linux.exit(0);
    } else {
        std.c._exit(0);
    }
}

fn killWatchdogWorker(pid: std.posix.pid_t) void {
    std.posix.kill(pid, .KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => {},
    };
    waitWatchdogWorker(pid);
}

fn watchdogNowNs() u64 {
    const timestamp = std.Io.Clock.awake.now(std.Options.debug_io).nanoseconds;
    return @intCast(@max(timestamp, 0));
}

fn resultFromWatchdogShared(
    allocator: std.mem.Allocator,
    options: RunOptions,
    shared: *const WatchdogShared,
) RunError!RunOnceResult {
    const header = shared.header;
    return switch (header.status) {
        .out_of_memory => error.OutOfMemory,
        .invalid_trace => error.InvalidTracePayload,
        .trace_too_large => watchdogFailureFromShared(allocator, options, shared, .livelock),
        .result_too_large => error.WatchdogTraceTooLarge,
        .running => error.WatchdogUnavailable,
        .passed, .failed => codec.decode(allocator, shared.result[0..header.result_len]) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.WatchdogUnavailable,
        },
    };
}

fn watchdogFailureFromShared(
    allocator: std.mem.Allocator,
    options: RunOptions,
    shared: *const WatchdogShared,
    kind: RunFailureKind,
) RunError!RunOnceResult {
    var prefix = shared.trace[0..shared.header.trace_len.load(.acquire)];
    if (shared.header.trace_truncated.load(.acquire) != 0) {
        if (std.mem.lastIndexOfScalar(u8, prefix, '\n')) |last_newline| {
            prefix = prefix[0 .. last_newline + 1];
        } else {
            prefix = &.{};
        }
    }
    const event_count = retainedTraceEventCount(prefix);
    const task_id = shared.header.task_id.load(.acquire);
    const task_running = shared.header.task_running.load(.acquire) != 0;
    const suffix = if ((kind == .non_yielding or kind == .worker_crashed) and !task_running)
        try std.fmt.allocPrint(
            allocator,
            "event={} watchdog.{s} task=main\n",
            .{ event_count, @tagName(kind) },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "event={} watchdog.{s} task={}\n",
            .{ event_count, @tagName(kind), task_id },
        );
    defer allocator.free(suffix);
    const trace = try std.mem.concat(allocator, u8, &.{ prefix, suffix });
    errdefer allocator.free(trace);
    _ = options;
    return .{
        .allocator = allocator,
        .trace = trace,
        .event_count = event_count + 1,
        .tape_complete = false,
        .outcome = .{ .failed = try (execution.Failure{
            .kind = kind,
            .error_name = switch (kind) {
                .non_yielding => "WatchdogStall",
                .worker_crashed => "WatchdogWorkerCrashed",
                else => "WatchdogTimeout",
            },
        }).clone(allocator) },
    };
}

pub fn retainedTraceEventCount(trace: []const u8) u64 {
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "event=")) count += 1;
    }
    return count;
}
