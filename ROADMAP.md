# Roadmap

This is Marionette's single source of truth for planned work. It should stay
focused on what to build next, why that work is ordered this way, and what
"done" means for each release.

Completed work belongs in `CHANGELOG.md` and feature docs. Detailed designs
belong in the relevant docs, especially:

- `docs/std-io-direction.md`
- `docs/network-production.md`
- `docs/network.md`
- `docs/disk-fault-model.md`
- `docs/api.md`

Last updated after `v0.4.0`.

---

## Current Target: 0.5 - Deepen Simulation Correctness

**Theme:** close the last missing simulator primitive and give faults a real
recovery vocabulary before the production-transport push.

**Done-signal:** Marionette can model allocation pressure and storage
recoverability, then shrink meaningful disk/allocation failures into
maintainer-readable repros.

Pick from this section first unless a later release item is blocking it.

### Deterministic Allocation Authority

Allocation is explicit in Marionette examples, but it is not yet a simulated
authority. User code can still silently reach for process-global allocators,
and Marionette cannot yet model deterministic OOM, quotas, or
allocation-pressure bugs.

Do this before allocator behavior becomes baked into more examples and before
the scheduler grows more long-lived dynamic state.

Acceptance criteria:

- Add an app-facing `std.mem.Allocator` wrapper returned from `Env` or
  alongside `Env`.
- Add a production adapter that wraps a caller-provided backing allocator with
  no faults by default.
- Add harness-side controls for deterministic fail-after,
  quota/max-live-bytes, and optional `BuggifyRate` allocation failures.
- Keep allocation fault configuration on `control`, not at each allocation call
  site.
- Trace allocation decisions without raw addresses: allocation id, requested
  length/alignment, result, live bytes, and failure reason.
- Decide whether frees/reallocs are always traced or only traced in a verbose
  profile. The default should catch leaks and OOM behavior without making every
  trace unreadable.
- Add a tidy default or documented project rule for global allocators such as
  `std.heap.page_allocator` in simulated code once the replacement API exists.
- Add or extend an example so allocation failure is a real modeled branch, not
  only a unit test of the allocator wrapper.

Design constraints:

- Prefer Zig's `std.mem.Allocator` interface over a Marionette-specific
  allocation API.
- Model failure timing and resource pressure, not address determinism.
- Keep modeled application allocations separate from Marionette's internal
  bookkeeping allocations at first.

### Recovery Windows And Disk Fault Budgets

The KV example currently encodes recoverability in its checker. Reusable disk
profiles need explicit vocabulary for "durable truth" and "allowed damage."

Acceptance criteria:

- Document a minimal recovery-window concept using the KV example as the worked
  case.
- Define how destructive disk fault budgets interact with synced and unsynced
  writes.
- Keep generic enforcement out of `mar.Disk` until at least one more storage
  example exists.
- Add the probabilistic KV recovery search that was held until this vocabulary
  existed.

### External Storage Compatibility And Shrinking

The base disk lifecycle surface exists. The remaining storage work is about
confidence, compatibility, and readable repros.

Acceptance criteria:

- Expand the xitdb crash-fault profile into a real fuzzer with shrinking.
- Vary sector size, crash point, workload length, and one active fault class at
  a time.
- Reduce failures to a maintainer-readable operation sequence.
- Add a small compatibility scenario that ports the storage-facing slice of
  `kvdb` or a local surrogate:
  open database, append WAL records, commit, reopen/recover, compact via
  rename, and clear/delete the WAL.
- Keep filesystem modeling scoped. Directory deletion/rename, permissions,
  symlinks, and richer directory APIs remain deferred until a compatibility
  target forces them.

### Liveness Mode Transition

Add a one-shot `sim.transitionToLiveness(core: []const NodeId)` that:

- zeroes probabilistic fault rates,
- restores the core's links,
- brings the core's nodes up,
- leaves non-core failures permanent.

This follows the VOPR `transition_to_liveness_mode` shape. It depends on the
recovery-window and external-storage work above so storage examples have a
durable-truth vocabulary.

### Opportunistic 0.5 Cleanup

Take these only if they are naturally forced by the work above or can land as
small isolated patches:

- Replace `SimNetworkOptions.service_nodes: usize` with
  `partitionable_nodes: []const NodeId` when a third caller sets
  `service_nodes`, or when a real example needs a non-prefix subset.
