#!/usr/bin/env node
const fs = require('fs');

const ARM_API_VERSION = '2026-01-01';
const SQUAD_PROMPT_UTF8_BYTE_CAP = 100000;
const LITERAL_ONLY_SESSION_ENV_KEYS = new Set([
  'GITHUB_REPOSITORY',
  'GITHUB_REF',
  'SQUAD_MODE',
  'SESSION_NAME',
  'SQUAD_DEPLOYMENT_MODE',
  'SQUAD_POD_ID',
  'OTEL_SERVICE_NAME',
  'ENABLE_GITHUB_REMOTE',
  'SQUAD_PROMPT',
  'SQUAD_TEAM',
  'RUN_COPILOT_SMOKE',
  'PUSH_CHANGES',
  'OUTPUT_BRANCH',
  'PR_TITLE',
  'PR_BODY',
  'COMMIT_MESSAGE',
  'RALPH_LABELS',
  'RALPH_MAX_ISSUES',
  'SQUAD_DISPATCH_ROUTE',
  'SQUAD_DISPATCH_SOURCE',
  'SQUAD_LEASE_KEY'
]);

function utf8Bytes(value) {
  return Buffer.byteLength(String(value ?? ''), 'utf8');
}

function assertPromptCap(prompt, context = 'SQUAD_PROMPT') {
  const bytes = utf8Bytes(prompt);
  if (bytes > SQUAD_PROMPT_UTF8_BYTE_CAP) {
    throw new Error(`${context} exceeds the ${SQUAD_PROMPT_UTF8_BYTE_CAP} UTF-8 bytes cap (actual: ${bytes} bytes).`);
  }
  return bytes;
}

function parseEnvTokens(path) {
  const raw = fs.readFileSync(path, 'utf8');
  return raw.split('\u0000').filter(Boolean).map((token) => {
    const index = token.indexOf('=');
    const name = index >= 0 ? token.slice(0, index) : token;
    const value = index >= 0 ? token.slice(index + 1) : '';
    if (!LITERAL_ONLY_SESSION_ENV_KEYS.has(name) && value.startsWith('secretref:')) {
      return { name, secretRef: value.slice('secretref:'.length) };
    }
    return { name, value };
  });
}

function buildStartBody(jobDefinition, envTokens) {
  const properties = jobDefinition && typeof jobDefinition === 'object' ? (jobDefinition.properties || {}) : {};
  const template = properties.template || {};
  const manualTriggerConfig = properties.configuration && properties.configuration.manualTriggerConfig
    ? properties.configuration.manualTriggerConfig
    : undefined;
  const containers = Array.isArray(template.containers) ? template.containers.slice() : [];
  if (containers.length === 0) {
    throw new Error('Job definition has no template container to start.');
  }
  const first = { ...containers[0] };
  first.env = envTokens;
  containers[0] = first;
  const body = { containers };
  if (Array.isArray(template.initContainers) && template.initContainers.length > 0) {
    body.initContainers = template.initContainers;
  }
  if (manualTriggerConfig) {
    body.manualTriggerConfig = manualTriggerConfig;
  }
  return body;
}

function main(argv) {
  const command = argv[2] || '';
  if (command === 'prompt-bytes') {
    process.stdout.write(String(utf8Bytes(process.env.SQUAD_PROMPT_INPUT || '')));
    return;
  }
  if (command === 'assert-prompt-cap') {
    const context = argv[3] || 'SQUAD_PROMPT';
    process.stdout.write(String(assertPromptCap(process.env.SQUAD_PROMPT_INPUT || '', context)));
    return;
  }
  if (command === 'build-start-body') {
    const jobDefinitionPath = argv[3];
    const envTokensPath = argv[4];
    if (!jobDefinitionPath || !envTokensPath) {
      throw new Error('Usage: aca-job-rest.js build-start-body <job-definition.json> <env-tokens.bin>');
    }
    const jobDefinition = JSON.parse(fs.readFileSync(jobDefinitionPath, 'utf8'));
    const envTokens = parseEnvTokens(envTokensPath);
    process.stdout.write(JSON.stringify(buildStartBody(jobDefinition, envTokens)));
    return;
  }
  throw new Error('Usage: aca-job-rest.js <prompt-bytes|assert-prompt-cap|build-start-body>');
}

if (require.main === module) {
  try {
    main(process.argv);
  } catch (error) {
    process.stderr.write(String(error && error.message ? error.message : error) + '\n');
    process.exit(1);
  }
}

module.exports = {
  ARM_API_VERSION,
  SQUAD_PROMPT_UTF8_BYTE_CAP,
  utf8Bytes,
  assertPromptCap,
  parseEnvTokens,
  buildStartBody,
};
