# Network API Direction

This document describes the intended production/simulation network API shape.
Some simulator pieces exist today; production networking and `Env.network` are
still future work.

Marionette should eventually let application code use the same network
authority in production and simulation. The composition root chooses the
environment; the service code should not care whether packets are real sockets
or deterministic simulator events.

## Current Status

Today, production networking does not exist in Marionette.

The current network simulator wrapper is:

```zig
const Sim = mar.NetworkSimulation(Payload, .{
    .node_count = 3,
    .client_count = 1,
    .path_capacity = 64,
});
```

`NetworkSimulation` owns one packet core and exposes two views over it:
`sim.network()` for app-shaped sends, and `sim.control().network` for
test-only fault orchestration. The packet core owns a fixed topology, per-link
packet queues, packet ids, seeded drops, latency, and deterministic delivery
order.

## Two Surfaces

The final network shape should have two separate surfaces:

- App-facing network authority.
- Simulator-control authority.

Application code should use the app-facing authority. Test scenarios and
simulation harnesses should use the simulator-control authority.

This split keeps production code portable without giving production code
test-only powers such as partitioning the network or stopping nodes.

## App-Facing Authority

The app-facing authority is what user services receive through `Env`:

```zig
fn service(env: anytype) !void {
    const network = env.network();

    try network.send(.{
        .to = .{ .node = 1 },
        .payload = "ping",
    });

    const message = try network.recv();
    _ = message;
}
```

In simulation:

```zig
fn scenario(world: *mar.World) !void {
    const sim = try world.simulate(.{});
    try service(sim.env);
}
```

The service shape should stay the same. Production routing should use real IO.
Simulation routing should use deterministic packet scheduling, seeded faults,
and trace records.

Exact names such as `send`, `recv`, `listen`, `connect`, addresses, and
payload ownership are not committed yet. The important contract is that user
services talk to an environment-provided network authority, not directly to
`std.net` or to `UnstableNetwork`.

## Simulator-Control Authority

The simulator-control authority is for tests, scenarios, and future
schedulers:

```zig
try sim.control().network.setNode(1, false);
try sim.control().network.clog(0, 1, 100 * ns_per_ms);
try sim.control().network.partition(&left, &right);
try sim.control().network.heal();
```

These calls are not app behavior. They are fault orchestration. They should
not be required or available in ordinary production service code.

Today, these operations live on `NetworkSimulation.control().network`:

```zig
try sim.control().network.setNode(1, false);
try sim.control().network.clog(0, 1, 100 * ns_per_ms);
try sim.control().network.partition(&left, &right);
try sim.control().network.heal();
```

The important constraint is that fault orchestration is separate from the
app-shaped send path. A later `Env` network capability should wrap this again
so application code stops depending on the network simulator type directly.

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

`Env.network` is also not implemented yet.

The likely simulation path is:

```text
Env.network
  -> app-facing node or endpoint authority
  -> simulator-owned scheduler/network state
  -> UnstableNetwork-like packet core
  -> World clock, World PRNG, World trace
```

The current `UnstableNetwork` is the packet core in this chain. It proves the
deterministic pieces before Marionette commits to the final user API.

The packet core already has a declared topology and per-link queues. The env
layer still needs to provide the process-facing authority for application
code; the current simulator-control view is the first half of that split.
`NetworkSimulation.tick()` is the current outer tick for this slice: it
advances the world clock and then evolves network fault state. Future
tick-evolved subsystems should attach to an outer simulation tick rather than
asking users to remember separate subsystem ticks.

## Non-Goals For Now

Marionette is not trying to support all of production networking in the first
network API. These are intentionally unresolved:

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

is using a simulator primitive. Code that reaches for
`sim.packetCore().send(...)` is writing harness code, not production service
code. Production-ready Marionette code should eventually depend on
`env.network()` instead.
