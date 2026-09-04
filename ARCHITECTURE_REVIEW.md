# Architecture Review — 2026-09-04

Scope: current working tree based on `cdb2f80`, including the decision-tape work
already in progress. The original inspection below motivated the changes now implemented on
`feat/0.7.0` (starting at `9c77c8e`). The source audit was against `cdb2f80`
plus the decision-tape draft. The original main checkout remains untouched.

## Implementation Status

All five proposed changes are implemented:

| Review item | Result |
| --- | --- |
| Delete unused network implementation | Removed packet core, EventQueue, and NetworkOptions; ported unique contracts to active runtime tests. |
| Shared file metadata | One process-registry store plus disk identity lookup and identity-keyed locks; removed lock-path rekeying and retained descriptor-local state. |
| Configuration and formatting | Owned normalization before temporary tuple storage expires; common dynamic attribute formatting and CLI writers. |
| Fatal replay state | Divergence survives rollback; common scalar choice transaction helper. |
| Execution and watchdog ownership | Owned execution result, dedicated transport, shared versioned codec, and persistent capsules. |

Self-review also corrected canceled file-lock waiter ownership, phantom locks after direct
disk rename and old-path reuse, disabled network
loss draws, and worker-exit classification. Regression, optimization, and external
validation evidence is recorded in `RELEASE_READINESS.md`. Reduction and arbitrary
cross-version replay are explicitly outside the 0.7 scope.

The remainder preserves the original evidence and rationale; proposed paths and
line counts refer to the pre-refactor source.

The most useful simplification is to remove duplicated authorities and obsolete
implementations. The `std.Io` application seam, explicit harness controls,
cooperative scheduler, and named disk contract are worth keeping.

## 1. Delete The Unused Parallel Network Implementation

**Evidence:** `src/network/packet_core.zig` is 699 lines implementing
`UnstableNetwork` and its `NetworkSimulation` wrapper. Repository references
show that its consumers are `src/network/tests.zig` and internal re-exports.
`World.simulate`, examples, and external validations use the runtime in
`src/network/sim.zig`. The fixed packet core is not a layer underneath that
runtime: each owns its own queues, node/link state, delivery logic, and controls.

**Proposed deletion:** Port the useful loss, partition, clog, ordering, and
capacity assertions from the legacy tests to `World.simulate` plus endpoints or
streams. Then delete `packet_core.zig`, its internal exports, and unused imports.
The fixed-capacity `scheduler.EventQueue` is used only by this legacy core and
its own tests, making it a follow-on deletion candidate. `NetworkOptions` is
also a legacy topology type, but is still exported at the public root; removing
that name needs an explicit compatibility decision.

**Why:** Maintaining two implementations gives tests a way to pass against code
that real scenarios never exercise. The current tape migration even adds
decision sites to both implementations. One implementation reduces semantic,
testing, and replay maintenance.

**Validation:** Preserve each relevant behavioral assertion on the active
runtime, then run the normal optimization matrix and network validations.
Do not delete all legacy tests without checking which coverage is unique.

## 2. Give Shared Files One Metadata Authority

**Evidence:** `SimDisk.File` owns file identity and length, while each
`Backend.files` list owns another `FileMeta` with path, inode, length, timestamp,
deleted, and stale state. `src/io/file.zig` returns cached lengths and clips
reads with them. Rename and delete require cross-process metadata sweeps in
`src/io/backend.zig`; process restart has another refresh path. SIM-001 proves
that ordinary writes already escape this synchronization scheme.

**Proposed simplification:** Keep descriptor access mode, cursor, locks, and
process lifetime local. Move file identity and observable metadata to a shared
filesystem object, or use a single disk-owned metadata version to validate
caches. Prefer stable identity handles over repeatedly rekeying copied paths.
Keep the existing disk contract explicit while doing this; inode lifetime and
open-file deletion semantics require deliberate decisions.

**Why:** This removes competing truths rather than adding another broadcast
invalidation path. It also addresses mixed `Disk` and `std.Io.File` use, since
both capabilities are exposed by `Env` and can mutate the same disk.

