# Marionette

Deterministic simulation testing for Zig.

Write your code against `env`. In tests, drive `control` to inject faults. The
same code runs on the simulator and on real hardware.

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

That parity is the point. You do not write a simulator version of your code.
You write your code once, and Marionette gives you a deterministic environment
to run it in.

## Why

Distributed and storage systems fail in ways that are hard to reproduce: a
torn write under crash, a network partition during quorum, or a race between
two timers. By the time you have a stack trace, the conditions that caused the
bug are gone.

Deterministic simulation testing turns those bugs into seeds. Every run is
reproducible. Every failure is replayable. Marionette brings that approach to
Zig as a library, not a framework you have to build your system around.

## A Complete Example

Here's a WAL recovery test that crashes the disk mid-write, corrupts a sector,
and asserts that committed records survive while unsynced ones do not.

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
```

Three pieces show up in every test:

- **`init`** sets up your harness: your code under test plus the `control`
  handle for fault injection.
- **`scenario`** drives the action. It calls into your code through `env` and
  into the simulator through `control`.
- **`checks`** assert invariants on the final state.

## Env And Control

Every Marionette test has two surfaces.

**`env`** is what application code sees. It exposes non-generic capabilities
such as `disk`, `clock`, randomness, and tracing. Typed capabilities such as
`Network(Payload)` are passed alongside `env`, so `Env` stays one concrete
type.

```zig
try env.disk.write(.{ .path = "kv.wal", .offset = 0, .bytes = &bytes });
const now = env.clock.now();
```

**`control`** is what tests use to inject faults. It is only available in
simulation and mirrors `env`'s structure.

```zig
try control.disk.crash();
try control.disk.corruptSector(path, offset);
try control.network.partition(&side_a, &side_b);
try control.network.setFaults(.{ .drop_rate = .percent(20) });
try control.network.heal();
```

## Distributed Simulation

Network simulation follows the same split. Scenario code controls partitions,
latency, drops, and healing; application code keeps using its network
authority.

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

Messages have configurable drop rates, latency distributions, and reordering
through `control.network.setFaults(...)`. Application code sends through the
typed network handle and drains deterministic deliveries with
`while (try net.nextDelivery()) |packet|`.

## Traces

Every run produces a structured trace. When a check fails, the trace shows the
events that led to the violation plus the seed needed to reproduce it.

```text
register.write.start version=1 value=41 retry_limit=8
register.message kind=propose to=0 version=1 value=41
replica.accept replica=0 version=1 value=41 accepted=true
register.message kind=propose to=1 version=1 value=41
replica.accept replica=1 version=1 value=41 accepted=true
register.write.quorum version=1 value=41 acks=2
register.invariant_violation kind=committed_divergence replica=1 ...
```

Trace records can come from application code, scenario code, and checks.
Passing runs return traces for persistence, diffing, or external tooling.

## Docs

- [Overview](overview.md)
- [Architecture](architecture.md)
- [Trace Format](trace-format.md)
- [Run](run.md)
- [API Target Spec](api-target.md)
- [BUGGIFY](buggify.md)
- [Network Model](network.md)
- [Network API Direction](network-api.md)
- [Disk Fault Model](disk-fault-model.md)
- [API](api.md)
- [Determinism](determinism.md)
- [Examples](examples.md)
- [Roadmap](roadmap.md)
- [Prior art](prior-art.md)
- [TigerBeetle Lessons](tigerbeetle-lessons.md)
- [Blog](blog/index.md)

## Status

Marionette is early. The API shape is converging but not yet stable; expect
breaking changes between minor versions until 0.1. The simulator currently
models disk, network, and clock; allocator simulation is in progress.

The [`examples/`](../examples/) directory is the best place to start.

## Install

```sh
zig fetch --save https://github.com/sb2bg/marionette/archive/<commit>.tar.gz
```

Requires Zig 0.16.x.

## Acknowledgments

Marionette stands on the shoulders of FoundationDB's simulation testing,
TigerBeetle's VOPR, and the broader DST tradition.
