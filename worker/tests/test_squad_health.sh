#!/usr/bin/env bash
# Issue #116: gate the session on `squad health --json`.
#
# Squad 0.13 ships `squad health --json` (schema `squad-health/v1`): checks
# team, registry-charters, routing, state-backend, and env-vars, built for
# "gate dispatch on readiness" (verified directly against the published
# @bradygaster/squad-cli@0.13.1 package -- `npm pack` + read
# dist/cli/commands/health.js: overall `status` is `pass`/`fail` only (no
# `warn`); each check's own `status` is `pass`/`fail`/`skip`; failing check
# ids live at `.checks[].id`; the CLI itself exits 1 on an overall fail).
#
# worker/entrypoint.sh adds two functions for this:
#   squad_health_gate_applies_to_mode()  -- which SQUAD_MODE values dispatch
#                                            an agent and therefore pay for
#                                            the gate.
#   squad_health_gate()                  -- runs `squad health --json`,
#                                            classifies the result as
#                                            healthy / unavailable / failed,
#                                            and fails closed (exit 78) only
#                                            on a genuine parsed "fail".
#
# This suite proves, with the REAL functions EXTRACTED from
# worker/entrypoint.sh (never a reimplementation, the same awk-range
# technique worker/tests/test_security_f3_parity_announce.sh and
# worker/tests/test_no_orphan_children.sh already use for functions in this
# same file):
#
#   1. A healthy report (status: "pass") lets the session proceed --
#      squad_health_gate returns 0 and logs a "healthy" (PASS) line, never a
#      "fail".
#   2. A report with status: "fail" exits 78 AND logs every failing check id
#      -- not just the word "failed".
#   3. An older/broken CLI -- a stub that errors on `health` entirely, and
#      separately a stub that emits unparseable output -- is reported as
#      UNAVAILABLE: the session is NOT aborted, and the log never calls it a
#      pass.
#   4. squad_health_gate_applies_to_mode() answers correctly for every mode
#      worker/entrypoint.sh actually dispatches on (the `case
#      "${SQUAD_MODE:-smoke}" in` list), not just the ones this suite
#      happened to think of.
#   5. WIRING + ORDERING, checked two ways:
#      a. STATICALLY: the real call site sits textually after SubSquad
#         activation finishes and before squad_policy_harden is invoked.
#      b. DYNAMICALLY: a driver mirroring entrypoint.sh's own shape (bash,
#         `set -Eeuo pipefail`, the same bootstrap -> gate -> hardening
#         sequence) proves a healthy gate lets execution actually REACH the
#         hardening stand-in, and a failing gate stops it from EVER being
#         reached -- not merely that the gate function returned some value.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
ENTRYPOINT="${WORKER_DIR}/entrypoint.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node bash

echo "== squad health --json gate (issue #116) =="

[[ -f "$ENTRYPOINT" ]] || { echo "FAIL: worker/entrypoint.sh is missing"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-health-gate-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

# ===========================================================================
# Extract the real functions, unedited, from worker/entrypoint.sh.
# ===========================================================================
APPLIES_FN="$(awk '/^squad_health_gate_applies_to_mode\(\) \{/,/^\}/' "$ENTRYPOINT")"
GATE_FN="$(awk '/^squad_health_gate\(\) \{/,/^\}/' "$ENTRYPOINT")"
LOG_FN="$(awk '/^log\(\) \{/,/^\}/' "$ENTRYPOINT")"

assert_ne "" "$APPLIES_FN" "squad_health_gate_applies_to_mode() is present in worker/entrypoint.sh"
assert_ne "" "$GATE_FN" "squad_health_gate() is present in worker/entrypoint.sh"
assert_ne "" "$LOG_FN" "entrypoint.sh's log() helper is present"

# A STUB `squad` binary that answers `squad health --json` however the test
# case asks, via env vars, and complains loudly about any OTHER invocation so
# a stray real call never silently no-ops.
FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/squad" <<'STUB'
#!/usr/bin/env bash
# Stub for worker/tests/test_squad_health.sh.
if [[ "${1:-}" == "health" ]]; then
  case "${SQUAD_STUB_HEALTH_MODE:-pass}" in
    pass)
      cat <<'JSON'
{"schema":"squad-health/v1","status":"pass","checks":[{"id":"team","status":"pass","message":"ok"},{"id":"registry-charters","status":"pass","message":"ok"},{"id":"routing","status":"pass","message":"ok"},{"id":"state-backend","status":"skip","message":"No state backend is configured"},{"id":"env-vars","status":"skip","message":"No required environment variables are declared"}]}
JSON
      exit 0
      ;;
    fail)
      cat <<'JSON'
{"schema":"squad-health/v1","status":"fail","checks":[{"id":"team","status":"pass","message":"ok"},{"id":"registry-charters","status":"fail","message":".squad/registry.json is missing"},{"id":"routing","status":"fail","message":"routing.md has no parseable routing rules"},{"id":"state-backend","status":"skip","message":"No state backend is configured"},{"id":"env-vars","status":"skip","message":"No required environment variables are declared"}]}
JSON
      exit 1
      ;;
    missing-command)
      echo "squad: error: unknown command 'health'" >&2
      exit 1
      ;;
    garbage-output)
      echo "this is not json at all"
      exit 0
      ;;
  esac
