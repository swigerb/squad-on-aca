#!/usr/bin/env bash
# Security re-review N5 + the entrypoint half of N1/F7: behaviour of the REAL
# worker/entrypoint.sh functions (extracted verbatim with awk, not
# reimplemented) running against the REAL worker/lib/squad-policy.sh:
#
#   N5  a SIGTERM that lands WHILE squad_policy_checkpoint runs is deferred
#       until the checkpoint and the governance report are done -- it no
#       longer kills the shell mid-verify;
#   F7  the governance report is written on the exit-78 violation path, and on
#       the TAMPERED path (an abort raised inside squad_policy_verify), not
#       only after a passing checkpoint;
#   fd  squad_policy_exec_agent closes the sampler and seal descriptors in the
#       agent, also when launched through the #115 signal-forwarding wrapper,
#       and the forwarded SIGTERM still reaches the agent itself;
#   N1  a half-configured or non-root "sealed" store is refused (78), and
#       worker/squad-agent refuses a sealed store with no sealed baseline.
#
# The uid boundary itself (root-owned store, agent uid cannot touch it) needs
# real root: see test_security_n1b_root_sealed_state.sh.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${SQUAD_POLICY_LIB_UNDER_TEST:-${WORKER_DIR}/lib/squad-policy.sh}"
ENTRYPOINT="${SQUAD_ENTRYPOINT_UNDER_TEST:-${WORKER_DIR}/entrypoint.sh}"
WRAPPER="${SQUAD_AGENT_WRAPPER_UNDER_TEST:-${WORKER_DIR}/squad-agent}"
FWD_LIB="${WORKER_DIR}/lib/squad-signal-forwarding.sh"
RESOLVER="${WORKER_DIR}/lib/agent-policy.js"

TEST_TMP_ROOT="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-n5-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'chmod -R u+w "$TEST_TMP_ROOT" 2>/dev/null; rm -rf "$TEST_TMP_ROOT"' EXIT

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum diff stat base64

echo "== security re-review N5 / F7 / fd hygiene: real entrypoint functions =="

if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_security_n5_entrypoint_hardening.sh — running as root, mode bits are not enforced against uid 0"
  exit 77
fi

export GIT_CONFIG_GLOBAL="${TEST_TMP_ROOT}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global core.autocrlf false >/dev/null 2>&1 || true

FAKE_BIN="${TEST_TMP_ROOT}/bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/copilot" <<'COPILOT'
#!/usr/bin/env bash
printf 'COPILOT_RAN %s\n' "$*" >> "${COPILOT_ARGV_DUMP:?}"
exit 0
COPILOT
chmod +x "${FAKE_BIN}/copilot"
export PATH="${FAKE_BIN}:${PATH}"
export COPILOT_ARGV_DUMP="${TEST_TMP_ROOT}/copilot.ran"

PARITY_JSON="$(env -u SQUAD_COPILOT_FLAGS -u SQUAD_WATCH_STRICT_POLICY \
  SQUAD_MODE=watch SQUAD_DISPATCH_SOURCE=watch SQUAD_COPILOT_FLAGS="" SQUAD_EXECUTION_MODE=aca-job \
  SQUAD_WATCH_STRICT_POLICY=false node "$RESOLVER" watch-agent-parity-argv-json)"
export PARITY_JSON WRAPPER FWD_LIB

# The real functions, verbatim from worker/entrypoint.sh.
extract_fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' "$ENTRYPOINT"; }
ENTRY_FNS=""
for fn in log squad_policy_checkpoint squad_policy_on_abort squad_defer_shutdown_signals \
          squad_release_shutdown_signals squad_watch_governance_report_if_any; do
  body="$(extract_fn "$fn")"
  assert_ne "" "$body" "worker/entrypoint.sh defines ${fn}()"
  ENTRY_FNS+="${body}"$'\n'
done
export ENTRY_FNS

