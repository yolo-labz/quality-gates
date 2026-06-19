#!/usr/bin/env bash
#
# alignment-gate.sh — deterministic "did the agent finish + stay in scope" gate.
# Zero-dependency (git + grep + awk). Catches the completion-theater / scope-creep
# class no linter sees: TODO/stub left in "done" code, skipped/only tests, added lint
# suppressions (goal-hacking), debug artifacts, and over-wide blast radius.
#
# Heuristics modeled on the deterministic checks in donegate (MIT, intrepideai/donegate),
# AgentLiar (MIT), and opencode-swarm's placeholder-scan — reimplemented portably.
#
# Scope (pick one; default = path "."):
#   --staged                files staged in git     → pre-commit / PostToolUse-batch
#   --base REF              files changed vs REF    → CI on a PR (scans ADDED lines only)
#   <path>                  scan a dir/file         → manual (scans all lines)
#
# Strictness (env-overridable; 1 = fail, 0 = report-only):
#   ALIGN_FAIL_ON_TODO        default 1   TODO/FIXME/HACK/XXX + not-implemented + stubs
#   ALIGN_FAIL_ON_SKIP        default 1   skipped / .only / disabled tests
#   ALIGN_FAIL_ON_LINT_DISABLE default 1  added eslint-disable / @ts-ignore / noqa / …
#   ALIGN_FAIL_ON_DEBUG       default 0   console.log / debugger / set_trace left in
#   ALIGN_MAX_FILES           default 0   0=off; else fail if changed code files > N
#
# Exit: 0 = aligned · 1 = violation over threshold · 2 = tooling/usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALIGN_FAIL_ON_TODO="${ALIGN_FAIL_ON_TODO:-1}"
ALIGN_FAIL_ON_SKIP="${ALIGN_FAIL_ON_SKIP:-1}"
ALIGN_FAIL_ON_LINT_DISABLE="${ALIGN_FAIL_ON_LINT_DISABLE:-1}"
ALIGN_FAIL_ON_DEBUG="${ALIGN_FAIL_ON_DEBUG:-0}"
ALIGN_MAX_FILES="${ALIGN_MAX_FILES:-0}"

# NB: literal dots written [.] so the same patterns are safe in both grep -E and awk.
CODE_RE='[.](ts|tsx|js|jsx|py|go|rs|rb|php|java|cs|c|cpp|h|hpp|swift|kt|ex|exs|sh|bash|nix)$'
TEST_RE='([.]test[.]|[.]spec[.]|_test[.]|/tests?/|/__tests__/|(^|/)test_[^/]*[.]py$|_test[.]go$|_spec[.]rb$)'
# self-exemption: never scan the gate's own files (they contain the pattern tables) or meta docs
SELF_RE='(alignment-gate[.]sh$|/hooks/|posttooluse-aislop|code-slop-gate)'
META_RE='[.](md|rst|txt|lock)$'

die() { echo "alignment-gate: $*" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || die "git required"
command -v awk  >/dev/null 2>&1 || die "awk required"

mode="path"; base="HEAD"; target="."
case "${1:-}" in
  --staged)   mode="staged" ;;
  --worktree) mode="worktree" ;;
  --changes) mode="changes"; [ "${2:-}" = "--base" ] && base="${3:?--base needs a ref}" ;;
  --base)    mode="changes"; base="${2:?--base needs a ref}" ;;
  "")        target="." ;;
  -*)        die "unknown flag: $1" ;;
  *)         target="$1" ;;
esac

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
stream="$WORK/stream"     # path \t lineno \t content   (added lines for diff; all lines for path)
: >"$stream"

emit_diff() {
  local range
  case "$mode" in
    staged)   range=(--cached) ;;
    worktree) range=("HEAD") ;;
    changes)  range=("$base...HEAD") ;;
  esac
  git diff -U0 --no-color "${range[@]}" 2>/dev/null | awk '
    /^\+\+\+ b\// { file=substr($0,7); next }
    /^@@/ { if (match($0,/\+[0-9]+/)) { n=substr($0,RSTART+1,RLENGTH-1)+0; ln=n-1 } next }
    /^\+/ && !/^\+\+\+/ { ln++; print file "\t" ln "\t" substr($0,2) }
  '
}
emit_path() {
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    awk -v p="$f" '{print p "\t" NR "\t" $0}' "$f"
  done < <(find "$target" -type f 2>/dev/null)
}

# build the filtered line stream
{ [ "$mode" = "path" ] && emit_path || emit_diff; } | \
  awk -F'\t' -v code="$CODE_RE" -v self="$SELF_RE" -v meta="$META_RE" \
    '$1 ~ code && $1 !~ self && $1 !~ meta' >"$stream"

