#!/usr/bin/env bash
# The Azure identity must not survive into a session that runs an agent.
#
# Container Apps hands a container its managed identity as IDENTITY_ENDPOINT +
# IDENTITY_HEADER. Those two values ARE the credential: one HTTP call exchanges
# them for an ARM token, and `curl` can make that call, so denying `az` denies a
# command rather than the capability. The process running here is an agent
# executing attacker-influenceable text, so every mode that does not call Azure
# must not be holding them.
#
# This drives the real function out of the real entrypoint rather than
# reimplementing it, and asserts by side effect: what is left in the environment
# after it runs.

set -uo pipefail

# Issue #92 sprint 3: announce before any check runs (raw write(), not
# buffered stdio), so an interrupted/cancelled job names the test it stopped
# in rather than showing nothing.
echo "== identity drop (issue #83) =="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$SCRIPT_DIR/../entrypoint.sh"

pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    printf '  ok   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$name"; fail=$((fail + 1))
  fi
}

# Extract the function from the entrypoint instead of copying it, so this test
# fails when the real thing changes rather than agreeing with a stale copy.
extract_fn() {
  awk '/^squad_drop_azure_identity\(\) \{/,/^\}/' "$ENTRYPOINT"
}

if [[ -z "$(extract_fn)" ]]; then
  echo "  FAIL squad_drop_azure_identity() is not in entrypoint.sh -- it was renamed or removed"
  exit 1
fi

# Run the function in a subshell holding a full ACA-style identity environment,
# and report what is left.
remaining_after_drop() {
  local mode="$1"
  bash -c "
    log() { :; }
    SQUAD_MODE='$mode'
    IDENTITY_ENDPOINT='http://localhost:42356/msi/token'
    IDENTITY_HEADER='super-secret-header-value'
    MSI_ENDPOINT='http://localhost:42356/msi/token'
    MSI_SECRET='another-secret'
    IMDS_ENDPOINT='http://169.254.169.254'
    AZURE_CLIENT_ID='11111111-2222-3333-4444-555555555555'
    AZURE_RESOURCE_GROUP='rg-keep-me'
    GH_TOKEN='gh-keep-me'
    $(extract_fn)
    squad_drop_azure_identity
    for v in IDENTITY_ENDPOINT IDENTITY_HEADER MSI_ENDPOINT MSI_SECRET IMDS_ENDPOINT AZURE_CLIENT_ID; do
      if [[ -n \"\${!v:-}\" ]]; then echo \"\$v\"; fi
    done
  "
}

# --- the credential is gone -------------------------------------------------

left="$(remaining_after_drop prompt)"
check "no identity variable survives the drop (left: '${left:-none}')" test -z "$left"

# Each one individually, so a partial unset names the survivor rather than
# hiding inside a pass.
for var in IDENTITY_ENDPOINT IDENTITY_HEADER MSI_ENDPOINT MSI_SECRET IMDS_ENDPOINT AZURE_CLIENT_ID; do
  check "$var is unset" bash -c "! grep -qx '$var' <<< \"\$(cat)\"" <<< "$left"
done

# --- what must NOT be collateral damage -------------------------------------

survivors="$(bash -c "
  log() { :; }
  SQUAD_MODE=prompt
  IDENTITY_ENDPOINT=x IDENTITY_HEADER=y
  AZURE_RESOURCE_GROUP='rg-keep-me'
  GH_TOKEN='gh-keep-me'
  GITHUB_REPOSITORY='owner/repo'
  $(extract_fn)
  squad_drop_azure_identity
  echo \"\${AZURE_RESOURCE_GROUP:-}|\${GH_TOKEN:-}|\${GITHUB_REPOSITORY:-}\"
")"
check "the session keeps what it legitimately needs (got '$survivors')" \
  test "$survivors" = "rg-keep-me|gh-keep-me|owner/repo"

# --- it is safe to call when there is no identity at all --------------------

check "a container with no identity is not an error" bash -c "
  log() { :; }
  SQUAD_MODE=prompt
  $(extract_fn)
  squad_drop_azure_identity
"

# --- Ralph, the one mode that must KEEP the identity ------------------------

# Ralph is exempted by the dispatch above the case statement, not by the
# function, so this asserts the dispatch: the entrypoint must not call the drop
# for ralph.
check "ralph is exempted from the drop" bash -c "
  awk '/^case \"\\\$\{SQUAD_MODE:-smoke\}\" in\$/,/^esac\$/' '$ENTRYPOINT' \
    | head -20 | grep -q 'ralph)'
"

check "every other mode is dropped by a wildcard, so a NEW mode is safe by default" bash -c "
  awk '/^case \"\\\$\{SQUAD_MODE:-smoke\}\" in\$/,/^esac\$/' '$ENTRYPOINT' \
    | head -20 | grep -q '\*)'
"

# --- the ordering that makes it a boundary ----------------------------------

# The drop has to happen BEFORE any agent runs, or it protects nothing.
drop_line="$(grep -n 'squad_drop_azure_identity$' "$ENTRYPOINT" | tail -1 | cut -d: -f1)"
first_agent_line="$(grep -n 'copilot -p\|squad loop\|squad_hub_run' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
check "the identity is dropped before the first agent invocation (drop @${drop_line}, agent @${first_agent_line})" \
  test "$drop_line" -lt "$first_agent_line"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
