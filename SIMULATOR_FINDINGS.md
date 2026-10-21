# Simulator Findings

This is the active Marionette defect backlog. Completed findings remain in Git
history and release notes rather than this file. Confirmed bugs in external
systems under test belong in `FOUND_BUGS.md`.

The September 4 audit's SIM-001 through SIM-004 are fixed on `feat/0.7.0`.
Their permanent regressions are in `tests/regressions_070.zig`; completed
findings and the additional self-review fixes are described in `CHANGELOG.md`.

## Open

Probe letters refer to the network characterization probes planned for 0.8.1;
those findings were reproduced on v0.7.2 with Zig 0.16 and must be rerun on
Zig 0.17.

| Severity | Target | Finding | Primary location |
| --- | --- | --- | --- |
| Medium | 0.8.1 | One world-global pool of 64 stream buffers couples connections: a reader that never reads makes an unrelated connect fail with `SystemResources` (probe G). | `src/message_pool.zig`, `src/io/net.zig` |
| High | 0.9 | Network faults become immediate errors, and close and kill reach peers through shared state even across a partition: connect into a partition fails in 0 ms despite a 10 s timeout, a reply sent during a partition becomes `Timeout` 1 ms later, and 1% loss kills a stream (probes A to E). | `src/io/net.zig` (`simNetConnectIp`, `drainNetworkReady`), `src/io/backend.zig` (`closeConnectionState`) |
| Medium | 0.9 | One port namespace for the whole world: only one node can bind `0.0.0.0:7000`, any node can bind any IP, and accepted peers report the destination IP (probe F). | `src/io/backend.zig` (`ProcessRegistry`), `src/io/net.zig` (`simNetLookup`) |

## Later Or Scope-Dependent

| Severity | Target | Finding | Primary location |
| --- | --- | --- | --- |
| Medium | 0.9/1.0 | Windows root compilation fails because real-disk inode and simulated file/network handles assume Unix integer representations. Harden or explicitly narrow supported targets. | `src/disk/real.zig`, `src/io/backend.zig`, `src/io/file.zig`, `src/io/net.zig` |

## Standing Model Decisions

- The stream backpressure wake key is world-global because the byte pool is
  world-global. Extra wakeups are a performance tradeoff; the pool's coupling of
  unrelated connections is an open finding above.
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
