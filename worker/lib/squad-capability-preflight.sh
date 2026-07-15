#!/usr/bin/env bash
# squad-capability-preflight.sh
#
# Validates that the checked-out repository's declared capability manifest
# is satisfiable by the current worker image *before* Squad/Copilot starts
# doing work. This turns "the agent got halfway through a task and hit a
# missing binary" into a fast, actionable failure at session start.
#
# Design notes:
#   - Backward compatible by default: if no manifest is present, this is a
#     no-op (exit 0). Existing repos and sessions are unaffected.
#   - Only capabilities explicitly marked `required: true` can block a
#     session. Everything else is advisory (printed, never blocking) so a
#     manifest can document "nice to have" tooling/services without
#     breaking sessions that don't need it.
#   - This script does not grant any additional permissions, install any
#     tools, or open any egress. It only *checks* what's already present
#     and reports actionable gaps. See docs/capability-manifest.md for the
#     documented extension points (custom worker images, controlled
#     egress, short-lived credentials, SandboxGroup-per-task selection).
#   - Manifest content is never executed as shell. Tool and credential names
#     map to fixed, built-in checks implemented below.
#
# Usage:
#   squad-capability-preflight.sh <repo-dir>
#
# Environment:
#   CAPABILITY_MANIFEST_PATH   path to manifest, relative to <repo-dir>
#                              (default: squad-capabilities.yml)
#   SKIP_CAPABILITY_PREFLIGHT  "true" to bypass validation entirely
#
# Exit codes:
#   0   validation passed (or was skipped / no manifest present)
#   64  usage error
#   78  one or more required capabilities are missing (EX_CONFIG)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="${SCRIPT_DIR}/parse-capabilities.js"
SUPPORTED_TOOLS='az bash cargo curl docker dotnet gh git go java javac jq kubectl make mvn node npm pip pip3 pnpm python python3 rustc sh terraform yarn'
SUPPORTED_CREDENTIALS='ACA_SESSION_JOB_NAME ACR_PASSWORD ACR_USERNAME AZURE_CLIENT_ID AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID COPILOT_GITHUB_TOKEN DOCKER_PASSWORD DOCKER_USERNAME GH_TOKEN GITHUB_TOKEN NODE_AUTH_TOKEN NPM_TOKEN'

log() {
  printf '[capability-preflight] %s\n' "$*"
}

check_tool() {
  local tool_name="$1"
  case "$tool_name" in
    az) command -v az >/dev/null 2>&1 ;;
    bash) command -v bash >/dev/null 2>&1 ;;
    cargo) command -v cargo >/dev/null 2>&1 ;;
    curl) command -v curl >/dev/null 2>&1 ;;
    docker) command -v docker >/dev/null 2>&1 ;;
    dotnet) command -v dotnet >/dev/null 2>&1 ;;
    gh) command -v gh >/dev/null 2>&1 ;;
    git) command -v git >/dev/null 2>&1 ;;
    go) command -v go >/dev/null 2>&1 ;;
    java) command -v java >/dev/null 2>&1 ;;
    javac) command -v javac >/dev/null 2>&1 ;;
    jq) command -v jq >/dev/null 2>&1 ;;
    kubectl) command -v kubectl >/dev/null 2>&1 ;;
    make) command -v make >/dev/null 2>&1 ;;
    mvn) command -v mvn >/dev/null 2>&1 ;;
    node) command -v node >/dev/null 2>&1 ;;
    npm) command -v npm >/dev/null 2>&1 ;;
    pip) command -v pip >/dev/null 2>&1 ;;
    pip3) command -v pip3 >/dev/null 2>&1 ;;
    pnpm) command -v pnpm >/dev/null 2>&1 ;;
    python) command -v python >/dev/null 2>&1 ;;
    python3) command -v python3 >/dev/null 2>&1 ;;
    rustc) command -v rustc >/dev/null 2>&1 ;;
    sh) command -v sh >/dev/null 2>&1 ;;
    terraform) command -v terraform >/dev/null 2>&1 ;;
    yarn) command -v yarn >/dev/null 2>&1 ;;
    *) return 2 ;;
  esac
}

