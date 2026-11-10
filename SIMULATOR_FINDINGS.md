# Simulator Findings

This is the active Marionette defect backlog. Completed findings remain in Git
history and release notes rather than this file. Confirmed bugs in external
systems under test belong in `FOUND_BUGS.md`.

The September 4 audit's SIM-001 through SIM-004 are fixed on `feat/0.7.0`.
Their permanent regressions are in `tests/regressions_070.zig`; completed
findings and the additional self-review fixes are described in `CHANGELOG.md`.

## Open

No open findings target the default network model. The 0.9 network findings
(probes A to G in `tests/network_characterization.zig`: invented errors, close
and kill crossing partitions, loss killing a stream, one world-global stream
buffer pool, and one port namespace) are fixed under `semantics = .tcp_v1`,
with regressions in `tests/network_tcp.zig`. They remain the documented
behavior of `legacy_v0`. The 0.8.3 storage findings (rename committing
unsynced data and empty creation lost after a directory sync) are fixed by
`portable_v2`, with regressions in `tests/storage_083.zig`.

## Later Or Scope-Dependent

| Severity | Target | Finding | Primary location |
| --- | --- | --- | --- |
| Medium | 0.9/1.0 | Windows root compilation fails because real-disk inode and simulated file/network handles assume Unix integer representations. Harden or explicitly narrow supported targets. | `src/disk/real.zig`, `src/io/backend.zig`, `src/io/file.zig`, `src/io/net.zig` |

## Standing Model Decisions

- Under `legacy_v0`, the stream backpressure wake key is world-global because
  the byte pool is world-global. `tcp_v1` sockets have their own buffers.
- `portable_v1`, through 0.8.2, committed pending writes at `setLength`,
  delete, and rename. `portable_v2` keeps that data pending on the file's
  identity; older artifacts retain their pinned-build interpretation and are
  rejected by later builds.
- Default crash fault rates are zero, so a default disk crash preserves pending
  writes and metadata while stopping processes. This is a deliberate clean
  crash case. Durability checks name a `CrashProfile` and can require effects
  rather than relying on configured rates.
- The harness main context is a scheduler driver, not a normal application
  task.
- Seed schedules are positional same-build exploration controls. Persisted
  capsules own durable replay for pinned builds/workloads, not cross-version
  migration. Killed watchdog workers have incomplete tapes.
- Protocol/runtime expansion is SUT-driven and is not a bug backlog.

Add a row when a suspected simulator defect has a concrete reproduction and
location. Remove it when the fixing change and regression test land.
