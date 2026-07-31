#!/usr/bin/env bash
# Behavioural tests for worker/lib/squad-token-preflight.sh (issue #32).
#
# WHAT THE GATE IS FOR. A GitHub App installation token has a hard 1-hour TTL.
# A Squad session clones, runs an agent for 10-60 minutes, and pushes at the
# very end. Every way the credential can be wrong is INVISIBLE until that push,
# because a clone of a public repository succeeds with an expired token (exit 0,
# no warning; measured). Losing a session at minute 2 costs two minutes; losing
# it at minute 55 costs the whole run's wall-clock and AI credits.
#
# HOW THESE TESTS AVOID RESTATING THE IMPLEMENTATION. Every case runs the real
# script as a real process and asserts on its EXIT CODE -- the thing the
# entrypoint actually acts on -- plus a message an operator would need. The
# credential wiring is built by the real squad_credential_install_helper against
# a real git config, and `gh` is a real child process on PATH whose behaviour is
# driven from a control file, so the probe path is exercised rather than
# described.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PREFLIGHT="${WORKER_DIR}/lib/squad-token-preflight.sh"
CRED_LIB="${WORKER_DIR}/lib/squad-credentials.sh"
HELPER_SRC="${WORKER_DIR}/lib/squad-git-credential-helper.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps git

echo "== squad-token-preflight.sh =="

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-token-preflight-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

cp "$HELPER_SRC" "${WORK}/squad-git-credential-helper.sh"
chmod +x "${WORK}/squad-git-credential-helper.sh"
HELPER="${WORK}/squad-git-credential-helper.sh"

# A `gh` that is a real process on PATH. Its behaviour comes from a control
# file, so a case changes what GitHub "answers" without changing the script
# under test.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
mode="$(cat "${FAKE_GH_MODE_FILE:-/dev/null}" 2>/dev/null || echo ok)"
printf '%s %s\n' "$mode" "$*" >> "${FAKE_GH_CALL_LOG:-/dev/null}"
case "$*" in
  *"api -i user"*)
    case "$mode" in
      badcreds)  echo "gh: Bad credentials (HTTP 401)" >&2; exit 1 ;;
      network)   echo "gh: dial tcp: lookup api.github.com: no such host" >&2; exit 1 ;;
      expiring)
        echo "HTTP/2.0 200 OK"
        echo "github-authentication-token-expiration: ${FAKE_GH_EXPIRY:-}"
        echo ""
        echo '{"login":"octo-stub"}'
        exit 0 ;;
      *)
        echo "HTTP/2.0 200 OK"
        echo ""
        echo '{"login":"octo-stub"}'
        exit 0 ;;
    esac ;;
  *"api repos/"*)
    case "${FAKE_GH_PERMISSIONS:-push}" in
      nopush) echo "false"; exit 0 ;;
      fail)   echo "gh: Bad credentials (HTTP 401)" >&2; exit 1 ;;
      broken) echo "gh: the remote end hung up unexpectedly" >&2; exit 1 ;;
      *)      echo "true"; exit 0 ;;
    esac ;;
esac
exit 0
GHEOF
chmod +x "${WORK}/bin/gh"

# Builds a clean, correctly wired credential environment for one case, then
# echoes the directory it made. Every case starts from a healthy setup and
# breaks exactly one thing, so a failure names one cause.
case_no=0
new_case() {
  case_no=$((case_no + 1))
  local dir="${WORK}/case-${case_no}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# Runs the preflight in a subshell with a case's environment. Echoes the exit
# code on the last line so a caller can read both output and status without
# `$?` ever crossing a pipe (this repository has already shipped a runner that
# captured the NEGATED status of an `if !`, and could therefore never report a
# failure).
run_preflight() {
  local dir="$1"; shift
  local out rc
  out="$(
    cd "$dir" || exit 70
    export HOME="$dir/home"
    export GIT_CONFIG_GLOBAL="$dir/home/.gitconfig"
    export PATH="${WORK}/bin:${PATH}"
    export SQUAD_CREDENTIALS_LIB="$CRED_LIB"
    export SQUAD_GIT_TOKEN_FILE="$dir/state/git-token"
    export SQUAD_GIT_CREDENTIAL_HOST="github.com"
    export SQUAD_GIT_CREDENTIAL_HELPER="$HELPER"
    export FAKE_GH_MODE_FILE="$dir/gh-mode"
    export FAKE_GH_CALL_LOG="$dir/gh-calls"
    env "$@" bash "$PREFLIGHT" 2>&1
  )"
  rc=$?
  printf '%s\n__RC__%s\n' "$out" "$rc"
}
out_of()  { printf '%s' "${1%%__RC__*}"; }
rc_of()   { printf '%s' "${1##*__RC__}" | tr -d '\n'; }

