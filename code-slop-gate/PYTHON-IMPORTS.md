# Python local-module resolution

28/09/2026 — INTV-35/21 exposed an aislop 0.12.0 false positive: a Python
script's `from prompt import render` was rejected even with `prompt.py` beside
that script. The detector consulted dependency manifests/stdlib but never
resolved the imported module against local source files.

## Contract / implementation

The pinned dependency patch changes the detector **before diagnostics are
created**, in CLI, library and MCP entrypoints. No findings filter, import
allowlist, threshold change, fictitious dependency or hook suppression.

Resolve the whole dotted module against the importing script's directory, the
project root, then its `src` directory. Require a regular `.py` file or package
`__init__.py`, whose resolved path remains within the project. An unrelated
same-basename file, absent dotted child, directory-only match, or external
symlink is not resolution. Unknown dependencies remain errors.

This is static source resolution, not execution of Python or a claim about every
possible sys.path customization. Namespace-only packages and custom import
hooks remain outside the resolver. A dynamically configured deployment path
cannot be inferred by searching every basename in the repository.

The patch is version-pinned and checks every original replacement before
writing. Already patched input must contain both repairs. Unexpected upstream
bundle/version drift fails installation rather than silently omitting the fix.
Upgrade aislop only after checking whether the upstream resolver supersedes it.

## Runnable checks / evidence

`npm ci` applies the patch and runs the real-engine falsifier; the existing CI
installation step therefore exercises it without any workflow changes.
`npm test` also runs the resolver and existing dependency/clone ratchets.

- Before patch: synthetic sibling import plus nonexistent dependency produces
  **two** missing-import errors, so the real-engine test fails.
- After patch: only the nonexistent dependency remains; **2/2 tests pass**.
- Existing dependency baseline and jscpd snapshot suites pass unchanged.

Generator: OpenAI. Advisory review and remote CI status belong in the PR, not
asserted here. Nix's currently vendored package must consume these files and
run `npm test` before a separate authorized package rollout; this source change
does not activate a fleet package or replace managed hooks.
