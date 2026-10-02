#!/usr/bin/env bash
# Security re-review N1, layer 0: the governance state is held behind a REAL uid
# boundary. Requires real root (it creates a root-owned store and drops to an
# unprivileged uid exactly as worker/entrypoint.sh does), so it SKIPS LOUDLY
# everywhere else. Run it on Linux as root, e.g. from Windows:
#
#   wsl -u root -e bash worker/tests/test_security_n1b_root_sealed_state.sh
#
# What runs is the REAL code: squad_root_seal_policy_state() and log() are
# extracted verbatim from worker/entrypoint.sh, the real
# worker/lib/squad-policy.sh hardens and verifies, the real worker/squad-agent
# wraps copilot, and the drop is the entrypoint's own `env -u HOME runuser -p`.
# The unprivileged side runs as `nobody` (the image's `squad` user does not
# exist on a test host; any non-root uid is the same boundary).
#
# Proven here, as the dropped uid:
#   - the store is a root-owned 0711 directory of root-owned 0644 files;
#   - rm / overwrite / mv / create / rm -rf / chmod / symlink-replace of the
#     sealed copies ALL fail, and the session still verifies cleanly;
#   - A2, A4, A5b, A5c (security-rereview.md) aimed at the sealed copies are
#     impossible, and aimed at the agent-writable copies are blocked (78);
#   - a pre-harden holder of the seal channel that seals FIRST with forged
#     content makes harden abort (78) -- a DoS, never a bypass;
#   - F7: the governance report lands in the root-owned store on the exit-78
#     violation path and on the TAMPERED path, and the agent cannot delete it.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== security re-review N1 layer 0: root-sealed governance state (real uid boundary) =="

if [[ "$(id -u)" -ne 0 ]]; then
  echo "SKIP: test_security_n1b_root_sealed_state.sh — NOT RUN: needs real root to create a root-owned store and drop privileges."
  echo "SKIP:   run it as root on Linux, e.g.: wsl -u root -e bash worker/tests/test_security_n1b_root_sealed_state.sh"
  exit 77
fi
for dep in runuser node git sha256sum base64 stat awk; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "SKIP: test_security_n1b_root_sealed_state.sh — NOT RUN: missing ${dep}"
    exit 77
  fi
done
if ! id nobody >/dev/null 2>&1; then
  echo "SKIP: test_security_n1b_root_sealed_state.sh — NOT RUN: no 'nobody' user to drop to"
  exit 77
fi

WORK="$(mktemp -d /tmp/squad-n1b.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
chmod 0755 "$WORK"
# A private, readable copy of the worker (the checkout may live under a home
# directory the dropped uid cannot traverse). CRs are stripped so a Windows
# checkout runs as it does in the image.
cp -r "$WORKER_DIR" "${WORK}/worker"
find "${WORK}/worker" -type f \( -name '*.sh' -o -name 'squad-agent' -o -name '*.js' \) \
  -exec sed -i 's/\r$//' {} +
chmod -R a+rX "${WORK}/worker"
W="${WORK}/worker"
mkdir -p "${WORK}/run" "${WORK}/cases" "${WORK}/home" "${WORK}/bin"
chmod 0755 "${WORK}/run"
chown nobody "${WORK}/cases" "${WORK}/home"

cat >"${WORK}/bin/copilot" <<'COPILOT'
#!/usr/bin/env bash
printf 'COPILOT_RAN %s\n' "$*" >> "${COPILOT_ARGV_DUMP:?}"
exit 0
COPILOT
chmod 0755 "${WORK}/bin/copilot"
# The dropped uid needs node, which may live under a home it cannot traverse.
cp "$(readlink -f "$(command -v node)")" "${WORK}/bin/node" && chmod 0755 "${WORK}/bin/node"

extract_fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' "${W}/entrypoint.sh"; }
ROOT_FNS="$(extract_fn log)"$'\n'"$(extract_fn squad_root_seal_policy_state)"
assert_contains "$ROOT_FNS" "squad_policy_sealer_start" \
  "worker/entrypoint.sh defines squad_root_seal_policy_state() and it starts the root sealer"
