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

actual="$(jq --slurpfile baseline "$WORK/base.json" --arg base origin/main -f "$FILTER" <<'JSON'
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
  and ([.diagnostics[] | select(.message == "lodash (high) — baseline on origin/main" and .severity == "warning")] | length) == 1
  and ([.diagnostics[] | select(.message == "minimist (high)" and .severity == "error")] | length) == 1
  and ([.diagnostics[] | select(.message | contains("left-pad"))] | length) == 0
  and ([.diagnostics[] | select(.rule == "correctness/swallowed-exception" and .severity == "error")] | length) == 1
' >/dev/null <<<"$actual"

echo "dependency baseline ratchet: PASS"
