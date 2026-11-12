# 0.10.0 compatibility evidence

The scenarios in `tests/compatibility_072.zig`, recaptured with trace format
version 5, which adds `site=<choice site>` to every `world.random_*`
decision event. The tests compare every byte of both artifact sets, and check
that removing the site fields and restoring the version header reproduces
`../0.8.3-revision3` exactly. The fixtures retain disk revision 3 shipped
in 0.8.3; only the trace version and choice-site fields change in 0.10.

Identity fields hold synthetic labels, so these are wire-format fixtures, not
executable cross-build replay capsules. Do not regenerate them to make a
refactor pass; a semantic or format change needs its own planned
compatibility change and new fixtures.
