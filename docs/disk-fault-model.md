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

The disk authority is owned by `World` and exposed to application code through
the environment. Application code should depend on `env.disk()`, not on
`World` internals:

```zig
fn store(env: anytype, entry: []const u8) !void {
    try env.disk().write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = entry,
    });
    try env.disk().sync(.{ .path = "wal.log" });
}
```

The test harness may still use `World` or a simulator-control handle to
inspect disk state, inject scripted faults, or crash/restart the simulated
disk. Those operations must not leak into the app-facing disk API.

In later multi-node work, each simulated node should expose its own disk view:

```zig
try node.env().disk().write(.{ .path = "wal.log", .offset = offset, .bytes = entry });
```

The shared `World` remains the owner of the clock, PRNG, global event index,
and trace. The disk handle should not read wall-clock time, call host
randomness, or use host filesystem state as a simulator decision source.

The first public type name should be `Disk`. Smaller terms like `BlockDevice`
are too narrow for a WAL/KV-store example, and broader terms like `Storage`
are too vague.

## Operation Model

Every disk operation should receive a deterministic operation id. The
simulator can then order pending work by:

1. `ready_at` simulated timestamp.
2. Operation id.

That ordering avoids pointer addresses, hash-map iteration order, and host
scheduling as tie breakers.

Initial operation concepts:

- File identity: logical path-like names (`[]const u8`) scoped to the
  simulated disk. These are not host paths and must not read host filesystem
  state. Trace output writes them through `recordFields` text escaping.
- Offset and length: integer byte ranges.
- Sector size: a configured simulation parameter, defaulting to 4096 bytes.
- Pending operation: submitted work waiting for simulated latency.
- Completed operation: result delivered to user code.
- Crash window: submitted or partially completed writes affected by crash.

The Phase 1 implementation should start synchronous from the user's
perspective: a `write` or `read` may advance simulated time internally and then
return. The model can still assign operation ids and latency so traces match
the future scheduler shape. A later async scheduler can split submit/complete
without changing trace ordering.

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
globally. Disk code must use `World.recordFields` so logical paths and status
strings are escaped consistently. Candidate Phase 1 events:

- `disk.read op=<u64> path=<escaped-text> offset=<u64> len=<u64> status=<literal> latency_ns=<u64>`
- `disk.write op=<u64> path=<escaped-text> offset=<u64> len=<u64> status=<literal> latency_ns=<u64>`
- `disk.sync op=<u64> path=<escaped-text> status=<literal> latency_ns=<u64>`
- `disk.fault op=<u64> path=<escaped-text> kind=<literal>`
- `disk.crash pending_writes=<u64> landed=<u64> lost=<u64> torn=<u64>`

Use status values such as `ok`, `io_error`, `corrupt`, and `torn`. Use fault
kinds such as `read_error`, `write_error`, `corrupt_read`, `lost_write`, and
`torn_write`.

Trace fields must be scalar, deterministic, and independent of pointer
identity. User bytes should not be dumped into the default trace unless a
caller explicitly requests that, because it can make traces huge and unstable.
Trace `len`, not byte contents. If a debugging mode later records payload
hashes, the hash algorithm must be named and stable.

## Determinism Rules

- All latency and fault choices draw from the world's PRNG.
- All time movement routes through the world's clock.
- Ready operations use a stable `(ready_at, op_id)` ordering.
- Host filesystem calls are not part of the simulator model.
- Disk APIs must not call `std.crypto.random`, `/dev/urandom`, or wall-clock
  time.
- Tests must compare same-seed disk traces byte-for-byte.
- Checksums and record validation belong to user code in Phase 1. Marionette
  may corrupt, tear, lose, or error operations, but it should not infer storage
  format semantics.

## Phase 1 Decisions

- First type: `Disk`.
- App-facing access: `env.disk()`.
- File identity: logical path-like `[]const u8`, escaped in traces and never
  resolved against the host filesystem by the simulator.
- Default sector size: 4096 bytes.
- Initial operations: `read`, `write`, `sync`, and explicit simulated crash.
- Initial example: append-only WAL recovery.
- User data: store bytes in memory, trace lengths and outcomes by default.
- Checksums: user code owns them.
- Recoverability budgets: start with a conservative single-node default and
  explicit destructive mode; defer strong multi-replica budgets.

## Open Questions

- How closely should the production `Disk` adapter align with future `std.Io`
  file APIs?
- Should Phase 1 expose `create/delete/rename`, or should the first WAL
  example avoid directory semantics entirely?
- Should `sync` be per-file only, or should there also be a whole-disk sync?
- What is the smallest explicit API for declaring recovery windows?
