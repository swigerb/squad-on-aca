#!/usr/bin/env bash
# Issue #115: `squad watch` / `squad loop` run for the lifetime of the
# container. ACA stops a replica (revision update, restart, scale-in) by
# sending SIGTERM to PID 1. Running Squad as the FOREGROUND child of
# worker/entrypoint.sh means bash defers its own trap handling until the
# foreground job returns -- so SIGTERM never reaches Squad, and its
# documented drain (finish the in-flight turn, flush state, exit 0; see
# Squad's `reference/container-image.md` Graceful Shutdown section) never
# happens. The fix is to run Squad in the BACKGROUND and forward the signal
# explicitly.
#
# The second half is the classic bash trap/wait gotcha. When a signal arrives
# while the shell is blocked in `wait "$pid"`, bash runs the trap and the
# INTERRUPTED `wait` call then returns on its own with a synthetic 128+signo
# status -- NOT the child's real exit status, because the child has not
# necessarily exited yet. A single `wait` therefore reports "done" the instant
# the signal lands, while Squad is still mid-drain. The fix: the REAL wait for
# the child's actual exit status happens INSIDE the trap handler itself (this
# is the "wait a second time" the gotcha calls for), so the handler does not
# return until the child has actually finished draining. Only once that
# second `wait` resolves does execution continue past the interrupted outer
# `wait` below, and the real exit status (captured inside the handler) is
# what this function returns -- never the synthetic 128+signo one.
#
# Factored into its own library (rather than left inline in entrypoint.sh) so
# worker/tests/test_signal_forwarding.sh can source these REAL functions
# directly, the same way test_proc_isolation_probe.sh sources
# worker/lib/proc-isolation-probe.sh -- a mutation to the real logic breaks
# the matching assertion.
SQUAD_FOREGROUND_CHILD_PID=""
SQUAD_FOREGROUND_CHILD_DONE=0
SQUAD_FOREGROUND_CHILD_RC=0
# The child's real exit status from the last squad_run_foreground_with_signal_
# forwarding call, whether or not the call returned it.
SQUAD_FOREGROUND_RC=0
squad_forward_signal_to_child() {
  local sig="$1"
  if [[ -n "$SQUAD_FOREGROUND_CHILD_PID" ]]; then
    log "Received ${sig}; forwarding to Squad (pid ${SQUAD_FOREGROUND_CHILD_PID}) to drain."
    kill -s "$sig" "$SQUAD_FOREGROUND_CHILD_PID" 2>/dev/null || true
    # This IS the "wait a second time" the trap/wait gotcha requires: block
    # here, inside the handler, until the child has actually exited, and
    # capture its REAL exit status -- not the synthetic 128+signo one the
    # interrupted outer `wait` below would otherwise report.
    SQUAD_FOREGROUND_CHILD_RC=0
    wait "$SQUAD_FOREGROUND_CHILD_PID" 2>/dev/null || SQUAD_FOREGROUND_CHILD_RC=$?
    SQUAD_FOREGROUND_CHILD_DONE=1
  fi
}


# Optional: when SQUAD_FOREGROUND_STOP_FILE names a file, ask the child to stop
# as soon as that file appears. Used for a pinned-model launch failure (see
# worker/lib/squad-policy.sh, "Pinned-model failure lifecycle"): Squad keeps
# polling after its agent command fails, so something outside it must end the
# run. Runs as a background subshell owned by squad_run_foreground_with_signal_
# forwarding and only ever signals the pid it was handed -- TERM first, so Squad
# drains the way an ACA stop does (it kills and waits for its own in-flight
# agent), then KILL if the pid is still alive after
# SQUAD_FOREGROUND_STOP_GRACE_SECONDS (default 120). That KILL also goes to the
# child's own process group when the caller started it in one (third argument
# 1), so a wedged Squad cannot leave its agent behind. No process is found or
# signalled by name.
squad_foreground_stop_watcher() {
  local target="$1" stop_file="$2" own_group="${3:-0}"
  local grace="${SQUAD_FOREGROUND_STOP_GRACE_SECONDS:-120}"
  local poll="${SQUAD_FOREGROUND_STOP_POLL_SECONDS:-1}"
  local nap="" waited=0
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=120
  trap '[[ -n "$nap" ]] && kill "$nap" 2>/dev/null; exit 0' TERM
  while kill -0 "$target" 2>/dev/null; do
    if [[ -e "$stop_file" ]]; then
      log "Stop file ${stop_file} appeared; sending TERM to Squad (pid ${target}) and stopping its iterations."
      kill -s TERM "$target" 2>/dev/null || true
      while [[ "$waited" -lt "$grace" ]] && kill -0 "$target" 2>/dev/null; do
        sleep 1 &
        nap=$!
        wait "$nap" 2>/dev/null || true
        nap=""
        waited=$((waited + 1))
      done
      if kill -0 "$target" 2>/dev/null; then
        if [[ "$own_group" == 1 ]]; then
          log "Squad (pid ${target}) did not stop within ${grace}s of TERM; sending KILL to it and to its own process group."
          kill -s KILL -- "-${target}" 2>/dev/null || true
        else
          log "Squad (pid ${target}) did not stop within ${grace}s of TERM; sending KILL to that pid."
        fi
        kill -s KILL "$target" 2>/dev/null || true
      fi
      return 0
    fi
    sleep "$poll" &
    nap=$!
    wait "$nap" 2>/dev/null || true
    nap=""
  done
  return 0
}

