# OSV caller compatibility and private security reporting

## Spec

Repair the seven assigned OSV update paths and pedro-portfolio-recipes without disabling scanning, suppressing vulnerabilities, changing repository visibility, or touching application/media code. Generator: OpenAI GPT-6 Astra. Coordinator owns independent full GLM review and all merge/activation gates.

Observed failure: chrome-bridge job 106279594630 rejects `--skip-git` with exit 127; the identical pinned v2.6.0 container reproduces this locally. Removing that argument reaches extraction. Git-root inclusion is now opt-in (`--include-git-root`, default false). Seven trees have no supported dependency manifests; fand has Cargo.lock (110 packages). Do not mistake an empty inventory for a comprehensive security verdict.

Recipes additionally has code-scanning HTTP 403 (Advanced Security required), and Scorecard GraphQL ListCommits lacks integration permissions. Keep analysis and downloadable SARIF artifacts; do not publish private results to the public Scorecard service.

## Plan

1. Reproduce the real parse failure and read upstream workflow/CLI contracts before propagation.
2. Pin v2.6.0 and remove obsolete `--skip-git`; use `--allow-no-lockfiles` only on verified manifest-free trees. Keep the upstream missing-results guard and fail-on-vulnerability behavior.
3. Keep recipes Scorecard analysis with documented private-repository read permissions; disable public publication and replace unsupported code-scanning upload with Actions artifacts. Disable only OSV's code-scanning upload, retaining its scan/report/artifact path.
4. Run actual container scans, negative/positive synthetic dependency checks, workflow lint and PR CI. Preserve full source-independent evidence in this repository.

## Tasks

- [x] Read assignment, prior useful results, live repo state and upstream input definitions.
- [x] Reproduce original parse error; enumerate actual extraction results in all eight trees.
- [x] Apply minimal per-repository workflow changes in exclusive 091-osv-swarm worktrees.
- [x] Execute actual scanner regression and workflow lint; create PRs and inspect CI.
- [x] Save exact-head handoff report with every repository and unresolved gate.
- [ ] Coordinator: independent full GLM review, workflow approval and merge disposition.