call_line="$(grep -n '^  squad_root_seal_policy_state$' "${W}/entrypoint.sh" | head -1 | cut -d: -f1)"
drop_line="$(grep -n 'exec env -u HOME runuser -p' "${W}/entrypoint.sh" | head -1 | cut -d: -f1)"
assert_eq "1" "$([[ -n "$call_line" && -n "$drop_line" && "$call_line" -lt "$drop_line" ]] && echo 1 || echo 0)" \
  "worker/entrypoint.sh creates the root-owned store BEFORE the runuser privilege drop"
ENTRY_FNS=""
for fn in log squad_policy_checkpoint squad_policy_on_abort squad_watch_governance_report_if_any; do
  ENTRY_FNS+="$(extract_fn "$fn")"$'\n'
done
printf '%s\n' "$ENTRY_FNS" >"${WORK}/entry-fns.sh"

PARITY_JSON="$(env -u SQUAD_COPILOT_FLAGS -u SQUAD_WATCH_STRICT_POLICY \
  SQUAD_MODE=watch SQUAD_DISPATCH_SOURCE=watch SQUAD_COPILOT_FLAGS="" SQUAD_EXECUTION_MODE=aca-job \
  SQUAD_WATCH_STRICT_POLICY=false node "${W}/lib/agent-policy.js" watch-agent-parity-argv-json)"

# ---------------------------------------------------------------------------
# The unprivileged half. Runs as `nobody`, holding only what the entrypoint
# hands across runuser: the environment and the seal descriptor.
# ---------------------------------------------------------------------------
cat >"${WORK}/driver.sh" <<'DRIVER'
set -uo pipefail
case_name="$1"
REPO="${WORK}/cases/repo-${case_name}"
STATE="${WORK}/cases/state-${case_name}"
export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
export SQUAD_POLICY_STATE_DIR="$STATE" SQUAD_POLICY_RESOLVER="${W}/lib/agent-policy.js"
export GIT_CONFIG_GLOBAL="${HOME}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.com
export PATH="${WORK}/bin:${PATH}" COPILOT_ARGV_DUMP="${WORK}/cases/copilot-${case_name}.ran"
git config --global init.defaultBranch main
echo "DROPPED_UID=$(id -u)"
D="${SQUAD_POLICY_SEALED_DIR:-}"

mkdir -p "${REPO}/.squad/agents/security" "${REPO}/.squad/identity" "${REPO}/.squad/memory" \
         "${REPO}/.squad/casting" "${REPO}/.squad/policies" "${REPO}/src"
printf 'original charter\n'  >"${REPO}/.squad/agents/security/charter.md"
printf 'original identity\n' >"${REPO}/.squad/identity/identity.md"
printf 'original now\n'      >"${REPO}/.squad/identity/now.md"
printf 'original audit\n'    >"${REPO}/.squad/memory/audit.jsonl"
printf '{"v":1}\n'           >"${REPO}/.squad/casting/registry.json"
printf 'original policy\n'   >"${REPO}/.squad/policies/security.md"
printf '{"mcpServers":{"legit":{}}}\n' >"${REPO}/.mcp.json"
printf 'work\n'              >"${REPO}/src/app.js"
( cd "$REPO" && git init --quiet . && git add -A && git commit --quiet -m baseline )

source "${W}/lib/squad-policy.sh"
source "${WORK}/entry-fns.sh"
REPO_DIR="$REPO"
agent() { ( squad_policy_exec_agent bash -c "$1" ); }
try() { if agent "$1" 2>/dev/null; then echo "ATTACK_SUCCEEDED: $2"; else echo "attack refused: $2"; fi; }
wrap() {
  : >"$COPILOT_ARGV_DUMP"
  ( squad_policy_exec_agent env SQUAD_AGENT_POLICY_ARGV_JSON="$PARITY_JSON" SQUAD_AGENT_REPO_DIR="$REPO" \
      bash "${W}/squad-agent" -p x ) 2>&1
  echo "WRAP_RC=$?"
  echo "COPILOT_RAN=$([[ -s "$COPILOT_ARGV_DUMP" ]] && echo 1 || echo 0)"
}

