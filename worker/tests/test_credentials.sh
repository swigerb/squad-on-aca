#!/usr/bin/env bash
# Behavioural tests for the worker's GitHub credential path (issue #32):
#   worker/lib/squad-credentials.sh
#   worker/lib/squad-git-credential-helper.sh
#
# WHAT THIS SUITE REFUSES TO DO.
#
# The change under test removes `url.<...>.insteadOf` and installs a git
# credential helper instead. The tempting test -- "clone and check it worked" --
# is worthless here, because squad-on-aca's repository is PUBLIC: an
# unauthenticated clone succeeds, and so does a clone with an EXPIRED token
# (measured: exit 0, no warning). A test that only observed a successful clone
# would stay green with the helper deleted.
#
# So every claim below is exercised against a REAL git remote over REAL HTTPS
# that answers 401 until a correct credential arrives (worker/tests/lib/
# fake-git-https-server.js, driving the real `git http-backend`). Against that
# remote:
#
#   * a successful push can only have come from the helper -- there is no other
#     source for the password -- and the server's auth log records exactly what
#     crossed the wire, so the assertion is about the credential, not the exit
#     code;
#   * the mid-session refresh is reproduced end to end: push with a stale token
#     (fails), rewrite ONLY the token file, push again in the same working copy
#     with no re-clone and no `git config` change (succeeds).
#
# The client is stock `git` doing stock smart-HTTP. Nothing in the credential
# path is simulated.
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

echo "== squad-credentials.sh + squad-git-credential-helper.sh =="

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-credentials-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
SERVER_PID=""
# Issue #92: every background child this suite starts must be accounted for
# by the SAME cleanup path that runs on ANY exit (normal, failure, signal) --
# not just the happy-path manual `kill` further down, which never runs if the
# script exits before reaching it. DECOY_PID/SLOW_PID/PUSH_PID are declared
# here, before anything can background them, so the trap is safe under `set -u`
# no matter how early it fires.
DECOY_PID=""
SLOW_PID=""
PUSH_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  [[ -n "$DECOY_PID" ]] && kill "$DECOY_PID" 2>/dev/null
  [[ -n "$SLOW_PID" ]] && kill "$SLOW_PID" 2>/dev/null
  [[ -n "$PUSH_PID" ]] && kill "$PUSH_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

BACKEND=""
for candidate in /usr/lib/git-core/git-http-backend /usr/libexec/git-core/git-http-backend; do
  [[ -x "$candidate" ]] && { BACKEND="$candidate"; break; }
done
if [[ -z "$BACKEND" ]]; then
  echo "SKIP: test_credentials.sh — missing git-http-backend"
  exit "$TEST_SKIP_EXIT_CODE"
fi

# The shipped files, copied and made executable exactly as worker/Dockerfile
# does (`chmod +x`), so the suite runs the bytes that ship without depending on
# a mode git may not have preserved on the checkout.
mkdir -p "${WORK}/lib"
cp "$CRED_LIB_SRC" "${WORK}/lib/squad-credentials.sh"
cp "$HELPER_SRC" "${WORK}/lib/squad-git-credential-helper.sh"
chmod +x "${WORK}/lib/squad-git-credential-helper.sh"
HELPER="${WORK}/lib/squad-git-credential-helper.sh"

# --- a real HTTPS remote that really requires a credential -------------------
mkdir -p "${WORK}/tls"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${WORK}/tls/key.pem" -out "${WORK}/tls/cert.pem" \
  -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 || {
    echo "SKIP: test_credentials.sh — openssl could not mint a self-signed certificate"
    exit "$TEST_SKIP_EXIT_CODE"
  }

mkdir -p "${WORK}/srv"
git init --bare --quiet "${WORK}/srv/repo.git"
git -C "${WORK}/srv/repo.git" config http.receivepack true

SERVER_TOKEN_FILE="${WORK}/srv/accepted-token"   # what the SERVER will accept
AUTH_LOG="${WORK}/srv/auth.log"
REQUEST_LOG="${WORK}/srv/request.log"
PORT_FILE="${WORK}/srv/port"

LIVE_TOKEN="ghs-live-token-aaaaaaaaaaaaaaaaaaaaaaaa"
STALE_TOKEN="ghs-stale-token-bbbbbbbbbbbbbbbbbbbbbbbb"
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

