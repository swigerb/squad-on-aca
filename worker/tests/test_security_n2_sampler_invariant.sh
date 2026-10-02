#!/usr/bin/env bash
# Security re-review N2: the append-only (F4) and modify-then-revert (F6)
# properties must not depend on winning a race against a sampling interval.
#
# Every case runs the REAL path: squad_policy_harden (which starts the real
# in-session sampler) -> agent-shaped writes from a child process ->
# squad_policy_verify (which collects the sampler and runs the authoritative
# end-state comparison). Nothing here calls a scanner by hand -- the previous
# regression test did, which is why it could not catch A1.
#
# What is an INVARIANT now (independent of timing): any write that leaves a
# governance file byte-identical to its baseline -- grow-then-truncate,
# modify-then-revert -- changes the file's inode/ctime fingerprint, which
# verify compares against the fingerprint harden recorded in memory.
# What is still SAMPLED (documented residual, asserted honestly below): a
# PARTIAL truncation of an append-only file that still leaves it longer than
# its baseline, completed between two sampler ticks. Closing that needs the
# kernel to enforce append-only (chattr +a, CAP_LINUX_IMMUTABLE before the
# privilege drop) -- an entrypoint change.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${SQUAD_POLICY_LIB_UNDER_TEST:-${WORKER_DIR}/lib/squad-policy.sh}"
RESOLVER="${WORKER_DIR}/lib/agent-policy.js"

TEST_TMP_ROOT="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-n2-sampler-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'chmod -R u+w "$TEST_TMP_ROOT" 2>/dev/null; rm -rf "$TEST_TMP_ROOT"' EXIT INT TERM

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum diff stat

echo "== security re-review N2: append-only / revert detection is not a sampling race =="

if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_security_n2_sampler_invariant.sh — running as root, mode bits are not enforced against uid 0"
  exit 77
fi

export GIT_CONFIG_GLOBAL="${TEST_TMP_ROOT}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global core.autocrlf false >/dev/null 2>&1 || true

make_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "${repo}/.squad/agents/security" "${repo}/.squad/identity" "${repo}/.squad/memory" "${repo}/src"
  printf 'original charter\n'  >"${repo}/.squad/agents/security/charter.md"
  printf 'original history\n'  >"${repo}/.squad/agents/security/history.md"
  printf 'original now\n'      >"${repo}/.squad/identity/now.md"
  # 35 bytes, as in the reviewer's A1 repro.
  printf '{"event":"baseline","seq":1,"ok":1}' >"${repo}/.squad/memory/audit.jsonl"
  printf 'work\n'              >"${repo}/src/app.js"
  ( cd "$repo" && git init --quiet . && git add -A && git commit --quiet -m baseline ) || return 1
}

scenario() {
  local repo="$1" state="$2" body="$3"
  (
    export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
    export SQUAD_POLICY_STATE_DIR="$state"
    export SQUAD_POLICY_RESOLVER="$RESOLVER"
    export REPO="$repo" STATE="$state"
    # shellcheck source=/dev/null
    source "$LIB"
    agent() { bash -c "$1"; }
    eval "$body"
  ) 2>&1
}

AUDIT_BASE='{"event":"baseline","seq":1,"ok":1}'
export AUDIT_BASE

# ---------------------------------------------------------------------------
# A1 exact: 5s interval (the old default), grow 35 -> 51 bytes and truncate
# back to the exact baseline bytes immediately -- no sampler tick can land in
# between. Before: VERIFY_RC=0, undetected.
# ---------------------------------------------------------------------------
echo "-- A1: grow-then-truncate inside one sampler window --"
REPO="${TEST_TMP_ROOT}/repo-a1"; STATE="${TEST_TMP_ROOT}/state-a1"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=5
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"{\\\"evil\\\":\\\"xyz1\\\"}\\n\" >> \"$REPO/.squad/memory/audit.jsonl\"; wc -c < \"$REPO/.squad/memory/audit.jsonl\"; printf \"%s\" \"\$AUDIT_BASE\" > \"$REPO/.squad/memory/audit.jsonl\"; wc -c < \"$REPO/.squad/memory/audit.jsonl\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "51" "A1 setup: the audit trail really grew to 51 bytes"
assert_contains "$out" "VERIFY_RC=1" "A1: grow-then-truncate inside one 5s window now FAILS verification (was rc=0)"
assert_contains "$out" ".squad/memory/audit.jsonl was MODIFIED AND RESTORED to its exact baseline bytes" \
  "A1: caught by the timing-independent inode/ctime fingerprint, not by the sampler"

# Same, for an agent history file and a 30s interval (no tick can possibly land).
REPO="${TEST_TMP_ROOT}/repo-a1h"; STATE="${TEST_TMP_ROOT}/state-a1h"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=30
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"tamper\\n\" >> \"$REPO/.squad/agents/security/history.md\"; printf \"original history\\n\" > \"$REPO/.squad/agents/security/history.md\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1" "A1 (history.md, 30s interval): grow-then-truncate fails verification"
assert_contains "$out" ".squad/agents/security/history.md was MODIFIED AND RESTORED" "A1 (history.md): named in the log"

