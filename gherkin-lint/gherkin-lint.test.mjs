#!/usr/bin/env node
// Discrimination tests for gherkin-lint.
//
// The failure mode this guards against is a linter that flags everything (so
// nobody runs it) or nothing (so it certifies bad specs). Neither is caught by
// running it on bad input alone. So:
//
//   - fixtures/allowlist.feature is REAL, good input, taken verbatim from
//     yolo-labz/wa#339. It must produce ZERO findings. If a rule fires here,
//     that rule is over-eager and would reject honest work.
//   - fixtures/broken.feature must produce EXACTLY the expected rule set, by
//     name. Not "some findings" — the exact set, so a rule cannot quietly stop
//     working while its neighbours keep the suite green.
//
// Run: node bdd/gherkin-lint.test.mjs   (exit 0 = all pass)

import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const LINT = join(here, "gherkin-lint.mjs");
const FIX = join(here, "fixtures");

let pass = 0;
let fail = 0;

// "Ran and found nothing" and "never ran" are different facts, and only one of
// them is good news. Parsing a crashed process's empty stdout as `{}` made them
// identical: `rulesOf({})` is `[]`, so the over-eagerness check certified a
// linter that could not even load (measured 10/08/2026 with node_modules
// absent — "produces zero findings" went green while the process died with
// ERR_MODULE_NOT_FOUND). That is the same shape as a gate whose refusal branch
// never executes: green, and evidence of nothing. So a run that produced no
// parseable report is a hard failure of the harness, never an empty result.
function run(file) {
  let code = 0;
  let stdout;
  try {
    stdout = execFileSync(process.execPath, [LINT, "--json", join(FIX, file)], {
      encoding: "utf8",
    });
  } catch (err) {
    // No exit status at all means the process never started (spawn failure) —
    // distinct from the linter deliberately exiting non-zero on findings.
    if (err.status === undefined) {
      throw new Error(`gherkin-lint did not run for ${file}: ${err.message}`);
    }
    code = err.status;
    stdout = err.stdout ?? "";
  }

  let data;
  try {
    data = JSON.parse(stdout);
  } catch {
    throw new Error(
      `gherkin-lint produced no parseable JSON for ${file} (exit ${code}). ` +
        `stderr/stdout was: ${JSON.stringify(stdout.slice(0, 200))}`,
    );
  }
  if (!Array.isArray(data.findings)) {
    throw new Error(
      `gherkin-lint report for ${file} has no findings array (exit ${code}) — ` +
        `an empty report is not the same as a clean one`,
    );
  }
  return { code, data };
}

function eq(name, got, want) {
  const g = JSON.stringify(got);
  const w = JSON.stringify(want);
  if (g === w) {
    pass++;
    console.log(`  ok   ${name}`);
  } else {
    fail++;
    console.log(`  FAIL ${name}\n         want ${w}\n         got  ${g}`);
  }
}

function rulesOf(data) {
  return [...new Set(data.findings.map((f) => f.rule))].sort();
}

// ---------------------------------------------------------------------------
console.log("good input must be silent (over-eagerness check)");
{
  const r = run("allowlist.feature");
  eq("real wa#339 feature produces zero findings", rulesOf(r.data), []);
  eq("real wa#339 feature exits 0", r.code, 0);
}

console.log("broken input must trip EXACTLY the expected rules");
{
  const r = run("broken.feature");
  eq(
    "broken.feature rule set",
    rulesOf(r.data),
    [
      "blank-line-between-steps",
      "dup-scenario-name",
      "line-length",
      "max-steps",
      "phase-order",
      "placeholder-data",
      "ui-mechanics",
      "vague-then",
    ],
  );
  eq("broken.feature exits 1", r.code, 1);
}

console.log("an invented keyword is caught even though it kills the parse");
{
  const r = run("broken-or.feature");
  eq("broken-or.feature rule set", rulesOf(r.data), ["no-or-keyword", "parse-error"]);
  eq("broken-or.feature exits 1", r.code, 1);
}

console.log("severity split: a SHOULD must not fail the build on its own");
{
  const r = run("broken.feature");
  const ph = (r.data.findings ?? []).filter((f) => f.rule === "placeholder-data");
  eq("placeholder-data is warning-tier", [...new Set(ph.map((f) => f.sev))], ["warning"]);
  const others = (r.data.findings ?? []).filter((f) => f.rule !== "placeholder-data");
  eq("every other finding is error-tier", [...new Set(others.map((f) => f.sev))], ["error"]);
}

console.log("findings carry a usable location");
{
  const r = run("broken.feature");
  const bad = (r.data.findings ?? []).filter((f) => !Number.isInteger(f.line) || f.line < 1);
  eq("every finding has a positive line number", bad.length, 0);
}

console.log("");
console.log(`pass=${pass} fail=${fail}`);
process.exit(fail === 0 ? 0 : 1);
