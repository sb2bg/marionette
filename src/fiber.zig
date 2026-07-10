//! Thin fiber primitive seam for Marionette's deterministic scheduler.
//!
//! This wraps Zig's bare `std.Io.fiber` context switch without depending on
//! `std.Io.Evented`/Dispatch/Uring. The scheduler owns policy; this file only
//! owns stack setup, context switching, and teardown.

const std = @import("std");
const builtin = @import("builtin");

const guard_diagnostics = @import("fiber_guard_diagnostics.zig");
const std_fiber = std.Io.fiber;

/// Win64 uses `rcx` for the first argument, while the current x86_64 entry
/// trampoline is SysV-only. Keep the target compileable but fail closed until
/// a Windows trampoline has execution coverage.
pub const supported = std_fiber.supported and
    !(builtin.os.tag == .windows and builtin.cpu.arch == .x86_64);
pub const Context = std_fiber.Context;
pub const Switch = std_fiber.Switch;

pub const default_stack_size = 64 * 1024;
pub const stack_alignment = 16;

/// Whether fiber stacks come from mmap with a PROT_NONE guard region below
/// the usable region. An overflow then faults at the offending write
/// instead of corrupting adjacent heap and masquerading as nondeterminism.
/// Stacks on these targets bypass the user-passed allocator; this is a
/// deliberate, documented exception to allocator discipline.
const use_guard_pages = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

/// Minimum guard region below each fiber stack, rounded up to the page size.
///
/// A single page is not enough: one stack-frame adjustment larger than the
/// page (easy to hit in Debug builds with large locals) steps straight over
/// it and corrupts whatever is mapped below, which then presents as heap
/// corruption or nondeterminism far from the overflow. The region is
/// PROT_NONE and never committed, so widening it costs address space only.
/// A frame larger than the whole region can still escape; 256 KiB makes that
/// require a quarter-megabyte local, which is a deliberate act.
const guard_region_size = 256 * 1024;

fn guardLength() usize {
    return std.mem.alignForward(usize, guard_region_size, std.heap.pageSize());
}

/// Sentinel written at the low end of every fiber stack, checked by the
/// scheduler after every switch. Best-effort diagnostics only: it catches
/// overflows that write contiguously through the low end (deep call chains,
/// buffer overruns), but a single large stack-frame adjustment can jump past
/// the canary and write outside the allocation without touching it.
/// Dependable detection needs guard pages (mmap + mprotect); the canary is
/// the portable fallback that works with plain allocator memory.
const stack_canary: u64 = 0x5AFE_57AC_CA4A_111E;
const stack_canary_size = @sizeOf(u64);

/// Bytes reserved below the start closure for the zeroed sentinel root
/// frame that terminates stack unwinding. See `placeClosure`.
const sentinel_frame_size = 2 * @sizeOf(usize);

pub const Error = error{
    FiberUnsupported,
    StackTooSmall,
} || std.mem.Allocator.Error;

pub const Entry = *const fn (arg: *anyopaque) void;

pub const CreateOptions = struct {
    stack_size: usize = default_stack_size,
    finish_context: *Context,
    entry: Entry,
    arg: *anyopaque,
    /// When set on guard-page targets, the fiber's guard region is
    /// registered with the overflow-diagnostics signal handler under this
    /// identity, so an overflow fault names the task instead of presenting
    /// as a raw segfault. No effect on targets without guard pages.
    diagnostic: ?Diagnostic = null,
};

pub const Diagnostic = struct {
    task_id: u64,
    process_id: ?u64,
};

