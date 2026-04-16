# Architecture

This document records Marionette's foundational correctness contract. If a
future feature weakens this contract, it needs an explicit design discussion.

## Determinism Contract

Given the same Marionette version, Zig version, target platform, user code,
simulation options, and seed, a Marionette simulation must produce the same
declared result and byte-identical Marionette trace across repeated runs. The
guarantee applies only to behavior routed through Marionette-controlled
authorities: simulated time, seeded randomness, future disk, future network,
future scheduling, and explicit trace events. Marionette does not guarantee
stability for host wall-clock time, OS thread scheduling, stack or heap
addresses, pointer identity, unordered map iteration, external syscalls, data
read from real devices, or behavior from dependencies that bypass the
simulator. A nondeterminism leak is a correctness bug, not a flaky test.

## Current State

Phase 0 has:

- `World`, which owns one simulated clock, one seeded PRNG, and one trace log.
- `Clock(.production)` and `Clock(.simulation)`.
- A seeded `Random` wrapper.
- Fixed-seed trace comparison tests.
- Many-seed deterministic fuzz-style tests.
- An AST-based tidy linter for obvious nondeterministic calls, including
  simple const aliases such as `const time = std.time;`.

Phase 0 does not yet have:

- `marionette.run`.
- A scheduler.
- Disk or network simulation.
- Invariant registration.
- Liveness checking.
- Seed shrinking.
- Syscall interception.

## IO Strategy

Marionette is a library-first simulator. User code should pass explicit
authorities at the top of the program instead of reaching for host globals.

For Phase 0, Marionette owns small interfaces for time and randomness because
they are needed now and they are not solved by `std.Io`. For disk and network,
the long-term preference is to align with Zig's `std.Io` direction rather than
inventing a permanent incompatible ecosystem. The migration plan is:

- Keep Marionette's public effect surface narrow while `std.Io` is unstable.
- Model disk and network behind adapters that can wrap `std.Io` when its shape
  settles.
- Avoid promising compatibility with arbitrary direct `std.fs`, `std.net`, or
  OS calls.
- Track Zig master and expect API churn before Zig 1.0.

If `std.Io` changes, Marionette should absorb that churn inside adapters, not
make every user rewrite their simulation tests.

## Time Model

Phase 0 time is an integer nanosecond virtual clock. There is exactly one
clock authority per `World`, and simulated code should receive that authority
instead of calling `std.time`.

Current behavior:

- `now()` reads the world's current simulated timestamp.
- `tick()` advances by the world's configured tick duration.
- `runFor(duration)` advances by whole ticks.
- `sleep(duration)` on `SimClock` is currently an immediate deterministic
  advance because there is no scheduler yet.

Future scheduler behavior must preserve the same authority: sleeps,
deadlines, timers, retries, network latency, and disk latency all route
through the world's clock. A scheduler may advance time to the next event, but
it must not introduce a second clock.

## Randomness Model

There is exactly one seeded PRNG per `World`. Every simulator choice must draw
from it: packet latency, disk latency, BUGGIFY, crash timing, workload
generation, scheduling choices, and future shrink decisions.

Current `World.random()` exposes a raw deterministic `std.Random` view for
ergonomics. Draws through that view are deterministic, but not automatically
traced. When a draw matters to replay diagnostics, use traced helpers such as
`randomU64()` and `randomBool()`.

Direct `std.crypto.random`, unseeded randomness, `/dev/urandom`, wall-clock
seeding, and host entropy are banned inside simulated code. The tidy linter is
the first guard. Twice-and-compare trace replay is the backstop. A future
paranoid mode should make simulator-incompatible effects fail loudly.

## Smallest User Program

The target shape is deliberately close to ordinary Zig dependency passing:

```zig
const std = @import("std");
const mar = @import("marionette");

fn client(world: *mar.World) !void {
    const latency_ns = try world.randomU64() % 1_000_000;
    world.clock().sleep(latency_ns);
    try world.record("client.request latency_ns={}", .{latency_ns});
}

test "single request is replayable" {
    var world = try mar.World.init(std.testing.allocator, .{ .seed = 0x1234 });
    defer world.deinit();

    try client(&world);
}
```