**Validation:** Two live processes observing extension/truncation, directory
stat versus descriptor stat, rename/delete, crash recovery, and operations
suspended on disk latency. Existing stable allocations and operation scratch
are purposeful: fibers killed while parked do not execute ordinary defers.

## 3. Normalize Runner Configuration Once, With Explicit Storage Lifetime

**Evidence:** `runSimCase` accepts an `anytype` bag, then `runOptionsFromConfig`
and `fieldOrDefault` coerce optional fields into borrowed slices. SIM-004 shows
that an inferred metadata tuple becomes dangling storage. Metadata formatting
also exists in both `run.zig:recordRunContext` and `run_types.zig`, and SIM-003
shows the fixed trace formatter does not cover the advertised scalar domain.

**Proposed simplification:** Retain compile-time inference for `init`, scenario,
and checks, but normalize runtime options and borrowed collections once into
storage that lives across both executions. A typed `RunOptions` subfield is an
alternative if changing the call shape is acceptable. Share scalar formatting
between trace and report writers while retaining each envelope's escaping rules.

**Why:** It removes conversion/lifetime ambiguity and duplicate representations.
The roadmap's richer harness can extend `runSimCase`; it does not need another
parallel high-level runner.

**Validation:** Inferred and explicitly typed arrays, runtime strings, empty
collections, large floats, failure reports, and allocator-failure cleanup. Check
actual expected values as well as equality between repeated executions.

## 4. Separate Retryable Transactions From Fatal Replay State

**Evidence:** `World.TransactionCheckpoint` combines trace, PRNG, and decision
state. `Engine.Checkpoint` includes the latched divergence, and rollback restores
it. Disk crash staging invokes rollback for any error, erasing a fatal replay
mismatch in SIM-002. The three `World.choose*` methods also repeat almost the
same choice/trace/rollback sequence.

**Proposed simplification:** Define the transaction boundary once: which state
is staged, which state commits, and which diagnostics survive any rollback.
Keep the first fatal replay mismatch outside retryable checkpoint state.
After that contract is tested, use a small shared helper for the repeated
choice transaction plumbing if it makes the three typed entry points clearer.

**Why:** Callers should not need to discover which errors are safe to roll back.
This is especially important before decision reduction introduces more ways to
reach mismatched or exhausted tapes.

**Validation:** OOM at every choice/trace append, mismatches inside multi-choice
transactions, empty and partial tapes, construction failure, and caught replay
errors followed by another choice or `finishDecisionReplay`.

## 5. Separate Watchdog Transport From Execution Result Ownership

**Evidence:** `src/run.zig` contains generic scenario inference, execution,
comparison, formatting, POSIX worker management, shared-memory transport, and
watchdog timeout classification. Its internal `RunOnceResult` already uses the
public aggregate result/failure types. `compareRunOnceResults` manually moves
traces, tapes, options, diagnostics, and several ownership flags through each
outcome pairing. The watchdog reconstructs another subset of those fields and
currently cannot carry decision tapes.

**Proposed simplification:** Use one owned internal execution result containing
trace, tape, and a pass/failure outcome. Let the two-run comparator assemble the
public report and own shared run metadata once. Extract watchdog transport into
its own module behind that result boundary, with explicit unsupported/partial
fields. Make the future capsule codec the shared serialization contract where
practical, rather than growing another independent result layout.

**Why:** Ownership becomes easier to review, and adding replay capsules does
not require synchronizing multiple ad hoc result shapes. This can follow the
correctness fixes; it is not a prerequisite for fixing them.

**Validation:** Pass/pass, pass/fail, fail/pass, matching failures, mismatched
failures, first replay divergence, watchdog termination, and allocation failure
while constructing every owned result. Keep public error identities stable.

## Suggested Order

1. Fix SIM-001 through SIM-004 and promote their reproductions into regular tests.
2. Port legacy network coverage and delete the redundant implementation.
3. Normalize runner configuration and formatting around explicit ownership.
4. Consolidate filesystem metadata, then simplify the invalidation/rekey paths.
5. Separate execution results and watchdog transport while implementing capsules.

Do not spend this round replacing scheduler queues with heaps, introducing a
general plugin model, or expanding network protocols. The code and current
findings support the focused deletions and ownership changes above; data
structure changes still need measurements and protocol expansion needs a SUT.
