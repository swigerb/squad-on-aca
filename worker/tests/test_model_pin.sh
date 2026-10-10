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
#     success inferred from output text. Real Squad does NOT stop on a failed
#     agent (`watch` keeps polling, `loop` reschedules), so for watch/loop the
#     first unsolicited non-zero exit of the pinned Copilot is recorded, latches
#     any further launch off, stops Squad through the supervisor and ends the
#     worker non-zero;
#   - exactly ONE `--model` reaches Copilot: matching operator spellings are
#     removed, never forwarded next to the pin.
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
#      argv they receive. For watch and loop the stub `squad` is a faithful
#      polling Squad: it stays alive, runs `--agent-cmd <cmd>` as a CHILD with
#      `-p <prompt>` appended, logs a failed child and keeps polling, and
#      drains on TERM. The command it spawns is the REAL worker/squad-agent and
#      the supervisor is the REAL squad_run_foreground_with_signal_forwarding,
#      so both the argv that reaches the stub `copilot` and the lifecycle
#      around it are the ones production has.
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
SIGNAL_LIB="${WORKER_DIR}/lib/squad-signal-forwarding.sh"
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
REPO_DEFAULT_AUTO="$(mk_repo default-auto '{"defaultModel":"auto"}')"
REPO_NONE="$(mk_repo none __NONE__)"
REPO_UNSEEN="$(mk_repo unseen '{"agentModelOverrides":{"lead":"model-from-a-future-catalog-9.9"}}')"
REPO_CASE_DUP_SAME="$(mk_repo case-dup-same '{"agentModelOverrides":{"lead":"model-alpha","Lead":"MODEL-ALPHA"}}')"

# --- resolver CLI helper ----------------------------------------------------
# pin <mode> <repo> [NAME=value ...] -> PIN_OUT (stdout), PIN_ERR (stderr),
# PIN_RC, and PIN_L[0..5] = status, role, model, source, declared, warning.
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
assert_eq "model" "${PIN_L[4]:-}" "defaultModel: the role still has a declared model, the repository-wide one"
assert_contains "${PIN_L[5]:-}" "no agentModelOverrides.ralph entry" "defaultModel standing in for a role: an explicit warning says the role has no entry of its own"
assert_contains "${PIN_L[5]:-}" "defaultModel '${DEFAULT_MODEL}' applies" "... and names the generic model that applies instead"
pin prompt "$REPO_DEFAULT"
assert_contains "${PIN_L[5]:-}" "no agentModelOverrides.lead entry" "defaultModel standing in for the lead role warns too, naming that role"

pin watch "$REPO_ROLES"
assert_eq "model" "${PIN_L[4]:-}" "a role with its own entry: declared is 'model'"
assert_eq "" "${PIN_L[5]:-}" "a role with its own entry: no generic-fallback warning"
pin watch "$REPO_DEFAULT" SQUAD_MODEL="$DEFAULT_MODEL"
expect_pinned "defaultModel standing in, with a matching operator override" ralph "$DEFAULT_MODEL"
assert_contains "${PIN_L[5]:-}" "no agentModelOverrides.ralph entry" "... still warns: the warning describes the repository, not the override"

pin watch "$REPO_NO_RALPH"
expect_unpinned "no entry for the role and no defaultModel" ralph
assert_contains "${PIN_L[3]:-}" "declares no model" "unpinned: the reason is stated, not silent"
assert_eq "none" "${PIN_L[4]:-}" "no model declared: declared is 'none', which is not the same as 'auto'"
assert_eq "" "${PIN_L[5]:-}" "no model declared: there is no generic model to warn about"
pin prompt "$REPO_NO_RALPH"
expect_pinned "a role that IS declared stays pinned beside one that is not" lead "$LEAD_MODEL"

pin watch "$REPO_AUTO"
expect_unpinned "an explicit 'auto' for the role is not a pin" ralph
assert_eq "auto" "${PIN_L[4]:-}" "'auto': declared is 'auto', which is NOT the same as declaring nothing"
assert_contains "${PIN_L[3]:-}" "NOT a pin" "'auto': the source says it is not a pin"
assert_eq "" "${PIN_L[5]:-}" "'auto': it is the role's own entry, so there is no generic-fallback warning"
pin prompt "$REPO_AUTO"
expect_unpinned "'auto' for the role beats an explicit defaultModel (the role's own entry wins)" lead
assert_eq "auto" "${PIN_L[4]:-}" "'auto' beating defaultModel: declared is 'auto'"
pin watch "$REPO_DEFAULT_AUTO"
expect_unpinned "defaultModel 'auto' standing in for a role is not a pin" ralph
assert_eq "auto" "${PIN_L[4]:-}" "defaultModel 'auto': declared is 'auto'"
assert_contains "${PIN_L[5]:-}" "no agentModelOverrides.ralph entry" "defaultModel 'auto': the generic fallback is warned about as well"

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
pin prompt "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL} --model=${RALPH_MODEL}"
expect_refused "a matching --model followed by a conflicting one" "SQUAD_COPILOT_FLAGS --model"
pin prompt "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${RALPH_MODEL} --model ${LEAD_MODEL}"
expect_refused "a conflicting --model FIRST is refused even when a matching one follows" "SQUAD_COPILOT_FLAGS --model"
pin watch "$REPO_ROLES" SQUAD_AGENT_MODEL="$RALPH_MODEL" SQUAD_MODEL="$LEAD_MODEL"
expect_refused "watch: a matching SQUAD_AGENT_MODEL does not excuse a conflicting SQUAD_MODEL" "SQUAD_MODEL="
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
# The expected model is derived from the file here, independently of
# agent-policy.js: the role's own agentModelOverrides entry (key compared
# case-insensitively), else the repository-wide defaultModel.
repo_config_model() {
  node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const o = c.agentModelOverrides || {};
    const k = Object.keys(o).find((x) => x.toLowerCase() === process.argv[2]);
    const v = k !== undefined ? o[k] : c.defaultModel;
    process.stdout.write(typeof v === "string" ? v : "");
  ' "${REPO_ROOT}/.squad/config.json" "$1"
}
for m in watch triage loop prompt new-project smoke; do
  pin "$m" "$REPO_ROOT"
  want_role="lead"
  case "$m" in watch|triage|loop) want_role="ralph" ;; esac
  want_model="$(repo_config_model "$want_role")"
  assert_ne "" "$want_model" "this repo, mode '${m}': .squad/config.json declares a model for the '${want_role}' role (its own entry or defaultModel)"
  assert_eq "$want_model" "${PIN_L[2]:-}" "this repo, mode '${m}': the pin is exactly what .squad/config.json says for the '${want_role}' role, not some other role's or a global model"
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
# A stub `squad` that records ITS argv and then behaves like the real Squad
# (1.0.1) `watch`/`loop` where it matters here, so the lifecycle assertions do
# not rest on a shortcut:
#   - it stays ALIVE across rounds (SQUAD_STUB_ROUNDS, SQUAD_STUB_POLL seconds
#     apart) and runs `--agent-cmd <cmd>` as a CHILD with `-p <prompt>`
#     appended -- like Squad's execFile -- rather than `exec`ing it, so the
#     agent command's exit status is NOT Squad's;
#   - a failed child is logged as success:false and Squad KEEPS POLLING;
#   - TERM drains: the in-flight child is awaited, no further round starts, and
#     Squad exits 0;
#   - <cmd> is the production path (/usr/local/lib/squad-on-aca/squad-agent),
#     which does not exist on a test host, so it is mapped to the real
#     worker/squad-agent.
# Everything it does is appended to SQUAD_STUB_LOG.
FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"
COPILOT_DUMP="${WORK}/copilot.argv"
COPILOT_CALLS="${WORK}/copilot.calls"
COPILOT_PIDS="${WORK}/copilot.pids"
SQUAD_DUMP="${WORK}/squad.argv"
SQUAD_LOG="${WORK}/squad.log"
cat > "${FAKE_BIN}/copilot" <<'COPILOT'
#!/usr/bin/env bash
: > "${COPILOT_ARGV_DUMP:?}"
for a in "$@"; do printf '%s\n' "$a" >> "${COPILOT_ARGV_DUMP}"; done
printf 'x\n' >> "${COPILOT_CALL_COUNT:?}"
printf '%s\n' "$$" >> "${COPILOT_PID_FILE:-/dev/null}"
# What a failing launch can look like: a success-sounding line on stdout AND a
# non-zero status. Only the status may count.
if [[ -n "${COPILOT_STUB_SAYS:-}" ]]; then printf '%s\n' "$COPILOT_STUB_SAYS"; fi
# A launch still running when it is cancelled: the pid stays this process's own
# (exec), so a TERM that reaches it ends it and nothing is left behind.
if [[ -n "${COPILOT_STUB_SLEEP:-}" ]]; then exec sleep "$COPILOT_STUB_SLEEP"; fi
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
log="${SQUAD_STUB_LOG:?}"
printf 'pid %s\n' "$$" >> "$log"
draining=0
child=""
# SQUAD_STUB_KILL_CHILD_ON_TERM: like the real Squad's shutdown, which TERMs the
# agent it is running (`currentChild`) and then exits; without it the stub
# drains by waiting for the in-flight child.
trap 'draining=1; printf "term\n" >> "$log"; if [[ -n "${SQUAD_STUB_KILL_CHILD_ON_TERM:-}" && -n "$child" ]]; then kill -s TERM "$child" 2>/dev/null; fi' TERM
rounds="${SQUAD_STUB_ROUNDS:-1}"
poll="${SQUAD_STUB_POLL:-0.3}"
round=0
while (( round < rounds && draining == 0 )); do
  round=$((round + 1))
  printf 'round %s\n' "$round" >> "$log"
  bash "${REAL_SQUAD_AGENT:?}" -p "Ralph, Go! (stub prompt)" &
  child=$!
  printf 'agent %s\n' "$child" >> "$log"
  rc=0
  while :; do
    rc=0
    wait "$child" || rc=$?
    kill -0 "$child" 2>/dev/null || break
  done
  if (( rc != 0 )); then
    printf 'agent-failed %s (success:false, still polling)\n' "$rc" >> "$log"
  else
    printf 'agent-ok\n' >> "$log"
  fi
  (( round < rounds && draining == 0 )) || break
  sleep "$poll" &
  nap=$!
  wait "$nap" 2>/dev/null || true
  kill "$nap" 2>/dev/null || true
