//! Thin fiber primitive seam for Marionette's deterministic scheduler.
//!
//! This wraps Zig's bare `std.Io.fiber` context switch without depending on
//! `std.Io.Evented`/Dispatch/Uring. The scheduler owns policy; this file only
//! owns stack setup, context switching, and teardown.

const std = @import("std");
const builtin = @import("builtin");

const std_fiber = std.Io.fiber;

pub const supported = std_fiber.supported;
pub const Context = std_fiber.Context;
pub const Switch = std_fiber.Switch;

pub const default_stack_size = 64 * 1024;
pub const stack_alignment = 16;

/// Sentinel written at the low end of every fiber stack, checked by the
/// scheduler after every switch. Best-effort diagnostics only: it catches
/// overflows that write contiguously through the low end (deep call chains,
/// buffer overruns), but a single large stack-frame adjustment can jump past
/// the canary and write outside the allocation without touching it.
/// Dependable detection needs guard pages (mmap + mprotect); the canary is
/// the portable fallback that works with plain allocator memory.
const stack_canary: u64 = 0x5AFE_57AC_CA4A_111E;
const stack_canary_size = @sizeOf(u64);

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
};

pub const Fiber = struct {
    allocator: std.mem.Allocator,
    stack: []align(stack_alignment) u8,
    context: Context,
    closure: *StartClosure,
    finished: bool = false,

    pub fn create(allocator: std.mem.Allocator, options: CreateOptions) Error!*Fiber {
        if (!supported) return error.FiberUnsupported;
        if (options.stack_size < @sizeOf(StartClosure) + stack_alignment + stack_canary_size) {
            return error.StackTooSmall;
        }

        const self = try allocator.create(Fiber);
        errdefer allocator.destroy(self);

        const stack = try allocator.alignedAlloc(u8, .fromByteUnits(stack_alignment), options.stack_size);
        errdefer allocator.free(stack);
        std.mem.writeInt(u64, stack[0..stack_canary_size], stack_canary, .little);

        const closure = placeClosure(stack);
        self.* = .{
            .allocator = allocator,
            .stack = stack,
            .context = undefined,
            .closure = closure,
        };
        closure.* = .{
            .self_context = &self.context,
            .finish_context = options.finish_context,
            .entry = options.entry,
            .arg = options.arg,
            .finished = &self.finished,
        };
        self.context = initContext(closure);

        return self;
    }

    pub fn destroy(self: *Fiber) void {
        const allocator = self.allocator;
        allocator.free(self.stack);
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
        return std.mem.readInt(u64, self.stack[0..stack_canary_size], .little) == stack_canary;
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
    return std_fiber.contextSwitch(message);
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
    return @ptrFromInt(address);
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
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ b %[call]
            :
            : [call] "X" (&entryCall),
        ),
        .riscv64 => asm volatile (
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
    fiber_instance.stack[0] = 0;
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
