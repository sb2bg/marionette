# Marionette Simulator Findings

This document is the item-level ledger for audit findings and fix work in
Marionette itself. The roadmap groups this work into releases; this file
preserves each finding until it is fixed, deferred with an explicit reason, or
rejected after a reproduction shows the report was wrong.

This is not a count of 44 confirmed bugs. It currently contains 39 code-defect
candidates from source audit, one unresolved model decision, one documentation
task, and three capability gaps. A candidate is treated as reproduced only
after targeted reproduction or regression coverage exists.

Findings in external systems under test belong in
[`FOUND_BUGS.md`](FOUND_BUGS.md), not here.

## Status And Severity

- **Open:** not fixed; may still require targeted reproduction.
- **Fixed:** landed with a regression; record the commit or PR in the status.
- **Deferred:** accepted but moved out of its target release with a reason.
- **Rejected:** demonstrated not to violate the declared contract; preserve the
  reason so the same report is not repeatedly rediscovered.

Severities are release-oriented:

- **High:** model soundness, memory safety, silent false confidence, or a major
  public contract violation. Blocks its target release.
- **Medium:** real correctness, lifecycle, portability, or failure-path bug
  without the same immediate release risk.
- **Low:** bounded correctness/UX defect or deliberately low-risk edge case.

Unless a row explicitly describes a model decision, documentation task, or
capability gap, it is a code-defect candidate from source audit. Open does not
mean reproduced; the fixing work must add the targeted regression that proves
the failure and prevents recurrence.

## 0.6.0 - Simulator TCB Closure

| Severity | Status | Finding | Primary location |
| --- | --- | --- | --- |
| High | Open | `runSimCase` drops allocation faults, task stack size, task-start jitter, and fiber diagnostics instead of forwarding all `World.SimulateOptions`. | `simulateOptionsFromConfig` in `src/run.zig` |
| High | Open | Connection teardown wakes world-global backpressure waiters but leaves dead-target frames owning the shared path queues and byte pool, which can deadlock unrelated later traffic. | `Backend.closeConnectionState` in `src/io/backend.zig`; `SimByteRuntime` queues in `src/network/sim.zig` |
| High | Open | Network enqueue publishes a pooled message before fallible trace recording; trace OOM can release a message still referenced by a queue. Dequeue has the inverse leaked-slot failure. | `SimByteRuntime.sendMessageAtOrAfter` and `popReadyEventFor` in `src/network/sim.zig` |
| High | Open | File operations retain pointers into the reallocating `Backend.files` list across suspending disk calls, allowing another task to invalidate the pointer before resume. | `Backend.files` in `src/io/backend.zig`; read/write/set-length helpers in `src/io/file.zig` |
| High | Open | Scheduler-driven clock jumps call `World.runFor` directly and bypass automatic process/network fault-evolution boundaries. | timer advancement in `src/scheduler.zig`; `SimControl.runFor` in `src/env.zig` |
| High | Open | A failing process restart callback can leave tasks, handles, or other resources from a partial incarnation alive while the supervisor remains killed. | `ProcessSupervisor.restartProcessInternal` in `src/world.zig` |
| High | Open | A saved node-scoped `Env`/`Io` capability remains usable while its process is killed and can spawn tasks or open resources before restart. | process state in `src/world.zig`; task creation in `src/io/backend.zig` |
| High | Open | Manual process restart preserves non-stale per-backend file metadata, hiding disk changes made by another node while the process was down. | cache invalidation in `src/io/backend.zig`; refresh path in `src/io/file.zig` |
| High | Open | Async/group context and result storage is hard-capped at 16-byte alignment; valid over-aligned values trap in checked builds and can become misaligned UB in ReleaseFast. | closure storage and creation in `src/io/backend.zig` |
| High | Open | Lexical path validation does not stop host filesystem operations from following symlinked components outside the configured `RealDisk` root. | root-relative operations in `src/disk/real.zig` |
| Medium | Open | Full-range task-start jitter avoids `maxInt + 1` at spawn but can overflow when the task computes or tick-rounds its actual deadline. | `TaskScheduler.spawn` and `Task.run` in `src/scheduler.zig` |
| Medium | Open | `Env.clock.sleep` promises tick rounding but forwards an unaligned duration directly, asserting in checked builds and moving time off-grid in ReleaseFast. | `worldClockSleep` in `src/env.zig` |
| Medium | Open | Near the timestamp ceiling, scheduling an irrelevant future automatic process transition can return `InvalidDuration` even when the requested run ends earlier. | process transition scheduling in `src/world.zig` |
| Medium | Open | `transitionToLiveness` consumes its one-shot flag before fallible tracing, control updates, disk restart, and lifecycle callbacks complete. | `Simulation.transitionToLiveness` in `src/world.zig` |
| Medium | Open | Process kill marks async closures done and retires tasks but leaves closures and never-started opaque adapters allocated until world teardown. | kill cleanup in `src/io/backend.zig` and `src/scheduler.zig` |
| Medium | Open | Extreme configured stack sizes overflow guard/usable-length arithmetic; ReleaseFast can map an undersized region and place state outside the usable stack. | `Fiber.create` in `src/fiber.zig` |
| Medium | Open | Runner traces are copied before app/state teardown, so teardown events and simulated allocator frees are excluded from twice-and-compare. | run-once teardown ordering in `src/run.zig` |
| Medium | Open | `World.simulate` allocation failure is converted into `scenario_error`, contradicting the runner's setup-allocation error contract. | simulation setup in `src/run.zig` |
| Medium | Open | App state returned as `*App` is accepted but never deinitialized because `appHasDeinit` only recognizes container types. | app lifecycle detection in `src/run.zig` |
| Medium | Open | Trace-summary replacement frees an old name before allocating the replacement, and duplicate-inside-append paths can leak or double-free on OOM. | summary parsing and counters in `src/trace_summary.zig` |
| Medium | Open | The exported tidy build helper resolves `src/main_tidy.zig` relative to the consuming package instead of Marionette. | `src/build_support.zig` |
| Low | Open | A fuzz campaign with `seeds = 0` passes without initializing or executing the scenario once. | `expectSimFuzz` loop in `src/run.zig` |

