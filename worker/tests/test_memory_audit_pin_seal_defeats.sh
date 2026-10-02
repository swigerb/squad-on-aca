#!/usr/bin/env bash
# Issue #113 (follow-up), R-CI split: the security review's findings 1-4
# against the UNTRACKED half of the seal (`.git/info/exclude`), moved out of
# test_memory_audit_pin_publication.sh.
#
# Security's re-review (.squad/decisions/inbox/security-pin-seal-rereview.md,
# finding R-CI) measured the whole original suite (every scenario below, plus
# the two real-SDK 1100-call loops that moved to
# test_memory_audit_pin_rotation.sh) at 112s / 147s against run-tests.sh's
# hard 120s per-suite kill (worker/tests/run-tests.sh:~59), with
# .github/workflows/worker-tests.yml failing the job on ANY skip. Removing
# the two real-SDK loops alone left the remainder (findings 1-9, the hooks,
# and the wrapper gate) still measuring ~117s on this host -- too close to
# the limit once a slower CI runner's ~1.3x factor (the ratio security's own
# two hosts showed) is applied. This file and its sibling
# test_memory_audit_pin_hooks.sh split that remainder roughly in half so
# EACH suite (run-tests.sh times every test_*.sh file independently) has
# real margin, not just the rotation suite.
#
# See test_memory_audit_pin_publication.sh's header for the full picture of
# what this fix does and does not guarantee, and
# test_memory_audit_pin_hooks.sh for the push-backstop/hook/wrapper half of
# the security findings. This file proves only the untracked-seal DEFEAT
# vectors and their detection -- none of it needs the real squad-sdk or a
# git remote, which is also why it is fast:
#
#   e1. Finding 1: `git add -f <path>` on the untracked pin is refused by the
#       worker-generated pre-commit hook, and is a governance violation.
#   e2. Finding 1: `git add -f .squad` (the directory, not just the file).
#   e3. Finding 2: a `.gitignore` negation added mid-session, then a plain
#       `git add -A` -- no flag at all -- is still caught.
#   e3b. A negation added and then removed before verify is still caught
#        (the in-session sampler's sticky mask, not a point-in-time check).
#   e3c. The TRACKED seal's equivalent: --skip-worktree cleared and restored.
#   e4b. The pin replaced by the SDK's own default (what ensureInitialized()
#        writes after a delete) is classified as re-created and re-pinned.
#   e4c. For the TRACKED seal, deleting the pin is a violation (it can only
#        be deliberate: `git clean` cannot remove a tracked file).
#   e5. Finding 4: --skip-worktree AND --assume-unchanged (set separately)
#       make `ls-files -v` print a lowercase `s` -- a STRONGER seal, not a
#       broken one -- and the push backstop must still accept it.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SQUAD_POLICY_SH="${WORKER_DIR}/lib/squad-policy.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum

echo "== memory-audit-pin seal defeats, untracked half (issue #113 follow-up, R-CI split) =="

[[ -f "$SQUAD_POLICY_SH" ]] || { echo "FAIL: worker/lib/squad-policy.sh is missing"; exit 1; }

# Same posture as test_governance_guard.sh / test_memory_audit_pin_publication.sh:
# the preventive half of this fix is POSIX mode bits (squad_policy_harden's
# `chmod -R a-w`), which root ignores. A run as root cannot answer "is the
# seal real?", so it reports a skip rather than a pass.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_memory_audit_pin_seal_defeats.sh — running as root, mode bits are not enforced against uid 0"
  exit 77
fi

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-pin-seal-defeats-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global user.name "Test" >/dev/null 2>&1 || true
git config --global user.email "test@example.com" >/dev/null 2>&1 || true

git_quiet() { git -c advice.detachedHead=false "$@" >/dev/null 2>&1; }

# A plain (no remote) repository. Identical to
# test_memory_audit_pin_publication.sh's make_repo. (Duplicated rather than
# shared, so each suite stays independently runnable.)
make_repo() {
  local repo="$1" tracked="$2"
  rm -rf "$repo"; mkdir -p "$repo"
  git_quiet init "$repo"
  (
    cd "$repo"
    mkdir -p .squad/policies src
    echo "security policy" >.squad/policies/security.md
    echo "original work" >src/app.js
    if [[ "$tracked" == 1 ]]; then
      mkdir -p .squad/memory
      printf '{\n  "policy": {\n    "auditMaxBytes": 1048576,\n    "auditMaxArchives": 3\n  }\n}\n' >.squad/memory/config.json
    fi
    git add -A
    git commit -q -m baseline
  ) >/dev/null 2>&1
}

