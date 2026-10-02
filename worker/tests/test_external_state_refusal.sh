#!/usr/bin/env bash
# Issue #117: refuse externalized Squad state / remote teamRoot before the
# agent starts.
#
# Squad 0.13 supports two layouts where the mutable Squad state is NOT in the
# repo's own `.squad/`:
#   - `stateLocation: "external"` (written by `squad externalize`): state
#     moves to a per-user app-data directory outside the repo.
#   - a `teamRoot` other than `.` (written by `squad init --mode remote`):
#     state lives in another `.squad/`, resolved relative to the project root.
#
# squad-aca clones a repo into an ephemeral container and hardens, commits,
# and pushes `.squad/` in THAT checkout only. If either layout is in play,
# the real state is not where squad-aca looks, so the governance lock and
# audit trail would protect a directory that does not hold it. This suite
# proves, with the REAL function EXTRACTED from worker/entrypoint.sh (never a
# reimplementation, the same awk-range technique worker/tests/test_squad_health.sh
# already uses for functions in this same file):
#
#   squad_external_state_gate()  -- reads ${REPO_DIR}/.squad/config.json with
#                                    `node` (never grep, to avoid false
#                                    positives on the strings appearing in
#                                    comments or unrelated values), applies
#                                    EXACTLY Squad's own config.json
#                                    recognition rule (verified against the
#                                    published @bradygaster/squad-sdk@0.13.1
#                                    package's dist/resolution.js:
#                                    loadDirConfig() only treats a
#                                    config.json as "live" when it has BOTH a
#                                    numeric `version` and a string
#                                    `teamRoot`), and fails closed (exit 78)
#                                    only on a genuinely recognized
#                                    `stateLocation: "external"` or a
#                                    `teamRoot` other than `.`.
#
# Proven here, with REAL config files in a REAL temp repo directory (never a
# mock of the gate's own logic):
#   1. stateLocation "external" -> exit 78, cause named in the log.
#   2. a non-"." teamRoot -> exit 78, cause named in the log.
#   3. no .squad/config.json at all -> proceeds normally (exit 0).
#   4. config.json present but with neither key -> proceeds normally.
#   5. teamRoot "." and stateLocation "local" (or any non-"external" value)
#      -> proceeds normally.
#   6. a malformed (unparseable) config.json -> proceeds normally, never a
#      false-positive refusal.
#   7. ORDERING: a driver mirroring entrypoint.sh's own shape (bash,
#      `set -Eeuo pipefail`, clone stand-in -> gate call -> agent-start
#      stand-in, exactly as the real call site wires it) proves the agent
#      stand-in runs after a clean gate, and NEVER runs after a refusing one
#      -- not merely that the gate function returned some exit code.
#   8. STATIC ordering: the real call site in worker/entrypoint.sh sits after
#      the clone and after the ref checkout block, and before `squad init`,
#      the health gate, and policy hardening.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
ENTRYPOINT="${WORKER_DIR}/entrypoint.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node bash

echo "== externalized Squad state refusal (issue #117) =="

