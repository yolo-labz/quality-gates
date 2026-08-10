#!/usr/bin/env bash
#
# gherkin-lint-gate.sh — MUST-rule lint for .feature files, over the official
# Gherkin AST (@cucumber/gherkin).
#
# Replaces gherkin-lint, dead upstream since the ruby gem 1.2.2 (2017) / npm
# port 4.2.4 (2023), with no successor under the cucumber org. Every rule is a
# MUST from the fleet's `bdd` context contract; that list was written to be
# AST-checkable so the contract and the linter cannot drift.
#
# Scope (env-overridable):
#   GHERKIN_PATHS     default "features"   space-separated files or directories
#   GHERKIN_FAIL_ON   default "error"      "error" | "warning" (warning = strict)
#
# Two behaviours this gate must get right, and they pull in opposite directions:
#
#   1. A repo with NO .feature files passes silently. Most consumers have none
#      — Gherkin is deliberately scoped (see the contract: not Elixir, not Nix,
#      not Bash), so a gate that failed on "no scenarios" would make the whole
#      composite action unadoptable.
#   2. A repo WITH .feature files must never pass because the linter could not
#      run. "Ran and found nothing" and "never ran" are different facts and only
#      one is good news — a crashed linter reporting zero findings is exactly
#      the false-pass that claude-skills#22 fixed one layer up. If the engine is
#      missing or its output is unparseable, that is exit 2, not exit 0.
#
# Exit: 0 = clean (or nothing to lint) · 1 = findings over threshold · 2 = tooling error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/gherkin-lint.mjs"

GHERKIN_PATHS="${GHERKIN_PATHS:-features}"
GHERKIN_FAIL_ON="${GHERKIN_FAIL_ON:-error}"

die() { printf '::error title=gherkin-lint::%s\n' "$*" >&2; exit 2; }

command -v node >/dev/null 2>&1 || die "node is not on PATH"
[ -f "$LINT" ] || die "linter missing at $LINT"

# ---- 1. resolve the targets -------------------------------------------------
# Only existing paths are passed on; a configured directory that does not exist
# is the normal case for a repo that has not adopted Gherkin.
targets=()
for p in $GHERKIN_PATHS; do
  [ -e "$p" ] && targets+=("$p")
done

if [ ${#targets[@]} -eq 0 ]; then
  echo "gherkin-lint: no path in '$GHERKIN_PATHS' exists — nothing to lint."
  exit 0
fi

count=0
for t in "${targets[@]}"; do
  n=$(find "$t" -name '*.feature' -not -path '*/node_modules/*' 2>/dev/null | wc -l)
  count=$((count + n))
done

if [ "$count" -eq 0 ]; then
  echo "gherkin-lint: no .feature files under '$GHERKIN_PATHS' — nothing to lint."
  exit 0
fi

# ---- 2. from here a silent pass is not an acceptable outcome ----------------
[ -d "$SCRIPT_DIR/node_modules/@cucumber/gherkin" ] || die \
  "$count .feature file(s) to lint but @cucumber/gherkin is not installed (run npm ci in $SCRIPT_DIR). Refusing to report a clean result from a linter that cannot run."

report=$(node "$LINT" --json "${targets[@]}" 2>&1)
rc=$?

# The linter answers 0 (clean) or 1 (findings). Anything else is the engine
# failing, and must not be read as "clean".
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  printf '%s\n' "$report" >&2
  die "linter exited $rc (expected 0 or 1) — treating as a tooling failure, not a clean run"
fi

if ! printf '%s' "$report" | jq -e 'has("findings") and (.findings | type == "array")' >/dev/null 2>&1; then
  printf '%s\n' "$report" >&2
  die "linter produced no parseable findings array — treating as a tooling failure, not a clean run"
fi

# ---- 3. report --------------------------------------------------------------
errors=$(printf '%s' "$report" | jq '[.findings[] | select(.sev == "error")] | length')
warnings=$(printf '%s' "$report" | jq '[.findings[] | select(.sev == "warning")] | length')

printf '%s' "$report" | jq -r '.findings[] | "\(.file):\(.line): \(.sev) [\(.rule)] \(.msg)"'

echo "── gherkin-lint ──────────────────────────────"
echo "scanned: $count .feature file(s) · $errors error(s) · $warnings warning(s)"

fail=0
[ "$errors" -gt 0 ] && fail=1
if [ "$GHERKIN_FAIL_ON" = "warning" ] && [ "$warnings" -gt 0 ]; then fail=1; fi

if [ "$fail" -eq 1 ]; then
  echo "✗ FAIL — fix the scenarios above (GHERKIN_FAIL_ON=$GHERKIN_FAIL_ON)."
  exit 1
fi

echo "✓ PASS"
exit 0
