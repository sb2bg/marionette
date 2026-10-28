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

Code that uses `std.Io` syncs a directory the way it would on POSIX: open the
directory as a file and sync it.

```zig
var directory = try std.Io.Dir.cwd().openFile(io, ".", .{ .allow_directory = true });
defer directory.close(io);
try directory.sync(io); // the simulated backend runs `syncDir` for it
```

So durable application code needs only `std.Io`, not the `Disk` capability.

`Disk.deleteDir` and `Dir.deleteDir` remove an empty directory; the removal is
pending until its parent is synced, like a file delete. Because a directory is
removed only once empty, a removal that becomes durable, by a parent sync or by
surviving a crash, makes the changes that emptied it durable too: a crash never
restores a file into a directory it keeps removed, or moves one back into it.
Changes made after the removal, in a directory recreated at the same path, still
need that directory's own sync.

A handle names the directory it opened, not its path. Once that directory is
removed, nothing resolves by name through the handle (`FileNotFound`), it lists
no entries, and setting its permissions or times, or syncing it, succeeds
without touching a directory recreated at the same path, as on a host.

Files and directories carry a modification and an access time. Writes and
length changes move the modification time; reads do not move the access time,
as on a `noatime` mount. `File.setTimestamps`, `Dir.setTimestamps`, and
`Disk.setTimes` set either time without making pending writes durable: a set
time overrides earlier writes, and later writes move the modification time
again. Timestamps survive a crash, as they do on a real machine, even when the
data that set them is lost. Times before the Unix epoch return `Unexpected`.
Permissions follow the same rules: `File.setPermissions`,
`Dir.setFilePermissions`, the `permissions` given when creating a file or
directory, and `Disk.setMode` set the mode `stat` reports. Modes are recorded,
not enforced.

`setLength` extension is zero-filled by the disk authority. It is one
lifecycle operation, not a series of independently fallible sector writes.
Extension allocates like a write, so under `capacity_bytes` it fails with
`NoSpaceLeft`; `File.setLength` reports that as `FileTooBig`.

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
crash never fires; `control.disk.disarmCrash()` cancels it and reports whether
one was pending. A firing armed crash records
`disk.fault kind=armed_crash fired=true` before its `disk.crash`, and a
cancelled one records `disk.fault kind=armed_crash disarmed=true`.

Crash marks the disk down and stops live logical processes. Disk restart only
restores the disk authority; applications restart explicitly through
`control.process.restart`, which reruns a registered lifecycle or, without one,
revives the node's I/O.

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

## `std.Io` file operations

Simulated `std.Io` supports:

- creating, opening, and closing files; positional and streaming reads and
  writes; seeking; length changes; and `sync`;
- `stat` with size, modification and access times, and permissions, and setting
  times and permissions;
- open-time locks and `lock`, `tryLock`, `unlock`, and `downgradeLock`;
- `deleteFile`, `rename`, `renamePreserve`, and `createFileAtomic` with
  `File.Atomic.replace` and `link`;
- `createDir`, `createDirPath`, `openDir`, iteration, `deleteDir`,
  `deleteTree`, and directory sync through a directory opened with
  `allow_directory`.

Operations the model does not provide fail as a host without the feature
would, never with a misleading `FileNotFound`:

| Operation | Result |
| --- | --- |
| Creating a symbolic link | `PermissionDenied`, as on a filesystem without them |
| `readLink` | `NotLink` for an existing path, `FileNotFound` otherwise |
| Hard links, `realPath` | `OperationUnsupported` |
| Changing ownership | `PermissionDenied`; `stat` reports no owner |
| Memory maps | `AccessDenied` |
| Zero-copy file-to-file and file-to-socket transfer | `Unimplemented`, so the standard writer falls back to reading and writing |

Permissions are recorded, not enforced, and every node shares one disk. Names
are case-sensitive byte strings with no Unicode normalization.

## Limits

The model does not provide full filesystem behavior, transparent interception
of direct host filesystem calls, or arbitrary random media chaos. Checksums,
record validation, and the definition of a valid recovered application state
belong to application code.
