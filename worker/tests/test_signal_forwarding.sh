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

# The stub's own pid and process group (Linux: /proc/<pid>/stat; Git Bash:
# /proc/<pid>/pgid). Empty when the host exposes neither.
proc_pgid() {
  local s
  if [[ -r "/proc/$1/pgid" ]]; then
    cat "/proc/$1/pgid"
  elif [[ -r "/proc/$1/stat" ]]; then
    s="$(cat "/proc/$1/stat")"
    s="${s##*) }"
    set -- $s
    printf '%s\n' "$3"
  fi
}
printf '%s\n' "$$" > "${SQUAD_STUB_STATE_DIR}/stub.pid"
proc_pgid "$$" > "${SQUAD_STUB_STATE_DIR}/stub.pgid"

# A descendant that outlives the stub, in the stub's process group: what a
# killed Squad leaves behind when its agent could not be stopped.
if [[ -n "${SQUAD_STUB_ORPHAN:-}" ]]; then
  sleep 300 &
  printf '%s\n' "$!" > "${SQUAD_STUB_STATE_DIR}/orphan.pid"
fi

# `started` is written only once the stub is ready for the signal the test
# sends next: a TERM that lands before the traps below are installed would kill
# the stub with its default disposition.
if [[ "${SQUAD_STUB_MODE:-drain}" == "immediate" ]]; then
  : > "${SQUAD_STUB_STATE_DIR}/started"
  exit "${SQUAD_STUB_EXIT_CODE:-0}"
fi

# ignore-term: a Squad that never drains -- only KILL ends it.
if [[ "${SQUAD_STUB_MODE:-drain}" == "ignore-term" ]]; then
  trap '' TERM
  : > "${SQUAD_STUB_STATE_DIR}/started"
  while true; do sleep 0.1; done
fi

term_received=0
on_signal() {
  term_received=1
  : > "${SQUAD_STUB_STATE_DIR}/term-received"
}
trap 'on_signal' TERM
trap 'on_signal' INT
: > "${SQUAD_STUB_STATE_DIR}/started"

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

# =============================================================================
# 6. The optional stop file (SQUAD_FOREGROUND_STOP_FILE), used when a pinned
#    model fails to launch: real Squad keeps polling after its agent command
#    exits non-zero, so the supervisor watches for the file and stops Squad.
#    The watcher only ever signals the pid it supervises (TERM first, so Squad
#    drains; KILL of that same pid after a grace period), never a process found
#    by name -- a bystander process in the same shell proves it. The supervised
#    status is left in SQUAD_FOREGROUND_RC and the call itself returns 0 (a
#    plain call under `set -e`, which is how the entrypoint makes it, so errexit
#    stays on for the child).
# =============================================================================
STOP_DRIVER="${WORK}/stop-driver.sh"
cat > "$STOP_DRIVER" <<'STOP_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '[driver] %s\n' "$*"; }
# shellcheck source=/dev/null
source "${LIB_FILE:?}"

if [[ -r "/proc/$$/pgid" ]]; then
  cat "/proc/$$/pgid" > "${STATE_DIR}/driver.pgid"
elif [[ -r "/proc/$$/stat" ]]; then
  s="$(cat "/proc/$$/stat")"; s="${s##*) }"; set -- $s; printf '%s\n' "$3" > "${STATE_DIR}/driver.pgid"
fi
if [[ -n "${NO_STOP_FILE:-}" ]]; then unset SQUAD_FOREGROUND_STOP_FILE; fi

sleep 60 &
bystander=$!
printf '%s\n' "$bystander" > "${STATE_DIR}/bystander.pid"
stopper=""
if [[ -n "${STOP_AFTER:-}" ]]; then
  ( sleep "$STOP_AFTER"; : > "$SQUAD_FOREGROUND_STOP_FILE" ) &
  stopper=$!
fi
printf '%s\n' "$stopper" > "${STATE_DIR}/stopper.pid"

squad_run_foreground_with_signal_forwarding squad
echo "$SQUAD_FOREGROUND_RC" > "${STATE_DIR}/rc"
jobs -p > "${STATE_DIR}/jobs"
if kill -0 "$bystander" 2>/dev/null; then echo alive > "${STATE_DIR}/bystander.state"; else echo dead > "${STATE_DIR}/bystander.state"; fi
kill "$bystander" 2>/dev/null || true
STOP_EOF
chmod +x "$STOP_DRIVER"

