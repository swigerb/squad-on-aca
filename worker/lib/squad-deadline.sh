#!/usr/bin/env bash
# Issue #134: publish the agent's work BEFORE the session's hard deadline.
#
# THE FAILURE MODE
# ----------------
# In `prompt` and `new-project` mode the worker publishes (commit_and_push_if_
# needed in worker/entrypoint.sh) only AFTER the agent exits. The session job's
# ACA `replicaTimeout` is a hard kill: when it fires, the replica is stopped
# whether or not the agent has finished, and nothing in that path published
# what was already in the checkout. A session still working at the limit
# therefore ended with nothing pushed -- up to the WHOLE replica timeout of
# agent work lost, not delayed. Live evidence: squad-hub #165 and #166
# (executions caj-squad-aca-session-7755n6o and -moxu6gw, 2026-10-05) both hit
# the 2 h limit and ended Failed with no branch; session
# `129-safe-prompt-dispatch` came within 35 minutes of it with no commits.
#
# Reacting to the platform's SIGTERM is NOT a fix, and that is measured, not
# assumed. A container started as root (production) drops privileges with
# `exec runuser`, so PID 1 is util-linux runuser, not this script. runuser
# 2.38.1 (Debian bookworm, this image's base) handles a SIGTERM by forwarding
# SIGTERM to its child, `sleep(2)`, then SIGKILL -- login-utils/su-common.c,
# the `if (caught_signal)` block after wait_for_child(). So a worker that only
# starts publishing when ACA's SIGTERM arrives has about two seconds to commit,
# pass the governance checkpoint and push: not a window anything can rely on.
#
# THE FIX: A SOFT DEADLINE THE WORKER OWNS
# ----------------------------------------
# 1. The worker computes its own deadline, comfortably BEFORE the hard kill
#    (squad_deadline_compute):
#
#        deadline = container start + SQUAD_REPLICA_TIMEOUT_SECONDS (7200)
#                                   - SQUAD_PUBLISH_MARGIN_SECONDS  (900)
#
#    and, when the control plane says when the push credential expires
#    (SQUAD_TOKEN_EXPIRES_AT -- see worker/lib/squad-token-preflight.sh), an
#    EARLIER `expiry - margin` wins, because a push after the token expires
#    loses the work exactly as surely as a push after the replica is killed.
#    scripts/deploy.ps1 sets SQUAD_REPLICA_TIMEOUT_SECONDS and the job's
#    `--replica-timeout` from ONE parameter, so the two cannot drift; the
#    7200 default matches the session job's historical timeout for a template
#    deployed before that parameter existed.
#
# 2. The deadline is exported to the agent as SQUAD_SESSION_DEADLINE_UTC and
#    stated in its prompt (squad_publish_contract_note, worker/lib/squad-
#    push.sh), so a well-behaved agent commits a coherent slice and stops on
#    its own -- the cheap, cooperative half.
#
# 3. The agent runs under a watchdog (squad_deadline_run_agent). At the
#    deadline the worker stops it: SIGINT to its whole process group (Copilot
#    CLI and squad-hub both treat SIGINT as "stop"), then SIGTERM after
#    SQUAD_DEADLINE_INT_GRACE_SECONDS (60), then SIGKILL after a further
#    SQUAD_DEADLINE_TERM_GRACE_SECONDS (30). The worst case is therefore 90 s
#    of the 900 s margin, which leaves well over ten minutes for the publish.
#    The caller then runs the SAME commit_and_push_if_needed as a session that
#    finished -- same governance checkpoint, same pin-leak guard, same push
#    path -- with only its commit message, PR title/body and the PR's draft
#    flag changed (squad_deadline_wip_*), and ends the session with exit 124
#    (SQUAD_EXIT_DEADLINE, the conventional timeout(1) code) so a timed-out
#    session is distinguishable from both success and an ordinary failure.
#
# WHAT THIS DELIBERATELY DOES NOT DO
# ----------------------------------
# It does not trap the platform's SIGTERM to make a last-ditch push (issue
# #134 scope item 3, optional). Two reasons, both above: runuser leaves ~2 s,
# and a SIGTERM before the soft deadline is overwhelmingly an INTENTIONAL stop
# -- `squad-aca stop` cancels the execution (Stop-SquadExecution), which ACA
# enacts with SIGTERM -- and publishing a pull request for a session someone
# just cancelled would be the wrong answer to "stop". A shutdown signal
# therefore keeps exactly the disposition it had before this change.
#
# It does not change anything for a session that finishes before the
# deadline: no extra signal, no extra wait, the agent's own exit code, the
# same commit message and the same pull request (worker/tests/test_session_
# deadline.sh holds that as a golden test).
#
# Factored into a library, like squad-push.sh and squad-signal-forwarding.sh,
# because nothing under worker/tests/ sources entrypoint.sh: signal and
# exit-code handling written inline there would be logic no test can reach.
#
# Sourced by worker/entrypoint.sh (bash) and by worker/tests/test_session_
# deadline.sh.

