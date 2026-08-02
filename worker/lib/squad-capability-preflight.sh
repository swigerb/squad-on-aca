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
#     egress, short-lived credentials, per-task Sandboxes selection).
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
#   69  the shared manifest-path locator (locate-manifest.js) is missing or
#       misbehaving, so this gate cannot decide whether the path is safe
#       (EX_UNAVAILABLE). The session is refused; it is never downgraded to
#       "no manifest present".
#   78  one or more required capabilities are missing (EX_CONFIG)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="${SCRIPT_DIR}/parse-capabilities.js"
SUPPORTED_TOOLS='az bash cargo curl docker dotnet gh git go java javac jq kubectl make mvn node npm pip pip3 pnpm python python3 rustc sh terraform yarn'
SUPPORTED_CREDENTIALS='ACA_SESSION_JOB_NAME ACR_PASSWORD ACR_USERNAME AZURE_CLIENT_ID AZURE_RESOURCE_GROUP AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID COPILOT_GITHUB_TOKEN DOCKER_PASSWORD DOCKER_USERNAME GH_TOKEN GITHUB_TOKEN NODE_AUTH_TOKEN NPM_TOKEN'

log() {
  printf '[capability-preflight] %s\n' "$*"
}

fail() {
  log "$@"
  exit 78
}