# ---------------------------------------------------------------------------
# F6 inside one window: modify a reported-mutable file and revert it before
# any tick. Before: silent. Now: reported (the class is report-only).
# ---------------------------------------------------------------------------
echo "-- F6: modify-then-revert inside one sampler window --"
REPO="${TEST_TMP_ROOT}/repo-f6"; STATE="${TEST_TMP_ROOT}/state-f6"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=30
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"evil\\n\" > \"$REPO/.squad/identity/now.md\"; printf \"original now\\n\" > \"$REPO/.squad/identity/now.md\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=0" "F6: reported-mutable stays report-only"
assert_contains "$out" ".squad/identity/now.md was modified during this session and reverted to its baseline value before verification." \
  "F6: modify-then-revert inside one window is reported (was silent)"

# ---------------------------------------------------------------------------
# The sampler itself, through the real path: a partial truncation that a tick
# DID observe is caught at the real verify.
# ---------------------------------------------------------------------------
echo "-- sampler: an observed partial truncation is caught at verify --"
REPO="${TEST_TMP_ROOT}/repo-pt"; STATE="${TEST_TMP_ROOT}/state-pt"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"%s\\n{\\\"a\\\":1}\\n{\\\"b\\\":2}\\n\" \"\$AUDIT_BASE\" > \"$REPO/.squad/memory/audit.jsonl.new\"; cat \"$REPO/.squad/memory/audit.jsonl.new\" > \"$REPO/.squad/memory/audit.jsonl\""
  sleep 1
  agent "printf \"%s\\n{\\\"a\\\":1}\\n\" \"\$AUDIT_BASE\" > \"$REPO/.squad/memory/audit.jsonl\"; rm -f \"$REPO/.squad/memory/audit.jsonl.new\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1" "sampler: partial truncation observed by a tick fails verification"
assert_contains "$out" "TRUNCATED to" "sampler: reported as a truncation"

# HONEST LIMITATION -- asserted so it cannot silently change: a partial
# truncation that stays ABOVE the baseline length and completes between two
# ticks is not observed. The file still ends with exactly its baseline bytes
# as a prefix, so the end state is a legal append; nothing in user space can
# distinguish "appended 10" from "appended 20, removed 10" after the fact.
REPO="${TEST_TMP_ROOT}/repo-lim"; STATE="${TEST_TMP_ROOT}/state-lim"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=30
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"%s\\n{\\\"a\\\":1}\\n{\\\"b\\\":2}\\n\" \"\$AUDIT_BASE\" > \"$REPO/.squad/memory/audit.jsonl\"; printf \"%s\\n{\\\"a\\\":1}\\n\" \"\$AUDIT_BASE\" > \"$REPO/.squad/memory/audit.jsonl\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=0" \
  "DOCUMENTED RESIDUAL (N2): partial truncation above baseline inside one tick is NOT caught -- needs chattr +a (entrypoint follow-up)"

# ---------------------------------------------------------------------------
# The sampler cannot be silenced: killed, stopped, or tricked into exiting
# early by an agent-sent USR1 => violation, never "nothing to check".
# ---------------------------------------------------------------------------
echo "-- sampler liveness is enforced (fail closed) --"
REPO="${TEST_TMP_ROOT}/repo-kill"; STATE="${TEST_TMP_ROOT}/state-kill"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  agent "kill -9 $SQUAD_POLICY_SAMPLER_PID"
  sleep 0.5
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1" "kill -9 of the sampler fails verification"
assert_contains "$out" "GOVERNANCE VIOLATION: the in-session governance sampler" "kill -9: the sampler is named"

REPO="${TEST_TMP_ROOT}/repo-usr1"; STATE="${TEST_TMP_ROOT}/state-usr1"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  agent "kill -USR1 $SQUAD_POLICY_SAMPLER_PID"
  sleep 1.5
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1" "an early USR1 from the agent fails verification"
assert_contains "$out" "GOVERNANCE VIOLATION: the in-session governance sampler" "early USR1: the sampler is named"

REPO="${TEST_TMP_ROOT}/repo-stop"; STATE="${TEST_TMP_ROOT}/state-stop"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  SQUAD_POLICY_SAMPLER_COLLECT_TIMEOUT_SECONDS=2
  squad_policy_harden "$REPO" >/dev/null
  agent "kill -STOP $SQUAD_POLICY_SAMPLER_PID"
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
  kill -CONT "$SQUAD_POLICY_SAMPLER_PID" 2>/dev/null; kill -9 "$SQUAD_POLICY_SAMPLER_PID" 2>/dev/null
')"
assert_contains "$out" "VERIFY_RC=1" "SIGSTOP of the sampler fails verification (collect times out)"
assert_contains "$out" "GOVERNANCE VIOLATION: the in-session governance sampler" "SIGSTOP: the sampler is named"

# Control: an untouched session with a live sampler verifies clean.
REPO="${TEST_TMP_ROOT}/repo-ok"; STATE="${TEST_TMP_ROOT}/state-ok"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"\\n{\\\"legit\\\":1}\\n\" >> \"$REPO/.squad/memory/audit.jsonl\""
  sleep 0.6
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=0" "control: a legitimate append with a live sampler verifies clean"
assert_not_contains "$out" "VIOLATION" "control: no violation logged"

test_summary