This is not yet the final multi-node API. The target Phase 2 version should
let the user pass a simulator-provided network authority in the same style,
without rewriting the application around a Marionette-only runtime.

## Production Cost And BUGGIFY

Fault hooks must not pollute production hot paths. The intended Zig shape is a
comptime-selected simulator authority:

```zig
if (sim.buggify(.drop_packet)) return error.PacketDropped;
```

In simulation builds, `sim.buggify` draws from the world's PRNG and records the
decision when useful. In production builds, `sim` is a production authority and
the branch should fold away when the hook is disabled at comptime. This is the
Zig replacement for FoundationDB-style BUGGIFY macros.

## Failure Surface

When Marionette finds a bug, the minimum useful failure report is:

- Failing seed.
- Simulation options.
- Failure kind.
- Trace bytes or trace path.
- Last event index.
- Reproduction command.

Better reports will add shrinking and a reduced trace. A report that only says
`seed 0x1234 failed` is insufficient.

## Exploration Strategy

Marionette will not claim to solve state-space exploration. Phase 0 and early
Phase 1 use uniform seeded random exploration. That is good enough to prove the
replay contract, not good enough to claim deep distributed-systems coverage.

Planned strategy layers:

- Uniform random choices first.
- Weighted fault profiles after examples reveal real needs.
- Coverage or state feedback only after there is a stable trace/event model.
- Shrinking only after failures are represented as replayable event streams.

Branch coverage alone is a weak signal for distributed simulation quality.

## Invariants And Liveness

Safety invariants are required for real DST. Users need to express properties
like "no two replicas disagree about committed entries" and have the simulator
check them regularly.

Planned API direction:

- Register invariants with the world or scenario.
- Check cheap invariants after every event.
- Allow expensive invariants every N events and on quiescence.
- Include invariant name and event index in failure reports.

Liveness is harder. Marionette should eventually detect stuck systems, unmet
deadlines, and lack of progress under fair scheduling assumptions. This is not
in v0.1, but it is a real requirement for a serious multi-node simulator.

## Testing Marionette

Marionette itself must be tested as if determinism is the product.

Required test classes:

- Same seed, same scenario, byte-identical trace.
- Different seeds eventually explore different traces.
- Tidy catches banned calls and ignores comments/string literals.
- Tidy catches simple aliases to banned call paths.
- Debug and ReleaseSafe builds both pass.
- Future CI should run twice-and-compare on every example.

## Showcase Example

The planned proof example should be a small replicated protocol, not only a
rate limiter. A 500-line Raft, VSR, or primary-backup KV store that Marionette
can break and replay would prove the library much better than toy examples.

Until that exists, Marionette is promising infrastructure, not proven DST.

## Non-Goals

Marionette is not:

- A replacement for unit tests.
- A Jepsen alternative that runs real distributed binaries.
- A syscall interception platform.
- A general OS thread scheduler.
- A guarantee that arbitrary Zig dependencies are deterministic.
- A commitment to support every concurrency primitive in v0.1.

Scope control is part of correctness. It is better to be narrow and true than
wide and almost deterministic.

## Target `run` Walkthrough

`marionette.run(.{ .seed = 0x1234 }, myTest)` does not exist yet. The target
chronology is:

1. Parse options and freeze the seed, start time, exploration profile, max
   event count, and trace settings.
2. Construct one `World`.
3. Create exactly one clock authority and one PRNG authority inside the world.
4. Construct simulated disk, network, scheduler, and BUGGIFY authorities from
   that same world state.
5. Invoke the user's scenario with those authorities.
6. On every event, pick the next simulator decision from the world's PRNG.
7. Route all time movement through the world's clock.
8. Record stable event data into the trace.
9. Check registered safety invariants at configured points.
10. Stop on success, user error, invariant failure, liveness failure, or budget
    exhaustion.
11. Rerun the same scenario with the same seed and compare byte-identical
    traces.
12. If the run failed, print the seed, options, event index, failure kind,
    trace location, and reproduction command.

The dangerous spots are scheduler choice, time advancement, raw randomness,
unordered state dumps, and host APIs. Those must stay under simulator control.
