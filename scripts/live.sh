#!/bin/bash
# Live check on the real screen, ONE Scout at a time (lock: $TMPDIR/scout-run.lock).
# Launches build/Scout.app in automation mode (no permission prompts, sample data), runs scout:// commands,
# captures a region, then quits Scout. Keep it short: it shows on the real screen, and it quits any running Scout.
#
# Usage: scripts/live.sh <out.png> <region> [command ...]
#   region:  notch | top | full | x,y,w,h   (points, origin top-left of the main screen)
#   command: anything after scout://, e.g.  "notch.open?ws=nook"  "ring.open?x=860&y=560"  "wait=1.5"
# Example: scripts/live.sh /tmp/nook.png notch "notch.open?ws=nook" "wait=1"
set -euo pipefail

if [ -z "${SCOUT_LIVE_LOCKED:-}" ]; then
  export SCOUT_LIVE_LOCKED=1
  exec lockf -t 900 "${TMPDIR:-/tmp}/scout-run.lock" "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${SCOUT_APP:-$ROOT/build/Scout.app}"   # SCOUT_APP=build/appstore/Scout.app for the App Store edition
OUT="$1"; REGION="$2"; shift 2
[ -d "$APP" ] || { echo "No build at $APP" >&2; exit 1; }

W=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.mainScreen.frame.size.width' 2>/dev/null || echo 1728)
H=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.mainScreen.frame.size.height' 2>/dev/null || echo 1117)
W=${W%.*}; H=${H%.*}
case "$REGION" in
  notch) R="$(( (W - 1000) / 2 )),0,1000,340" ;;
  top)   R="0,0,$W,400" ;;
  full)  R="0,0,$W,$H" ;;
  *)     R="$REGION" ;;
esac

pkill -x Scout 2>/dev/null || true
sleep 0.4
open -n "$APP" --args --automation
sleep 2.0
for cmd in "$@"; do
  if [[ "$cmd" == wait=* ]]; then sleep "${cmd#wait=}"; continue; fi
  # -a: send the URL to THIS build (several Scout.app copies share the bundle id).
  open -g -a "$APP" "scout://$cmd"
  sleep 0.9
done
mkdir -p "$(dirname "$OUT")"
screencapture -x -R "$R" "$OUT"
open -g -a "$APP" "scout://quit" || true
sleep 0.6
pkill -x Scout 2>/dev/null || true
echo "Captured $OUT ($R)"
