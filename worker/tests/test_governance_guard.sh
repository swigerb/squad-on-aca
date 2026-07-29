#!/usr/bin/env bash
# Behavioural tests for worker/lib/squad-policy.sh — governance-path enforcement.
#
# Issue #26 / PRD #6: ".squad/policies, .squad/agents, .squad/identity,
# approval/audit state, config, and routing must not be writable by autonomous
# sandboxed agents."
#
# WHY THIS SUITE LOOKS LIKE THIS
# ------------------------------
# The requirement is that a governance path is NOT WRITABLE. The only honest way
# to test that is to build a real repository, run the real hardening, and then
# actually try to write to each path — the way an agent's shell tool would. An
# assertion that greps squad-policy.sh for `chmod` passes whether or not the
# chmod is ever reached, applied to the right paths, or checked for failure.
# scripts/tests/verify-launch-detachment.ps1 is the reference for this style:
# evaluate the real thing in a real shell and look at what happened.
#
# The detective half is tested the same way: mutate a governance file exactly as
# an agent would, and assert the session-blocking verdict actually comes back.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${WORKER_DIR}/lib/squad-policy.sh"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-governance-guard"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum diff

echo "== squad-policy.sh (governance guard) =="

# The preventive layer is POSIX mode bits, and root ignores them. A run as root
# cannot answer "is this path writable?" for a non-root agent, so it must not
# claim to: report a skip rather than a pass. Containers run the agent as the
# unprivileged `squad` user (worker/Dockerfile), and CI runners are non-root.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_governance_guard.sh — running as root, mode bits are not enforced against uid 0"
  exit 77
fi

rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
# chmod -R u+w first: the suite deliberately leaves read-only trees behind on a
# failing path, and rm would otherwise be unable to clean them up.
trap 'chmod -R u+w "$TEST_TMP_ROOT" 2>/dev/null; rm -rf "$TEST_TMP_ROOT"' EXIT

export GIT_CONFIG_GLOBAL="${TEST_TMP_ROOT}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global user.name "Test" >/dev/null 2>&1 || true
git config --global user.email "test@example.com" >/dev/null 2>&1 || true

# Every governance path PRD #6 names, plus the audit/approval state.
GOVERNANCE_FILES=(
  ".squad/policies/security.md"
  ".squad/agents/security/charter.md"
  ".squad/agents/security/history.md"
  ".squad/identity/identity.md"
  ".squad/config.json"
  ".squad/routing.md"
  ".squad/memory/audit.jsonl"
  ".squad/fact-checker/audit-trail.md"
  ".squad/rai/audit-trail.md"
)

make_repo() {
  local repo="$1" f
  rm -rf "$repo"
  mkdir -p "$repo"
  ( cd "$repo" && git init --quiet . ) || return 1
  for f in "${GOVERNANCE_FILES[@]}"; do
    mkdir -p "${repo}/$(dirname "$f")"
    printf 'original %s\n' "$f" >"${repo}/${f}"
  done
  # A NON-governance file, so the guard is shown to protect a set rather than
  # simply freezing the whole checkout.
  mkdir -p "${repo}/src"
  printf 'original work\n' >"${repo}/src/app.js"
  printf 'team\n' >"${repo}/.squad/team.md"
  ( cd "$repo" && git add -A && git commit --quiet -m "baseline" ) || return 1
  return 0
}

# Run one scenario in a subshell so a squad_policy_abort (exit 78) is captured
# instead of taking the whole suite down with it.
#   scenario <repo> <state-dir> <shell-body>
scenario() {
  local repo="$1" state="$2" body="$3"
  (
    export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
    export SQUAD_POLICY_STATE_DIR="$state"
    export SQUAD_POLICY_RESOLVER="${WORKER_DIR}/lib/agent-policy.js"
    # shellcheck source=/dev/null
    source "$LIB"
    eval "$body"
  ) 2>&1
}

# ---------------------------------------------------------------------------
# 1. PREVENTIVE — an autonomous run cannot write any governance path
# ---------------------------------------------------------------------------
# The real requirement, tested the real way: harden, then attempt the write an
# agent would attempt, and look at whether the bytes changed.
echo "-- preventive: governance paths are not writable --"

REPO="${TEST_TMP_ROOT}/repo-write"
STATE="${TEST_TMP_ROOT}/state-write"
make_repo "$REPO" || { echo "FAIL: could not build fixture repo"; exit 1; }

