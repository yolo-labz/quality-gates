#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARE="$SCRIPT_DIR/jscpd-snapshot-compare.js"
GATE="$SCRIPT_DIR/code-slop-gate.sh"
FILTER="$SCRIPT_DIR/dependency-baseline.jq"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

fail() {
  printf 'jscpd ratchet fixture: FAIL — %s\n' "$*" >&2
  exit 1
}

# Stub executables are generated at runtime, so patchShebangs cannot reach them.
# The Nix build sandbox has no /usr/bin/env, so an unpatched `#!/usr/bin/env
# bash` stub is silently unexecutable and the gate only reports the downstream
# symptom ("aislop emitted no parseable JSON").
BASH_BIN="$(command -v bash)"
absolute_shebang() {
  sed -i "1s|^#!/usr/bin/env bash\$|#!$BASH_BIN|" "$@"
}

write_report() {
  local output="$1"
  local root="$2"
  local tokens="$3"
  local first_path="$4"
  local first_span="$5"
  local second_path="$6"
  local second_span="$7"
  local count="${8:-1}"

  node - "$output" "$root" "$tokens" "$first_path" "$first_span" \
    "$second_path" "$second_span" "$count" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [output, root, tokenText, firstPath, firstSpan, secondPath, secondSpan, countText] = process.argv.slice(2);

function endpoint(relativePath, span) {
  const name = path.resolve(root, relativePath);
  const contents = fs.readFileSync(name);
  const needle = Buffer.from(span);
  const start = contents.indexOf(needle);
  if (start < 0) throw new Error(`span not found in ${relativePath}`);
  return {
    name,
    startLoc: { position: start },
    endLoc: { position: start + needle.length },
  };
}

const duplicate = {
  format: 'typescript',
  tokens: Number(tokenText),
  firstFile: endpoint(firstPath, firstSpan),
  secondFile: endpoint(secondPath, secondSpan),
};
const duplicates = Array.from({ length: Number(countText) }, () => duplicate);
const report = {
  duplicates,
  statistics: {
    total: {
      clones: duplicates.length,
      duplicatedLines: duplicates.length,
      percentage: duplicates.length === 0 ? 0 : 10,
    },
  },
};
fs.writeFileSync(output, `${JSON.stringify(report)}\n`);
NODE
}

write_empty_report() {
  printf '%s\n' \
    '{"duplicates":[],"statistics":{"total":{"clones":0,"duplicatedLines":0,"percentage":0}}}' \
    >"$1"
}

write_manifest() {
  local output="$1"
  shift
  : >"$output"
  printf '%s\0' "$@" >"$output"
}

run_compare() {
  local label="$1"
  local expected="$2"
  local baseline_report="$3"
  local candidate_report="$4"
  local baseline_root="$5"
  local candidate_root="$6"
  local changes="$7"
  local actual=0
  local output="$WORK/compare-output.json"

  if node "$COMPARE" \
    --baseline-report "$baseline_report" \
    --candidate-report "$candidate_report" \
    --baseline-root "$baseline_root" \
    --candidate-root "$candidate_root" \
    --changes "$changes" >"$output" 2>"$WORK/compare-error"; then
    actual=0
  else
    actual=$?
  fi
  [ "$actual" -eq "$expected" ] ||
    fail "$label returned $actual, expected $expected: $(<"$WORK/compare-error")"
  if [ "$expected" -eq 1 ]; then
    jq -e '.summary.regressions > 0' "$output" >/dev/null ||
      fail "$label did not report a clone regression"
  fi
}

new_compare_case() {
  local name="$1"
  local case_root="$WORK/$name"
  mkdir -p "$case_root/baseline" "$case_root/candidate"
  printf '%s\n' "$case_root"
}

# Exact inherited content survives ordinary edits.
case_root="$(new_compare_case inherited)"
printf 'shared();\n' >"$case_root/baseline/a.ts"
printf 'shared();\n' >"$case_root/baseline/b.ts"
cp "$case_root/baseline/a.ts" "$case_root/candidate/a.ts"
cp "$case_root/baseline/b.ts" "$case_root/candidate/b.ts"
write_report "$case_root/base.json" "$case_root/baseline" 10 a.ts 'shared();' b.ts 'shared();'
write_report "$case_root/candidate.json" "$case_root/candidate" 10 a.ts 'shared();' b.ts 'shared();'
write_manifest "$case_root/changes.z" M a.ts
run_compare inherited 0 "$case_root/base.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"

