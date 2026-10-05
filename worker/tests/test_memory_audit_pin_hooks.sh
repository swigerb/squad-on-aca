#!/usr/bin/env bash
# Issue #113 (follow-up), R-CI split: the security review's findings against
# repo_dir validation, fail-closed semantics, the pre-commit/pre-push hooks,
# squad_push_branch's push backstop, and worker/squad-agent's per-iteration
# wrapper gate -- moved out of test_memory_audit_pin_publication.sh.
#
# See test_memory_audit_pin_seal_defeats.sh's header for the R-CI timing
# background (security's re-review measured the original combined suite at
# 112s / 147s against run-tests.sh's hard 120s per-suite kill). This file is
# the second half of that split: the ENFORCEMENT surface (hooks, the push
# backstop, the wrapper) rather than the DEFEAT vectors against the seal
# itself. Like its sibling, it needs no real squad-sdk.
#
#   e6. Finding 7: repo_dir must be the checkout ROOT -- a subdirectory is
#       refused (78), not silently checked against cwd-relative paths.
#   e7. Finding 8: fail closed in a git checkout git cannot inspect, and a
#       no-op (nothing to publish) only where there truly is no .git at all.
#   e8. Findings 1 and 6: a pin committed past the pre-commit hook
#       (--no-verify) is refused by the pre-push hook on a direct
#       `git push`, and by squad_push_branch itself (78) -- nothing reaches
#       the remote.
#   e8b. R5: a 3-commit branch where ONLY THE MIDDLE commit carries the pin
#        (the tip has since undone it) is still refused -- the pre-push hook
#        and squad_push_branch must walk the full commit range being
#        published (base..tip), not just the tip, or this mid-range commit
#        would reach the remote undetected.
#   e9. worker/squad-agent (the per-iteration wrapper watch/loop/triage
#       spawn) re-checks the seal before EVERY iteration, refusing (78) to
#       start one on a broken seal, and never execs the agent when it does.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SQUAD_POLICY_SH="${WORKER_DIR}/lib/squad-policy.sh"
CRED_LIB_SRC="${WORKER_DIR}/lib/squad-credentials.sh"
PUSH_LIB_SRC="${WORKER_DIR}/lib/squad-push.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum

echo "== memory-audit-pin hooks, push backstop, wrapper gate (issue #113 follow-up, R-CI split) =="

[[ -f "$SQUAD_POLICY_SH" ]] || { echo "FAIL: worker/lib/squad-policy.sh is missing"; exit 1; }

# Same posture as test_governance_guard.sh / test_memory_audit_pin_publication.sh:
# the preventive half of this fix is POSIX mode bits (squad_policy_harden's
# `chmod -R a-w`), which root ignores. A run as root cannot answer "is the
# seal real?", so it reports a skip rather than a pass.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_memory_audit_pin_hooks.sh — running as root, mode bits are not enforced against uid 0"
  exit 77
