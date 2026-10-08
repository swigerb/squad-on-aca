#!/usr/bin/env bash
# Behavioural tests for worker/lib/squad-pr-content.sh and its integration
# into worker/entrypoint.sh's commit_and_push_if_needed (issue #130).
#
# WHY THIS SUITE EXISTS
#
# Before issue #130, every Squad on ACA pull request opened against whatever
# `GITHUB_BASE_BRANCH` happened to be baked into the ACA job template at
# deploy time -- commonly a stale "main" -- because none of the three dispatch
# paths (PowerShell CLI, Ralph/bash, GitHub Actions workflow) treated it as a
# per-execution value the ARM REST start body must always set. It also had no
# way for an agent, or a CLI caller, to give the pull request a meaningful
# title/body: every PR was "Remote Squad session <name>" / "Created by
# Azure-hosted Squad session <name>." unconditionally.
#
# Part 1 below unit-tests worker/lib/squad-pr-content.sh directly: the
# agent-supplied-file safety rules (symlink refusal, character caps, control
# character stripping, newline preservation in the body only), precedence
# resolution, the commit/push scrub, and the additive hook/exclude install.
#
# Part 2 extracts the REAL commit_and_push_if_needed from worker/entrypoint.sh
# (the same technique worker/tests/test_session_deadline.sh uses) and runs it
# against a real local git remote with a stubbed `gh`, to prove the base
# branch and title/body behaviour end to end: explicit branch, the
# repository's real default branch, a template-baked "main" being ignored, a
# missing base branch failing clearly instead of falling back silently, and
# every precedence/safety rule surviving the full pull request creation path.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
ENTRYPOINT="${WORKER_DIR}/entrypoint.sh"
PR_CONTENT_LIB="${WORKER_DIR}/lib/squad-pr-content.sh"
PUSH_LIB_SRC="${WORKER_DIR}/lib/squad-push.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps git

echo "== worker/lib/squad-pr-content.sh (issue #130) =="

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-pr-content-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT

git_quiet() { git -c init.defaultBranch=main -c user.email=test@example.com -c user.name=test "$@" >/dev/null 2>&1; }

log() { :; } # silence the library's own logging for the unit tests below; re-defined per-case when a test needs to assert on it.

# ===========================================================================
# 1. Reading .squad-pr/title and .squad-pr/body.md directly
# ===========================================================================
echo "-- 1. reading agent-supplied files --"

# shellcheck source=../lib/squad-pr-content.sh
source "$PR_CONTENT_LIB"

REPO1="${WORK}/repo1"
mkdir -p "${REPO1}/.squad-pr"

# -- absence --
rm -rf "${REPO1:?}/.squad-pr"
out="$(squad_pr_content_read_title "$REPO1" 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "no .squad-pr/title: returns 1 (absent, not refused)"
assert_eq "" "$out" "no .squad-pr/title: prints nothing"

# -- plain, well-formed files --
mkdir -p "${REPO1}/.squad-pr"
printf 'Fix #130: real pull request title\n' >"${REPO1}/.squad-pr/title"
printf '## Summary\n\nSome *markdown* body.\n\nSecond paragraph.\n' >"${REPO1}/.squad-pr/body.md"
title="$(squad_pr_content_read_title "$REPO1")"
assert_eq "Fix #130: real pull request title" "$title" "a well-formed .squad-pr/title is read verbatim (trailing newline trimmed)"
body="$(squad_pr_content_read_body "$REPO1")"
assert_eq "$(printf '## Summary\n\nSome *markdown* body.\n\nSecond paragraph.')" "$body" \
  "a well-formed .squad-pr/body.md is read verbatim, newlines preserved"

# -- title caps at 256 chars --
long_title="$(printf 'A%.0s' $(seq 1 400))"
printf '%s' "$long_title" >"${REPO1}/.squad-pr/title"
title="$(squad_pr_content_read_title "$REPO1")"
assert_eq "256" "${#title}" "a 400-char title is capped at 256 characters"
assert_eq "$(printf 'A%.0s' $(seq 1 256))" "$title" "...and the capped title is a true PREFIX, not truncated oddly"