# Deleting unrelated bytes and moving line numbers leave span provenance intact.
case_root="$(new_compare_case deletion)"
printf 'unrelated();\nshared();\n' >"$case_root/baseline/a.ts"
printf 'shared();\n' >"$case_root/baseline/b.ts"
printf 'shared();\n' >"$case_root/candidate/a.ts"
cp "$case_root/baseline/b.ts" "$case_root/candidate/b.ts"
write_report "$case_root/base.json" "$case_root/baseline" 10 a.ts 'shared();' b.ts 'shared();'
write_report "$case_root/candidate.json" "$case_root/candidate" 10 a.ts 'shared();' b.ts 'shared();'
write_manifest "$case_root/changes.z" M a.ts
run_compare deletion-only 0 "$case_root/base.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"

case_root="$(new_compare_case line-movement)"
printf 'shared();\n' >"$case_root/baseline/a.ts"
printf 'shared();\n' >"$case_root/baseline/b.ts"
printf 'moved();\nshared();\n' >"$case_root/candidate/a.ts"
cp "$case_root/baseline/b.ts" "$case_root/candidate/b.ts"
write_report "$case_root/base.json" "$case_root/baseline" 10 a.ts 'shared();' b.ts 'shared();'
write_report "$case_root/candidate.json" "$case_root/candidate" 10 a.ts 'shared();' b.ts 'shared();'
write_manifest "$case_root/changes.z" M a.ts
run_compare line-movement 0 "$case_root/base.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"

# Rename destinations translate back to baseline provenance paths.
case_root="$(new_compare_case rename)"
printf 'shared();\n' >"$case_root/baseline/a.ts"
printf 'shared();\n' >"$case_root/baseline/b.ts"
cp "$case_root/baseline/a.ts" "$case_root/candidate/renamed.ts"
cp "$case_root/baseline/b.ts" "$case_root/candidate/b.ts"
write_report "$case_root/base.json" "$case_root/baseline" 10 a.ts 'shared();' b.ts 'shared();'
write_report "$case_root/candidate.json" "$case_root/candidate" 10 renamed.ts 'shared();' b.ts 'shared();'
write_manifest "$case_root/changes.z" R100 a.ts renamed.ts
run_compare rename 0 "$case_root/base.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"

# New clones fail whether the other endpoint changed or remained untouched.
case_root="$(new_compare_case changed-unchanged)"
printf 'first();\n' >"$case_root/baseline/a.ts"
printf 'shared();\n' >"$case_root/baseline/b.ts"
printf 'shared();\n' >"$case_root/candidate/a.ts"
cp "$case_root/baseline/b.ts" "$case_root/candidate/b.ts"
write_empty_report "$case_root/base.json"
write_report "$case_root/candidate.json" "$case_root/candidate" 10 a.ts 'shared();' b.ts 'shared();'
write_manifest "$case_root/changes.z" M a.ts
run_compare changed-unchanged 1 "$case_root/base.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"

case_root="$(new_compare_case changed-changed)"
printf 'first();\n' >"$case_root/baseline/a.ts"
printf 'second();\n' >"$case_root/baseline/b.ts"
printf 'shared();\n' >"$case_root/candidate/a.ts"
printf 'shared();\n' >"$case_root/candidate/b.ts"
write_empty_report "$case_root/base.json"
write_report "$case_root/candidate.json" "$case_root/candidate" 10 a.ts 'shared();' b.ts 'shared();'
write_manifest "$case_root/changes.z" M a.ts M b.ts
run_compare changed-changed 1 "$case_root/base.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"

# Expanded blocks and extra identical occurrences cannot consume baseline evidence.
case_root="$(new_compare_case expansion)"
printf 'shared();\n' >"$case_root/baseline/a.ts"
printf 'shared();\n' >"$case_root/baseline/b.ts"
printf 'shared();extended();\n' >"$case_root/candidate/a.ts"
printf 'shared();extended();\n' >"$case_root/candidate/b.ts"
write_report "$case_root/base.json" "$case_root/baseline" 10 a.ts 'shared();' b.ts 'shared();'
write_report "$case_root/candidate.json" "$case_root/candidate" 20 a.ts 'shared();extended();' b.ts 'shared();extended();'
write_manifest "$case_root/changes.z" M a.ts M b.ts
run_compare expansion 1 "$case_root/base.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"

