#!/usr/bin/env bash
# Issue #134: a prompt / new-project session that is still working when ACA's
# replicaTimeout hard-kills the replica must not lose its work.
#
# Before this fix the worker published (commit_and_push_if_needed) only AFTER
# the agent exited. A session still running at the replicaTimeout was killed
# with everything it had done sitting unpublished in the container's checkout:
# squad-hub #165 and #166 each lost ~2 hours of work that way on 2026-10-05.
#
# worker/lib/squad-deadline.sh now computes SQUAD_SESSION_DEADLINE_UTC
# (container start + SQUAD_REPLICA_TIMEOUT_SECONDS - SQUAD_PUBLISH_MARGIN_
# SECONDS, or an earlier SQUAD_TOKEN_EXPIRES_AT - margin), tells the agent,
# and runs the agent under a watchdog that stops it at the deadline (SIGINT,
# then SIGTERM, then SIGKILL). The session then publishes through the SAME
# commit_and_push_if_needed -- governance checkpoint, pin hook, pin backstop
# and all -- as a WIP commit and a draft pull request, and exits 124.
#
# What this suite proves, in order:
#
#   1. the deadline arithmetic: defaults 7200 / 900, both honoured when set, an
#      earlier token expiry wins, nonsense refuses (64), and the deadline is
#      never taken from the inbound environment;
#   2. the agent is told the deadline (squad_publish_contract_note), and a
#      session that does not publish is told nothing new;
#   3. the watchdog itself, on stub agents: a fast exit is untouched, a polite
#      agent stops on SIGINT, a stubborn one is escalated INT -> TERM -> KILL,
#      and a grandchild left in the group is swept;
#   4. errexit stays live inside the agent job (the fail-closed property
#      squad_hub_run depends on) -- and why the call must be a plain statement;
#   5. END TO END, on the REAL prompt) / new-project) blocks extracted from
#      worker/entrypoint.sh and a real bare remote:
#        * the acceptance case -- a stub agent that never exits, with
#          SQUAD_REPLICA_TIMEOUT_SECONDS=90 and SQUAD_PUBLISH_MARGIN_SECONDS=30:
#          the branch is pushed with a WIP commit, the PR is created --draft
#          with a WIP title and body, the session exits 124, and the published
#          branch carries no .squad/memory/config.json diff;
#        * a session that finishes before the deadline is byte-for-byte the old
#          behaviour (commit message, gh argv without --draft, exit 0);
#        * a failing agent still ends the session with its own status and
#          publishes nothing;
#        * an agent that force-stages the memory audit pin and then hangs is
#          stopped, and the WIP publish is REFUSED by the pin guard (78);
#        * the squad-hub oneshot path: a hub process that ignores INT and TERM
#          is killed and the work is still published; a policy-resolver
#          failure on that path still refuses (78) instead of launching the
#          hub with an empty policy;
#        * a repository that cannot have draft PRs still gets a (WIP) PR;
#   6. deploy.ps1 drives --replica-timeout AND SQUAD_REPLICA_TIMEOUT_SECONDS
#      for the session job from the one -SessionReplicaTimeout parameter, and
#      the Dockerfile ships the new library.
#
# Every timing in here is real but short (1-second graces, a deadline one or
# two seconds out); the suite runs in well under a minute.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WORKER_DIR}/.." && pwd)"
ENTRYPOINT="${WORKER_DIR}/entrypoint.sh"
DEADLINE_LIB="${WORKER_DIR}/lib/squad-deadline.sh"
SQUAD_POLICY_SH="${WORKER_DIR}/lib/squad-policy.sh"
CRED_LIB_SRC="${WORKER_DIR}/lib/squad-credentials.sh"
PUSH_LIB_SRC="${WORKER_DIR}/lib/squad-push.sh"
HUB_LIB_SRC="${WORKER_DIR}/lib/squad-hub.sh"
DEPLOY_PS1="${REPO_ROOT}/scripts/deploy.ps1"
DOCKERFILE="${WORKER_DIR}/Dockerfile"

source "${TEST_DIR}/lib/assert.sh"
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum date

echo "== session deadline: publish before the replica timeout (issue #134) =="

[[ -f "$DEADLINE_LIB" ]] || { echo "FAIL: worker/lib/squad-deadline.sh is missing"; exit 1; }

# The end-to-end scenarios harden the checkout exactly as a real session does,
# and that hardening is mode bits, which uid 0 ignores -- the same reason
# test_memory_audit_pin_publication.sh skips under root.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_session_deadline.sh — running as root, the end-to-end scenarios' hardening is not enforced against uid 0"
  exit 77
fi

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-session-deadline-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

# Hermetic: a suite run from inside a live session (or a dev shell that has
# exported some of these) must not inherit that session's sealed-state store,
# deadline, or publish overrides.
while read -r inherited; do
  unset "$inherited"
done < <(compgen -e | grep -E '^(SQUAD_|OUTPUT_BRANCH$|PR_TITLE$|PR_BODY$|COMMIT_MESSAGE$|PUSH_CHANGES$|CREATE_PR$|GH_|GITHUB_BASE_BRANCH$|GITHUB_REF$)')

export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main
git config --global user.name "Test"
git config --global user.email "test@example.com"

git_quiet() { git -c advice.detachedHead=false "$@" >/dev/null 2>&1; }

# Is this pid gone? A SIGKILLed process can linger as a zombie until it is
# reaped by whoever inherited it, and `kill -0` succeeds on a zombie, so a
# zombie counts as gone: it runs no code and holds no file open.
pid_gone() {
  local pid="$1" state
  [[ -n "$pid" ]] || return 1
  [[ -e "/proc/${pid}" ]] || return 0
  state="$(awk '/^State:/ {print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
  [[ -z "$state" || "$state" == "Z" ]]
}

# ===========================================================================
# 1. Deadline arithmetic
# ===========================================================================
echo "-- 1. deadline computation --"

