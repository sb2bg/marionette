# BUGGIFY

BUGGIFY is Marionette's fault-injection hook: a user writes a branch that can
fire in simulation, while production builds erase it when the hook is disabled
at comptime.

The Phase 0 API lives on `Env`:

```zig
if (try env.buggify(.drop_packet)) return error.PacketDropped;
```

`ProductionEnv.buggify` and envs made with `ProductionEnvWith` always return
`false`. `SimulationEnv.buggify` draws through the world's single PRNG and
records `buggify hook=<name> fired=<bool>` in the trace.

Users can call `buggify` because application code knows domain-specific fault
points a generic simulator cannot infer. Marionette controls the randomness,
trace output, and production behavior.

## Worked Shape

Source: [`examples/buggify_zero_cost.zig`](https://github.com/sb2bg/marionette/blob/main/examples/buggify_zero_cost.zig)

```zig
const Mode = enum { production, simulation };
const Hook = enum { drop_packet };

fn Sim(comptime mode: Mode) type {
    return struct {
        const Self = @This();

        inline fn buggify(_: *Self, comptime hook: Hook) bool {
            _ = hook;
            return switch (mode) {
                .production => comptime false,
                .simulation => true,
            };
        }
    };
}

export fn send_packet_prod() u32 {
    var sim: Sim(.production) = .{};
    if (sim.buggify(.drop_packet)) return 0;
    return 1;
}

export fn send_packet_baseline() u32 {
    return 1;
}
```

The production branch must compile to the same code as the baseline.

## Local Check

Command:

```sh
zig build-obj -O ReleaseFast examples/buggify_zero_cost.zig \
  -femit-bin=.zig-cache/buggify_zero_cost.o
objdump -d .zig-cache/buggify_zero_cost.o
nm -m .zig-cache/buggify_zero_cost.o
```

Observed on Darwin arm64:

```text
.zig-cache/buggify_zero_cost.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
       0: a9bf7bfd     	stp	x29, x30, [sp, #-0x10]!
       4: 910003fd     	mov	x29, sp
       8: 52800020     	mov	w0, #0x1                ; =1
       c: a8c17bfd     	ldp	x29, x30, [sp], #0x10
      10: d65f03c0     	ret
```

The symbol table shows both exported functions share the same address:

```text
0000000000000000 (__TEXT,__text) external _send_packet_baseline
0000000000000000 (__TEXT,__text) external _send_packet_prod
```

That is the bar for Marionette's real BUGGIFY API: disabled production hooks
must fold away, not become cold branches.

## Real API Requirements

When implemented, BUGGIFY should specify:

- The hook id type. Prefer a small enum or typed comptime tag over arbitrary
  strings in hot paths.
- The probability model.
- Whether the decision is traced by default.
- How hook decisions draw from the world's single PRNG.
- How production mode disables individual hooks at comptime.
- How tests assert that production branches still fold away.
