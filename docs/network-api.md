# Network API Direction

This document describes the intended production/simulation network API shape.
It is a design contract, not implemented public API yet.

Marionette should eventually let application code use the same network
authority in production and simulation. The composition root chooses the
environment; the service code should not care whether packets are real sockets
or deterministic simulator events.

## Current Status

Today, production networking does not exist in Marionette.

The only network implementation is:

```zig
const Network = mar.UnstableNetwork(Payload, capacity);
```

`UnstableNetwork` is a simulation-kernel primitive for examples and scheduler
work. It owns packet ids, seeded drops, latency, link filters, partitions,
node state, and deterministic delivery order. It is not the final app-facing
network API.

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

In production:

```zig
var env = mar.ProductionEnv.init(.{});
try service(&env);
```

In simulation:

```zig
fn scenario(world: *mar.World) !void {
    var env = mar.SimulationEnv.init(world);
    try service(&env);
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
try sim.network().setNode(1, false);
try sim.network().partition(&left, &right);
try sim.network().heal();
```

These calls are not app behavior. They are fault orchestration. They should
not be required or available in ordinary production service code.

Today, these operations live directly on `UnstableNetwork`:

```zig
try network.setNode(world, 1, false);
try network.partition(world, &left, &right);
try network.heal(world);
```

That is acceptable for Phase 0 because examples are still close to the
simulation kernel. A later `SimulationEnv` or scheduler layer should wrap
these operations so examples stop depending on the kernel type directly.

## Production Path

`ProductionEnv.network()` is not implemented yet.

The likely production path is an adapter over Zig's IO and networking APIs.
Marionette should not freeze that adapter before Zig's `std.Io` direction is
stable enough to build on. The current rule is:

- Do not invent a large permanent socket ecosystem.
- Keep app-facing network requirements narrow.
- Route production through host IO at the composition root.
- Route simulation through deterministic simulator machinery.
- Keep simulator-control operations out of production service code.

## Simulation Path

`SimulationEnv.network()` is also not implemented yet.

The likely simulation path is:

```text
SimulationEnv.network()
  -> app-facing node or endpoint authority
  -> simulator-owned scheduler/network state
  -> UnstableNetwork-like packet core
  -> World clock, World PRNG, World trace
```

The current `UnstableNetwork` is the packet core in this chain. It proves the
deterministic pieces before Marionette commits to the final user API.

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
mar.UnstableNetwork(Payload, capacity)
```

is using a simulator primitive. That is fine for examples and internal
network work. Production-ready Marionette code should eventually depend on
`env.network()` instead.
