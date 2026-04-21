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
through Zig's host IO clock.

`mar.Clock(.simulation)` returns `mar.SimClock`, which advances only when the
caller explicitly ticks or sleeps it.

All timestamps and durations are nanoseconds:

```zig
pub const Timestamp = u64;
pub const Duration = u64;
```

## `Env`

Most application code should receive an environment from its caller instead of
constructing individual authorities itself:

```zig
fn service(env: anytype) !void {
    const now = env.clock().now();
    const jitter = try env.random().intLessThan(mar.Duration, 1_000);
    if (try env.buggify(.slow_path, .oneIn(10))) {
        env.clock().sleep(jitter);
    }
    _ = .{ now, jitter };
}
```

Production chooses production authorities once at the composition root:

```zig
var env = mar.ProductionEnv.init(.{});
try service(&env);
```

Simulation borrows a `World` and routes through traced deterministic
authorities:

```zig
fn scenario(world: *mar.World) !void {
    var env = mar.SimulationEnv.init(world);
    try service(&env);
}
```

`mar.Env(.production)` aliases `mar.ProductionEnv`.
`mar.Env(.simulation)` aliases `mar.SimulationEnv`.

Phase 0 environments expose `clock()`, `random()`, and `buggify()`.
`ProductionEnv.buggify` always returns `false`. `SimulationEnv.buggify` takes
a `BuggifyRate`, draws through the world's PRNG, and records the hook
decision. The hook only decides whether the fault fires; user code still owns
the domain behavior, such as dropping a packet, delaying an operation, or
returning a simulated disk error.

`SimulationEnv` also exposes `tick()`, `runFor()`, and `record()` as
convenience wrappers around the backing world for scenario code. Future disk
and network authorities should be added to this environment shape instead of
relying on auto-detection. Marionette does not currently expose a public
extension point for alternate production authority routing; keeping that closed
avoids locking in a large user-implemented interface while the authority
surface is still growing.

## `World`

`mar.World` owns Phase 0 simulation engine state:

- One `SimClock`.
- One seeded `Random`.
- One trace log.

Application code should usually receive `SimulationEnv`, not `World` directly.
Scenarios and harnesses use `World` to construct envs, drive time, and inspect
trace bytes.

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
try world.record("request.accepted id={}", .{42});
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

Low-level harness code that should not receive the whole `World` can take a
narrow traced random authority. Application code should usually use
`env.random()` instead:

```zig
const random = world.tracedRandom();
const latency_ns = try random.intLessThan(u64, 1_000_000);
```

## Event Queue

`mar.UnstableEventQueue` is a fixed-capacity deterministic event queue. It is
a scheduler sketch for examples, not the final scheduler API. It currently
uses a linear scan on pop; the real scheduler should use a heap once queues get
hot.

```zig
const Event = struct {
    ready_at: u64,
    id: u64,
};

fn lessThan(a: Event, b: Event) bool {
    return a.ready_at < b.ready_at or (a.ready_at == b.ready_at and a.id < b.id);
}

const Queue = mar.UnstableEventQueue(Event, 64, lessThan);
var queue = Queue.init();
try queue.push(.{ .ready_at = 10, .id = 1 });
```

Callers provide the ordering function explicitly. For distributed simulation,
that ordering should be based on stable fields such as `(ready_at, event_id)`,
not pointer identity or hash-map iteration.

## Network

`mar.UnstableNetworkSimulation(Payload, options)` is the first
network/scheduler sketch. It is intentionally not the final public network
API. It gives examples a shared deterministic primitive for fixed topologies,
per-link queues, seeded packet loss, tick-aligned latency, simulator-control
faults, and delivery order by `(deliver_at, packet_id)`.

See [Network Model](network.md) for the design contract and current limits.
See [Network API Direction](network-api.md) for the intended future split
between production/simulation app-facing network authority and test-only
simulator-control operations.

```zig
const Payload = struct { value: u64 };
const Sim = mar.UnstableNetworkSimulation(Payload, .{
    .node_count = 3,
    .client_count = 1,
    .path_capacity = 64,
});

var sim = Sim.init(world);
try sim.packetCore().send(0, 1, .{ .value = 42 }, .{
    .drop_rate = .percent(20),
    .min_latency_ns = 1_000_000,
    .latency_jitter_ns = 2_000_000,
});

while (try sim.packetCore().popReady()) |packet| {
    _ = packet.payload;
}
```

For examples that should run queued packets until no network work remains:

```zig
try sim.drainUntilIdle(context, deliver);
```

`send` records `network.send` or `network.drop`. `popReady` records
`network.deliver`. Latency values must align with the world's tick size because
Phase 0 simulated time advances in whole ticks.

When a network simulation owns time-evolved faults, advance time through the
simulation wrapper:

```zig
try sim.tick();
try sim.runFor(10 * ns_per_ms);
```

This advances the backing world and then evolves network fault state.

Nodes are up by default. Mark one down or up with:

```zig
try sim.network().setNode(1, false);
try sim.network().setNode(1, true);
```

Directed links can be disabled and re-enabled:

```zig
try sim.network().setLink(0, 1, false);
try sim.network().setLink(0, 1, true);
```

Directed paths can also be clogged for a simulated duration:

```zig
try sim.network().clog(0, 1, 100 * ns_per_ms);
try sim.network().unclog(0, 1);
```

Partitions disable every directed link crossing between two groups:

