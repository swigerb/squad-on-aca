#!/usr/bin/env bash
# Issue #84 PI-3: withholding the push credential from an untrusted-input
# agent, then restoring it before the session publishes.
#
# worker/lib/squad-credentials.sh: squad_credential_withhold / _restore.
#
# WHAT THIS SUITE PROVES, and how:
#
#   1. While withheld, the agent's environment has NO push credential and NO
#      working git credential helper -- checked against git and the
#      environment directly, not against source text.
#   2. After restore, the SAME session can still push and would still be able
#      to open a PR -- checked against a real HTTPS remote that requires a
#      credential (worker/tests/lib/fake-git-https-server.js), exactly the
#      transport worker/tests/test_credentials.sh already uses for issue #32.
#   3. The ORDERING constraint from the design review: the lease heartbeat
#      background child is stopped BEFORE the credential is touched and only
#      restarted AFTER it is fully back -- proved by watching the actual PID,
#      not by reading the function body.
#   4. A restore that cannot recover the credential is FATAL (session abort),
#      never a silent "stay withheld and let the push fail later".
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
CRED_LIB_SRC="${WORKER_DIR}/lib/squad-credentials.sh"
HELPER_SRC="${WORKER_DIR}/lib/squad-git-credential-helper.sh"
SERVER_JS="${TEST_DIR}/lib/fake-git-https-server.js"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git openssl

echo "== squad-credentials.sh: PI-3 credential withholding (issue #84) =="

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-credential-withhold-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
SERVER_PID=""
HEARTBEAT_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  [[ -n "$HEARTBEAT_PID" ]] && kill "$HEARTBEAT_PID" 2>/dev/null
  [[ -n "${SQUAD_LEASE_HEARTBEAT_PID:-}" ]] && kill "$SQUAD_LEASE_HEARTBEAT_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BACKEND=""
for candidate in /usr/lib/git-core/git-http-backend /usr/libexec/git-core/git-http-backend; do
  [[ -x "$candidate" ]] && { BACKEND="$candidate"; break; }
done
if [[ -z "$BACKEND" ]]; then
  echo "SKIP: test_credential_withholding.sh — missing git-http-backend"
  exit "$TEST_SKIP_EXIT_CODE"
fi

mkdir -p "${WORK}/lib"
cp "$CRED_LIB_SRC" "${WORK}/lib/squad-credentials.sh"
cp "$HELPER_SRC" "${WORK}/lib/squad-git-credential-helper.sh"
chmod +x "${WORK}/lib/squad-git-credential-helper.sh"
HELPER="${WORK}/lib/squad-git-credential-helper.sh"

mkdir -p "${WORK}/tls"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${WORK}/tls/key.pem" -out "${WORK}/tls/cert.pem" \
  -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 || {
    echo "SKIP: test_credential_withholding.sh — openssl could not mint a self-signed certificate"
    exit "$TEST_SKIP_EXIT_CODE"
  }

mkdir -p "${WORK}/srv"
git init --bare --quiet "${WORK}/srv/repo.git"
git -C "${WORK}/srv/repo.git" config http.receivepack true

SERVER_TOKEN_FILE="${WORK}/srv/accepted-token"
AUTH_LOG="${WORK}/srv/auth.log"
REQUEST_LOG="${WORK}/srv/request.log"
PORT_FILE="${WORK}/srv/port"

LIVE_TOKEN="ghs-live-token-withhold-aaaaaaaaaaaaaaaa"
printf '%s\n' "$LIVE_TOKEN" > "$SERVER_TOKEN_FILE"

node "$SERVER_JS" \
  --root "${WORK}/srv" --cert "${WORK}/tls/cert.pem" --key "${WORK}/tls/key.pem" \
  --token-file "$SERVER_TOKEN_FILE" --auth-log "$AUTH_LOG" --request-log "$REQUEST_LOG" \
  --port-file "$PORT_FILE" --backend "$BACKEND" >"${WORK}/srv/server.out" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 100); do
  [[ -s "$PORT_FILE" ]] && { PORT="$(cat "$PORT_FILE")"; break; }
  sleep 0.1
done
if [[ -z "$PORT" ]]; then
  echo "FAIL: the HTTPS git fixture never bound a port"
  cat "${WORK}/srv/server.out" 2>/dev/null
  exit 1
fi

CRED_HOST="localhost:${PORT}"
REMOTE_URL="https://${CRED_HOST}/repo.git"