# Builds a healthy wiring inside a case directory: token file at 0600, one
# absolute-path helper, no URL rewrite.
wire_case() {
  local dir="$1" token="${2:-ghs-preflight-token-aaaaaaaaaaaaaaaa}"
  mkdir -p "$dir/home"
  (
    export HOME="$dir/home"
    export GIT_CONFIG_GLOBAL="$dir/home/.gitconfig"
    export SQUAD_GIT_TOKEN_FILE="$dir/state/git-token"
    export SQUAD_GIT_CREDENTIAL_HOST="github.com"
    export SQUAD_GIT_CREDENTIAL_HELPER="$HELPER"
    : > "$GIT_CONFIG_GLOBAL"
    # shellcheck source=lib/squad-credentials.sh
    source "$CRED_LIB"
    squad_credential_write_token "$token"
    squad_credential_install_helper
  )
  echo "ok" > "$dir/gh-mode"
}

# --- 1. no credential at all, and the session does not push -----------------
# A public-repository session with PUSH_CHANGES=false legitimately has no
# credential. Blocking it would be a regression.
d="$(new_case)"; mkdir -p "$d/home"; : > "$d/home/.gitconfig"
r="$(run_preflight "$d")"
assert_eq "0" "$(rc_of "$r")" "no credential and no push: exits 0 (a public-repo session must not be blocked)"
assert_contains "$(out_of "$r")" "nothing to validate" "no credential and no push: says why it did nothing"

# --- 2. no credential, but the session intends to push ----------------------
d="$(new_case)"; mkdir -p "$d/home"; : > "$d/home/.gitconfig"
r="$(run_preflight "$d" PUSH_CHANGES=true)"
assert_eq "77" "$(rc_of "$r")" "no credential but PUSH_CHANGES=true: exits 77 (EX_NOPERM) instead of discovering it after the agent run"
assert_contains "$(out_of "$r")" "would fail after the whole agent run" "no credential but PUSH_CHANGES=true: names the consequence"

# --- 3. healthy wiring, live credential, unknown expiry ---------------------
d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d")"
assert_eq "0" "$(rc_of "$r")" "healthy wiring and a credential the API accepts: exits 0"
assert_contains "$(out_of "$r")" "Credential wiring OK" "healthy wiring: reports the wiring it verified"
assert_contains "$(out_of "$r")" "lifetime unverified" "unknown expiry: says so plainly instead of implying the token will survive the run"

# --- 4. the API rejects the credential --------------------------------------
d="$(new_case)"; wire_case "$d"; echo "badcreds" > "$d/gh-mode"
r="$(run_preflight "$d")"
assert_eq "77" "$(rc_of "$r")" "a credential the API rejects: exits 77 BEFORE the agent starts"
assert_contains "$(out_of "$r")" "REJECTED" "rejected credential: says the credential was rejected"

# --- 5. a transport failure says nothing about the credential ---------------
d="$(new_case)"; wire_case "$d"; echo "network" > "$d/gh-mode"
r="$(run_preflight "$d")"
assert_eq "0" "$(rc_of "$r")" "a DNS/transport failure does NOT block the session — a network hiccup is not evidence about the token"
assert_contains "$(out_of "$r")" "transport" "transport failure: explains why it did not block"

# --- 6. the credential authenticates but cannot push ------------------------
d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d" PUSH_CHANGES=true GITHUB_REPOSITORY=octo/demo FAKE_GH_PERMISSIONS=nopush)"
assert_eq "77" "$(rc_of "$r")" "a credential with no push access to the target repository: exits 77 when the session intends to push"
assert_contains "$(out_of "$r")" "does NOT have push access" "no push access: names the missing permission"

d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d" PUSH_CHANGES=true GITHUB_REPOSITORY=octo/demo FAKE_GH_PERMISSIONS=push)"
assert_eq "0" "$(rc_of "$r")" "a credential WITH push access: exits 0"
assert_contains "$(out_of "$r")" "has push access" "push access: confirms what it verified"

d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d" PUSH_CHANGES=true GITHUB_REPOSITORY=octo/demo FAKE_GH_PERMISSIONS=broken)"
assert_eq "0" "$(rc_of "$r")" "a permission probe that fails for a NON-credential reason does not block the session"

# --- 7. lifetime versus the estimated run -----------------------------------
# The estimate is configurable, and the two directions are asserted with the
# SAME remaining lifetime so the verdict can only have come from the estimate.
soon="$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)"

d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d" "SQUAD_TOKEN_EXPIRES_AT=$soon" SQUAD_ESTIMATED_RUN_MINUTES=60)"
assert_eq "77" "$(rc_of "$r")" "10 minutes of credential left and a 60-minute estimated run: exits 77 rather than spending the run and failing at the push"
assert_contains "$(out_of "$r")" "estimated run 60m" "insufficient lifetime: reports the estimate it judged against"

d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d" "SQUAD_TOKEN_EXPIRES_AT=$soon" SQUAD_ESTIMATED_RUN_MINUTES=2 SQUAD_TOKEN_MARGIN_MINUTES=1)"
assert_eq "0" "$(rc_of "$r")" "the SAME 10 minutes of credential with a 2-minute estimated run: exits 0 — the estimate is genuinely what decides, and it is configurable"

