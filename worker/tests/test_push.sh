#!/usr/bin/env bash
# Behavioural tests for worker/lib/squad-push.sh (issue #32).
#
# WHY THIS SUITE EXISTS AT ALL.
#
# The push logic used to live inline in worker/entrypoint.sh. Nothing under
# worker/tests/ sources entrypoint.sh, so it was logic no test could reach --
# and it shipped with the exact defect that sank PR #9 in this repository:
#
#     if ! git push ...; then
#       push_rc=$?          # <-- 0, ALWAYS. `$?` here is the status of the
#     fi                    #     NEGATION, which is 0 precisely when the
#                           #     command failed.
#
# The consequence was not cosmetic. The caller ended with `exit "$push_rc"`, so
# a push that git REFUSED would have exited 0 and the session would have been
# recorded as successful with nothing pushed. Case B below is the regression
# test for that, and case E is its control: it runs the OLD shape against the
# same refused push and shows it reporting success, which is what proves case B
# is observing behaviour rather than restating the implementation.
#
# Every failure below is a real refusal by real git -- a genuine non-fast-
# forward for the non-credential cases, and a real 401 from the smart-HTTP
# fixture for the credential ones. None of it is simulated.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
CRED_LIB_SRC="${WORKER_DIR}/lib/squad-credentials.sh"
PUSH_LIB_SRC="${WORKER_DIR}/lib/squad-push.sh"
HELPER_SRC="${WORKER_DIR}/lib/squad-git-credential-helper.sh"
SERVER_JS="${TEST_DIR}/lib/fake-git-https-server.js"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git openssl

echo "== squad-push.sh =="

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-push-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

export HOME="${WORK}/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
: >"$GIT_CONFIG_GLOBAL"

# shellcheck source=lib/squad-credentials.sh
source "$CRED_LIB_SRC"
# shellcheck source=lib/squad-push.sh
source "$PUSH_LIB_SRC"

git_quiet() { git -c advice.detachedHead=false "$@" >/dev/null 2>&1; }

