#!/usr/bin/env bash
# Tests for the per-role model pin: which model each Copilot launch runs on.
#
# WHAT THIS SUITE IS ACTUALLY GUARDING
# ------------------------------------
# `copilot` used to be launched with no `--model` unless an operator typed one
# in, so which model ran a session was whatever the CLI defaulted to that day.
# The pin makes it the repository's own, per-role, decision:
#
#   - watch / triage / loop  -> the `ralph` role's model (the watch prompt IS
#     Ralph's charter);
#   - prompt / new-project / smoke (every Ralph-dispatched session is a
#     `prompt` session) -> the `lead` (coordinator) role's model;
#   - read from the repository's .squad/config.json, resolved ONCE before any
#     launch, never from a model list baked into the image;
#   - an operator override is accepted only when it names the SAME model; a
#     conflicting or malformed one stops the session (78) with no fallback;
#   - a pinned model that Copilot cannot run (unavailable, over quota) ends
#     the session with Copilot's own status: no retry on another model, and no
#     success inferred from output text.
#
# The assertions are about the RESOLVED DECISION and the argv Copilot actually
# receives. Three layers, each proving something the others cannot:
#
#   1. agent-policy.js `model-pin`, through its real CLI: the absent / matching
#      / conflicting / invalid override matrix and the policy-file cases.
#   2. The REAL model-resolution fragment of worker/entrypoint.sh and the REAL
#      `prompt)`, `new-project)`, `loop)` and `watch|triage)` case blocks,
#      extracted from the file (the awk-range technique the F3 and deadline
#      suites use) and run with a stub `copilot`/`squad` on PATH that dump the
#      argv they receive. For watch and loop the stub `squad` does what Squad
#      does with `--agent-cmd` -- spawn it with `-p <prompt>` appended -- and
#      the command it spawns is the REAL worker/squad-agent, so the argv that
#      reaches the stub `copilot` is the one production would give Copilot.
#   3. Wiring: the entrypoint resolves the model once, after hardening and
#      before the case dispatch, and no launch carries a model of its own.
#
# Fixtures use generic role ids and made-up model ids. No product persona name
# and no real model catalog is assumed anywhere in this file.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WORKER_DIR}/.." && pwd)"
RESOLVER="${WORKER_DIR}/lib/agent-policy.js"
POLICY_LIB="${WORKER_DIR}/lib/squad-policy.sh"
DEADLINE_LIB="${WORKER_DIR}/lib/squad-deadline.sh"
ENTRYPOINT="${WORKER_DIR}/entrypoint.sh"
WRAPPER="${WORKER_DIR}/squad-agent"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== model pin (per-role --model for direct, watch and loop launches) =="

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-model-pin-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

# Made-up ids. The suite must hold for a model this image has never heard of.
LEAD_MODEL="model-alpha"
RALPH_MODEL="model-beta"
DEFAULT_MODEL="model-gamma"

mk_repo() {
  local name="$1" config="$2"
  local dir="${WORK}/repo-${name}"
  mkdir -p "${dir}/.squad"
  if [[ "$config" != "__NONE__" ]]; then
    printf '%s\n' "$config" > "${dir}/.squad/config.json"
  fi
  printf '%s' "$dir"
}

REPO_ROLES="$(mk_repo roles '{"defaultModel":"model-gamma","agentModelOverrides":{"lead":"model-alpha","ralph":"model-beta","other-role":"model-gamma"}}')"
REPO_DEFAULT="$(mk_repo default '{"defaultModel":"model-gamma"}')"
REPO_NO_RALPH="$(mk_repo no-ralph '{"agentModelOverrides":{"lead":"model-alpha"}}')"
REPO_AUTO="$(mk_repo auto '{"defaultModel":"model-gamma","agentModelOverrides":{"lead":"auto","ralph":"AUTO"}}')"
REPO_NONE="$(mk_repo none __NONE__)"
REPO_UNSEEN="$(mk_repo unseen '{"agentModelOverrides":{"lead":"model-from-a-future-catalog-9.9"}}')"
REPO_CASE_DUP_SAME="$(mk_repo case-dup-same '{"agentModelOverrides":{"lead":"model-alpha","Lead":"MODEL-ALPHA"}}')"

# --- resolver CLI helper ----------------------------------------------------
# pin <mode> <repo> [NAME=value ...] -> PIN_OUT (stdout), PIN_ERR (stderr),
# PIN_RC, and PIN_L[0..3] = status, role, model, source.
# Every variable the resolver reads is cleared first so a stray export in the
# shell running this suite cannot change an answer.
pin() {
  local mode="$1" repo="$2"
  shift 2
  PIN_OUT="$(env -u SQUAD_MODEL -u SQUAD_AGENT_MODEL -u COPILOT_MODEL -u SQUAD_COPILOT_FLAGS \
      -u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_GITHUB_TOKEN \
      -u SQUAD_COPILOT_TOKEN_PROVENANCE -u SQUAD_ALLOW_SHARED_COPILOT_TOKEN \
      SQUAD_MODE="$mode" SQUAD_DISPATCH_SOURCE=actions "$@" \
      node "$RESOLVER" model-pin "$repo" 2>"${WORK}/pin.err")"
  PIN_RC=$?
  PIN_ERR="$(cat "${WORK}/pin.err")"
  PIN_L=()
  if [[ -n "$PIN_OUT" ]]; then
    mapfile -t PIN_L <<<"$PIN_OUT"
  fi
}

