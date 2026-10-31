// Apply the pinned upstream resolver repair before any engine is launched.
// This changes resolution in the detector, never filters its diagnostics.
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, 'node_modules/aislop');
const version = JSON.parse(fs.readFileSync(path.join(root, 'package.json'))).version;
if (version !== '0.12.0') throw new Error(`Revalidate local-import patch for aislop ${version}`);
const marker = 'import { isLocalPythonImport } from "../python-local-imports.cjs";\n';
const edits = [
  ['const checkPyImport = (spec, pyDeps) => {',
    'const checkPyImport = (spec, pyDeps, filePath, rootDirectory) => {\n\tif (isLocalPythonImport(spec, filePath, rootDirectory)) return null;'],
  ['checkPyImport(spec, pyDeps ?? manifest.pyDeps)',
    'checkPyImport(spec, pyDeps ?? manifest.pyDeps, filePath, context.rootDirectory)'],
];
const outputs = ['cli.js', 'index.js', 'mcp.js'].map(name => {
  const file = path.join(root, 'dist', name);
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
