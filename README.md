# Marionette

Deterministic simulation testing for Zig.

Marionette helps Zig services reproduce timing, randomness, and eventually
disk/network failures from a seed.

Same seed. Same trace. Same bug.

```zig
const std = @import("std");
const mar = @import("marionette");

fn scenario(world: *mar.World) !void {
    try world.tick();
    _ = try world.randomIntLessThan(u64, 1_000);
    try world.record("request.accepted id={}", .{42});
}

test "scenario is replayable" {
    var report = try mar.run(std.testing.allocator, .{
        .seed = 0xC0FFEE,
        .tick_ns = 1_000_000,
    }, scenario);
    defer report.deinit();

    switch (report) {
        .passed => |passed| try std.testing.expect(passed.trace.len > 0),
        .failed => |failure| {
            failure.print();
            return error.ScenarioFailed;
        },
    }
}
```

## Status

Phase 0. Time, seeded randomness, trace logging, replay checks, and named
world/state scenario checks are being built now. Run tags and typed attributes
are trace-visible so failing seeds can carry their expanded profile. Disk,
network, scheduling, shrinking, and time-travel debugging are planned, not
implemented.

The API is not stable. Do not use this in production yet.

## Try It

```sh
zig build test
```

## Why

Distributed systems bugs are hard because they depend on timing, ordering,
and failure. Traditional tests often find them by accident, if at all.

Deterministic simulation testing changes the loop: run the system in a
controlled world, save the seed and trace when it fails, replay the exact
execution until the bug is fixed.

Marionette is the Zig-native version of that idea: explicit interfaces,
explicit allocators, no runtime magic.

## Docs

- [Overview](docs/overview.md)
- [Architecture](docs/architecture.md)
- [Trace Format](docs/trace-format.md)
- [Run](docs/run.md)
- [BUGGIFY](docs/buggify.md)
- [Disk Fault Model](docs/disk-fault-model.md)
- [API](docs/api.md)
- [Determinism](docs/determinism.md)
- [Examples](docs/examples.md)
- [Roadmap](docs/roadmap.md)
- [Prior art](docs/prior-art.md)
- [TigerBeetle Lessons](docs/tigerbeetle-lessons.md)
- [Blog](docs/blog/README.md)

Current examples include a rate limiter and a tiny VOPR-inspired replicated
register showcase.

## Is This For Me?

Eventually, yes, if you are building a database, queue, storage engine,
consensus system, scheduler, replicated service, or anything where
correctness under failure matters more than feature velocity.

Probably not, if you are building a CRUD app, GUI, ML training system, or a
multi-threaded service you are not willing to structure around deterministic
interfaces.

## Installation

Not published yet. Phase 0 is source-only while the core API settles.

## License

MIT. See [LICENSE](LICENSE).
