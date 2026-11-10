# `std.Io.net` Conformance

This ledger classifies Marionette's simulated `std.Io.net` surface against Zig
0.17.0. It is the source of truth for supported operations and options.

- **Exact:** portable observable behavior is intended to match host
  `std.Io.net`.
- **Abstracted:** the application contract is preserved without modeling a
  particular kernel implementation.
- **Unsupported:** the operation or option fails explicitly.
- **Divergent:** intentional behavior differs from the host contract and is
  stated here.

## IP Streams Under `tcp_v1`

`tcp_v1` is the default since 0.9. See [Network Model](network.md#tcp-lite) for
the protocol and its error mechanisms.

| Surface | Classification | Simulated contract |
| --- | --- | --- |
| IPv4 and IPv6 literal lookup | Exact | Returns the parsed address without host DNS state. |
| `localhost` lookup | Abstracted | Deterministically returns IPv6 then IPv4 loopback. |
| Simulated host names | Abstracted | `nodeN` and names added with `addHostName` resolve to that host's IPv4 then IPv6 address. |
| Other hostname lookup | Unsupported | Returns `error.UnknownHostName`; DNS and host files are ambient host state. |
| `listen` mode `.stream`, protocol `.tcp` | Exact | Creates a listener in the host's own port table. |
| Listen address scope | Exact | A host may bind the unspecified address, loopback, or its own address; any other address returns `error.AddressUnavailable`. Wildcard and exact binds conflict per host and per family. IPv4 and IPv6 are separate families (as with `IPV6_V6ONLY`). |
| `listen.kernel_backlog` | Exact | Bounds established, unaccepted connections. A `SYN` arriving while the queue is full is dropped and the client retransmits, as on Linux. |
| `listen.reuse_address` | Abstracted | Accepted. `TIME_WAIT` never blocks a bind, as if `SO_REUSEADDR` were always set. |
| Listen port `0` | Exact | Assigns a port from the host's ephemeral range, 32768 to 60999. |
| `connect` mode `.stream`, protocol `.tcp` | Exact | A three-way handshake over the fabric. Refusal is an `RST` one round trip later; silence retransmits the `SYN` at 1, 2, 4, ... s and times out after 127 s under `.linux`. Unroutable addresses fail with `NetworkUnreachable` at once; absent in-subnet hosts with `HostUnreachable` after an ARP timeout. |
| `connect.timeout` duration or deadline | Exact | Bounds establishment in simulated time and returns `error.Timeout`, abandoning the attempt. |
| Connect cancellation | Exact | Returns `error.Canceled` and abandons the attempt. |
| `accept` | Exact | Blocks cancelably and returns the client's real address and ephemeral port. A connection reset before `accept` is still returned; its first read reports the reset. |
| Stream read/write ordering | Exact | Bytes arrive in order, exactly once, across loss, reordering, and duplication. |
| Write flow control | Exact | A write copies what fits in the bounded send buffer and blocks while it is full; the peer's receive window limits what is in flight. |
| Partial write progress | Exact | A write returns the bytes it accepted. |
| `operateTimeout` and `Batch` | Exact | Read and write readiness are real; `awaitConcurrent` honors its timeout with `error.Timeout`. |
| Stream read metadata | Exact | Reads report byte count, zero ancillary bytes, and no control truncation. |
| Ancillary writes | Unsupported | Nonempty control data returns `error.Unexpected` before sending payload bytes. |
| Stream errors | Exact | `ConnectionResetByPeer` after an `RST`, `ConnectionTimedOut` after retransmissions or window probes run out. A read reports an error once, then end of stream; writes keep reporting it. |
| Read/write cancellation | Exact | Armed cancellation is delivered at entry and at blocking waits. |
| `shutdown(.recv)` | Abstracted | Later reads return end of stream; arriving data is acknowledged and discarded. |
| `shutdown(.send)` | Exact | Sends a `FIN` after buffered data; later writes fail; the peer reads end of stream. |
| `shutdown(.both)` | Exact | Both of the above without closing the handle. |
| `close` | Exact | Sends buffered data and a `FIN`, or an `RST` over unread data. The kernel finishes the connection after the handle is gone. |
| Process kill | Exact | The host's kernel closes each socket as `close` does. |
| Disk crash | Abstracted | A machine crash: sockets vanish silently and peers learn by sending. |

## IP Streams Under `legacy_v0`

| Surface | Classification | Simulated contract |
| --- | --- | --- |
| Listen address scope | Divergent | One port namespace for the whole world; any node may bind any address. |
| `listen.kernel_backlog` | Divergent | Excess connects are refused at once. |
| `connect` | Divergent | A down destination, disabled link, or partition fails the connect at once, even with a timeout. |
| `accept` | Divergent | The peer IP is the connect destination, not the client's address. |
| Stream ordering | Divergent | Loss terminally fails the receive stream with `ConnectionTimedOut`. |
| Stream timeout errors | Divergent | A partition or unavailable read reports `error.ConnectionTimedOut` without an application timeout. |
| `close` and process kill | Divergent | Reach the peer at once through shared state, even across a partition. |
| `Batch` | Abstracted | Ready operations complete; waiting on more than one unready stream reports `ConcurrencyUnavailable`. |

## Explicit Scope

UDP, Unix-domain sockets, real DNS, keepalive, congestion control, Nagle's
algorithm, urgent data, and broader socket-option parity are unsupported. They should be added only
when a pinned system under test requires them. Binding a datagram socket
returns `ProtocolUnsupportedBySystem`, and Unix-domain listen and connect return
`AddressFamilyUnsupported`. Sending a file to a stream returns `Unimplemented`
to the standard writer, which then reads the file and writes its bytes.

The no-fault differential tests run the same portable bidirectional exchange,
accepted-peer port/family observations, send-half-close/EOF scenario, and IPv4
wildcard-listener exchange against host `std.Io.net` and Marionette. They do
not claim source-IP equivalence. Fault behavior remains an explicit simulator
abstraction rather than an attempt to reproduce one host kernel.