pub const Fiber = struct {
    allocator: std.mem.Allocator,
    memory: Memory,
    context: Context,
    closure: *StartClosure,
    finished: bool = false,

    const Memory = union(enum) {
        /// mmap'd region laid out as [guard region][usable stack].
        mapped: []align(std.heap.page_size_min) u8,
        /// Plain allocation with canary-only protection.
        heap: []align(stack_alignment) u8,
    };

    pub fn create(allocator: std.mem.Allocator, options: CreateOptions) Error!*Fiber {
        if (!supported) return error.FiberUnsupported;
        if (options.stack_size < @sizeOf(StartClosure) + stack_alignment + stack_canary_size + sentinel_frame_size) {
            return error.StackTooSmall;
        }

        const self = try allocator.create(Fiber);
        errdefer allocator.destroy(self);

        const memory: Memory = if (use_guard_pages) memory: {
            const page_size = std.heap.pageSize();
            const usable_len = std.mem.alignForward(usize, options.stack_size, page_size);
            const guard_len = guardLength();
            const mapping = std.posix.mmap(
                null,
                usable_len + guard_len,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            ) catch return error.OutOfMemory;
            errdefer std.posix.munmap(mapping);
            // std.posix has no mprotect wrapper, so replace the lowest pages
            // with an inaccessible mapping via MAP_FIXED to form the guard.
            _ = std.posix.mmap(
                @alignCast(mapping.ptr),
                guard_len,
                .{},
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
                -1,
                0,
            ) catch return error.OutOfMemory;
            break :memory .{ .mapped = mapping };
        } else .{
            .heap = try allocator.alignedAlloc(u8, .fromByteUnits(stack_alignment), options.stack_size),
        };

        self.* = .{
            .allocator = allocator,
            .memory = memory,
            .context = undefined,
            .closure = undefined,
        };

        const stack = self.usableStack();
        std.mem.writeInt(u64, stack[0..stack_canary_size], stack_canary, .little);

        const closure = placeClosure(stack);
        self.closure = closure;
        closure.* = .{
            .self_context = &self.context,
            .finish_context = options.finish_context,
            .entry = options.entry,
            .arg = options.arg,
            .finished = &self.finished,
        };
        self.context = initContext(closure);

        if (use_guard_pages) {
            if (options.diagnostic) |diagnostic| {
                switch (self.memory) {
                    .mapped => |mapping| guard_diagnostics.register(mapping[0..guardLength()], .{
                        .task_id = diagnostic.task_id,
                        .process_id = diagnostic.process_id,
                        .stack_size = options.stack_size,
                    }),
                    .heap => {},
                }
            }
        }

        return self;
    }

    pub fn destroy(self: *Fiber) void {
        const allocator = self.allocator;
        switch (self.memory) {
            // The comptime branch keeps std.posix out of analysis on
            // targets without guard pages; the arm itself still exists
            // because the union does.
            .mapped => |mapping| if (use_guard_pages) {
                guard_diagnostics.unregister(mapping[0..guardLength()]);
                std.posix.munmap(mapping);
            } else unreachable,
            .heap => |stack| allocator.free(stack),
        }
        allocator.destroy(self);
    }

    pub fn contextPtr(self: *Fiber) *Context {
        return &self.context;
    }

    pub fn isFinished(self: *const Fiber) bool {
        return self.finished;
    }

    /// Whether the low-end stack sentinel is intact. False means the fiber
    /// overflowed its stack at some point since creation.
    pub fn canaryIntact(self: *const Fiber) bool {
        return std.mem.readInt(u64, self.usableStack()[0..stack_canary_size], .little) == stack_canary;
    }

    fn usableStack(self: *const Fiber) []align(stack_alignment) u8 {
        return switch (self.memory) {
            .mapped => |mapping| @alignCast(mapping[guardLength()..]),
            .heap => |stack| stack,
        };
    }
};

pub inline fn switchTo(current: *Context, next: *Context) void {
    var message: Switch = .{
        .old = current,
        .new = next,
    };
    _ = contextSwitch(&message);
}

pub inline fn contextSwitch(message: *const Switch) *const Switch {
    return correctedContextSwitch(message);
}

