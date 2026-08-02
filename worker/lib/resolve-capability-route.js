#!/usr/bin/env node
'use strict';

/**
 * resolve-capability-route.js
 *
 * Sprint 2 of PRD #6: turn a repository's capability manifest into a
 * deterministic, machine-readable ROUTING DECISION.
 *
 * The decision is computed and reported. It is NOT acted upon here: no sandbox
 * is created, no dispatch path changes, and the in-worker preflight
 * (squad-capability-preflight.sh) remains the final safety check regardless of
 * what this resolver decides. Sprint 3 adds the provider seam; Sprint 5 acts on
 * the decision.
 *
 * This builds on worker/lib/parse-capabilities.js — it consumes the manifest
 * that parser already produces and validates, and never re-implements parsing.
 *
 * Routes:
 *   aca-job      run on the existing fixed squad-worker ACA job (today's path)
 *   sandbox      run in an administrator-approved ACA Sandboxes class
 *   fail-closed  refuse to route; a human must resolve the gap
 *
 * Security invariants (non-negotiable):
 *   1. A manifest only *requests* capabilities. It can never grant privilege,
 *      select an arbitrary image, name a shell command, add an egress
 *      destination, or bypass administrator approval. Every capability that can
 *      be granted comes from config/sandbox-classes.json, which lives in the
 *      control plane, not in the worked-on repository.
 *   2. image.hint is only ever used to disambiguate between already-approved
 *      classes (matched against a class's imageHintAliases). It is never used
 *      as, or turned into, an image reference. The emitted "imageHint" field is
 *      therefore always a catalog-owned string or null — never manifest text.
 *   3. Repository entries may only NARROW within an approved class's egress
 *      template. A declared host that the class template does not already
 *      permit disqualifies the class; it never widens it.
 *   4. Diagnostics are redacted. Only allowlisted identifier NAMES, fixed reason
 *      codes, and counts are emitted. Free-form manifest text (reason, notes,
 *      raw key names, values) never reaches the output, logs, or errors.
 *   5. Anything ambiguous fails closed. A malformed manifest, an unreadable or
 *      invalid catalog, an unsafe manifest path, or an identifier that is
 *      safe-charactered but implausibly long all produce fail-closed — never a
 *      silent aca-job.
 *
 * Determinism: object keys are emitted in a fixed order and every array is
 * de-duplicated and sorted by code unit, so the output is golden-testable and
 * diffable.
 *
 * Usage:
 *   node resolve-capability-route.js <repo-dir> [--manifest-path <relative>]
 *                                    [--catalog <path>] [--pretty]
 *
 * Environment:
 *   CAPABILITY_MANIFEST_PATH       manifest path relative to <repo-dir>
 *                                  (default: squad-capabilities.yml)
 *   SQUAD_SANDBOX_CLASS_CATALOG    absolute path to the sandbox class catalog
 *
 * Exit codes:
 *   0   a routing decision was produced (aca-job, sandbox, OR fail-closed);
 *       the decision itself carries the outcome
 *   64  (EX_USAGE) no repository directory supplied
 *   70  (EX_SOFTWARE) the administrator catalog is missing/unreadable/invalid,
 *       so no decision is possible. A fail-closed decision is still written to
 *       stdout so a caller that ignores exit codes still fails closed.
 */

const fs = require('fs');
const path = require('path');

const { parseCapabilityManifest, validateManifest } = require('./parse-capabilities.js');
const { locateManifest } = require('./locate-manifest.js');

const DECISION_SCHEMA_VERSION = 1;
const SUPPORTED_CATALOG_SCHEMA_VERSION = 1;
const DEFAULT_MANIFEST_RELATIVE_PATH = 'squad-capabilities.yml';

const ROUTE_ACA_JOB = 'aca-job';
const ROUTE_SANDBOX = 'sandbox';
const ROUTE_FAIL_CLOSED = 'fail-closed';

// Output safety layer. The parser already rejects control characters and
// delimiter smuggling in these fields; these bounds are defense in depth
// against a value that is character-safe but implausibly long (a log-flooding
// or golden-file-poisoning shape). Anything outside them fails closed and is
// never echoed.
const MAX_IDENTIFIER_LENGTH = 64;
const MAX_HOST_LENGTH = 253;
const MAX_IMAGE_HINT_LENGTH = 512;
const SAFE_IDENTIFIER_PATTERN = /^[A-Za-z0-9._-]+$/;
const SAFE_HOST_PATTERN = /^[A-Za-z0-9.-]+(?::\d{1,5})?$/;

