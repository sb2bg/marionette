# A Graceful Shutdown That Only Worked Because of Thread Preemption

Marionette runs unmodified Zig libraries under a deterministic `std.Io`, so
when I sat down to test HTTP connection pooling I expected to find pool
bugs. I did find one, and it is a good one. But the bug I want to write
about is the second one, because it belongs to a class I find spooky. Code
that has never once worked correctly, and whose users cannot tell, because
thread preemption keeps rescuing it.

The system under test is dusty, a small HTTP/1.1 client/server library
written against Zig's injectable `std.Io`. That design choice is why any of
this is possible. Marionette can swap in a simulated network, a virtual
clock, and a cooperative scheduler without touching a line of dusty's code.
Everything below happened to the pinned dusty 0.1.0 under simulation, on
one seed, reproducibly.

## The appetizer: a connection pool that cannot recover

The scenario was simple. Make one keep-alive request so a connection goes
back into the client's pool. Kill the server process. Fetch again.

The fetch fails, as it should, the pooled connection is dead. Then retry.
And here, dusty does something quietly catastrophic. The retry fails with
the same `WriteFailed`, and so does the next one, and the next. The trace
shows why with a precision I have come to love. Marionette records an
`io.net.connect` event for every dial, and across three retries there are
zero of them. The client never opened a new connection. It re-acquired the
same corpse from the pool every time.

The mechanism is a one-line omission. dusty's fetch path releases
connections back to the pool on the error path, and the pool only discards
connections marked `closing`. Response-parsing failures set that flag.
Write failures never do. So a connection that died between requests gets
re-pooled, and because acquisition scans most-recently-used first, it
shadows any healthy path forward, forever.

Here is the kicker. I restarted the server through Marionette's process lifecycle
hooks, proved it reachable, and retried on the same client. Same failure.
A fresh client with an empty pool converged on its first attempt. In
production terms, restart your API server and every pooled dusty client
that had a connection open is bricked until someone recreates it. No
partition, no packet loss, no exotic schedule. Just a restart.

That finding took about an afternoon, and most of the afternoon was
writing the scenario, not finding the bug. This is the part of
deterministic simulation testing that I think people underrate. The bug
was not hiding. It reproduces on every seed. Nobody had pointed an oracle
at it.

## Then the world froze

The second scenario ended differently. The test process pinned a core at
99% CPU and never finished.

My first instinct was a virtual-time watchdog. Marionette scenarios run on
a virtual clock, so I spawned a harness task that sleeps five virtual
seconds and then dumps the trace tail. If something was looping in
simulated time, the watchdog would fire almost immediately in real time
and tell me where.

It never fired. That non-result was the single most informative
observation of the whole investigation. A cooperative scheduler advances
virtual time only when every task is blocked. My watchdog was starving,
which meant some task was running hot without ever reaching a suspension
point. Virtual time was not looping. It was frozen. And that ruled out
almost everything I had been imagining, because Marionette's deadlock
detector was silent too, and now I knew why. The detector fires when all
tasks are blocked, and one task was the opposite of blocked.

An `lldb` attach settled it in one backtrace.

```text
frame #0: Io.Event.waitTimeout at Io.zig:1828
frame #1: server.Server.listen at server.zig:163
```

Line 163 is inside dusty's graceful-shutdown drain.

```zig
while (true) {
    const remaining = self.active_connections.load(.acquire);
    if (remaining == 0) break;
    try self.last_connection_closed.waitTimeout(self.io, .{
        .duration = .{ .raw = std.Io.Duration.fromMilliseconds(100), .clock = .awake },
    });
}
```

Read it the way its author surely did. While connections remain, wait for
the next one to close, and re-check. The 100ms timeout even doubles as
dusty's documented shutdown contract, because `waitTimeout` returns
`error.Timeout` and the `try` propagates it out of `listen` when a
connection never drains. It looks correct. It reads correct.

The problem is `last_connection_closed`. It is a `std.Io.Event`, and
`std.Io.Event` latches. Once set, it stays set until someone resets it,
and nothing here ever resets it. `Event.waitTimeout` on a set event
returns immediately, by documented contract. So the drain has two modes.

- No connection has ever closed. The event is unset, the wait actually
  blocks, and after 100ms the timeout propagates. This is the tested,
  documented path.
- Any connection has ever closed. The event is set. The "wait" is a
  no-op. If a handler is still active, `remaining` never changes, and the
  loop spins at full speed with no suspension point, forever.

On any real server the second mode is the only mode, because some
connection has always closed by the time you shut down.

## Why nobody ever saw it

Here is the part that earns the title. On a preemptive runtime, this bug
is nearly invisible. The drain thread spins, but the OS keeps scheduling
the connection handlers anyway, they finish, `active_connections` hits
zero, and the loop exits. The observable symptom is that graceful
shutdown burns a core for its duration. Who profiles their server during
the last two seconds of its life?

Under a cooperative scheduler there is no OS to rescue you. The spinning
drain never yields, so the handler that would decrement the counter never
runs, so the counter never reaches zero, so the drain never yields. The
performance bug is revealed as the correctness bug it always was. This
loop's termination has only ever been guaranteed by preemption, which is
to say, by something outside the code.

There is a register-allocation-luck flavor to this that I keep coming
back to. The earlier post in that genre was about the compiler quietly
underwriting our correctness. This one is about the thread scheduler
doing the same. In both cases the code carried an unstated dependency on
machinery it never asked for, and the dependency only became visible when
the machinery was swapped out from under it.

And Marionette's own existing dusty shutdown test had been passing over
this bug the whole time, for a luck-shaped reason of its own. That
scenario shuts down while its only connection is still open, so no close
had ever latched the event, so the drain blocked properly. One scenario
to the left, deterministic wake ordering happened to let handlers exit
before the canceled accept loop resumed. The bug sat in the gap between
two tests that each missed it by one scheduling decision.

## What the simulator cannot see

I want to be honest about the uncomfortable lesson, because this
investigation exposed a blind spot in Marionette itself.

A hot loop with no suspension point is invisible from inside a
cooperative world. The deadlock detector cannot fire, because the task is
runnable. A watchdog task cannot report it, because nothing ever yields
to the watchdog. The trace cannot show it, because trace events are
emitted by code that runs, and only one piece of code is running. The
only observers that caught this were outside the process, `ps` showing
99% CPU and a debugger attaching cold.

So the fix for the scenario was to sidestep, not to detect. The pool
scenarios tear their server down with a process kill instead of a
graceful cancel, which is also the more honest model of the crash they
simulate. And the roadmap gained an item I would not have thought to
write down a week ago, a step budget between suspension points, so a task
that runs too long without yielding becomes a harness failure with a
name, instead of a frozen world. Antithesis solves this class with a
hypervisor that owns time itself. A library simulator has to settle for
detecting the symptom, but detecting it is worth doing.

Both dusty findings are written up with reproduction details in
Marionette's `FOUND_BUGS.md` as DUSTY-001 and DUSTY-002. The scenarios
that found them are ordinary validation code, about four hundred lines
including the byte-exact oracles, running the unmodified library. That is
the pitch, really. The pool bug reproduces on every seed and had been
waiting for anyone to look. The shutdown bug needed the scheduler swapped
out from under the code before it would show itself at all. One
afternoon, one seed, two bugs that ship in the same release. One always
happens, and one can never happen, until the runtime changes.