case "$case_name" in
  clean)
    squad_policy_harden "$REPO"
    echo "DIR_STAT=$(stat -c '%u %a' "$D")"
    for f in governance.sha256 mcp-config.sha256 base-commit sealed; do echo "FILE_STAT $f=$(stat -c '%u %a' "$D/$f")"; done
    echo "SEALED_MCP_MATCHES=$([[ "$(<"$D/mcp-config.sha256")" == "$SQUAD_POLICY_MCP_DIGEST" ]] && echo 1 || echo 0)"
    echo "AGENT_SEES_SEAL_FD=[$( ( squad_policy_exec_agent bash -c 'printf %s "${SQUAD_POLICY_SEAL_FD:-}"' ) )]"
    squad_policy_verify "$REPO"; echo "VERIFY_RC=$?"
    ;;
  attack)
    squad_policy_harden "$REPO" >/dev/null
    try "rm -f '$D/governance.sha256'"                 "rm the sealed manifest"
    try "printf x > '$D/governance.sha256'"            "overwrite the sealed manifest"
    try "printf x >> '$D/mcp-config.sha256'"           "append to the sealed .mcp.json digest"
    try "mv '$D/base-commit' '$D/base-commit.x'"       "rename the sealed base commit"
    try "touch '$D/new-file'"                          "create a file in the store"
    try "rm -f '$D/sealed'"                            "rm the sealed marker"
    try "rm -rf '$D' && test ! -e '$D'"                "rm -rf the whole store"
    try "chmod 0777 '$D'"                              "chmod the store"
    try "ln -sf /dev/null '$D/mcp-config.sha256'"      "symlink-replace the sealed digest"
    try "printf x >> '$D/reported-changes.md'"         "write the governance report directly"
    echo "SEAL_PROBLEMS=[$(squad_policy_seal_problems)]"
    squad_policy_verify "$REPO"; echo "VERIFY_RC=$?"
    ;;
  a2)
    SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
    squad_policy_harden "$REPO" >/dev/null
    agent "printf '{\"x\":1}\n' >> '$REPO/.squad/memory/audit.jsonl'"
    sleep 1
    try "rm -f '$D/governance.sha256'" "A2 against the sealed store"
    agent "rm -f '$STATE/highwater.state'"
    agent "printf 'original audit\n' > '$REPO/.squad/memory/audit.jsonl'"
    squad_policy_verify "$REPO"; echo "VERIFY_RC=$?"
    ;;
  a4)
    SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
    squad_policy_harden "$REPO" >/dev/null
    agent "printf 'evil focus\n' > '$REPO/.squad/identity/now.md'"
    sleep 1
    try "rm -f '$D/governance.sha256' '$D/mcp-config.sha256' '$D/base-commit' '$D/sealed'" "A4 against the sealed store"
    echo "AGENT_CAN_LIST_STORE=$(agent "ls '$D'" >/dev/null 2>&1 && echo 1 || echo 0)"
    agent "rm -f '$STATE'/*"
    agent "printf 'original now\n' > '$REPO/.squad/identity/now.md'"
    squad_policy_verify "$REPO"; echo "VERIFY_RC=$?"
    ;;
  a5)
    squad_policy_harden "$REPO" >/dev/null
    echo "== baseline"; wrap
    agent "printf '{\"mcpServers\":{\"evil\":{\"command\":\"curl\"}}}\n' > '$REPO/.mcp.json'"
    try "rm -f '$D/mcp-config.sha256'" "A5b against the sealed store"
    agent "rm -f '$STATE/mcp-config.sha256'"
    echo "== a5b"; wrap
    try "sha256sum '$REPO/.mcp.json' | cut -d' ' -f1 > '$D/mcp-config.sha256'" "A5c against the sealed store"
    agent "sha256sum '$REPO/.mcp.json' | cut -d' ' -f1 > '$STATE/mcp-config.sha256'"
    echo "== a5c-env"; SQUAD_POLICY_MCP_CONFIG_SHA256="$(sha256sum "$REPO/.mcp.json" | cut -d' ' -f1)" wrap
    echo "== end"
    ;;
  forged)
    # A bootstrap-era process still holding the seal channel seals FIRST.
    fake="$(printf 'forged\n' | base64 -w0)"
    for n in governance.sha256 mcp-config.sha256 base-commit; do
      printf 'FILE %s %s\n' "$n" "$fake" >&"$SQUAD_POLICY_SEAL_FD"
    done
    printf 'SEAL\n' >&"$SQUAD_POLICY_SEAL_FD"
    sleep 0.5
    squad_policy_harden "$REPO"
    echo "NOT_REACHED"
    ;;
  report-violation|report-tamper)
    squad_policy_harden "$REPO" >/dev/null
    SQUAD_POLICY_VERIFIED=0; SQUAD_POLICY_IN_VERIFY=0
    agent "printf 'new focus\n' > '$REPO/.squad/identity/now.md'"
    if [[ "$case_name" == report-violation ]]; then
      agent "chmod u+w '$REPO/.squad/policies/security.md' && printf 'evil\n' >> '$REPO/.squad/policies/security.md'"
    else
      agent "rm -f '$STATE/governance.sha256'"
    fi
    squad_policy_checkpoint
    echo "NOT_REACHED"
    ;;
