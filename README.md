# quality-gates

The 3 fleet-wide quality gates as one **composite GitHub Action** — so every yolo-labz repo
gates its PR diff server-side, identically, without vendoring the scripts N times.

Implements the global-gate layer of [Standard — Project Quality & Alignment Enforcement].
The same two gates also run as Claude Code / opencode / Codex hooks + git pre-commit (NixOS
#974); this action is the **CI layer** that gates the diff independent of any host hook.

| Gate | Axis | Catches |
|---|---|---|
| **code-slop-gate** (aislop + jscpd) | anti-slop | swallowed exceptions, `as any`, narrative comments, dead code, oversized functions, copy-paste |
| **alignment-gate** (git+grep+awk, zero-dep) | alignment | TODO/stub/`NotImplemented` in "done" code, skipped/`.only` tests, added lint-suppressions, debug artifacts, blast-radius |
| **gherkin-lint** (official `@cucumber/gherkin` AST) | specification | unparseable `.feature`, invented `Or` keyword, > 10 steps, duplicate scenario names, `Given`→`When`→`Then` violations, vague `Then` outcomes, UI mechanics in steps, placeholder data |

All three are deterministic (no runtime LLM). Exit 0 = clean, 1 = over threshold, 2 = tooling error.

### On the Gherkin gate

It exists because `gherkin-lint` is dead upstream — ruby gem 1.2.2 (2017), npm port 4.2.4
(2023), no successor under the cucumber org — while the official parser is alive and emits a
real AST. Every rule is a MUST from the fleet's `bdd` context contract, which was written to
be AST-checkable precisely so the contract and the linter cannot drift.

Two behaviours it is built to get right, because they pull in opposite directions:

- **A repo with no `.feature` files passes silently.** Gherkin is deliberately scoped (not
  Elixir, not Nix, not Bash), so most consumers have none and a gate that failed on "no
  scenarios" would make the whole action unadoptable.
- **A repo with `.feature` files never passes because the linter could not run.** "Ran and
  found nothing" and "never ran" are different facts and only one is good news; a missing
  parser or unparseable output is exit 2, never a clean result.

Dependency audits are ratcheted against the PR merge base. An exact high/critical
finding already present on the base branch remains visible as a baseline warning;
a new or worsened finding remains a blocking error. If the base scan cannot run,
the gate fails closed and preserves the head findings unchanged.

## Use it

```yaml
# .github/workflows/quality-gates.yml
name: quality-gates
on: pull_request
permissions:
  contents: read
jobs:
  gates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # full history so the gates can diff the PR
      - uses: yolo-labz/quality-gates@v1
        with:
          base-ref: origin/${{ github.base_ref }}
```

## Ratchet (per the standard)

Strictness moves one way only — **report-only → warn → block**. On a legacy repo, start
report-only (`align-fail-on-todo: '0'`, `aislop-max-errors: '999'`), fix the backlog, then
ratchet down. Never loosen a passing threshold without an inline justification.

| input | default | meaning |
|---|---|---|
| `base-ref` | `origin/main` | ref to diff against (use `origin/${{ github.base_ref }}`) |
| `aislop-max-errors` | `0` | fail when aislop errors exceed this |
| `jscpd-max-pct` | `0` | fail when duplication % exceeds this |
| `align-fail-on-todo` | `1` | TODO/stub in changed code (0 = report-only) |
| `align-fail-on-skip` | `1` | skipped/`.only` tests |
| `align-fail-on-lint-disable` | `1` | added lint-suppressions |
| `align-max-files` | `0` | fail if changed code files > N (0 = off) |
| `gherkin-paths` | `features` | space-separated files/dirs to lint; a missing path or one with no `.feature` files is a silent pass |
| `gherkin-fail-on` | `error` | lowest severity that fails; `warning` also fails on `placeholder-data` (a SHOULD in the contract, so warning-tier by default) |

Source gates live at `~/Documents/Code/experiments/{code-slop-gate,alignment-gate}` and are
nix-packaged for the hook layer (NixOS #974); this repo vendors them for the CI layer.
