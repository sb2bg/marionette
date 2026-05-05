# Production Network Transport: Design Plan

This document is a forward-looking plan, not a current specification. It
describes the target shape for Marionette's production-side
`Network(Payload)` once it grows from a same-process FIFO into a real
cross-process transport. It is the source of truth for roadmap item 15
("App-facing typed network composition: production transport").

The current production handle is documented in `docs/network-api.md`. The
simulation network is documented in `docs/network.md`. This file covers the
production-side architecture only.

## Why this is a real engineering project

Marionette's parity claim is "the same code runs in production and under the
simulator." Today that claim is true only inside a single OS process: a
sender's bytes reach a receiver because both share an in-memory queue. The
moment a service uses Marionette across hosts, parity breaks.

Closing that gap requires a production transport that:

- accepts a topology of peer addresses at startup,
- frames messages on the wire so torn reads cannot cross a message boundary,
- pools and bounds the memory used for in-flight messages,
- manages outbound connections with reconnect and backoff,
- exposes the same `Network(Payload)` vtable that simulation already exposes,
- preserves the application code path so production-shaped code never branches
  on whether the network is real.

This is not a small library. TigerBeetle's MessageBus is roughly a thousand
lines of Zig dedicated to exactly this problem, and that count excludes their
IO backend.

## Reference: TigerBeetle's MessageBus

The closest fully-realized example in the Zig ecosystem. Studied in detail in
`docs/tigerbeetle-lessons.md` lesson 15. Quick recap of the shape:

- One `MessageBusType(IO)` per process, parametric on an IO backend so fuzz
  tests can swap a deterministic IO.
- Identity is asymmetric: `ProcessID = union { replica: u8, client: u128 }`.
- Topology declared at init as `[]const std.net.Address`.
- Wire format: u32 size, header checksum, body checksum, VSR header.
- Pool of refcounted messages preallocated at startup; sender obtains via
  `bus.get_message`, fills, calls `send_message_to_replica` or
  `send_message_to_client`.
- Send drops silently on full per-peer queue or no connection. Caller retries.
- Receive is callback-driven: bus invokes `on_messages_callback(bus, buffer)`,
  application iterates the buffer and either consumes or suspends each
  message.
- Connection management is internal: lazy outbound connect, exponential
  backoff with seeded jittered delay, async close that waits for in-flight
  recv/send to complete.
- VOPR uses a separate, simpler `testing/cluster/message_bus.zig` that
  bypasses sockets and routes through an in-memory packet simulator.

## Marionette's seam choice

There are actually two seams hiding in this question, and they have different
answers.

**Public-API seam (settled).** The user-visible `Network(Payload)` type
will not be parametric on an IO backend. The vtable already gives the
sim/prod swap; adding `Network(Payload, IO)` would push the IO choice into
every function signature that takes a network handle and leak library
internals into application code. The same `Network(Payload)` type is
satisfied by two impls: a simulation impl backed by the deterministic
packet bus, and a production impl backed by sockets. Production transport
work goes behind the existing `TypedNetwork(Payload)` vtable in
`src/network.zig`. No type signatures change in user-facing code.

**Implementer-internal seam (deferred, not foreclosed).** Whether the
production-side bus implementation is itself parametric on an internal IO
type is a separate question. TigerBeetle's `MessageBusType(IO)` is not
primarily for swapping sim and prod (VOPR uses a different MessageBus
entirely); it is for `message_bus_fuzz`, which exercises the *real*
production MessageBus code against a deterministic test IO that simulates
partial reads, EOF mid-frame, `EAGAIN`, and similar IO-edge behaviors.
That coverage is not optional in a correctness-focused project: framing,
recv-buffer reassembly, and connection state-machine code only ever runs
against real sockets without it.

The vtable seam does not deliver this coverage. Once code is on the prod
side of `TypedNetwork(Payload)`'s vtable, syscalls are wired in directly.
The pragmatic plan is to leave room for an internal IO seam without
committing to one yet:

- Sub-tasks 15a (framing) and 15b (buffer pool) are already independent of
  IO and are fuzzable directly.
- Sub-tasks 15d-15g (sockets, connection management, queues) should
  structure their IO calls behind a small internal abstraction, even if
  the only impl is the real one. That keeps a future deterministic IO
  impl cheap to add.
- A decision on whether to actually ship a deterministic IO + bus-impl
  fuzzer is deferred until 15d lands and we know what the IO surface
  looks like in practice. At that point we either commit to internal
  parameterization or drop the option.

The user-visible API is unaffected by this question either way.

## Target architecture

### Wire format

Length-prefixed framing with header and body checksums:

```
+------------+--------------------+-----------------+--------+--------+----------+--------+
|  size:u32  | checksum_header:u128 | checksum_body:u128 | from:u16 | to:u16 | reserved:u32 | payload |
+------------+--------------------+-----------------+--------+--------+----------+--------+
```

