# Changelog

## v0.3.0 - Unreleased

Marionette's third release makes deterministic `std.Io` execution the primary
integration tier:

- Adds scheduler-backed `Io.async`, `Io.concurrent`, and `Io.await`, including
  task-side suspension and main-context scheduler driving.
- Routes simulated sleep and disk-operation latency through scheduler
  deadlines, so a long I/O operation cannot skip an earlier timer.
- Adds traced deterministic `Io.random` / `Io.randomSecure` and compares replay
  outcomes symmetrically, including failures.
- Runs the pinned `g41797/mailbox` validation and the bounded-queue capability
  validation entirely through ordinary `std.Io` tasks.
- Adds an external-style fixed-frame KV client/server written only against
  `std.Io.net`, with deterministic happy-path replay and a
  partition/timeout/heal retry scenario.
- Adds `zig build validate-std-io-net-kv` plus runnable correct and planted-bug
  scenarios. The exact oracle catches duplicate mutation application even when
  the final value is unchanged.
- Suspends `std.Io.net` accept and read operations cooperatively and models
  stream latency, send-time loss, delivery-time partitions, healing, retry
  timeouts, and graceful close.
- Models disk crashes as process restarts for the file layer: open handles are
  invalidated and cached lengths are refreshed from durable disk state.
- Fixes Zig 0.16 fiber context-switch constraints and optimizer visibility,
  adds unwind-safe entry stacks, eagerly reclaims completed fiber stacks, and
  adds POSIX guard pages with a portable stack-canary fallback.
- Splits disk, network, and `std.Io` internals into focused modules and narrows
  obsolete top-level API aliases.
- Makes failed simulation construction roll back teardown registrations,
  enforces one simulation per world, and shares rooted logical-path validation
  between simulated and production disks.
- Makes production directory sync fail explicitly with
  `error.DirectorySyncUnsupported` rather than reporting durability without
  performing it.
- Disables x86_64 Windows fiber execution until the Win64 entry trampoline has
  execution coverage; the disabled target remains compile-checked.
- Expands CI to Debug, ReleaseSafe, and ReleaseFast validation, macOS execution,
  a Win64 fiber compile check, and bounded job timeouts.

Known limits remain: fibers are cooperative rather than preemptive; one world
hosts one simulation; current `std.Io.net` listener/connection allocation
consumes fixed topology nodes; `Io.Group`, cooperative cancellation, logical
process restart, cross-process production networking, and complete host
filename parity remain roadmap work.

## v0.2.0 - 2026-06-02

Marionette's second tagged release adds the cooperative-concurrency tier:

- Adds the `std.Io.fiber`-backed scheduler stack: deterministic task spawning,
  seeded runnable selection, blocking wait sets, futex wakeups, and timed futex
  waits.
- Runs a real Zig cooperative-concurrency library, `g41797/mailbox` pinned at
  `d30ff69f1fa0288e1a8cb96b24ae3b552739f490`, unmodified through Marionette's
  scheduler-backed `std.Io`.
- Verifies same-seed replay for Mailbox timeout, same-deadline timeout
  ordering, and send/wake paths through `zig build validate-mailbox`.
- Keeps the concurrency claim deliberately scoped: cooperative `Mutex` /
  `Condition` code is modeled; arbitrary OS thread scheduling, memory-model
  interleavings, `async` / `await`, cancellation, allocator simulation, and
  production scheduler parity remain roadmap work.
- Keeps the v0.1 storage story intact: `zig build validate-xitdb` still runs
  the pinned xitdb validation target against the deterministic file backend.

## v0.1.0 - 2026-05-29

Marionette's first tagged release demonstrates the core thesis:

- Runs a real Zig storage engine, `xit-vcs/xitdb` pinned at
  `f86134242e4d265cddfb0dbebd4d2d6dd4967274`, unmodified through Marionette's
  deterministic `std.Io` file backend.
- Replays deterministically from a seed and validates xitdb against a modeled
  randomized workload.
- Confirms, on the pinned xitdb commit and the current validation profile, that
  acknowledged file-backed transactions survive lost-write crash injection.
- Checks xitdb old read-only moments after later writes and verifies the same
  modeled workload against both SimDisk and host `std.Io`.
- Surfaces a precise sub-field-granularity torn-write counterexample: xitdb's
  committed-size field lives at bytes 28-35, so it is structurally atomic for
  512- and 4096-byte sectors, but Marionette can demonstrate the recovery
  boundary with a deliberately non-realistic 7-byte sector.

This is still a `0.x` API. There is no stability guarantee before 1.0. The
intended-stable surface today is `World`, `Env`, `Control`, `runCase` /
`expect*`, `Disk`, `SimDisk`, `RealDisk`, `Production`, `Recorder`, and the
app-facing `Endpoint(Message)` shape. Everything else may change as the
simulator grows.

Known scope limits for this release:

- `Mutex`, `Condition`, futex waits, and arbitrary OS thread scheduling are not
  modeled.
- Production network transport is partial; cross-process production endpoints
  remain roadmap work.
- Allocator simulation and shrinking are planned, not shipped.
