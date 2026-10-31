const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');
const { isLocalPythonImport } = require('./python-local-imports.cjs');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'python-imports-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const put = (name, content = '') => {
    const file = path.join(root, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
    return file;
  };
  put('pyproject.toml', '[project]\nname = "synthetic"\nversion = "0.0.0"\ndependencies = []\n');
  const importer = put('src/app/server.py', 'from prompt import render\nimport nonexistent_dependency\n');
  put('src/app/prompt.py', 'def render():\n    return "synthetic"\n');
  return { root, put, importer };
}

test('resolve sibling, root and src packages without accepting unrelated basenames', t => {
  const { root, put, importer } = fixture(t);
  put('root_module.py');
  put('src/package/__init__.py');
  put('src/package/submodule.py');
  put('unrelated/ghost.py');
  put('src/directory_only/.keep');
  for (const name of ['prompt', 'root_module', 'package', 'package.submodule']) {
    assert.equal(isLocalPythonImport(name, importer, root), true, name);
  }
  for (const name of ['ghost', 'missing', 'package.missing', 'directory_only', '../prompt', 'Prompt']) {
    assert.equal(isLocalPythonImport(name, importer, root), false, name);
  }
  fs.symlinkSync(process.execPath, path.join(root, 'src/app/external.py'));
  assert.equal(isLocalPythonImport('external', importer, root), false);
  fs.mkdirSync(path.join(root, 'src/app/directory.py'));
  assert.equal(isLocalPythonImport('directory', importer, root), false);
});

test('real engine accepts local prompt but still rejects a missing dependency', t => {
  const { root } = fixture(t);
  const result = spawnSync(process.execPath, [
    path.join(__dirname, 'node_modules/aislop/dist/cli.js'), 'scan', '--json', root,
  ], { encoding: 'utf8', timeout: 60000 });
  assert.ifError(result.error);
  const findings = JSON.parse(result.stdout).diagnostics.filter(d => d.rule === 'ai-slop/hallucinated-import');
  assert.equal(findings.length, 1, JSON.stringify(findings));
  assert.match(findings[0].message, /nonexistent_dependency/);
});
