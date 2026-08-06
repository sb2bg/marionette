# Examples

The examples are executable scenarios, not alternate APIs. Start with the
smallest example covering the boundary you need.

## Canonical Examples

| Example | Demonstrates |
| --- | --- |
| [`retry_queue.zig`](https://github.com/sb2bg/marionette/blob/main/examples/retry_queue.zig) | Virtual time, retry races, named checks, and a planted stale-ack bug |
| [`kv_store.zig`](https://github.com/sb2bg/marionette/blob/main/examples/kv_store.zig) | `std.Io.File`, WAL durability, crash recovery, allocation, and `Recorder` |
| [`std_io_net_kv.zig`](https://github.com/sb2bg/marionette/blob/main/examples/std_io_net_kv.zig) | Fixed-frame codecs shared by host and simulated `std.Io.net` paths |
| [`replicated_register.zig`](https://github.com/sb2bg/marionette/blob/main/examples/replicated_register.zig) | Experimental typed endpoints, loss, partitions, and quorum checks |
| [`durable_broadcast.zig`](https://github.com/sb2bg/marionette/blob/main/examples/durable_broadcast.zig) | Combined disk, network, and process failure modeling |

Smaller focused demonstrations cover allocation pressure, idempotency,
strict WAL-record decoding, and a typed toy protocol.

## Run One

```sh
zig build run-example -- retry-queue --seed 12648430 --summary
zig build run-example -- kv-store-bug --seed 12648430 --expect-failure
zig build run-example -- replicated-register --trace
```

The CLI prints its current scenario names when invoked without a valid
scenario.

## Reuse The Shape

Application code should accept the narrow capabilities it needs. A storage
component commonly accepts `std.Io`, a root `std.Io.Dir`, and `mar.Recorder`.
Its simulator initializer obtains those values from `mar.Sim`; production can
provide host values directly.

Keep fault injection and assertions in scenario code through `case.control()`.
Do not pass `Control` into the application merely to make an example shorter.