done
printf 'exit rounds=%s draining=%s\n' "$round" "$draining" >> "$log"
exit "${SQUAD_STUB_EXIT:-0}"
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
    printf 'export PATH=%q:"$PATH"\n' "${LAUNCH_BIN:-$FAKE_BIN}"
    printf 'cd %q\n' "$workdir"
    printf 'WORKDIR=%q\n' "$workdir"
    printf 'REPO_DIR=%q\n' "$repo"
    echo 'SESSION_NAME=model-pin-test'
    printf 'source %q\n' "$POLICY_LIB"
    printf 'source %q\n' "$DEADLINE_LIB"
    printf 'SIGNAL_LIB=%q\n' "$SIGNAL_LIB"
    cat <<'STUBS'
log() { printf '[entrypoint] %s\n' "$*"; }
require() { :; }
squad_session_deadline_init() { SQUAD_SESSION_DEADLINE_EPOCH=0; return 0; }
squad_publish_contract_note() { :; }
squad_credential_should_withhold() { return 1; }
squad_hub_should_supervise() { return 1; }
squad_policy_announce() { :; }
squad_deadline_run_agent() { shift; if "$@"; then SQUAD_DEADLINE_AGENT_RC=0; else SQUAD_DEADLINE_AGENT_RC=$?; fi; return 0; }
# In the supervisor's background job (BASHPID != $$) the production function
# `exec`s the command, so the job's pid IS the command's pid; in the main
# shell (the direct launches) it must just run it.
squad_policy_exec_agent() { if [[ "$BASHPID" != "$$" ]]; then exec "$@"; else "$@"; fi; }
source "$SIGNAL_LIB"
squad_watch_policy_announce_undelivered() { :; }
squad_defer_shutdown_signals() { :; }
squad_release_shutdown_signals() { :; }
squad_policy_checkpoint() { echo "CHECKPOINT-RAN"; }
squad_watch_governance_report_if_any() { echo "GOVERNANCE-REPORT-RAN"; }
commit_and_push_if_needed() { echo "PUBLISHED"; }
squad_deadline_finish_session() { :; }
ASPIRE_OTLP_HTTP_ENDPOINT="http://stub.invalid:4318"
ASPIRE_OTLP_GRPC_ENDPOINT="http://stub.invalid:4317"
LOOP_MARKDOWN="${LOOP_MARKDOWN:-stub loop}"
if [[ -n "${SEED_TEAM_MD:-}" ]]; then mkdir -p .squad; printf '%s\n' "$SEED_TEAM_MD" > .squad/team.md; fi
SQUAD_PROMPT="stub prompt"
squad_policy_resolve
STUBS
    printf '%s\n' "$FRAGMENT"
    echo 'case "${SQUAD_MODE}" in'
    printf '%s\n' "$block"
    echo 'esac'
  } > "$driver"

  : > "$COPILOT_DUMP"; : > "$COPILOT_CALLS"; : > "$COPILOT_PIDS"; : > "$SQUAD_DUMP"; : > "$SQUAD_LOG"
  local launch_env=(env -u SQUAD_MODEL -u SQUAD_AGENT_MODEL -u COPILOT_MODEL -u SQUAD_COPILOT_FLAGS
      -u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_GITHUB_TOKEN -u SQUAD_MODEL_PINNED
      -u SQUAD_COPILOT_TOKEN_PROVENANCE -u SQUAD_ALLOW_SHARED_COPILOT_TOKEN
      -u SQUAD_MODEL_PIN_FAILURE_FILE -u SQUAD_FOREGROUND_STOP_FILE
      SQUAD_MODE="$mode" SQUAD_DISPATCH_SOURCE=actions
      COPILOT_ARGV_DUMP="$COPILOT_DUMP" COPILOT_CALL_COUNT="$COPILOT_CALLS" COPILOT_PID_FILE="$COPILOT_PIDS"
      SQUAD_ARGV_DUMP="$SQUAD_DUMP" SQUAD_STUB_LOG="$SQUAD_LOG" REAL_SQUAD_AGENT="$WRAPPER"
      SQUAD_FOREGROUND_STOP_POLL_SECONDS=0.2 SQUAD_FOREGROUND_STOP_GRACE_SECONDS=20
      "$@")
  if [[ -n "${LAUNCH_SIGNAL:-}" ]]; then
    # Cancel: start the worker, wait until copilot is really running, then send
    # the signal to the worker process (what ACA does to PID 1 on a stop).
    local out="${WORK}/launch-out-${RANDOM}" dpid ticks=0
    "${launch_env[@]}" bash "$driver" > "$out" 2>&1 &
    dpid=$!
    while [[ ! -s "$COPILOT_CALLS" && "$ticks" -lt 150 ]]; do sleep 0.1; ticks=$((ticks + 1)); done
    if [[ -n "${LAUNCH_SIGNAL_DELAY:-}" ]]; then sleep "$LAUNCH_SIGNAL_DELAY"; fi
    LAUNCH_ALIVE_AT_SIGNAL=0
    if kill -0 "$dpid" 2>/dev/null; then LAUNCH_ALIVE_AT_SIGNAL=1; fi
    kill -s "$LAUNCH_SIGNAL" "$dpid" 2>/dev/null
    wait "$dpid"
    LAUNCH_RC=$?
    LAUNCH_OUT="$(cat "$out")"
    rm -f "$out"
  else
    LAUNCH_OUT="$("${launch_env[@]}" bash "$driver" 2>&1)"
    LAUNCH_RC=$?
  fi
  rm -f "$driver"
  FAILURE_FILE="${workdir}/model-pin-test/model-pin-failure"
  COPILOT_ARGV_SEEN=()
  if [[ -s "$COPILOT_DUMP" ]]; then
    while IFS= read -r line; do COPILOT_ARGV_SEEN+=("$line"); done < "$COPILOT_DUMP"
  fi
  SQUAD_ARGV_SEEN=()
  if [[ -s "$SQUAD_DUMP" ]]; then
    while IFS= read -r line; do SQUAD_ARGV_SEEN+=("$line"); done < "$SQUAD_DUMP"
  fi
  COPILOT_CALL_N="$(wc -l < "$COPILOT_CALLS" | tr -d ' ')"
  SQUAD_ROUNDS_N="$(grep -c '^round ' "$SQUAD_LOG" || true)"
  SQUAD_TERMS_N="$(grep -c '^term$' "$SQUAD_LOG" || true)"
  SQUAD_FAILED_N="$(grep -c '^agent-failed ' "$SQUAD_LOG" || true)"
  SQUAD_PID_SEEN="$(sed -n 's/^pid //p' "$SQUAD_LOG" | head -n1)"
  COPILOT_PIDS_SEEN="$(tr '\n' ' ' < "$COPILOT_PIDS")"
  AGENT_PIDS_SEEN="$(sed -n 's/^agent //p' "$SQUAD_LOG" | tr '\n' ' ')"
}