# git puts the PORT in the credential `host` field when it is non-default, so
# the helper and the config key must both be scoped to host:port.
CRED_HOST="localhost:${PORT}"
REMOTE_URL="https://${CRED_HOST}/repo.git"

# --- a HOME and a git config that belong only to this suite ------------------
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

# ===========================================================================
# 1. WIRING: a pre-existing helper holding a WRONG credential must not win
# ===========================================================================
# Staged BEFORE the install, because that is the real hazard: a helper
# inherited from the base image or from an earlier run in the same HOME serves
# a cached credential, git uses the FIRST helper that answers, and the freshly
# refreshed token file is never consulted.
git config --global credential.helper store
printf 'https://x-access-token:%s@%s\n' "$STALE_TOKEN" "$CRED_HOST" > "${HOME}/.git-credentials"
chmod 600 "${HOME}/.git-credentials"

# A leftover URL rewrite -- the mechanism this change removes -- is staged too.
git config --global "url.https://x-access-token:${STALE_TOKEN}@${CRED_HOST}/.insteadOf" "https://${CRED_HOST}/"

squad_credential_write_token "$LIVE_TOKEN"
squad_credential_install_helper

rewrites_after="$(squad_credential_url_rewrites)"
assert_eq "" "$rewrites_after" "install removes every url.insteadOf rewrite, so the remote URL cannot carry a frozen token and bypass the helper"

helpers_after="$(squad_credential_configured_helpers)"
assert_eq "$HELPER" "$helpers_after" "install leaves exactly one credential helper for the host, at an absolute path (git prefixes a bare name with git-credential- and would find nothing)"

generic_after="$(git config --global --get-all credential.helper 2>/dev/null || true)"
assert_eq "" "$generic_after" "install clears the pre-existing generic credential.helper, so a stale cached credential cannot answer before the token file"

# ===========================================================================
# 2. The remote really does require a credential (control for everything below)
# ===========================================================================
anon_out="$(GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL="${WORK}/empty-gitconfig" git ls-remote "$REMOTE_URL" 2>&1)"
anon_rc=$?
assert_eq "128" "$anon_rc" "CONTROL: with no credential helper configured at all, the fixture refuses the remote (exit 128) — so every success below is evidence about the credential, not about the network"
assert_eq "auth" "$(squad_credential_classify_git_failure "$anon_out")" "CONTROL: the anonymous attempt fails for a credential reason (git could obtain no credential at all)"

# ===========================================================================
# 3. THE HELPER IS ACTUALLY CONSULTED
# ===========================================================================
mkdir -p "${WORK}/clone"
: > "$AUTH_LOG"
clone_out="$(git clone --quiet "$REMOTE_URL" "${WORK}/clone/work" 2>&1)"
clone_rc=$?
assert_eq "0" "$clone_rc" "clone against a remote that requires auth succeeds (the helper supplied the credential)"
assert_contains "$(cat "$AUTH_LOG")" "PRESENTED x-access-token:${LIVE_TOKEN}" "the credential that crossed the wire is the token from the FILE, presented as x-access-token — proof the helper was consulted, not merely that a clone worked"

REPO="${WORK}/clone/work"
git -C "$REPO" config user.name "Squad Test"
git -C "$REPO" config user.email "test@example.invalid"

remote_url_recorded="$(git -C "$REPO" remote get-url origin)"
assert_not_contains "$remote_url_recorded" "$LIVE_TOKEN" "the token is not embedded in the remote URL (that is exactly what url.insteadOf used to do, and what freezes it for the session)"

config_dump="$(git -C "$REPO" config --list --show-origin 2>&1; git config --global --list 2>&1)"
assert_not_contains "$config_dump" "$LIVE_TOKEN" "the token appears nowhere in git config output"

# ===========================================================================
# 4. THE HEADLINE: a token that goes stale mid-session is recovered by
#    rewriting ONLY the token file — no re-clone, no config change
# ===========================================================================
make_commit() {
  local msg="$1"
  printf '%s\n' "$msg" >> "${REPO}/log.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m "$msg"
}