// Fixed reason vocabulary. Nothing here is interpolated from manifest input, so
// a reason code can never carry attacker-controlled text.
const REASON_DETAILS = {
  'no-manifest':
    'No capability manifest is present, so the repository is routed to the existing ACA job unchanged.',
  'default-profile-satisfies-manifest':
    'Every required capability is already provided by the default worker profile, so the existing ACA job is used.',
  'approved-sandbox-class-matched':
    'Required capabilities exceed the default worker profile and an administrator-approved sandbox class provides all of them.',
  'no-approved-sandbox-class':
    'Required capabilities exceed the default worker profile and no administrator-approved sandbox class provides all of them. Extend the worker image, relax the requirement, or ask an administrator to approve a class that covers it. See docs/capability-manifest.md.',
  'manifest-invalid':
    'The capability manifest failed schema validation. Fix the manifest and retry; run the capability parser locally for the redacted field-level errors. See docs/capability-manifest.md.',
  'manifest-unreadable':
    'The capability manifest exists but could not be read. Check file permissions and encoding.',
  'manifest-path-unsafe':
    'The configured manifest path is not a regular file inside the repository working tree, so it was not read. Check CAPABILITY_MANIFEST_PATH.',
  'manifest-identifier-unsafe':
    'The manifest declares an identifier that is not safe to route on (out of bounds for a tool, credential, or host name). No manifest values are reported. Fix the manifest and retry.',
  'catalog-unavailable':
    'The administrator sandbox class catalog is missing, unreadable, or invalid, so no routing decision can be made. This is a control-plane configuration fault, not a repository fault.'
};

class SandboxCatalogError extends Error {}

function sortUnique(values) {
  return Array.from(new Set(values)).sort((a, b) => {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
  });
}

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isSafeIdentifier(value) {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= MAX_IDENTIFIER_LENGTH &&
    SAFE_IDENTIFIER_PATTERN.test(value)
  );
}

function isSafeHost(value) {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= MAX_HOST_LENGTH &&
    SAFE_HOST_PATTERN.test(value)
  );
}

// --------------------------------------------------------------------------
// Administrator catalog
// --------------------------------------------------------------------------

// An explicitly configured catalog path is authoritative: if it is given and
// unusable, that is an error, never a silent fall back to a different catalog.
function catalogSearchPaths(explicitPath) {
  const configured = explicitPath || process.env.SQUAD_SANDBOX_CLASS_CATALOG || null;
  if (configured) return [configured];
  return [
    // Packaged next to the worker libraries inside the image (Sprint 3), then
    // the repository layout used by tests and local runs.
    path.join(__dirname, 'sandbox-classes.json'),
    path.resolve(__dirname, '..', '..', 'config', 'sandbox-classes.json')
  ];
}

function validateEgressPolicy(policy, context, errors) {
  if (!isPlainObject(policy)) {
    errors.push(`${context}.egress must be a mapping`);
    return;
  }
  if (policy.defaultAction !== 'Allow' && policy.defaultAction !== 'Deny') {
    errors.push(`${context}.egress.defaultAction must be "Allow" or "Deny"`);
  }
  if (!Array.isArray(policy.hostRules)) {
    errors.push(`${context}.egress.hostRules must be a list`);
    return;
  }
  policy.hostRules.forEach((rule, idx) => {
    if (!isPlainObject(rule)) {
      errors.push(`${context}.egress.hostRules[${idx}] must be a mapping`);
      return;
    }
    if (typeof rule.pattern !== 'string' || rule.pattern.trim() === '') {
      errors.push(`${context}.egress.hostRules[${idx}].pattern must be a non-empty string`);
    }
    if (rule.action !== 'Allow' && rule.action !== 'Deny') {
      errors.push(`${context}.egress.hostRules[${idx}].action must be "Allow" or "Deny"`);
    }
  });
}

function validateStringList(value, context, errors) {
  if (!Array.isArray(value)) {
    errors.push(`${context} must be a list`);
    return;
  }
  value.forEach((entry, idx) => {
    if (typeof entry !== 'string' || entry.trim() === '') {
      errors.push(`${context}[${idx}] must be a non-empty string`);
    }
  });
}