- Pick one misuse contract for `runFor`: `SimControl.runFor` currently returns
  `error.InvalidDuration`, while `World.runFor` / `SimClock.runFor` assert.
- Pick one disabled-fault random-consumption convention: disk `rollFault`
  skips the draw when `numerator == 0`, while `Env.buggify` always draws.
- Document complete host filename parity as deferred. The current guarantee is
  rooted, non-traversing logical syntax, not identical behavior across case
  sensitivity, Unicode normalization, Windows reserved names/streams,
  trailing-dot/space handling, or host path limits.

---

## Next Target: 0.6 - Production Transport Parity

**Theme:** close the cross-process gap so the same `Endpoint(Message)`
application path runs in simulation and across real OS processes.

**Done-signal:** `Endpoint(Message)` supports real multi-process socket
transport with bounded queues, reconnect, silent-drop convergence, and CI
coverage through a cross-process replicated-register parity test.

The architecture source of truth is `docs/network-production.md`. Keep that
document detailed; keep this roadmap focused on the sequence.

Steps 15a-15f are already started. Finish the chain:

- **15g. Production-bus fake IO tests.** Exercise partial frame reads/writes,
  EOF mid-frame, reconnect timing, and close discipline against the production
  bus machinery without replacing normal `World` simulation.
- **15h. Multi-peer connection management.** Add lazy outbound connect,
  inbound listener, and peer identity resolution from the first valid frame.
- **15i. Reconnect with seeded jittered backoff.** Test connection drop and
  recovery end to end. Jitter seed comes from the local `NodeId`.
- **15j. Bounded send and recv queues.** Converge sim/prod send semantics:
  `error.EventQueueFull` becomes a trace-visible
  `network.drop reason=queue_full` event in both implementations, and `send`
  no longer surfaces transient errors.
- **15k. Cross-process parity test.** Run the replicated-register example on N
  OS processes, same source, same scenario, real sockets. This closes roadmap
  item 15.

Supporting scheduler/runtime work belongs in 0.6 only when transport
correctness needs it:

- cooperative cancellation points,
- queue suspension,
- close discipline.

Broader production event-loop or thread-per-core runtime parity is not part of
the 0.6 done-signal unless the transport test forces it.

---

## 0.7 And Beyond

Promote later items only when they have a concrete example, compatibility
target, or user-facing proof.

### Production Runtime Parity

Define production runtime shapes for scheduler-backed code beyond transport:

- single-thread cooperative event loop,
- shared-nothing thread-per-core runtime,
- explicit guarantee demotion for arbitrary preemptive threads.

Marionette should continue to test logical concurrency at deterministic
authority boundaries, not CPU memory-model or kernel scheduling behavior.

### Cluster Correctness UX

- Multi-replica fault atlas.
- Linearizability checker.
- Richer reduced failure reports for distributed protocols.

### Shrinking And Debugging UX

- General seed shrinking.
- Trace export.
- Time-travel/debugging cursor.

The xitdb shrinker in 0.5 should inform this work rather than pre-solving it
globally.

### Network Composition

- Named buses.
- Message-kind filters.

Do this only after a second independent example needs both RPC/gossip-style
channels or payload-class-specific faults.

### Filesystem Parity Profile

- Versioned, opt-in portable filename profile.
- Production `std.Io` wrapper or equivalent seam so simulation and production
  enforce the same policy.

### Platform Maturity

- Full Windows execution.
- Win64 fiber trampoline with execution coverage.
- Broader socket-handle work needed by Windows transport.

### Scheduler Scale

- Replace the `EventQueue` linear-scan pop with a heap when benchmarking shows
  it matters.

---

## Contributor Notes

### Choosing Work

- Start with the current target.
- Prefer the highest item that is unblocked.
- Later-release items are fair game only when they unblock the current target
  or are deliberately small cleanup.
- One task per PR. Do not bundle unrelated changes.

### Done Means

1. `zig build test` passes.
2. `zig build test -Doptimize=ReleaseSafe` passes.
3. The tidy linter passes.
4. Listed acceptance criteria are met.
5. Public API changes update the relevant docs.
6. Trace-byte changes include updated snapshot coverage rather than deleting
   old expectations silently.

### Keeping This File Clean

- Do not add completed-task history here; use `CHANGELOG.md`.
- Do not duplicate long architecture writeups here; link or name the relevant
  doc path.
- Do not add unresolved `TODO` comments without either a roadmap task or a
  GitHub issue.
- Update this roadmap in the same PR as any substantive scope change.
