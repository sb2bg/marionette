# API

This document describes the current Phase 0 API. The API is not stable yet.

## `Random`

`mar.Random` is a thin wrapper around Zig's default PRNG that forces callers
to provide a seed.

```zig
var rng = mar.Random.init(42);
const random = rng.random();
const value = random.int(u64);
```

The same seed produces the same stream within a single Zig version.

## `Clock`

Clock implementations are selected at comptime:

```zig
const ProdClock = mar.Clock(.production);
const SimClock = mar.Clock(.simulation);
```

`mar.Clock(.production)` returns `mar.ProductionClock`, which reads host time
through `std.time`.

`mar.Clock(.simulation)` returns `mar.SimClock`, which advances only when the
caller explicitly ticks or sleeps it.

All timestamps and durations are nanoseconds:

```zig
pub const Timestamp = u64;
pub const Duration = u64;
```

## `World`

`mar.World` owns Phase 0 simulation state:

- One `SimClock`.
- One seeded `Random`.
- One trace log.

Create a world with an explicit allocator:

```zig
const ns_per_ms: mar.Duration = 1_000_000;

var world = try mar.World.init(std.testing.allocator, .{
    .seed = 0xC0FFEE,
    .tick_ns = ns_per_ms,
});
defer world.deinit();
```

Advance simulated time:

```zig
try world.tick();
try world.runFor(10 * ns_per_ms);
```

Record service-level trace events:

```zig
try world.record("request accepted id={}", .{42});
```

Read the trace:

```zig
const trace = world.traceBytes();
```

The returned trace slice is invalidated by later trace writes.

Phase 0 traces start with `marionette.trace format=text version=0`. Every
later `World.record` line is prefixed with a global `event=<u64>` index.

## Random Choices In A World

`world.unsafeUntracedRandom()` returns a raw `std.Random` view over the
world's seeded PRNG. Raw draws are deterministic, but they are not
automatically traced. The unsafe name is intentional: simulator decisions
should usually use traced helpers.

Use traced helpers when the random choice should appear in the replay trace:

```zig
const value = try world.randomU64();
const enabled = try world.randomBool();
const index = try world.randomIntLessThan(u64, 1_000_000);
```

`randomIntLessThan` uses Zig's rejection-sampling bounded integer helper, so it
does not teach modulo bias.

User code that should not receive the whole `World` can take a narrow traced
random authority:

```zig
const random = world.tracedRandom();
const latency_ns = try random.intLessThan(u64, 1_000_000);
```

## Error Policy

Marionette uses a small error policy:

- Invariant violations use `std.debug.assert`.
- Resource failures return standard Zig errors.
- Expected simulated faults will use domain-specific errors when Disk and
  Network exist.

Today, most fallible `World` methods fail only because trace logging can
allocate. That means standard allocator errors are the right surface for now.

Examples of assertions:

- `tick_ns` must be greater than zero.
- `runFor(duration)` must use a duration that is an exact multiple of the
  world's tick size.
- Simulated timestamp arithmetic must not overflow.

Examples of returned errors:

- Trace allocation failure.
- Trace formatting allocation failure.

The project may add named aliases like `TraceError` once the trace API
settles, but it should not invent broad custom errors until there are real
domain failures to expose.

When a future `marionette.run` wrapper catches a scenario error return, it
should preserve the partial trace through the last completed event and include
that trace in the failure report. Panics are harder because Zig's default panic
path may abort before Marionette can flush anything; users should prefer
error-returning invariant checks for simulated failures.

## Build Support

`src/build_support.zig` exposes a helper for wiring `marionette-tidy` into a
build:

```zig
const marionette = @import("src/build_support.zig");

const tidy = marionette.addTidyStep(b, .{
    .paths = &.{ "src", "examples", "tests" },
});
test_step.dependOn(&tidy.step);
```

The helper builds the `marionette-tidy` executable and creates a run step that
exits non-zero when banned non-deterministic calls are found. The current
linter is AST-based: it ignores comments and string literals, and catches
simple const aliases such as `const time = std.time`. It does not yet perform
full semantic import resolution.
