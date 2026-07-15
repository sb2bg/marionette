# Network API Direction

This document describes Marionette's two network-testing altitudes. Node-scoped
`std.Io.net` is the canonical literal same-code surface. Experimental typed
endpoints model protocol behavior above the wire; production uses an
application-owned transport seam. The former Marionette-owned production
endpoint adapters were removed in 0.6 rather than retained as an unsupported
parity contract.

Application code should put its protocol behind an application-owned seam.
The composition root supplies simulated endpoints in tests and host networking
in production.

## Current Status

The experimental app-facing message surface is `mar.Endpoint(Message)`. An
endpoint is bound to one `NodeId`, so application code can only send as that
node and can only receive messages addressed to that node:

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

The simulator network owns a fixed topology, per-link packet queues, packet ids,
seeded drops, latency, node and link state, and deterministic delivery order.
Older packet-core wrappers remain confined to low-level network tests; public
examples should use the composition-root endpoint API.

`Endpoint(Message)` is a protocol-level simulation tool, not a wire transport.
`Message` is copied with ordinary Zig value semantics: inline values are copied,
but pointers, slices, and handles still refer to their original storage.
Marionette does not serialize messages, retain referenced storage, or manage
pointee lifetimes. Prefer value-only messages. If references are unavoidable,
their storage must remain valid and immutable for the entire simulation.

The current operation contract is intentionally narrow:

- `send(to, message)` is synchronous and does not wait for delivery. Success
  does not prove that the message was queued: seeded loss and a down source are
  successful, trace-visible drops. A queued message may still be dropped when
  received if its destination is down or its directed link is disabled.
- Capacity is bounded per directed `(from, to)` path. A full path currently
  returns `error.EventQueueFull`.
- Delivery order is scheduled timestamp followed by packet id. Independent
  latency jitter can therefore reorder messages, even on one directed path.
  There is no separate reorder operation and no duplication or corruption
  fault today.
- `receive()` may advance time to the earliest delivery anywhere on the same
  typed bus. `null` means no message for this endpoint is available at that bus
  scheduling boundary. It does not mean that the endpoint has no later packet,
  is closed, or has reached EOF.
- The destination and directed-link state are checked when a ready packet is
  consumed by `receive()`, not merely when its scheduled timestamp passes.
- Typed endpoint node state is controlled by `control.network.setNode` and is
  separate from process-supervisor state. `killProcess(node)` alone does not
  mark a typed endpoint node down.

Endpoint handles are borrowed from their simulation and must not outlive it.
The current surface has no close, EOF, deadline, cancellation, delivery
acknowledgement, or backpressure contract. Use simulated `std.Io.net` when the
system under test must exercise serialization, framing, partial I/O, stream
ordering, or connection lifecycle.

## Two Network Altitudes

The two data paths make different, complementary guarantees:

- Node-scoped `std.Io.net` exercises the same socket-facing application code,
  codec, framing, partial-I/O handling, and connection lifecycle used with host
  I/O.
- `mar.Endpoint(Message)` explores protocol/state-machine behavior under the
  documented message model. It does not exercise production serialization or
  transport code.

Both paths share simulator-owned topology and fault authority, but neither is
implemented as a wrapper around the other.

## Two Authorities

Each data path remains separate from simulator-control authority:

- Application authority: `std.Io.net` or `mar.Endpoint(Message)`.
- Harness authority: `control.network`.

Application code uses the appropriate data path. Test scenarios and simulation
harnesses use simulator control.

This split keeps production-shaped code portable without giving it test-only
powers such as partitioning the network, stopping nodes, or changing drop rates.

## App-Facing Authority

The app-facing authority is a typed sibling handle. Code that only needs a
trace should take `mar.Recorder`; code that needs Marionette-specific clock or
random capabilities can still take `Env`:

```zig
fn write(recorder: mar.Recorder, endpoint: mar.Endpoint(Message), message: Message) !void {
    try recorder.record("write.start", .{});
    try endpoint.send(1, message);
}
```

This is deliberately not a field on `Env`. `Env` is one non-generic type, while
`Endpoint(Message)` is message-specialized. Keeping the typed endpoint beside
`Env` avoids making every function that accepts `Env` generic.

Simulation setup wires node-scoped endpoints into protocol/state-machine code:

```zig
const Case = mar.SimCase(Service);

fn init(sim: mar.Sim) !Service {
    return Service.init(
        sim.env.recorder(),
        try sim.endpoint(Message, client_node_id),
        try sim.endpoints(Message, replica_count, 0),
    );
}

fn scenario(case: *Case) !void {
    try case.control().network.setLossiness(.{ .drop_rate = .percent(20) });
    try case.app.write(.{ .version = 1, .value = 41 });
}
```

The application-shaped code depends on narrow handles such as `Recorder` plus
typed endpoints, not on `control`, `World`, `std.net`, or the packet core.

Ordinary `std.Io.net` code gets node identity from the simulation environment
rather than from each socket. `sim.env` is node 0 for compatibility; multi-node
stream tests should pass each process its own environment:

```zig
const server_env = try sim.envForNode(0);
const client_env = try sim.envForNode(1);

var listener = try address.listen(server_env.io(), .{});
var client = try address.connect(client_env.io(), .{
    .mode = .stream,
    .protocol = .tcp,
});
```

The same node id is the logical-process id for scheduler-backed `std.Io`.
Killing a process with `sim.killProcess(node)` cancels tasks spawned through
that node's `Io`, closes its listeners/connections, and wakes surviving stream
peers with reset errors. Restart is explicit: register a
`mar.ProcessLifecycle`, then call `sim.restartProcess(node)` to rerun the
initializer with a fresh node-scoped `Env` over durable disk state that survived
the crash/kill sequence.

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

The sibling-network-surfaces decision in `ROADMAP.md` (2026-07) cancelled
Marionette's production transport work outright. Socket-facing production code
uses host `std.Io.net`; message-oriented applications own their production
transport interface and may adapt it to an endpoint in simulation. Matching the
current endpoint vtable alone does not establish behavioral parity. Marionette
will not ship reconnect, background receive, or multi-peer connection machinery
for a generic production bus.
`docs/network-production.md` is retained as design history for the cancelled
bus, not as a plan.

`Production` now exposes host `std.Io` through `Env`; it does not construct
Marionette network endpoints.

The standing rules:

- Keep app-facing network requirements narrow.
- Route socket-facing production through host I/O at the composition root.
- Keep message-oriented production transport application-owned until a real
  SUT drives a shared contract.
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
- Arbitrary `std.net` compatibility. A narrow deterministic `std.Io.net`
  TCP stream subset is tracked separately as a simulator capability; it
  currently covers scheduler-backed accept/read suspension, latency,
  send-time loss, and delivery-time partition/heal behavior. It preserves
  in-order bytes within a connection and remains distinct from the typed
  message model.
- Cross-process simulation.

The typed endpoint remains experimental until a pinned SUT drives an owned or
encoded representation and explicit delivery, readiness, lifecycle,
cancellation, backpressure, and error semantics.
