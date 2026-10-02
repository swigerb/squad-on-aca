#!/usr/bin/env bash
# Issue #115: `squad watch` / `squad loop` must receive SIGTERM/SIGINT
# directly so they can drain (finish the in-flight turn, flush state, exit 0)
# instead of being killed abruptly when ACA stops the replica.
#
# Every assertion here targets the REAL functions in
# worker/lib/squad-signal-forwarding.sh, sourced directly -- never a
# reimplementation -- so a mutation to the real trap/wait logic breaks the
# matching assertion, the same convention test_proc_isolation_probe.sh uses
# for worker/lib/proc-isolation-probe.sh.
#
# A STUB `squad` script stands in for the real CLI. It traps TERM/INT, writes
# a marker the instant it is received, "drains" for a short, FIXED, bounded
# number of ticks, writes a second marker once draining is actually done, and
# only then exits with a caller-chosen code. This suite proves, against that
# stub:
#
#   1. sending SIGTERM (and separately SIGINT) to the process running
#      worker/entrypoint.sh's new signal-forwarding wrapper results in the
#      stub CHILD actually receiving the same signal (the "term-received"
#      marker appears);
#   2. the wrapper WAITS for the child to finish draining rather than
#      reporting done the instant the signal lands -- the classic bash
#      trap/wait gotcha this issue calls out. Checked two ways: the wrapper
#      has not yet returned shortly after the signal is sent (its process is
#      still alive, and no exit-code file exists yet), and once it does
#      return, the child's "drained" marker is already on disk;
#   3. the child's REAL exit status is propagated -- not the synthetic
#      128+signo status an interrupted `wait` would report on its own;
#   4. a normal, un-signaled exit still returns the child's real exit code
#      too (regression guard against the OTHER classic mistake: calling
#      `wait` a second time unconditionally, which fails with "not a child of
#      this shell" once a non-signaled wait has already reaped the process);
#   5. the existing EXIT-trap / checkpoint shape worker/entrypoint.sh relies
#      on (a `trap ... EXIT` set before the squad invocation, a plain
#      function call made AFTER it returns) still fires exactly once each,
#      in the signaled path, with no double-run and no clobbering.
#
# Robust against a noisy Windows/Git Bash host: every synchronization wait
# below polls a marker file with a bounded timeout -- no fixed `sleep` races
# against a background process's progress. The one genuine fixed delay
# (the stub's own simulated "drain" work) is short (well under a second) and
# is the thing under test, not a synchronization point.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB_FILE="${WORKER_DIR}/lib/squad-signal-forwarding.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== squad watch/loop forwards SIGTERM/SIGINT so Squad can drain (issue #115) =="

[[ -f "$LIB_FILE" ]] || { echo "FAIL: worker/lib/squad-signal-forwarding.sh is missing"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-signal-forwarding-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}

# worker/entrypoint.sh installs TERM and INT traps through the exact same
# code path (squad_run_foreground_with_signal_forwarding is symmetric in the
# signal name), so the two only need to be proven independently to the
# extent the HOST can actually deliver each one. On this MSYS/Git-Bash host,
# `kill -s INT`/`kill -INT`/`kill -s SIGINT` sent to a background process do
# NOT reach a bash `trap ... INT` handler at all (confirmed empirically: a
# minimal `bash -c 'trap ... INT; sleep 5' &` target never saw its trap fire
# no matter which kill spelling was used) -- Cygwin/MSYS's signal emulation
# ties SIGINT to console Ctrl+C events, not to an out-of-band `kill`. That is
# a host limitation, not a property of our code, so this suite detects it and
# degrades the INT scenario to a clearly-logged skip instead of a false FAIL.
HOST_SUPPORTS_KILL_INT=0
{
  rm -f "${WORK}/int-capability-marker"
  bash -c "trap 'echo x > \"${WORK}/int-capability-marker\"' INT; sleep 5" &
  _probe_pid=$!
  sleep 0.2
  kill -s INT "$_probe_pid" 2>/dev/null
  for _ in $(seq 1 20); do
    [[ -e "${WORK}/int-capability-marker" ]] && { HOST_SUPPORTS_KILL_INT=1; break; }
    sleep 0.05
  done
  kill -KILL "$_probe_pid" 2>/dev/null
  wait "$_probe_pid" 2>/dev/null
}
if [[ "$HOST_SUPPORTS_KILL_INT" -eq 0 ]]; then
  echo "NOTE: this host cannot deliver SIGINT via kill to a bash trap at all (confirmed with a minimal probe, independent of our code) -- the INT scenario below is skipped rather than reported as a false FAIL. SIGTERM, which ACA actually sends, is fully exercised."