# Run one scenario in a subshell so a squad_policy_abort (exit 78) is captured
# instead of taking the whole suite down with it. Same idiom as
# test_governance_guard.sh's / test_memory_audit_pin_publication.sh's
# scenario()/policy_scenario().
#   policy_scenario <repo> <state-dir> <shell-body>
policy_scenario() {
  local repo="$1" state="$2" body="$3"
  (
    export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
    export SQUAD_POLICY_STATE_DIR="$state"
    export SQUAD_POLICY_RESOLVER="${WORKER_DIR}/lib/agent-policy.js"
    # shellcheck source=/dev/null
    source "$SQUAD_POLICY_SH"
    eval "$body"
  ) 2>&1
}

PIN=".squad/memory/config.json"
STATE_E="${WORK}/state-e"

echo "-- untracked-seal defeats and re-pin --"

# e1. Finding 1: UNTRACKED fixture, `git add -f <path>`. The pre-commit hook
#     refuses an ordinary commit; verify names the break.
E1="${WORK}/repo-e1"
make_repo "$E1" 0
e1_out="$(policy_scenario "$E1" "${STATE_E}1" '
  squad_policy_harden "'"$E1"'"
  git -C "'"$E1"'" add -f -- '"$PIN"'
  git -C "'"$E1"'" commit -q -m "agent: commit" >/dev/null 2>&1; echo "COMMIT_RC=$?"
  git -C "'"$E1"'" rev-parse -q --verify "HEAD:'"$PIN"'" >/dev/null 2>&1; echo "HEAD_HAS_PIN_RC=$?"
  squad_policy_verify "'"$E1"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$e1_out" "COMMIT_RC=1" "(e1) the worker-generated pre-commit hook refuses a commit carrying the force-added untracked pin"
assert_contains "$e1_out" "HEAD_HAS_PIN_RC=1" "(e1) HEAD does not carry the pin"
assert_contains "$e1_out" "VERIFY_RC=1" "(e1) 'git add -f <pin>' on the UNTRACKED fixture is a governance violation"
assert_contains "$e1_out" "is staged in the index" "(e1) verify names the force-add as a seal break"

# e2. Finding 1: `git add -f .squad`.
E2="${WORK}/repo-e2"
make_repo "$E2" 0
e2_out="$(policy_scenario "$E2" "${STATE_E}2" '
  squad_policy_harden "'"$E2"'"
  git -C "'"$E2"'" add -f -- .squad
  git -C "'"$E2"'" commit -q -m "agent: commit .squad" >/dev/null 2>&1; echo "COMMIT_RC=$?"
  squad_policy_verify "'"$E2"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$e2_out" "COMMIT_RC=1" "(e2) the pre-commit hook refuses after 'git add -f .squad'"
assert_contains "$e2_out" "VERIFY_RC=1" "(e2) 'git add -f .squad' on the UNTRACKED fixture is a governance violation"
assert_contains "$e2_out" "seal broken" "(e2) verify names it as a seal break"

# e3. Finding 2: a `.gitignore` negation added MID-SESSION, then a plain
#     `git add -A` -- no flag at all.
E3="${WORK}/repo-e3"
make_repo "$E3" 0
e3_out="$(policy_scenario "$E3" "${STATE_E}3" '
  squad_policy_harden "'"$E3"'"
  printf "!/.squad/memory/config.json\n" >"'"$E3"'/.gitignore"
  git -C "'"$E3"'" add -A
  git -C "'"$E3"'" ls-files -s -- '"$PIN"' | grep -q . && echo STAGED=1 || echo STAGED=0
  git -C "'"$E3"'" commit -q -m "agent: add -A" >/dev/null 2>&1; echo "COMMIT_RC=$?"
  squad_policy_verify "'"$E3"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$e3_out" "STAGED=1" "(e3) precondition: the mid-session .gitignore negation really does let plain 'git add -A' stage the pin (the hole security found)"
assert_contains "$e3_out" "COMMIT_RC=1" "(e3) the pre-commit hook refuses that commit"
assert_contains "$e3_out" "VERIFY_RC=1" "(e3) a mid-session .gitignore negation is a governance violation"
assert_contains "$e3_out" "no longer ignored" "(e3) verify names the negation"

