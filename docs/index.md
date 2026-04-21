# Marionette

Deterministic simulation testing for Zig.

Marionette helps Zig services reproduce timing, randomness, and eventually
disk/network failures from a seed.

Make rare bugs repeat themselves.

## Status

Marionette is in Phase 0. Time, seeded randomness, trace logging, replay
checks, named world/state scenario checks, and trace-visible run context are
being built now. An unstable deterministic network sketch exists for examples.

Disk, a real scheduler, shrinking, and time-travel debugging are planned, not
implemented. The API is not stable, and Marionette is not ready for production
use.

## Start Here

- [Overview](overview.md)
- [Determinism](determinism.md)
- [Run](run.md)
- [Network Model](network.md)
- [API](api.md)
- [Roadmap](roadmap.md)

## Blog

- [Why deterministic replay in Zig is harder than it sounds](blog/why-deterministic-replay-in-zig-is-harder-than-it-sounds.md)

## Try It

```sh
zig build test
```
