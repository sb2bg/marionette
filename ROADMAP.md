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

Last updated after `v0.5.0`.

---

## Current Target: 0.6 - Deterministic std.Io.net Depth

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

- **16d. Keep-alive and connection churn.** Sequential connection churn and
  close/shutdown discipline landed through the pinned beanstalkz queue
  client (`validate-beanstalkz`): fresh connect/put/quit/`shutdown(.both)`
  cycles, a reserve parked across virtual time, and reset-on-crash
  contracts. Remaining: dusty's pooled keep-alive reuse across requests and
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

### Opportunistic Cleanup

Take this only when naturally forced or as a small isolated patch:

- Replace `SimNetworkOptions.service_nodes: usize` with
  `partitionable_nodes: []const NodeId` when a third caller sets
  `service_nodes`, or when a real example needs a non-prefix subset.

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

### Seed Schedules And Guided Exploration

Make the seed plural: a run becomes identified by (code, options, seed
schedule), where a schedule is an ordered list of seed segments ending at
deterministic cutpoints. Cutpoints must cover more than simulated time,
because randomness is also drawn at non-time boundaries (scheduler choices,
disk fault rolls, app-facing randomness, allocation buggify, send-time
network loss/latency), so the boundary vocabulary wants simulated-time
boundaries, random-draw or trace-event indices, and named trace milestones.
Every switch is trace-visible, so the determinism contract is unchanged:
same code, same options, same seed schedule, byte-identical trace, and the
twice-and-compare runner works on schedules as-is.

This unlocks Antithesis-style exploration: branch from an interesting point
by keeping the schedule prefix and appending a fresh suffix seed, derivable
as hash(prefix, branch index). As a library, forking means replaying the
prefix, O(prefix) per branch rather than O(1) snapshotting; quiet spans
already jump, so replay is cheap. Search policy (milestone predicates over
trace events, schedule retention) belongs in an `explore()` harness layered
above the core, not in `World`. Done when guided exploration measurably
beats the durable broadcast example's 64-seed probabilistic bug search.

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