# -- body caps at 60000 chars --
long_body="$(printf 'B%.0s' $(seq 1 70000))"
printf '%s' "$long_body" >"${REPO1}/.squad-pr/body.md"
body="$(squad_pr_content_read_body "$REPO1")"
assert_eq "60000" "${#body}" "a 70000-char body is capped at 60000 characters"

# -- embedded newlines in a title are collapsed to spaces (never multi-line) --
printf 'line one\nline two\nline three\n' >"${REPO1}/.squad-pr/title"
title="$(squad_pr_content_read_title "$REPO1")"
assert_eq "line one line two line three" "$title" \
  "a title with embedded newlines has them folded to spaces, never forging extra lines"

# -- control characters are stripped from both, but \n and \t survive in the body --
printf 'ti\x01tle\x1b[31m\n' >"${REPO1}/.squad-pr/title"
title="$(squad_pr_content_read_title "$REPO1")"
assert_eq "title[31m" "$title" "control characters (e.g. an ANSI escape byte, a SOH) are stripped from the title"
printf 'para one\x01\nSTILL\tindented\x07 line two\n\npara three\n' >"${REPO1}/.squad-pr/body.md"
body="$(squad_pr_content_read_body "$REPO1")"
assert_eq "$(printf 'para one\nSTILL\tindented line two\n\npara three')" "$body" \
  "control characters are stripped from the body while \\n and \\t are preserved"

# -- CRLF-authored body.md collapses to plain LF, no stray blank-looking line --
printf 'line one\r\nline two\r\n' >"${REPO1}/.squad-pr/body.md"
body="$(squad_pr_content_read_body "$REPO1")"
assert_eq "$(printf 'line one\nline two')" "$body" "a CRLF body.md collapses \\r\\n to plain \\n"

# -- an empty file resolves as absent (return 1), not as an empty-but-present title --
printf '' >"${REPO1}/.squad-pr/title"
out="$(squad_pr_content_read_title "$REPO1" 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "an empty .squad-pr/title is treated as absent"

# -- a whitespace-only title is also treated as absent after trimming --
printf '   \n' >"${REPO1}/.squad-pr/title"
out="$(squad_pr_content_read_title "$REPO1" 2>/dev/null)"; rc=$?
assert_eq "1" "$rc" "a whitespace-only .squad-pr/title is treated as absent"

echo "-- 2. symlink refusal --"

mkdir -p "${REPO1}/.squad-pr"
printf 'legit\n' >"${REPO1}/.squad-pr/title"
rm -f "${REPO1}/.squad-pr/title"
ln -s /etc/hostname "${REPO1}/.squad-pr/title"
out="$(squad_pr_content_read_title "$REPO1" 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" ".squad-pr/title being a symlink is REFUSED (rc=2), not followed"
assert_eq "" "$out" "...and nothing is printed -- the symlink target is never read"
rm -f "${REPO1}/.squad-pr/title"
printf 'legit\n' >"${REPO1}/.squad-pr/title"

rm -rf "${REPO1:?}/.squad-pr"
target_dir="${WORK}/symlink-target"
mkdir -p "$target_dir"
printf 'target title\n' >"${target_dir}/title"
ln -s "$target_dir" "${REPO1}/.squad-pr"
out="$(squad_pr_content_read_title "$REPO1" 2>/dev/null)"; rc=$?
assert_eq "2" "$rc" "a symlinked .squad-pr DIRECTORY itself is also refused, not just a symlinked leaf file"
rm -f "${REPO1}/.squad-pr"
mkdir -p "${REPO1}/.squad-pr"

echo "-- 3. precedence: env override > agent file > default (caller decides the default) --"

printf 'From agent file\n' >"${REPO1}/.squad-pr/title"
printf 'Agent body.\n' >"${REPO1}/.squad-pr/body.md"

resolved="$(squad_pr_content_resolve_title "$REPO1" "")"
assert_eq "From agent file" "$resolved" "no override: the agent-supplied title wins"
resolved="$(squad_pr_content_resolve_title "$REPO1" "From CLI/dispatch override")"
assert_eq "From CLI/dispatch override" "$resolved" "a non-empty override wins outright over the agent-supplied file"
resolved="$(squad_pr_content_resolve_body "$REPO1" "")"
assert_eq "Agent body." "$resolved" "no override: the agent-supplied body wins"
resolved="$(squad_pr_content_resolve_body "$REPO1" "From CLI/dispatch override body")"
assert_eq "From CLI/dispatch override body" "$resolved" "a non-empty override wins outright over the agent-supplied body file"