# A bare remote plus a working copy whose branch is behind it, so a push is
# refused as a non-fast-forward: a REAL git refusal that has nothing to do with
# credentials. This is the shape a branch-ruleset refusal takes too -- both exit
# 1 and neither is fixable by re-reading a token.
make_rejecting_pair() {
  local base="$1"
  rm -rf "$base"; mkdir -p "$base"
  git_quiet init --bare "${base}/remote.git"

  git_quiet clone "${base}/remote.git" "${base}/seed"
  (
    cd "${base}/seed"
    git config user.email t@example.com; git config user.name t
    echo one >f; git add -A; git commit -qm one
    git push -q origin HEAD:refs/heads/work
  ) >/dev/null 2>&1

  # Advance the remote so the client below cannot fast-forward.
  (
    cd "${base}/seed"
    echo two >f; git add -A; git commit -qm two
    git push -q origin HEAD:refs/heads/work
  ) >/dev/null 2>&1

  git_quiet clone "${base}/remote.git" "${base}/client"
  (
    cd "${base}/client"
    git config user.email t@example.com; git config user.name t
    git checkout -q -B work origin/work~1
    echo divergent >f; git add -A; git commit -qm divergent
  ) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# A. a push that git accepts returns 0
# ---------------------------------------------------------------------------
A="${WORK}/a"
rm -rf "$A"; mkdir -p "$A"
git_quiet init --bare "${A}/remote.git"
git_quiet clone "${A}/remote.git" "${A}/client"
(
  cd "${A}/client"
  git config user.email t@example.com; git config user.name t
  git checkout -q -B work
  echo hello >f; git add -A; git commit -qm hello
) >/dev/null 2>&1
a_rc=0
( cd "${A}/client" && squad_push_branch work ) >/dev/null 2>&1 || a_rc=$?
assert_eq "0" "$a_rc" "a push the remote accepts returns 0"

a_remote_head="$(git --git-dir="${A}/remote.git" rev-parse refs/heads/work 2>/dev/null)"
a_local_head="$(git -C "${A}/client" rev-parse HEAD)"
assert_eq "$a_local_head" "$a_remote_head" "the branch actually landed on the remote, so the 0 above is evidence and not just an exit code"

# ---------------------------------------------------------------------------
# B. THE REGRESSION. A refusal that is NOT a credential fault must propagate a
#    NON-ZERO code. Under the PR #9 shape this returned 0.
# ---------------------------------------------------------------------------
B="${WORK}/b"
make_rejecting_pair "$B"
b_rc=0
b_out="$( cd "${B}/client" && squad_push_branch work 2>&1 )" || b_rc=$?
assert_ne "0" "$b_rc" "a push REFUSED by the remote for a non-credential reason returns non-zero -- under the PR #9 shape (\$? captured inside 'if ! git push') this returned 0 and the session was recorded as a success with nothing pushed"
assert_eq "1" "$b_rc" "it returns git's own exit code (1), not a substitute, so the caller can tell a ruleset refusal from an expired token (128)"
assert_contains "$b_out" "NOT a credential fault" "the operator is told this is not a credential problem, so nobody rotates a healthy token"

b_remote_head="$(git --git-dir="${B}/remote.git" rev-parse refs/heads/work)"
b_local_head="$(git -C "${B}/client" rev-parse HEAD)"
assert_ne "$b_local_head" "$b_remote_head" "nothing was pushed, which is what makes returning 0 here a lie rather than a rounding error"

# ---------------------------------------------------------------------------
# C. CONTROL for B. The pre-fix shape, run against the SAME refused push, is
#    shown reporting success. Without this, B could pass for the wrong reason.
# ---------------------------------------------------------------------------
legacy_push_branch() {
  local branch="$1" push_log push_rc
  push_log="$(mktemp)"
  push_rc=0
  # The original shape, reproduced verbatim.
  if ! git push --set-upstream origin "$branch" >"$push_log" 2>&1; then
    push_rc=$?
    rm -f "$push_log"
    return "$push_rc"
  fi
  rm -f "$push_log"
  return 0
}
C="${WORK}/c"
make_rejecting_pair "$C"
c_rc=0
( cd "${C}/client" && legacy_push_branch work ) >/dev/null 2>&1 || c_rc=$?
assert_eq "0" "$c_rc" "CONTROL: the pre-fix shape returns 0 for the very same refused push -- so case B distinguishes a real propagated failure from the characters of one"

c_remote_head="$(git --git-dir="${C}/remote.git" rev-parse refs/heads/work)"
c_local_head="$(git -C "${C}/client" rev-parse HEAD)"
assert_ne "$c_local_head" "$c_remote_head" "CONTROL: and it returned 0 while the remote never moved"

# ---------------------------------------------------------------------------
# D + E. Credential failures, against the real smart-HTTP fixture.
# ---------------------------------------------------------------------------
BACKEND=""
for candidate in /usr/lib/git-core/git-http-backend /usr/libexec/git-core/git-http-backend; do
  [[ -x "$candidate" ]] && { BACKEND="$candidate"; break; }
done
if [[ -z "$BACKEND" ]]; then
  echo "SKIP: git-http-backend not found; credential-refusal cases need a real smart-HTTP remote"
else
  SRV="${WORK}/srv"
  mkdir -p "${SRV}/repos"
  git_quiet init --bare "${SRV}/repos/proj.git"
  git --git-dir="${SRV}/repos/proj.git" config http.receivepack true

  openssl req -x509 -newkey rsa:2048 -nodes -keyout "${SRV}/key.pem" -out "${SRV}/cert.pem" \
    -days 2 -subj "/CN=localhost" >/dev/null 2>&1

  ACCEPTED="${SRV}/accepted-token"
  AUTH_LOG="${SRV}/auth.log"
  printf 'ghs-good-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >"$ACCEPTED"

  node "$SERVER_JS" --root "${SRV}/repos" --cert "${SRV}/cert.pem" --key "${SRV}/key.pem" \
    --token-file "$ACCEPTED" --auth-log "$AUTH_LOG" >"${SRV}/server.out" 2>&1 &
  SERVER_PID=$!
  PORT=""
  for _ in $(seq 1 100); do
    PORT="$(sed -n 's/^LISTENING //p' "${SRV}/server.out" | head -n 1)"
    [[ -n "$PORT" ]] && break
    sleep 0.1
  done

  if [[ -z "$PORT" ]]; then
    echo "SKIP: the smart-HTTP fixture did not start"
  else
    export GIT_SSL_NO_VERIFY=true
    export SQUAD_GIT_TOKEN_FILE="${WORK}/session-token"
    export SQUAD_GIT_CREDENTIAL_HOST="localhost:${PORT}"
    # Staged and chmod +x'd exactly as the Dockerfile does, so the suite runs
    # the bytes that ship. A helper git cannot execute yields no credential at
    # all, which looks like an auth failure and would let case D pass for
    # entirely the wrong reason.
    mkdir -p "${WORK}/bin"
    cp "$HELPER_SRC" "${WORK}/bin/squad-git-credential-helper.sh"
    chmod +x "${WORK}/bin/squad-git-credential-helper.sh"
    export SQUAD_GIT_CREDENTIAL_HELPER="${WORK}/bin/squad-git-credential-helper.sh"

    squad_credential_write_token "$(cat "$ACCEPTED")"
    squad_credential_install_helper >/dev/null 2>&1

    D="${WORK}/d"
    mkdir -p "$D"
    (
      cd "$D"
      git init -q
      git config user.email t@example.com; git config user.name t
      git remote add origin "https://localhost:${PORT}/proj.git"
      git checkout -q -B work
      echo d >f; git add -A; git commit -qm d
    ) >/dev/null 2>&1

    # The session's token stops being accepted mid-run: the server now wants a
    # different one. This is expiry, reproduced.
    printf 'ghs-rotated-bbbbbbbbbbbbbbbbbbbbbbbbbbbb' >"$ACCEPTED"

    # D. refused, and STAYS refused because nothing refreshes the file.
    d_rc=0
    d_out="$( cd "$D" && squad_push_branch work 2>&1 )" || d_rc=$?
    assert_eq "$SQUAD_EXIT_CREDENTIAL" "$d_rc" "a push refused because the CREDENTIAL was rejected, and still refused after the token file is re-read, returns the credential exit code (${SQUAD_EXIT_CREDENTIAL}) rather than an anonymous non-zero"
    assert_contains "$d_out" "CREDENTIAL was refused" "the operator is told the credential is what failed, not that the agent's work failed"

    # E. the mitigation: the control plane refreshes ONLY the token file
    # between the two attempts, and the retry inside squad_push_branch picks it
    # up with no re-clone and no git config change.
    # `git push --set-upstream` legitimately writes branch.*.remote and
    # branch.*.merge, so a whole-config comparison would fail for a reason that
    # has nothing to do with credentials. The claim being tested is narrower and
    # is the one that matters: the retry did not rewrite any CREDENTIAL wiring.
    # The old design could only recover by rewriting url.<...>.insteadOf; this
    # one recovers because the helper re-read a file.
    cred_config_before="$(cd "$D" && git config --list 2>/dev/null | grep -E '^(credential|url)\.' | sort)"
    (
      cd "$D"
      # Simulate the control plane rewriting the token file while the push is
      # being retried, by refreshing it before the call.
      squad_credential_write_token "$(cat "$ACCEPTED")"
    )
    e_rc=0
    e_out="$( cd "$D" && squad_push_branch work 2>&1 )" || e_rc=$?
    cred_config_after="$(cd "$D" && git config --list 2>/dev/null | grep -E '^(credential|url)\.' | sort)"

    assert_eq "0" "$e_rc" "once the token FILE holds a token the remote accepts, the next push succeeds in the same working copy with no re-clone"
    assert_eq "$cred_config_before" "$cred_config_after" "and it succeeded without rewriting ANY credential or url configuration -- the token file is the only thing that moved, which is the whole point of the helper"

    e_remote="$(git --git-dir="${SRV}/repos/proj.git" rev-parse refs/heads/work 2>/dev/null)"
    e_local="$(git -C "$D" rev-parse HEAD)"
    assert_eq "$e_local" "$e_remote" "the work actually landed on the remote, so the 0 is evidence"
    assert_contains "$(cat "$AUTH_LOG")" "PRESENTED x-access-token:ghs-rotated-bbbbbbbbbbbbbbbbbbbbbbbbbbbb" "the successful push presented the REFRESHED token, proving the helper re-read the file rather than reusing anything cached"
  fi
fi

test_summary