d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d" "SQUAD_TOKEN_EXPIRES_AT=$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)")"
assert_eq "77" "$(rc_of "$r")" "an already-expired credential: exits 77"
assert_contains "$(out_of "$r")" "expired" "expired credential: says so"

# The expiry may arrive on the API response instead of from the control plane.
d="$(new_case)"; wire_case "$d"; echo "expiring" > "$d/gh-mode"
r="$(run_preflight "$d" "FAKE_GH_EXPIRY=$soon" SQUAD_ESTIMATED_RUN_MINUTES=60)"
assert_eq "77" "$(rc_of "$r")" "an expiry read from the API response header is honoured just like SQUAD_TOKEN_EXPIRES_AT"
assert_contains "$(out_of "$r")" "response header" "header expiry: says where the expiry came from"

d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d" SQUAD_ESTIMATED_RUN_MINUTES=sixty)"
assert_eq "64" "$(rc_of "$r")" "a non-numeric run estimate is a usage error (64), not a silent default"

# --- 8. wiring faults are configuration failures, not credential failures ----
d="$(new_case)"; wire_case "$d"
( export GIT_CONFIG_GLOBAL="$d/home/.gitconfig"
  git config --global "url.https://x-access-token:frozen@github.com/.insteadOf" "https://github.com/" )
r="$(run_preflight "$d")"
assert_eq "78" "$(rc_of "$r")" "a surviving url.insteadOf rewrite: exits 78 — it embeds a FROZEN token and the helper would never be consulted"
assert_contains "$(out_of "$r")" "insteadOf" "surviving rewrite: names the mechanism"

d="$(new_case)"; wire_case "$d"
( export GIT_CONFIG_GLOBAL="$d/home/.gitconfig"
  git config --global --add "credential.https://github.com.helper" "/usr/bin/true" )
r="$(run_preflight "$d")"
assert_eq "78" "$(rc_of "$r")" "a second credential helper for the host: exits 78 — git uses the FIRST helper that answers, so a stale cache could outrank the token file"

d="$(new_case)"; wire_case "$d"
( export GIT_CONFIG_GLOBAL="$d/home/.gitconfig"
  git config --global --unset-all "credential.https://github.com.helper"
  git config --global --add "credential.https://github.com.helper" ""
  git config --global --add "credential.https://github.com.helper" "squad-helper" )
r="$(run_preflight "$d")"
assert_eq "78" "$(rc_of "$r")" "a helper configured by bare name rather than absolute path: exits 78 — git would look for a 'git-credential-squad-helper' binary that does not exist"

d="$(new_case)"; wire_case "$d"; chmod 644 "$d/state/git-token"
r="$(run_preflight "$d")"
assert_eq "78" "$(rc_of "$r")" "a world-readable token file: exits 78"
assert_contains "$(out_of "$r")" "600" "wide token file: names the mode it required"

# --- 9. the opt-outs, and what they cost ------------------------------------
d="$(new_case)"; wire_case "$d"; echo "badcreds" > "$d/gh-mode"
r="$(run_preflight "$d" SQUAD_TOKEN_PREFLIGHT=disabled)"
assert_eq "0" "$(rc_of "$r")" "SQUAD_TOKEN_PREFLIGHT=disabled bypasses a setup that would otherwise fail"

d="$(new_case)"; wire_case "$d"; echo "badcreds" > "$d/gh-mode"
r="$(run_preflight "$d" SKIP_TOKEN_PREFLIGHT=true)"
assert_eq "0" "$(rc_of "$r")" "SKIP_TOKEN_PREFLIGHT=true bypasses too, mirroring SKIP_CAPABILITY_PREFLIGHT"

d="$(new_case)"; wire_case "$d"; echo "badcreds" > "$d/gh-mode"
r="$(run_preflight "$d" SQUAD_TOKEN_PREFLIGHT_PROBE=disabled)"
assert_eq "0" "$(rc_of "$r")" "SQUAD_TOKEN_PREFLIGHT_PROBE=disabled skips only the live probe, for an offline environment"
assert_contains "$(out_of "$r")" "NOT exercised" "probe disabled: states plainly that the credential was never exercised"

# --- 10. a missing credential library is a configuration failure ------------
d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d" SQUAD_CREDENTIALS_LIB=/nonexistent/squad-credentials.sh)"
assert_eq "78" "$(rc_of "$r")" "a missing credential library: exits 78 rather than silently passing a gate it could not run"

# --- 11. the probe really is a probe ----------------------------------------
# A gate that never calls `gh` cannot have exercised the credential. This checks
# the call actually happened, so "usability verified" is not a claim about
# nothing.
d="$(new_case)"; wire_case "$d"
r="$(run_preflight "$d" PUSH_CHANGES=true GITHUB_REPOSITORY=octo/demo)"
calls="$(cat "$d/gh-calls" 2>/dev/null || true)"
assert_contains "$calls" "api -i user" "the gate really calls the GitHub API to exercise the credential"
assert_contains "$calls" "api repos/octo/demo" "the gate really reads the target repository's push permission when the session intends to push"

test_summary
