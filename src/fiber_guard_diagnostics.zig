//! Signal-level diagnostics for guarded fiber stack overflows.
//!
//! Guard pages make a fiber stack overflow fail fast, but the fault arrives
//! as a raw `SIGSEGV`/`SIGBUS` with no indication that a fiber stack was
//! involved, which task overflowed, or what to do about it. This module
//! registers each guarded fiber's guard region with task/process metadata
//! and installs a signal handler that recognizes faults landing inside a
//! registered guard, writes a targeted diagnostic to stderr, and then chains
//! to whatever handler was installed before (Zig's own Debug handler still
//! prints the fault-site trace). Faults outside every registered guard chain
//! straight through with no output, so non-fiber crashes keep their existing
//! behavior.
//!
//! Signal-handler discipline: the handler allocates nothing, takes no locks,
//! and touches only atomically published registry slots, a fixed stack
//! buffer, and `write(2)`. Registration and unregistration happen outside
//! the handler on ordinary control flow.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Mirrors the guard-page target set in `fiber.zig`. Windows would need a
/// vectored-exception-handler mechanism and has no guarded fiber stacks yet.
pub const supported = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

pub const GuardInfo = struct {
    task_id: u64,
    /// Simulation process that owns the task, or null for harness-owned
    /// tasks spawned outside any node.
    process_id: ?u64,
    /// The configured usable stack size, as passed by the creator; reported
    /// in the diagnostic so the fix (`task_stack_size`) has a baseline.
    stack_size: usize,
};

const Slot = struct {
    /// Guard region base address. 0 = free, 1 = reserved during publish;
    /// real addresses are page-aligned and never collide with either.
    guard_start: std.atomic.Value(usize) = .init(0),
    guard_len: usize = 0,
    info: GuardInfo = .{ .task_id = 0, .process_id = null, .stack_size = 0 },
};

const slot_free: usize = 0;
const slot_reserved: usize = 1;
const max_slots = 1024;

var slots: [max_slots]Slot = @splat(.{});

/// Registration overflow is silent by design: diagnostics degrade to the
/// previous raw-signal behavior rather than failing fiber creation.
pub fn register(guard: []const u8, info: GuardInfo) void {
    if (!supported) return;
    ensureInstalled();
    ensureAltStack();

    for (&slots) |*slot| {
        if (slot.guard_start.cmpxchgStrong(slot_free, slot_reserved, .acquire, .monotonic) != null) continue;
        slot.guard_len = guard.len;
        slot.info = info;
        slot.guard_start.store(@intFromPtr(guard.ptr), .release);
        return;
    }
}

pub fn unregister(guard: []const u8) void {
    if (!supported) return;
    const start = @intFromPtr(guard.ptr);
    for (&slots) |*slot| {
        if (slot.guard_start.load(.acquire) != start) continue;
        slot.guard_start.store(slot_free, .release);
        return;
    }
}

const InstallState = enum(u8) { uninstalled, installing, installed };
var install_state: std.atomic.Value(InstallState) = .init(.uninstalled);
var old_segv: posix.Sigaction = undefined;
var old_bus: posix.Sigaction = undefined;

fn ensureInstalled() void {
    if (install_state.load(.acquire) == .installed) return;
    if (install_state.cmpxchgStrong(.uninstalled, .installing, .acquire, .acquire) != null) {
        // Another thread won the install race; wait until the saved old
        // handlers are valid before publishing any guard region.
        while (install_state.load(.acquire) != .installed) std.atomic.spinLoopHint();
        return;
    }

    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = handleFault },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO | posix.SA.ONSTACK,
    };
    posix.sigaction(.SEGV, &act, &old_segv);
    posix.sigaction(.BUS, &act, &old_bus);
    install_state.store(.installed, .release);
}

/// The handler must run on an alternate stack: the faulting fiber's stack is
/// exhausted, so without one the handler itself faults and the process dies
/// with no output. `std.start`/`std.Thread` normally install a per-thread
/// alternate stack (`std.options.signal_stack_size`), but an embedder can
/// disable that, so verify per registering thread and provide a fallback.
threadlocal var alt_stack_checked = false;
threadlocal var fallback_alt_stack: [256 * 1024]u8 align(16) = undefined;

