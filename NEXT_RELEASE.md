# 0.7.1 release acceptance

Working branch: `feat/0.7.1` (based on post-0.7 main).
The Reduction and Explanation implementation is complete. The PostgreSQL and
Redis client validations are consolidated on this branch. Publication remains
subject to the final candidate gates below; the proposed follow-up milestones
and 1.0 criteria live in `ROADMAP.md`.

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
- [x] Seven pinned external validations in the three-optimization CI matrix.

Allocation-site stacks and generic resource tracking are explicitly future work
in the roadmap; no new production runtime or broad model extensions are needed.

## Final Candidate Verification Gates

- Run the 473 core/example tests and all seven external validation targets in
  Debug, ReleaseSafe, and ReleaseFast. The external targets are xitdb, mailbox,
  Ochi, Dusty, beanstalkz, pg.zig, and Redis: 45 external tests, 518 combined.
- Require green Linux and macOS jobs on the final candidate commit, including
  tidy, formatting, the disabled Win64 fiber compile check, and release-symbol
  isolation. Check whitespace locally and exclude generated/vendor sources from
  local formatting checks.
- Build documentation with strict MkDocs validation.
- Run `reduce-idempotency`: the reference seed 1234 reduces three groups to two
  in five attempts, retaining the property failure and reaching one-group
  minimality.

## Publication Gates

- [ ] Set package version, changelog heading, and install instructions to 0.7.1.
- [ ] Require green CI and Pages for the prepared release commit.
- [ ] Date the changelog, commit, and require green CI again.
- [ ] Tag and publish the dated commit, then verify the documented package fetch
      from a clean consumer.

Trace format 4 and the nonempty/unique property-ID requirement must remain
explicit in release notes. Old capsules require their matching pinned harness.

## Evidence and contracts

- `tests/reduction_explanation.zig`: checkpoints, fingerprint preservation,
  candidate budgets, minimized capsule replay, byte reduction, watchdog transport,
  artifact I/O and allocation failures, causal spans, process reopen and cleanup.
- `src/decision.zig`: reduction scratch ownership and transactional rollback.
- `src/scheduler.zig`: compact task-completion cycles and unowned-wait fallback.
- `examples/reduction.zig`: executable request/duplicate failure reduction.
- `docs/reduction-and-explanation.md`: API, scope, ownership, minimality, artifact,
  and diagnostic contracts.
- `validation/pg_client.zig` and `validation/redis_client.zig`: scripted-peer
  client framing, recovery, and retry characterization with same-seed replay.