rm -rf "${REPO1:?}/.squad-pr"
resolved="$(squad_pr_content_resolve_title "$REPO1" "")"
assert_eq "" "$resolved" "no override and no agent file: resolves empty (the caller applies ITS OWN default text)"

echo "-- 4. scrub --"

mkdir -p "${REPO1}/repo-git"
(cd "${REPO1}/repo-git" && git_quiet init && mkdir -p .squad-pr && printf 't\n' >.squad-pr/title && printf 'b\n' >.squad-pr/body.md && echo ok >tracked.txt && git_quiet add -A)
squad_pr_content_scrub "${REPO1}/repo-git"
assert_eq "0" "$(cd "${REPO1}/repo-git" && git status --porcelain -- .squad-pr | wc -l | tr -d ' ')" \
  "scrub removes .squad-pr/ from BOTH the index and the worktree -- git status sees nothing left to report"
assert_eq "0" "$([[ -e "${REPO1}/repo-git/.squad-pr" ]] && echo 1 || echo 0)" \
  ".squad-pr/ no longer exists in the worktree after scrub"
# Idempotent: scrubbing an already-absent directory is a no-op, not an error.
squad_pr_content_scrub "${REPO1}/repo-git"
echo "ok - scrub on an already-scrubbed repo does not fail (set -e would have aborted this suite)"

echo "-- 5. hook install is additive --"

mkdir -p "${REPO1}/hookrepo"
(cd "${REPO1}/hookrepo" && git_quiet init)
squad_pr_content_install_hooks "${REPO1}/hookrepo"
for h in pre-commit pre-push; do
  assert_eq "1" "$([[ -x "${REPO1}/hookrepo/.git/hooks/${h}" ]] && echo 1 || echo 0)" \
    "squad_pr_content_install_hooks creates an executable ${h} hook"
  assert_contains "$(cat "${REPO1}/hookrepo/.git/hooks/${h}")" "$SQUAD_PR_CONTENT_HOOK_MARKER" \
    "...carrying the .squad-pr guard marker"
done

# Additive: an existing, unrelated pre-commit hook is PREPENDED to, not
# replaced -- its own logic must still run after the guard.
rm -rf "${REPO1:?}/hookrepo2"
mkdir -p "${REPO1}/hookrepo2"
(cd "${REPO1}/hookrepo2" && git_quiet init)
mkdir -p "${REPO1}/hookrepo2/.git/hooks"
cat >"${REPO1}/hookrepo2/.git/hooks/pre-commit" <<'EOF'
#!/bin/sh
echo "pre-existing hook ran" >"PRE_EXISTING_HOOK_RAN"
exit 0
EOF
chmod +x "${REPO1}/hookrepo2/.git/hooks/pre-commit"
squad_pr_content_install_hooks "${REPO1}/hookrepo2"
assert_contains "$(cat "${REPO1}/hookrepo2/.git/hooks/pre-commit")" "$SQUAD_PR_CONTENT_HOOK_MARKER" \
  "an existing pre-commit hook gets the .squad-pr guard PREPENDED"
assert_contains "$(cat "${REPO1}/hookrepo2/.git/hooks/pre-commit")" "pre-existing hook ran" \
  "...and the pre-existing hook's own logic is still present, not discarded"

# Idempotent: running install twice does not double-prepend.
squad_pr_content_install_hooks "${REPO1}/hookrepo2"
count="$(grep -c "$SQUAD_PR_CONTENT_HOOK_MARKER" "${REPO1}/hookrepo2/.git/hooks/pre-commit")"
assert_eq "1" "$count" "re-running install_hooks does not duplicate the guard in an already-guarded hook"