export HOME="${WORK}/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="${WORK}/home/.gitconfig"
: > "$GIT_CONFIG_GLOBAL"
export GIT_SSL_NO_VERIFY=1
export GIT_AUTHOR_NAME="Squad Test" GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="Squad Test" GIT_COMMITTER_EMAIL="test@example.invalid"

export SQUAD_GIT_TOKEN_FILE="${WORK}/state/git-token"
export SQUAD_GIT_CREDENTIAL_HOST="$CRED_HOST"
export SQUAD_GIT_CREDENTIAL_HELPER="$HELPER"

# shellcheck source=lib/squad-credentials.sh
source "${WORK}/lib/squad-credentials.sh"

# A stand-in for the lease heartbeat: a long-lived background process whose
# liveness we can watch directly, and — the whole point of the ordering rule —
# whose OWN environment freezes GH_TOKEN at the instant it forks. Redefining
# squad_lease_heartbeat_loop lets squad_credential_restore's restart path be
# exercised exactly as entrypoint.sh would call it.
squad_lease_heartbeat_loop() {
  # shellcheck disable=SC2016
  exec bash -c 'echo "$GH_TOKEN" > "$SQUAD_TEST_HEARTBEAT_SNAPSHOT"; while true; do sleep 3600; done' \
    >/dev/null 2>&1 </dev/null
}
SQUAD_LEASE_KEY="test-lease"

start_fake_heartbeat() {
  local snapshot_file="$1"
  export SQUAD_TEST_HEARTBEAT_SNAPSHOT="$snapshot_file"
  squad_lease_heartbeat_loop >/dev/null 2>&1 </dev/null &
  SQUAD_LEASE_HEARTBEAT_PID=$!
  # give the child a moment to snapshot its environment and start sleeping
  for _ in $(seq 1 50); do
    [[ -s "$snapshot_file" ]] && break
    sleep 0.1
  done
}

pid_alive() {
  kill -0 "$1" 2>/dev/null
}

# ===========================================================================
# 1. Baseline: install the credential, prove the remote is reachable, start
#    the fake heartbeat holding the live token in ITS OWN process environment.
# ===========================================================================
squad_credential_write_token "$LIVE_TOKEN"
squad_credential_install_helper
squad_credential_refresh_env

mkdir -p "${WORK}/clone"
clone_out="$(git clone --quiet "$REMOTE_URL" "${WORK}/clone/work" 2>&1)"
assert_eq "0" "$?" "CONTROL: baseline clone against the credentialed remote succeeds before any withholding"
REPO="${WORK}/clone/work"
git -C "$REPO" config user.name "Squad Test"
git -C "$REPO" config user.email "test@example.invalid"

HEARTBEAT_SNAPSHOT_1="${WORK}/heartbeat-snapshot-1"
start_fake_heartbeat "$HEARTBEAT_SNAPSHOT_1"
first_heartbeat_pid="$SQUAD_LEASE_HEARTBEAT_PID"
assert_eq "1" "$(pid_alive "$first_heartbeat_pid" && echo 1 || echo 0)" \
  "CONTROL: the fake heartbeat child is running before withholding"
assert_eq "$LIVE_TOKEN" "$(cat "$HEARTBEAT_SNAPSHOT_1" 2>/dev/null)" \
  "CONTROL: the heartbeat child's own environment holds the live token at fork time"

# ===========================================================================
# 2. WITHHOLD: no push credential, no working helper, in the environment an
#    agent started after this call would inherit — and the heartbeat that
#    could have kept the token legible is gone BEFORE any of that happens.
# ===========================================================================
squad_credential_withhold

assert_eq "0" "$(pid_alive "$first_heartbeat_pid" && echo 1 || echo 0)" \
  "ORDERING: the pre-withholding heartbeat child is no longer running once withhold() returns"
assert_eq "" "${SQUAD_LEASE_HEARTBEAT_PID}" \
  "ORDERING: SQUAD_LEASE_HEARTBEAT_PID is cleared, so nothing restarts it accidentally while withheld"

assert_eq "" "${GH_TOKEN:-}"     "withheld: GH_TOKEN is unset in the shell an agent process would inherit"
assert_eq "" "${GITHUB_TOKEN:-}" "withheld: GITHUB_TOKEN is unset in the shell an agent process would inherit"
assert_eq "1" "$([[ -e "$SQUAD_GIT_TOKEN_FILE" ]] && echo 0 || echo 1)" \
  "withheld: the token file no longer exists on disk"
assert_eq "" "$(squad_credential_configured_helpers)" \
  "withheld: git reports NO configured credential helper for the host — an agent-run git operation cannot get a credential from git either"