/// `SS.DISABLE` when the target's libc layer defines it; null where `SS`
/// is left `void` (DragonFly in Zig 0.16), in which case a disabled
/// alternate stack is detected by its zero size instead.
const ss_disable: ?comptime_int = blk: {
    const SS = posix.system.SS;
    if (@TypeOf(SS) != type) break :blk null;
    break :blk switch (@typeInfo(SS)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(SS, "DISABLE")) SS.DISABLE else null,
        else => null,
    };
};

fn altStackDisabled(current: posix.stack_t) bool {
    if (ss_disable) |disable| return current.flags & disable != 0;
    return current.size == 0;
}

fn ensureAltStack() void {
    if (alt_stack_checked) return;
    alt_stack_checked = true;

    var current: posix.stack_t = undefined;
    posix.sigaltstack(null, &current) catch return;
    if (!altStackDisabled(current)) return;

    posix.sigaltstack(&.{
        .sp = &fallback_alt_stack,
        .flags = 0,
        .size = fallback_alt_stack.len,
    }, null) catch {};
}

fn handleFault(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    if (faultAddress(sig, info)) |addr| {
        for (&slots) |*slot| {
            const start = slot.guard_start.load(.acquire);
            if (start <= slot_reserved) continue;
            if (addr < start or addr >= start + slot.guard_len) continue;
            writeDiagnostic(slot.info, addr);
            break;
        }
    }
    chain(sig, info, ctx);
}

/// Fault address extraction mirrors `std.debug.handleSegfaultPosix`.
fn faultAddress(sig: posix.SIG, info: *const posix.siginfo_t) ?usize {
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        // Non-canonical addresses fault without a usable si_addr.
        const SI_KERNEL = 0x80;
        if (sig == .SEGV and info.code == SI_KERNEL) return null;
    }
    return switch (builtin.os.tag) {
        .dragonfly, .freebsd, .macos => @intFromPtr(info.addr),
        .linux => @intFromPtr(info.fields.sigfault.addr),
        .netbsd => @intFromPtr(info.info.reason.fault.addr),
        .openbsd => @intFromPtr(info.data.fault.addr),
        .illumos => @intFromPtr(info.reason.fault.addr),
        else => null,
    };
}

fn writeDiagnostic(info: GuardInfo, addr: usize) void {
    var buffer: [512]u8 = undefined;
    const kib = (info.stack_size + 1023) / 1024;
    const message = blk: {
        if (info.process_id) |process_id| {
            break :blk std.fmt.bufPrint(
                &buffer,
                "marionette: fiber stack overflow: task {d} (process {d}) exceeded its {d} KiB stack " ++
                    "(fault addr 0x{x} in guard region); increase World.simulate(.task_stack_size)\n",
                .{ info.task_id, process_id, kib, addr },
            ) catch return;
        }
        break :blk std.fmt.bufPrint(
            &buffer,
            "marionette: fiber stack overflow: task {d} (process none) exceeded its {d} KiB stack " ++
                "(fault addr 0x{x} in guard region); increase World.simulate(.task_stack_size)\n",
            .{ info.task_id, kib, addr },
        ) catch return;
    };
    // Raw write(2): the only async-signal-safe way to reach stderr here.
    _ = posix.system.write(posix.STDERR_FILENO, message.ptr, message.len);
}

/// Conservative chaining: hand the fault to whatever was installed before
/// us. A default disposition is restored and re-triggered by returning; a
/// function handler is invoked directly so this handler stays installed.
fn chain(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) void {
    const old = switch (sig) {
        .SEGV => &old_segv,
        .BUS => &old_bus,
        else => return,
    };
    if (old.flags & posix.SA.SIGINFO != 0) {
        if (old.handler.sigaction) |old_action| {
            old_action(sig, info, ctx);
            return;
        }
    } else if (old.handler.handler) |old_handler| {
        if (old_handler == posix.SIG.IGN) return;
        if (old_handler != posix.SIG.DFL) {
            old_handler(sig);
            return;
        }
    }
    // Default (or absent) disposition: reinstall it and return; the faulting
    // instruction re-executes and the default action terminates the process.
    posix.sigaction(sig, old, null);
}
