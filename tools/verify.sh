#!/usr/bin/env bash
# Repository checks deliberately use Git's source inventory, not recursive fmt.
set -euo pipefail
cd "$(dirname "$0")/.."
zig_exe=${ZIG:-zig}
mode=${1:-full}
case "$mode" in
  fmt|quick|full) ;;
  *) echo "usage: $0 [fmt|quick|full]" >&2; exit 2 ;;
esac

# Include new source files while excluding ignored dependencies and generated
# files, including caches nested under tests/tidy_consumer. NULs preserve spaces.
git ls-files --cached --others --exclude-standard -z -- '*.zig' '*.zon' |
  xargs -0 "$zig_exe" fmt --check
git diff --check
if [[ "$mode" == fmt ]]; then exit 0; fi

"$zig_exe" build --summary all
if [[ "$mode" == quick ]]; then
  "$zig_exe" build test --test-timeout 5m --summary all
  exit 0
fi
for optimize in Debug ReleaseSafe ReleaseFast; do
  "$zig_exe" build test -Doptimize="$optimize" --test-timeout 5m --summary all
  "$zig_exe" build validate-xitdb validate-mailbox validate-ochi validate-dusty \
    validate-beanstalkz validate-pg validate-redis -Doptimize="$optimize" --test-timeout 5m --summary all
done
"$zig_exe" test src/fiber.zig -target x86_64-windows-gnu -OReleaseSafe -fno-emit-bin
"$zig_exe" build check-release-symbols --summary all