# compute <start> [VAR=value ...] -- prints "rc epoch source"
compute() {
  local start="$1"; shift
  (
    unset SQUAD_REPLICA_TIMEOUT_SECONDS SQUAD_PUBLISH_MARGIN_SECONDS SQUAD_TOKEN_EXPIRES_AT
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source=/dev/null
    source "$DEADLINE_LIB"
    rc=0
    squad_deadline_compute "$start" >/dev/null 2>&1 || rc=$?
    printf '%s %s %s' "$rc" "${SQUAD_SESSION_DEADLINE_EPOCH:-}" "${SQUAD_SESSION_DEADLINE_SOURCE:-}"
  )
}

START=1790000000
assert_eq "0 $((START + 7200 - 900)) replica-timeout" "$(compute "$START")" \
  "env unset: deadline = start + 7200 - 900 (the brief's defaults)"
assert_eq "0 $((START + 14400 - 900)) replica-timeout" "$(compute "$START" SQUAD_REPLICA_TIMEOUT_SECONDS=14400)" \
  "SQUAD_REPLICA_TIMEOUT_SECONDS is honoured (14400 -> start + 14400 - 900)"
assert_eq "0 $((START + 90 - 30)) replica-timeout" \
  "$(compute "$START" SQUAD_REPLICA_TIMEOUT_SECONDS=90 SQUAD_PUBLISH_MARGIN_SECONDS=30)" \
  "SQUAD_PUBLISH_MARGIN_SECONDS is honoured (90 - 30 -> start + 60)"
assert_eq "0 $((START + 7200 - 600)) replica-timeout" "$(compute "$START" SQUAD_PUBLISH_MARGIN_SECONDS=600)" \
  "margin alone set: timeout still defaults to 7200"

TOKEN_EARLY="$(date -u -d "@$((START + 3600))" +%Y-%m-%dT%H:%M:%SZ)"
assert_eq "0 $((START + 3600 - 900)) token-expiry" \
  "$(compute "$START" "SQUAD_TOKEN_EXPIRES_AT=${TOKEN_EARLY}")" \
  "an EARLIER SQUAD_TOKEN_EXPIRES_AT wins: deadline = expiry - margin"
TOKEN_LATE="$(date -u -d "@$((START + 86400))" +%Y-%m-%dT%H:%M:%SZ)"
assert_eq "0 $((START + 7200 - 900)) replica-timeout" \
  "$(compute "$START" "SQUAD_TOKEN_EXPIRES_AT=${TOKEN_LATE}")" \
  "a LATER SQUAD_TOKEN_EXPIRES_AT does not move the deadline out"
assert_eq "0 $((START + 7200 - 900)) replica-timeout" \
  "$(compute "$START" "SQUAD_TOKEN_EXPIRES_AT=not-a-date")" \
  "an unparseable SQUAD_TOKEN_EXPIRES_AT is ignored (the replica deadline still applies), not fatal"

for bad in "SQUAD_REPLICA_TIMEOUT_SECONDS=abc" "SQUAD_REPLICA_TIMEOUT_SECONDS=0" \
           "SQUAD_PUBLISH_MARGIN_SECONDS=-5" "SQUAD_PUBLISH_MARGIN_SECONDS=1e3"; do
  assert_eq "64" "$(compute "$START" "$bad" | cut -d' ' -f1)" "refuses (64) a malformed value: ${bad}"
done
assert_eq "64" "$(compute "$START" SQUAD_REPLICA_TIMEOUT_SECONDS=900 SQUAD_PUBLISH_MARGIN_SECONDS=900 | cut -d' ' -f1)" \
  "refuses (64) a margin that leaves no time at all (margin >= timeout)"
assert_eq "64" "$(compute "not-a-number" | cut -d' ' -f1)" "refuses (64) a non-numeric start"

init_out="$(
  unset SQUAD_REPLICA_TIMEOUT_SECONDS SQUAD_PUBLISH_MARGIN_SECONDS SQUAD_TOKEN_EXPIRES_AT
  export SQUAD_SESSION_DEADLINE_UTC="2099-01-01T00:00:00Z" SQUAD_SESSION_TIMED_OUT=1
  # shellcheck source=/dev/null
  source "$DEADLINE_LIB"
  printf 'after-source utc=[%s] timed_out=[%s]\n' "${SQUAD_SESSION_DEADLINE_UTC:-}" "$SQUAD_SESSION_TIMED_OUT"
  export SQUAD_SESSION_START_EPOCH="$START"
  squad_session_deadline_init >/dev/null 2>&1
  printf 'utc=[%s] exported=[%s]\n' "$SQUAD_SESSION_DEADLINE_UTC" "$(bash -c 'printf %s "${SQUAD_SESSION_DEADLINE_UTC:-}"')"
)"
assert_contains "$init_out" "after-source utc=[] timed_out=[0]" \
  "sourcing the library discards an inbound SQUAD_SESSION_DEADLINE_UTC / SQUAD_SESSION_TIMED_OUT (the dispatcher cannot pre-set either)"
EXPECTED_UTC="$(date -u -d "@$((START + 6300))" +%Y-%m-%dT%H:%M:%SZ)"
assert_contains "$init_out" "utc=[${EXPECTED_UTC}] exported=[${EXPECTED_UTC}]" \
  "squad_session_deadline_init exports SQUAD_SESSION_DEADLINE_UTC as an ISO-8601 UTC instant to child processes (the agent)"

# ===========================================================================
# 2. The agent is told
# ===========================================================================
echo "-- 2. the publish contract note states the deadline --"

note() {
  (
    # shellcheck source=/dev/null
    source "$PUSH_LIB_SRC"
    eval "$1"
    squad_publish_contract_note
  )
}
NOTE_NO_DEADLINE="$(note 'unset SQUAD_SESSION_DEADLINE_UTC; PUSH_CHANGES=true')"
NOTE_DEADLINE="$(note 'export SQUAD_SESSION_DEADLINE_UTC=2026-10-05T20:35:00Z; PUSH_CHANGES=true')"
NOTE_NO_PUSH="$(note 'export SQUAD_SESSION_DEADLINE_UTC=2026-10-05T20:35:00Z; PUSH_CHANGES=false')"

