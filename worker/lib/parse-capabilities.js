#!/usr/bin/env node
'use strict';

/**
 * parse-capabilities.js
 *
 * Minimal, dependency-free parser for the Squad on ACA capability manifest.
 *
 * The manifest is written in a deliberately restricted YAML subset so it can
 * be parsed reliably without pulling in a third-party YAML library inside
 * the worker image. Supported shape:
 *
 *   version: 1
 *   tools:
 *     - name: docker
 *       required: true
 *       reason: Needed to build the app image
 *   credentials:
 *     - name: NPM_TOKEN
 *       required: true
 *       reason: Auth for the private npm feed
 *   services:
 *     - name: postgres
 *       required: false
 *       reason: Integration tests expect a local Postgres instance
 *   egress:
 *     - host: registry.npmjs.org
 *       reason: Package installs
 *   image:
 *     hint: ghcr.io/example/squad-worker-python:latest
 *     reason: Needs a pinned Python 3.12 + Poetry toolchain
 *   notes: Free-form guidance for humans/agents.
 *
 * Only two levels of nesting are supported: a top-level key holding either
 * a scalar, a single-level map, or a list of single-level maps. This keeps
 * the grammar small enough to parse with confidence and cover with tests.
 *
 * Usage:
 *   node parse-capabilities.js <path-to-manifest> [--pretty]
 *
 * Exit codes:
 *   0  parsed successfully, JSON printed to stdout
 *   65 (EX_DATAERR) manifest could not be parsed
 */

const fs = require('fs');

const SUPPORTED_MANIFEST_VERSION = 1;
const KNOWN_LIST_KEYS = new Set(['tools', 'credentials', 'services', 'egress']);
const KNOWN_MAP_KEYS = new Set(['image']);
const ALLOWED_TOP_LEVEL_KEYS = new Set(['version', 'tools', 'credentials', 'services', 'egress', 'image', 'notes']);

class CapabilityManifestError extends Error {}

function stripComment(line) {
  let inQuotes = null;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (inQuotes) {
      if (ch === inQuotes) inQuotes = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      inQuotes = ch;
      continue;
    }
    if (ch === '#' && (i === 0 || /\s/.test(line[i - 1]))) {
      return line.slice(0, i);
    }
  }
  return line;
}

