# Marionette

Deterministic I/O and simulation testing for Zig.

Long term, Marionette is aiming to be the deterministic `std.Io` for Zig:
production libraries accept `std.Io`, and tests swap in Marionette's
deterministic implementation. Today, Marionette ships the simulator, trace,
fault, disk, and network primitives that make that direction concrete.

The current validation targets include an unmodified storage engine
(`xit-vcs/xitdb`), an unmodified cooperative-concurrency library
(`g41797/mailbox`), the pinned Ochi storage engine, the unmodified
`lalinsky/dusty` HTTP client/server library, the unmodified
`g41797/beanstalkz` queue client, and an external-style client/server KV
service whose SUT imports only `std.Io.net`.

Write production-shaped code against `std.Io` wherever possible, and add small
Marionette handles only when the application actually needs them. In tests,
drive `control` to inject faults. `Production.env()` supplies host I/O and the
rooted real disk; application-owned protocol seams receive Marionette endpoints
only in simulation.

```zig
const mar = @import("marionette");

fn writeAndRecover(io: std.Io, root: std.Io.Dir) !KVStore {
    var store = try KVStore.init(io, root);
    try store.put(1, 41, .sync);
    try store.put(2, 99, .no_sync);
    try store.recover(.strict);
    return store;
}

// In simulation: deterministic, fault-injectable, replayable from a seed.
var world = try mar.World.init(std.testing.allocator, .{ .seed = 0xC0FFEE });
defer world.deinit();

const sim = try world.simulate(.{ .disk = .{ .sector_size = 16 } });
var sim_store = try writeAndRecover(sim.env.io(), std.Io.Dir.cwd());

// In production: real disk, same code path.
var tmp = std.testing.tmpDir(.{});
defer tmp.cleanup();

var production = try mar.Production.init(.{
    .allocator = std.testing.allocator,
    .root_dir = tmp.dir,
    .io = std.testing.io,
});
defer production.deinit();

const prod_env = production.env();
var prod_store = try writeAndRecover(prod_env.io(), tmp.dir);
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
const Case = mar.SimCase(WalStore);

pub fn scenario(case: *Case) !void {
    const store = &case.app;
    const disk = case.control().disk;

    try store.put(committed_key, committed_value, .sync);
    try disk.setFaults(.{ .crash_lost_write_rate = .always() });
    try store.put(volatile_key, volatile_value, .no_sync);
    try disk.crash();
    try disk.restart();
    try disk.corruptSector(wal_path, record_size);
    try store.reopen();
    try store.recover(.strict);
}

pub const checks = [_]mar.StateCheck(Case){
    .{ .name = "synced records recover, unsynced records are rejected", .check = recoveredStateIsSafe },
};

test "wal recovery" {
    try mar.expectSimPass(.{
        .allocator = std.testing.allocator,
        .seed = 0xC0FFEE,
        .simulate = .{},
        .init = WalStore.init,
        .scenario = scenario,
        .checks = &checks,
    });
}
```

`mar.SimCase(App)` is the standard wrapper for simulation tests: `init`
receives `mar.Sim`, `scenario` receives `*mar.SimCase(App)`, and app state
lives at `case.app`. Harnesses that need lower-level `World` access or
unusual ownership drive `mar.World` directly.

Three pieces show up either way:

- **`init`** sets up app state from `mar.Sim`.
- **`scenario`** drives the action through `case.app` and simulator authorities
  such as `case.control()`.
- **`checks`** assert invariants on the final state, usually through
  `*const mar.SimCase(App)`.

## Io And Control

Every Marionette test has two surfaces.