fi
BACKGROUND_PIDS=()
cleanup() {
  local pid
  for pid in "${BACKGROUND_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

wait_for_path() {
  # Polls for a path to appear, up to a bounded number of 0.1s ticks. No
  # fixed sleep is used as a synchronization point anywhere else below.
  local path="$1" max_ticks="${2:-50}"
  local ticks=0
  while [[ ! -e "$path" && "$ticks" -lt "$max_ticks" ]]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  [[ -e "$path" ]]
}

# --- The stub `squad` on PATH -----------------------------------------------
FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"
cat > "${FAKE_BIN}/squad" <<'STUB'
#!/usr/bin/env bash
# Stub for worker/tests/test_signal_forwarding.sh. Controlled entirely via
# env vars so the same stub covers both the signaled and non-signaled paths.
set -uo pipefail
: > "${SQUAD_STUB_STATE_DIR}/started"

if [[ "${SQUAD_STUB_MODE:-drain}" == "immediate" ]]; then
  exit "${SQUAD_STUB_EXIT_CODE:-0}"
fi

term_received=0
on_signal() {
  term_received=1
  : > "${SQUAD_STUB_STATE_DIR}/term-received"
}
trap 'on_signal' TERM
trap 'on_signal' INT

drain_ticks_remaining=-1
while true; do
  sleep 0.1
  if [[ "$term_received" -eq 1 && "$drain_ticks_remaining" -lt 0 ]]; then
    drain_ticks_remaining="${SQUAD_STUB_DRAIN_TICKS:-8}"
  fi
  if [[ "$drain_ticks_remaining" -ge 0 ]]; then
    if [[ "$drain_ticks_remaining" -eq 0 ]]; then
      : > "${SQUAD_STUB_STATE_DIR}/drained"
      exit "${SQUAD_STUB_EXIT_CODE:-0}"
    fi
    drain_ticks_remaining=$((drain_ticks_remaining - 1))
  fi
done
STUB
chmod +x "${FAKE_BIN}/squad"

# --- The driver: stands in for worker/entrypoint.sh -------------------------
# Deliberately mirrors entrypoint.sh's own shape: `set -Eeuo pipefail`, an
# EXIT trap installed BEFORE the squad invocation (standing in for
# squad_hub_release_ambient / squad_lease_finish), and a plain function call
# made AFTER squad_run_foreground_with_signal_forwarding returns (standing in
# for squad_policy_checkpoint) -- so this proves the real errexit/trap
# interaction, not a simplified stand-in for it.
DRIVER="${WORK}/driver.sh"
cat > "$DRIVER" <<DRIVER_EOF
#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '[driver] %s\n' "\$*"; }
# shellcheck source=/dev/null
source "${LIB_FILE}"

EXIT_TRAP_MARKER="\${DRIVER_STATE_DIR}/exit-trap-ran"
CHECKPOINT_MARKER="\${DRIVER_STATE_DIR}/checkpoint-ran"
EXIT_CODE_FILE="\${DRIVER_STATE_DIR}/wrapper-exit-code"

driver_checkpoint_stub() {
  printf 'x' >> "\$CHECKPOINT_MARKER"
}
driver_exit_trap_stub() {
  printf 'x' >> "\$EXIT_TRAP_MARKER"
}
trap driver_exit_trap_stub EXIT

squad_run_foreground_with_signal_forwarding squad --execute --fake-arg
rc=\$?
echo "\$rc" > "\$EXIT_CODE_FILE"
driver_checkpoint_stub
DRIVER_EOF
chmod +x "$DRIVER"

# =============================================================================
# 1. Normal (un-signaled) path: the wrapper still returns the child's real
#    exit code. Regression guard against the OTHER classic trap/wait mistake
#    -- calling `wait "$pid"` a second time UNCONDITIONALLY, which fails with
#    "not a child of this shell" once a non-signaled wait already reaped the
#    process, and would corrupt exactly this path.
# =============================================================================
NORMAL_STATE="${WORK}/normal-state"
mkdir -p "$NORMAL_STATE"
NORMAL_RC="$(
  SQUAD_STUB_STATE_DIR="$NORMAL_STATE" SQUAD_STUB_MODE="immediate" SQUAD_STUB_EXIT_CODE="5" \
    PATH="${FAKE_BIN}:${PATH}" \
    bash -c "log() { :; }; source '${LIB_FILE}'; squad_run_foreground_with_signal_forwarding squad; echo \$?"
)"
assert_eq "5" "$NORMAL_RC" \
  "normal (un-signaled) exit: the wrapper returns the child's real exit code (5), not a side effect of double-waiting an already-reaped child"

