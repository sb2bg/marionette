<p align="center">
  <a href="https://sb2bg.github.io/marionette/">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="assets/transparent_logo_text_dark.png">
      <source media="(prefers-color-scheme: light)" srcset="assets/transparent_logo_text.png">
      <img src="assets/transparent_logo_text.png" alt="Marionette" width="420">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://sb2bg.github.io/marionette/">Docs and blog</a>
</p>

[![CI](https://github.com/sb2bg/marionette/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sb2bg/marionette/actions/workflows/ci.yml)

Deterministic simulation testing for Zig.

Write your code against `env`. In tests, drive `control` to inject faults. The same code runs on the simulator and on real hardware.

```zig
fn writeAndRecover(env: mar.Env) !KVStore {
    var store = KVStore.init(env);
    try store.put(1, 41, .sync);
    try store.put(2, 99, .no_sync);
    try store.recover(.strict);
    return store;
}

// In simulation: deterministic, fault-injectable, replayable from a seed.
const sim = try world.simulate(.{ .disk = .{ .sector_size = 16 } });
var sim_store = try writeAndRecover(sim.env);

// In production: real disk, same code path.
var production = try mar.Production.init(.{ .root_dir = tmp.dir, .io = std.testing.io });
var prod_store = try writeAndRecover(production.env());
```

That parity is the whole point. You don't write a "simulator version" of your code. You write your code, and Marionette gives you a deterministic environment to run it in.

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
- **`scenario`** drives the action. It calls into your code via `env`, and into the simulator via `control`.
- **`checks`** assert invariants on the final state.

`expectPass` runs once with a fixed seed. `expectFuzz` runs many seeds in parallel. `expectFailure` asserts that a deliberately-buggy scenario gets caught, useful for proving your checker actually works.

## The two surfaces: `env` and `control`

Every Marionette test has two halves.

**`env`** is what your application code sees. It exposes non-generic resources such as `disk`, `clock`, randomness, and tracing. Typed resources such as `Network(Payload)` are passed alongside `env`, so `Env` stays one concrete type.

```zig
try env.disk.write(.{ .path = "kv.wal", .offset = 0, .bytes = &bytes });
const now = env.clock.now();
```

**`control`** is what your test code uses to inject faults. It's only available in simulation. It mirrors `env`'s structure: every resource has a control surface.

```zig
try control.disk.crash();
try control.disk.corruptSector(path, offset);
try control.network.partition(&side_a, &side_b);
try control.network.setFaults(.{ .drop_rate = .percent(20) });
try control.network.heal();
```

This split is the whole API. Adding a new resource means adding it to both surfaces. You never have to learn a third concept.

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

Messages have configurable drop rates, latency distributions, and reordering through `control.network.setFaults(...)`. Application code sends with `net.send(from, to, payload)` and can drain deterministic deliveries with `while (try net.nextDelivery()) |packet|`.

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

You write trace records with `env.record(...)` from anywhere. Application code, scenario code, checks. Failed runs print the trace automatically. Passing runs hand it back to you so you can persist it, diff it, or feed it to whatever observability you already have.

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

Marionette is early. The API shape is converging but not yet stable; expect breaking changes between minor versions until 0.1. The simulator currently models disk, network, and clock; allocator simulation is in progress.

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
