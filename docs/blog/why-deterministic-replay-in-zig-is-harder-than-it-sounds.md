# Why Deterministic Replay in Zig Is Harder Than It Sounds

Status: Phase 0 build log.

I started Marionette with a small target that sounded almost too easy: run one
tiny Zig scenario twice, give both runs the same seed, and get the same trace
bytes back.

That is not the exciting version of deterministic simulation testing. There is
no network partition, no disk corruption, and no cluster slowly working its way
through some strange recovery case at 2am. At this point Marionette is mostly a
clock, a random number generator, a trace buffer, and a runner that says "do it
again."

Still, that little loop has been enough to reveal most of the design pressure.
Before we can talk honestly about simulating networks or disks, we need to know
what it means for one boring run to replay exactly.

## The First Trap: "Seeded" Is Not "Deterministic"

The beginner version of this idea is straightforward: pick a seed, use a
seeded PRNG, print the seed when the test fails, and replay it later. That gets
you part of the way there, and for some tests it may be enough.

It is also a good way to fool yourself.

The seed only controls the choices that draw from that PRNG. If the code also
reads host time, calls `std.crypto.random`, depends on pointer addresses,
spawns a real thread, or dumps a hash map in whatever order it happens to
choose today, then the seed is only steering part of the run. The rest is still
coming from the machine.

This is where the Zig version gets interesting. Zig already makes it normal to
pass dependencies explicitly. Passing an allocator is ordinary. Passing a clock
or random source does not feel like a framework taking over the program.

So Marionette is taking the library route. It does not fake time with
`LD_PRELOAD`, intercept syscalls, or try to make arbitrary Zig code
deterministic from the outside. The deal is simpler and stricter than that:
pass the code a simulated clock if it needs time, pass it seeded randomness if
it needs randomness, and later pass it simulated disk and network authorities
for I/O. If code reaches around those interfaces, that is a bug in the test
shape.

That is less magical than a platform that captures the whole process, but it is
also much easier to reason about.

## The Trace Is Where the Honesty Lives

The current trace format is plain text on purpose:

```text
marionette.trace format=text version=0
event=0 world.init seed=12648430 start_ns=0 tick_ns=1000000
event=1 world.tick now_ns=1000000
event=2 world.random_u64 value=10121301305976376037
event=3 request.accepted id=42
```

This is not meant to be a logging system. It is the thing we compare. If two
runs with the same seed produce different trace bytes, Marionette has not found
an application bug yet. It has found a determinism leak.

That one decision makes a bunch of details matter earlier than I expected.
Trace events cannot contain wall-clock timestamps, pointer addresses, or host
thread ids. They cannot depend on unordered map iteration. They should not
include machine-local paths unless those paths are part of the explicit test
input.

It is tempting to treat that as bookkeeping, but I think it is the real work. A
deterministic simulator is only as useful as the artifact it leaves behind when
something fails. If the trace is vague, unstable, or full of accidental host
state, the seed will not save you.

## The Blunt Tool I Like Most So Far

Phase 0 has a runner called `mar.run`. It runs the scenario once, saves the
trace, initializes fresh state, runs the same scenario again, and compares the
trace bytes.

That is all it does, and that is why I like it.

If both scenario bodies return success but the traces differ, the run still
fails. This has already shaped the API more than a longer design document would
have, because it turns determinism into something we can test directly instead
of something we hope the code mostly preserves.

Marionette also has a `tidy` linter that bans obvious host nondeterminism in
simulated code. It catches direct `std.time`, host entropy, threads, direct
network calls, and common filesystem entry points. It can catch simple aliases
too:

```zig
const time = std.time;
const now = time.nanoTimestamp();
```

I want that linter to become one of Marionette's strongest features. It should
feel less like a style checker and more like project law: if you are writing
simulated code, these are the ways nondeterminism is allowed to enter, and
everything else gets stopped at the door.

But the linter will never be the whole story. It is the front door. The
twice-and-compare trace check is the backstop. The linter says, "you probably
should not do that." The trace says, "show me."

## The Tiny Register Is Supposed to Be Tiny

The repo has a replicated-register example now. It is not a consensus protocol,
and I do not want anyone to mistake it for one. It is a small example with
three replicas, seeded message drops, deterministic delivery ordering,
trace-visible profile data, and a checker that catches divergent committed
state.

That is enough to make uncomfortable questions concrete. What does a simulator
decision look like in the trace? What does a user event look like? Where do run
options go? How do we name a checker failure? How do we keep a seed from
becoming the only clue in a bug report?

That last question matters more than it seems. A seed by itself is not enough
once a test has profiles, retry limits, queue capacities, replica counts, and
fault probabilities. Marionette records that context before scenario code
starts:

```text
event=1 run.profile name=replicated-register-smoke
event=2 run.tag value=scenario:smoke
event=3 run.attribute key=replicas value=uint:3
event=4 run.attribute key=proposal_drop_percent value=uint:20
```

This is not glamorous, but it is the kind of thing I want in place before the
simulator grows real network and disk fault models. A future failure report
should not make you reverse-engineer what the seed expanded into.

## What Is Not Built Yet

Marionette does not simulate disk yet. It does not simulate a network yet. It
does not have a scheduler, shrinking, time-travel debugging, or liveness
checking.

Those are the reasons to build the project, but they are not reasons to rush
past the boring replay loop. The boring loop is the contract everything else
will lean on.

Right now the useful pieces are one simulated clock authority, one seeded PRNG
per world, a stable text trace format, `mar.run` twice-and-compare replay, a
`tidy` linter for host nondeterminism, named checks with failure summaries, and
run tags and typed attributes for replay context.

That may sound modest, but I think it is the right kind of modest. I would
rather have a small simulator that is honest than a large one that occasionally
lies.

## The Bet

The bet is that Zig projects can be structured around explicit effect
boundaries without becoming unpleasant to write. If that is true, deterministic
simulation testing does not have to be a custom harness every serious systems
project rebuilds from scratch. It can be a library.

Not a runtime trick, and not a syscall trap. A library with sharp edges on
purpose: pass in the authorities, keep host nondeterminism out of simulated
code, make simulator decisions visible, and treat trace mismatch as a bug.

That is what Phase 0 is trying to prove: when a run fails, the execution should
come back with the same seed, the same trace, and enough context to debug it.