make_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "${repo}/.squad/agents/security" "${repo}/.squad/identity" "${repo}/.squad/memory" \
           "${repo}/.squad/casting" "${repo}/.squad/policies" "${repo}/src"
  printf 'original charter\n'  >"${repo}/.squad/agents/security/charter.md"
  printf 'original identity\n' >"${repo}/.squad/identity/identity.md"
  printf 'original now\n'      >"${repo}/.squad/identity/now.md"
  printf 'original audit\n'    >"${repo}/.squad/memory/audit.jsonl"
  printf '{"v":1}\n'           >"${repo}/.squad/casting/registry.json"
  printf 'original policy\n'   >"${repo}/.squad/policies/security.md"
  printf '{"mcpServers":{"legit":{}}}\n' >"${repo}/.mcp.json"
  printf 'work\n'              >"${repo}/src/app.js"
  ( cd "$repo" && git init --quiet . && git add -A && git commit --quiet -m baseline ) || return 1
}

# One process hardens, lets the "agent" act, then runs the REAL entrypoint
# checkpoint/report functions -- the same shape as worker/entrypoint.sh.
scenario() {
  local repo="$1" state="$2" body="$3"
  (
    export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
    export SQUAD_POLICY_STATE_DIR="$state" SQUAD_POLICY_RESOLVER="$RESOLVER"
    export REPO="$repo" STATE="$state"
    unset SQUAD_POLICY_SEAL_FD SQUAD_POLICY_SEALED_DIR
    # shellcheck source=/dev/null
    source "$LIB"
    eval "$ENTRY_FNS"
    REPO_DIR="$repo"
    SQUAD_POLICY_VERIFIED=0
    SQUAD_POLICY_IN_VERIFY=0
    agent() { bash -c "$1"; }
    eval "$body"
  ) 2>&1
}

# ---------------------------------------------------------------------------
# N5 -- a real SIGTERM, delivered by another process while the real
# checkpoint is running.
# ---------------------------------------------------------------------------
echo "-- N5: SIGTERM during the checkpoint is deferred, not fatal --"
REPO="${TEST_TMP_ROOT}/repo-n5"; STATE="${TEST_TMP_ROOT}/state-n5"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"new now\\n\" > \"$REPO/.squad/identity/now.md\""
  squad_defer_shutdown_signals
  me=$BASHPID
  ( sleep 0.2; kill -TERM "$me" ) &
  sleep 0.6
  squad_policy_checkpoint
  echo "CHECKPOINT_DONE"
  squad_watch_governance_report_if_any
  echo "REPORT_DONE"
  squad_release_shutdown_signals
  echo "AFTER_RELEASE_NOT_REACHED"
')"
rc_line="$(printf '%s\n' "$out" | tail -1)"
assert_contains "$out" "SIGTERM received during the governance checkpoint" \
  "N5: the SIGTERM was actually delivered while the checkpoint window was open"
assert_contains "$out" "CHECKPOINT_DONE" \
  "N5: the checkpoint still ran to completion after the SIGTERM landed"
assert_contains "$out" "Governance integrity verified" \
  "N5: the governance verify itself completed (not killed mid-verify)"
assert_contains "$out" "REPORT_DONE" \
  "N5: the governance report still ran after the SIGTERM landed"
assert_contains "$out" ".squad/identity/now.md" \
  "N5: the report really contains this session's reported-mutable change"
assert_contains "$out" "Honouring the deferred SIGTERM" \
  "N5: the deferred SIGTERM is honoured once the checkpoint and report are done"
assert_not_contains "$out" "AFTER_RELEASE_NOT_REACHED" \
  "N5: the session ends at release -- the deferred signal is not swallowed"

echo "-- N5 control: the same SIGTERM without the deferral kills the shell mid-checkpoint --"
REPO="${TEST_TMP_ROOT}/repo-n5c"; STATE="${TEST_TMP_ROOT}/state-n5c"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  me=$BASHPID
  ( sleep 0.2; kill -TERM "$me" ) &
  sleep 0.6
  squad_policy_checkpoint
  echo "CHECKPOINT_DONE"
'; echo "RC=$?")"
assert_not_contains "$out" "CHECKPOINT_DONE" \
  "N5 control: with the default disposition the same signal kills the checkpoint (proves the test can fail)"

