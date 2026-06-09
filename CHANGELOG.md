# Changelog

## Unreleased

- Adds an external-style fixed-frame KV client/server written only against
  `std.Io.net`, with deterministic happy-path replay and a
  partition/timeout/heal retry scenario.
- Adds `zig build validate-std-io-net-kv` plus runnable correct and planted-bug
  scenarios. The exact oracle catches duplicate mutation application even when
  the final value is unchanged.
- Fixes simulated graceful close so delayed bytes already accepted by the
  network runtime are delivered before the reader observes EOF.
- Keeps the scheduler-side run loop optimizer-opaque across fiber stack
  switches, fixing a ReleaseSafe crash exposed by the client/server workload.
- Documents the current TCP-like stream contract and unsupported network
  boundary.

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
