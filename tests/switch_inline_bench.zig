//! Ping-pong benchmark: marionette's corrected aarch64 context switch as
//! noinline fn vs inline fn, to quantify lalinsky's claim that inlining
//! lets the register allocator spill only live registers while noinline
//! pays the full C-ABI save/restore on every switch.
const std = @import("std");
const builtin = @import("builtin");

const Context = extern struct { sp: u64, fp: u64, pc: u64 };
const Switch = extern struct { old: *Context, new: *Context };

comptime {
    if (builtin.cpu.arch != .aarch64) @compileError("aarch64-only benchmark");
}

// Same asm and clobber list as marionette's correctedContextSwitch
// (aarch64, Darwin: x18 reserved so excluded).
noinline fn switchNoinline(s: *const Switch) *const Switch {
    return asm volatile (
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
        });
}

inline fn switchInline(s: *const Switch) *const Switch {
    return asm volatile (
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
        });
}

// Hypothesis test: identical to switchInline except lr (x30) is swapped
// through the context by the asm itself and removed from the clobber list.
// If LLVM's mishandling of x30 clobbers is the whole bug, this runs inline
// at full speed. Context gains an lr slot: {sp, fp, lr, pc}.
const Context4 = extern struct { sp: u64, fp: u64, lr: u64, pc: u64 };
const Switch4 = extern struct { old: *Context4, new: *Context4 };

