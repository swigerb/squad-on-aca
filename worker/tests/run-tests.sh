#!/usr/bin/env bash
# Runs all worker capability tests. No external test framework required.
#
# Suite exit codes:
#   0  - suite PASSED
#   77 - suite SKIPPED because a declared dependency is genuinely unavailable
#        (see lib/deps.sh). Reported in the summary; never counted as a pass.
#   *  - suite FAILED
#
# The runner exits non-zero if ANY suite failed, and also if no suite actually
# executed (empty test directory, or every suite skipped) — a run that proved
# nothing must never print a green banner.
set -uo pipefail

# SQUAD_ACA_TEST_DIR exists purely for testability: the harness self-test
# (test_run_tests.sh) points the real runner at a throwaway directory of
# synthetic suites. When it is unset the runner behaves exactly as before and
# runs the suites that live next to this script.
TEST_DIR="${SQUAD_ACA_TEST_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Issue #92 sprint 1/2/4: "a hang must fail, not idle." The observed incident
# was a single suite (`Run worker capability tests`) sitting with no output
# for 40+ minutes; the workflow's own step-level timeout (see worker-tests.yml)
# is a backstop for the WHOLE step, but it cannot say which suite hung.
# Wrapping each suite individually means a hang is caught, and named, within
# seconds of exceeding its own budget rather than the whole job's. 120s is
# generous headroom over every suite's real runtime (the slowest observed
# locally is single-digit seconds); overridable for local debugging of a
# suite that is legitimately slow.
#
# Sprint 4 (reviewer rejection of the sprint-1/2/3 revision): the proof run
# that shipped with that revision (31458923518) actually ran the full 10
# minutes and was killed by the STEP-level backstop, not the per-suite
# wrapper, and GitHub's own job cleanup reported orphaned `tee`/`cat`/`sleep`
# processes afterward. Root cause: plain `timeout CMD` only ever signals its
# DIRECT child. A suite that backgrounds a grandchild with `&` (exactly the
# shape of the production heartbeat loop this issue started from, and of a
# `| tee` / `cat` pipeline) is not that direct child, so the grandchild is
# never signalled and survives, holding its inherited stdout fd open for as
# long as it lives — which is the exact mechanism issue #92 is about.
#
# The fix here is TWO independent layers, either of which alone would close
# the hole:
#   1. Process-GROUP containment: `set -m` (job control) makes each suite the
#      leader of its OWN new process group (verified: its pgid equals its
#      pid). On timeout we signal the WHOLE group (`kill -TERM -- -PID`, then
#      `-KILL` after a grace period if TERM is ignored) rather than the
#      single suite process, so a backgrounded grandchild dies with its
#      parent instead of surviving it.
#   2. Stdout isolation: each suite's combined stdout/stderr is captured to a
#      private regular file, not connected live to this script's own stdout
#      (i.e. not to the Actions step's pipe). Even if some future descendant
#      escaped the process group (e.g. by calling setsid itself) and outlived
#      the kill, writing to a plain file never blocks on a reader, so it
#      cannot hold the step's actual output pipe open the way the incident's
#      surviving `tee`/`cat` did. The captured output is `cat`'d to this
#      script's real stdout immediately after the suite is reaped, so suite
#      announcements and assertion output are fully preserved in the log.
SUITE_TIMEOUT_SECONDS="${SQUAD_ACA_TEST_SUITE_TIMEOUT:-120}"
KILL_GRACE_SECONDS="${SQUAD_ACA_TEST_SUITE_KILL_GRACE:-10}"

SKIP_EXIT_CODE=77
overall_rc=0
passed=0
failed=0
skipped=0
skipped_suites=()

for test_file in "${TEST_DIR}"/test_*.sh; do
  [[ -f "$test_file" ]] || continue
  suite="$(basename "$test_file")"
  echo ""
  echo "### Running ${suite}"

  suite_out="$(mktemp "${TMPDIR:-/tmp}/squad-suite-out.XXXXXXXXXXXX")"
  suite_start=$(date +%s)

  # `set -m` gives the backgrounded suite its own process group (pgid == its
  # own pid), independent of this runner's group, so it can be signalled as a
  # unit. Output goes to a private file, not this script's stdout — see the
  # comment above.
  set -m
  bash "$test_file" >"$suite_out" 2>&1 &
  suite_pid=$!
  set +m

  waited=0
  timed_out=0
  while kill -0 "$suite_pid" 2>/dev/null; do
    if (( waited >= SUITE_TIMEOUT_SECONDS )); then
      timed_out=1
      # Signal the WHOLE process group, not just $suite_pid, so a
      # backgrounded grandchild (e.g. the incident's surviving tee/cat/sleep)
      # is terminated along with its parent rather than orphaned.
      kill -TERM -- -"$suite_pid" 2>/dev/null
      grace_waited=0
      while kill -0 "$suite_pid" 2>/dev/null && (( grace_waited < KILL_GRACE_SECONDS )); do
        sleep 1
        grace_waited=$((grace_waited + 1))
      done
      # Escalate to KILL for the group if TERM was ignored (mirrors the old
      # --kill-after semantics, now applied to the whole group).
      kill -KILL -- -"$suite_pid" 2>/dev/null
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$suite_pid" 2>/dev/null
  rc=$?
  suite_end=$(date +%s)
  duration=$((suite_end - suite_start))

  cat "$suite_out"
  rm -f "$suite_out"

  # Best-effort orphan sweep: if anything is still alive in this suite's
  # process group after it was reaped (e.g. a descendant that re-parented
  # itself away before the KILL landed), force it down and say so loudly
  # rather than silently leaving it for GitHub's own cleanup to report.
  orphan_check="$(pgrep -g "$suite_pid" 2>/dev/null || true)"
  if [[ -n "$orphan_check" ]]; then
    echo "WARNING: orphan descendant(s) of ${suite} survived (pgid ${suite_pid}); force-killing: ${orphan_check}"
    kill -KILL -- -"$suite_pid" 2>/dev/null
  fi

  if [[ "$timed_out" -eq 1 ]]; then
    echo "FAIL: ${suite} did not finish within ${SUITE_TIMEOUT_SECONDS}s and was killed (duration ${duration}s, process group terminated) — a hang must fail, not idle (issue #92)."
    failed=$((failed + 1))
    overall_rc=1
  elif [[ "$rc" -eq 0 ]]; then
    passed=$((passed + 1))
  elif [[ "$rc" -eq "$SKIP_EXIT_CODE" ]]; then
    skipped=$((skipped + 1))
    skipped_suites+=("$suite")
  else
    failed=$((failed + 1))
    overall_rc=1
  fi
done

echo ""
echo "Suites: ${passed} passed, ${failed} failed, ${skipped} skipped."
if [[ "$skipped" -gt 0 ]]; then
  echo "Skipped suites (NOT counted as passes):"
  for suite in "${skipped_suites[@]}"; do
    echo "  - ${suite}"
  done
fi

if [[ $((passed + failed)) -eq 0 ]]; then
  echo "No worker capability test suites executed in ${TEST_DIR} — refusing to report success."
  exit 1
fi

if [[ "$overall_rc" -eq 0 ]]; then
  echo "All worker capability tests passed."
else
  echo "One or more worker capability test suites FAILED."
fi
exit "$overall_rc"
