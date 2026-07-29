#!/usr/bin/env node
'use strict';

/**
 * verify-image-evidence.js
 *
 * WHY THIS EXISTS
 * ---------------
 * config/sandbox-classes.json states, per class, which `tools` an image
 * provides. Until now nothing compared that statement to the image, and the
 * statement was wrong: two approved classes pinned the same squad-worker digest
 * and between them claimed python3, pip3, jq, make and pnpm that the image did
 * not carry. Routing sent a Python repository to a class with no Python; only
 * the in-worker preflight stopped the session. A declaration that nothing
 * verifies is exactly the defect class this programme keeps rejecting.
 *
 * This module is the missing comparison. It is deliberately SEPARATE from
 * validateCatalog() in resolve-capability-route.js: that function is a pure,
 * filesystem-free structural check that runs on the dispatch hot path and
 * inside the worker image, where evidence files are not shipped. This one reads
 * the filesystem and is run by the gates (scripts/validate.ps1, the worker test
 * suite), never by dispatch. Mixing the two would either put file I/O on the
 * routing path or make routing fail for a reason routing cannot fix.
 *
 * WHAT IT PROVES, AND WHAT IT DOES NOT
 * ------------------------------------
 * This check is OFFLINE. It cannot pull a private ACR image, so it does NOT
 * inspect image contents. It proves:
 *
 *   - every approved class in a reviewed catalog has a recorded evidence file,
 *   - that file is keyed by, and agrees with, the digest the class pins,
 *   - the evidence was recorded for the same image repository, and
 *   - every tool the class claims appears in the evidence's observed tools.
 *
 * Producing the evidence requires a live run against the real registry:
 * scripts/verify-image-tools.ps1 boots the pinned digest as a sandbox, probes
 * each tool, and writes the file this check reads. So: a LIVE RUN proves what
 * is in the image; CI proves that a live run happened for exactly the digest
 * that is pinned today, and that the claims do not exceed what it observed.
 * Re-pinning a class to a new digest without re-running the live verification
 * therefore FAILS here, because the evidence for the new digest does not exist.
 *
 * FAIL CLOSED. Missing evidence, unreadable evidence, evidence for a different
 * digest or a different repository, and a claim wider than the evidence are all
 * FAILURES. None of them is a skip. A check that passes when its input is
 * missing is not a check.
 *
 * Usage:
 *   node verify-image-evidence.js [--catalog <path>] [--evidence-dir <path>]
 *                                 [--json]
 *
 * Exit codes:
 *   0   every approved class is backed by matching evidence
 *   1   at least one problem was found (details on stdout)
 *   64  (EX_USAGE) bad arguments
 *   70  (EX_SOFTWARE) the catalog itself is missing, unreadable or invalid
 */

const fs = require('fs');
const path = require('path');

const EVIDENCE_SCHEMA_VERSION = 1;

const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/;
// Same identifier grammar the resolver already routes on, so a tool name that
// could not be routed on cannot be smuggled in through an evidence file.
const TOOL_NAME_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;
const IMAGE_REFERENCE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._\-/:]{0,254}$/;
const TIMESTAMP_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

const DEFAULT_CATALOG_PATH = path.resolve(__dirname, '..', '..', 'config', 'sandbox-classes.json');
const DEFAULT_EVIDENCE_DIR = path.resolve(__dirname, '..', '..', 'config', 'image-evidence');

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * The evidence file name for a digest. Keying the file by digest is the whole
 * mechanism: a re-pin changes the file name that must exist, so evidence can
 * never silently carry over to an image nobody probed.
 */
function evidenceFileNameForDigest(digest) {
  return `${String(digest).replace(':', '-')}.json`;
}

function validateStringList(value, context, errors) {
  if (!Array.isArray(value)) {
    errors.push(`${context} must be a list`);
    return [];
  }
  const bad = value.filter((entry) => typeof entry !== 'string' || !TOOL_NAME_PATTERN.test(entry));
  if (bad.length > 0) {
    errors.push(`${context} must contain only tool names matching ${TOOL_NAME_PATTERN}`);
  }
  return value.filter((entry) => typeof entry === 'string');
}

/**
 * Structural validation of one evidence document, independent of any catalog.
 *
 * @param {object} doc      the parsed evidence document
 * @param {string} context  human label used in error text
 * @returns {string[]} errors (empty when the document is well formed)
 */
