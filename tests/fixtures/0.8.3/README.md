# 0.8.3 compatibility evidence

The scenarios in `tests/compatibility_072.zig`, recaptured under the
`portable_v2` disk contract (disk model version 2). The tests compare every
byte of both artifact sets.

`../0.7.1` holds the same scenarios under `portable_v1` and is kept unchanged.
`tests/compatibility_072.zig` lists every expectation the contract change
altered, with its reason, and fails if any other line differs. A capsule
recorded under `portable_v1` decodes but is rejected for replay with
`error.IncompatibleDiskModel`; it replays only on its pinned build.

As with the 0.7.1 set, identity fields hold synthetic labels so the
comparison does not depend on target or optimization. These are wire-format
fixtures, not executable cross-build replay capsules. Do not regenerate them
to make a refactor pass; a semantic or format change needs its own planned
compatibility change and new fixtures.
