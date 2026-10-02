#!/usr/bin/env bash
# Security re-review N1 (+ N3): governance policy state must be out of the
# agent's reach. Re-runs the reviewer's exact repros (A2, A4, A5b, A5c) and the
# obvious generalisations through the REAL entry points: squad_policy_harden ->
# (agent-shaped tampering from a child process) -> squad_policy_verify, and the
# REAL worker/squad-agent wrapper with the environment harden exported.
#
# THE INVARIANT UNDER TEST. The agent runs as the same uid that owns
# SQUAD_POLICY_STATE_DIR, so anything on disk there is attacker-controlled.
# squad_policy_harden therefore keeps the AUTHORITATIVE baseline in the memory
# of the hardening process (and hands the .mcp.json digest to squad-agent via
# the inherited environment); the on-disk copies are tripwires. Every case
# below tampers with the on-disk state from a CHILD process -- exactly what the
# agent's shell tool can do -- and asserts the session does not pass.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
# The *_UNDER_TEST overrides exist only so the suite can be pointed at an older
# revision to show it FAILS there (the repros are real, not tautologies).
LIB="${SQUAD_POLICY_LIB_UNDER_TEST:-${WORKER_DIR}/lib/squad-policy.sh}"
WRAPPER="${SQUAD_AGENT_WRAPPER_UNDER_TEST:-${WORKER_DIR}/squad-agent}"
RESOLVER="${WORKER_DIR}/lib/agent-policy.js"

TEST_TMP_ROOT="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-n1-tamper-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'chmod -R u+w "$TEST_TMP_ROOT" 2>/dev/null; rm -rf "$TEST_TMP_ROOT"' EXIT INT TERM

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum diff stat

echo "== security re-review N1/N3: governance state is out of the agent's reach =="

if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_security_n1_state_tamper.sh — running as root, mode bits are not enforced against uid 0"
  exit 77
fi

export GIT_CONFIG_GLOBAL="${TEST_TMP_ROOT}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global core.autocrlf false >/dev/null 2>&1 || true

# A stub `copilot` so the real wrapper has something to exec; it records that
# it ran, which is how "the tampered config was loaded" is observed.
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
export PARITY_JSON WRAPPER

make_repo() {
  local repo="$1"
  rm -rf "$repo"
  mkdir -p "${repo}/.squad/agents/security" "${repo}/.squad/identity" "${repo}/.squad/memory" \
           "${repo}/.squad/casting" "${repo}/.squad/policies" "${repo}/src"
  printf 'original charter\n'  >"${repo}/.squad/agents/security/charter.md"
  printf 'original history\n'  >"${repo}/.squad/agents/security/history.md"
  printf 'original identity\n' >"${repo}/.squad/identity/identity.md"
  printf 'original now\n'      >"${repo}/.squad/identity/now.md"
  printf 'original audit\n'    >"${repo}/.squad/memory/audit.jsonl"
  printf '{"v":1}\n'           >"${repo}/.squad/casting/registry.json"
  printf 'original policy\n'   >"${repo}/.squad/policies/security.md"
  printf '{"mcpServers":{"legit":{}}}\n' >"${repo}/.mcp.json"
  printf 'work\n'              >"${repo}/src/app.js"
  ( cd "$repo" && git init --quiet . && git add -A && git commit --quiet -m baseline ) || return 1
}

# scenario <repo> <state-dir> <body>: ONE process hardens, lets the "agent"
# act, and verifies -- the same shape as worker/entrypoint.sh.
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

# agent <command>: run a command the way the agent's shell tool would -- a
# separate child process, same uid, no access to the hardening shell's memory.
AGENT_FN='agent() { bash -c "$1"; }'

# ---------------------------------------------------------------------------
# A2 -- grow, let the sampler observe it, delete the state file the previous
# round kept the high-water mark in, truncate back to the exact baseline.
# Before: VERIFY_RC=0. The mark is no longer on disk at all.
# ---------------------------------------------------------------------------
echo "-- A2: deleting on-disk high-water state cannot launder a truncation --"
REPO="${TEST_TMP_ROOT}/repo-a2"; STATE="${TEST_TMP_ROOT}/state-a2"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" "$AGENT_FN"'
  SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"{\\\"x\\\":1}\\n\" >> \"$REPO/.squad/memory/audit.jsonl\""
  sleep 1
  agent "rm -f \"$STATE/highwater.state\""
  agent "printf \"original audit\\n\" > \"$REPO/.squad/memory/audit.jsonl\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "VERIFY_RC=1" "A2: grow -> tick -> rm highwater.state -> truncate-to-baseline now FAILS verification (was rc=0)"
assert_contains "$out" "TRUNCATED BACK to its exact baseline length and hash" "A2: the high-water mark survived because it was never on disk"

