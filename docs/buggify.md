# BUGGIFY

BUGGIFY is Marionette's fault-injection hook. Marionette decides whether a
hook fires; user code owns what that means for the domain.

The Phase 0 API lives on `Env`:

```zig
if (try env.buggify(.drop_packet, .percent(20))) {
    return error.PacketDropped;
}
```

`ProductionEnv.buggify` always returns `false`. `SimulationEnv.buggify` draws
through the world's single PRNG according to the supplied `BuggifyRate` and
records `buggify hook=<name> rate=<n>/<d> roll=<value> fired=<bool>` in the
trace. Invalid runtime rates return `error.InvalidRate` before any random draw
or hook trace event.

Users can call `buggify` because application code knows domain-specific fault
points a generic simulator cannot infer. A hook can guard behavior such as
dropping a packet, delaying a response, simulating a disk write error, or
forcing a retry path. Marionette controls the randomness, trace output, and
production behavior.

## Worked Fault Hook

Source: [`examples/buggify_fault_hook.zig`](https://github.com/sb2bg/marionette/blob/main/examples/buggify_fault_hook.zig)

```zig
pub fn sendPacket(env: anytype, packet_id: u64) !void {
    const latency_ns = try env.random().intLessThan(mar.Duration, 1_000);
    env.clock().sleep(latency_ns);

    if (try env.buggify(.drop_packet, .percent(20))) {
        return SendError.PacketDropped;
    }

    _ = packet_id;
}
```

This is intentionally not "just a random number." The random decision is
Marionette's job. The packet drop is the user's domain behavior.

## Open Requirements

BUGGIFY still needs to specify:

- The hook id type. Prefer a small enum or typed comptime tag over arbitrary
  strings in hot paths.
- Whether hook probabilities are configured only at call sites or also by a
  central scenario fault profile.
- Whether an expanded options API is needed once hooks carry more context.
- Whether the decision is traced by default.
- How hook decisions draw from the world's single PRNG.
- How production mode disables individual hooks at comptime.
- How tests assert that production branches still fold away.
