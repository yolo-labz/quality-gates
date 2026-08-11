#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { TextDecoder } = require('node:util');

class InputError extends Error {}

function parseArgs(argv) {
  const values = new Map();
  const required = new Set([
    '--baseline-report',
    '--candidate-report',
    '--baseline-root',
    '--candidate-root',
    '--changes',
  ]);

  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.has(flag) || value === undefined || value.length === 0) {
      throw new InputError(`invalid argument near ${flag ?? '<end>'}`);
    }
    if (values.has(flag)) {
      throw new InputError(`duplicate argument: ${flag}`);
    }
    values.set(flag, value);
  }

  for (const flag of required) {
    if (!values.has(flag)) throw new InputError(`missing argument: ${flag}`);
  }
  return values;
}

function readJson(file, label) {
  let contents;
  try {
    contents = fs.readFileSync(file, 'utf8');
  } catch (error) {
    throw new InputError(`${label} report is unavailable: ${error.message}`);
  }

  try {
    return JSON.parse(contents);
  } catch (error) {
    throw new InputError(`${label} report is malformed: ${error.message}`);
  }
}

function requireInteger(value, label) {
  if (!Number.isInteger(value) || value < 0) {
    throw new InputError(`${label} must be a non-negative integer`);
  }
  return value;
}

function requireNumber(value, label) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    throw new InputError(`${label} must be a non-negative finite number`);
  }
  return value;
}

function validateReport(report, label) {
  if (report === null || typeof report !== 'object' || Array.isArray(report)) {
    throw new InputError(`${label} report must be an object`);
  }
  if (!Array.isArray(report.duplicates)) {
    throw new InputError(`${label} report is missing duplicates[]`);
  }

  const total = report.statistics?.total;
  if (total === null || typeof total !== 'object' || Array.isArray(total)) {
    throw new InputError(`${label} report is missing statistics.total`);
  }
  const clones = requireInteger(total.clones, `${label} statistics.total.clones`);
  requireInteger(total.duplicatedLines, `${label} statistics.total.duplicatedLines`);
  const percentage = requireNumber(total.percentage, `${label} statistics.total.percentage`);
  if (percentage > 100) {
    throw new InputError(`${label} statistics.total.percentage exceeds 100`);
  }
  if (clones !== report.duplicates.length) {
    throw new InputError(`${label} clone count does not match duplicates[]`);
  }
  return report;
}

function decodeField(buffer, label) {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer);
  } catch (error) {
    throw new InputError(`${label} is not valid UTF-8: ${error.message}`);
  }
}

function validateRepoPath(value, label) {
  if (value.length === 0 || path.isAbsolute(value)) {
    throw new InputError(`${label} must be a non-empty repository-relative path`);
  }
  const normalized = path.posix.normalize(value);
  if (normalized !== value || normalized === '..' || normalized.startsWith('../')) {
    throw new InputError(`${label} escapes the repository: ${value}`);
  }
  return value;
}

function parseChanges(file) {
  let raw;
  try {
    raw = fs.readFileSync(file);
  } catch (error) {
    throw new InputError(`change manifest is unavailable: ${error.message}`);
  }
  if (raw.length === 0) return { changed: new Set(), renames: new Map() };
  if (raw[raw.length - 1] !== 0) {
    throw new InputError('change manifest is not NUL-terminated');
  }

  const fields = [];
  let start = 0;
  for (let index = 0; index < raw.length; index += 1) {
    if (raw[index] !== 0) continue;
    fields.push(decodeField(raw.subarray(start, index), 'change manifest field'));
    start = index + 1;
  }

  const changed = new Set();
  const renames = new Map();
  for (let index = 0; index < fields.length;) {
    const status = fields[index++];
    if (!/^[ACDMRT][0-9]*$/.test(status)) {
      throw new InputError(`unsupported change status: ${status}`);
    }

    const kind = status[0];
    if (kind === 'R' || kind === 'C') {
      if (index + 1 >= fields.length) throw new InputError(`truncated ${kind} change record`);
      const source = validateRepoPath(fields[index++], `${kind} source`);
      const destination = validateRepoPath(fields[index++], `${kind} destination`);
      changed.add(destination);
      if (kind === 'R') {
        if (renames.has(destination)) throw new InputError(`duplicate rename destination: ${destination}`);
        renames.set(destination, source);
      }
      continue;
    }

    if (index >= fields.length) throw new InputError(`truncated ${kind} change record`);
    const changedPath = validateRepoPath(fields[index++], `${kind} path`);
    if (kind !== 'D') changed.add(changedPath);
  }
  return { changed, renames };
}