expect_pinned() {
  local label="$1" role="$2" model="$3"
  assert_eq "0" "$PIN_RC" "${label}: resolves (exit 0)"
  assert_eq "pinned" "${PIN_L[0]:-}" "${label}: status is pinned"
  assert_eq "$role" "${PIN_L[1]:-}" "${label}: the role is '${role}'"
  assert_eq "$model" "${PIN_L[2]:-}" "${label}: the model is '${model}'"
}

expect_unpinned() {
  local label="$1" role="$2"
  assert_eq "0" "$PIN_RC" "${label}: resolves (exit 0)"
  assert_eq "unpinned" "${PIN_L[0]:-}" "${label}: status is unpinned"
  assert_eq "$role" "${PIN_L[1]:-}" "${label}: the role is '${role}'"
  assert_eq "" "${PIN_L[2]:-}" "${label}: no model is chosen"
}

# A refusal is exit 78 with NOTHING on stdout -- no model a caller could use
# as a fallback -- and a diagnostic on stderr.
expect_refused() {
  local label="$1" needle="$2"
  assert_eq "78" "$PIN_RC" "${label}: refused (exit 78)"
  assert_eq "" "$PIN_OUT" "${label}: no model is printed, so there is nothing to fall back to"
  assert_contains "$PIN_ERR" "$needle" "${label}: the diagnostic says why"
}

# ===========================================================================
# 1. Which role a mode runs as
# ===========================================================================
echo "-- role per mode --"

role_of() {
  env -u SQUAD_MODEL SQUAD_MODE="$1" node "$RESOLVER" model-role 2>&1
}
for m in watch triage loop; do
  assert_eq "ralph" "$(role_of "$m")" "mode '${m}' runs as the work-monitor role (its prompt is Ralph's charter)"
done
for m in prompt new-project smoke; do
  assert_eq "lead" "$(role_of "$m")" "mode '${m}' runs as the coordinator role"
done
for m in ralph telemetry-smoke shell; do
  assert_eq "" "$(role_of "$m")" "mode '${m}' starts no Copilot session, so it has no role"
done

# ===========================================================================
# 2. Policy only: the model comes from the repository, per role
# ===========================================================================
echo "-- policy resolution (no operator override) --"

pin watch "$REPO_ROLES"
expect_pinned "watch" ralph "$RALPH_MODEL"
assert_contains "${PIN_L[3]:-}" "agentModelOverrides.ralph" "watch: the source names the config entry the model came from"
pin triage "$REPO_ROLES"
expect_pinned "triage" ralph "$RALPH_MODEL"
pin loop "$REPO_ROLES"
expect_pinned "loop" ralph "$RALPH_MODEL"
for m in prompt new-project smoke; do
  pin "$m" "$REPO_ROLES"
  expect_pinned "$m" lead "$LEAD_MODEL"
done
assert_ne "$LEAD_MODEL" "$RALPH_MODEL" "the fixture really gives the two roles different models (the pin is per role, not one global model)"

pin watch "$REPO_DEFAULT"
expect_pinned "defaultModel applies to a role with no entry of its own" ralph "$DEFAULT_MODEL"
assert_contains "${PIN_L[3]:-}" "defaultModel" "defaultModel: the source says it was the default"

pin watch "$REPO_NO_RALPH"
expect_unpinned "no entry for the role and no defaultModel" ralph
assert_contains "${PIN_L[3]:-}" "declares no model" "unpinned: the reason is stated, not silent"
pin prompt "$REPO_NO_RALPH"
expect_pinned "a role that IS declared stays pinned beside one that is not" lead "$LEAD_MODEL"

pin watch "$REPO_AUTO"
expect_unpinned "an explicit 'auto' for the role is not a pin" ralph
pin prompt "$REPO_AUTO"
expect_unpinned "'auto' for the role beats an explicit defaultModel (the role's own entry wins)" lead

pin prompt "$REPO_NONE"
expect_unpinned "a repository with no .squad/config.json" lead
pin watch "$REPO_NONE"
expect_unpinned "a repository with no .squad/config.json (watch)" ralph

pin prompt "$REPO_UNSEEN"
expect_pinned "a model no catalog in this image knows is still the approved model" lead "model-from-a-future-catalog-9.9"

pin prompt "$REPO_CASE_DUP_SAME"
expect_pinned "the same role named twice with the same model (differing only in case) is not ambiguous" lead "model-alpha"

