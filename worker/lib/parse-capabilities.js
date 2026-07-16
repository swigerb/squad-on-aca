#!/usr/bin/env node
'use strict';

const SUPPORTED_VERSION = '1';
const TOP_LEVEL_KEYS = new Set(['version', 'tools', 'credentials', 'services', 'egress', 'image', 'notes']);
const ITEM_KEYS = new Set(['name', 'required']);
const IMAGE_KEYS = new Set(['hint', 'required']);

class ManifestError extends Error {
  constructor(message, line) {
    super(message);
    this.name = 'ManifestError';
    this.line = line || null;
  }
}

function readLines(text) {
  return String(text || '').replace(/^\uFEFF/, '').split(/\r?\n/).map((raw, index) => ({
    number: index + 1,
    raw,
  }));
}

function stripComment(text) {
  let single = false;
  let double = false;
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    const prev = i > 0 ? text[i - 1] : '';
    if (char === "'" && !double) {
      single = !single;
      continue;
    }
    if (char === '"' && !single && prev !== '\\') {
      double = !double;
      continue;
    }
    if (char === '#' && !single && !double) {
      return text.slice(0, i);
    }
  }
  return text;
}

function sanitizeScalar(value, lineNumber) {
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i);
    if ((code >= 0 && code < 32) || code === 127) {
      throw new ManifestError(`control characters are not allowed at line ${lineNumber}`, lineNumber);
    }
  }
}

function parseScalar(value, lineNumber) {
  const trimmed = value.trim();
  if (trimmed === '') {
    return '';
  }

  let parsed;
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    const quote = trimmed[0];
    const inner = trimmed.slice(1, -1);
    if (quote === '"') {
      parsed = inner.replace(/\\n/g, '\n').replace(/\\r/g, '\r').replace(/\\t/g, '\t').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    } else {
      parsed = inner.replace(/''/g, "'");
    }
    sanitizeScalar(parsed, lineNumber);
    return parsed;
  }

  if (trimmed === 'true') return true;
  if (trimmed === 'false') return false;
  if (/^-?\d+(?:\.\d+)?$/.test(trimmed)) return Number(trimmed);

  sanitizeScalar(trimmed, lineNumber);
  return trimmed;
}

function splitKeyValue(text, lineNumber) {
  let single = false;
  let double = false;
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    const prev = i > 0 ? text[i - 1] : '';
    if (char === "'" && !double) {
      single = !single;
      continue;
    }
    if (char === '"' && !single && prev !== '\\') {
      double = !double;
      continue;
    }
    if (char === ':' && !single && !double) {
      return { key: text.slice(0, i).trim(), value: text.slice(i + 1) };
    }
  }
  throw new ManifestError(`expected a key/value pair at line ${lineNumber}`, lineNumber);
}

function preprocess(text) {
  const items = [];
  for (const line of readLines(text)) {
    if (/\t/.test(line.raw)) {
      throw new ManifestError(`tabs are not allowed at line ${line.number}`, line.number);
    }
    const withoutComment = stripComment(line.raw);
    if (!withoutComment.trim()) continue;
    const indentMatch = withoutComment.match(/^( *)/);
    const indent = indentMatch ? indentMatch[1].length : 0;
    if (indent % 2 !== 0) {
      throw new ManifestError(`indentation must use multiples of two spaces at line ${line.number}`, line.number);
    }
    items.push({
      number: line.number,
      indent,
      content: withoutComment.trimEnd(),
    });
  }
  return items;
}

function parseList(lines, startIndex, expectedIndent) {
  const result = [];
  let index = startIndex;

  while (index < lines.length) {
    const line = lines[index];
    if (line.indent < expectedIndent) break;
    if (line.indent > expectedIndent) {
      throw new ManifestError(`unexpected indentation at line ${line.number}`, line.number);
    }
    const trimmed = line.content.trimStart();
    if (!trimmed.startsWith('- ')) {
      break;
    }

    const payload = trimmed.slice(2).trim();
    if (!payload) {
      throw new ManifestError(`list item is missing a value at line ${line.number}`, line.number);
    }

    if (payload.includes(':')) {
      const first = splitKeyValue(payload, line.number);
      const item = { __line: line.number };
      const seen = new Set();
      if (!ITEM_KEYS.has(first.key)) {
        throw new ManifestError(`unrecognized nested key (redacted) at line ${line.number}`, line.number);
      }
      seen.add(first.key);
      item[first.key] = parseScalar(first.value, line.number);
      index += 1;
      while (index < lines.length) {
        const nested = lines[index];
        if (nested.indent < expectedIndent + 2) break;
        if (nested.indent > expectedIndent + 2) {
          throw new ManifestError(`unexpected indentation at line ${nested.number}`, nested.number);
        }
        const nestedTrimmed = nested.content.trimStart();
        if (nestedTrimmed.startsWith('- ')) break;
        const pair = splitKeyValue(nestedTrimmed, nested.number);
        if (!ITEM_KEYS.has(pair.key)) {
          throw new ManifestError(`unrecognized nested key (redacted) at line ${nested.number}`, nested.number);
        }
        if (seen.has(pair.key)) {
          throw new ManifestError(`duplicate nested key (redacted) at line ${nested.number}`, nested.number);
        }
        seen.add(pair.key);
        item[pair.key] = parseScalar(pair.value, nested.number);
        index += 1;
      }
      result.push(item);
      continue;
    }

    result.push({ __line: line.number, name: parseScalar(payload, line.number) });
    index += 1;
  }

  return { value: result, nextIndex: index };
}

