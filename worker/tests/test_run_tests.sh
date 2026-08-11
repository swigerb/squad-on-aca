#!/usr/bin/env bash
# Contract tests for worker/tests/run-tests.sh — the harness self-test.
#
# PR #9 shipped a runner that could not report failure. It captured the suite
# status INSIDE the negated condition:
#
#   if ! bash "$test_script"; then
#     status=$?     # $? here is the NEGATED status, i.e. always 0
#     break
#   fi
#
# A failing suite therefore left status=0, and the runner printed
# "All worker capability tests passed." and exited 0. Nothing in the suite could
# detect that, because nothing tested the runner itself.
#
# These tests run the REAL runner against a throwaway directory of synthetic
# suites (via the SQUAD_ACA_TEST_DIR override) and assert its exit code, banner,
# and counts for every outcome: pass, fail, mixed, skip, all-skipped, and empty.
# They also prove the default (no override) discovery path still works, and that
# lib/deps.sh emits a visible SKIP rather than a silent pass.
#
# Everything is created under a self-cleaning temp root; no synthetic suite is
# ever left in worker/tests/, so a normal run is unaffected.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${TEST_DIR}/run-tests.sh"
DEPS_LIB="${TEST_DIR}/lib/deps.sh"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-run-tests"

PASS_BANNER="All worker capability tests passed."
FAIL_BANNER="One or more worker capability test suites FAILED."

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${DEPS_LIB}"
require_deps env find

# Single source of truth for the skip code, shared with run-tests.sh.
SKIP_EXIT_CODE="$TEST_SKIP_EXIT_CODE"

echo "== run-tests.sh (harness self-test) =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

# --- Fixture helpers --------------------------------------------------------

# make_fixture_dir -> prints a fresh, empty directory of synthetic suites.
make_fixture_dir() {
  local dir="${TEST_TMP_ROOT}/case-$$-${RANDOM}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# make_suite <dir> <name> <exit-code> [message]
# Writes a synthetic suite that echoes a marker and exits with the given code.
make_suite() {
  local dir="$1" name="$2" code="$3" msg="${4:-}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "ran %s"\n' "$name"
    if [[ -n "$msg" ]]; then printf 'echo "%s"\n' "$msg"; fi
    printf 'exit %s\n' "$code"
  } > "${dir}/${name}"
  chmod +x "${dir}/${name}"
}

# run_runner <fixture-dir> -> sets RUNNER_OUT and RUNNER_RC.
run_runner() {
  RUNNER_OUT="$(SQUAD_ACA_TEST_DIR="$1" bash "$RUNNER" 2>&1)"
  RUNNER_RC=$?
}

# 1. A single failing suite must make the runner fail. This is the exact PR #9
#    regression: the runner previously exited 0 here.
dir="$(make_fixture_dir)"
make_suite "$dir" "test_boom.sh" 1
run_runner "$dir"
assert_eq "1" "$RUNNER_RC" "failing suite: runner exits non-zero"
assert_contains "$RUNNER_OUT" "$FAIL_BANNER" "failing suite: prints the failure banner"
assert_not_contains "$RUNNER_OUT" "$PASS_BANNER" "failing suite: never prints the success banner"
assert_contains "$RUNNER_OUT" "Suites: 0 passed, 1 failed, 0 skipped." "failing suite: counts the failure"
rm -rf "$dir"

# 2. A suite that fails with a code other than 1 (and other than the skip code)
#    is still a failure, not a skip.
dir="$(make_fixture_dir)"
make_suite "$dir" "test_exit78.sh" 78
run_runner "$dir"
assert_eq "1" "$RUNNER_RC" "non-1 failure code: runner exits non-zero"
assert_contains "$RUNNER_OUT" "Suites: 0 passed, 1 failed, 0 skipped." "non-1 failure code: counted as a failure, not a skip"
rm -rf "$dir"