inline fn switchInlineLrSaved(s: *const Switch4) *const Switch4 {
    return asm volatile (
        \\ ldp x0, x2, [x1]
        \\ ldr x3, [x2, #24]
        \\ mov x4, sp
        \\ stp x4, fp, [x0]
        \\ adr x5, 0f
        \\ stp x30, x5, [x0, #16]
        \\ ldp x4, fp, [x2]
        \\ ldr x30, [x2, #16]
        \\ mov sp, x4
        \\ br x3
        \\0:
        : [received_message] "={x1}" (-> *const Switch4),
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
        });
}

const BenchLr = struct {
    var main_ctx: Context4 = undefined;
    var fiber_ctx: Context4 = undefined;

    fn entryTrampoline() callconv(.naked) void {
        asm volatile (
            \\ mov x30, xzr
            \\ b %[call]
            :
            : [call] "X" (&entryCall),
        );
    }

    fn entryCall(_: *const Switch4) callconv(.c) noreturn {
        while (true) {
            var msg: Switch4 = .{ .old = &fiber_ctx, .new = &main_ctx };
            _ = switchInlineLrSaved(&msg);
        }
    }

    fn run(allocator: std.mem.Allocator, rounds: usize) !void {
        const stack = try allocator.alignedAlloc(u8, .fromByteUnits(16), stack_size);
        defer allocator.free(stack);

        const top = std.mem.alignBackward(usize, @intFromPtr(stack.ptr) + stack.len - 32, 16);
        fiber_ctx = .{ .sp = top, .fp = 0, .lr = 0, .pc = @intFromPtr(&entryTrampoline) };

        {
            var msg: Switch4 = .{ .old = &main_ctx, .new = &fiber_ctx };
            _ = switchInlineLrSaved(&msg);
        }

        var start = nowNs();
        var i: usize = 0;
        while (i < rounds) : (i += 1) {
            var msg: Switch4 = .{ .old = &main_ctx, .new = &fiber_ctx };
            _ = switchInlineLrSaved(&msg);
        }
        const low_ns = nowNs() - start;

        var a0: u64 = 1;
        var a1: u64 = 2;
        var a2: u64 = 3;
        var a3: u64 = 5;
        var a4: u64 = 7;
        var a5: u64 = 11;
        var a6: u64 = 13;
        var a7: u64 = 17;
        start = nowNs();
        i = 0;
        while (i < rounds) : (i += 1) {
            var msg: Switch4 = .{ .old = &main_ctx, .new = &fiber_ctx };
            _ = switchInlineLrSaved(&msg);
            a0 +%= i;
            a1 ^= a0;
            a2 +%= a1;
            a3 ^= a2;
            a4 +%= a3;
            a5 ^= a4;
            a6 +%= a5;
            a7 ^= a6;
        }
        const high_ns = nowNs() - start;
        std.mem.doNotOptimizeAway(a0 +% a1 +% a2 +% a3 +% a4 +% a5 +% a6 +% a7);

        const per_low = @as(f64, @floatFromInt(low_ns)) / @as(f64, @floatFromInt(rounds)) / 2.0;
        const per_high = @as(f64, @floatFromInt(high_ns)) / @as(f64, @floatFromInt(rounds)) / 2.0;
        std.debug.print("inline+lr-saved: {d:.2} ns/switch (low pressure), {d:.2} ns/switch (8 live regs)\n", .{ per_low, per_high });
    }
};

const stack_size = 64 * 1024;

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn Bench(comptime switchFn: anytype, comptime name: []const u8) type {
    return struct {
        var main_ctx: Context = undefined;
        var fiber_ctx: Context = undefined;

        fn entryTrampoline() callconv(.naked) void {
            asm volatile (
                \\ mov x30, xzr
                \\ b %[call]
                :
                : [call] "X" (&entryCall),
            );
        }

        fn entryCall(_: *const Switch) callconv(.c) noreturn {
            while (true) {
                var msg: Switch = .{ .old = &fiber_ctx, .new = &main_ctx };
                _ = switchFn(&msg);
            }
        }

        fn run(allocator: std.mem.Allocator, rounds: usize) !void {
            const stack = try allocator.alignedAlloc(u8, .fromByteUnits(16), stack_size);
            defer allocator.free(stack);

            const top = std.mem.alignBackward(usize, @intFromPtr(stack.ptr) + stack.len - 32, 16);
            fiber_ctx = .{ .sp = top, .fp = 0, .pc = @intFromPtr(&entryTrampoline) };

            // Warm up: one round trip so the fiber is parked in its loop.
            {
                var msg: Switch = .{ .old = &main_ctx, .new = &fiber_ctx };
                _ = switchFn(&msg);
            }

            // Low register pressure: nothing live across the switch.
            var start = nowNs();
            var i: usize = 0;
            while (i < rounds) : (i += 1) {
                var msg: Switch = .{ .old = &main_ctx, .new = &fiber_ctx };
                _ = switchFn(&msg);
            }
            const low_ns = nowNs() - start;

            // High register pressure: 8 accumulators live across the switch.
            var a0: u64 = 1;
            var a1: u64 = 2;
            var a2: u64 = 3;
            var a3: u64 = 5;
            var a4: u64 = 7;
            var a5: u64 = 11;
            var a6: u64 = 13;
            var a7: u64 = 17;
            start = nowNs();
            i = 0;
            while (i < rounds) : (i += 1) {
                var msg: Switch = .{ .old = &main_ctx, .new = &fiber_ctx };
                _ = switchFn(&msg);
                a0 +%= i;
                a1 ^= a0;
                a2 +%= a1;
                a3 ^= a2;
                a4 +%= a3;
                a5 ^= a4;
                a6 +%= a5;
                a7 ^= a6;
            }
            const high_ns = nowNs() - start;
            std.mem.doNotOptimizeAway(a0 +% a1 +% a2 +% a3 +% a4 +% a5 +% a6 +% a7);

            const per_low = @as(f64, @floatFromInt(low_ns)) / @as(f64, @floatFromInt(rounds)) / 2.0;
            const per_high = @as(f64, @floatFromInt(high_ns)) / @as(f64, @floatFromInt(rounds)) / 2.0;
            std.debug.print("{s}: {d:.2} ns/switch (low pressure), {d:.2} ns/switch (8 live regs)\n", .{ name, per_low, per_high });
        }
    };
}

pub fn main() !void {
    var stack_memory: [4 * stack_size]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_memory);
    const allocator = fba.allocator();
    const rounds = 5_000_000;

    // Correctness sentinel: if returns-twice inlining miscompiles the loop,
    // this either hangs or the round count is wrong.
    try Bench(switchNoinline, "noinline").run(allocator, rounds);
    try BenchLr.run(allocator, rounds);
    try Bench(switchInline, "inline  ").run(allocator, rounds);
    std.debug.print("all variants completed {} rounds\n", .{rounds});
}
