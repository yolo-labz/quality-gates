#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="$SCRIPT_DIR/dependency-baseline.jq"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/base.json" <<'JSON'
{"summary":{"errors":2,"warnings":0},"diagnostics":[
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"lodash (high)","detail":"npm"},
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"left-pad (high)","detail":"npm"}
]}
JSON

actual="$(jq --slurpfile baseline "$WORK/base.json" --arg base HEAD -f "$FILTER" <<'JSON'
{"summary":{"errors":3,"warnings":1},"diagnostics":[
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"lodash (high)","detail":"npm"},
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"minimist (high)","detail":"npm"},
  {"engine":"ai-slop","rule":"correctness/swallowed-exception","severity":"error","message":"empty catch"},
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"warning","message":"uuid (moderate)","detail":"npm"}
]}
JSON
)"

jq -e '
  .summary == {errors: 2, warnings: 2}
  and ([.diagnostics[] | select(.message == "lodash (high) — baseline on HEAD" and .severity == "warning")] | length) == 1
  and ([.diagnostics[] | select(.message == "minimist (high)" and .severity == "error")] | length) == 1
  and ([.diagnostics[] | select(.message | contains("left-pad"))] | length) == 0
  and ([.diagnostics[] | select(.rule == "correctness/swallowed-exception" and .severity == "error")] | length) == 1
' >/dev/null <<<"$actual"

echo "dependency baseline ratchet: PASS"

# Regression (2026-11-02): a pre-existing advisory whose *prose* changed must stay a
# baseline warning. npm flips `fixAvailable` from `true` to a concrete {name,version}
# as soon as the other advisories in the tree are fixed, and aislop folds that hint
# into the message; keying the fingerprint on the whole message re-failed zod as new.
cat >"$WORK/base-prose.json" <<'JSON'
{"summary":{"errors":2,"warnings":0},"diagnostics":[
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"zod (high) — transitive — may need override or parent upgrade","detail":"npm"},
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"minimatch (moderate) — transitive — may need override or parent upgrade","detail":"npm"}
]}
JSON

actual="$(jq --slurpfile baseline "$WORK/base-prose.json" --arg base origin/main -f "$FILTER" <<'JSON'
{"summary":{"errors":4,"warnings":0},"diagnostics":[
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"zod (high) — transitive — needs override or parent upgrade — upgrade to n8n-workflow@1.75.1","detail":"npm"},
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"minimatch (high) — transitive — needs override or parent upgrade","detail":"npm"},
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"zod (high) — transitive — needs override or parent upgrade (2 advisories)","detail":"npm"},
  {"engine":"security","rule":"security/vulnerable-dependency","severity":"error","message":"axios (high) — transitive — needs override or parent upgrade","detail":"npm"}
]}
JSON
)"

jq -e '
  .summary == {errors: 3, warnings: 1}
  and ([.diagnostics[] | select(.message | startswith("zod (high) — transitive — needs override or parent upgrade — upgrade to")) | select(.severity == "warning" and (.message | endswith("— baseline on origin/main")))] | length) == 1
  and ([.diagnostics[] | select(.message | startswith("minimatch (high)")) | select(.severity == "error")] | length) == 1
  and ([.diagnostics[] | select(.message | contains("(2 advisories)")) | select(.severity == "error")] | length) == 1
  and ([.diagnostics[] | select(.message | startswith("axios (high)")) | select(.severity == "error")] | length) == 1
' >/dev/null <<<"$actual"

echo "dependency baseline fingerprint: PASS"