# A git operation attempted from inside the "agent's" environment, in the same
# shell, with the exact same PATH/HOME an agent subprocess would see, fails —
# this is the direct behavioural proof requested: no push credential, no
# working helper, in the agent's own view of the world.
: > "$AUTH_LOG"
printf 'work produced while the credential is withheld\n' >> "${REPO}/log.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "work produced while withheld"
withheld_push_out="$(GIT_TERMINAL_PROMPT=0 git -C "$REPO" push origin HEAD:refs/heads/withheld-attempt 2>&1)"
withheld_push_rc=$?
assert_ne "0" "$withheld_push_rc" \
  "withheld: an agent-initiated push fails outright — there is no credential anywhere to answer it"
assert_eq "auth" "$(squad_credential_classify_git_failure "$withheld_push_out")" \
  "withheld: the push failure classifies as a credential fault, not a network/execution fault"

# MUTATION PROOF M8 target: removing `unset GH_TOKEN GITHUB_TOKEN` from
# squad_credential_withhold makes the "GH_TOKEN is unset"/"GITHUB_TOKEN is
# unset" assertions above fail (the exported variable would still be
# present).
# MUTATION PROOF M9 target: removing the squad_credential_uninstall_helper
# call from squad_credential_withhold makes "git reports NO configured
# credential helper" fail, and the withheld push would then succeed instead
# of failing (the stale helper would still answer).

# ===========================================================================
# 3. RESTORE: before "commit_and_push_if_needed" runs, the credential, the
#    helper, and the environment are all back — and the heartbeat is
#    restarted only now, never straddling the withheld window.
# ===========================================================================
squad_credential_restore

assert_eq "$LIVE_TOKEN" "${GH_TOKEN:-}"     "restored: GH_TOKEN is back to the withheld value"
assert_eq "$LIVE_TOKEN" "${GITHUB_TOKEN:-}" "restored: GITHUB_TOKEN is back to the withheld value"
assert_eq "$LIVE_TOKEN" "$(squad_credential_read_token)" \
  "restored: the token file is rewritten with the withheld value"
assert_eq "$HELPER" "$(squad_credential_configured_helpers)" \
  "restored: the credential helper is reinstalled for the host"

restarted_heartbeat_pid="$SQUAD_LEASE_HEARTBEAT_PID"
assert_ne "" "$restarted_heartbeat_pid" "restored: a new heartbeat PID is recorded"
assert_ne "$first_heartbeat_pid" "$restarted_heartbeat_pid" \
  "restored: the restarted heartbeat is a DIFFERENT process, not the one that was killed"
assert_eq "1" "$(pid_alive "$restarted_heartbeat_pid" && echo 1 || echo 0)" \
  "restored: the new heartbeat child is actually running"
HEARTBEAT_PID="$restarted_heartbeat_pid"

# This is the headline claim of PI-3: the agent held no push credential, and
# the SAME session — after restore — still creates a branch and can still
# push it, exactly the shape worker/entrypoint.sh's commit_and_push_if_needed
# needs post-agent.
: > "$AUTH_LOG"
git -C "$REPO" checkout --quiet -b "squad/withhold-restore-proof"
printf 'work published after restore, standing in for commit_and_push_if_needed\n' >> "${REPO}/log.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "post-agent publish after credential restore"
restored_push_out="$(git -C "$REPO" push origin HEAD:refs/heads/squad/withhold-restore-proof 2>&1)"
restored_push_rc=$?
assert_eq "0" "$restored_push_rc" \
  "restored: post-agent push of the new branch succeeds — the branch a PR would be opened from is created and pushed"
assert_contains "$(cat "$AUTH_LOG")" "PRESENTED x-access-token:${LIVE_TOKEN}" \
  "restored: the credential that crossed the wire on the post-agent push is the SAME token that was withheld, not a leftover/cached one"

remote_branches="$(git -C "$REPO" ls-remote --heads "$REMOTE_URL" 2>&1)"
assert_contains "$remote_branches" "refs/heads/squad/withhold-restore-proof" \
  "restored: the branch a PR would be opened against exists on the remote after restore"

# MUTATION PROOF M10 target: removing the squad_credential_restore call
# (or the entire restore block) from worker/entrypoint.sh means the token
# file / helper / env are never put back, and this whole section — restored
# GH_TOKEN, restored helper, and the post-agent push — fails, because
# squad_credential_restore itself was skipped.

