# Marionette as Deterministic std.Io

This document sets the long-term direction for Marionette: become the
deterministic `std.Io` implementation for Zig.

The design is forward-looking. Zig 0.16 introduced the `std.Io` interface and
the fiber primitives needed to build stackful coroutine runtimes on supported
architectures. That makes an experimental deterministic `std.Io` backend
possible sooner than expected, but the API and implementation are still moving.

## Vision

Production Zig libraries should eventually accept `std.Io` for I/O, sleep,
networking, files, and concurrency. Marionette should provide a deterministic
implementation of that interface for tests.

The desired user model is:

```zig
const sim = try world.simulate(.{});
const io = sim.env.io();

try io.concurrent(serverLoop, .{io});
try clientThatAcceptsIo(io);
```

The app code should not import Marionette. The harness owns Marionette:
`World`, `Env`, `Control`, traces, fault injection, seeds, replay, and checks.

## Layers

Marionette should settle into three user-visible layers.

`std.Io` is the production-facing I/O dependency. Code under test should accept
this where possible.

`mar.Env` is the harness-facing Marionette environment. It owns Marionette-only
affordances such as structured trace recording, seeded simulation helpers, and
the `io()` accessor.

`mar.Control` is the simulator fault authority. Scenario code uses it to inject
disk crashes, network drops, partitions, latency, and other faults. Production
code should not hold it.

## Current io() Contract

`Env.io()` exists now because it is the right name and destination. The current
contract is intentionally narrow:

- production envs return the host `std.Io` supplied to `Production.init`;
- simulation envs return Marionette's current deterministic `std.Io` backend.

The simulation backend supports deterministic clock, sleep, random, and
`randomSecure` operations today; random draws are traced (`io.random` events
carry length and a fixed-seed digest of the bytes). `World.simulate` owns a
cooperative scheduler, so `io.async` and `io.concurrent` spawn deterministic
scheduler tasks with seeded, replay-visible interleaving: `future.await`
parks the awaiting task, or drives the scheduler when awaited from the
scenario itself. Cancellation runs the task to completion (cooperative tasks
cannot be preempted). `Io.Group` uses the same scheduler and supports
async/concurrent task ownership, await, reuse, and process-kill cleanup;
`Group.cancel` currently drains cooperatively. Without a task runtime
attached (bare `Backend`), `async` runs eagerly on the caller and
`concurrent` returns `error.ConcurrencyUnavailable`. The backend also
supports `Io.Queue` operations and a small in-memory TCP stream subset for
`std.Io.net` listen/connect/accept/read/write/close.
When network simulation is configured, `World.simulate()` creates one
process-scoped I/O backend per declared node. Use `sim.envForNode(node).io()`
when separate server/client tasks should speak as distinct simulated nodes;
`sim.env.io()` remains node 0 for single-process and compatibility cases.
Those backends are also logical-process owners: `sim.killProcess(node)` closes
that node's open file/socket/listener handles, cancels scheduler-backed tasks
spawned through that node's `Io`, completes their futures so awaiters cannot
deadlock, and wakes surviving TCP peers with `error.ConnectionResetByPeer`.
`sim.registerProcess(node, lifecycle)` registers type-erased `on_kill` and
`restart` callbacks; `sim.restartProcess(node)` kills a live incarnation if
needed and reruns the initializer with that node's `Env` against surviving
durable disk state. `DiskControl.crash()` uses the same supervisor after
applying pending-write crash faults, killing every live process and marking
file metadata stale for re-derivation after disk restart.
When the backend is attached to a scheduler wait set, `Io.sleep` parks the
current fiber until its deadline, empty accepts park until a connection is
queued, and open-peer empty reads park until bytes arrive or the peer closes.
Sleep and timed-wait deadlines round up to the simulation clock resolution.
Without a scheduler wait set, sleep advances through `World.runFor` and records
the time movement; empty accepts return `error.WouldBlock`, and empty stream
reads return `error.Timeout` while the peer remains open because Zig 0.16's
stream reader error set has no `WouldBlock` variant. This TCP subset is still
intentionally narrow, but socket bytes can route through the shared
`NetworkControl` byte runtime when simulation network control is attached.
Latency and send-time loss use that shared fault core directly. If a queued
stream frame reaches its delivery time while its directed link is partitioned,
the frame is dropped and the affected empty read observes `error.Timeout`.
That receive direction is then terminal: queued suffix frames are discarded,
and retry after `heal()` requires a fresh connection. Clogs also share the
packet runtime. Explicit `unclog`, `unclogAll`, `heal`, and core-liveness
restoration wake scheduler-backed stream and connect waiters so readiness is
recomputed at the control event rather than the superseded clog deadline.
Process resets discard the killed endpoint's delayed outbound frames before
surfacing a terminal `error.ConnectionResetByPeer` to the peer.

