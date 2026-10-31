// Version dispatch for code-slop-gate/patch-python-imports.cjs.
//
// The engine-level proof that the repair *works* is test-python-local-imports.cjs
// (it runs the installed aislop against a fixture and asserts a local import is
// accepted while a genuinely missing dependency is still reported). This file
// covers the other half: that the script picks the right regime for the version
// it finds, applies or skips the edit accordingly, is idempotent, and fails
// closed on a version it has never been validated against.
//
// Fixtures are synthetic shapes carrying the anchors the script matches. They are
// not the real bundles — the real bundles are covered by the engine test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const SCRIPT = path.join(__dirname, 'patch-python-imports.cjs');
const HELPER = path.join(__dirname, 'python-local-imports.cjs');

const HEAD = '#!/usr/bin/env node\n';

// aislop 0.12.0 shape: the repair is ours to apply.
const v012 = {
  cli: `${HEAD}const checkPyImport = (spec, pyDeps) => {\n\tconst root = spec.split(".")[0];\n\treturn root;\n};\n`
    + 'const hallucinated = checkPyImport(spec, pyDeps ?? manifest.pyDeps);\n',
};

// aislop >= 0.16.0 shape: upstream ships its own repair and passes filePath/root.
const v016 = {
  cli: `${HEAD}const isLocalPythonImport = (spec, filePath, rootDirectory) => {\n`
    + '\tconst modulePath = spec.split(".").join(path.sep);\n'
    + '\tsearchDirectory = path.dirname(searchDirectory);\n'
    + '\treturn false;\n};\n'
    + 'const checkPyImport = (spec, pyDeps, filePath, rootDirectory) => {\n'
    + '\tif (isLocalPythonImport(spec, filePath, rootDirectory)) return null;\n'
    + '\treturn spec.split(".")[0];\n};\n'
    + 'const hallucinated = checkPyImport(spec, pyDeps ?? manifest.pyDeps, filePath, pyImportRoot);\n',
};

// aislop 0.19.1 shape: same repair, but the py-dependency expression upstream
// renamed to `filePyDeps` — the verification must match it structurally.
const v019 = {
  cli: v016.cli.replace('pyDeps ?? manifest.pyDeps', 'filePyDeps ?? manifest.pyDeps'),
};

function fixture(t, version, source) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aislop-patch-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const pkg = path.join(root, 'node_modules/aislop');
  fs.mkdirSync(path.join(pkg, 'dist'), { recursive: true });
  fs.writeFileSync(path.join(pkg, 'package.json'), JSON.stringify({ name: 'aislop', version }));
  for (const name of ['cli.js', 'index.js', 'mcp.js']) fs.writeFileSync(path.join(pkg, 'dist', name), source.cli);
  fs.copyFileSync(SCRIPT, path.join(root, 'patch-python-imports.cjs'));
  fs.copyFileSync(HELPER, path.join(root, 'python-local-imports.cjs'));
  return { root, pkg, run: () => spawnSync(process.execPath, ['patch-python-imports.cjs'], { cwd: root, encoding: 'utf8' }) };
}

test('0.12.0: applies the local-import repair, idempotently', t => {
  const { pkg, run } = fixture(t, '0.12.0', v012);
  const first = run();
  assert.equal(first.status, 0, first.stderr);
  assert.match(first.stdout, /patched 0\.12\.0/);
  for (const name of ['cli.js', 'index.js', 'mcp.js']) {
    const text = fs.readFileSync(path.join(pkg, 'dist', name), 'utf8');
    assert.match(text, /from "\.\.\/python-local-imports\.cjs";/, name);
    assert.match(text, /checkPyImport\(spec, pyDeps \?\? manifest\.pyDeps, filePath, context\.rootDirectory\)/, name);
  }
  assert.ok(fs.existsSync(path.join(pkg, 'python-local-imports.cjs')), 'helper must be copied in');
  const second = run();
  assert.equal(second.status, 0, second.stderr);
  assert.equal(fs.readFileSync(path.join(pkg, 'dist/cli.js'), 'utf8').split('python-local-imports.cjs').length, 2,
    'a second run must not add a second marker');
});

test('0.16.1: verifies the upstream repair instead of patching, and is repeatable', t => {
  const { pkg, run } = fixture(t, '0.16.1', v016);
  for (const pass of [1, 2]) {
    const result = run();
    assert.equal(result.status, 0, `pass ${pass}: ${result.stderr}`);
    assert.match(result.stdout, /verified upstream repair in 0\.16\.1/);
  }
  const text = fs.readFileSync(path.join(pkg, 'dist/cli.js'), 'utf8');
  assert.doesNotMatch(text, /python-local-imports\.cjs/, 'upstream-owned fix must not be patched over');
  assert.equal(fs.existsSync(path.join(pkg, 'python-local-imports.cjs')), false, 'stale helper must be removed');
});

test('0.16.1 with the upstream repair stripped: fails closed', t => {
  const stripped = { ...v016, cli: v016.cli.replace(/\tif \(isLocalPythonImport\(spec, filePath, rootDirectory\)\) return null;\n/, '') };
  const { run } = fixture(t, '0.16.1', stripped);
  const result = run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Upstream local-import repair missing/);
});

test('0.19.1: renamed py-deps expression still verifies', t => {
  const { run } = fixture(t, '0.19.1', v019);
  const result = run();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /verified upstream repair in 0\.19\.1/);
});

test('unknown version: refuses to guess', t => {
  const { run } = fixture(t, '0.14.0', v012);
  const result = run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Revalidate local-import patch for aislop 0\.14\.0/);
});
