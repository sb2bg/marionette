# Marionette as Deterministic std.Io

This document sets the long-term direction for Marionette: become the
deterministic `std.Io` implementation for Zig.

The design is forward-looking. Zig 0.16 introduced the `std.Io` interface, but
the coroutine-backed implementations needed for a full single-threaded
cooperative simulator are still evolving. Marionette should move toward this
shape without pretending the full runtime exists today.

## Vision

Production Zig libraries should eventually accept `std.Io` for I/O, sleep,
networking, files, and concurrency. Marionette should provide a deterministic
implementation of that interface for tests.

The desired user model is:

```zig
const sim = try world.simulate(.{});
const io = sim.env.io().?;

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
- simulation envs return `null` until Marionette ships a deterministic
  `std.Io` implementation.

This avoids shipping a fake deterministic runtime while still making the API
direction explicit.

The eventual target is for simulation envs to return a deterministic `std.Io`
that routes time, files, network, queues, and concurrency through `World`.

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

## Coroutine Constraint

The hard part is suspension. A deterministic single-threaded `std.Io`
implementation needs to stop a task at I/O points, run another task, then resume
the first task later.

Without stable Zig coroutine support, there are three choices:

- hand-write state machines, which defeats the purpose;
- ship platform-specific stackful coroutines, which is high-risk and likely to
  be rewritten later;
- design now and implement the full scheduler when Zig support is ready.

Marionette should take the third path for now. Do not build a libucontext or
assembly coroutine runtime yet.

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

## Phases

Phase 0 is the current bridge:

- expose `Env.io()` with the honest optional contract;
- keep building explicit-control primitives;
- document the deterministic `std.Io` destination;
- avoid a fake coroutine runtime.

Phase 1 begins when coroutine support is tractable:

- implement the deterministic scheduler;
- route sleep, queue, file, and network I/O through `World`;
- make simulation `Env.io()` return a real deterministic `std.Io`.

Phase 2 is ecosystem leverage:

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

- When should `Env.io()` become non-optional?
- Should Marionette introduce `mar.Recorder` before or after the deterministic
  `std.Io` implementation?
- Should `Endpoint(Message)` be renamed or documented as `MessageBus(Message)`
  before public users depend on it?
- How much of `std.Io` should Phase 1 implement before the project claims
  "deterministic std.Io" publicly?
