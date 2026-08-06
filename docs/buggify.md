# BUGGIFY

BUGGIFY is Marionette's fault-injection hook. Marionette decides whether a
hook fires; user code owns what that means for the domain.

The API lives on `Env`:

```zig
if (try env.buggify(.drop_packet, .percent(20))) {
    return error.PacketDropped;
}
```

Production envs should construct `Env` with buggify disabled, so
`env.buggify` always returns `false`. Simulation envs returned by
`world.simulate` draw through `env.io()` into the world's single PRNG according
to the supplied `BuggifyRate` and record
`buggify hook=<name> rate=<n>/<d> roll=<value> fired=<bool>` in the trace.
Invalid runtime rates return `error.InvalidRate` before any random draw or
hook trace event.

Use `buggify` for domain-specific fault points such as dropping a packet,
delaying a response, returning a write error, or forcing a retry. Marionette
controls the random choice, trace event, and production behavior.

## Worked Fault Hook

```zig
pub fn sendPacket(env: anytype, packet_id: u64) !void {
    const io = env.io();
    var source: std.Random.IoSource = .{ .io = io };
    const latency_ns = source.interface().intRangeLessThan(u64, 0, 1_000);
    try std.Io.sleep(io, .fromNanoseconds(latency_ns), .awake);

    if (try env.buggify(.drop_packet, .percent(20))) {
        return SendError.PacketDropped;
    }

    _ = packet_id;
}
```