# =============================================================================
# 2-5. The signaled path, for both SIGTERM and SIGINT.
#
# driver.sh mirrors entrypoint.sh's real shape, including `set -Eeuo
# pipefail`. That means a NONZERO return from
# squad_run_foreground_with_signal_forwarding is a bare-statement failure
# under errexit: the script aborts right there -- the same `rc=$?` /
# checkpoint lines that would follow a zero return never run, and
# squad_policy_checkpoint is skipped. That is pre-existing, intentional
# behaviour (req. #2: "the existing EXIT trap and squad_policy_checkpoint
# behaviour must still fire exactly as they do now") and this suite checks
# BOTH halves of it:
#   - exit_code=0 (a clean graceful drain): rc file + checkpoint + EXIT trap
#     all fire, proving the full normal continuation path survives being
#     signaled.
#   - exit_code=7 (a draining child that still exits nonzero): errexit fires
#     immediately after, so the checkpoint is skipped -- exactly as it would
#     have been for the old bare `squad watch ...` statement -- but the EXIT
#     trap (which runs on ANY exit, including an errexit-triggered one) still
#     fires, and the driver PROCESS's own exit status (captured by `wait`,
#     not a file the aborted script never reached) is still the real child
#     code 7, never a synthetic 128+signo value.
# =============================================================================
run_signal_case() {
  local sig="$1" exit_code="$2" expect_checkpoint="$3"
  local state="${WORK}/case-${sig}-${exit_code}"
  mkdir -p "$state"

  # NOTE: deliberately NOT wrapped in a `( ... ) &` subshell -- that would
  # make `$!` the PID of the wrapping subshell, not of the `bash "$DRIVER"`
  # process the signal actually needs to reach, and `wait` on that subshell
  # PID would never observe the real driver's exit. Env-var prefixing a
  # single backgrounded command does not introduce a subshell, so `$!` below
  # is the real driver process.
  local driver_log="${state}/driver.out"
  SQUAD_STUB_STATE_DIR="$state" SQUAD_STUB_DRAIN_TICKS="8" SQUAD_STUB_EXIT_CODE="$exit_code" \
    DRIVER_STATE_DIR="$state" PATH="${FAKE_BIN}:${PATH}" \
    bash "$DRIVER" > "$driver_log" 2>&1 &
  local driver_pid=$!
  BACKGROUND_PIDS+=("$driver_pid")

  assert_eq "1" "$(wait_for_path "${state}/started" 50 && echo 1 || echo 0)" \
    "[$sig/rc=$exit_code] the stub squad child actually started"

  kill -s "$sig" "$driver_pid" 2>/dev/null

  # --- 2. The forwarded signal actually reaches the child. ------------------
  assert_eq "1" "$(wait_for_path "${state}/term-received" 50 && echo 1 || echo 0)" \
    "[$sig/rc=$exit_code] the stub child received the forwarded signal (marker exists)"

  # --- 3. The wrapper WAITS: shortly after the signal, the driver has NOT
  #     yet exited (its EXIT trap, which runs on every exit path, has not
  #     fired), and the process is still alive. The stub's drain takes ~0.8s
  #     (8 x 0.1s); checking at ~0.2s is well inside that window on any host,
  #     without being a tight race.
  sleep 0.2
  assert_eq "0" "$([[ -e "${state}/exit-trap-ran" ]] && echo 1 || echo 0)" \
    "[$sig/rc=$exit_code] the driver has NOT exited yet while the child is still draining (a naive single wait would report done -- and run the EXIT trap -- the instant the signal lands)"
  assert_eq "1" "$(kill -0 "$driver_pid" 2>/dev/null && echo 1 || echo 0)" \
    "[$sig/rc=$exit_code] the driver process (standing in for worker/entrypoint.sh) is still running while the child drains, rather than exiting immediately"

  # --- Bounded wait for the real drain to finish and the driver to exit;
  #     confirm the child's own "drained" marker is already on disk by then
  #     -- the wrapper's second, real `wait` is what unblocked everything.
  assert_eq "1" "$(wait_for_path "${state}/exit-trap-ran" 100 && echo 1 || echo 0)" \
    "[$sig/rc=$exit_code] the driver eventually exits (EXIT trap fires) once the child actually finishes draining"
  assert_eq "1" "$([[ -e "${state}/drained" ]] && echo 1 || echo 0)" \
    "[$sig/rc=$exit_code] the child's own drained marker exists by the time the driver exits"

  # --- 4. The REAL exit status is propagated -- not a synthetic 128+signo
  #     one (143 for TERM, 130 for INT). Read from the driver PROCESS's own
  #     exit status via `wait`, not a file the script would never reach
  #     writing to when errexit aborts it on a nonzero return.
  local reported_rc=0
  wait "$driver_pid" 2>/dev/null || reported_rc=$?
  BACKGROUND_PIDS=("${BACKGROUND_PIDS[@]/$driver_pid/}")
  assert_eq "$exit_code" "$reported_rc" \
    "[$sig/rc=$exit_code] the real exit status ($exit_code) is propagated, not a synthetic 128+signo value from the interrupted outer wait"

  # --- 5. The existing EXIT trap still fires exactly once, never clobbered
  #     by the new TERM/INT trap. The post-invocation checkpoint only runs
  #     when the real exit code is zero -- exactly the pre-existing errexit
  #     behaviour the old bare `squad watch ...` statement already had.
  assert_eq "1" "$(cat "${state}/exit-trap-ran" 2>/dev/null | tr -d '\n' | wc -c | tr -d ' ')" \
    "[$sig/rc=$exit_code] the pre-existing EXIT trap (standing in for squad_hub_release_ambient / squad_lease_finish) ran exactly once -- not clobbered and not skipped by the new TERM/INT trap"
  local checkpoint_count
  checkpoint_count="$(cat "${state}/checkpoint-ran" 2>/dev/null | tr -d '\n' | wc -c | tr -d ' ')"
  assert_eq "$expect_checkpoint" "$checkpoint_count" \
    "[$sig/rc=$exit_code] the post-invocation checkpoint (standing in for squad_policy_checkpoint) ran exactly ${expect_checkpoint} time(s) -- same errexit-driven behaviour as the old bare squad invocation"
}

# A clean graceful drain (exit 0): the full normal continuation -- rc
# propagation, checkpoint, and EXIT trap -- all fire.
run_signal_case TERM 0 1
if [[ "$HOST_SUPPORTS_KILL_INT" -eq 1 ]]; then
  run_signal_case INT 0 1
else
  echo "SKIP: [INT] scenario skipped -- this host cannot deliver SIGINT via kill at all (see NOTE above); squad_run_foreground_with_signal_forwarding installs the INT trap through the identical code path already proven for TERM above."
fi

# A draining child that still exits nonzero: errexit skips the checkpoint
# exactly as it would have for the old bare statement, but the EXIT trap
# still fires and the real (non-synthetic) exit code is still what the
# driver process itself exits with.
run_signal_case TERM 7 0

test_summary
