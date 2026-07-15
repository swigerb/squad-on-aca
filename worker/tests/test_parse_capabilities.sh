#!/usr/bin/env bash
# Unit tests for worker/lib/parse-capabilities.js
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PARSER="${WORKER_DIR}/lib/parse-capabilities.js"
FIXTURES="${TEST_DIR}/fixtures"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== parse-capabilities.js =="

out="$(node "$PARSER" "${FIXTURES}/valid.yml" 2>&1)"
rc=$?
assert_eq "0" "$rc" "valid.yml parses successfully"
assert_contains "$out" '"version":1' "valid.yml includes version"
assert_contains "$out" '"name":"git"' "valid.yml includes git tool entry"
assert_contains "$out" '"hint":"ghcr.io/example/squad-worker-python:latest"' "valid.yml includes image hint"

out="$(node "$PARSER" "${FIXTURES}/satisfied.yml" 2>&1)"
rc=$?
assert_eq "0" "$rc" "satisfied.yml parses successfully"

out="$(node "$PARSER" "${FIXTURES}/malformed.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "malformed.yml is rejected with EX_DATAERR"
assert_contains "$out" "Invalid capability manifest" "malformed.yml error is actionable"

out="$(node "$PARSER" "${FIXTURES}/missing-fields.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "missing-fields.yml (tool without name) is rejected"
assert_contains "$out" 'missing "name"' "missing-fields.yml error names the problem"

out="$(node "$PARSER" "${FIXTURES}/does-not-exist.yml" 2>&1)"
rc=$?
assert_eq "66" "$rc" "missing manifest file is EX_NOINPUT"

out="$(node "$PARSER" 2>&1)"
rc=$?
assert_eq "64" "$rc" "no path argument is EX_USAGE"

test_summary
