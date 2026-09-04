# 0.7.0 Pre-release Review — 2026-09-04

This document records the local review before publication. Hosted release
checks are recorded in GitHub Actions for the release commit.

## Verdict

The implementation is a release candidate for the documented 0.7 replay
foundation scope. Do not tag it until CI passes on the final branch revision,
including Linux runtime tests and external validations. Local Linux
cross-compilation is not a substitute for executing the watchdog/fiber paths.

This is not the entire former “Replay, Reduce, Explain” roadmap. Decision
reduction, richer property lifecycles, causal spans, automatic artifact
directories, and cross-version migration remain future work. The roadmap now
separates those items from the implemented release scope.

## Reviewed Work

Reviewed the existing `feat/0.7.0` commits `2a07abe`, `1f751b3`, and `9c77c8e`:
strict superdense schedules, application randomness routing, pre-worker schedule
validation, and release documentation. Kept their scheduled stream and
transaction semantics. Integrated the in-progress decision-tape and resource
check work from the original checkout, then implemented all five items in
`ARCHITECTURE_REVIEW.md` on the feature branch.

The four original audit defects now have ordinary regression tests. Self-review
also fixed file-lock cancellation ownership, direct-rename lock aliasing after
old-path reuse, disabled network loss consuming
choices, unexpected watchdog worker exits, and inferred run-name storage.

The final ownership review checked configuration lifetime, byte tapes and their
clones, all report outcome pairings, worker result transport, and malformed
capsules. Simulation options come directly from the report, so callers cannot
accidentally attach a different simulation configuration while encoding it.

## Seeds And Durable Replay

It is correct for seed schedules to remain positional exploration controls.
An extra earlier random call changes later microsteps, so persisting only a
seed/cutover list cannot make the resulting execution durable.

0.7 now also provides versioned replay capsules with actual choices, including
application random bytes, configuration, trace, failure identity, and pinned
build/SUT/toolchain/target/model identity. Replay checks compatibility and each
semantic boundary, and verifies the complete trace and outcome. Callers must
retain the matching executable/source/dependencies and application input and
supply meaningful build and workload identifiers. Arbitrary cross-version
replay is deliberately rejected rather than silently drifting.

Completed watchdog workers carry full tapes. Terminated workers have an
explicitly incomplete tape and cannot be encoded as durable capsules. The
infallible `std.Io.random` interface latches replay divergence for the runner to
report after application code returns; watchdog containment remains necessary
for code that never returns or yields.

## Compatibility Changes

- Trace format advances to version 3; old seed traces are not byte-compatible.
- The unused public `NetworkOptions` name is removed. Use
  `World.SimulateOptions.network` / `SimNetworkOptions`.
- New `worker_crashed` failure kind and watchdog `result_capacity` bound.
- Capsules and decision semantics begin at version 1; persisted artifacts need
  the exact supported build/workload identity.
- Windows root support remains out of scope; the disabled Win64 fiber path
  still compiles. The optional disk identity-inspection hook is implemented by
  SimDisk; custom disks without it retain the cached adapter contract.

## Validation

Validation used Zig 0.16.0 on AArch64 macOS. All local checks passed.

| Check | Result |
| --- | --- |
| Core tests, Debug / ReleaseSafe / ReleaseFast | 446 / 446 passed in each mode, including tidy and capability validations. |
| Five pinned external validations, all three modes | 37 / 37 passed in each mode: xitdb (11), mailbox (3), ochi (1), dusty (16), beanstalkz (6). |
| Combined suite and external matrix | 483 / 483 passed in each mode. |
| Allocation-failure checks | Passed for owned tape/diagnostic cloning, capsule decoding, and all report outcome pairings. |
| Capsule and shared-file regressions | Passed in all three modes, including byte override with a different seed, nonfinite floats, and direct-rename identity locks. |
| Bounded seed sweep | 100 seeds per scenario, ReleaseSafe: passed. |
| Linux root cross-compilation | x86_64-linux-gnu, ReleaseSafe: passed (compile only). |
| Disabled Windows fiber path | x86_64-windows-gnu, ReleaseSafe: passed (compile only). |
| Build / release symbols | Passed; no simulation-only symbols in the release probe. |
| Formatting / diff whitespace / docs | Passed; strict MkDocs build passed. |

The ordinary suite intentionally prints a planted failure while testing failure
reporting. The build exit status is zero and the aggregate summary reports all
tests passing; that diagnostic is not a failed gate.

Reproduce the main matrix with:

```sh
zig build test validate-xitdb validate-mailbox validate-ochi validate-dusty validate-beanstalkz -Doptimize=Debug --test-timeout 5m
zig build test validate-xitdb validate-mailbox validate-ochi validate-dusty validate-beanstalkz -Doptimize=ReleaseSafe --test-timeout 5m
zig build test validate-xitdb validate-mailbox validate-ochi validate-dusty validate-beanstalkz -Doptimize=ReleaseFast --test-timeout 5m
zig build seed-sweep -Doptimize=ReleaseSafe -Dseed-sweep-count=100
```

The final metadata serialization changes were additionally rerun through the
complete core matrix. No remaining release-blocking source defect was found in
this review. Linux execution and final-revision hosted CI remain unverified
locally; publishing/tagging has not been performed.
