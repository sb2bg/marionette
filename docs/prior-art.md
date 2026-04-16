# Prior Art

Marionette is not a new testing idea. It is an attempt to make deterministic
simulation testing natural for Zig services.

## FoundationDB

FoundationDB is the canonical example of deterministic simulation testing in
a production distributed database. Its simulation work is a major inspiration
for Marionette's seed-and-replay model.

Useful starting points:

- FoundationDB project: <https://www.foundationdb.org/>
- FoundationDB testing docs: <https://apple.github.io/foundationdb/testing.html>

## TigerBeetle

TigerBeetle's VOPR is the most important Zig-adjacent reference point. It
tests a replicated system in a deterministic single-threaded simulation and
uses aggressive engineering discipline to keep that simulation trustworthy.

Marionette's `tidy` linter is directly inspired by TigerBeetle's approach to
enforcing project rules in code.

Useful starting point:

- TigerBeetle docs: <https://docs.tigerbeetle.com/single-page/>

## Antithesis

Antithesis provides deterministic testing for arbitrary containerized
software using a different approach: a controlled execution environment
rather than a Zig library.

Marionette is not trying to be Antithesis. The shared idea is deterministic
replay; the implementation and adoption model are different.

Useful starting point:

- Antithesis: <https://antithesis.com/>

## Rust Ecosystem

Rust has several projects in adjacent territory:

- Shuttle.
- Turmoil.
- MadSim.

These projects show both the value of library-level simulation and the
integration challenges that appear when user code depends on a broader async
or runtime ecosystem.

## Writing

Phil Eaton's writeup is a good general introduction to deterministic
simulation testing:

- <https://notes.eatonphil.com/2024-08-20-deterministic-simulation-testing.html>

This writeup by Polar Signals achieving (mostly) deterministic testing in Go helps identify core tensions in the design space:

- <https://www.polarsignals.com/blog/posts/2024/05/28/mostly-dst-in-go>
