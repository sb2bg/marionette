# `std.Io.net` Conformance

This ledger classifies Marionette's simulated `std.Io.net` surface against Zig
0.16.0. It is the source of truth for supported operations and options.

- **Exact:** portable observable behavior is intended to match host
  `std.Io.net`.
- **Abstracted:** the application contract is preserved without modeling a
  particular kernel implementation.
- **Unsupported:** the operation or option fails explicitly.
- **Divergent:** intentional behavior differs from the host contract and is
  stated here.

## IP Streams

| Surface | Classification | Simulated contract |
| --- | --- | --- |
| IPv4 and IPv6 literal lookup | Exact | Returns the parsed address without host DNS state. |
| `localhost` lookup | Abstracted | Deterministically returns IPv6 then IPv4 loopback. |
| Other hostname lookup | Unsupported | Returns `error.UnknownHostName`; DNS and host files are ambient host state. |
| `listen` mode `.stream`, protocol `.tcp` | Exact | Creates a process-scoped listener. |
| Listen address scope | Abstracted | An unspecified IPv4 or IPv6 listener matches same-family literal destinations and conflicts with active wildcard or exact binds on that port. Address identity is not tied to modeled host interfaces, and IPv4/IPv6 remain separate families. |
| Other listen modes or protocols | Unsupported | Returns the corresponding mode/protocol error. |
| `listen.kernel_backlog` | Abstracted | Bounds pending, unaccepted connections; excess connects are refused deterministically. |
| `listen.reuse_address = true` | Abstracted | Accepted, while active-bind exclusivity remains enforced. The simulator has no kernel `TIME_WAIT` state to bypass. |
| Listen port `0` | Exact | Assigns a deterministic port from the IANA dynamic port range. |
| `connect` mode `.stream`, protocol `.tcp` | Abstracted | Queues establishment through the deterministic network, assigns a deterministic client port, observes latency, and rejects a down source, down destination, disabled link, or full backlog before publishing either endpoint. |
| `connect.timeout` duration or deadline | Exact | Bounds queued establishment in simulated time and returns `error.Timeout`; failure rolls back the probe and unpublished socket state. |
| Connect cancellation | Exact | Cancellation at entry or while establishment is queued returns `error.Canceled` and rolls back the attempt. |
| `accept` | Abstracted | Blocks cancelably and returns deterministic peer metadata. The port comes from a rotating simulated client ephemeral-port cursor and may be reused after the modeled range wraps; active peer-tuple uniqueness is not modeled. The family matches the connect destination. Nodes do not model source interfaces, so the peer IP is copied from the connect destination rather than representing a genuine client source address. |
| Stream read/write ordering | Abstracted | Writes are segmented into ordered frames. Readers receive only a contiguous prefix. Loss terminally fails that receive stream; later frames are discarded. |
| Partial write progress | Exact | Once a write prefix is accepted, a later cancellation, reset, or resource failure returns the accepted byte count. |
| Read/write cancellation | Exact | Armed cancellation is delivered at entry and at blocking waits. |
| `shutdown(.recv)` | Abstracted | Discards inbound bytes and makes later reads return EOF. The opposite direction remains usable. |
| `shutdown(.send)` | Abstracted | Makes local writes fail and makes the peer observe EOF after accepted bytes. The opposite direction remains usable. |
| `shutdown(.both)` | Abstracted | Applies both directional shutdowns without closing the socket handle. |
| `close` | Abstracted | Releases local state and queued capacity. A process reset discards that endpoint's delayed outbound frames and terminally surfaces `error.ConnectionResetByPeer`; graceful close preserves already accepted bytes before EOF. |

## Explicit Scope

UDP, Unix-domain sockets, non-literal DNS, broader socket-option parity, and
kernel-specific readiness behavior are unsupported. They should be added only
when a pinned system under test requires them.

The no-fault differential tests run the same portable bidirectional exchange,
accepted-peer port/family observations, send-half-close/EOF scenario, and IPv4
wildcard-listener exchange against host `std.Io.net` and Marionette. They do
not claim source-IP equivalence. Fault behavior remains an explicit simulator
abstraction rather than an attempt to reproduce one host kernel.
