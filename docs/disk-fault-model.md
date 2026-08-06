# Disk Fault Model

Marionette's simulated disk is an in-memory, deterministic fault model. It is
not an emulator for a particular filesystem or block device. Storage code
should normally use `std.Io` through `env.io()`; `mar.Disk` is the lower-level
capability underneath that backend.

## Portable v1

The current contract is `portable_v1`, numeric version `1`. Its constants are
`mar.disk_semantic_contract` and `mar.disk_semantic_version`. Each simulated
disk records a `disk.model` event containing the contract, version, sector
size, tear model, reorder model, and lifecycle policy.

The contract guarantees:

- A successful write is visible immediately but remains pending until the
  file is synced.
- A torn pending write lands a prefix of whole sectors, never a byte prefix.
- A successful reorder roll reverses all surviving pending writes for that
  crash; each is classified as `reordered`.
- Crash faults affect only pending writes and metadata. Unrelated durable
  state remains exact.
- `corruptSector` destructively changes existing logical media. A corrupt-read
  fault changes only the returned bytes.
- `setLength`, `delete`, and `rename` first commit pending writes for the
  affected source path, then perform the lifecycle change.
- Crash metadata is resolved newest to oldest. When rollback would collide
  with a later surviving create, the later entry wins.
- A crash and its trace/process notification are atomic. Allocation or trace
  failure restores the pre-crash media, liveness, random stream, and trace so
  the same crash can be retried exactly.

Lifecycle operations deliberately do not stand in for durability boundaries.
Only successful `sync` and `syncDir` calls support a portable crash-survival
claim.

## Capabilities

One `mar.SimDisk` provides two views over the same state:

- `mar.Disk` exposes reads, writes, sync, metadata, and file lifecycle
  operations to the application.
- `mar.DiskControl` lets the harness configure faults, corrupt sectors, and
  crash or restart the disk.

Application code should receive `env.io()` or, for direct model tests,
`env.disk`. Harness-only operations are available through
`world.simulate(...).control.disk`.

Logical file paths never address the host filesystem. They contain non-empty
`/`-separated components and reject `.`, `..`, empty components, backslashes,
NUL, and host absolute or drive roots. `.` names the logical root directory
for `syncDir`.

The `World` owns the clock, random stream, global event index, and trace. Disk
code must not use wall-clock time, host randomness, pointer identity, hash-map
iteration order, or host filesystem state as model inputs.

## Operations and ordering

Every operation receives a deterministic id. Ready operations are ordered by
`(ready_at, op_id)`. Operations are synchronous to application code: a call
may advance simulated time before returning.

Successful writes are pending and visible to later reads. File `sync` commits
pending bytes. `syncDir` commits creates, deletes, and renames for that logical
directory. A newly created file becomes durable by syncing the file and then
its parent directory. A cross-directory rename requires syncing both parents.

`setLength` extension is zero-filled by the disk authority. It is one
lifecycle operation, not a series of independently fallible sector writes.

## Faults

`DiskFaultOptions` configures deterministic rates for:

- read and write I/O errors;
- corrupt reads;
- lost pending writes;
- sector-prefix torn pending writes;
- reordered pending writes; and
- lost pending metadata.

The harness may also call `corruptSector` for an explicitly destructive,
path-and-sector-scoped fault.

`control.disk.crashAfterOps(n)` arms a structural crash. After `n` more data
or metadata operations complete, the next operation crashes the disk before
doing work and fails like any post-crash operation. Re-arming replaces the
budget; any crash disarms it. If the workload never reaches the boundary, the
crash never fires.

Crash marks the disk down and stops live logical processes. Disk restart only
restores the disk authority; applications restart explicitly through their
registered process lifecycle.

## Recovery windows

A durability boundary separates durable truth from pending state:

- file bytes cross the boundary at successful file `sync`;
- creates, deletes, and renames cross it at successful parent `syncDir`.

Synced data must recover exactly. A pending write may be absent or present
exactly as written; recovery accepting damaged data is never valid. Ordinary
crash profiles cannot damage durable truth. Doing that requires the explicit
`corruptSector` control or a corrupt-read profile.

The conservative single-node destructive-fault budget is one named sector on
one path per recovery window. Tests that exceed it are destructive negative
tests and should say so. Product-specific recovery checkers enforce these
budgets; the generic disk API does not interpret application record formats.

The KV example demonstrates the contract: a synced record must survive, while
an unsynced record may be absent or exact. Its checker rejects both loss of
durable truth and recovery of a damaged record.

## Trace contract

Disk code records escaped scalar fields through `World.recordFields`. It
records lengths and outcomes, not user payloads. The principal events are:

- `disk.model`
- `disk.read`, `disk.read_some`, and `disk.write`
- `disk.sync` and `disk.sync_dir`
- `disk.stat`, `disk.set_length`, `disk.delete`, and `disk.rename`
- `disk.fault`
- `disk.crash_write` and `disk.crash_metadata`
- `disk.crash` and `disk.restart`

Fault rolls are tied to an operation id or explicit crash. They are separate
from the time-evolved `fault_evolution.boundary` contract used by network and
process dynamics.

Status and fault names are stable literals such as `ok`, `not_found`,
`io_error`, `corrupt`, `read_error`, `crash_lost_write`, and
`crash_torn_write`. Payload hashes, if ever added for debugging, must name a
stable algorithm.

## Limits

The model does not provide full filesystem behavior, transparent interception
of direct host filesystem calls, or arbitrary random media chaos. Checksums,
record validation, and the definition of a valid recovered application state
belong to application code.