function validateCatalog(catalog) {
  const errors = [];

  if (!isPlainObject(catalog)) return ['catalog root must be a mapping'];

  if (catalog.schemaVersion !== SUPPORTED_CATALOG_SCHEMA_VERSION) {
    errors.push(`catalog schemaVersion must be ${SUPPORTED_CATALOG_SCHEMA_VERSION}`);
  }
  if (typeof catalog.provisional !== 'boolean') {
    errors.push('catalog "provisional" must be a boolean');
  }

  if (!isPlainObject(catalog.defaultWorker)) {
    errors.push('catalog "defaultWorker" must be a mapping');
  } else {
    if (typeof catalog.defaultWorker.id !== 'string' || catalog.defaultWorker.id.trim() === '') {
      errors.push('"defaultWorker.id" must be a non-empty string');
    }
    validateStringList(catalog.defaultWorker.tools, '"defaultWorker.tools"', errors);
    validateStringList(catalog.defaultWorker.credentials, '"defaultWorker.credentials"', errors);
    validateEgressPolicy(catalog.defaultWorker.egress, '"defaultWorker"', errors);
  }

  if (!Array.isArray(catalog.classes)) {
    errors.push('catalog "classes" must be a list');
    return errors;
  }

  const seenIds = new Set();
  catalog.classes.forEach((cls, idx) => {
    const context = `"classes[${idx}]"`;
    if (!isPlainObject(cls)) {
      errors.push(`${context} must be a mapping`);
      return;
    }
    if (typeof cls.id !== 'string' || cls.id.trim() === '') {
      errors.push(`${context}.id must be a non-empty string`);
    } else if (seenIds.has(cls.id)) {
      errors.push(`${context}.id is a duplicate class id`);
    } else {
      seenIds.add(cls.id);
    }
    if (typeof cls.approved !== 'boolean') {
      errors.push(`${context}.approved must be a boolean`);
    }
    if (!isPlainObject(cls.image) || typeof cls.image.reference !== 'string' || cls.image.reference.trim() === '') {
      errors.push(`${context}.image must be a mapping with a non-empty "reference"`);
    } else if (catalog.provisional === false && cls.approved === true) {
      // An approved class in a REVIEWED catalog can create a sandbox that runs
      // repository code, so it must name an immutable image. A moving tag means
      // re-tagging the registry silently changes what executes; a digest cannot
      // be re-pointed. This is only enforced once provisional is cleared, so a
      // provisional catalog may still carry placeholders (that is what
      // provisional means).
      if (cls.image.pinned !== true) {
        errors.push(`${context}.image.pinned must be true for an approved class in a non-provisional catalog`);
      }
      if (typeof cls.image.digest !== 'string' || !/^sha256:[0-9a-f]{64}$/.test(cls.image.digest)) {
        errors.push(`${context}.image.digest must be a sha256 digest for an approved class in a non-provisional catalog`);
      }
    }
    if (!isPlainObject(cls.resources)) {
      errors.push(`${context}.resources must be a mapping`);
    }
    if (!isPlainObject(cls.limits)) {
      errors.push(`${context}.limits must be a mapping`);
    }
    validateStringList(cls.tools, `${context}.tools`, errors);
    validateStringList(cls.allowedCredentials, `${context}.allowedCredentials`, errors);
    if (!Array.isArray(cls.imageHintAliases)) {
      errors.push(`${context}.imageHintAliases must be a list`);
    } else {
      validateStringList(cls.imageHintAliases, `${context}.imageHintAliases`, errors);
    }
    validateEgressPolicy(cls.egress, context, errors);
  });

  return errors;
}

function loadCatalog(explicitPath) {
  const candidates = catalogSearchPaths(explicitPath);
  let resolved = null;
  for (const candidate of candidates) {
    try {
      if (fs.statSync(candidate).isFile()) {
        resolved = candidate;
        break;
      }
    } catch (err) {
      // Candidate absent; try the next one.
    }
  }
  if (!resolved) {
    throw new SandboxCatalogError('sandbox class catalog not found');
  }

  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(resolved, 'utf8'));
  } catch (err) {
    throw new SandboxCatalogError('sandbox class catalog is not valid JSON');
  }

  const errors = validateCatalog(parsed);
  if (errors.length > 0) {
    throw new SandboxCatalogError(`sandbox class catalog is invalid (${errors.length} problem(s))`);
  }

  return parsed;
}

// --------------------------------------------------------------------------
// Egress template matching
// --------------------------------------------------------------------------

