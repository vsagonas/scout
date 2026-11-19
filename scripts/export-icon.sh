#!/bin/bash
# The app icon (AppIconArt's Island, see AppIconInUse in Sources/Scout/Core/AppIconArt.swift) at every macOS size, from the full edition's
# own binary run headless, into Support/AppIcon.icns (the SwiftPM build) and Support/Assets.xcassets/AppIcon.appiconset (the App Store
# archive). Run from the repo root after `scripts/build-app.sh debug`. Never runs the App Store binary.
set -euo pipefail
BIN="build/Scout.app/Contents/MacOS/Scout"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
"$BIN" --automation --headless --run "scout://icon.export?dir=$WORK/png&out=$WORK/export.txt" >/dev/null 2>&1 & PID=$!
for _ in $(seq 1 60); do [ -s "$WORK/export.txt" ] && grep -q "icon.export done" "$WORK/export.txt" && break; sleep 0.5; done
kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true
cat "$WORK/export.txt"
if grep -q FAIL "$WORK/export.txt" || ! grep -q "icon.export done" "$WORK/export.txt"; then echo "export failed"; exit 1; fi
mkdir -p "$WORK/AppIcon.iconset"
cp "$WORK"/png/icon_*.png "$WORK/AppIcon.iconset/"
iconutil -c icns "$WORK/AppIcon.iconset" -o Support/AppIcon.icns
cp "$WORK"/png/icon_*.png Support/Assets.xcassets/AppIcon.appiconset/
echo "Wrote Support/AppIcon.icns and Support/Assets.xcassets/AppIcon.appiconset"
