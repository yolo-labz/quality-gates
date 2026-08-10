#!/usr/bin/env bash
#
# test-gherkin-lint-gate.sh — discrimination tests for the gate wrapper.
#
# The wrapper's whole job is to tell three outcomes apart that all look like
# "nothing to report" from the outside:
#
#   nothing to lint   → PASS   (most consumer repos; the action must stay silent)
#   linted, clean     → PASS
#   could not run     → FAIL   (never a silent pass — the claude-skills#22 trap)
#
# A wrapper that returns 0 for all three is indistinguishable from a working one
# until the day it matters, so each case below is paired with the outcome it
# must NOT produce.
#
# Exit 0 = all pass.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/gherkin-lint-gate.sh"
FIX="$SCRIPT_DIR/fixtures"
pass=0
fail=0

check() { # check <name> <expected-exit> [VAR=value ...]
  local name="$1" want="$2"; shift 2
  local got
  env "$@" "$GATE" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %-52s exit=%s\n' "$name" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-52s want=%s got=%s\n' "$name" "$want" "$got"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/empty" "$TMP/good" "$TMP/bad"
cp "$FIX/allowlist.feature" "$TMP/good/"
cp "$FIX/broken.feature" "$TMP/bad/"

echo "a repo with no scenarios must pass silently, not fail"
check "configured path does not exist"        0 "GHERKIN_PATHS=$TMP/nope"
check "path exists but holds no .feature"     0 "GHERKIN_PATHS=$TMP/empty"

echo "a repo with scenarios is actually linted"
check "clean scenarios pass"                  0 "GHERKIN_PATHS=$TMP/good"
check "broken scenarios fail"                 1 "GHERKIN_PATHS=$TMP/bad"

echo "warning tier is opt-in (a SHOULD must not fail a build on its own)"
# allowlist.feature is clean; broken.feature carries placeholder-data warnings
# alongside errors, so use a warning-only case: the good file under --strict
# must still pass, proving strict does not fire spuriously.
check "clean file stays clean under fail-on=warning" 0 "GHERKIN_PATHS=$TMP/good" "GHERKIN_FAIL_ON=warning"

echo "the engine failing must NEVER read as clean"
if [ -d "$SCRIPT_DIR/node_modules" ]; then
  mv "$SCRIPT_DIR/node_modules" "$SCRIPT_DIR/node_modules.testhidden"
  check "deps missing + files to lint = tooling error" 2 "GHERKIN_PATHS=$TMP/good"
  check "deps missing + nothing to lint = still pass"  0 "GHERKIN_PATHS=$TMP/empty"
  mv "$SCRIPT_DIR/node_modules.testhidden" "$SCRIPT_DIR/node_modules"
else
  printf '  skip %-52s (node_modules absent; run npm ci first)\n' "deps-missing cases"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
