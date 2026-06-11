# Our Tests Only Passed Because of Register Allocation Luck

Status: Phase 1 build log. A debugging story.

Marionette's whole pitch is that one seed produces one execution, forever.
This week I found a bug class that the entire architecture is blind to: the
compiler toolchain generating wrong code for the simulator itself. Both runs
of the twice-and-compare loop execute the same binary, so deterministic wrong
behavior is outside that backstop. In this case the scheduler spun forever
before the comparison could even complete.

This is the story of finding it, being wrong about it twice, and proving
the real cause with a six-line reproducer. The bug is not in Marionette.
One defect is in the inline assembly constraints of Zig's standard-library
fiber context switch; another is the optimizer-visible returns-twice shape
of that switch. At the time of writing, both remain present in the
canonical Zig master branch on Codeberg.

## It started as "the tests are slow"

I was finishing a round of fixes and kicked off the usual verification
sweep: Debug tests, ReleaseSafe tests, validation suites. The ReleaseSafe
job didn't come back. When I looked, two test binaries had been burning
100% CPU for forty minutes on a suite that takes seconds.

The investigation below used Zig 0.16.0 on AArch64 macOS. The failing
full-suite command was `zig build test -Doptimize=ReleaseSafe`.

A `sample` of the stuck process showed it spinning inside the
deterministic scheduler's `runUntilIdle`, in the very first scheduler
test: three toy tasks that do nothing but yield a few times and complete.
Debug mode passed. ReleaseSafe hung. Every time.

## The red herring: "order dependence"

The test passed in isolation and hung in the full suite, so I assumed
some earlier test was corrupting state. That theory fell apart on a
detail worth remembering: `--test-filter` in Zig changes what gets
_compiled_, not just what runs. The isolated binary and the full binary
are different programs. The hang wasn't order-dependent. It was
**binary-dependent**: a given compilation either always hung or never
did, deterministically.

That reframing mattered, because the next experiment made no sense
without it. I bisected my working tree changes and found that the hang
appeared with a change that grew one struct by eight bytes, with no
behavioral meaning at all. Reverting unrelated files didn't help.
Reverting everything made it pass. Making a one-line change in the other
direction, marking the context switch wrapper `noinline`, produced a
deterministic segfault instead.

Committed HEAD passed. HEAD plus eight bytes hung. HEAD plus `noinline`
crashed. The only consistent conclusion: HEAD was passing by codegen
luck, and any perturbation re-rolled the dice.

## Being wrong, in order

Forensics on the hanging binary showed an "impossible" state. The typed
debugger view said all three tasks were completed, the ready queue was
empty, and the loop should take its exit branch. The disassembly said
the loop's exit condition was a byte loaded from a **static constant**
in rodata. State that should change across context switches had been
folded into a compile-time value.