# Every process the last run started that is still alive: the stub Squad, each
# worker/squad-agent wrapper it ran and each copilot stub the wrapper ran, so a
# survivor at any level shows here. Empty means the run left nothing behind.
leaked_pids() {
  local pid out=""
  for pid in $SQUAD_PID_SEEN $AGENT_PIDS_SEEN $COPILOT_PIDS_SEEN; do
    if kill -0 "$pid" 2>/dev/null; then out+="${out:+ }${pid}"; fi
  done
  printf '%s' "$out"
}

# True when the stub squad of the last run is still a live process.
squad_stub_alive() {
  [[ -n "$SQUAD_PID_SEEN" ]] && kill -0 "$SQUAD_PID_SEEN" 2>/dev/null
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
# How many tokens on the copilot argv select a model, in either spelling.
model_flag_count() {
  local n=0 t
  for t in "${COPILOT_ARGV_SEEN[@]}"; do
    if [[ "$t" == "--model" || "$t" == --model=* ]]; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}
# The argv element immediately before the first --model.
token_before_model() {
  local i
  for ((i = 0; i < ${#COPILOT_ARGV_SEEN[@]}; i++)); do
    if [[ "${COPILOT_ARGV_SEEN[i]}" == "--model" ]]; then
      printf '%s' "${COPILOT_ARGV_SEEN[i-1]:-<start>}"
      return 0
    fi
  done
  printf '<no --model>'
}

# The WHOLE argv, exactly. The tool policy part comes from the resolver's own
# CLI (`bundle` for the direct launches, `watch-agent-argv-json` for squad-agent),
# asked with the operator's non-model flags only, so it does not depend on the
# code that removes model tokens. A launch is then correct only when its argv is
#   -p <prompt> --model <pin> <that policy argv, operator flags last>
# token for token: one `--model`, in the two-token form, whatever spelling,
# repetition or letter case the operator used.
resolver_env() {
  env -u SQUAD_MODEL -u SQUAD_AGENT_MODEL -u COPILOT_MODEL -u SQUAD_COPILOT_FLAGS \
      -u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_GITHUB_TOKEN \
      -u SQUAD_COPILOT_TOKEN_PROVENANCE -u SQUAD_ALLOW_SHARED_COPILOT_TOKEN \
      SQUAD_MODE="$1" SQUAD_DISPATCH_SOURCE=actions SQUAD_WATCH_STRICT_POLICY=false \
      SQUAD_COPILOT_FLAGS="$2" node "$RESOLVER" "$3" 2>/dev/null
}
RESOLVED_TAIL=()
resolver_tail_direct() {
  local out
  out="$(resolver_env prompt "$1" bundle | awk '{ if (n > 0) { print; n--; next } if ($0 ~ /^ARGV [0-9]+$/) { n = $2 } }')"
  RESOLVED_TAIL=()
  if [[ -n "$out" ]]; then mapfile -t RESOLVED_TAIL <<<"$out"; fi
}
resolver_tail_watch() {
  local out
  out="$(resolver_env watch "$1" watch-agent-argv-json | node -e '
    let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
      for (const a of JSON.parse(s)) process.stdout.write(a + "\n");
    });')"
  RESOLVED_TAIL=()
  if [[ -n "$out" ]]; then mapfile -t RESOLVED_TAIL <<<"$out"; fi
}
# assert_argv_exact <label> <expected token>...  : the copilot argv equals it, token for token.
assert_argv_exact() {
  local label="$1"
  shift
  local want got
  want="$(printf '%s\n' "$@")"
  got="$(printf '%s\n' "${COPILOT_ARGV_SEEN[@]}")"
  assert_eq "$want" "$got" "$label"
}
# exact_argv_matrix <mode> <block> <direct|watch> <pinned model> <repo> <quick: 0|1>
# Every spelling of a matching model, alone and mixed, must end as ONE
# `--model <pin>` and an otherwise identical argv; a conflicting model anywhere,
# in any order, must stop the session before anything is launched.
exact_argv_matrix() {
  local mode="$1" block="$2" kind="$3" model="$4" repo="$5" quick="$6"
  local extra="--log-level debug" prompt="stub prompt"
  if [[ "$kind" == direct ]]; then resolver_tail_direct "$extra"; else resolver_tail_watch "$extra"; prompt="Ralph, Go! (stub prompt)"; fi
  local -a want=(-p "$prompt" --model "$model" "${RESOLVED_TAIL[@]}")
  local n=0 tok
  for tok in "${want[@]}"; do if [[ "$tok" == "--model" || "$tok" == --model=* ]]; then n=$((n + 1)); fi; done
  assert_eq "1" "$n" "${mode}: the expected argv itself carries exactly one model selector"
  assert_eq "debug" "${want[-1]}" "${mode}: ... with the operator's own flag after the policy argv"

  local other="$LEAD_MODEL"
  if [[ "$model" == "$LEAD_MODEL" ]]; then other="$RALPH_MODEL"; fi
  local up="${model^^}"
  local -a forms=(
    "no model flag|${extra}|"
    "--model X|--model ${model} ${extra}|"
    "--model=X|${extra} --model=${model}|"
    "repeated, both forms|--model ${model} --model=${model} ${extra}|"
    "repeated, split by another flag|--model=${model} ${extra} --model ${model}|"
    "other letter case|--model=${up} ${extra}|"
    "every source at once|--model=${model} ${extra}|SQUAD_MODEL=${model};SQUAD_AGENT_MODEL=${up};COPILOT_MODEL=${model}"
  )
  if [[ "$quick" == 1 ]]; then forms=("${forms[1]}" "${forms[3]}"); fi
  local form label flags envs
  local -a envargs
  for form in "${forms[@]}"; do
    IFS='|' read -r label flags envs <<<"$form"
    envargs=()
    if [[ -n "$envs" ]]; then IFS=';' read -ra envargs <<<"$envs"; fi
    run_launch "$mode" "$block" "$repo" SQUAD_COPILOT_FLAGS="$flags" "${envargs[@]}"
    assert_eq "0" "$LAUNCH_RC" "${mode}, exact argv (${label}): the launch runs"
    assert_eq "1" "$COPILOT_CALL_N" "${mode}, exact argv (${label}): copilot is launched once"
    assert_argv_exact "${mode}, exact argv (${label}): copilot receives -p <prompt> --model ${model} <policy argv> <operator flags>, token for token" "${want[@]}"
  done

  local -a badforms=(
    "conflict first, match second|--model ${other} --model ${model}|"
    "match first, conflict second as --model=|--model ${model} --model=${other}|"
    "match in flags, conflict in COPILOT_MODEL|--model ${model}|COPILOT_MODEL=${other}"
    "SQUAD_AGENT_MODEL matches, SQUAD_MODEL conflicts||SQUAD_AGENT_MODEL=${model};SQUAD_MODEL=${other}"
  )
  if [[ "$quick" == 1 ]]; then badforms=("${badforms[0]}"); fi
  for form in "${badforms[@]}"; do
    IFS='|' read -r label flags envs <<<"$form"
    envargs=()
    if [[ -n "$envs" ]]; then IFS=';' read -ra envargs <<<"$envs"; fi
    run_launch "$mode" "$block" "$repo" SQUAD_COPILOT_FLAGS="$flags" "${envargs[@]}"
    assert_eq "78" "$LAUNCH_RC" "${mode}, exact argv (${label}): refused (78)"
    assert_eq "0" "$COPILOT_CALL_N" "${mode}, exact argv (${label}): ... with no copilot launch, on either model"
    assert_eq "0" "${#SQUAD_ARGV_SEEN[@]}" "${mode}, exact argv (${label}): ... and no squad"
  done
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
  assert_eq "1" "$(model_flag_count)" "${mode}: ... and copilot receives exactly ONE --model token: the matching override is not forwarded next to the pin"
  assert_eq "$LEAD_MODEL" "$(model_values)" "${mode}: ... and it names the pinned model"
  assert_eq "-p" "${COPILOT_ARGV_SEEN[0]:-}" "${mode}: the prompt flag is still first"
  assert_eq "--model ${LEAD_MODEL}" "${COPILOT_ARGV_SEEN[2]:-} ${COPILOT_ARGV_SEEN[3]:-}" "${mode}: ... and the pin sits right after it, ahead of every operator flag"

  # Every spelling the real token parser accepts. SQUAD_COPILOT_FLAGS is split
  # on runs of whitespace and quotes are NOT interpreted, so the forms are
  # `--model X`, `--model=X` and any whitespace between tokens.
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model=${LEAD_MODEL}"
  assert_eq "0" "$LAUNCH_RC" "${mode}: a matching --model=<id> is accepted"
  assert_eq "$LEAD_MODEL" "$(model_values)" "${mode}: ... as exactly one --model, the pin"
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL} --model ${RALPH_MODEL}"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a matching --model followed by a conflicting second one is refused (78)"
  assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched"

  # new-project shares the whole launch path with prompt; the rest of the
  # token-form matrix runs once, on prompt, to keep this suite inside its time budget.
  if [[ "$mode" == "prompt" ]]; then
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL} --model=${LEAD_MODEL}"
    assert_eq "0" "$LAUNCH_RC" "${mode}: the same model named twice, in both forms, is accepted"
    assert_eq "$LEAD_MODEL" "$(model_values)" "${mode}: ... and canonicalizes to exactly one --model"
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL^^}"
    assert_eq "0" "$LAUNCH_RC" "${mode}: a matching --model in another letter case is accepted"
    assert_eq "$LEAD_MODEL" "$(model_values)" "${mode}: ... as exactly one --model in the policy's own spelling"
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="$(printf -- '--model\t%s\n  --model=%s' "$LEAD_MODEL" "$LEAD_MODEL")"
    assert_eq "$LEAD_MODEL" "$(model_values)" "${mode}: tab / newline / run-of-space separators between the tokens canonicalize to one --model"
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_MODEL="${LEAD_MODEL}" COPILOT_MODEL="${LEAD_MODEL^^}" SQUAD_AGENT_MODEL="${LEAD_MODEL}" SQUAD_COPILOT_FLAGS="--model=${LEAD_MODEL}"
    assert_eq "$LEAD_MODEL" "$(model_values)" "${mode}: every override source agreeing still yields exactly one --model"
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--log-level"
    assert_eq "1" "$(model_flag_count)" "${mode}: an operator flag left dangling at the end of SQUAD_COPILOT_FLAGS does not displace the pin"
    assert_ne "--log-level" "$(token_before_model)" "${mode}: ... and does not swallow it as its own value"

    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model=${LEAD_MODEL} --model=${RALPH_MODEL}"
    assert_eq "78" "$LAUNCH_RC" "${mode}: the same refusal for the --model=<id> form"
    assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched"
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL} --model"
    assert_eq "78" "$LAUNCH_RC" "${mode}: a trailing --model with no value is refused (78)"
    assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched"
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model \"${LEAD_MODEL}\""
    assert_eq "78" "$LAUNCH_RC" "${mode}: a double-quoted model is refused: quotes are not interpreted, so it is not a model id (78)"
    assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched"
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model='${LEAD_MODEL}'"
    assert_eq "78" "$LAUNCH_RC" "${mode}: a single-quoted --model='<id>' is refused the same way (78)"
    assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched"
    run_launch "$mode" "$block" "$REPO_ROLES" COPILOT_MODEL="${RALPH_MODEL}" SQUAD_COPILOT_FLAGS="--model ${LEAD_MODEL}"
    assert_eq "78" "$LAUNCH_RC" "${mode}: a stale COPILOT_MODEL naming another model is not bypassed by a matching --model (78)"
    assert_eq "0" "$COPILOT_CALL_N" "${mode}: ... and copilot is never launched"
  fi

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
  assert_eq "1" "$(model_flag_count)" "${mode}: ... as exactly one --model token on copilot's argv"
  assert_eq "-p" "${COPILOT_ARGV_SEEN[0]:-}" "${mode}: Squad's own -p <prompt> is still first"
  assert_eq "--model ${RALPH_MODEL}" "${COPILOT_ARGV_SEEN[2]:-} ${COPILOT_ARGV_SEEN[3]:-}" "${mode}: the pin sits right after it, ahead of the policy argv"
  assert_argv_has "${mode}: the coordinator agent is still selected" "squad"
  assert_argv_has "${mode}: the resolved tool policy is still applied" "--allow-all-tools"
  assert_contains "$LAUNCH_OUT" "Model: ${RALPH_MODEL} for role 'ralph'" "${mode}: the session log states the model, the role and where it came from"

  # triage runs the very same case block as watch (`watch|triage)`), so only the
  # role it resolves is checked here; the rest runs for watch and loop (this
  # suite's time budget).
  if [[ "$mode" == "triage" ]]; then continue; fi

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_MODEL="$RALPH_MODEL"
  assert_eq "0" "$LAUNCH_RC" "${mode}: a matching SQUAD_MODEL is accepted"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: ... with still exactly one --model"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${RALPH_MODEL}"
  assert_eq "0" "$LAUNCH_RC" "${mode}: a matching --model in SQUAD_COPILOT_FLAGS is accepted"
  assert_eq "1" "$(model_flag_count)" "${mode}: ... and copilot still receives exactly ONE --model token, not the pin plus the override"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: ... naming the pinned model"
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model=${RALPH_MODEL}"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: --model=<id> canonicalizes to exactly one --model"
  assert_eq "1" "$(model_flag_count)" "${mode}: ... as one token pair"
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${RALPH_MODEL} --model ${LEAD_MODEL}"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a matching --model followed by a conflicting second one is refused (78)"
  assert_eq "0" "${#SQUAD_ARGV_SEEN[@]}" "${mode}: ... before squad is started"

  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${RALPH_MODEL} --model=${RALPH_MODEL^^}"
  assert_eq "0" "$LAUNCH_RC" "${mode}: the same model named twice (other case, both forms) is accepted"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: ... as exactly one --model in the policy's own spelling"
  assert_eq "1" "$(model_flag_count)" "${mode}: ... and exactly one token pair"
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="$(printf -- '--model\t%s\n  --model=%s' "$RALPH_MODEL" "$RALPH_MODEL")"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: tab / newline / run-of-space separators canonicalize to one --model"
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--log-level"
  assert_eq "1" "$(model_flag_count)" "${mode}: an operator flag left dangling at the end of SQUAD_COPILOT_FLAGS does not displace the pin"
  assert_ne "--log-level" "$(token_before_model)" "${mode}: ... and does not swallow it as its own value"
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model ${RALPH_MODEL} --model"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a trailing --model with no value is refused (78)"
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model \"${RALPH_MODEL}\""
  assert_eq "78" "$LAUNCH_RC" "${mode}: a double-quoted model is refused: quotes are not interpreted, so it is not a model id (78)"
  assert_eq "0" "${#SQUAD_ARGV_SEEN[@]}" "${mode}: ... before squad is started"
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_COPILOT_FLAGS="--model='${RALPH_MODEL}'"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a single-quoted --model='<id>' is refused the same way (78)"
  run_launch "$mode" "$block" "$REPO_ROLES" COPILOT_MODEL="${LEAD_MODEL}" SQUAD_COPILOT_FLAGS="--model ${RALPH_MODEL}"
  assert_eq "78" "$LAUNCH_RC" "${mode}: a stale COPILOT_MODEL naming another model is not bypassed by a matching --model (78)"
  assert_eq "0" "${#SQUAD_ARGV_SEEN[@]}" "${mode}: ... before squad is started"

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