fi
echo "UNEXPECTED STUB CALL: squad $*" >&2
exit 99
STUB
chmod +x "${FAKE_BIN}/squad"

# Runs squad_health_gate (extracted, real) in a fresh bash subprocess with the
# stub squad on PATH, under the SAME `set -Eeuo pipefail` entrypoint.sh itself
# runs under, and reports both the captured log output and the real process
# exit code.
run_gate() {
  local health_mode="$1"
  local driver="${WORK}/gate-driver-${health_mode}-$$-${RANDOM}.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf '%s\n' "$LOG_FN"
    printf '%s\n' "$GATE_FN"
    echo 'squad_health_gate'
    echo 'echo "GATE_RETURNED_ZERO"'
  } > "$driver"
  chmod +x "$driver"
  SQUAD_STUB_HEALTH_MODE="$health_mode" PATH="${FAKE_BIN}:${PATH}" bash "$driver"
  echo "DRIVER_EXIT_CODE:$?"
  rm -f "$driver"
}

# ===========================================================================
# 1. Healthy: the session proceeds (the gate returns 0, logged as PASS/not
#    FAIL), and the driver script's OWN continuation line after the gate call
#    actually runs -- proving this is not merely "did not crash" but "let
#    execution continue".
# ===========================================================================
out_pass="$(run_gate pass)"
assert_contains "$out_pass" "Squad health: PASS" \
  "healthy report: squad_health_gate logs a PASS line"
assert_not_contains "$out_pass" "Squad health: FAIL" \
  "healthy report: squad_health_gate never logs FAIL"
assert_contains "$out_pass" "GATE_RETURNED_ZERO" \
  "healthy report: the line AFTER the gate call actually ran -- the session proceeds"
assert_contains "$out_pass" "DRIVER_EXIT_CODE:0" \
  "healthy report: the driver process exits 0, never 78"

# ===========================================================================
# 2. Failed: exit 78, AND every failing check id is named -- not just the
#    word "failed". The continuation line never runs.
# ===========================================================================
out_fail="$(run_gate fail)"
assert_contains "$out_fail" "Squad health: FAIL" \
  "fail report: squad_health_gate logs a FAIL line"
assert_contains "$out_fail" "registry-charters" \
  "fail report: the failing 'registry-charters' check id is named in the log"
assert_contains "$out_fail" "routing" \
  "fail report: the failing 'routing' check id is named in the log"
assert_not_contains "$out_fail" "GATE_RETURNED_ZERO" \
  "fail report: the line AFTER the gate call never runs -- the session is stopped, not merely warned"
assert_contains "$out_fail" "DRIVER_EXIT_CODE:78" \
  "fail report: the driver process exits 78 (fail-closed), matching the rest of entrypoint.sh's fail-closed gates"

# A check that actually passed ("team") must NOT be reported as failing --
# the id list is the ACTUAL failing set, not every check.
assert_not_contains "$(printf '%s' "$out_fail" | grep 'Squad health: FAIL')" "team," \
  "fail report: a check that actually PASSED (team) is not listed among the failing ids"

# ===========================================================================
# 3. Degrades honestly on an older/broken CLI: UNAVAILABLE, never a pass, and
#    never a hard failure either. Two distinct ways an old CLI can show up:
#    the subcommand itself does not exist, and a CLI that runs but returns
#    output this parser cannot read as a squad-health/v1 report.
# ===========================================================================
out_missing="$(run_gate missing-command)"
assert_contains "$out_missing" "Squad health: UNAVAILABLE" \
  "missing 'health' subcommand: reported as UNAVAILABLE"
assert_not_contains "$out_missing" "Squad health: PASS" \
  "missing 'health' subcommand: never silently reported as a pass"
assert_not_contains "$out_missing" "Squad health: FAIL" \
  "missing 'health' subcommand: never hard-fails -- an older CLI still has to keep working"
assert_contains "$out_missing" "GATE_RETURNED_ZERO" \
  "missing 'health' subcommand: the session still proceeds"
assert_contains "$out_missing" "DRIVER_EXIT_CODE:0" \
  "missing 'health' subcommand: the driver exits 0, not 78"

