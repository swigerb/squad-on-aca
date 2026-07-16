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
assert_contains "$out" 'unsupported manifest version (redacted); supported versions: 1' "invalid-version.yml reports supported versions safely"
assert_not_contains "$out" '2' "invalid-version.yml does not echo the raw manifest version"

large_version_manifest="${TEST_TMP_ROOT}/oversized-version.yml"
large_version_raw="90071992547409919551"
large_version_rounded="$(node -e 'process.stdout.write(String(Number(process.argv[1])))' "$large_version_raw")"
printf 'version: %s\ntools:\n  - name: git\n    required: true\n' "$large_version_raw" > "$large_version_manifest"
out="$(node "$PARSER" "$large_version_manifest" 2>&1)"
rc=$?
assert_eq "65" "$rc" "oversized version manifest is rejected"
assert_not_contains "$out" "$large_version_raw" "oversized version manifest does not echo the raw manifest version"
assert_not_contains "$out" "$large_version_rounded" "oversized version manifest does not echo the rounded JS value"
assert_contains "$out" 'unsupported manifest version (redacted); supported versions: 1' "oversized version manifest still reports supported versions safely"

out="$(node "$PARSER" "${FIXTURES}/invalid-required-type.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "invalid-required-type.yml is rejected"
assert_contains "$out" '"tools[0]".required must be a boolean' "invalid-required-type.yml reports boolean requirement"

out="$(node "$PARSER" "${FIXTURES}/wrong-tools-type.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "wrong-tools-type.yml is rejected"
assert_contains "$out" '"tools" must be a list' "wrong-tools-type.yml reports list requirement"

out="$(node "$PARSER" "${FIXTURES}/required-service.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "required-service.yml is rejected (required services unsupported)"
assert_contains "$out" '"services[0]".required must be false' "required-service.yml reports the unsupported required-service rule"
assert_contains "$out" 'required external services are not supported' "required-service.yml explains why required services are unsupported"

out="$(node "$PARSER" "${FIXTURES}/malformed-array-element.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "malformed-array-element.yml is rejected"
assert_contains "$out" 'contains an unrecognized key (redacted) at line 5' "malformed-array-element.yml reports unknown item key by safe location, not raw key"
assert_not_contains "$out" 'unexpected' "malformed-array-element.yml does not echo the raw unknown key name"

out="$(node "$PARSER" "${FIXTURES}/unknown-top-level.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "unknown-top-level.yml is rejected"
assert_contains "$out" 'manifest contains an unrecognized key (redacted) at line 2' "unknown-top-level.yml reports unknown top-level key by safe location, not raw key"
assert_not_contains "$out" '"unknown"' "unknown-top-level.yml does not echo the raw unknown key name"

out="$(node "$PARSER" "${FIXTURES}/duplicate-top-level.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "duplicate-top-level.yml is rejected"
assert_contains "$out" 'duplicate key (redacted) in the manifest (first seen at line 1)' "duplicate-top-level.yml reports duplicate top-level keys by safe location, not raw key"
assert_not_contains "$out" 'duplicate key "version"' "duplicate-top-level.yml does not echo the raw duplicate key name"

out="$(node "$PARSER" "${FIXTURES}/duplicate-nested-required.yml" 2>&1)"
rc=$?
assert_eq "65" "$rc" "duplicate-nested-required.yml is rejected"
assert_contains "$out" 'duplicate key (redacted) in list item in "tools" (first seen at line 4)' "duplicate-nested-required.yml reports duplicate nested keys by safe location, not raw key"
assert_not_contains "$out" 'duplicate key "required"' "duplicate-nested-required.yml does not echo the raw duplicate key name"

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

# --- Blocker 2 regression: never echo raw unknown/duplicate keys or secret values ---

# An unknown top-level key whose value looks like a leaked secret: neither the
# raw key name nor the secret value may appear anywhere in the error output.
secret_key_manifest="${TEST_TMP_ROOT}/unknown-secret-key.yml"
secret_value="sk-super-secret-value-12345"
printf 'version: 1\napi_key_totally_secret: "%s"\n' "$secret_value" > "$secret_key_manifest"
out="$(node "$PARSER" "$secret_key_manifest" 2>&1)"
rc=$?
assert_eq "65" "$rc" "unknown secret-looking key is rejected"
assert_not_contains "$out" "$secret_value" "unknown secret key: raw secret value is never echoed"
assert_not_contains "$out" "api_key_totally_secret" "unknown secret key: raw key name is never echoed"
assert_contains "$out" "unrecognized key (redacted) at line 2" "unknown secret key: safe redacted location is still reported"

# A key carrying control characters (ANSI colour + bell + CR) must not leak any
# raw control byte into the error output (log/terminal-injection defense), while
# still reporting the correct line number.
esc=$'\x1b'
bel=$'\x07'
cr=$'\r'
control_inject_manifest="${TEST_TMP_ROOT}/control-inject-key.yml"
printf 'version: 1\nevil%s[31m%skey: boom\n' "$esc" "$bel" > "$control_inject_manifest"
out="$(node "$PARSER" "$control_inject_manifest" 2>&1)"
rc=$?
assert_eq "65" "$rc" "control-character injected key is rejected"
assert_not_contains "$out" "$esc" "control-char key: no raw ESC (ANSI) byte appears in output"
assert_not_contains "$out" "$bel" "control-char key: no raw BEL byte appears in output"
assert_not_contains "$out" "$cr" "control-char key: no raw CR byte appears in output"
assert_contains "$out" "line 2" "control-char key: correct line number is still reported"

# A control-character-bearing value in a validated name field: the value must be
# rejected without echoing the raw control bytes.
control_value_manifest="${TEST_TMP_ROOT}/control-value.yml"
printf 'version: 1\ntools:\n  - name: "git%s[31mred"\n    required: true\n' "$esc" > "$control_value_manifest"
out="$(node "$PARSER" "$control_value_manifest" 2>&1)"
rc=$?
assert_eq "65" "$rc" "control-character value is rejected"
assert_not_contains "$out" "$esc" "control-char value: no raw ESC byte appears in output"
assert_contains "$out" 'unsupported characters' "control-char value: reports safe validation message"

# A duplicate key whose name is itself sensitive-looking: only safe location
# info may be reported, never the raw duplicated key name.
dup_secret_manifest="${TEST_TMP_ROOT}/duplicate-secret-key.yml"
printf 'version: 1\ntools:\n  - name: git\n    secret_dup_marker_key: a\n    secret_dup_marker_key: b\n' > "$dup_secret_manifest"
out="$(node "$PARSER" "$dup_secret_manifest" 2>&1)"
rc=$?
assert_eq "65" "$rc" "duplicate sensitive-looking key is rejected"
assert_not_contains "$out" "secret_dup_marker_key" "duplicate key: raw duplicated key name is never echoed"
assert_contains "$out" "duplicate key (redacted)" "duplicate key: reports redacted, safe location info"
assert_contains "$out" "first seen at line 4" "duplicate key: reports first-seen line for triage"

out="$(node "$PARSER" "${FIXTURES}/does-not-exist.yml" 2>&1)"
rc=$?
assert_eq "66" "$rc" "missing manifest file is EX_NOINPUT"

out="$(node "$PARSER" 2>&1)"
rc=$?
assert_eq "64" "$rc" "no path argument is EX_USAGE"

test_summary