# run_stop_case <name> [NAME=value ...] -> STOP_RC, STOP_STATE
run_stop_case() {
  local name="$1"
  shift
  STOP_STATE="${WORK}/stop-${name}"
  mkdir -p "$STOP_STATE"
  STOP_RC=0
  env LIB_FILE="$LIB_FILE" STATE_DIR="$STOP_STATE" SQUAD_STUB_STATE_DIR="$STOP_STATE" \
    PATH="${FAKE_BIN}:${PATH}" SQUAD_FOREGROUND_STOP_FILE="${STOP_STATE}/stop" \
    SQUAD_FOREGROUND_STOP_POLL_SECONDS=0.1 "$@" \
    bash "$STOP_DRIVER" > "${STOP_STATE}/driver.out" 2>&1 || STOP_RC=$?
}
# Anything the driver left running other than its two deliberate helpers.
stop_leftover_jobs() {
  local jobs_file="${STOP_STATE}/jobs" keep1 keep2
  keep1="$(head -n1 "${STOP_STATE}/bystander.pid" 2>/dev/null)"
  keep2="$(head -n1 "${STOP_STATE}/stopper.pid" 2>/dev/null)"
  grep -vxE "${keep1:-none}|${keep2:-none}" "$jobs_file" 2>/dev/null | tr '\n' ' '
}

# The file appears while Squad runs: Squad gets the TERM and drains.
run_stop_case appears STOP_AFTER=0.4 SQUAD_STUB_DRAIN_TICKS=3 SQUAD_STUB_EXIT_CODE=0
assert_eq "0" "$STOP_RC" "[stop file] the supervisor call itself returns 0 (the driver, under errexit, ran on)"
assert_eq "0" "$(cat "${STOP_STATE}/rc" 2>/dev/null)" "[stop file] SQUAD_FOREGROUND_RC holds the stopped Squad's own exit status"
assert_eq "1" "$([[ -e "${STOP_STATE}/term-received" ]] && echo 1 || echo 0)" "[stop file] Squad received a TERM when the file appeared"
assert_eq "1" "$([[ -e "${STOP_STATE}/drained" ]] && echo 1 || echo 0)" "[stop file] ... and was given the time to drain, not killed"
assert_contains "$(cat "${STOP_STATE}/driver.out")" "Stop file ${STOP_STATE}/stop appeared" "[stop file] the supervisor logged why it stopped Squad"
assert_eq "alive" "$(cat "${STOP_STATE}/bystander.state" 2>/dev/null)" "[stop file] an unrelated process in the same shell was NOT signalled: only the supervised pid is"
assert_eq "" "$(stop_leftover_jobs)" "[stop file] the watcher was stopped and reaped before the call returned"

# Squad's own failing status survives a stop (it is the caller's to read).
run_stop_case appears-rc7 STOP_AFTER=0.4 SQUAD_STUB_DRAIN_TICKS=3 SQUAD_STUB_EXIT_CODE=7
assert_eq "0" "$STOP_RC" "[stop file, rc 7] the call itself still returns 0"
assert_eq "7" "$(cat "${STOP_STATE}/rc" 2>/dev/null)" "[stop file, rc 7] ... and SQUAD_FOREGROUND_RC is Squad's real 7, not a synthetic 143"

# The file never appears: nothing is signalled, the watcher is cleaned up, and
# Squad's status is still there to read.
run_stop_case never SQUAD_STUB_MODE=immediate SQUAD_STUB_EXIT_CODE=5
assert_eq "0" "$STOP_RC" "[stop file never created] the call returns 0"
assert_eq "5" "$(cat "${STOP_STATE}/rc" 2>/dev/null)" "[stop file never created] SQUAD_FOREGROUND_RC is Squad's real exit status"
assert_eq "0" "$([[ -e "${STOP_STATE}/term-received" ]] && echo 1 || echo 0)" "[stop file never created] nothing signalled Squad"
assert_eq "" "$(stop_leftover_jobs)" "[stop file never created] the watcher does not outlive the call"

# A Squad that ignores TERM is KILLed after the grace period -- that pid only.
run_stop_case ignores-term STOP_AFTER=0.3 SQUAD_STUB_MODE=ignore-term SQUAD_FOREGROUND_STOP_GRACE_SECONDS=1
assert_eq "0" "$STOP_RC" "[stop file, TERM ignored] the call returns 0 once Squad is gone"
assert_eq "137" "$(cat "${STOP_STATE}/rc" 2>/dev/null)" "[stop file, TERM ignored] Squad was KILLed (137) after the grace period"
assert_contains "$(cat "${STOP_STATE}/driver.out")" "did not stop within 1s of TERM" "[stop file, TERM ignored] the supervisor logged the escalation"
assert_eq "alive" "$(cat "${STOP_STATE}/bystander.state" 2>/dev/null)" "[stop file, TERM ignored] the unrelated process survived the KILL too"
assert_eq "" "$(stop_leftover_jobs)" "[stop file, TERM ignored] the watcher was reaped"

