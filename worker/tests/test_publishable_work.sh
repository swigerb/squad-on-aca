#!/usr/bin/env bash
# Behavioural tests for squad_session_has_publishable_work (worker/lib/squad-push.sh).
#
# Regression: an unattended session (dispatch source 'api') is denied
# `git push` and `gh pr`, so the agent committed its finished feature locally
# and stopped. The worker only looked at the working tree, saw it clean, logged
# "No changes to push." and the container exited with the work inside it.
# Case D is that exact shape.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps git

echo "== squad_session_has_publishable_work =="

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-publishable-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

export HOME="${WORK}/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
printf '[user]\n\temail = t@example.com\n\tname = t\n[init]\n\tdefaultBranch = main\n' >"$GIT_CONFIG_GLOBAL"
cd "$WORK" || exit 1

# shellcheck source=lib/squad-push.sh
source "${WORKER_DIR}/lib/squad-push.sh"

# A repo with one commit, as the worker sees it right after clone + checkout.
make_repo() {
  local dir="$1"
  git init -q "$dir"
  (cd "$dir" && echo one >f && git add -A && git commit -qm base)
}

verdict() {
  if squad_session_has_publishable_work "$1" "$2"; then echo publish; else echo nothing; fi
}

# A: clean tree, HEAD unchanged -> nothing to publish.
make_repo "${WORK}/a"
base_a="$(git -C "${WORK}/a" rev-parse HEAD)"
assert_eq "nothing" "$(verdict "${WORK}/a" "$base_a")" "A: an untouched checkout has nothing to publish"

# B: a modified tracked file.
make_repo "${WORK}/b"
base_b="$(git -C "${WORK}/b" rev-parse HEAD)"
echo two >"${WORK}/b/f"
assert_eq "publish" "$(verdict "${WORK}/b" "$base_b")" "B: a modified tracked file is published"

# C: only a new untracked file. `git diff` cannot see this.
make_repo "${WORK}/c"
base_c="$(git -C "${WORK}/c" rev-parse HEAD)"
echo new >"${WORK}/c/new.js"
assert_eq "publish" "$(verdict "${WORK}/c" "$base_c")" "C: an untracked-only change is published"

# D: the agent committed its work on its own branch and left a clean tree.
make_repo "${WORK}/d"
base_d="$(git -C "${WORK}/d" rev-parse HEAD)"
(cd "${WORK}/d" && git checkout -qb feature/x && echo feat >g && git add -A && git commit -qm feat)
assert_eq "" "$(git -C "${WORK}/d" status --porcelain)" "D: precondition, the agent left a clean tree"
assert_eq "publish" "$(verdict "${WORK}/d" "$base_d")" "D: commits the agent made itself are published"

# E: a gitignored file only -> nothing to publish.
make_repo "${WORK}/e"
(cd "${WORK}/e" && printf 'tmp/\n' >.gitignore && git add -A && git commit -qm ignore)
base_e="$(git -C "${WORK}/e" rev-parse HEAD)"
mkdir -p "${WORK}/e/tmp" && echo x >"${WORK}/e/tmp/scratch"
assert_eq "nothing" "$(verdict "${WORK}/e" "$base_e")" "E: ignored scratch output alone is not published"

# F: unborn branch (new-project), no base. Nothing yet, then an agent commit.
git init -q "${WORK}/f"
assert_eq "nothing" "$(verdict "${WORK}/f" "")" "F: an empty unborn repo has nothing to publish"
(cd "${WORK}/f" && echo boot >README.md && git add -A && git commit -qm boot)
assert_eq "publish" "$(verdict "${WORK}/f" "")" "F: an agent commit on an unborn branch is published"

# G: an attended agent that was allowed to push already published its own
# commits. Publishing them again would open a duplicate pull request.
git init -q --bare "${WORK}/g-remote.git"
git clone -q "${WORK}/g-remote.git" "${WORK}/g" 2>/dev/null
(cd "${WORK}/g" && echo one >f && git add -A && git commit -qm base && git push -q origin HEAD:main 2>/dev/null)
base_g="$(git -C "${WORK}/g" rev-parse HEAD)"
(cd "${WORK}/g" && git checkout -qb feature/y && echo feat >g && git add -A && git commit -qm feat)
assert_eq "publish" "$(verdict "${WORK}/g" "$base_g")" "G: a local-only agent commit is published"
git -C "${WORK}/g" push -q origin feature/y 2>/dev/null
assert_eq "nothing" "$(verdict "${WORK}/g" "$base_g" 2>/dev/null)" "G: commits the agent already pushed are not published twice"
echo more >"${WORK}/g/h"
assert_eq "publish" "$(verdict "${WORK}/g" "$base_g")" "G: uncommitted work left after its own push is still published"

# The prompt note: present exactly when the worker is the one publishing.
note="$(PUSH_CHANGES=true squad_publish_contract_note)"
assert_contains "$note" "Do not run git push or gh pr" "note: tells the agent not to push or open a PR"
assert_contains "$note" "worker pushes the branch and opens the pull request" "note: says who publishes instead"
assert_eq "" "$(PUSH_CHANGES=false squad_publish_contract_note)" "note: absent when the worker will not publish"
assert_eq "" "$(unset PUSH_CHANGES; squad_publish_contract_note)" "note: absent when PUSH_CHANGES is unset"

test_summary
