#!/usr/bin/env bash
# Unit tests for worker/lib/parse-capabilities.js
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PARSER="${WORKER_DIR}/lib/parse-capabilities.js"
FIXTURES="${TEST_DIR}/fixtures"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-parse"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== parse-capabilities.js =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

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
assert_contains "$out" 'must include a non-empty string "name"' "missing-fields.yml error names the problem"

out="$(node "$PARSER" "${FIXTURES}/missing-version.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "missing-version.yml is rejected"
assert_contains "$out" 'missing required top-level "version" field' "missing-version.yml reports missing version"

out="$(node "$PARSER" "${FIXTURES}/invalid-version.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "invalid-version.yml is rejected"
assert_contains "$out" 'unsupported manifest version 2' "invalid-version.yml reports supported versions"

out="$(node "$PARSER" "${FIXTURES}/invalid-required-type.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "invalid-required-type.yml is rejected"
assert_contains "$out" '"tools[0]".required must be a boolean' "invalid-required-type.yml reports boolean requirement"

out="$(node "$PARSER" "${FIXTURES}/wrong-tools-type.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "wrong-tools-type.yml is rejected"
assert_contains "$out" '"tools" must be a list' "wrong-tools-type.yml reports list requirement"

out="$(node "$PARSER" "${FIXTURES}/malformed-array-element.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "malformed-array-element.yml is rejected"
assert_contains "$out" 'contains unknown key "unexpected"' "malformed-array-element.yml reports unknown item key"

out="$(node "$PARSER" "${FIXTURES}/unknown-top-level.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "unknown-top-level.yml is rejected"
assert_contains "$out" 'manifest contains unknown key "unknown"' "unknown-top-level.yml reports unknown top-level key"

out="$(node "$PARSER" "${FIXTURES}/duplicate-top-level.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "duplicate-top-level.yml is rejected"
assert_contains "$out" 'duplicate key "version"' "duplicate-top-level.yml reports duplicate top-level keys"

out="$(node "$PARSER" "${FIXTURES}/duplicate-nested-required.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "duplicate-nested-required.yml is rejected"
assert_contains "$out" 'duplicate key "required"' "duplicate-nested-required.yml reports duplicate nested keys"

redacted_manifest="${TEST_TMP_ROOT}/redacted-malformed.yml"
leak_token="SECRET_TOKEN_SHOULD_NEVER_APPEAR_123"
printf 'version: 1\nthis line leaks %s\n' "$leak_token" > "$redacted_manifest"
out="$(node "$PARSER" "$redacted_manifest" 2>&1)"
rc=$?
assert_eq "65" "$rc" "malformed redaction fixture is rejected"
assert_contains "$out" 'Line 2' "malformed redaction fixture reports the line number"
assert_not_contains "$out" "$leak_token" "malformed redaction fixture does not leak raw manifest content"

tab_manifest="${TEST_TMP_ROOT}/tab-tool-name.yml"
printf 'version: 1\ntools:\n  - name: "git\t0\tshim"\n    required: true\n' > "$tab_manifest"
out="$(node "$PARSER" "$tab_manifest" 2>&1)"
rc=$?
assert_eq "65" "$rc" "tab-bearing tool identifier is rejected"
assert_contains "$out" 'unsupported characters' "tab-bearing tool identifier reports identifier validation"

control_manifest="${TEST_TMP_ROOT}/control-tool-name.yml"
printf 'version: 1\ntools:\n  - name: "git\vsneaky"\n    required: true\n' > "$control_manifest"
out="$(node "$PARSER" "$control_manifest" 2>&1)"
rc=$?
assert_eq "65" "$rc" "control-character tool identifier is rejected"
assert_contains "$out" 'unsupported characters' "control-character tool identifier reports identifier validation"

out="$(node "$PARSER" "${FIXTURES}/does-not-exist.yml" 2>&1)"
rc=$?
assert_eq "66" "$rc" "missing manifest file is EX_NOINPUT"

out="$(node "$PARSER" 2>&1)"
rc=$?
assert_eq "64" "$rc" "no path argument is EX_USAGE"

test_summary