# The control plane rotates: the server now accepts only a NEW token, and the
# worker is still holding the old one. This is minute 55 of a 60-minute run.
ROTATED_TOKEN="ghs-rotated-token-cccccccccccccccccccccccc"
printf '%s\n' "$ROTATED_TOKEN" > "$SERVER_TOKEN_FILE"

make_commit "work produced by the agent run"
: > "$AUTH_LOG"
push_out="$(git -C "$REPO" push origin HEAD:refs/heads/main 2>&1)"
push_rc=$?
assert_eq "128" "$push_rc" "a push with the token the session started with fails once that token is no longer accepted (exit 128) — the failure the whole change exists to survive"
push_kind="$(squad_credential_classify_git_failure "$push_out")"
assert_eq "auth" "$push_kind" "that push failure classifies as a CREDENTIAL fault, so an operator is told to rotate the token instead of re-running the work"

# The refresh: ONLY the token file is rewritten. Same process, same working
# copy, same git config, no re-clone.
config_before_refresh="$(git -C "$REPO" config --list; git config --global --list)"
squad_credential_write_token "$ROTATED_TOKEN"
config_after_refresh="$(git -C "$REPO" config --list; git config --global --list)"
assert_eq "$config_before_refresh" "$config_after_refresh" "the refresh changes NO git configuration — the token file is the only thing rewritten"

: > "$AUTH_LOG"
retry_out="$(git -C "$REPO" push origin HEAD:refs/heads/main 2>&1)"
retry_rc=$?
assert_eq "0" "$retry_rc" "after the token FILE is refreshed, the very next push succeeds in the same working copy with no re-clone — this is the mitigation, end to end"
assert_contains "$(cat "$AUTH_LOG")" "PRESENTED x-access-token:${ROTATED_TOKEN}" "the retry presented the REFRESHED token, so the helper re-read the file rather than reusing anything cached"

server_head="$(git -C "${WORK}/srv/repo.git" rev-parse refs/heads/main 2>/dev/null)"
local_head="$(git -C "$REPO" rev-parse HEAD)"
assert_eq "$local_head" "$server_head" "the work actually landed on the remote after the refresh (the ref moved), not merely a zero exit code"

# ===========================================================================
# 5. Nothing is ever cached to disk by git
# ===========================================================================
stored_creds="$(cat "${HOME}/.git-credentials" 2>/dev/null || true)"
assert_not_contains "$stored_creds" "$ROTATED_TOKEN" "a successful authentication does not write the live token into ~/.git-credentials (the helper's 'store' is a silent no-op)"

home_grep="$(grep -rlF -- "$ROTATED_TOKEN" "$HOME" 2>/dev/null | grep -v "^${SQUAD_GIT_TOKEN_FILE}$" || true)"
assert_eq "" "$home_grep" "the live token exists in no file under HOME other than the 0600 token file"

# ===========================================================================
# 6. The token file is private
# ===========================================================================
token_mode="$(stat -c '%a' "$SQUAD_GIT_TOKEN_FILE")"
assert_eq "600" "$token_mode" "the token file is mode 0600"
dir_mode="$(stat -c '%a' "$(dirname "$SQUAD_GIT_TOKEN_FILE")")"
assert_eq "700" "$dir_mode" "the directory holding the token file is mode 0700"

umask_probe_dir="${WORK}/umask-probe"
( umask 000; SQUAD_GIT_TOKEN_FILE="${umask_probe_dir}/git-token" squad_credential_write_token "$LIVE_TOKEN" )
assert_eq "600" "$(stat -c '%a' "${umask_probe_dir}/git-token")" "the token file is 0600 even when the caller's umask is 000 — it is never created wide and narrowed afterwards"

# ===========================================================================
# 7. The token is never in any process's argv (with a POSITIVE CONTROL)
# ===========================================================================
# An absence assertion is only worth something if the same probe can be shown to
# detect a presence. A control process is started holding a decoy token in its
# argv; the scan must find the decoy and must not find the real one, in the same
# window, while a push is genuinely in flight.
scan_argv_for() {
  local needle="$1" p
  # A pid that exits between the glob and the read is normal, not an error, so
  # the read's own stderr is discarded too.
  for p in /proc/[0-9]*/cmdline; do
    if tr '\0' ' ' 2>/dev/null < "$p" | grep -qF -- "$needle" 2>/dev/null; then
      return 0
    fi
  done 2>/dev/null
  return 1
}