# Leftover members of the child's own process group, killed after the child has
# gone (see squad_run_foreground_with_signal_forwarding). Only ever the group
# whose id is the pid this function started: never a name, never a pattern.
squad_foreground_sweep_group() {
  local pgid="$1"
  if kill -s KILL -- "-${pgid}" 2>/dev/null; then
    log "Squad (pid ${pgid}) had already exited but its process group still held processes; sent KILL to that group so nothing is left running."
  fi
}

# Run "$@" as a backgrounded child with SIGTERM/SIGINT forwarded to it, and
# return its real exit status. Resets its bookkeeping on every call and clears
# the TERM/INT traps before returning, so it never clobbers an EXIT trap a
# caller may have set independently (e.g. `squad_lease_finish` /
# `squad_hub_release_ambient` in worker/entrypoint.sh), and so a signal
# arriving after this function returns falls back to the shell's normal
# (default) disposition rather than an installed-but-stale handler.
#
# With SQUAD_FOREGROUND_STOP_FILE set (a pinned-model session) the child is
# started in a process group of its own (pgid == its pid, the same
# `set -m; ...; set +m` idiom squad-deadline.sh uses). A forwarded TERM/INT is
# still sent to the child's pid alone, so Squad drains and stops its own agent
# as before. What the group adds is the cleanup: if the session ended abnormally
# (a stop was requested, a signal was forwarded, or the child exited non-zero)
# anything still in that group once the child is gone -- an agent a killed Squad
# could not stop -- is sent KILL, so a pinned launch failure or a cancel leaves
# no process behind. A clean exit 0 sweeps nothing. Without the stop file
# nothing about the child, its group or its exit handling changes.
squad_run_foreground_with_signal_forwarding() {
  SQUAD_FOREGROUND_CHILD_PID=""
  SQUAD_FOREGROUND_CHILD_DONE=0
  SQUAD_FOREGROUND_CHILD_RC=0

  trap 'squad_forward_signal_to_child TERM' TERM
  trap 'squad_forward_signal_to_child INT' INT

  local own_group=0 monitor_was_on=0
  if [[ -n "${SQUAD_FOREGROUND_STOP_FILE:-}" ]]; then
    own_group=1
    case "$-" in *m*) monitor_was_on=1 ;; esac
    set -m
    # Job control would otherwise leave the child's stdin attached; a plain
    # background job reads /dev/null, so keep that.
    "$@" </dev/null &
    SQUAD_FOREGROUND_CHILD_PID=$!
    if [[ "$monitor_was_on" -eq 0 ]]; then set +m; fi
  else
    "$@" &
    SQUAD_FOREGROUND_CHILD_PID=$!
  fi

  # Optional stop file (see squad_foreground_stop_watcher). Its pid is owned by
  # this function: started after the child, stopped and reaped before returning.
  local watcher_pid=""
  if [[ -n "${SQUAD_FOREGROUND_STOP_FILE:-}" ]]; then
    squad_foreground_stop_watcher "$SQUAD_FOREGROUND_CHILD_PID" "$SQUAD_FOREGROUND_STOP_FILE" "$own_group" &
    watcher_pid=$!
  fi

  local outer_rc=0
  wait "$SQUAD_FOREGROUND_CHILD_PID" || outer_rc=$?

  if [[ -n "$watcher_pid" ]]; then
    kill -s TERM "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  fi

  trap - TERM INT

  # A handler that ran (because a signal arrived) already did the real wait
  # and holds the child's true exit status -- use that instead of the
  # synthetic 128+signo status the interrupted outer `wait` above returned.
  SQUAD_FOREGROUND_RC="$outer_rc"
  if [[ "$SQUAD_FOREGROUND_CHILD_DONE" -eq 1 ]]; then
    SQUAD_FOREGROUND_RC="$SQUAD_FOREGROUND_CHILD_RC"
  fi

  if [[ "$own_group" -eq 1 ]]; then
    if [[ "$SQUAD_FOREGROUND_RC" -ne 0 || "$SQUAD_FOREGROUND_CHILD_DONE" -eq 1 || -e "$SQUAD_FOREGROUND_STOP_FILE" ]]; then
      squad_foreground_sweep_group "$SQUAD_FOREGROUND_CHILD_PID"
    fi
  fi

  # With a stop file the caller asked for a stop and has to look at WHY the
  # child ended before deciding what the session's status is, so the status is
  # left in SQUAD_FOREGROUND_RC and the call itself succeeds. Returning it
  # would need `fn || rc=$?` at the call site, and that runs the whole function
  # -- including the child it backgrounds -- with errexit switched off.
  if [[ -n "${SQUAD_FOREGROUND_STOP_FILE:-}" ]]; then
    return 0
  fi
  return "$SQUAD_FOREGROUND_RC"
}