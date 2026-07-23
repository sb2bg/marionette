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
| Other listen modes or protocols | Unsupported | Returns the corresponding mode/protocol error. |
| `listen.kernel_backlog` | Abstracted | Bounds pending, unaccepted connections; excess connects are refused deterministically. |
| `listen.reuse_address = true` | Unsupported | Returns `error.OptionUnsupported`. |
| Listen port `0` | Exact | Assigns a deterministic address from the IANA dynamic port range. |
| `connect` mode `.stream`, protocol `.tcp` | Abstracted | Connects to an existing simulated listener, assigns a deterministic client port, and rejects a down source, down destination, or disabled link. Establishment does not yet traverse simulated latency. |
| `connect.timeout` other than `.none` | Unsupported | Returns `error.OptionUnsupported` rather than silently ignoring the timeout. |
| `accept` | Exact | Blocks cancelably and returns the connecting peer address. |
| Stream read/write ordering | Abstracted | Writes are segmented into ordered frames. Readers receive only a contiguous prefix. Loss terminally fails that receive stream; later frames are discarded. |
| Partial write progress | Exact | Once a write prefix is accepted, a later cancellation, reset, or resource failure returns the accepted byte count. |
| Read/write cancellation | Exact | Armed cancellation is delivered at entry and at blocking waits. |
| `shutdown(.recv)` | Abstracted | Discards inbound bytes and makes later reads return EOF. The opposite direction remains usable. |
| `shutdown(.send)` | Abstracted | Makes local writes fail and makes the peer observe EOF after accepted bytes. The opposite direction remains usable. |
| `shutdown(.both)` | Abstracted | Applies both directional shutdowns without closing the socket handle. |
| `close` | Abstracted | Releases local state and queued capacity; an unexpected peer close is surfaced as reset. |

## Explicit Scope

UDP, Unix-domain sockets, non-literal DNS, broader socket-option parity, and
kernel-specific readiness behavior are unsupported. They should be added only
when a pinned system under test requires them.

The remaining material stream-contract gap is connect establishment latency:
connect must become a queued deterministic network event before latency and
timeouts can be classified as exact or abstracted.