harden_out="$(scenario "$REPO" "$STATE" 'squad_policy_harden "'"$REPO"'"; echo "HARDEN_RC=$?"')"
assert_contains "$harden_out" "HARDEN_RC=0"                  "hardening succeeds on a well-formed repository"
assert_contains "$harden_out" "Governance paths locked read-only" "hardening reports which paths it locked"

for f in "${GOVERNANCE_FILES[@]}"; do
  # Overwrite, the way `echo ... > file` from a shell tool would. stderr is
  # discarded because "Permission denied" is the EXPECTED outcome here; the
  # assertion is on the file's contents, not on the message.
  ( printf 'TAMPERED\n' >"${REPO}/${f}" ) 2>/dev/null
  actual="$(cat "${REPO}/${f}" 2>/dev/null)"
  assert_eq "original ${f}" "$actual" "governance path ${f} could not be overwritten"
done

for f in "${GOVERNANCE_FILES[@]}"; do
  # Append, the way `>>` on an audit trail would.
  ( printf 'APPENDED\n' >>"${REPO}/${f}" ) 2>/dev/null
  assert_not_contains "$(cat "${REPO}/${f}" 2>/dev/null)" "APPENDED" "governance path ${f} could not be appended to"
done

# Creating a NEW file inside a protected directory must also fail — otherwise an
# agent simply adds .squad/policies/mine.md instead of editing an existing one.
( : >"${REPO}/.squad/policies/injected.md" ) 2>/dev/null
assert_eq "0" "$([[ -f "${REPO}/.squad/policies/injected.md" ]] && echo 1 || echo 0)" \
  "a new file cannot be created inside a protected directory"

# ... and deleting a file inside one fails, because the containing directory is
# read-only. Deletion of a protected file that sits at the TOP of .squad/ is a
# different case, handled below and deliberately not claimed here.
rm -f "${REPO}/.squad/policies/security.md" 2>/dev/null
assert_eq "1" "$([[ -f "${REPO}/.squad/policies/security.md" ]] && echo 1 || echo 0)" \
  "a file inside a protected directory cannot be deleted"

# HONEST LIMITATION, ASSERTED RATHER THAN DESCRIBED.
# Removing a file requires write permission on its PARENT directory, not on the
# file. `.squad/config.json` and `.squad/routing.md` sit directly in `.squad/`,
# and `.squad/` cannot be frozen: a session legitimately creates `.squad/log/`
# and other run state there, so locking it would break normal operation for no
# security gain. The preventive layer therefore does NOT stop deletion of those
# two, and this suite refuses to pretend otherwise — the detective assertions
# below are what actually covers the case.
rm -f "${REPO}/.squad/config.json" 2>/dev/null
assert_eq "0" "$([[ -f "${REPO}/.squad/config.json" ]] && echo 1 || echo 0)" \
  "documented gap: a top-level protected file CAN be deleted (mode bits cannot prevent it)"

# ... and ordinary work is untouched. A guard that froze the whole repository
# would pass every assertion above while making the product useless.
printf 'agent work\n' >"${REPO}/src/app.js" 2>/dev/null
assert_eq "agent work" "$(cat "${REPO}/src/app.js")" "non-governance files remain writable"
printf 'new\n' >"${REPO}/src/new.js" 2>/dev/null
assert_eq "1" "$([[ -f "${REPO}/src/new.js" ]] && echo 1 || echo 0)" "new non-governance files can still be created"

# ---------------------------------------------------------------------------
# 2. DETECTIVE — a governance change fails the session
# ---------------------------------------------------------------------------
# The preventive layer is mode bits, and the agent owns the checkout, so a
# determined `chmod` can undo it. What must NOT be possible is doing that
# unnoticed. Each case below removes the write protection first — modelling an
# agent that defeated the preventive layer — and asserts the verdict still comes.
echo "-- detective: a defeated preventive layer is still caught --"

for target in ".squad/policies/security.md" ".squad/agents/security/charter.md" ".squad/identity/identity.md" ".squad/config.json" ".squad/routing.md" ".squad/memory/audit.jsonl"; do
  REPO="${TEST_TMP_ROOT}/repo-detect"
  STATE="${TEST_TMP_ROOT}/state-detect"
  rm -rf "$STATE"
  make_repo "$REPO" >/dev/null || { echo "FAIL: fixture"; exit 1; }
  out="$(scenario "$REPO" "$STATE" '
    squad_policy_harden "'"$REPO"'" >/dev/null
    chmod -R u+w "'"$REPO"'/.squad"
    printf "REWRITTEN\n" > "'"$REPO"'/'"$target"'"
    squad_policy_verify "'"$REPO"'"
    echo "VERIFY_RC=$?"
  ')"
  assert_contains "$out" "VERIFY_RC=1"          "verify FAILS after ${target} is rewritten"
  assert_contains "$out" "GOVERNANCE VIOLATION" "verify reports a governance violation for ${target}"
  assert_contains "$out" "$target"              "the violation names ${target}"