// Strips an optional ":<port>" suffix. Host rules are FQDN patterns; ports are
// not part of the allowlist decision.
function hostOf(value) {
  const idx = value.indexOf(':');
  return idx === -1 ? value : value.slice(0, idx);
}

// "*.example.com" matches any host ending in ".example.com" (one or more
// leading labels) and deliberately does NOT match the bare apex "example.com",
// which must be listed explicitly. Every other pattern is an exact,
// case-insensitive host match. No other wildcard form is supported.
function hostMatchesPattern(host, pattern) {
  const normalizedHost = hostOf(host).toLowerCase();
  const normalizedPattern = pattern.toLowerCase();
  if (normalizedPattern.startsWith('*.')) {
    const suffix = normalizedPattern.slice(1); // ".example.com"
    return normalizedHost.length > suffix.length && normalizedHost.endsWith(suffix);
  }
  return normalizedHost === normalizedPattern;
}

// First matching rule wins; defaultAction applies when no rule matches. This is
// the ACA Sandboxes network policy evaluation order.
function egressAllows(policy, host) {
  for (const rule of policy.hostRules) {
    if (hostMatchesPattern(host, rule.pattern)) {
      return rule.action === 'Allow';
    }
  }
  return policy.defaultAction === 'Allow';
}

// --------------------------------------------------------------------------
// Decision construction
// --------------------------------------------------------------------------

// Single construction point for the decision object so key order is fixed and
// every field is always present. Golden files depend on this.
function buildDecision(overrides) {
  const base = {
    schemaVersion: DECISION_SCHEMA_VERSION,
    route: ROUTE_FAIL_CLOSED,
    reason: 'manifest-invalid',
    requiredTools: [],
    requiredCredentials: [],
    egressHosts: [],
    imageHint: null,
    defaultImageSufficient: false,
    sandboxClass: null,
    manifestPresent: false,
    manifestVersion: null,
    imageHintPresent: false,
    imageHintRecognized: false,
    unsatisfiedTools: [],
    unsatisfiedCredentials: [],
    unsatisfiedEgressHosts: [],
    catalogSchemaVersion: null,
    catalogProvisional: true,
    detail: ''
  };
  const merged = Object.assign(base, overrides);
  merged.detail = REASON_DETAILS[merged.reason] || '';
  // Re-project through the base key order so overrides can never reorder keys.
  const ordered = {};
  for (const key of Object.keys(base)) ordered[key] = merged[key];
  return ordered;
}

function requiredNames(section, nameKey) {
  if (!Array.isArray(section)) return [];
  return section
    .filter((item) => isPlainObject(item) && item.required === true && typeof item[nameKey] === 'string')
    .map((item) => item[nameKey]);
}

function declaredHosts(section) {
  if (!Array.isArray(section)) return [];
  return section
    .filter((item) => isPlainObject(item) && typeof item.host === 'string')
    .map((item) => item.host);
}

function profileSatisfies(profileTools, profileCredentials, profileEgress, required) {
  return (
    required.tools.every((tool) => profileTools.has(tool)) &&
    required.credentials.every((credential) => profileCredentials.has(credential)) &&
    required.egressHosts.every((host) => egressAllows(profileEgress, host))
  );
}

/**
 * Computes the routing decision.
 *
 * @param {object}  input
 * @param {boolean} input.manifestPresent  whether a manifest file exists
 * @param {object}  [input.manifest]       the parsed+validated manifest
 * @param {string}  [input.manifestFailure] a fixed reason code when the manifest
 *                                          could not be parsed/validated/read
 * @param {object}  input.catalog          the administrator catalog
 * @returns {object} the ordered decision object
 */