/// Local copy of `std.Io.fiber.contextSwitch` with three corrections, all
/// load-bearing for ReleaseSafe:
///
/// 1. Corrected asm constraints. The std version lists the message
///    register (aarch64 `x1`, x86_64 `rsi`, riscv64 `a1`) as an input, an
///    output, AND a clobber. Declaring an input/output register as a
///    clobber is ill-formed asm; under register pressure LLVM silently
///    drops the copy of the input into that register and the switch
///    dereferences caller garbage. The clobber lists below are std's
///    minus the message register, plus the condition-flags register on
///    aarch64 (std's x86_64 variant clobbers rflags; its aarch64 variant
///    omits nzcv).
///
/// 2. `noinline`. The asm resumes at a local label that other executions
///    re-enter (setjmp-like returns-twice control flow the optimizer does
///    not model). Inlined into a caller loop, LLVM has been observed to
///    fold the loop's exit condition into a constant, spinning forever.
///    Keeping the label inside this dedicated function makes every switch
///    a plain call from the caller's point of view.
///
/// 3. Complete LLVM clobber coverage. On x86_64, LLVM does not always treat
///    `zmmN` as clobbering its `ymmN` and `xmmN` aliases when the target CPU
///    lacks the wider register classes, so all three widths are explicit.
///    On aarch64, `x18` is allocatable on targets such as Linux and must be
///    invalidated across a switch, but it must stay out of the clobber list
///    on Android, Darwin, Fuchsia, Windows, and OpenHarmony, where LLVM
///    reserves it as a platform register by default.
///
/// Remove this copy once fixes land upstream in `std.Io.fiber`.
noinline fn correctedContextSwitch(s: *const Switch) *const Switch {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ ldp x0, x2, [x1]
            \\ ldr x3, [x2, #16]
            \\ mov x4, sp
            \\ stp x4, fp, [x0]
            \\ adr x5, 0f
            \\ ldp x4, fp, [x2]
            \\ str x5, [x0, #16]
            \\ mov sp, x4
            \\ br x3
            \\0:
            : [received_message] "={x1}" (-> *const Switch),
            : [message_to_send] "{x1}" (s),
            : .{
              .x0 = true,
              .x2 = true,
              .x3 = true,
              .x4 = true,
              .x5 = true,
              .x6 = true,
              .x7 = true,
              .x8 = true,
              .x9 = true,
              .x10 = true,
              .x11 = true,
              .x12 = true,
              .x13 = true,
              .x14 = true,
              .x15 = true,
              .x16 = true,
              .x17 = true,
              .x18 = !(builtin.abi.isAndroid() or
                builtin.abi.isOpenHarmony() or
                builtin.os.tag.isDarwin() or
                builtin.os.tag == .fuchsia or
                builtin.os.tag == .windows),
              .x19 = true,
              .x20 = true,
              .x21 = true,
              .x22 = true,
              .x23 = true,
              .x24 = true,
              .x25 = true,
              .x26 = true,
              .x27 = true,
              .x28 = true,
              .x30 = true,
              .z0 = true,
              .z1 = true,
              .z2 = true,
              .z3 = true,
              .z4 = true,
              .z5 = true,
              .z6 = true,
              .z7 = true,
              .z8 = true,
              .z9 = true,
              .z10 = true,
              .z11 = true,
              .z12 = true,
              .z13 = true,
              .z14 = true,
              .z15 = true,
              .z16 = true,
              .z17 = true,
              .z18 = true,
              .z19 = true,
              .z20 = true,
              .z21 = true,
              .z22 = true,
              .z23 = true,
              .z24 = true,
              .z25 = true,
              .z26 = true,
              .z27 = true,
              .z28 = true,
              .z29 = true,
              .z30 = true,
              .z31 = true,
              .p0 = true,
              .p1 = true,
              .p2 = true,
              .p3 = true,
              .p4 = true,
              .p5 = true,
              .p6 = true,
              .p7 = true,
              .p8 = true,
              .p9 = true,
              .p10 = true,
              .p11 = true,
              .p12 = true,
              .p13 = true,
              .p14 = true,
              .p15 = true,
              .fpcr = true,
              .fpsr = true,
              .ffr = true,
              .nzcv = true,
              .memory = true,
            }),
        .riscv64 => asm volatile (
            \\ ld a0, 0(a1)
            \\ ld a2, 8(a1)
            \\ lla a3, 0f
            \\ sd sp, 0(a0)
            \\ sd fp, 8(a0)
            \\ sd a3, 16(a0)
            \\ ld sp, 0(a2)
            \\ ld fp, 8(a2)
            \\ ld a3, 16(a2)
            \\ jr a3
            \\0:
            : [received_message] "={a1}" (-> *const Switch),
            : [message_to_send] "{a1}" (s),
            : .{
              .x1 = true,
              .x3 = true,
              .x4 = true,
              .x5 = true,
              .x6 = true,
              .x7 = true,
              .x9 = true,
              .x10 = true,
              .x12 = true,
              .x13 = true,
              .x14 = true,
              .x15 = true,
              .x16 = true,
              .x17 = true,
              .x18 = true,
              .x19 = true,
              .x20 = true,
              .x21 = true,
              .x22 = true,
              .x23 = true,
              .x24 = true,
              .x25 = true,
              .x26 = true,
              .x27 = true,
              .x28 = true,
              .x29 = true,
              .x30 = true,
              .x31 = true,
              .f0 = true,
              .f1 = true,
              .f2 = true,
              .f3 = true,
              .f4 = true,
              .f5 = true,
              .f6 = true,
              .f7 = true,
              .f8 = true,
              .f9 = true,
              .f10 = true,
              .f11 = true,
              .f12 = true,
              .f13 = true,
              .f14 = true,
              .f15 = true,
              .f16 = true,
              .f17 = true,
              .f18 = true,
              .f19 = true,
              .f20 = true,
              .f21 = true,
              .f22 = true,
              .f23 = true,
              .f24 = true,
              .f25 = true,
              .f26 = true,
              .f27 = true,
              .f28 = true,
              .f29 = true,
              .f30 = true,
              .f31 = true,
              .v0 = true,
              .v1 = true,
              .v2 = true,
              .v3 = true,
              .v4 = true,
              .v5 = true,
              .v6 = true,
              .v7 = true,
              .v8 = true,
              .v9 = true,
              .v10 = true,
              .v11 = true,
              .v12 = true,
              .v13 = true,
              .v14 = true,
              .v15 = true,
              .v16 = true,
              .v17 = true,
              .v18 = true,
              .v19 = true,
              .v20 = true,
              .v21 = true,
              .v22 = true,
              .v23 = true,
              .v24 = true,
              .v25 = true,
              .v26 = true,
              .v27 = true,
              .v28 = true,
              .v29 = true,
              .v30 = true,
              .v31 = true,
              .vtype = true,
              .vl = true,
              .vxsat = true,
              .vxrm = true,
              .vcsr = true,
              .fflags = true,
              .frm = true,
              .memory = true,
            }),
        .x86_64 => asm volatile (
            \\ movq 0(%%rsi), %%rax
            \\ movq 8(%%rsi), %%rcx
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\0:
            : [received_message] "={rsi}" (-> *const Switch),
            : [message_to_send] "{rsi}" (s),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rbx = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = true,
              .r14 = true,
              .r15 = true,
              .mm0 = true,
              .mm1 = true,
              .mm2 = true,
              .mm3 = true,
              .mm4 = true,
              .mm5 = true,
              .mm6 = true,
              .mm7 = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .ymm0 = true,
              .ymm1 = true,
              .ymm2 = true,
              .ymm3 = true,
              .ymm4 = true,
              .ymm5 = true,
              .ymm6 = true,
              .ymm7 = true,
              .ymm8 = true,
              .ymm9 = true,
              .ymm10 = true,
              .ymm11 = true,
              .ymm12 = true,
              .ymm13 = true,
              .ymm14 = true,
              .ymm15 = true,
              .ymm16 = true,
              .ymm17 = true,
              .ymm18 = true,
              .ymm19 = true,
              .ymm20 = true,
              .ymm21 = true,
              .ymm22 = true,
              .ymm23 = true,
              .ymm24 = true,
              .ymm25 = true,
              .ymm26 = true,
              .ymm27 = true,
              .ymm28 = true,
              .ymm29 = true,
              .ymm30 = true,
              .ymm31 = true,
              .xmm0 = true,
              .xmm1 = true,
              .xmm2 = true,
              .xmm3 = true,
              .xmm4 = true,
              .xmm5 = true,
              .xmm6 = true,
              .xmm7 = true,
              .xmm8 = true,
              .xmm9 = true,
              .xmm10 = true,
              .xmm11 = true,
              .xmm12 = true,
              .xmm13 = true,
              .xmm14 = true,
              .xmm15 = true,
              .xmm16 = true,
              .xmm17 = true,
              .xmm18 = true,
              .xmm19 = true,
              .xmm20 = true,
              .xmm21 = true,
              .xmm22 = true,
              .xmm23 = true,
              .xmm24 = true,
              .xmm25 = true,
              .xmm26 = true,
              .xmm27 = true,
              .xmm28 = true,
              .xmm29 = true,
              .xmm30 = true,
              .xmm31 = true,
              .fpsr = true,
              .fpcr = true,
              .mxcsr = true,
              .rflags = true,
              .dirflag = true,
              .memory = true,
            }),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    };
}