# 3. All-passing suites: green banner, accurate counts, exit 0.
dir="$(make_fixture_dir)"
make_suite "$dir" "test_ok_a.sh" 0
make_suite "$dir" "test_ok_b.sh" 0
run_runner "$dir"
assert_eq "0" "$RUNNER_RC" "all passing: runner exits 0"
assert_contains "$RUNNER_OUT" "$PASS_BANNER" "all passing: prints the success banner"
assert_contains "$RUNNER_OUT" "Suites: 2 passed, 0 failed, 0 skipped." "all passing: counts both suites"
assert_contains "$RUNNER_OUT" "### Running test_ok_a.sh" "all passing: announces each suite"
rm -rf "$dir"

# 4. Mixed pass + fail: one green suite must not mask a red one.
dir="$(make_fixture_dir)"
make_suite "$dir" "test_ok.sh" 0
make_suite "$dir" "test_zbroken.sh" 1
run_runner "$dir"
assert_eq "1" "$RUNNER_RC" "mixed pass/fail: runner exits non-zero"
assert_not_contains "$RUNNER_OUT" "$PASS_BANNER" "mixed pass/fail: no success banner"
assert_contains "$RUNNER_OUT" "Suites: 1 passed, 1 failed, 0 skipped." "mixed pass/fail: counts both outcomes"
rm -rf "$dir"

# 5. A later-failing suite must not be masked by an earlier passing one, and the
#    runner must keep going rather than stopping at the first result.
dir="$(make_fixture_dir)"
make_suite "$dir" "test_a_ok.sh" 0
make_suite "$dir" "test_b_bad.sh" 1
make_suite "$dir" "test_c_ok.sh" 0
run_runner "$dir"
assert_eq "1" "$RUNNER_RC" "failure in the middle: runner exits non-zero"
assert_contains "$RUNNER_OUT" "ran test_c_ok.sh" "failure in the middle: later suites still run"
assert_contains "$RUNNER_OUT" "Suites: 2 passed, 1 failed, 0 skipped." "failure in the middle: counts are accurate"
rm -rf "$dir"

# 6. Skip semantics: a skipped suite is surfaced and is NOT counted as a pass.
dir="$(make_fixture_dir)"
make_suite "$dir" "test_ok.sh" 0
make_suite "$dir" "test_skipme.sh" "$SKIP_EXIT_CODE" "SKIP: test_skipme.sh — missing definitely-not-a-real-binary"
run_runner "$dir"
assert_eq "0" "$RUNNER_RC" "skipped suite: does not fail the run"
assert_contains "$RUNNER_OUT" "SKIP: test_skipme.sh — missing definitely-not-a-real-binary" "skipped suite: the SKIP line is visible"
assert_contains "$RUNNER_OUT" "Suites: 1 passed, 0 failed, 1 skipped." "skipped suite: counted as a skip, not a pass"
assert_contains "$RUNNER_OUT" "Skipped suites (NOT counted as passes):" "skipped suite: summary calls out skips"
assert_contains "$RUNNER_OUT" "  - test_skipme.sh" "skipped suite: names the skipped suite"
rm -rf "$dir"

# 7. A skip must not mask a real failure.
dir="$(make_fixture_dir)"
make_suite "$dir" "test_skipme.sh" "$SKIP_EXIT_CODE" "SKIP: test_skipme.sh — missing nope"
make_suite "$dir" "test_zbroken.sh" 1
run_runner "$dir"
assert_eq "1" "$RUNNER_RC" "skip + failure: runner still exits non-zero"
assert_not_contains "$RUNNER_OUT" "$PASS_BANNER" "skip + failure: no success banner"
assert_contains "$RUNNER_OUT" "Suites: 0 passed, 1 failed, 1 skipped." "skip + failure: counts both"
rm -rf "$dir"

# 8. If EVERY suite skips, nothing was proven — the run must not report success.
dir="$(make_fixture_dir)"
make_suite "$dir" "test_skip_a.sh" "$SKIP_EXIT_CODE" "SKIP: test_skip_a.sh — missing nope"
make_suite "$dir" "test_skip_b.sh" "$SKIP_EXIT_CODE" "SKIP: test_skip_b.sh — missing nope"
run_runner "$dir"
assert_eq "1" "$RUNNER_RC" "all skipped: runner exits non-zero (nothing executed)"
assert_not_contains "$RUNNER_OUT" "$PASS_BANNER" "all skipped: no success banner"
assert_contains "$RUNNER_OUT" "No worker capability test suites executed" "all skipped: says nothing executed"
rm -rf "$dir"

