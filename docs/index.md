# Marionette

Deterministic I/O and simulation testing for Zig.

Long term, Marionette is aiming to be the deterministic `std.Io` for Zig:
production libraries accept `std.Io`, and tests swap in Marionette's
deterministic implementation. Today, Marionette ships the simulator, trace,
fault, disk, and network primitives that make that direction concrete.

Write production-shaped code against `std.Io` plus any small Marionette handles
it actually needs, such as `mar.Recorder` or `mar.Endpoint(Message)`. In tests,
drive `control` to inject faults. For the modeled file and local endpoint
surfaces, the same application logic can run on the simulator and on production
adapters.

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

That parity is the point. You do not write a simulator version of your code.
You write your code behind Marionette-owned authorities, and Marionette gives
you a deterministic environment to run it in.

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
- **`scenario`** drives the action. It calls into your code through the handles
  created by `env`, and into the simulator through `control`.
- **`checks`** assert invariants on the final state.

## Io And Control

Every Marionette test has two surfaces.

**`io`** is what production-shaped storage code should usually see. In
simulation, `sim.env.io()` returns Marionette's deterministic `std.Io` backend.
In production, `production.env().io()` returns the host `std.Io` supplied at
setup. Application code that wants trace events should accept a narrow
`mar.Recorder`, not all of `mar.Env`.

```zig
var store = try KVStore.init(io, root, recorder);
try store.put(1, 41, .sync);
```

**`control`** is what tests use to inject faults. It is only available in
simulation and mirrors `env`'s structure.

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

Messages have configurable loss, latency, clogs, and partition dynamics
through focused `control.network` calls such as `setLossiness(...)`,
`setLatency(...)`, and `setPartitionDynamics(...)`. Application code sends
through a node-scoped endpoint with `endpoint.send(to, message)` and receives
with `while (try endpoint.receive()) |envelope|`.

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
- [Findings](findings.md)
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

The [`examples/`](../examples/) directory is the best place to start.

## Install

```sh
zig fetch --save https://github.com/sb2bg/marionette/archive/<commit>.tar.gz
```

Requires Zig 0.16.x.

## Acknowledgments

Marionette stands on the shoulders of FoundationDB's simulation testing,
TigerBeetle's VOPR, and the broader DST tradition.