/// Recovers the parent message sent by the resumed context. Use this only when
/// that context will switch back with the same message envelope type.
pub inline fn contextSwitchMessage(comptime Message: type, message: *const Message) *const Message {
    return @fieldParentPtr("contexts", contextSwitch(&message.contexts));
}

const StartClosure = struct {
    self_context: *Context,
    finish_context: *Context,
    entry: Entry,
    arg: *anyopaque,
    finished: *bool,
};

fn placeClosure(stack: []align(stack_alignment) u8) *StartClosure {
    const address = std.mem.alignBackward(
        usize,
        @intFromPtr(stack.ptr) + stack.len - @sizeOf(StartClosure),
        stack_alignment,
    );
    const closure: *StartClosure = @ptrFromInt(address);

    // Sentinel root frame. Stack unwinders (the testing allocator captures a
    // trace on every alloc/free) walk past `entryCall` and restore its
    // caller's state from these slots; they were previously uninitialized
    // stack bytes, so the unwinder dereferenced garbage and crashed. A zero
    // return address / frame pointer is the conventional end-of-stack
    // marker. On x86_64 the slot directly below the closure is the entry
    // function's return address; on aarch64/riscv64 termination also relies
    // on the trampoline zeroing the link register before entering.
    const sentinel: *[2]usize = @ptrFromInt(address - 2 * @sizeOf(usize));
    sentinel.* = .{ 0, 0 };

    return closure;
}