## 0.6.1 - Truthful std.Io.net Contracts

| Severity | Status | Finding | Primary location |
| --- | --- | --- | --- |
| High | Open | A segmented write can queue a prefix and then return cancellation/reset/allocation error without reporting partial progress, so retrying the original buffer duplicates bytes. | `simNetWrite` in `src/io/net.zig` |
| High | Open | A dropped stream segment sets `read_error` but later segments are still appended and returned, exposing a continuing stream with an interior byte hole. | delivery drain and segmented send in `src/io/net.zig` |
| High | Open | Connect establishment bypasses link/node state, latency, timeout, and the simulated network path, so connect can succeed immediately across a partition. | `simNetConnectIp` in `src/io/net.zig` |
| High | Open | Listen silently ignores backlog/reuse semantics and returns port `0` unchanged instead of assigning a deterministic ephemeral port or failing unsupported options. | `simNetListenIp` in `src/io/net.zig` |
| Medium | Open | Direct `ByteEndpoint.receive` frees the same shared queue/pool capacity used by stream writes but does not wake world-global backpressure waiters. | `SimByteRuntime.receive` in `src/network/sim.zig` |
| Medium | Open | Listen, connect, and shutdown expose cancelable standard error sets but do not consume an armed cancellation request. | immediate net operations in `src/io/net.zig` |
| Medium | Open | Network latency jitter can overflow both the inclusive draw bound and the addition of minimum latency plus jitter. | latency helpers in `src/network/sim.zig` and `src/network/packet_core.zig` |
| Medium | Open | Shutdown ignores `.recv`, `.send`, and `.both`, fully closes every handle, and succeeds for unknown/already-closed handles. | `simNetShutdown` in `src/io/net.zig` |
| Medium | Open | Accepted sockets expose the listener's local address rather than the connecting peer's remote address; client ephemeral identity is not represented. | connection construction and `simNetAccept` in `src/io/net.zig` |
| Medium | Open | Production byte-endpoint configuration is silently first-call-wins; later endpoint options are ignored and the socket path cannot handle multiple inbound peers or reconnects. Remove the candidate API or fix it while it remains exported. | byte runtime registry in `src/network/production.zig` |
| Medium | Open | README/API stability and production-endpoint language still obscures the standing endpoints-are-sim-only decision and removal status of production endpoint remnants. | `README.md`, `docs/api.md`, `docs/network-api.md` |

