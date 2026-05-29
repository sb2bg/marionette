# Changelog

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
