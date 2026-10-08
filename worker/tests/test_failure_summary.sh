#!/usr/bin/env bash
# Behavioural tests for worker/lib/failure-summary.js (issue #144).
#
# The extractor is the thing standing between a failed Squad on ACA job and a
# human (or a fix-dispatch agent) actually knowing why. So this suite is
# weighted towards the acceptance criteria from the issue itself:
#
#   * known artifact (test.out-shaped file) is preferred over the raw log;
#   * wrapper/shell echo noise never pollutes the summary;
#   * exact failing test/suite names and their assertion context are kept;
#   * final status and exit code are always present;
#   * a pointer to the raw log/artifact is always included;
#   * when there is NOTHING to extract from, the summary says so explicitly
#     instead of emitting a confident-looking empty report.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
MODULE="${WORKER_DIR}/lib/failure-summary.js"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== failure-summary.js =="

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-failure-summary.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

run_cli() {
  node "$MODULE" "$@"
}

# ---------------------------------------------------------------------------
# Fixture: a realistic captured test-output artifact (shaped like this repo's
# own run-tests.out / the issue's "test.out"), containing wrapper noise AND a
# real failure with assertion context.
# ---------------------------------------------------------------------------
cat >"${WORK}/test.out" <<'EOF'
Run bash worker/tests/run-tests.sh
+ set -o pipefail
+ bash worker/tests/run-tests.sh
::group::Suite output

### Running test_widget.sh
ok - widget renders

### Running test_gadget.sh
FAIL: test_gadget.sh did not finish within 120s and was killed (duration 121s, process group terminated) -- a hang must fail, not idle (issue #92).
AssertionError: expected gadget.state to equal "ready" but got "pending"
    at Object.<anonymous> (/repo/worker/tests/test_gadget.sh:88:5)

Suites: 1 passed, 1 failed, 0 skipped.
One or more worker capability test suites FAILED.
::endgroup::
EOF

cat >"${WORK}/raw.log" <<'EOF'
2026-10-08T01:00:00Z [info] starting session
2026-10-08T01:00:05Z [info] running bash worker/tests/run-tests.sh
2026-10-08T01:00:10Z [stdout] ### Running test_gadget.sh
2026-10-08T01:00:11Z [stdout] FAIL: test_gadget.sh assertion failed in raw log fallback
2026-10-08T01:00:12Z [info] session ended with exit 1
EOF

# ---------------------------------------------------------------------------
# 1. The known artifact (test.out) is PREFERRED over the raw log when both
#    are available.
# ---------------------------------------------------------------------------
out="$(run_cli --test-out "${WORK}/test.out" --raw-log "${WORK}/raw.log" \
  --command "bash worker/tests/run-tests.sh" --exit-code 1 --status failure 2>"${WORK}/stderr1")"
assert_contains "$out" "known artifact" "the summary states it extracted from the known artifact"
assert_contains "$(cat "${WORK}/stderr1")" "origin=artifact" "and the CLI's own diagnostic line confirms artifact origin"
assert_not_contains "$out" "raw log fallback" "raw-log-only content is NOT pulled in when the artifact is present"

# ---------------------------------------------------------------------------
# 2. Wrapper / shell echo noise is filtered out of the summary entirely.
# ---------------------------------------------------------------------------
assert_not_contains "$out" "+ set -o pipefail" "set -x style command echo is filtered"
assert_not_contains "$out" "::group::" "GitHub Actions grouping markers are filtered"
assert_not_contains "$out" "Run bash worker/tests/run-tests.sh" "the Actions step-echo banner is filtered"

# ---------------------------------------------------------------------------
# 3. Exact failing test/suite name and assertion context are present.
# ---------------------------------------------------------------------------
assert_contains "$out" "test_gadget.sh" "the exact failing suite name is named, not just an aggregate count"
assert_contains "$out" "a hang must fail, not idle" "the real FAIL line survives filtering"
assert_contains "$out" 'expected gadget.state to equal "ready"' "the assertion/error text around the failure is preserved"
assert_contains "$out" "test_gadget.sh:88" "the failing file/line reference is preserved"

# ---------------------------------------------------------------------------
# 4. Final status, exit code and a raw-log pointer are always included.
# ---------------------------------------------------------------------------
assert_contains "$out" "**Final status:** failure" "final status is reported"
assert_contains "$out" "**Exit code:** 1" "exit code is reported"
assert_contains "$out" "**Failing command/step:** \`bash worker/tests/run-tests.sh\`" "the failing command/step is named"
assert_contains "$out" "raw.log" "a pointer to the raw log is included even though the artifact was preferred"
assert_contains "$out" "test.out" "a pointer to the known artifact is included"

# ---------------------------------------------------------------------------
# 5. Fallback to the raw log when no known artifact is available.
# ---------------------------------------------------------------------------
out_fallback="$(run_cli --raw-log "${WORK}/raw.log" --command "bash worker/tests/run-tests.sh" --exit-code 1 2>"${WORK}/stderr2")"
assert_contains "$out_fallback" "raw log fallback" "with no artifact, the raw log content is used instead"
assert_contains "$(cat "${WORK}/stderr2")" "origin=raw-log" "and the CLI diagnostic confirms the raw-log origin"

# ---------------------------------------------------------------------------
# 6. Explicit extraction failure when NEITHER source is available.
# ---------------------------------------------------------------------------
out_none="$(run_cli --raw-log "${WORK}/does-not-exist.log" --command "bash worker/tests/run-tests.sh" --exit-code 1 2>"${WORK}/stderr3")"
assert_contains "$out_none" "extraction failed" "a missing/unreadable log produces an EXPLICIT extraction-failure summary, not a silent empty one"
assert_contains "$out_none" "does-not-exist.log" "the explicit failure still points at where the raw log was expected"
assert_contains "$(cat "${WORK}/stderr3")" "extractionFailed=true" "and the CLI diagnostic agrees"

# ---------------------------------------------------------------------------
# 7. A source with no recognizable failure markers still produces a readable
#    (non-crashing) summary rather than silently reporting nothing.
# ---------------------------------------------------------------------------
cat >"${WORK}/unstructured.out" <<'EOF'
some process wrote unstructured output
and then just stopped
EOF
out_unstructured="$(run_cli --test-out "${WORK}/unstructured.out" --command "custom-tool" --exit-code 3 2>/dev/null)"
assert_contains "$out_unstructured" "No failing test/step names were recognized" "unstructured content is reported honestly rather than pattern-matched into something it is not"
assert_contains "$out_unstructured" "unstructured output" "the best-available tail of the filtered output is still shown"

# ---------------------------------------------------------------------------
# 8. --out writes the markdown to a file instead of stdout.
# ---------------------------------------------------------------------------
run_cli --test-out "${WORK}/test.out" --command "x" --exit-code 1 --out "${WORK}/failure-summary.md" >/dev/null 2>&1
assert_eq "yes" "$([[ -s "${WORK}/failure-summary.md" ]] && echo yes || echo no)" "--out writes a non-empty failure-summary.md artifact to disk"
assert_contains "$(cat "${WORK}/failure-summary.md")" "test_gadget.sh" "the written artifact contains the same extracted content"

test_summary
