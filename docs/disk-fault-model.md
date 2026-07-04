# Disk Fault Model

This is the design note for Marionette's disk simulation work. Production-shaped
storage code should usually use `std.Io`; `mar.Disk` is the lower-level
sector/file-lifecycle capability underneath that backend. `mar.SimDisk`
currently supports
deterministic logical files, latency, read/write IO errors, probabilistic
corrupt reads, scripted sector corruption, and crash/restart simulation for
pending writes. Generic recoverability budgets are still being built.

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

The current `mar.SimDisk` simulator is constructed from `World` by the
simulation harness or scenario state. It produces two capabilities over the
same backing state:

- `mar.Disk`: lower-level sector `read`, `write`, and `sync`, plus file
  metadata and lifecycle operations.
- `mar.DiskControl`: harness-facing faults, crash/restart, and scripted
  corruption.

Simulation application code that is intentionally testing the disk model can
receive `env.disk` instead of depending on `World` internals. Ordinary storage
code should prefer `env.io()` and `std.Io.File`:

```zig
fn store(disk: mar.Disk, entry: []const u8) !void {
    try disk.write(.{
        .path = "wal.log",
        .offset = 0,
        .bytes = entry,
    });
    try disk.sync(.{ .path = "wal.log" });
}
```

The test harness gets `DiskControl` from `world.simulate(...).control.disk` to
inspect disk state, inject scripted faults, or crash/restart the simulated
disk. Those operations must not leak into the app-visible disk API.

In multi-node simulations, get process-scoped app capabilities from
`sim.envForNode(node)`:

```zig
const node_env = try sim.envForNode(node);
try node_env.disk.write(.{ .path = "wal.log", .offset = offset, .bytes = entry });
```

The shared `World` remains the owner of the clock, PRNG, global event index,
and trace. The disk handle should not read wall-clock time, call host
randomness, or use host filesystem state as a simulator decision source.

The app-facing public type name should be `Disk`. Smaller terms like
`BlockDevice` are too narrow for a WAL/KV-store example, and broader terms
like `Storage` are too vague. Simulator-specific construction and control live
on `SimDisk` and `DiskControl`.

## Operation Model

Every disk operation should receive a deterministic operation id. The
simulator can then order pending work by:

1. `ready_at` simulated timestamp.
2. Operation id.

That ordering avoids pointer addresses, hash-map iteration order, and host
scheduling as tie breakers.

Implemented operation concepts:

- File identity: logical path-like names (`[]const u8`) scoped to the
  simulated disk. These are not host paths and must not read host filesystem
  state. File paths use non-empty `/`-separated components and reject `.`,
  `..`, empty components, backslashes, NUL, and host absolute/drive roots.
  `.` is reserved for the root logical directory in `syncDir`. Trace output
  writes paths through `recordFields` text escaping.
- Offset and length: integer byte ranges.
- Sector size: a configured simulation parameter, defaulting to 4096 bytes.
- Completed operation: result delivered to user code after deterministic
  synchronous latency.
- Runtime fault profile: `DiskFaultOptions` controls read errors, write
  errors, corrupt reads, lost pending writes, torn pending writes, and
  reordered pending writes with validated `BuggifyRate` values.
- Scripted sector corruption: harness code can mark one logical path/sector as
  corrupt with `corruptSector`.
- Pending writes: successful writes are visible to later reads immediately,
  but they are not durable until `sync`.
- Crash window: `crash` processes pending writes and metadata, marks the disk
  down, then kills every live logical process through the simulation process
  supervisor. Disk restart only brings the disk authority back up; application
  restart is modeled explicitly with `sim.restartProcess(node)` after a
  lifecycle initializer has been registered.

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

Initial faults are small and explicit:

- Latency: operation completes at a deterministic future timestamp.
- IO error: read/write returns a simulated disk error.
- Corruption: read returns bytes that differ from the durable model.
- Scripted corruption: a specific logical sector is marked corrupt by the
  harness.
- Torn write: a crash leaves only part of a write durable.
- Lost pending write: a crash drops an acknowledged-pending write before it
  becomes durable.

Later faults can include misdirected writes, stale reads, byte-level
corruption, reordered flushes, and more specific media behavior, but only after
the basic model is traceable and tested. Misdirected writes should be a named
fault type rather than being collapsed into generic corruption, because they
test whether user code validates record identity and location.

### Structural crash trigger

