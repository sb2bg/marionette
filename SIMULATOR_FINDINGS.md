# Simulator Findings

This is the active Marionette defect backlog. Completed findings remain in Git
history and release notes rather than this file. Confirmed bugs in external
systems under test belong in `FOUND_BUGS.md`.

## Open For 0.6.3

| Severity | Finding | Primary location |
| --- | --- | --- |
| Medium | Main-context future waits convert deterministic deadlock and scheduler errors into panic before the runner can preserve a structured artifact. | task runtime await bridge in `src/scheduler.zig` |
| Medium | Disk-latency and file-lock waits expose cancelable operations but do not consistently park through the cancelable scheduler path. | `src/scheduler.zig`, `src/io/backend.zig` |
| Medium | A non-yielding SUT loop freezes the cooperative world before in-process detection can run; no worker watchdog preserves a partial artifact. | runner/worker boundary |
| Medium | `expectSimFailure` accepts any replayable failure, so unrelated setup/scenario failures can satisfy a planted-bug test. | expectation helpers in `src/run.zig` |

## Later Or Scope-Dependent

| Severity | Target | Finding | Primary location |
| --- | --- | --- | --- |
| Medium | 0.9/1.0 | Windows root compilation fails because real-disk inode and simulated file/network handles assume Unix integer representations. Harden or explicitly narrow supported targets. | `src/disk/real.zig`, `src/io/backend.zig`, `src/io/file.zig`, `src/io/net.zig` |
| Low | 0.7 | Fixed CLI summary buffers can return `NoSpaceLeft` for otherwise valid reports with enough metadata or network links. | `src/main_run.zig` |

## Standing Model Decisions

- The stream backpressure wake key is world-global because the byte pool is
  world-global. Extra wakeups are a performance tradeoff.
- `setLength`, delete, and rename committing pending writes is the named
  `portable_v1` disk contract.
- The harness main context is a scheduler driver, not a normal application
  task.
- One call-order-sensitive PRNG stream is a replay-durability limitation, not a
  same-build determinism failure. The 0.7 decision tape owns that work.
- Protocol/runtime expansion is SUT-driven and is not a bug backlog.

Add a row when a suspected simulator defect has a concrete reproduction and
location. Remove it when the fixing change and regression test land.
