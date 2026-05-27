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
`randomSecure` operations today. It also supports synchronous `async` and
`Group.async` for functions that complete immediately, inert cancellation checks,
`Io.Queue` operations that can complete without parking, and a small in-memory
TCP stream subset for `std.Io.net` listen/connect/accept/read/write/close.
Empty accepts return `error.WouldBlock`; empty stream reads return
`error.Timeout` while the peer remains open because Zig 0.16's stream reader
error set has no `WouldBlock` variant. It also supports a flat file subset over
`SimDisk`: `Dir.createFile`, `Dir.openFile`, `Dir.statFile`,
`Dir.access`, positional file read/write, `File.length`, `File.stat`,
`File.setLength`, `File.sync`, `File.close`, `Dir.deleteFile`, and
`Dir.rename`. This subset gives
byte-oriented `std.Io.File` behavior over the sector-oriented disk simulator
without modeling a complete filesystem. File stats track `mtime` for successful
content mutations; `atime` and `ctime` remain zero.
`concurrent`, blocking queue waits, directory metadata and iteration,
chmod/chown, symlinks, memory maps, process operations, datagrams, DNS, and real
external network access fail closed until they are routed through
simulator-owned state.

The eventual target is for simulation envs to return a fuller deterministic
`std.Io` that routes time, files, network, queues, and concurrency through
`World`.

## Mapping

The future deterministic implementation maps `std.Io` operations onto existing
Marionette simulator state.

- `io.sleep(duration)` parks the current task and advances simulated time.
- `io.async` and `io.concurrent` enqueue deterministic simulator tasks.
- `future.await(io)` parks until the target task completes.
- `future.cancel(io)` requests cancellation at the next yield point.
- `Io.Queue(T)` becomes a deterministic queue with documented wake order.
- file I/O routes through the disk simulator and `DiskControl` fault state.
- network I/O routes through the network simulator and `NetworkControl` fault
  state.

All decisions that can vary between runnable tasks must be seed-determined and
trace-visible enough to replay failures.

## Fiber and Evented Boundary

The hard part is suspension. A deterministic single-threaded `std.Io`
implementation needs to stop a task at I/O points, run another task, then resume
the first task later.

Zig 0.16 exposes low-level fiber context switching on supported architectures
and uses it inside `std.Io.Evented`. Marionette should not use
`std.Io.Evented` as its simulator backend. Evented is built on kernel or OS
event sources such as io_uring, kqueue, and platform dispatch mechanisms; their
completion order is outside Marionette's control. That breaks the replay
guarantee.

Marionette wants the lower-level fiber machinery, not the OS event loop. The
deterministic backend should implement the `std.Io` vtable itself, schedule
fibers with `World`'s seeded ordering, and route file/network operations through
Marionette's simulated disk and network state.

This means Phase 1 is not blocked on inventing coroutines from scratch. It is
blocked on whether the current fiber stack and `std.Io` surface are acceptable
for an experimental backend. The answer can be "yes" for small opt-in tests
before it is "yes" for production-grade large simulations.

Do not build a separate libucontext or assembly coroutine runtime. If Marionette
experiments with fibers, it should use Zig's `std.Io.fiber` primitives directly
and keep the backend clearly marked experimental.

## Existing Primitives

The current Marionette network types are not wasted.

`Endpoint(Message)`, `ByteEndpoint`, `ByteTransport`, and
`CodecTransport(Codec)` are explicit-control primitives. They are useful for
modeling protocols directly, testing framed transports, and building examples
before the `std.Io` ecosystem is ready.

As `std.Io` matures, these types should become the precise Marionette-native
path, while ordinary libraries use `std.Io` directly.

The naming should avoid future confusion. If `std.Io.net` becomes the normal
network surface, Marionette's typed in-process network should likely be
documented as a message bus rather than "the network."

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

## Phases

Phase 0 is the current bridge:

- expose `Env.io()` with deterministic clock/random support in simulation;
- keep building explicit-control primitives;
- document the deterministic `std.Io` destination;
- add small non-coroutine pieces where they help users migrate to `io`-shaped
  code.

Phase 1 is experimental deterministic `std.Io`:

- implement a Marionette `std.Io` vtable backed by Zig fiber primitives;
- implement the deterministic scheduler for small opt-in simulations;
- route sleep, queue, file, and network I/O through `World`;
- expand simulation `Env.io()` from the Phase 0 backend into a suspending
  deterministic `std.Io`;
- document memory and platform caveats clearly.

Phase 2 is production readiness and ecosystem leverage:

- shrink or eliminate the fiber-stack caveats as Zig's coroutine work matures;
- standard and third-party libraries accept `std.Io`;
- Marionette can run those libraries unchanged under deterministic simulation;
- Marionette-specific I/O primitives remain available for precise protocol
  modeling and compatibility.

## Guarantees

The future deterministic `std.Io` must provide:

- byte-for-byte replay for a seed and program;
- seed-determined scheduling ties;
- no wall-clock time leaks;
- no system entropy leaks through simulator-controlled I/O;
- fault injection through `Control`, not per-call flags.

It will not make direct OS calls deterministic. Code that bypasses `std.Io` is
outside the simulator.

## Open Questions

- How much of the `std.Io` vtable should the Phase 0 backend support before
  fiber scheduling begins?
- Should Marionette introduce `mar.Recorder` before or after the deterministic
  `std.Io` implementation?
- What exact API registers external network mocks, and how much should it model
  before users ask for more?
- Should `Endpoint(Message)` be renamed or documented as `MessageBus(Message)`
  before public users depend on it?
- How much of `std.Io` should Phase 1 implement before the project claims
  "deterministic std.Io" publicly?
