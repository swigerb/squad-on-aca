#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { parseCapabilityManifest, ManifestError, SUPPORTED_VERSION } = require('./parse-capabilities');

const RESOLUTION_SCHEMA_VERSION = '1';
const DEFAULT_MANIFEST_NAME = 'squad-capabilities.yml';

const KNOWN_CAPABILITIES = Object.freeze({
  tools: new Set(['az', 'bash', 'copilot', 'docker', 'gh', 'git', 'kubectl', 'make', 'node', 'npm', 'python3', 'squad']),
  credentials: new Set(['azure-client-id', 'azure-subscription-id', 'azure-tenant-id', 'copilot-github-token', 'github-token']),
  services: new Set(['aspire-otlp', 'azure-management', 'git-remote', 'github-api', 'private-artifacts']),
  egress: new Set(['api.github.com', 'ca-squad-aspire', 'github.com', 'management.azure.com', 'packages.github.com']),
});

const DEFAULT_WORKER = Object.freeze({
  tools: new Set(['az', 'bash', 'copilot', 'gh', 'git', 'node', 'npm', 'squad']),
  credentials: new Set(['copilot-github-token', 'github-token']),
  services: new Set(['aspire-otlp', 'azure-management', 'git-remote', 'github-api', 'private-artifacts']),
  egress: new Set(['api.github.com', 'ca-squad-aspire', 'github.com', 'management.azure.com', 'packages.github.com']),
  imageHints: new Set(),
});

function stableResolution(overrides) {
  return Object.assign({
    schemaVersion: RESOLUTION_SCHEMA_VERSION,
    route: 'aca-job',
    sandboxClass: null,
    requiredCapabilities: [],
    optionalCapabilities: [],
    unsatisfiedRequired: [],
    fallbackReason: null,
    manifestPresent: false,
    manifestVersion: null,
    defaultImageSufficient: true,
  }, overrides || {});
}

function createCapabilityToken(kind, name) {
  return `${kind}:${name}`;
}

