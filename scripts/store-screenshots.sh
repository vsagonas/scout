#!/bin/bash
# Renders the Mac App Store screenshots (gallery items "store-*", 2880 x 1800, light + dark) and writes them,
# flattened to RGB, into store/screenshots/. Usage: scripts/store-screenshots.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RAW="$(mktemp -d "${TMPDIR:-/tmp}/scout-store.XXXXXX")"
trap 'rm -rf "$RAW"' EXIT
scripts/build-app.sh debug
# The listing is English (U.S.): render with the US locale ("16.4 GB", "9:30 AM"), whatever the Mac is set to.
# Same launch and time limit as scripts/gallery.sh, plus the locale arguments.
render() {
  rm -rf "$RAW" && mkdir -p "$RAW"
  build/Scout.app/Contents/MacOS/Scout --gallery "$RAW" --only store -AppleLocale en_US -AppleLanguages '(en-US)' &
  local pid=$!
  for _ in $(seq 1 480); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "Render timed out after 240 s" >&2; fi
  wait "$pid" 2>/dev/null || true
}
# Other scripts (live.sh) sometimes quit every running Scout, which cuts a render short: retry until all 16 images exist (8 frames, light and dark).
COUNT=0
for attempt in 1 2 3 4 5 6; do
  render
  COUNT=$(ls "$RAW"/store-*.png 2>/dev/null | wc -l | tr -d ' ')
  [ "$COUNT" -eq 16 ] && break
  echo "Render $attempt gave $COUNT of 16 images; trying again." >&2
done
if [ "$COUNT" -ne 16 ]; then echo "Expected 16 store images, got $COUNT" >&2; exit 1; fi
rm -rf store/screenshots
swift scripts/flatten-png.swift "$RAW" store/screenshots store-
ls -1 store/screenshots