# --- 4b1. the whole argv, token for token ----------------------------------------
echo "-- the exact argv (one canonical --model, nothing else moved) --"
exact_argv_matrix prompt "$PROMPT_BLOCK" direct "$LEAD_MODEL" "$REPO_ROLES" 0
exact_argv_matrix new-project "$NEWPROJECT_BLOCK" direct "$LEAD_MODEL" "$REPO_ROLES" 1
exact_argv_matrix watch "$WATCH_BLOCK" watch "$RALPH_MODEL" "$REPO_ROLES" 0
exact_argv_matrix loop "$LOOP_BLOCK" watch "$RALPH_MODEL" "$REPO_ROLES" 1

# A role with no entry of its own runs on defaultModel, with an explicit warning
# in the session log -- and still on exactly one --model.
run_launch watch "$WATCH_BLOCK" "$REPO_DEFAULT" SQUAD_COPILOT_FLAGS="--model=${DEFAULT_MODEL}"
assert_eq "0" "$LAUNCH_RC" "defaultModel standing in for a role: the launch runs"
assert_eq "$DEFAULT_MODEL" "$(model_values)" "defaultModel standing in for a role: exactly one --model, the repository-wide one"
assert_contains "$LAUNCH_OUT" "WARNING: role 'ralph' has no agentModelOverrides.ralph entry" "defaultModel standing in for a role: the session log warns that the generic model applies"
assert_contains "$LAUNCH_OUT" "Model: ${DEFAULT_MODEL} for role 'ralph'" "defaultModel standing in for a role: ... and still states the model and role"
run_launch watch "$WATCH_BLOCK" "$REPO_ROLES"
assert_not_contains "$LAUNCH_OUT" "WARNING: role" "a role with its own entry: no generic-fallback warning in the log"
run_launch watch "$WATCH_BLOCK" "$REPO_AUTO"
assert_eq "" "$(model_values)" "an 'auto' role: Copilot gets no --model"
assert_contains "$LAUNCH_OUT" "declared 'auto': Copilot chooses the model for this role, on purpose" "an 'auto' role: the log says that is a declared choice"
assert_contains "$LAUNCH_OUT" "NOT PINNED" "an 'auto' role: ... and that the model is not pinned"
run_launch watch "$WATCH_BLOCK" "$REPO_NO_RALPH"
assert_contains "$LAUNCH_OUT" "declared none for this role" "a role with nothing declared: the log says nothing was declared (not 'auto')"
assert_not_contains "$LAUNCH_OUT" "on purpose" "a role with nothing declared: ... and does not call it a choice"