# ===========================================================================
# 4. ORDERING ASSERTION: withholding happens before the "agent" step and
#    restoring happens after it and before "publish" — recorded as an
#    explicit sequence, so a mutation that moves either call across that
#    boundary is caught structurally, not just by its side effects.
# ===========================================================================
ORDER_LOG="${WORK}/order.log"
: > "$ORDER_LOG"

run_ordered_session() {
  # Mirrors worker/entrypoint.sh's shape for prompt/new-project: withhold,
  # run the agent, restore, THEN publish. Never withhold/restore split across
  # the heartbeat in a way that lets the agent step see a live credential.
  squad_credential_withhold
  echo "withhold" >> "$ORDER_LOG"

  echo "agent-start" >> "$ORDER_LOG"
  # the "agent": prove it runs with nothing to credential itself with
  if [[ -n "${GH_TOKEN:-}" || -e "$SQUAD_GIT_TOKEN_FILE" ]]; then
    echo "agent-saw-credential" >> "$ORDER_LOG"
  fi
  echo "agent-end" >> "$ORDER_LOG"

  squad_credential_restore
  echo "restore" >> "$ORDER_LOG"

  echo "publish" >> "$ORDER_LOG"
}
run_ordered_session

order_seq="$(tr '\n' ',' < "$ORDER_LOG")"
assert_eq "withhold,agent-start,agent-end,restore,publish," "$order_seq" \
  "ORDERING: withhold precedes the agent step, restore follows it, and publish follows restore — with no 'agent-saw-credential' entry in between"

# MUTATION PROOF M11 target: reordering run_ordered_session so restore is
# called BEFORE the agent step (or withhold after it) changes order_seq —
# either producing "agent-saw-credential" (the agent step observed a live
# credential) or a sequence where restore/publish precede agent-end — and
# this assertion fails.

# ---------------------------------------------------------------------------
# 4b. The heartbeat/credential ordering INSIDE squad_credential_withhold /
#     squad_credential_restore themselves, structurally: the heartbeat kill
#     must precede any credential mutation in withhold(), and the heartbeat
#     restart must follow every credential-restoration step in restore(). A
#     mutation that moves withholding across that internal boundary (rather
#     than removing a whole call) is caught here even though it would not
#     necessarily change order_seq above, since order_seq only observes the
#     OUTER prompt/agent/publish sequence, not the heartbeat boundary inside
#     a single function call.
# ---------------------------------------------------------------------------
WITHHOLD_BODY="$(sed -n '/^squad_credential_withhold() {/,/^}/p' "${WORK}/lib/squad-credentials.sh")"
RESTORE_BODY="$(sed -n '/^squad_credential_restore() {/,/^}/p' "${WORK}/lib/squad-credentials.sh")"

heartbeat_kill_line="$(printf '%s\n' "$WITHHOLD_BODY" | grep -n 'kill "\$SQUAD_LEASE_HEARTBEAT_PID"' | head -1 | cut -d: -f1)"
unset_token_line="$(printf '%s\n' "$WITHHOLD_BODY" | grep -n '^ *unset GH_TOKEN GITHUB_TOKEN$' | head -1 | cut -d: -f1)"
remove_file_line="$(printf '%s\n' "$WITHHOLD_BODY" | grep -n '^ *squad_credential_remove_token_file$' | head -1 | cut -d: -f1)"

assert_eq "1" "$([[ -n "$heartbeat_kill_line" && -n "$unset_token_line" && "$heartbeat_kill_line" -lt "$unset_token_line" ]] && echo 1 || echo 0)" \
  "ORDERING (internal): squad_credential_withhold kills the heartbeat BEFORE unsetting GH_TOKEN/GITHUB_TOKEN"
assert_eq "1" "$([[ -n "$heartbeat_kill_line" && -n "$remove_file_line" && "$heartbeat_kill_line" -lt "$remove_file_line" ]] && echo 1 || echo 0)" \
  "ORDERING (internal): squad_credential_withhold kills the heartbeat BEFORE removing the token file"

refresh_env_line="$(printf '%s\n' "$RESTORE_BODY" | grep -n 'squad_credential_refresh_env' | head -1 | cut -d: -f1)"
heartbeat_restart_line="$(printf '%s\n' "$RESTORE_BODY" | grep -n 'squad_lease_heartbeat_loop &$' | head -1 | cut -d: -f1)"
_m11_restore_ordered="$([[ -n "$refresh_env_line" && -n "$heartbeat_restart_line" && "$refresh_env_line" -lt "$heartbeat_restart_line" ]] && echo 1 || echo 0)"

assert_eq "1" "$_m11_restore_ordered" \
  "ORDERING (internal): squad_credential_restore restarts the heartbeat only AFTER the credential is refreshed, never before"