function safeFailure(message, details) {
  return stableResolution(Object.assign({
    route: 'fail-closed',
    fallbackReason: message,
    defaultImageSufficient: false,
  }, details || {}));
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function loadSandboxClasses(filePath) {
  const data = readJson(filePath);
  const classes = Array.isArray(data.classes) ? data.classes : [];
  return classes.map((entry, index) => ({
    name: String(entry.name || `class-${index + 1}`),
    imageHints: new Set((entry.imageHints || []).map(String)),
    capabilities: {
      tools: new Set((entry.capabilities && entry.capabilities.tools || []).map(String)),
      credentials: new Set((entry.capabilities && entry.capabilities.credentials || []).map(String)),
      services: new Set((entry.capabilities && entry.capabilities.services || []).map(String)),
      egress: new Set((entry.capabilities && entry.capabilities.egress || []).map(String)),
    },
  })).sort((left, right) => left.name.localeCompare(right.name));
}

function validateKnownIdentifiers(manifest) {
  for (const kind of ['tools', 'credentials', 'services', 'egress']) {
    for (const entry of manifest[kind]) {
      if (!KNOWN_CAPABILITIES[kind].has(entry.name)) {
        throw new ManifestError(`unsupported ${kind.slice(0, -1)} identifier at line ${entry.line || 1}`, entry.line || 1);
      }
    }
  }
}

function collectRequests(manifest) {
  const required = [];
  const optional = [];
  for (const kind of ['tools', 'credentials', 'services', 'egress']) {
    for (const entry of manifest[kind]) {
      const token = createCapabilityToken(kind, entry.name);
      (entry.required ? required : optional).push(token);
    }
  }
  if (manifest.image && manifest.image.hint) {
    const token = createCapabilityToken('image', manifest.image.hint);
    (manifest.image.required ? required : optional).push(token);
  }
  required.sort();
  optional.sort();
  return { required, optional };
}

function setHas(set, name) {
  return set instanceof Set && set.has(name);
}

function capabilitySatisfiedBy(source, token) {
  const [kind, name] = token.split(/:(.+)/);
  if (kind === 'image') {
    return setHas(source.imageHints, name);
  }
  return setHas(source[kind], name);
}

function findUnsatisfied(source, requested) {
  return requested.filter((token) => !capabilitySatisfiedBy(source, token));
}

function redactToken(tokens, originalToken) {
  return tokens.map((token) => (token === originalToken ? 'image:[redacted]' : token));
}

function sandboxCanSatisfy(sandbox, token) {
  return capabilitySatisfiedBy({
    tools: sandbox.capabilities.tools,
    credentials: sandbox.capabilities.credentials,
    services: sandbox.capabilities.services,
    egress: sandbox.capabilities.egress,
    imageHints: sandbox.imageHints,
  }, token);
}

function chooseSandboxClass(classes, requestedRequired, requestedOptional, imageHint, defaultUnsatisfiedAll) {
  const candidates = [];
  for (const sandbox of classes) {
    const requiredMissing = requestedRequired.filter((token) => !sandboxCanSatisfy(sandbox, token));
    if (requiredMissing.length > 0) continue;
    const optionalCovered = requestedOptional.filter((token) => sandboxCanSatisfy(sandbox, token));
    const requestedCovered = defaultUnsatisfiedAll.filter((token) => sandboxCanSatisfy(sandbox, token));
    const imageMatched = imageHint ? sandbox.imageHints.has(imageHint) : false;
    if (requestedCovered.length === 0 && !imageMatched) continue;
    candidates.push({
      sandbox,
      score: requestedCovered.length * 10 + optionalCovered.length + (imageMatched ? 1000 : 0),
      optionalCovered: optionalCovered.length,
    });
  }

  if (candidates.length === 0) return null;
  candidates.sort((left, right) => {
    if (right.score !== left.score) return right.score - left.score;
    if (right.optionalCovered !== left.optionalCovered) return right.optionalCovered - left.optionalCovered;
    return left.sandbox.name.localeCompare(right.sandbox.name);
  });
  return candidates[0].sandbox;
}

function resolveCapabilities(options) {
  const repoRoot = path.resolve(options.repoRoot || process.cwd());
  const manifestRelativePath = options.manifestPath || process.env.CAPABILITY_MANIFEST_PATH || DEFAULT_MANIFEST_NAME;
  const manifestPath = path.resolve(repoRoot, manifestRelativePath);
  const defaultSandboxPath = path.resolve(__dirname, '..', '..', 'config', 'sandbox-classes.json');
  const sandboxInput = options.sandboxClassesPath || defaultSandboxPath;
  const sandboxPath = path.isAbsolute(sandboxInput) ? sandboxInput : path.resolve(process.cwd(), sandboxInput);
  const sandboxClasses = loadSandboxClasses(sandboxPath);

  if (!fs.existsSync(manifestPath)) {
    return stableResolution({
      manifestPresent: false,
      manifestVersion: null,
      route: 'aca-job',
      defaultImageSufficient: true,
    });
  }

  let manifest;
  try {
    manifest = parseCapabilityManifest(fs.readFileSync(manifestPath, 'utf8'));
    validateKnownIdentifiers(manifest);
  } catch (error) {
    const reason = error instanceof ManifestError ? error.message : 'capability manifest validation failed';
    return safeFailure(reason, {
      manifestPresent: true,
      manifestVersion: null,
    });
  }

  const requested = collectRequests(manifest);
  const defaultUnsatisfiedRequired = findUnsatisfied(DEFAULT_WORKER, requested.required);
  const defaultUnsatisfiedOptional = findUnsatisfied(DEFAULT_WORKER, requested.optional);
  const defaultUnsatisfiedAll = Array.from(new Set([...defaultUnsatisfiedRequired, ...defaultUnsatisfiedOptional])).sort();
  const imageHint = manifest.image && manifest.image.hint ? manifest.image.hint : null;

  if (defaultUnsatisfiedAll.length === 0) {
    return stableResolution({
      route: 'aca-job',
      manifestPresent: true,
      manifestVersion: manifest.version,
      requiredCapabilities: requested.required,
      optionalCapabilities: requested.optional,
      defaultImageSufficient: true,
    });
  }

  const imageHintKnown = !imageHint || sandboxClasses.some((entry) => entry.imageHints.has(imageHint)) || DEFAULT_WORKER.imageHints.has(imageHint);
  if (!imageHintKnown) {
    const imageToken = createCapabilityToken('image', imageHint);
    const redactedRequired = redactToken(requested.required, imageToken);
    const redactedOptional = redactToken(requested.optional, imageToken);
    if (manifest.image && manifest.image.required) {
      return safeFailure('required image hint is not approved', {
        manifestPresent: true,
        manifestVersion: manifest.version,
        requiredCapabilities: redactedRequired,
        optionalCapabilities: redactedOptional,
        unsatisfiedRequired: ['image:[redacted]'],
      });
    }
    return stableResolution({
      route: 'aca-job',
      manifestPresent: true,
      manifestVersion: manifest.version,
      requiredCapabilities: redactedRequired,
      optionalCapabilities: redactedOptional,
      defaultImageSufficient: false,
      fallbackReason: 'optional image hint is not approved; using aca-job',
    });
  }

  const sandbox = chooseSandboxClass(sandboxClasses, requested.required, requested.optional, imageHint, defaultUnsatisfiedAll);
  if (sandbox) {
    return stableResolution({
      route: 'sandbox',
      sandboxClass: sandbox.name,
      manifestPresent: true,
      manifestVersion: manifest.version,
      requiredCapabilities: requested.required,
      optionalCapabilities: requested.optional,
      defaultImageSufficient: false,
    });
  }

  const unsatisfiedRequired = requested.required.filter((token) => {
    if (!defaultUnsatisfiedRequired.includes(token)) return false;
    return !sandboxClasses.some((entry) => sandboxCanSatisfy(entry, token));
  }).sort();

  if (unsatisfiedRequired.length > 0) {
    return safeFailure('required capabilities are not available in the default worker image or approved sandbox classes', {
      manifestPresent: true,
      manifestVersion: manifest.version,
      requiredCapabilities: requested.required,
      optionalCapabilities: requested.optional,
      unsatisfiedRequired,
    });
  }

  return stableResolution({
    route: 'aca-job',
    manifestPresent: true,
    manifestVersion: manifest.version,
    requiredCapabilities: requested.required,
    optionalCapabilities: requested.optional,
    defaultImageSufficient: false,
    fallbackReason: 'optional capabilities are unavailable in approved sandbox classes; using aca-job',
  });
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if ((item === '--repo-root' || item === '--cwd') && index + 1 < argv.length) {
      options.repoRoot = argv[index + 1];
      index += 1;
      continue;
    }
    if (item === '--manifest' && index + 1 < argv.length) {
      options.manifestPath = argv[index + 1];
      index += 1;
      continue;
    }
    if (item === '--sandbox-classes' && index + 1 < argv.length) {
      options.sandboxClassesPath = argv[index + 1];
      index += 1;
    }
  }
  return options;
}

if (require.main === module) {
  const result = resolveCapabilities(parseArgs(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

module.exports = {
  DEFAULT_MANIFEST_NAME,
  DEFAULT_WORKER,
  KNOWN_CAPABILITIES,
  RESOLUTION_SCHEMA_VERSION,
  resolveCapabilities,
};
