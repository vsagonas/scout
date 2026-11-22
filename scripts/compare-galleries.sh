#!/bin/bash
# Proves that pictures did not change between two builds: renders the same gallery prefixes with a BASELINE build and a CANDIDATE build, back to
# back, each twice, and compares them pixel by pixel (scripts/compare-pictures.swift). A pixel that changes between two renders of the SAME
# build (a clock, a date, an animation) is masked; every other difference is reported.
# Usage: scripts/compare-galleries.sh <baseline Scout.app> <candidate Scout.app> <out folder> <prefix> [prefix ...]
#   The look comes from the caller's environment and is the same for all four renders: SCOUT_8BIT, SCOUT_PRESET, SCOUT_SCALE, SCOUT_LANG.
#   Animations are rendered calm (SCOUT_REDUCE_MOTION=1) so nothing is caught in the middle of a move. A spot that changes by itself is
#   masked 12 pixels wider on each side (COMPARE_GROW; the pixel faces blink and glance).
# Nothing shows on the screen. Exit 0 when nothing differs outside the masks and no picture is gone; new pictures are listed, not counted.
set -uo pipefail
[ "$#" -ge 4 ] || { sed -n 2,8p "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_APP="$1"; CAND_APP="$2"; OUT="$3"; shift 3
for app in "$BASE_APP" "$CAND_APP"; do
  [ -x "$app/Contents/MacOS/Scout" ] || { echo "No build at $app" >&2; exit 64; }
  if codesign -d --entitlements - "$app" 2>/dev/null | /usr/bin/grep -q "com.apple.security.app-sandbox"; then
    echo "Refusing: $app is the sandboxed edition; pictures are rendered with the development edition only." >&2; exit 64
  fi
done
mkdir -p "$OUT"
export SCOUT_REDUCE_MOTION=1
# The comparison is compiled once (optimised): as a script it would take minutes on a few hundred pictures.
TOOL="$OUT/.compare-pictures"
swiftc -O -o "$TOOL" "$ROOT/scripts/compare-pictures.swift" || { echo "Could not compile scripts/compare-pictures.swift" >&2; exit 70; }
STATUS=0
for prefix in "$@"; do
  for run in base-1 base-2 cand-1 cand-2; do
    case "$run" in base-*) app="$BASE_APP";; *) app="$CAND_APP";; esac
    dir="$OUT/$prefix/$run"
    mkdir -p "$dir" && find "$dir" -maxdepth 1 -type f \( -name '*.png' -o -name 'gallery.txt' \) -delete
    # Each render has its own, empty settings domain, so no render inherits another one's look.
    domain="com.vsag.Scout.automation.compare"
    defaults delete "$domain" >/dev/null 2>&1 || true
    SCOUT_DEFAULTS_SUITE="$domain" SCOUT_APP="$app" "$ROOT/scripts/gallery.sh" "$prefix" "$dir" >/dev/null 2>&1 || { echo "RENDER FAILED  $prefix ($run)"; STATUS=1; }
  done
  echo "== $prefix"
  "$TOOL" "$OUT/$prefix/base-1" "$OUT/$prefix/cand-1" --stable "$OUT/$prefix/base-2" --stable2 "$OUT/$prefix/cand-2" --grow "${COMPARE_GROW:-12}" --diff "$OUT/$prefix/diff" || STATUS=1
done
exit "$STATUS"