# The installed hooks actually refuse what they claim to. install_hooks also
# installs the local-only exclude (squad_pr_content_install_exclude), so a
# plain `git add .squad-pr/title` is already refused by git itself; `-f`
# here simulates an agent (or a hostile prompt injection) forcing it into the
# index anyway, which is exactly the case the pre-commit hook defends against.
mkdir -p "${REPO1}/hookrepo3/.squad-pr"
(cd "${REPO1}/hookrepo3" && git_quiet init && echo ok >tracked.txt && git_quiet add tracked.txt && git_quiet commit -m baseline)
squad_pr_content_install_hooks "${REPO1}/hookrepo3"
(cd "${REPO1}/hookrepo3" && printf 'sneaky\n' >.squad-pr/title && git add -f .squad-pr/title 2>/dev/null)
commit_out="$(cd "${REPO1}/hookrepo3" && git commit -m "try to commit .squad-pr" 2>&1)"; commit_rc=$?
assert_ne "0" "$commit_rc" "the installed pre-commit hook REFUSES a commit that stages .squad-pr/"
assert_contains "$commit_out" ".squad-pr/ is agent OUTPUT" "...with a clear explanation, not a silent/generic failure"

echo "-- 6. local-only exclude --"

mkdir -p "${REPO1}/excluderepo"
(cd "${REPO1}/excluderepo" && git_quiet init)
git_dir="$(cd "${REPO1}/excluderepo" && git rev-parse --absolute-git-dir)"
squad_pr_content_install_exclude "${REPO1}/excluderepo" "$git_dir"
assert_contains "$(cat "${git_dir}/info/exclude")" ".squad-pr/" \
  "squad_pr_content_install_exclude adds .squad-pr/ to the LOCAL-ONLY info/exclude"
# Idempotent.
squad_pr_content_install_exclude "${REPO1}/excluderepo" "$git_dir"
count="$(grep -cxF '.squad-pr/' "${git_dir}/info/exclude")"
assert_eq "1" "$count" "re-running install_exclude does not duplicate the entry"
mkdir -p "${REPO1}/excluderepo/.squad-pr"
printf 'x\n' >"${REPO1}/excluderepo/.squad-pr/title"
untracked="$(cd "${REPO1}/excluderepo" && git status --porcelain --ignored -- .squad-pr)"
assert_contains "$untracked" "!!" ".squad-pr/ shows as IGNORED (not merely untracked) once the exclude entry is in place"

echo "-- 6b. Squad 1.0 transient casting files are never published (issue #148) --"

CAST="${REPO1}/castingrepo"
mkdir -p "${CAST}/.squad/casting"
(cd "$CAST" && git_quiet init && git config user.email t@example.invalid && git config user.name t)
printf '{"agents":{}}\n' >"${CAST}/.squad/casting/registry.json"
printf '{"assignments":[]}\n' >"${CAST}/.squad/casting/history.json"
printf '{"registry_sha256":"x"}\n' >"${CAST}/.squad/casting/registry-history.commit.json"
(cd "$CAST" && git add -A && git_quiet commit -m base)
squad_casting_transient_install_exclude "$CAST"
squad_casting_transient_install_exclude "$CAST"
cast_exclude="$(cd "$CAST" && git rev-parse --path-format=absolute --git-path info/exclude)"
assert_eq "1" "$(grep -cxF '/.squad/casting/registry.lock' "$cast_exclude")" \
  "the casting lock exclude is installed exactly once, even when called twice"
# Every transient shape Squad 1.0.1's durable-registry.js creates.
mkdir -p "${CAST}/.squad/casting/registry.lock" \
         "${CAST}/.squad/casting/registry.lock.recovery" \
         "${CAST}/.squad/casting/registry.lock.stale-tok-uuid" \
         "${CAST}/.squad/casting/registry-history.transaction.1234.payload"
printf 'o\n' >"${CAST}/.squad/casting/registry.lock/owner.json"
printf 'p\n' >"${CAST}/.squad/casting/registry-history.transaction.1234.payload/registry.json"
printf 'j\n' >"${CAST}/.squad/casting/registry-history.transaction.json"
printf 't\n' >"${CAST}/.squad/casting/registry.json.tmp-tx-uuid"
printf 't\n' >"${CAST}/.squad/casting/registry-history.commit.json.tmp-tx-uuid"
cast_status="$(cd "$CAST" && git status --porcelain)"
assert_eq "" "$cast_status" \
  "with only Squad 1.0 transient casting files present, git sees NOTHING to publish (lock, recovery guard, quarantine, journal, payload, temp files)"
