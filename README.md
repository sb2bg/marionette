# Marionette

Deterministic simulation testing for Zig.

Write your service once, against Marionette's interfaces. In production it
runs with zero overhead. In tests, it runs inside a simulator that controls
time, scheduling, disk, and network, so any bug you find can be replayed
exactly, as many times as you need.

> **Status: early development (Phase 0).** The ideas work in toy examples.
> The API will change. Do not use this in production yet. See
> [Roadmap](#roadmap) for what's real and what's aspirational.

## What this solves

Distributed systems bugs are the hardest bugs. They appear in production at
3am, refuse to reproduce locally, and cost real money. Your test suite runs
in one boring universe where packets always arrive, disks never corrupt, and
clocks move forward smoothly. Production runs in a universe that does none
of those things.

Deterministic simulation testing (DST) closes that gap. You run your code in
a simulated world that injects failures, dropped packets, delayed writes,
partitioned nodes, clock skew, torn disk writes, but does it _deterministically_.
One seed produces one exact execution. When the simulator finds a bug, you
save the seed. Replay it, and the bug appears again, in the same order, at
the same tick. No more "couldn't reproduce, closing as wontfix."

This approach is how FoundationDB, TigerBeetle, and a growing number of
serious distributed systems are tested. Until now, adopting it meant building
your own simulator from scratch.

## A tiny example

```zig
const std = @import("std");
const mar = @import("marionette");

// Your service takes Marionette's interfaces as parameters.
// In production, these are zero-cost wrappers over syscalls.
// In tests, they route through the simulator.
const RateLimiter = struct {
    clock: mar.Clock,
    requests_per_second: u32,
    last_refill: u64,
    tokens: u32,

    pub fn allow(self: *RateLimiter) bool {
        const now = self.clock.now();
        const elapsed = now - self.last_refill;
        // ... refill logic ...
        if (self.tokens > 0) {
            self.tokens -= 1;
            return true;
        }
        return false;
    }
};

test "rate limiter never allows more than the configured rate" {
    // Same seed. Same execution. Every single time.
    var world = try mar.World.init(.{ .seed = 0xC0FFEE });
    defer world.deinit();

    var limiter = RateLimiter{
        .clock = world.clock(),
        .requests_per_second = 100,
        .last_refill = 0,
        .tokens = 100,
    };

    var allowed: u32 = 0;
    for (0..10_000) |_| {
        if (limiter.allow()) allowed += 1;
        try world.tick();
    }

    try std.testing.expect(allowed <= 100 + (world.elapsed_seconds() * 100));
}
```

The interesting part isn't the rate limiter. It's that `zig build test`
produces the exact same execution every time. When someone eventually finds a
bug, the fix starts with a seed number, not a 20-slide postmortem.

## Why Zig

Marionette is feasible in Zig in a way it isn't in most other languages:

- **No hidden allocations.** Allocator-passing is the idiom, not an
  exception. Swapping in a deterministic allocator for tests is natural.
- **No runtime.** No goroutine scheduler, no async runtime to fight. The
  scheduler is ours.
- **Comptime.** The sim/production switch vanishes in release builds. The
  binary you test is the binary you ship.
- **Idiomatic interface-passing.** Well-written Zig services already take
  their dependencies as parameters. Marionette slots in without rewrites.

Go can't do this cleanly without forking the runtime (Polar Signals tried).
Rust can do it, painfully, with constant tokio-compatibility fights (see
MadSim, Turmoil). Zig was practically designed for it.

## Design decisions

Marionette is an opinionated library. The opinions are load-bearing, each
one cuts out a large class of problems that would otherwise make determinism
impossible. If these opinions don't match your project, Marionette is not
for you, and that's fine.

### Single-threaded simulated components

Your service's simulated components must run on a single OS thread.
Determinism and real threads don't mix without kernel-level tools like rr or
Hermit, which are far outside this project's scope.

If your production code needs parallelism, the approach is:

- Run multiple `World` instances in separate OS threads, each is
  deterministic on its own.
- Isolate the parallel parts behind an interface Marionette simulates
  sequentially. Test the coordination logic; trust OS primitives.
- Accept that some subsystems aren't Marionette-tested. Cover them with
  traditional tools.

This is the same choice TigerBeetle made. VOPR tests an entire replicated
cluster on a single thread. DST works when you shape your system to be
testable, not when the testing tool tries to paper over a multi-threaded
design.

If what you need is adversarial scheduling of concurrent data structures,
you want a Shuttle-style tool, not Marionette. That's a valid project,
just not this one.

### No faketime, no LD_PRELOAD, no syscall interception

Marionette will never ship a `libfaketime`-style shim to intercept `std.time`
calls from code that wasn't written against our interfaces. The premise of
the project is that Zig's interface-passing idioms make DST natural. If we
needed LD_PRELOAD, we'd be admitting the premise is wrong.

Practical consequence: you have to route all time, randomness, disk, and
network through Marionette's interfaces. We help you hold that line with
a build-time linter (see below), but we don't intercept your calls behind
your back.

### Determinism is enforced, not hoped for

"Just be careful about `std.time`" is not a plan. Marionette enforces
determinism in four layers:

1. **API design.** The right path is the easy path. `World.clock()` is
   right there; nobody reaches for `std.time.nanoTimestamp` unless they're
   fighting the library.
2. **Build-integrated linter.** Marionette's `addTidyStep` is a one-line
   addition to your `build.zig` that scans your source for banned calls
   (`std.time.*`, `std.Thread.spawn`, `std.crypto.random`, etc.). It runs
   as part of `zig build test`, no separate tool to remember, no CI hook
   to forget. Build fails on violation.

   ```zig
   // your build.zig
   const marionette = b.dependency("marionette", .{});

   const tidy = marionette.addTidyStep(b, .{
       .paths = &.{ "src", "tests" },
   });
   tests.step.dependOn(&tidy.step);
   ```

3. **Twice-and-compare runtime detector.** Every simulated scenario runs
   twice with the same seed. If the traces differ, something leaked.
   You can't ignore this, your test just failed.
4. **Documentation.** The rest is a question of knowing the gotchas.

The combination is what makes the determinism guarantee credible. No single
layer is enough; together, they cover accidents well enough that real users
can trust them.

## Roadmap

Marionette is being built in phases. Each has a clear exit criterion so you
can judge whether it's ready for your use case.

**Phase 0, Proof of concept** _(current)_
Core interfaces (Clock, Random). Single-node toy examples. The twice-and-
compare detector and a basic linter. A test suite that proves deterministic
replay actually works. Not usable for real projects yet.

**Phase 1, Single-node MVP**
Stable Clock, Random, and Disk interfaces with fault injection. Linter
upgraded from substring matching to AST-based. Adoptable for single-node
services that need reproducible testing.

**Phase 2, Multi-node**
Network simulator (partitions, drops, reorders, delays). Node spawning. A
real example: a small consensus protocol tested end-to-end under arbitrary
network faults.

**Phase 3, Production-grade**
Linearizability checking. Time-travel debugging. Seed shrinking. Trace
export. Dependency audit tooling.

**Phase 4, Ecosystem**
Talks, case studies, a "Marionette-compatible" ecosystem for libraries that
commit to determinism.

Rough timeline: Phase 0 in weeks, Phase 1 in 2–3 months, Phase 2 in 4–7
months, Phase 3 by month 12. These are estimates from someone who has
learned not to trust their own estimates, so treat them as such.

## Is this for me?

**Yes, eventually, if you're building:**

- A distributed system of any kind (consensus, replication, leader election)
- A database, queue, or storage engine
- A service where correctness matters more than feature velocity
- Anything that has to survive network partitions and machine failures
- A single-threaded or single-threaded-per-core architecture

**No, if you're building:**

- A CRUD web app. DST is overkill. Use normal tests.
- Something inherently non-deterministic (ML training, GUIs, graphics).
- A project that needs to ship this quarter. Marionette isn't ready yet.
- A multi-threaded service you're not willing to restructure. Marionette's
  simulated components are single-threaded; this is permanent.

**Maybe, if you're building:**

- A concurrent-but-not-distributed system. You might want a Shuttle-style
  tool instead.

## Installation

Not yet. Phase 0 is not published. When Phase 0 is done, installation will
be a standard `build.zig.zon` dependency. Watch the repo for releases, or
check back when Phase 1 ships.

## Prior art and acknowledgments

Marionette stands on the shoulders of a lot of thinking that happened
elsewhere. The core ideas are not ours:

- **FoundationDB** pioneered deterministic simulation testing in the late
  2000s. Will Wilson's 2014 Strange Loop talk is still the best introduction.
- **TigerBeetle** built the VOPR (Viewstamped Operation Replicator), the
  most sophisticated DST system in the Zig ecosystem. Their work is the
  direct inspiration for Marionette, and their public writing on the
  subject is essential reading. The linter approach is directly inspired
  by their `src/tidy.zig`.
- **Antithesis** built a hypervisor that provides DST for arbitrary
  containerized workloads. Different approach, same goal. They're a
  company; we're a library.
- **MadSim, Turmoil, and Shuttle** in the Rust ecosystem showed what
  library-level DST can look like and where the sharp edges are.

If you want to understand the technique deeply before using the library,
read TigerBeetle's VOPR docs and Phil Eaton's
[writeup on DST](https://notes.eatonphil.com/2024-08-20-deterministic-simulation-testing.html).

## Contributing

Not yet accepting contributions. The API is in flux during Phase 0 and
PRs from outside would be more friction than help. Once Phase 0 lands,
this will open up.

If you're interested in the direction, the most useful thing you can do
right now is open an issue describing the service you'd want to test with
Marionette and what pain points you hit with existing Zig testing. That
directly shapes Phase 1's API.

## License

TBD. Will be MIT or Apache-2.0 at Phase 0 release.

## Name

Marionette, because you control every string: the clock, the random number
generator, the disk, the network. Nothing moves in your test that you
didn't move.