# e3b. A negation that is added and then REMOVED before verify is still a
#      violation: the sampler's sticky mask saw it (point-in-time is not enough).
E3B="${WORK}/repo-e3b"
make_repo "$E3B" 0
e3b_out="$(policy_scenario "$E3B" "${STATE_E}3b" '
  export SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
  squad_policy_harden "'"$E3B"'"
  printf "!memory/config.json\n" >"'"$E3B"'/.squad/.gitignore"
  sleep 1.5
  rm -f "'"$E3B"'/.squad/.gitignore"
  squad_policy_verify "'"$E3B"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$e3b_out" "VERIFY_RC=1" "(e3b) a nested .gitignore negation undone before verify is still caught (in-session sampler)"
assert_contains "$e3b_out" "no longer ignored" "(e3b) and named"

# e3c. Same for the TRACKED seal: --skip-worktree cleared, then restored.
E3C="${WORK}/repo-e3c"
make_repo "$E3C" 1
e3c_out="$(policy_scenario "$E3C" "${STATE_E}3c" '
  export SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
  squad_policy_harden "'"$E3C"'"
  git -C "'"$E3C"'" update-index --no-skip-worktree -- '"$PIN"'
  sleep 1.5
  git -C "'"$E3C"'" update-index --skip-worktree -- '"$PIN"'
  squad_policy_verify "'"$E3C"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$e3c_out" "VERIFY_RC=1" "(e3c) clearing --skip-worktree and restoring it before verify is still caught"

# e4b. The pin replaced by the SDK's own default (what ensureInitialized()
#      writes after a delete) is classified as re-created and re-pinned.
E4B="${WORK}/repo-e4b"
make_repo "$E4B" 0
e4b_out="$(policy_scenario "$E4B" "${STATE_E}4b" '
  export SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
  squad_policy_harden "'"$E4B"'"
  rm -f "'"$E4B"'/'"$PIN"'"
  printf "%s" "$SQUAD_POLICY_SDK_DEFAULT_MEMORY_CONFIG" >"'"$E4B"'/'"$PIN"'"
  sleep 1.5
  grep -q "\"auditMaxBytes\": 0" "'"$E4B"'/'"$PIN"'" && echo REPINNED=1 || echo REPINNED=0
  squad_policy_verify "'"$E4B"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$e4b_out" "REPINNED=1" "(e4b) an SDK-recreated default config.json is re-pinned by the sampler"
assert_contains "$e4b_out" "VERIFY_RC=0" "(e4b) and reported, not a violation (untracked seal)"

# e4c. For the TRACKED seal, deleting the pin is a violation (it can only be
#      deliberate: `git clean` cannot remove a tracked file).
E4C="${WORK}/repo-e4c"
make_repo "$E4C" 1
e4c_out="$(policy_scenario "$E4C" "${STATE_E}4c" '
  export SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
  squad_policy_harden "'"$E4C"'"
  rm -f "'"$E4C"'/'"$PIN"'"
  sleep 1.5
  [[ -f "'"$E4C"'/'"$PIN"'" ]] && echo RESTORED=1 || echo RESTORED=0
  squad_policy_verify "'"$E4C"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$e4c_out" "RESTORED=1" "(e4c) a deleted TRACKED pin is restored by the sampler"
assert_contains "$e4c_out" "VERIFY_RC=1" "(e4c) and the deletion is a violation"

# e5. Finding 4: --skip-worktree AND --assume-unchanged (set separately) make
#     `ls-files -v` print a LOWERCASE `s`. That is a stronger seal, not a
#     broken one: verify must pass and the push backstop must allow it.
E5="${WORK}/repo-e5"
make_repo "$E5" 1
e5_out="$(policy_scenario "$E5" "${STATE_E}5" '
  squad_policy_harden "'"$E5"'"
  git -C "'"$E5"'" update-index --assume-unchanged -- '"$PIN"'
  echo "LSV=$(git -C "'"$E5"'" ls-files -v -- '"$PIN"' | cut -c1)"
  squad_policy_assert_pin_unpublished "'"$E5"'"; echo "ASSERT_RC=$?"
  squad_policy_verify "'"$E5"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$e5_out" "LSV=s" "(e5) precondition: both flags set gives a lowercase 's' tag"
assert_contains "$e5_out" "ASSERT_RC=0" "(e5) the push backstop accepts the lowercase 's' seal"
assert_contains "$e5_out" "VERIFY_RC=0" "(e5) verify does not report a stronger seal as broken"
assert_not_contains "$e5_out" "seal broken" "(e5) no false 'seal broken'"

test_summary
