#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${1:-${PWD}}"
RESOLVER="$SCRIPT_DIR/resolve-capabilities.js"
SANDBOX_CLASSES_PATH="${SANDBOX_CLASSES_PATH:-$REPO_ROOT/config/sandbox-classes.json}"

resolution="$(node "$RESOLVER" --cwd "$REPO_ROOT" --sandbox-classes "$SANDBOX_CLASSES_PATH")"
printf '%s\n' "$resolution"

route="$(printf '%s' "$resolution" | node -e 'let data="";process.stdin.on("data",c=>data+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(data).route));')"
fallback="$(printf '%s' "$resolution" | node -e 'let data="";process.stdin.on("data",c=>data+=c);process.stdin.on("end",()=>{const value=JSON.parse(data).fallbackReason;process.stdout.write(value?String(value):"");});')"
sandbox_class="$(printf '%s' "$resolution" | node -e 'let data="";process.stdin.on("data",c=>data+=c);process.stdin.on("end",()=>{const value=JSON.parse(data).sandboxClass;process.stdout.write(value?String(value):"");});')"

case "$route" in
  aca-job)
    if [[ -n "$fallback" ]]; then
      printf '[squad-on-aca] capability preflight resolved to aca-job (%s)\n' "$fallback" >&2
    else
      printf '[squad-on-aca] capability preflight resolved to aca-job\n' >&2
    fi
    ;;
  sandbox)
    printf '[squad-on-aca] capability preflight resolved to sandbox class %s (recorded only; sandbox execution is not enabled in sprints 0-2)\n' "$sandbox_class" >&2
    ;;
  fail-closed)
    printf '[squad-on-aca] capability preflight failed closed (%s)\n' "${fallback:-redacted diagnostic}" >&2
    exit 78
    ;;
  *)
    printf '[squad-on-aca] capability preflight returned an unknown route\n' >&2
    exit 78
    ;;
 esac
