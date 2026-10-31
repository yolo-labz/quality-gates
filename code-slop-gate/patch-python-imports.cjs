// Apply the pinned upstream resolver repair before any engine is launched.
// This changes resolution in the detector, never filters its diagnostics.
//
// Two regimes:
//   * aislop 0.12.0 — the local-import repair is ours: patch checkPyImport to
//     consult python-local-imports.cjs before reporting a hallucinated import.
//   * aislop >= 0.16.0 — upstream ships an equivalent repair (its own
//     isLocalPythonImport, walking up from the importer to the root) and
//     checkPyImport already takes (spec, pyDeps, filePath, rootDirectory).
//     Patching it again would double-apply; instead the script VERIFIES the
//     upstream repair is present and fails closed if it is not.
// Any other version still aborts, so a bump can never silently lose the repair.
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, 'node_modules/aislop');
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'))).version;
const DIST = ['cli.js', 'index.js', 'mcp.js'].map(name => [name, path.join(root, 'dist', name)]);
const marker = 'import { isLocalPythonImport } from "../python-local-imports.cjs";\n';

// Why the repair is needed at all (0.12.0): a bare `from prompt import render`
// inside a project is a local sibling import, not a hallucinated dependency.
const LOCAL_IMPORT_REPAIR = /const checkPyImport = \(spec, pyDeps, filePath, rootDirectory\) => \{[\s\S]{0,400}?isLocalPythonImport\(spec, filePath, rootDirectory\)/;
const UPSTREAM_LOCAL_IMPORT = /const isLocalPythonImport = \(spec, filePath, rootDirectory\) => \{[\s\S]{0,900}?searchDirectory = path\.dirname\(searchDirectory\)/;
// The py-dependency expression was renamed upstream (0.19: `filePyDeps`), so the
// call site is matched structurally: four arguments, with filePath and a root
// identifier in the tail — that is the contract the local-import repair needs.
const CALL_SITE = /checkPyImport\(spec, [^,()]+ \?\? manifest\.pyDeps, filePath, [A-Za-z_$][\w$]*\)/;

function patchLocalImports() {
  const edits = [
    ['const checkPyImport = (spec, pyDeps) => {',
      'const checkPyImport = (spec, pyDeps, filePath, rootDirectory) => {\n\tif (isLocalPythonImport(spec, filePath, rootDirectory)) return null;'],
    ['checkPyImport(spec, pyDeps ?? manifest.pyDeps)',
      'checkPyImport(spec, pyDeps ?? manifest.pyDeps, filePath, context.rootDirectory)'],
  ];
  const outputs = DIST.map(([name, file]) => {
    let text = fs.readFileSync(file, 'utf8');
    if (text.includes(marker)) {
      for (const [, replacement] of edits) {
        if (!text.includes(replacement)) throw new Error(`Incomplete patch: ${name}`);
      }
      return [file, text];
    }
    for (const [original, replacement] of edits) {
      if (text.split(original).length !== 2) throw new Error(`Upstream drift: ${name}`);
      text = text.replace(original, replacement);
    }
    const start = text.startsWith('#!') ? text.indexOf('\n') + 1 : 0;
    return [file, text.slice(0, start) + marker + text.slice(start)];
  });
  fs.copyFileSync(path.join(__dirname, 'python-local-imports.cjs'), path.join(root, 'python-local-imports.cjs'));
  for (const [file, text] of outputs) fs.writeFileSync(file, text);
  return `patched ${version}`;
}

function verifyUpstreamLocalImports() {
  for (const [name, file] of DIST) {
    const text = fs.readFileSync(file, 'utf8');
    if (text.includes(marker)) {
      throw new Error(`Stale local patch still applied to aislop ${version}: ${name}`);
    }
    if (!LOCAL_IMPORT_REPAIR.test(text)) throw new Error(`Upstream local-import repair missing: ${name}`);
    if (!UPSTREAM_LOCAL_IMPORT.test(text)) throw new Error(`Upstream isLocalPythonImport missing: ${name}`);
    if (!CALL_SITE.test(text)) throw new Error(`Upstream call site changed: ${name}`);
  }
  // No helper to copy: upstream owns its own implementation.
  const stale = path.join(root, 'python-local-imports.cjs');
  if (fs.existsSync(stale)) fs.rmSync(stale);
  return `verified upstream repair in ${version}`;
}

const major = Number.parseInt(version.split('.')[0], 10);
const minor = Number.parseInt(version.split('.')[1], 10);
let outcome;
if (version === '0.12.0') outcome = patchLocalImports();
else if (major > 0 || minor >= 16) outcome = verifyUpstreamLocalImports();
else throw new Error(`Revalidate local-import patch for aislop ${version}`);
console.log(`local-import repair: ${outcome}`);
