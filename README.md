# quality-gates

The 2 fleet-wide quality gates as one **composite GitHub Action** — so every yolo-labz repo
gates its PR diff server-side, identically, without vendoring the scripts N times.

Implements the global-gate layer of [Standard — Project Quality & Alignment Enforcement].
The same two gates also run as Claude Code / opencode / Codex hooks + git pre-commit (NixOS
#974); this action is the **CI layer** that gates the diff independent of any host hook.

| Gate | Axis | Catches |
|---|---|---|
| **code-slop-gate** (aislop + jscpd) | anti-slop | swallowed exceptions, `as any`, narrative comments, dead code, oversized functions, copy-paste |
| **alignment-gate** (git+grep+awk, zero-dep) | alignment | TODO/stub/`NotImplemented` in "done" code, skipped/`.only` tests, added lint-suppressions, debug artifacts, blast-radius |

Both are deterministic (no runtime LLM). Exit 0 = clean, 1 = over threshold, 2 = tooling error.

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

Source gates live at `~/Documents/Code/experiments/{code-slop-gate,alignment-gate}` and are
nix-packaged for the hook layer (NixOS #974); this repo vendors them for the CI layer.