## 0.6.2 - Disk Semantics v1

| Severity | Status | Finding | Primary location |
| --- | --- | --- | --- |
| High | Open | Disk crash sets durable/crashed state before the final trace and only notifies process observers afterward; trace OOM can leave a crashed disk with live pre-crash process state. | `SimDisk.crash` in `src/disk/sim.zig` |
| High | Open | Torn writes land half the pending bytes even though the public contract says a prefix of whole sectors lands. | `applyTornWrite` in `src/disk/sim.zig`; `DiskFaultOptions` in `src/disk/model.zig` |
| High | Open | One successful per-write reorder roll reverses the entire surviving landing list while only selected entries are traced as reordered; option, trace, and implementation semantics disagree. | crash landing loop in `src/disk/sim.zig` |
| Medium | Open | Failed multi-sector `setLength` extension can leave disk-visible zero writes beyond the still-cached old length. | `simFileSetLength` and `zeroDiskBytes` in `src/io/file.zig` |
| Medium | Open | `corruptSector` uses get-or-create lookup and can materialize a missing logical file instead of rejecting a nonexistent target. | `SimDisk.corruptSector` in `src/disk/sim.zig` |

## 0.6.3 - Expected-Failure Containment

| Severity | Status | Finding | Primary location |
| --- | --- | --- | --- |
| High | Open | A task canceled while blocked in `Group.await` remains on a noncancelable park, does not cancel members, and can deterministically deadlock its outer future. | group await in `src/io/backend.zig`; task blocking in `src/scheduler.zig` |
| Medium | Open | Main-context future waits convert deterministic deadlock and scheduler errors into panic, which can abort before the runner preserves a structured failure artifact. | task runtime await bridge in `src/scheduler.zig` |
| Medium | Open | Disk-latency and file-lock waits expose cancelable operations but do not consistently park through the cancelable scheduler path. | disk latency runtime and file-lock waits in `src/scheduler.zig` and `src/io/backend.zig` |
| Medium | Open | A non-yielding SUT loop freezes the cooperative world before in-process deadlock/livelock detection can run; no worker watchdog preserves a partial artifact. | runner/worker boundary; demonstrated by the dusty shutdown-drain bug |

## Later Or Scope-Dependent

| Severity | Target | Status | Finding | Primary location |
| --- | --- | --- | --- |
| Medium | 0.9/1.0 | Open | Full Windows root compilation fails because RealDisk inode and simulated file/network handle code assumes Unix integer representations. Either harden it or explicitly narrow supported targets. | `src/disk/real.zig`, `src/io/backend.zig`, `src/io/file.zig`, `src/io/net.zig` |
| Low | 0.7 | Open | Fixed CLI summary buffers return `NoSpaceLeft` for otherwise valid reports with enough tags, attributes, or network-link summaries. | `src/main_run.zig` |

## Explicit Non-Bugs And Model Decisions

These reports were reviewed but should not re-enter the bug queue without new
evidence:

- The world-global stream backpressure wake key intentionally wakes unrelated
  writers because the byte pool itself is world-global. Extra wakeups are a
  performance tradeoff, not a correctness defect.
- `setLength`, delete, and rename committing pending writes is the current
  documented Phase 1 disk contract. 0.6.2 may replace or name that contract,
  but its present existence is not an undocumented implementation bug.
- The harness main context is intentionally a scheduler driver rather than a
  normal application task. A scheduled root task is a possible exploration
  design, not a current contract violation.
- One call-order-sensitive PRNG stream is a replay-durability limitation, not a
  determinism failure. The 0.7 decision tape and later generation policy own
  that work.
- Broad protocol/runtime expansion remains SUT-driven and is not a bug backlog.

## Maintenance Rules

- Every fixing PR updates the corresponding row's status and adds the landed
  commit/PR plus the regression-test name.
- Do not delete fixed or rejected rows; this ledger is the audit trail.
- If one root cause closes several rows, update every affected row and link the
  shared fix.
- New audit findings receive their own row and classification here before being
  added to a release's roadmap scope.