[[ -f "$ENTRYPOINT" ]] || { echo "FAIL: worker/entrypoint.sh is missing"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-external-state-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

# ===========================================================================
# Extract the real function, unedited, from worker/entrypoint.sh.
# ===========================================================================
GATE_FN="$(awk '/^squad_external_state_gate\(\) \{/,/^\}/' "$ENTRYPOINT")"
LOG_FN="$(awk '/^log\(\) \{/,/^\}/' "$ENTRYPOINT")"

assert_ne "" "$GATE_FN" "squad_external_state_gate() is present in worker/entrypoint.sh"
assert_ne "" "$LOG_FN" "entrypoint.sh's log() helper is present"

# A REAL temp "repo" directory -- this is what REPO_DIR points at in every
# real worker run. Each case gets its own fresh one with a real
# .squad/config.json (or none at all) written to disk, never a stand-in for
# the gate's own JSON logic.
make_repo() {
  local name="$1"
  local dir="${WORK}/repo-${name}"
  mkdir -p "${dir}/.squad"
  printf '%s\n' "$dir"
}

# Runs squad_external_state_gate (extracted, real) in a fresh bash
# subprocess with REPO_DIR pointed at a real temp repo, under the SAME
# `set -Eeuo pipefail` entrypoint.sh itself runs under, and reports both the
# captured log output and the real process exit code.
run_gate() {
  local repo_dir="$1"
  local driver="${WORK}/gate-driver-$$-${RANDOM}.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf 'REPO_DIR=%q\n' "$repo_dir"
    printf '%s\n' "$LOG_FN"
    printf '%s\n' "$GATE_FN"
    echo 'squad_external_state_gate'
    echo 'echo "GATE_RETURNED_ZERO"'
  } > "$driver"
  chmod +x "$driver"
  bash "$driver"
  echo "DRIVER_EXIT_CODE:$?"
  rm -f "$driver"
}

# ===========================================================================
# 1. stateLocation: "external" -> exit 78, cause named in the log, agent
#    stand-in never reached.
# ===========================================================================
repo_external="$(make_repo external)"
cat > "${repo_external}/.squad/config.json" <<'JSON'
{
  "version": 1,
  "teamRoot": ".",
  "stateLocation": "external",
  "projectKey": "squad-on-aca"
}
JSON
out_external="$(run_gate "$repo_external")"
assert_contains "$out_external" "Externalized Squad state detected" \
  "stateLocation external: logs detection"
assert_contains "$out_external" "external" \
  "stateLocation external: the cause ('external'/'squad externalize') is named in the log"
assert_contains "$out_external" "squad internalize" \
  "stateLocation external: the remedy ('squad internalize') is named in the log"
assert_not_contains "$out_external" "GATE_RETURNED_ZERO" \
  "stateLocation external: the line AFTER the gate call never runs -- refused before anything else"
assert_contains "$out_external" "DRIVER_EXIT_CODE:78" \
  "stateLocation external: the driver process exits 78, matching the rest of entrypoint.sh's fail-closed gates"

# ===========================================================================
# 2. A non-"." teamRoot -> exit 78, cause named in the log.
# ===========================================================================
repo_remote="$(make_repo remote)"
cat > "${repo_remote}/.squad/config.json" <<'JSON'
{
  "version": 1,
  "teamRoot": "../team-repo"
}
JSON
out_remote="$(run_gate "$repo_remote")"
assert_contains "$out_remote" "Externalized Squad state detected" \
  "remote teamRoot: logs detection"
assert_contains "$out_remote" "../team-repo" \
  "remote teamRoot: the actual configured teamRoot value is named in the log"
assert_not_contains "$out_remote" "GATE_RETURNED_ZERO" \
  "remote teamRoot: the line AFTER the gate call never runs"
assert_contains "$out_remote" "DRIVER_EXIT_CODE:78" \
  "remote teamRoot: the driver process exits 78"

# ===========================================================================
# 3. No .squad/config.json at all -> proceeds normally. The common case must
#    never be falsely refused.
# ===========================================================================
repo_absent="$(make_repo absent)"
out_absent="$(run_gate "$repo_absent")"
assert_not_contains "$out_absent" "Externalized Squad state detected" \
  "no config.json: never reports a detection"
assert_contains "$out_absent" "GATE_RETURNED_ZERO" \
  "no config.json: the session proceeds"
assert_contains "$out_absent" "DRIVER_EXIT_CODE:0" \
  "no config.json: the driver exits 0, never 78"

