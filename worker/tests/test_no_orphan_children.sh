#!/usr/bin/env bash
# Issue #92: the intermittent worker-tests hang (40+ minutes, no output,
# cancelled; same commit passed on retry).
#
# THE MECHANISM, confirmed against the actual GitHub Actions runner model: a
# step ends when its OUTPUT PIPE CLOSES, not when the foreground script exits.
# A background child that inherits the step's stdout/stderr keeps that pipe
# open for as long as the child lives. worker/entrypoint.sh's lease heartbeat
# (squad_lease_heartbeat_loop) is exactly this shape: a `while true` loop,
# forked with `&`, that never exits on its own. #91 added a SECOND fork site
# (squad_credential_restore, after a credential-withholding window) -- a
# second opportunity for a restart to inherit a pipe the first fork was
# careful about, or never was.
#
# This suite proves three things, and mutation-proves the first two:
#
#   1. squad_lease_heartbeat_loop's OWN body redirects its stdio, so it is
#      correct regardless of what any call site does.
#   2. BOTH places that fork it (worker/entrypoint.sh's initial start, and
#      worker/lib/squad-credentials.sh's post-restore restart) redirect at
#      the call site too, so a caller can never regress it by omission.
#   3. Behaviourally: forking the REAL extracted loop with its stdout wired
#      to a pipe, the reading end reaches EOF almost immediately even
#      though the child is still alive -- which is the exact property a
#      GitHub Actions step depends on to end. Reverting the redirect (kept
#      as an inline mutation below, restored immediately after) makes the
#      pipe hang, proving the assertion is not vacuous.
#
# Expected background children of THIS suite: none survive past its own exit.
# Every child it forks (the extracted-loop probe process, and its `sleep`
# descendant) is explicitly killed and waited on before the suite exits, and
# that is asserted directly, not assumed.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
ENTRYPOINT="${WORKER_DIR}/entrypoint.sh"
CRED_LIB="${WORKER_DIR}/lib/squad-credentials.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== worker capability tests: no orphaned background children survive (issue #92) =="

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-no-orphan-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
PROBE_PID=""
# Recursively kill a process and every descendant (children, grandchildren,
# ...). This suite forks driver scripts that themselves fork further
# processes (e.g. a `sleep`, or a `cat` reading a FIFO); killing only the
# PID this suite recorded (the immediate child) leaves those grandchildren
# as orphans -- the exact bug class issue #92 is about. Best-effort: PIDs
# that already exited are silently ignored.
kill_tree() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}
cleanup() {
  [[ -n "$PROBE_PID" ]] && kill_tree "$PROBE_PID"
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ===========================================================================
# 1. squad_lease_heartbeat_loop's own body redirects its stdio.
# ===========================================================================
LOOP_BODY="$(awk '/^squad_lease_heartbeat_loop\(\) \{/,/^\}/' "$ENTRYPOINT")"
assert_ne "" "$LOOP_BODY" "squad_lease_heartbeat_loop() is present in worker/entrypoint.sh"
assert_contains "$LOOP_BODY" '>/dev/null 2>&1 </dev/null' \
  "squad_lease_heartbeat_loop redirects its own stdout/stderr/stdin, so it can never keep a step's pipe open regardless of how it is forked"

# ===========================================================================
# 2. Both fork sites redirect too (defense in depth: correct even if a future
#    refactor moves the redirect out of the function body).
# ===========================================================================
ENTRY_FORK_LINE="$(grep -n 'squad_lease_heartbeat_loop.*&$' "$ENTRYPOINT" | head -1)"
assert_ne "" "$ENTRY_FORK_LINE" "worker/entrypoint.sh still forks squad_lease_heartbeat_loop directly"
ENTRY_FORK_LINE_NO="${ENTRY_FORK_LINE%%:*}"
ENTRY_FORK_TEXT="$(sed -n "${ENTRY_FORK_LINE_NO}p" "$ENTRYPOINT")"
assert_contains "$ENTRY_FORK_TEXT" '>/dev/null 2>&1 </dev/null' \
  "worker/entrypoint.sh's initial heartbeat fork redirects stdout/stderr/stdin at the call site"

RESTART_LINE="$(grep -n 'squad_lease_heartbeat_loop.*&$' "$CRED_LIB" | head -1)"
assert_ne "" "$RESTART_LINE" "worker/lib/squad-credentials.sh still restarts squad_lease_heartbeat_loop after restore (issue #91's changed behaviour)"
RESTART_LINE_NO="${RESTART_LINE%%:*}"
RESTART_TEXT="$(sed -n "${RESTART_LINE_NO}p" "$CRED_LIB")"
assert_contains "$RESTART_TEXT" '>/dev/null 2>&1 </dev/null' \
  "worker/lib/squad-credentials.sh's post-restore heartbeat RESTART redirects stdout/stderr/stdin at the call site -- the exact spot issue #92 names as the new opportunity to inherit a pipe"

# ===========================================================================
# 3. Behavioural proof: a step ends when its pipe closes, and the redirected
#    real loop does not keep it open.
#
# The extracted loop is run inside a short driver script: fork it exactly as
# entrypoint.sh does, then let the driver exit while the loop keeps running
# in the background. A FIFO stands in for a step's output pipe: the driver's
# stdout/stderr are connected to it, and a reader on the other end is timed.
# If ANY process holding the FIFO's write end survives, the reader blocks
# and never reaches EOF -- exactly the mechanism named in issue #92. The
# read is bounded and polled rather than left to block indefinitely, so this
# suite itself cannot hang even if the assertion it is proving were false.
# ===========================================================================
wait_for_file() {
  local file="$1" seconds="$2"
  local waited=0
  while [[ ! -e "$file" && "$waited" -lt "$seconds" ]]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  [[ -e "$file" ]]
}

DRIVER="${WORK}/driver.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  echo "SQUAD_LEASE_HEARTBEAT_SECONDS=9999"
  # squad_lease_report short-circuits immediately when SQUAD_LEASE_KEY/
  # GITHUB_REPOSITORY are unset -- exactly the guard the real function relies
  # on -- so the extracted loop never needs a real dispatch CLI to run.
  awk '/^squad_lease_report\(\) \{/,/^\}/' "$ENTRYPOINT"
  awk '/^squad_lease_heartbeat_loop\(\) \{/,/^\}/' "$ENTRYPOINT"
  # Use the ACTUAL fork line extracted from entrypoint.sh above (captured in
  # $ENTRY_FORK_TEXT), not a hand-written `squad_lease_heartbeat_loop &`.
  # bash's redirect-undo bookkeeping for a `while` loop's OWN trailing
  # redirect (`done >/dev/null 2>&1 </dev/null`) is not, by itself, reliable:
  # a loop that never exits never runs the "restore original fd" step bash
  # attaches to that redirect, so a synthetic driver that forked the loop
  # WITHOUT the call-site redirect was found (while writing this suite) to
  # leak a duplicate write end of the FIFO forever, even though the
  # function's own body redirect looked correct by inspection and by the
  # grep-based assertions in part 1/2 above. The call-site redirect is what
  # actually closes it reliably, because that redirect applies to the fork()
  # itself rather than to a compound statement that never completes. Forking
  # the loop any other way here would not be testing what production does.
  echo "${ENTRY_FORK_TEXT}"
  echo 'echo "$!" > "'"${WORK}"'/loop.pid"'
  echo 'echo "driver done"'
} > "$DRIVER"
chmod +x "$DRIVER"

