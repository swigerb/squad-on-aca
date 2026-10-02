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

# Run "$@" as a backgrounded child with SIGTERM/SIGINT forwarded to it, and
# return its real exit status. Resets its bookkeeping on every call and clears
# the TERM/INT traps before returning, so it never clobbers an EXIT trap a
# caller may have set independently (e.g. `squad_lease_finish` /
# `squad_hub_release_ambient` in worker/entrypoint.sh), and so a signal
# arriving after this function returns falls back to the shell's normal
# (default) disposition rather than an installed-but-stale handler.
squad_run_foreground_with_signal_forwarding() {
  SQUAD_FOREGROUND_CHILD_PID=""
  SQUAD_FOREGROUND_CHILD_DONE=0
  SQUAD_FOREGROUND_CHILD_RC=0

  trap 'squad_forward_signal_to_child TERM' TERM
  trap 'squad_forward_signal_to_child INT' INT

  "$@" &
  SQUAD_FOREGROUND_CHILD_PID=$!

  local outer_rc=0
  wait "$SQUAD_FOREGROUND_CHILD_PID" || outer_rc=$?

  trap - TERM INT

  # A handler that ran (because a signal arrived) already did the real wait
  # and holds the child's true exit status -- use that instead of the
  # synthetic 128+signo status the interrupted outer `wait` above returned.
  if [[ "$SQUAD_FOREGROUND_CHILD_DONE" -eq 1 ]]; then
    return "$SQUAD_FOREGROUND_CHILD_RC"
  fi
  return "$outer_rc"
}
