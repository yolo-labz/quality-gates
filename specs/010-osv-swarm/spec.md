# OSV caller compatibility and private security reporting

## Spec

Repair the seven assigned public OSV update paths and separately scoped private-target compatibility without disabling scanning, suppressing vulnerabilities, changing repository visibility, or touching application/media code. Generator: OpenAI GPT-6 Astra. Coordinator owns independent full GLM review and all merge/activation gates.

Observed failure: chrome-bridge job 106279594630 rejects `--skip-git` with exit 127; the identical pinned v2.6.0 container reproduces this locally. Removing that argument reaches extraction. Git-root inclusion is now opt-in (`--include-git-root`, default false). Six public trees have no supported dependency manifests; fand has Cargo.lock (110 packages). Do not mistake an empty inventory for a comprehensive security verdict.

Private-target operational findings belong only in the owning private repository. Where Code Scanning is unavailable, retain analysis and private downloadable artifacts rather than publishing findings to a public service or broadening entitlements.

## Plan

1. Reproduce the real parse failure and read upstream workflow/CLI contracts before propagation.
2. Pin v2.6.0 and remove obsolete `--skip-git`; use `--allow-no-lockfiles` only on verified manifest-free trees. Keep the upstream missing-results guard and fail-on-vulnerability behavior.
3. Support private-repository analysis with narrowly scoped read permissions and private artifacts; keep scan/report/failure behavior while separating any unsupported public API integration.
4. Run actual container scans, negative/positive synthetic dependency checks, workflow lint and PR CI. Preserve evidence in the repository that was scanned; synthetic fixture receipts may live here.

## Tasks

- [x] Read assignment, prior useful results, live repo state and upstream input definitions.
- [x] Reproduce original parse error; enumerate actual extraction results in assigned trees.
- [x] Apply minimal per-repository workflow changes in exclusive 091-osv-swarm worktrees.
- [x] Execute actual scanner regression and workflow lint; create PRs and inspect CI.
- [x] Save scoped handoffs and unresolved gates without exporting private findings.
- [x] Coordinator: full GLM reviewed the implementation; source metadata confirmed the provider/family.
- [ ] Coordinator: refresh exact-head review after current-tip redaction, workflow approval and merge disposition. Historical exposure remains unresolved.
