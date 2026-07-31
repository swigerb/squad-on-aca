#!/usr/bin/env bash
# squad-token-preflight.sh
#
# A fail-fast gate on the GitHub credential, run BEFORE the agent starts.
#
# WHY IT EXISTS. A GitHub App installation token has a hard 1-hour TTL. A Squad
# session clones, runs an agent for 10-60 minutes, and pushes at the very end.
# Every way that credential can be wrong -- wrong value, no push permission,
# already expired, or simply not able to survive the run -- is invisible until
# the push, because a clone of a public repository succeeds with an EXPIRED
# token (exit 0, no warning; measured). Losing a session at minute 2 is far
# better than losing it at minute 55 with the AI credits already spent.
#
# It follows the shape and the opt-out conventions of
# squad-capability-preflight.sh, the established fail-fast gate in this image:
# safe by default (no credential configured -> no-op), one blocking exit code,
# and an explicit escape hatch that is named in the failure message.
#
# WHAT IT CHECKS, in order, stopping at the first failure:
#
#   1. WIRING. git must consult exactly one credential helper for the host --
#      ours -- and no `url.<...>.insteadOf` rewrite may survive. A rewrite
#      embeds a FROZEN token in the remote URL and the helper is never called,
#      which would silently restore the pre-#32 behaviour while every other
#      check still passed. Asserted by asking GIT, not by re-reading the code
#      that wrote the config.
#   2. THE TOKEN FILE. Present, non-empty, and mode 0600.
#   3. USABILITY. The credential is exercised against the real API (`gh api
#      user`), and -- when this session intends to push -- the repository's
#      push permission is read. A failure is classified with the SHARED
#      taxonomy: an `auth` verdict blocks; a transport failure is reported and
#      does NOT block, because a network hiccup says nothing about the token.
#   4. LIFETIME. Remaining lifetime is compared against the estimated run
#      duration plus a margin. If the token cannot survive the run, the session
#      fails now.
#
# Usage:
#   squad-token-preflight.sh
#
# Environment:
#   SQUAD_TOKEN_PREFLIGHT        disabled|disable|off|false|0 to bypass entirely
#   SKIP_TOKEN_PREFLIGHT         "true" to bypass entirely (mirrors
#                                SKIP_CAPABILITY_PREFLIGHT)
#   SQUAD_ESTIMATED_RUN_MINUTES  how long this session is expected to run
#                                (default 60)
#   SQUAD_TOKEN_MARGIN_MINUTES   safety margin on top of the estimate
#                                (default 5)
#   SQUAD_TOKEN_EXPIRES_AT       ISO-8601 expiry supplied by the control plane.
#                                This is the authoritative source: a GitHub App
#                                installation token's `expires_at` is returned
#                                when the token is MINTED and is not carried on
#                                the token itself.
#   SQUAD_TOKEN_PREFLIGHT_PROBE  disabled|off|false|0 to skip the live API probe
#                                (offline environments)
#   SQUAD_CREDENTIALS_LIB        path to squad-credentials.sh
#   SQUAD_GIT_TOKEN_FILE         path to the token file
#   PUSH_CHANGES                 "true" makes push permission a requirement
#   GITHUB_REPOSITORY            owner/name, used for the permission probe
#
# Exit codes:
#   0   the credential can do the job (or the check was skipped / not applicable)
#   64  usage error
#   77  EX_NOPERM -- the credential is unusable, lacks push, or cannot survive
#       the estimated run. THE SESSION MUST NOT START.
#   78  EX_CONFIG -- the credential wiring is wrong (helper missing, a URL
#       rewrite survived, token file mode too wide)

set -Eeuo pipefail

log() {
  printf '[token-preflight] %s\n' "$*"
}

EXIT_CREDENTIAL=77
EXIT_CONFIG=78

case "${SQUAD_TOKEN_PREFLIGHT:-}" in
  disabled|disable|off|false|0)
    log "SQUAD_TOKEN_PREFLIGHT is disabled; skipping credential validation."
    exit 0
    ;;
esac
if [[ "${SKIP_TOKEN_PREFLIGHT:-false}" == "true" ]]; then
  log "SKIP_TOKEN_PREFLIGHT=true; skipping credential validation."
  exit 0
fi

CREDENTIALS_LIB="${SQUAD_CREDENTIALS_LIB:-/usr/local/lib/squad-on-aca/squad-credentials.sh}"
if [[ ! -f "$CREDENTIALS_LIB" ]]; then
  log "Credential library not found at ${CREDENTIALS_LIB}; cannot validate the credential wiring."
  log "  fix: this file ships in the worker image alongside the entrypoint. A worker without it cannot refresh a token mid-session."
  exit "$EXIT_CONFIG"
