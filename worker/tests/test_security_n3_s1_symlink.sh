#!/usr/bin/env bash
# Security review S1 (re-review: NOT CLOSED): a governance directory that is a
# symbolic link must not silently lose detection.
#
# On real Linux, `find <symlink-to-dir> -type f` (no -L / trailing slash)
# returns ZERO files, so the manifest recorded only `dir <path>` and nothing
# under it was ever hashed. The previous conclusion that this was "already
# handled" came from a Windows host where MSYS `ln -s` silently COPIES.
#
# Decision: REFUSE. A governance path that is (or contains) a symlink aborts
# harden with 78 before the agent runs; one planted mid-session is a
# violation at verify. Simplest, fail-closed, and no `find -L` loop/escape
# semantics to get right.
#
# This suite needs REAL symlinks. If the filesystem cannot make one (MSYS
# without Developer Mode, some network mounts), it SKIPS LOUDLY (77) -- it must
# never pass on a fixture that was not created. Run it on Linux/WSL for the
# authoritative proof.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${SQUAD_POLICY_LIB_UNDER_TEST:-${WORKER_DIR}/lib/squad-policy.sh}"
RESOLVER="${WORKER_DIR}/lib/agent-policy.js"

TEST_TMP_ROOT="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-s1-symlink-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'chmod -R u+w "$TEST_TMP_ROOT" 2>/dev/null; rm -rf "$TEST_TMP_ROOT"' EXIT INT TERM

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum diff stat find

echo "== security S1: symlinked governance paths are refused, not silently unhashed =="

if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_security_n3_s1_symlink.sh — running as root, mode bits are not enforced against uid 0"
  exit 77
fi

# Ask MSYS for a native symlink (fails instead of copying when it cannot).
export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"

probe_dir="${TEST_TMP_ROOT}/probe"
mkdir -p "${probe_dir}/target"
printf 'x\n' >"${probe_dir}/target/f"
ln -s "${probe_dir}/target" "${probe_dir}/link" 2>/dev/null || true
if [[ ! -L "${probe_dir}/link" ]]; then
  echo "##############################################################################"
  echo "SKIP: test_security_n3_s1_symlink.sh -- this filesystem cannot create a real"
  echo "      symbolic link (ln -s copied or failed). S1 is NOT verified on this host."
  echo "      Run on Linux/WSL:  wsl -e bash -lc 'bash worker/tests/test_security_n3_s1_symlink.sh'"
  echo "##############################################################################"
  exit 77
fi
echo "platform: $(uname -s) $(uname -r); $(find --version 2>/dev/null | head -n1)"

export GIT_CONFIG_GLOBAL="${TEST_TMP_ROOT}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global core.autocrlf false >/dev/null 2>&1 || true
git config --global core.symlinks true >/dev/null 2>&1 || true

scenario() {
  local repo="$1" state="$2" body="$3"
  (
    export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
    export SQUAD_POLICY_STATE_DIR="$state"
    export SQUAD_POLICY_RESOLVER="$RESOLVER"
    export REPO="$repo" STATE="$state"
    # shellcheck source=/dev/null
    source "$LIB"
    eval "$body"
  ) 2>&1
}

make_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "${repo}/.squad/identity" "${repo}/.squad/policies" "${repo}/src"
  printf 'original identity\n' >"${repo}/.squad/identity/identity.md"
  printf 'original policy\n'   >"${repo}/.squad/policies/security.md"
  printf 'work\n'              >"${repo}/src/app.js"
}

# ---------------------------------------------------------------------------
# The reviewer's evidence, re-established on this host: find does not
# descend into a symlinked directory.
# ---------------------------------------------------------------------------
echo "-- evidence: find <symlink-dir> -type f lists nothing --"
assert_eq "0" "$(find "${probe_dir}/link" -type f | wc -l | tr -d ' ')" \
  "on this platform find <symlink-dir> -type f returns zero files (why the old manifest silently lost them)"

# ---------------------------------------------------------------------------
# Harden REFUSES a repo whose governance directory is a symlink.
# ---------------------------------------------------------------------------
echo "-- harden refuses a symlinked governance directory --"
REPO="${TEST_TMP_ROOT}/repo-link"; STATE="${TEST_TMP_ROOT}/state-link"; make_repo "$REPO"
real_agents="${TEST_TMP_ROOT}/real-agents"
mkdir -p "${real_agents}/security"
printf 'original charter\n' >"${real_agents}/security/charter.md"
ln -s "$real_agents" "${REPO}/.squad/agents"
( cd "$REPO" && git init --quiet . && git add -A && git commit --quiet -m baseline )
assert_eq "yes" "$([[ -L "${REPO}/.squad/agents" ]] && echo yes || echo no)" "fixture: .squad/agents really is a symlink"

out="$(scenario "$REPO" "$STATE" 'squad_policy_harden "$REPO"; echo "HARDEN_RC=$?"')"
rc=$?
assert_eq "78" "$rc" "S1: harden with a symlinked .squad/agents ABORTS with 78"
assert_contains "$out" "Governance path(s) are symbolic links" "S1: the refusal says why"
assert_contains "$out" ".squad/agents" "S1: the symlinked path is named"
assert_not_contains "$out" "HARDEN_RC=" "S1: harden never returned a verdict (the agent would not run)"

# A symlinked FILE inside a real governance directory is refused too.
REPO="${TEST_TMP_ROOT}/repo-filelink"; STATE="${TEST_TMP_ROOT}/state-filelink"; make_repo "$REPO"
printf 'outside\n' >"${TEST_TMP_ROOT}/outside.md"
ln -s "${TEST_TMP_ROOT}/outside.md" "${REPO}/.squad/policies/linked.md"
( cd "$REPO" && git init --quiet . && git add -A && git commit --quiet -m baseline )
out="$(scenario "$REPO" "$STATE" 'squad_policy_harden "$REPO"; echo "HARDEN_RC=$?"')"
rc=$?
assert_eq "78" "$rc" "S1: a symlinked file inside a governance directory ABORTS harden with 78"
assert_contains "$out" ".squad/policies/linked.md" "S1: the symlinked file is named"

# ---------------------------------------------------------------------------
# A symlink planted MID-SESSION is a verify violation, not a blind spot.
# ---------------------------------------------------------------------------
echo "-- a symlink planted mid-session is caught at verify --"
REPO="${TEST_TMP_ROOT}/repo-mid"; STATE="${TEST_TMP_ROOT}/state-mid"; make_repo "$REPO"
( cd "$REPO" && git init --quiet . && git add -A && git commit --quiet -m baseline )
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  bash -c "chmod u+w \"$REPO/.squad/policies\"; ln -s /etc/hostname \"$REPO/.squad/policies/evil.md\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1" "S1: a symlink planted inside a governance directory mid-session fails verification"
assert_contains "$out" ".squad/policies/evil.md" "S1: the planted symlink is named"

# Control: an ordinary repo still hardens and verifies clean on this platform.
REPO="${TEST_TMP_ROOT}/repo-ok"; STATE="${TEST_TMP_ROOT}/state-ok"; make_repo "$REPO"
( cd "$REPO" && git init --quiet . && git add -A && git commit --quiet -m baseline )
out="$(scenario "$REPO" "$STATE" 'squad_policy_harden "$REPO" >/dev/null; squad_policy_verify "$REPO"; echo "VERIFY_RC=$?"')"
assert_contains "$out" "VERIFY_RC=0" "control: a repo with no symlinks hardens and verifies clean"

test_summary