The stream adapter preserves byte order within each connection. It does not
inject byte-stream reordering because the modeled transport is TCP; message
reordering remains an `Endpoint(Message)`-altitude fault where message
boundaries exist.

The backend also supports a directory-aware file subset over `SimDisk`:
`Dir.createFile`, `Dir.openFile`, `Dir.statFile`,
`Dir.access`, positional file read/write, streaming file read/write,
`File.length`, `File.stat`, `File.setLength`, `File.sync`, `File.close`,
`Dir.deleteFile`, and `Dir.rename`. Streaming files keep a cursor per open
file handle; `seekTo`/`seekBy` update that cursor, successful operations advance
only by bytes actually transferred, and failed streaming operations leave the
cursor unchanged. This subset gives
byte-oriented `std.Io.File` behavior over the sector-oriented disk simulator.
The backend also supports a narrow directory namespace: absolute and
handle-relative paths, create/open/access/stat, direct-child iteration,
directory syncing through `File.sync`, and process-coordinated advisory file
locks with blocking and non-blocking acquisition. Directory state is owned by
`SimDisk`, so all simulated processes observe one namespace and crash metadata
faults affect unsynced directory entries. It does not model a complete host
filesystem. File stats track `mtime` for successful content mutations; `atime`
and `ctime` remain zero. `Dir.createFile` routes new empty files through the
disk authority.
Blocking queue waits, directory deletion/rename, chmod/chown, symlinks, memory
maps, process operations, datagrams, DNS, and real external network access
fail closed until they are routed through simulator-owned state.

The implementation target is for simulation envs to return an increasingly
complete deterministic `std.Io` that routes supported time, file, network,
queue, and concurrency operations through `World`.

## Mapping

The future deterministic implementation maps `std.Io` operations onto existing
Marionette simulator state.

- `io.sleep(duration)` parks the current task and advances simulated time.
  (Done.)
- `io.async` and `io.concurrent` enqueue deterministic simulator tasks.
  (Done.)
- `future.await(io)` parks until the target task completes. (Done; awaiting
  from the non-task scenario context drives the scheduler instead.)
- `future.cancel(io)` requests cancellation and awaits completion. (Done for
  the current supported futex, sleep, and network cancellation points;
  additional I/O surfaces must define their own cancellation behavior.)
- `Io.Queue(T)` becomes a deterministic queue with documented wake order.
- file I/O routes through the disk simulator and `DiskControl` fault state.
- network I/O routes through the network simulator and `NetworkControl` fault
  state.

All decisions that can vary between runnable tasks must be seed-determined and
trace-visible enough to replay failures.

## std.Io.net Suspension Plan

Zig 0.16's `std.Io.net` vtable already gives Marionette the seam it needs for
a narrow deterministic stream backend:

- immediate operations: `netListenIp`, `netClose`, `netShutdown`;
- suspending operations: `netConnectIp` while its probe is queued, `netAccept`
  when no connection is queued, `netRead` when the peer is open but no bytes
  are buffered, and `netWrite` under simulated backpressure;
- currently unsupported or out of scope: DNS lookup, Unix sockets, datagrams,
  socket pairs, `sendmsg`/`recvmsg`, `writeFile`, and interface-name queries.

The first useful slice replaces the current `WouldBlock` / `Timeout` stand-ins
with scheduler-backed suspension when a wait set is attached. `netAccept` parks
on a stable listener wait key and wakes when `netConnectIp` queues a connection.
`netRead` parks on a stable socket wait key and wakes when bytes arrive or the
peer closes. The current tests use two fibers, one server and one client,
asserting byte-identical same-seed traces for connect/accept/read/write before
any real SUT is involved.

The next validation layer is implemented as an external-style fixed-frame KV
client/server. The SUT imports only `std`, while the harness owns Marionette's
scheduler, latency, partition/heal sequence, trace, and retry-idempotency
oracle. It demonstrates a stream-visible timeout followed by a deterministic
retry and keeps a planted duplicate-apply mode as a replayable failure. This is
ordinary production-shaped code, but it is maintained in this repository and
is not counted as a third-party SUT finding.

Stream connects and writes route through the shared byte-message runtime when
network control is attached. Connection probes and framed payloads traverse
the existing latency/link/clog machinery, while stream loss is terminal so a
reliable stream never exposes an interior byte hole. Delayed stream bytes wake
readers through the scheduler's timed wait path. Send-time and delivery-time
faults preserve enough frame metadata to wake the affected connection with
stream-shaped errors; destination-down delivery maps to `error.NetworkDown`.
Connect duration/deadline timeouts and cancellation roll back unpublished
attempts. External host networking, broader DNS, and datagrams remain future
work. A Marionette-owned production transport is not: the
roadmap's sibling-network-surfaces decision cancelled it, and production
socket networking is host `std.Io.net`.