`control.disk.crashAfterOps(n)` arms a crash that fires at the operation
boundary after `n` more data/metadata operations complete: the first
operation past the budget crashes the disk before doing any work and fails
like any post-crash operation. This places a crash at a structural point of
the workload (the Nth write of a commit) instead of a measured tick offset,
the disk-side analog of the futex-handshake choreography the network
scenarios use. Arming is trace-visible as `disk.fault kind=armed_crash
after_ops=n`; re-arming replaces the budget, and any crash (armed or manual)
disarms it. A budget the workload never reaches simply never fires, which
harnesses can use as a self-bounding crash-point scan (see the xitdb
fuzzer).

## Recovery Windows

Fault injection needs budgets. A simulator that can corrupt every copy of
truth in one seed is not useful unless the test explicitly asked for a
destructive profile. This section defines the vocabulary Marionette's storage
examples and checkers use; enforcement deliberately stays in checkers until a
second storage example justifies a generic API.

**Durability boundary.** The operation after which the application may claim
data survives a crash: a successful `sync` for file bytes, a successful
`syncDir` for creates, deletes, and renames. Acknowledged writes that have not
crossed a boundary are pending. Directory-entry boundaries are parent-scoped:
creating `/kvc` requires syncing the root directory, and syncing `/kvc` only
persists entries under `/kvc`. For newly created files, sync the file first so
its create metadata is registered, then sync the parent directory before
treating the file entry as durable.

**Durable truth.** Everything behind a durability boundary at crash time.
The crash fault classes (`crash_lost_write`, `crash_torn_write`,
`crash_reordered_write`, `crash_lost_metadata`) apply only to pending writes
and pending metadata; no probabilistic crash profile, at any rate, may damage
durable truth. Damaging durable truth requires an explicitly destructive
fault: scripted `corruptSector` or a `corrupt_read_rate` profile.

**Recovery window.** The set of states a correct system may legally present
after crash and recovery, given where its durability boundaries were. Synced
data must recover exactly as written. Each pending write may be absent
(lost, or torn and rejected by recovery) or present exactly as written;
recovery accepting a damaged record is outside every window.

**Budget.** A bound on destructive faults per window. The conservative
single-node default is at most one destructive fault against durable truth
per recovery window, explicitly scoped (one sector, one path). Profiles that
exceed it are negative tests and should say so.

### Worked case: the KV example

`examples/kv_store.zig` is the reference shape:

- `put(committed_key, ..., .sync)` crosses a durability boundary: this
  record is durable truth for every scenario that follows.
- `put(volatile_key, ..., .no_sync)` stays pending: it defines the window's
  allowed damage.
- The probabilistic scenarios crash with `crash_lost_write_rate` and
  `crash_torn_write_rate` at 25% each, so the pending record's fate varies by
  seed while durable truth may not.
- The `recovered state is within the recovery window` checker encodes the
  window exactly: the committed record must recover with its exact value
  (`error.DurableTruthLost` otherwise); the volatile record may be absent or
  exact (`error.DamagedRecordAccepted` when recovery admits a mangled
  record).
- The deterministic `scenario` additionally spends a destructive budget of
  exactly one scripted `corruptSector` against a known sector after restart,
  which strict recovery must reject.

The planted `buggy_accept_magic_only` recovery validates the checker: it
accepts a torn record on magic alone, and the seed search in
`examples/root.zig` finds the resulting `DamagedRecordAccepted` within a
bounded seed range.

### Worked case: KV compatibility validation

`validation/kv_compat.zig` extends the same vocabulary to a compacting store:

- the WAL commit is durable truth only after `kv.wal.sync`;
- the compacted table contents are durable only after `kv.tab.tmp.sync`;
- the tmp-to-table rename is metadata and becomes durable only after syncing
  `/kvc`;
- WAL clear/delete is metadata and becomes durable only after the final
  `/kvc` sync.

Crashes before a directory sync may recover either file incarnation. The
checker therefore asserts convergence, not one physical layout: old table plus
WAL, new table plus old WAL, and new table plus empty WAL must all produce the
same durable key/value state. Recovery never reads `kv.tab.tmp`, so torn tmp
writes stay inside the recovery window instead of becoming durable truth.

Replicated windows (per-replica faults bounded so at least one quorum path
stays recoverable) remain future work tracked with the multi-replica fault
atlas.

## Trace Events

Disk traces are stable text events until the trace format changes globally.
Disk code must use `World.recordFields` so logical paths and status strings
are escaped consistently. Current events:

Disk fault rolls are explicitly operation-shaped. They are tied to the
operation id (or to an explicit crash) and do not participate in the
time-evolved `fault_evolution.boundary` contract used by network and process
dynamics.