done

# Deleting a whole protected directory must be caught too. Without the explicit
# `absent` markers in the manifest, both sides would simply lose those lines and
# compare equal — a deletion that erased every policy would read as clean.
REPO="${TEST_TMP_ROOT}/repo-delete"; STATE="${TEST_TMP_ROOT}/state-delete"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  chmod -R u+w "'"$REPO"'/.squad"
  rm -rf "'"$REPO"'/.squad/policies"
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1"      "verify FAILS when a whole protected directory is deleted"
assert_contains "$out" ".squad/policies"  "the violation names the deleted directory"

# The gap asserted above, closed by the detective layer: deleting a top-level
# protected file needs no chmod at all, and must still fail the session.
REPO="${TEST_TMP_ROOT}/repo-unlink"; STATE="${TEST_TMP_ROOT}/state-unlink"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  rm -f "'"$REPO"'/.squad/config.json"
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1"        "verify FAILS when a top-level protected file is deleted"
assert_contains "$out" ".squad/config.json" "the violation names the deleted file"

# A governance file that did NOT exist at hardening time and is CREATED during
# the session, left uncommitted. `git diff` cannot see an untracked file, so the
# hash manifest is the only thing that catches this — an agent introducing
# `.squad/casting-policy.json` mid-run is exactly how a policy gets added rather
# than edited.
REPO="${TEST_TMP_ROOT}/repo-create"; STATE="${TEST_TMP_ROOT}/state-create"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  printf "{}\n" > "'"$REPO"'/.squad/casting-policy.json"
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1"              "verify FAILS when a NEW governance file appears mid-session"
assert_contains "$out" ".squad/casting-policy.json" "the violation names the newly created governance file"

# A change that is COMMITTED rather than left in the working tree. This is the
# case the hash manifest alone would miss if the agent restored the file after
# committing, so it has an independent detector.
REPO="${TEST_TMP_ROOT}/repo-commit"; STATE="${TEST_TMP_ROOT}/state-commit"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  chmod -R u+w "'"$REPO"'/.squad"
  printf "REWRITTEN\n" > "'"$REPO"'/.squad/routing.md"
  ( cd "'"$REPO"'" && git add -A && git commit --quiet -m "sneak" )
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1"                  "verify FAILS when the governance change was committed"
assert_contains "$out" "changed in commits made during this session" "the commit detector fires, not just the hash manifest"

# A clean session must PASS — a control that fails everything protects nothing
# and would simply be turned off.
REPO="${TEST_TMP_ROOT}/repo-clean"; STATE="${TEST_TMP_ROOT}/state-clean"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  printf "real work\n" > "'"$REPO"'/src/app.js"
  ( cd "'"$REPO"'" && git add -A && git commit --quiet -m "work" )
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=0"                      "a session that only touches product code passes"
assert_contains "$out" "Governance integrity verified"    "a clean session says so explicitly"
assert_not_contains "$out" "GOVERNANCE VIOLATION"         "a clean session reports no violation"

# Write bits are restored afterwards, or teardown and diagnostics break.
assert_eq "1" "$([[ -w "${REPO}/.squad/config.json" ]] && echo 1 || echo 0)" \
  "verify restores write access when the session is clean"

# ---------------------------------------------------------------------------
# 3. FAIL CLOSED — an unapplicable policy aborts, it does not proceed
# ---------------------------------------------------------------------------
# This is the defect class this programme has rejected most often: a control
# that cannot run and lets the session continue anyway. Each case asserts the
# EXIT STATUS (78), not merely the presence of a warning in the log.
echo "-- fail closed --"

REPO="${TEST_TMP_ROOT}/repo-failclosed"; make_repo "$REPO" >/dev/null

# The baseline cannot be written because the state directory is inside the repo,
# where the agent's own file tools can reach and rewrite it.
scenario "$REPO" "${REPO}/.inside-state" 'squad_policy_harden "'"$REPO"'"' >"${TEST_TMP_ROOT}/o1" 2>&1
rc1=$?
assert_eq "78" "$rc1" "hardening ABORTS (78) when the baseline would live inside the checkout"
assert_contains "$(cat "${TEST_TMP_ROOT}/o1")" "outside the checkout" "the abort explains why"

