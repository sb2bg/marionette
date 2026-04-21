# Why Deterministic Replay in Zig Is Harder Than It Sounds

Status: Phase 0 build log.

I started Marionette with a goal that sounded almost too easy: run one tiny
Zig scenario twice, give both runs the same seed, and get the same trace bytes
back.

That's not the exciting version of deterministic simulation testing. There's no
network partition, no disk corruption, no cluster slowly working its way
through a strange recovery case at 2am. Right now Marionette is mostly a clock,
a random number generator, a trace buffer, and a runner that says "do it
again."

That little loop has been enough to reveal most of the design pressure anyway.
Before I can talk honestly about simulating networks or disks, I need to know
what it means for one boring run to replay exactly.

## "Seeded" is not "deterministic"

The beginner version of this idea goes: pick a seed, use a seeded PRNG, print
the seed when the test fails, replay it later. That gets you part of the way,
and for some tests it might be enough.

It's also a good way to fool yourself.

A seed only controls the choices that draw from that PRNG. If the code also
reads host time, calls `std.crypto.random`, depends on pointer addresses,
spawns a real thread, or dumps a hash map in whatever order it picks today,
then the seed is only steering part of the run. The rest is still coming from
the machine.

This is where Zig starts to help. Passing dependencies explicitly is already
normal here. Passing an allocator is ordinary. Passing a clock or a random
source doesn't feel like a framework taking over your program. It feels like
the rest of the code you already write.

So Marionette takes the library route. It doesn't fake time with `LD_PRELOAD`,
intercept syscalls, or try to make arbitrary Zig code deterministic from the
outside. The deal is stricter than that: if your code needs time, you pass it a
simulated clock; if it needs randomness, you pass it a seeded source; if it
needs disk or network, you'll eventually pass it those authorities too.
Reaching around any of them is a bug in the test shape.

Less magical than a platform that captures the whole process, and much easier
to reason about.

## The trace is where the honesty lives

The current trace format is plain text on purpose:

```text
marionette.trace format=text version=0
event=0 world.init seed=12648430 start_ns=0 tick_ns=1000000
event=1 world.tick now_ns=1000000
event=2 world.random_u64 value=10121301305976376037
event=3 request.accepted id=42
```

This isn't a logging system. It's the thing I compare. If two runs with the
same seed produce different trace bytes, Marionette hasn't found an application
bug. It's found a determinism leak.

That single decision made a lot of detail matter earlier than I expected.
Trace events can't contain wall-clock timestamps, pointer addresses, or host
thread ids. They can't depend on unordered map iteration. They shouldn't
include machine-local paths unless those paths are part of the explicit test
input.

It's tempting to treat the trace as bookkeeping, but I think it's the real
work. A deterministic simulator is only as useful as the artifact it leaves
behind when something fails. If the trace is vague, unstable, or full of
accidental host state, the seed won't save you.

## The blunt tool I like most so far

Phase 0 has a runner called `mar.run`. It runs the scenario once, saves the
trace, reinitializes, runs the same scenario again, and compares the trace
bytes.

That's all it does, and that's why I like it.

If both scenario bodies return success but the traces differ, the run still
fails. This has shaped the API more than any design document would have,
because it turns determinism into something I can test directly instead of
something I hope the code mostly preserves.

There's also a `tidy` linter that bans obvious host nondeterminism in simulated
code: direct `std.time`, host entropy, threads, direct network calls, common
filesystem entry points. It catches simple aliases too:

```zig
const time = std.time;
const now = time.nanoTimestamp();
```

I want that linter to become one of Marionette's strongest features. It should
feel less like a style checker and more like project law: if you're writing
simulated code, these are the ways nondeterminism is allowed to enter, and
everything else gets stopped at the door.

But the linter will never be the whole story. It's the front door. The
twice-and-compare trace check is the backstop. The linter says "you probably
shouldn't do that"; the trace says "show me."

## The tiny register is supposed to be tiny

The repo has a replicated-register example now. It's not a consensus protocol
and I don't want anyone to mistake it for one. Three replicas, seeded message
drops, deterministic delivery ordering, trace-visible profile data, and a
checker that catches divergent committed state.

That's enough to make the uncomfortable questions concrete. What does a
simulator decision look like in the trace? What does a user event look like?
Where do run options go? How do I name a checker failure? How do I keep a seed
from being the only clue in a bug report?

The last one matters more than it sounds. A seed by itself isn't enough once a
test has profiles, retry limits, queue capacities, replica counts, and fault
probabilities. Marionette records that context before scenario code even
starts:

```text
event=1 run.profile name=replicated-register-smoke
event=2 run.tag value=scenario:smoke
event=3 run.attribute key=replicas value=uint:3
event=4 run.attribute key=proposal_drop_percent value=uint:20
```

Not glamorous, but exactly the kind of thing I want in place before the
simulator grows real network and disk fault models. A future failure report
shouldn't make you reverse-engineer what the seed expanded into.

## What isn't built yet

Marionette doesn't simulate disk. It doesn't simulate a network. There's no
scheduler, no shrinking, no time-travel debugging, no liveness checking.

Those are the reasons to build the project. They aren't reasons to rush past
the boring replay loop. The boring loop is the contract everything else will
lean on, and I'd rather have a small simulator that's honest than a large one
that occasionally lies.

## The bet

The bet is that Zig projects can be structured around explicit effect
boundaries without becoming unpleasant to write. If that's true, deterministic
simulation testing doesn't have to be a custom harness that every serious
systems project rebuilds from scratch. It can be a library.

Not a runtime trick, not a syscall trap. A library with sharp edges on purpose:
pass in the authorities, keep host nondeterminism out of simulated code, make
simulator decisions visible, and treat trace mismatch as a bug.

That's what Phase 0 is trying to prove. When a run fails, it should come back
with the same seed, the same trace, and enough context to debug it.
