# API

This document describes the current experimental API. The API is not stable
yet.

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
    const now = env.clock.now();
    const jitter = try env.random.intLessThan(mar.Duration, 1_000);
    if (try env.buggify(.slow_path, .oneIn(10))) {
        try env.clock.sleep(jitter);
    }
    _ = .{ now, jitter };
}
```

`mar.Env` is the concrete app-facing capability bundle. Its disk, clock,
random, and tracer authorities are fields, not lazy accessors.

Simulation builds app and harness views together through `World.simulate`:

```zig
fn scenario(world: *mar.World) !void {
    const sim = try world.simulate(.{});
    try service(sim.env);
}
```

`sim.env` is passed to application code. `sim.control` is kept by the harness
for simulator-only actions such as advancing time or crashing disk.
`env.buggify` draws through the env's random capability only when the env was
built by simulation; production env construction is still being shaped.

## `World`

`mar.World` owns Phase 0 simulation engine state:

- One `SimClock`.
- One seeded `Random`.
- One trace log.

Application code should usually receive `Env`, not `World` directly.
Scenarios and harnesses use `World` to construct simulations, drive time, and
inspect trace bytes.

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

Use structured fields when a value comes from user text, paths, or other
runtime bytes that may contain spaces or separators:

```zig
try world.recordFields("disk.open", &.{
    mar.traceField("path", .{ .text = "/tmp/a b" }),
    mar.traceField("mode", .{ .literal = "read" }),
});
```

The text field is written as `path=/tmp/a%20b`; raw `World.record` remains
strict and returns `error.InvalidTracePayload` for ambiguous formatted values.

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

Application code should usually use `env.random` instead of receiving the
whole `World`:

```zig
const latency_ns = try env.random.intLessThan(u64, 1_000_000);
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

## Disk

`mar.Disk` is the app-facing disk capability. It is a concrete, storable
handle with `read`, `write`, and `sync`. `mar.SimDisk` is the deterministic
in-memory simulator behind that handle: logical files, sector-aligned
reads/writes, sparse sectors, deterministic latency, operation ids, trace
events, replayable read/write/corruption faults, and crash/restart behavior
for pending writes. Production storage adapters are not implemented yet;
`mar.Disk.unavailable()` is the honest null-object for envs without storage.

Construct a world-owned simulator bundle, then hand app code only the disk
capability:

```zig
const sim = try world.simulate(.{ .disk = .{
    .sector_size = 4096,
    .min_latency_ns = 1_000_000,
    .latency_jitter_ns = 2_000_000,
} });

const disk = sim.env.disk;
```

If `DiskOptions.min_latency_ns` is omitted, it defaults to the world's tick
duration. Passing a concrete value keeps that exact value and validates it
against the tick size.

Write and read logical paths:

```zig
try disk.write(.{
    .path = "wal.log",
    .offset = 0,
    .bytes = sector_bytes,
});

try disk.read(.{
    .path = "wal.log",
    .offset = 0,
    .buffer = sector_buffer,
});

try disk.sync(.{ .path = "wal.log" });
```

Application code receives `Env` with an attached `Disk` field and uses only the
app-facing operations:

```zig
const sim = try world.simulate(.{
    .disk = .{ .sector_size = 4096 },
});

fn appendRecord(env: mar.Env, sector_bytes: []const u8) !void {
    try env.disk.write(.{ .path = "wal.log", .offset = 0, .bytes = sector_bytes });
    try env.disk.sync(.{ .path = "wal.log" });
}
```

The `Env.disk` view exposes `read`, `write`, and `sync`.
Simulator-control operations such as `setFaults`, `crash`, `restart`, and
`corruptSector` remain on `mar.DiskControl`, exposed through
`sim.control.disk`, and are kept by the harness or scenario state.

Offsets and lengths must be whole multiples of `sector_size`. Reads from
unwritten sectors return zero bytes. Logical paths are not host paths and are
escaped through `World.recordFields` in trace events:

