# Network API Direction

This document describes the current network API shape. Marionette now exposes
the same typed network handle shape from simulation and production setup. The
production handle is still a local in-process adapter, not a socket stack.

Application code should not care whether packets come from deterministic
simulator events or a production backing. The composition root chooses the
backing environment and threads `env` plus typed handles into the service.

## Current Status

The current app-facing network surface is `mar.Network(Payload)`, obtained
from `World.simulate(...).network(Payload)` in tests or
`Production.network(Payload)` in production-shaped setup:

```zig
const Payload = struct { value: u64 };

const sim = try world.simulate(.{ .network = .{
    .nodes = 4,
    .path_capacity = 64,
} });

const net = try sim.network(Payload);
try sim.control.network.setFaults(.{ .drop_rate = .percent(20) });
try net.send(3, 0, .{ .value = 42 });

while (try net.nextDelivery()) |packet| {
    try apply(packet.payload);
}
```

The simulator network owns a fixed topology, per-link packet queues, packet
ids, seeded drops, latency, node and link state, and deterministic delivery
order. The older `NetworkSimulation(Payload, options)` wrapper remains internal
to network tests; public examples should use the composition-root API.

## Two Surfaces

The network API has two separate surfaces:

- App-facing network authority: `mar.Network(Payload)`.
- Simulator-control authority: `control.network`.

Application code should use the app-facing authority. Test scenarios and
simulation harnesses should use the simulator-control authority.

This split keeps production-shaped code portable without giving it test-only
powers such as partitioning the network, stopping nodes, or changing drop
rates.

## App-Facing Authority

The app-facing authority is a typed sibling handle passed alongside `Env`:

```zig
fn write(env: mar.Env, net: mar.Network(Payload), payload: Payload) !void {
    try env.record("write.start", .{});
    try net.send(client_node_id, 1, payload);
}
```

This is deliberately not a field on `Env`. `Env` is one non-generic type, while
`Network(Payload)` is payload-specialized. Keeping the typed handle beside
`Env` avoids making every function that accepts `Env` generic.

Simulation setup wires both handles into production-shaped code:

```zig
fn init(world: *mar.World) !Harness {
    const sim = try world.simulate(.{ .network = .{ .nodes = replica_count + 1 } });
    return .{
        .replicas = Replicas.init(sim.env, try sim.network(MessagePayload)),
        .control = sim.control,
        .sim = sim,
    };
}
```

The application-shaped code depends on `Env` plus the typed network handle, not
on `control`, `World`, `std.net`, or `UnstableNetwork`.

## Simulator-Control Authority

The simulator-control authority is for tests, scenarios, and future schedulers:

```zig
try sim.control.network.setFaults(.{ .drop_rate = .percent(20) });
try sim.control.network.setNode(1, false);
try sim.control.network.clog(0, 1, 100 * ns_per_ms);
try sim.control.network.partition(&left, &right);
try sim.control.network.heal();
```

These calls are not app behavior. They are fault orchestration. They should not
be required or available in ordinary production service code.

The important constraint is that fault orchestration is separate from the
app-shaped send path. `send` takes only `from`, `to`, and `payload`.

## Production Path

`Production.network(Payload)` exists today and returns the same typed handle
shape as simulation. Its current backing is local and in-process, useful for
same-process parity tests and for proving that production-shaped code does not
depend on simulator control. It is not a cross-process transport.

A real socket-backed production transport is scoped under roadmap item 15.
The target architecture lives in `docs/network-production.md`: TigerBeetle
MessageBus shape behind the existing `Network(Payload)` vtable, with
length-prefixed framing, refcounted message pool, lazy connect with seeded
jittered backoff, async close, bounded per-peer queues, and silent-drop
send semantics. Read that doc before picking up any 15a-15h sub-task.

The standing rules until 15h ships:

- Do not invent a large permanent socket ecosystem yet.
- Keep app-facing network requirements narrow.
- Route production through host IO at the composition root.
- Route simulation through deterministic simulator machinery.
- Keep simulator-control operations out of production service code.

## Simulation Path

The simulation path is:

```text
World.simulate(...).network(Payload)
  -> app-facing typed network handle
  -> simulator-owned scheduler/network state
  -> fixed-topology packet queues
  -> World clock, World PRNG, World trace
```

The composition-root control plane owns the shared topology and fault state.
Typed handles are created lazily for each payload type and share that control
state. A simulation may create at most one handle for a given payload type;
requesting the same `Network(Payload)` twice returns
`error.NetworkHandleAlreadyExists` so pending packets cannot be split across
parallel queues accidentally.

## Non-Goals For Now

Marionette is not trying to support all of production networking in the first
network API. These are intentionally unresolved:

- Multiple named buses or bus registry.
- TCP versus UDP shape.
- Stream versus datagram ownership.
- Listener and connection lifetime.
- Backpressure semantics.
- TLS.
- Real DNS.
- Arbitrary `std.net` compatibility.
- Cross-process simulation.

The first stable app-facing network is narrow enough to test a small multi-node
service, then grow from real examples.

## Migration Rule

Use:

```zig
const sim = try world.simulate(.{ .network = .{ .nodes = 4 } });
const net = try sim.network(Payload);
```

The old `NetworkSimulation` wrapper is not exported from the root API. Code
that reaches for packet-core APIs is writing harness or low-level simulator
code, not production-shaped service code.