function validateEvidenceDocument(doc, context) {
  const errors = [];
  if (!isPlainObject(doc)) return [`${context} must be a JSON object`];

  if (doc.schemaVersion !== EVIDENCE_SCHEMA_VERSION) {
    errors.push(`${context}.schemaVersion must be ${EVIDENCE_SCHEMA_VERSION}`);
  }
  if (!isPlainObject(doc.image)) {
    errors.push(`${context}.image must be a mapping with "reference" and "digest"`);
  } else {
    if (typeof doc.image.reference !== 'string' || !IMAGE_REFERENCE_PATTERN.test(doc.image.reference)) {
      errors.push(`${context}.image.reference must be an image repository reference`);
    }
    if (typeof doc.image.digest !== 'string' || !DIGEST_PATTERN.test(doc.image.digest)) {
      errors.push(`${context}.image.digest must be a sha256 digest`);
    }
  }
  if (typeof doc.verifiedAt !== 'string' || !TIMESTAMP_PATTERN.test(doc.verifiedAt)) {
    errors.push(`${context}.verifiedAt must be a UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)`);
  }
  if (typeof doc.method !== 'string' || doc.method.trim() === '') {
    errors.push(`${context}.method must describe how the image was probed`);
  }

  if (!isPlainObject(doc.tools)) {
    errors.push(`${context}.tools must be a mapping with "present" and "absent" lists`);
    return errors;
  }
  const present = validateStringList(doc.tools.present, `${context}.tools.present`, errors);
  const absent = validateStringList(doc.tools.absent, `${context}.tools.absent`, errors);

  // An evidence file that observed nothing proves nothing. Treat it as a
  // failure rather than as a vacuously satisfied claim.
  if (Array.isArray(doc.tools.present) && present.length === 0) {
    errors.push(`${context}.tools.present is empty, so the probe observed nothing`);
  }
  const overlap = present.filter((tool) => absent.includes(tool));
  if (overlap.length > 0) {
    errors.push(
      `${context} records ${overlap.length} tool(s) as both present and absent: ${overlap.sort().join(', ')}`
    );
  }
  return errors;
}

function readEvidenceFile(filePath, context) {
  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (err) {
    return { doc: null, errors: [`${context} could not be read`] };
  }
  let doc;
  try {
    doc = JSON.parse(raw);
  } catch (err) {
    return { doc: null, errors: [`${context} is not valid JSON`] };
  }
  return { doc, errors: validateEvidenceDocument(doc, context) };
}

/**
 * Compares every approved class's declared tools against the recorded evidence
 * for the digest it pins.
 *
 * Scope: approved classes in a REVIEWED (provisional:false) catalog. That
 * mirrors the pinning rule already enforced by validateCatalog: a provisional
 * catalog is report-only and cannot reach the execution plane at all, so
 * requiring probe evidence for a draft class would block the drafting workflow
 * without closing any hole. An UNAPPROVED class is never selectable, so it
 * needs no evidence -- but if it happens to carry an evidence file, that file
 * still has to be well formed and correctly keyed.
 *
 * @param {object} catalog       parsed config/sandbox-classes.json
 * @param {string} evidenceDir   directory holding sha256-<hex>.json files
 * @returns {string[]} errors (empty when every approved class is backed)
 */