assert_contains "$NOTE_DEADLINE" "2026-10-05T20:35:00Z" "the note names the deadline instant"
assert_contains "$NOTE_DEADLINE" "Session deadline" "the note says it is a deadline"
assert_contains "$NOTE_DEADLINE" "Remaining" "the note asks for a 'Remaining' checklist"
assert_contains "$NOTE_DEADLINE" "draft" "the note says unfinished work is published as a draft"
assert_eq "$NOTE_NO_DEADLINE" "${NOTE_DEADLINE:0:${#NOTE_NO_DEADLINE}}" \
  "the deadline paragraph is APPENDED: the existing contract text is unchanged and first"
assert_not_contains "$NOTE_NO_DEADLINE" "deadline" "no deadline set: the note is exactly as before (no deadline text)"
assert_eq "" "$NOTE_NO_PUSH" "PUSH_CHANGES=false: still no note at all, deadline or not"

# ===========================================================================
# 3. The watchdog on stub agents
# ===========================================================================
echo "-- 3. the watchdog --"

STUBS_UNIT="${WORK}/unit-stubs"
mkdir -p "$STUBS_UNIT"

# A polite agent: stops on SIGINT with a status of its own choosing.
cat >"${STUBS_UNIT}/polite.sh" <<'EOF'
#!/usr/bin/env bash
trap 'echo INT >>"$1"; exit 42' INT
trap 'echo TERM >>"$1"; exit 43' TERM
while :; do sleep 0.1; done
EOF
# Ignores SIGINT, stops on SIGTERM.
cat >"${STUBS_UNIT}/term-only.sh" <<'EOF'
#!/usr/bin/env bash
trap 'echo INT >>"$1"' INT
trap 'echo TERM >>"$1"; exit 143' TERM
while :; do sleep 0.1; done
EOF
# Never exits on its own and swallows both polite signals: only SIGKILL works.
cat >"${STUBS_UNIT}/stubborn.sh" <<'EOF'
#!/usr/bin/env bash
trap 'echo INT >>"$1"' INT
trap 'echo TERM >>"$1"' TERM
while :; do sleep 0.1; done
EOF
# Leaves a grandchild in its process group that ignores INT and TERM, then
# exits on SIGINT itself -- the "test runner the agent started" case.
cat >"${STUBS_UNIT}/leaves-grandchild.sh" <<'EOF'
#!/usr/bin/env bash
( trap '' INT TERM; exec sleep 300 ) &
echo $! >"$1"
trap 'exit 130' INT
while :; do sleep 0.1; done
EOF
chmod +x "${STUBS_UNIT}"/*.sh

# watchdog <seconds-until-deadline> <cmd...> -- prints the report variables
# The timed-out cases use 2, not 1: EPOCHSECONDS has whole-second resolution,
# so "+1" can be a few milliseconds away -- less than a stub needs to install
# its traps -- and a SIGINT landing first would kill it with bash's default
# disposition and make the case flaky. "+2" is always at least a full second.
watchdog() {
  local until="$1"; shift
  (
    set -Eeuo pipefail
    # shellcheck source=/dev/null
    source "$DEADLINE_LIB"
    export SQUAD_DEADLINE_INT_GRACE_SECONDS=1 SQUAD_DEADLINE_TERM_GRACE_SECONDS=1
    local t0=$SECONDS
    squad_deadline_run_agent $((EPOCHSECONDS + until)) "$@" 2>/dev/null
    printf 'TIMED_OUT=%s RC=%s ELAPSED=%s' "$SQUAD_SESSION_TIMED_OUT" "$SQUAD_DEADLINE_AGENT_RC" $((SECONDS - t0))
  )
}

out="$(watchdog 30 bash -c 'exit 3')"
assert_contains "$out" "TIMED_OUT=0 RC=3" "an agent that exits before the deadline: not timed out, its own status reported"
elapsed="${out##*ELAPSED=}"
assert_eq "1" "$(( elapsed <= 2 ? 1 : 0 ))" "... and the watchdog does not hold the session open until the deadline (${elapsed}s)"

out="$(watchdog 30 true)"
assert_contains "$out" "TIMED_OUT=0 RC=0" "a successful agent: TIMED_OUT=0 RC=0"

# A signal that was IGNORED when a non-interactive bash started cannot be
# trapped or reset by it (POSIX), and the ignore is inherited by everything it
# starts. This suite inherits SIGINT ignored when it is itself launched as a
# background job without job control (`suite &` from a script) -- then no stub
# can ever see the watchdog's SIGINT. Probe exactly the stubs' mechanism; where
# SIGINT cannot arrive, prove instead that the watchdog's SIGTERM escalation
# still stops every agent -- which is also what happens in a container whose
# agent starts with SIGINT ignored.
SIGINT_DELIVERABLE=0
bash -c 'trap "exit 42" INT; kill -INT $$; exit 0' 2>/dev/null
[[ $? -eq 42 ]] && SIGINT_DELIVERABLE=1
if [[ "$SIGINT_DELIVERABLE" -eq 1 ]]; then
  OFFERED="INT TERM"
else
  OFFERED="TERM"
  echo "NOTE: this suite was started with SIGINT ignored (inherited, so no bash stub can trap it); the SIGINT-specific outcomes below are replaced by the SIGTERM fallback, which is still asserted."
fi

SIG="${WORK}/sig-polite"; : >"$SIG"
out="$(watchdog 2 "${STUBS_UNIT}/polite.sh" "$SIG")"
if [[ "$SIGINT_DELIVERABLE" -eq 1 ]]; then
  assert_contains "$out" "TIMED_OUT=1 RC=42" "a polite agent still running at the deadline is stopped by SIGINT (its own status 42 kept)"
  assert_eq "INT" "$(tr '\n' ' ' <"$SIG" | sed 's/ $//')" "... and received SIGINT only -- no escalation was needed"
else
  assert_contains "$out" "TIMED_OUT=1 RC=43" "(SIGINT ignored on entry) a polite agent is stopped by the SIGTERM escalation instead"
  assert_eq "TERM" "$(tr '\n' ' ' <"$SIG" | sed 's/ $//')" "... which it received"
fi

SIG="${WORK}/sig-term"; : >"$SIG"
out="$(watchdog 2 "${STUBS_UNIT}/term-only.sh" "$SIG")"
assert_contains "$out" "TIMED_OUT=1 RC=143" "an agent that ignores SIGINT is escalated to SIGTERM after the INT grace"
assert_eq "$OFFERED" "$(tr '\n' ' ' <"$SIG" | sed 's/ $//')" "... in that order: SIGINT first, then SIGTERM"

SIG="${WORK}/sig-stubborn"; : >"$SIG"
out="$(watchdog 2 "${STUBS_UNIT}/stubborn.sh" "$SIG")"
assert_contains "$out" "TIMED_OUT=1 RC=137" "an agent that swallows SIGINT and SIGTERM is SIGKILLed after the TERM grace (137)"
assert_eq "$OFFERED" "$(tr '\n' ' ' <"$SIG" | sed 's/ $//')" "... after being offered SIGINT, then SIGTERM"

GC="${WORK}/grandchild.pid"; : >"$GC"
out="$(watchdog 2 "${STUBS_UNIT}/leaves-grandchild.sh" "$GC")"
assert_contains "$out" "TIMED_OUT=1 RC=$([[ "$SIGINT_DELIVERABLE" -eq 1 ]] && echo 130 || echo 143)" "an agent that stops but leaves a child behind reports its own status"
sleep 0.2
assert_eq "1" "$(pid_gone "$(cat "$GC")" && echo 1 || echo 0)" \
  "... and the child it left in its process group (ignoring INT and TERM) is swept with SIGKILL, so nothing is still writing to the checkout during the WIP commit"

out="$(
  # shellcheck source=/dev/null
  source "$DEADLINE_LIB"
  squad_deadline_run_agent "not-an-epoch" true 2>/dev/null; echo "RC=$?"
)"
assert_eq "RC=64" "$out" "an unusable deadline argument is refused (64) before anything is started"

settle_out="$(
  # shellcheck source=/dev/null
  source "$DEADLINE_LIB"
  SQUAD_SESSION_TIMED_OUT=0 SQUAD_DEADLINE_AGENT_RC=5
  ( squad_deadline_settle_agent "$WORK" ); echo "not-timed-out-failed=$?"
  SQUAD_SESSION_TIMED_OUT=0 SQUAD_DEADLINE_AGENT_RC=0
  ( squad_deadline_settle_agent "$WORK" ); echo "not-timed-out-ok=$?"
  mkdir -p "${WORK}/settle/.git"; : >"${WORK}/settle/.git/index.lock"
  SQUAD_SESSION_TIMED_OUT=1 SQUAD_DEADLINE_AGENT_RC=137
  ( squad_deadline_settle_agent "${WORK}/settle" 2>/dev/null ); echo "timed-out=$?"
  [[ -e "${WORK}/settle/.git/index.lock" ]] && echo "lock=kept" || echo "lock=removed"
  ( squad_deadline_finish_session 2>/dev/null ); echo "finish-timed-out=$?"
  SQUAD_SESSION_TIMED_OUT=0
  ( squad_deadline_finish_session ); echo "finish-normal=$?"
)"
assert_contains "$settle_out" "not-timed-out-failed=5" "settle: an agent that failed on its own still ends the session with its status (unchanged behaviour)"
assert_contains "$settle_out" "not-timed-out-ok=0" "settle: an agent that succeeded continues to publish"
assert_contains "$settle_out" "timed-out=0" "settle: a stopped agent continues to publish whatever its status"
assert_contains "$settle_out" "lock=removed" "settle: the stale .git/index.lock a stopped agent left is removed so the WIP commit can be made"
assert_contains "$settle_out" "finish-timed-out=124" "finish: a timed-out session exits 124 (timeout(1)'s code), distinguishable from a failure"
assert_contains "$settle_out" "finish-normal=0" "finish: every other session is untouched"

# ===========================================================================
# 4. errexit stays live inside the agent job
# ===========================================================================
echo "-- 4. errexit inside the agent job --"
# squad_hub_run's `policy_json="$(squad_hub_policy_json)"` stops the session
# when the policy resolver aborts ONLY because errexit is live in the job. The
# old `( ... )` subshell gave that for free; the watchdog must too.
errexit_probe() {
  (
    set -Eeuo pipefail
    # shellcheck source=/dev/null
    source "$DEADLINE_LIB"
    agent() { local x; x="$(false)"; echo "CONTINUED-PAST-FAILURE"; }
    eval "$1"
    echo "RC=${SQUAD_DEADLINE_AGENT_RC}"
  ) 2>/dev/null
}
out="$(errexit_probe 'squad_deadline_run_agent $((EPOCHSECONDS + 30)) agent')"
assert_not_contains "$out" "CONTINUED-PAST-FAILURE" \
  "a plain-statement call keeps errexit live in the agent job: a failed assignment stops it"
assert_contains "$out" "RC=1" "... and its failure status reaches the caller"
# The hazard the plain-statement rule exists for, pinned so the comment in
# squad_deadline_run_agent stays true: called on the left of `||`, the job
# inherits errexit suppression and runs on past the failure.
out="$(errexit_probe 'squad_deadline_run_agent $((EPOCHSECONDS + 30)) agent || true')"
assert_contains "$out" "CONTINUED-PAST-FAILURE" \
  "(hazard, pinned) under '|| ...' the job inherits errexit suppression -- which is why entrypoint.sh must never call it that way"

# And entrypoint.sh never does. Join backslash continuations so a multi-line
# call is checked as the one statement it is.
calls="$(awk '
  /^[[:space:]]*#/ { next }
  { line = line $0 }
  /\\$/ { sub(/\\$/, "", line); next }
  { print line; line = "" }
' "$ENTRYPOINT" | grep 'squad_deadline_run_agent' || true)"
assert_eq "4" "$(printf '%s\n' "$calls" | grep -c 'squad_deadline_run_agent')" \
  "entrypoint.sh runs the agent under the watchdog on all four paths (prompt + new-project, direct + hub)"
assert_eq "0" "$(printf '%s\n' "$calls" | grep -cE '\|\||&&|^[[:space:]]*(if|while|until|!)[[:space:]]|\$\(' || true)" \
  "every one of those calls is a plain statement (no ||, &&, if, !, or command substitution)"

# ===========================================================================
# 5. End to end on the real prompt) / new-project) blocks
# ===========================================================================
echo "-- 5. end to end: the real entrypoint blocks, a real remote --"

LOG_FN="$(awk '/^log\(\) \{/,/^\}/' "$ENTRYPOINT")"
CHECKPOINT_FN="$(awk '/^squad_policy_checkpoint\(\) \{/,/^\}/' "$ENTRYPOINT")"
ON_ABORT_FN="$(awk '/^squad_policy_on_abort\(\) \{/,/^\}/' "$ENTRYPOINT")"
REPORT_FN="$(awk '/^squad_watch_governance_report_if_any\(\) \{/,/^\}/' "$ENTRYPOINT")"
COMMIT_PUSH_FN="$(awk '/^commit_and_push_if_needed\(\) \{/,/^\}/' "$ENTRYPOINT")"
# The case-arm body, without its `prompt)` label and closing `;;`.
PROMPT_BODY="$(sed -n '/^  prompt)/,/^    ;;/p' "$ENTRYPOINT" | sed '1d;$d')"
NEWPROJ_BODY="$(sed -n '/^  new-project)/,/^    ;;/p' "$ENTRYPOINT" | sed '1d;$d')"

for fn_var in LOG_FN CHECKPOINT_FN ON_ABORT_FN REPORT_FN COMMIT_PUSH_FN PROMPT_BODY NEWPROJ_BODY; do
  assert_ne "" "${!fn_var}" "extracted ${fn_var} from worker/entrypoint.sh"
done
assert_contains "$COMMIT_PUSH_FN" "squad_policy_checkpoint" \
  "the WIP publish goes through commit_and_push_if_needed, whose governance checkpoint is unchanged"
assert_contains "$COMMIT_PUSH_FN" "squad_push_branch" \
  "... and through squad_push_branch, whose pin backstop runs on every push"

make_remote_pair() {
  local base="$1"
  rm -rf "$base"; mkdir -p "$base"
  git_quiet init --bare "${base}/remote.git"
  git_quiet clone "${base}/remote.git" "${base}/seed"
  (
    cd "${base}/seed"
    mkdir -p .squad/policies .squad/memory src
    echo "security policy" >.squad/policies/security.md
    echo "original work" >src/app.js
    # Tracked, non-zero: the arcade-hall-of-fame#7 shape the pin guard exists
    # for. Any diff to this file on a published branch is the leak.
    printf '{\n  "policy": {\n    "auditMaxBytes": 1048576,\n    "auditMaxArchives": 3\n  }\n}\n' >.squad/memory/config.json
    git add -A
    git commit -q -m baseline
    git push -q origin HEAD:refs/heads/main
  ) >/dev/null 2>&1
  git_quiet clone "${base}/remote.git" "${base}/client"
  git_quiet -C "${base}/client" checkout main
}

# Stub executables put first on the agent's PATH. Each records what it saw in
# $STUB_DIR, which the assertions read afterwards.
make_stubs() {
  local dir="$1"
  mkdir -p "$dir"
  # `copilot -p <prompt> ...`, behaviour chosen by STUB_MODE.
  cat >"${dir}/copilot" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$2" >"${STUB_DIR}/prompt.txt"
echo $$ >"${STUB_DIR}/agent.pid"
case "${STUB_MODE}" in
  finish)
    echo "finished work" >>src/app.js
    exit 0 ;;
  fail)
    echo "broken work" >>src/app.js
    exit 3 ;;
  never-exits)
    # Half-done work, a brand new file, and a git index lock as if stopped
    # mid-`git add` -- then never exits, and swallows SIGINT and SIGTERM so
    # only the final SIGKILL stops it.
    echo "half-done work" >>src/app.js
    echo "new feature, unfinished" >src/wip-feature.js
    : >.git/index.lock
    trap 'echo INT >>"${STUB_DIR}/signals"' INT
    trap 'echo TERM >>"${STUB_DIR}/signals"' TERM
    while :; do sleep 0.1; done ;;
  pin-adversary)
    # Tries to smuggle the session-only memory audit pin into the WIP commit:
    # clear the skip-worktree bit and force-stage it, then hang until stopped.
    echo "work" >>src/app.js
    git update-index --no-skip-worktree -- .squad/memory/config.json 2>/dev/null || true
    git add -f -- .squad/memory/config.json 2>/dev/null || true
    trap '' INT
    while :; do sleep 0.1; done ;;
esac
EOF
  # `squad-hub oneshot`: does some work, then ignores INT and TERM entirely.
  cat >"${dir}/squad-hub" <<'EOF'
#!/usr/bin/env bash
echo $$ >"${STUB_DIR}/hub.pid"
printf '%s' "${SQUAD_HUB_PROMPT:-}" >"${STUB_DIR}/prompt.txt"
echo "hub work" >>"${SQUAD_HUB_CWD}/src/app.js"
trap '' INT TERM
while :; do sleep 0.1; done
EOF
  # `gh pr create ...`: records each call's argv, NUL-separated, one file per
  # call. GH_FAIL_DRAFT=1 makes a --draft create fail, as it does on a plan
  # without draft pull requests.
  cat >"${dir}/gh" <<'EOF'
#!/usr/bin/env bash
n=$(ls "${STUB_DIR}" | grep -c '^gh-call-' || true)
printf '%s\0' "$@" >"${STUB_DIR}/gh-call-$((n + 1))"
if [[ "${GH_FAIL_DRAFT:-0}" == 1 ]]; then
  for a in "$@"; do [[ "$a" == "--draft" ]] && { echo "draft pull requests are not supported" >&2; exit 1; }; done
fi
exit 0
EOF
  chmod +x "${dir}/copilot" "${dir}/squad-hub" "${dir}/gh"
}

# run_session <name> <block-var> <stub-mode> <supervise 0|1> <deadline-offset>
#             [extra driver lines...]
# Runs one session: the real case-arm body, eval'd in a driver that sources the
# real libraries and defines the real entrypoint functions, against a fresh
# clone of a fresh bare remote. The deadline is <deadline-offset> seconds from
# the moment the checkout has been hardened (computed through the real
# SQUAD_REPLICA_TIMEOUT_SECONDS=90 / SQUAD_PUBLISH_MARGIN_SECONDS=30
# arithmetic: start = now - 60 + offset). Taken AFTER hardening, which can
# take seconds on a loaded runner: a deadline that has already passed when the
# agent starts would stop it before it wrote anything, and the scenario would
# prove nothing. TIMED_OUT_OFFSET leaves room for the agent (and, on the hub
# path, the node policy resolver that runs before it) to start and write.
# Leaves: ${WORK}/<name>/{remote.git,client,stub/*} and prints the driver's
# combined output, ending in "SESSION_EXIT=<rc>".
run_session() {
  local name="$1" block_var="$2" stub_mode="$3" supervise="$4" offset="$5"; shift 5
  local base="${WORK}/${name}" driver
  make_remote_pair "$base"
  make_stubs "${base}/bin"
  mkdir -p "${base}/stub"
  driver="${base}/driver.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf 'export PATH=%q:"$PATH"\n' "${base}/bin"
    printf 'export STUB_DIR=%q STUB_MODE=%q\n' "${base}/stub" "$stub_mode"
    printf 'export SQUAD_POLICY_RESOLVER=%q\n' "${WORKER_DIR}/lib/agent-policy.js"
    printf 'export SQUAD_POLICY_STATE_DIR=%q\n' "${base}/policy-state"
    printf 'source %q\n' "$SQUAD_POLICY_SH" "$CRED_LIB_SRC" "$PUSH_LIB_SRC" "$HUB_LIB_SRC" "$DEADLINE_LIB"
    printf '%s\n' "$LOG_FN" "$CHECKPOINT_FN" "$ON_ABORT_FN" "$REPORT_FN" "$COMMIT_PUSH_FN"
    # The pieces of the real session the blocks call that are not under test
    # here: credential withholding has its own suite, and hub preflight /
    # policy announcement only log.
    echo 'require() { :; }'
    echo 'squad_credential_should_withhold() { return 1; }'
    printf 'squad_hub_should_supervise() { return %s; }\n' "$([[ "$supervise" == 1 ]] && echo 0 || echo 1)"
    echo 'squad_hub_preflight() { :; }'
    echo 'squad_policy_announce() { :; }'
    echo 'SQUAD_POLICY_VERIFIED=0'
    echo 'SQUAD_POLICY_IN_VERIFY=0'
    printf 'REPO_DIR=%q\n' "${base}/client"
    echo 'export SQUAD_MODE=prompt SESSION_NAME=deadline-test GITHUB_REPOSITORY=octo/repo'
    echo 'export PUSH_CHANGES=true CREATE_PR=true'
    echo 'export SQUAD_PROMPT="Implement the feature."'
    echo 'export ASPIRE_OTLP_HTTP_ENDPOINT=http://otel.invalid SQUAD_HUB_URL=http://hub.invalid'
    echo 'COPILOT_ARGV=(--allow-all-tools --deny-tool "shell(git push)")'
    echo 'export SQUAD_REPLICA_TIMEOUT_SECONDS=90 SQUAD_PUBLISH_MARGIN_SECONDS=30'
    echo 'export SQUAD_DEADLINE_INT_GRACE_SECONDS=1 SQUAD_DEADLINE_TERM_GRACE_SECONDS=1'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
    echo 'cd "$REPO_DIR"'
    echo 'squad_policy_harden "$REPO_DIR" >/dev/null'
    printf 'export SQUAD_SESSION_START_EPOCH=$((EPOCHSECONDS - 60 + %d))\n' "$offset"
    echo 'trap '"'"'echo "SESSION_EXIT=$?"'"'"' EXIT'
    printf '%s\n' "${!block_var}"
  } >"$driver"
  bash "$driver" 2>&1
}

# Seconds from "hardened" to the deadline in the scenarios that time out.
TIMED_OUT_OFFSET=4

remote_branch() { git --git-dir="${WORK}/$1/remote.git" rev-parse --verify -q "refs/heads/$2" 2>/dev/null || echo none; }
remote_main() { git --git-dir="${WORK}/$1/remote.git" rev-parse refs/heads/main; }
gh_call() { tr '\0' '\n' <"${WORK}/$1/stub/gh-call-$2" 2>/dev/null; }
gh_call_flat() { tr '\0' '|' <"${WORK}/$1/stub/gh-call-$2" 2>/dev/null; }

# --- 5a. the acceptance case: an agent that never exits -------------------
t0=$SECONDS
out="$(run_session never PROMPT_BODY never-exits 0 "$TIMED_OUT_OFFSET")"
elapsed=$((SECONDS - t0))
branch="$(remote_branch never squad/deadline-test)"
assert_contains "$out" "SESSION_EXIT=124" \
  "acceptance: a never-exiting agent (timeout 90, margin 30) ends the session with exit 124 -- timed out, distinguishable"
assert_ne "none" "$branch" "acceptance: the branch squad/deadline-test IS pushed to the remote before the session ends"
if [[ "$branch" != none ]]; then
  subject="$(git --git-dir="${WORK}/never/remote.git" log -1 --format=%s "$branch")"
  body="$(git --git-dir="${WORK}/never/remote.git" log -1 --format=%b "$branch")"
  assert_eq "WIP: Remote Squad session deadline-test (stopped at session deadline)" "$subject" \
    "acceptance: the pushed commit is clearly marked WIP"
  assert_contains "$body" "UNFINISHED" "acceptance: the WIP commit body says the work is unfinished"
  files="$(git --git-dir="${WORK}/never/remote.git" show --name-only --format= "$branch" | sort | tr '\n' ' ')"
  assert_eq "src/app.js src/wip-feature.js " "$files" \
    "acceptance: the WIP commit carries the agent's modified AND new files -- and nothing else"
  assert_eq "" "$(git --git-dir="${WORK}/never/remote.git" diff "$(remote_main never)" "$branch" -- .squad/memory/config.json)" \
    "acceptance: the published branch carries NO .squad/memory/config.json diff (the session-only pin never leaves the container)"
fi
assert_eq "$OFFERED" "$(tr '\n' ' ' <"${WORK}/never/stub/signals" 2>/dev/null | sed 's/ $//')" \
  "acceptance: the agent was offered SIGINT, then SIGTERM, before being killed"
assert_eq "1" "$(pid_gone "$(cat "${WORK}/never/stub/agent.pid" 2>/dev/null)" && echo 1 || echo 0)" \
  "acceptance: the agent process is gone after the session"
gh1="$(gh_call never 1)"
assert_contains "$gh1" "--draft" "acceptance: the pull request is opened as a DRAFT"
assert_contains "$gh1" "WIP: Remote Squad session deadline-test" "acceptance: the pull request title is marked WIP"
assert_contains "$gh1" "WIP: this session stopped at its deadline" "acceptance: the pull request body says it stopped at the session deadline"
assert_contains "$gh1" "## Remaining" "acceptance: the pull request body has a Remaining checklist"
assert_contains "$gh1" "Created by Azure-hosted Squad session deadline-test." "acceptance: the body the PR would have had is still there, under the banner"
assert_eq "0" "$(ls "${WORK}/never/stub" | grep -c '^gh-call-2' || true)" "acceptance: exactly one gh call (the draft succeeded)"
assert_contains "$(cat "${WORK}/never/stub/prompt.txt" 2>/dev/null)" "Session deadline:" \
  "acceptance: the agent's prompt stated the session deadline"
assert_eq "1" "$(( elapsed < 40 ? 1 : 0 ))" "acceptance: the whole timed-out session took ${elapsed}s, far inside the 90 s 'replica timeout'"

# --- 5b. golden: a session that finishes before the deadline ---------------
out="$(run_session golden PROMPT_BODY finish 0 7200)"
assert_contains "$out" "SESSION_EXIT=0" "golden: a session that finishes before the deadline exits 0"
assert_not_contains "$out" "deadline reached" "golden: the watchdog never fired"
branch="$(remote_branch golden squad/deadline-test)"
assert_ne "none" "$branch" "golden: the branch is pushed"
assert_eq "Remote Squad session deadline-test" "$(git --git-dir="${WORK}/golden/remote.git" log -1 --format=%B "$branch" | sed '/^$/d')" \
  "golden: the commit message is exactly the pre-#134 default"
assert_eq "pr|create|--repo|octo/repo|--base|main|--head|squad/deadline-test|--title|Remote Squad session deadline-test|--body|Created by Azure-hosted Squad session deadline-test.|" \
  "$(gh_call_flat golden 1)" \
  "golden: gh pr create receives exactly the pre-#134 argv -- no --draft, no WIP"
assert_eq "" "$(git --git-dir="${WORK}/golden/remote.git" diff "$(remote_main golden)" "$branch" -- .squad/memory/config.json)" \
  "golden: no .squad/memory/config.json diff either"

# --- 5c. a failing agent: unchanged -----------------------------------------
out="$(run_session failing PROMPT_BODY fail 0 7200)"
assert_contains "$out" "SESSION_EXIT=3" "a failing agent (not timed out) still ends the session with ITS status"
assert_eq "none" "$(remote_branch failing squad/deadline-test)" "... and still publishes nothing, as before"
assert_eq "0" "$(ls "${WORK}/failing/stub" | grep -c '^gh-call-' || true)" "... and opens no pull request"

# --- 5d. the WIP publish is still pin-guarded ------------------------------
out="$(run_session pin PROMPT_BODY pin-adversary 0 "$TIMED_OUT_OFFSET")"
assert_contains "$out" "SESSION_EXIT=78" \
  "an agent that force-stages .squad/memory/config.json and hangs is stopped -- and the WIP publish is REFUSED by the pin guard (78)"
assert_eq "none" "$(remote_branch pin squad/deadline-test)" \
  "... nothing is pushed: the WIP path goes through the same pin guard, it does not bypass it"
assert_eq "0" "$(ls "${WORK}/pin/stub" | grep -c '^gh-call-' || true)" "... and no pull request is opened"

# --- 5e. the squad-hub oneshot path ----------------------------------------
out="$(run_session hub PROMPT_BODY none 1 "$TIMED_OUT_OFFSET")"
assert_contains "$out" "SESSION_EXIT=124" "hub path: a squad-hub oneshot still running at the deadline ends the session with 124"
branch="$(remote_branch hub squad/deadline-test)"
assert_ne "none" "$branch" "hub path: the WIP branch is pushed"
if [[ "$branch" != none ]]; then
  assert_contains "$(git --git-dir="${WORK}/hub/remote.git" log -1 --format=%s "$branch")" "WIP:" "hub path: the commit is marked WIP"
fi
assert_contains "$(gh_call hub 1)" "--draft" "hub path: the PR is a draft"
assert_eq "1" "$(pid_gone "$(cat "${WORK}/hub/stub/hub.pid" 2>/dev/null)" && echo 1 || echo 0)" \
  "hub path: the squad-hub process -- which ignored INT and TERM and outlived its parent subshell -- is gone (swept from the process group)"
assert_contains "$(cat "${WORK}/hub/stub/prompt.txt" 2>/dev/null)" "Session deadline:" \
  "hub path: the hub-supervised agent's prompt states the deadline too"

out="$(run_session hub-resolver PROMPT_BODY none 1 7200 \
  'squad_hub_policy_json() { squad_hub_abort "The policy resolver produced no hub argv (exit 1): stubbed failure"; }')"
assert_contains "$out" "SESSION_EXIT=78" \
  "hub path: a policy-resolver failure inside the watchdogged job still REFUSES the session (78) -- errexit is live"
assert_eq "0" "$([[ -e "${WORK}/hub-resolver/stub/hub.pid" ]] && echo 1 || echo 0)" \
  "... and squad-hub was never launched with an empty policy"
assert_eq "none" "$(remote_branch hub-resolver squad/deadline-test)" "... and nothing is published"

# --- 5f. new-project: same watchdog, its own branch and title --------------
out="$(run_session newproj NEWPROJ_BODY never-exits 0 "$TIMED_OUT_OFFSET" 'unset PUSH_CHANGES')"
assert_contains "$out" "SESSION_EXIT=124" "new-project: a never-exiting agent also ends with 124"
branch="$(remote_branch newproj squad/bootstrap-deadline-test)"
assert_ne "none" "$branch" "new-project: its bootstrap branch is pushed"
if [[ "$branch" != none ]]; then
  assert_contains "$(git --git-dir="${WORK}/newproj/remote.git" log -1 --format=%s "$branch")" "WIP:" "new-project: the commit is marked WIP"
fi
gh1="$(gh_call newproj 1)"
assert_contains "$gh1" "--draft" "new-project: the PR is a draft"
assert_contains "$gh1" "WIP: Bootstrap project with Squad on ACA" "new-project: its own PR title, marked WIP"

# --- 5g. no draft PRs on this repository: still a PR, still WIP -----------
out="$(run_session nodraft PROMPT_BODY never-exits 0 "$TIMED_OUT_OFFSET" 'export GH_FAIL_DRAFT=1')"
assert_contains "$out" "SESSION_EXIT=124" "no-draft repo: the session still ends 124"
assert_contains "$(gh_call nodraft 1)" "--draft" "no-draft repo: a draft was tried first"
gh2="$(gh_call nodraft 2)"
assert_not_contains "$gh2" "--draft" "no-draft repo: then a regular PR is opened, so the pushed work still gets one"
assert_contains "$gh2" "WIP: Remote Squad session deadline-test" "no-draft repo: ... still titled WIP"
assert_contains "$gh2" "WIP: this session stopped at its deadline" "no-draft repo: ... and still described as WIP"

# ===========================================================================
# 6. Deployment wiring and image layout
# ===========================================================================
echo "-- 6. deploy.ps1 and the Dockerfile --"
deploy="$(cat "$DEPLOY_PS1")"
assert_contains "$deploy" '[int]$SessionReplicaTimeout = 14400' "deploy.ps1 has -SessionReplicaTimeout, default 14400"
session_create="$(awk '/az containerapp job create/ {c++} c == 1' "$DEPLOY_PS1" | awk '/Out-Null/ {print; exit} {print}')"
assert_contains "$session_create" '--name $jobName' "(the first job create in deploy.ps1 is the session job)"
assert_contains "$session_create" '--replica-timeout $SessionReplicaTimeout' "session job create: --replica-timeout comes from the parameter"
assert_contains "$session_create" '$sessionTimeoutEnv' "session job create: SQUAD_REPLICA_TIMEOUT_SECONDS is set from the same parameter"
session_update="$(grep 'az containerapp job update --name \$jobName ' "$DEPLOY_PS1")"
assert_contains "$session_update" '--replica-timeout $SessionReplicaTimeout' "session job update: --replica-timeout comes from the parameter"
assert_contains "$session_update" '$sessionTimeoutEnv' "session job update: SQUAD_REPLICA_TIMEOUT_SECONDS is set from the same parameter"
assert_contains "$deploy" '$sessionTimeoutEnv = "SQUAD_REPLICA_TIMEOUT_SECONDS=$SessionReplicaTimeout"' \
  "the env value is built from the parameter, so the two cannot drift"
assert_not_contains "$deploy" '--replica-timeout 7200' "the hard-coded 7200 is gone"
assert_eq "2" "$(grep -c -- '--replica-timeout 240' "$DEPLOY_PS1")" "the ralph job keeps its own 240 s budget (create and update), untouched"
assert_not_contains "$(awk '/^\$commonEnv = @\(/,/^\)/' "$DEPLOY_PS1")" "SQUAD_REPLICA_TIMEOUT_SECONDS" \
  "SQUAD_REPLICA_TIMEOUT_SECONDS is NOT in \$commonEnv, which the ralph job and watch app share"

docker="$(cat "$DOCKERFILE")"
assert_contains "$(grep '^COPY .*worker/lib/' "$DOCKERFILE")" "worker/lib/squad-deadline.sh" "the Dockerfile ships worker/lib/squad-deadline.sh"
assert_contains "$(grep "sed -i 's/\\\\r\$//'" "$DOCKERFILE")" "/usr/local/lib/squad-on-aca/squad-deadline.sh" \
  "the Dockerfile strips CRLF from it like every other sourced library"
assert_contains "$(cat "$ENTRYPOINT")" 'SQUAD_DEADLINE_LIB="${SQUAD_DEADLINE_LIB:-/usr/local/lib/squad-on-aca/squad-deadline.sh}"' \
  "entrypoint.sh sources it from where the image installs it"
: "$docker"

test_summary
