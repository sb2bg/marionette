# 0.7.1 compatibility evidence

Captured from commit `8fb0fa3` (v0.7.1), using the scenarios in
`tests/compatibility_072.zig`, Zig 0.16.0, Debug, aarch64-macos, before the 0.7.2
process/runner refactor. The tests compare every byte of both artifact sets.

- `process`: manual kill/restart, disk crash/reopen, automatic process dynamics,
  seed cutover, liveness transition, and managed cleanup with resource checks.
- `reduced`: property failure after action-group reduction, including disabled
  telemetry, causal spans, exact decision tape, and full failure identity.

The replay JSON contains the trace and typed decision tape as well as runtime
configuration. Identity fields deliberately contain synthetic fixture labels to
make serialization comparisons independent of target and optimization. These are
wire-format fixtures, **not** executable cross-build replay capsules. Actual
capsule tests use the running harness identity and reject mismatched dimensions.

These files should not be regenerated to make a refactor pass. A semantic or
format change requires its own planned compatibility change and new fixtures.
