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
  bash "$test_file"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
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
