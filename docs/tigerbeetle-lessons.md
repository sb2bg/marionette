# TigerBeetle Lessons

This is a focused study pass over TigerBeetle's local reference clone. The goal
is not to copy VOPR. The goal is to extract design lessons that should shape
Marionette before we build scheduler, network, disk, invariants, and liveness.

TigerBeetle is licensed under Apache-2.0. These notes are an independent study
of TigerBeetle's public VOPR design and source code. They summarize lessons for
Marionette; they are not copied TigerBeetle code or documentation.

Primary files studied:

- `.references/tigerbeetle/docs/internals/vopr.md`
- `.references/tigerbeetle/docs/internals/testing.md`
- `.references/tigerbeetle/src/vopr.zig`
- `.references/tigerbeetle/src/testing/cluster.zig`
- `.references/tigerbeetle/src/testing/packet_simulator.zig`
- `.references/tigerbeetle/src/testing/storage.zig`
- `.references/tigerbeetle/src/testing/io.zig`
- `.references/tigerbeetle/src/testing/time.zig`
- `.references/tigerbeetle/src/testing/fuzz.zig`
- `.references/tigerbeetle/src/testing/cluster/state_checker.zig`
- `.references/tigerbeetle/src/testing/cluster/storage_checker.zig`
- `.references/tigerbeetle/src/testing/cluster/network.zig`

## Overall Read

VOPR is a purpose-built simulator for TigerBeetle, not a reusable DST library.
That is its strength. It can model VSR, TigerBeetle storage, checkpoint repair,
client replies, crash/restart behavior, upgrades, partitions, and liveness in
domain-specific detail.

Marionette should not copy that shape directly. Marionette should copy the
discipline:

- all nondeterminism goes through explicit simulator authorities,
- every seed expands into printed options,
- fault models are constrained by recoverability,
- safety and liveness are separate phases,
- checkers are first-class, not afterthoughts,
- event ordering is deterministic and visible,
- failures are replayable by seed and build identity.

## Lessons

### 1. Seed Is Necessary, Not Sufficient

VOPR accepts a seed, but it also logs the full option set derived from that
seed: replica counts, client counts, request probabilities, network delay,
partition probabilities, storage latencies, read/write fault probabilities,
crash/restart probabilities, and more.

Marionette decision: `RunFailure` carries run options, replay-visible tags,
and typed attributes, and `RunFailure.writeSummary` is testable. Future CLI
output must print the full expanded simulator profile, not just `seed`. Once
network and disk exist, every probability and budget must appear in attributes
and the failure report.

### 2. CI Seeds Can Be Meaningful

TigerBeetle's fuzz helper accepts either a numeric seed or a 40-character Git
commit hash, truncating the hash into a seed. That makes CI runs vary by commit
while remaining reproducible.

Marionette decision: keep `parseSeed` available for CLI layers. It accepts
decimal seeds and 40-character Git hashes, truncating hashes to the low 64
bits. This is a small adoption feature with high leverage for CI.

### 3. Profiles Beat One Giant Random Soup

VOPR has distinct option generators: swarm, lite, and performance. These modes
do different jobs. Lite looks mostly for crashes. Swarm exercises many fault
combinations. Performance uses a different shape and can simulate missing
replicas.

Marionette decision: `RunOptions.profile_name`, tags, and `RunAttribute` are
the first step. Introduce generated named simulation profiles before
multi-node work grows too large. Likely profiles:

- `smoke`: fast, low-fault, CI default.
- `swarm`: broad randomized fault exploration.
- `replay`: exact options from a failing run.
- `performance`: low-noise profile for throughput-style examples.

### 4. Safety And Liveness Are Different Phases

VOPR first runs under arbitrary failures to test safety. Then it transitions to
a liveness mode: choose a core, restart core replicas, heal core partitions,
disable core storage faults, and ask whether the system converges. This avoids
confusing "the environment is still adversarial" with "the system is stuck."

Marionette decision: do not bolt liveness onto safety checks as "no pending
events after N ticks." When liveness lands, it needs an explicit environment
transition: stop injecting some faults, define a fair/reachable core, then
check progress.

### 5. Event Loops Drain Ready Work Before Advancing Time

TigerBeetle's packet simulator and storage simulator both have a split between
`step()` and `tick()`. `step()` drains ready work at the current time. `tick()`
advances simulated time and probabilistically changes the environment.

Marionette decision: the scheduler should copy this conceptual split:

- drain all currently-ready deterministic work,
- then advance time or inject new timed faults,
- keep the tie-breaker stable and explicit.

This should replace the current Phase 0 "tick is just time movement" model
when we add scheduler/network/disk.

### 6. Network Faults Are Path State, Not Just Node State

TigerBeetle models a link for every source-target path. Each path has a queue,
filter, optional drop function, optional recording, capacity, clog state, and
delivery delay. Partitions compile down to link filters.

