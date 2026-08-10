#!/usr/bin/env node
// gherkin-lint — the fleet's AST linter for .feature files.
//
// Replaces gherkin-lint, which is dead upstream (ruby gem 1.2.2 / 2017, npm port
// 4.2.4 / 2023) with no successor under the cucumber org. This runs over the
// OFFICIAL parser (@cucumber/gherkin), so "does it parse" is answered by the
// same code the runners use rather than by a regex approximation.
//
// Every rule here is a MUST from the bdd skill's SKILL.md. That is deliberate:
// the MUST list was chosen to be AST-checkable so the contract and the linter
// cannot drift apart. A rule that cannot be mechanically checked belongs in the
// checklist, not here.
//
// Usage:
//   node gherkin-lint.mjs <file-or-dir>...      exit 1 on any error
//   node gherkin-lint.mjs --strict <paths>      warnings also fail
//   node gherkin-lint.mjs --json <paths>        machine-readable findings
//
// Tiering (REFERENCE.md §4): fast enough for a PostToolUse hook on a single
// file; run over the whole tree in CI.

import { AstBuilder, GherkinClassicTokenMatcher, Parser } from "@cucumber/gherkin";
import { IdGenerator } from "@cucumber/messages";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { basename, join } from "node:path";

const MAX_STEPS = 10; // "> 10 steps means the scenario is testing two things"
const MAX_LINE = 120;

// Vague outcomes: a Then a stakeholder cannot confirm. Anchored to whole words
// so "it works" is caught but "network works around the proxy" is not.
const VAGUE = [
  /\bit works\b/i,
  /\blooks (right|good|correct)\b/i,
  /\bno errors?\b/i,
  /\bas expected\b/i,
  /\bis (ok|fine)\b/i,
  /\bworks? (correctly|properly|fine)\b/i,
];

