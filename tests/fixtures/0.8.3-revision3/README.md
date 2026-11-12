# 0.8.3 disk revision 3 compatibility evidence

The same scenarios as `../0.8.3`, retained under disk model revision 3.
Neither workload mixes torn writes with length changes or arms tracked crash
requests, so only the model revision and artifact disk identity change.
`tests/compatibility_072.zig` verifies that these are the only differences and
compares newly captured artifacts byte for byte with these fixtures.

The earlier candidate fixtures remain unchanged. Revision-2 capsules must
replay on their original pinned build. Synthetic identities make these
wire-format evidence, not permission for cross-build replay.