fi
# shellcheck source=squad-credentials.sh
source "$CREDENTIALS_LIB"

# --- 0. is there a credential at all? --------------------------------------
# A session against a public repository with PUSH_CHANGES=false legitimately has
# no credential. Blocking that would be a regression, so it is a documented
# no-op rather than a failure.
if ! token="$(squad_credential_read_token 2>/dev/null)"; then
  log "No credential is configured (${SQUAD_GIT_TOKEN_FILE} is absent or empty); nothing to validate."
  if [[ "${PUSH_CHANGES:-false}" == "true" ]]; then
    log "This session intends to PUSH but has no credential. The push would fail after the whole agent run."
    log "  fix: supply GH_TOKEN (or GITHUB_TOKEN) to the session, or set PUSH_CHANGES=false."
    exit "$EXIT_CREDENTIAL"
  fi
  exit 0
fi
unset token

# --- 1. wiring --------------------------------------------------------------
mapfile -t configured_helpers < <(squad_credential_configured_helpers)
rewrites="$(squad_credential_url_rewrites)"

if [[ -n "$rewrites" ]]; then
  log "A git URL rewrite survived: ${rewrites%%$'\n'*}"
  log "  A url.<...>.insteadOf rewrite embeds a token in the remote URL at session start and FREEZES it there, so the credential helper is never consulted and a refreshed token can never be picked up. That is the exact failure issue #32 removes."
  exit "$EXIT_CONFIG"
fi

if [[ "${#configured_helpers[@]}" -ne 1 ]]; then
  log "git is configured with ${#configured_helpers[@]} credential helper(s) for https://${SQUAD_GIT_CREDENTIAL_HOST}; expected exactly 1."
  log "  git asks helpers in order and uses the FIRST that answers, so any other helper can serve a stale cached credential in preference to the refreshed token file."
  exit "$EXIT_CONFIG"
fi