Graceful close does not discard delayed bytes already accepted by the shared
network runtime. A reader drains pending deliveries before observing EOF.

TCP stream bytes remain ordered within a connection. Marionette does not inject
intra-stream reorder because that would violate the transport contract;
reordering belongs on `Endpoint(Message)`, where independently delivered
messages can legitimately arrive in a different order.

`Endpoint(Message)` and `std.Io.net` must stay as sibling surfaces over
simulator-owned network state. Do not implement `std.Io.net` on top of
`Endpoint(Message)`, and do not force endpoint messages through a fake socket
stack. The typed endpoint remains the message-altitude API: faults appear as
dropped, delayed, clogged, partitioned, or reordered messages. The
`std.Io.net` backend is the byte-stream altitude: the same simulator authority
must translate faults into stream vocabulary such as blocked reads, timeouts,
EOF, connection reset, or network-down errors. Keeping those translations
separate preserves Marionette's existing message model while making ordinary
`std.Io.net` code testable.

## Fiber and Evented Boundary

The hard part is suspension. A deterministic single-threaded `std.Io`
implementation needs to stop a task at I/O points, run another task, then resume
the first task later.

Zig 0.16 exposes low-level fiber context switching on supported architectures
and uses it inside `std.Io.Evented`. Marionette now has a small internal
`src/fiber.zig` seam over that primitive, verified on `aarch64-macos` and
`x86_64-macos` without using Evented. Marionette should not use
`std.Io.Evented` as its simulator backend. Evented is built on kernel or OS
event sources such as io_uring, kqueue, and platform dispatch mechanisms; their
completion order is outside Marionette's control. That breaks the replay
guarantee.

Marionette wants the lower-level fiber machinery, not the OS event loop. The
deterministic backend implements the `std.Io` vtable itself, schedules fibers
with `World`'s seeded ordering, and routes file/network operations through
Marionette's simulated disk and network state.

This means Phase 1 was not blocked on inventing coroutines from scratch. The
bare context-switch spike is green for the pinned compiler, and the first
scheduler layers now cover ready ordering, futex wait sets, and timed futex
waits. `Io.async`/`Io.concurrent`/`await` now run through each simulation's
world-owned scheduler, and the validation harnesses use them exclusively.
`Io.Group` and cooperative cancellation at the supported futex, sleep, and
network points are implemented. Remaining scheduler risk is broader I/O
suspension, explicit cancellation contracts for each new surface, and
same-seed trace stability as more real SUTs move onto the backend.

Do not build a separate libucontext or assembly coroutine runtime. Marionette's
fiber experiments should continue through the local seam over `std.Io.fiber`
and keep the backend clearly marked experimental.

## Cooperative Concurrency Scope

The current scheduler result is deliberately narrow but real: unmodified
cooperative `Mutex` / `Condition` code can run deterministically under
Marionette through `std.Io.fiber`-backed simulated futexes. The pinned lazy
`g41797/mailbox` validation target exercises a real third-party library through
that path, including timed `receive`, send/wake, and same-deadline timeout
ordering. The validation asserts byte-identical same-seed traces and checks
that Mailbox reached the deadline-carrying futex path.

The internal `validate-bounded-queue` target exercises the same tier with a
canonical producer-consumer oracle: every pushed item must be popped exactly
once, in FIFO order, across a seed sweep. It also keeps one deliberately buggy
close path where `signal` replaces the required `broadcast`; Marionette reports
the resulting lost-wakeup deadlock deterministically. This is a capability
demonstration, not an external SUT bug.

This does not mean Marionette models arbitrary concurrent Zig. The current
claim is cooperative task scheduling inside Marionette's scheduler, not
preemptive OS threads or memory-model interleavings. Atomics, lock-free
algorithms, torn non-atomic reads, missed wakeups in host condition variables,
and CPU reorderings remain outside this model and need different tools. The
single-future and `Io.Group` `async` / `concurrent` / await/cancel paths are
implemented. Cooperative cancellation is intentionally scoped to the
supported futex, sleep, and network points; every future suspending I/O
surface must add and validate its own cancellation contract.

The scheduler work exposed two concrete determinism leaks that future backend
work should keep in view:

- raw futex pointer addresses never enter the trace; the sim backend maps them
  to stable logical keys so ASLR and allocator placement do not affect replay;
- scheduler-side dispatch plus fiber suspension and completion boundaries are
  intentionally opaque to the optimizer. ReleaseSafe corrupted task state when
  the optimizer inlined across a context-switch boundary, so those `noinline`
  boundaries are load-bearing.