# ---------------------------------------------------------------------------
# F7 -- the report is written on the violation path, before exit 78.
# ---------------------------------------------------------------------------
echo "-- F7: violation path writes the report before exit 78 --"
REPO="${TEST_TMP_ROOT}/repo-f7v"; STATE="${TEST_TMP_ROOT}/state-f7v"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"new now\\n\" > \"$REPO/.squad/identity/now.md\""
  agent "chmod u+w \"$REPO/.squad/policies/security.md\" && printf \"evil\\n\" >> \"$REPO/.squad/policies/security.md\""
  squad_policy_checkpoint
  echo "NOT_REACHED"
'; echo "RC=$?")"
assert_contains "$out" "RC=78" "F7 violation: the checkpoint still fails the session (78)"
assert_not_contains "$out" "NOT_REACHED" "F7 violation: nothing runs after the failing checkpoint"
assert_contains "$out" "Verdict: governance VIOLATION" \
  "F7 violation: the report carries the violation verdict"
assert_contains "$out" ".squad/identity/now.md" \
  "F7 violation: the report lists the reported-mutable change, even though the session failed"
report_file="${STATE}/reported-changes.md"
assert_contains "$(cat "$report_file" 2>/dev/null)" "Verdict: governance VIOLATION" \
  "F7 violation: the durable report file was written before exit 78"
assert_contains "$out" "agent-writable; no root-sealed store" \
  "F7 violation: without a root sealer the log says plainly that this copy is agent-writable"
viol_line="$(printf '%s\n' "$out" | grep -n 'Verdict: governance VIOLATION' | head -1 | cut -d: -f1)"
fail_line="$(printf '%s\n' "$out" | grep -n 'Session FAILED' | head -1 | cut -d: -f1)"
assert_eq "1" "$([[ -n "$viol_line" && -n "$fail_line" && "$viol_line" -lt "$fail_line" ]] && echo 1 || echo 0)" \
  "F7 violation: the report is emitted BEFORE the session-failed line and exit"

echo "-- F7: TAMPERED path (abort inside verify) still writes the report --"
REPO="${TEST_TMP_ROOT}/repo-f7t"; STATE="${TEST_TMP_ROOT}/state-f7t"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"new now\\n\" > \"$REPO/.squad/identity/now.md\""
  agent "rm -f \"$STATE/governance.sha256\""
  squad_policy_checkpoint
  echo "NOT_REACHED"
'; echo "RC=$?")"
assert_contains "$out" "RC=78" "F7 tamper: the session fails (78)"
assert_contains "$out" "Verdict: governance state TAMPERED" \
  "F7 tamper: the abort hook emitted the report with the tamper verdict"
assert_contains "$out" ".squad/identity/now.md" \
  "F7 tamper: the report still lists the reported-mutable change"

echo "-- F7: a passing checkpoint with nothing to report writes nothing --"
REPO="${TEST_TMP_ROOT}/repo-f7p"; STATE="${TEST_TMP_ROOT}/state-f7p"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  squad_policy_checkpoint
  squad_watch_governance_report_if_any
  echo "DONE"
'; echo "RC=$?")"
assert_contains "$out" "RC=0" "F7 pass: a clean session still exits 0"
assert_eq "0" "$([[ -e "${STATE}/reported-changes.md" ]] && echo 1 || echo 0)" \
  "F7 pass: no report file for a clean session"