if [[ -r /proc/self/cmdline ]]; then
  DECOY="squad-decoy-token-dddddddddddddddddddddddd"
  # `; :` defeats bash's exec optimisation for a single simple command; without
  # it bash would exec `sleep` and REPLACE its own argv, and the control would
  # silently stop being a control.
  bash -c 'sleep 6; :' "--token=${DECOY}" >/dev/null 2>&1 </dev/null &
  DECOY_PID=$!
  sleep 0.3

  # A second server with a response delay, so the push is measurably in flight
  # while /proc is scanned. Without the delay the scan races the push and an
  # empty result proves nothing.
  SLOW_PORT_FILE="${WORK}/srv/slow-port"
  node "$SERVER_JS" \
    --root "${WORK}/srv" --cert "${WORK}/tls/cert.pem" --key "${WORK}/tls/key.pem" \
    --token-file "$SERVER_TOKEN_FILE" --port-file "$SLOW_PORT_FILE" --delay-ms 2500 \
    --backend "$BACKEND" >"${WORK}/srv/slow.out" 2>&1 &
  SLOW_PID=$!
  SLOW_PORT=""
  for _ in $(seq 1 100); do
    [[ -s "$SLOW_PORT_FILE" ]] && { SLOW_PORT="$(cat "$SLOW_PORT_FILE")"; break; }
    sleep 0.1
  done

  if [[ -n "$SLOW_PORT" ]]; then
    # The slow remote is a different host:port, so it needs its own scoped
    # helper entry; the same helper file answers for it.
    SQUAD_GIT_CREDENTIAL_HOST="localhost:${SLOW_PORT}"
    export SQUAD_GIT_CREDENTIAL_HOST
    squad_credential_install_helper
    make_commit "a change pushed while /proc is being scanned"
    ( git -C "$REPO" push "https://localhost:${SLOW_PORT}/repo.git" HEAD:refs/heads/slow >/dev/null 2>&1 ) &
    PUSH_PID=$!

    control_seen=1
    token_seen=1
    for _ in $(seq 1 40); do
      scan_argv_for "$DECOY" && control_seen=0
      scan_argv_for "$ROTATED_TOKEN" && token_seen=0
      kill -0 "$PUSH_PID" 2>/dev/null || break
      sleep 0.1
    done
    wait "$PUSH_PID" 2>/dev/null
    PUSH_PID=""

    assert_eq "0" "$control_seen" "POSITIVE CONTROL: the /proc argv scan does find a decoy token that IS in a process's argv, so the absence assertion below is a real observation"
    assert_eq "1" "$token_seen" "no process held the live token in its argv while a push was in flight — the token reaches git through the helper's stdout, never through a command line"
  fi
  kill "$DECOY_PID" 2>/dev/null
  wait "$DECOY_PID" 2>/dev/null
  DECOY_PID=""
  kill "$SLOW_PID" 2>/dev/null
  wait "$SLOW_PID" 2>/dev/null
  SLOW_PID=""
  # Restore the scoping the rest of the suite expects.
  SQUAD_GIT_CREDENTIAL_HOST="$CRED_HOST"
  export SQUAD_GIT_CREDENTIAL_HOST
fi

# ===========================================================================
# 8. The helper's protocol contract, driven through REAL git
# ===========================================================================
# `git credential fill` is git's own front door to the helper stack: it reads
# the same config and runs the same helpers a fetch or a push would. Asserting
# through it means the protocol claims are about git's behaviour, not about a
# hand-rolled reading of the helper script.
fill_out="$(printf 'protocol=https\nhost=%s\n\n' "$CRED_HOST" | git credential fill 2>/dev/null)"
assert_contains "$fill_out" "username=x-access-token" "git credential fill returns the username the helper supplies"
assert_contains "$fill_out" "=${ROTATED_TOKEN}" "git credential fill returns the CURRENT contents of the token file"

other_host_out="$(printf 'protocol=https\nhost=example.invalid\n\n' | git credential fill 2>/dev/null | grep -c "$ROTATED_TOKEN" || true)"
assert_eq "0" "$other_host_out" "git does not hand this token to a different host — the helper is scoped in config AND re-checks the host itself"