case_root="$(new_compare_case multiplicity)"
printf 'shared();\n' >"$case_root/baseline/a.ts"
printf 'shared();\n' >"$case_root/baseline/b.ts"
cp "$case_root/baseline/a.ts" "$case_root/candidate/a.ts"
cp "$case_root/baseline/b.ts" "$case_root/candidate/b.ts"
write_report "$case_root/base.json" "$case_root/baseline" 10 a.ts 'shared();' b.ts 'shared();' 1
write_report "$case_root/candidate.json" "$case_root/candidate" 10 a.ts 'shared();' b.ts 'shared();' 2
write_manifest "$case_root/changes.z" M a.ts
run_compare multiplicity 1 "$case_root/base.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"

# Missing/malformed reports and invalid endpoint bounds fail as tooling errors.
case_root="$(new_compare_case invalid-input)"
printf 'shared();\n' >"$case_root/baseline/a.ts"
printf 'shared();\n' >"$case_root/baseline/b.ts"
cp "$case_root/baseline/a.ts" "$case_root/candidate/a.ts"
cp "$case_root/baseline/b.ts" "$case_root/candidate/b.ts"
write_report "$case_root/base.json" "$case_root/baseline" 10 a.ts 'shared();' b.ts 'shared();'
write_report "$case_root/candidate.json" "$case_root/candidate" 10 a.ts 'shared();' b.ts 'shared();'
write_manifest "$case_root/changes.z" M a.ts
run_compare missing-baseline 2 "$case_root/missing.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"
printf '{\n' >"$case_root/malformed.json"
run_compare malformed-candidate 2 "$case_root/base.json" "$case_root/malformed.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"
jq '.duplicates[0].firstFile.endLoc.position = 99999' "$case_root/base.json" >"$case_root/bad-base.json"
run_compare invalid-baseline-position 2 "$case_root/bad-base.json" "$case_root/candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"
jq '.duplicates[0].secondFile.endLoc.position = 99999' "$case_root/candidate.json" >"$case_root/bad-candidate.json"
run_compare invalid-candidate-position 2 "$case_root/base.json" "$case_root/bad-candidate.json" \
  "$case_root/baseline" "$case_root/candidate" "$case_root/changes.z"

# Build an isolated package facade so orchestration tests use deterministic fake
# engine reports while exercising the real snapshot and comparison code.
gate_fixture="$WORK/gate-package"
mkdir -p "$gate_fixture/node_modules/.bin"
cp "$GATE" "$COMPARE" "$FILTER" "$gate_fixture/"
cat >"$gate_fixture/node_modules/.bin/aislop" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"summary":{"errors":0,"warnings":0},"score":100,"diagnostics":[]}'
SH
cat >"$gate_fixture/node_modules/.bin/jscpd" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
paths=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --reporters | --min-tokens | --threshold) shift 2 ;;
    --silent | --absolute | --no-gitignore) shift ;;
    *) paths+=("$1"); shift ;;
  esac
done
[ -n "$output" ]
mkdir -p "$output"
node - "$output/jscpd-report.json" "${paths[@]}" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [output, ...inputs] = process.argv.slice(2);
const files = [];

function collect(input) {
  const stat = fs.statSync(input);
  if (stat.isDirectory()) {
    for (const entry of fs.readdirSync(input)) collect(path.join(input, entry));
  } else if (stat.isFile() && /\.(?:ts|tsx|js|jsx|py|go|rs|rb|php)$/.test(input)) {
    files.push(path.resolve(input));
  }
}
for (const input of inputs) collect(input);

const duplicates = [];
for (let first = 0; first < files.length; first += 1) {
  const firstContents = fs.readFileSync(files[first]);
  if (firstContents.length === 0) continue;
  for (let second = first + 1; second < files.length; second += 1) {
    const secondContents = fs.readFileSync(files[second]);
    if (!firstContents.equals(secondContents)) continue;
    duplicates.push({
      format: 'typescript',
      tokens: firstContents.length,
      firstFile: {
        name: files[first],
        startLoc: { position: 0 },
        endLoc: { position: firstContents.length },
      },
      secondFile: {
        name: files[second],
        startLoc: { position: 0 },
        endLoc: { position: secondContents.length },
      },
    });
  }
}
fs.writeFileSync(output, `${JSON.stringify({
  duplicates,
  statistics: {
    total: {
      clones: duplicates.length,
      duplicatedLines: duplicates.length,
      percentage: duplicates.length === 0 ? 0 : 100,
    },
  },
})}\n`);
NODE
SH
chmod +x "$gate_fixture/code-slop-gate.sh" \
  "$gate_fixture/node_modules/.bin/aislop" "$gate_fixture/node_modules/.bin/jscpd"
