# Determinism Contract

For a fixed build, target, configuration, seed, and application input,
Marionette must produce the same trace and outcome.

## Controlled Inputs

Simulation behavior may depend on:

- the configured seed and virtual start time;
- typed simulator options and fault profiles;
- application input supplied by the harness;
- deterministic `std.Io` time, randomness, files, network, and task behavior;
- explicit harness actions through `Control`.

Simulated code must not consult wall time, host randomness, ambient process
state, host threads, global allocator singletons, or unordered/address-bearing
data when those values affect behavior or traces.

## Replay Check

`runSimCase` executes every case twice, including failing cases. Matching
failures require the same kind, error/check identity, and trace. A pass/fail
split or different failure is reported as a determinism leak.

`expectSimFuzz` derives independent seeds and applies the same twice-run check
to each. Large campaigns run in the nightly seed sweep.

## Randomness

Harness and model choices use the world's seeded PRNG. Application algorithms
should draw through `std.Random.IoSource` over `Env.io()`. Direct
`World.unsafeUntracedRandom` draws are deterministic today but are not recorded
as individual decisions; avoid them in durable replay-sensitive code.

Disabled probabilistic faults consume no random values, so toggling one off
does not shift unrelated choices.

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