# The helper answers `get` for its own host and nothing else, and never errors.
helper_get="$(printf 'protocol=https\nhost=%s\n\n' "$CRED_HOST" | "$HELPER" get 2>&1)"
assert_contains "$helper_get" "$ROTATED_TOKEN" "helper 'get' for the configured host returns the token"

wrong_proto="$(printf 'protocol=http\nhost=%s\n\n' "$CRED_HOST" | "$HELPER" get 2>&1)"
wrong_proto_rc=$?
assert_eq "0" "$wrong_proto_rc" "helper exits 0 for a protocol it will not answer (an erroring helper fails the whole git operation)"
assert_eq "" "$wrong_proto" "helper emits nothing for plain http, so a downgraded URL cannot collect the token"

store_out="$(printf 'protocol=https\nhost=%s\nusername=x-access-token\npassword=%s\n\n' "$CRED_HOST" "$ROTATED_TOKEN" | "$HELPER" store 2>&1)"
store_rc=$?
assert_eq "0" "$store_rc" "helper 'store' exits 0"
assert_eq "" "$store_out" "helper 'store' writes nothing anywhere, so no token is ever persisted by git's caching"

erase_out="$("$HELPER" erase </dev/null 2>&1)"
erase_rc=$?
assert_eq "0" "$erase_rc" "helper 'erase' exits 0"
assert_eq "" "$erase_out" "helper 'erase' is silent"

unknown_out="$("$HELPER" some-future-verb </dev/null 2>&1)"
unknown_rc=$?
assert_eq "0" "$unknown_rc" "helper exits 0 for an unknown operation, so a future git verb cannot take a session down"
assert_eq "" "$unknown_out" "helper emits nothing for an unknown operation"

# A CR in the token file would become part of the password and produce a 401
# that looks exactly like an expired token.
printf 'ghs-crlf-token-eeeeeeeeeeeeeeeeeeeeeeee\r\n' > "$SQUAD_GIT_TOKEN_FILE"
crlf_out="$(printf 'protocol=https\nhost=%s\n\n' "$CRED_HOST" | "$HELPER" get 2>&1 | tr -d '\n')"
assert_contains "$crlf_out" "=ghs-crlf-token-eeeeeeeeeeeeeeeeeeeeeeee" "a CRLF-terminated token file yields a password with no carriage return"
assert_not_contains "$crlf_out" "$(printf '\r')" "the helper's output carries no carriage return at all"

# An absent or empty token file is "no credential", not an error.
rm -f "$SQUAD_GIT_TOKEN_FILE"
missing_out="$(printf 'protocol=https\nhost=%s\n\n' "$CRED_HOST" | "$HELPER" get 2>&1)"
missing_rc=$?
assert_eq "0" "$missing_rc" "helper exits 0 when the token file is absent"
assert_eq "" "$missing_out" "helper emits nothing when the token file is absent"

: > "$SQUAD_GIT_TOKEN_FILE"
empty_out="$(printf 'protocol=https\nhost=%s\n\n' "$CRED_HOST" | "$HELPER" get 2>&1)"
assert_eq "" "$empty_out" "helper emits nothing when the token file is empty"

# ===========================================================================
# 9. `gh` sees the refreshed token
# ===========================================================================
# `gh` is a fresh process each time, so it WOULD honour a new token -- except
# that the entrypoint exported GH_TOKEN once at startup and an exported variable
# is frozen for the life of that shell. This is the gap squad_credential_refresh_env
# closes, and it is asserted by running a real child process and reading what it
# actually inherited.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf 'GH_TOKEN=%s\nGITHUB_TOKEN=%s\nCOPILOT_GITHUB_TOKEN=%s\n' \
  "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${COPILOT_GITHUB_TOKEN:-}"
GHEOF
chmod +x "${WORK}/bin/gh"
export PATH="${WORK}/bin:${PATH}"

export GH_TOKEN="$STALE_TOKEN"
export GITHUB_TOKEN="$STALE_TOKEN"
export COPILOT_GITHUB_TOKEN="copilot-plane-token-ffffffffffffffffffff"
squad_credential_write_token "$ROTATED_TOKEN"