# Verify called with no baseline at all.
scenario "$REPO" "${TEST_TMP_ROOT}/state-missing" 'SQUAD_POLICY_STATE_DIR=""; squad_policy_verify "'"$REPO"'"' >"${TEST_TMP_ROOT}/o2" 2>&1
rc2=$?
assert_eq "78" "$rc2" "verify ABORTS (78) when there is no baseline to verify against"
assert_contains "$(cat "${TEST_TMP_ROOT}/o2")" "cannot be verified" "the abort says the session is unverifiable"

# Baseline directory present but the manifest file deleted — an agent that found
# the state directory and removed the evidence must not thereby pass.
REPO="${TEST_TMP_ROOT}/repo-nobaseline"; STATE="${TEST_TMP_ROOT}/state-nobaseline"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  rm -f "'"$STATE"'/governance.sha256"
  squad_policy_verify "'"$REPO"'"
' >"${TEST_TMP_ROOT}/o3" 2>&1
rc3=$?
assert_eq "78" "$rc3" "verify ABORTS (78) when the baseline file has been removed"

# The resolver itself missing.
REPO="${TEST_TMP_ROOT}/repo-noresolver"; make_repo "$REPO" >/dev/null
(
  export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
  export SQUAD_POLICY_RESOLVER="${TEST_TMP_ROOT}/does-not-exist.js"
  # shellcheck source=/dev/null
  source "$LIB"
  squad_policy_resolve
) >"${TEST_TMP_ROOT}/o4" 2>&1
rc4=$?
assert_eq "78" "$rc4" "resolve ABORTS (78) when the policy resolver is missing"
assert_contains "$(cat "${TEST_TMP_ROOT}/o4")" "must not run with blanket allow" \
  "the abort states the fail-closed rule rather than just erroring"

# An escalation attempt in SQUAD_COPILOT_FLAGS must abort the SESSION, not just
# the resolver: the shell layer has to propagate the refusal.
REPO="${TEST_TMP_ROOT}/repo-escalate"; make_repo "$REPO" >/dev/null
(
  export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
  export SQUAD_COPILOT_FLAGS="--yolo"
  export SQUAD_POLICY_RESOLVER="${WORKER_DIR}/lib/agent-policy.js"
  # shellcheck source=/dev/null
  source "$LIB"
  squad_policy_resolve
) >"${TEST_TMP_ROOT}/o5" 2>&1
rc5=$?
assert_eq "78" "$rc5" "resolve ABORTS (78) when SQUAD_COPILOT_FLAGS tries to restore --yolo"

# ---------------------------------------------------------------------------
# 4. The resolved flags reach the shell layer intact
# ---------------------------------------------------------------------------
# SQUAD_POLICY_ARGV is what entrypoint.sh expands into the `copilot` argv. A
# multi-word deny pattern that word-split here would silently become two bogus
# arguments and the rule would be gone.
echo "-- resolved flags reach the shell layer intact --"

out="$(
  export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
  export SQUAD_POLICY_RESOLVER="${WORKER_DIR}/lib/agent-policy.js"
  # shellcheck source=/dev/null
  source "$LIB"
  squad_policy_resolve
  printf 'TIER=%s\n' "$SQUAD_POLICY_TIER"
  for a in "${SQUAD_POLICY_ARGV[@]}"; do printf 'ARG[%s]\n' "$a"; done
  printf 'SQUADFLAGS=%s\n' "$SQUAD_POLICY_SQUAD_FLAGS"
  squad_policy_announce squad
)"
assert_contains "$out" "TIER=autonomous"          "the shell layer receives the autonomous tier for a ralph session"
assert_contains "$out" "ARG[shell(git config)]"   "a multi-word deny pattern survives as ONE shell argument"
assert_contains "$out" "ARG[--no-ask-user]"       "the unattended no-prompt flag reaches the shell layer"
assert_not_contains "$out" "ARG[--yolo]"          "no blanket-allow flag reaches the shell layer"
assert_not_contains "$out" "ARG[--allow-all-paths]" "no blanket path flag reaches the shell layer"
assert_contains "$out" "NOT enforced on this path" "the squad handoff announces the rules it cannot carry"
assert_contains "$out" "shell(git config)"        "the announcement names the dropped rule instead of hiding it"

test_summary
