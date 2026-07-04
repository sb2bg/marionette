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

### Liveness Mode Transition

Add a one-shot `sim.transitionToLiveness(core: []const NodeId)` that:

- zeroes probabilistic fault rates,
- restores the core's links,
- brings the core's nodes up,
- leaves non-core failures permanent.

This follows the VOPR `transition_to_liveness_mode` shape. It depends on the
recovery-window vocabulary and storage compatibility validation, which are now
met by `docs/disk-fault-model.md` and `validation/kv_compat.zig`.

### Opportunistic 0.5 Cleanup

Take these only if they are naturally forced by the work above or can land as
small isolated patches:

- Replace `SimNetworkOptions.service_nodes: usize` with
  `partitionable_nodes: []const NodeId` when a third caller sets
  `service_nodes`, or when a real example needs a non-prefix subset.

Settled in 0.5: misaligned `runFor` durations assert as harness misuse
everywhere; disabled faults (zero rates) consume no randomness and emit no
trace (see the determinism doc's conventions section); and deferred host
filename parity is documented in the API doc's logical-path section.

---

## Next Target: 0.6 - Deterministic std.Io.net Depth

**Theme:** grow the simulated `std.Io.net` surface until a pinned, unmodified
external network SUT runs, fails meaningfully, and shuts down cleanly under
simulation.

**Done-signal:** the pinned dusty HTTP validation runs its unmodified client
and server through the real `Server.listen` accept loop, exercises keep-alive
reuse, chunked transfer, and graceful shutdown under deterministic latency,
partition, and heal scenarios with an exact response oracle, and runs in CI
alongside the other external validations.

Rationale: for `std.Io.net` code, production parity is free because the host
`std.Io` is the production implementation. Every sim-side gap closed here buys
compatibility with any Zig code written against the standard interface. This
replaces the previous 0.6 target (production `Endpoint(Message)` transport),
which moves to 0.7 until a user needs cross-process endpoint parity.

The first three slices exist: cooperative cancellation (16a) delivers
`error.Canceled` at futex, sleep, and net suspension points with deterministic
group ordering, `validate-dusty` (16b) runs the pinned, unmodified
`lalinsky/dusty` server through its real `Server.listen` accept loop with
cancel-driven graceful shutdown and byte-identical same-seed replay, and the
dusty fault scenarios (16c) partition before and during responses, pin the
observed `error.Timeout` contract, heal, retry with an exact body oracle, and
reject short-success partial responses. Finish the chain:

- **16d. Keep-alive and connection churn.** Sequential connections, pooled
  reuse across requests, and close/shutdown discipline, including
  `netShutdown` semantics under partition.
- **16e. Larger transfers.** Chunked bodies and payloads spanning many
  simulated packets, exercising partial reads and writes through the
  `Io.Reader`/`Io.Writer` adapters.
- **16f. Randomized task start jitter.** Readiness races are structurally
  masked today: virtual time advances only when every task blocks, so a
  server with no suspension point before `listen` always beats a client that
  sleeps first, and no seed can find the race. Add an opt-in simulate option
  that draws a small per-task initial delay from the seed so the scheduler
  explores those orderings for the whole class of SUTs instead of one
  hand-written delay per scenario. Done when a validation deterministically
  reproduces a connect-before-listen race with same-seed replay, and the
  option defaults off so existing traces and snapshots are unchanged.

Deferred cancellation follow-ups, promoted when a SUT forces them: a
cancelable `Group.await` park (a canceled awaiter should propagate to members
and resurface `error.Canceled`), and cancellation points on disk-latency and
file-lock waits.

Supporting scheduler/runtime work belongs in 0.6 only when the SUT forces it.

---

## 0.7 And Beyond

Promote later items only when they have a concrete example, compatibility
target, or user-facing proof.

### Production Endpoint Transport (deferred from 0.6)

The architecture source of truth remains `docs/network-production.md`. Steps
15a-15f produced framing and buffer-pool code that stays. Finish 15g-15k
(fake-IO bus tests, multi-peer connection management, seeded reconnect,
bounded queues, cross-process parity test) when a user or example needs
cross-process `Endpoint(Message)` parity.

Two notes recorded now so they are not relitigated later:

- When the production bus is built, prefer implementing its socket layer on
  host `std.Io.net` so the simulator's own deterministic backend can exercise
  partial reads, EOF mid-frame, and reconnect timing, instead of building a
  bespoke fake-IO backend. This resolves the internal-seam decision that
  `docs/network-production.md` deferred until 15d.
- The 15j send-semantics convergence (silent drop plus a trace-visible
  `network.drop reason=queue_full` event, `send` no longer surfacing
  transient errors) is an app-facing contract change independent of sockets.
  If endpoint usage grows before this section is promoted, land the contract
  change on the simulation side first.

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