absolute_shebang "$gate_fixture/node_modules/.bin/aislop" \
  "$gate_fixture/node_modules/.bin/jscpd"

new_repo() {
  local name="$1"
  local repo="$WORK/$name-repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b feature
  git -C "$repo" config user.name Fixture
  git -C "$repo" config user.email fixture@example.invalid
  printf 'alpha();\n' >"$repo/a.ts"
  printf 'beta();\n' >"$repo/b.ts"
  git -C "$repo" add a.ts b.ts
  # Hookless: the universal NixOS pre-commit hooks (code-slop-gate /
  # alignment-gate) run on EVERY repo, and this fixture's FIRST commit has
  # no baseline HEAD for them to resolve — the exact unborn-HEAD case this
  # suite covers below. The fixture exercises the gate directly via
  # `run_gate`; the host hook must not intercept its setup commits.
  git -C "$repo" -c core.hooksPath=/dev/null commit -qm baseline
  printf '%s\n' "$repo"
}

run_gate() {
  local label="$1"
  local expected="$2"
  local repo="$3"
  shift 3
  local actual=0
  if (cd "$repo" && "$gate_fixture/code-slop-gate.sh" "$@") \
    >"$WORK/gate-output" 2>"$WORK/gate-error"; then
    actual=0
  else
    actual=$?
  fi
  [ "$actual" -eq "$expected" ] ||
    fail "$label returned $actual, expected $expected: $(<"$WORK/gate-error")"
}

# The index is authoritative in both staged/unstaged directions.
repo="$(new_repo staged-regression)"
printf 'beta();\n' >"$repo/a.ts"
git -C "$repo" add a.ts
printf 'alpha();\n' >"$repo/a.ts"
run_gate staged-index-regression 1 "$repo" --staged

repo="$(new_repo staged-clean)"
printf 'gamma();\n' >"$repo/a.ts"
git -C "$repo" add a.ts
printf 'beta();\n' >"$repo/a.ts"
run_gate unstaged-regression-ignored 0 "$repo" --staged

# Unborn HEAD — the first commit of a fresh repo (git init, no baseline
# commit yet). The gate must not die on `HEAD^{commit}`, and the commit's
# own clones establish the ratchet instead of failing it: regression for the
# fixture repos that commit straight from `git init` (bilu-bridge
# test_household_desfaz, reported 06/08/2026 after the PR #974 gate landed).
repo="$WORK/unborn-repo"
mkdir -p "$repo"
git -C "$repo" init -q -b feature
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.invalid
printf 'shared();\n' >"$repo/a.ts"
printf 'shared();\n' >"$repo/b.ts"
git -C "$repo" add a.ts b.ts
run_gate unborn-head-first-commit 0 "$repo" --staged

# Both branch tips contain the clone, but their merge base does not. Comparing
# against the base tip would pass; comparing against the resolved merge base fails.
repo="$(new_repo divergent)"
git -C "$repo" branch base
printf 'beta();\n' >"$repo/a.ts"
git -C "$repo" add a.ts
git -C "$repo" -c core.hooksPath=/dev/null commit -qm feature-clone
git -C "$repo" switch -q base
printf 'beta();\n' >"$repo/a.ts"
git -C "$repo" add a.ts
git -C "$repo" -c core.hooksPath=/dev/null commit -qm base-clone
git -C "$repo" switch -q feature
run_gate divergent-merge-base 1 "$repo" --changes --base base
run_gate missing-merge-base 2 "$repo" --changes --base absent

# A checkout-index failure cannot silently substitute worktree content.
repo="$(new_repo extraction)"
printf 'gamma();\n' >"$repo/a.ts"
git -C "$repo" add a.ts
fake_bin="$WORK/failing-git"
mkdir -p "$fake_bin"
real_git="$(command -v git)"
cat >"$fake_bin/git" <<'SH'
#!/usr/bin/env bash
for argument in "$@"; do
  [ "$argument" != "checkout-index" ] || exit 42