# 9. An empty test directory must not report success either.
dir="$(make_fixture_dir)"
run_runner "$dir"
assert_eq "1" "$RUNNER_RC" "empty test dir: runner exits non-zero"
assert_not_contains "$RUNNER_OUT" "$PASS_BANNER" "empty test dir: no success banner"
rm -rf "$dir"

# 10. Default discovery (no SQUAD_ACA_TEST_DIR) still resolves to the runner's
#     OWN directory. Copy the real runner next to synthetic suites and run it
#     with the override explicitly unset.
dir="$(make_fixture_dir)"
cp "$RUNNER" "${dir}/run-tests.sh"
make_suite "$dir" "test_ok.sh" 0
make_suite "$dir" "test_zbroken.sh" 1
out="$(env -u SQUAD_ACA_TEST_DIR bash "${dir}/run-tests.sh" 2>&1)"
rc=$?
assert_eq "1" "$rc" "default discovery: finds suites beside the runner and reports failure"
assert_contains "$out" "ran test_ok.sh" "default discovery: ran the co-located passing suite"
assert_contains "$out" "Suites: 1 passed, 1 failed, 0 skipped." "default discovery: counts match the co-located suites"
rm -rf "$dir"

# --- issue #92: a hanging suite must fail, and fail fast, not idle ---------

# 15a. A suite that hangs (never exits) must be killed and counted as a
#      FAILURE, named by suite, once it exceeds its budget — not left to hang
#      the whole runner/job. SQUAD_ACA_TEST_SUITE_TIMEOUT overrides the real
#      120s default so this proves the mechanism in under two seconds.
#      Duration is asserted with BOTH an upper bound (killed near budget, not
#      left to the old 10-minute/6-hour backstop) and a lower bound (it did
#      not report success/failure suspiciously fast, which would mean the
#      hang was never actually exercised) — a pass/fail-only check would let
#      a six-hour timeout falsely pass.
dir="$(make_fixture_dir)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'echo "ran test_hangs.sh"\n'
  printf 'sleep 9999\n'
} > "${dir}/test_hangs.sh"
chmod +x "${dir}/test_hangs.sh"
hang_start=$(date +%s)
out="$(SQUAD_ACA_TEST_DIR="$dir" SQUAD_ACA_TEST_SUITE_TIMEOUT=1 SQUAD_ACA_TEST_SUITE_KILL_GRACE=1 bash "$RUNNER" 2>&1)"
rc=$?
hang_end=$(date +%s)
hang_duration=$((hang_end - hang_start))
assert_eq "1" "$rc" "hanging suite: runner exits non-zero rather than hanging forever"
assert_contains "$out" "ran test_hangs.sh" "hanging suite: the suite's own output before it hung is still visible"
assert_contains "$out" "FAIL: test_hangs.sh did not finish within 1s and was killed" "hanging suite: names the suite that hung, not a generic timeout"
assert_contains "$out" "Suites: 0 passed, 1 failed, 0 skipped." "hanging suite: counted as a failure, not silently dropped"
assert_not_contains "$out" "$PASS_BANNER" "hanging suite: no success banner"
if (( hang_duration < 1 )); then
  echo "FAIL: hanging suite: took ${hang_duration}s, suspiciously fast — the hang may never have actually been exercised (expected >= 1s)"
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "ok - hanging suite: took at least as long as the configured timeout (${hang_duration}s >= 1s), proving it genuinely hung before being caught"
  TESTS_RUN=$((TESTS_RUN + 1))
fi
if (( hang_duration > 15 )); then
  echo "FAIL: hanging suite: took ${hang_duration}s -- nowhere near the configured 1s+1s bound; a six-hour timeout would also 'pass' a status-only check like this one (expected <= 15s)"
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
else
  echo "ok - hanging suite: finished in ${hang_duration}s, close to its configured bound rather than a coarse multi-minute/hour backstop"
  TESTS_RUN=$((TESTS_RUN + 1))
fi
rm -rf "$dir"

