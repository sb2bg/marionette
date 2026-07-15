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

Item-level status for Marionette's own defects lives in
[`SIMULATOR_FINDINGS.md`](https://github.com/sb2bg/marionette/blob/main/SIMULATOR_FINDINGS.md).
External SUT findings remain separately characterized in
[`FOUND_BUGS.md`](https://github.com/sb2bg/marionette/blob/main/FOUND_BUGS.md).

Last updated during the post-`v0.5.0` simulator trustworthiness audit.

---

## North Star

**Normal Zig code goes in; small, replayable, truthful counterexamples come
out.** Marionette wins by removing work from the entire failure lifecycle, not
by owning the most protocols or exposing the most simulator knobs.

The primary application seam is host `std.Io`, `std.Io.Dir`, and narrow
application-owned capabilities. Normal SUT code should not know about `World`
or harness fault controls. The primary harness experience should become one
high-level test declaration that owns world construction, expanded profiles,
scenario execution, properties, exploration, cleanup, artifacts, replay, and
reduction.

A mature failure report should identify the property/fingerprint, artifact,
event and choice counts, reduced fault/action sequence, relevant wait cycle,
and one-command replay. Every release should make either model truthfulness,
adoption, or this failure workflow materially better; breadth without a pinned
SUT or user-facing proof does not advance the north star.

---

## Current Target: 0.6.0 - Simulator TCB Closure

**Theme:** the simulator must not lie because its own ownership, time,
lifecycle, or runner machinery is unsound.

**Done-signal:** every confirmed High-severity simulator-TCB finding from the
0.6 audit has an interaction-level regression test; ownership-changing
fallible paths roll back cleanly; suspension never retains pointers into
reallocatable storage; process and fault state remain coherent across kill,
restart, trace failure, and allocator failure.

The `std.Io.net` depth work through randomized task start jitter already
landed and is recorded in `CHANGELOG.md`: dusty and beanstalkz now exercise
real accept loops, cancellation, keep-alive reuse, connection churn, large
segmented transfers, backpressure, partitions, healing, and exact response
oracles. The audit those SUTs enabled found model bugs that must be closed
before broadening the surface again.

### 16g. Ownership And Suspension Safety

- Replace borrowed `FileMeta` pointers held across disk latency with stable
  identities or stable allocation.
- Retire killed async closures and never-started task adapters during the run,
  not only at world teardown.
- Support valid over-aligned async/group arguments and results.
- Check fiber stack-size arithmetic before mapping or placing canaries.
- Sweep trace-summary and similar allocation-failure paths for leak,
  double-free, and stale-pointer rollback bugs.

### 16h. Time, Fault, And Process Coherence

- Route scheduler-driven clock jumps through the same fault-evolution boundary
  machinery as harness-driven `SimControl.runFor`.
- Reject operations through stale node-scoped capabilities while a process is
  killed.
- Roll back partial restart initialization, and invalidate per-process caches
  across manual restart as well as disk crash.
- Make `transitionToLiveness` retryable until the transition actually
  succeeds.
- Round app-facing simulated sleeps as documented and reject or safely handle
  unrepresentable deadlines and future fault timestamps.
- Decide whether direct `Env.clock.sleep` is deliberately a low-level clock
  mutation or must drive scheduler work and automatic fault evolution like
  app-facing `std.Io` sleep; document or unify the two authorities.

### 16i. Runner And Configuration Integrity

- Forward every `World.SimulateOptions` field through `runSimCase`, including
  allocation faults, stack size, start jitter, and fiber diagnostics.
- Preserve the distinction between setup allocation errors and scenario
  failures.
- Deinitialize pointer-valued app state, include teardown behavior in replay
  comparison, and reject zero-run fuzz campaigns.
- Keep same-seed twice-and-compare as a release gate while these paths change.

### 16j. Audit Regression Matrix

- Add interaction tests for each closed audit finding, not only isolated unit
  tests.
- Add targeted allocation-failure sweeps around ownership publication and
  trace recording.
- Run the full suite in Debug, ReleaseSafe, and ReleaseFast.
- Keep the pinned external SUT corpus release-blocking.
- Compile supported library surfaces for the advertised target matrix;
  unsupported targets must fail closed or be documented explicitly.

---

## 0.6.1 - Truthful std.Io.net Contracts

**Theme:** every supported stream operation means what Zig's `std.Io` contract
says it means; abstractions and intentional divergences are explicit.

**Done-signal:** a checked-in conformance ledger classifies every supported
operation and option as exact, abstracted, unsupported, or an intentional
divergence; no supported option is silently ignored; a reliable stream never
exposes an interior byte hole.

- Model connect as a deterministic network event that participates in node and
  link state, latency, timeout, and cancellation.
- Enforce listener backlog, assign deterministic ephemeral ports for port `0`,
  and return the remote peer address from accept.
- Preserve contiguous ordered bytes across loss/partition behavior; retry,
  stall, or reset rather than delivering a prefix and suffix with a hole.
- Return partial progress after a segmented write has already queued a prefix.
- Implement half-close, or return a documented unsupported error instead of
  treating every shutdown direction as full close.
- Deliver cancellation at every claimed net cancellation point.
- Reclaim shared path/pool capacity on teardown and wake writers whenever any
  API frees the shared resource.
- Add no-fault differential tests against host `std.Io.net` for portable
  observable behavior.

Do not add UDP, Unix sockets, or broader DNS in this release. Promote them only
when a pinned SUT requires them; every simulated surface is a determinism
contract we then maintain.

---

## 0.6.2 - Disk Semantics v1

**Theme:** name and test the atomicity and durability promises applications
may rely on.

**Done-signal:** the disk model has a versioned semantic contract; ordinary
crash faults never damage durable truth; every trace classification matches
the state transition it describes.

- Make torn writes land a prefix of whole sectors, matching the declared
  `DiskFaultOptions` contract. Any byte-tear profile must be separate and
  explicit.
- Choose one reorder model (crash-global permutation, reorder window, or
  per-write placement) and make its option, trace, and tests agree.
- Require `corruptSector` to target existing media instead of materializing a
  missing file.
- Make crash application and process notification coherent across trace or
  allocator failure.
- Prevent failed multi-sector `setLength` from splitting cached and disk-visible
  truth.
- State explicitly whether lifecycle operations commit pending writes; keep
  this as a named portable/adversarial contract rather than implying one host
  filesystem's behavior.
- Add tiny exhaustive crash tests, metamorphic tests, and the invariant that
  non-destructive crash profiles never modify durable truth.

Do not add OS-named storage profiles without differential evidence.

---

## 0.6.3 - Expected-Failure Containment

**Theme:** deadlock, cancellation, timeout, livelock, and non-yielding hot loops
remain observable simulation outcomes rather than terminating or freezing the
test process without evidence.

**Done-signal:** expected failures produce a structured report with the partial
trace and relevant task/resource state; a non-yielding planted loop is
classified by a host-side worker watchdog.

- Make `Group.await` cancellation propagate to members and resurface
  `error.Canceled`; finish cancellation at disk-latency and file-lock waits.
- Return structured deadlock, timeout, cancellation, and cooperative-livelock
  outcomes from the runner where the API can represent them.
- Include a compact wait census and minimal wait cycle for deadlocks.
- Run cases behind a worker boundary with a heartbeat so non-yielding loops,
  simulator panics, and stack corruption preserve the last completed events
  before the worker is terminated.
- Keep this artifact deliberately small; the durable replay capsule belongs in
  0.7.

---

## 0.7 - Replay, Reduce, Explain

**Theme:** a failure becomes a durable, minimal, executable artifact.

**Done-signal:** every planted failure emits a versioned capsule; strict replay
on the same build reaches the same failure fingerprint; replay on a changed
build either reproduces or reports the first semantic divergence; reduction
substantially shrinks its decisions and generated actions; a normal test can
use the high-level harness without constructing `World` directly.

The durable moat is what a future stdlib deterministic scheduler would not
ship: disk and network fault models, buggify, trace replay tooling, and the
external validation corpus. Keep twice-and-compare after exact replay lands:
decision replay proves the artifact can drive execution, while
twice-and-compare proves generation itself remains deterministic.

### 17a. Typed Decision Tape

- Record one globally ordered sequence of typed choices with domain, stable
  semantic site id, alternative shape, selected alternative, logical time,
  and microstep.
- Cover scheduler and wake order, network and disk faults/latency, allocation,
  workload generation, and app randomness.
- Give sites explicit names or comptime tokens rather than source-line
  identity.
- Allow generated choices to carry an action/operation group so reduction can
  remove a whole workload action before editing its component choices.
- Own and version the choice-generation algorithm used for seed discovery, or
  treat any generator change as an explicit model-version boundary. Exact
  replay still consumes the recorded tape rather than depending on that PRNG.

Cutpoint representation (settled in issue #1 with Jason Aten) remains
superdense `(sim_time_ns, microstep)`, where the microstep is the nth random
draw at that timestamp. The pair is a human-friendly projection of the global
decision order: a priori cutpoints such as `(t, 0)` do not require known draw
counts, while branch points harvested from a trace use the full pair. Once a
decision tape is active, `unsafeUntracedRandom` must either participate in the
microstep count or be barred so one pair cannot name two PRNG positions.

### 17b. Replay Capsule And Strict Replay

- Package artifact schema, Marionette/model version, Zig and target identity,
  SUT/build identity, expanded options, root seed, decision tape, human trace,
  failure fingerprint, and property/check identity.
- Consume recorded decisions during strict replay instead of generating new
  ones.
- Stop at the first divergent choice with expected/observed site and
  alternative diagnostics plus the preceding causal event.
- Emit a copy-paste replay command and machine-readable summary.

### 17c. Properties At Safe Points

- Add stable property ids and `always`, `never`, `sometimes`, `eventually`,
  and `at_end` lifecycles.
- Evaluate through a read-only observation surface at deterministic safe
  points; property evaluation must not mutate the simulation or consume
  unrecorded randomness.
- Record evaluation count, first failure, last success, trigger, and whether
  the property was exercised.

### 17d. Execution-Choice Reduction

- Reduce decisions and generated actions, not numeric seed values.
- Delete action groups and choice ranges, disable fired faults, reduce
  durations/counts/payloads, and move alternatives toward stable defaults.
- Preserve the same failure fingerprint and reduce to the earliest causally
  sufficient failure when possible.
- Use the xitdb shrinker as evidence and a test case, not as the generic
  architecture.

### 17e. Failure Explanation

- Add causal event ids and operation spans.
- Enrich deadlocks from a census to a minimal wait cycle.
- Preserve a compact automatic artifact directory suitable for CI attachment
  and regression-corpus check-in.

### 17f. High-Level Harness API

- Add one primary `mar.check`-style entry point (final naming follows API
  review) that owns world lifecycle, replay attempts, cleanup, profile
  expansion, scenarios, properties, and artifact creation.
- Keep application code shaped around `std.Io`, `std.Io.Dir`, `Recorder`, and
  application-owned interfaces; `Env` remains an opt-in convenience rather
  than the price of entry.
- Keep harness powers on control/scenario types and out of application handles.
- Give properties, scenarios, profiles, and failure fingerprints stable names
  suitable for artifacts, deduplication, and regression corpora.
- Make the common path concise without hiding expanded simulator options from
  traces and replay capsules.
- Own routine process lifecycle/reopen wiring so crash tests do not need an
  empty restart callback merely to reactivate process-scoped capabilities.

Defer domain-separated choice generation until exact replay exists. Changing
generation before artifacts are durable makes old/new exploration behavior
harder to compare.

---

## 0.8 - Guided Exploration And Distributed Correctness

**Theme:** spend exploration budgets on semantically distinct executions and
check distributed behavior directly.

**Done-signal:** a resumable campaign deduplicates failures by stable
fingerprint, reports semantic coverage, and PCT measurably outperforms plain
random scheduling on planted depth-one and depth-two bugs.

- Add scheduler policies in order: random, exact replay, PCT, then bounded
  choice/preemption exploration. Defer DFS/DPOR until resource dependencies
  and alternative backtracking points are trustworthy.
- Add campaign budgets, workers/shards, resume, corpus retention, strategy and
  profile mixes, stop/collect policy, and JSON/JUnit output.
- Report choice-site alternatives, property evaluations, event-pair coverage,
  fault-site x system-state combinations, process lifecycle states, link
  transitions, durability boundaries, and cancellation points.
- Record structured invocation/completion histories and ship an initial
  small-history linearizability checker plus external export.
- Add bounded crash-point campaigns, recovery-window helpers, correlated fault
  scenarios, and explicit fault budgets.
- Add storage faults by demonstrated value: ENOSPC/quota, sync failure,
  read-only behavior, delayed writeback, and latent corruption.
- Add a cluster/node builder over process lifecycle only when it simplifies a
  real multi-node SUT.
- Keep `Endpoint(Message)` experimental until a pinned SUT demonstrates the
  message-transport contract it needs. Promotion requires an owned or encoded
  message representation plus explicit delivery/ordering, send acceptance,
  receive readiness, close, cancellation/deadline, backpressure, peer-lifetime,
  and transport-independent error semantics. Validate the same contract against
  both the simulated adapter and the SUT's production adapter; test the real
  codec, framing, and socket path separately through `std.Io.net`.
- Add narrow extension hooks for custom resources, faults, events, and
  properties only after two independent users need them; do not expose mutable
  `World` internals as the plugin API.
- Maintain a public bug zoo of planted durability, cancellation, retry,
  deadlock, linearizability, and liveness failures, each with its original and
  reduced replay artifact.

---

## 0.9 And 1.0 - Stabilize The Narrow Core

Stabilize the seams that proved useful, not every simulator implementation
type:

- Define three compatibility tiers: application (`std.Io`, `std.Io.Dir`, and
  narrow app-owned capabilities), harness (scenario, control, profile,
  property, campaign, artifact, replay, reduction), and model-author
  (low-level world/network/disk/scheduler machinery).
- Narrow root exports around the proven application and harness seams; place
  model-author APIs behind an explicitly weaker compatibility boundary only
  after the high-level harness can replace ordinary direct `World` use.
- Publish model, trace, decision-tape, and artifact compatibility/versioning
  policies.
- Run platform and optimize-mode matrices for the fiber/context-switching and
  `std.Io` backends; harden Windows or scope supported targets explicitly.
- Benchmark scheduler/event-queue scaling before replacing data structures.
- Establish artifact retention/migration policy and a release-blocking
  external SUT corpus.
- Consider time-travel or graphical trace tooling only after artifacts and
  causal structure are stable.

Do not move `World` or other existing public types into an experimental
namespace until the harness seam can replace their normal use without losing
capability.

---

## Standing Decisions

### Message And Stream Networking Are Sibling Surfaces (decided 2026-07)

Marionette supports two deliberately different testing altitudes:

- `std.Io.net` is the canonical literal same-code seam for socket-facing code.
  It exercises codecs, framing, partial I/O, stream ordering, connection
  lifecycle, and transport glue through the deterministic backend.
- `Endpoint(Message)` is an experimental message-modeling seam for exploring
  protocol and state-machine behavior above the wire. It can model independent
  message loss, latency, reordering through delivery scheduling, and partitions
  without forcing every model through a byte-stream abstraction.

At the endpoint altitude, the same protocol/state-machine implementation can
run behind an application-owned production transport and a Marionette adapter
in simulation. That is a narrower promise than wire-path parity: the current
endpoint does not serialize arbitrary Zig values and does not yet define a
production-grade ownership, lifecycle, readiness, cancellation, or backpressure
contract. Matching its vtable shape alone is not evidence of behavioral parity.

Marionette will not ship its own production socket bus. Owning one would create
a parallel networking stack whose adoption and maintenance costs land on users.
If a real SUT later needs one shared message interface, its semantics and
production adapter must drive the design; the 0.8 promotion gate records the
required contract.

Consequences, recorded so they are not relitigated:

- Steps 15g-15k (production bus, multi-peer reconnect, cross-process
  parity) are cancelled, not deferred. `docs/network-production.md` is
  retained as design history. If a real user ever needs cross-process
  `Endpoint(Message)`, that is a new decision made with that user.
- `ByteEndpoint` is removed from the public surface in 0.6. Its byte-pool and
  delivery machinery remain private implementation details of deterministic
  `std.Io.net`; there is no second public byte-network API.
- Queue-full behavior remains `error.EventQueueFull`. Whether a future message
  transport instead uses silent, trace-visible drops is a candidate to evaluate
  with the pinned SUT that drives the stable contract; it is not settled now.

### The std.Io Seam Is The Product

Production-shaped SUT code should accept host `std.Io`; simulation substitutes
Marionette's deterministic implementation. Do not require SUT code to know
about `World`, do not put harness fault powers into application handles, and do
not build a Marionette production runtime merely to preserve symmetry.

Marionette explores logical concurrency at deterministic authority and
suspension boundaries. It does not prove arbitrary preemptive shared-memory
code free of data races; users still need ordinary integration, sanitizer,
fuzz, and platform testing.

### Breadth Is SUT-Driven

- UDP, Unix sockets, broader DNS, named buses, message-kind filters, and richer
  protocol surfaces require a pinned SUT or concrete user.
- OS-named storage profiles require differential evidence.
- Production runtime shapes beyond host `std.Io` require a real adopter.
- DPOR, graphical debugging, and scheduler data-structure rewrites wait for a
  mature dependency model or measurement.
- Replace `SimNetworkOptions.service_nodes` with an explicit partitionable set
  only when a non-prefix topology is needed.

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
3. `zig build test -Doptimize=ReleaseFast` passes.
4. The format gate and tidy linter pass.
5. Listed acceptance criteria and release-specific done-signals are met.
6. Supported `std.Io` operations and options are implemented, explicitly
   abstracted, or fail closed; none are silently ignored.
7. Model changes include contract or state-machine coverage in addition to
   scenario tests; ownership-changing fallible paths receive targeted
   allocation/trace-failure coverage.
8. Public API and model-contract changes update the relevant docs and
   conformance ledger.
9. Trace/model semantic changes update versions and snapshot coverage rather
   than deleting old expectations silently.
10. Relevant target compile checks and the release-blocking external SUT
    validations pass; unsupported targets remain explicitly documented.

### Keeping This File Clean

- Do not add completed-task history here; use `CHANGELOG.md`.
- Do not duplicate long architecture writeups here; link or name the relevant
  doc path.
- Do not add unresolved `TODO` comments without either a roadmap task or a
  GitHub issue.
- Update this roadmap in the same PR as any substantive scope change.