for m in ralph telemetry-smoke shell; do
  pin "$m" "$REPO_ROLES"
  assert_eq "0" "$PIN_RC" "mode '${m}': resolves"
  assert_eq "not-applicable" "${PIN_L[0]:-}" "mode '${m}': no Copilot session, nothing to pin"
  assert_eq "" "${PIN_L[2]:-}" "mode '${m}': no model"
done

# ===========================================================================
# 3. Operator overrides: absent / matching / conflicting / invalid
# ===========================================================================
echo "-- operator overrides --"

# --- matching: accepted, and the policy's own spelling is what is used --------
pin prompt "$REPO_ROLES" SQUAD_MODEL="$LEAD_MODEL"
expect_pinned "SQUAD_MODEL matching the policy" lead "$LEAD_MODEL"
assert_contains "${PIN_L[3]:-}" "matches" "a matching override is reported as matching"
pin prompt "$REPO_ROLES" SQUAD_MODEL="MODEL-ALPHA"
expect_pinned "SQUAD_MODEL differing only in case" lead "$LEAD_MODEL"
pin prompt "$REPO_ROLES" SQUAD_AGENT_MODEL="$LEAD_MODEL"
expect_pinned "a pre-set SQUAD_AGENT_MODEL matching the policy" lead "$LEAD_MODEL"
pin prompt "$REPO_ROLES" COPILOT_MODEL="$LEAD_MODEL"
expect_pinned "COPILOT_MODEL matching the policy" lead "$LEAD_MODEL"
pin prompt "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL}"
expect_pinned "'--model X' in SQUAD_COPILOT_FLAGS matching the policy" lead "$LEAD_MODEL"
pin prompt "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model=${LEAD_MODEL}"
expect_pinned "'--model=X' in SQUAD_COPILOT_FLAGS matching the policy" lead "$LEAD_MODEL"
pin prompt "$REPO_ROLES" SQUAD_MODEL="$LEAD_MODEL" COPILOT_MODEL="$LEAD_MODEL" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL}"
expect_pinned "several overrides, all matching" lead "$LEAD_MODEL"
pin watch "$REPO_ROLES" SQUAD_MODEL="$RALPH_MODEL"
expect_pinned "watch: SQUAD_MODEL matching the ralph role's model" ralph "$RALPH_MODEL"

# --- conflicting: refused, naming both sides, never a fallback ----------------
pin prompt "$REPO_ROLES" SQUAD_MODEL="$RALPH_MODEL"
expect_refused "SQUAD_MODEL naming another role's model" "SQUAD_MODEL='${RALPH_MODEL}'"
assert_contains "$PIN_ERR" "'${LEAD_MODEL}'" "conflict: the policy's model is named too"
assert_contains "$PIN_ERR" "no fallback" "conflict: the message says nothing falls back"
pin watch "$REPO_ROLES" SQUAD_MODEL="$LEAD_MODEL"
expect_refused "watch: SQUAD_MODEL naming the lead role's model (one global model is NOT accepted)" "role 'ralph'"
pin prompt "$REPO_ROLES" SQUAD_MODEL="model-unrelated"
expect_refused "SQUAD_MODEL naming a model the policy never mentions" "model-unrelated"
pin prompt "$REPO_ROLES" SQUAD_AGENT_MODEL="$RALPH_MODEL"
expect_refused "a pre-set SQUAD_AGENT_MODEL that conflicts" "SQUAD_AGENT_MODEL="
pin prompt "$REPO_ROLES" COPILOT_MODEL="$RALPH_MODEL"
expect_refused "COPILOT_MODEL that conflicts" "COPILOT_MODEL="
pin prompt "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${RALPH_MODEL}"
expect_refused "'--model X' in SQUAD_COPILOT_FLAGS that conflicts" "SQUAD_COPILOT_FLAGS --model"
pin prompt "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model=${RALPH_MODEL}"
expect_refused "'--model=X' in SQUAD_COPILOT_FLAGS that conflicts" "SQUAD_COPILOT_FLAGS --model"
pin prompt "$REPO_ROLES" SQUAD_MODEL="$LEAD_MODEL" COPILOT_MODEL="$RALPH_MODEL"
expect_refused "one override matching does not excuse another that conflicts" "COPILOT_MODEL="
pin prompt "$REPO_DEFAULT" SQUAD_MODEL="$LEAD_MODEL"
expect_refused "an override that disagrees with defaultModel" "defaultModel"

# --- no repository policy to arbitrate: operator overrides stand, but must agree
pin prompt "$REPO_NONE" SQUAD_MODEL="$RALPH_MODEL"
expect_pinned "no policy: an operator's SQUAD_MODEL is the pin (the pre-pin behaviour is kept)" lead "$RALPH_MODEL"
assert_contains "${PIN_L[3]:-}" "operator override" "no policy: the source says it is the operator's"
pin watch "$REPO_NO_RALPH" SQUAD_MODEL="$DEFAULT_MODEL"
expect_pinned "no entry for the role: an operator's SQUAD_MODEL is the pin" ralph "$DEFAULT_MODEL"
pin prompt "$REPO_AUTO" SQUAD_MODEL="$RALPH_MODEL"
expect_pinned "policy says 'auto': an operator's SQUAD_MODEL is the pin" lead "$RALPH_MODEL"
pin prompt "$REPO_NONE" SQUAD_MODEL="$LEAD_MODEL" COPILOT_MODEL="$LEAD_MODEL"
expect_pinned "no policy: two operator overrides that agree" lead "$LEAD_MODEL"
pin prompt "$REPO_NONE" SQUAD_MODEL="$LEAD_MODEL" COPILOT_MODEL="$RALPH_MODEL"
expect_refused "no policy: two operator overrides that disagree with each other" "Conflicting model overrides"

