# TigerBeetle Lessons

I spent a few days reading through TigerBeetle's VOPR: the simulator, the
packet and storage models, the cluster harness, the checkers, and the testing
docs. Not to copy it. The goal was to figure out what VOPR has learned about
deterministic simulation that Marionette should internalize before I start
writing scheduler, network, disk, invariant, and liveness code.

These notes are my own summary of public TigerBeetle material. TigerBeetle is
Apache-2.0, and none of the code or documentation below is copied. This is a
study pass and a list of lessons I want Marionette to carry.

If you want to follow along in the TigerBeetle source, the relevant files live
in [`tigerbeetle/tigerbeetle`](https://github.com/tigerbeetle/tigerbeetle) under
`docs/internals/vopr.md`, `src/vopr.zig`, and `src/testing/` (especially
`cluster.zig`, `packet_simulator.zig`, `storage.zig`, `time.zig`, `fuzz.zig`,
and the checkers under `cluster/`).

## The overall shape

VOPR is a purpose-built simulator for TigerBeetle. It isn't a reusable DST
library, and that's its strength. Because it only has to model VSR,
TigerBeetle's storage engine, checkpoint repair, client replies, crash and
restart behavior, upgrades, partitions, and liveness, it can do all of those in
domain-specific detail.

Marionette shouldn't imitate the shape. Marionette should imitate the
discipline:

- all nondeterminism flows through explicit simulator authorities,
- every seed expands into printed options,
- fault models are constrained by recoverability,
- safety and liveness live in separate phases,
- checkers are first-class components, not afterthoughts,
- event ordering is deterministic and visible,
- failures are replayable from the seed and the build identity alone.

## Lessons

### 1. A seed is necessary, not sufficient

VOPR accepts a seed, but it also prints the full option set derived from that
seed: replica counts, client counts, request probabilities, network delay,
partition probabilities, storage latencies, read and write fault
probabilities, crash and restart probabilities, and more.

Marionette already has `RunFailure` carrying run options, replay-visible tags,
and typed attributes, and `RunFailure.writeSummary` is testable. The CLI layer
still needs to print the full expanded profile, not just the seed. Once the
network and disk models exist, every probability and budget needs to show up
in both the attributes and the failure report.

### 2. CI seeds can be meaningful

TigerBeetle's fuzz helper accepts either a numeric seed or a 40-character Git
commit hash, truncating the hash into a seed. That lets CI runs vary by commit
while staying reproducible.

Marionette already does this through `parseSeed`, which handles decimal seeds
and 40-character hashes. It's a tiny feature with outsize leverage on CI
ergonomics, and I want to make sure any future CLI layer keeps it.

### 3. Profiles beat one giant random soup

VOPR has distinct option generators (swarm, lite, and performance), and each
does a different job. Lite is mostly looking for crashes. Swarm is trying to
exercise broad fault combinations. Performance uses a different shape entirely
and can simulate missing replicas.

Marionette already has `RunOptions.name`, tags, and `RunAttribute`,
but there are no named profiles yet. Before multi-node work gets heavy, I want
at least:

- `smoke`: fast, low-fault, CI default.
- `swarm`: broad randomized fault exploration.
- `replay`: exact options from a failing run.
- `performance`: low-noise profile for throughput-style examples.

### 4. Safety and liveness are different phases

VOPR first runs under arbitrary failures to test safety. Then it transitions
into a liveness phase: pick a core, restart the core replicas, heal core
partitions, disable core storage faults, and check whether the system
converges. This separates "the environment is still adversarial" from "the
system is stuck."

I don't want to bolt liveness onto safety checks as something like "no pending
events after N ticks." When liveness lands in Marionette, it needs an explicit
environment transition: stop injecting some faults, define a fair and
reachable core, then check progress.

### 5. Event loops drain ready work before advancing time

TigerBeetle's packet simulator and storage simulator both split `step()` from
`tick()`. `step()` drains ready work at the current time. `tick()` advances
simulated time and probabilistically changes the environment.

Marionette's current "tick is just time movement" model is fine for Phase 0,
but the scheduler should copy the split once network and disk arrive: drain
all currently-ready deterministic work, then advance time or inject new timed
faults, with a stable and explicit tie-breaker between simultaneous events.

### 6. Network faults live on paths, not nodes

TigerBeetle models a link for every source-target path. Each path has its own
queue, filter, optional drop function, optional recording, capacity, clog
state, and delivery delay. Partitions compile down to link filters.

That mental model is more powerful than "node is up / node is down." Designing
Marionette's network around path state is what lets you model asymmetric
partitions, per-path capacity, path clogs, packet replay, per-command
filtering, and deterministic delivery ordering. Node-level APIs are fine as an
ergonomic layer on top, but the internals need to be path-shaped from day
one. `docs/network.md` is the source of truth for Marionette's current
network model and the VOPR comparison.

### 7. Faults need stability, not just probability

VOPR's network partitions have partition and unpartition probabilities and
stability durations. Its packet simulator also clogs paths from the simulator
tick using a probability and duration distribution. Replica crashes and
restarts have crash and restart probabilities and stability durations. This
avoids unrealistic flicker and lets tests explore "long enough to matter"
failure windows.

Marionette's fault model should follow the same pattern. Every recurring
fault type needs at least a probability, a minimum duration or cooldown, a
scope, and a trace event when state changes. A Bernoulli decision every tick
isn't enough to find interesting bugs. For network specifically, the next
layer is a runtime `NetworkFaultOptions` profile separate from static topology.

### 8. Storage faults need a fault model

TigerBeetle's simulated storage doesn't just corrupt random bytes when it
feels like it. It tracks faulty sectors, write-misdirection overlays, fault
eligibility by zone, crash faults on pending writes, and a cluster-level fault
atlas that distributes faults while preserving recoverability assumptions.

That's why their disk tests find real bugs instead of drowning in impossible
worlds. Marionette's future `Disk` API needs to start narrower than "randomly
fail reads and writes" and grow from a documented model: corruption, IO
errors, latency, crash during pending write, optional misdirection, and an
explicit recoverability budget. `docs/disk-fault-model.md` is the source of
truth for the first Marionette version of that model: generic logical paths
and WAL recovery first, VOPR-style fault atlases later after more examples
justify the abstraction.

### 9. Checkers are separate components

VOPR has distinct checkers for state, storage, grid, manifest, and journal.
They aren't the workload. They encode independent truths about the cluster and
storage, and each one is its own file with its own job.

Marionette's invariants should be first-class registered checkers, not user
asserts sprinkled through scenarios. Even Phase 1 should have a tiny checker
API so the first real examples grow around the right shape.

### 10. Human failure output is a product feature

VOPR's output is compact but information-dense: replica index, event, role,
status, view, checkpoint and commit, journal state, WAL state, sync range,
release, grid state, pipeline state. That isn't generic logging. It's a
domain-specific debugging console.

The lesson for Marionette is to keep the machine trace stable, since replay
leans on it, but to plan for human summary renderers per example or domain.
The raw trace is for comparison; the summary is for the human trying to
understand what happened.

### 11. Assertions multiply the simulator

TigerBeetle leans hard on assertions and checkers, and VOPR is what turns
those assertions into searchable counterexamples. Each assertion is another
way the simulator can catch the moment things go wrong.

Marionette examples and user guidance should encourage assertion-heavy
simulated code and error-returning invariant checks. DST without invariants is
mostly expensive fuzzing.

### 12. Manual replay hooks matter

TigerBeetle's packet simulator can record selected packets and later replay
them. That's separate from replaying the whole seed. It's a surgical tool
for unit tests and debugging, not a full-run repro.

I don't want replay thinking in Marionette to be whole-run-only. Once the
event model exists, it should be possible to extract a small event schedule
or packet sequence from a failure and replay it in a narrower test.

### 13. Fault injection can be domain-aware

VOPR increases crash probability when a replica has pending writes. It's a
small thing, but the idea behind it is important: faults should target
dangerous states, not just uniform time.

Marionette's `buggify` and fault profiles should support contextual weights.
Disk crash probability rising while writes are pending, network drops biased
toward quorum boundaries, scheduler perturbation aimed at retry and deadline
windows. Uniform randomness misses most of the interesting failure modes.

### 14. Deterministic time can still model bad clocks

TigerBeetle's `TimeSim` models both monotonic time and realtime offsets, with
linear, periodic, step, and non-ideal drift. The simulator still owns time,
but it can hand nodes imperfect clocks.

Marionette should keep `World` as the single clock authority, but later add
node-local clock views with skew and drift. What I don't want is each node
holding an independent uncontrolled clock. That way lies the usual distributed
systems nightmare without any of the determinism upside.

### 15. The "production network" seam: TigerBeetle has two, Marionette has one

TigerBeetle's production transport is `MessageBusType(IO)`: a parametric type
where the IO backend is swappable. Their fuzz harness uses the *same*
MessageBus with a deterministic IO backend. VOPR uses a *separate* simpler
MessageBus (`testing/cluster/message_bus.zig`) that bypasses sockets entirely
and routes through an in-memory `Network` packet simulator. Two seams, chosen
deliberately: the parametric form keeps message_bus_fuzz exercising the real
bus code, and the separate VOPR form avoids paying the cost of simulating TCP
in software for full-cluster runs.

Marionette already has one seam at the right level: the `Endpoint(Message)`
vtable. The current production impl is a same-process FIFO; the simulation
impl is the deterministic packet bus. Both satisfy the same vtable. Reading
TigerBeetle, I considered switching to a parametric `Endpoint(Message, IO)`
shape and decided against it. The vtable already gives us the swappability;
adding a generic IO type would force every user to choose an IO backend at
the call site, which leaks library internals into user code.

The substantive lesson is what *fills* the production impl, not the seam
shape. TigerBeetle's MessageBus is a small product unto itself: length-prefixed
framing with header and body checksums, a refcounted preallocated message
pool, lazy outbound connect with seeded jittered backoff, async close that
drains in-flight operations before the socket goes away, peer-type inference
that lets a connection start unknown and resolve to replica or client, and
silent-drop send semantics on unreachable peers and full queues. Most of this
is general transport discipline, not VSR-specific.

For Marionette this means item 15 on the roadmap is not "wire up sockets" but
a sequence of independent primitives: framing, buffer pool, topology config,
single-peer transport, reconnect, bounded queues. Each ships on its own. The
done-signal is a cross-process parity test, not a socket primitive landing.

One concrete API consequence: TigerBeetle's bus drops messages silently on
full per-peer queues and unreachable peers. The application retries. Marionette
today returns `error.EventQueueFull` from sim's `send`. We should converge on
silent-drop in both impls; full queues become a trace-visible fault, not a
return value. This is the cleanest way to keep sim and prod behaviorally
identical at the call site. The full design lives in
`docs/network-production.md`.

## What not to copy

VOPR's product-specific VSR and storage assumptions shouldn't leak into
Marionette's generic API. `World` shouldn't become a giant object every
component holds just because VOPR can get away with a purpose-built cluster
harness. Marionette's users shouldn't have to adopt TigerBeetle's logging
shape; the trace needs stable generic structure first. And I don't want to
claim liveness support until there's an explicit liveness phase, or offer
unconstrained "chaos" disk faults without a recoverability story.

## What this implies for near-term work

A few things fall directly out of the study:

Once a scheduler exists, the current named-check API should grow into
event-by-event invariant checks, and typed run attributes should grow into
real named simulation profiles.

Before the network lands, I want the internals designed around source-target
path state, a specified deterministic event order for simultaneous ready
packets, and partition and unpartition stability built into the profile from
the start.

Before disk lands, the fault model doc needs to be written. Starting surface
should be latency, IO error, corruption, and crash-during-write, and each
example should be explicit about which faults are fair for single-node versus
replicated configurations.

Before liveness lands, I need to define what "environment transition" means,
how a user marks the core or progress target, and how to keep safety and
liveness failure kinds clearly separated in the output.

None of that is surprising in retrospect, but it's the kind of thing that's
much easier to bake in while the simulator is small than to retrofit once
users are depending on it.
