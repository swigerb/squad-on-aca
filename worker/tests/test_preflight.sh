#!/usr/bin/env bash
# Integration tests for worker/lib/squad-capability-preflight.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
PREFLIGHT="${WORKER_DIR}/lib/squad-capability-preflight.sh"
FIXTURES="${TEST_DIR}/fixtures"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-preflight"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== squad-capability-preflight.sh =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

make_repo() {
  local dir="${TEST_TMP_ROOT}/repo-$$-${RANDOM}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# 1. No manifest present -> backward-compatible no-op.
repo="$(make_repo)"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "0" "$rc" "no manifest present: exits 0"
assert_contains "$out" "skipping" "no manifest present: explains the no-op"
rm -rf "$repo"

# 2. Manifest present, all required tools satisfied.
repo="$(make_repo)"
cp "${FIXTURES}/satisfied.yml" "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "0" "$rc" "satisfied manifest: exits 0"
assert_contains "$out" "passed" "satisfied manifest: reports pass"
rm -rf "$repo"

# 3. Manifest present, required tool missing -> blocking failure.
repo="$(make_repo)"
cp "${FIXTURES}/missing-required-tool.yml" "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "missing required tool: exits 78 (EX_CONFIG)"
assert_contains "$out" "Unsupported required tool: definitely-not-installed-binary" "missing required tool: names the tool"
assert_contains "$out" "docs/capability-manifest.md" "missing required tool: points at documentation"
rm -rf "$repo"

# 4. Manifest present, required credential missing -> blocking failure.
repo="$(make_repo)"
cp "${FIXTURES}/missing-required-credential.yml" "${repo}/squad-capabilities.yml"
unset NPM_TOKEN 2>/dev/null || true
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "missing required credential: exits 78"
assert_contains "$out" "Missing required credential: NPM_TOKEN" "missing required credential: names the credential"
rm -rf "$repo"

# 5. Same manifest, credential now provided -> passes.
repo="$(make_repo)"
cp "${FIXTURES}/missing-required-credential.yml" "${repo}/squad-capabilities.yml"
out="$(NPM_TOKEN=set-for-test bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "0" "$rc" "credential provided via env: exits 0"
rm -rf "$repo"

# 6. Optional (non-required) gaps are advisory only, never block.
repo="$(make_repo)"
cp "${FIXTURES}/valid.yml" "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "0" "$rc" "optional gaps in valid.yml: exits 0"
assert_contains "$out" "Advisory" "optional gaps in valid.yml: prints advisory section"
assert_contains "$out" "some-tool-that-does-not-exist-xyz" "optional gaps in valid.yml: mentions optional missing tool"
rm -rf "$repo"

# 7. SKIP_CAPABILITY_PREFLIGHT=true bypasses even a failing manifest.
repo="$(make_repo)"
cp "${FIXTURES}/missing-required-tool.yml" "${repo}/squad-capabilities.yml"
out="$(SKIP_CAPABILITY_PREFLIGHT=true bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "0" "$rc" "SKIP_CAPABILITY_PREFLIGHT=true: bypasses failing manifest"
rm -rf "$repo"

# 8. Malformed manifest is a blocking, actionable failure.
repo="$(make_repo)"
cp "${FIXTURES}/malformed.yml" "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "malformed manifest: exits 78"
assert_contains "$out" "malformed" "malformed manifest: says so"
rm -rf "$repo"

# 9. Custom manifest path via CAPABILITY_MANIFEST_PATH is honored.
repo="$(make_repo)"
mkdir -p "${repo}/config"
cp "${FIXTURES}/satisfied.yml" "${repo}/config/capabilities.yml"
out="$(CAPABILITY_MANIFEST_PATH="config/capabilities.yml" bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "0" "$rc" "custom manifest path: exits 0"
assert_contains "$out" "config/capabilities.yml" "custom manifest path: is reflected in logs"
rm -rf "$repo"

# 10. Manifest symlinks that escape the repo are rejected safely.
repo="$(make_repo)"
outside_dir="$(make_repo)"
secret_payload="OUTSIDE_SECRET_SHOULD_NEVER_APPEAR_456"
printf 'version: 1\nnotes: %s\n' "$secret_payload" > "${outside_dir}/outside.yml"
ln -s "${outside_dir}/outside.yml" "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "symlink escape manifest: exits 78"
assert_contains "$out" "invalid or unsafe" "symlink escape manifest: reports a generic safe error"
assert_not_contains "$out" "$secret_payload" "symlink escape manifest: does not leak target content"
rm -rf "$repo" "$outside_dir"

# 11. Malformed manifest content is redacted from preflight output.
repo="$(make_repo)"
leak_token="MANIFEST_SECRET_SHOULD_NEVER_APPEAR_789"
printf 'version: 1\nbad line %s\n' "$leak_token" > "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "malformed manifest redaction: exits 78"
assert_contains "$out" "Capability manifest is malformed" "malformed manifest redaction: remains actionable"
assert_not_contains "$out" "$leak_token" "malformed manifest redaction: does not leak raw manifest content"
rm -rf "$repo"

# 12. Tab-bearing identifiers are rejected before any delimiter-based serialization.
repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: "git\t0\toptional-smuggle"\n    required: true\n' > "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "tab-bearing identifier manifest: exits 78"
assert_contains "$out" "unsupported characters" "tab-bearing identifier manifest: is rejected during validation"
rm -rf "$repo"

# 13. Control-character identifiers are rejected before any downstream handling.
repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: "git\vsneaky"\n    required: true\n' > "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "control-character identifier manifest: exits 78"
assert_contains "$out" "unsupported characters" "control-character identifier manifest: is rejected during validation"
rm -rf "$repo"

test_summary