**`io`** is what production-shaped storage code should usually see. In
simulation, `sim.env.io()` returns node 0's deterministic `std.Io` backend, and
multi-node `std.Io.net` code should use `sim.envForNode(node).io()` for stable
per-process node identity.
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
fn partitionScenario(case: *Case) !void {
    const isolated = [_]mar.NodeId{0};
    const majority = [_]mar.NodeId{ 1, 2, client_node_id };

    try case.control().network.partition(&isolated, &majority);
    try case.app.write(.{ .version = 1, .value = 41, .retry_limit = 2 });

    try case.control().network.heal();
    try case.app.write(.{ .version = 1, .value = 41, .retry_limit = 1 });

    try checkReplicaCommitted(&case.app, 0, 1, 41);
}
```

Messages have configurable loss, latency, clogs, and partition dynamics
through focused `control.network` calls such as `setLossiness(...)`,
`setLatency(...)`, and `setPartitionDynamics(...)`. Application code sends
through a node-scoped endpoint with `endpoint.send(to, message)` and receives
with `while (try endpoint.receive()) |envelope|`.

## std.Io.net Client/Server Validation

The [`std_io_net_kv`](https://github.com/sb2bg/marionette/blob/main/examples/std_io_net_kv.zig)
SUT is ordinary `std.Io.net` code. Its harness injects latency and a
delivery-time partition, observes `error.Timeout`, heals the link, retries the
same PUT, and checks that the mutation was applied exactly once. A planted
buggy mode deterministically violates that oracle.

See [Testing std.Io.net Code Deterministically](std-io-net-example.md) for the
runnable commands, trace, and unsupported boundary.

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
- [std.Io.net Client/Server Example](std-io-net-example.md)
- [Disk Fault Model](disk-fault-model.md)
- [API](api.md)
- [Determinism](determinism.md)
- [Examples](examples.md)
- [Roadmap](roadmap.md)
- [Prior art](prior-art.md)
- [TigerBeetle Lessons](tigerbeetle-lessons.md)
- [Releasing](releasing.md)
- [Blog](blog/index.md)

## Status

Marionette is early. This is a `0.x` release: there is no API stability
guarantee before 1.0. The intended-stable surface today is `World`, `Env`,
`Control`, `SimCase`, `runSimCase` / `expectSim*`,
`Disk`, `SimDisk`, `RealDisk`, `Production`, and `Recorder`. The public
`Endpoint(Message)` message-modeling surface remains experimental while its
ownership and transport contract are validated against a real SUT.

The simulator currently models clock, deterministic randomness, disk, a
directory-aware `std.Io.File`/`Dir` subset, experimental typed message modeling, a narrow scheduler-backed
`std.Io.net` stream subset with deterministic latency, timeout, partition,
healing behavior, and literal-only host lookup (an unmodified
`std.http.Client` runs against simulated servers; real DNS stays
unsupported), and cooperative `std.Io` tasks, groups, and futex waits for
`Mutex` / `Condition` code, validated against the pinned `g41797/mailbox`
target, the internal bounded-queue capability demo, pinned Ochi storage, and
the pinned `lalinsky/dusty` HTTP library. Simulated disk
operations park scheduler tasks until their completion deadlines rather than
skipping earlier timers. When network simulation is configured, each node also
has a process-scoped `std.Io` backend; `killProcess` and registered restart
lifecycles model process death and explicit application restart.
The simulator also models deterministic allocation faults through
`Env.allocator()` and cooperative cancellation: `Future.cancel` and
`Group.cancel` deliver `error.Canceled` at futex, sleep, and net suspension
points following `std.Io`'s one-shot protocol. A one-shot
`sim.transitionToLiveness(core)` ends the fault regime so bounded runs can
prove the core makes progress once faults stop.
It does not model arbitrary OS thread scheduling or memory-level concurrency;
code that depends on those needs separate testing.
Networking has two sibling testing altitudes. Node-scoped `std.Io.net` is the
canonical literal same-code path for codecs, framing, partial I/O, and stream
lifecycle. Experimental `Endpoint(Message)` explores protocol/state-machine
behavior above the wire; production uses an application-owned transport seam,
and Marionette does not claim that the real transport runs through the endpoint
model. The former Marionette-owned production adapters were removed in 0.6.
Queue suspension and broader scheduler parity are planned.

Scheduler-backed fibers are tested on Linux and macOS. The x86_64 Windows
fiber path is deliberately disabled until its Win64 entry ABI has execution
coverage. `RealDisk.syncDir` returns `error.DirectorySyncUnsupported` because
Zig 0.16 does not expose a portable directory-sync operation.

The [`examples/`](https://github.com/sb2bg/marionette/tree/main/examples)
directory is the best place to start.

## Install

```sh
zig fetch --save https://github.com/sb2bg/marionette/archive/refs/tags/v0.5.0.tar.gz
```

Then wire the module into your test build in `build.zig` and import it:

```zig
const marionette = b.dependency("marionette", .{
    .target = target,
    .optimize = optimize,
});
tests_module.addImport("marionette", marionette.module("marionette"));
```

```zig
const mar = @import("marionette");
```

Consumer builds stay lean: depending on Marionette pulls in Marionette
alone, never its validation targets or their pinned third-party
dependencies.

Requires Zig 0.16.x.

## Acknowledgments

Marionette stands on the shoulders of FoundationDB's simulation testing,
TigerBeetle's VOPR, and the broader DST tradition.