# --- 4b2. a pinned launch failure must stop Squad, through the real lifecycle ----
# Real Squad does not stop when its agent command exits non-zero. The stub squad
# above does not either (its log records "success:false, still polling"), so
# every assertion here is about what the WORKER does around a Squad that keeps
# going: worker/squad-agent (a child, not an exec), the real supervisor and the
# real entrypoint block.
echo "-- a pinned launch failure stops Squad and the worker (watch, loop) --"

for entry in "watch|WATCH_BLOCK" "loop|LOOP_BLOCK"; do
  mode="${entry%%|*}"
  blockvar="${entry##*|}"
  block="${!blockvar}"

  # Control: an UNPINNED session keeps the old behaviour exactly -- the stub
  # proves it stays alive and polls after a failed child, three attempts and a
  # clean worker exit. (This is what the pinned lifecycle exists to change.)
  run_launch "$mode" "$block" "$REPO_NONE" COPILOT_STUB_EXIT=9 SQUAD_STUB_ROUNDS=3 SQUAD_STUB_POLL=0.2
  assert_eq "0" "$LAUNCH_RC" "${mode}, control (unpinned): Squad ends by itself and the worker exits 0 as before"
  assert_eq "3" "$COPILOT_CALL_N" "${mode}, control (unpinned): the stub Squad kept polling after a failed agent: 3 launches"
  assert_eq "3" "$SQUAD_FAILED_N" "${mode}, control (unpinned): ... and logged each as a failed child"
  assert_eq "0" "$SQUAD_TERMS_N" "${mode}, control (unpinned): ... with nothing stopping it"
  assert_eq "no" "$([[ -e "$FAILURE_FILE" ]] && echo yes || echo no)" "${mode}, control (unpinned): no failure record is created"
  assert_contains "$LAUNCH_OUT" "CHECKPOINT-RAN" "${mode}, control (unpinned): the governance checkpoint still runs"

  # The pinned model cannot run: ONE attempt, then Squad is stopped and the
  # worker exits with Copilot's status. 60 rounds half a second apart would be
  # 30 seconds of retries if nothing stopped it.
  run_launch "$mode" "$block" "$REPO_ROLES" COPILOT_STUB_EXIT=9 COPILOT_STUB_SAYS="Task completed successfully." SQUAD_STUB_ROUNDS=60 SQUAD_STUB_POLL=0.5
  assert_eq "9" "$LAUNCH_RC" "${mode}: the worker exits with copilot's own non-zero status, not 0"
  assert_eq "1" "$COPILOT_CALL_N" "${mode}: copilot was launched exactly ONCE: no retry of the unavailable pin"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}: ... and that one attempt was on the pinned model"
  assert_eq "1" "$SQUAD_TERMS_N" "${mode}: the supervisor sent Squad exactly one TERM"
  if [[ "${SQUAD_ROUNDS_N:-0}" -ge 1 && "${SQUAD_ROUNDS_N:-0}" -lt 60 ]]; then
    assert_eq "ok" "ok" "${mode}: Squad's iterations stopped early (${SQUAD_ROUNDS_N} of 60 rounds started)"
  else
    assert_eq "between 1 and 59 rounds" "${SQUAD_ROUNDS_N:-?}" "${mode}: Squad's iterations stopped early"
  fi
  assert_contains "$(cat "$SQUAD_LOG")" "exit rounds=" "${mode}: Squad drained and exited itself (it was not killed)"
  assert_contains "$(cat "$SQUAD_LOG")" "draining=1" "${mode}: ... because of the TERM"
  if squad_stub_alive; then
    assert_eq "stopped" "still running (pid ${SQUAD_PID_SEEN})" "${mode}: no Squad process is left behind"
  else
    assert_eq "ok" "ok" "${mode}: no Squad process is left behind"
  fi
  assert_eq "9" "$(head -n1 "$FAILURE_FILE" 2>/dev/null)" "${mode}: the failure record holds copilot's exit status"
  assert_contains "$LAUNCH_OUT" "failed to launch Copilot (exit 9)" "${mode}: the session log reports the launch failure and its status"
  assert_contains "$LAUNCH_OUT" "No retry, no fallback model" "${mode}: ... and says nothing was retried or substituted"
  assert_contains "$LAUNCH_OUT" "CHECKPOINT-RAN" "${mode}: the governance checkpoint still runs before the worker exits"
  assert_contains "$LAUNCH_OUT" "GOVERNANCE-REPORT-RAN" "${mode}: ... and so does the governance report"
  assert_not_contains "$LAUNCH_OUT" "PUBLISHED" "${mode}: nothing is published"

  # The latch on its own, with the supervisor's reaction effectively disabled:
  # Squad keeps polling for all three rounds, but only the first reaches copilot.
  run_launch "$mode" "$block" "$REPO_ROLES" COPILOT_STUB_EXIT=9 SQUAD_STUB_ROUNDS=3 SQUAD_STUB_POLL=0.2 SQUAD_FOREGROUND_STOP_POLL_SECONDS=1000
  assert_eq "1" "$COPILOT_CALL_N" "${mode}, latch alone: three rounds ran but copilot was launched only ONCE"
  assert_eq "3" "$SQUAD_ROUNDS_N" "${mode}, latch alone: Squad itself kept polling (it was never stopped)"
  assert_eq "0" "$SQUAD_TERMS_N" "${mode}, latch alone: ... and nothing signalled it"
  assert_eq "2" "$(grep -c '^agent-failed 78 ' "$SQUAD_LOG" || true)" "${mode}, latch alone: the two later rounds were refused by the wrapper (78) before any launch"
  assert_eq "9" "$LAUNCH_RC" "${mode}, latch alone: the worker still exits with the recorded copilot status"

  # The normal completed workflow is untouched: copilot exits 0 every round.
  run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_STUB_ROUNDS=3 SQUAD_STUB_POLL=0.2
  assert_eq "0" "$LAUNCH_RC" "${mode}, success: a pinned session whose copilot exits 0 completes with 0"
  assert_eq "3" "$COPILOT_CALL_N" "${mode}, success: every round launched copilot"
  assert_eq "$RALPH_MODEL" "$(model_values)" "${mode}, success: ... on the pinned model, as exactly one --model"
  assert_eq "0" "$SQUAD_TERMS_N" "${mode}, success: the supervisor never stopped Squad"
  assert_eq "no" "$([[ -e "$FAILURE_FILE" ]] && echo yes || echo no)" "${mode}, success: no failure is recorded"
  assert_contains "$LAUNCH_OUT" "CHECKPOINT-RAN" "${mode}, success: the checkpoint runs"
  assert_not_contains "$LAUNCH_OUT" "failed to launch Copilot" "${mode}, success: no failure is reported"

  # The two blocks share this lifecycle code; the remaining cases run for
  # watch only (this suite's time budget).
  if [[ "$mode" == "watch" ]]; then
    # A Squad that fails for its own reasons (not a recorded pin failure) still
    # ends the session with its status, with or without a pin -- as errexit did.
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_STUB_EXIT=3
    assert_eq "3" "$LAUNCH_RC" "${mode}: a pinned session whose Squad itself exits 3 ends with 3"
    assert_not_contains "$LAUNCH_OUT" "CHECKPOINT-RAN" "${mode}: ... without the checkpoint, exactly as before"
    run_launch "$mode" "$block" "$REPO_NONE" SQUAD_STUB_EXIT=3
    assert_eq "3" "$LAUNCH_RC" "${mode}: and so does an unpinned one"
    assert_not_contains "$LAUNCH_OUT" "CHECKPOINT-RAN" "${mode}: ... without the checkpoint, exactly as before"

    # Nothing that merely arrives in the environment is trusted: a stale failure
    # path (with a failure in it) and a stale stop file do not stop a healthy session.
    printf '5\n' > "${WORK}/stale-failure"
    run_launch "$mode" "$block" "$REPO_ROLES" SQUAD_MODEL_PIN_FAILURE_FILE="${WORK}/stale-failure" SQUAD_FOREGROUND_STOP_FILE="${WORK}/stale-failure" SQUAD_STUB_ROUNDS=2 SQUAD_STUB_POLL=0.2
    assert_eq "0" "$LAUNCH_RC" "${mode}: a stale SQUAD_MODEL_PIN_FAILURE_FILE / SQUAD_FOREGROUND_STOP_FILE in the environment is ignored"
    assert_eq "2" "$COPILOT_CALL_N" "${mode}: ... both rounds ran copilot"
    assert_eq "0" "$SQUAD_TERMS_N" "${mode}: ... and Squad was not stopped"

    # Cancel: the worker is sent TERM (what ACA sends PID 1 on a stop) while
    # copilot is running. Squad's shutdown stops its agent, the wrapper forwards
    # that to copilot, and the session ends cleanly: a cancel is not a model
    # failure, nothing is latched or retried, and nothing is left running.
    LAUNCH_SIGNAL=TERM run_launch "$mode" "$block" "$REPO_ROLES" COPILOT_STUB_SLEEP=60 SQUAD_STUB_KILL_CHILD_ON_TERM=1 SQUAD_STUB_ROUNDS=5 SQUAD_STUB_POLL=0.2
    assert_eq "0" "$LAUNCH_RC" "${mode}, cancel: the worker ends cleanly on the forwarded TERM"
    assert_eq "1" "$COPILOT_CALL_N" "${mode}, cancel: copilot was launched once and no round started after the TERM"
    assert_eq "1" "$SQUAD_TERMS_N" "${mode}, cancel: Squad received exactly the one forwarded TERM"
    assert_eq "no" "$([[ -e "$FAILURE_FILE" ]] && echo yes || echo no)" "${mode}, cancel: no launch failure is recorded for a cancel"
    assert_not_contains "$LAUNCH_OUT" "failed to launch Copilot" "${mode}, cancel: ... and none is reported"
    assert_contains "$LAUNCH_OUT" "CHECKPOINT-RAN" "${mode}, cancel: the governance checkpoint still runs"
    assert_eq "" "$(leaked_pids)" "${mode}, cancel: no Squad, wrapper or copilot process is left running (pids ${SQUAD_PID_SEEN} ${AGENT_PIDS_SEEN}${COPILOT_PIDS_SEEN})"

    # The same for an unpinned session: its behaviour is the old one.
    LAUNCH_SIGNAL=TERM run_launch "$mode" "$block" "$REPO_NONE" COPILOT_STUB_SLEEP=60 SQUAD_STUB_KILL_CHILD_ON_TERM=1 SQUAD_STUB_ROUNDS=5 SQUAD_STUB_POLL=0.2
    assert_eq "0" "$LAUNCH_RC" "${mode}, cancel (unpinned): the worker ends cleanly on the forwarded TERM, as before"
    assert_eq "1" "$SQUAD_TERMS_N" "${mode}, cancel (unpinned): Squad received the one forwarded TERM"
    assert_eq "" "$(leaked_pids)" "${mode}, cancel (unpinned): nothing is left running"
  fi