# The durable pair and its manifest are real team state: still tracked, still published.
printf '{"agents":{"lead":{}}}\n' >"${CAST}/.squad/casting/registry.json"
printf '{"registry_sha256":"y"}\n' >"${CAST}/.squad/casting/registry-history.commit.json"
cast_status="$(cd "$CAST" && git status --porcelain)"
assert_contains "$cast_status" ".squad/casting/registry.json" \
  "a real change to registry.json is still publishable (only transient files are excluded)"
assert_contains "$cast_status" ".squad/casting/registry-history.commit.json" \
  "a real change to the Squad 1.0 commit manifest is still publishable"
(cd "$CAST" && git add -A)
staged="$(cd "$CAST" && git diff --cached --name-only)"
assert_not_contains "$staged" "registry.lock" "git add -A never stages the casting lock"
assert_not_contains "$staged" "transaction" "git add -A never stages the casting transaction journal or payload"
assert_not_contains "$staged" ".tmp-" "git add -A never stages a durableReplace() temp file"
# Not a git checkout: best-effort, never fails the session.
mkdir -p "${REPO1}/not-a-repo"
squad_casting_transient_install_exclude "${REPO1}/not-a-repo"
assert_eq "0" "$?" "squad_casting_transient_install_exclude never fails the session, even outside a git checkout"

# ===========================================================================
# 7. End to end: the real commit_and_push_if_needed, a real local remote
# ===========================================================================
echo "-- 7. end to end: base branch + title/body through gh pr create --"

COMMIT_PUSH_FN="$(awk '/^commit_and_push_if_needed\(\) \{/,/^\}/' "$ENTRYPOINT")"
assert_ne "" "$COMMIT_PUSH_FN" "extracted commit_and_push_if_needed from worker/entrypoint.sh"

# make_remote_pair <base-dir> [extra-branch...]
# A bare "remote.git" with a 'main' branch and, optionally, extra branches
# created from the same initial commit -- enough to exercise an explicit
# release branch and a "the base branch does not exist" refusal.
make_remote_pair() {
  local base="$1"; shift
  rm -rf "$base"; mkdir -p "$base"
  git -C /tmp init -q --bare "${base}/remote.git" 2>/dev/null || git init -q --bare "${base}/remote.git"
  git_quiet clone "${base}/remote.git" "${base}/seed"
  (
    cd "${base}/seed"
    echo "original work" >src.txt
    git add -A
    git_quiet commit -m baseline
    git_quiet push origin HEAD:refs/heads/main
    local b
    for b in "$@"; do
      git_quiet checkout -b "$b"
      git_quiet push origin "HEAD:refs/heads/${b}"
      git_quiet checkout main
    done
  ) >/dev/null 2>&1
  git_quiet clone "${base}/remote.git" "${base}/client"
  git_quiet -C "${base}/client" checkout main
}

# make_gh_stub <bin-dir> <stub-dir>
# Records each `gh` call's argv, NUL-separated, resolving `--body-file <path>`
# to the FILE'S CONTENT (issue #130: the real worker now passes the body via
# a file, not a shell string, and the temp file is deleted immediately after
# the call -- so the stub must capture its content before that happens).
make_gh_stub() {
  local bin="$1" stub="$2"
  mkdir -p "$bin" "$stub"
  cat >"${bin}/gh" <<EOF
#!/usr/bin/env bash
n=\$(ls "${stub}" | grep -c '^gh-call-' || true)
args=()
capture_next_as_body=0
for a in "\$@"; do
  if [[ "\$capture_next_as_body" == 1 ]]; then
    args+=("\$(cat -- "\$a" 2>/dev/null)")
    capture_next_as_body=0
    continue
  fi
  args+=("\$a")
  [[ "\$a" == "--body-file" ]] && capture_next_as_body=1
done
printf '%s\n' "\${args[@]}" >"${stub}/gh-call-\$((n + 1))"
if [[ "\$1" == "pr" && "\$2" == "create" ]]; then
  echo "\${GH_PR_URL:-https://github.com/octo/repo/pull/42}"
fi
exit 0
EOF
  chmod +x "${bin}/gh"
}