# --- invalid: refused, and never compared or passed on as if it were a model --
pin prompt "$REPO_ROLES" SQUAD_MODEL="--allow-all-tools"
expect_refused "SQUAD_MODEL that would be read as a flag" "starts with '-'"
pin prompt "$REPO_NONE" SQUAD_MODEL="--allow-all-tools"
expect_refused "a flag-shaped SQUAD_MODEL with no policy to arbitrate" "starts with '-'"
pin prompt "$REPO_ROLES" SQUAD_MODEL="bad model"
expect_refused "SQUAD_MODEL with a space" "not a valid model id"
pin prompt "$REPO_ROLES" SQUAD_MODEL='a/b'
expect_refused "SQUAD_MODEL with a path separator" "not a valid model id"
pin prompt "$REPO_ROLES" SQUAD_MODEL='$(id)'
expect_refused "SQUAD_MODEL with shell metacharacters" "not a valid model id"
pin prompt "$REPO_ROLES" COPILOT_MODEL="-x"
expect_refused "COPILOT_MODEL that would be read as a flag" "starts with '-'"
pin prompt "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model"
expect_refused "SQUAD_COPILOT_FLAGS ending in --model with no value" "no model id"
pin prompt "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model --allow-all-tools"
expect_refused "'--model' followed by a flag in SQUAD_COPILOT_FLAGS" "starts with '-'"
pin prompt "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model="
expect_refused "'--model=' with no value in SQUAD_COPILOT_FLAGS" "no model id"
pin ralph "$REPO_ROLES" SQUAD_MODEL="--allow-all-tools"
expect_refused "a flag-shaped SQUAD_MODEL is refused even in a mode that starts no Copilot" "starts with '-'"

# --- an unreadable or malformed policy is refused, never skipped ---------------
echo "-- the policy file itself --"
bad_repo() { mk_repo "$1" "$2"; }
pin prompt "$(bad_repo bad-json '{not json')"
expect_refused "config.json that is not JSON" "could not be read as JSON"
pin prompt "$(bad_repo empty '')"
expect_refused "an empty config.json" "could not be read as JSON"
pin prompt "$(bad_repo array '[]')"
expect_refused "config.json that is not an object" "not a JSON object"
pin prompt "$(bad_repo overrides-array '{"agentModelOverrides":["x"]}')"
expect_refused "agentModelOverrides that is not a map" "agentModelOverrides is not an object"
pin prompt "$(bad_repo default-number '{"defaultModel":7}')"
expect_refused "defaultModel that is not a string" "defaultModel is not a string"
pin prompt "$(bad_repo role-number '{"defaultModel":"model-gamma","agentModelOverrides":{"lead":7}}')"
expect_refused "a role entry that is not a string is NOT skipped in favour of defaultModel" "not a model id"
pin prompt "$(bad_repo role-flag '{"defaultModel":"model-gamma","agentModelOverrides":{"lead":"-x"}}')"
expect_refused "a role entry shaped like a flag is NOT skipped in favour of defaultModel" "starts with '-'"
pin prompt "$(bad_repo role-space '{"defaultModel":"model-gamma","agentModelOverrides":{"lead":"a b"}}')"
expect_refused "a role entry that is not a model id" "not a valid model id"
pin watch "$(bad_repo default-flag '{"defaultModel":"--yolo"}')"
expect_refused "a defaultModel shaped like a flag" "starts with '-'"
pin prompt "$(bad_repo role-dup '{"agentModelOverrides":{"lead":"model-alpha","Lead":"model-beta"}}')"
expect_refused "one role named twice with different models" "more than once"
pin ralph "$(bad_repo bad-json-ralph '{not json')"
assert_eq "0" "$PIN_RC" "a malformed config does not stop a mode that starts no Copilot"

# --- the repository's OWN policy resolves for every mode that launches Copilot --
# Asserts the shape (pinned, valid id, right role), not a particular model id:
# which model a role gets is the repository's decision, not this suite's.
echo "-- this repository's own .squad/config.json --"
for m in watch triage loop prompt new-project smoke; do
  pin "$m" "$REPO_ROOT"
  want_role="lead"
  case "$m" in watch|triage|loop) want_role="ralph" ;; esac
  assert_eq "0" "$PIN_RC" "this repo, mode '${m}': the policy resolves"
  assert_eq "pinned" "${PIN_L[0]:-}" "this repo, mode '${m}': a model is pinned, not left to Copilot's default"
  assert_eq "$want_role" "${PIN_L[1]:-}" "this repo, mode '${m}': runs as the '${want_role}' role"
  if [[ "${PIN_L[2]:-}" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]]; then
    assert_eq "ok" "ok" "this repo, mode '${m}': the pinned model ('${PIN_L[2]}') is a well-formed id"
  else
    assert_eq "a well-formed model id" "${PIN_L[2]:-}" "this repo, mode '${m}': the pinned model is a well-formed id"
  fi