done

# Every launch above left nothing behind: the last failure-lifecycle run, and a
# pinned launch failure on its own (the leak check is on the processes of THAT run).
run_launch watch "$WATCH_BLOCK" "$REPO_ROLES" COPILOT_STUB_EXIT=9 SQUAD_STUB_ROUNDS=60 SQUAD_STUB_POLL=0.5
assert_eq "9" "$LAUNCH_RC" "pinned launch failure (leak check): the worker exits with copilot's status"
assert_eq "" "$(leaked_pids)" "pinned launch failure: no Squad, wrapper or copilot process is left running (pids ${SQUAD_PID_SEEN} ${AGENT_PIDS_SEEN}${COPILOT_PIDS_SEEN})"

# --- 4b3. the same lifecycle against the REAL Squad ------------------------------
# The stub Squad above is a model of Squad 1.0.1; this runs the actual
# @bradygaster/squad-cli `loop` (the version worker/Dockerfile ships) with the
# real worker/squad-agent as its agent command, the real supervisor and the real
# entrypoint loop block. Only copilot is a stub. Squad is found through
# SQUAD_CLI_ENTRY (<squad-cli>/dist/cli-entry.js) or, as CI has it, next to
# SQUAD_SDK_DIR. When it cannot be found, is not the shipped version, or the
# host's node cannot execFile a bash script (Git Bash on Windows cannot), the
# scenario is SKIPPED, visibly, and everything above still stands.
echo "-- the lifecycle against the real Squad --"

