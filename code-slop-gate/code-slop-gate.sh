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
BASELINE_FILTER="$SCRIPT_DIR/dependency-baseline.jq"
JSCPD_COMPARE="$SCRIPT_DIR/jscpd-snapshot-compare.js"

AISLOP_MAX_ERRORS="${AISLOP_MAX_ERRORS:-0}"
AISLOP_MIN_SCORE="${AISLOP_MIN_SCORE:-0}"
JSCPD_MAX_PCT="${JSCPD_MAX_PCT:-0}"
JSCPD_MIN_TOKENS="${JSCPD_MIN_TOKENS:-50}"
CODE_RE='\.(ts|tsx|js|jsx|py|go|rs|rb|php)$'

die() { echo "code-slop-gate: $*" >&2; exit 2; }
[ -x "$AISLOP" ] || die "aislop missing — run 'npm install' in $SCRIPT_DIR"
[ -x "$JSCPD" ]  || die "jscpd missing — run 'npm install' in $SCRIPT_DIR"
[ -f "$BASELINE_FILTER" ] || die "dependency baseline filter missing: $BASELINE_FILTER"
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

# Resolve scoped snapshots before either engine runs. The raw NUL-delimited
# manifest is also the only source of changed destinations and rename provenance.
repo_root=""
baseline_commit=""
baseline_label=""
changes_file="$WORK/changes.z"
if [ "$mode" != "path" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "scoped mode requires a Git worktree"
  case "$mode" in
    staged)
      # Unborn HEAD — the first commit of a fresh repo (test fixtures,
      # bootstraps) — has no baseline: `HEAD^{commit}` does not resolve and
      # `diff --cached HEAD` fails. Diff against the empty tree instead and
      # leave the baseline empty, so both ratchets treat this commit as the
      # snapshot they start from rather than as slop against nothing.
      if baseline_commit="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)"; then
        baseline_label="HEAD"
        git -C "$repo_root" diff --cached --name-status -z -M --diff-filter=ACDMRT HEAD >"$changes_file" ||
          die "cannot derive staged change manifest"
      else
        baseline_commit=""
        baseline_label="unborn"
        git -C "$repo_root" diff --cached --name-status -z -M --diff-filter=ACDMRT >"$changes_file" ||
          die "cannot derive staged change manifest"
      fi
      ;;
    changes)
      baseline_commit="$(git -C "$repo_root" merge-base "$base" HEAD 2>/dev/null)" ||
        die "cannot resolve merge base for $base and HEAD"
      baseline_label="$base"
      git -C "$repo_root" diff --name-status -z -M --diff-filter=ACDMRT "$baseline_commit" HEAD >"$changes_file" ||
        die "cannot derive changed-file manifest from merge base"
      ;;
  esac
  if [ ! -s "$changes_file" ]; then
    echo "✓ code-slop-gate: no staged/changed files — nothing to check."
    exit 0
  fi
  [ -f "$JSCPD_COMPARE" ] || die "jscpd snapshot comparison helper missing: $JSCPD_COMPARE"
  command -v node >/dev/null 2>&1 || die "node is required for scoped jscpd comparison"
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

# Scoped dependency audits are repository-wide. Ratchet them against the
# unchanged tree: HEAD for a staged commit, or the PR merge base for CI.
# Exact inherited vulnerabilities stay visible as warnings; new or worsened
# high-severity findings stay errors. A failed base scan fails closed.
baseline_dependency_errors=0
if [ -n "$baseline_commit" ] &&
   jq -e '.diagnostics[]? | select(.engine == "security" and .rule == "security/vulnerable-dependency" and .severity == "error")' \
     >/dev/null 2>&1 <<<"$aislop_json"; then
  baseline_tree="$WORK/baseline"
  baseline_json_file="$WORK/baseline.json"
  if mkdir -p "$baseline_tree" && git archive "$baseline_commit" | tar -x -C "$baseline_tree"; then
    mkdir -p "$baseline_tree/.aislop"
    cat >"$baseline_tree/.aislop/config.yml" <<'YAML'
version: 1
engines:
  format: false
  lint: false
  code-quality: false
  ai-slop: false
  architecture: false
  security: true
security:
  audit: true
  auditTimeout: 25000
telemetry:
  enabled: false