# shellcheck shell=bash

if [[ -z "${SQUAD_EXIT_DEADLINE:-}" ]]; then
    SQUAD_EXIT_DEADLINE=124
fi

SQUAD_DEADLINE_DEFAULT_REPLICA_TIMEOUT_SECONDS=7200
SQUAD_DEADLINE_DEFAULT_PUBLISH_MARGIN_SECONDS=900
SQUAD_DEADLINE_DEFAULT_INT_GRACE_SECONDS=60
SQUAD_DEADLINE_DEFAULT_TERM_GRACE_SECONDS=30

# Session state. Reset when the library is sourced, so neither a value
# inherited from the dispatcher's environment nor one left by a previous
# caller can mark a session as timed out (which would turn its pull request
# into a draft) or hand the agent a deadline this worker did not compute.
SQUAD_SESSION_TIMED_OUT=0
SQUAD_SESSION_DEADLINE_EPOCH=""
SQUAD_SESSION_DEADLINE_SOURCE=""
SQUAD_DEADLINE_AGENT_RC=0
unset SQUAD_SESSION_DEADLINE_UTC

squad_deadline_log() {
    if declare -f log >/dev/null 2>&1; then
        log "$@"
    else
        printf '%s\n' "$*" >&2
    fi
}

squad_deadline_iso() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# A non-negative whole number of seconds from $1, or $2 (the default) with a
# log line when $1 is set to anything else. Only for the internal grace
# knobs, where falling back to the documented default is always safe; the
# two inputs that decide WHEN the deadline is are validated strictly in
# squad_deadline_compute instead.
_squad_deadline_seconds_or_default() {
    local name="$1" default="$2" value
    value="${!name:-}"
    if [[ -z "$value" ]]; then
        printf '%s' "$default"
        return 0
    fi
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        squad_deadline_log "${name}='${value}' is not a whole number of seconds; using the default ${default}s." >&2
        printf '%s' "$default"
        return 0
    fi
    printf '%s' "$((10#$value))"
}