function parseScalar(raw) {
  const value = raw.trim();
  if (value === '') return '';
  if (value === 'true') return true;
  if (value === 'false') return false;
  if (value === 'null' || value === '~') return null;
  if (/^-?\d+$/.test(value)) return parseInt(value, 10);
  if (/^-?\d+\.\d+$/.test(value)) return parseFloat(value);
  if (
    (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
    (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
  ) {
    return value.slice(1, -1);
  }
  return value;
}

function indentOf(line) {
  const match = /^ */.exec(line);
  return match ? match[0].length : 0;
}

function splitKeyValue(content, lineNo) {
  const idx = content.indexOf(':');
  if (idx === -1) {
    throw new CapabilityManifestError(`Line ${lineNo}: expected "key: value", got "${content}"`);
  }
  const key = content.slice(0, idx).trim();
  const value = content.slice(idx + 1).trim();
  if (!key) {
    throw new CapabilityManifestError(`Line ${lineNo}: empty key in "${content}"`);
  }
  return { key, value };
}

function parseCapabilityManifest(source) {
  const rawLines = source.split(/\r?\n/);
  const result = {};

  let currentTopKey = null;
  let currentList = null;
  let currentItem = null;
  let currentMap = null;

  for (let i = 0; i < rawLines.length; i += 1) {
    const lineNo = i + 1;
    const withoutComment = stripComment(rawLines[i]);
    if (!withoutComment.trim()) continue;

    const indent = indentOf(withoutComment);
    const content = withoutComment.trim();

    if (indent === 0) {
      const { key, value } = splitKeyValue(content, lineNo);
      currentTopKey = key;
      currentList = null;
      currentItem = null;
      currentMap = null;

      if (value === '') {
        if (KNOWN_LIST_KEYS.has(key)) {
          currentList = [];
          result[key] = currentList;
        } else if (KNOWN_MAP_KEYS.has(key)) {
          currentMap = {};
          result[key] = currentMap;
        } else {
          result[key] = '';
        }
      } else {
        result[key] = parseScalar(value);
      }
      continue;
    }

    if (indent === 2 && content.startsWith('- ')) {
      if (!currentList) {
        throw new CapabilityManifestError(
          `Line ${lineNo}: list item found under "${currentTopKey}", which is not a list block`
        );
      }
      const itemContent = content.slice(2);
      const { key, value } = splitKeyValue(itemContent, lineNo);
      currentItem = { [key]: parseScalar(value) };
      currentList.push(currentItem);
      continue;
    }

    if (indent >= 4 && currentItem) {
      const { key, value } = splitKeyValue(content, lineNo);
      currentItem[key] = parseScalar(value);
      continue;
    }

    if (indent === 2 && currentMap) {
      const { key, value } = splitKeyValue(content, lineNo);
      currentMap[key] = parseScalar(value);
      continue;
    }

    throw new CapabilityManifestError(`Line ${lineNo}: unexpected indentation in "${content}"`);
  }

  return result;
}

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function addUnknownKeyErrors(target, allowedKeys, context, errors) {
  for (const key of Object.keys(target)) {
    if (!allowedKeys.has(key)) {
      errors.push(`${context} contains unknown key "${key}"`);
    }
  }
}

function validateNamedList(manifest, sectionName, nameKey) {
  const errors = [];
  const section = manifest[sectionName];
  if (section === undefined) return errors;

  if (!Array.isArray(section)) {
    errors.push(`"${sectionName}" must be a list`);
    return errors;
  }

  const allowedKeys = new Set([nameKey, 'required', 'reason']);
  section.forEach((item, idx) => {
    const context = `"${sectionName}[${idx}]"`;
    if (!isPlainObject(item)) {
      errors.push(`${context} must be a mapping`);
      return;
    }

    addUnknownKeyErrors(item, allowedKeys, context, errors);

    if (typeof item[nameKey] !== 'string' || item[nameKey].trim() === '') {
      errors.push(`${context} must include a non-empty string "${nameKey}"`);
    }
    if (Object.prototype.hasOwnProperty.call(item, 'required') && typeof item.required !== 'boolean') {
      errors.push(`${context}.required must be a boolean`);
    }
    if (Object.prototype.hasOwnProperty.call(item, 'reason') && typeof item.reason !== 'string') {
      errors.push(`${context}.reason must be a string`);
    }
  });

  return errors;
}

function validateManifest(manifest) {
  const errors = [];

  if (!isPlainObject(manifest)) {
    return ['manifest root must be a mapping'];
  }

  addUnknownKeyErrors(manifest, ALLOWED_TOP_LEVEL_KEYS, 'manifest', errors);

  if (manifest.version === undefined) {
    errors.push('missing required top-level "version" field');
  } else if (!Number.isInteger(manifest.version)) {
    errors.push('"version" must be an integer');
  } else if (manifest.version !== SUPPORTED_MANIFEST_VERSION) {
    errors.push(`unsupported manifest version ${manifest.version}; supported versions: ${SUPPORTED_MANIFEST_VERSION}`);
  }

  errors.push(...validateNamedList(manifest, 'tools', 'name'));
  errors.push(...validateNamedList(manifest, 'credentials', 'name'));
  errors.push(...validateNamedList(manifest, 'services', 'name'));

  if (manifest.egress !== undefined) {
    if (!Array.isArray(manifest.egress)) {
      errors.push('"egress" must be a list');
    } else {
      const allowedKeys = new Set(['host', 'reason']);
      manifest.egress.forEach((item, idx) => {
        const context = `"egress[${idx}]"`;
        if (!isPlainObject(item)) {
          errors.push(`${context} must be a mapping`);
          return;
        }
        addUnknownKeyErrors(item, allowedKeys, context, errors);
        if (typeof item.host !== 'string' || item.host.trim() === '') {
          errors.push(`${context} must include a non-empty string "host"`);
        }
        if (Object.prototype.hasOwnProperty.call(item, 'reason') && typeof item.reason !== 'string') {
          errors.push(`${context}.reason must be a string`);
        }
      });
    }
  }

  if (manifest.image !== undefined) {
    if (!isPlainObject(manifest.image)) {
      errors.push('"image" must be a mapping');
    } else {
      const allowedKeys = new Set(['hint', 'reason']);
      addUnknownKeyErrors(manifest.image, allowedKeys, '"image"', errors);
      if (typeof manifest.image.hint !== 'string' || manifest.image.hint.trim() === '') {
        errors.push('"image.hint" must be a non-empty string');
      }
      if (Object.prototype.hasOwnProperty.call(manifest.image, 'reason') && typeof manifest.image.reason !== 'string') {
        errors.push('"image.reason" must be a string');
      }
    }
  }

  if (manifest.notes !== undefined && typeof manifest.notes !== 'string') {
    errors.push('"notes" must be a string');
  }

  return errors;
}

function main() {
  const args = process.argv.slice(2);
  const filePath = args.find((arg) => !arg.startsWith('--'));
  const pretty = args.includes('--pretty');

  if (!filePath) {
    process.stderr.write('Usage: parse-capabilities.js <manifest-path> [--pretty]\n');
    process.exit(64);
  }

  let source;
  try {
    source = fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    process.stderr.write(`Cannot read manifest at ${filePath}: ${err.message}\n`);
    process.exit(66);
  }

  let manifest;
  try {
    manifest = parseCapabilityManifest(source);
  } catch (err) {
    process.stderr.write(`Invalid capability manifest at ${filePath}: ${err.message}\n`);
    process.exit(65);
  }

  const errors = validateManifest(manifest);
  if (errors.length > 0) {
    process.stderr.write(`Invalid capability manifest at ${filePath}:\n`);
    for (const error of errors) {
      process.stderr.write(`  - ${error}\n`);
    }
    process.exit(65);
  }

  process.stdout.write(JSON.stringify(manifest, null, pretty ? 2 : 0) + '\n');
}

if (require.main === module) {
  main();
}

module.exports = { parseCapabilityManifest, validateManifest, CapabilityManifestError, SUPPORTED_MANIFEST_VERSION };
