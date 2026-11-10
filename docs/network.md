# Network Model

Marionette has two network altitudes:

- deterministic `std.Io.net` for socket-facing code, codecs, framing, partial
  I/O, deadlines, and connection lifecycle;
- experimental `Endpoint(Message)` for protocol and state-machine exploration
  above the wire.

`std.Io.net` is the canonical same-code production seam. Marionette does not
provide a production endpoint bus.

## Semantics Versions

`World.SimulateOptions.network.semantics` selects the network model. Capsules
record it, so a run always replays under the model it was recorded with.

| Semantics | Default | What it models |
| --- | --- | --- |
| `tcp_v1` | yes, since 0.9 | TCP-lite over a push-based packet fabric. Faults produce silence; errors come from Linux-shaped mechanisms. |
| `legacy_v0` | before 0.9 | The pull model: delivery waits for readers, faults become immediate errors, and close and kill reach peers through shared state. |

`legacy_v0` is deprecated: it is retained for one release so recorded
evidence and unported harnesses keep running, and 0.10 removes it. Capsules written before 0.9 name no model and decode as `legacy_v0`.
A `tcp_v1` capsule carries `model_version`
(`network_semantic_version`); replay rejects a capsule from another version with
`error.IncompatibleNetworkModel`.

## Topology

`World.SimulateOptions.network` configures:

- `nodes`: total hosts, one logical process each;
- `service_nodes`: the prefix eligible for automatic partitions and restored by
  the liveness transition;
- `semantics`, `address_model`, and `timing` (see below);
- `tcp`: per-socket send and receive buffer sizes and the segment size;
- `path_capacity`: queued capacity per directed path for `legacy_v0` streams
  and typed endpoints.

Node IDs are stable `u16` values. Links are directed, so cutting `A -> B` does
not cut `B -> A`.

## Hosts Own Addresses

Under `address_model = .per_host_v1` (the `tcp_v1` default) each host owns:

- IPv4 `10.0.0.0/8` offset by `node + 1`, so node 0 is `10.0.0.1`;
- IPv6 `fd00::/8` offset by `node + 1`, so node 0 is `fd00::1`;
- its own loopback (`127.0.0.0/8`, `::1`), reachable only from itself;
- its own port table and ephemeral range (32768 to 60999, as on Linux).

`AnyNetworkControl.hostIp4(node, port)` and `hostIp6(node, port)` name these
addresses. Every node may listen on `0.0.0.0:7000` at once. Binding another
host's address fails with `error.AddressUnavailable`. `accept` reports the
client's real address and ephemeral port.

The simulated DNS resolves `nodeN` and names registered with
`control.network.addHostName(name, node)` to that host's addresses, IPv4
first: RFC 6724 ranks IPv4 above unique-local IPv6. Literals and `localhost`
resolve as before.

Connecting to an address outside the simulated subnets fails at once with
`error.NetworkUnreachable`, as with no route. An address inside them that no
host owns fails with `error.HostUnreachable` after an ARP timeout.

`address_model = .shared_v0` keeps one port namespace for the whole world,
where any node may bind any address and `127.0.0.1` reaches whichever node
listens there. `tcp_v1` supports it as a migration step: port the semantics
first, then the addresses. `legacy_v0` supports only `shared_v0`.

## TCP-Lite

Every socket's state lives in its own host's table. Endpoints interact only
through segments carried by the fabric:

- a three-way handshake (`SYN`, `SYN-ACK`, `ACK`); a listener whose accept
  queue is full drops the `SYN`, as Linux does, and the client retries;
- cumulative ACKs, delayed ACKs (every second segment or after the delayed-ACK
  timer), and an out-of-order queue, so loss costs a retransmission, not the
  stream;
- receive windows over bounded per-socket buffers, with window updates when the
  reader drains and window probes when the peer's window is zero;
- timed retransmission with exponential backoff, Karn's rule, RTT estimation
  (RTO = SRTT + 4 RTTVAR, clamped), fast retransmit on three duplicate ACKs, and
  partial-ACK recovery;
- `FIN` and `RST` on the wire, `FIN_WAIT`, `CLOSE_WAIT`, `LAST_ACK`, `CLOSING`,
  and `TIME_WAIT`.

