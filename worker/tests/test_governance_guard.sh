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

# Every governance path PRD #6 names, plus the audit/approval state. These stay
# LOCKED: nothing in this list may be written, appended to, created or deleted.
GOVERNANCE_FILES=(
  ".squad/policies/security.md"
  ".squad/agents/security/charter.md"
  ".squad/identity/identity.md"
  ".squad/config.json"
  ".squad/routing.md"
  ".squad/memory/audit.jsonl"
  ".squad/fact-checker/audit-trail.md"
  ".squad/rai/audit-trail.md"
)

# The ONE narrow exclusion. `.squad/agents/<name>/history.md` is an append-only
# WORK LOG, not policy: it records what an agent did and grants it nothing.
# Locking it prevented no escalation and destroyed the audit trail PRD #6 asks
# for, so it is excluded from the write lock and held to an append-only
# integrity rule instead. `charter.md` in the SAME DIRECTORY stays locked —
# a charter defines what an agent is permitted to do, which is governance.
APPEND_ONLY_FILES=(
  ".squad/agents/security/history.md"
)

ALL_FIXTURE_FILES=("${GOVERNANCE_FILES[@]}" "${APPEND_ONLY_FILES[@]}")

make_repo() {
  local repo="$1" f
  rm -rf "$repo"
  mkdir -p "$repo"
  ( cd "$repo" && git init --quiet . ) || return 1
  for f in "${ALL_FIXTURE_FILES[@]}"; do
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
# 1b. THE NARROW EXCLUSION — agent history is appendable, and nothing else is
# ---------------------------------------------------------------------------
# `.squad/agents/<name>/history.md` sits INSIDE a directory whose other contents
# are locked, so the interesting question is not "can the run append?" but
# "does making the file writable make the DIRECTORY writable?". It must not:
# otherwise "history is writable" quietly becomes "the agents directory is
# writable", and an agent can add or remove files beside a charter it cannot
# edit. Every assertion below is against the SAME hardened repository used
# above, so it is one filesystem state answering all of the questions.
echo "-- narrow exclusion: history appends, the directory does not open --"

# The reason the exclusion exists at all: an autonomous run must be able to
# record what it did.
( printf 'SESSION 42: appended by an autonomous run\n' >>"${REPO}/.squad/agents/security/history.md" ) 2>/dev/null
assert_contains "$(cat "${REPO}/.squad/agents/security/history.md" 2>/dev/null)" "SESSION 42" \
  "an autonomous run CAN append to .squad/agents/<name>/history.md"
assert_contains "$(cat "${REPO}/.squad/agents/security/history.md" 2>/dev/null)" "original .squad/agents/security/history.md" \
  "appending does not disturb the history that was already there"

# The charter sits in the same directory and is the thing that actually grants
# authority. It must be exactly as locked as before.
( printf 'TAMPERED\n' >"${REPO}/.squad/agents/security/charter.md" ) 2>/dev/null
assert_eq "original .squad/agents/security/charter.md" "$(cat "${REPO}/.squad/agents/security/charter.md" 2>/dev/null)" \
  "an autonomous run CANNOT write .squad/agents/<name>/charter.md — a charter is what an agent is permitted to do"
( printf 'APPENDED\n' >>"${REPO}/.squad/agents/security/charter.md" ) 2>/dev/null
assert_not_contains "$(cat "${REPO}/.squad/agents/security/charter.md" 2>/dev/null)" "APPENDED" \
  "the charter cannot be appended to either"

# Directory mode: creating a NEW file beside history.md must still fail. This is
# the assertion that proves the file was unlocked and not its parent.
( : >"${REPO}/.squad/agents/security/policy.md" ) 2>/dev/null
assert_eq "0" "$([[ -f "${REPO}/.squad/agents/security/policy.md" ]] && echo 1 || echo 0)" \
  "an autonomous run CANNOT create a new file in .squad/agents/<name>/"
( : >"${REPO}/.squad/agents/attacker-history.md" ) 2>/dev/null
assert_eq "0" "$([[ -f "${REPO}/.squad/agents/attacker-history.md" ]] && echo 1 || echo 0)" \
  "an autonomous run CANNOT create a file directly in .squad/agents/"
mkdir -p "${REPO}/.squad/agents/impostor" 2>/dev/null
assert_eq "0" "$([[ -d "${REPO}/.squad/agents/impostor" ]] && echo 1 || echo 0)" \
  "an autonomous run CANNOT create a whole new agent directory"

# ... and deleting an existing file there must still fail.
rm -f "${REPO}/.squad/agents/security/charter.md" 2>/dev/null
assert_eq "1" "$([[ -f "${REPO}/.squad/agents/security/charter.md" ]] && echo 1 || echo 0)" \
  "an autonomous run CANNOT delete an existing file in .squad/agents/<name>/"
rm -f "${REPO}/.squad/agents/security/history.md" 2>/dev/null
assert_eq "1" "$([[ -f "${REPO}/.squad/agents/security/history.md" ]] && echo 1 || echo 0)" \
  "the unlocked history file itself cannot be deleted — unlink needs write on the parent, which stays locked"

# The exclusion is a PATTERN, and a pattern that matched one segment too many
# would re-open the charter. Ask the resolver directly, because it is the single
# source of truth that squad-policy.sh and validate.ps1 both read.
classify() { node "${WORKER_DIR}/lib/agent-policy.js" classify-governance-path "$1" 2>&1; }
assert_eq "append-only" "$(classify '.squad/agents/security/history.md')" "the resolver classifies an agent history file as append-only"
assert_eq "locked"      "$(classify '.squad/agents/security/charter.md')" "the resolver keeps charter.md locked"
assert_eq "locked"      "$(classify '.squad/agents/history.md')"          "a history.md directly under .squad/agents is NOT excluded"
assert_eq "locked"      "$(classify '.squad/agents/a/b/history.md')"      "a nested history.md is NOT excluded"
assert_eq "locked"      "$(classify '.squad/agents/security/history.md.bak')" "a lookalike filename is NOT excluded"
assert_eq "locked"      "$(classify '.squad/policies/history.md')"        "history.md outside .squad/agents is NOT excluded"
assert_eq "locked"      "$(classify '.squad/identity/identity.md')"       "an unrelated governance file is locked"

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

# ---------------------------------------------------------------------------
# 2b. DETECTIVE — the excluded path is NOT excluded from the detector
# ---------------------------------------------------------------------------
# A path that is excluded from BOTH the lock and the integrity check is a
# foothold: anyone who can write there can write freely and invisibly. So the
# history files stay in the manifest under a different rule — they may GROW, and
# the bytes the baseline already pinned must still be there. An append passes
# and is reported with its size; a rewrite fails the session like any other
# governance violation.
echo "-- detective: history may grow, and only grow --"

# The permitted case. This is the whole point of the narrowing, so it must be
# demonstrably green, not merely "not red".
REPO="${TEST_TMP_ROOT}/repo-append"; STATE="${TEST_TMP_ROOT}/state-append"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  printf "## Session 42\nDid the work.\n" >> "'"$REPO"'/.squad/agents/security/history.md"
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=0"                  "an autonomous run that appends to history PASSES verification"
assert_not_contains "$out" "GOVERNANCE VIOLATION"     "appending to history is not reported as a violation"
assert_contains "$out" "Agent history appended (permitted)" "the detector still REPORTS that history changed"
assert_contains "$out" ".squad/agents/security/history.md +28 bytes" \
  "the report says HOW MUCH history grew, so the audit trail is reviewable"
assert_contains "$out" "1 permitted append-only work-log update" "the summary line counts the permitted updates"

# Truncation — the exact way an agent would erase the record of what it did.
REPO="${TEST_TMP_ROOT}/repo-truncate"; STATE="${TEST_TMP_ROOT}/state-truncate"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  : > "'"$REPO"'/.squad/agents/security/history.md"
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1"                  "verify FAILS when history is TRUNCATED — the file is appendable, not editable"
assert_contains "$out" "REWRITTEN, not appended to"   "the violation says the file was rewritten rather than appended to"

# Rewrite that keeps the file the same length or longer, so a size-only check
# would wave it through. This is why the baseline pins a prefix HASH.
REPO="${TEST_TMP_ROOT}/repo-rewrite"; STATE="${TEST_TMP_ROOT}/state-rewrite"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  printf "FABRICATED HISTORY THAT IS LONGER THAN THE ORIGINAL\n" > "'"$REPO"'/.squad/agents/security/history.md"
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1"                       "verify FAILS when history is rewritten with LONGER content (a size check alone would pass it)"
assert_contains "$out" ".squad/agents/security/history.md" "the violation names the rewritten history file"

# Deleting the work log needs a chmod, and must still be caught after one.
REPO="${TEST_TMP_ROOT}/repo-histdel"; STATE="${TEST_TMP_ROOT}/state-histdel"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  chmod -R u+w "'"$REPO"'/.squad"
  rm -f "'"$REPO"'/.squad/agents/security/history.md"
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1"   "verify FAILS when the append-only work log is deleted"
assert_contains "$out" "was DELETED"   "the violation says the work log was deleted"

# A history file that did not exist at hardening time. "May append to history"
# must not become "may mint history", or an agent could fabricate a record for
# an identity that never ran.
REPO="${TEST_TMP_ROOT}/repo-histnew"; STATE="${TEST_TMP_ROOT}/state-histnew"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  chmod -R u+w "'"$REPO"'/.squad"
  mkdir -p "'"$REPO"'/.squad/agents/impostor"
  printf "invented\n" > "'"$REPO"'/.squad/agents/impostor/history.md"
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1"                        "verify FAILS when a NEW agent history file appears mid-session"
assert_contains "$out" ".squad/agents/impostor/history.md"  "the violation names the invented work log"

# The committed form gets the same rule. Without this, an agent could commit a
# truncated history and restore the working-tree copy: the manifest would
# compare clean and the truncation is what would be pushed.
REPO="${TEST_TMP_ROOT}/repo-histcommit"; STATE="${TEST_TMP_ROOT}/state-histcommit"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  chmod -R u+w "'"$REPO"'/.squad"
  printf "FABRICATED\n" > "'"$REPO"'/.squad/agents/security/history.md"
  ( cd "'"$REPO"'" && git add -A && git commit --quiet -m "sneak" )
  printf "original .squad/agents/security/history.md\n" > "'"$REPO"'/.squad/agents/security/history.md"
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1"                          "verify FAILS when a history REWRITE was committed and the working tree restored"
assert_contains "$out" "in a commit made during this session" "the commit detector is what catches the restored-working-tree case"

# ... and a committed APPEND is permitted and reported, because that is exactly
# what an autonomous run is supposed to do with its work log.
REPO="${TEST_TMP_ROOT}/repo-histcommitok"; STATE="${TEST_TMP_ROOT}/state-histcommitok"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "'"$REPO"'" >/dev/null
  printf "## Session 42\n" >> "'"$REPO"'/.squad/agents/security/history.md"
  ( cd "'"$REPO"'" && git add -A && git commit --quiet -m "record the run" )
  squad_policy_verify "'"$REPO"'"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=0"                             "a run that COMMITS a history append passes verification"
assert_contains "$out" "Agent history appended in a commit (permitted)" "the commit detector reports the permitted committed append"
assert_not_contains "$out" "GOVERNANCE VIOLATION"                "a committed history append is not a violation"

# The manifest must still DESCRIBE the excluded path rather than omit it. A path
# dropped from the baseline is invisible to an operator reviewing it.
REPO="${TEST_TMP_ROOT}/repo-manifest"; STATE="${TEST_TMP_ROOT}/state-manifest"; rm -rf "$STATE"
make_repo "$REPO" >/dev/null
scenario "$REPO" "$STATE" 'squad_policy_harden "'"$REPO"'"' >/dev/null
assert_contains "$(cat "${STATE}/governance.sha256" 2>/dev/null)" "append-only .squad/agents/security/history.md" \
  "the baseline records the excluded path under an 'append-only' rule instead of dropping it"
assert_contains "$(cat "${STATE}/governance.sha256" 2>/dev/null)" "file .squad/agents/security/charter.md" \
  "the baseline still pins charter.md as immutable"


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
