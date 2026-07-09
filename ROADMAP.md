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
since cancelled outright; see "Endpoints Are Sim-Only" below.

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

Deferred `std.Io.net` surface, promoted when a pinned SUT forces it: UDP
datagrams (`netBindIp` currently fails closed), unix sockets, and DNS
resolution. Likely first customer: a gossip or DNS-client library. Do not
build these speculatively; every simulated surface is a determinism
contract we then maintain.

Supporting scheduler/runtime work belongs in 0.6 only when the SUT forces it.

### Opportunistic Cleanup

Take this only when naturally forced or as a small isolated patch:

- Replace `SimNetworkOptions.service_nodes: usize` with
  `partitionable_nodes: []const NodeId` when a third caller sets
  `service_nodes`, or when a real example needs a non-prefix subset.
- Export trace assertion helpers. `dusty_http.zig` and
  `xitdb_durability.zig` each define a private `expectTraceContains`
  (11 call sites between them); the trace is a first-class Marionette
  artifact, so asserting on it belongs in the public API. Scope is
  deliberately narrow: trace assertions only, no test-framework layer
  (ready-signal types, protocol scaffolding, model-comparison harnesses
  stay out; Marionette's surface is the deterministic `std.Io` substrate).

---

## 0.7 And Beyond

Promote later items only when they have a concrete example, compatibility
target, or user-facing proof.

Presumptive 0.7 theme: exploration and debugging depth (seed schedules,
shrinking, failure-report UX) rather than more transport plumbing. The
durable moat is what a future stdlib deterministic scheduler would never
ship: disk and network fault models, buggify, trace replay tooling, and
the external validation corpus. Zig core has floated Io-injection-based
deterministic schedule testing for unit tests; if that lands, basic
schedule exploration commoditizes and the fault-model depth is what
remains differentiated.

### Endpoints Are Sim-Only (decided 2026-07, closes the production transport question)

`Endpoint(Message)` and `ByteEndpoint` are simulation modeling tools: they
exist so protocol logic can be tested above the wire, with per-message
loss, reorder, and partition faults that a byte stream cannot express (a
stream must deliver in order or die, so "drop message 3" is only
meaningful at the message layer). Production networking is host
`std.Io.net`; Marionette will not ship its own production socket bus.

This does not break the same-code contract; it locates it. The unit
under test at the endpoint layer is the transport-independent protocol
state machine, which runs unchanged in production behind the app's real
transport glue. The glue is written against `std.Io.net` and is itself
testable under the deterministic backend with stream-level faults. Apps
that want literal endpoint parity can implement the `Endpoint(Message)`
vtable over their own transport, or better, own their bus interface and
adapt it to `mar.Endpoint` in tests only.
Rationale: a Marionette-owned transport is a parallel networking stack
whose adoption cost lands on users, which is the madsim failure mode
(owning a mirror of an API surface you do not control) in reverse.

Consequences, recorded so they are not relitigated:

- Steps 15g-15k (production bus, multi-peer reconnect, cross-process
  parity) are cancelled, not deferred. `docs/network-production.md` is
  retained as design history. If a real user ever needs cross-process
  `Endpoint(Message)`, that is a new decision made with that user.
- The typed `Production.endpoint` in-process FIFO and its options/errors
  are now removal candidates; prune them when touching that code, and
  keep `Production.byteEndpoint`'s loopback slice only while a parity
  test still uses it.
- The 15j send-semantics convergence (silent drop plus a trace-visible
  `network.drop reason=queue_full` event) still applies to the simulated
  endpoint if endpoint usage grows; it is a sim-side contract change now.

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