A fault by itself produces silence. An application sees an error only from:

| Error | Mechanism |
| --- | --- |
| `ConnectionRefused` | An `RST` answering a `SYN` to a port nobody listens on. |
| `ConnectionResetByPeer` | An `RST`: the peer closed over unread data, a listener closed with the connection unaccepted, or a segment reached a socket that no longer exists. |
| `Timeout` (connect) | SYN retries ran out (127 s under `.linux`), or the caller's own `connect` timeout. |
| `ConnectionTimedOut` (read/write) | Data retransmissions ran out (`tcp_retries2`, 15), or window probes went unanswered as long. |
| `HostUnreachable` | An ARP timeout, or a `reject` fault's unreachable signal (it aborts a connect at once; on an established connection it becomes the final error if retries run out). |
| `NetworkUnreachable` | No route to the destination. |

Without an application timeout, a read across a partition blocks. If nothing
else can happen, the scheduler reports a deadlock, so a missing timeout is a
finding, not a hang. Applications set timeouts the production way: a `connect`
timeout, or `io.operateTimeout` around a read or write (`Batch` awaits are
supported).

### Close, Kill, And Crash

- `close` sends buffered data and a `FIN`; the kernel finishes the connection
  after the application lets go. Closing over unread data sends an `RST`
  instead.
- A process kill closes every socket that process held, the same way.
  The `FIN` crosses the fabric, so it waits behind a partition like any packet.
- A disk crash is a machine crash: sockets vanish without sending anything.
  A peer learns only when it next sends and gets an `RST`, or when its
  retransmissions run out.

`listen.reuse_address` is accepted; `TIME_WAIT` never blocks a bind.

### Timing Profiles

`timing = .linux` uses Linux defaults: 1 s SYN RTO with 6 retries, 200 ms
minimum and 120 s maximum RTO, 15 data retries, 40 ms delayed ACK, 60 s
`FIN_WAIT2` and `TIME_WAIT`, 3 s ARP timeout. `timing = .compressed` divides
every interval by 100 for long-horizon scenarios. Intervals round up to the
world tick.

## Push-Based Fabric

Each directed link applies latency and loss when a segment is sent and fault
fate when it arrives. Arrivals and protocol timers sit in one network event
queue. The scheduler advances virtual time to the next event even when every
task is blocked without a deadline, so delivery never waits for a reader and
one stalled connection cannot starve another. Timers that cannot change what
an application sees (`TIME_WAIT` and orphaned `FIN_WAIT2` expiry, and window
probes that would be answered with a zero window again) do not keep the
scheduler awake.

## Faults As Handles

`case.control().network` injects faults and returns a `NetworkFault` handle:

```zig
const fault = try control.network.partition(&.{0}, &.{ 1, 2 }, .{});
const lossy = try control.network.degrade(1, 0, .{ .delay_ns = 20 * ms, .drop_rate = .percent(5) });
const refused = try control.network.cut(2, 0, .{ .mode = .reject, .duration_ns = 1 * s });
_ = try control.network.isolate(3, .{ .mode = .hold });
try control.network.healFault(fault); // the others stay
```

- `partition(left, right, options)` cuts every link between the groups.
  Nodes in neither group still reach both sides: a partial partition.
- `isolate(node, options)` cuts one node off from all others, the shape
  failure studies find behind most partition bugs.
- `cut(from, to, options)` disrupts one directed link.
- `degrade(from, to, options)` adds latency, jitter, and seeded loss to one
  directed link (`tcp_v1` only).

Each fault has a disruption mode:

| Mode | Effect on a covered packet |
| --- | --- |
| `drop` | It vanishes. |
| `hold` | It waits at the fault and continues, in order, when the fault heals. |
| `slow` | It is delayed by `delay_ns`. |
| `reject` | It vanishes and the sender's host receives an unreachable signal one base latency later. |

A fault may carry `duration_ns` and then heals itself. **Composition rule:** the
most disruptive mode among the faults covering a path decides a packet's fate,
`drop` before `reject` before `hold`; `slow` delays add. The oldest fault of
the deciding mode is credited in traces. `healFault` heals one fault and
returns `error.FaultNotActive` once it has healed or expired.
`heal()` heals every fault and brings every node up.