function resolveCapabilityRoute(input) {
  const catalog = input.catalog;
  const catalogFields = {
    catalogSchemaVersion: catalog ? catalog.schemaVersion : null,
    catalogProvisional: catalog ? catalog.provisional !== false : true
  };

  if (!catalog) {
    return buildDecision(Object.assign({ reason: 'catalog-unavailable' }, catalogFields));
  }

  if (!input.manifestPresent) {
    return buildDecision(
      Object.assign(
        {
          route: ROUTE_ACA_JOB,
          reason: 'no-manifest',
          defaultImageSufficient: true,
          manifestPresent: false
        },
        catalogFields
      )
    );
  }

  if (input.manifestFailure) {
    return buildDecision(
      Object.assign({ reason: input.manifestFailure, manifestPresent: true }, catalogFields)
    );
  }

  const manifest = input.manifest || {};

  const rawTools = requiredNames(manifest.tools, 'name');
  const rawCredentials = requiredNames(manifest.credentials, 'name');
  const rawHosts = declaredHosts(manifest.egress);
  const rawHint =
    isPlainObject(manifest.image) && typeof manifest.image.hint === 'string' ? manifest.image.hint : null;

  // Defense in depth: refuse to route on anything the output safety layer would
  // not emit, and never echo the offending value. Fails closed.
  const identifiersSafe =
    rawTools.every(isSafeIdentifier) &&
    rawCredentials.every(isSafeIdentifier) &&
    rawHosts.every(isSafeHost) &&
    (rawHint === null || rawHint.length <= MAX_IMAGE_HINT_LENGTH);

  if (!identifiersSafe) {
    return buildDecision(
      Object.assign(
        {
          reason: 'manifest-identifier-unsafe',
          manifestPresent: true,
          manifestVersion: Number.isInteger(manifest.version) ? manifest.version : null,
          imageHintPresent: rawHint !== null
        },
        catalogFields
      )
    );
  }

  const required = {
    tools: sortUnique(rawTools),
    credentials: sortUnique(rawCredentials),
    egressHosts: sortUnique(rawHosts)
  };

  const common = Object.assign(
    {
      requiredTools: required.tools,
      requiredCredentials: required.credentials,
      egressHosts: required.egressHosts,
      manifestPresent: true,
      manifestVersion: Number.isInteger(manifest.version) ? manifest.version : null,
      imageHintPresent: rawHint !== null
    },
    catalogFields
  );

  const defaultTools = new Set(catalog.defaultWorker.tools);
  const defaultCredentials = new Set(catalog.defaultWorker.credentials);
  const defaultSufficient = profileSatisfies(
    defaultTools,
    defaultCredentials,
    catalog.defaultWorker.egress,
    required
  );

  if (defaultSufficient) {
    // image.hint stays advisory here: the default profile already satisfies
    // everything, so the hint cannot change the route. Preserves today's
    // behaviour for the overwhelmingly common case.
    return buildDecision(
      Object.assign({}, common, {
        route: ROUTE_ACA_JOB,
        reason: 'default-profile-satisfies-manifest',
        defaultImageSufficient: true
      })
    );
  }

  const approved = catalog.classes
    .filter((cls) => cls.approved === true)
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  const candidates = approved.filter((cls) =>
    profileSatisfies(new Set(cls.tools), new Set(cls.allowedCredentials), cls.egress, required)
  );

  if (candidates.length === 0) {
    // Report only the requirements that NO approved class can provide. Names
    // are allowlisted identifiers, never free-form manifest text.
    const unsatisfiedTools = required.tools.filter(
      (tool) => !approved.some((cls) => cls.tools.includes(tool))
    );
    const unsatisfiedCredentials = required.credentials.filter(
      (credential) => !approved.some((cls) => cls.allowedCredentials.includes(credential))
    );
    const unsatisfiedEgressHosts = required.egressHosts.filter(
      (host) => !approved.some((cls) => egressAllows(cls.egress, host))
    );
    return buildDecision(
      Object.assign({}, common, {
        route: ROUTE_FAIL_CLOSED,
        reason: 'no-approved-sandbox-class',
        defaultImageSufficient: false,
        unsatisfiedTools,
        unsatisfiedCredentials,
        unsatisfiedEgressHosts
      })
    );
  }

  // The hint can only narrow an already-approved candidate set. It is never
  // used as an image reference, and an unrecognized hint is ignored rather than
  // honoured.
  const hinted = rawHint === null ? [] : candidates.filter((cls) => cls.imageHintAliases.includes(rawHint));
  const selected = hinted.length > 0 ? hinted[0] : candidates[0];
  const matchedAlias = hinted.length > 0 ? rawHint : null;

  return buildDecision(
    Object.assign({}, common, {
      route: ROUTE_SANDBOX,
      reason: 'approved-sandbox-class-matched',
      defaultImageSufficient: false,
      sandboxClass: selected.id,
      // Catalog-owned value only: this is the alias string as stored in the
      // catalog, echoed back after an exact match. Never raw manifest text.
      imageHint: matchedAlias === null ? null : selected.imageHintAliases.find((alias) => alias === matchedAlias),
      imageHintRecognized: matchedAlias !== null
    })
  );
}

