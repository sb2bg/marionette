<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/transparent_logo_dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/transparent_logo.png">
  <img src="assets/transparent_logo.png" alt="Marionette" width="126px" align="left">
</picture>

### Marionette

Deterministic I/O and simulation testing for Zig.

[![Docs](https://img.shields.io/badge/docs-0a7ea4?style=for-the-badge&logo=readthedocs&logoColor=white)](https://sb2bg.github.io/marionette/)
[![CI](https://img.shields.io/github/actions/workflow/status/sb2bg/marionette/ci.yml?branch=main&style=for-the-badge&logo=github&logoColor=white&label=ci)](https://github.com/sb2bg/marionette/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/zig-0.16-%23F7A41D?style=for-the-badge&logo=zig&logoColor=white)](https://ziglang.org/download)
[![Status](https://img.shields.io/badge/status-alpha-ff7a00?style=for-the-badge)](#status)
[![License](https://img.shields.io/badge/license-MIT-3fb950?style=for-the-badge)](#license)

<hr>

Marionette is a deterministic `std.Io` simulator for Zig. Production libraries
accept ordinary `std.Io`; tests swap in Marionette's seeded, fault-injectable
implementation and get replayable traces.

This is already demonstrated on real Zig code:

- `xit-vcs/xitdb`, a file-backed storage engine, runs unmodified on
  Marionette's deterministic file backend and is checked against a modeled
  randomized workload under crash faults.
- `g41797/mailbox`, a cooperative `Mutex` / `Condition` library, runs
  unmodified on Marionette's scheduler-backed futex backend with byte-identical
  same-seed replay.

The current scope is deterministic simulation for storage, local endpoint
protocols, and cooperative `std.Io` concurrency. It is not a model of
preemptive OS threads, memory-model interleavings, or production-grade
cross-process networking. See [Std.Io Direction](docs/std-io-direction.md) for
the precise concurrency boundary.

Write production-shaped code against `std.Io` plus any small Marionette handles
it actually needs, such as `mar.Recorder` or `mar.Endpoint(Message)`. In tests,
drive `control` to inject faults. For the modeled file, cooperative futex, and
local endpoint surfaces, the same application logic can run on the simulator
and on production adapters.

```zig
fn writeAndRecover(io: std.Io, root: std.Io.Dir, recorder: mar.Recorder) !KVStore {
    var store = try KVStore.init(io, root, recorder);
    try store.put(1, 41, .sync);
    try store.put(2, 99, .no_sync);
    try store.recover(.strict);
    return store;
}

// In simulation: deterministic, fault-injectable, replayable from a seed.
const sim = try world.simulate(.{ .disk = .{ .sector_size = 16 } });
var sim_store = try writeAndRecover(sim.env.io(), std.Io.Dir.cwd(), sim.env.recorder());

// In production: real disk, same code path.
var production = try mar.Production.init(.{ .root_dir = tmp.dir, .io = std.testing.io });
const prod_env = production.env();
var prod_store = try writeAndRecover(prod_env.io(), tmp.dir, prod_env.recorder());
```

That parity is the point. You don't write a "simulator version" of your code.
You write your code behind Marionette-owned authorities, and Marionette gives
you a deterministic environment to run it in.

## Why

Distributed and storage systems fail in ways that are hard to reproduce: a torn write under crash, a network partition during quorum, a race between two timers. By the time you have a stack trace, the conditions that caused the bug are gone.

Deterministic simulation testing turns those bugs into seeds. Every run is reproducible. Every failure is replayable. You compress weeks of fuzz-testing into seconds, and when something breaks in CI, the seed alone is enough to debug it.

Marionette brings that approach to Zig. It's inspired by the techniques behind FoundationDB, TigerBeetle, and Antithesis, but designed to be a drop-in library, not a framework you build your system around.

## A complete example

Here's a WAL recovery test that crashes the disk mid-write, corrupts a sector, and asserts that committed records survive while unsynced ones don't.

```zig
pub fn scenario(harness: *Harness) !void {
    try harness.store.put(committed_key, committed_value, .sync);
    try harness.control.disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try harness.store.put(volatile_key, volatile_value, .no_sync);
    try harness.control.disk.crash();
    try harness.control.disk.restart();
    try harness.control.disk.corruptSector(wal_path, record_size);
    try harness.store.recover(.strict);
}

pub const checks = [_]mar.StateCheck(Harness){
    .{ .name = "synced records recover, unsynced records are rejected", .check = recoveredStateIsSafe },
};

test "wal recovery" {
    try mar.expectPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .init = Harness.init,
        .scenario = scenario,
        .checks = &checks,
    });
}

test "wal recovery fuzz" {
    try mar.expectFuzz(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .seeds = 16,
        .init = Harness.init,
        .scenario = scenario,
        .checks = &checks,
    });
}
```

Three pieces, every test:

- **`init`** sets up your harness: your code under test, plus the `control` handle for fault injection.
- **`scenario`** drives the action. It calls into your code through the handles
  created by `env`, and into the simulator via `control`.
- **`checks`** assert invariants on the final state.

`expectPass` runs once with a fixed seed. `expectFuzz` runs many seeds in parallel. `expectFailure` asserts that a deliberately-buggy scenario gets caught, useful for proving your checker actually works.

## The two surfaces: `io` and `control`

Every Marionette test has two halves.

**`io`** is what production-shaped storage code should usually see. In
simulation, `sim.env.io()` returns Marionette's deterministic `std.Io` backend.
In production, `production.env().io()` returns the host `std.Io` supplied at
setup. Application code that wants trace events should accept a narrow
`mar.Recorder`, not all of `mar.Env`.

```zig
var store = try KVStore.init(io, root, recorder);
try store.put(1, 41, .sync);
```

**`control`** is what your test code uses to inject faults. It's only available in simulation. It mirrors `env`'s structure: every resource has a control surface.

```zig
try control.disk.crash();
try control.disk.corruptSector(path, offset);
try control.network.partition(&side_a, &side_b);
try control.network.setLossiness(.{ .drop_rate = .percent(20) });
try control.network.heal();
```

`Env` is still the harness-owned bundle that supplies `io()`, `recorder()`,
clock/random helpers, and remaining Marionette capabilities. Code that only
needs file I/O should prefer `std.Io` so it stays ordinary Zig code.

## Distributed simulation

Network simulation works the same way. Here's a partition test against a toy replicated register:

```zig
fn partitionScenario(harness: *Harness) !void {
    const isolated = [_]mar.NodeId{0};
    const majority = [_]mar.NodeId{ 1, 2, client_node_id };

    try harness.control.network.partition(&isolated, &majority);
    try harness.replicas.write(.{ .version = 1, .value = 41, .retry_limit = 2 });

    try harness.control.network.heal();
    try harness.replicas.write(.{ .version = 1, .value = 41, .retry_limit = 1 });

    try checkReplicaCommitted(&harness.replicas, 0, 1, 41);
}
```

Messages have configurable loss, latency, clogs, and partition dynamics through focused `control.network` calls such as `setLossiness(...)`, `setLatency(...)`, and `setPartitionDynamics(...)`. Application code sends through a node-scoped endpoint with `endpoint.send(to, message)` and receives with `while (try endpoint.receive()) |envelope|`.

## Traces

Every run produces a structured trace. When a check fails, you get the full sequence of events that led to the violation, plus the seed to reproduce it.

```
register.write.start version=1 value=41 retry_limit=8
register.message kind=propose to=0 version=1 value=41
replica.accept replica=0 version=1 value=41 accepted=true
register.message kind=propose to=1 version=1 value=41
replica.accept replica=1 version=1 value=41 accepted=true
register.write.quorum version=1 value=41 acks=2
register.invariant_violation kind=committed_divergence replica=1 ...
```

You write trace records with `mar.Recorder` or, inside harness-shaped code,
`env.record(...)`. Application code, scenario code, and checks can all record.
Failed runs print the trace automatically. Passing runs hand it back to you so
you can persist it, diff it, or feed it to whatever observability you already
have.

## Docs

- [Overview](docs/overview.md)
- [Architecture](docs/architecture.md)
- [Trace Format](docs/trace-format.md)
- [Run](docs/run.md)
- [API Target Spec](docs/api-target.md)
- [BUGGIFY](docs/buggify.md)
- [Network Model](docs/network.md)
- [Network API Direction](docs/network-api.md)
- [Disk Fault Model](docs/disk-fault-model.md)
- [API](docs/api.md)
- [Determinism](docs/determinism.md)
- [Examples](docs/examples.md)
- [Roadmap](docs/roadmap.md)
- [Prior art](docs/prior-art.md)
- [TigerBeetle Lessons](docs/tigerbeetle-lessons.md)
- [Blog](docs/blog/index.md)

## Status

Marionette is early. This is a `0.x` release: there is no API stability
guarantee before 1.0. The intended-stable surface today is `World`, `Env`,
`Control`, `runCase` / `expect*`, `Disk`, `SimDisk`, `RealDisk`, `Production`,
`Recorder`, and the app-facing `Endpoint(Message)` shape. Everything else may
change as the simulator grows.

The simulator currently models clock, deterministic randomness, disk, a flat
`std.Io.File` subset, typed endpoint networking, and experimental cooperative
`std.Io` futex waits for `Mutex` / `Condition` code, validated against the
pinned `g41797/mailbox` target. It does not model arbitrary OS thread
scheduling or memory-level concurrency; code that depends on those needs
separate testing. The production network path is partial: local same-process
endpoints and experimental framed loopback paths exist, but cross-process
production transport is still roadmap work. Allocator simulation, async/cancel
integration, and broader scheduler parity are planned.

If you're building something where determinism matters and you want to try it, the [`examples/`](examples/) directory is the best place to start. Open issues and PRs welcome.

## Install

```
zig fetch --save https://github.com/sb2bg/marionette/archive/<commit>.tar.gz
```

Requires Zig 0.16.x.

## Acknowledgments

Marionette stands on the shoulders of [FoundationDB's simulation testing](https://apple.github.io/foundationdb/testing.html), [TigerBeetle's VOPR](https://tigerbeetle.com/blog/2023-03-28-random-fuzzy-thoughts), and the broader DST tradition. The bugs they catch are bugs everyone has; this library tries to make catching them easy in Zig.

## License

MIT