# ---------------------------------------------------------------------------
# fd hygiene -- the agent does not inherit the sampler or seal descriptors.
# ---------------------------------------------------------------------------
echo "-- fd hygiene: squad_policy_exec_agent closes the policy descriptors --"
REPO="${TEST_TMP_ROOT}/repo-fd"; STATE="${TEST_TMP_ROOT}/state-fd"; make_repo "$REPO"
SIG_MARK="${TEST_TMP_ROOT}/agent-got-term"
export SIG_MARK
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  # Stand-in seal channel (no root here); harden already ran, so it is only
  # the descriptor whose inheritance is under test.
  exec {SQUAD_POLICY_SEAL_FD}>/dev/null
  export SQUAD_POLICY_SEAL_FD
  echo "SAMPLER_FD=$SQUAD_POLICY_SAMPLER_FD SEAL_FD=$SQUAD_POLICY_SEAL_FD"
  echo "CONTROL_FDS= $(bash -c "ls /proc/\$\$/fd | tr \"\\n\" \" \"") "
  echo "AGENT_FDS= $( ( squad_policy_exec_agent bash -c "ls /proc/\$\$/fd | tr \"\\n\" \" \"" ) ) "
  echo "AGENT_ENV_SEAL=[$( ( squad_policy_exec_agent bash -c "printf %s \"\${SQUAD_POLICY_SEAL_FD:-}\"" ) )]"
  log() { printf "[fwd] %s\n" "$*"; }
  source "$FWD_LIB"
  me=$BASHPID
  ( sleep 1; kill -TERM "$me" ) &
  squad_run_foreground_with_signal_forwarding \
    squad_policy_exec_agent \
    bash -c "echo \"FWD_FDS= \$(ls /proc/\$\$/fd | tr \"\\n\" \" \") \"; trap \"echo got > \\\"$SIG_MARK\\\"; exit 0\" TERM; while :; do sleep 0.1; done"
  echo "FWD_RC=$?"
  ( squad_policy_exec_agent true ) && echo "SUBSHELL_OK"
  squad_policy_exec_agent true
  echo "MAIN_SHELL_NOT_REACHED"
'; echo "RC=$?")"
sampler_fd="$(printf '%s\n' "$out" | sed -n 's/^SAMPLER_FD=\([0-9]*\) .*/\1/p')"
seal_fd="$(printf '%s\n' "$out" | sed -n 's/.* SEAL_FD=\([0-9]*\)$/\1/p')"
control="$(printf '%s\n' "$out" | grep '^CONTROL_FDS=')"
agent_fds="$(printf '%s\n' "$out" | grep '^AGENT_FDS=')"
fwd_fds="$(printf '%s\n' "$out" | grep '^FWD_FDS=')"
assert_ne "" "$sampler_fd" "fd: harden opened a sampler descriptor"
assert_ne "" "$seal_fd" "fd: a seal descriptor is open in the hardening shell"
assert_contains "$control" " ${sampler_fd} " \
  "fd control: a child started WITHOUT the helper inherits the sampler descriptor (proves the probe can see it)"
assert_contains "$control" " ${seal_fd} " \
  "fd control: a child started WITHOUT the helper inherits the seal descriptor"
assert_ne "" "$agent_fds" "fd: the helper-launched agent reported its descriptors"
assert_not_contains "$agent_fds" " ${sampler_fd} " \
  "fd: an agent launched through squad_policy_exec_agent does NOT hold the sampler descriptor"
assert_not_contains "$agent_fds" " ${seal_fd} " \
  "fd: an agent launched through squad_policy_exec_agent does NOT hold the seal descriptor"
assert_contains "$out" "AGENT_ENV_SEAL=[]" \
  "fd: SQUAD_POLICY_SEAL_FD is not passed on to the agent's environment"
assert_ne "" "$fwd_fds" "fd: the agent launched through the #115 forwarding wrapper ran"
assert_not_contains "$fwd_fds" " ${sampler_fd} " \
  "fd: through squad_run_foreground_with_signal_forwarding the agent does NOT hold the sampler descriptor"
assert_not_contains "$fwd_fds" " ${seal_fd} " \
  "fd: through squad_run_foreground_with_signal_forwarding the agent does NOT hold the seal descriptor"
assert_eq "got" "$(cat "$SIG_MARK" 2>/dev/null)" \
  "fd: the forwarded SIGTERM reached the agent itself (the helper exec'd, so \$! is the agent's pid)"
assert_contains "$out" "FWD_RC=0" "fd: the forwarding wrapper still returned the agent's real exit code"
assert_contains "$out" "SUBSHELL_OK" "fd: the helper works in a ( ... ) subshell"
assert_contains "$out" "must run in a subshell or background job" \
  "fd: the helper refuses to run in the hardening shell itself"
