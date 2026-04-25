# Disk Fault Model

This is the design note for Marionette's disk simulation work. The first
no-fault `mar.Disk` authority exists; the fault and crash model described here
is still being built.

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

## VOPR Lessons

TigerBeetle's VOPR storage simulator is deliberately protocol-aware. It keeps
simulated storage in memory, queues reads and writes with simulated latency,
tracks faulty sectors, can misdirect writes, and can fault targets of pending
writes during crash. More importantly, its cluster-level fault atlas decides
which replicas and storage regions are eligible for faults so the simulator
does not manufacture impossible worlds where every recoverable copy is
destroyed at once.

Marionette should adapt that lesson, not copy the whole design. TigerBeetle can
name zones such as superblock, WAL headers, WAL prepares, and grid blocks
because VOPR is product-specific. Marionette's Phase 1 `Disk` should stay
generic: logical paths, byte ranges, sector size, pending writes, and explicit
fault profiles. Product-specific recoverability still belongs to examples and
checks until enough examples justify a generic fault-atlas API.

The immediate rule is: no unconstrained "random disk chaos" default. Every
destructive disk fault needs a scope, a budget, and a trace event.

## Authority Shape

The current `mar.Disk` authority is constructed from `World` by the simulation
harness or scenario state. The intended app-facing shape is still environment
based: application code should eventually depend on `env.disk()`, not on
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

The test harness may still construct `Disk` from `World` or use a
simulator-control handle to inspect disk state, inject scripted faults, or
crash/restart the simulated disk. Those operations must not leak into the
app-facing disk API.

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

Implemented no-fault operation concepts:

- File identity: logical path-like names (`[]const u8`) scoped to the
  simulated disk. These are not host paths and must not read host filesystem
  state. Trace output writes them through `recordFields` text escaping.
- Offset and length: integer byte ranges.
- Sector size: a configured simulation parameter, defaulting to 4096 bytes.
- Completed operation: result delivered to user code after deterministic
  synchronous latency.

Future operation concepts:

- Pending operation: submitted work waiting for simulated latency.
- Crash window: submitted or partially completed writes affected by crash.

The Phase 1 implementation should start synchronous from the user's
perspective: a `write` or `read` may advance simulated time internally and then
return. The model can still assign operation ids and latency so traces match
the future scheduler shape. A later async scheduler can split submit/complete
without changing trace ordering.

The backing implementation should be an in-memory durable model. Production
adapters may later route the same narrow API to host filesystem calls, but the
simulator itself should not depend on the host filesystem for data, metadata,
ordering, or failure behavior.

## Faults

Initial faults should be small and explicit:

- Latency: operation completes at a deterministic future timestamp.
- IO error: read/write returns a simulated disk error.
- Corruption: read returns bytes that differ from the durable model.
- Torn write: a crash leaves only part of a write durable.
- Lost pending write: a crash drops an acknowledged-pending write before it
  becomes durable.

Later faults can include misdirected writes, stale reads, byte-level
corruption, reordered flushes, and more specific media behavior, but only after
the basic model is traceable and tested. Misdirected writes should be a named
fault type rather than being collapsed into generic corruption, because they
test whether user code validates record identity and location.

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

For Phase 1, the append-only WAL example should define its own recovery window
in the checker: flushed records are durable truth; unflushed records may be
lost, torn, or corrupted according to the profile. A later generic fault atlas
can lift that pattern out of examples.

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
- Initial operations: `read`, `write`, and `sync` are implemented. Explicit
  simulated crash is next.
- Initial example: append-only WAL recovery.
- User data: store bytes in memory, trace lengths and outcomes by default.
- Checksums: user code owns them.
- Recoverability budgets: start with a conservative single-node default and
  explicit destructive mode; defer strong multi-replica budgets.
- Misdirected writes: document as a future named fault, not Phase 1 default.

## Open Questions

- How closely should the production `Disk` adapter align with future `std.Io`
  file APIs?
- Should Phase 1 expose `create/delete/rename`, or should the first WAL
  example avoid directory semantics entirely?
- Should `sync` be per-file only, or should there also be a whole-disk sync?
- What is the smallest explicit API for declaring recovery windows?
- What is the first reusable shape for a VOPR-style fault atlas once
  Marionette has more than one storage example?
