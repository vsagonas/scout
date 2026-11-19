#!/bin/bash
# Builds Scout.app from the Swift package (no Xcode project, never xcodebuild).
# Usage: scripts/build-app.sh [debug|release] [full|appstore]
#   full     → build/Scout.app           (everything; not sandboxed)
#   appstore → build/appstore/Scout.app  (-D APPSTORE, sandboxed with Support/Scout-AppStore.entitlements)
set -euo pipefail

CONFIG="${1:-debug}"
EDITION="${2:-full}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"


VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0.1.0)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

SWIFT_ARGS=(-c "$CONFIG" --arch arm64)
APP="$ROOT/build/Scout.app"
ENTITLEMENTS=()
if [ "$EDITION" = "appstore" ]; then
  export SCOUT_APPSTORE=1   # Package.swift drops SwiftTerm
  SWIFT_ARGS+=(-Xswiftc -DAPPSTORE --scratch-path "$ROOT/.build-appstore")
  APP="$ROOT/build/appstore/Scout.app"
  ENTITLEMENTS=(--entitlements "$ROOT/Support/Scout-AppStore.entitlements")
fi

set +e
swift build "${SWIFT_ARGS[@]}" 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\] (Compiling|Write|Emitting|Planning|Copying|Linking)'
STATUS=${PIPESTATUS[0]}
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "swift build failed ($STATUS)" >&2
  exit "$STATUS"
fi

BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Scout" "$APP/Contents/MacOS/Scout"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Support/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Resources: everything in Support/Resources is copied as-is into Contents/Resources.
# Load with Bundle.main.url(forResource:withExtension:) — never Bundle.module (it looks at the .app root).
if [ -d Support/Resources ]; then
  cp -R Support/Resources/. "$APP/Contents/Resources/"
fi
# Translations: Support/Resources/<code>.lproj (Localizable.strings, InfoPlist.strings) came across with the copy above. InfoPlist.strings holds the
# permission texts of BOTH editions (the App Store wording sits under `KEY~appstore`); each edition ships only its own.
if [ -e Support/Resources/pseudo.lproj ] && [ "$EDITION" = "appstore" ]; then
  echo "Refusing: Support/Resources/pseudo.lproj must never be in a store build." >&2
  exit 3
fi
rm -rf "$APP/Contents/Resources/pseudo.lproj"
# Test-only pseudo language (SCOUT_PSEUDO=1, debug full build only): every value wrapped like [! ... !], vowels accented, 40% longer.
# Run it with SCOUT_LANG=pseudo (scripts/gallery.sh, or the headless runs). Never in a release or App Store build.
if [ "${SCOUT_PSEUDO:-}" = "1" ]; then
  if [ "$CONFIG" = "debug" ] && [ "$EDITION" = "full" ]; then
    mkdir -p "$APP/Contents/Resources/pseudo.lproj"
    python3 "$ROOT/scripts/l10n/pseudo.py" "$APP/Contents/Resources/pseudo.lproj/Localizable.strings" "$APP/Contents/Resources/pseudo.lproj/InfoPlist.strings"
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string pseudo" "$APP/Contents/Info.plist"
    # Until a real Arabic translation exists, `ar` is the same pseudo text, so SCOUT_LANG=ar shows the right-to-left layout (marked by .pseudo-rtl).
    if [ ! -d "$APP/Contents/Resources/ar.lproj" ]; then
      mkdir -p "$APP/Contents/Resources/ar.lproj"
      cp "$APP/Contents/Resources/pseudo.lproj/"*.strings "$APP/Contents/Resources/ar.lproj/"
      : > "$APP/Contents/Resources/ar.lproj/.pseudo-rtl"
      /usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" "$APP/Contents/Info.plist" | grep -qx "    ar" || /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string ar" "$APP/Contents/Info.plist"
    fi
    echo "Pseudo language added (debug build only): run with SCOUT_LANG=pseudo (left to right) or SCOUT_LANG=ar (right to left)"
  else
    echo "SCOUT_PSEUDO=1 is ignored: the pseudo language is for debug full builds only." >&2
  fi
fi
for LPROJ in "$APP/Contents/Resources/"*.lproj; do
  [ -f "$LPROJ/InfoPlist.strings" ] || continue
  python3 "$ROOT/scripts/l10n/infoplist.py" bundle "$EDITION" "$LPROJ/InfoPlist.strings" "$LPROJ/InfoPlist.strings.edition"
  mv "$LPROJ/InfoPlist.strings.edition" "$LPROJ/InfoPlist.strings"
done
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# The privacy manifest (required reasons for the APIs Scout uses) goes in both editions.
if [ -f Support/PrivacyInfo.xcprivacy ]; then
  cp Support/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
fi
# Dynamic libraries / frameworks you build or vendor go in Support/Frameworks.
if [ -d Support/Frameworks ]; then
  cp -R Support/Frameworks/. "$APP/Contents/Frameworks/"
fi
for lib in "$BIN_DIR"/*.dylib; do
  [ -e "$lib" ] && cp "$lib" "$APP/Contents/Frameworks/"
done
if [ -z "$(ls -A "$APP/Contents/Frameworks")" ]; then rmdir "$APP/Contents/Frameworks"; fi

# Sign with the Apple Development identity so macOS keeps permissions (Accessibility, camera…) across
# rebuilds. Falls back to ad-hoc (then permissions must be granted again after each build).
IDENTITY="${SCOUT_SIGN_IDENTITY:-Apple Development}"
if ! codesign --force --deep --timestamp=none ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
  echo "Developer signing failed; signed ad-hoc instead." >&2
  codesign --force --deep ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} --sign - "$APP" >/dev/null 2>&1
fi

echo "Built $APP — Scout $VERSION ($BUILD_NUMBER), $CONFIG, $EDITION edition"