# run_commit_push <name> [extra-remote-branches...] -- then set env vars and
# call with_env (below). Returns via globals: OUT (combined stdout+stderr),
# RC (exit code), CALLDIR (stub dir for gh_call()).
gh_call() { tr '\n' '|' <"${CALLDIR}/gh-call-$1" 2>/dev/null; }

with_env() {
  local base="${WORK}/$1"; shift
  local driver="${base}/driver.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf 'export PATH=%q:"$PATH"\n' "${base}/bin"
    # Isolation: unset every env var this suite's cases set deliberately, so
    # a real Squad on ACA session's OWN environment (this very test can run
    # inside one) never leaks into what is meant to be a clean per-case
    # environment -- a real session exports exactly these names for its own
    # publish, and inheriting them here would make every case silently
    # replay that session's values instead of the one under test.
    echo 'unset PR_TITLE PR_BODY GITHUB_BASE_BRANCH GITHUB_REF OUTPUT_BRANCH SQUAD_PR_REVIEWER SQUAD_SESSION_TIMED_OUT COMMIT_MESSAGE'
    echo 'log() { printf "[squad-on-aca] %s\n" "$*" >&2; }'
    echo 'unset SQUAD_POLICY_PIN_SEAL_MODE' # this suite is about base branch + title/body, not pin sealing (worker/tests/test_memory_audit_pin_*.sh covers that)
    echo 'squad_policy_checkpoint() { return 0; }'
    echo 'squad_policy_reported_changes_report() { printf "%s" "${FAKE_GOVERNANCE_REPORT:-}"; }'
    echo 'squad_credential_refresh_env() { return 0; }'
    echo 'squad_hub_report_pr_if_any() { return 0; }'
    printf 'source %q\n' "$PUSH_LIB_SRC" "$PR_CONTENT_LIB"
    printf '%s\n' "$COMMIT_PUSH_FN"
    printf 'REPO_DIR=%q\n' "${base}/client"
    echo 'cd "$REPO_DIR"'
    printf '%s\n' "$@"
    echo 'commit_and_push_if_needed'
    echo 'echo "RC=$?"'
  } >"$driver"
  chmod +x "$driver"
  OUT="$(bash "$driver" 2>&1)"
  RC="$?"
}

# -- Case A: dev default branch (no override) --------------------------------
make_remote_pair "${WORK}/a"
make_gh_stub "${WORK}/a/bin" "${WORK}/a/stub"
CALLDIR="${WORK}/a/stub"
(cd "${WORK}/a/client" && echo "agent change" >>src.txt)
with_env a \
  'export PUSH_CHANGES=true GITHUB_REPOSITORY=octo/repo SESSION_NAME=sess OUTPUT_BRANCH=squad/sess' \
  'export GITHUB_BASE_BRANCH=main GITHUB_REF=main'
assert_contains "$OUT" "RC=0" "dev default branch: the session succeeds"
assert_eq "pr|create|--repo|octo/repo|--base|main|--head|squad/sess|--title|Remote Squad session sess|--body-file|Created by Azure-hosted Squad session sess.|" \
  "$(gh_call 1)" "dev default branch: gh pr create targets 'main' -- the repository's real default branch"

# -- Case B: explicit release branch, not the template's main ---------------
make_remote_pair "${WORK}/b" "release/1.0"
make_gh_stub "${WORK}/b/bin" "${WORK}/b/stub"
CALLDIR="${WORK}/b/stub"
(cd "${WORK}/b/client" && echo "agent change" >>src.txt)
with_env b \
  'export PUSH_CHANGES=true GITHUB_REPOSITORY=octo/repo SESSION_NAME=sess OUTPUT_BRANCH=squad/sess' \
  'export GITHUB_BASE_BRANCH=release/1.0 GITHUB_REF=release/1.0'
assert_contains "$OUT" "RC=0" "explicit release branch: the session succeeds"
assert_contains "$(gh_call 1)" "--base|release/1.0|" "explicit release branch: gh pr create targets it, not main"

