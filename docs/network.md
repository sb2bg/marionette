# Network Model

Marionette has two network altitudes:

- deterministic `std.Io.net` for socket-facing code, codecs, framing, partial
  I/O, deadlines, and connection lifecycle;
- experimental `Endpoint(Message)` for protocol and state-machine exploration
  above the wire.

`std.Io.net` is the canonical same-code production seam. Marionette does not
provide a production endpoint bus.

## Topology

`World.SimulateOptions.network` configures:

- `nodes`: total logical processes;
- `service_nodes`: the prefix restored by liveness transition;
- `path_capacity`: queued capacity per directed path.

Node IDs are stable `u16` values. Links are directed, so disabling `A -> B`
does not disable `B -> A`.

## Harness Control

`case.control().network` can configure loss, latency, automatic partitions,
node state, link state, clogs, explicit partitions, and healing. Changes are
trace-visible.

Application code does not receive this capability. It receives node-scoped
`std.Io` from `sim.envForNode(node)` or a typed endpoint created through
`sim.endpoint`.

## Delivery

Each send receives a monotonically increasing packet ID and a deterministic
delivery timestamp. Ready packets are selected by delivery time and packet ID.
This permits latency-driven reordering without unstable container iteration.

Loss may occur at send time. Destination failure, link disablement, or
partition may also discard a packet when delivery becomes due. Clogged links
delay otherwise ready packets until the clog expires. Every outcome records a
reason.

For reliable `std.Io.net` streams, a lost interior segment terminally fails the
receive stream; later bytes are not exposed across a hole. Connection teardown
reclaims queued frames and wakes writers waiting on shared byte capacity.

## Time And Backpressure

Network delivery advances only when the harness moves virtual time or drives
scheduled tasks. Queues and the shared stream byte pool are bounded. Capacity
exhaustion blocks stream writers through deterministic scheduler wait keys;
typed endpoint queues return `error.EventQueueFull`.

## Process State

Node failure affects both network delivery and process-scoped I/O. Saved
capabilities reject use while their process is killed. Restart creates a fresh
incarnation; stale handles remain invalid.

## Limits

The current model does not provide UDP, Unix sockets, real DNS, arbitrary
multi-peer production transports, or preemptive shared-memory scheduling.
Typed endpoints do not serialize arbitrary Zig values and do not yet promise a
stable production ownership, readiness, cancellation, or backpressure
contract.

See [`std.Io.net` Conformance](std-io-net-conformance.md) for the exact socket
subset and [the client/server example](std-io-net-example.md) for usage.