# changed code-file count (for blast-radius)
nfiles="$(cut -f1 "$stream" | sort -u | grep -c . || true)"

# checks: rule | severity | test_only | toggle | ERE | message
checks=(
  "incomplete/todo|error|0|$ALIGN_FAIL_ON_TODO|\b(TODO|FIXME|HACK|XXX)\b|TODO/FIXME/HACK/XXX left in changed code"
  "incomplete/not-implemented|error|0|$ALIGN_FAIL_ON_TODO|NotImplementedError|NotImplementedException|[Nn]ot implemented|unimplemented|not-implemented marker"
  "incomplete/throw-stub|error|0|$ALIGN_FAIL_ON_TODO|(throw new Error|raise)[^;]*(implement|stub|placeholder|TODO)|stub raises/throws instead of implementing"
  "incomplete/ellipsis-body|error|0|$ALIGN_FAIL_ON_TODO|^[[:space:]]*\.\.\.[[:space:]]*$|ellipsis placeholder body"
  "test/skip|error|1|$ALIGN_FAIL_ON_SKIP|\b(it|test|describe)\.(skip|todo|failing|only)\b|\bx(it|describe|test)[[:space:]]*\(|@pytest\.mark\.(skip|skipif|xfail)\b|pytest\.skip\(|unittest\.skip|\bt\.Skip(f|Now)?\(|#\[ignore\b|@(Disabled|Ignore)\b|markTestSkipped|markTestIncomplete|skipped / .only / disabled test added"
  "align/lint-suppressed|error|0|$ALIGN_FAIL_ON_LINT_DISABLE|eslint-disable|biome-ignore|@ts-(ignore|nocheck|expect-error)|#[[:space:]]*noqa|#[[:space:]]*type:[[:space:]]*ignore|#[[:space:]]*pylint:[[:space:]]*disable|//[[:space:]]*nolint|#\[allow\(|@SuppressWarnings|rubocop:disable|swiftlint:disable|lint suppression added (goal-hacking)"
  "align/debug-artifact|warn|0|$ALIGN_FAIL_ON_DEBUG|console\.(log|debug)\(|^[[:space:]]*debugger;|pdb\.set_trace\(|binding\.pry|[[:space:]]dbg!\(|debug artifact left in code"
)

findings="$WORK/findings"; : >"$findings"   # sev \t rule \t path:lineno \t message
for spec in "${checks[@]}"; do
  # spec layout: rule|sev|test_only|toggle|<re...>|msg  (re may contain | alternation,
  # so peel fixed fields off the front and msg off the back; re is what remains).
  rule="${spec%%|*}"; rest="${spec#*|}"
  sev="${rest%%|*}"; rest="${rest#*|}"
  test_only="${rest%%|*}"; rest="${rest#*|}"
  toggle="${rest%%|*}"; rest="${rest#*|}"
  msg="${rest##*|}"; re="${rest%|*}"
  [ "$toggle" = "0" ] && [ "$sev" = "error" ] && sev="warn"   # strictness downgrade
  while IFS=$'\t' read -r path lineno content; do
    [ "$test_only" = "1" ] && { echo "$path" | grep -qE "$TEST_RE" || continue; }
    if printf '%s' "$content" | grep -qE "$re"; then
      printf '%s\t%s\t%s:%s\t%s\n' "$sev" "$rule" "$path" "$lineno" "$msg" >>"$findings"
    fi
  done <"$stream"
done

# blast-radius
if [ "$ALIGN_MAX_FILES" -gt 0 ] && [ "${nfiles:-0}" -gt "$ALIGN_MAX_FILES" ]; then
  printf 'error\tscope/blast-radius\t(%s files)\tchanged code files %s > max %s\n' \
    "$nfiles" "$nfiles" "$ALIGN_MAX_FILES" >>"$findings"
fi

errs="$(grep -c '^error' "$findings" 2>/dev/null)"; errs="${errs:-0}"
warns="$(grep -c '^warn' "$findings" 2>/dev/null)"; warns="${warns:-0}"

echo "── alignment gate ─────────────────────────────"
printf 'scanned: %s changed code file(s) · %s error(s) · %s warning(s)\n' "${nfiles:-0}" "$errs" "$warns"
if [ -s "$findings" ]; then
  echo "findings:"
  sort "$findings" | awk -F'\t' '{printf "  %-5s %-26s %-28s %s\n", toupper($1), $2, $3, $4}'
fi
echo "───────────────────────────────────────────────"
if [ "${errs:-0}" -gt 0 ]; then
  echo "✗ FAIL — finish the work / tighten scope before claiming done."
  exit 1
fi
echo "✓ PASS — no completion-theater or scope violations over threshold."
exit 0
