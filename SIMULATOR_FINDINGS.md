# Simulator Findings

This is the active Marionette defect backlog. Completed findings remain in Git
history and release notes rather than this file. Confirmed bugs in external
systems under test belong in `FOUND_BUGS.md`.

The September 4 audit's SIM-001 through SIM-004 are fixed on `feat/0.7.0`.
Their permanent regressions are in `tests/regressions_070.zig`; completed
findings and the additional self-review fixes are described in `CHANGELOG.md`.

## Later Or Scope-Dependent

| Severity | Target | Finding | Primary location |
| --- | --- | --- | --- |
| Medium | 0.9/1.0 | Windows root compilation fails because real-disk inode and simulated file/network handles assume Unix integer representations. Harden or explicitly narrow supported targets. | `src/disk/real.zig`, `src/io/backend.zig`, `src/io/file.zig`, `src/io/net.zig` |

## Standing Model Decisions

- The stream backpressure wake key is world-global because the byte pool is
  world-global. Extra wakeups are a performance tradeoff.
- `setLength`, delete, and rename committing pending writes is the named
  `portable_v1` disk contract.
- The harness main context is a scheduler driver, not a normal application
  task.
- Seed schedules are positional same-build exploration controls. Persisted
  capsules own durable replay for pinned builds/workloads, not cross-version
  migration. Killed watchdog workers have incomplete tapes.
- Protocol/runtime expansion is SUT-driven and is not a bug backlog.

Add a row when a suspected simulator defect has a concrete reproduction and
location. Remove it when the fixing change and regression test land.