credential_is_set() {
  local credential_name="$1"
  case "$credential_name" in
    ACA_SESSION_JOB_NAME) [[ -n "${ACA_SESSION_JOB_NAME:-}" ]] ;;
    ACR_PASSWORD) [[ -n "${ACR_PASSWORD:-}" ]] ;;
    ACR_USERNAME) [[ -n "${ACR_USERNAME:-}" ]] ;;
    AZURE_CLIENT_ID) [[ -n "${AZURE_CLIENT_ID:-}" ]] ;;
    AZURE_RESOURCE_GROUP) [[ -n "${AZURE_RESOURCE_GROUP:-}" ]] ;;
    AZURE_SUBSCRIPTION_ID) [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]] ;;
    AZURE_TENANT_ID) [[ -n "${AZURE_TENANT_ID:-}" ]] ;;
    COPILOT_GITHUB_TOKEN) [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]] ;;
    DOCKER_PASSWORD) [[ -n "${DOCKER_PASSWORD:-}" ]] ;;
    DOCKER_USERNAME) [[ -n "${DOCKER_USERNAME:-}" ]] ;;
    GH_TOKEN) [[ -n "${GH_TOKEN:-}" ]] ;;
    GITHUB_TOKEN) [[ -n "${GITHUB_TOKEN:-}" ]] ;;
    NODE_AUTH_TOKEN) [[ -n "${NODE_AUTH_TOKEN:-}" ]] ;;
    NPM_TOKEN) [[ -n "${NPM_TOKEN:-}" ]] ;;
    *) return 2 ;;
  esac
}

if [[ "${SKIP_CAPABILITY_PREFLIGHT:-false}" == "true" ]]; then
  log "SKIP_CAPABILITY_PREFLIGHT=true; skipping capability validation."
  exit 0
fi