// --------------------------------------------------------------------------
// Manifest location + load
// --------------------------------------------------------------------------

// The manifest-path rules live in ONE place: worker/lib/locate-manifest.js.
// They used to live here AND as an inline node heredoc inside
// worker/lib/squad-capability-preflight.sh, so a rule could be added to the
// routing decision without being added to the gate that actually runs in the
// session. locateManifest is re-exported below so existing callers of this
// module are unaffected by where the code now lives.
//
// This resolver is the module's in-process consumer; the preflight is its CLI
// consumer. Both verdicts come from the same function, and
// worker/tests/test_manifest_path_corpus.sh drives the same corpus through both
// entry points so a change to the rules has to move both, or fail twice.

function loadManifest(manifestPath) {
  let source;
  try {
    source = fs.readFileSync(manifestPath, 'utf8');
  } catch (err) {
    return { failure: 'manifest-unreadable' };
  }

  let manifest;
  try {
    manifest = parseCapabilityManifest(source);
  } catch (err) {
    return { failure: 'manifest-invalid' };
  }

  if (validateManifest(manifest).length > 0) {
    return { failure: 'manifest-invalid' };
  }

  return { manifest };
}

// --------------------------------------------------------------------------
// CLI
// --------------------------------------------------------------------------

// Positional walk so a flag's value can never be mistaken for the repo dir (and
// vice versa) just because the two strings happen to be equal.
function parseArgs(args) {
  const parsed = { pretty: false, catalogPath: null, manifestPathFlag: null, repoDir: null };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--pretty') {
      parsed.pretty = true;
    } else if (arg === '--catalog') {
      parsed.catalogPath = args[i + 1] !== undefined ? args[i + 1] : null;
      i += 1;
    } else if (arg === '--manifest-path') {
      parsed.manifestPathFlag = args[i + 1] !== undefined ? args[i + 1] : null;
      i += 1;
    } else if (!arg.startsWith('--') && parsed.repoDir === null) {
      parsed.repoDir = arg;
    }
  }
  return parsed;
}

function main() {
  const { pretty, catalogPath, manifestPathFlag, repoDir } = parseArgs(process.argv.slice(2));

  if (!repoDir) {
    process.stderr.write(
      'Usage: resolve-capability-route.js <repo-dir> [--manifest-path <relative>] [--catalog <path>] [--pretty]\n'
    );
    process.exit(64);
  }

  let catalog = null;
  try {
    catalog = loadCatalog(catalogPath);
  } catch (err) {
    if (!(err instanceof SandboxCatalogError)) throw err;
    // No decision is possible. Emit a fail-closed decision anyway so a caller
    // that ignores the exit code still fails closed, then exit non-zero.
    const decision = resolveCapabilityRoute({ manifestPresent: false, catalog: null });
    process.stdout.write(JSON.stringify(decision, null, pretty ? 2 : 0) + '\n');
    process.stderr.write(`Cannot resolve capability route: ${err.message}\n`);
    process.exit(70);
  }

  const manifestRelativePath =
    manifestPathFlag || process.env.CAPABILITY_MANIFEST_PATH || DEFAULT_MANIFEST_RELATIVE_PATH;
  const located = locateManifest(repoDir, manifestRelativePath);

  let decision;
  if (located.status === 'absent') {
    decision = resolveCapabilityRoute({ manifestPresent: false, catalog });
  } else if (located.status === 'unsafe') {
    decision = resolveCapabilityRoute({
      manifestPresent: true,
      manifestFailure: 'manifest-path-unsafe',
      catalog
    });
  } else {
    const loaded = loadManifest(located.path);
    decision = resolveCapabilityRoute({
      manifestPresent: true,
      manifest: loaded.manifest,
      manifestFailure: loaded.failure,
      catalog
    });
  }

  process.stdout.write(JSON.stringify(decision, null, pretty ? 2 : 0) + '\n');
}

if (require.main === module) {
  main();
}

module.exports = {
  DECISION_SCHEMA_VERSION,
  ROUTE_ACA_JOB,
  ROUTE_SANDBOX,
  ROUTE_FAIL_CLOSED,
  SandboxCatalogError,
  egressAllows,
  hostMatchesPattern,
  loadCatalog,
  loadManifest,
  locateManifest,
  resolveCapabilityRoute,
  validateCatalog
};
