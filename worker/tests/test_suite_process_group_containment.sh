#!/usr/bin/env bash
# Issue #92 sprint 4 (reviewer rejection of the sprint 1/2/3 revision):
# proof run 31458923518 showed the per-suite wrapper did NOT actually work —
# it ran the full 10 minutes and was killed by the workflow's STEP-level
# backstop, not the per-suite timeout, and GitHub's own job cleanup reported
# orphaned `tee`/`cat`/`sleep` processes afterward. Root cause: plain
# `timeout CMD` only ever signals its DIRECT child. A suite that backgrounds
# a grandchild with `&` — exactly a `tee`/`cat` pipeline holding stdout open,
# the shape GitHub's cleanup actually reported — is never signalled and
# survives.
#
# This suite is the control for that gap. It runs the REAL
# worker/tests/run-tests.sh (not a reimplementation) against a synthetic
# suite that deliberately backgrounds a grandchild pipeline
# (`tee`/`cat`/`sleep`) inheriting the suite's own stdout, and proves:
#
#   1. the per-suite wrapper terminates the hang around its configured
#      bound, not the 6-hour (or job/step-level) backstop — asserted with
#      BOTH an upper bound (it must not run drastically over budget) and a
#      lower bound (it must not report success suspiciously fast, which
#      would mean the suite was never actually run) on wall-clock duration,
#   2. the failure output names the specific suite that hung,
#   3. no descendant tee/cat/sleep process survives the run,
#   4. a mutation proof: temporarily disabling the process-GROUP signal in a
#      throwaway copy of run-tests.sh (kill only the direct suite PID, not
#      its group — the actual containment mechanism) reproduces the orphan,
#      showing the assertions above are not vacuous.
#
# SQUAD_ACA_TEST_SUITE_TIMEOUT and SQUAD_ACA_TEST_SUITE_KILL_GRACE let this
# run in a couple of seconds locally/on CI rather than waiting on the real
# 120s/10s production defaults.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${TEST_DIR}/run-tests.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

# assert.sh has no numeric bound helpers; add them here rather than growing
# the shared helper for two call sites.
assert_ge() {
  local actual="$1" min="$2" msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if (( actual < min )); then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "FAIL: ${msg} (expected >= ${min}, actual: ${actual})"
    return 0
  fi
  echo "ok - ${msg}"
}
assert_le() {
  local actual="$1" max="$2" msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if (( actual > max )); then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "FAIL: ${msg} (expected <= ${max}, actual: ${actual})"
    return 0
  fi
  echo "ok - ${msg}"
}

# Recursively kill a process and every descendant. Used to guarantee this
# suite's OWN fixtures are fully swept even in the mutation-proof case below,
# where the runner under test is deliberately missing its containment (so
# its own cleanup cannot be relied on to reap the orphan it was built to
# leave behind).
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

echo "== run-tests.sh contains a suite that backgrounds a tee/cat/sleep grandchild inheriting stdout (issue #92 sprint 4) =="

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-pg-containment-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

SUITE_TIMEOUT=2
KILL_GRACE=2
# Generous but bounded: real hangs are killed within TIMEOUT+GRACE plus a
# couple of seconds of polling/signal-delivery slack, never anywhere near
# the old 10-minute step backstop or a 6-hour default.
UPPER_BOUND_SECONDS=$((SUITE_TIMEOUT + KILL_GRACE + 8))
# A run that "succeeds" faster than the timeout itself proves nothing --
# it would mean the suite was never actually let run/hang at all.
LOWER_BOUND_SECONDS="$SUITE_TIMEOUT"

make_fixture_dir() {
  local dir="${WORK}/case-$$-${RANDOM}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# Writes the exact shape GitHub's cleanup reported as orphans: a
# `tee`/`cat`/`sleep` pipeline backgrounded with `&` and disowned, inheriting
# the suite's own stdout, that never exits on its own. `tee`'s own argv
# carries $marker_file (a unique per-run path), so a later
# `pgrep -f "$marker_file"` matches the LIVE, long-running grandchild
# process itself for as long as it survives, rather than some short-lived
# side effect that would exit before this suite gets a chance to check.
write_grandchild_hang_suite() {
  local dir="$1" name="$2" marker_file="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "ran %s"\n' "$name"
    printf '( sleep 9999 | tee -a "%s" | cat > /dev/null ) &\n' "$marker_file"
    printf 'disown -a\n'
    printf 'sleep 9999\n'
  } > "${dir}/${name}"
  chmod +x "${dir}/${name}"
}

run_containment_case() {
  local dir marker_file; dir="$(make_fixture_dir)"
  marker_file="${WORK}/orphan-marker-$$-${RANDOM}.log"
  write_grandchild_hang_suite "$dir" "test_grandchild_hang.sh" "$marker_file"
  local start end
  start=$(date +%s)
  CASE_OUT="$(SQUAD_ACA_TEST_DIR="$dir" SQUAD_ACA_TEST_SUITE_TIMEOUT="$SUITE_TIMEOUT" SQUAD_ACA_TEST_SUITE_KILL_GRACE="$KILL_GRACE" bash "$RUNNER" 2>&1)"
  CASE_RC=$?
  end=$(date +%s)
  CASE_DURATION=$((end - start))
  CASE_MARKER_FILE="$marker_file"
  rm -rf "$dir"
}

