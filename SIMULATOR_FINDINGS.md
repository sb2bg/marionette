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
| High | Fixed (`5618127`; `runSimCase: forwards every simulate option`) | `runSimCase` drops allocation faults, task stack size, task-start jitter, and fiber diagnostics instead of forwarding all `World.SimulateOptions`. | `simulateOptionsFromConfig` in `src/run.zig` |
| High | Fixed (`6b8fab5`; `io: closing a connection reclaims its queued stream frames`) | Connection teardown wakes world-global backpressure waiters but leaves dead-target frames owning the shared path queues and byte pool, which can deadlock unrelated later traffic. | `Backend.closeConnectionState` in `src/io/backend.zig`; `SimByteRuntime` queues in `src/network/sim.zig` |
| High | Fixed (`e2acf14`; `composition byte endpoint: trace allocation failures preserve message ownership`) | Network enqueue publishes a pooled message before fallible trace recording; trace OOM can release a message still referenced by a queue. Dequeue has the inverse leaked-slot failure. | `SimByteRuntime.sendMessageAtOrAfter` and `popReadyEventFor` in `src/network/sim.zig` |
| High | Fixed (`1ae592a`, `9f0df97`; `std.Io.net retries ready delivery after inbox allocation failure`) | Stream delivery removes a ready network frame before reserving the target inbox and publishing the fallible `io.net.deliver` trace. Inbox or trace OOM can therefore lose the already-dequeued bytes. | `Backend.drainNetworkReady` in `src/io/net.zig`; stream receive API in `src/network/sim.zig` |
| High | Fixed (`92c22c4`; `io: file metadata stays stable across table growth during disk latency`) | File operations retain pointers into the reallocating `Backend.files` list across suspending disk calls, allowing another task to invalidate the pointer before resume. | `Backend.files` in `src/io/backend.zig`; read/write/set-length helpers in `src/io/file.zig` |
| High | Fixed (`6c7e37e`, `e5cfa20`; `io: scheduler timer jumps evolve process and network faults`) | Scheduler-driven clock jumps call `World.runFor` directly and bypass automatic process/network fault-evolution boundaries. | timer advancement in `src/scheduler.zig`; `SimControl.runFor` in `src/env.zig` |
| High | Fixed (`634630c`; `io: failed restart rolls back partial process resources`) | A failing process restart callback can leave tasks, handles, or other resources from a partial incarnation alive while the supervisor remains killed. | `ProcessSupervisor.restartProcessInternal` in `src/world.zig` |
| High | Fixed (`634630c`, `d34196d`; `io: killed processes reject saved node capabilities until restart`) | A saved node-scoped `Env`/`Io` capability remains usable while its process is killed and can spawn tasks or open resources before restart. | process state in `src/world.zig`; task creation in `src/io/backend.zig` |
| High | Fixed (`634630c`; `io: manual restart invalidates process-local file metadata`) | Manual process restart preserves non-stale per-backend file metadata, hiding disk changes made by another node while the process was down. | cache invalidation in `src/io/backend.zig`; refresh path in `src/io/file.zig` |
| High | Fixed (`d46152a`; `io: async preserves over-aligned context and result storage`) | Async/group context and result storage is hard-capped at 16-byte alignment; valid over-aligned values trap in checked builds and can become misaligned UB in ReleaseFast. | closure storage and creation in `src/io/backend.zig` |
| High | Fixed (`684890a`; `disk: real disk rejects symlink escapes`) | Lexical path validation does not stop host filesystem operations from following symlinked components outside the configured `RealDisk` root. | root-relative operations in `src/disk/real.zig` |
| Medium | Fixed (`df0360f`; `TaskScheduler: maximum task start jitter draws and schedules without overflow`) | Full-range task-start jitter avoids `maxInt + 1` at spawn but can overflow when the task computes or tick-rounds its actual deadline. | `TaskScheduler.spawn` and `Task.run` in `src/scheduler.zig` |
| Medium | Fixed (`873de1e`; `env: simulation clock sleep rounds up to tick resolution`) | `Env.clock.sleep` promises tick rounding but forwards an unaligned duration directly, asserting in checked builds and moving time off-grid in ReleaseFast. | `worldClockSleep` in `src/env.zig` |
| Medium | Fixed | Direct `Env.clock.sleep` mutates the low-level world clock, skipping runnable tasks and automatic process/network fault boundaries that an equivalent app-facing `std.Io` sleep observes. Simulated environment clocks now use their node-scoped I/O scheduler; `World.clock()` remains the documented raw authority. | environment clock construction in `src/world.zig` |
| Medium | Fixed (`51e86db`; `io: process transition beyond clock range does not fail an earlier run`) | Near the timestamp ceiling, scheduling an irrelevant future automatic process transition can return `InvalidDuration` even when the requested run ends earlier. | process transition scheduling in `src/world.zig` |
| Medium | Fixed (`7285aa8`; near-clock-ceiling automatic network regressions) | Automatic network clog and partition schedules return `InvalidDuration` when the sampled transition or clog end lies beyond the clock range, even when the requested run ends earlier. | automatic schedules in `src/network/sim.zig` |
| Medium | Fixed (`36ff90d`; `io: transitionToLiveness remains retryable after lifecycle failure`) | `transitionToLiveness` consumes its one-shot flag before fallible tracing, control updates, disk restart, and lifecycle callbacks complete. | `Simulation.transitionToLiveness` in `src/world.zig` |
| Medium | Fixed | Process kill marks async closures done and retires tasks but leaves closures and never-started opaque adapters allocated until world teardown. Task execution state now retires with the killed scheduler task while the smaller future result record remains valid until `await`/`cancel`. | kill cleanup in `src/io/backend.zig` and `src/scheduler.zig` |
| Medium | Fixed (`d618b73`; `io: killing a Group.await task releases group state`) | Killing a task suspended in `Group.await` retires member closures but leaves its `GroupState` holding a pointer into the destroyed fiber stack until world teardown. | group kill cleanup in `src/io/backend.zig` |
| Medium | Fixed (`6bb2b25`, `ead37c5`; `io: process kill aborts main-context pathname waits`) | The pathname gate retires task-owned waiters on process kill but originally left a main-context waiter driving the scheduler behind another process's reservation after its own capability became stale. The abort path transfers waiter ownership on registration so allocator-clean builds cannot free it twice. | pathname-gate kill cleanup in `src/io/backend.zig` |
| Medium | Fixed (`abb85e8`; `fiber: rejects stack sizes whose guarded mapping length overflows`) | Extreme configured stack sizes overflow guard/usable-length arithmetic; ReleaseFast can map an undersized region and place state outside the usable stack. | `Fiber.create` in `src/fiber.zig` |
| Medium | Fixed (`f1841c1`; `runSimCase: includes app teardown in replay comparison`) | Runner traces are copied before app/state teardown, so teardown events and simulated allocator frees are excluded from twice-and-compare. | run-once teardown ordering in `src/run.zig` |
| Medium | Fixed (`39bf071`; `runSimCase: simulation setup allocation errors remain runner errors`) | `World.simulate` allocation failure is converted into `scenario_error`, contradicting the runner's setup-allocation error contract. | simulation setup in `src/run.zig` |
| Medium | Fixed (`589c931`; `runSimCase: deinitializes pointer-valued apps after each replay`) | App state returned as `*App` is accepted but never deinitialized because `appHasDeinit` only recognizes container types. | app lifecycle detection in `src/run.zig` |
| Medium | Fixed (`d7376c1`; `trace summary: allocation failures roll back owned fields`) | Trace-summary replacement frees an old name before allocating the replacement, and duplicate-inside-append paths can leak or double-free on OOM. | summary parsing and counters in `src/trace_summary.zig` |
| Medium | Fixed | The exported tidy build helper resolves `src/main_tidy.zig` relative to the consuming package instead of Marionette. The public build API now locates its own dependency and constructs a dependency-owned source path, covered by a nested consumer build. | `build.zig`; `src/build_support.zig` |
| Low | Fixed (`53c5720`; `expectSimFuzz rejects zero-run campaigns`) | A fuzz campaign with `seeds = 0` passes without initializing or executing the scenario once. | `expectSimFuzz` loop in `src/run.zig` |
| Medium | Fixed (`8b8a83f`; `world: trace allocation failure rolls back random draws` and clock movement) | Traced world random draws and clock movement mutate state before fallible trace publication, so retry after trace OOM consumes a different choice or advances time twice. | traced random/time methods in `src/world.zig` |
| Low | Fixed (`6eb2a9c`; `runSimCase: accepts an infallible scenario`) | `runSimCase` validation accepts `fn (*SimCase) void`, but the internal runner previously required `anyerror!void`, so valid infallible scenarios failed to compile. | scenario adaptation in `src/run.zig` |
| High | Fixed (`f875bcd`, `3f8a995`; suspended lifetime, rename serialization, and delete serialization regressions) | Concurrent delete/rename can retire `FileState` or replace/free a metadata path while a streaming operation is suspended. A copied path prevents use-after-free but can still direct later sectors to the obsolete pathname, so pathname mutations must also serialize with in-flight I/O and queued handle operations must revalidate the current metadata path. | file-handle retirement and pathname gate in `src/io/backend.zig`; suspended helpers in `src/io/file.zig` |