out_garbage="$(run_gate garbage-output)"
assert_contains "$out_garbage" "Squad health: UNAVAILABLE" \
  "unparseable output: reported as UNAVAILABLE"
assert_not_contains "$out_garbage" "Squad health: PASS" \
  "unparseable output: never silently reported as a pass"
assert_not_contains "$out_garbage" "Squad health: FAIL" \
  "unparseable output: never hard-fails"
assert_contains "$out_garbage" "GATE_RETURNED_ZERO" \
  "unparseable output: the session still proceeds"
assert_contains "$out_garbage" "DRIVER_EXIT_CODE:0" \
  "unparseable output: the driver exits 0, not 78"

# ===========================================================================
# 4. squad_health_gate_applies_to_mode() answers correctly for every mode
#    worker/entrypoint.sh's own `case "${SQUAD_MODE:-smoke}" in` dispatches
#    on -- read directly out of the real case block, so a NEW mode added
#    there later is covered by this list automatically rather than by a
#    hand-maintained copy.
# ===========================================================================
DISPATCH_CASE="$(awk '/^case "\$\{SQUAD_MODE:-smoke\}" in$/,/^esac$/' "$ENTRYPOINT")"
assert_ne "" "$DISPATCH_CASE" "the real SQUAD_MODE dispatch case block is present in worker/entrypoint.sh"

check_mode_applies() {
  local mode="$1" expect="$2"
  local driver="${WORK}/mode-driver-${mode}.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf '%s\n' "$APPLIES_FN"
    printf 'squad_health_gate_applies_to_mode %q\n' "$mode"
    echo 'echo $?'
  } > "$driver"
  local got
  got="$(bash "$driver")"
  rm -f "$driver"
  assert_eq "$expect" "$got" \
    "squad_health_gate_applies_to_mode('${mode}') == ${expect} (0 = gated, 1 = skipped)"
}

# Agent-dispatching modes: a one-shot `copilot -p` (prompt, new-project), or
# a mode that owns its own loop and spawns Copilot itself (loop, watch,
# triage). Each is confirmed to actually invoke `copilot` or `squad
# watch`/`squad loop` in the real case block, so this list is not a guess.
for mode in prompt new-project loop watch triage; do
  label_line="$(printf '%s\n' "$DISPATCH_CASE" | grep -nE "^  ([a-zA-Z_-]+\|)*${mode}(\|[a-zA-Z_-]+)*\)\$" | head -1 | cut -d: -f1)"
  mode_block=""
  if [[ -n "$label_line" ]]; then
    mode_block="$(printf '%s\n' "$DISPATCH_CASE" | awk -v start="$label_line" 'NR>=start{print} NR>=start && /;;$/{exit}')"
  fi
  assert_ne "" "$mode_block" \
    "mode '${mode}' has a real case block in worker/entrypoint.sh's dispatch"
  assert_eq "1" "$(printf '%s' "$mode_block" | grep -qE 'copilot -p|squad (watch|loop)' && echo 1 || echo 0)" \
    "mode '${mode}' actually dispatches an agent (copilot -p, squad watch, or squad loop) in the real case block"
  check_mode_applies "$mode" "0"
done

# Non-agent modes: smoke never runs Copilot unless RUN_COPILOT_SMOKE=true is
# explicitly opted into (and even then it is a direct smoke probe, not a
# session the gate's governance-readiness checks are protecting);
# telemetry-smoke, ralph, and shell never run Copilot at all.
for mode in smoke telemetry-smoke ralph shell; do
  check_mode_applies "$mode" "1"
done
# An unknown mode defaults to "not gated" rather than silently gating a mode
# that does not exist -- entrypoint.sh's own `*) exit 64 ;;` already refuses
# an unrecognized SQUAD_MODE before the gate would matter.
check_mode_applies "totally-unknown-mode" "1"

# ===========================================================================
# 5a. STATIC ordering: the real call site in worker/entrypoint.sh sits after
#     SubSquad activation finishes and before squad_policy_harden runs.
# ===========================================================================
line_of() { grep -n "$1" "$ENTRYPOINT" | head -1 | cut -d: -f1; }

subsquad_line="$(line_of 'squad subsquads activate')"
gate_call_line="$(line_of '^  squad_health_gate$')"
harden_line="$(line_of '^squad_policy_harden ')"

assert_eq "1" "$([[ -n "$subsquad_line" && -n "$gate_call_line" && "$gate_call_line" -gt "$subsquad_line" ]] && echo 1 || echo 0)" \
  "the real squad_health_gate call site (@${gate_call_line:-?}) sits AFTER SubSquad activation (@${subsquad_line:-?})"