# ===========================================================================
# 4. config.json present but with NEITHER key -> proceeds normally. Mirrors
#    Squad's own loadDirConfig(): a config.json missing `version` or
#    `teamRoot` is not recognized as a live config at all.
# ===========================================================================
repo_neither="$(make_repo neither)"
cat > "${repo_neither}/.squad/config.json" <<'JSON'
{
  "consult": true
}
JSON
out_neither="$(run_gate "$repo_neither")"
assert_not_contains "$out_neither" "Externalized Squad state detected" \
  "config.json with neither key: never reports a detection"
assert_contains "$out_neither" "GATE_RETURNED_ZERO" \
  "config.json with neither key: the session proceeds"
assert_contains "$out_neither" "DRIVER_EXIT_CODE:0" \
  "config.json with neither key: the driver exits 0"

# ===========================================================================
# 5. teamRoot "." and stateLocation "local" -> proceeds normally. This is the
#    live, local-state shape a real config.json carries day to day.
# ===========================================================================
repo_local="$(make_repo local)"
cat > "${repo_local}/.squad/config.json" <<'JSON'
{
  "version": 1,
  "teamRoot": ".",
  "stateLocation": "local"
}
JSON
out_local="$(run_gate "$repo_local")"
assert_not_contains "$out_local" "Externalized Squad state detected" \
  "teamRoot '.' + stateLocation 'local': never reports a detection"
assert_contains "$out_local" "GATE_RETURNED_ZERO" \
  "teamRoot '.' + stateLocation 'local': the session proceeds"
assert_contains "$out_local" "DRIVER_EXIT_CODE:0" \
  "teamRoot '.' + stateLocation 'local': the driver exits 0"

# ===========================================================================
# 6. A malformed (unparseable) config.json -> proceeds normally, never a
#    false-positive refusal from a JSON.parse failure.
# ===========================================================================
repo_malformed="$(make_repo malformed)"
printf '{ this is not valid json' > "${repo_malformed}/.squad/config.json"
out_malformed="$(run_gate "$repo_malformed")"
assert_not_contains "$out_malformed" "Externalized Squad state detected" \
  "malformed config.json: never reports a detection"
assert_contains "$out_malformed" "GATE_RETURNED_ZERO" \
  "malformed config.json: the session proceeds"
assert_contains "$out_malformed" "DRIVER_EXIT_CODE:0" \
  "malformed config.json: the driver exits 0"

# ===========================================================================
# 7. ORDERING: a driver mirroring entrypoint.sh's own structure -- bash,
#    `set -Eeuo pipefail`, a clone stand-in, the REAL gate call wired exactly
#    as worker/entrypoint.sh wires it, then an agent-start stand-in -- proves
#    a clean repo lets execution REACH the agent stand-in, and an
#    externalized/remote repo stops it from EVER being reached.
# ===========================================================================
run_ordering_driver() {
  local case_name="$1" repo_dir="$2"
  local state="${WORK}/order-${case_name}"
  mkdir -p "$state"
  local driver="${state}/driver.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf '%s\n' "$LOG_FN"
    printf '%s\n' "$GATE_FN"
    printf 'REPO_DIR=%q\n' "$repo_dir"
    printf 'STATE=%q\n' "$state"
    # Clone stand-in: entrypoint.sh's own clone/checkout happen immediately
    # before the real call site.
    echo ': > "${STATE}/clone-ran"'
    # The REAL wiring, copied verbatim from worker/entrypoint.sh's own call
    # site (a bare call, no guard), not reworded.
    echo 'squad_external_state_gate'
    # Agent-start stand-in: squad init / the health gate / policy hardening /
    # the agent itself all live after this point in the real script.
    echo ': > "${STATE}/agent-start-ran"'
  } > "$driver"
  chmod +x "$driver"
  bash "$driver" >"${state}/out.log" 2>&1
  echo "$?" > "${state}/exit-code"
}

