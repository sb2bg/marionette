# Network API Direction

This document describes the current simulation network API. Marionette
endpoints are simulation-only; production networking uses host `std.Io.net`.
The remaining local/socket-backed production endpoint adapters are deprecated
compatibility code and removal candidates, not a supported parity contract.

Application code should put its protocol behind an application-owned seam.
The composition root supplies simulated endpoints in tests and host networking
in production.

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

The simulator network owns a fixed topology, per-link packet queues, packet ids,
seeded drops, latency, node and link state, and deterministic delivery order.
Older packet-core wrappers remain confined to low-level network tests; public
examples should use the composition-root endpoint API.

## Two Surfaces

The network API has two separate surfaces:

- App-facing authority: `mar.Endpoint(Message)`.
- Simulator-control authority: `control.network`.

Application code should use endpoints. Test scenarios and simulation harnesses
should use simulator control.

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

Simulation setup wires node-scoped endpoints into production-shaped code:

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

## Byte Endpoint

`ByteEndpoint` is the byte-oriented app surface for code that already owns a
wire protocol. It has the same node-scoped shape as `Endpoint(Message)`, but it
makes byte ownership explicit:

- `send(to, bytes)` copies borrowed bytes before returning.
- `acquire(len)` returns a pool-owned buffer.
- `sendMessage(to, message)` transfers an acquired buffer on success.
- `receive()` returns `{ from, message }`; the caller must release the message.

This is the intended integration point for future Zig networking/RPC libraries
that want Marionette as a test backend without exposing `Endpoint(Message)` to
their users.

Encoding and decoding are deliberately the app's job. Marionette moves bytes
deterministically; the wire format, its buffers, and its receive-value
lifetimes belong to the protocol that owns them. The intended shape is:

```zig
const endpoint = try sim.byteEndpoint(server_node);

var buffer: [max_frame_len]u8 = undefined;
try endpoint.send(client_node, encodeResponse(&buffer, response));

const envelope = (try endpoint.receive()) orelse return;
defer envelope.message.release();
try apply(envelope.from, try decodeRequest(envelope.message.bytes()));
```

## Production Path

Endpoints are simulation-only. The "Endpoints Are Sim-Only" decision in
`ROADMAP.md` (2026-07) cancelled the production transport work outright:
production networking is host `std.Io.net`, and Marionette will not ship its
own production socket bus. Reconnect, background receive, and multi-peer
connection management are cancelled with it, not deferred.
`docs/network-production.md` is retained as design history for the cancelled
bus, not as a plan.

What still exists today:

- `Production.endpoint(Message, opts)` returns the same typed endpoint shape
  as simulation over a local in-process adapter. It is a removal candidate;
  prune it when touching that code.
- `Production.byteEndpoint(opts)` uses the same local in-process adapter
  unless `opts.listen` is set, which selects the socket-backed loopback slice
  behind the same `ByteEndpoint` surface. It stays only while a parity test
  still uses it.

The standing rules:

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
- Arbitrary `std.net` compatibility. A narrow deterministic `std.Io.net`
  TCP stream subset is tracked separately as a simulator capability; it
  currently covers scheduler-backed accept/read suspension, latency,
  send-time loss, and delivery-time partition/heal behavior. It preserves
  in-order bytes within a connection and is not the first stable typed endpoint
  API.
- Cross-process simulation.

The first stable app-facing network is narrow enough to test a small multi-node
service, then grow from real examples.