## Existing Primitives

The experimental `Endpoint(Message)` remains useful for modeling protocols
directly above the wire. It does not serialize its payload or exercise a real
codec, framing implementation, or socket transport, so it carries a narrower
same-protocol-code guarantee than `std.Io.net`'s literal same-code path.

The redundant public `ByteEndpoint` facade was removed in 0.6. Its pooled byte
runtime remains a private part of deterministic `std.Io.net`, not a second API
for applications to adopt.

Promotion of the typed endpoint into a stable message-transport interface is
SUT-gated in the roadmap. A real integration must drive its ownership,
delivery, readiness, lifecycle, cancellation, and backpressure semantics.

## Env, Io, and Tracing

Production libraries should not need `mar.Env`. They should accept `std.Io`.

Tracing is still valuable. The clean long-term shape is a narrow recorder
capability, separate from `Env`, that production-shaped code may optionally
accept:

```zig
fn put(io: std.Io, recorder: mar.Recorder, key: u64, value: u64) !void {
    try recorder.record("kv.put key={} value={}", .{ key, value });
}
```

Production can pass a no-op recorder or one backed by logging. Marionette can
pass a recorder backed by the trace. This keeps `Env` harness-owned while
preserving rich traces where users want them.

Do not make general-purpose libraries depend on `mar.Env` just to get tracing.

## External Network

The deterministic simulator models a closed network. Code running under
Marionette's deterministic `std.Io` should only be able to reach endpoints that
the simulation declares.

The default behavior for external hostnames or addresses is failure, such as
`error.HostNotFound` or `error.NetworkUnreachable`, depending on where the
lookup or connect fails. This strict default keeps DST runs hermetic and
replayable.

Tests that need external services should route names into simulator-owned
servers. The small core should be:

- alias this name or address to a simulator node or listener;
- let user code run the fake service as ordinary Marionette-shaped server code;
- let that server use simulator time, disk, network, and faults.

Marionette should not grow a generic wiremock-style matcher DSL by default.
Request matching, canned responses, sequencing, and protocol-specific behavior
grow without a clean stopping point. If a test needs an etcd-shaped service, an
S3-shaped service, or a SQL-shaped service, the user should be able to run a
small fake server inside the simulator using normal Zig code.

A future community package can provide reusable fake services for common
protocols. That is different from making Marionette itself responsible for
behavior-faithful simulators for every external dependency.

Real network passthrough is an explicit escape hatch, not a default. It should
be opt-in, visible in the trace, and documented as breaking deterministic replay.
This is useful for smoke tests and integration suites, but those runs are not
DST runs in the strict sense.

## Implementation Status

The experimental deterministic `std.Io` foundation is implemented:

- `Env.io()` supplies deterministic clock, random, file, futex, and narrow
  stream-network behavior in simulation.
- A local `std.Io.fiber` seam supports the seeded cooperative scheduler.
- Scheduler-backed `Io.sleep` parks tasks, preserves earlier deadlines, and
  quantizes arbitrary durations to the simulation clock resolution.
- Futex wait/wake and timed waits are validated with the pinned
  `g41797/mailbox` target and the internal bounded-queue oracle.
- Scheduler-backed `std.Io.net` accept/read suspension routes stream bytes
  through the shared network loss, latency, clog, and partition runtime.
- The fixed-frame KV validation covers replay, timeout, heal/retry,
  idempotency, and graceful-close delivery.
- TCP byte order is preserved within each stream; message reordering remains
  an `Endpoint(Message)`-altitude fault.

Remaining deterministic `std.Io` work includes queue suspension, cancellation
contracts for future I/O surfaces, richer stream reset/node-down behavior, and
continued validation against real `std.Io`-native libraries.

The next maturity phase is production readiness and ecosystem leverage:

- shrink or eliminate the fiber-stack caveats as Zig's coroutine work matures;
- standard and third-party libraries accept `std.Io`;
- Marionette can run those libraries unchanged under deterministic simulation;
- Marionette-specific I/O primitives remain available for precise protocol
  modeling and compatibility.

## Guarantees

The deterministic `std.Io` backend must preserve:

- byte-for-byte replay for a seed and program;
- seed-determined scheduling ties;
- no wall-clock time leaks;
- no system entropy leaks through simulator-controlled I/O;
- fault injection through `Control`, not per-call flags.

It will not make direct OS calls deterministic. Code that bypasses `std.Io` is
outside the simulator.

## Open Questions

- Which real SUT, if any, justifies promoting the experimental typed endpoint
  into a stable message-transport contract?
- Which additional `std.Io` operations should be implemented only when a real
  validation target requires them?