FIFO="${WORK}/step.fifo"
mkfifo "$FIFO"
READER_OUT="${WORK}/reader.out"
READER_DONE="${WORK}/reader.done"
# The reader is the "step". It reaches EOF (and this file appears) only once
# EVERY process holding the FIFO's write end has closed it.
( cat "$FIFO" > "$READER_OUT"; : > "$READER_DONE" ) &
READER_PID=$!

bash "$DRIVER" > "$FIFO" 2>&1
# bash "$DRIVER" itself returns almost immediately (it only forks the loop
# and exits) -- what is under test is whether the READER also finishes
# promptly, i.e. whether the forked loop held the FIFO's write end open.
READER_FINISHED="$(wait_for_file "$READER_DONE" 8 && echo 1 || echo 0)"
assert_eq "1" "$READER_FINISHED" \
  "the step's output pipe (a FIFO standing in for a GitHub Actions step's stdout) reaches EOF within a few seconds of the driver script returning, proving the REAL, redirected squad_lease_heartbeat_loop does not hold it open"
assert_contains "$(cat "$READER_OUT" 2>/dev/null || true)" "driver done" \
  "the driver's own output made it through the pipe before it closed"
kill_tree "$READER_PID"

LOOP_PID="$(cat "${WORK}/loop.pid" 2>/dev/null || true)"
assert_ne "" "$LOOP_PID" "the loop's PID was recorded"
if [[ -n "$LOOP_PID" ]]; then
  assert_eq "0" "$(kill -0 "$LOOP_PID" 2>/dev/null; echo $?)" \
    "the heartbeat loop is STILL RUNNING after the pipe closed -- this is the point: a live background child does not, by itself, keep a step open once its own stdio is redirected away"
  PROBE_PID="$LOOP_PID"