# -- Case C: a stale template-baked GITHUB_BASE_BRANCH is IGNORED when the ---
#    caller (the dispatch path, simulated here by the driver) resolves the
#    per-execution value correctly -- this proves the worker USES whatever
#    GITHUB_BASE_BRANCH it is given; the dispatch-side fix (session-env.ps1 /
#    ralph-dispatch.sh / squad-dispatch.yml) is what stops a stale template
#    value from reaching it at all, covered by their own suites.
make_remote_pair "${WORK}/c" "release/2.0"
make_gh_stub "${WORK}/c/bin" "${WORK}/c/stub"
CALLDIR="${WORK}/c/stub"
(cd "${WORK}/c/client" && echo "agent change" >>src.txt)
with_env c \
  'export PUSH_CHANGES=true GITHUB_REPOSITORY=octo/repo SESSION_NAME=sess OUTPUT_BRANCH=squad/sess' \
  'export GITHUB_BASE_BRANCH=release/2.0 GITHUB_REF=release/2.0'
assert_contains "$(gh_call 1)" "--base|release/2.0|" \
  "a correctly-resolved per-execution base branch wins -- never a leftover template value"

# -- Case D: the chosen base branch does not exist remotely -> fail clearly -
make_remote_pair "${WORK}/d"
make_gh_stub "${WORK}/d/bin" "${WORK}/d/stub"
CALLDIR="${WORK}/d/stub"
(cd "${WORK}/d/client" && echo "agent change" >>src.txt)
with_env d \
  'export PUSH_CHANGES=true GITHUB_REPOSITORY=octo/repo SESSION_NAME=sess OUTPUT_BRANCH=squad/sess' \
  'export GITHUB_BASE_BRANCH=does-not-exist GITHUB_REF=does-not-exist'
assert_not_contains "$OUT" "RC=0" "a base branch that does not exist remotely: the session does NOT succeed"
assert_contains "$OUT" "does not exist on origin" "...and says so clearly"
assert_eq "0" "$(ls "${WORK}/d/stub" 2>/dev/null | grep -c '^gh-call-' || true)" \
  "...never silently falling back to 'main' and opening a pull request anyway"

# -- Case E: title/body from agent-supplied .squad-pr/ files -----------------
make_remote_pair "${WORK}/e"
make_gh_stub "${WORK}/e/bin" "${WORK}/e/stub"
CALLDIR="${WORK}/e/stub"
(cd "${WORK}/e/client" && echo "agent change" >>src.txt && mkdir -p .squad-pr \
  && printf 'Fix #130: real title from the agent\n' >.squad-pr/title \
  && printf '## What changed\n\nAgent-authored body.\n' >.squad-pr/body.md)
with_env e \
  'export PUSH_CHANGES=true GITHUB_REPOSITORY=octo/repo SESSION_NAME=sess OUTPUT_BRANCH=squad/sess GITHUB_BASE_BRANCH=main GITHUB_REF=main'
assert_contains "$OUT" "RC=0" "agent-file title/body: the session succeeds"
assert_contains "$(gh_call 1)" "--title|Fix #130: real title from the agent|" \
  "agent-file title/body: gh pr create uses the agent-supplied title"
assert_contains "$(gh_call 1)" "## What changed" "...and the agent-supplied body"
assert_contains "$(gh_call 1)" "Agent-authored body." "...(full body content, not just a path)"
assert_eq "0" "$(cd "${WORK}/e/client" && git show HEAD --stat | grep -c '.squad-pr' || true)" \
  ".squad-pr/ never reaches the commit the worker makes"
remote_tip_files="$(git --git-dir="${WORK}/e/remote.git" ls-tree -r --name-only squad/sess 2>/dev/null)"
assert_not_contains "$remote_tip_files" ".squad-pr" ".squad-pr/ is not present in the pushed branch's tree either"

# -- Case F: CLI/dispatch override (PR_TITLE/PR_BODY) beats the agent file ---
make_remote_pair "${WORK}/f"
make_gh_stub "${WORK}/f/bin" "${WORK}/f/stub"
CALLDIR="${WORK}/f/stub"
(cd "${WORK}/f/client" && echo "agent change" >>src.txt && mkdir -p .squad-pr \
  && printf 'Agent title (should be overridden)\n' >.squad-pr/title \
  && printf 'Agent body (should be overridden)\n' >.squad-pr/body.md)
with_env f \
  'export PUSH_CHANGES=true GITHUB_REPOSITORY=octo/repo SESSION_NAME=sess OUTPUT_BRANCH=squad/sess GITHUB_BASE_BRANCH=main GITHUB_REF=main' \
  'export PR_TITLE="Fix #130: CLI-supplied title" PR_BODY="CLI-supplied body."'