esac
DRIVER

# run_case <name>: root creates the store with the entrypoint's own function,
# then drops exactly as the entrypoint does. Prints the store path first.
run_case() {
  (
    export WORK W PARITY_JSON
    eval "$ROOT_FNS"
    SQUAD_POLICY_LIB="${W}/lib/squad-policy.sh" SQUAD_POLICY_SEAL_BASE="${WORK}/run" squad_root_seal_policy_state
    echo "SEALED_DIR=${SQUAD_POLICY_SEALED_DIR}"
    env -u HOME runuser -p -u nobody -- env HOME="${WORK}/home" bash "${WORK}/driver.sh" "$1"
    echo "RC=$?"
  ) 2>&1
}
sealed_dir_of() { printf '%s\n' "$1" | sed -n 's/^SEALED_DIR=//p' | head -1; }

echo "-- clean session: the store is root-owned and the dropped uid only reads it --"
out="$(run_case clean)"
assert_contains "$out" "DROPPED_UID=$(id -u nobody)" "the driver really ran as the dropped uid"
assert_contains "$out" "DIR_STAT=0 711" "the store is a root-owned 0711 directory"
for f in governance.sha256 mcp-config.sha256 base-commit sealed; do
  assert_contains "$out" "FILE_STAT ${f}=0 644" "sealed ${f} is a root-owned 0644 file"
done
assert_contains "$out" "SEALED_MCP_MATCHES=1" "the sealed .mcp.json digest is this session's harden-time digest"
assert_contains "$out" "Governance baseline sealed in root-owned" "harden reports the seal"
assert_contains "$out" "AGENT_SEES_SEAL_FD=[]" "the agent is not handed the seal channel"
assert_contains "$out" "VERIFY_RC=0" "a clean session verifies"
assert_contains "$out" "RC=0" "a clean session exits 0"

echo "-- every write the dropped uid can attempt against the store fails --"
out="$(run_case attack)"
assert_not_contains "$out" "ATTACK_SUCCEEDED" "no rm/overwrite/mv/create/rm -rf/chmod/symlink/report write succeeded"
assert_eq "10" "$(printf '%s\n' "$out" | grep -c '^attack refused')" "all 10 attack primitives were attempted and refused"
assert_contains "$out" "SEAL_PROBLEMS=[]" "the sealed copies are intact afterwards"
assert_contains "$out" "VERIFY_RC=0" "and the session still verifies cleanly (nothing actually changed)"
D="$(sealed_dir_of "$out")"
assert_eq "0 711" "$(stat -c '%u %a' "$D" 2>/dev/null)" "root confirms: the store is still root-owned 0711"