# MUTATION PROOF M11 target: moving the heartbeat kill in
# squad_credential_withhold to AFTER the credential mutations (or moving the
# heartbeat restart in squad_credential_restore to BEFORE the credential is
# refreshed) makes one of the three assertions immediately above fail —
# catching a straddling reorder even when it would not otherwise change the
# outer withhold/agent/restore/publish sequence.

# ===========================================================================
# 5. A restore that cannot recover the credential is FATAL, not silent.
# ===========================================================================
(
  trap - EXIT INT TERM
  # shellcheck source=lib/squad-credentials.sh
  source "${WORK}/lib/squad-credentials.sh"
  squad_lease_heartbeat_loop() { :; }
  SQUAD_CREDENTIAL_IS_WITHHELD=1
  SQUAD_CREDENTIAL_WITHHELD_TOKEN=""
  squad_credential_restore
) >"${WORK}/fatal-restore.out" 2>&1
fatal_restore_rc=$?
fatal_restore_out="$(cat "${WORK}/fatal-restore.out")"
assert_ne "0" "$fatal_restore_rc" \
  "a restore with no withheld token to restore never returns success — the subshell exits non-zero"
assert_eq "78" "$fatal_restore_rc" \
  "a restore with no withheld token to restore exits 78 (fatal), matching worker/entrypoint.sh's config-fault exit code"
assert_contains "$fatal_restore_out" "FATAL: no withheld credential is available to restore" \
  "the fatal restore path names the specific failure, not a generic error"

# ===========================================================================
# 6. entrypoint.sh wiring: withhold/restore are actually called, in order,
#    around the agent invocation, and restore precedes commit_and_push_if_needed.
# ===========================================================================
echo "-- entrypoint.sh wiring --"

ENTRY="${WORKER_DIR}/entrypoint.sh"
PROMPT_BLOCK="$(sed -n '/^  prompt)/,/^    ;;/p' "$ENTRY")"
NEWPROJ_BLOCK="$(sed -n '/^  new-project)/,/^    ;;/p' "$ENTRY")"

for block_name in "prompt:${PROMPT_BLOCK}" "new-project:${NEWPROJ_BLOCK}"; do
  name="${block_name%%:*}"
  block="${block_name#*:}"
  assert_contains "$block" "squad_credential_should_withhold" \
    "${name} mode checks whether the credential should be withheld"
  assert_contains "$block" "squad_credential_withhold"        "${name} mode calls squad_credential_withhold"
  assert_contains "$block" "squad_credential_restore"         "${name} mode calls squad_credential_restore"

  # ORDERING, read directly from the file: withhold before the agent call,
  # restore after it, and restore before commit_and_push_if_needed. Grepping
  # line numbers rather than trusting prose, exactly as test_identity_drop.sh
  # already does for squad_drop_azure_identity vs the first agent invocation.
  withhold_line="$(printf '%s\n' "$block" | grep -n 'squad_credential_withhold$' | head -1 | cut -d: -f1)"
  restore_line="$(printf '%s\n' "$block" | grep -n 'squad_credential_restore$' | head -1 | cut -d: -f1)"
  agent_line="$(printf '%s\n' "$block" | grep -n 'squad_hub_run\|copilot -p' | head -1 | cut -d: -f1)"
  publish_line="$(printf '%s\n' "$block" | grep -n '^ *commit_and_push_if_needed$' | head -1 | cut -d: -f1)"

  assert_eq "1" "$([[ -n "$withhold_line" && -n "$agent_line" && "$withhold_line" -lt "$agent_line" ]] && echo 1 || echo 0)" \
    "${name} mode: withhold happens BEFORE the agent is invoked"
  assert_eq "1" "$([[ -n "$agent_line" && -n "$restore_line" && "$agent_line" -lt "$restore_line" ]] && echo 1 || echo 0)" \
    "${name} mode: restore happens AFTER the agent is invoked"
  assert_eq "1" "$([[ -n "$restore_line" && -n "$publish_line" && "$restore_line" -lt "$publish_line" ]] && echo 1 || echo 0)" \
    "${name} mode: restore happens BEFORE commit_and_push_if_needed publishes"
done

# MUTATION PROOF M10 target: removing the `squad_credential_restore` call (or
# the whole restore block) from one of the case blocks in worker/entrypoint.sh
# makes that mode's "calls squad_credential_restore" assertion above fail
# (restore_line/publish_line become empty), rather than merely leaving the
# runtime behaviour untested.

test_summary