Marionette decision: design `Network` around path/link state. Node-level APIs
are ergonomic for users, but the simulator needs source-target path state for:

- asymmetric partitions,
- per-path capacity,
- path clogs,
- packet replay,
- per-command filtering,
- deterministic delivery ordering.

### 7. Faults Need Stability, Not Just Probability

VOPR's network partitions have partition/unpartition probabilities and
stability durations. Replica crashes and restarts have crash/restart
probabilities and stability durations. This prevents unrealistic flicker and
lets tests explore "long enough to matter" failures.

Marionette decision: every recurring fault type should have at least:

- probability,
- minimum duration or cooldown,
- scope,
- trace event when state changes.

A Bernoulli decision every tick is not enough.

### 8. Storage Faults Must Be Constrained By A Fault Model

TigerBeetle's simulated storage does not corrupt arbitrary bytes whenever it
feels like it. It tracks faulty sectors, write misdirection overlays, fault
eligibility by zone, crash faults on pending writes, and a cluster fault atlas
that distributes faults while preserving recoverability assumptions.

Marionette decision: the future `Disk` API should start narrower than
"randomly fail reads and writes." It needs a documented fault model with:

- corruption,
- IO errors,
- latency,
- crash during pending write,
- optional misdirection,
- explicit recoverability budget.

Without a fault model, disk simulation will produce either trivial failures or
unfair impossible worlds.

### 9. Checkers Are Separate Components

VOPR has state, storage, grid, manifest, and journal checkers. These are not
the workload. They encode independent truths about the cluster and storage.

Marionette decision: invariants should be first-class registered checkers, not
just user asserts sprinkled through scenarios. Even Phase 1 should have a tiny
checker API so examples grow around the right shape.

### 10. Human Failure Output Is A Product Feature

TigerBeetle's VOPR output is compact but information-dense: replica index,
event, role, status, view, checkpoint/commit, journal state, WAL state, sync
range, release, grid state, and pipeline state. That is not generic logging.
It is a domain debugging console.

Marionette decision: keep the machine trace stable, but plan for human summary
renderers per example/domain. The raw trace is for replay; the summary is for
debugging.

### 11. Assertions Multiply The Simulator

TigerBeetle leans hard on assertions and checkers. VOPR turns those assertions
into searchable counterexamples.

Marionette decision: examples and future user guidance should encourage
assertion-heavy simulated code and error-returning invariant checks. DST
without invariants is mostly expensive fuzzing.

### 12. Manual Replay Hooks Matter

TigerBeetle's packet simulator can record selected packets and later replay
them. This is separate from replaying the whole seed; it is a surgical tool for
unit tests and debugging.

Marionette decision: do not limit replay thinking to whole-run seeds. Once the
event model exists, support extracting small event schedules or packet
sequences from a failure and replaying them in a narrower test.

### 13. Fault Injection Can Be Domain-Aware

VOPR increases crash probability when a replica has pending writes. That is a
small but important idea: faults should target dangerous states, not only
uniform time.

Marionette decision: `buggify` and fault profiles should support contextual
weights. For example, disk crash probability can rise while writes are pending,
network drops can target quorum boundaries, and scheduler perturbation can
target retry/deadline windows.

### 14. Deterministic Time Can Still Model Bad Clocks

TigerBeetle's `TimeSim` models monotonic time and realtime offsets: linear,
periodic, step, and non-ideal drift. The simulator still owns time, but the
time authority can return imperfect clocks to the system under test.

Marionette decision: keep `World` as the single clock authority, but later add
node-local clock views with skew/drift models. Do not give each node an
independent uncontrolled clock.

## What Marionette Should Not Copy

- Do not copy VOPR's product-specific VSR/storage assumptions into the generic
  API.
- Do not expose a giant `World` to every component just because VOPR can use a
  purpose-built cluster harness.
- Do not require users to adopt TigerBeetle's logging shape. Marionette's trace
  needs stable generic structure first.
- Do not claim liveness support until there is an explicit liveness mode.
- Do not create unconstrained "chaos" disk faults without a recoverability
  model.

## Concrete Marionette Actions

Near-term:

- Expand the current named-check API into event-by-event invariant checks once
  a scheduler exists.
- Grow typed run attributes into generated simulation profiles.

Before network:

- Design network internals as source-target path state.
- Specify deterministic event ordering for ready packets with identical
  timestamps.
- Include partition stability and unpartition stability in the profile.

Before disk:

- Write a disk fault model doc.
- Start with latency, IO error, corruption, and crash-during-write.
- Define which faults are fair for single-node vs replicated examples.

Before liveness:

- Define what environment transition means.
- Define how a user marks the "core" or progress target.
- Keep safety and liveness failure kinds separate.
