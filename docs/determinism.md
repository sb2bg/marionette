# Determinism Contract

For a fixed build, target, configuration, initial seed, seed schedule, and
application input, Marionette must produce the same trace and outcome.

## Controlled Inputs

Simulation behavior may depend on:

- the configured initial seed, seed schedule, and virtual start time;
- typed simulator options and fault profiles;
- application input supplied by the harness;
- deterministic `std.Io` time, randomness, files, network, and task behavior;
- explicit harness actions through `Control`.

Simulated code must not consult wall time, host randomness, ambient process
state, host threads, global allocator singletons, or unordered/address-bearing
data when those values affect behavior or traces.

## Replay Check

`runSimCase` executes every case twice, including failing cases. The first
ordinary execution records a typed semantic decision tape; the second consumes
it exactly and still must reproduce the same trace. Matching failures require
the same kind, error/check identity, and trace. A changed decision boundary is
`replay_diverged`; a pass/fail split or other difference is a determinism leak.

`expectSimFuzz` derives independent seeds and applies the same twice-run check
to each. Large campaigns run in the nightly seed sweep.

## Randomness

Harness and model choices use the world's scheduled PRNG. Application
algorithms should draw through `std.Random.IoSource` over `Env.io()`. Harnesses
and model code use the traced `World.randomU64`, `World.randomBool`,
`World.randomIntLessThan`, or `World.randomBytes` methods.

An optional seed schedule resets the PRNG before the first traced random call
at or after a superdense `(sim_time_ns, microstep)` point. `microstep` starts at
zero at each simulated timestamp and counts successfully committed traced
random calls, not internal PRNG words. One `Io.random` call therefore advances
one microstep regardless of buffer length. If no random call occurs at the
scheduled point, the cutover is applied before the next later call; multiple
due cutovers are applied in schedule order.

Seed schedules are exact only for the same build and configuration. They are a
positional control surface, not a durable cross-version replay artifact:
inserting, removing, or reordering an earlier random call can move every later
microstep. Durable replay requires semantic decision-site identities and
recorded selected values rather than only a PRNG reset position.

Disabled probabilistic faults consume no random values, so an already-disabled fault adds no positional noise. Enabling or disabling
a previously active fault can change later positions in the shared stream.

Scheduler, network, disk, allocation, automatic-process choices, and application
`std.Io` random bytes have tape entries. Application workloads participate when
they draw through these authorities. Versioned replay capsules persist the
exact decisions for a pinned build and workload; see
[Decision Tapes And Replay Capsules](decision-tapes.md).

## Time And Scheduling

Simulated time begins at `start_ns` and changes only through deterministic
clock/scheduler operations. Cooperative tasks run at modeled suspension
boundaries. Host scheduling is outside the contract.

The optional worker watchdog deliberately observes host monotonic time to
contain a task that never returns to the cooperative scheduler. Its timeout is
a liveness classification, not a simulated input: traces contain the configured
bounds and the stable classification, never the observed wall-clock timestamp.
Replay requires both isolated executions to produce the same failure identity.
Exact traces still match directly; when host timing cuts off two watchdog
failures after different event counts, the completed event stream from one run
must be a byte prefix of the other. A divergence inside their shared prefix
remains a determinism mismatch.

## Trace Stability

Traces use global event indexes and stable scalar fields. They must not contain
addresses, wall-clock timestamps, unordered iteration, or arbitrary debug
formatting. Dynamic text is percent-escaped. Semantic trace changes require a
format or model-version decision rather than silently updating snapshots.

## Tidy Gate

The AST-based tidy scan rejects known ambient host authorities in simulator,
examples, tests, and validation code. It ignores comments and strings and
supports narrow per-pattern exemptions for composition roots.

Tidy is a guardrail, not a proof. Review is still required for nondeterminism
introduced through caller data, unstable iteration, foreign libraries, or
unmodeled resource access.