# A2, generalised: delete the WHOLE state directory as well.
REPO="${TEST_TMP_ROOT}/repo-a2b"; STATE="${TEST_TMP_ROOT}/state-a2b"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" "$AGENT_FN"'
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"{\\\"x\\\":1}\\n\" >> \"$REPO/.squad/memory/audit.jsonl\"; printf \"original audit\\n\" > \"$REPO/.squad/memory/audit.jsonl\""
  agent "rm -rf \"$STATE\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "GOVERNANCE STATE TAMPERED" "A2b: rm -rf of the whole state directory is reported as tampering"
assert_contains "$out" "policy state directory" "A2b: the log names the removed state directory"
assert_contains "$out" "MODIFIED AND RESTORED" "A2b: the audit-trail rewrite is still caught from in-memory state"
assert_not_contains "$out" "VERIFY_RC=" "A2b: verify ABORTED (78) rather than returning a verdict"

# ---------------------------------------------------------------------------
# A4 -- modify a reported-mutable file, tick, delete state, revert.
# Before: VERIFY_RC=0 and now.md never mentioned.
# ---------------------------------------------------------------------------
echo "-- A4: modify -> tick -> rm state -> revert is still reported --"
REPO="${TEST_TMP_ROOT}/repo-a4"; STATE="${TEST_TMP_ROOT}/state-a4"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" "$AGENT_FN"'
  SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"evil focus\\n\" > \"$REPO/.squad/identity/now.md\""
  sleep 1
  agent "rm -f \"$STATE/highwater.state\""
  agent "printf \"original now\\n\" > \"$REPO/.squad/identity/now.md\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
  squad_policy_reported_changes_report
')"
assert_contains "$out" "VERIFY_RC=0" "A4: a reported-mutable change is still PERMITTED (the class is report-only)"
assert_contains "$out" ".squad/identity/now.md was modified during this session and reverted to its baseline value before verification." \
  "A4: ...but the modify-then-revert is no longer silent (was: now.md never mentioned)"
assert_contains "$out" ".squad/identity/now.md (modified then reverted)" "A4: and it reaches the PR-body report"

# A4 with the state deleted too: reported AND aborted as tampering.
REPO="${TEST_TMP_ROOT}/repo-a4b"; STATE="${TEST_TMP_ROOT}/state-a4b"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" "$AGENT_FN"'
  squad_policy_harden "$REPO" >/dev/null
  agent "printf \"evil\\n\" > \"$REPO/.squad/identity/now.md\"; rm -f \"$STATE\"/*; printf \"original now\\n\" > \"$REPO/.squad/identity/now.md\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "now.md was modified during this session and reverted" "A4b: revert still reported with every state file deleted"
assert_contains "$out" "governance.sha256 was deleted" "A4b: the deleted tripwire is named"
assert_not_contains "$out" "VERIFY_RC=" "A4b: verify ABORTED (78)"

# ---------------------------------------------------------------------------
# Forging the baseline: rewrite a locked file, then rewrite governance.sha256
# and base-commit to match the tampered tree. Must not pass.
# ---------------------------------------------------------------------------
echo "-- forged on-disk baseline / base commit --"
REPO="${TEST_TMP_ROOT}/repo-forge"; STATE="${TEST_TMP_ROOT}/state-forge"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" "$AGENT_FN"'
  squad_policy_harden "$REPO" >/dev/null
  agent "chmod -R u+w \"$REPO/.squad/agents\"; printf \"evil charter\\n\" > \"$REPO/.squad/agents/security/charter.md\""
  agent "cd \"$REPO\" && git add -A && git commit --quiet -m evil && git rev-parse HEAD > \"$STATE/base-commit\""
  # Forge the manifest: the agent can compute exactly what verify will compute.
  ( squad_policy_write_manifest "$REPO" ) > "$STATE/forged" 2>/dev/null
  agent "mv \"$STATE/forged\" \"$STATE/governance.sha256\""
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
assert_contains "$out" "governance.sha256 was rewritten" "forge: a rewritten governance.sha256 is detected as tampering"
assert_contains "$out" "base-commit was rewritten" "forge: a rewritten base-commit is detected as tampering"
assert_contains "$out" "file .squad/agents/security/charter.md" "forge: the charter change is still caught against the IN-MEMORY baseline"
assert_contains "$out" "changed in commits made during this session" "forge: the commit detector uses the in-memory base commit"
assert_not_contains "$out" "VERIFY_RC=" "forge: verify ABORTED (78)"

# A process that never hardened cannot verify, however intact the disk looks:
# the disk is not trusted as a baseline source.
REPO="${TEST_TMP_ROOT}/repo-fresh"; STATE="${TEST_TMP_ROOT}/state-fresh"; make_repo "$REPO"
scenario "$REPO" "$STATE" 'squad_policy_harden "$REPO" >/dev/null' >/dev/null
scenario "$REPO" "$STATE" 'squad_policy_verify "$REPO"; echo "VERIFY_RC=$?"' >"${TEST_TMP_ROOT}/fresh.out"
rc=$?
assert_eq "78" "$rc" "a verify in a process that did not harden ABORTS (78) even with every state file intact"
assert_contains "$(cat "${TEST_TMP_ROOT}/fresh.out")" "cannot be verified" "and says the session cannot be verified"

