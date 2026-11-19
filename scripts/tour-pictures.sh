#!/bin/bash
# Renders the welcome tour's four pictures (the real dashboard: 8-bit and minimal, dark and light colours) from the full edition's
# gallery item "look-tour-dash" and copies them to Support/Resources/tour-<8bit|min>-<dark|light>.png. Usage: scripts/tour-pictures.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
scripts/build-app.sh debug
RAW="$(mktemp -d "${TMPDIR:-/tmp}/scout-tour.XXXXXX")"
trap 'rm -rf "$RAW"' EXIT
for look in 8bit min; do
  for preset in dark light; do
    eight=$([ "$look" = 8bit ] && echo 1 || echo 0)
    SCOUT_8BIT=$eight SCOUT_PRESET=$preset scripts/gallery.sh look-tour-dash "$RAW/$look-$preset" >/dev/null
    # The backdrop is covered by the island's own surface, so either appearance file is the same picture.
    cp "$RAW/$look-$preset/look-tour-dash-dark.png" "Support/Resources/tour-$look-$preset.png"
    echo "tour-$look-$preset.png"
  done
done