# Compute the session deadline from a start instant (epoch seconds).
#
# Sets SQUAD_SESSION_DEADLINE_EPOCH and SQUAD_SESSION_DEADLINE_SOURCE
# (`replica-timeout` or `token-expiry`) in THIS shell rather than printing
# them: entrypoint.sh's log() writes to stdout, so a `$(...)` caller would
# capture its own log lines as the answer.
#
# Returns 64 (configuration error, the code the token preflight uses for an
# unusable SQUAD_ESTIMATED_RUN_MINUTES) when the two inputs that decide the
# deadline are not usable. That is a refusal BEFORE the agent starts, not a
# silent default: a typo here would otherwise either kill every session at
# start-up or quietly restore the exact lose-everything behaviour this exists
# to remove.
squad_deadline_compute() {
    local start="$1"
    local timeout="${SQUAD_REPLICA_TIMEOUT_SECONDS:-$SQUAD_DEADLINE_DEFAULT_REPLICA_TIMEOUT_SECONDS}"
    local margin="${SQUAD_PUBLISH_MARGIN_SECONDS:-$SQUAD_DEADLINE_DEFAULT_PUBLISH_MARGIN_SECONDS}"
    local deadline source expires token_deadline

    if [[ ! "$start" =~ ^[0-9]+$ ]]; then
        squad_deadline_log "The session start instant '${start}' is not an epoch-seconds value; cannot compute the session deadline."
        return 64
    fi
    if [[ ! "$timeout" =~ ^[0-9]+$ ]] || (( 10#$timeout == 0 )); then
        squad_deadline_log "SQUAD_REPLICA_TIMEOUT_SECONDS='${timeout}' is not a positive whole number of seconds."
        squad_deadline_log "  It must equal the session job's ACA replicaTimeout (scripts/deploy.ps1 -SessionReplicaTimeout sets both). Refusing to start rather than guess when the replica will be killed."
        return 64
    fi
    if [[ ! "$margin" =~ ^[0-9]+$ ]]; then
        squad_deadline_log "SQUAD_PUBLISH_MARGIN_SECONDS='${margin}' is not a whole number of seconds."
        return 64
    fi
    timeout=$((10#$timeout))
    margin=$((10#$margin))
    if (( margin >= timeout )); then
        squad_deadline_log "SQUAD_PUBLISH_MARGIN_SECONDS (${margin}) is not smaller than SQUAD_REPLICA_TIMEOUT_SECONDS (${timeout}); the deadline would fall at or before the session even starts."
        return 64
    fi

    deadline=$((start + timeout - margin))
    source="replica-timeout"

    if [[ -n "${SQUAD_TOKEN_EXPIRES_AT:-}" ]]; then
        if expires="$(date -u -d "$SQUAD_TOKEN_EXPIRES_AT" +%s 2>/dev/null)"; then
            token_deadline=$((expires - margin))
            if (( token_deadline < deadline )); then
                deadline="$token_deadline"
                source="token-expiry"
            fi
        else
            # Not a refusal HERE: the token preflight is the gate that owns
            # this variable and already refuses an unparseable value (exit
            # 64) when it runs. If it was deliberately disabled, the replica
            # deadline still applies, which is strictly better than none.
            squad_deadline_log "SQUAD_TOKEN_EXPIRES_AT='${SQUAD_TOKEN_EXPIRES_AT}' could not be parsed as a date; the session deadline uses the replica timeout only."
        fi
    fi

    SQUAD_SESSION_DEADLINE_EPOCH="$deadline"
    SQUAD_SESSION_DEADLINE_SOURCE="$source"
    return 0
}

# Compute the deadline for THIS session, export SQUAD_SESSION_DEADLINE_UTC to
# the agent, and say what was decided. Must run BEFORE the agent's prompt is
# composed, because squad_publish_contract_note reads the exported value.
#
# The start instant is SQUAD_SESSION_START_EPOCH, recorded by entrypoint.sh as
# the first thing it does (before the privilege drop, so the re-exec cannot
# move it), falling back to "now" for a caller that did not record one.
squad_session_deadline_init() {
    local start="${SQUAD_SESSION_START_EPOCH:-$EPOCHSECONDS}" rc=0
    squad_deadline_compute "$start" || rc=$?
    if (( rc != 0 )); then
        return "$rc"
    fi
    SQUAD_SESSION_DEADLINE_UTC="$(squad_deadline_iso "$SQUAD_SESSION_DEADLINE_EPOCH")" || return 64
    export SQUAD_SESSION_DEADLINE_UTC

    local timeout="${SQUAD_REPLICA_TIMEOUT_SECONDS:-$SQUAD_DEADLINE_DEFAULT_REPLICA_TIMEOUT_SECONDS}"
    local margin="${SQUAD_PUBLISH_MARGIN_SECONDS:-$SQUAD_DEADLINE_DEFAULT_PUBLISH_MARGIN_SECONDS}"
    squad_deadline_log "Session deadline: ${SQUAD_SESSION_DEADLINE_UTC} (from the ${SQUAD_SESSION_DEADLINE_SOURCE}; replica timeout ${timeout}s, publish margin ${margin}s, session started $(squad_deadline_iso "$start"))."
    squad_deadline_log "  At the deadline the agent is stopped and whatever is in the checkout is published as a WIP commit on a DRAFT pull request, before the replica is killed (issue #134)."
    if (( SQUAD_SESSION_DEADLINE_EPOCH <= EPOCHSECONDS )); then
        squad_deadline_log "  The deadline has ALREADY passed (${SQUAD_SESSION_DEADLINE_SOURCE}); the agent will be stopped as soon as it starts."
    fi
    return 0
}

# Block until child $1 exits or the epoch-seconds instant $2 is reached.
#
#   0  the child exited; its exit status is in SQUAD_DEADLINE_AGENT_RC
#   1  the instant was reached and the child is still running
#
# The wait is `wait -n` on the child AND a `sleep` timer, so a child that
# exits early is noticed the moment it exits -- not at the next poll -- and a
# session that finishes before its deadline is not held back even one second.
# The timer is a plain `sleep`, a single process with no children of its own,
# so killing it cannot orphan anything (the issue #92 shape: a backgrounded
# loop whose `sleep` grandchild outlives it and holds the output pipe open).
#
# Looped rather than single-shot so a wait interrupted for any other reason
# (a trapped signal returns >128 with no pid named; a stray job reaped by
# `wait -n`) recomputes the time left and waits again instead of being
# mistaken for either outcome.
_squad_deadline_wait_until() {
    local pid="$1" until="$2"
    local remaining timer finished rc

    while :; do
        remaining=$((until - EPOCHSECONDS))
        if (( remaining <= 0 )); then
            if kill -0 "$pid" 2>/dev/null; then
                return 1
            fi
            # Exited (or is a zombie awaiting reap) in the same second the
            # time ran out: that is "exited", and its status is still ours.
            rc=0
            wait "$pid" 2>/dev/null || rc=$?
            SQUAD_DEADLINE_AGENT_RC="$rc"
            return 0
        fi

        sleep "$remaining" &
        timer=$!
        finished=""
        rc=0
        wait -n -p finished "$pid" "$timer" 2>/dev/null || rc=$?

        if [[ "$finished" == "$pid" ]]; then
            kill "$timer" 2>/dev/null || true
            wait "$timer" 2>/dev/null || true
            SQUAD_DEADLINE_AGENT_RC="$rc"
            return 0
        fi
        if [[ "$finished" == "$timer" ]]; then
            continue
        fi

        kill "$timer" 2>/dev/null || true
        wait "$timer" 2>/dev/null || true
        if ! kill -0 "$pid" 2>/dev/null; then
            rc=0
            wait "$pid" 2>/dev/null || rc=$?
            SQUAD_DEADLINE_AGENT_RC="$rc"
            return 0
        fi
    done
}

# Run "$@" (the agent) under the session deadline, epoch seconds in $1.
#
# Reports through two variables and RETURNS 0 (64 only for an unusable
# deadline argument -- a refusal before anything is started):
#
#   SQUAD_DEADLINE_AGENT_RC   the agent's own exit status
#   SQUAD_SESSION_TIMED_OUT   0 if it exited by itself before the deadline,
#                             1 if the watchdog had to stop it
#
#   * finishes before the deadline: nothing else happens. The caller
#     (squad_deadline_settle_agent) then treats its status exactly as the
#     `set -e` subshell this replaces did.
#   * still running at the deadline: SIGINT, SIGTERM, SIGKILL in turn to the
#     agent's whole process group (see the header for the timings), then any
#     process still left in that group is SIGKILLed.
#
# WHY IT MUST BE CALLED AS A PLAIN STATEMENT, NEVER `... || rc=$?`. Measured
# on bash 5.2: a background job forked inside a function that runs where
# `set -e` is being ignored (the left side of `||`/`&&`, an `if` condition)
# INHERITS that suppression, and a `set -e` inside the job cannot turn it back
# on. squad_hub_run relies on errexit -- `policy_json="$(squad_hub_policy_
# json)"` is what stops the session when the policy resolver aborts -- so
# under `|| rc=$?` a resolver failure would fall through and launch
# `squad-hub oneshot` with an EMPTY policy argv instead of refusing. The old
# `( squad_policy_exec_agent ... )` was a plain statement with errexit live in
# the subshell; returning 0 and reporting through variables is what lets this
# stay one too. worker/tests/test_session_deadline.sh holds that as a test.
#
# The agent is started as a background job WITH JOB CONTROL ON (`set -m`), for
# two reasons that are each load-bearing:
#
#   * its own process group (pgid == its pid), so ONE signal reaches the whole
#     tree. On the squad-hub path the job is a bash subshell running
#     squad_hub_run, whose foreground child is `squad-hub oneshot`, whose
#     child is `copilot --acp`; signalling only the subshell's pid would kill
#     the subshell and leave the agent running, unsupervised, still editing
#     the checkout the worker is about to commit.
#   * bash makes a background job started WITHOUT job control ignore SIGINT
#     (and an ignored signal stays ignored across exec), so the polite first
#     signal would never arrive at all. Verified with a stub that traps INT:
#     it receives it under `set -m` and does not without.
#
# The job runs the command exactly as the old `( squad_policy_exec_agent ... )`
# subshell did -- it is still a subshell, so squad_policy_exec_agent's
# "never in the hardening shell" guard is satisfied and its descriptor
# closing still happens in the child -- and `set -m` is restored to the
# caller's setting immediately after the fork.
#
# The leftover-process sweep happens ONLY after a timeout. Its point is that
# nothing the stopped agent started (a test runner, a build) is still writing
# into the tree while commit_and_push_if_needed stages and commits it. On the
# normal path nothing is swept, exactly as before.
squad_deadline_run_agent() {
    local deadline="$1"
    shift
    local int_grace term_grace agent_pid had_monitor=0 rc

    SQUAD_SESSION_TIMED_OUT=0
    SQUAD_DEADLINE_AGENT_RC=0

    if [[ ! "$deadline" =~ ^[0-9]+$ ]]; then
        squad_deadline_log "No usable session deadline ('${deadline}'); refusing to run the agent without one."
        return 64
    fi
    int_grace="$(_squad_deadline_seconds_or_default SQUAD_DEADLINE_INT_GRACE_SECONDS "$SQUAD_DEADLINE_DEFAULT_INT_GRACE_SECONDS")"
    term_grace="$(_squad_deadline_seconds_or_default SQUAD_DEADLINE_TERM_GRACE_SECONDS "$SQUAD_DEADLINE_DEFAULT_TERM_GRACE_SECONDS")"

    [[ "$-" == *m* ]] && had_monitor=1
    set -m
    "$@" &
    agent_pid=$!
    if (( had_monitor == 0 )); then
        set +m
    fi

    if _squad_deadline_wait_until "$agent_pid" "$deadline"; then
        return 0
    fi

    SQUAD_SESSION_TIMED_OUT=1
    squad_deadline_log "Session deadline ${SQUAD_SESSION_DEADLINE_UTC:-$(squad_deadline_iso "$deadline")} reached with the agent still running (pid ${agent_pid}). Sending SIGINT to its process group so it can stop cleanly; the work in the checkout will be published as WIP (issue #134)."
    kill -INT -- "-${agent_pid}" 2>/dev/null || true

    if ! _squad_deadline_wait_until "$agent_pid" $((EPOCHSECONDS + int_grace)); then
        squad_deadline_log "The agent is still running ${int_grace}s after SIGINT; sending SIGTERM to its process group."
        kill -TERM -- "-${agent_pid}" 2>/dev/null || true
        if ! _squad_deadline_wait_until "$agent_pid" $((EPOCHSECONDS + term_grace)); then
            squad_deadline_log "The agent is still running ${term_grace}s after SIGTERM; sending SIGKILL to its process group."
            kill -KILL -- "-${agent_pid}" 2>/dev/null || true
            rc=0
            wait "$agent_pid" 2>/dev/null || rc=$?
            SQUAD_DEADLINE_AGENT_RC="$rc"
        fi
    fi

    if kill -KILL -- "-${agent_pid}" 2>/dev/null; then
        squad_deadline_log "Sent SIGKILL to whatever was still left in the agent's process group, so nothing is still writing to the checkout while it is committed."
    fi
    squad_deadline_log "The agent stopped at the session deadline (its exit status: ${SQUAD_DEADLINE_AGENT_RC})."
    return 0
}

# What the caller does with the agent's outcome, BEFORE it publishes.
#
#   $1  the repository directory
#
# Reads SQUAD_DEADLINE_AGENT_RC and SQUAD_SESSION_TIMED_OUT, as left by
# squad_deadline_run_agent.
#
# Not timed out: a non-zero agent status ends the session with that status
# right here, exactly as the `set -e` subshell it replaces did -- nothing
# published. That is today's behaviour for a failed agent, and this change
# keeps it.
#
# Timed out: returns 0 so the caller goes on to publish. A git index lock
# left by an agent stopped mid-`git add`/`git commit` is removed first: every
# process of the agent's group is dead by now (squad_deadline_run_agent swept
# it), so the lock is stale by construction, and leaving it would make the
# WIP commit fail and lose the work this whole path exists to save.
squad_deadline_settle_agent() {
    local repo_dir="${1:-}" rc="${SQUAD_DEADLINE_AGENT_RC:-0}"
    if [[ "${SQUAD_SESSION_TIMED_OUT:-0}" -eq 1 ]]; then
        if [[ -n "$repo_dir" && -f "${repo_dir}/.git/index.lock" ]]; then
            squad_deadline_log "Removing the stale .git/index.lock the stopped agent left behind, so the WIP commit can be made."
            rm -f "${repo_dir}/.git/index.lock"
        fi
        return 0
    fi
    if [[ "$rc" -ne 0 ]]; then
        exit "$rc"
    fi
    return 0
}

# After a timed-out session has published, end it with SQUAD_EXIT_DEADLINE.
# A no-op for every other session. The work is already on the branch by the
# time this runs, so a non-zero exit costs nothing and is the honest result:
# the brief was not finished. squad_lease_finish (worker/entrypoint.sh) records
# the reason as `session-deadline-exit-124`.
squad_deadline_finish_session() {
    if [[ "${SQUAD_SESSION_TIMED_OUT:-0}" -eq 1 ]]; then
        squad_deadline_log "Session ended at its deadline with the brief unfinished; exiting ${SQUAD_EXIT_DEADLINE} (timed out). Whatever was in the checkout has been published above."
        exit "$SQUAD_EXIT_DEADLINE"
    fi
    return 0
}

# --- the WIP labels commit_and_push_if_needed uses after a timeout ----------
# Worker-generated text only. Nothing the agent wrote (file names, commit
# messages) is interpolated into the commit message or the pull request body,
# so a hostile checkout cannot use the WIP path to put markup, mentions or
# links into either; what the agent left is described by count and commit.

# The base message may be multi-line: the Actions dispatcher passes a
# COMMIT_MESSAGE whose later paragraphs are "Requested by" and a
# Co-authored-by trailer. Only its FIRST line becomes the WIP subject; the
# rest is re-emitted unchanged at the END, so a trailer is still the last
# paragraph and git still parses it as one.
squad_deadline_wip_commit_message() {
    local base="$1" subject rest=""
    subject="${base%%$'\n'*}"
    if [[ "$base" == *$'\n'* ]]; then
        rest="${base#*$'\n'}"
        rest="${rest#$'\n'}"
    fi
    printf 'WIP: %s (stopped at session deadline)\n\n%s\n' "$subject" \
        "The agent was still working when the session reached its deadline (${SQUAD_SESSION_DEADLINE_UTC:-unknown}), so the Squad on ACA worker stopped it and committed what was in the checkout as-is, so the work is not lost when the replica is killed (issue #134). This commit is UNFINISHED: it may not build, and its tests may not pass."
    if [[ -n "$rest" ]]; then
        printf '\n%s\n' "$rest"
    fi
}

squad_deadline_wip_pr_title() {
    printf 'WIP: %s' "$1"
}

#   $1  the body the pull request would have had
#   $2  the short sha of the worker's WIP commit, or "" if the agent left a
#       clean tree (its own commits are published unchanged)
#   $3  how many files that WIP commit contains
squad_deadline_wip_pr_body() {
    local base="$1" wip_commit="${2:-}" wip_files="${3:-0}"
    printf '> [!WARNING]\n'
    printf '> **WIP: this session stopped at its deadline (%s) before the agent finished.**\n' "${SQUAD_SESSION_DEADLINE_UTC:-unknown}"
    printf '> The Squad on ACA worker stopped the agent and published what was in the checkout so the work is not lost (issue #134). It is opened as a draft where the repository allows one; either way, do not merge it as-is.\n\n'
    printf '%s\n\n' "$base"
    printf '## Remaining\n\n'
    printf -- '- [ ] Finish the brief. The agent did not report completion before the deadline.\n'
    if [[ -n "$wip_commit" ]]; then
        printf -- '- [ ] Review WIP commit %s: %s file(s) the agent had not committed when it was stopped. They may be half-finished.\n' "$wip_commit" "$wip_files"
    fi
    printf -- '- [ ] Check the last commit message from the agent for its own "Remaining:" checklist, if it left one.\n'
    printf -- '- [ ] Run the tests and mark this pull request ready for review only when they pass.\n'
}
