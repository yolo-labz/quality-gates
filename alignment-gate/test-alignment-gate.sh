#!/usr/bin/env bash
#
# test-alignment-gate.sh — discrimination tests for the alignment gate.
#
# This gate was the last of the three with no suite of its own, while being a
# REQUIRED check on wa. That is how a real bug survived in it until shellcheck
# was turned on (#5): `{ A && B || C; }` used as if-then-else, so a failing
# path scan also ran the diff scan. A suite would have caught it; hand-reading
# did not.
#
# Every rule here is paired with the near-miss that must NOT fire. A gate that
# flags everything gets switched off and protects nothing; a gate that flags
# nothing certifies unfinished work. Neither is caught by testing one direction.
#
# Exit 0 = all pass.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/alignment-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# Each case gets its own directory: the gate scans a whole tree in path mode,
# so a shared one would leak every fixture into every case.
mkcase() {
  local dir="$WORK/$1"
  mkdir -p "$dir" || return 1
  printf '%s\n' "$dir"
}

# run <dir> [VAR=value ...] -> exit code, output in $OUT
run() {
  local dir="$1"; shift
  OUT="$(cd "$dir" && env "$@" "$GATE" . 2>&1)"
  return $?
}

check() { # check <name> <want-exit> <dir> [VAR=value ...]
  local name="$1" want="$2" dir="$3"; shift 3
  local got=0
  run "$dir" "$@" || got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %-52s exit=%s\n' "$name" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-52s want=%s got=%s\n%s\n' "$name" "$want" "$got" "$OUT"
  fi
}

# checkrule <name> <dir> <rule> — the finding must name this rule exactly.
# "some finding" is not enough: a rule can silently stop working while a
# neighbour keeps the suite green.
checkrule() {
  local name="$1" dir="$2" rule="$3"
  run "$dir" || true
  if printf '%s' "$OUT" | grep -q "$rule"; then
    pass=$((pass + 1)); printf '  ok   %-52s %s\n' "$name" "$rule"
  else
    fail=$((fail + 1)); printf '  FAIL %-52s expected rule %s\n%s\n' "$name" "$rule" "$OUT"
  fi
}

# ---------------------------------------------------------------------------
echo "clean code is silent (over-eagerness check)"
d="$(mkcase clean)"
printf 'export function add(a: number, b: number) {\n  return a + b;\n}\n' >"$d/a.ts"
check "finished code passes" 0 "$d"

# ---------------------------------------------------------------------------
echo "each incomplete-work rule fires, by name"
d="$(mkcase todo)"
printf 'export function f() {\n  // TODO: handle the error path\n  return 1;\n}\n' >"$d/a.ts"
check     "TODO fails the gate"        1 "$d"
checkrule "TODO names its rule"          "$d" "incomplete/todo"

d="$(mkcase notimpl)"
printf 'def handler():\n    raise NotImplementedError()\n' >"$d/a.py"
check     "NotImplementedError fails"  1 "$d"
checkrule "not-implemented names rule"   "$d" "incomplete/not-implemented"

d="$(mkcase stub)"
printf 'export function f() {\n  throw new Error("not yet implement this");\n}\n' >"$d/a.ts"
checkrule "throw-stub names its rule"    "$d" "incomplete/throw-stub"

d="$(mkcase ellipsis)"
printf 'def handler():\n    ...\n' >"$d/a.py"
check     "ellipsis body fails"        1 "$d"
checkrule "ellipsis names its rule"      "$d" "incomplete/ellipsis-body"

d="$(mkcase suppress)"
printf 'const x: any = load(); // eslint-disable-line\n' >"$d/a.ts"
check     "lint suppression fails"     1 "$d"
checkrule "lint-suppressed names rule"   "$d" "align/lint-suppressed"

# ---------------------------------------------------------------------------
echo "a skipped test is a finding — but only in a test file"
d="$(mkcase skip-test)"
printf 'describe.skip("payments", () => {});\n' >"$d/pay.test.ts"
check     "skipped test in a test file fails"  1 "$d"
checkrule "test/skip names its rule"             "$d" "test/skip"

# The same text in production code is not a skipped test — most often it is a
# string, a comment, or an unrelated identifier. Flagging it teaches people to
# ignore the gate.
d="$(mkcase skip-nontest)"
printf 'const doc = "use describe.skip to disable a suite";\n' >"$d/docs.ts"
check "same text outside a test file is ignored" 0 "$d"