Constraints:

- `size` is the total frame size including header, in bytes. Receivers reject
  frames whose declared size exceeds a configured maximum.
- Header checksum covers everything from `from` through the payload length;
  body checksum covers the payload bytes. Two checksums let us reject torn
  headers without reading the body.
- `from` and `to` are `NodeId` values matching the topology config.
- `reserved` accommodates a future framing version. v0 sets it to zero.

Checksum function: SipHash-128 with a per-process seed is the working
default. The framing is extension-shaped so the choice can change without
breaking the surface API.

Payload encoding is the user's responsibility. For fixed-shape Zig structs,
`std.mem.toBytes` is sufficient. Variable-length payloads require a
user-supplied `encode`/`decode` pair; this is deferred until a real example
demands it.

### Topology declaration

Production setup requires a topology config absent in simulation:

```zig
const net = try production.network(MessagePayload, .{
    .self = 1,
    .peers = &.{
        .{ .id = 0, .address = "127.0.0.1:4240" },
        .{ .id = 1, .address = "127.0.0.1:4241" },
        .{ .id = 2, .address = "127.0.0.1:4242" },
    },
    .listen = "0.0.0.0:4241",
});
```

Simulation does not need this; `World.simulate(.{ .network = .{ .nodes = N }
})` declares topology implicitly.

This is a deliberate divergence: `Production.network` and `Sim.network`
accept different option types. The returned handle is the same. Application
code that holds a `Network(Payload)` is unaware of how its peers were
declared.

### Identity model

Single `NodeId = u16` namespace, matching the simulator. Marionette will not
adopt TigerBeetle's asymmetric replica/client identity model at the bus
layer. Users who need a replica/client distinction encode it in their
`Payload`.

Rationale: TigerBeetle conflates client UUIDs and replica indices because VSR
requires it. Marionette is a generic library and should not constrain payload
shape. If a future use case demands UUID-shaped clients on the bus, we will
add it as a separate primitive rather than retrofit it.

### Buffer pool

Preallocated, refcounted message pool. Pool size is a config field; the
default is computed from the topology and per-peer queue depths. Pool
exhaustion returns `error.PoolExhausted` from `send`; this is one of the few
conditions that propagates as a hard error rather than dropping silently,
because it represents a configuration bug, not a transient condition.

User-facing API for v1 is copy semantics: `net.send(from, to, payload)` copies
the payload into a pooled buffer. Zero-copy primitives such as `acquire`/
`commitSend` are deferred until a workload justifies them.

### Connection management

Internal to the production impl. Outbound: lazy connect on first send to a
peer; persistent connections; exponential backoff with seeded jittered
delay on failure. The jitter seed comes from the local `NodeId` so that
multiple replicas reconnecting to a flapping peer naturally desynchronize.

Inbound: a single listener bound to `options.listen` accepts connections.
Peer identity is inferred from the first valid frame's `from` field.

Async close: when a connection terminates, pending recv and send completions
must drain before the socket file descriptor is released. This prevents
TOCTOU races and dropped data on graceful shutdown.

### Backpressure

Send side: bounded per-peer queue. Default capacity TBD; configured via
options. Full queue drops the message and emits a trace event; the caller
does not receive an error. This matches TigerBeetle. The application owns
retries.

Receive side: bounded per-connection recv buffer. When the buffer is full,
the kernel read on that connection is paused until `nextDelivery` consumes a
message. The pull-shaped `nextDelivery` API gives application backpressure for
free.

Marionette will *not* implement TigerBeetle's per-message `suspend_message`
semantics in v1. The pull model plus bounded recv buffer is simpler and
preserves the existing API. If a workload demands fine-grained per-message
deferral, we add it then.

### Send semantics

```zig
try net.send(from, to, payload);
```

Returns `!void`. Possible errors:

- `error.PoolExhausted`: the message pool is full. Configuration bug; this is
  not a transient condition.
- `error.InvalidNode`: `to` is not in the topology. Caller bug.

Does *not* return errors for transient conditions:

- Peer is unreachable: drop silently, emit `network.drop reason=peer_down`
  trace event. Caller retries at the application layer.
- Per-peer queue is full: drop silently, emit `network.drop reason=queue_full`
  trace event. Caller retries.

This converges sim and prod on the same surface. The current sim
`error.EventQueueFull` becomes a silent drop with a trace event in both
impls. The reconciliation lands as a small follow-up to the simulation
network code.

### Receive semantics

```zig
while (try net.nextDelivery()) |packet| { ... }
```

Returns `!?Packet`. Same shape as today. The production impl fills pooled
recv buffers from sockets and hands the next available packet to the caller.
When no packet is currently deliverable, the production impl yields control
to the IO backend (i.e. blocks on a poll) until one arrives or until a
configured deadline expires; the deadline is exposed via a future
`nextDeliveryWithin(duration)` variant if needed.

