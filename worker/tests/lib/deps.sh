#!/usr/bin/env bash
# Explicit test dependency declaration for worker test suites — no external
# dependency, sourced alongside lib/assert.sh.
#
# A suite declares what it needs up front, before doing any work:
#
#   source "${TEST_DIR}/lib/deps.sh"
#   require_deps node git
#
# When every dependency is present, require_deps is a silent no-op and the suite
# runs normally. When one is genuinely absent it prints a VISIBLE
#
#   SKIP: <suite> — missing <dep>
#
# line and exits with TEST_SKIP_EXIT_CODE (77, the conventional EX_UNAVAILABLE
# "skipped" code). run-tests.sh counts that as a SKIP and reports it in the
# end-of-run summary — never as a pass.
#
# This file NEVER downloads or installs a runtime. A missing dependency is
# reported, not silently provisioned: a test run that quietly bootstrapped node
# would no longer be testing the environment it claims to test.
set -uo pipefail

# Exit code a suite uses to tell run-tests.sh "I did not execute".
TEST_SKIP_EXIT_CODE=77

# require_deps <command> [command...]
# Exits the calling suite with TEST_SKIP_EXIT_CODE if any command is missing.
require_deps() {
  local suite dep
  local missing=()
  # BASH_SOURCE[1] is the suite that called us (BASH_SOURCE[0] is this file).
  suite="$(basename "${BASH_SOURCE[1]:-$0}")"

  for dep in "$@"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      missing+=("$dep")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "SKIP: ${suite} — missing ${missing[*]}"
    exit "$TEST_SKIP_EXIT_CODE"
  fi
}