echo "-- A2: rm high-water state + truncate-to-baseline --"
out="$(run_case a2)"
assert_contains "$out" "attack refused: A2 against the sealed store" "A2: the sealed copy cannot be deleted at all"
assert_contains "$out" "TRUNCATED BACK to its exact baseline length and hash" "A2: the truncation is still detected"
assert_contains "$out" "VERIFY_RC=1" "A2: blocked -- verification FAILS (was rc=0)"
assert_not_contains "$out" "VERIFY_RC=0" "A2: verify never passes"

echo "-- A4: modify -> tick -> rm state -> revert --"
out="$(run_case a4)"
assert_contains "$out" "attack refused: A4 against the sealed store" "A4: the sealed store cannot be emptied"
assert_contains "$out" "AGENT_CAN_LIST_STORE=0" "A4: the dropped uid cannot even list the store (0711)"
assert_contains "$out" "now.md was modified during this session and reverted" "A4: the revert is reported"
assert_contains "$out" "RC=78" "A4: deleting the agent-writable state aborts (78; was rc=0, silent)"

echo "-- A5b/A5c: .mcp.json baseline --"
out="$(run_case a5)"
section() { printf '%s\n' "$out" | awk -v s="== $1" '$0==s {p=1; next} /^== / {p=0} p'; }
assert_contains "$(section baseline)" "WRAP_RC=0" "A5 control: an untampered session runs copilot through the real wrapper"
assert_contains "$(section baseline)" "COPILOT_RAN=1" "A5 control: copilot ran"
assert_contains "$out" "attack refused: A5b against the sealed store" "A5b: the sealed digest cannot be deleted"
assert_contains "$(section a5b)" "WRAP_RC=78" "A5b: tampered .mcp.json with the agent-writable baseline removed is REFUSED (78; was 0)"
assert_contains "$(section a5b)" "COPILOT_RAN=0" "A5b: the tampered config was not loaded"
assert_contains "$out" "attack refused: A5c against the sealed store" "A5c: the sealed digest cannot be rewritten"
assert_contains "$(section a5c-env)" "WRAP_RC=78" "A5c: even with BOTH the env digest and the state file forged, the wrapper refuses (78)"
assert_contains "$(section a5c-env)" "COPILOT_RAN=0" "A5c: the tampered config was not loaded"
assert_contains "$(section a5c-env)" "root-sealed .mcp.json baseline" "A5c: refused on the ROOT-SEALED digest -- the one copy the agent cannot forge"

echo "-- a forged early SEAL is a denial of service, never a bypass --"
out="$(run_case forged)"
assert_contains "$out" "does not match" "forged: harden detects that someone sealed first"
assert_not_contains "$out" "NOT_REACHED" "forged: the session never starts"
assert_contains "$out" "RC=78" "forged: exit 78"

echo "-- F7: the report reaches the root-owned store on the exit-78 paths --"
for c in report-violation report-tamper; do
  out="$(run_case "$c")"
  D="$(sealed_dir_of "$out")"
  assert_contains "$out" "RC=78" "${c}: the session fails (78)"
  assert_not_contains "$out" "NOT_REACHED" "${c}: nothing runs after the failure"
  assert_eq "0 644" "$(stat -c '%u %a' "${D}/reported-changes.md" 2>/dev/null)" "${c}: the report is a root-owned 0644 file in the store"
  report="$(cat "${D}/reported-changes.md" 2>/dev/null)"
  assert_contains "$report" ".squad/identity/now.md" "${c}: the report lists the reported-mutable change"
  runuser -u nobody -- rm -f "${D}/reported-changes.md" 2>/dev/null
  assert_eq "1" "$([[ -f "${D}/reported-changes.md" ]] && echo 1 || echo 0)" "${c}: the dropped uid cannot delete the report"
  if [[ "$c" == report-violation ]]; then
    assert_contains "$report" "Verdict: governance VIOLATION" "${c}: the report carries the violation verdict"
  else
    assert_contains "$report" "Verdict: governance state TAMPERED" "${c}: the report carries the tamper verdict"
  fi
done

test_summary