## 0.6.1 - Truthful std.Io.net Contracts

| Severity | Status | Finding | Primary location |
| --- | --- | --- | --- |
| High | Fixed (`io: peer close wakes a writer parked on stream backpressure`; `io: process kill wakes a writer parked on stream backpressure`) | A segmented write can queue a prefix and then return cancellation/reset/allocation error without reporting partial progress, so retrying the original buffer duplicates bytes. | `simNetWrite` in `src/io/net.zig` |
| High | Fixed (`TaskScheduler: std.Io.net partition loss terminates the reliable stream`) | A dropped stream segment sets `read_error` but later segments are still appended and returned, exposing a continuing stream with an interior byte hole. Loss now terminally fails the receive stream and retires queued suffix frames. | delivery drain and segmented send in `src/io/net.zig` |
| High | Open (node/link state fixed by `io: connect observes node and link availability`; non-default timeout now returns `OptionUnsupported`) | Connect establishment bypasses link/node state, latency, timeout, and the simulated network path, so connect can succeed immediately across a partition. The remaining gap is queued establishment latency and timeout. | `simNetConnectIp` in `src/io/net.zig` |
| High | Fixed (port `0` by `086a57c`; `io: listener backlog refuses excess pending connections`; reuse returns `OptionUnsupported`) | Listen silently ignores backlog and reuse semantics instead of implementing or rejecting them. | `simNetListenIp` in `src/io/net.zig` |
| Medium | Fixed by removal | Direct `ByteEndpoint.receive` freed the same shared queue/pool capacity used by stream writes without waking world-global backpressure waiters. The public byte-endpoint facade was removed; the surviving `std.Io.net` drain path wakes backpressured writers whenever it releases a frame. | removed `ByteEndpoint`; stream delivery in `src/io/net.zig` |
| Medium | Fixed (`io: armed cancellation reaches immediate net operations`) | Listen, connect, and shutdown expose cancelable standard error sets but do not consume an armed cancellation request. | immediate net operations in `src/io/net.zig` |
| Medium | Fixed (`4eb4337`; `network: full-range latency jitter does not overflow its draw bound`) | Network latency jitter can overflow both the inclusive draw bound and the addition of minimum latency plus jitter. | latency helpers in `src/network/sim.zig` and `src/network/packet_core.zig` |
| Medium | Fixed (`io: directional stream shutdown preserves the opposite direction`) | Shutdown ignores `.recv`, `.send`, and `.both`, fully closes every handle, and succeeds for unknown/already-closed handles. | `simNetShutdown` in `src/io/net.zig` |
| Medium | Fixed (`io: accept returns the connecting peer address`) | Accepted sockets expose the listener's local address rather than the connecting peer's remote address; client ephemeral identity is not represented. | connection construction and `simNetAccept` in `src/io/net.zig` |
| Medium | Fixed by removal (`72e94d2`) | Production byte-endpoint configuration is silently first-call-wins; later endpoint options are ignored and the socket path cannot handle multiple inbound peers or reconnects. Remove the candidate API or fix it while it remains exported. | removed production endpoint bus |
| Medium | Fixed by removal (`72e94d2`) | The deprecated production byte-endpoint loopback test can block forever in `accept` under ReleaseSafe even after the client send, preventing the advertised release-mode gate from completing. | removed production endpoint bus and loopback test |
| Medium | Fixed (`7625874`; API documentation review) | README/API stability and production-endpoint language still obscures the standing endpoints-are-sim-only decision and removal status of production endpoint remnants. | `README.md`, `docs/api.md`, `docs/network-api.md` |