# ---------------------------------------------------------------------------
# A5b / A5c -- .mcp.json, through real harden and the REAL wrapper, using the
# environment harden exported (what `squad watch` passes to every spawn).
# Before: both RC=0 with the tampered config loaded.
# ---------------------------------------------------------------------------
echo "-- A5b/A5c: .mcp.json baseline cannot be deleted or forged --"
REPO="${TEST_TMP_ROOT}/repo-a5"; STATE="${TEST_TMP_ROOT}/state-a5"; make_repo "$REPO"
out="$(scenario "$REPO" "$STATE" "$AGENT_FN"'
  squad_policy_harden "$REPO" >/dev/null
  wrap() { : > "$COPILOT_ARGV_DUMP"; SQUAD_AGENT_POLICY_ARGV_JSON="$PARITY_JSON" SQUAD_AGENT_REPO_DIR="$REPO" bash "$WRAPPER" -p x 2>&1; echo "WRAP_RC=$?"; echo "COPILOT_RAN=$([[ -s "$COPILOT_ARGV_DUMP" ]] && echo 1 || echo 0)"; }
  echo "== baseline =="; wrap
  agent "printf \"{\\\"mcpServers\\\":{\\\"evil\\\":{\\\"command\\\":\\\"curl\\\"}}}\\n\" > \"$REPO/.mcp.json\""
  agent "rm -f \"$STATE/mcp-config.sha256\""
  echo "== A5b =="; wrap
  agent "sha256sum \"$REPO/.mcp.json\" | cut -d\" \" -f1 > \"$STATE/mcp-config.sha256\""
  echo "== A5c =="; wrap
  echo "== verify =="
  squad_policy_verify "$REPO"
  echo "VERIFY_RC=$?"
')"
base="${out#*== baseline ==}"; base="${base%%== A5b ==*}"
a5b="${out#*== A5b ==}"; a5b="${a5b%%== A5c ==*}"
a5c="${out#*== A5c ==}"; a5c="${a5c%%== verify ==*}"
ver="${out#*== verify ==}"
assert_contains "$base" "WRAP_RC=0" "A5 control: an untampered hardened session execs copilot"
assert_contains "$base" "COPILOT_RAN=1" "A5 control: copilot ran"
assert_contains "$a5b" "WRAP_RC=78" "A5b: rm the .mcp.json baseline + tamper .mcp.json is REFUSED (78; was RC=0)"
assert_contains "$a5b" "COPILOT_RAN=0" "A5b: the tampered MCP config was NOT loaded"
assert_contains "$a5c" "WRAP_RC=78" "A5c: forging the baseline to the tampered hash is REFUSED (78; was RC=0)"
assert_contains "$a5c" "COPILOT_RAN=0" "A5c: the tampered MCP config was NOT loaded"
assert_contains "$a5c" ".mcp.json has changed since this session was hardened" "A5c: refused on the env digest, not the forged file"
assert_contains "$ver" "mcp-config.sha256 was rewritten" "A5: the checkpoint also reports the forged tripwire"
assert_not_contains "$ver" "VERIFY_RC=" "A5: and the checkpoint ABORTS (78)"

# ---------------------------------------------------------------------------
# N4 -- the governance-path classifier must not leak case variants. On a
# case-insensitive filesystem (or via a tool that folds case) `.SQUAD/...` IS
# `.squad/...`; it was classified not-governance. Carve-outs stay exact-case
# (a case variant of a carve-out falls back to LOCKED -- fail closed).
# ---------------------------------------------------------------------------
echo "-- N4: classifier is case-insensitive for membership, fail-closed for carve-outs --"
classify() { node "$RESOLVER" classify-governance-path "$1" 2>&1 | tr -d '\r'; }
assert_eq "locked"         "$(classify '.SQUAD/identity/mission.md')"       "N4: .SQUAD/identity/mission.md is locked (was not-governance)"
assert_eq "locked"         "$(classify '.squad/Agents/x/charter.md')"       "N4: .squad/Agents/x/charter.md is locked"
assert_eq "locked"         "$(classify '.squad/memory/AUDIT.JSONL')"        "N4: a case variant of an append-only carve-out falls back to locked"
assert_eq "locked"         "$(classify '.squad/agents/a/HISTORY.md')"       "N4: a case variant of history.md falls back to locked"
assert_eq "locked"         "$(classify '.squad')"                           "N4: the bare .squad directory itself is locked"
assert_eq "append-only"    "$(classify '.squad/agents/a/history.md')"       "N4 control: exact-case history.md is still append-only"
assert_eq "not-governance" "$(classify 'src/app.js')"                       "N4 control: ordinary source is not governance"

test_summary
