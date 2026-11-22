#!/bin/bash
# Runs the self-tests of ONE build with nothing on the screen: the features suite, then every headless suite (one process each).
# Usage: scripts/selftests.sh [suite ...]      every suite when none is named ("features" is the features suite)
#   SCOUT_APP=<path to a Scout.app>            the build to test (default: build/Scout.app of this checkout)
#   SUITE_TAG=<word>                           this run's own settings domain, com.vsag.Scout.automation.<word> (default: selftests)
#   WITH_SLOW=1                                also the suites that relaunch the app or start shells (language.selftest.restart, termtab.selftest.relaunch)
# One line per suite (PASS or FAIL, the suite, its last line), the failing lines under it, a summary at the end. Exit 1 when anything failed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${SCOUT_APP:-$ROOT/build/Scout.app}"
BIN="$APP/Contents/MacOS/Scout"
[ -x "$BIN" ] || { echo "No build at $APP (run scripts/build-app.sh debug)." >&2; exit 64; }
# The sandboxed edition is never run for tests: its settings and files are the real app's.
if codesign -d --entitlements - "$APP" 2>/dev/null | /usr/bin/grep -q "com.apple.security.app-sandbox"; then
  echo "Refusing: $APP is the sandboxed edition; tests run in the development edition only." >&2; exit 64
fi
TAG="${SUITE_TAG:-selftests}"
export SCOUT_DEFAULTS_SUITE="com.vsag.Scout.automation.$TAG"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/scout-selftests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SLOW="language.selftest.restart termtab.selftest.relaunch"
HELPERS="language.selftest.child"

# Waits until file $1 exists and has stopped growing, at most $2 seconds.
settled() {
  local file="$1" limit="$2" last=-1 size i
  for ((i = 0; i < limit * 4; i++)); do
    if [ -s "$file" ]; then
      size=$(stat -f %z "$file")
      [ "$size" = "$last" ] && return 0
      last=$size
    fi
    sleep 0.25
  done
  return 1
}

# The names this build registers for a headless run.
discover() {
  local out="$WORK/commands.txt"
  "$BIN" --automation --headless --run "scout://commands?out=$out" >/dev/null 2>&1 &
  local pid=$!
  settled "$out" 30 || true
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ -s "$out" ] && /usr/bin/grep -E "selftest" "$out" | sort
}

if [ "$#" -gt 0 ]; then
  SUITES=("$@")
else
  SUITES=(features)
  while IFS= read -r name; do
    case " $HELPERS " in *" $name "*) continue;; esac
    case " $SLOW " in *" $name "*) [ "${WITH_SLOW:-0}" = "1" ] || continue;; esac
    SUITES+=("$name")
  done < <(discover)
  [ "${#SUITES[@]}" -gt 1 ] || { echo "FAIL  could not read the list of suites from $APP" >&2; exit 1; }
fi

PASSED=0; FAILED=0; FAILED_NAMES=()
for suite in "${SUITES[@]}"; do
  if [ "$suite" = "features" ]; then
    log="$WORK/features.log"
    SCOUT_SELFTEST=1 "$BIN" --automation --headless --gallery "$WORK/gallery" --only zzz >"$log" 2>&1 &
    pid=$!
    for ((i = 0; i < 300; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    last="$(/usr/bin/grep -E "^selftest done: " "$log" | tail -1)"
    bad="$(/usr/bin/grep -E "selftest FAIL" "$log" | head -8)"
    counts="$(echo "$last" | sed -E 's/.*done: ([0-9]+)\/([0-9]+) passed.*/\1 \2/')"
    if [ -n "$last" ] && [ -z "$bad" ] && [ "${counts% *}" = "${counts#* }" ]; then ok=1; else ok=0; fi
  else
    out="$WORK/$suite.txt"
    "$BIN" --automation --headless --run "scout://$suite?out=$out" >"$WORK/$suite.log" 2>&1 &
    pid=$!
    settled "$out" "${SUITE_TIMEOUT:-240}"; got=$?
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    last="$(tail -1 "$out" 2>/dev/null)"
    # A text result says FAIL; a JSON result (live, radio, the window suites) says "pass" : false, "ok" : false or "failed" : N.
    bad="$(/usr/bin/grep -E 'FAIL|"(pass|ok)" *: *false|"failed" *: *[1-9]' "$out" 2>/dev/null | head -8)"
    if /usr/bin/grep -q -E '^\{' "$out" 2>/dev/null; then
      last="$(/usr/bin/grep -E '"(passed|failed)" *:' "$out" | tr -d ' ,\n' | sed 's/""/, /g; s/"//g')"
    fi
    if [ "$got" -eq 0 ] && [ -z "$bad" ] && [ -n "$last" ]; then ok=1; else ok=0; [ "$got" -eq 0 ] || last="no result within ${SUITE_TIMEOUT:-240} s"; fi
  fi
  if [ "$ok" -eq 1 ]; then
    PASSED=$((PASSED + 1)); printf 'PASS  %-28s %s\n' "$suite" "$last"
  else
    FAILED=$((FAILED + 1)); FAILED_NAMES+=("$suite"); printf 'FAIL  %-28s %s\n' "$suite" "$last"
    [ -n "$bad" ] && echo "$bad" | sed 's/^/        /'
  fi
done
echo "selftests: $PASSED passed, $FAILED failed, of ${#SUITES[@]} suites (Scout $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null), $APP)"
[ "$FAILED" -eq 0 ] || { echo "failed: ${FAILED_NAMES[*]}"; exit 1; }
