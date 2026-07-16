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

# --- Blocker 1 regression: no predictable in-repo temp files; secure temp dir outside repo ---

# 14. Attacker plants a symlink at a predictable in-repo temp path pointing at a
#     sentinel victim file OUTSIDE the repo. Preflight must not follow it, must
#     not write in the repo, and must clean up its secure external temp dir.
repo="$(make_repo)"
cp "${FIXTURES}/valid.yml" "${repo}/squad-capabilities.yml"
sentinel_dir="$(make_repo)"
sentinel="${sentinel_dir}/victim.txt"
printf 'ORIGINAL_SENTINEL_CONTENT' > "$sentinel"
# Predictable paths the OLD vulnerable code used inside the repo working tree.
ln -s "$sentinel" "${repo}/.squad-capability-preflight-decoy"
mkdir -p "${repo}/.squad-capability-preflight-$$"
ln -s "$sentinel" "${repo}/.squad-capability-preflight-$$/manifest.json"
# Snapshot secure-temp namespace before running to prove trap cleanup afterwards.
tmp_base="${TMPDIR:-/tmp}"
before_tmp="$(ls -d "${tmp_base%/}"/squad-capability-preflight.* 2>/dev/null | sort)"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
after_tmp="$(ls -d "${tmp_base%/}"/squad-capability-preflight.* 2>/dev/null | sort)"
sentinel_after="$(cat "$sentinel")"
assert_eq "ORIGINAL_SENTINEL_CONTENT" "$sentinel_after" "blocker1: attacker sentinel outside repo is never written via predictable symlink"
assert_eq "$before_tmp" "$after_tmp" "blocker1: secure external temp dir is removed on exit (trap cleanup worked)"
# Remove the planted decoys, then assert no *fresh* preflight temp path was created in the repo.
rm -rf "${repo}/.squad-capability-preflight-decoy" "${repo}/.squad-capability-preflight-$$"
leftover="$(find "$repo" -maxdepth 1 -name '.squad-capability-preflight*' -print 2>/dev/null)"
assert_eq "" "$leftover" "blocker1: no predictable temp path is created inside the repo working tree"
rm -rf "$repo" "$sentinel_dir"

# 15. If a secure temp dir cannot be created (TMPDIR points nowhere), the script
#     must FAIL safely instead of silently using a predictable fallback.
repo="$(make_repo)"
cp "${FIXTURES}/satisfied.yml" "${repo}/squad-capabilities.yml"
out="$(TMPDIR="${repo}/definitely-not-a-real-tmpdir-xyz" bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "blocker1: fails safely (78) when no secure temp dir can be created"
assert_contains "$out" "secure private work directory" "blocker1: reports the secure-temp failure reason"
leftover="$(find "$repo" -maxdepth 1 -name '.squad-capability-preflight*' -print 2>/dev/null)"
assert_eq "" "$leftover" "blocker1: still creates nothing predictable in the repo on failure"
rm -rf "$repo"

# 16. A temp base that would resolve INSIDE the repo is refused (never lands a
#     temp workspace in the working tree), and nothing is left behind there.
repo="$(make_repo)"
cp "${FIXTURES}/satisfied.yml" "${repo}/squad-capabilities.yml"
mkdir -p "${repo}/inside-tmp"
out="$(TMPDIR="${repo}/inside-tmp" bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "blocker1: refuses a temp base that resolves inside the repo tree"
inside_leftover="$(find "${repo}/inside-tmp" -mindepth 1 -print 2>/dev/null)"
assert_eq "" "$inside_leftover" "blocker1: leaves nothing inside an in-repo temp base"
rm -rf "$repo"

# 17. A manifest declaring a required external service is rejected (required
#     services are unsupported: the worker will not probe reachability or open
#     egress). Preflight surfaces this as a blocking, actionable failure.
repo="$(make_repo)"
cp "${FIXTURES}/required-service.yml" "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "78" "$rc" "required service manifest: exits 78"
assert_contains "$out" "required must be false" "required service manifest: reports the unsupported required-service rule"
rm -rf "$repo"

# 18. An optional (required: false) service is advisory only and never blocks.
repo="$(make_repo)"
cp "${FIXTURES}/valid.yml" "${repo}/squad-capabilities.yml"
out="$(bash "$PREFLIGHT" "$repo" 2>&1)"
rc=$?
assert_eq "0" "$rc" "optional service manifest: exits 0"
assert_contains "$out" "external service (advisory only, not validated): postgres" "optional service manifest: surfaces the service as advisory"
rm -rf "$repo"

test_summary
