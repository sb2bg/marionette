# The Clobber List Said x30. LLVM Disagreed.

In [the last codegen story](our-tests-only-passed-because-of-register-allocation-luck.md),
Marionette's context switch got three fixes (corrected asm constraints, a
`noinline` marker, complete clobber coverage), and I closed with an open
question about [zio](https://github.com/lalinsky/zio):

> It does, however, still inline a switch that resumes through a local
> assembly label. That makes it a useful reference, not proof that the
> broader returns-twice optimizer hazard is absent.

This week that question got answered, because zio's author reviewed
Marionette's switch and left a performance note:

> Regarding the inline marker for the context switch, it's actually
> essential for performance to keep it as inline, so that the compiler sees
> the register allocations in the calling function and spills only what's
> needed there. In your simulation, it probably doesn't matter, but it does
> matter in general.

He's right about the mechanism, and I can now put numbers on it. He's also
right that it doesn't matter for Marionette. But taking the advice
literally, by flipping the corrected switch back to `inline`, produces a
deterministic segfault in every optimized build mode, and the reason turned
out to be a second live codegen bug that the entire clobber list is
powerless against.

## Benchmarking the advice

The claim is concrete: an inlined switch lets the register allocator spill
only what's live at each call site, while a `noinline` wrapper always pays
worst case. The wrapper's asm clobbers every callee-saved register, so the
ABI forces its prologue to save all of them, every switch, no matter what
the caller has live:

```
_switch_bench.switchNoinline:
  stp d15, d14, [sp, #-0xa0]!
  stp d13, d12, [sp, #0x10]
  stp d11, d10, [sp, #0x20]
  stp d9,  d8,  [sp, #0x30]
  stp x28, x27, [sp, #0x40]
  stp x26, x25, [sp, #0x50]
  stp x24, x23, [sp, #0x60]
  stp x22, x21, [sp, #0x70]
  stp x20, x19, [sp, #0x80]
  stp x29, x30, [sp, #0x90]
  ...
```

Ten store-pairs down, ten load-pairs back up. 160 bytes of stack traffic
each way, per switch, unconditionally.

So I wrote a ping-pong benchmark: two fibers switching back and forth five
million times (ten million switches), with the corrected switch compiled
both ways, at two levels of register pressure: nothing live across the
switch, and eight accumulators live across the switch. AArch64 macOS,
Zig 0.16.0. The benchmark is
[`tests/switch_inline_bench.zig`](https://github.com/sb2bg/marionette/blob/main/tests/switch_inline_bench.zig)
(`zig run -OReleaseFast -lc tests/switch_inline_bench.zig`).

Debug mode, where both variants run, shows his point exactly:

| Debug      | nothing live | 8 live registers |
| ---------- | ------------ | ---------------- |
| `noinline` | 16.4 ns      | 18.9 ns          |
| `inline`   | 4.4 ns       | 8.3 ns           |

The inline cost scales with what's actually live. The noinline cost is the
flat worst case. Roughly 4x, exactly as advertised.

Then ReleaseFast:

```
noinline: 13.85 ns/switch (low pressure), 13.92 ns/switch (8 live regs)
exit: 139
```

Exit 139 is SIGSEGV. Same asm. Same corrected constraints. Same complete
clobber list that had just survived ten million switches as a `noinline`
function. The only change was inlining.

## The crash address is doing arithmetic at you

ReleaseSafe prints a trace before dying:

```
Segmentation fault at address 0x4c4b50
switch_bench.zig:117:5: 0x1045a0994 in switchInline (switch_bench)
    return asm volatile (
```

`0x4c4b50` is 5,000,016. The benchmark's loop bound is `rounds =
5_000_000`. The faulting address is my loop bound plus sixteen.

That plus-sixteen is a fingerprint. The switch asm begins:

```
ldp x0, x2, [x1]      // x0 = msg.old, x2 = msg.new
ldr x3, [x2, #16]     // x3 = new_context.pc   <- offset 16
```

Something dereferenced `msg.new + 16` while `msg.new` held the integer
5,000,000. The loop counter had ended up inside a context pointer. The
question was how it traveled.

## Reading the codegen

The disassembly of the benchmark's hot loop answers it in two instructions:

```
mov  w30, #0x4b40           ; ┐
movk w30, #0x4c, lsl #16    ; ┘ x30 = 5,000,000
loop:
  stp  x9, x8, [sp, #0x98]  ; msg = {&main_ctx, &fiber_ctx}   (correct)
  ...inlined switch asm...  ; saves resume pc, switches away
  subs x30, x30, #1         ; <- decrement, AFTER the resume label
  b.ne loop
```

LLVM put the loop counter in **x30, the link register, and kept it live
across the inline asm**. `.x30 = true` is in the clobber list. It's been in
the clobber list the whole time.

The fiber side of the ping-pong has the same disease in a different organ:

```
adrp x30, ...               ; ┐ x30 = &main_ctx, hoisted out of
add  x30, x30, #0xb90       ; ┘ the fiber's while(true) loop
loop:
  add  x8, x30, #0x18
  stp  x8, x30, [sp]        ; msg.new = x30
  mov  x1, sp
  ldp  x0, x2, [x1]         ; x2 = msg.new
  ldr  x3, [x2, #0x10]      ; <- the faulting instruction
```

Now the whole crash replays mechanically. Main parks 5,000,000 in x30 and
switches out. The fiber resumes, rebuilds its message from x30, which it
hoisted `&main_ctx` into trusting it to survive, and stores the counter
where a context pointer belongs. `ldr x3, [x2, #16]` dereferences
5,000,016. That's `0x4c4b50`, byte for byte.

Both sides violated the same contract, in the same register, and neither
side was wrong about anything else. Every one of the other fifty-nine
clobbers was honored.

## Why noinline never crashed

LLVM's AArch64 backend appears to treat an x30 clobber in inline asm as a
statement about the _function_ ("this function must save and restore LR in
its prologue and epilogue") rather than a statement about the _asm_
("LR is dead across this block"). Once the prologue has saved LR, the
allocator considers x30 a perfectly good scratch register for the whole
function body, inline asm included. It parks a value there and expects it
back afterward. For a function call that expectation holds, because `bl`
overwrites LR and the ABI makes every caller assume so. For inline asm that
resumes from a different fiber, it's fiction.

That's also the complete explanation for why `noinline` is reliable: the
call boundary launders exactly the register LLVM mishandles. Callers never
keep anything in x30 across a `bl` because the ABI forbids it. The
`noinline` marker wasn't just suppressing a returns-twice optimizer hazard.
It was, unknowingly, working around a second bug.

## zio had the answer filed under "optimization"

With the mechanism in hand, I went back to zio's switch, the mature
reference from the last investigation, to see how it survives being
inlined. Its context struct has a slot std's doesn't:

```zig
.aarch64 => extern struct {
    sp: u64,
    fp: u64,
    lr: u64,  // x30 (link register) only saved a an optimization reusing ldp/stp
    pc: u64,
    ...
```

And above the asm:

```zig
// NOTE: We technically don't need to save x30/lr, we could mark it as
//       clobbered, but the compiler will almost always need to save it
//       anyway, and we can fit it into our stp/ldp instructions, so we
//       will help it out a bit.
```

zio saves and restores `lr` through the context, inside the asm, and keeps
x30 _off_ the clobber list. The comment calls it a codegen favor. As far as
I can tell it is also the entire reason zio's inlined switch is correct on
LLVM: it never asks the backend to honor an x30 clobber in the first place.

It gets better. zio's 32-bit ARM variant carries this comment on the same
field:

```zig
lr: u32,  // r14 (link register) only saved beause of
          // https://github.com/llvm/llvm-project/pull/179740
          // (can't be worked around in zig)
```

Same bug family, different limb: on arm32 the author hit LLVM's LR-clobber
mishandling head-on and documented it as unworkaroundable. On AArch64 the
workaround exists, and it's the "optimization."

## The decisive experiment

If the x30 clobber is the whole bug, then one change should make the
inlined switch correct: grow the context by one slot, swap `lr` through it
in the asm, and delete `.x30` from the clobber list. Everything else stays:
the register output at the resume point, the message struct in memory,
the other fifty-nine clobbers.

```
 stp x30, x5, [x0, #16]   ; save lr + resume pc
 ...
 ldr x30, [x2, #16]       ; restore new fiber's lr
```

ReleaseFast, all three variants:

| ReleaseFast              | nothing live | 8 live registers | outcome |
| ------------------------ | ------------ | ---------------- | ------- |
| `noinline`, x30 clobber  | 13.7 ns      | 14.3 ns          | passes  |
| `inline`, lr via context | **3.4 ns**   | **6.4 ns**       | passes  |
| `inline`, x30 clobber    | n/a          | n/a              | SIGSEGV |

One register moved from the clobber list into the context, and the inlined
switch went from deterministically crashing to the fastest correct variant
on the board. The returns-twice shape, the asm output, the memory handoff:
none of them were the problem. The last post's open hazard, at least as it
manifests here, has a name and a one-slot fix.

## Stakes

This isn't just Marionette's problem. `std.Io.fiber.contextSwitch` in Zig
0.16.0 is declared `pub inline fn`, and its AArch64 clobber list contains
`.x30 = true`. That is precisely the combination shown above to miscompile.
Whether any given program crashes depends on whether the register allocator
happens to park something in x30 across a call site. It is the same
luck-dependent codegen as last time, one register over.

The reproducer is going onto the
[existing Codeberg issue](https://codeberg.org/ziglang/zig/issues/35724)
alongside the constraint bug, with zio's llvm-project#179740 reference as
prior art for the LR-clobber family. The clean upstream fix is zio's: give
`Context` an `lr` slot and stop asking LLVM to honor the clobber.

For Marionette itself, the decision is genuinely open. The case for
staying `noinline`: ten nanoseconds per switch is noise against simulation
bookkeeping, and this makes twice in two weeks that "trust the clobber list
across a returns-twice edge" lost to a target-specific backend bug (the
constraint conflict last time, x30 now, with zio's x86 xmm-alias and
Windows-TEB scars as neighboring exhibits). A simulator whose product is
determinism has license to be the most conservative program in the room.
The case for switching: the lr-through-context variant is correct, four
times faster, and battle-tested in zio across more architectures than
Marionette supports. The switch stays `noinline` today while I sit with
that, and the inline variant is recorded here and in
`tests/switch_inline_bench.zig` either way.

## Lessons

- **Crash addresses are data, not noise.** `0x4c4b50` decoded to "your
  loop bound, plus the offset of the `pc` field." One subtraction turned a
  segfault into a register-flow diagram. Last time it was code bytes
  dereferenced as a pointer; this time an induction variable wearing a
  pointer's clothes.
- **Performance advice is a test case.** The maintainer's note was about
  nanoseconds. Benchmarking it honestly, including the variant that
  crashes, found a miscompilation that reading the code never would have,
  and quantified the advice at the same time: 4x, exactly as claimed.
- **Comments can encode load-bearing knowledge, mislabeled.** zio's lr
  save is annotated as a favor to the compiler. It's a correctness fix for
  a backend bug the same author documented explicitly one architecture
  over. When a mature implementation does something "unnecessary," the
  polite assumption is that the necessity just isn't written down.
- **The ABI is a correctness tool.** `noinline` worked not because it
  suppressed an optimizer transform but because a real call boundary forces
  every caller to treat x30 as dead. When a backend won't honor your
  contract, sometimes you can rent a stronger one.

## Credit

This investigation exists because [zio](https://github.com/lalinsky/zio)'s
author reviewed Marionette's switch unprompted, catching the x86_64
xmm/ymm alias gap and the allocatable-x18 gap by inspection (both now
fixed), and then made a performance claim precise enough to falsify. Reference
code eliminated hypotheses last time; this time it contained the fix,
comment and all.