assert_not_contains "$out" "MAIN_SHELL_NOT_REACHED" "fd: ... and that refusal is fatal"
assert_contains "$out" "RC=78" "fd: ... with exit 78"

# ---------------------------------------------------------------------------
# N1 -- a promised uid boundary that is not real is refused.
# ---------------------------------------------------------------------------
echo "-- N1: a half-configured or non-root sealed store is refused --"
REPO="${TEST_TMP_ROOT}/repo-half"; STATE="${TEST_TMP_ROOT}/state-half"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  export SQUAD_POLICY_SEALED_DIR="$STATE-sealed"
  squad_policy_harden "$REPO"
  echo "NOT_REACHED"
'; echo "RC=$?")"
assert_contains "$out" "half-configured" "N1: SEALED_DIR without a seal channel is refused"
assert_contains "$out" "RC=78" "N1: ... with exit 78"

REPO="${TEST_TMP_ROOT}/repo-own"; STATE="${TEST_TMP_ROOT}/state-own"; make_repo "$REPO"
mkdir -p "${TEST_TMP_ROOT}/fake-sealed"
export FAKE_SEALED="${TEST_TMP_ROOT}/fake-sealed"
out="$(scenario "$REPO" "$STATE" '
  exec {SQUAD_POLICY_SEAL_FD}>/dev/null
  export SQUAD_POLICY_SEAL_FD SQUAD_POLICY_SEALED_DIR="$FAKE_SEALED"
  squad_policy_harden "$REPO"
  echo "NOT_REACHED"
'; echo "RC=$?")"
assert_contains "$out" "not a uid boundary" \
  "N1: a 'sealed' store owned by (or writable by) the session's own uid is refused"
assert_contains "$out" "RC=78" "N1: ... with exit 78"

echo "-- N1: worker/squad-agent refuses a sealed store with no sealed baseline --"
REPO="${TEST_TMP_ROOT}/repo-wrap"; STATE="${TEST_TMP_ROOT}/state-wrap"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" '
  squad_policy_harden "$REPO" >/dev/null
  wrap() { : > "$COPILOT_ARGV_DUMP"; SQUAD_AGENT_POLICY_ARGV_JSON="$PARITY_JSON" SQUAD_AGENT_REPO_DIR="$REPO" bash "$WRAPPER" -p x 2>&1; echo "WRAP_RC=$?"; echo "COPILOT_RAN=$([[ -s "$COPILOT_ARGV_DUMP" ]] && echo 1 || echo 0)"; }
  echo "== baseline"; wrap
  export SQUAD_POLICY_SEALED_DIR="$FAKE_SEALED"
  echo "== unsealed"; wrap
  printf "%s\n" "$SQUAD_POLICY_MCP_CONFIG_SHA256" > "$FAKE_SEALED/mcp-config.sha256"; : > "$FAKE_SEALED/sealed"
  echo "== sealed-match"; wrap
  printf "%s\n" "0000000000000000000000000000000000000000000000000000000000000000" > "$FAKE_SEALED/mcp-config.sha256"
  echo "== sealed-mismatch"; wrap
')"
section() { printf '%s\n' "$out" | awk -v s="== $1" '$0==s {p=1; next} /^== / {p=0} p'; }
assert_contains "$(section baseline)" "WRAP_RC=0" "wrapper control: no sealed store configured -> runs (0)"
assert_contains "$(section unsealed)" "WRAP_RC=78" "wrapper: sealed store configured but nothing sealed -> 78"
assert_contains "$(section unsealed)" "COPILOT_RAN=0" "wrapper: ... and copilot never ran"
assert_contains "$(section sealed-match)" "WRAP_RC=0" "wrapper: sealed baseline agrees with the session -> runs (0)"
assert_contains "$(section sealed-mismatch)" "WRAP_RC=78" "wrapper: sealed baseline disagrees -> 78"
assert_contains "$(section sealed-mismatch)" "COPILOT_RAN=0" "wrapper: ... and copilot never ran"

test_summary
