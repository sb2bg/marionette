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

Simulated time is owned by the world. `mar.SimClock` advances only when the
caller explicitly ticks or sleeps it; application code reads time through
`env.clock` (or, in `std.Io`-shaped code, `std.Io.Clock.*` over the
environment's `io()`). Production code reads host time through the `std.Io`
its composition root already owns; Marionette does not wrap host time.

All timestamps and durations are nanoseconds:

```zig
pub const Timestamp = u64;
pub const Duration = u64;
```

## `Env`

Application code should receive explicit authorities from its caller instead of
constructing them itself. Storage-oriented code should usually take `std.Io`,
a root `std.Io.Dir`, and a narrow `mar.Recorder`; code that needs Marionette's
clock, random hooks, or other simulator capabilities can take `mar.Env`:

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

`mar.Env` is the concrete harness-facing capability bundle. Its disk, clock,
random, and tracer authorities are fields, not lazy accessors. `env.io()`
returns the backing `std.Io`: host I/O in production envs, and Marionette's
current deterministic backend in simulation envs. `env.recorder()` returns a
narrow structured recording capability for code that should not depend on all
of `Env`.

Production-shaped libraries should prefer taking the smallest capabilities they
need. For example, code that only needs I/O and trace events can accept
`std.Io` plus `mar.Recorder`:

```zig
fn put(io: std.Io, recorder: mar.Recorder, key: u64, value: u64) !void {
    _ = io;
    try recorder.record("kv.put key={} value={}", .{ key, value });
}
```

Simulation builds app and harness views together through `World.simulate`:

```zig
fn scenario(world: *mar.World) !void {
    const sim = try world.simulate(.{});
    try service(sim.env);
}
```

`sim.env` supplies the handles passed to application code. `sim.control` is
kept by the harness for simulator-only actions such as advancing time or
crashing disk.
`simulate` options also include `task_stack_size` for scheduler-backed
`std.Io` tasks (default 1 MiB). Raise it when a simulated SUT's call chains
run deep; on guard-page targets stacks cost address space, not resident
memory, and overflow faults at a 256 KiB guard region instead of corrupting
neighboring memory.
On POSIX guard-page targets, an overflow fault also produces a targeted
stderr diagnostic before the fault proceeds: the task id, owning process,
configured stack size, and the `task_stack_size` fix, after which the fault
chains to the previously installed signal handler (Zig's Debug handler still
prints the fault-site trace). This installs a process-global
`SIGSEGV`/`SIGBUS` handler on first task spawn; embedders that own their
signal dispositions can disable it with
`simulate(.{ .fiber_overflow_diagnostics = false })`. Faults outside fiber
guard regions chain through with no added output.
`env.buggify` draws through the env's random capability only when the env was
built by simulation; production envs construct the same composition bundle with
production adapters such as `mar.RealDisk`.

## `World`

`mar.World` owns deterministic simulation engine state:

- One `SimClock`.
- One seeded `Random`.
- One trace log.

Application code should receive explicit handles from the composition root, not
`World` directly.
Scenarios and harnesses use `World` to construct simulations, drive time, and
inspect trace bytes.
Each `World` constructs at most one simulation. A failed `simulate` attempt
rolls back its resources and leaves the world available for another attempt.

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

Phase 0 traces start with `marionette.trace format=text version=1`. Every
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

## Allocation

`env.allocator()` returns the app-facing `std.mem.Allocator`. Production envs
return the backing allocator passed to `Production.init`, with no added
faults. Simulation envs return a deterministic allocation authority that
wraps the harness allocator with modeled failures and address-free tracing.

Configure faults at simulation setup:

```zig
const sim = try world.simulate(.{ .allocation = .{
    .fail_after = 32,
} });
```

Or from scenario code through the control surface:

```zig
try control.allocation.setFaults(.{ .quota_bytes = 4096 });
try control.allocation.setFaults(.{ .buggify_rate = .percent(25) });
try control.allocation.setFaults(.{}); // heal
```

Fault semantics:

- `fail_after` counts successful allocation and growth requests over the
  whole simulation, not since the last `setFaults` call. `fail_after = 0`
  fails every subsequent growth request.
- `quota_bytes` bounds modeled live bytes. Growth requests that would exceed
  the quota fail; frees and shrinks return budget.
- `buggify_rate` draws a seeded roll per growth request and fails the request
  when the roll fires. Shrinking operations and frees never fail.

`control.allocation.stats()` returns address-free counters: operation index,
successful allocations, live bytes, and total allocated and freed bytes.

Allocation faults model failure timing and resource pressure, not address
determinism. The addresses returned by the backing allocator are not part of
the deterministic contract and never appear in traces.

Every allocation operation is traced by default, including frees, resizes,
and remaps: leak diagnosis needs the free events, and OOM diagnosis needs the
operation sequence. Modeled app allocations are expected to be deliberate and
scarce, so this is the readable default; if a real workload floods traces, a
quieter profile can be added later without changing what the default records.

Modeled application allocations stay separate from Marionette's internal
bookkeeping: this surface cannot inject harness OOM, and a modeled app OOM
does not corrupt simulator state. The tidy linter rejects
`std.heap.page_allocator` in simulated code; pass an allocator explicitly
instead.

## Disk

`mar.Disk` is the lower-level disk capability beneath Marionette's `std.Io`
backend. It is a concrete, storable handle with sector-oriented `read`,
`write`, and `sync`, plus path-level `stat`, EOF-aware `readSome`,
`setLength`, `delete`, and `rename`.
`mar.SimDisk` is the deterministic
in-memory simulator behind that handle: logical files, sector-aligned
reads/writes, sparse sectors, deterministic latency, operation ids, trace
events, replayable read/write/corruption faults, and crash/restart behavior
for pending writes. `mar.RealDisk` is the production adapter backed by a real
root directory. `mar.Disk.unavailable()` remains the honest null-object for
envs without storage.

Construct a world-owned simulator bundle, then hand app code either `std.Io`
for ordinary file code or the lower-level sector disk capability when a test
needs that explicit surface:

```zig
const sim = try world.simulate(.{ .disk = .{
    .sector_size = 4096,
    .min_latency_ns = 1_000_000,
    .latency_jitter_ns = 2_000_000,
} });

const io = sim.env.io();
const disk = sim.env.disk; // low-level sector API
```

`sim.env.io()` is node 0's default process I/O. Multi-node `std.Io.net`
scenarios should use `sim.envForNode(node).io()` so listeners and clients keep
stable process identity across reconnects.

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

const stat = try disk.stat(.{ .path = "wal.log" });
const read_len = try disk.readSome(.{
    .path = "wal.log",
    .offset = 0,
    .buffer = wal_buffer,
});
try disk.setLength(.{ .path = "wal.log", .len = 0 });
try disk.rename(.{ .old_path = "compact.tmp", .new_path = "data.db" });
try disk.delete(.{ .path = "wal.log" });
```

Construct a production capability bundle by scoping it to a root directory:

```zig
var production = try mar.Production.init(.{
    .allocator = allocator,
    .root_dir = root_dir,
    .io = io,
    .disk = .{ .sector_size = 4096 },
});
defer production.deinit();

const env = production.env();
```

`Production` owns the production capability adapters and exposes the same
`Env` shape that simulation returns. Its disk adapter accepts relative paths,
creates parent directories on write, reads missing or short files as
zero-filled sectors, and uses the same sector alignment checks as `SimDisk`.
Logical file paths use canonical rooted syntax: non-empty `/`-separated
components, no `.`, `..`, empty components, backslashes, NUL, or host absolute
roots. `.` is reserved for the root directory in `syncDir`.
That validator is a namespace boundary, not a full portable filename profile.
It guarantees rooted, non-traversing logical syntax and keeps host absolute
paths and current-working-directory behavior out of app code. It does not
guarantee identical behavior across host filesystems: case sensitivity,
Unicode normalization, Windows reserved names and alternate streams, trailing
dots/spaces, and path limits may still differ. Uppercase, Unicode, and
ordinary punctuation remain accepted by the logical syntax today. Complete
host filename parity requires a future opt-in portable filename profile or a
production `std.Io` wrapper that can enforce the same policy in simulation and
production.

The `io` argument is the production host I/O backend used to perform
filesystem calls and provide host randomness. `production.env().io()` returns
that same host `std.Io`. Simulation envs return Marionette's current
deterministic `std.Io` backend; `sim.envForNode(node).io()` returns the
process-scoped backend for a specific simulated node. The backend supports
deterministic clock/random operations, scheduler-backed `Io.async` /
`Io.concurrent` / await, scheduler-backed `Io.Group`, immediate non-blocking
`Io.Queue` operations, and an in-memory TCP stream subset today. Cancellation
currently waits for completion; cooperative cancellation points remain future
work. The backend also supports a directory-aware file subset over `SimDisk`:
create/open, access/statFile, positional and streaming read/write,
length/stat/setLength, sync, close, delete, rename, directory
create/open/stat/iteration, and process-coordinated blocking and non-blocking
advisory locks. Directory namespace state is shared by all simulated processes
through `SimDisk`. Streaming cursor state is per open file handle, advances
only by bytes actually transferred, and is left unchanged by failed streaming
operations. Full filesystem behavior, process operations, datagrams, DNS, and
real external network access still fail closed. See
[`std.Io` Direction](std-io-direction.md).
Simulated file stats report deterministic size, kind, and mutation-time
information. `mtime` updates on successful content mutations; access and change
timestamps remain zero because Marionette does not yet model them.
Simulated storage tests should prefer `world.simulate(...).env.io()` for code
that naturally uses `std.Io.File`. The `Disk` returned by
`world.simulate(...).env.disk` remains the low-level sector/file-lifecycle
surface for examples that intentionally test Marionette's disk model directly;
harness code keeps the matching `DiskControl` for faults, crash, restart, and
corruption.

Low-level disk-shaped code uses the attached `Disk` field and only the
app-facing operations:

```zig
const sim = try world.simulate(.{
    .disk = .{ .sector_size = 4096 },
});

fn appendRecord(disk: mar.Disk, sector_bytes: []const u8) !void {
    try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = sector_bytes });
    try disk.sync(.{ .path = "wal.log" });
    try disk.syncDir(.{ .path = "." });
}
```

The `Disk` view exposes `read`, `write`, `sync`, `syncDir`, `stat`,
`readSome`, `setLength`, `delete`, and `rename`.
Simulator-control operations such as `setFaults`, `crash`, `restart`, and
`corruptSector` remain on `mar.DiskControl`, exposed through
`sim.control.disk`, and are kept by the harness or scenario state.

For sector-oriented `read` and `write`, offsets and lengths must be whole
multiples of `sector_size`. `readSome` and `setLength` are byte-oriented for
WAL iteration and file lifecycle code. Reads from unwritten sectors return
zero bytes; `readSome` returns the number of bytes copied and does not fill
past EOF. Logical paths are not host paths and are escaped through
`World.recordFields` in trace events:

```text
disk.write op=0 path=wal.log offset=0 len=4096 status=ok latency_ns=1000000
disk.read op=1 path=wal.log offset=0 len=4096 status=ok latency_ns=1000000
disk.sync op=2 path=wal.log status=ok committed_writes=1 latency_ns=1000000
disk.sync_dir op=3 path=. status=ok committed_metadata=1 latency_ns=1000000
disk.stat op=4 path=wal.log status=ok size=4096 latency_ns=1000000
disk.read_some op=5 path=wal.log offset=0 requested_len=32 read_len=32 status=ok latency_ns=1000000
disk.set_length op=6 path=wal.log len=0 status=ok committed_writes=0 latency_ns=1000000
disk.rename op=7 path=compact.tmp new_path=data.db status=ok committed_writes=0 latency_ns=1000000
disk.delete op=8 path=wal.log status=ok committed_writes=0 latency_ns=1000000
```

File `sync` commits pending file contents. `syncDir` commits directory-entry
metadata for creates, deletes, and renames in that logical directory. Without
`syncDir`, a crash can keep file contents while losing the directory entry,
matching the classic parent-directory-fsync storage bug class. Cross-directory
renames require syncing both parent directories before the rename is fully
durable.

`RealDisk.syncDir` currently returns `error.DirectorySyncUnsupported`. Zig
0.16 does not expose a portable directory-sync operation through `std.Io`, so
the production adapter fails explicitly instead of reporting durability it did
not establish.

Faults are disabled by default. Enable them through `mar.DiskControl`:

```zig
const control = sim.control.disk;
try control.setFaults(.{
    .read_error_rate = .oneIn(100),
    .write_error_rate = .oneIn(100),
    .corrupt_read_rate = .oneIn(1_000),
    .crash_lost_write_rate = .oneIn(10),
    .crash_torn_write_rate = .oneIn(10),
    .crash_reordered_write_rate = .oneIn(10),
    .crash_lost_metadata_rate = .oneIn(10),
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
durable in-memory model. Scenario code can inject persistent scripted sector
corruption with:

```zig
try control.corruptSector("wal.log", 0);
```

That simulator-control API records `disk.fault ... kind=scripted_corruption`;
later reads covering that sector return `status=corrupt`.

Writes are visible to later reads immediately, but they are pending until
`sync`. A crash processes pending writes according to the crash fault profile:
each pending write may land, be lost, be torn, or be applied out of issue
order. Synced writes are already committed and are not lost by crash.

```zig
try disk.write(.{ .path = "wal.log", .offset = 0, .bytes = sector_bytes });
try control.crash();
try control.restart();
```

While crashed, disk operations return `error.DiskCrashed`. Crash outcomes are
trace-visible. In simulation, `control.crash()` also kills every live logical
process after pending-write outcomes are applied; `control.restart()` brings
only the disk back up. Rerun registered application initializers with
`sim.control.process.restart(node)`.

```text
disk.fault op=3 path=wal.log kind=crash_lost_write rate=1/10 roll=7 fired=false
disk.fault op=3 path=wal.log kind=crash_torn_write rate=1/10 roll=0 fired=true
disk.crash_write op=3 path=wal.log offset=0 len=4096 result=torn
disk.crash pending_writes=1 landed=0 lost=0 torn=1 reordered=0
disk.restart status=ok
```

Process lifecycle is explicit on the `Sim` returned by `World.simulate`.
`sim.registerProcess(node, lifecycle)` registers the initializer, while
`sim.control.process.kill(node)` tears down one logical process and
`sim.control.process.restart(node)` reruns the registered initializer with
that node's `Env`. Invalid nodes return `error.InvalidNode`; restarting
without a registered lifecycle returns `error.ProcessNotRegistered`.

Per-node crash/restart dynamics live on the same process-control handle:

```zig
try sim.registerProcess(0, .{
    .ptr = &state,
    .on_kill = State.onKill,
    .restart = State.restart,
});
try sim.control.process.setDynamics(0, .{
    .crash_rate = .percent(1),
    .restart_rate = .percent(10),
    .crash_stability_min_ns = 10 * ns_per_ms,
    .restart_stability_min_ns = 50 * ns_per_ms,
});
```

Process dynamics evolve only through `sim.control.tick()` or positive
`sim.control.runFor(...)` boundaries. Automatic crashes record
`process.kill reason=auto_crash`; automatic restarts rerun the registered
lifecycle and record `process.restart automatic=true`. Invalid rates return
`error.InvalidRate`; stability durations must be tick-aligned or
`setDynamics` returns `error.InvalidDuration`.

## Network

`mar.Endpoint(Message)` is the app-facing network handle. Simulation and
production setup both return this typed endpoint shape, while simulator-control
faults remain on `control.network`.

See [Network Model](network.md) for the design contract and current limits.
See [Network API Direction](network-api.md) for the split between app-facing
network authority and test-only simulator-control operations.

```zig
const Message = struct { value: u64 };

const sim = try world.simulate(.{ .network = .{
    .nodes = 4,
    .path_capacity = 64,
} });
const sender = try sim.endpoint(Message, 0);
const receiver = try sim.endpoint(Message, 1);

try sim.control.network.setLossiness(.{ .drop_rate = .percent(20) });
try sim.control.network.setLatency(.{
    .min_latency_ns = 1_000_000,
    .latency_jitter_ns = 2_000_000,
});
try sender.send(1, .{ .value = 42 });

while (try receiver.receive()) |envelope| {
    _ = envelope.from;
    _ = envelope.message;
}
```

`send` records `network.send` or `network.drop`. `receive` records
`network.deliver`, advances world time when the next queued packet is in the
future for that endpoint, and returns `null` when the endpoint has no pending
messages.

Latency values must align with the world's tick size because simulated
delivery and fault-evolution boundaries are tick-aligned.

When a simulation owns time-evolved faults, advance time through simulation
control:

```zig
try sim.control.tick();
try sim.control.runFor(10 * ns_per_ms);
```

This advances the backing world and evolves network fault state at
deterministic control boundaries. Long `runFor` calls may jump between
boundaries rather than iterating every tick in the interval.

Nodes are up by default. Mark one down or up with:

```zig
try sim.control.network.setNode(1, false);
try sim.control.network.setNode(1, true);
```

Directed links can be disabled and re-enabled:

```zig
try sim.control.network.setLink(0, 1, false);
try sim.control.network.setLink(0, 1, true);
```

Directed paths can also be clogged for a simulated duration:

```zig
try sim.control.network.clog(0, 1, 100 * ns_per_ms);
try sim.control.network.unclog(0, 1);
```

Partitions disable every directed link crossing between two groups:

```zig
const left = [_]mar.NodeId{0};
const right = [_]mar.NodeId{ 1, 2 };
try sim.control.network.partition(&left, &right);
try sim.control.network.heal();
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

## `runSimCase`, `runCase`, And `run`

`mar.runSimCase(opts)` is the primary stateful simulation runner. It
initializes fresh `SimCase(App)` state for each replay attempt, executes a
scenario twice with the same seed, runs named checks, and compares
byte-identical traces.

`mar.runCase(opts)` remains available for custom or low-level state.
`mar.run(allocator, options, scenario)` is the lower-level world-only runner for
scenarios that do not need structured state.

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
const tags = [_][]const u8{ "example:replicated_register", "scenario:smoke" };
const attributes = [_]mar.RunAttribute{
    mar.runAttribute("replicas", @as(u64, 3)),
    mar.runAttribute("packet_loss_percent", @as(u8, 20)),
};

var report = try mar.run(std.testing.allocator, .{
    .seed = 0x1234,
    .name = "smoke",
    .tags = &tags,
    .attributes = &attributes,
}, scenario);
```

`name`, `tags`, and `attributes` are recorded into the trace before
scenario code runs and are included in failure summaries. Tags are loose
searchable labels. Attributes are stable scalar facts needed to reproduce the
run without forcing tools to parse presentation strings. Use
`mar.runAttribute` to build attributes; keys are written explicitly so exported
metadata names never silently track internal field renames. Runtime behavior
should read from the config, not from derived attributes.

Named simulation profiles package common run metadata, static simulator setup,
and runtime fault controls. A profile must still be expanded and applied
explicitly: `simulateOptions()` configures `World.simulate`, `runTags()` and
`runAttributes()` make the expanded values visible in traces and failure
summaries, and `apply(control)` sets runtime controls such as network loss,
latency, clogs, and partition dynamics.

```zig
fn swarmProfile() mar.SimProfile.Expanded {
    return mar.SimProfile.swarm(.{
        .tick_ns = tick_ns,
        .network = .{
            .nodes = replica_count + 1,
            .service_nodes = replica_count,
            .path_capacity = max_messages,
        },
    }).expand();
}

fn scenario(case: *Case) !void {
    const profile = swarmProfile();
    try profile.apply(case.control());
    try case.app.write(.{ .version = 1, .value = 41, .retry_limit = 6 });
}

const profile = swarmProfile();
var report = try mar.runSimCase(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .name = "replicated-register-swarm",
    .tags = profile.runTags(),
    .attributes = profile.runAttributes(),
    .simulate = profile.simulateOptions(),
    .init = initReplicas,
    .scenario = scenario,
    .checks = &checks,
});
```

The built-in profile names are `baseline`, `swarm`, `replay`, and
`performance`. `replay` is intentionally just an exact carrier for explicit
values; pass the values from a failure summary back into the profile options
rather than relying on hidden generation. Network runtime controls are reported
as nonzero metadata only when a network topology is present. `performance`
defaults disk latency to zero and runtime faults to off.

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

Simulation scenarios should usually use `runSimCase` and `SimCase(App)`. The
app initializer receives `mar.Sim` directly, while scenarios and checks receive
the standard case wrapper:

```zig
const Case = mar.SimCase(Model);

const Model = struct {
    env: mar.Env,
    committed: bool = false,
};

fn initModel(sim: mar.Sim) Model {
    return .{ .env = sim.env };
}

fn scenario(case: *Case) !void {
    try case.control().tick();
    case.app.committed = true;
    try case.env().record("model.commit", .{});
}

fn committed(case: *const Case) !void {
    if (!case.app.committed) return error.NotCommitted;
}

const state_checks = [_]mar.StateCheck(Case){
    .{ .name = "committed", .check = committed },
};

var report = try mar.runSimCase(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .name = "model-smoke",
    .simulate = .{},
    .init = initModel,
    .scenario = scenario,
    .checks = &state_checks,
});
defer report.deinit();
```

`runSimCase` initializes fresh state for each replay attempt: it creates the
`World`, records run metadata, calls `world.simulate(config.simulate)`, passes
the resulting `mar.Sim` to `init`, and then runs the scenario and checks over
`*mar.SimCase(App)`. Use `case.app` for application state and `case.control()`
for simulator authority. `case.env()`, `case.envForNode(...)`,
`case.endpoint(...)`, and related helpers forward to the underlying `mar.Sim`.
`case.io()` and `case.ioForNode(node)` are the std.Io-facing equivalents for
single-node and node-scoped simulated I/O.

Use `runCase` when state really is custom or low-level. It passes the attempt's
`World` into the initializer and leaves simulation setup entirely to the state
type. If custom state owns non-world resources, provide
`.deinit = State.deinit`; the deinitializer runs once per replay attempt after
scenario execution and checks. `SimCase(App)` automatically calls `app.deinit()`
when `App` defines that method.

Tests that only need pass/fail behavior can skip report handling:

```zig
try mar.expectSimPass(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .simulate = .{},
    .init = initModel,
    .scenario = scenario,
    .checks = &state_checks,
});

try mar.expectSimFuzz(.{
    .allocator = std.testing.allocator,
    .seed = 0x1234,
    .seeds = 1000,
    .simulate = .{},
    .init = initModel,
    .scenario = scenario,
    .checks = &state_checks,
});
```

Use `mar.expectSimFailure` when proving a simulation checker catches a
known-buggy scenario. Use `mar.expectFailure` for custom `runCase` state.
Use the lower-level `mar.run` for world-only scenarios. The older
`runWithState*` positional helpers are internal implementation details.

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
build. Expose that file from your dependency as a build module, then import it:

```zig
const marionette = @import("marionette_build");

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
