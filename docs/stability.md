# Stability Ledger

This ledger classifies every public surface ahead of the first stabilization
candidate. 1.0 commits to the **candidate** rows; **experimental** rows may
change in any release; **deprecated** rows will be removed or frozen before
the first candidate. The final freeze follows 0.11, which gives each host its
own storage domain: rows marked *settles in 0.11* may still change there.

## Candidates For The 1.0 Contract

| Surface | Notes |
| --- | --- |
| Simulated `std.Io` (files, directories, `std.Io.net` streams, time, randomness, tasks, futexes, `Batch`) | The subsets in [`std.Io.net` Conformance](std-io-net-conformance.md) and the [disk fault model](disk-fault-model.md). Unsupported operations fail with honest errors. |
| `Env`, `Production`, `Recorder` (`record`, `event`, `beginOperation`, `fromSink`), `Operation` | Application-facing capabilities. Recording never fails at the call site. |
| `mar.Harness` and its methods, `SimCase`, `StateCheck`, `CheckPhase` | The typed harness: run, capture, typed inputs, expectations, fuzz, replay, reduction, campaigns, crash-point sweeps. |
| `Control` and its sub-controls (`allocation`, `disk`, `network`, `process`, `tasks`) | Including `failRun`, the decision helpers, `record`, `traceBytes`, `now`, and `harnessAllocator`. Disk control *settles in 0.11* with per-host crash domains. |
| `CrashProfile`, crash-point sweep options and results, `CrashEffects`, `crashEffects` | Named durability profiles and effect requirements; the `portable_v2` disk contract. Domains *settle in 0.11*. |
| `TraceFocus`, `writeTraceHistory`, `writeTraceTail`, `firstTraceDifference`, `RunFailure.writeDiagnosis` | Text diagnostics derived from trace bytes. |
| `SimulateOptions.strict_capabilities`, `TimeError` | Unsupported-operation runs and descriptive time errors. |
| Network fault handles (`partition`, `isolate`, `cut`, `degrade`, `healFault`) and `tcp_v1` | The [network model](network.md). |
| `RunReport`, `RunFailure`, `RunFailureKind`, `FailureExpectation` | Failure kinds may gain variants; switch with an `else` prong. |
| `ReplayCapsule`, `ReplayIdentity`, `mar.repro`, `mar.cli`, `reproOptions` | Evidence and reproduction. |
| Grouped namespaces `mar.disk`, `mar.net`, `mar.replay`, `mar.decision`, `mar.trace`, `mar.campaign`, `mar.crash`, `mar.process`, `mar.alloc`, `mar.seed` | The preferred names for everything above. |
| Trace grammar, trace format version, capsule format, decision tape format | Versioned; see [Trace Format](trace-format.md) and [Decision Tapes](decision-tapes.md). |

## Experimental

| Surface | Why |
| --- | --- |
| `Endpoint(Message)`, `sim.borrowedEndpoint` | No wire, flow control, or lifecycle, under a declared delivery and ownership contract; see [Typed Endpoints](network.md#typed-endpoints). |
| `World` and its fields and methods | The engine behind `Control`. Harnesses should not need it. |
| `SimDisk`, `SimClock`, direct model operations | Simulator contracts and white-box tests. |
| `SimProfile` | Awaits workload evidence. |

## Deprecated

| Surface | Replacement |
| --- | --- |
| Flat root aliases (`NetworkFault`, `ReplayCapsule`, `DiskControl`, `runCampaign`, ...) | The grouped namespaces. |
| `anytype` config entry points (`runSimCase`, `expectSim*`, `replaySimCase`, `reduceSimCase`, `reduceCapsule`, `runCampaign`, `sweepCrashPoints`) | `mar.Harness`. |
| `legacy_v0` network semantics and the `shared_v0` address model (deprecated in 0.9) | `tcp_v1`. Removal is deferred past the one-release window until the legacy characterization and regression tests are ported; see the changelog. |

## Rules

- A breaking change to a candidate surface needs a changelog entry under
  **Breaking** with migration guidance, and is batched into a minor release.
- A deprecated surface keeps working for at least one minor release after its
  replacement ships, and its removal is announced in the changelog first.
- A behavior change that alters replay of the same decisions bumps the
  relevant semantic version (`disk_semantic_version`,
  `network_semantic_version`, or the trace format), so stale capsules are
  rejected instead of misreplayed.
- Two consecutive stabilization candidates must ship without breaking any
  candidate surface before 1.0.