fi

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-pin-hooks-test.XXXXXXXXXXXX")" || {
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

# A bare remote plus a working clone, seeded with one baseline commit.
# Identical to test_memory_audit_pin_publication.sh's make_remote_pair.
# (Duplicated rather than shared, so each suite stays independently
# runnable.)
make_remote_pair() {
  local base="$1" tracked="$2"
  rm -rf "$base"; mkdir -p "$base"
  git_quiet init --bare "${base}/remote.git"
  git_quiet clone "${base}/remote.git" "${base}/seed"
  (
    cd "${base}/seed"
    mkdir -p .squad/policies src
    echo "security policy" >.squad/policies/security.md
    echo "original work" >src/app.js
    if [[ "$tracked" == 1 ]]; then
      mkdir -p .squad/memory
      printf '{\n  "policy": {\n    "auditMaxBytes": 1048576,\n    "auditMaxArchives": 3\n  }\n}\n' >.squad/memory/config.json
    fi
    git add -A
    git commit -q -m baseline
    git push -q origin HEAD:refs/heads/main
  ) >/dev/null 2>&1
  git_quiet clone "${base}/remote.git" "${base}/client"
  git_quiet -C "${base}/client" checkout main
}

# A plain (no remote) repository. Identical to
# test_memory_audit_pin_publication.sh's make_repo.
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

echo "-- repo_dir validation, fail-closed, hooks, push backstop, wrapper gate --"

# e6. Finding 7: repo_dir must be the checkout ROOT -- a subdirectory is refused.
E6="${WORK}/repo-e6"
make_repo "$E6" 0
mkdir -p "${E6}/sub"
e6_rc=0
e6_out="$(policy_scenario "${E6}/sub" "${STATE_E}6" 'squad_policy_harden "'"$E6"'/sub"')" || e6_rc=$?
assert_eq "78" "$e6_rc" "(e6) hardening a subdirectory of a checkout refuses (78) instead of checking cwd-relative paths"
assert_contains "$e6_out" "not the root of its git checkout" "(e6) and says why"

# e7. Finding 8: fail closed in a git checkout, no-op only without one.
E7NOGIT="${WORK}/nogit-e7"; mkdir -p "$E7NOGIT"
E7BROKEN="${WORK}/brokengit-e7"; mkdir -p "$E7BROKEN"; echo "not a gitdir" >"${E7BROKEN}/.git"
E7="${WORK}/repo-e7"; make_repo "$E7" 0
e7_out="$(policy_scenario "$E7" "${STATE_E}7" '
  SQUAD_POLICY_PIN_SEAL_MODE=""; SQUAD_POLICY_PIN_REPO_DIR=""
  squad_policy_assert_pin_unpublished "'"$E7NOGIT"'"; echo "NOGIT_RC=$?"
  squad_policy_assert_pin_unpublished "'"$E7BROKEN"'"; echo "BROKEN_RC=$?"
  squad_policy_assert_pin_unpublished "'"$E7"'"; echo "NOSEAL_RC=$?"
')"
assert_contains "$e7_out" "NOGIT_RC=0" "(e7) no .git at all: nothing to publish, the backstop is a no-op"
assert_contains "$e7_out" "BROKEN_RC=1" "(e7) a .git git cannot inspect: the backstop refuses"
assert_contains "$e7_out" "NOSEAL_RC=1" "(e7) a git checkout with no recorded seal: the backstop refuses (was: allow when base capture failed)"
e7h_rc=0
policy_scenario "$E7BROKEN" "${STATE_E}7h" 'squad_policy_harden "'"$E7BROKEN"'"' >/dev/null || e7h_rc=$?
assert_eq "78" "$e7h_rc" "(e7) hardening a directory whose .git git cannot inspect refuses (78)"

# e8. Findings 1 and 6: a pin committed past the pre-commit hook (--no-verify)
#     is refused by the pre-push hook on a direct `git push`, and by
#     squad_push_branch itself (78) -- nothing reaches the remote.
E8="${WORK}/scenario-e8"
make_remote_pair "$E8" 1
e8_out="$(policy_scenario "${E8}/client" "${STATE_E}8" '
  source "'"$CRED_LIB_SRC"'"
  source "'"$PUSH_LIB_SRC"'"
  cd "'"$E8"'/client"
  squad_policy_harden "$(pwd)"; echo "HARDEN_RC=$?"
  git update-index --no-skip-worktree -- '"$PIN"'
  git add -f -- '"$PIN"'
  git commit --no-verify -q -m "agent: pin"; echo "COMMIT_RC=$?"
  git push -q origin HEAD:refs/heads/hook-test >/dev/null 2>&1; echo "RAW_PUSH_RC=$?"
  git checkout -q -B squad/e8
  squad_push_branch squad/e8; echo "PUSH_BRANCH_RC=$?"
')"
assert_contains "$e8_out" "HARDEN_RC=0" "(e8) hardening succeeds"
assert_contains "$e8_out" "COMMIT_RC=0" "(e8) precondition: --no-verify commits the pin past the pre-commit hook"
assert_not_contains "$e8_out" "RAW_PUSH_RC=0" "(e8) the worker-generated pre-push hook refuses a direct 'git push' of a commit carrying the pin"
assert_contains "$e8_out" "PUSH_BRANCH_RC=78" "(e8) squad_push_branch refuses (78) to push a branch carrying the pin (finding 6: the gate is on the push itself)"
assert_eq "none" "$(git --git-dir="${E8}/remote.git" rev-parse -q --verify refs/heads/hook-test 2>/dev/null || echo none)" \
  "(e8) the raw push left nothing on the remote"
assert_eq "none" "$(git --git-dir="${E8}/remote.git" rev-parse -q --verify refs/heads/squad/e8 2>/dev/null || echo none)" \
  "(e8) squad_push_branch left nothing on the remote"

# e8b. R5: a 3-commit branch where ONLY THE MIDDLE commit carries the pin
#      (the tip has since undone it) is still refused. A tip-only check
#      (the pre-R5 behaviour) would see a clean tip and let this through;
#      the pre-push hook and squad_push_branch must walk the full commit
#      range being published (base..tip), not just the tip, to catch it.
#      Builds its own remote directly (bare init + `git remote add`) rather
#      than make_remote_pair's seed-clone-push-clone round trip: this suite
#      is R-CI budget-constrained (see this file's header), and this
#      scenario doesn't need seeded remote content.
E8B="${WORK}/scenario-e8b"
make_repo "$E8B" 1
git_quiet init --bare "${E8B}.git"
e8b_out="$(policy_scenario "$E8B" "${STATE_E}8b" '
  source "'"$CRED_LIB_SRC"'"
  source "'"$PUSH_LIB_SRC"'"
  cd "'"$E8B"'"
  git remote add origin "'"${E8B}.git"'"
  squad_policy_harden "$(pwd)"; echo "HARDEN_RC=$?"
  git checkout -q -B squad/e8b
  echo "commit1" >ignored-e8b-1.txt
  git add -A
  git commit -q -m "commit1: unrelated, clean"; echo "C1_RC=$?"
  git update-index --no-skip-worktree -- '"$PIN"'
  git add -f -- '"$PIN"'
  git commit --no-verify -q -m "commit2: carries the pin"; echo "C2_RC=$?"
  git update-index --no-skip-worktree -- '"$PIN"'
  # squad_policy_harden chmod -R a-w'"'"'d the governance paths, including this
  # file itself, so it must be made writable again before the content can be
  # rewritten -- the mode bit is not part of the seal predicate being tested.
  chmod u+w -- '"$PIN"'
  node -e "const fs=require(\"fs\"); const c=JSON.parse(fs.readFileSync(process.argv[1],\"utf8\")); c.policy.auditMaxBytes=1048576; fs.writeFileSync(process.argv[1], JSON.stringify(c, null, 2) + \"\n\")" '"$PIN"'
  git add -f -- '"$PIN"'
  git commit --no-verify -q -m "commit3: undoes the pin at the tip"; echo "C3_RC=$?"
  git push -q origin HEAD:refs/heads/hook-test-e8b >/dev/null 2>&1; echo "RAW_PUSH_RC=$?"
  squad_push_branch squad/e8b; echo "PUSH_BRANCH_RC=$?"
')"
assert_contains "$e8b_out" "HARDEN_RC=0" "(e8b) hardening succeeds"
assert_contains "$e8b_out" "C1_RC=0" "(e8b) commit1 (clean) succeeds"
assert_contains "$e8b_out" "C2_RC=0" "(e8b) commit2 (--no-verify, carries the pin) succeeds"
assert_contains "$e8b_out" "C3_RC=0" "(e8b) commit3 (--no-verify, undoes the pin at the tip) succeeds"
assert_not_contains "$e8b_out" "RAW_PUSH_RC=0" \
  "(e8b) R5: the pre-push hook refuses a direct 'git push' even though ONLY the MIDDLE commit of the 3-commit range carries the pin and the tip is clean (range-walk, not tip-only)"
assert_contains "$e8b_out" "PUSH_BRANCH_RC=78" \
  "(e8b) R5: squad_push_branch (assert_pin_unpublished) refuses (78) a branch whose range contains the pin even though its tip does not"
assert_eq "none" "$(git --git-dir="${E8B}.git" rev-parse -q --verify refs/heads/hook-test-e8b 2>/dev/null || echo none)" \
  "(e8b) the raw push left nothing on the remote"
assert_eq "none" "$(git --git-dir="${E8B}.git" rev-parse -q --verify refs/heads/squad/e8b 2>/dev/null || echo none)" \
  "(e8b) squad_push_branch left nothing on the remote"

# e9. worker/squad-agent (the per-iteration wrapper watch/loop/triage spawn)
#     re-checks the seal before EVERY iteration.
E9BIN="${WORK}/fakebin-e9"; mkdir -p "$E9BIN"
printf '#!/usr/bin/env bash\necho COPILOT_RAN\nexit 0\n' >"${E9BIN}/copilot"
chmod +x "${E9BIN}/copilot"
E9="${WORK}/repo-e9"
make_repo "$E9" 0
e9_out="$(policy_scenario "$E9" "${STATE_E}9" '
  export PATH="'"$E9BIN"':$PATH"
  squad_policy_harden "'"$E9"'"
  run_agent() { SQUAD_AGENT_POLICY_ARGV_JSON="[\"--allow-all-tools\"]" SQUAD_AGENT_REPO_DIR="'"$E9"'" bash "'"$WORKER_DIR"'/squad-agent" -p x 2>&1; echo "AGENT_RC=$?"; }
  echo "--control--"; run_agent
  echo "--badsum--"; SQUAD_POLICY_PIN_SHA256=0000000000000000000000000000000000000000000000000000000000000000 run_agent
  git -C "'"$E9"'" add -f -- '"$PIN"'
  echo "--broken--"; run_agent
')"
e9_control="$(sed -n '/--control--/,/--badsum--/p' <<<"$e9_out")"
e9_badsum="$(sed -n '/--badsum--/,/--broken--/p' <<<"$e9_out")"
e9_broken="$(sed -n '/--broken--/,$p' <<<"$e9_out")"
assert_contains "$e9_control" "COPILOT_RAN" "(e9) control: with the seal intact the wrapper execs copilot"
assert_contains "$e9_control" "AGENT_RC=0" "(e9) control: exit 0"
assert_contains "$e9_badsum" "AGENT_RC=78" "(e9) the wrapper refuses (78) when the pin file no longer holds the recorded pin"
assert_not_contains "$e9_badsum" "COPILOT_RAN" "(e9) and copilot never runs"
assert_contains "$e9_broken" "AGENT_RC=78" "(e9) the wrapper refuses (78) to start an iteration on a broken seal ('git add -f' of the pin)"
assert_contains "$e9_broken" "seal is broken" "(e9) and names the seal"
assert_not_contains "$e9_broken" "COPILOT_RAN" "(e9) and copilot never runs"

test_summary