// Automation/UI mechanics leaking into a domain-level step.
const MECHANICS = [
  /\bclick(s|ed)? (on )?[#.][\w-]+/i, // click #submit / clicks .btn
  /\bxpath\b/i,
  /\bcss selector\b/i,
  /\bwaits? for \d+ ?(ms|s|seconds?)\b/i,
  /\bsleeps? \d+/i,
  /\bcss=|\bid=["'][\w-]+["']/i,
  /\bpresses? the [\w-]+ button\b/i,
];

// Placeholder data. SHOULD in the contract, so warning-tier.
const PLACEHOLDER = /\b(foo|bar|baz|qux|lorem ipsum|john doe|jane doe|acme|example\.com)\b/i;

const findings = [];
const add = (file, line, rule, sev, msg) =>
  findings.push({ file, line, rule, sev, msg });

function lintText(file, text) {
  const lines = text.split(/\r?\n/);

  // ---- filename ------------------------------------------------------------
  const name = basename(file);
  if (!/^[a-z0-9]+(-[a-z0-9]+)*\.feature$/.test(name)) {
    add(file, 1, "kebab-filename", "error",
      `filename "${name}" is not kebab-case .feature (e.g. allowlist-authorization.feature)`);
  }

  // ---- line-level ----------------------------------------------------------
  lines.forEach((l, i) => {
    if (l.length > MAX_LINE) {
      add(file, i + 1, "line-length", "error",
        `line is ${l.length} chars; the contract caps lines at ${MAX_LINE}`);
    }
    if (/^\s*Or\s+/.test(l)) {
      add(file, i + 1, "no-or-keyword", "error",
        "`Or` is not a Gherkin keyword; split the scenario or use a Scenario Outline");
    }
  });

  // ---- parse ---------------------------------------------------------------
  let doc;
  try {
    const parser = new Parser(new AstBuilder(IdGenerator.uuid()), new GherkinClassicTokenMatcher());
    doc = parser.parse(text);
  } catch (err) {
    const line = err?.errors?.[0]?.location?.line ?? 1;
    add(file, line, "parse-error", "error", String(err.message ?? err).split("\n")[0]);
    return; // nothing further is trustworthy
  }

  const feature = doc.feature;
  if (!feature) {
    add(file, 1, "empty-file", "error", "no Feature in this file");
    return;
  }
  if (!feature.name || !feature.name.trim()) {
    add(file, feature.location.line, "empty-title", "error", "Feature has no title");
  }

  // One Feature per file is structural in Gherkin (the parser allows only one),
  // so the check that earns its place is the reverse: a second `Feature:` line
  // that the parser silently swallowed into a description.
  lines.forEach((l, i) => {
    if (i + 1 !== feature.location.line && /^\s*Feature:/.test(l)) {
      add(file, i + 1, "one-feature", "error",
        "a second `Feature:` line — one Feature per file");
    }
  });

  const seen = new Map();

  for (const child of feature.children ?? []) {
    const sc = child.scenario;
    if (!sc) continue;

    const at = sc.location.line;
    const title = (sc.name ?? "").trim();

    if (!title) add(file, at, "empty-title", "error", "scenario has no title");

    if (title) {
      const key = title.toLowerCase();
      if (seen.has(key)) {
        add(file, at, "dup-scenario-name", "error",
          `duplicate scenario name (first at line ${seen.get(key)}); names must be unique`);
      } else seen.set(key, at);
    }

    const steps = sc.steps ?? [];
    if (steps.length > MAX_STEPS) {
      add(file, at, "max-steps", "error",
        `${steps.length} steps; over ${MAX_STEPS} means the scenario tests more than one behavior`);
    }

    // ---- phase order: Given -> When -> Then, no phase repeated after leaving it
    const RANK = { Given: 0, When: 1, Then: 2 };
    let rank = -1;
    let sawThen = false;
    for (const st of steps) {
      const kw = st.keyword.trim();
      if (kw === "And" || kw === "But" || kw === "*") {
        if (sawThen === false && rank === -1) {
          add(file, st.location.line, "phase-order", "error",
            `"${kw}" before any Given/When/Then — a scenario starts with Given`);
        }
        continue;
      }
      const r = RANK[kw];
      if (r === undefined) continue;
      if (r === 1 && sawThen) {
        add(file, st.location.line, "phase-order", "error",
          "`When` after `Then` — one Arrange/Act/Assert pass per scenario");
      } else if (r < rank) {
        add(file, st.location.line, "phase-order", "error",
          `\`${kw}\` after a later phase — order is Given then When then Then`);
      }
      if (r === 2) sawThen = true;
      rank = Math.max(rank, r);
    }

    // ---- per-step text checks
    let inThen = false;
    for (const st of steps) {
      const kw = st.keyword.trim();
      if (kw === "Then") inThen = true;
      else if (kw === "Given" || kw === "When") inThen = false;

      const txt = st.text ?? "";

      for (const re of MECHANICS) {
        if (re.test(txt)) {
          add(file, st.location.line, "ui-mechanics", "error",
            "step leaks automation/UI mechanics; keep steps at domain level");
          break;
        }
      }

      if (inThen) {
        for (const re of VAGUE) {
          if (re.test(txt)) {
            add(file, st.location.line, "vague-then", "error",
              "outcome is not observable/checkable — a stakeholder cannot confirm it");
            break;
          }
        }
      }

      if (PLACEHOLDER.test(txt)) {
        add(file, st.location.line, "placeholder-data", "warning",
          "placeholder data; use concrete realistic values");
      }
    }

    // ---- blank line between steps (contract: never)
    if (steps.length > 1) {
      const first = steps[0].location.line;
      const last = steps[steps.length - 1].location.line;
      for (let i = first; i < last - 1; i++) {
        if (lines[i] !== undefined && lines[i].trim() === "") {
          add(file, i + 1, "blank-line-between-steps", "error",
            "blank line between steps; blank lines separate scenarios, not steps");
        }
      }
    }
  }
}

function collect(target) {
  const out = [];
  const walk = (p) => {
    const s = statSync(p);
    if (s.isDirectory()) {
      for (const e of readdirSync(p)) {
        if (e === "node_modules" || e === ".git") continue;
        walk(join(p, e));
      }
    } else if (p.endsWith(".feature")) out.push(p);
  };
  walk(target);
  return out;
}

const args = process.argv.slice(2);
const strict = args.includes("--strict");
const asJson = args.includes("--json");
const targets = args.filter((a) => !a.startsWith("--"));

if (targets.length === 0) {
  console.error("usage: gherkin-lint.mjs [--strict] [--json] <file-or-dir>...");
  process.exit(2);
}

const files = targets.flatMap(collect);
for (const f of files) lintText(f, readFileSync(f, "utf8"));

const errors = findings.filter((f) => f.sev === "error");
const warnings = findings.filter((f) => f.sev === "warning");

if (asJson) {
  console.log(JSON.stringify({ files: files.length, findings }, null, 2));
} else {
  for (const f of findings) {
    console.log(`${f.file}:${f.line}: ${f.sev} [${f.rule}] ${f.msg}`);
  }
  console.log(
    `\n${files.length} file(s) · ${errors.length} error(s) · ${warnings.length} warning(s)`,
  );
}

process.exit(errors.length > 0 || (strict && warnings.length > 0) ? 1 : 0);