# 15b. A hang must not mask a later suite's own real result — the runner keeps
#      going past a killed suite rather than stopping.
dir="$(make_fixture_dir)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'sleep 9999\n'
} > "${dir}/test_a_hangs.sh"
chmod +x "${dir}/test_a_hangs.sh"
make_suite "$dir" "test_b_ok.sh" 0
out="$(SQUAD_ACA_TEST_DIR="$dir" SQUAD_ACA_TEST_SUITE_TIMEOUT=1 bash "$RUNNER" 2>&1)"
rc=$?
assert_eq "1" "$rc" "hang then pass: runner still exits non-zero overall"
assert_contains "$out" "ran test_b_ok.sh" "hang then pass: the suite after the hang still runs"
assert_contains "$out" "Suites: 1 passed, 1 failed, 0 skipped." "hang then pass: both outcomes are counted correctly"
rm -rf "$dir"

# --- lib/deps.sh contract ---------------------------------------------------

# 11. A missing dependency produces a visible SKIP line and the skip exit code.
dir="$(make_fixture_dir)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'source "%s"\n' "$DEPS_LIB"
  printf 'require_deps definitely-not-a-real-binary-9999\n'
  printf 'echo "SHOULD NOT REACH HERE"\n'
} > "${dir}/test_needs_missing.sh"
out="$(bash "${dir}/test_needs_missing.sh" 2>&1)"
rc=$?
assert_eq "$SKIP_EXIT_CODE" "$rc" "require_deps: missing dep exits with the skip code (77)"
assert_contains "$out" "SKIP: test_needs_missing.sh — missing definitely-not-a-real-binary-9999" "require_deps: prints a visible SKIP naming suite and dep"
assert_not_contains "$out" "SHOULD NOT REACH HERE" "require_deps: missing dep stops the suite immediately"
rm -rf "$dir"

# 12. Present dependencies are a silent no-op — the suite runs normally.
dir="$(make_fixture_dir)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'source "%s"\n' "$DEPS_LIB"
  printf 'require_deps bash\n'
  printf 'echo "suite body ran"\n'
} > "${dir}/test_needs_bash.sh"
out="$(bash "${dir}/test_needs_bash.sh" 2>&1)"
rc=$?
assert_eq "0" "$rc" "require_deps: satisfied deps exit 0"
assert_contains "$out" "suite body ran" "require_deps: satisfied deps run the suite body"
assert_not_contains "$out" "SKIP:" "require_deps: satisfied deps emit no SKIP line"
rm -rf "$dir"

# 13. Multiple missing deps are reported together on one SKIP line.
dir="$(make_fixture_dir)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'source "%s"\n' "$DEPS_LIB"
  printf 'require_deps bash no-such-tool-a no-such-tool-b\n'
} > "${dir}/test_needs_many.sh"
out="$(bash "${dir}/test_needs_many.sh" 2>&1)"
assert_contains "$out" "missing no-such-tool-a no-such-tool-b" "require_deps: reports every missing dep, ignoring present ones"
rm -rf "$dir"

# 14. End to end through the runner: a dependency-driven skip is surfaced by the
#     runner's summary and is not counted as a pass.
dir="$(make_fixture_dir)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'source "%s"\n' "$DEPS_LIB"
  printf 'require_deps definitely-not-a-real-binary-9999\n'
} > "${dir}/test_dep_skip.sh"
make_suite "$dir" "test_ok.sh" 0
run_runner "$dir"
assert_eq "0" "$RUNNER_RC" "dep skip via runner: run is not failed by a skip"
assert_contains "$RUNNER_OUT" "SKIP: test_dep_skip.sh — missing definitely-not-a-real-binary-9999" "dep skip via runner: SKIP line reaches the runner output"
assert_contains "$RUNNER_OUT" "Suites: 1 passed, 0 failed, 1 skipped." "dep skip via runner: skip is not counted as a pass"
rm -rf "$dir"

# 15. The synthetic fixtures must never leak into the real test directory.
leaked="$(find "$TEST_DIR" -maxdepth 1 -name 'test_ok*.sh' -o -maxdepth 1 -name 'test_boom.sh' | wc -l | tr -d ' ')"
assert_eq "0" "$leaked" "cleanup: no synthetic suite is left in worker/tests/"

test_summary