# ---------------------------------------------------------------------------
# 1/2/3. The real mechanism: bounded duration, names the suite, no orphans.
# ---------------------------------------------------------------------------
run_containment_case
assert_eq "1" "$CASE_RC" "grandchild hang: runner exits non-zero rather than hanging forever"
assert_contains "$CASE_OUT" "FAIL: test_grandchild_hang.sh did not finish within ${SUITE_TIMEOUT}s and was killed" \
  "grandchild hang: names the specific suite that hung, not a generic timeout"
assert_ge "$CASE_DURATION" "$LOWER_BOUND_SECONDS" \
  "grandchild hang: the run took at least as long as the configured per-suite timeout (proves the suite genuinely hung and was caught, not a vacuous instant pass)"
assert_le "$CASE_DURATION" "$UPPER_BOUND_SECONDS" \
  "grandchild hang: the run finished around the configured bound (${CASE_DURATION}s <= ${UPPER_BOUND_SECONDS}s), not the old 10-minute step backstop or a 6-hour default"

sleep 1
ORPHANS="$(pgrep -f "$CASE_MARKER_FILE" 2>/dev/null || true)"
assert_eq "" "$ORPHANS" \
  "grandchild hang: no descendant (tee/cat/sleep) tagged with this run's marker survives -- the exact orphan shape GitHub's own job cleanup reported on the rejected proof run"
# Best-effort belt-and-suspenders sweep so a failure above still leaves the
# machine/runner clean.
[[ -n "$ORPHANS" ]] && kill -KILL $ORPHANS 2>/dev/null

# ---------------------------------------------------------------------------
# MUTATION PROOF: disable the process-GROUP signal (the actual containment
# fix) by mutating a copy of run-tests.sh so it signals only the direct
# suite PID instead of the whole group (`kill -TERM/-KILL "$suite_pid"`
# instead of `-- -"$suite_pid"`), rerun the SAME synthetic suite, and show
# the backgrounded/disowned grandchild survives — proving the assertions
# above are not vacuous, i.e. it is the process-GROUP signal doing the work,
# not some other part of the harness (e.g. GNU coreutils' own default
# grouping of `timeout`'s child, which this repo no longer even calls). The
# real run-tests.sh is never modified; only a throwaway copy is.
# ---------------------------------------------------------------------------
MUTATED_RUNNER="${WORK}/run-tests-mutated.sh"
sed -E 's/-- -"\$suite_pid"/"$suite_pid"/g' "$RUNNER" > "$MUTATED_RUNNER" 2>/dev/null || true

if [[ -s "$MUTATED_RUNNER" ]] && ! grep -q -- '-- -"\$suite_pid"' "$MUTATED_RUNNER"; then
  chmod +x "$MUTATED_RUNNER"
  dir="$(make_fixture_dir)"
  MUT_MARKER_FILE="${WORK}/orphan-mutation-marker-$$-${RANDOM}.log"
  write_grandchild_hang_suite "$dir" "test_grandchild_hang.sh" "$MUT_MARKER_FILE"

  SQUAD_ACA_TEST_DIR="$dir" SQUAD_ACA_TEST_SUITE_TIMEOUT="$SUITE_TIMEOUT" SQUAD_ACA_TEST_SUITE_KILL_GRACE="$KILL_GRACE" bash "$MUTATED_RUNNER" >/dev/null 2>&1
  sleep 1
  MUT_ORPHANS="$(pgrep -f "$MUT_MARKER_FILE" 2>/dev/null || true)"
  assert_ne "" "$MUT_ORPHANS" \
    "MUTATION PROOF: disabling the process-GROUP signal (single-PID kill instead of group kill) leaves the tee/cat/sleep grandchild running after the same synthetic hang -- confirming the group-kill above is the thing actually preventing the orphan, not an artifact of this harness"
  # Full cleanup: with the group signal disabled, BOTH the pipeline's own
  # `sleep` (found via the marker) and the suite's separate foreground
  # `sleep 9999` (which carries no distinguishing marker of its own) are
  # left as orphans reparented off of the already-killed suite process.
  # `sleep 9999` is this repo's established synthetic-hang literal (used the
  # same way elsewhere in worker/tests), so it is safe to sweep broadly here
  # -- this suite runs suites sequentially and never overlaps another
  # concurrent `sleep 9999` fixture.
  pkill -KILL -f "$MUT_MARKER_FILE" 2>/dev/null
  pkill -KILL -f 'sleep 9999' 2>/dev/null
  rm -rf "$dir"
else
  echo "FAIL: could not construct the mutated (group-signal-disabled) runner for the mutation proof -- see script"
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
fi

test_summary