# Confirm the call-site line in the driver is a byte-for-byte copy of the
# real one in worker/entrypoint.sh, so this driver cannot silently drift from
# the real wiring it claims to mirror.
real_call_site="$(grep -n '^squad_external_state_gate$' "$ENTRYPOINT" | head -1 | cut -d: -f2-)"
assert_eq "squad_external_state_gate" "$real_call_site" \
  "the real call site in worker/entrypoint.sh is exactly a bare 'squad_external_state_gate' call"

run_ordering_driver clean "$repo_local"
assert_eq "1" "$([[ -f "${WORK}/order-clean/clone-ran" ]] && echo 1 || echo 0)" \
  "ordering (clean repo): the clone stand-in ran"
assert_eq "1" "$([[ -f "${WORK}/order-clean/agent-start-ran" ]] && echo 1 || echo 0)" \
  "ordering (clean repo): the agent-start stand-in ran AFTER a clean gate"
assert_eq "0" "$(cat "${WORK}/order-clean/exit-code")" \
  "ordering (clean repo): the whole driver exits 0"

run_ordering_driver externalized "$repo_external"
assert_eq "1" "$([[ -f "${WORK}/order-externalized/clone-ran" ]] && echo 1 || echo 0)" \
  "ordering (externalized repo): the clone stand-in still ran (the gate runs AFTER the clone, not instead of it)"
assert_eq "0" "$([[ -f "${WORK}/order-externalized/agent-start-ran" ]] && echo 1 || echo 0)" \
  "ordering (externalized repo): the agent-start stand-in NEVER ran -- refused before the agent could start"
assert_eq "78" "$(cat "${WORK}/order-externalized/exit-code")" \
  "ordering (externalized repo): the whole driver exits 78"

run_ordering_driver remote "$repo_remote"
assert_eq "0" "$([[ -f "${WORK}/order-remote/agent-start-ran" ]] && echo 1 || echo 0)" \
  "ordering (remote teamRoot repo): the agent-start stand-in NEVER ran"
assert_eq "78" "$(cat "${WORK}/order-remote/exit-code")" \
  "ordering (remote teamRoot repo): the whole driver exits 78"

# ===========================================================================
# 8. STATIC ordering: the real call site in worker/entrypoint.sh sits after
#    the initial clone and the ref checkout block, and before `squad init`,
#    the health gate, and policy hardening.
# ===========================================================================
line_of() { grep -n "$1" "$ENTRYPOINT" | head -1 | cut -d: -f1; }

clone_line="$(line_of '^git clone --depth')"
gate_call_line="$(line_of '^squad_external_state_gate$')"
squad_init_line="$(line_of 'squad init --preset')"
health_gate_line="$(line_of 'squad_health_gate_applies_to_mode "')"
policy_lib_line="$(line_of '^SQUAD_POLICY_LIB=')"

assert_eq "1" "$([[ -n "$clone_line" && -n "$gate_call_line" && "$gate_call_line" -gt "$clone_line" ]] && echo 1 || echo 0)" \
  "the real squad_external_state_gate call site (@${gate_call_line:-?}) sits AFTER the clone (@${clone_line:-?})"
assert_eq "1" "$([[ -n "$gate_call_line" && -n "$squad_init_line" && "$squad_init_line" -gt "$gate_call_line" ]] && echo 1 || echo 0)" \
  "the real call site (@${gate_call_line:-?}) sits BEFORE 'squad init' (@${squad_init_line:-?})"
assert_eq "1" "$([[ -n "$gate_call_line" && -n "$health_gate_line" && "$health_gate_line" -gt "$gate_call_line" ]] && echo 1 || echo 0)" \
  "the real call site (@${gate_call_line:-?}) sits BEFORE the squad health gate (@${health_gate_line:-?})"
assert_eq "1" "$([[ -n "$gate_call_line" && -n "$policy_lib_line" && "$policy_lib_line" -gt "$gate_call_line" ]] && echo 1 || echo 0)" \
  "the real call site (@${gate_call_line:-?}) sits BEFORE policy hardening (@${policy_lib_line:-?})"

test_summary
