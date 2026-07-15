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
 *       check: docker --version
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

const KNOWN_LIST_KEYS = new Set(['tools', 'credentials', 'services', 'egress']);
const KNOWN_MAP_KEYS = new Set(['image']);

class CapabilityManifestError extends Error {}

function stripComment(line) {
  // A `#` only starts a comment when preceded by whitespace or at the start
  // of the (trimmed) line, so manifest values may still contain '#'.
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

/**
 * Parses manifest source text into a plain JS object.
 * Throws CapabilityManifestError on malformed input.
 */
function parseCapabilityManifest(source) {
  const rawLines = source.split(/\r?\n/);
  const result = {};

  let currentTopKey = null;
  let currentList = null; // array reference when currentTopKey holds a list
  let currentItem = null; // last object pushed onto currentList
  let currentMap = null; // object reference when currentTopKey holds a map

  for (let i = 0; i < rawLines.length; i += 1) {
    const lineNo = i + 1;
    const withoutComment = stripComment(rawLines[i]);
    if (!withoutComment.trim()) continue; // blank or comment-only line

    const indent = indentOf(withoutComment);
    const content = withoutComment.trim();

    if (indent === 0) {
      const { key, value } = splitKeyValue(content, lineNo);
      currentTopKey = key;
      currentList = null;
      currentItem = null;
      currentMap = null;

      if (value === '') {
        // Nested block follows on subsequent indented lines.
        if (KNOWN_LIST_KEYS.has(key)) {
          currentList = [];
          result[key] = currentList;
        } else if (KNOWN_MAP_KEYS.has(key)) {
          currentMap = {};
          result[key] = currentMap;
        } else {
          // Unknown top-level block key: still track it as a generic list,
          // so forward-compatible/custom keys degrade gracefully instead of
          // throwing, but keep validation strict for known keys above.
          currentList = [];
          result[key] = currentList;
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

function validateManifest(manifest) {
  const errors = [];

  if (manifest.version === undefined) {
    errors.push('missing required top-level "version" field');
  }

  for (const key of ['tools', 'credentials', 'services', 'egress']) {
    if (manifest[key] === undefined) continue;
    if (!Array.isArray(manifest[key])) {
      errors.push(`"${key}" must be a list`);
      continue;
    }
    manifest[key].forEach((item, idx) => {
      if (typeof item !== 'object' || item === null) {
        errors.push(`"${key}[${idx}]" must be a mapping`);
        return;
      }
      if (key === 'egress') {
        if (!item.host) errors.push(`"${key}[${idx}]" is missing "host"`);
      } else if (!item.name) {
        errors.push(`"${key}[${idx}]" is missing "name"`);
      }
      if (key === 'tools' && item.required && !item.check) {
        errors.push(`"${key}[${idx}]" (${item.name}) is required but has no "check" command`);
      }
    });
  }

  if (manifest.image !== undefined && typeof manifest.image !== 'object') {
    errors.push('"image" must be a mapping with at least "hint"');
  }

  return errors;
}

function main() {
  const args = process.argv.slice(2);
  const filePath = args.find((a) => !a.startsWith('--'));
  const pretty = args.includes('--pretty');

  if (!filePath) {
    process.stderr.write('Usage: parse-capabilities.js <manifest-path> [--pretty]\n');
    process.exit(64); // EX_USAGE
  }

  let source;
  try {
    source = fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    process.stderr.write(`Cannot read manifest at ${filePath}: ${err.message}\n`);
    process.exit(66); // EX_NOINPUT
  }

  let manifest;
  try {
    manifest = parseCapabilityManifest(source);
  } catch (err) {
    process.stderr.write(`Invalid capability manifest at ${filePath}: ${err.message}\n`);
    process.exit(65); // EX_DATAERR
  }

  const errors = validateManifest(manifest);
  if (errors.length > 0) {
    process.stderr.write(`Invalid capability manifest at ${filePath}:\n`);
    for (const e of errors) process.stderr.write(`  - ${e}\n`);
    process.exit(65); // EX_DATAERR
  }

  process.stdout.write(JSON.stringify(manifest, null, pretty ? 2 : 0) + '\n');
}

if (require.main === module) {
  main();
}

module.exports = { parseCapabilityManifest, validateManifest, CapabilityManifestError };