Today's calls map onto handles: `setLink(from, to, false)` is a `cut`,
`clog` is a `hold` cut with a duration, automatic partitions are `isolate`
faults, and automatic clogs are timed `hold` cuts. `legacy_v0` supports only
`drop` handles.

`setLossiness` and `setLatency` set the defaults every link applies, and
`setNode(node, false)` takes a host's interface down: packets from or to it
vanish while its sockets keep their state.

Application code never receives this capability. It receives node-scoped
`std.Io` from `sim.envForNode(node)` or a typed endpoint from `sim.endpoint`.

## Explaining Every Packet

Under `tcp_v1` the trace records every segment's fate:

```text
net.send pkt=3 from=1 to=0 src=10.0.0.2:32768 dst=10.0.0.1:7000 flags=A seq=1 ack=1 len=5 wnd=65536 deliver_at=4000000
net.drop pkt=3 from=1 to=0 reason=fault fault=1 mode=drop
net.hold pkt=4 fault=2
net.release pkt=4
net.deliver pkt=4 from=1 to=0 conn=3
```

Drop reasons are `loss`, `fault` (with the fault id and mode), `source_down`,
and `destination_down`. Socket events (`tcp.connect`, `tcp.listen`,
`tcp.accept`, `tcp.state`, `tcp.retransmit`, `tcp.fast_retransmit`,
`tcp.window_probe`, `tcp.reset`, `tcp.error`) and fault events
(`network.fault`, `network.fault_heal`) explain the rest.

On a deadlock, and when a scenario or check fails, the trace ends with a
`netstat` table: every listener with its accept queue, every connection with its
state, addresses, send and receive queues, unacknowledged and unsent bytes,
windows, retries, RTO, and owner, and every active fault. A watchdog failure
appends a table reconstructed from the trace, since the killed worker cannot be
asked. `control.network.recordNetstat(reason)` records one on demand.

## Typed Endpoints

`Endpoint(Message)` stays experimental. It sends typed values over per-path
queues and obeys the same fault handles (`drop` and `reject` discard, clogs
delay), but it has no wire, no flow control, and no connection lifecycle. raftz
builds cluster tests on it; it is not promoted to a stable surface. Retaining
it requires the contract below.

Delivery: each send is delivered at most once and never duplicated. Loss can
happen at send (configured loss, a down source) or when the message becomes due
(a down destination, a disabled link, a dropping or rejecting fault), and every
loss records `network.drop` with its reason. Ready messages are delivered by
delivery time, then send order, so latency can reorder messages on different
paths but never on one path. A full path returns `error.EventQueueFull`.

Ownership: `send` copies the message by value and the receiver owns its copy.
`sim.endpoint(Message, node)` rejects at compile time a `Message` containing
pointers or slices, since nothing would keep the referenced storage alive or
unchanged. `sim.borrowedEndpoint(Message, node)` is the explicit opt-in; its
referenced storage must stay valid and immutable for the simulation.

Time: `poll()` returns a message ready now, or null, and never advances
virtual time. `awaitDelivery()` is the explicit harness-driver operation: it
advances time to this endpoint's own next delivery, or returns null without
advancing when nothing is in flight to it. `receive()`, which could advance
time to a delivery for any endpoint on the bus, is deprecated and will be
removed in 0.10.

Migration path: keep the protocol's state machine and its message type, add a
codec, and carry the encoded messages over `std.Io.net` streams between
`hostIp4` addresses. The codec and framing then run in production too, and
partitions, slow links, and restarts exercise the application's real timeouts
and reconnects. A future datagram transport will rebuild `Endpoint(Message)`
under the same delivery contract once a pinned workload needs UDP.

## Limits

The model does not provide UDP, Unix sockets, real DNS, congestion control,
Nagle's algorithm, keepalive, urgent data, or socket options beyond those
listed in [`std.Io.net` Conformance](std-io-net-conformance.md). Every host
shares one disk and one clock. See [the client/server example](std-io-net-example.md)
for usage.
