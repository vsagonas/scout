#!/bin/bash
# Renders registered views offscreen to PNG (nothing opens on screen).
# Usage: scripts/gallery.sh [prefix] [outdir]     e.g. scripts/gallery.sh ring
# Language: SCOUT_LANG=<code> scripts/gallery.sh ...   (de, ar, pt-BR, zh-Hans, … or `pseudo` for a build made with SCOUT_PSEUDO=1); English by default.
# Needs a current build: run scripts/build-app.sh first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-}"
OUT="${2:-$ROOT/build/gallery}"
APP="${SCOUT_APP:-$ROOT/build/Scout.app}"   # SCOUT_APP=build/appstore/Scout.app for the App Store edition
[ -x "$APP/Contents/MacOS/Scout" ] || { echo "No build at $APP — run scripts/build-app.sh" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
ARGS=(--gallery "$OUT")
[ -n "$PREFIX" ] && ARGS+=(--only "$PREFIX")
if [ -n "${SCOUT_LANG:-}" ]; then
  LOCALE_ID="${SCOUT_LANG//-/_}"
  [ "$SCOUT_LANG" = "pseudo" ] && LOCALE_ID="en_US"
  ARGS+=(-AppleLanguages "($SCOUT_LANG)" -AppleLocale "$LOCALE_ID")
fi
# Hard time limit so a stuck render never hangs a run (4 min: the full gallery has hundreds of images).
"$APP/Contents/MacOS/Scout" "${ARGS[@]}" &
PID=$!
for _ in $(seq 1 480); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$PID" 2>/dev/null; then kill "$PID"; echo "Gallery timed out after 240 s" >&2; exit 3; fi
wait "$PID" || true
ls "$OUT" | grep -c png | xargs -I{} echo "{} images in $OUT"
