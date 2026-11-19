#!/bin/bash
# Writes l10n/FREEZE.txt: the number of keys of each English file, the sha256 of each, and the time. Run it once the English text is final
# (the app builds, scripts/l10n/extract.sh --write is done). From then on no English key may change or be added: a key that must change gets a
# line `old key => new key` in l10n/DELTA.txt.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
{
  for f in l10n/en/Localizable.strings l10n/en/InfoPlist.strings; do
    echo "$(basename "$f") keys=$(grep -c '^"' "$f") sha256=$(shasum -a 256 "$f" | cut -d' ' -f1)"
  done
  echo "PIXEL-LABELS.txt keys=$(grep -vc '^#' l10n/PIXEL-LABELS.txt) sha256=$(shasum -a 256 l10n/PIXEL-LABELS.txt | cut -d' ' -f1)"
  echo "frozen $(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "From now on no English key changes or is added; a key that must change gets one line 'old key => new key' in l10n/DELTA.txt."
} > l10n/FREEZE.txt
cat l10n/FREEZE.txt