fn initContext(closure: *StartClosure) Context {
    const closure_address = @intFromPtr(closure);
    return switch (builtin.cpu.arch) {
        .aarch64 => .{
            .sp = closure_address,
            .fp = 0,
            .pc = @intFromPtr(&entryTrampoline),
        },
        .riscv64 => .{
            .sp = closure_address,
            .fp = 0,
            .pc = @intFromPtr(&entryTrampoline),
        },
        .x86_64 => .{
            .rsp = closure_address - 8,
            .rbp = 0,
            .rip = @intFromPtr(&entryTrampoline),
        },
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    };
}

fn entryTrampoline() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        // The link register holds whatever the previous context left there;
        // zero it so the entry function's frame record terminates unwinding
        // instead of pointing at a stale code address.
        .aarch64 => asm volatile (
            \\ mov x30, xzr
            \\ mov x0, sp
            \\ b %[call]
            :
            : [call] "X" (&entryCall),
        ),
        .riscv64 => asm volatile (
            \\ mv ra, zero
            \\ mv a0, sp
            \\ j %[call]
            :
            : [call] "X" (&entryCall),
        ),
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rdi
            \\ jmp %[call:P]
            :
            : [call] "X" (&entryCall),
        ),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    }
}

fn entryCall(closure: *StartClosure, _: *const Switch) callconv(.withStackAlign(.c, @alignOf(StartClosure))) noreturn {
    const entry = closure.entry;
    const arg = closure.arg;
    const finished = closure.finished;
    const self_context = closure.self_context;
    const finish_context = closure.finish_context;

    entry(arg);
    finished.* = true;
    switchTo(self_context, finish_context);
    unreachable;
}

