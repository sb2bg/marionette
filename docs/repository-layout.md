# Repository Layout

This guide is for contributors deciding where a change belongs. The public API
entry point is `src/root.zig`; users should import the `marionette` module, not
individual source files by path. Subsystem `root.zig` files are aggregation
boundaries for Marionette's implementation.

## Source Directories

`src/io/` contains Marionette's minimal `std.Io` support: backend plumbing,
file and network adapters, futex/task integration, shared errors, and focused
unit tests. Put code here when it is about making Zig `std.Io` operations run
under Marionette-controlled production or simulation authorities. Keep
subsystem tests in `src/io/tests.zig`.

`src/network/` contains deterministic and production network transport
implementation. It owns typed and byte endpoints, production endpoint setup,
the packet core, framing, network control hooks, and network tests. Add protocol-neutral transport behavior here; add application-specific
network scenarios under `examples/` or `validation/` instead.

`src/disk/` contains the app-facing disk capability, deterministic disk model,
simulation implementation, production adapter, disk controls, fault behavior,
and disk tests. Add storage-fault semantics here when they are part of
Marionette itself. Keep app-level WAL or database behavior in examples or
validation targets.

Top-level `src/*.zig` files compose the simulator: `World`, `Env`, `SimCase`,
`runSimCase`, the scheduler, clock, seeded random, trace summaries,
build support, and CLI entry points. Prefer these files for cross-subsystem
orchestration, not for disk, network, or `std.Io` internals that already have
an owner directory.

## Validation And Tests

`validation/` contains external or integration-style validation targets that
exercise Marionette against realistic concurrency, durability, or `std.Io.net`
workloads. Add a file here when the target is larger than a unit test and is
meant to prove Marionette works against code shaped like a real dependency or
application.

Subsystem unit tests live with their implementation in `src/io/tests.zig`,
`src/network/tests.zig`, and `src/disk/tests.zig`. Project-level tests live in
`tests/` when they cover package behavior such as determinism, fuzz-style
replay, or trace summaries rather than one subsystem.

## Documentation

`docs/` contains the contributor and user documentation published by MkDocs.
Add design notes, API direction, and operational guidance here, then wire new
pages into `mkdocs.yml` so they appear in the navigation. Keep documents
focused: if a page is about a specific subsystem, link to related pages instead
of copying their details.

## Examples

`examples/` contains small services that are both readable and testable. They
show how application code should accept Marionette-controlled authorities such
as `std.Io`, `mar.Endpoint`, `mar.Recorder`, and simulator controls from the
harness. Current examples cover:

- `retry_queue.zig`, the README-facing late-ack bug.
- `kv_store.zig`, a small disk-backed WAL.
- `idempotency_bug.zig`, a seed-sensitive replay demo.
- `replicated_register.zig`, typed endpoint and network partition behavior.
- `durable_broadcast.zig`, combined disk and network durability.
- `toy_sql_db.zig`, a larger storage-shaped example.
- `std_io_net_kv.zig`, the scheduler-backed `std.Io.net` example.

Add new examples to `examples/root.zig` so `zig build test` picks them up
without a new `build.zig` entry. If an example becomes primarily an external
compatibility check or a larger regression target, consider moving that shape
to `validation/`.
