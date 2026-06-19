#!/usr/bin/env bash
#
# code-slop-gate.sh — deterministic code-slop gate (aislop + jscpd).
#
# Engines:
#   aislop scan --json   AI-slop findings (swallowed exceptions, as-any casts,
#                        narrative comments, dead code, oversized functions) + 0-100 score.
#   jscpd                copy/paste duplication detection.
#
# Scope (pick one; default = path "."):
#   --staged                files staged in git          → pre-commit / PreToolUse
#   --changes [--base REF]   files changed vs REF (HEAD)  → CI on a PR
#   --base REF               alias for --changes --base REF
#   <path>                   scan a directory or a file   → manual / repo-wide
#
# Policy (env-overridable):
#   AISLOP_MAX_ERRORS   default 0    fail when aislop error count exceeds this
#   AISLOP_MIN_SCORE    default 0    fail when aislop score is below this (0 = off)
#   JSCPD_MAX_PCT       default 0    fail when duplication percentage exceeds this
#   JSCPD_MIN_TOKENS    default 50   jscpd clone sensitivity
#
# Exit: 0 = clean · 1 = slop over threshold · 2 = tooling/usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AISLOP="$SCRIPT_DIR/node_modules/.bin/aislop"
JSCPD="$SCRIPT_DIR/node_modules/.bin/jscpd"

AISLOP_MAX_ERRORS="${AISLOP_MAX_ERRORS:-0}"
AISLOP_MIN_SCORE="${AISLOP_MIN_SCORE:-0}"
JSCPD_MAX_PCT="${JSCPD_MAX_PCT:-0}"
JSCPD_MIN_TOKENS="${JSCPD_MIN_TOKENS:-50}"
CODE_RE='\.(ts|tsx|js|jsx|py|go|rs|rb|php)$'

die() { echo "code-slop-gate: $*" >&2; exit 2; }
[ -x "$AISLOP" ] || die "aislop missing — run 'npm install' in $SCRIPT_DIR"
[ -x "$JSCPD" ]  || die "jscpd missing — run 'npm install' in $SCRIPT_DIR"
command -v jq >/dev/null 2>&1 || die "jq is required"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- scope ---
mode="path"; base="HEAD"; target="."
case "${1:-}" in
  --staged)  mode="staged" ;;
  --changes) mode="changes"; [ "${2:-}" = "--base" ] && base="${3:?--base needs a ref}" ;;
  --base)    mode="changes"; base="${2:?--base needs a ref}" ;;
  "")        target="." ;;
  -*)        die "unknown flag: $1" ;;
  *)         target="$1" ;;
esac

# jscpd has no git awareness — build the changed-file list for staged/changes scopes.
scope_files() {
  case "$mode" in
    staged)  git diff --cached --name-only --diff-filter=ACM 2>/dev/null ;;
    changes) git diff        --name-only --diff-filter=ACM "$base"...HEAD 2>/dev/null ;;
  esac | grep -E "$CODE_RE" || true
}

FILES=()
if [ "$mode" != "path" ]; then
  mapfile -t FILES < <(scope_files)
  if [ "${#FILES[@]}" -eq 0 ]; then
    echo "✓ code-slop-gate: no staged/changed code files — nothing to check."
    exit 0
  fi
fi

# --- aislop ---
aislop_args=(scan --json)
case "$mode" in
  staged)  aislop_args+=(--staged) ;;
  changes) aislop_args+=(--changes --base "$base") ;;
  path)    aislop_args+=("$target") ;;
esac
# aislop scans directories only; a single-file path target is isolated in a temp dir.
if [ "$mode" = "path" ] && [ -f "$target" ]; then
  mkdir -p "$WORK/at"
  cp "$target" "$WORK/at/$(basename "$target")"
  aislop_json="$("$AISLOP" scan --json "$WORK/at" 2>/dev/null || true)"
else
  aislop_json="$("$AISLOP" "${aislop_args[@]}" 2>/dev/null || true)"
fi
jq -e . >/dev/null 2>&1 <<<"$aislop_json" || die "aislop emitted no parseable JSON (args: ${aislop_args[*]})"
a_errors="$(jq -r '.summary.errors   // 0' <<<"$aislop_json")"
a_warns="$( jq -r '.summary.warnings // 0' <<<"$aislop_json")"
a_score="$( jq -r '.score            // empty' <<<"$aislop_json")"

# --- jscpd ---
jscpd_out="$WORK/jscpd"
mkdir -p "$jscpd_out"
jscpd_args=(--reporters json --silent --min-tokens "$JSCPD_MIN_TOKENS" --output "$jscpd_out")
if [ "$mode" = "path" ]; then jscpd_args+=("$target"); else jscpd_args+=("${FILES[@]}"); fi
"$JSCPD" "${jscpd_args[@]}" >/dev/null 2>&1 || true
j_report="$jscpd_out/jscpd-report.json"
j_pct="$(   jq -r '.statistics.total.percentage     // 0' "$j_report" 2>/dev/null || echo 0)"
j_clones="$(jq -r '.statistics.total.clones         // 0' "$j_report" 2>/dev/null || echo 0)"
j_dup="$(   jq -r '.statistics.total.duplicatedLines // 0' "$j_report" 2>/dev/null || echo 0)"

# --- verdict ---
fail=0
reasons=()
if [ "$a_errors" -gt "$AISLOP_MAX_ERRORS" ]; then
  fail=1; reasons+=("aislop: $a_errors error(s) > max $AISLOP_MAX_ERRORS")
fi
if [ "$AISLOP_MIN_SCORE" -gt 0 ] && [ -n "$a_score" ] && [ "$a_score" -lt "$AISLOP_MIN_SCORE" ]; then
  fail=1; reasons+=("aislop: score $a_score < min $AISLOP_MIN_SCORE")
fi
if awk "BEGIN{exit !($j_pct > $JSCPD_MAX_PCT)}"; then
  fail=1; reasons+=("jscpd: ${j_pct}% duplication > max ${JSCPD_MAX_PCT}% ($j_clones clone(s), $j_dup line(s))")
fi

# --- report ---
echo "── code-slop gate ─────────────────────────────"
printf 'aislop : score %s · %s error(s) · %s warning(s)\n' "${a_score:-n/a}" "$a_errors" "$a_warns"
printf 'jscpd  : %s%% duplication · %s clone(s) · %s line(s)\n' "$j_pct" "$j_clones" "$j_dup"
if [ "$a_errors" -gt 0 ] || [ "$a_warns" -gt 0 ]; then
  echo "findings:"
  jq -r '.diagnostics[]? | "  \(.severity|ascii_upcase)  \(.filePath):\(.line)  \(.rule) — \(.message)"' <<<"$aislop_json" 2>/dev/null | head -20
fi
echo "───────────────────────────────────────────────"
if [ "$fail" -eq 1 ]; then
  echo "✗ FAIL"
  printf '  %s\n' "${reasons[@]}"
  exit 1
fi
echo "✓ PASS — no code-slop over threshold."
exit 0
