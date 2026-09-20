# Security Policy

`quality-gates` is a composite GitHub Action plus three deterministic gate scripts
(`code-slop-gate`, `alignment-gate`, `gherkin-lint`). It runs inside other repositories' CI, on
their pull requests, as a required check. Being a component in the supply chain of every
consumer's merge gate is the whole threat model here, so reports against the action, its
scripts, its pinned actions, and its engines are in scope.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private vulnerability reporting:

<https://github.com/yolo-labz/quality-gates/security/advisories/new>

That form is the channel — it keeps the report private between you and the maintainer, and it is
what produces an advisory (and a CVE, when the report warrants one). There is no security email
address for this repository.

Please include: the ref you were running (a 40-char action SHA or a gate-script commit, since
consumers pin SHAs), a reproducer, the impact you believe it has, and a suggested fix if you
have one.

## What to expect

| Phase | Target |
|---|---|
| Acknowledgement | within 72 hours |
| Triage + severity | within 7 days |
| Fix released | within 30 days (high/critical), 90 days (medium/low) |

One maintainer, best-effort, on targets rather than guarantees — a slipped target gets you an
update, not silence. Public disclosure is coordinated through the same advisory form; please
allow a fix to ship first.

## Supported versions

Consumers pin a commit SHA (or the moving `v1` tag). Only the newest `v1` commit is supported:

| Ref | Supported |
|---|---|
| latest `v1` / `main` | ✅ |
| any older pinned SHA | ❌ — bump your pin |

There are no backports. A SHA pin is a fixed, verifiable artifact, and the cost of that is that
it never heals on its own: a fix lands on a new commit, while a consumer still pinned to the old
one keeps the old behaviour. That is why `.github/dependabot.yml` exists — a consumer with
Dependabot enabled is offered the bump automatically.

## Supply chain

- Every `uses:` in `.github/workflows/` and in `action.yml` is pinned to a full commit SHA with
  the release version beside it, so a moving tag cannot change what executes.
- The action needs no token of its own and reads no secrets; the only network access is `npm ci`
  for its three engines, resolved from the committed lockfiles, which pin each package by
  content hash.
- Workflows declare top-level `permissions: {}` and re-grant only `contents: read` per job.

## Out of scope

- **Findings the gates report about your code.** A red gate run is the action working, not a
  vulnerability. Route those to the repository being gated.
- **Threshold choices in a consumer.** The defaults are documented in `README.md`; a consumer
  that sets `align-fail-on-todo: '0'` has opted into report-only deliberately.
- **Private-repo merge discipline.** On a private free-tier repository this action is a signal,
  not a gate. `README.md` documents why, and "a red run did not block the merge" is that
  documented plan limit rather than a reportable defect.