real_squad_entry() {
  local cand=""
  if [[ -n "${SQUAD_CLI_ENTRY:-}" ]]; then
    cand="$SQUAD_CLI_ENTRY"
  elif [[ -n "${SQUAD_SDK_DIR:-}" ]]; then
    cand="${SQUAD_SDK_DIR}/../squad-cli/dist/cli-entry.js"
  fi
  if [[ -f "$cand" ]]; then printf '%s' "$cand"; fi
}
REAL_ENTRY="$(real_squad_entry)"
REAL_SKIP=""
if [[ -z "$REAL_ENTRY" ]]; then
  REAL_SKIP="no Squad CLI found (set SQUAD_CLI_ENTRY=<squad-cli>/dist/cli-entry.js, or SQUAD_SDK_DIR as CI does)"
else
  want_version="$(sed -n 's/^ARG SQUAD_VERSION=//p' "${WORKER_DIR}/Dockerfile" | head -n1 | tr -d '[:space:]')"
  have_version="$(node "$REAL_ENTRY" --version 2>/dev/null | head -n1 | tr -d '[:space:]')"
  if [[ -z "$want_version" || "$want_version" != "$have_version" ]]; then
    REAL_SKIP="the Squad CLI found reports '${have_version:-nothing}', not the '${want_version:-unknown}' worker/Dockerfile ships"
  fi
fi
REAL_BIN="${WORK}/real-bin"
mkdir -p "$REAL_BIN"
if [[ -z "$REAL_SKIP" ]]; then
  # Squad runs its agent command with execFile: a bash script must be runnable
  # directly by node on this host.
  printf '#!/usr/bin/env bash\nexit 0\n' > "${REAL_BIN}/exec-probe"
  chmod +x "${REAL_BIN}/exec-probe"
  if ! node -e 'require("child_process").execFile(process.argv[1], ["-p", "x"], (e) => process.exit(e ? 1 : 0))' "${REAL_BIN}/exec-probe" 2>/dev/null; then
    REAL_SKIP="this host's node cannot execFile a bash script, which is how Squad starts its agent command"
  fi
fi

if [[ -n "$REAL_SKIP" ]]; then
  echo "SKIP: the real-Squad lifecycle scenarios -- ${REAL_SKIP}. The stub-Squad scenarios above still ran."
else
  cp "${FAKE_BIN}/copilot" "${REAL_BIN}/copilot"
  # `squad`: the real CLI, with the production agent-cmd path (which does not
  # exist on a test host) mapped to a shim that runs the real worker/squad-agent.
  cat > "${REAL_BIN}/squad" <<'REALSQUAD'
#!/usr/bin/env bash
printf 'pid %s\n' "$$" >> "${SQUAD_STUB_LOG:?}"
args=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--agent-cmd" && "${2:-}" == /usr/local/lib/squad-on-aca/squad-agent ]]; then
    args+=("$1" "${REAL_AGENT_SHIM:?}"); shift 2; continue
  fi
  args+=("$1"); shift
done
exec node "${REAL_SQUAD_ENTRY:?}" "${args[@]}"
REALSQUAD
  cat > "${REAL_BIN}/agent-shim" <<'AGENTSHIM'
