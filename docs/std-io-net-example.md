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

1. The server accepts TCP-like streams and processes requests.
2. The client sends a PUT with a 1 ms response deadline (`operateTimeout`
   around each read), gives up when the deadline passes, reconnects, retries
   the same request ID, then reads the key.
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

The correct run records the fault at the packet and application altitudes.
The partition only drops the reply and its `FIN`; the client's own deadline
ends the wait:

```text
network.partition left_count=1 right_count=1
network.fault fault=1 kind=partition mode=drop paths=2 delay_ns=0 until_ns=0
net.drop pkt=4 from=0 to=1 reason=fault fault=1 mode=drop
net.drop pkt=5 from=0 to=1 reason=fault fault=1 mode=drop
std_io_net_kv.client.timeout request_id=7
network.heal disabled_count=2 down_count=0 clogged_count=0
network.fault_heal_all faults=1
std_io_net_kv.client.reconnected
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

## Dusty HTTP Fault Scenarios

[`validation/dusty_http.zig`](https://github.com/sb2bg/marionette/blob/main/validation/dusty_http.zig)
also runs the pinned, unmodified dusty HTTP client/server through partition
fault scenarios. The server is dusty's real `Server.listen` loop; the harness
owns only the simulated network, scheduler, trace, and oracle.

Two scenarios cut the server/client link at structural points:

- before the held handler writes any response bytes;
- mid-response after a configured number of chunked body chunks.

Both cuts use futex handshakes rather than tick counts or sleeps. The severed
link only drops packets; dusty's own 5 ms fetch deadline fails the first fetch
with `error.Timeout`. After
the harness heals the link, a fresh dusty client retries and must receive the
exact response: `hello from the simulation` for the held route and the full
64 KiB chunked body for the large route.

The mid-response oracle is intentionally strict. A first fetch that returns a
short or different body is `error.ShortSuccess`; partial response bytes must
not be accepted as a complete HTTP response. The trace also pins the network
shape: at least one response segment is sent before `dusty_fault.partition`, a
later one is dropped with `reason=fault mode=drop` before `dusty_fault.heal`,
and the network itself reports no error.

## Stream Semantics

Streams run TCP-lite (`semantics = .tcp_v1`): a handshake, cumulative ACKs,
receive windows, retransmission with backoff, and `FIN` and `RST` on the wire.
Bytes arrive in order and exactly once across loss and reordering. A partition
produces silence, so a client needs its own deadline; without one, a read that
can never complete surfaces as a scheduler deadlock with a `netstat` table.
See [Network Model](network.md).

Each node owns its address: node 0 is `10.0.0.1`, and
`AnyNetworkControl.hostIp4(node, port)` names it. `127.0.0.1` reaches only the
caller's own host. The simulated DNS resolves `nodeN` and names registered
with `addHostName`, so an unmodified `std.http.Client` can fetch
`http://node0:<port>/`. Real DNS, `/etc/hosts`, and search domains are host
state and fail with `error.UnknownHostName`.

The boundary does not include datagrams, Unix sockets, external host access,
TLS, `sendmsg` / `recvmsg`, or preemptive OS-thread scheduling. Unsupported
vtable regions fail closed rather than silently using host I/O.

Use `sim.envForNode(node).io()` to give each server or client its host
identity; reconnect loops create new sockets on that host without consuming
additional topology nodes.

## What This Proves

This validation proves that production-shaped `std.Io.net` client/server code
can:

- suspend and resume on simulated socket operations;
- receive deterministic network latency and partition faults;
- retry after its own response deadline passes;
- reproduce a failure from a seed and byte-identical trace;
- be checked against an application-level invariant without importing
  Marionette.

It does not claim compatibility with arbitrary network programs or a real
third-party network SUT. That remains an ecosystem validation target as more
Zig libraries adopt `std.Io.net`.