YAML
    "$AISLOP" scan --json "$baseline_tree" >"$baseline_json_file" 2>/dev/null || true
    if jq -e . "$baseline_json_file" >/dev/null 2>&1; then
      head_dependency_errors="$(jq '[.diagnostics[]? | select(.engine == "security" and .rule == "security/vulnerable-dependency" and .severity == "error")] | length' <<<"$aislop_json")"
      aislop_json="$(jq --slurpfile baseline "$baseline_json_file" --arg base "$baseline_label" -f "$BASELINE_FILTER" <<<"$aislop_json")"
      remaining_dependency_errors="$(jq '[.diagnostics[]? | select(.engine == "security" and .rule == "security/vulnerable-dependency" and .severity == "error")] | length' <<<"$aislop_json")"
      if [ "$remaining_dependency_errors" -lt "$head_dependency_errors" ]; then
        baseline_dependency_errors=$((head_dependency_errors - remaining_dependency_errors))
      fi
    else
      echo "code-slop-gate: dependency baseline scan unavailable; preserving head errors" >&2
    fi
  else
    echo "code-slop-gate: dependency base tree unavailable; preserving head errors" >&2
  fi
fi

# Drop findings about code this repository does not own.
#
# aislop's per-language passes can surface diagnostics from OUTSIDE the working
# tree — measured 10/08/2026 in yolo-labz/fand, where a `--staged` scan of one
# changed workflow file returned 341 findings, 338 of them from crates under
# ~/.cargo/registry (clippy loading `mach2` from the sysroot). The gate counted
# all of them, so every local commit in that repo failed on third-party code,
# whatever it contained. The same shape is possible for any language whose
# analyser resolves dependencies from a shared cache.
#
# A gate must never fail a repo for code it cannot change. In-repo paths are
# relative (`build.rs`) or under $repo_root; anything else is another project's
# problem, so it is filtered out of BOTH the counts and the findings list rather
# than merely hidden from the report — a number the printed list cannot explain
# is how "338 errors" became unactionable in the first place.
#
# `--staged`/`--changes` only: in `path` mode the caller names the target
# explicitly and may legitimately point outside the repo.
if [ "$mode" != "path" ] && [ -n "$repo_root" ]; then
  aislop_json="$(jq --arg root "$repo_root/" '
    (.diagnostics // []) as $all
    | ($all | map(select((.filePath // "") | (startswith("/") | not) or startswith($root)))) as $mine
    | .diagnostics = $mine
    | .summary.errors   = ([$mine[] | select(.severity == "error")]   | length)
    | .summary.warnings = ([$mine[] | select(.severity == "warning")] | length)
    | .foreignFindings  = (($all | length) - ($mine | length))
  ' <<<"$aislop_json")" || die "failed to scope aislop findings to the repository"

  foreign="$(jq -r '.foreignFindings // 0' <<<"$aislop_json")"
  if [ "${foreign:-0}" -gt 0 ]; then
    echo "code-slop-gate: ignored $foreign finding(s) outside $repo_root" >&2
  fi
fi

a_errors="$(jq -r '.summary.errors   // 0' <<<"$aislop_json")"
a_warns="$( jq -r '.summary.warnings // 0' <<<"$aislop_json")"
a_score="$( jq -r '.score            // empty' <<<"$aislop_json")"

# --- jscpd ---
j_pct=0
j_clones=0
j_dup=0
j_relevant=0
j_inherited=0
j_regressions=0
j_compare_file=""

materialize_commit() {
  local commit="$1"
  local destination="$2"
  mkdir -p "$destination" || die "cannot create snapshot directory: $destination"
  if ! git -C "$repo_root" archive "$commit" | tar -x -C "$destination"; then
    die "cannot materialize Git snapshot: $commit"
  fi
}

filter_code_files() {
  local tracked_file="$1"
  local snapshot_root="$2"
  local output_file="$3"
  local tracked_path

  : >"$output_file" || die "cannot create eligible-code manifest"
  while IFS= read -r -d '' tracked_path; do
    if [[ "$tracked_path" =~ $CODE_RE ]]; then
      [ -f "$snapshot_root/$tracked_path" ] ||
        die "tracked code file missing from snapshot: $tracked_path"
      printf '%s\0' "$snapshot_root/$tracked_path" >>"$output_file" ||
        die "cannot write eligible-code manifest"
    fi
  done <"$tracked_file"
}

empty_jscpd_report() {
  local report="$1"
  printf '%s\n' \
    '{"duplicates":[],"statistics":{"total":{"clones":0,"duplicatedLines":0,"percentage":0}}}' \
    >"$report" || die "cannot create empty jscpd report"
}

scan_snapshot() {
  local code_file="$1"
  local output_dir="$2"
  local label="$3"
  local report="$output_dir/jscpd-report.json"
  local -a code_paths=()

  mkdir -p "$output_dir" || die "cannot create $label jscpd output directory"
  mapfile -d '' -t code_paths <"$code_file"
  if [ "${#code_paths[@]}" -eq 0 ]; then
    empty_jscpd_report "$report"
    return
  fi

  # Scoped policy is the snapshot ratchet below. Neutralize jscpd's aggregate
  # exit threshold so any non-zero engine status is an actual tooling failure;
  # manual/path mode keeps JSCPD_MAX_PCT unchanged.
  if ! "$JSCPD" --reporters json --silent --absolute --no-gitignore \
    --min-tokens "$JSCPD_MIN_TOKENS" --threshold 100 --output "$output_dir" \
    "${code_paths[@]}" >/dev/null 2>&1; then
    die "$label jscpd scan failed"
  fi
  [ -s "$report" ] || die "$label jscpd report is missing"
}

if [ "$mode" = "path" ]; then
  jscpd_out="$WORK/jscpd"
  mkdir -p "$jscpd_out"
  jscpd_args=(--reporters json --silent --min-tokens "$JSCPD_MIN_TOKENS" --output "$jscpd_out")
  jscpd_args+=("$target")
  "$JSCPD" "${jscpd_args[@]}" >/dev/null 2>&1 || true
  j_report="$jscpd_out/jscpd-report.json"
  j_pct="$(   jq -r '.statistics.total.percentage     // 0' "$j_report" 2>/dev/null || echo 0)"
  j_clones="$(jq -r '.statistics.total.clones         // 0' "$j_report" 2>/dev/null || echo 0)"
  j_dup="$(   jq -r '.statistics.total.duplicatedLines // 0' "$j_report" 2>/dev/null || echo 0)"
else
  baseline_tree="$WORK/jscpd-baseline"
  candidate_tree="$WORK/jscpd-candidate"
  baseline_tracked="$WORK/jscpd-baseline-tracked.z"
  candidate_tracked="$WORK/jscpd-candidate-tracked.z"
  baseline_code="$WORK/jscpd-baseline-code.z"
  candidate_code="$WORK/jscpd-candidate-code.z"
  baseline_out="$WORK/jscpd-baseline-report"
  candidate_out="$WORK/jscpd-candidate-report"
  j_compare_file="$WORK/jscpd-compare.json"

  if [ -n "$baseline_commit" ]; then
    materialize_commit "$baseline_commit" "$baseline_tree"
    git -C "$repo_root" ls-tree -r --name-only -z "$baseline_commit" >"$baseline_tracked" ||
      die "cannot list baseline tracked files"
  else
    # Unborn HEAD — first commit of a fresh repo. No prior snapshot exists,
    # so the ratchet starts from an empty manifest: nothing to inherit,
    # nothing to regress. The candidate scan below still runs, so the report
    # shows the commit's own duplication stats.
    : >"$baseline_tracked"
  fi

  case "$mode" in
    staged)
      mkdir -p "$candidate_tree" || die "cannot create staged snapshot directory"
      git -C "$repo_root" checkout-index --all --prefix="$candidate_tree/" ||
        die "cannot materialize staged index"
      git -C "$repo_root" ls-files --cached -z >"$candidate_tracked" ||
        die "cannot list staged tracked files"
      ;;
    changes)
      materialize_commit HEAD "$candidate_tree"
      git -C "$repo_root" ls-tree -r --name-only -z HEAD >"$candidate_tracked" ||
        die "cannot list candidate tracked files"
      ;;
  esac

  filter_code_files "$baseline_tracked" "$baseline_tree" "$baseline_code"
  filter_code_files "$candidate_tracked" "$candidate_tree" "$candidate_code"
  scan_snapshot "$baseline_code" "$baseline_out" "baseline"
  scan_snapshot "$candidate_code" "$candidate_out" "candidate"

  if [ -n "$baseline_commit" ]; then
    compare_status=0
    node "$JSCPD_COMPARE" \
      --baseline-report "$baseline_out/jscpd-report.json" \
      --candidate-report "$candidate_out/jscpd-report.json" \
      --baseline-root "$baseline_tree" \
      --candidate-root "$candidate_tree" \
      --changes "$changes_file" >"$j_compare_file" || compare_status=$?
    case "$compare_status" in
      0 | 1) ;;
      *) die "jscpd snapshot comparison failed" ;;
    esac
    jq -e '
      .summary
      | (.baselineClones | type == "number")
        and (.candidateClones | type == "number")
        and (.relevantClones | type == "number")
        and (.inheritedClones | type == "number")
        and (.regressions | type == "number")
    ' "$j_compare_file" >/dev/null 2>&1 || die "jscpd comparison emitted invalid JSON"

    j_relevant="$(jq -r '.summary.relevantClones' "$j_compare_file")"
    j_inherited="$(jq -r '.summary.inheritedClones' "$j_compare_file")"
    j_regressions="$(jq -r '.summary.regressions' "$j_compare_file")"
  else
    # Unborn HEAD: the commit establishes the ratchet — every clone in it is
    # baseline by definition, so none can be a regression.
    j_compare_file=""
    j_relevant=0
    j_inherited=0
    j_regressions=0
  fi

  j_report="$candidate_out/jscpd-report.json"
  j_pct="$(jq -r '.statistics.total.percentage' "$j_report")"
  j_clones="$(jq -r '.statistics.total.clones' "$j_report")"
  j_dup="$(jq -r '.statistics.total.duplicatedLines' "$j_report")"
fi

# --- verdict ---
fail=0
reasons=()
if [ "$a_errors" -gt "$AISLOP_MAX_ERRORS" ]; then
  fail=1; reasons+=("aislop: $a_errors error(s) > max $AISLOP_MAX_ERRORS")
fi
if [ "$AISLOP_MIN_SCORE" -gt 0 ] && [ -n "$a_score" ] && [ "$a_score" -lt "$AISLOP_MIN_SCORE" ]; then
  fail=1; reasons+=("aislop: score $a_score < min $AISLOP_MIN_SCORE")
fi
if [ "$mode" = "path" ]; then
  if awk "BEGIN{exit !($j_pct > $JSCPD_MAX_PCT)}"; then
    fail=1; reasons+=("jscpd: ${j_pct}% duplication > max ${JSCPD_MAX_PCT}% ($j_clones clone(s), $j_dup line(s))")
  fi
elif [ "$j_regressions" -gt 0 ]; then
  fail=1; reasons+=("jscpd: $j_regressions new, expanded, or additional clone occurrence(s)")
fi

# --- report ---
echo "── code-slop gate ─────────────────────────────"
printf 'aislop : score %s · %s error(s) · %s warning(s)\n' "${a_score:-n/a}" "$a_errors" "$a_warns"
[ "$baseline_dependency_errors" -gt 0 ] && printf 'baseline: %s unchanged dependency error(s) reported as warning(s)\n' "$baseline_dependency_errors"
printf 'jscpd  : %s%% duplication · %s clone(s) · %s line(s)\n' "$j_pct" "$j_clones" "$j_dup"
if [ "$mode" != "path" ]; then
  if [ -n "$baseline_commit" ]; then
    printf 'ratchet: %s relevant · %s inherited · %s regression(s)\n' \
      "$j_relevant" "$j_inherited" "$j_regressions"
  else
    printf 'ratchet: first commit on unborn HEAD — baseline established, nothing to regress\n'
  fi
fi
if [ "$a_errors" -gt 0 ] || [ "$a_warns" -gt 0 ]; then
  echo "findings:"
  jq -r '.diagnostics[]? | "  \(.severity|ascii_upcase)  \(.filePath):\(.line)  \(.rule) — \(.message)"' <<<"$aislop_json" 2>/dev/null | head -20
fi
if [ "$j_regressions" -gt 0 ]; then
  echo "clone regressions:"
  jq -r '.regressions[:20][] | "  \(.format) · \(.tokens) token(s) · \(.endpoints[0].path) ↔ \(.endpoints[1].path)"' \
    "$j_compare_file"
fi
echo "───────────────────────────────────────────────"
if [ "$fail" -eq 1 ]; then
  echo "✗ FAIL"
  printf '  %s\n' "${reasons[@]}"
  exit 1
fi
echo "✓ PASS — no code-slop over threshold."
exit 0
