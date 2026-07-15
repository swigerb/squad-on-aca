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

log() {
  printf '[capability-preflight] %s\n' "$*"
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
MANIFEST_PATH="${REPO_DIR}/${MANIFEST_RELATIVE_PATH}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  log "No capability manifest at ${MANIFEST_RELATIVE_PATH}; skipping (safe default)."
  exit 0
fi

log "Found capability manifest at ${MANIFEST_RELATIVE_PATH}; validating..."

MANIFEST_JSON="$(mktemp)"
trap 'rm -f "$MANIFEST_JSON"' EXIT

if ! node "$PARSER" "$MANIFEST_PATH" > "$MANIFEST_JSON" 2> >(sed 's/^/[capability-preflight] /' >&2); then
  log "Capability manifest is malformed. Fix ${MANIFEST_RELATIVE_PATH} and retry."
  log "See docs/capability-manifest.md for the manifest schema."
  exit 78
fi

# node -e reads the parsed JSON and drives the actual required/advisory
# checks so we get JSON parsing correctness for free and keep bash limited
# to running the declared shell "check" commands, which must run in this
# environment (not inside node's process) to reflect real PATH/tool state.
FAILURES_FILE="$(mktemp)"
ADVISORIES_FILE="$(mktemp)"
trap 'rm -f "$MANIFEST_JSON" "$FAILURES_FILE" "$ADVISORIES_FILE"' EXIT

node -e '
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const tools = manifest.tools || [];
const credentials = manifest.credentials || [];
const services = manifest.services || [];
const egress = manifest.egress || [];

const lines = [];
for (const t of tools) {
  lines.push(["tool", t.name, t.required ? "1" : "0", t.check || "", t.reason || ""].join("\t"));
}
for (const c of credentials) {
  lines.push(["credential", c.name, c.required ? "1" : "0", "", c.reason || ""].join("\t"));
}
for (const s of services) {
  lines.push(["service", s.name, s.required ? "1" : "0", "", s.reason || ""].join("\t"));
}
for (const e of egress) {
  lines.push(["egress", e.host, "0", "", e.reason || ""].join("\t"));
}
if (manifest.image && manifest.image.hint) {
  lines.push(["image", manifest.image.hint, "0", "", manifest.image.reason || ""].join("\t"));
}
process.stdout.write(lines.join("\n") + (lines.length ? "\n" : ""));
' "$MANIFEST_JSON" > "${MANIFEST_JSON}.rows"

FAILED=0
while IFS=$'\t' read -r kind name required check reason; do
  [[ -z "$kind" ]] && continue
  case "$kind" in
    tool)
      if [[ -n "$check" ]] && bash -c "$check" >/dev/null 2>&1; then
        continue
      fi
      if [[ "$required" == "1" ]]; then
        {
          echo "Missing required tool: ${name}"
          [[ -n "$check" ]] && echo "  check failed: ${check}"
          [[ -n "$reason" ]] && echo "  reason: ${reason}"
          echo "  fix: bake ${name} into a custom worker image (see docs/capability-manifest.md#extending-the-worker-image) or remove/relax this requirement."
        } >> "$FAILURES_FILE"
        FAILED=1
      else
        echo "Optional tool not present: ${name}${reason:+ (${reason})}" >> "$ADVISORIES_FILE"
      fi
      ;;
    credential)
      value="${!name:-}"
      if [[ -n "$value" ]]; then
        continue
      fi
      if [[ "$required" == "1" ]]; then
        {
          echo "Missing required credential: ${name}"
          [[ -n "$reason" ]] && echo "  reason: ${reason}"
          echo "  fix: provide ${name} as an ACA secret/env var for this session (see docs/capability-manifest.md#credentials)."
        } >> "$FAILURES_FILE"
        FAILED=1
      else
        echo "Optional credential not set: ${name}${reason:+ (${reason})}" >> "$ADVISORIES_FILE"
      fi
      ;;
    service)
      if [[ "$required" == "1" ]]; then
        {
          echo "Required external service declared but cannot be auto-validated: ${name}"
          [[ -n "$reason" ]] && echo "  reason: ${reason}"
          echo "  fix: confirm ${name} is reachable from this session, or mark it required: false if it is optional."
        } >> "$FAILURES_FILE"
        FAILED=1
      else
        echo "Declared optional service (not validated): ${name}${reason:+ (${reason})}" >> "$ADVISORIES_FILE"
      fi
      ;;
    egress)
      echo "Declared egress dependency (advisory only, not enforced yet): ${name}${reason:+ (${reason})}" >> "$ADVISORIES_FILE"
      ;;
    image)
      echo "Manifest suggests worker image '${name}'${reason:+ (${reason})}; current worker image is fixed. See docs/capability-manifest.md#future-per-task-images." >> "$ADVISORIES_FILE"
      ;;
  esac
done < "${MANIFEST_JSON}.rows"
rm -f "${MANIFEST_JSON}.rows"

if [[ -s "$ADVISORIES_FILE" ]]; then
  log "Advisory (non-blocking) capability notes:"
  while IFS= read -r line; do log "  ${line}"; done < "$ADVISORIES_FILE"
fi

if [[ "$FAILED" == "1" ]]; then
  log "Preflight failed: required capabilities are not satisfied."
  while IFS= read -r line; do log "  ${line}"; done < "$FAILURES_FILE"
  log "Set SKIP_CAPABILITY_PREFLIGHT=true to bypass at your own risk, or fix the gaps above."
  exit 78
fi

log "Capability preflight passed."
exit 0