For v1, `nextDelivery` blocks indefinitely until a packet is available or the
network handle is closed. Callers that need a non-blocking poll use the
trySend / tryRecv pattern, deferred until a real example asks for it.

### IO backend

Target: `std.Io` once it stabilizes in Zig 0.16 or later. Until then, a thin
internal abstraction with one impl per platform: io_uring on Linux, kqueue on
Darwin, IOCP on Windows.

The internal IO type is not part of the public API. Users see only
`Network(Payload)`. The decision to migrate to `std.Io` happens when `std.Io`
exposes the primitives the production impl needs (async accept, recv, send,
close); until then, the internal abstraction is whatever works.

The internal IO surface should be small and well-defined for a second
reason beyond `std.Io` migration: structured this way, the production bus
implementation can later be made parametric on the internal IO type so a
deterministic IO impl can drive bus-implementation fuzz tests
(TigerBeetle's `message_bus_fuzz` pattern). This is not committed work for
v1, but the cost of structuring the IO calls cleanly now is small and
preserves the option. See "Marionette's seam choice" above for the full
reasoning.

## Implementation order

Each item ships on its own. Cross-process parity is the done-signal.

1. **Wire format and framing primitive.** Encode/decode helpers, checksum,
   roundtrip tests. No sockets yet. Lives in `src/network_frame.zig`.
2. **Buffer pool primitive.** Refcounted, preallocated pool. Pool exhaustion
   returns hard error. Lives in `src/message_pool.zig`. Used by both sim and
   prod once integrated.
3. **Topology config and `Production.network(Payload, opts)`.** Production
   handle accepts peers and self id. Initially returns the same in-process
   FIFO behavior as today; the API change is the gate.
4. **Single-peer end-to-end socket transport.** Two processes, one peer each,
   real send and receive with the new framing. Loopback only.
5. **Multi-peer with internal connection management.** Lazy outbound connect,
   inbound listener, peer-type resolution from frames.
6. **Reconnect with seeded jittered backoff.** Connection drop and recovery
   tested end to end.
7. **Bounded send and recv queues with silent-drop semantics.** Sim
   reconciles to the same drop semantics as part of this step.
8. **Cross-process parity test.** The replicated-register example runs on N
   OS processes. Same source, same scenario, real network. This is the
   done-signal that closes roadmap item 15.

Steps 1 and 2 are independent of the rest and can be picked up in parallel.
Steps 3-8 are sequential.

## Open questions

These are deferred until implementation forces an answer. Recording them so
they do not get rediscussed.

- Checksum function specifics: SipHash-128 is the working default but not yet
  settled.
- Pool sizing: is the default computed from topology automatically, or must
  the user configure it explicitly? TigerBeetle computes from topology; we
  may need to until users complain.
- Listener lifetime: bound to `Production.deinit`, or explicit `bind`/
  `shutdown`? Current plan is implicit lifetime; revisit if it bites.
- Variable-length payloads: deferred until a real example demands them.
- Multiple buses on one process (RPC plus gossip): out of scope here; tracked
  separately under the named-bus question in `docs/network-api.md`.

## Deliberate non-goals

- General-purpose RPC: no request/response correlation, no service discovery,
  no client libraries.
- TLS, real DNS, arbitrary `std.net` compatibility.
- Stream or datagram primitives outside the `Network(Payload)` shape.
- A drop-in replacement for Tokio, libuv, or any general-purpose async
  runtime.

If a user needs any of the above, they should reach for `std.net` directly
and not use `Network(Payload)` for that workload.

## Deviations from TigerBeetle

For posterity, where this design diverges from TigerBeetle and why:

- **One *user-visible* seam, not two.** Marionette's vtable substitutes
  for the TigerBeetle equivalent of "different MessageBus per use case"
  (separate VOPR bus vs production bus). Justification: keeps the public
  type uniform across sim and prod. Note this is narrower than "one seam
  total": TigerBeetle's parametric `MessageBusType(IO)` exists primarily
  to let `message_bus_fuzz` exercise the production bus against a
  deterministic IO. Marionette has not adopted that internal seam yet but
  has not foreclosed on it; see "Marionette's seam choice" above.
- **No bus-level replica/client distinction.** Single `NodeId` namespace.
  Justification: Marionette is generic, not VSR-specific.
- **Pull-shaped receive (`nextDelivery`).** TigerBeetle is callback-shaped.
  Justification: pull is simpler in the single-threaded simulator; the
  production impl buffers internally and the user pulls.
- **Sim and prod converge on silent-drop send semantics.** TigerBeetle does
  silent-drop on the prod side; Marionette's sim currently returns
  `error.EventQueueFull`. We will converge on the TigerBeetle behavior in
  both impls.