#!/usr/bin/env bash
printf 'agent %s\n' "$$" >> "${SQUAD_STUB_LOG:?}"
exec bash "${REAL_SQUAD_AGENT:?}" "$@"
AGENTSHIM
  chmod +x "${REAL_BIN}/squad" "${REAL_BIN}/agent-shim"
  REAL_TEAM_MD=$'# Team\n\n## Members\n\n| Name | Role | Charter | Status |\n|------|------|---------|--------|\n| Ralph | Work Monitor | - | active |'
  REAL_LOOP_MD=$'---\nconfigured: true\ninterval: 1\ntimeout: 1\n---\nDo the thing.'
  real_launch() {
    LAUNCH_BIN="$REAL_BIN" SEED_TEAM_MD="$REAL_TEAM_MD" run_launch loop "$LOOP_BLOCK" "$@" \
      LOOP_MARKDOWN="$REAL_LOOP_MD" LOOP_INTERVAL_MINUTES=1 LOOP_TIMEOUT_MINUTES=1 \
      REAL_SQUAD_ENTRY="$REAL_ENTRY" REAL_AGENT_SHIM="${REAL_BIN}/agent-shim"
  }

  # Pinned: copilot cannot run the model. Real Squad would wait a whole
  # interval (60s) and launch the agent again; here it must be stopped after the
  # first failed launch.
  started_at=$SECONDS
  real_launch "$REPO_ROLES" COPILOT_STUB_EXIT=9 COPILOT_STUB_SAYS="Task completed successfully."
  took=$((SECONDS - started_at))
  assert_eq "9" "$LAUNCH_RC" "real Squad, pinned launch failure: the worker exits with copilot's own status"
  assert_eq "1" "$COPILOT_CALL_N" "real Squad, pinned launch failure: copilot was launched exactly ONCE: no retry on the unavailable pin"
  assert_eq "$RALPH_MODEL" "$(model_values)" "real Squad, pinned launch failure: ... on the pinned model, as exactly one --model"
  assert_eq "9" "$(head -n1 "$FAILURE_FILE" 2>/dev/null)" "real Squad, pinned launch failure: the failure record holds copilot's status"
  assert_contains "$LAUNCH_OUT" "failed to launch Copilot (exit 9)" "real Squad, pinned launch failure: the session log reports it"
  assert_contains "$LAUNCH_OUT" "CHECKPOINT-RAN" "real Squad, pinned launch failure: the governance checkpoint still runs"
  if [[ "$took" -lt 40 ]]; then
    assert_eq "ok" "ok" "real Squad, pinned launch failure: stopped within ${took}s, well before Squad's 60s interval would have run it again"
  else
    assert_eq "under 40s" "${took}s" "real Squad, pinned launch failure: stopped well before Squad's 60s interval"
  fi
  assert_eq "" "$(leaked_pids)" "real Squad, pinned launch failure: no Squad, wrapper or copilot process is left running (pids ${SQUAD_PID_SEEN} ${AGENT_PIDS_SEEN}${COPILOT_PIDS_SEEN})"

  # Control: the premise. Unpinned, the same real Squad is STILL ALIVE after its
  # agent failed, and keeps polling until it is told to stop.
  LAUNCH_SIGNAL=TERM LAUNCH_SIGNAL_DELAY=4 real_launch "$REPO_NONE" COPILOT_STUB_EXIT=9
  assert_eq "1" "$LAUNCH_ALIVE_AT_SIGNAL" "real Squad, unpinned control: Squad is still running 4s after its agent failed (it does not stop on a failed agent)"
  assert_eq "1" "$COPILOT_CALL_N" "real Squad, unpinned control: copilot was launched once"
  assert_eq "0" "$LAUNCH_RC" "real Squad, unpinned control: the forwarded TERM ends Squad's drain and the worker with 0, as before"
  assert_eq "" "$(leaked_pids)" "real Squad, unpinned control: nothing is left running"

  # Cancel with copilot in flight, pinned. Squad 1.0.1 only installs its
  # SIGTERM handler AFTER its first round (loop.js `await executeRound()` runs
  # before `process.on('SIGTERM', ...)`), so a TERM during round 1 simply kills
  # Squad (143) and leaves its agent, the wrapper and copilot orphaned. The
  # supervisor's abnormal-end sweep of the owned process group must reap them.
  LAUNCH_SIGNAL=TERM real_launch "$REPO_ROLES" COPILOT_STUB_SLEEP=60
  case "$LAUNCH_RC" in
    0|143) assert_eq "ok" "ok" "real Squad, pinned cancel: the worker ends on the forwarded TERM (rc ${LAUNCH_RC}; 143 = Squad itself died of the TERM in round 1)" ;;
    *) assert_eq "0 or 143" "$LAUNCH_RC" "real Squad, pinned cancel: the worker ends on the forwarded TERM" ;;
  esac
  assert_eq "1" "$COPILOT_CALL_N" "real Squad, pinned cancel: copilot was launched once"
  assert_eq "no" "$([[ -e "$FAILURE_FILE" ]] && echo yes || echo no)" "real Squad, pinned cancel: a cancel is not recorded as a model failure"
  assert_not_contains "$LAUNCH_OUT" "failed to launch Copilot" "real Squad, pinned cancel: ... and none is reported"
  if [[ "$LAUNCH_RC" == "143" ]]; then
    assert_contains "$LAUNCH_OUT" "process group still held processes" "real Squad, pinned cancel: the orphaned wrapper and copilot were reaped by the owned-group sweep"
  fi
  assert_eq "" "$(leaked_pids)" "real Squad, pinned cancel: nothing is left running (pids ${SQUAD_PID_SEEN} ${AGENT_PIDS_SEEN}${COPILOT_PIDS_SEEN})"
fi

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

# The failure lifecycle is armed in BOTH Squad-driven blocks, in order: init
# before the supervisor, settle straight after it, then the checkpoint and the
# report, and only then the worker exits with the recorded status.
for entry in "loop|LOOP_BLOCK" "watch|WATCH_BLOCK"; do
  mode="${entry%%|*}"
  blockvar="${entry##*|}"
  active_block="$(printf '%s\n' "${!blockvar}" | grep -vE '^[[:space:]]*#' || true)"
  init_n="$(grep -n 'squad_model_pin_lifecycle_init' <<<"$active_block" | head -n1 | cut -d: -f1)"
  run_n="$(grep -n 'squad_run_foreground_with_signal_forwarding' <<<"$active_block" | head -n1 | cut -d: -f1)"
  settle_n="$(grep -n 'squad_model_pin_settle_session "\$SQUAD_FOREGROUND_RC"' <<<"$active_block" | head -n1 | cut -d: -f1)"
  check_n="$(grep -n 'squad_policy_checkpoint' <<<"$active_block" | head -n1 | cut -d: -f1)"
  exit_n="$(grep -n 'squad_model_pin_exit_if_failed' <<<"$active_block" | head -n1 | cut -d: -f1)"
  if [[ -n "$init_n" && -n "$run_n" && -n "$settle_n" && -n "$check_n" && -n "$exit_n" ]] \
     && (( init_n < run_n && run_n < settle_n && settle_n < check_n && check_n < exit_n )); then
    assert_eq "ok" "ok" "${mode}: init < supervisor < settle < checkpoint < exit-if-failed"
  else
    assert_eq "init < run < settle < checkpoint < exit" "init=${init_n:-?} run=${run_n:-?} settle=${settle_n:-?} checkpoint=${check_n:-?} exit=${exit_n:-?}" "${mode}: the pinned-failure lifecycle is wired in order"
  fi
done

test_summary
