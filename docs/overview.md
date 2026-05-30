# Overview

Marionette is a deterministic I/O and simulation testing library for Zig.
The long-term target is to become the deterministic `std.Io` implementation
for Zig.

The core promise: write production-shaped code against `std.Io` and narrow
Marionette handles such as `Recorder` or `Endpoint(Message)`. In production,
those handles route to direct operations. In simulation, they route through a
controlled world that can replay the same execution from the same seed.

Marionette is still experimental, but the core replay loop is real: seeded
randomness, simulated time, trace logging, twice-and-compare replay, trace
summaries, named post-scenario checks, deterministic disk/network authorities
with replayable faults, and a deterministic `std.Io` backend for the current
file and network subset. A real scheduler and richer replay tooling are
planned.

For the precise correctness model, see [Architecture](architecture.md). For
the replay artifact bytes, see [Trace Format](trace-format.md). For
simulation-only fault hooks, see [BUGGIFY](buggify.md). For storage faults,
see [Disk Fault Model](disk-fault-model.md). For the long-term `std.Io`
direction, see [std.Io Direction](std-io-direction.md).

## What This Solves

Distributed systems bugs often depend on timing, ordering, and failure:

- A timeout fires just before a response arrives.
- A write succeeds locally but is lost before replication.
- A node observes messages in an unlucky order.
- A retry races with leader election.

Normal tests rarely explore those interleavings systematically. When they
do find one, the failure can be hard to reproduce.

DST makes the test environment deterministic. A seed controls simulated
choices. The world records a trace. When a bug appears, the seed and trace
become the starting point for debugging.

## What Marionette Is Not

Marionette is not:

- A general-purpose testing framework. Use `std.testing` for unit tests.
- A fuzzer for pure functions.
- A consensus library.
- A production runtime.
- A syscall interception layer.
- A tool that makes arbitrary non-deterministic code deterministic.

Users must route time, randomness, disk, and network through Marionette-owned
authorities. For storage code, the preferred authority is `std.Io`; `Env` is
the harness-owned bundle that supplies that I/O backend plus recorders and
remaining Marionette capabilities. That discipline is the product.

Marionette does not auto-detect whether code is running in production or
simulation. The composition root passes explicit handles into the application;
simulation harnesses build those handles with `world.simulate`.

## Why Zig

Marionette fits Zig because Zig already pushes code in the right direction:

- Explicit allocator passing.
- No hidden runtime.
- Comptime specialization.
- Interface-passing by convention.
- Systems programmers who care about reproducibility and control.

The design goal is for production builds to pay nothing for simulation code
they do not use, while tests get a world that can control and replay every
interesting source of non-determinism.

## Audience

Marionette is aimed at people building reliability-critical systems:

- Databases.
- Queues.
- Storage engines.
- Consensus systems.
- Replicated services.
- Distributed schedulers.
- Infrastructure control planes.

It is probably overkill for ordinary CRUD applications.