before_refresh="$(gh whatever)"
assert_contains "$before_refresh" "GH_TOKEN=${STALE_TOKEN}" "CONTROL: without a refresh, a freshly spawned gh inherits the STALE token the shell exported at startup — the exact defect being fixed"

squad_credential_refresh_env
after_refresh="$(gh whatever)"
assert_contains "$after_refresh" "GH_TOKEN=${ROTATED_TOKEN}" "after squad_credential_refresh_env, a freshly spawned gh inherits the token currently in the FILE"
assert_contains "$after_refresh" "GITHUB_TOKEN=${ROTATED_TOKEN}" "GITHUB_TOKEN is refreshed alongside GH_TOKEN"
assert_contains "$after_refresh" "COPILOT_GITHUB_TOKEN=copilot-plane-token-ffffffffffffffffffff" "the Copilot credential plane is NOT overwritten by a git-token refresh — the two planes may legitimately hold different tokens"

rm -f "$SQUAD_GIT_TOKEN_FILE"
if squad_credential_refresh_env; then refresh_rc=0; else refresh_rc=1; fi
assert_eq "1" "$refresh_rc" "squad_credential_refresh_env reports failure when there is no token to read, instead of silently exporting an empty credential"
squad_credential_write_token "$ROTATED_TOKEN"

# ===========================================================================
# 10. Classification cannot collide the way this repository's last one did
# ===========================================================================
# A classifier here once matched the bare substring "429" and so read the hex of
# a correlation GUID as a rate-limit verdict. Every case below is a message a
# real remote emits.
assert_eq "auth" "$(squad_credential_classify_git_failure "remote: Invalid username or token. Password authentication is not supported.")" "classifier: GitHub's expired/invalid token message is a credential fault"
assert_eq "auth" "$(squad_credential_classify_git_failure "fatal: Authentication failed for 'https://github.com/o/r.git/'")" "classifier: git's own authentication failure is a credential fault"
assert_eq "auth" "$(squad_credential_classify_git_failure "fatal: could not read Username for 'https://github.com': terminal prompts disabled")" "classifier: a git that could not obtain a credential at all is a credential fault"
assert_eq "auth" "$(squad_credential_classify_git_failure "error: RPC failed; HTTP 403 curl 22 The requested URL returned error: 403")" "classifier: a 403 anchored to git's own wording is a credential fault"
assert_eq "auth" "$(squad_credential_classify_git_failure "remote: Write access to repository not granted.")" "classifier: an installation without write access is a credential fault"
assert_eq "auth" "$(squad_credential_classify_git_failure "gh: Bad credentials (HTTP 401)")" "classifier: gh's bad-credential message is a credential fault"

assert_eq "execution" "$(squad_credential_classify_git_failure "error: failed to push some refs to 'origin'; hint: Updates were rejected because the tip of your current branch is behind")" "classifier: a non-fast-forward rejection is NOT a credential fault — rotating a token would not fix it"
assert_eq "execution" "$(squad_credential_classify_git_failure "remote: error: GH006: Protected branch update failed for refs/heads/main.")" "classifier: a branch-protection rejection is NOT a credential fault"
assert_eq "execution" "$(squad_credential_classify_git_failure "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com")" "classifier: a DNS failure is NOT a credential fault"
assert_eq "execution" "$(squad_credential_classify_git_failure "error: server reported Correlation ID: 1b8f403c-9d2e-4a11-8f0e-7c5d401ab991 while processing the request")" "classifier: a message whose only '401'/'403' is inside a correlation GUID is NOT a credential fault — the exact collision that inverted this repository's previous classifier"
assert_eq "execution" "$(squad_credential_classify_git_failure "fatal: the remote end hung up unexpectedly")" "classifier: an unrecognised failure falls through to execution rather than sending an operator to rotate a healthy token"

# ===========================================================================
# 11. The credential exit code is a distinct, named constant
# ===========================================================================
assert_eq "77" "${SQUAD_EXIT_CREDENTIAL}" "the session's credential-failure exit code is 77 (EX_NOPERM), distinct from the 64/70/78 the entrypoint already uses so a control plane can tell 'rotate the token' from 'fix the deployment'"

test_summary