That smelled like the optimizer mismodeling the context switch, so I
went looking for a mature reference. [zio](https://github.com/lalinsky/zio)
has a multi-architecture fiber implementation, and comparing its switch
against `std.Io.fiber.contextSwitch` turned up three structural
differences:

1. zio clobbers `nzcv`, the AArch64 condition flags. std does not, even
   though std's own x86_64 variant clobbers `rflags`.
2. zio's asm has no output operands; the handoff goes through memory.
   std returns the received message through a register output.
3. zio enters fibers through naked functions.

Two testable hypotheses. Both wrong. Adding the missing `nzcv` clobber
fixed nothing. Rebuilding the switch zio-style with no outputs and a
memory handoff also fixed nothing; it just morphed the hang into a
segfault whose fault address decoded as two AArch64 `mov` instructions,
code bytes dereferenced as a pointer.

I'm including the failed theories on purpose. Both were plausible, both
were falsifiable, and falsifying them is what kept the investigation
honest. The `nzcv` asymmetry is still a real latent hazard worth fixing
upstream. It just wasn't _this_ bug.

zio avoids the exact constraint failure eventually found below because it
has no register output competing with its fixed register inputs and
clobbers. It does, however, still inline a switch that resumes through a
local assembly label. That makes it a useful reference, not proof that the
broader returns-twice optimizer hazard is absent.

## The break: a function small enough to read

The `noinline` reproducer turned out to be the gift. With the switch
out-of-line, the whole function is thirty instructions, and the crash
report becomes legible: faulting instruction `ldp x0, x2, [x1]` with
`x1 = 0`, while `x0` still held the valid message pointer.

The wrapper receives its argument in `x0`, because that's the calling
convention. The asm needs it in `x1`, because that's its input
constraint. Between the prologue and the asm there is supposed to be a
`mov x1, x0`.

It isn't there. The compiler never emitted it.

Why? Look at the constraints on `std.Io.fiber.contextSwitch`:

```zig
: [received_message] "={x1}" (-> *const Switch),
: [message_to_send] "{x1}" (s),
: .{
    .x0 = true,
    .x1 = true,   // <- the bug
    .x2 = true,
    // ...
```

The message register is declared as the input, the output, **and a
clobber**. Giving the same fixed register all three roles creates a
conflicting constraint set. The generated code does not reject the
conflict; under register pressure it drops the copy of the input into the
message register. The switch then dereferences whatever the caller happened
to leave in `x1`. Whether the missing diagnostic or bad lowering belongs to
Zig's frontend or the LLVM backend is an upstream triage question; the
defective constraint set is in Zig's standard library.

Everything snapped into focus:

- HEAD passed because, at every inlined call site, the caller happened
  to compute the message address into `x1` naturally. The missing copy
  was invisible.
- Growing a struct by eight bytes shifted register allocation somewhere,
  some site stopped using `x1`, and the "received message" became a
  pointer to a random rodata constant. The scheduler read its loop state
  through it and span forever.
- `noinline` moved the argument to `x0` per the ABI, making the missing
  copy immediately fatal.
- Debug mode never bit because unoptimized codegen materializes
  constraints naively.
- My zio-style rewrite failed because I had faithfully copied the
  poisoned clobber list into it.

## The six-line proof

Extracting the pattern gives a standalone reproducer. This fails with
`error.InputCopyDropped` at `-OReleaseSafe`, and the disassembly shows
`passThrough` returning the caller's stale `x1` without ever loading its
argument into it:

```zig
noinline fn passThrough(p: *const u64) *const u64 {
    return asm volatile (""
        : [out] "={x1}" (-> *const u64),
        : [in] "{x1}" (p),
        : .{ .x0 = true, .x1 = true, .x2 = true, .memory = true });
}

pub fn main() !void {
    var value: u64 = 42;
    if (passThrough(&value) != &value) return error.InputCopyDropped;
}
```

No fibers, no scheduler, no Marionette. The same register is input, output,
and clobber; the required input copy disappears.

## The second bug underneath

Fixing the constraints cured the `noinline` crash but not the
struct-resize hang, which sent me back with an instruction-level step
trace. The residual cycle was twenty-one instructions, and one branch
was simply wired wrong: the path for "no timers pending, return false,
exit the loop" jumped back to the loop head, into a block that tested a
byte of a materialized constant whose layout matches an error union
`{ err = 0, payload = true }`. The optimizer had constant-folded one
arm of the scheduler's exit decision and merged the control flow around
it.

This is the deeper issue with the std switch shape: the asm resumes at
a local label that _other executions of the same code_ re-enter. That is
setjmp-like, returns-twice control flow, and nothing in the asm's
constraints tells LLVM about it. Inlined into a hot loop, the optimizer
is entitled to assumptions that the label breaks.

The mitigation is structural: keep the resume label inside a dedicated
`noinline` function, so every switch is a plain call from the caller's
point of view. Marionette's scheduler already kept its _own_ suspension
points opaque for exactly this reason, after an earlier ReleaseSafe
incident. The lesson just had to be pushed one level deeper, into the
switch primitive itself.

## The fix, and why both halves are load-bearing

Marionette now carries a local copy of the context switch
(`correctedContextSwitch` in `src/fiber.zig`) with two changes:

1. std's asm for aarch64, x86_64, and riscv64 with the message register
   removed from each clobber list, plus the missing `nzcv` clobber on
   aarch64.
2. `noinline`, so the returns-twice label cannot be inlined into caller
   control flow.

Each fix alone was insufficient; I tested both ways. Together, both
previously deterministic reproducers pass, along with the full Debug,
ReleaseSafe, and ReleaseFast suites and every validation harness. The
struct-resize change that started all of this is now harmless, which
also let the fiber stack guard pages land.

## What this means for a determinism library

Marionette's strongest claim is the twice-and-compare backstop: run
every scenario twice, byte-compare the traces, and non-determinism has
nowhere to hide. This bug is precisely the thing that backstop cannot
see. A miscompiled simulator is deterministic. It replays its wrong
behavior perfectly.

Three process lessons came out of this:

- **Passing tests are evidence, not proof, when codegen is in the
  loop.** The committed tree was one register allocation decision away
  from hanging forever, and every test was green.
- **Perturbation is a real testing technique.** An eight-byte struct
  resize and a one-keyword inlining change were the two best bug
  detectors in the entire project. Cheap, dumb perturbations of layout
  and inlining shake out luck-dependent codegen.
- **CI needs timeouts.** A hang in ReleaseSafe looks like a slow build
  until you sample it. A job timeout converts "mysteriously stuck" into
  a red X.

## Upstream

[I'm filing upstream against the Codeberg source](https://codeberg.org/ziglang/zig/issues/35724) with the
standalone reproducer. Marionette's local copy carries a removal note for
the day the fix lands.

Diagnosis credit where due: comparing against zio's implementation is
what narrowed the search, even though its two most visible differences
turned out not to be the cause. Good reference code is worth a lot even
when it's "only" eliminating hypotheses.
