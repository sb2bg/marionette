# Reduction and Explanation release acceptance — complete

Working branch: `feat/next-release-properties` (based on post-0.7 main).
This checklist covers the unnumbered Reduction and Explanation release target
following 0.7.0. The roadmap now advances to the subsequent 0.8 Guided Exploration
campaign work. Release numbering and publication remain separate release tasks.

- [x] Stable property IDs and initialization/scenario lifecycle checks.
- [x] Explicit checkpoints; caught property failures remain fatal and replayable.
- [x] Decision/action-group reduction preserving a stable failure fingerprint;
      bounded attempts and a fresh exact-replay-verified executable capsule.
- [x] Causal references and operation spans on the narrow Recorder capability.
- [x] Compact deadlock-cycle diagnostics for modeled wait dependencies.
- [x] Caller-owned host I/O artifact directories integrated with runSimCase;
      metadata, traces, capsule, and useful incomplete-failure diagnostics.
- [x] Harness-owned typed process restart/reopen lifecycle helper.
- [x] End-to-end examples, ownership/failure tests, contracts, roadmap/changelog.
- [x] Debug/ReleaseSafe/ReleaseFast, external corpus, tidy/format, target/symbol gates.

Allocation-site stacks and generic resource tracking are explicitly future work
in the roadmap; no new production runtime or broad model extensions are needed.

## Verification

- 470/470 tests pass in Debug, ReleaseSafe, and ReleaseFast.
- All five external validation targets pass in all three modes (37 tests per mode):
  xitdb, mailbox, Ochi, Dusty, and beanstalkz.
- Tidy, tracked/new source formatting, and whitespace checks pass.
- Linux x86_64 ReleaseSafe root-test compilation and the disabled Win64 fiber
  compile check pass; release-symbol isolation passes.
- Strict MkDocs build passes.
- `reduce-idempotency` reduces three groups to two in five candidate attempts,
  retaining the same property failure and reaching one-group minimality.

## Evidence and contracts

- `tests/reduction_explanation.zig`: checkpoints, fingerprint preservation,
  candidate budgets, minimized capsule replay, byte reduction, watchdog transport,
  artifact I/O and allocation failures, causal spans, process reopen and cleanup.
- `src/decision.zig`: reduction scratch ownership and transactional rollback.
- `src/scheduler.zig`: compact task-completion cycles and unowned-wait fallback.
- `examples/reduction.zig`: executable request/duplicate failure reduction.
- `docs/reduction-and-explanation.md`: API, scope, ownership, minimality, artifact,
  and diagnostic contracts.
