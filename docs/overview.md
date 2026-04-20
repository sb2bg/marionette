# Overview

Marionette is a deterministic simulation testing (DST) library for Zig.

The core promise: write a service against Marionette's interfaces for time,
randomness, disk, and network. In production, those interfaces compile down
to direct operations. In simulation, they route through a controlled world
that can replay the same execution from the same seed.

Phase 0 is intentionally small. Today Marionette has seeded randomness,
simulated time, trace logging, twice-and-compare replay, and named world/state
post-scenario checks. Disk, network, scheduling, and richer replay tooling are
planned.

For the precise correctness model, see [Architecture](architecture.md). For
the replay artifact bytes, see [Trace Format](trace-format.md). For the
planned zero-cost fault hook shape, see [BUGGIFY](buggify.md). For storage
faults, see [Disk Fault Model](disk-fault-model.md).

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

Users must route time, randomness, disk, and network through Marionette's
interfaces. That discipline is the product.

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
