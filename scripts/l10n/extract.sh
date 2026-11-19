#!/bin/bash
# Extracts the exact English key list of the app (compiler-accurate): builds the full AND the App Store edition into scratch folders with
# -emit-localized-strings (one .stringsdata JSON per source file), then scripts/l10n/extract.py merges them into l10n/en/Localizable.strings
# (and adds the pixelLabel("…") words and the lint report). Never touches build/Scout.app or the normal .build folder.
# Usage: scripts/l10n/extract.sh [--write]   (without --write it only prints the counts and the lint to the terminal)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
WORK="$ROOT/build/l10n"
rm -rf "$WORK/sd-full" "$WORK/sd-appstore"
mkdir -p "$WORK/sd-full" "$WORK/sd-appstore"
# SwiftPM caches (SwiftTerm checkout) are reused when the normal .build has them, so nothing is fetched twice.
# Always a full rebuild: an incremental build re-emits only the recompiled files and the key list would be incomplete.
for scratch in .build-l10n .build-l10n-appstore; do
  rm -rf "$scratch"
  mkdir -p "$scratch"
  if [ -d .build/checkouts ] && [ ! -d "$scratch/checkouts" ]; then
    cp -R .build/checkouts .build/repositories .build/workspace-state.json "$scratch/" 2>/dev/null || true
  fi
done
echo "Full edition…"
nice -n 15 swift build -c debug --arch arm64 --scratch-path "$ROOT/.build-l10n" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/sd-full" 2>&1 | grep -E "error:|Build complete" || true
echo "App Store edition…"
SCOUT_APPSTORE=1 nice -n 15 swift build -c debug --arch arm64 --scratch-path "$ROOT/.build-l10n-appstore" -Xswiftc -DAPPSTORE \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/sd-appstore" 2>&1 | grep -E "error:|Build complete" || true
python3 "$ROOT/scripts/l10n/extract.py" "$WORK/sd-full" "$WORK/sd-appstore" "$@"
