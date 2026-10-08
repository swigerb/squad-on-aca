#!/usr/bin/env bash
# Issue #113 (follow-up): the memory-audit-pin PUBLICATION leak.
#
# worker/lib/squad-policy.sh pins `.squad/memory/config.json`'s
# `policy.auditMaxBytes` to 0 for the whole session, so squad-sdk's own
# rotateAuditIfNeeded() never renames the append-only `.squad/memory/
# audit.jsonl` -- a rotation would otherwise look exactly like the agent
# deleting its own audit trail to the append-only detector in
# squad_policy_verify. That part was always correct.
#
# What was WRONG: squad_policy_harden used to COMMIT the pin, before
# SQUAD_POLICY_BASE_COMMIT was ever captured, on the theory that an
# uncommitted change to a LOCKED path sitting in the working tree at session
# start would be swept into the session's own `git add -A && git commit` and
# flagged by detector (c) as a violation the CONTROL caused. That reasoning
# was right about detector (c) and wrong about everything downstream: the
# commit it produced is ANCESTRY. Every branch this container, or an agent
# running `squad watch`/`squad loop`, ever pushed carried that commit
# forward, so the pin shipped in the net diff of every published PR -- a
# real `auditMaxBytes: 1048576 -> 0` change with no corresponding agent
# action. Live evidence: swigerb/arcade-hall-of-fame#7.
#
# The fix, squad_policy_seal_memory_audit_config_pin (worker/lib/squad-
# policy.sh), never commits the pin. It keeps it in the WORKING TREE only
# (squad-sdk 0.13.1 reads `.squad/memory/config.json` off disk, never from
# git) and seals it out of git staging instead. The two seals differ in
# strength: reset + --skip-worktree when the path is tracked at HEAD is an
# INDEX property ordinary porcelain cannot undo; `rm --cached` + a
# `.git/info/exclude` entry when it is not is only an IGNORE RULE, which a
# deliberate `git add -f`, a `.gitignore` negation or `git clean -x` can
# defeat. Those defeats are covered by continuous detection (the in-session
# sampler, worker/squad-agent's per-iteration check, squad_policy_verify),
# a re-pin of a deleted file, worker-generated pre-commit/pre-push hooks, and
# the push backstop in squad_push_branch -- section (e) below.
#
# WHAT THIS SUITE PROVES, with REAL git repositories and the REAL functions
# from worker/lib/squad-policy.sh and worker/entrypoint.sh (no mocks, no
# reimplementation):
#
#   (a) a prompt-mode session (REPO_DIR pushed by THIS container, via the
#       real commit_and_push_if_needed extracted from worker/entrypoint.sh)
#       publishes a branch whose `.squad/memory/config.json` is IDENTICAL to
#       the branch it started from -- no diff, no `chore(governance)`
#       commit -- while the working tree still holds the pin;
#   (b) a watch/loop-style session, where the AGENT runs its own ordinary
#       `git add -A && git commit` and its own push (there is no
#       commit_and_push_if_needed call on that path at all), publishes no
#       pin either -- for the ordinary case; the deliberate defeats are (e);
#   (c) an agent that defeats the seal -- rewrites the file's content,
#       clears --skip-worktree and commits, strips the exclude line and
#       commits, or clears either control without committing -- is still
#       caught, by the pre-existing manifest/detector(c) checks or by the
#       new seal-integrity check in squad_policy_verify; and a repository
#       `.gitignore` containing a `!.squad/memory/config.json` negation
#       (which overrides `.git/info/exclude` -- confirmed by direct
#       experiment, not assumed) makes squad_policy_harden itself refuse to
#       run, rather than silently seal nothing;
#   (d) against the REAL @bradygaster/squad-sdk 0.13.1 shipped by worker/
#       Dockerfile (not a mock of its rotation logic): 1100 real
#       LocalMemoryStore.audit() calls against a hardened repository never
#       produce an `audit.1.jsonl`, and the SAME loop against an
#       UNHARDENED repository (the control) DOES rotate -- so the hardened
#       case's absence of rotation is evidence, not a fluke of the harness.
#       (R-CI: this scenario, and (e4) below, moved to the sibling suite
#       test_memory_audit_pin_rotation.sh -- the three 1100-call loops
#       together pushed this suite's combined runtime past run-tests.sh's
#       per-suite budget. See that file's header.)
#   (e0) the SDK-default constant the in-session sampler uses to classify a
#       re-created config.json is byte-identical to what the REAL squad-sdk
#       0.13.1 writes via ensureInitialized() -- this still needs the real
#       SDK, which is why the import prelude stays in this file.
#
#   (R-CI, security re-review): the full security-review scenario (e) --
#   untracked-seal defeats/re-pin (e1-e5), and hooks/push-backstop/wrapper-
#   gate enforcement including R5's mid-range-commit proof (e6-e9, e8b) --
#   moved out of this file into two sibling suites so each file comfortably
#   clears run-tests.sh's per-suite budget:
#     - test_memory_audit_pin_seal_defeats.sh  (e1, e2, e3, e3b, e3c, e4b,
#       e4c, e5)
#     - test_memory_audit_pin_hooks.sh          (e6, e7, e8, e8b, e9)
#   and the two REAL-SDK 1100-call rotation loops ((d), (e4)) moved into
#   test_memory_audit_pin_rotation.sh. See each file's header for exactly
#   what it proves; this file now covers only (a), (b), (c1-c6), (e0).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
ENTRYPOINT="${WORKER_DIR}/entrypoint.sh"
SQUAD_POLICY_SH="${WORKER_DIR}/lib/squad-policy.sh"
CRED_LIB_SRC="${WORKER_DIR}/lib/squad-credentials.sh"
PUSH_LIB_SRC="${WORKER_DIR}/lib/squad-push.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum

echo "== memory-audit-pin PUBLICATION leak (issue #113 follow-up) =="

[[ -f "$ENTRYPOINT" ]] || { echo "FAIL: worker/entrypoint.sh is missing"; exit 1; }
[[ -f "$SQUAD_POLICY_SH" ]] || { echo "FAIL: worker/lib/squad-policy.sh is missing"; exit 1; }

# Same posture as test_governance_guard.sh: the preventive half of this fix is
# POSIX mode bits (squad_policy_harden's `chmod -R a-w`), which root ignores.
# A run as root cannot answer "is the seal real?", so it reports a skip
# rather than a pass.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_memory_audit_pin_publication.sh — running as root, mode bits are not enforced against uid 0"
  exit 77
fi

# ---------------------------------------------------------------------------
# Locate the REAL @bradygaster/squad-sdk 0.13.1 for scenario (d). SQUAD_SDK_DIR
# is what CI sets (see .github/workflows/worker-tests.yml); locally, the
# nested copy squad-cli@0.13.1 ships is used as a fallback. Neither present,
# or the wrong major.minor, is a genuine missing dependency -- same posture as
# lib/deps.sh: report a visible SKIP, never a silent pass that proves less
# than this suite claims.
locate_sdk() {
  local candidate base
  if [[ -n "${SQUAD_SDK_DIR:-}" && -f "${SQUAD_SDK_DIR}/dist/memory/index.js" && -f "${SQUAD_SDK_DIR}/dist/storage/fs-storage-provider.js" ]]; then
    printf '%s' "$SQUAD_SDK_DIR"
    return 0
  fi
  # Issue #148: the worker image installs Squad from the release bundle at
  # /opt/squad (worker/Dockerfile), so that is the first local fallback.
  candidate="/opt/squad/app/node_modules/@bradygaster/squad-sdk"
  if [[ -f "${candidate}/dist/memory/index.js" && -f "${candidate}/dist/storage/fs-storage-provider.js" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  base="$(npm root -g 2>/dev/null)" || base=""
  if [[ -n "$base" ]]; then
    # A Windows-style path (e.g. under Git Bash or WSL's interop npm) needs
    # translating to the path this bash actually sees.
    if [[ "$base" =~ ^[A-Za-z]: ]] && command -v wslpath >/dev/null 2>&1; then
      base="$(wslpath -u "$base" 2>/dev/null)" || base=""
    fi
    for candidate in \
      "${base}/@bradygaster/squad-cli/node_modules/@bradygaster/squad-sdk" \
      "${base}/@bradygaster/squad-sdk"
    do
      if [[ -n "$base" && -f "${candidate}/dist/memory/index.js" && -f "${candidate}/dist/storage/fs-storage-provider.js" ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  fi
  return 1
}

SDK_DIR=""
if SDK_DIR="$(locate_sdk)"; then
  SDK_VERSION="$(node -e 'console.log(require(require("path").join(process.argv[1], "package.json")).version)' "$SDK_DIR" 2>/dev/null || true)"
  # Issue #148: lockstep with what worker/Dockerfile actually ships (its
  # SQUAD_VERSION ARG), not a hard-coded version that could silently drift.
  EXPECTED_SQUAD_VERSION="$(sed -n 's/^ARG SQUAD_VERSION=//p' "${WORKER_DIR}/Dockerfile" | head -n 1)"
  if [[ -z "$EXPECTED_SQUAD_VERSION" || "$SDK_VERSION" != "$EXPECTED_SQUAD_VERSION" ]]; then
    echo "SKIP: test_memory_audit_pin_publication.sh — @bradygaster/squad-sdk at ${SDK_DIR} is '${SDK_VERSION:-unknown}', not ${EXPECTED_SQUAD_VERSION:-<unknown>} (the version worker/Dockerfile ships); scenario (d) needs the real rotation logic this pin relies on"
    exit 77
  fi
else
  echo "SKIP: test_memory_audit_pin_publication.sh — the @bradygaster/squad-sdk that worker/Dockerfile ships was not found (set SQUAD_SDK_DIR to <bundle>/app/node_modules/@bradygaster/squad-sdk, or see .github/workflows/worker-tests.yml for how CI installs it)"
  exit 77
fi

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-pin-publication-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global user.name "Test" >/dev/null 2>&1 || true
git config --global user.email "test@example.com" >/dev/null 2>&1 || true

git_quiet() { git -c advice.detachedHead=false "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
# A bare remote plus a working clone, seeded with one baseline commit.
# tracked=1 reproduces the arcade-hall-of-fame#7 shape: the repository already
# committed .squad/memory/config.json (e.g. from a PREVIOUS session) with a
# non-zero auditMaxBytes. tracked=0 is the common first-session shape: the
# path does not exist yet and harden-init creates it, untracked.
make_remote_pair() {
  local base="$1" tracked="$2"
  rm -rf "$base"; mkdir -p "$base"
  git_quiet init --bare "${base}/remote.git"
  git_quiet clone "${base}/remote.git" "${base}/seed"
  (
    cd "${base}/seed"
    mkdir -p .squad/policies src
    echo "security policy" >.squad/policies/security.md
    echo "original work" >src/app.js
    if [[ "$tracked" == 1 ]]; then
      mkdir -p .squad/memory
      printf '{\n  "policy": {\n    "auditMaxBytes": 1048576,\n    "auditMaxArchives": 3\n  }\n}\n' >.squad/memory/config.json
    fi
    git add -A
    git commit -q -m baseline
    git push -q origin HEAD:refs/heads/main
  ) >/dev/null 2>&1
  git_quiet clone "${base}/remote.git" "${base}/client"
  git_quiet -C "${base}/client" checkout main
}

# A plain (no remote) repository, for the tamper scenarios and the real-SDK
# rotation test, neither of which pushes anywhere.
make_repo() {
  local repo="$1" tracked="$2"
  rm -rf "$repo"; mkdir -p "$repo"
  git_quiet init "$repo"
  (
    cd "$repo"
    mkdir -p .squad/policies src
    echo "security policy" >.squad/policies/security.md
    echo "original work" >src/app.js
    if [[ "$tracked" == 1 ]]; then
      mkdir -p .squad/memory
      printf '{\n  "policy": {\n    "auditMaxBytes": 1048576,\n    "auditMaxArchives": 3\n  }\n}\n' >.squad/memory/config.json
    fi
    git add -A
    git commit -q -m baseline
  ) >/dev/null 2>&1
}

# Run one scenario in a subshell so a squad_policy_abort (exit 78) is captured
# instead of taking the whole suite down with it. Same idiom as
# test_governance_guard.sh's scenario().
#   policy_scenario <repo> <state-dir> <shell-body>
policy_scenario() {
  local repo="$1" state="$2" body="$3"
  (
    export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
    export SQUAD_POLICY_STATE_DIR="$state"
    export SQUAD_POLICY_RESOLVER="${WORKER_DIR}/lib/agent-policy.js"
    # shellcheck source=/dev/null
    source "$SQUAD_POLICY_SH"
    eval "$body"
  ) 2>&1
}

# ===========================================================================
# (a) PROMPT-MODE PUSH: the real commit_and_push_if_needed, extracted from
#     worker/entrypoint.sh (same technique as
#     test_security_f7_watch_loop_governance_report.sh), pushes a branch
#     whose .squad/memory/config.json carries no diff from the branch it
#     started from.
# ===========================================================================
echo "-- (a) prompt-mode push carries no pin diff --"

LOG_FN="$(awk '/^log\(\) \{/,/^\}/' "$ENTRYPOINT")"
CHECKPOINT_FN="$(awk '/^squad_policy_checkpoint\(\) \{/,/^\}/' "$ENTRYPOINT")"
ON_ABORT_FN="$(awk '/^squad_policy_on_abort\(\) \{/,/^\}/' "$ENTRYPOINT")"
REPORT_FN="$(awk '/^squad_watch_governance_report_if_any\(\) \{/,/^\}/' "$ENTRYPOINT")"
COMMIT_PUSH_FN="$(awk '/^commit_and_push_if_needed\(\) \{/,/^\}/' "$ENTRYPOINT")"

assert_ne "" "$LOG_FN" "entrypoint.sh's log() helper is present"
assert_ne "" "$CHECKPOINT_FN" "entrypoint.sh's squad_policy_checkpoint() is present"
assert_ne "" "$ON_ABORT_FN" "entrypoint.sh's squad_policy_on_abort() is present"
assert_ne "" "$REPORT_FN" "entrypoint.sh's squad_watch_governance_report_if_any() is present"
assert_ne "" "$COMMIT_PUSH_FN" "entrypoint.sh's commit_and_push_if_needed() is present"
assert_contains "$COMMIT_PUSH_FN" "squad_push_branch" \
  "commit_and_push_if_needed pushes through squad_push_branch"
assert_contains "$(cat "$PUSH_LIB_SRC")" "squad_policy_assert_pin_unpublished" \
  "squad_push_branch (worker/lib/squad-push.sh) runs the pin publication backstop on every push"

A="${WORK}/scenario-a"
make_remote_pair "$A" 1

run_commit_and_push() {
  local repo="$1"; shift
  local driver="${WORK}/driver-a-$$-${RANDOM}.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf 'export SQUAD_POLICY_RESOLVER=%q\n' "${WORKER_DIR}/lib/agent-policy.js"
    # A private state directory: the default (~/.squad-policy/session) is
    # shared by every concurrent run of this suite on the host.
    printf 'export SQUAD_POLICY_STATE_DIR=%q\n' "${WORK}/state-a-${RANDOM}"
    printf 'source %q\n' "$SQUAD_POLICY_SH"
    printf 'source %q\n' "$CRED_LIB_SRC"
    printf 'source %q\n' "$PUSH_LIB_SRC"
    printf '%s\n' "$LOG_FN"
    printf '%s\n' "$CHECKPOINT_FN"
    printf '%s\n' "$ON_ABORT_FN"
    printf '%s\n' "$REPORT_FN"
    printf '%s\n' "$COMMIT_PUSH_FN"
    echo 'SQUAD_POLICY_VERIFIED=0'
    echo 'SQUAD_POLICY_IN_VERIFY=0'
    printf 'REPO_DIR=%q\n' "$repo"
    echo 'PUSH_CHANGES=true'
    echo 'CREATE_PR=false'
    printf 'OUTPUT_BRANCH=%q\n' "squad/test"
    printf 'SESSION_NAME=%q\n' "test"
    printf 'cd %q\n' "$repo"
    echo 'squad_policy_harden "$REPO_DIR"; echo "HARDEN_RC=$?"'
    echo 'echo "agent work" >>src/app.js'
    echo 'commit_and_push_if_needed; echo "COMMIT_PUSH_RC=$?"'
  } >"$driver"
  bash "$driver" 2>&1
  rm -f "$driver"
}

a_out="$(run_commit_and_push "${A}/client")"
assert_contains "$a_out" "HARDEN_RC=0" "(a) hardening the clone succeeds"
assert_contains "$a_out" "COMMIT_PUSH_RC=0" "(a) commit_and_push_if_needed succeeds (pushes)"

a_main_head="$(git --git-dir="${A}/remote.git" rev-parse refs/heads/main)"
a_branch_head="$(git --git-dir="${A}/remote.git" rev-parse refs/heads/squad/test 2>/dev/null || echo none)"
assert_ne "none" "$a_branch_head" "(a) the branch actually landed on the remote"

a_pin_diff="$(git --git-dir="${A}/remote.git" diff "$a_main_head" "$a_branch_head" -- .squad/memory/config.json)"
assert_eq "" "$a_pin_diff" \
  "(a) the published branch's .squad/memory/config.json is byte-identical to the branch it started from -- the live arcade-hall-of-fame#7 bug, regression-tested"

a_subjects="$(git --git-dir="${A}/remote.git" log --format=%s "${a_main_head}..${a_branch_head}")"
assert_not_contains "$a_subjects" "chore(governance)" \
  "(a) no commit on the published branch is the old pin-commit shape"

a_worktree_cfg="$(cat "${A}/client/.squad/memory/config.json" 2>/dev/null || true)"
assert_contains "$a_worktree_cfg" '"auditMaxBytes": 0' \
  "(a) the working tree still holds the session-only pin after the push -- the seal does not undo the pin, only its publication"

a_lsv="$(git -C "${A}/client" ls-files -v -- .squad/memory/config.json 2>/dev/null)"
assert_eq "1" "$([[ "$a_lsv" == S* ]] && echo 1 || echo 0)" \
  "(a) .squad/memory/config.json still carries the --skip-worktree bit after the push"

# ===========================================================================
# (b) WATCH/LOOP-STYLE PUSH: the AGENT runs its own git add/commit/push --
#     there is no commit_and_push_if_needed call on this path at all (see
#     test_security_f7_watch_loop_governance_report.sh's header comment for
#     why loop/watch never call it) -- so this scenario proves the seal holds
#     with NOTHING from worker/entrypoint.sh in the loop, only squad-policy.sh
#     and the agent's own git porcelain.
# ===========================================================================
echo "-- (b) watch/loop-style agent commit+push carries no pin diff --"

B="${WORK}/scenario-b"
make_remote_pair "$B" 0

b_driver="${WORK}/driver-b.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  printf 'export SQUAD_POLICY_RESOLVER=%q\n' "${WORKER_DIR}/lib/agent-policy.js"
  printf 'export SQUAD_POLICY_STATE_DIR=%q\n' "${WORK}/state-b"
  printf 'source %q\n' "$SQUAD_POLICY_SH"
  printf 'source %q\n' "$CRED_LIB_SRC"
  printf 'source %q\n' "$PUSH_LIB_SRC"
  printf 'cd %q\n' "${B}/client"
  echo 'squad_policy_harden "$(pwd)"; echo "HARDEN_RC=$?"'
  # The agent's own loop: edit, stage, commit, push -- exactly the sequence
  # squad watch/squad loop drive themselves, with no container-side
  # commit_and_push_if_needed in between.
  echo 'echo "agent loop work" >>src/app.js'
  echo 'git add -A'
  echo 'git commit -q -m "agent: loop iteration"'
  echo 'git checkout -q -B squad/loop-test'
  echo 'squad_push_branch squad/loop-test; echo "PUSH_RC=$?"'
  echo 'squad_policy_verify "$(pwd)"; echo "VERIFY_RC=$?"'
} >"$b_driver"
b_out="$(bash "$b_driver" 2>&1)"
rm -f "$b_driver"

assert_contains "$b_out" "HARDEN_RC=0" "(b) hardening the clone succeeds"
assert_contains "$b_out" "PUSH_RC=0" "(b) the agent's own push succeeds"
assert_contains "$b_out" "VERIFY_RC=0" "(b) the agent's own legitimate commit+push is NOT a governance violation"

b_main_head="$(git --git-dir="${B}/remote.git" rev-parse refs/heads/main)"
b_branch_head="$(git --git-dir="${B}/remote.git" rev-parse refs/heads/squad/loop-test 2>/dev/null || echo none)"
assert_ne "none" "$b_branch_head" "(b) the agent's branch actually landed on the remote"

b_pin_diff="$(git --git-dir="${B}/remote.git" diff "$b_main_head" "$b_branch_head" -- .squad/memory/config.json)"
assert_eq "" "$b_pin_diff" \
  "(b) the agent-pushed branch's .squad/memory/config.json carries no diff either -- this path (untracked at baseline) is covered by the .git/info/exclude half of the seal, not --skip-worktree"

b_subjects="$(git --git-dir="${B}/remote.git" log --format=%s "${b_main_head}..${b_branch_head}")"
assert_not_contains "$b_subjects" "chore(governance)" \
  "(b) no commit the agent made is the old pin-commit shape"

# ===========================================================================
# (c) TAMPERING: the seal is defeated deliberately, several ways, and every
#     one is still a governance violation -- or, for the .gitignore negation,
#     hardening itself refuses to run.
# ===========================================================================
echo "-- (c) seal-tampering and edits are still caught --"

STATE_C="${WORK}/state-c"

# squad_policy_verify, called directly (not through worker/entrypoint.sh's
# squad_policy_checkpoint wrapper), returns 1 on a detected violation; it only
# EXITS (78, via squad_policy_abort) when the policy STATE ITSELF was
# tampered with, which none of c1-c5 below do. So these scenarios assert
# VERIFY_RC=1, not 78 -- entrypoint.sh's checkpoint is what turns a 1 into the
# session's actual exit 78, and that wiring is covered by scenario (a) above.

# c1. A direct content rewrite (the manifest/append-only-adjacent case: this
#     file is plain LOCKED, so any edit at all is a violation) -- sanity check
#     that the seal did not quietly turn this path into something writable.
C1="${WORK}/repo-c1"
make_repo "$C1" 1
c1_out="$(policy_scenario "$C1" "${STATE_C}1" '
  squad_policy_harden "'"$C1"'"
  chmod u+w "'"$C1"'/.squad/memory/config.json"
  printf "{\"policy\":{\"auditMaxBytes\":1048576}}\n" >"'"$C1"'/.squad/memory/config.json"
  squad_policy_verify "'"$C1"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$c1_out" "VERIFY_RC=1" "(c1) directly rewriting the pinned file's content is still a governance violation"

# c2. TRACKED fixture: clear --skip-worktree, force-add, and commit. This is
#     a seal-integrity violation (index exposed) AND, once committed, the
#     pre-existing detector (c) (a governance path changed in a commit made
#     during the session).
C2="${WORK}/repo-c2"
make_repo "$C2" 1
c2_out="$(policy_scenario "$C2" "${STATE_C}2" '
  squad_policy_harden "'"$C2"'"
  git -C "'"$C2"'" update-index --no-skip-worktree -- .squad/memory/config.json
  git -C "'"$C2"'" add -f -- .squad/memory/config.json
  git -C "'"$C2"'" commit --no-verify -q -m "tamper: re-add pin"
  squad_policy_verify "'"$C2"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$c2_out" "VERIFY_RC=1" "(c2) clearing --skip-worktree, force-adding, and committing the tracked pin is caught"
assert_contains "$c2_out" "seal broken" "(c2) the seal-integrity detector specifically names the break"

# c3. UNTRACKED fixture: strip the .git/info/exclude line, add -A, and commit.
C3="${WORK}/repo-c3"
make_repo "$C3" 0
c3_out="$(policy_scenario "$C3" "${STATE_C}3" '
  squad_policy_harden "'"$C3"'"
  exclude_file="$(git -C "'"$C3"'" rev-parse --git-path info/exclude)"
  case "$exclude_file" in /*) ;; *) exclude_file="'"$C3"'/$exclude_file" ;; esac
  grep -vF "/.squad/memory/config.json" "$exclude_file" >"${exclude_file}.tmp" && mv "${exclude_file}.tmp" "$exclude_file"
  git -C "'"$C3"'" add -A
  git -C "'"$C3"'" commit --no-verify -q -m "tamper: stage untracked pin"
  squad_policy_verify "'"$C3"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$c3_out" "VERIFY_RC=1" "(c3) stripping the exclude line, add -A, and committing the untracked pin is caught"

# c4. TRACKED fixture: clear --skip-worktree only, no commit at all. No commit
#     exists yet for detector (c) to see; the NEW seal-integrity check is what
#     catches this.
C4="${WORK}/repo-c4"
make_repo "$C4" 1
c4_out="$(policy_scenario "$C4" "${STATE_C}4" '
  squad_policy_harden "'"$C4"'"
  git -C "'"$C4"'" update-index --no-skip-worktree -- .squad/memory/config.json
  squad_policy_verify "'"$C4"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$c4_out" "VERIFY_RC=1" "(c4) clearing --skip-worktree alone, with nothing committed, is still caught by the seal-integrity check"
assert_contains "$c4_out" "seal broken" "(c4) the seal-integrity detector names the break even with no commit"

# c5. UNTRACKED fixture: strip the exclude line only, no commit.
C5="${WORK}/repo-c5"
make_repo "$C5" 0
c5_out="$(policy_scenario "$C5" "${STATE_C}5" '
  squad_policy_harden "'"$C5"'"
  exclude_file="$(git -C "'"$C5"'" rev-parse --git-path info/exclude)"
  case "$exclude_file" in /*) ;; *) exclude_file="'"$C5"'/$exclude_file" ;; esac
  grep -vF "/.squad/memory/config.json" "$exclude_file" >"${exclude_file}.tmp" && mv "${exclude_file}.tmp" "$exclude_file"
  squad_policy_verify "'"$C5"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$c5_out" "VERIFY_RC=1" "(c5) stripping the exclude line alone, with nothing committed, is still caught by the seal-integrity check"

# c6. A repository .gitignore with a NEGATION entry overrides
#     .git/info/exclude -- confirmed by direct experiment, not assumed (see
#     squad_policy_seal_memory_audit_config_pin's doc comment). Hardening
#     itself must refuse rather than silently seal nothing.
C6="${WORK}/repo-c6"
rm -rf "$C6"; mkdir -p "$C6"
git_quiet init "$C6"
(
  cd "$C6"
  mkdir -p .squad/policies src
  echo "security policy" >.squad/policies/security.md
  echo "original work" >src/app.js
  printf '!.squad/memory/config.json\n' >.gitignore
  git add -A
  git commit -q -m baseline
) >/dev/null 2>&1
# squad_policy_harden's own failure path is squad_policy_abort, which calls
# `exit 78` directly -- unlike squad_policy_verify's return-1 shape above, that
# exit terminates the policy_scenario subshell itself before any `echo ...$?`
# inside the body would run. The subshell's own exit status is what this
# scenario must capture instead.
c6_rc=0
c6_out="$(policy_scenario "$C6" "${STATE_C}6" 'squad_policy_harden "'"$C6"'"')" || c6_rc=$?
assert_eq "78" "$c6_rc" "(c6) a .gitignore negation makes hardening refuse to run (exit 78), rather than silently publish through the gap"
assert_contains "$c6_out" "cannot keep session-only memory audit pin" "(c6) the abort message specifically names the pin-sealing failure"

# ===========================================================================
# R-CI (security re-review): scenario (d), the 1100-real-audit-call rotation
# proof (hardened subject + unhardened control), and scenario (e4), the
# 1100-real-audit-call proof that `git clean -fdx` does not re-enable
# rotation, moved to worker/tests/test_memory_audit_pin_rotation.sh. Combined,
# the three 1100-call loops measured 112s-147s against run-tests.sh's hard
# 120s per-suite kill; splitting them out keeps both suites comfortably under
# budget. See that file's header for exactly what it proves.
#
# (e0) below still needs the real SDK (it writes one default config.json
# through the real squad-sdk's auditLog(), which is cheap -- not a loop), so
# the import prelude stays here rather than moving with (d)/(e4).
export SQUAD_TEST_SDK_DIR="$SDK_DIR"
SDK_IMPORT_PRELUDE="$(cat <<'EOF'
import path from "node:path";
import { pathToFileURL } from "node:url";
const sdkUrl = (rel) => pathToFileURL(path.join(process.env.SQUAD_TEST_SDK_DIR, rel)).href;
const { LocalMemoryStore } = await import(sdkUrl("dist/memory/index.js"));
const { FSStorageProvider } = await import(sdkUrl("dist/storage/fs-storage-provider.js"));
EOF
)"

# ===========================================================================
# (e0) the SDK-default constant the sampler uses to classify a re-created
#     file must be byte-identical to the real SDK's output. The rest of
#     scenario (e) -- findings 1-9 against the untracked seal, the push
#     backstop, and the wrapper gate -- lives in the sibling suites
#     test_memory_audit_pin_seal_defeats.sh and test_memory_audit_pin_hooks.sh.
# ===========================================================================
echo "-- (e0) SDK-default constant matches the real SDK --"

STATE_E="${WORK}/state-e"

# The SDK-default constant the sampler uses to classify a re-created file must
# be byte-identical to what the REAL squad-sdk's ensureInitialized() writes.
E0="${WORK}/sdk-default-e0"; mkdir -p "$E0"
{
  printf '%s\n' "$SDK_IMPORT_PRELUDE"
  echo 'await new LocalMemoryStore(new FSStorageProvider(), process.argv[2]).auditLog();'
} >"${WORK}/init-e0.mjs"
node "${WORK}/init-e0.mjs" "$E0" >/dev/null 2>&1
e0_out="$(policy_scenario "$E0" "${STATE_E}0" '
  got=""
  IFS= read -r -d "" got <"'"$E0"'/.squad/memory/config.json" || :
  [[ -n "$got" && "$got" == "$SQUAD_POLICY_SDK_DEFAULT_MEMORY_CONFIG" ]] && echo DEFAULT_MATCH=1 || echo DEFAULT_MATCH=0
')"
assert_contains "$e0_out" "DEFAULT_MATCH=1" \
  "(e0) SQUAD_POLICY_SDK_DEFAULT_MEMORY_CONFIG is byte-identical to the config.json the real squad-sdk ${SDK_VERSION} re-creates"

test_summary
