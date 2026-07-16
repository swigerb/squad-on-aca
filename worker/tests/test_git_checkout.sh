#!/usr/bin/env bash
# Integration tests for worker/lib/git-checkout.sh.
#
# Uses REAL local git repositories (bare "origin" + shallow clones) — no network
# access. Exercises the shallow-clone checkout fallbacks that broke live ACA
# review validation, where a `git fetch origin <slash-branch>` populates only
# FETCH_HEAD and the naive `git checkout <ref>` / `git checkout -B <ref>
# origin/<ref>` both fail.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${WORKER_DIR}/lib/git-checkout.sh"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-git-checkout"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== git-checkout.sh =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

# Deterministic, isolated git identity/config for the whole suite.
export GIT_CONFIG_GLOBAL="${TEST_TMP_ROOT}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global user.name "Test" >/dev/null 2>&1 || true
git config --global user.email "test@example.com" >/dev/null 2>&1 || true

# shellcheck source=lib/git-checkout.sh
source "$LIB"

# Build a bare "origin" with main plus a slash-bearing branch and a tag. Use a
# file:// URL for clone/fetch so `--depth` is honored (git ignores --depth for
# plain local-path clones), faithfully reproducing the shallow-clone behavior
# that broke live ACA review validation.
ORIGIN="${TEST_TMP_ROOT}/origin.git"
ORIGIN_URL="file://${ORIGIN}"
SEED="${TEST_TMP_ROOT}/seed"
git init --quiet --bare "$ORIGIN"
git clone --quiet "$ORIGIN_URL" "$SEED"
(
  cd "$SEED"
  echo "main-1" > file.txt
  git add file.txt
  git commit --quiet -m "main commit 1"
  git push --quiet origin main

  git checkout --quiet -b review/cap-ok-20260716105335
  echo "review-1" > file.txt
  git commit --quiet -am "review commit"
  git push --quiet origin review/cap-ok-20260716105335

  git checkout --quiet main
  echo "main-2" > file.txt
  git commit --quiet -am "main commit 2"
  git tag v1.0.0
  git push --quiet origin main
  git push --quiet origin v1.0.0
)

fresh_clone() {
  # Shallow clone of origin/main, mirroring entrypoint.sh's initial clone.
  local dir="${TEST_TMP_ROOT}/clone-$$-${RANDOM}"
  git clone --quiet --depth 1 "$ORIGIN_URL" "$dir"
  printf '%s\n' "$dir"
}

# 1. Default branch (main) is already present from the shallow clone.
clone="$(fresh_clone)"
out="$( cd "$clone" && GIT_CLONE_DEPTH=1 checkout_github_ref "main" 2>&1 )"
rc=$?
branch="$( cd "$clone" && git rev-parse --abbrev-ref HEAD )"
head="$( cd "$clone" && cat file.txt )"
assert_eq "0" "$rc" "main: checkout succeeds"
assert_eq "main" "$branch" "main: HEAD is on main"
assert_eq "main-2" "$head" "main: has the latest main content"
rm -rf "$clone"

# 2. Slash-bearing temporary branch — the live ACA review regression. A shallow
#    fetch only populates FETCH_HEAD (no origin/<branch> tracking ref), so this
#    must resolve via the FETCH_HEAD fallback.
clone="$(fresh_clone)"
out="$( cd "$clone" && GIT_CLONE_DEPTH=1 checkout_github_ref "review/cap-ok-20260716105335" 2>&1 )"
rc=$?
branch="$( cd "$clone" && git rev-parse --abbrev-ref HEAD )"
head="$( cd "$clone" && cat file.txt )"
assert_eq "0" "$rc" "slash branch: checkout succeeds via FETCH_HEAD fallback"
assert_eq "review/cap-ok-20260716105335" "$branch" "slash branch: HEAD is on the review branch"
assert_eq "review-1" "$head" "slash branch: has the review branch content"
rm -rf "$clone"

# 3. Tag ref resolves and checks out (detached or named) at the tagged commit.
clone="$(fresh_clone)"
out="$( cd "$clone" && GIT_CLONE_DEPTH=1 checkout_github_ref "v1.0.0" 2>&1 )"
rc=$?
head="$( cd "$clone" && cat file.txt )"
assert_eq "0" "$rc" "tag: checkout succeeds"
assert_eq "main-2" "$head" "tag: content matches the tagged commit"
rm -rf "$clone"

# 4. A non-existent ref must FAIL loudly (non-zero) instead of silently staying
#    on the default branch's tree.
clone="$(fresh_clone)"
out="$( cd "$clone" && GIT_CLONE_DEPTH=1 checkout_github_ref "does/not/exist-9999" 2>&1 )"
rc=$?
assert_eq "1" "$rc" "missing ref: returns non-zero"
assert_contains "$out" "Unable to check out requested ref" "missing ref: logs an actionable failure"
rm -rf "$clone"

# 5. Empty ref is rejected before touching git.
clone="$(fresh_clone)"
out="$( cd "$clone" && checkout_github_ref "" 2>&1 )"
rc=$?
assert_eq "2" "$rc" "empty ref: returns 2"
rm -rf "$clone"

test_summary
