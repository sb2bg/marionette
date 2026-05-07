# Network API Direction

This document describes the current network API shape. Marionette exposes the
same app-facing typed endpoint shape from simulation and production setup. The
production backing is still a local in-process adapter, not a socket stack.

Application code should not care whether messages come from deterministic
simulator events or production IO. The composition root chooses the backing and
threads `env` plus node-scoped endpoints into the service.

## Current Status

The app-facing network surface is `mar.Endpoint(Message)`. An endpoint is bound
to one `NodeId`, so application code can only send as that node and can only
receive messages addressed to that node:

```zig
const Message = union(enum) {
    write: struct { value: u64 },
    ack: struct { value: u64 },
};

const sim = try world.simulate(.{ .network = .{
    .nodes = 4,
    .service_nodes = 3,
    .path_capacity = 64,
} });

const client = try sim.endpoint(Message, 3);
const replica = try sim.endpoint(Message, 0);

try sim.control.network.setLossiness(.{ .drop_rate = .percent(20) });
try client.send(0, .{ .write = .{ .value = 42 } });

while (try replica.receive()) |envelope| {
    try apply(envelope.from, envelope.message);
}
```

`mar.Network(Message)` remains an alias for `mar.Endpoint(Message)` for now, but
new docs and examples should use `Endpoint`.

The simulator network owns a fixed topology, per-link packet queues, packet ids,
seeded drops, latency, node and link state, and deterministic delivery order.
The older `NetworkSimulation(Message, options)` wrapper remains internal to
network tests; public examples should use the composition-root API.

## Two Surfaces

The network API has two separate surfaces:

- App-facing authority: `mar.Endpoint(Message)`.
- Simulator-control authority: `control.network`.

Application code should use endpoints. Test scenarios and simulation harnesses
should use simulator control.

This split keeps production-shaped code portable without giving it test-only
powers such as partitioning the network, stopping nodes, or changing drop rates.

## App-Facing Authority

The app-facing authority is a typed sibling handle passed alongside `Env`:

```zig
fn write(env: mar.Env, endpoint: mar.Endpoint(Message), message: Message) !void {
    try env.record("write.start", .{});
    try endpoint.send(1, message);
}
```

This is deliberately not a field on `Env`. `Env` is one non-generic type, while
`Endpoint(Message)` is message-specialized. Keeping the typed endpoint beside
`Env` avoids making every function that accepts `Env` generic.

Simulation setup wires node-scoped endpoints into production-shaped code:

```zig
fn init(world: *mar.World) !Harness {
    const sim = try world.simulate(.{ .network = .{ .nodes = replica_count + 1 } });

    return .{
        .service = Service.init(
            sim.env,
            try sim.endpoint(Message, client_node_id),
            try sim.endpointRange(Message, replica_count, 0),
        ),
        .control = sim.control,
    };
}
```

The application-shaped code depends on `Env` plus typed endpoints, not on
`control`, `World`, `std.net`, or `UnstableNetwork`.

## Simulator-Control Authority

The simulator-control authority is for tests, scenarios, and future schedulers:

```zig
try sim.control.network.setLossiness(.{ .drop_rate = .percent(20) });
try sim.control.network.setNode(1, false);
try sim.control.network.clog(0, 1, 100 * ns_per_ms);
try sim.control.network.partition(&left, &right);
try sim.control.network.heal();
```

These calls are fault orchestration. They should not be required or available in
ordinary production service code.

The important constraint is that fault orchestration is separate from the
app-shaped send path. App `send` takes only `to` and `message`; the endpoint's
own `NodeId` is the sender.

## Production Path

`Production.endpoint(Message, node)` exists today and returns the same typed
endpoint shape as simulation. Its current backing is local and in-process,
useful for same-process parity tests and for proving that production-shaped code
does not depend on simulator control. It is not a cross-process transport.

A real socket-backed production transport is scoped under roadmap item 15. The
target architecture lives in `docs/network-production.md`: TigerBeetle
MessageBus shape behind the existing endpoint vtable, with length-prefixed
framing, refcounted message pool, lazy connect with seeded jittered backoff,
async close, bounded per-peer queues, and silent-drop send semantics.

The standing rules until 15h ships:

- Do not invent a large permanent socket ecosystem yet.
- Keep app-facing network requirements narrow.
- Route production through host IO at the composition root.
- Route simulation through deterministic simulator machinery.
- Keep simulator-control operations out of production service code.

## Simulation Path

The simulation path is:

```text
World.simulate(...).endpoint(Message, node)
  -> app-facing typed process endpoint
  -> simulator-owned unnamed bus runtime for Message
  -> fixed-topology packet queues
  -> World clock, World PRNG, World trace
```

The composition-root control plane owns the shared topology and fault state.
Endpoint runtimes are created lazily per message type and shared by all node
endpoints of that message type. A simulation may create many endpoints for the
same message type; those endpoints share one unnamed bus.

## Multi-Bus Future

The current API intentionally models one unnamed bus per message type. It does
not foreclose multiple buses. If a later example needs both RPC and gossip in
the same process, the likely extension is an explicit bus key:

```zig
const rpc = try sim.endpoint(Message, .{ .bus = .rpc, .node = 0 });
const gossip = try sim.endpoint(Gossip, .{ .bus = .gossip, .node = 0 });
```

Until that need is driven by a real example, Marionette avoids a public bus
registry. Users can still model protocol variants inside one `union(enum)`
message type, which is the preferred shape for VSR/Raft-style protocols.

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