- `disk.read op=<u64> path=<escaped-text> offset=<u64> len=<u64> status=<literal> latency_ns=<u64>`
- `disk.write op=<u64> path=<escaped-text> offset=<u64> len=<u64> status=<literal> latency_ns=<u64>`
- `disk.sync op=<u64> path=<escaped-text> status=<literal> committed_writes=<u64> latency_ns=<u64>`
- `disk.sync_dir op=<u64> path=<escaped-text> status=ok committed_metadata=<u64> latency_ns=<u64>`
- `disk.stat op=<u64> path=<escaped-text> status=<literal> size=<u64> latency_ns=<u64>`
- `disk.read_some op=<u64> path=<escaped-text> offset=<u64> requested_len=<u64> read_len=<u64> status=<literal> latency_ns=<u64>`
- `disk.set_length op=<u64> path=<escaped-text> len=<u64> status=<literal> committed_writes=<u64> latency_ns=<u64>`
- `disk.delete op=<u64> path=<escaped-text> status=<literal> committed_writes=<u64> latency_ns=<u64>`
- `disk.rename op=<u64> path=<escaped-text> new_path=<escaped-text> status=<literal> committed_writes=<u64> latency_ns=<u64>`
- `disk.fault op=<u64> path=<escaped-text> kind=<literal> rate=<literal> roll=<u64> fired=<bool>`
- `disk.fault path=<escaped-text> offset=<u64> kind=scripted_corruption`
- `disk.crash_write op=<u64> path=<escaped-text> offset=<u64> len=<u64> result=<literal>`
- `disk.crash_metadata op=<u64> dir=<escaped-text> kind=<literal> result=<literal>`
- `disk.crash pending_writes=<u64> landed=<u64> lost=<u64> torn=<u64> reordered=<u64> pending_metadata=<u64> metadata_kept=<u64> metadata_lost=<u64>`
- `disk.restart status=ok`

Use status values such as `ok`, `not_found`, `io_error`, and `corrupt`. Use
fault kinds such as `read_error`, `write_error`, `corrupt_read`,
`crash_lost_write`, `crash_torn_write`, `crash_reordered_write`, and
`crash_lost_metadata`.
`crash_lost_write`, `crash_torn_write`, and `crash_reordered_write`.

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

- Low-level disk type: `Disk`.
- Simulator implementation type: `SimDisk`.
- Harness-control type: `DiskControl`.
- Low-level access: `env.disk`; preferred storage app access is `env.io()`.
- File identity: logical path-like `[]const u8`, escaped in traces and never
  resolved against the host filesystem by the simulator.
- Default sector size: 4096 bytes.
- Default minimum latency: omitted means "match the world's tick duration";
  explicit values are preserved and validated against the tick size.
- Initial app operations: sector-oriented `read`, `write`, `sync`, and
  `syncDir` are implemented. Path-level `stat`, EOF-aware `readSome`,
  `setLength`, `delete`, and `rename` are also implemented as the first
  real-storage compatibility slice.
- Initial harness-control operations: `setFaults`, `corruptSector`, `crash`,
  and `restart` are implemented. Read/write IO errors, corrupt reads, scripted
  sector corruption, lost pending writes, torn pending writes, reordered
  pending writes, and lost unsynced directory metadata are implemented.
- Initial example: append-only WAL recovery.
- User data: store bytes in memory, trace lengths and outcomes by default.
- Checksums: user code owns them.
- Recoverability budgets: start with a conservative single-node default and
  explicit destructive mode; defer strong multi-replica budgets.
- Misdirected writes: document as a future named fault, not Phase 1 default.
- File lifecycle operations are intentionally narrow and operation-shaped, not
  a full `std.fs.File` clone. `setLength`, `delete`, and `rename` reject while
  crashed and commit pending writes for the affected path before mutating
  metadata. `syncDir` is the explicit durability boundary for creates, deletes,
  and renames; cross-directory renames require syncing both parent directories.

## Open Questions

- How closely should the production `Disk` adapter align with future `std.Io`
  file APIs?
- Should `sync` be per-file only, or should there also be a whole-disk sync?
- Should `syncDir` stay on `Disk`, or should Marionette eventually expose a
  standard `std.Io.Dir` bridge for directory fsync when Zig's API supports it?
- What is the smallest explicit API for declaring recovery windows?
- What is the first reusable shape for a VOPR-style fault atlas once
  Marionette has more than one storage example?
