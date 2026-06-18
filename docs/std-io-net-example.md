# Testing std.Io.net Code Deterministically

Marionette includes an external-style client/server validation built only on
Zig's `std.Io.net` stream API. The application code imports `std`, not
Marionette. A separate harness owns the simulator, scheduler, seed, network
faults, trace, and correctness oracle.

This is a capability demonstration, not a third-party SUT finding. Its purpose
is to show the integration shape ordinary Zig network code can use today and
to keep the current stream boundary executable.

## The SUT

[`examples/std_io_net_kv.zig`](https://github.com/sb2bg/marionette/blob/main/examples/std_io_net_kv.zig)
implements a small fixed-frame KV protocol:

```text
client -> PUT request_id key value
server -> value revision duplicate
client -> GET request_id key
server -> value revision
```

The client and server use only `std.Io`, `std.Io.net.Stream`, the standard
stream reader/writer adapters, and fixed byte frames. The adapters handle short
transfers until the complete frame has moved.

The server has two modes:

- `deduplicate` caches successful PUT responses by request ID;
- `apply_every_put` is deliberately buggy and reapplies a retried PUT.

The second mode is planted test code. It is not an external bug report.

## The Harness

[`validation/std_io_net_kv.zig`](https://github.com/sb2bg/marionette/blob/main/validation/std_io_net_kv.zig)
creates two simulated nodes and three cooperative tasks:

1. The server accepts one TCP-like stream and processes requests.
2. The client sends a PUT, observes a timeout, retries the same request ID,
   then reads the key.
3. The fault controller partitions the server and client after the first
   response is queued, waits for the timeout, heals the link, and releases the
   retry.

The checker asserts an exact idempotency invariant:

```text
value == 41
revision == 1
applied_puts == 1
```

The correct server returns the cached response on retry. The buggy server
returns the right value but increments the revision and applies the mutation a
second time, so a value-only check would miss the failure.

## Run It

Run the validation tests:

```sh
zig build validate-std-io-net-kv
```

Replay the correct partition/retry scenario:

```sh
zig build run-example -- std-io-net-kv --seed 12648430 --trace
```

Replay the planted bug:

```sh
zig build run-example -- std-io-net-kv-bug \
  --seed 12648430 --trace --expect-failure
```

Two runs at seed `12648430` must produce byte-identical traces.

## Trace

The correct run records the fault at the stream and application altitudes:

```text
network.partition left_count=1 right_count=1
network.drop id=1 from=0 to=1 reason=link_disabled
io.net.delivery_error from=0 to=1 handle=1001 reason=link_disabled error=Timeout
std_io_net_kv.client.timeout request_id=7
network.heal disabled_count=2 down_count=0 clogged_count=0
std_io_net_kv.client.retry request_id=7 revision=1 duplicate=true
std_io_net_kv.check retry_idempotent=ok value=41 revision=1 applied_puts=1
```

The buggy run reaches the same timeout and heal, then ends with:

```text
std_io_net_kv.client.retry request_id=7 revision=2 duplicate=false
std_io_net_kv.invariant_violation expected_value=41 actual_value=41 expected_revision=1 actual_revision=2 expected_applied_puts=1 actual_applied_puts=2
```

The seed reproduces both the scheduler choices and the network delivery
history.

## Stream Semantics

The current simulated stream subset supports:

- IPv4 listen and connect inside the closed simulation;
- scheduler-backed blocking `accept` and `read`;
- stream reads, writes, shutdown, and close;
- deterministic latency and send-time loss;
- delivery-time manual partitions surfaced as `error.Timeout`;
- healing followed by deterministic retry on the same connection;
- in-order bytes within each connection;
- graceful close after queued delayed bytes have drained.

Marionette does not reorder bytes within a stream. The modeled transport is
TCP-like, so intra-stream reordering would violate the application-facing
contract. Message reordering remains available through
`Endpoint(Message)`, where independent message boundaries exist.

The current boundary does not include DNS, datagrams, Unix sockets, external
host access, TLS, `sendmsg` / `recvmsg`, full connection-reset behavior, or
preemptive OS-thread scheduling. Unsupported vtable regions fail closed rather
than silently using host I/O.

Listener and connection allocation is process-scoped rather than
socket-scoped. Use `sim.envForNode(node).io()` to give each server or client a
stable simulated process identity; reconnect loops create new socket handles
under that process without consuming additional topology nodes.

## What This Proves

This validation proves that production-shaped `std.Io.net` client/server code
can:

- suspend and resume on simulated socket operations;
- receive deterministic network latency and partition faults;
- retry after a stream-visible timeout;
- reproduce a failure from a seed and byte-identical trace;
- be checked against an application-level invariant without importing
  Marionette.

It does not claim compatibility with arbitrary network programs or a real
third-party network SUT. That remains an ecosystem validation target as more
Zig libraries adopt `std.Io.net`.