# ---------------------------------------------------------------------------
echo "severity split: a warn-tier rule must not fail a build on its own"
d="$(mkcase debug)"
printf 'export function f() {\n  console.log("here");\n}\n' >"$d/a.ts"
check "debug artifact is warn-tier by default"   0 "$d"
check "…and fails when opted in"                 1 "$d" ALIGN_FAIL_ON_DEBUG=1

# ---------------------------------------------------------------------------
echo "toggles downgrade instead of disabling (report-only ratchet)"
d="$(mkcase toggle)"
printf '// TODO: later\nexport const x = 1;\n' >"$d/a.ts"
check "TODO fails at default strictness"         1 "$d"
check "…downgrades to a warning when opted out"  0 "$d" ALIGN_FAIL_ON_TODO=0
# The finding must still be REPORTED after the downgrade — a toggle that
# silences the finding entirely is indistinguishable from a broken rule, and
# the ratchet depends on seeing what you have not fixed yet.
run "$d" ALIGN_FAIL_ON_TODO=0 || true
if printf '%s' "$OUT" | grep -q "incomplete/todo"; then
  pass=$((pass + 1)); printf '  ok   %-52s still reported\n' "downgraded finding stays visible"
else
  fail=$((fail + 1)); printf '  FAIL %-52s finding vanished\n%s\n' "downgraded finding stays visible" "$OUT"
fi

# ---------------------------------------------------------------------------
echo "file selection: only code, never docs or the gate's own source"
d="$(mkcase meta)"
printf '# TODO: write this section\n' >"$d/README.md"
check "a TODO in markdown is not code debt"      0 "$d"

d="$(mkcase ext)"
printf 'TODO: not a source file\n' >"$d/notes.log"
check "unknown extensions are skipped"           0 "$d"

# The gate's own pattern table contains every string it looks for, so scanning
# itself would fail every run.
d="$(mkcase selfscan)"
cp "$GATE" "$d/alignment-gate.sh"
check "the gate does not flag its own source"    0 "$d"

# ---------------------------------------------------------------------------
echo "blast radius counts files, and is off by default"
d="$(mkcase blast)"
for i in 1 2 3; do printf 'export const x%s = %s;\n' "$i" "$i" >"$d/f$i.ts"; done
check "3 clean files pass with the limit off"    0 "$d"
check "…and fail when the limit is 2"            1 "$d" ALIGN_MAX_FILES=2
check "…and pass when the limit is 3"            0 "$d" ALIGN_MAX_FILES=3

# ---------------------------------------------------------------------------
echo "path mode reads the tree, never the git diff (#5 regression)"
# The bug: `{ [ "$mode" = "path" ] && emit_path || emit_diff; }` ran emit_diff
# whenever emit_path returned non-zero, appending diff output to a path scan.
# Here the worktree is clean and the ONLY debt is in a file that is committed,
# so a path scan must find it while a diff of the same repo finds nothing.
d="$(mkcase pathmode)"
(
  cd "$d" || exit 1
  git init -q -b main
  git config user.name t; git config user.email t@t
  printf '// TODO: committed debt\nexport const x = 1;\n' >a.ts
  git add -A
  git -c core.hooksPath=/dev/null commit -qm base
) >/dev/null 2>&1
check "path mode sees committed debt"            1 "$d"
# Same repo, diff mode against its own HEAD: nothing changed, so nothing to
# report. If path and diff sources were ever concatenated, this would fail.
got=0
OUT="$(cd "$d" && "$GATE" --base HEAD 2>&1)" || got=$?
if [ "$got" -eq 0 ]; then
  pass=$((pass + 1)); printf '  ok   %-52s exit=0\n' "diff mode against HEAD reports nothing"
else
  fail=$((fail + 1)); printf '  FAIL %-52s want=0 got=%s\n%s\n' "diff mode against HEAD reports nothing" "$got" "$OUT"
fi

# ---------------------------------------------------------------------------
echo "usage errors are exit 2, distinct from a finding"
d="$(mkcase usage)"
got=0
OUT="$(cd "$d" && "$GATE" --nonsense 2>&1)" || got=$?
if [ "$got" -eq 2 ]; then
  pass=$((pass + 1)); printf '  ok   %-52s exit=2\n' "unknown flag is a tooling error"
else
  fail=$((fail + 1)); printf '  FAIL %-52s want=2 got=%s\n' "unknown flag is a tooling error" "$got"
fi

# ---------------------------------------------------------------------------
printf '\npass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