```zig
const left = [_]mar.NodeId{0};
const right = [_]mar.NodeId{ 1, 2 };
try sim.network().partition(&left, &right);
try sim.network().heal();
```

## Seeds

`mar.parseSeed` accepts decimal `u64` seeds and 40-character Git hashes:

```zig
const seed = try mar.parseSeed("000000000000000000000000000000000000002a");
try std.testing.expectEqual(@as(u64, 42), seed);
```

Git hashes are parsed as `u160` hexadecimal values and truncated to the low 64
bits. This is useful for CLI tools and CI jobs that want deterministic seed
variation by commit.

## Trace Summary

`mar.summarize(allocator, trace_bytes)` builds an owned `mar.Summary` from a
Marionette trace. It is a debugging view, not a replay format.

```zig
var summary = try mar.summarize(allocator, trace);
defer summary.deinit();

try summary.writeSummary(writer);
```

The summary output is deterministic and line-oriented. It reports total event
count, final simulated timestamp when present, replay context, subsystem and
event counts, singleton events, network send/drop/delivery counts, drop
reasons, and per-link network counts.

## `run`

`mar.run(allocator, options, scenario)` executes a scenario twice with the same
seed and compares byte-identical traces.

```zig
fn scenario(world: *mar.World) !void {
    try world.tick();
    try world.record("scenario.done", .{});
}

var report = try mar.run(std.testing.allocator, .{ .seed = 0x1234 }, scenario);
defer report.deinit();
```

Runs can carry replay-visible tags and typed attributes:

```zig
const SmokeRunProfile = struct {
    replicas: u64,
    packet_loss_percent: u8,
};

const profile: SmokeRunProfile = .{
    .replicas = 3,
    .packet_loss_percent = 20,
};

const tags = [_][]const u8{ "example:replicated_register", "scenario:smoke" };
const attributes = mar.runAttributesFrom(profile);

var report = try mar.run(std.testing.allocator, .{
    .seed = 0x1234,
    .profile_name = "smoke",
    .tags = &tags,
    .attributes = &attributes,
}, scenario);
```

`profile_name`, `tags`, and `attributes` are recorded into the trace before
scenario code runs and are included in failure summaries. Tags are loose
searchable labels. Attributes are stable scalar facts needed to reproduce the
run without forcing tools to parse presentation strings.
`mar.runAttributesFrom` derives those facts from a scalar-only run profile
struct so the trace-visible values stay tied to the scenario config.

The helper intentionally treats field names as exported attribute keys and
emits fields in declaration order. Use `mar.runAttribute` directly when a
stable exported key should differ from an internal field name. Runtime behavior
should read from the profile, not from derived attributes.

World-only checks can be attached to the run options:

```zig
fn noBadState(world: *mar.World) !void {
    if (std.mem.indexOf(u8, world.traceBytes(), "bad_state") != null) {
        return error.BadState;
    }
}

const checks = [_]mar.Check{
    .{ .name = "no bad state", .check = noBadState },
};

var report = try mar.run(std.testing.allocator, .{
    .seed = 0x1234,
    .checks = &checks,
}, scenario);
defer report.deinit();
```

Stateful scenarios can use `mar.runWithState` and `mar.StateCheck(State)`:

```zig
const Model = struct {
    committed: bool = false,

    fn init() Model {
        return .{};
    }
};

fn scenario(world: *mar.World, model: *Model) !void {
    model.committed = true;
    try world.record("model.commit", .{});
}

fn committed(world: *mar.World, model: *const Model) !void {
    if (!model.committed) return error.NotCommitted;
}

const state_checks = [_]mar.StateCheck(Model){
    .{ .name = "committed", .check = committed },
};

var report = try mar.runWithState(
    std.testing.allocator,
    .{ .seed = 0x1234 },
    Model,
    Model.init,
    scenario,
    &state_checks,
);
defer report.deinit();
```

`runWithState` initializes fresh state for each replay attempt. Phase 0 state
must be plain value state that does not require a deinitializer.

The return value is `mar.RunReport`:

- `.passed` contains the owned trace from the first successful run.
- `.failed` contains a failure report with seed, options, event counts, traces,
  failure kind, error name when available, and check name when a check failed.

`RunFailure.writeSummary(writer)` writes the compact failure line used by
`RunFailure.print()`. Prefer `writeSummary` in tests so failure output stays
stable.

See [Run](run.md) for details.

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

When `mar.run` catches a scenario error return, it preserves the partial trace
through the last completed event and includes that trace in the failure report.
Panics are harder because Zig's default panic path may abort before Marionette
can flush anything; users should prefer error-returning invariant checks for
simulated failures.

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
exits non-zero when banned non-deterministic calls are found. Projects can add
their own exact or prefix bans and file-level or pattern-level allow entries:

```zig
const tidy = marionette.addTidyStep(b, .{
    .paths = &.{ "src", "examples", "tests" },
    .extra_patterns = &.{
        .{
            .needle = "std.heap.page_allocator",
            .reason = "pass an allocator explicitly",
        },
        .{
            .needle = "std.posix",
            .reason = "route host effects through explicit interfaces",
            .match = .prefix,
        },
    },
    .extra_allowed = &.{
        .{ .path = "src/platform.zig", .needle = "std.posix" },
    },
});
```

The current linter is AST-based: it ignores comments and string literals,
supports exact and prefix dotted-path bans, and catches simple const aliases
such as `const time = std.time`. It does not yet perform full semantic import
resolution.