## 0.6.2 - Disk Semantics v1

| Severity | Status | Finding | Primary location |
| --- | --- | --- | --- |
| High | Open | Disk crash sets durable/crashed state before the final trace and only notifies process observers afterward; trace OOM can leave a crashed disk with live pre-crash process state. | `SimDisk.crash` in `src/disk/sim.zig` |
| High | Fixed (`e46e1de`; `disk: torn writes land a prefix of whole sectors`) | Torn writes land half the pending bytes even though the public contract says a prefix of whole sectors lands. | `applyTornWrite` in `src/disk/sim.zig`; `DiskFaultOptions` in `src/disk/model.zig` |
| High | Fixed (`d21691d`; `disk: crash-global reorder classifies every reversed write`) | One successful per-write reorder roll reverses the entire surviving landing list while only selected entries are traced as reordered; option, trace, and implementation semantics disagree. | crash landing loop in `src/disk/sim.zig` |
| Medium | Open | Failed multi-sector `setLength` extension can leave disk-visible zero writes beyond the still-cached old length. | `simFileSetLength` and `zeroDiskBytes` in `src/io/file.zig` |
| Medium | Fixed (`8af66f8`; `disk: scripted sector corruption rejects a missing file`) | `corruptSector` uses get-or-create lookup and can materialize a missing logical file instead of rejecting a nonexistent target. | `SimDisk.corruptSector` in `src/disk/sim.zig` |