assert_contains "$(gh_call 1)" "--title|Fix #130: CLI-supplied title|" \
  "CLI/dispatch PR_TITLE wins over an agent-supplied .squad-pr/title"
assert_contains "$(gh_call 1)" "CLI-supplied body." \
  "CLI/dispatch PR_BODY wins over an agent-supplied .squad-pr/body.md"
assert_not_contains "$(gh_call 1)" "should be overridden" \
  "...the agent's own text does not leak through anywhere"

# -- Case G: hostile agent-supplied files are sanitized, not rejected wholesale
make_remote_pair "${WORK}/g"
make_gh_stub "${WORK}/g/bin" "${WORK}/g/stub"
CALLDIR="${WORK}/g/stub"
(cd "${WORK}/g/client" && echo "agent change" >>src.txt && mkdir -p .squad-pr \
  && printf 'evil\x01title\nwith a newline\n' >.squad-pr/title)
python_long_body="$(printf 'X%.0s' $(seq 1 70000))"
(cd "${WORK}/g/client" && printf '%s' "$python_long_body" >.squad-pr/body.md)
with_env g \
  'export PUSH_CHANGES=true GITHUB_REPOSITORY=octo/repo SESSION_NAME=sess OUTPUT_BRANCH=squad/sess GITHUB_BASE_BRANCH=main GITHUB_REF=main'
assert_contains "$OUT" "RC=0" "hostile agent files: the session still succeeds (sanitized, not refused)"
call1="$(gh_call 1)"
assert_not_contains "$call1" $'\x01' "hostile title: the control byte never reaches gh"
assert_contains "$call1" "eviltitle with a newline" "hostile title: embedded newline folded to a space, control byte stripped"
body_len_check="$(printf '%s' "$call1" | grep -o 'X' | wc -l | tr -d ' ')"
assert_eq "60000" "$body_len_check" "hostile body: capped at 60000 chars even inside the full gh argv capture"

# -- Case H: a symlinked .squad-pr/title is refused -- falls back to default -
make_remote_pair "${WORK}/h"
make_gh_stub "${WORK}/h/bin" "${WORK}/h/stub"
CALLDIR="${WORK}/h/stub"
(cd "${WORK}/h/client" && echo "agent change" >>src.txt && mkdir -p .squad-pr \
  && ln -s /etc/hostname .squad-pr/title)
with_env h \
  'export PUSH_CHANGES=true GITHUB_REPOSITORY=octo/repo SESSION_NAME=sess OUTPUT_BRANCH=squad/sess GITHUB_BASE_BRANCH=main GITHUB_REF=main'
assert_contains "$OUT" "RC=0" "a symlinked .squad-pr/title: the session still succeeds"
assert_contains "$(gh_call 1)" "--title|Remote Squad session sess|" \
  "...refused -- falls back to the worker's own default title, the symlink target is never used"

# -- Case I: the governance report is ALWAYS appended, regardless of title/
#    body source -----------------------------------------------------------
make_remote_pair "${WORK}/i"
make_gh_stub "${WORK}/i/bin" "${WORK}/i/stub"
CALLDIR="${WORK}/i/stub"
(cd "${WORK}/i/client" && echo "agent change" >>src.txt && mkdir -p .squad-pr \
  && printf 'Custom title\n' >.squad-pr/title \
  && printf 'Custom narrative body.\n' >.squad-pr/body.md)
with_env i \
  'export PUSH_CHANGES=true GITHUB_REPOSITORY=octo/repo SESSION_NAME=sess OUTPUT_BRANCH=squad/sess GITHUB_BASE_BRANCH=main GITHUB_REF=main' \
  'export FAKE_GOVERNANCE_REPORT=$'"'"'\n\n## Reported-mutable governance changes\n\n- casting/registry.json'"'"
assert_contains "$(gh_call 1)" "Custom narrative body." \
  "governance report case: the agent's custom body is used as the base narrative"
assert_contains "$(gh_call 1)" "Reported-mutable governance changes" \
  "...and the governance report is appended after it, not replaced by it"
assert_contains "$(gh_call 1)" "casting/registry.json" "...with its actual content intact"