test "fiber: switches, resumes, and returns to finish context" {
    if (!supported) return error.SkipZigTest;

    const State = struct {
        main: Context = undefined,
        fiber: *Fiber = undefined,
        events: std.ArrayList(u8) = .empty,

        fn push(self: *@This(), byte: u8) void {
            self.events.append(std.testing.allocator, byte) catch @panic("append failed");
        }

        fn run(arg: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(arg));
            self.push('a');
            switchTo(self.fiber.contextPtr(), &self.main);
            self.push('c');
            switchTo(self.fiber.contextPtr(), &self.main);
            self.push('e');
        }
    };

    var state: State = .{};
    defer state.events.deinit(std.testing.allocator);
    state.fiber = try Fiber.create(std.testing.allocator, .{
        .finish_context = &state.main,
        .entry = State.run,
        .arg = &state,
    });
    defer state.fiber.destroy();

    state.push('0');
    switchTo(&state.main, state.fiber.contextPtr());
    state.push('b');
    switchTo(&state.main, state.fiber.contextPtr());
    state.push('d');
    switchTo(&state.main, state.fiber.contextPtr());
    state.push('f');

    try std.testing.expect(state.fiber.isFinished());
    try std.testing.expectEqualStrings("0abcdef", state.events.items);
}

test "fiber: stack canary detects overflow writes" {
    if (!supported) return error.SkipZigTest;

    var finish_context: Context = undefined;
    const Noop = struct {
        fn run(_: *anyopaque) void {}
    };

    const fiber_instance = try Fiber.create(std.testing.allocator, .{
        .finish_context = &finish_context,
        .entry = Noop.run,
        .arg = undefined,
    });
    defer fiber_instance.destroy();

    try std.testing.expect(fiber_instance.canaryIntact());
    fiber_instance.usableStack()[0] = 0;
    try std.testing.expect(!fiber_instance.canaryIntact());
}

test "fiber: rejects undersized stacks" {
    if (!supported) return error.SkipZigTest;

    var finish_context: Context = undefined;
    const Noop = struct {
        fn run(_: *anyopaque) void {}
    };

    try std.testing.expectError(error.StackTooSmall, Fiber.create(std.testing.allocator, .{
        .stack_size = @sizeOf(StartClosure),
        .finish_context = &finish_context,
        .entry = Noop.run,
        .arg = undefined,
    }));
}

test "fiber: custom switch messages survive optimized yields" {
    if (!supported) return error.SkipZigTest;

    const yielded: u8 = 1;

    const Message = extern struct {
        contexts: Switch,
        task: *anyopaque,
        reason: u8,
    };

    const Task = struct {
        main: Context = undefined,
        fiber: *Fiber = undefined,
        yield_message: Message = undefined,
        remaining: u8 = 4,
        observed: u8 = 0,

        fn run(arg: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(arg));
            while (self.remaining > 0) {
                self.remaining -= 1;
                self.observed += 1;
                self.yield_message = .{
                    .contexts = .{
                        .old = self.fiber.contextPtr(),
                        .new = &self.main,
                    },
                    .task = self,
                    .reason = yielded,
                };
                _ = contextSwitch(&self.yield_message.contexts);
            }
        }
    };

    const task = try std.testing.allocator.create(Task);
    defer std.testing.allocator.destroy(task);
    task.* = .{};

    task.fiber = try Fiber.create(std.testing.allocator, .{
        .finish_context = &task.main,
        .entry = Task.run,
        .arg = task,
    });
    defer task.fiber.destroy();

    while (task.remaining > 0) {
        var message: Message = .{
            .contexts = .{
                .old = &task.main,
                .new = task.fiber.contextPtr(),
            },
            .task = task,
            .reason = yielded,
        };
        const returned = contextSwitchMessage(Message, &message);
        try std.testing.expectEqual(@as(*anyopaque, @ptrCast(task)), returned.task);
        try std.testing.expectEqual(yielded, returned.reason);
    }

    try std.testing.expectEqual(@as(u8, 4), task.observed);
}