# =============================================================================
# 7. The child's own process group, and what is left behind (real shell, real
#    kill, real process ids -- nothing is found or signalled by name).
#
# With a stop file (a pinned-model session) Squad runs in a process group of its
# own. The stub leaves a descendant behind (`sleep 300`, SQUAD_STUB_ORPHAN),
# standing for the agent a Squad that was killed or wedged could not stop. After
# an ABNORMAL end -- Squad exited non-zero by itself, a stop was requested, or a
# signal was forwarded -- the supervisor sends KILL to that one group, so the
# session leaves no process behind. A clean exit 0 sweeps nothing, and a session
# with no stop file is exactly what it was. The driver's other children (the
# bystander `sleep 60`) are in the driver's own group and are never touched.
# =============================================================================
echo "-- the child's own process group and the cleanup after an abnormal end --"

pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }
read_state() { head -n1 "${STOP_STATE}/$1" 2>/dev/null | tr -d '[:space:]'; }
reap_orphan() {
  local o
  o="$(read_state orphan.pid)"
  if pid_alive "$o"; then kill -KILL "$o" 2>/dev/null; fi
}
orphan_state() {
  if pid_alive "$(read_state orphan.pid)"; then echo alive; else echo dead; fi
}
bystander_state() { cat "${STOP_STATE}/bystander.state" 2>/dev/null; }

# Squad exits 0 by itself and leaves a descendant: the normal path sweeps nothing.
run_stop_case group-clean SQUAD_STUB_ORPHAN=1 SQUAD_STUB_MODE=immediate SQUAD_STUB_EXIT_CODE=0
assert_eq "0" "$STOP_RC" "[group, clean exit] the call returns 0"
assert_eq "0" "$(read_state rc)" "[group, clean exit] SQUAD_FOREGROUND_RC is Squad's 0"
assert_eq "alive" "$(orphan_state)" "[group, clean exit] a clean exit 0 sweeps nothing: the descendant is untouched, as before"
assert_not_contains "$(cat "${STOP_STATE}/driver.out")" "process group still held" "[group, clean exit] ... and no sweep is logged"
reap_orphan

# Squad exits non-zero by itself.
run_stop_case group-rc3 SQUAD_STUB_ORPHAN=1 SQUAD_STUB_MODE=immediate SQUAD_STUB_EXIT_CODE=3
assert_eq "0" "$STOP_RC" "[group, Squad exits 3] the call returns 0"
assert_eq "3" "$(read_state rc)" "[group, Squad exits 3] SQUAD_FOREGROUND_RC is Squad's real 3 (the sweep never changes the status)"
assert_eq "dead" "$(orphan_state)" "[group, Squad exits 3] the descendant it left behind was killed"
assert_contains "$(cat "${STOP_STATE}/driver.out")" "process group still held processes" "[group, Squad exits 3] the supervisor logged the sweep"
assert_eq "alive" "$(bystander_state)" "[group, Squad exits 3] the driver's own other child (a different group) was not signalled"
reap_orphan
STUB_PID="$(read_state stub.pid)"; STUB_PGID="$(read_state stub.pgid)"; DRIVER_PGID="$(read_state driver.pgid)"
if [[ -n "$STUB_PGID" && -n "$DRIVER_PGID" ]]; then
  assert_eq "$STUB_PID" "$STUB_PGID" "[group] with a stop file Squad leads a process group of its own (pgid == pid)"
  assert_ne "$DRIVER_PGID" "$STUB_PGID" "[group] ... which is not the driver's group"
else
  echo "SKIP: [group] pgid assertions skipped -- this host exposes neither /proc/<pid>/pgid nor /proc/<pid>/stat"
fi

# The stop file appears; Squad drains and exits 0, leaving a descendant.
run_stop_case group-stop SQUAD_STUB_ORPHAN=1 STOP_AFTER=0.4 SQUAD_STUB_DRAIN_TICKS=3 SQUAD_STUB_EXIT_CODE=0
assert_eq "0" "$(read_state rc)" "[group, stop requested] Squad drained and exited 0"
assert_eq "1" "$([[ -e "${STOP_STATE}/drained" ]] && echo 1 || echo 0)" "[group, stop requested] ... it was TERMed and drained, not killed"
assert_eq "dead" "$(orphan_state)" "[group, stop requested] what it left behind was killed after the stop"
assert_eq "alive" "$(bystander_state)" "[group, stop requested] the unrelated process was not signalled"
reap_orphan