done

# ===========================================================================
# 4. The argv Copilot actually receives
# ===========================================================================
# A stub `copilot` that dumps its own argv, one element per line, and counts
# its invocations (a retry on another model would show up as a second one).
# A stub `squad` that records ITS argv and then does what Squad does with
# `--agent-cmd <cmd>`: runs <cmd> with `-p <prompt>` appended -- except that
# <cmd> is the production path (/usr/local/lib/squad-on-aca/squad-agent), which
# does not exist on a test host, so it is mapped to the real worker/squad-agent.
FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"
COPILOT_DUMP="${WORK}/copilot.argv"
COPILOT_CALLS="${WORK}/copilot.calls"
SQUAD_DUMP="${WORK}/squad.argv"
cat > "${FAKE_BIN}/copilot" <<'COPILOT'
#!/usr/bin/env bash
: > "${COPILOT_ARGV_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >> "${COPILOT_ARGV_DUMP}"; done
printf 'x\n' >> "${COPILOT_CALL_COUNT:?}"
# What a failing launch can look like: a success-sounding line on stdout AND a
# non-zero status. Only the status may count.
if [[ -n "${COPILOT_STUB_SAYS:-}" ]]; then printf '%s\n' "$COPILOT_STUB_SAYS"; fi
exit "${COPILOT_STUB_EXIT:-0}"
COPILOT
cat > "${FAKE_BIN}/squad" <<'SQUAD'
#!/usr/bin/env bash
: > "${SQUAD_ARGV_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >> "${SQUAD_ARGV_DUMP}"; done
agent_cmd=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--agent-cmd" ]]; then agent_cmd="$2"; shift; fi
  shift
done
[[ -n "$agent_cmd" ]] || exit 0
[[ "$agent_cmd" == "/usr/local/lib/squad-on-aca/squad-agent" ]] || { echo "unexpected --agent-cmd: ${agent_cmd}" >&2; exit 99; }
exec bash "${REAL_SQUAD_AGENT:?}" -p "Ralph, Go! (stub prompt)"
SQUAD
chmod +x "${FAKE_BIN}/copilot" "${FAKE_BIN}/squad"

# The model-resolution fragment of worker/entrypoint.sh: from the COPILOT_ARGV
# seed through the watch/loop agent-cmd env export. This is the REAL code.
FRAGMENT="$(awk '/^COPILOT_ARGV=\(/{p=1} p{print} /^SQUAD_WATCH_AGENT_POLICY_MODE=/{exit}' "$ENTRYPOINT")"
assert_ne "" "$FRAGMENT" "the model-resolution fragment is present in worker/entrypoint.sh"
assert_contains "$FRAGMENT" "squad_policy_resolve_model" "the fragment under test is the one that resolves the model"

block_of() {
  awk -v start="$1" '$0 == start {p=1} p{print} p && /^    ;;$/ {exit}' "$ENTRYPOINT"
}
PROMPT_BLOCK="$(block_of '  prompt)')"
NEWPROJECT_BLOCK="$(block_of '  new-project)')"
LOOP_BLOCK="$(block_of '  loop)')"
WATCH_BLOCK="$(block_of '  watch|triage)')"
for b in PROMPT NEWPROJECT LOOP WATCH; do
  var="${b}_BLOCK"
  assert_ne "" "${!var}" "the real ${b} case block was extracted from worker/entrypoint.sh"
done