done
exec "$REAL_GIT" "$@"
SH
chmod +x "$fake_bin/git"
absolute_shebang "$fake_bin/git"
actual=0
if (cd "$repo" && REAL_GIT="$real_git" PATH="$fake_bin:$PATH" \
  "$gate_fixture/code-slop-gate.sh" --staged) >"$WORK/gate-output" 2>"$WORK/gate-error"; then
  actual=0
else
  actual=$?
fi
[ "$actual" -eq 2 ] || fail "snapshot extraction failure returned $actual, expected 2"

# Manual/path mode still applies the absolute aggregate percentage threshold.
manual="$WORK/manual"
mkdir -p "$manual"
printf 'manual();\n' >"$manual/a.ts"
printf 'manual();\n' >"$manual/b.ts"
run_gate manual-threshold 1 "$repo" "$manual"
grep -F 'duplication > max 0%' "$WORK/gate-output" >/dev/null ||
  fail "manual mode did not enforce JSCPD_MAX_PCT"

# Findings about code the repository does not own must not fail it, and must not
# quietly disappear either. Measured 10/08/2026 in yolo-labz/fand: a --staged
# scan of ONE changed workflow file returned 341 aislop findings, 338 of them
# from crates under ~/.cargo/registry, so every local commit there failed on
# third-party code. The pair below is the discrimination: the same gate that
# ignores a foreign path must still fail on an in-repo one, or the filter is
# just a mute button.
foreign_fixture="$WORK/gate-foreign"
mkdir -p "$foreign_fixture/node_modules/.bin"
cp "$GATE" "$COMPARE" "$FILTER" "$foreign_fixture/"
cp "$gate_fixture/node_modules/.bin/jscpd" "$foreign_fixture/node_modules/.bin/jscpd"
cat >"$foreign_fixture/node_modules/.bin/aislop" <<'SH'
#!/usr/bin/env bash
# One error outside any repository, one warning inside it.
printf '%s\n' '{"summary":{"errors":1,"warnings":1},"score":10,"diagnostics":[
  {"engine":"lint","rule":"clippy/E0658","severity":"error","filePath":"/nowhere/registry/src/dep-1.0.0/src/lib.rs","line":7,"message":"unstable library feature"},
  {"engine":"ai-slop","rule":"style/nit","severity":"warning","filePath":"a.ts","line":1,"message":"in-repo warning"}
]}'
SH
cat >"$foreign_fixture/node_modules/.bin/aislop-inrepo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"summary":{"errors":1,"warnings":0},"score":10,"diagnostics":[
  {"engine":"ai-slop","rule":"correctness/swallowed-exception","severity":"error","filePath":"a.ts","line":1,"message":"in-repo error"}
]}'
SH
chmod +x "$foreign_fixture/code-slop-gate.sh" \
  "$foreign_fixture/node_modules/.bin/aislop" "$foreign_fixture/node_modules/.bin/aislop-inrepo"
absolute_shebang "$foreign_fixture/node_modules/.bin/aislop" \
  "$foreign_fixture/node_modules/.bin/aislop-inrepo"

repo="$(new_repo foreign-findings)"
printf 'gamma();\n' >"$repo/a.ts"
git -C "$repo" add a.ts

actual=0
(cd "$repo" && "$foreign_fixture/code-slop-gate.sh" --staged) \
  >"$WORK/gate-output" 2>"$WORK/gate-error" || actual=$?
[ "$actual" -eq 0 ] ||
  fail "a finding outside the repo failed the gate (exit $actual): $(<"$WORK/gate-error")"
grep -F 'ignored 1 finding(s) outside' "$WORK/gate-error" >/dev/null ||
  fail "the gate dropped a foreign finding without saying so"

# Same fixture, same shape, one in-repo error: must still fail.
cp "$foreign_fixture/node_modules/.bin/aislop-inrepo" "$foreign_fixture/node_modules/.bin/aislop"
actual=0
(cd "$repo" && "$foreign_fixture/code-slop-gate.sh" --staged) \
  >"$WORK/gate-output" 2>"$WORK/gate-error" || actual=$?
[ "$actual" -eq 1 ] ||
  fail "an in-repo error did not fail the gate (exit $actual)"

printf '%s\n' 'jscpd snapshot ratchet fixtures: PASS'