# Cleanup handler set once a secure work dir exists. Removes the temp dir
# unconditionally on any exit path (normal, error, or signal).
WORK_DIR=""
cleanup_workdir() {
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup_workdir EXIT INT TERM

# Creates an unpredictable, private (0700) work directory OUTSIDE the
# repository working tree. Never falls back to a predictable path: if a
# securely created directory cannot be verified, the caller fails hard.
create_secure_workdir() {
  local base created perms
  base="${TMPDIR:-/tmp}"
  base="${base%/}"

  [[ -d "$base" ]] || return 1

  # umask 077 + mktemp -d => a fresh dir readable/writable only by us.
  created="$(umask 077; mktemp -d "${base}/squad-capability-preflight.XXXXXXXXXXXX" 2>/dev/null)" || return 1
  [[ -n "$created" ]] || return 1

  # Any verification failure past this point must remove the just-created dir so
  # we never leave a partially-trusted temp path behind.
  _reject_workdir() {
    [[ -n "${created:-}" && -d "$created" ]] && rm -rf "$created"
    return 1
  }

  # Must be a real directory, not a symlink, owned by us.
  [[ -d "$created" && ! -L "$created" ]] || { _reject_workdir; return 1; }
  [[ -O "$created" ]] || { _reject_workdir; return 1; }

  # Must be exactly 0700.
  perms="$(stat -c '%a' "$created" 2>/dev/null || stat -f '%Lp' "$created" 2>/dev/null || echo '')"
  [[ "$perms" == "700" ]] || { _reject_workdir; return 1; }

  # Must live OUTSIDE the repository working tree, even after resolving
  # symlinks, so nothing inside the repo can be an attacker-writable target.
  local real_work real_repo
  real_work="$(cd "$created" 2>/dev/null && pwd -P)" || { _reject_workdir; return 1; }
  real_repo="$(cd "$REPO_DIR" 2>/dev/null && pwd -P)" || { _reject_workdir; return 1; }
  case "$real_work/" in
    "$real_repo"/*) { _reject_workdir; return 1; } ;;
  esac

  WORK_DIR="$created"
  return 0
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

# --- Manifest path resolution -------------------------------------------------
# This script does NOT decide whether a manifest path is safe. That decision is
# made in exactly one place -- worker/lib/locate-manifest.js -- shared with the
# routing resolver, so a rule can never apply to routing but not to the gate
# that actually runs inside the session (or the reverse). See
# docs/adr/0003-capability-manifest-future-work.md, finding 2.
#
# CLI contract: exit 0 = present (the resolved path is on stdout), 3 = absent,
# 4 = unsafe. EVERY other exit code is unclaimed and MUST refuse the session.
#
# That is why the verdicts are distinct exit codes and not "non-zero means
# unsafe" plus a stdout sentinel, which is what this script used to do. Under
# the old scheme a locator that could not load (node exits 1) was
# indistinguishable from a bad path, and a locator that exited 0 printing
# nothing would have read as "no manifest present" -- a fail-OPEN on a
# path-traversal boundary, which is strictly worse than the duplication this
# unification removed.
MANIFEST_LOCATOR="${SCRIPT_DIR}/locate-manifest.js"

if [[ ! -f "$MANIFEST_LOCATOR" ]]; then
  log "Manifest path locator is missing: ${MANIFEST_LOCATOR}"
  log "This worker image is incomplete, so the session cannot decide whether the capability manifest path is safe to read."
  log "Refusing the session rather than assuming no manifest is present."
  log "Rebuild and redeploy the worker image: worker/lib/locate-manifest.js must be shipped into /usr/local/lib/squad-on-aca/."
  exit 69
fi

if manifest_resolution="$(node "$MANIFEST_LOCATOR" "$REPO_DIR" "$MANIFEST_RELATIVE_PATH")"; then
  locator_rc=0
else
  locator_rc=$?
fi

case "$locator_rc" in
  0)
    if [[ -z "$manifest_resolution" ]]; then
      log "Manifest path locator reported a manifest but named no path."
      log "Refusing the session rather than guessing where ${MANIFEST_RELATIVE_PATH} landed."
      log "Rebuild and redeploy the worker image: ${MANIFEST_LOCATOR} is not honouring the contract this gate depends on."
      exit 69
    fi
    MANIFEST_PATH="$manifest_resolution"
    ;;
  3)
    log "No capability manifest at ${MANIFEST_RELATIVE_PATH}; skipping (safe default)."
    exit 0
    ;;
  4)
    log "Capability manifest path is invalid or unsafe; refusing to read it."
    log "Check CAPABILITY_MANIFEST_PATH and ensure it points to a regular file inside the repository."
    exit 78
    ;;
  *)
    log "Manifest path locator failed with exit ${locator_rc}, which is not a verdict it is allowed to return."
    log "Refusing the session rather than guessing whether ${MANIFEST_RELATIVE_PATH} is safe to read."
    log "Rebuild and redeploy the worker image: ${MANIFEST_LOCATOR} must be present and runnable by the image's node."
    exit 69
    ;;
esac

if ! create_secure_workdir; then
  fail "Could not create a secure private work directory; refusing to run with a predictable temp path."
fi

MANIFEST_JSON="${WORK_DIR}/manifest.json"
PARSER_STDERR="${WORK_DIR}/parser.stderr"
ROWS_FILE="${WORK_DIR}/rows.tsv"
FAILURES_FILE="${WORK_DIR}/failures.log"
ADVISORIES_FILE="${WORK_DIR}/advisories.log"

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
      # Required external services are rejected upstream by the parser/validator
      # (see parse-capabilities.js): the worker cannot validate external service
      # reachability without expanding network egress, so a manifest declaring a
      # service `required: true` fails during parsing above and never reaches this
      # loop. Anything that gets here is advisory-only by construction.
      echo "Declared external service (advisory only, not validated): ${name}" >>"$ADVISORIES_FILE"
      ;;
    egress)
      # PLANE-AWARE, because the old single message ("advisory only, not
      # enforced yet") is now WRONG inside a sandbox. On the ACA Sandboxes plane
      # New-SandboxEgressPolicy generates a default-deny policy from the
      # approved class template narrowed by this manifest and applies it before
      # this script runs; on the ACA Jobs plane there is no per-execution
      # network control at all, so a declared destination is reachable whether
      # or not it was declared. SQUAD_EXECUTION_MODE is set to "sandbox" by the
      # Sandboxes provider and is the same signal agent-policy.js uses to tell
      # the two planes apart. Unset means the Jobs plane, which is the
      # fail-honest default: it never claims a control that is absent.
      #
      # Neither branch echoes ${name}: the host is repository-controlled text
      # and this output is the session log.
      if [[ "${SQUAD_EXECUTION_MODE:-}" == "sandbox" ]]; then
        echo "Declared egress dependency (ENFORCED on this plane: the sandbox's default-deny egress policy was generated from the approved class template and applied before this session started); inspect ${MANIFEST_RELATIVE_PATH} for details." >>"$ADVISORIES_FILE"
      else
        echo "Declared egress dependency (NOT ENFORCED on this plane: ACA Jobs applies no per-execution network policy, so declaring a destination neither opens nor restricts it; route to an approved sandbox class for enforced egress); inspect ${MANIFEST_RELATIVE_PATH} for details." >>"$ADVISORIES_FILE"
      fi
      ;;
    image)
      echo "Manifest declares a custom worker image hint; current worker image is fixed. See docs/capability-manifest.md#future-per-task-images-and-sandboxes and inspect ${MANIFEST_RELATIVE_PATH} for details." >>"$ADVISORIES_FILE"
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