```text
disk.write op=0 path=wal.log offset=0 len=4096 status=ok latency_ns=1000000
disk.read op=1 path=wal.log offset=0 len=4096 status=ok latency_ns=1000000
disk.sync op=2 path=wal.log status=ok committed_writes=1 latency_ns=1000000
```

Faults are disabled by default. Enable them through `mar.DiskControl`:

```zig
const control = sim.control.disk;
try control.setFaults(.{
    .read_error_rate = .oneIn(100),
    .write_error_rate = .oneIn(100),
    .corrupt_read_rate = .oneIn(1_000),
    .crash_lost_write_rate = .oneIn(10),
    .crash_torn_write_rate = .oneIn(10),
});
```

Invalid rates return `error.InvalidRate`. Read and write errors return
`error.ReadError` and `error.WriteError` after deterministic latency. Fault
decisions are traced when their rate is non-zero:

```text
disk.fault op=3 path=wal.log kind=write_error rate=1/100 roll=42 fired=false
disk.fault op=4 path=wal.log kind=read_error rate=1/100 roll=0 fired=true
disk.read op=4 path=wal.log offset=0 len=4096 status=io_error latency_ns=1000000
```

`corrupt_read_rate` corrupts only the returned buffer; it does not mutate the
durable in-memory model. Harnesses can inject persistent scripted sector
corruption with:

```zig
try control.corruptSector("wal.log", 0);
```

That simulator-control API records `disk.fault ... kind=scripted_corruption`;
later reads covering that sector return `status=corrupt`.

Writes are visible to later reads immediately, but they are pending until
`sync`. A crash processes pending writes according to the crash fault profile:
each pending write may land, be lost, or be torn. Synced writes are already
committed and are not lost by crash.

```zig
try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = sector_bytes });
try control.crash(.{});
try control.restart(.{});
```

While crashed, `read`, `write`, and `sync` return `error.DiskCrashed`.
Crash outcomes are trace-visible:

```text
disk.fault op=3 path=wal.log kind=crash_lost_write rate=1/10 roll=7 fired=false
disk.fault op=3 path=wal.log kind=crash_torn_write rate=1/10 roll=0 fired=true
disk.crash_write op=3 path=wal.log offset=0 len=4096 result=torn
disk.crash pending_writes=1 landed=0 lost=0 torn=1
disk.restart status=ok
```

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

Stateful scenarios should usually use the struct-config runner. It infers the
state type from the initializer, and run metadata such as `profile_name`,
`tags`, and `attributes` is optional:

```zig
const Model = struct {
    env: mar.Env,
    committed: bool = false,

    fn init(world: *mar.World) Model {
        const sim = world.simulate(.{}) catch unreachable;
        return .{ .env = sim.env };
    }
};

fn scenario(model: *Model) !void {
    model.committed = true;
    try model.env.record("model.commit", .{});
}

fn committed(model: *const Model) !void {
    if (!model.committed) return error.NotCommitted;
}

const state_checks = [_]mar.StateCheck(Model){
    .{ .name = "committed", .check = committed },
};

var report = try mar.runCase(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .init = Model.init,
    .scenario = scenario,
    .checks = &state_checks,
});
defer report.deinit();
```

`runCase` initializes fresh state for each replay attempt and passes the
attempt's `World` into the initializer. Initializers may construct world-bound
simulator authorities, but should not record trace events. Stateful scenarios
and state checks receive only state; put environment authorities on the state
when they need to record or advance time.

Tests that only need pass/fail behavior can skip report handling:

```zig
try mar.expectPass(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .init = Model.init,
    .scenario = scenario,
    .checks = &state_checks,
});

try mar.expectFuzz(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .seeds = 1000,
    .init = Model.init,
    .scenario = scenario,
    .checks = &state_checks,
});
```

Use `mar.expectFailure` when proving a checker catches a known-buggy scenario.
The older positional runners remain available for code that needs explicit
lifecycle teardown or world-only scenarios.

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