function verifyCatalogEvidence(catalog, evidenceDir) {
  const errors = [];
  if (!isPlainObject(catalog)) return ['catalog root must be a mapping'];
  if (!Array.isArray(catalog.classes)) return ['catalog "classes" must be a list'];

  const reviewed = catalog.provisional === false;

  catalog.classes.forEach((cls, idx) => {
    if (!isPlainObject(cls)) {
      errors.push(`"classes[${idx}]" must be a mapping`);
      return;
    }
    const label = typeof cls.id === 'string' && cls.id.trim() !== '' ? cls.id : `classes[${idx}]`;
    const image = isPlainObject(cls.image) ? cls.image : {};
    const digest = typeof image.digest === 'string' ? image.digest : null;
    const approved = cls.approved === true;

    if (!approved) {
      // Not selectable, so no evidence is required. Any file that IS present
      // for its digest must still be honest, or a later approval would inherit
      // a broken record.
      if (digest && DIGEST_PATTERN.test(digest)) {
        const candidate = path.join(evidenceDir, evidenceFileNameForDigest(digest));
        if (fs.existsSync(candidate)) {
          const read = readEvidenceFile(candidate, `evidence for ${label}`);
          read.errors.forEach((e) => errors.push(e));
        }
      }
      return;
    }

    if (!reviewed) return;

    if (!digest || !DIGEST_PATTERN.test(digest)) {
      errors.push(`${label}: approved class has no sha256 image.digest, so its claims cannot be verified`);
      return;
    }

    const fileName = evidenceFileNameForDigest(digest);
    const filePath = path.join(evidenceDir, fileName);
    if (!fs.existsSync(filePath)) {
      errors.push(
        `${label}: no image evidence recorded for the pinned digest (expected ${path.basename(
          evidenceDir
        )}/${fileName}). Run scripts/verify-image-tools.ps1 against this digest.`
      );
      return;
    }

    const context = `evidence for ${label}`;
    const read = readEvidenceFile(filePath, context);
    if (read.errors.length > 0) {
      read.errors.forEach((e) => errors.push(e));
      return;
    }
    const doc = read.doc;

    // The file name is derived from the digest, so a mismatch here means the
    // document was copied from another image's evidence.
    if (doc.image.digest !== digest) {
      errors.push(`${context}: records digest ${doc.image.digest}, but the class pins ${digest}`);
      return;
    }
    if (typeof image.reference === 'string' && doc.image.reference !== image.reference) {
      errors.push(
        `${context}: recorded for image repository ${doc.image.reference}, but the class references ${image.reference}`
      );
      return;
    }

    const declared = Array.isArray(cls.tools) ? cls.tools.filter((t) => typeof t === 'string') : null;
    if (declared === null) {
      errors.push(`${label}: tools must be a list`);
      return;
    }
    if (declared.length === 0) {
      errors.push(`${label}: approved class declares no tools, so routing to it can never be justified`);
      return;
    }

    const present = new Set(doc.tools.present);
    const unbacked = declared.filter((tool) => !present.has(tool)).sort();
    if (unbacked.length > 0) {
      errors.push(
        `${label}: claims ${unbacked.length} tool(s) the pinned image was not observed to provide: ${unbacked.join(
          ', '
        )}`
      );
    }
  });

  return errors;
}

// --------------------------------------------------------------------------
// CLI
// --------------------------------------------------------------------------

function parseArgs(argv) {
  const flags = { catalog: DEFAULT_CATALOG_PATH, evidenceDir: DEFAULT_EVIDENCE_DIR, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--catalog') {
      flags.catalog = argv[i + 1];
      i += 1;
    } else if (arg === '--evidence-dir') {
      flags.evidenceDir = argv[i + 1];
      i += 1;
    } else if (arg === '--json') {
      flags.json = true;
    } else {
      return { error: `unrecognized argument: ${arg}` };
    }
  }
  if (!flags.catalog || !flags.evidenceDir) return { error: 'missing value for --catalog or --evidence-dir' };
  return { flags };
}

function main(argv) {
  const parsed = parseArgs(argv);
  if (parsed.error) {
    process.stderr.write(`verify-image-evidence: ${parsed.error}\n`);
    return 64;
  }
  const { catalog: catalogPath, evidenceDir, json } = parsed.flags;

  let catalog;
  try {
    catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
  } catch (err) {
    process.stderr.write(`verify-image-evidence: catalog is missing or not valid JSON: ${catalogPath}\n`);
    return 70;
  }

  const errors = verifyCatalogEvidence(catalog, evidenceDir);
  if (json) {
    process.stdout.write(`${JSON.stringify({ ok: errors.length === 0, errors }, null, 2)}\n`);
  } else if (errors.length === 0) {
    process.stdout.write('image evidence OK: every approved class is backed by evidence for the digest it pins\n');
  } else {
    process.stdout.write(`image evidence FAILED (${errors.length} problem(s)):\n`);
    errors.forEach((e) => process.stdout.write(`  - ${e}\n`));
  }
  return errors.length === 0 ? 0 : 1;
}

if (require.main === module) {
  process.exit(main(process.argv.slice(2)));
}

module.exports = {
  EVIDENCE_SCHEMA_VERSION,
  DEFAULT_CATALOG_PATH,
  DEFAULT_EVIDENCE_DIR,
  evidenceFileNameForDigest,
  validateEvidenceDocument,
  verifyCatalogEvidence
};
