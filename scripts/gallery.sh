#!/bin/bash
# Renders registered views offscreen to PNG (nothing opens on screen).
# Usage: scripts/gallery.sh [prefix] [folder]     e.g. scripts/gallery.sh dash90
#   Both arguments are optional: no prefix renders every picture, no folder means build/gallery. The folder is DELETED and made anew, so
#   it is only touched when it does not exist, is empty, or holds nothing but *.png files and gallery.txt (a gallery rendered before; a
#   .DS_Store that Finder left there does not count).
# Language: SCOUT_LANG=<code> scripts/gallery.sh ...   (de, ar, pt-BR, zh-Hans, … or `pseudo` for a build made with SCOUT_PSEUDO=1); English by default.
# Needs a build first: run scripts/build-app.sh (the script stops with "No build at ..." without one).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-}"
OUT="${2:-$ROOT/build/gallery}"
APP="${SCOUT_APP:-$ROOT/build/Scout.app}"   # SCOUT_APP=build/appstore/Scout.app for the App Store edition
[ -x "$APP/Contents/MacOS/Scout" ] || { echo "No build at $APP — run scripts/build-app.sh" >&2; exit 1; }
# The folder is deleted below, so it must hold nothing but the files of an earlier gallery: only *.png files and gallery.txt, no subfolder, no link.
if [ -L "$OUT" ]; then echo "Refusing to delete $OUT: it is a link, not a folder of pictures." >&2; exit 2; fi
if [ -e "$OUT" ]; then
  [ -d "$OUT" ] || { echo "Refusing to delete $OUT: it is a file, not a folder of pictures." >&2; exit 2; }
  OTHER="$(find "$OUT" -mindepth 1 ! \( -type f \( -name "*.png" -o -name "gallery.txt" -o -name ".DS_Store" \) \) -print -quit)"
  [ -z "$OTHER" ] || { echo "Refusing to delete $OUT: it holds $OTHER, which is not a gallery picture (only *.png files and gallery.txt may be in it)." >&2; exit 2; }
fi
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
