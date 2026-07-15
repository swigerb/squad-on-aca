#!/usr/bin/env bash
# Runs all worker capability tests. No external test framework required.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
overall_rc=0

for test_file in "${TEST_DIR}"/test_*.sh; do
  echo ""
  echo "### Running $(basename "$test_file")"
  if ! bash "$test_file"; then
    overall_rc=1
  fi
done

echo ""
if [[ "$overall_rc" -eq 0 ]]; then
  echo "All worker capability tests passed."
else
  echo "One or more worker capability test suites FAILED."
fi
exit "$overall_rc"
