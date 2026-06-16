# Releasing Marionette

Marionette releases are source tags. Prepare the release commit completely
before creating the tag so package consumers, documentation, and CI all refer
to the same tree.

## Release Candidate

1. Set `build.zig.zon` to the intended version.
2. Change the changelog heading to `vX.Y.Z - Unreleased` and summarize every
   user-visible change since the previous tag.
3. Point README and documentation install commands at `vX.Y.Z`.
4. Run formatting and `git diff --check`.
5. Run the Debug, ReleaseSafe, and ReleaseFast test and validation matrix.
6. Push the release commit and require green CI and Pages builds.

Do not create the tag while any advertised validation or supported-platform
job is failing.

## Publish

After the release commit is green:

1. Replace `Unreleased` in the changelog heading with the release date.
2. Commit and push that date-only change, then require green CI again.
3. Create an annotated `vX.Y.Z` tag at the dated release commit.
4. Push the tag.
5. Create a GitHub Release from the tag using the changelog section as the
   release notes.
6. Verify the documented `zig fetch` command from a clean temporary consumer.