function parseObject(lines, startIndex, expectedIndent) {
  const result = { __line: lines[startIndex] ? lines[startIndex].number : null };
  const seen = new Set();
  let index = startIndex;

  while (index < lines.length) {
    const line = lines[index];
    if (line.indent < expectedIndent) break;
    if (line.indent > expectedIndent) {
      throw new ManifestError(`unexpected indentation at line ${line.number}`, line.number);
    }
    const trimmed = line.content.trimStart();
    if (trimmed.startsWith('- ')) break;
    const pair = splitKeyValue(trimmed, line.number);
    if (!IMAGE_KEYS.has(pair.key)) {
      throw new ManifestError(`unrecognized nested key (redacted) at line ${line.number}`, line.number);
    }
    if (seen.has(pair.key)) {
      throw new ManifestError(`duplicate nested key (redacted) at line ${line.number}`, line.number);
    }
    seen.add(pair.key);
    result[pair.key] = parseScalar(pair.value, line.number);
    index += 1;
  }

  return { value: result, nextIndex: index };
}

function parseCapabilityManifest(text) {
  const lines = preprocess(text);
  const manifest = {};
  const seenTopLevel = new Set();
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    if (line.indent !== 0) {
      throw new ManifestError(`unexpected indentation at line ${line.number}`, line.number);
    }
    const pair = splitKeyValue(line.content, line.number);
    if (!pair.key) {
      throw new ManifestError(`missing key at line ${line.number}`, line.number);
    }
    if (!TOP_LEVEL_KEYS.has(pair.key)) {
      throw new ManifestError(`unrecognized top-level key (redacted) at line ${line.number}`, line.number);
    }
    if (seenTopLevel.has(pair.key)) {
      throw new ManifestError(`duplicate top-level key (redacted) at line ${line.number}`, line.number);
    }
    seenTopLevel.add(pair.key);

    const inlineValue = pair.value.trim();
    if (inlineValue !== '') {
      manifest[pair.key] = { value: parseScalar(inlineValue, line.number), line: line.number };
      index += 1;
      continue;
    }

    const next = lines[index + 1];
    if (!next || next.indent <= line.indent) {
      manifest[pair.key] = { value: null, line: line.number };
      index += 1;
      continue;
    }

    if (pair.key === 'image') {
      const parsed = parseObject(lines, index + 1, line.indent + 2);
      manifest[pair.key] = { value: parsed.value, line: line.number };
      index = parsed.nextIndex;
      continue;
    }

    const parsed = parseList(lines, index + 1, line.indent + 2);
    manifest[pair.key] = { value: parsed.value, line: line.number };
    index = parsed.nextIndex;
  }

  validateManifest(manifest);

  return {
    version: String(manifest.version.value),
    tools: normalizeEntries(manifest.tools ? manifest.tools.value : []),
    credentials: normalizeEntries(manifest.credentials ? manifest.credentials.value : []),
    services: normalizeEntries(manifest.services ? manifest.services.value : []),
    egress: normalizeEntries(manifest.egress ? manifest.egress.value : []),
    image: normalizeImage(manifest.image ? manifest.image.value : null),
    notes: manifest.notes ? manifest.notes.value : null,
  };
}

function normalizeEntries(value) {
  return (value || []).map((item) => ({
    name: item.name,
    required: Object.prototype.hasOwnProperty.call(item, 'required') ? item.required : true,
    line: item.__line || null,
  }));
}

function normalizeImage(value) {
  if (!value) return null;
  return {
    hint: value.hint,
    required: Object.prototype.hasOwnProperty.call(value, 'required') ? value.required : false,
    line: value.__line || null,
  };
}

function validateManifest(manifest) {
  if (!manifest.version) {
    throw new ManifestError('missing required version field at line 1', 1);
  }
  const version = String(manifest.version.value);
  if (version !== SUPPORTED_VERSION) {
    throw new ManifestError(`unsupported manifest version at line ${manifest.version.line}`, manifest.version.line);
  }

  validateEntryArray(manifest, 'tools');
  validateEntryArray(manifest, 'credentials');
  validateEntryArray(manifest, 'services');
  validateEntryArray(manifest, 'egress');

  if (manifest.image) {
    if (manifest.image.value === null || Array.isArray(manifest.image.value) || typeof manifest.image.value !== 'object') {
      throw new ManifestError(`image must be an object at line ${manifest.image.line}`, manifest.image.line);
    }
    const image = manifest.image.value;
    if (typeof image.hint !== 'string' || image.hint.trim() === '') {
      throw new ManifestError(`image.hint must be a non-empty string at line ${image.__line || manifest.image.line}`, image.__line || manifest.image.line);
    }
    if (Object.prototype.hasOwnProperty.call(image, 'required') && typeof image.required !== 'boolean') {
      throw new ManifestError(`image.required must be a boolean at line ${image.__line || manifest.image.line}`, image.__line || manifest.image.line);
    }
  }

  if (manifest.notes) {
    if (typeof manifest.notes.value !== 'string') {
      throw new ManifestError(`notes must be a string at line ${manifest.notes.line}`, manifest.notes.line);
    }
  }
}

function validateEntryArray(manifest, key) {
  if (!manifest[key]) return;
  const line = manifest[key].line;
  const value = manifest[key].value;
  if (!Array.isArray(value)) {
    throw new ManifestError(`${key} must be a list at line ${line}`, line);
  }
  for (const item of value) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      throw new ManifestError(`invalid list item at line ${line}`, line);
    }
    if (typeof item.name !== 'string' || item.name.trim() === '') {
      throw new ManifestError(`name must be a non-empty string at line ${item.__line || line}`, item.__line || line);
    }
    if (Object.prototype.hasOwnProperty.call(item, 'required') && typeof item.required !== 'boolean') {
      throw new ManifestError(`required must be a boolean at line ${item.__line || line}`, item.__line || line);
    }
  }
}

module.exports = {
  ManifestError,
  SUPPORTED_VERSION,
  parseCapabilityManifest,
};