## 0.6.3 - Expected-Failure Containment

| Severity | Status | Finding | Primary location |
| --- | --- | --- | --- |
| High | Fixed (`8db4719`; `io: canceling Group.await cancels members and resurfaces Canceled`) | A task canceled while blocked in `Group.await` remains on a noncancelable park, does not cancel members, and can deterministically deadlock its outer future. | group await in `src/io/backend.zig`; task blocking in `src/scheduler.zig` |
| Medium | Open | Main-context future waits convert deterministic deadlock and scheduler errors into panic, which can abort before the runner preserves a structured failure artifact. | task runtime await bridge in `src/scheduler.zig` |
| Medium | Open | Disk-latency and file-lock waits expose cancelable operations but do not consistently park through the cancelable scheduler path. | disk latency runtime and file-lock waits in `src/scheduler.zig` and `src/io/backend.zig` |
| Medium | Open | A non-yielding SUT loop freezes the cooperative world before in-process deadlock/livelock detection can run; no worker watchdog preserves a partial artifact. | runner/worker boundary; demonstrated by the dusty shutdown-drain bug |
| Medium | Open | `expectSimFailure` accepts any replayable failure, so a checker regression can pass because setup or the scenario failed for an unrelated reason. Add an expected kind/error/check predicate until 0.7 failure fingerprints supersede it. | expectation helpers in `src/run.zig` |

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