if [[ $# -lt 1 ]]; then
  log "Usage: squad-capability-preflight.sh <repo-dir>"
  exit 64
fi

REPO_DIR="$1"
MANIFEST_RELATIVE_PATH="${CAPABILITY_MANIFEST_PATH:-squad-capabilities.yml}"

if [[ ! -d "$REPO_DIR" ]]; then
  log "Repository directory does not exist: ${REPO_DIR}"
  exit 64
fi

WORK_DIR="${REPO_DIR}/.squad-capability-preflight-$$"
MANIFEST_JSON="${WORK_DIR}/manifest.json"
PARSER_STDERR="${WORK_DIR}/parser.stderr"
ROWS_FILE="${WORK_DIR}/rows.tsv"
FAILURES_FILE="${WORK_DIR}/failures.log"
ADVISORIES_FILE="${WORK_DIR}/advisories.log"

if ! manifest_resolution="$(
  node - "$REPO_DIR" "$MANIFEST_RELATIVE_PATH" <<'NODE'
const fs = require('fs');
const path = require('path');

const repoDir = process.argv[2];
const manifestRelativePath = process.argv[3];

function realpath(value) {
  return typeof fs.realpathSync.native === 'function' ? fs.realpathSync.native(value) : fs.realpathSync(value);
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

if (!manifestRelativePath || path.isAbsolute(manifestRelativePath) || /[\u0000-\u001f\u007f]/.test(manifestRelativePath)) {
  process.exit(2);
}

const repoRoot = realpath(repoDir);
if (!fs.statSync(repoRoot).isDirectory()) {
  process.exit(3);
}

const candidatePath = path.resolve(repoRoot, manifestRelativePath);
if (!isWithin(repoRoot, candidatePath)) {
  process.exit(2);
}

if (!fs.existsSync(candidatePath)) {
  process.stdout.write('__ABSENT__\n');
  process.exit(0);
}

const candidateLstat = fs.lstatSync(candidatePath);
if (candidateLstat.isSymbolicLink()) {
  process.exit(2);
}

const resolvedPath = realpath(candidatePath);
if (!isWithin(repoRoot, resolvedPath)) {
  process.exit(2);
}

if (!fs.statSync(resolvedPath).isFile()) {
  process.exit(2);
}

process.stdout.write(`${resolvedPath}\n`);
NODE
)"; then
  log "Capability manifest path is invalid or unsafe; refusing to read it."
  log "Check CAPABILITY_MANIFEST_PATH and ensure it points to a regular file inside the repository."
  exit 78
fi

if [[ "$manifest_resolution" == "__ABSENT__" ]]; then
  log "No capability manifest at ${MANIFEST_RELATIVE_PATH}; skipping (safe default)."
  exit 0
fi

MANIFEST_PATH="$manifest_resolution"

mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

log "Found capability manifest at ${MANIFEST_RELATIVE_PATH}; validating..."

if ! node "$PARSER" "$MANIFEST_PATH" >"$MANIFEST_JSON" 2>"$PARSER_STDERR"; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && log "$line"
  done <"$PARSER_STDERR"
  log "Capability manifest is malformed. Fix ${MANIFEST_RELATIVE_PATH} and retry."
  log "See docs/capability-manifest.md for the manifest schema."
  exit 78
fi

node - "$MANIFEST_JSON" >"$ROWS_FILE" <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const rows = [];
for (const tool of manifest.tools || []) {
  rows.push(['tool', tool.name, tool.required ? '1' : '0'].join('\t'));
}
for (const credential of manifest.credentials || []) {
  rows.push(['credential', credential.name, credential.required ? '1' : '0'].join('\t'));
}
for (const service of manifest.services || []) {
  rows.push(['service', service.name, service.required ? '1' : '0'].join('\t'));
}
for (const egress of manifest.egress || []) {
  rows.push(['egress', egress.host, '0'].join('\t'));
}
if (manifest.image && manifest.image.hint) {
  rows.push(['image', manifest.image.hint, '0'].join('\t'));
}
process.stdout.write(rows.join('\n'));
if (rows.length > 0) process.stdout.write('\n');
NODE

FAILED=0
while IFS=$'\t' read -r kind name required; do
  [[ -z "$kind" ]] && continue
  case "$kind" in
    tool)
      set +e
      check_tool "$name"
      tool_rc=$?
      set -e
      if [[ "$tool_rc" -eq 0 ]]; then
        continue
      fi
      if [[ "$required" == "1" ]]; then
        {
          if [[ "$tool_rc" -eq 2 ]]; then
            echo "Unsupported required tool: ${name}"
            echo "  fix: use a built-in tool name (${SUPPORTED_TOOLS}) or extend the worker image; see docs/capability-manifest.md#extending-the-worker-image."
          else
            echo "Missing required tool: ${name}"
            echo "  fix: bake ${name} into a custom worker image (see docs/capability-manifest.md#extending-the-worker-image) or remove/relax this requirement."
          fi
          echo "  details: inspect ${MANIFEST_RELATIVE_PATH} for the manifest entry."
        } >>"$FAILURES_FILE"
        FAILED=1
      else
        if [[ "$tool_rc" -eq 2 ]]; then
          echo "Unsupported optional tool: ${name}" >>"$ADVISORIES_FILE"
        else
          echo "Optional tool not present: ${name}" >>"$ADVISORIES_FILE"
        fi
      fi
      ;;
    credential)
      set +e
      credential_is_set "$name"
      credential_rc=$?
      set -e
      if [[ "$credential_rc" -eq 0 ]]; then
        continue
      fi
      if [[ "$required" == "1" ]]; then
        {
          if [[ "$credential_rc" -eq 2 ]]; then
            echo "Unsupported required credential: ${name}"
            echo "  fix: use a built-in credential name (${SUPPORTED_CREDENTIALS}); see docs/capability-manifest.md#preflight-validation."
          else
            echo "Missing required credential: ${name}"
            echo "  fix: provide ${name} as an ACA secret/env var for this session (see docs/capability-manifest.md#credentials)."
          fi
          echo "  details: inspect ${MANIFEST_RELATIVE_PATH} for the manifest entry."
        } >>"$FAILURES_FILE"
        FAILED=1
      else
        if [[ "$credential_rc" -eq 2 ]]; then
          echo "Unsupported optional credential: ${name}" >>"$ADVISORIES_FILE"
        else
          echo "Optional credential not set: ${name}" >>"$ADVISORIES_FILE"
        fi
      fi
      ;;
    service)
      if [[ "$required" == "1" ]]; then
        {
          echo "Required external service declared but cannot be auto-validated: ${name}"
          echo "  details: inspect ${MANIFEST_RELATIVE_PATH} for the manifest entry."
          echo "  fix: confirm ${name} is reachable from this session, or mark it required: false if it is optional."
        } >>"$FAILURES_FILE"
        FAILED=1
      else
        echo "Declared optional service (not validated): ${name}" >>"$ADVISORIES_FILE"
      fi
      ;;
    egress)
      echo "Declared egress dependency (advisory only, not enforced yet); inspect ${MANIFEST_RELATIVE_PATH} for details." >>"$ADVISORIES_FILE"
      ;;
    image)
      echo "Manifest declares a custom worker image hint; current worker image is fixed. See docs/capability-manifest.md#future-per-task-images-and-sandboxgroups and inspect ${MANIFEST_RELATIVE_PATH} for details." >>"$ADVISORIES_FILE"
      ;;
  esac
done <"$ROWS_FILE"

if [[ -s "$ADVISORIES_FILE" ]]; then
  log "Advisory (non-blocking) capability notes:"
  while IFS= read -r line; do
    log "  ${line}"
  done <"$ADVISORIES_FILE"
fi

if [[ "$FAILED" == "1" ]]; then
  log "Preflight failed: required capabilities are not satisfied."
  while IFS= read -r line; do
    log "  ${line}"
  done <"$FAILURES_FILE"
  log "Set SKIP_CAPABILITY_PREFLIGHT=true to bypass at your own risk, or fix the gaps above."
  exit 78
fi

log "Capability preflight passed."
exit 0
