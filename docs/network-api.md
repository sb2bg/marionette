# Network API Direction

This document describes the current network API direction. The simulator pieces
exist today; production networking and a non-generic
`World.simulate(...).network(Payload)` accessor are still future work.

Marionette should eventually let application code use the same network handle
in production and simulation. The composition root chooses the backing
environment; service code should not care whether packets are real sockets or
deterministic simulator events.

## Current Status

Today, production networking does not exist in Marionette. The current network
surface is a typed simulator handle built by `NetworkSimulation`:

```zig
const Payload = struct { value: u64 };
const Sim = mar.NetworkSimulation(Payload, .{
    .node_count = 3,
    .client_count = 1,
    .path_capacity = 64,
});

const authorities = try world.simulate(.{});
var sim = try Sim.init(authorities.control);

const net = sim.network();
try sim.control().network.setFaults(.{ .drop_rate = .percent(20) });
try net.send(3, 0, .{ .value = 42 });

while (try net.nextDelivery()) |packet| {
    try apply(packet.payload);
}
```

`NetworkSimulation` owns one packet core and exposes two views over it:
`sim.network()` for app-shaped sends and deterministic delivery, and
`sim.control().network` for test-only fault orchestration. The packet core owns
a fixed topology, per-link packet queues, packet ids, seeded drops, latency,
and deterministic delivery order.

## Two Surfaces

The network API has two separate surfaces:

- App-facing network authority.
- Simulator-control authority.

Application code should use the app-facing authority. Test scenarios and
simulation harnesses should use the simulator-control authority.

This split keeps production-shaped code portable without giving it test-only
powers such as partitioning the network, stopping nodes, or changing drop
rates.

## App-Facing Authority

The current app-facing authority is a typed sibling handle passed alongside
`Env`:

```zig
fn write(env: mar.Env, net: Network, payload: Payload) !void {
    try env.record("write.start", .{});
    try net.send(client_node_id, 1, payload);
}
```

This is deliberately not a field on `Env`. `Env` is one non-generic type, while
`Network(Payload)` is payload-specialized. A future generic accessor or named
bus registry may hide this behind a composition root, but the current API keeps
the typing constraint explicit.

Simulation setup wires both handles into production-shaped code:

```zig
fn init(world: *mar.World) !Harness {
    const authorities = try world.simulate(.{});
    var sim = try Sim.init(authorities.control);
    return .{
        .replicas = Replicas.init(authorities.env, sim.network()),
        .control = sim.control(),
        .sim = sim,
    };
}
```

The application-shaped code depends on `Env` plus the typed network handle, not
on `control`, `World`, `std.net`, or `UnstableNetwork`.

## Simulator-Control Authority

The simulator-control authority is for tests, scenarios, and future schedulers:

```zig
try sim.control().network.setFaults(.{ .drop_rate = .percent(20) });
try sim.control().network.setNode(1, false);
try sim.control().network.clog(0, 1, 100 * ns_per_ms);
try sim.control().network.partition(&left, &right);
try sim.control().network.heal();
```

These calls are not app behavior. They are fault orchestration. They should not
be required or available in ordinary production service code.

The important constraint is that fault orchestration is separate from the
app-shaped send path. `send` takes only `from`, `to`, and `payload`.

## Production Path

Production network adapters are not implemented yet.

The likely production path is an adapter over Zig's IO and networking APIs.
Marionette should not freeze that adapter before Zig's `std.Io` direction is
stable enough to build on. The current rule is:

- Do not invent a large permanent socket ecosystem.
- Keep app-facing network requirements narrow.
- Route production through host IO at the composition root.
- Route simulation through deterministic simulator machinery.
- Keep simulator-control operations out of production service code.

## Simulation Path

A non-generic `World.simulate(...).network(Payload)` accessor is not implemented
yet. The likely simulation path is:

```text
World.simulate(...).network(Payload)
  -> app-facing typed network handle
  -> simulator-owned scheduler/network state
  -> UnstableNetwork-like packet core
  -> World clock, World PRNG, World trace
```

The current `UnstableNetwork` is the packet core in this chain. It proves the
deterministic pieces before Marionette commits to the final composition-root
API.

The packet core already has a declared topology and per-link queues. The
composition layer still needs to provide the final process-facing authority for
application code without forcing `Env` itself to become generic.

## Non-Goals For Now

Marionette is not trying to support all of production networking in the first
network API. These are intentionally unresolved:

- Generic `World.simulate(...).network(Payload)` or named bus registry.
- TCP versus UDP shape.
- Stream versus datagram ownership.
- Listener and connection lifetime.
- Backpressure semantics.
- TLS.
- Real DNS.
- Arbitrary `std.net` compatibility.
- Cross-process simulation.

The first stable app-facing network should be narrow enough to test a small
multi-node service, then grow from real examples.

## Migration Rule

Do not treat `UnstableNetwork` as the final user-facing production API.

Code that uses:

```zig
mar.NetworkSimulation(Payload, options)
```

is using a simulator primitive. Code that reaches for `sim.packetCore()` is
writing harness or low-level simulator code, not production-shaped service
code. Production-ready Marionette code should eventually depend on `Env` plus a
production-backed typed network handle with the same call shape as
`NetworkSimulation.network()`.