# run_launch <mode> <block-text> <repo> [NAME=value ...]
# Runs: the real policy resolution, the real fragment, then the real case block,
# in one shell, the way the entrypoint's top level does. Sets LAUNCH_OUT,
# LAUNCH_RC, COPILOT_ARGV_SEEN, SQUAD_ARGV_SEEN and COPILOT_CALL_N.
run_launch() {
  local mode="$1" block="$2" repo="$3"
  shift 3
  local driver="${WORK}/driver-${mode}-$$-${RANDOM}.sh"
  local workdir="${WORK}/cwd-${mode}-${RANDOM}"
  mkdir -p "$workdir"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf 'export PATH=%q:"$PATH"\n' "$FAKE_BIN"
    printf 'cd %q\n' "$workdir"
    printf 'WORKDIR=%q\n' "$workdir"
    printf 'REPO_DIR=%q\n' "$repo"
    echo 'SESSION_NAME=model-pin-test'
    printf 'source %q\n' "$POLICY_LIB"
    printf 'source %q\n' "$DEADLINE_LIB"
    cat <<'STUBS'
log() { printf '[entrypoint] %s\n' "$*"; }
require() { :; }
squad_session_deadline_init() { SQUAD_SESSION_DEADLINE_EPOCH=0; return 0; }
squad_publish_contract_note() { :; }
squad_credential_should_withhold() { return 1; }
squad_hub_should_supervise() { return 1; }
squad_policy_announce() { :; }
squad_deadline_run_agent() { shift; if "$@"; then SQUAD_DEADLINE_AGENT_RC=0; else SQUAD_DEADLINE_AGENT_RC=$?; fi; return 0; }
squad_policy_exec_agent() { "$@"; }
squad_run_foreground_with_signal_forwarding() { "$@"; }
squad_watch_policy_announce_undelivered() { :; }
squad_defer_shutdown_signals() { :; }
squad_release_shutdown_signals() { :; }
squad_policy_checkpoint() { :; }
squad_watch_governance_report_if_any() { :; }
commit_and_push_if_needed() { echo "PUBLISHED"; }
squad_deadline_finish_session() { :; }
ASPIRE_OTLP_HTTP_ENDPOINT="http://stub.invalid:4318"
ASPIRE_OTLP_GRPC_ENDPOINT="http://stub.invalid:4317"
LOOP_MARKDOWN="stub loop"
SQUAD_PROMPT="stub prompt"
squad_policy_resolve
STUBS
    printf '%s\n' "$FRAGMENT"
    echo 'case "${SQUAD_MODE}" in'
    printf '%s\n' "$block"
    echo 'esac'
  } > "$driver"

  : > "$COPILOT_DUMP"; : > "$COPILOT_CALLS"; : > "$SQUAD_DUMP"
  LAUNCH_OUT="$(env -u SQUAD_MODEL -u SQUAD_AGENT_MODEL -u COPILOT_MODEL -u SQUAD_COPILOT_FLAGS \
      -u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_GITHUB_TOKEN -u SQUAD_MODEL_PINNED \
      -u SQUAD_COPILOT_TOKEN_PROVENANCE -u SQUAD_ALLOW_SHARED_COPILOT_TOKEN \
      SQUAD_MODE="$mode" SQUAD_DISPATCH_SOURCE=actions \
      COPILOT_ARGV_DUMP="$COPILOT_DUMP" COPILOT_CALL_COUNT="$COPILOT_CALLS" \
      SQUAD_ARGV_DUMP="$SQUAD_DUMP" REAL_SQUAD_AGENT="$WRAPPER" \
      "$@" bash "$driver" 2>&1)"
  LAUNCH_RC=$?
  rm -f "$driver"
  COPILOT_ARGV_SEEN=()
  if [[ -s "$COPILOT_DUMP" ]]; then
    while IFS= read -r line; do COPILOT_ARGV_SEEN+=("$line"); done < "$COPILOT_DUMP"
  fi
  SQUAD_ARGV_SEEN=()
  if [[ -s "$SQUAD_DUMP" ]]; then
    while IFS= read -r line; do SQUAD_ARGV_SEEN+=("$line"); done < "$SQUAD_DUMP"
  fi
  COPILOT_CALL_N="$(wc -l < "$COPILOT_CALLS" | tr -d ' ')"
}