function snapshotPath(root, reportedName, label) {
  if (typeof reportedName !== 'string' || reportedName.length === 0) {
    throw new InputError(`${label}.name must be a non-empty string`);
  }
  const absoluteRoot = path.resolve(root);
  const absoluteName = path.isAbsolute(reportedName)
    ? path.resolve(reportedName)
    : path.resolve(absoluteRoot, reportedName);
  const relativeName = path.relative(absoluteRoot, absoluteName);
  if (
    relativeName.length === 0
    || relativeName === '..'
    || relativeName.startsWith(`..${path.sep}`)
    || path.isAbsolute(relativeName)
  ) {
    throw new InputError(`${label}.name is outside its snapshot: ${reportedName}`);
  }
  return { absoluteName, relativeName: relativeName.split(path.sep).join('/') };
}

function endpointIdentity(endpoint, root, provenance, label, fileCache) {
  if (endpoint === null || typeof endpoint !== 'object' || Array.isArray(endpoint)) {
    throw new InputError(`${label} must be an object`);
  }
  const { absoluteName, relativeName } = snapshotPath(root, endpoint.name, label);
  const start = requireInteger(endpoint.startLoc?.position, `${label}.startLoc.position`);
  const end = requireInteger(endpoint.endLoc?.position, `${label}.endLoc.position`);
  if (end <= start) throw new InputError(`${label} has an empty or reversed byte span`);

  let contents = fileCache.get(absoluteName);
  if (contents === undefined) {
    try {
      const stat = fs.statSync(absoluteName);
      if (!stat.isFile()) throw new Error('not a regular file');
      contents = fs.readFileSync(absoluteName);
      fileCache.set(absoluteName, contents);
    } catch (error) {
      throw new InputError(`${label}.name is unreadable: ${error.message}`);
    }
  }
  if (end > contents.length) {
    throw new InputError(`${label}.endLoc.position exceeds file size`);
  }

  const spanHash = crypto.createHash('sha256').update(contents.subarray(start, end)).digest('hex');
  const provenancePath = provenance.get(relativeName) ?? relativeName;
  return {
    identity: `${provenancePath}\0${spanHash}`,
    relativeName,
    provenancePath,
    spanHash,
  };
}

function cloneIdentity(clone, root, provenance, label, fileCache) {
  if (clone === null || typeof clone !== 'object' || Array.isArray(clone)) {
    throw new InputError(`${label} must be an object`);
  }
  if (typeof clone.format !== 'string' || clone.format.length === 0) {
    throw new InputError(`${label}.format must be a non-empty string`);
  }
  const tokens = requireInteger(clone.tokens, `${label}.tokens`);
  if (tokens === 0) throw new InputError(`${label}.tokens must be positive`);

  const first = endpointIdentity(clone.firstFile, root, provenance, `${label}.firstFile`, fileCache);
  const second = endpointIdentity(clone.secondFile, root, provenance, `${label}.secondFile`, fileCache);
  const pair = [first.identity, second.identity].sort();
  return {
    key: JSON.stringify([clone.format, tokens, pair]),
    format: clone.format,
    tokens,
    endpoints: [first, second],
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const baseline = validateReport(readJson(args.get('--baseline-report'), 'baseline'), 'baseline');
  const candidate = validateReport(readJson(args.get('--candidate-report'), 'candidate'), 'candidate');
  const { changed, renames } = parseChanges(args.get('--changes'));
  const baselineRoot = args.get('--baseline-root');
  const candidateRoot = args.get('--candidate-root');
  const baselineFiles = new Map();
  const candidateFiles = new Map();

  const baselineMultiset = new Map();
  baseline.duplicates.forEach((clone, index) => {
    const identity = cloneIdentity(
      clone,
      baselineRoot,
      new Map(),
      `baseline.duplicates[${index}]`,
      baselineFiles,
    );
    baselineMultiset.set(identity.key, (baselineMultiset.get(identity.key) ?? 0) + 1);
  });

  let relevantClones = 0;
  let inheritedClones = 0;
  const regressions = [];
  candidate.duplicates.forEach((clone, index) => {
    const identity = cloneIdentity(
      clone,
      candidateRoot,
      renames,
      `candidate.duplicates[${index}]`,
      candidateFiles,
    );
    if (!identity.endpoints.some(endpoint => changed.has(endpoint.relativeName))) return;
    relevantClones += 1;

    const available = baselineMultiset.get(identity.key) ?? 0;
    if (available > 0) {
      baselineMultiset.set(identity.key, available - 1);
      inheritedClones += 1;
      return;
    }
    regressions.push({
      format: identity.format,
      tokens: identity.tokens,
      endpoints: identity.endpoints.map(endpoint => ({
        path: endpoint.relativeName,
        provenancePath: endpoint.provenancePath,
        spanHash: endpoint.spanHash,
      })),
    });
  });

  const result = {
    summary: {
      baselineClones: baseline.duplicates.length,
      candidateClones: candidate.duplicates.length,
      relevantClones,
      inheritedClones,
      regressions: regressions.length,
    },
    regressions,
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return regressions.length === 0 ? 0 : 1;
}

try {
  process.exitCode = main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`jscpd-snapshot-compare: ${message}\n`);
  process.exitCode = 2;
}
