const fs = require('node:fs');
const path = require('node:path');

// Python scripts can import siblings; src-layout packages can be project-local.
// Resolve the whole module, not just a matching basename elsewhere in the tree.
function isLocalPythonImport(spec, importer, root) {
  if (!/^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*$/.test(spec)) return false;
  const modulePath = spec.split('.').join(path.sep);
  const project = fs.realpathSync(root);
  for (const base of [path.dirname(importer), root, path.join(root, 'src')]) {
    const local = path.join(base, modulePath);
    for (const candidate of [`${local}.py`, path.join(local, '__init__.py')]) {
      try {
        const resolved = fs.realpathSync(candidate);
        const relative = path.relative(project, resolved);
        if (relative && relative !== '..' && !relative.startsWith(`..${path.sep}`)
            && !path.isAbsolute(relative) && fs.statSync(resolved).isFile()) return true;
      } catch (error) {
        if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
      }
    }
  }
  return false;
}

module.exports = { isLocalPythonImport };