# The value after every `--model` in the copilot argv, comma-joined.
model_values() {
  local out="" i
  for ((i = 0; i < ${#COPILOT_ARGV_SEEN[@]}; i++)); do
    local t="${COPILOT_ARGV_SEEN[i]}"
    if [[ "$t" == "--model" ]]; then
      out+="${out:+,}${COPILOT_ARGV_SEEN[i+1]:-<none>}"
    elif [[ "$t" == --model=* ]]; then
      out+="${out:+,}${t#--model=}"
    fi
  done
  printf '%s' "$out"
}
argv_has() {
  local want="$1" t
  for t in "${COPILOT_ARGV_SEEN[@]}"; do [[ "$t" == "$want" ]] && return 0; done
  return 1
}
squad_argv_has() {
  local want="$1" t
  for t in "${SQUAD_ARGV_SEEN[@]}"; do [[ "$t" == "$want" ]] && return 0; done
  return 1
}
assert_argv_has() {
  if argv_has "$2"; then assert_eq "ok" "ok" "$1"; else assert_eq "'$2' in copilot argv" "absent: ${COPILOT_ARGV_SEEN[*]:-<none>}" "$1"; fi
}
assert_squad_argv_has() {
  if squad_argv_has "$2"; then assert_eq "ok" "ok" "$1"; else assert_eq "'$2' in squad argv" "absent: ${SQUAD_ARGV_SEEN[*]:-<none>}" "$1"; fi
}
last_two() {
  local n=${#COPILOT_ARGV_SEEN[@]}
  if (( n >= 2 )); then printf '%s %s' "${COPILOT_ARGV_SEEN[n-2]}" "${COPILOT_ARGV_SEEN[n-1]}"; fi
}

# --- 4a. direct launches: prompt and new-project -------------------------------
echo "-- direct launches (prompt, new-project) --"

for entry in "prompt|PROMPT_BLOCK" "new-project|NEWPROJECT_BLOCK"; do
  mode="${entry%%|*}"
  blockvar="${entry##*|}"
  block="${!blockvar}"

  run_launch "$mode" "$block" "$REPO_ROLES"
  assert_eq "0" "$LAUNCH_RC" "${mode}: the launch runs"
  assert_eq "1" "$COPILOT_CALL_N" "${mode}: copilot is launched exactly once"
  assert_eq "$LEAD_MODEL" "$(model_values)" "${mode}: copilot receives exactly one --model, the lead role's model, with NO operator override"
  assert_argv_has "${mode}: the coordinator agent is still selected" "squad"
  assert_argv_has "${mode}: the resolved tool policy is still applied" "--allow-all-tools"
  assert_contains "$LAUNCH_OUT" "Model: ${LEAD_MODEL} for role 'lead'" "${mode}: the session log states the model, the role and where it came from"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_MODEL="$LEAD_MODEL"
  assert_eq "0" "$LAUNCH_RC" "${mode}: a matching SQUAD_MODEL is accepted"
  assert_eq "$LEAD_MODEL" "$(model_values)" "${mode}: a matching SQUAD_MODEL does not add a second --model"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL}"
  assert_eq "0" "$LAUNCH_RC" "${mode}: a matching --model in SQUAD_COPILOT_FLAGS is accepted"
  assert_eq "$LEAD_MODEL" "${COPILOT_ARGV_SEEN[$(( ${#COPILOT_ARGV_SEEN[@]} - 1 ))]:-}" "${mode}: the last argv element is still the pinned model"
  assert_eq "--model ${LEAD_MODEL}" "$(last_two)" "${mode}: and it is preceded by --model"
  assert_eq "${LEAD_MODEL},${LEAD_MODEL}" "$(model_values)" "${mode}: every --model that reaches copilot names the pinned model"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_MODEL="$RALPH_MODEL"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a conflicting SQUAD_MODEL stops the session (78)"
  assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched, on either model"
  assert_not_contains "$LAUNCH_OUT" "PUBLISHED" "${mode}: ... and nothing is published"
  assert_contains "$LAUNCH_OUT" "Refusing to run the session" "${mode}: ... through the policy abort path"
  assert_contains "$LAUNCH_OUT" "Model override conflict for role 'lead'" "${mode}: ... and the log says which role and override conflicted"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${RALPH_MODEL}"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a conflicting --model in SQUAD_COPILOT_FLAGS stops the session (78)"
  assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_MODEL="--allow-all-tools"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a flag-shaped SQUAD_MODEL stops the session (78)"
  assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched"

  run_launch "$mode" "$block" "$REPO_NONE"
  assert_eq "0" "$LAUNCH_RC" "${mode}: a repository with no model policy still runs"
  assert_eq "" "$(model_values)" "${mode}: ... with no --model invented for it"
  assert_contains "$LAUNCH_OUT" "NOT PINNED" "${mode}: ... and the log says the model is not pinned"

  run_launch "$mode" "$block" "$REPO_NONE" SQUAD_MODEL="$RALPH_MODEL"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: with no repository policy, an operator's SQUAD_MODEL is still honoured"

  # The pinned model cannot be run (unavailable, over quota): Copilot exits
  # non-zero. The session ends with THAT status, once, publishing nothing; a
  # success-sounding line on stdout changes nothing.
  run_launch "$mode" "$block" "$REPO_ROLES" COPILOT_STUB_EXIT=7 COPILOT_STUB_SAYS="Task completed successfully."
  assert_eq "7" "$LAUNCH_RC" "${mode}: a pinned model that copilot cannot run ends the session with copilot's own status"
  assert_eq "1" "$COPILOT_CALL_N" "${mode}: ... after ONE attempt: no retry on another model"
  assert_eq "$LEAD_MODEL" "$(model_values)" "${mode}: ... and that attempt was on the pinned model"
  assert_not_contains "$LAUNCH_OUT" "PUBLISHED" "${mode}: ... publishing nothing"
done

# --- 4b. watch / triage / loop through the real squad-agent --------------------
echo "-- watch and loop launches (via the real squad-agent) --"

for entry in "watch|WATCH_BLOCK|watch" "triage|WATCH_BLOCK|watch" "loop|LOOP_BLOCK|loop"; do
  IFS='|' read -r mode blockvar verb <<<"$entry"
  block="${!blockvar}"

  run_launch "$mode" "$block" "$REPO_ROLES"
  assert_eq "0" "$LAUNCH_RC" "${mode}: the launch runs"
  assert_squad_argv_has "${mode}: squad is started with the agent-cmd wrapper" "/usr/local/lib/squad-on-aca/squad-agent"
  assert_squad_argv_has "${mode}: squad is started with the '${verb}' verb" "$verb"
  assert_eq "1" "$COPILOT_CALL_N" "${mode}: the stub squad starts exactly one copilot session"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: copilot receives exactly one --model, the ralph role's model (NOT the lead's)"
  assert_eq "--model ${RALPH_MODEL}" "$(last_two)" "${mode}: --model <ralph model> is the LAST thing on copilot's argv, so it is the one that counts"
  assert_argv_has "${mode}: the coordinator agent is still selected" "squad"
  assert_argv_has "${mode}: the resolved tool policy is still applied" "--allow-all-tools"
  assert_contains "$LAUNCH_OUT" "Model: ${RALPH_MODEL} for role 'ralph'" "${mode}: the session log states the model, the role and where it came from"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_MODEL="$RALPH_MODEL"
  assert_eq "0" "$LAUNCH_RC" "${mode}: a matching SQUAD_MODEL is accepted"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: ... with still exactly one --model"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_MODEL="$LEAD_MODEL"
  assert_eq "78" "$LAUNCH_RC" "${mode}: the LEAD role's model as an override is a conflict here (78): one global model is not accepted"
  assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched"
  assert_eq "0" "${#SQUAD_ARGV_SEEN[@]}" "${mode}: ... nor is squad"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL}"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a conflicting --model in SQUAD_COPILOT_FLAGS stops the session (78)"
  assert_eq "0" "${#SQUAD_ARGV_SEEN[@]}" "${mode}: ... before squad is started"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_AGENT_MODEL="$LEAD_MODEL"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a pre-set SQUAD_AGENT_MODEL that conflicts is refused, not overwritten silently"

  run_launch "$mode" "$block" "$REPO_DEFAULT"
  assert_eq "$DEFAULT_MODEL" "$(model_values)" "${mode}: a role with no entry of its own runs on the repository's defaultModel"

  run_launch "$mode" "$block" "$REPO_NONE"
  assert_eq "0" "$LAUNCH_RC" "${mode}: a repository with no model policy still runs"
  assert_eq "" "$(model_values)" "${mode}: ... with no --model invented for it"
  assert_contains "$LAUNCH_OUT" "NOT PINNED" "${mode}: ... and the log says the model is not pinned"

  run_launch "$mode" "$block" "$REPO_ROLES" COPILOT_STUB_EXIT=9 COPILOT_STUB_SAYS="Task completed successfully."
  assert_eq "9" "$LAUNCH_RC" "${mode}: a pinned model that copilot cannot run ends the session with copilot's own status"
  assert_eq "1" "$COPILOT_CALL_N" "${mode}: ... after ONE attempt: no retry on another model"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: ... and that attempt was on the pinned model"
done

# --- 4c. wiring ---------------------------------------------------------------
# Part 4 ran the real blocks; these pin down the one thing it cannot see: that
# the resolution happens once, in the right place, and is the ONLY source of a
# model on any launch.
echo "-- wiring in worker/entrypoint.sh --"

active_entrypoint="$(grep -vE '^[[:space:]]*#' "$ENTRYPOINT")"
resolve_calls="$(printf '%s\n' "$active_entrypoint" | grep -c '^squad_policy_resolve_model ')"
assert_eq "1" "$resolve_calls" "the entrypoint resolves the model exactly once"

harden_line="$(grep -nE '^squad_policy_harden ' "$ENTRYPOINT" | head -n1 | cut -d: -f1)"
resolve_line="$(grep -nE '^squad_policy_resolve_model ' "$ENTRYPOINT" | head -n1 | cut -d: -f1)"
dispatch_line="$(grep -nE '^case "\$\{SQUAD_MODE:-smoke\}" in' "$ENTRYPOINT" | head -n1 | cut -d: -f1)"
if [[ -n "$harden_line" && -n "$resolve_line" && -n "$dispatch_line" ]] \
   && (( harden_line < resolve_line && resolve_line < dispatch_line )); then
  assert_eq "ok" "ok" "the model is resolved after hardening (the policy file is under the governance lock) and before any mode launches Copilot"
else
  assert_eq "harden < resolve < dispatch" "harden=${harden_line:-?} resolve=${resolve_line:-?} dispatch=${dispatch_line:-?}" "the model is resolved after hardening and before any mode launches Copilot"
fi

assert_eq "0" "$(printf '%s\n' "$active_entrypoint" | grep -c -- '--model')" "no launch in the entrypoint carries a --model of its own: the resolved pin is the only source"
copilot_launches="$(printf '%s\n' "$active_entrypoint" | grep -cE 'copilot -p .*"\$\{COPILOT_ARGV\[@\]\}"')"
assert_eq "3" "$copilot_launches" "all three direct launches (smoke, prompt, new-project) take their argv from COPILOT_ARGV, which carries the pin"
assert_contains "$LOOP_BLOCK" "--agent-cmd /usr/local/lib/squad-on-aca/squad-agent" "loop launches Copilot through squad-agent, which carries the pin"
assert_contains "$WATCH_BLOCK" "--agent-cmd /usr/local/lib/squad-on-aca/squad-agent" "watch launches Copilot through squad-agent, which carries the pin"

test_summary
