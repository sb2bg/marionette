#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <release-binary>" >&2
  exit 2
fi

binary=$1
if [ ! -f "$binary" ]; then
  echo "release symbol check: binary not found: $binary" >&2
  exit 2
fi

tmp_dir=${TMPDIR:-/tmp}/marionette-release-symbols.$$
mkdir -p "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

strings_out=$tmp_dir/strings.txt
symbols_out=$tmp_dir/symbols.txt
matches_out=$tmp_dir/matches.txt

strings -a "$binary" >"$strings_out"
: >"$symbols_out"

if command -v nm >/dev/null 2>&1; then
  nm -a "$binary" >>"$symbols_out" 2>/dev/null || true
fi

if command -v readelf >/dev/null 2>&1; then
  readelf --symbols --wide "$binary" >>"$symbols_out" 2>/dev/null || true
fi

pattern='(^|[^[:alnum:]_])(SimDisk|SimClock|SimControl|World\.simulate|SimulationAlreadyCreated|simulateAllocationFailureSweep|sim_vtable|sim[A-Z][[:alnum:]_]*|buggify hook=|disk\.fault|disk\.crash_write|network\.lossiness|network\.partition|network\.heal)([^[:alnum:]_]|$)'

: >"$matches_out"
if grep -E "$pattern" "$strings_out" >"$tmp_dir/string-matches.txt"; then
  {
    echo "raw binary strings:"
    sed -n '1,40p' "$tmp_dir/string-matches.txt"
  } >>"$matches_out"
fi

if [ -s "$symbols_out" ] && grep -E "$pattern" "$symbols_out" >"$tmp_dir/symbol-matches.txt"; then
  {
    echo "symbol table:"
    sed -n '1,40p' "$tmp_dir/symbol-matches.txt"
  } >>"$matches_out"
fi

if [ -s "$matches_out" ]; then
  echo "release symbol check failed: simulation-only symbols or trace strings leaked into $binary" >&2
  cat "$matches_out" >&2
  exit 1
fi

echo "release symbol check passed: no simulation-only symbols found in $binary"