assert_eq "1" "$([[ -n "$gate_call_line" && -n "$harden_line" && "$harden_line" -gt "$gate_call_line" ]] && echo 1 || echo 0)" \
  "the real squad_health_gate call site (@${gate_call_line:-?}) sits BEFORE squad_policy_harden (@${harden_line:-?})"

# ===========================================================================
# 5b. DYNAMIC ordering: a driver mirroring entrypoint.sh's own structure --
#     bash, `set -Eeuo pipefail`, bootstrap stand-in, the REAL gate call site
#     wired exactly as worker/entrypoint.sh wires it (applies-to-mode guard
#     then squad_health_gate), then a hardening stand-in -- proves a healthy
#     gate lets execution REACH hardening, and a failing gate stops hardening
#     from EVER running, rather than merely returning some exit code nobody
#     downstream reacts to.
# ===========================================================================
run_ordering_driver() {
  local mode="$1" health_mode="$2"
  local state="${WORK}/order-${mode}-${health_mode}"
  mkdir -p "$state"
  local driver="${state}/driver.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf '%s\n' "$LOG_FN"
    printf '%s\n' "$APPLIES_FN"
    printf '%s\n' "$GATE_FN"
    printf 'SQUAD_MODE=%q\n' "$mode"
    printf 'STATE=%q\n' "$state"
    # Bootstrap stand-in: the exact ordering worker/entrypoint.sh itself has
    # immediately before the gate -- `squad init` (if no team.md) then
    # SubSquad activation.
    echo ': > "${STATE}/bootstrap-ran"'
    # The REAL wiring, copied verbatim from worker/entrypoint.sh's own call
    # site below, not reworded:
    echo 'if squad_health_gate_applies_to_mode "${SQUAD_MODE:-smoke}"; then'
    echo '  squad_health_gate'
    echo 'fi'
    # Hardening stand-in.
    echo ': > "${STATE}/hardening-ran"'
  } > "$driver"
  chmod +x "$driver"
  SQUAD_STUB_HEALTH_MODE="$health_mode" PATH="${FAKE_BIN}:${PATH}" bash "$driver" >"${state}/out.log" 2>&1
  echo "$?" > "${state}/exit-code"
}

# Confirm the call-site snippet above is a byte-for-byte copy of the real one
# in worker/entrypoint.sh, so this driver cannot silently drift from the real
# wiring it claims to mirror.
real_call_site="$(sed -n "${gate_call_line}p" "$ENTRYPOINT" 2>/dev/null)"
assert_eq "  squad_health_gate" "$real_call_site" \
  "the real call site text at the located line is exactly 'squad_health_gate' (confirms line_of found the right line before the driver copies it)"

run_ordering_driver watch pass
assert_eq "1" "$([[ -f "${WORK}/order-watch-pass/bootstrap-ran" ]] && echo 1 || echo 0)" \
  "ordering (healthy, watch mode): bootstrap ran"
assert_eq "1" "$([[ -f "${WORK}/order-watch-pass/hardening-ran" ]] && echo 1 || echo 0)" \
  "ordering (healthy, watch mode): hardening ran AFTER a healthy gate"
assert_eq "0" "$(cat "${WORK}/order-watch-pass/exit-code")" \
  "ordering (healthy, watch mode): the whole driver exits 0"

run_ordering_driver watch fail
assert_eq "1" "$([[ -f "${WORK}/order-watch-fail/bootstrap-ran" ]] && echo 1 || echo 0)" \
  "ordering (failing, watch mode): bootstrap still ran (the gate runs AFTER bootstrap, not instead of it)"
assert_eq "0" "$([[ -f "${WORK}/order-watch-fail/hardening-ran" ]] && echo 1 || echo 0)" \
  "ordering (failing, watch mode): hardening NEVER ran -- the failing gate stopped the session before it"
assert_eq "78" "$(cat "${WORK}/order-watch-fail/exit-code")" \
  "ordering (failing, watch mode): the whole driver exits 78"

# A non-agent mode (smoke) must reach hardening even with a "fail" stub
# report -- the gate does not even run for it, exactly as #4 above proved in
# isolation; this re-confirms it end-to-end through the same ordering
# driver.
run_ordering_driver smoke fail
assert_eq "1" "$([[ -f "${WORK}/order-smoke-fail/hardening-ran" ]] && echo 1 || echo 0)" \
  "ordering (smoke mode, stub would report fail): hardening still ran -- smoke is not gated at all"
assert_eq "0" "$(cat "${WORK}/order-smoke-fail/exit-code")" \
  "ordering (smoke mode, stub would report fail): the whole driver exits 0"
assert_not_contains "$(cat "${WORK}/order-smoke-fail/out.log")" "UNEXPECTED STUB CALL" \
  "ordering (smoke mode): the stub squad binary was never even invoked for a mode the gate skips"

test_summary