# A Squad that ignores TERM: after the grace period the whole group is KILLed.
run_stop_case group-wedged SQUAD_STUB_ORPHAN=1 STOP_AFTER=0.3 SQUAD_STUB_MODE=ignore-term SQUAD_FOREGROUND_STOP_GRACE_SECONDS=1
assert_eq "137" "$(read_state rc)" "[group, TERM ignored] Squad was KILLed (137)"
assert_eq "dead" "$(orphan_state)" "[group, TERM ignored] its descendant did not survive the group KILL"
assert_contains "$(cat "${STOP_STATE}/driver.out")" "to its own process group" "[group, TERM ignored] the supervisor logged that the KILL covered the group"
assert_eq "alive" "$(bystander_state)" "[group, TERM ignored] the unrelated process survived"
reap_orphan

# Cancel: the driver itself is sent TERM (an ACA stop) while Squad runs.
# run_cancel_case <name> [NAME=value ...]
run_cancel_case() {
  local name="$1"
  shift
  STOP_STATE="${WORK}/stop-${name}"
  mkdir -p "$STOP_STATE"
  env LIB_FILE="$LIB_FILE" STATE_DIR="$STOP_STATE" SQUAD_STUB_STATE_DIR="$STOP_STATE" \
    PATH="${FAKE_BIN}:${PATH}" SQUAD_FOREGROUND_STOP_FILE="${STOP_STATE}/stop" \
    SQUAD_FOREGROUND_STOP_POLL_SECONDS=0.1 SQUAD_STUB_ORPHAN=1 SQUAD_STUB_DRAIN_TICKS=3 "$@" \
    bash "$STOP_DRIVER" > "${STOP_STATE}/driver.out" 2>&1 &
  local dpid=$!
  BACKGROUND_PIDS+=("$dpid")
  wait_for_path "${STOP_STATE}/orphan.pid" 50 || true
  wait_for_path "${STOP_STATE}/started" 50 || true
  CANCEL_RC=0
  kill -s TERM "$dpid" 2>/dev/null
  wait "$dpid" 2>/dev/null || CANCEL_RC=$?
  BACKGROUND_PIDS=("${BACKGROUND_PIDS[@]/$dpid/}")
  BACKGROUND_PIDS+=("$(read_state orphan.pid)")
}

run_cancel_case cancel-pinned SQUAD_STUB_EXIT_CODE=0
assert_eq "1" "$([[ -e "${STOP_STATE}/term-received" ]] && echo 1 || echo 0)" "[cancel, pinned] the TERM sent to the driver reached Squad"
assert_eq "1" "$([[ -e "${STOP_STATE}/drained" ]] && echo 1 || echo 0)" "[cancel, pinned] ... and Squad was allowed to drain"
assert_eq "0" "$(read_state rc)" "[cancel, pinned] the supervised status is Squad's real exit status, not 143"
assert_eq "0" "$CANCEL_RC" "[cancel, pinned] the driver ran on to a clean exit"
assert_eq "dead" "$(orphan_state)" "[cancel, pinned] nothing the session started is left running"
assert_eq "alive" "$(bystander_state)" "[cancel, pinned] the unrelated process was not signalled"
reap_orphan

# Control: the same cancel without a stop file (an unpinned session) behaves as
# it always did -- Squad shares the driver's group and nothing is swept.
run_cancel_case cancel-unpinned SQUAD_STUB_EXIT_CODE=0 NO_STOP_FILE=1
assert_eq "1" "$([[ -e "${STOP_STATE}/drained" ]] && echo 1 || echo 0)" "[cancel, unpinned] Squad drained on the forwarded TERM, exactly as before"
assert_eq "alive" "$(orphan_state)" "[cancel, unpinned] control: with no stop file nothing is swept (the old behaviour is untouched)"
STUB_PGID="$(read_state stub.pgid)"; DRIVER_PGID="$(read_state driver.pgid)"
if [[ -n "$STUB_PGID" && -n "$DRIVER_PGID" ]]; then
  assert_eq "$DRIVER_PGID" "$STUB_PGID" "[cancel, unpinned] control: Squad stays in the driver's own process group"
fi
reap_orphan
# Without a stop file the supervisor is exactly what it was: it RETURNS the
# status (the plain-call driver above would abort under errexit on a non-zero one).
UNSET_RC="$(
  SQUAD_STUB_STATE_DIR="$NORMAL_STATE" SQUAD_STUB_MODE="immediate" SQUAD_STUB_EXIT_CODE="6" \
    PATH="${FAKE_BIN}:${PATH}" \
    bash -c "unset SQUAD_FOREGROUND_STOP_FILE; log() { :; }; source '${LIB_FILE}'; squad_run_foreground_with_signal_forwarding squad || rc=\$?; echo \"\$rc \$SQUAD_FOREGROUND_RC\""
)"
assert_eq "6 6" "$UNSET_RC" "no stop file: the call returns Squad's status, and SQUAD_FOREGROUND_RC agrees"

test_summary
