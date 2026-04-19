# Disk Fault Model

This is a design note for future disk simulation work. It is not a public disk
API yet.

The goal is a deterministic, recoverability-aware disk authority that can test
real storage code without pretending to model every filesystem or device
quirk. Marionette should make disk failures replayable from a seed, visible in
the trace, and constrained enough that failures teach users something useful.

## Goals

- Route every disk decision through the owning `World`.
- Make disk latency, errors, corruption, and crash timing deterministic.
- Preserve a stable trace of disk operations and fault decisions.
- Support single-node durability testing first.
- Leave room for replicated systems with per-node disk authorities later.
- Avoid fault profiles that destroy all durable truth unless explicitly
  requested.

## Non-Goals

- Full filesystem simulation.
- Modeling every OS-specific `std.fs` behavior.
- Arbitrary byte chaos as the default corruption model.
- Real block-device emulation.
- Transparent interception of direct filesystem calls.
- Unbounded double faults that make recovery impossible by construction.

## Authority Shape

The preferred shape is a disk authority owned by `World` and exposed through a
narrow handle:

```zig
fn store(disk: *mar.Disk) !void {
    try disk.write(.{ .file = .wal, .offset = 0, .bytes = "entry" });
}
```

In Phase 2, each `Node` should expose its own disk view:

```zig
try node.disk().write(.{ .file = .wal, .offset = offset, .bytes = entry });
```

The shared `World` remains the owner of the clock, PRNG, global event index,
and trace. The disk handle should not read wall-clock time, call host
randomness, or use host filesystem state as a simulator decision source.

## Operation Model

Every disk operation should receive a deterministic operation id. The
simulator can then order pending work by:

1. `ready_at` simulated timestamp.
2. Operation id.

That ordering avoids pointer addresses, hash-map iteration order, and host
scheduling as tie breakers.

Initial operation concepts:

- File identity: stable user-declared file ids, not host paths.
- Offset and length: integer byte ranges.
- Block or sector size: a configured simulation parameter.
- Pending operation: submitted work waiting for simulated latency.
- Completed operation: result delivered to user code.
- Crash window: submitted or partially completed writes affected by crash.

## Faults

Initial faults should be small and explicit:

- Latency: operation completes at a deterministic future timestamp.
- IO error: read/write returns a simulated disk error.
- Corruption: read returns bytes that differ from the durable model.
- Torn write: a crash leaves only part of a write durable.
- Lost pending write: a crash drops an acknowledged-pending write before it
  becomes durable.

Later faults can include misdirected writes, stale reads, reordered flushes,
and more specific media behavior, but only after the basic model is traceable
and tested.

## Recoverability

Fault injection needs budgets. A simulator that can corrupt every copy of
truth in one seed is not useful unless the test explicitly asked for a
destructive profile.

The first profiles should be conservative:

- Single-node default: at most one destructive disk fault per recovery window.
- Single-node aggressive: allow repeated failures, but keep them traceable.
- Replicated default: allow per-replica faults only while at least one quorum
  path remains recoverable.
- Destructive: no recoverability guard, intended for negative tests.

The exact recovery-window API is undecided. Users may need to declare durable
regions, replicas, checkpoints, or commit points before Marionette can enforce
strong budgets.

## Trace Events

Disk traces should be stable text events until the trace format changes
globally. Candidate events:

- `disk.read.start op={} file={} offset={} len={}`
- `disk.read.finish op={} status={} latency_ns={}`
- `disk.write.start op={} file={} offset={} len={}`
- `disk.write.finish op={} status={} latency_ns={}`
- `disk.flush.start op={} file={}`
- `disk.flush.finish op={} status={} latency_ns={}`
- `disk.fault op={} kind={}`
- `disk.crash_pending_write op={} outcome={}`

Trace fields must be scalar, deterministic, and independent of pointer
identity. User bytes should not be dumped into the default trace unless a
caller explicitly requests that, because it can make traces huge and unstable.

## Determinism Rules

- All latency and fault choices draw from the world's PRNG.
- All time movement routes through the world's clock.
- Ready operations use a stable `(ready_at, op_id)` ordering.
- Host filesystem calls are not part of the simulator model.
- Disk APIs must not call `std.crypto.random`, `/dev/urandom`, or wall-clock
  time.
- Tests must compare same-seed disk traces byte-for-byte.

## Open Questions

- What is the first public type: `Disk`, `Storage`, or a smaller `BlockDevice`?
- Should Phase 1 use stable file ids only, or support path-like names?
- What block size should examples use by default?
- How much checksum behavior belongs in Marionette versus user code?
- How should users declare recoverability budgets?
- How will this wrap or align with future `std.Io` disk interfaces?

Disk simulation should not start until these questions have enough answers to
keep the first API narrow.
