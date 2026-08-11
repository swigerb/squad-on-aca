#!/usr/bin/env bash
# Issue #92 sprint 3: the cancelled job that motivated this issue showed NO
# output at all, so there was no way to tell which suite it stopped in
# without re-running it. The fix is behavioural (every suite prints an
# `echo "== ... =="` banner before it runs any check), and a behaviour with
# no test regresses silently the next time someone adds a suite. This test
# is that control: it reads every worker/tests/test_*.sh file (excluding
# itself and the harness, which announces each suite FOR them) and fails,
# by name, on any suite that either has no banner at all, or whose first
# check/assertion runs BEFORE its banner.
#
# A hard "banner must be in the first N lines" window was tried first and
# was wrong: several compliant suites carry a multi-line file-header comment
# explaining WHY the test exists (e.g. test_no_orphan_children.sh's own
# banner is on line 43) before the banner line, which is still well before
# the first check runs. A fixed line count would fail suites for having a
# good comment, and would just as easily pass a suite whose banner sat right
# at the cutoff while its first check ran even earlier. What actually matters
# — "does the suite announce itself before doing any work" — is a relative
# ordering, not an absolute position, so that is what this compares: the
# line number of the banner against the line number of the first
# check/assert_* invocation (a CALL, i.e. `check "..."` / `assert_eq ...`,
# not the `check() {`/`assert_eq()` function DEFINITION lines that several
# suites also contain).
set -uo pipefail

echo "== every worker test suite announces itself before running (issue #92) =="

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SELF="$(basename "${BASH_SOURCE[0]}")"

# First line number matching a bare `echo "== ...` banner, or empty if none.
banner_line() {
  grep -n -m1 'echo "== ' "$1" | cut -d: -f1
}

# First line number that CALLS a check/assert_* function (name followed by
# whitespace then a quote, e.g. `check "name" ...` / `assert_eq "a" "b" ...`)
# rather than DEFINES one (name followed by `()`), or empty if none.
first_check_line() {
  grep -n -E '^[[:space:]]*(check|assert_[A-Za-z_]+)[[:space:]]+["'"'"']' "$1" \
    | grep -v -E '^\s*[0-9]+:[[:space:]]*(check|assert_[A-Za-z_]+)\(\)' \
    | head -n1 | cut -d: -f1
}

missing=()
too_late=()
for test_file in "${TEST_DIR}"/test_*.sh; do
  [[ -f "$test_file" ]] || continue
  suite="$(basename "$test_file")"
  [[ "$suite" == "$SELF" ]] && continue

  banner="$(banner_line "$test_file")"
  if [[ -z "$banner" ]]; then
    missing+=("$suite")
    continue
  fi

  check_line="$(first_check_line "$test_file")"
  if [[ -n "$check_line" ]] && [[ "$banner" -gt "$check_line" ]]; then
    too_late+=("${suite}(banner@${banner},check@${check_line})")
  fi
done

assert_eq "" "${missing[*]:-}" \
  "every suite under worker/tests has a self-announcing banner somewhere in the file (missing: ${missing[*]:-none})"
assert_eq "" "${too_late[*]:-}" \
  "every suite's banner appears before its first check/assertion runs, not after (violations: ${too_late[*]:-none})"

test_summary