if [[ "${configured_helpers[0]}" != /* ]]; then
  log "The configured credential helper '${configured_helpers[0]}' is not an absolute path."
  log "  git prefixes a bare helper name with 'git-credential-', so this would resolve to a binary that does not exist and git would fall through with no credential."
  exit "$EXIT_CONFIG"
fi

if [[ ! -x "${configured_helpers[0]}" ]]; then
  log "The configured credential helper '${configured_helpers[0]}' is not executable."
  exit "$EXIT_CONFIG"
fi

# --- 2. the token file ------------------------------------------------------
mode="$(stat -c '%a' "$SQUAD_GIT_TOKEN_FILE" 2>/dev/null || echo '')"
if [[ "$mode" != "600" ]]; then
  log "The token file ${SQUAD_GIT_TOKEN_FILE} is mode '${mode:-unknown}', not 600."
  log "  A bearer token readable by any other account in the container is disclosed for the life of the session."
  exit "$EXIT_CONFIG"
fi

log "Credential wiring OK: one absolute-path helper for https://${SQUAD_GIT_CREDENTIAL_HOST}, no URL rewrite, token file 0600."

# --- 3. usability -----------------------------------------------------------
probe_disabled=false
case "${SQUAD_TOKEN_PREFLIGHT_PROBE:-}" in
  disabled|disable|off|false|0) probe_disabled=true ;;
esac

token_expires_at="${SQUAD_TOKEN_EXPIRES_AT:-}"

if [[ "$probe_disabled" == "true" ]]; then
  log "SQUAD_TOKEN_PREFLIGHT_PROBE is disabled; the credential was NOT exercised against the API."
elif ! command -v gh >/dev/null 2>&1; then
  log "'gh' is not installed; the credential was NOT exercised against the API."
else
  squad_credential_refresh_env || true

  set +e
  probe_out="$(gh api -i user 2>&1)"
  probe_rc=$?
  set -e

  if [[ "$probe_rc" -ne 0 ]]; then
    kind="$(squad_credential_classify_git_failure "$probe_out")"
    if [[ "$kind" == "auth" ]]; then
      log "The credential was REJECTED by the GitHub API (gh exited ${probe_rc})."
      log "  This session would have run to completion and then failed at the push. Failing now instead."
      log "  fix: mint a fresh token for this session; the token file is ${SQUAD_GIT_TOKEN_FILE}."
      exit "$EXIT_CREDENTIAL"
    fi
    log "The API probe failed but the failure says nothing about the credential (gh exited ${probe_rc}); treating it as transport and continuing."
  else
    log "The credential is accepted by the GitHub API."
    # A fine-grained PAT carries its expiry in a response header. An App
    # installation token does not, which is why SQUAD_TOKEN_EXPIRES_AT exists.
    if [[ -z "$token_expires_at" ]]; then
      header_expiry="$(printf '%s\n' "$probe_out" | grep -i '^github-authentication-token-expiration:' | head -n 1 | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
      if [[ -n "$header_expiry" ]]; then
        token_expires_at="$header_expiry"
        log "Token expiry read from the API response header: ${token_expires_at}"
      fi
    fi
  fi

  if [[ "${PUSH_CHANGES:-false}" == "true" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    set +e
    perm_out="$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.permissions.push' 2>&1)"
    perm_rc=$?
    set -e
    if [[ "$perm_rc" -ne 0 ]]; then
      kind="$(squad_credential_classify_git_failure "$perm_out")"
      if [[ "$kind" == "auth" ]]; then
        log "The credential cannot read ${GITHUB_REPOSITORY}'s permissions, which is how GitHub reports 'no access' to a token that can otherwise authenticate."
        log "  This session intends to PUSH. Failing now rather than after the agent run."
        exit "$EXIT_CREDENTIAL"
      fi
      log "The push-permission probe failed for a non-credential reason; continuing."
    elif [[ "$(printf '%s' "$perm_out" | tr -d '[:space:]')" != "true" ]]; then
      log "The credential does NOT have push access to ${GITHUB_REPOSITORY} (permissions.push=${perm_out})."
      log "  This session intends to PUSH; the push would fail after the whole agent run."
      log "  fix: grant the App installation (or the token) write access to this repository, or set PUSH_CHANGES=false."
      exit "$EXIT_CREDENTIAL"
    else
      log "The credential has push access to ${GITHUB_REPOSITORY}."
    fi
  fi
fi

# --- 4. lifetime ------------------------------------------------------------
run_minutes="${SQUAD_ESTIMATED_RUN_MINUTES:-60}"
margin_minutes="${SQUAD_TOKEN_MARGIN_MINUTES:-5}"
if [[ ! "$run_minutes" =~ ^[0-9]+$ ]]; then
  log "SQUAD_ESTIMATED_RUN_MINUTES='${run_minutes}' is not a whole number of minutes."
  exit 64
fi
if [[ ! "$margin_minutes" =~ ^[0-9]+$ ]]; then
  log "SQUAD_TOKEN_MARGIN_MINUTES='${margin_minutes}' is not a whole number of minutes."
  exit 64
fi
required_seconds=$(( (run_minutes + margin_minutes) * 60 ))

if [[ -z "$token_expires_at" ]]; then
  # Stated plainly rather than papered over. An unknown expiry is NOT evidence
  # that the token will survive, and this gate does not pretend otherwise: the
  # session proceeds, and the mid-run push retry (worker/entrypoint.sh) plus the
  # refresh channel are what cover it. See docs/sandboxes.md.
  log "Token expiry is UNKNOWN (no SQUAD_TOKEN_EXPIRES_AT and no expiry header); remaining lifetime was NOT checked."
  log "  A GitHub App installation token expires 1 hour after it is minted. Set SQUAD_TOKEN_EXPIRES_AT when dispatching to make this check meaningful."
  log "Token preflight passed (usability verified, lifetime unverified)."
  exit 0
fi

if ! expires_epoch="$(date -d "$token_expires_at" +%s 2>/dev/null)"; then
  log "SQUAD_TOKEN_EXPIRES_AT='${token_expires_at}' could not be parsed as a date; remaining lifetime was NOT checked."
  log "  fix: supply an ISO-8601 instant, e.g. 2026-07-31T18:00:00Z."
  exit 64
fi

now_epoch="$(date +%s)"
remaining=$(( expires_epoch - now_epoch ))

if [[ "$remaining" -le 0 ]]; then
  log "The credential expired $(( -remaining )) second(s) ago (expiry ${token_expires_at})."
  log "  Refusing to start: the clone would succeed and the push would fail at the end of the run."
  exit "$EXIT_CREDENTIAL"
fi

if [[ "$remaining" -lt "$required_seconds" ]]; then
  log "The credential has ${remaining}s left but this session needs ${required_seconds}s (estimated run ${run_minutes}m + margin ${margin_minutes}m)."
  log "  Refusing to start: the agent would run to completion and the push would then fail with an expired token."
  log "  fix: mint the token immediately before dispatch, lower SQUAD_ESTIMATED_RUN_MINUTES if this session is genuinely shorter, or deliver a mid-session refresh (ACA Sandboxes only -- see docs/sandboxes.md)."
  exit "$EXIT_CREDENTIAL"
fi

log "Token preflight passed: ${remaining}s of credential lifetime remain, ${required_seconds}s required."
exit 0