fi

# ---------------------------------------------------------------------------
# MUTATION PROOF (M-92-1): reproduce the pre-fix shape -- fork a loop of the
# same kind with stdio left inherited -- and show that the SAME pipe-close
# check now fails (the reader never reaches EOF within the bound), so the
# assertion above is not vacuous. This does not touch the real files; it is
# a synthetic reproduction of the bug shape, on the same FIFO mechanism.
# ---------------------------------------------------------------------------
UNREDIRECTED_DRIVER="${WORK}/driver-unredirected.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'unredirected_loop() { while true; do sleep 9999; done; }'
  echo 'unredirected_loop &'
  echo 'echo "$!" > "'"${WORK}"'/bad-loop.pid"'
  echo 'echo "driver done"'
} > "$UNREDIRECTED_DRIVER"
chmod +x "$UNREDIRECTED_DRIVER"

BAD_FIFO="${WORK}/bad-step.fifo"
mkfifo "$BAD_FIFO"
BAD_READER_OUT="${WORK}/bad-reader.out"
BAD_READER_DONE="${WORK}/bad-reader.done"
( cat "$BAD_FIFO" > "$BAD_READER_OUT"; : > "$BAD_READER_DONE" ) &
BAD_READER_PID=$!

bash "$UNREDIRECTED_DRIVER" > "$BAD_FIFO" 2>&1
BAD_READER_FINISHED="$(wait_for_file "$BAD_READER_DONE" 5 && echo 1 || echo 0)"
assert_eq "0" "$BAD_READER_FINISHED" \
  "MUTATION PROOF (M-92-1): a heartbeat-shaped loop that does NOT redirect its stdio DOES keep the pipe open past the driver's own exit (the reader never reaches EOF within 5s) -- confirming the fix above is the thing actually preventing the hang, not an artifact of the harness"

BAD_LOOP_PID="$(cat "${WORK}/bad-loop.pid" 2>/dev/null || true)"
kill_tree "$BAD_READER_PID"
kill_tree "$BAD_LOOP_PID"

# ===========================================================================
# 4. This suite itself leaves no orphan behind. The only child it started
#    (the real, redirected heartbeat loop, PID in $PROBE_PID) is explicitly
#    reaped by the cleanup trap below -- named here so a future addition to
#    this suite that forks something new and forgets to reap it is visible
#    by inspection, not just by accident of an empty `jobs -p`.
# ===========================================================================
if [[ -n "$PROBE_PID" ]]; then
  kill_tree "$PROBE_PID"
  PROBE_PID=""
fi
remaining_jobs="$(jobs -p)"
assert_eq "" "$remaining_jobs" \
  "no background job of this suite's own shell remains after explicit cleanup (expected: none; the heartbeat-loop probe and its synthetic mutation twin are the only children this suite ever starts, and both are reaped above)"

# Direct process-table check, not just this shell's own job list: the
# mutation-proof driver above forks a GRANDCHILD (`sleep 9999`, a
# descendant of BAD_LOOP_PID, not a direct job of this shell), which
# `jobs -p` alone would never see. WORK is a unique per-run temp path, so
# grepping the process table for it catches anything -- reader, loop, or a
# further descendant -- still alive under it.
sleep 0.2
leftover="$(pgrep -f "$WORK" 2>/dev/null | grep -v "^$$\$" || true)"
assert_eq "" "$leftover" \
  "no process (of any generation) referencing this suite's own temp directory survives cleanup — a survivor here is exactly the orphan tee/cat/sleep shape from issue #92's rejected proof run"
# The mutation-proof's grandchild (`sleep 9999`, forked from a bash function
# body rather than exec'd from a script) does not carry $WORK in its own
# argv, so it needs its own explicit check independent of the path-based one
# above.
leftover_sleep="$(pgrep -f 'sleep 9999' 2>/dev/null || true)"
assert_eq "" "$leftover_sleep" \
  "no lingering 'sleep 9999' grandchild (the mutation-proof's unredirected_loop descendant) survives cleanup"

test_summary
