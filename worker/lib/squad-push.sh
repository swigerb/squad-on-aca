#!/usr/bin/env bash
# Pushing the session branch, and surviving a credential that expired mid-run.
#
# This lives in a library rather than inline in entrypoint.sh for one reason:
# nothing in worker/tests/ sources entrypoint.sh, so logic written inline there
# is logic no test can reach. The exit-code handling below is precisely the kind
# that must be exercised, not inspected -- see the PR #9 note in
# squad_push_branch.
#
# Sourced by worker/entrypoint.sh (bash) and by worker/tests/test_push.sh.

# shellcheck shell=bash

if [[ -z "${SQUAD_EXIT_CREDENTIAL:-}" ]]; then
    SQUAD_EXIT_CREDENTIAL=77
fi

squad_push_log() {
    if declare -f log >/dev/null 2>&1; then
        log "$@"
    else
        printf '%s\n' "$*" >&2
    fi
}

# Push $1 to origin, refreshing the credential once if -- and only if -- the
# failure was the credential.
#
# RETURNS rather than exits so a test can observe the code. The caller is
# expected to `squad_push_branch "$b" || exit $?`.
#
#   0                       pushed (possibly on the retry)
#   $SQUAD_EXIT_CREDENTIAL  the credential was refused, and still refused after
#                           the token file was re-read
#   <git's exit code>       anything else -- a ruleset refusal, a non-fast-
#                           forward, a network fault. Deliberately NOT retried:
#                           re-reading a token cannot fix a branch protection
#                           rule, and pretending otherwise wastes a retry and
#                           misdescribes the fault.
squad_push_branch() {
    local branch="$1"
    local push_log push_rc push_kind

    push_log="$(mktemp)"

    # `push_rc=$?` must NOT be captured inside `if ! git push ...`. In the
    # then-branch of a negated condition, `$?` is the status of the NEGATION --
    # 0 exactly when the command failed -- so the real code is lost and the
    # caller's `|| exit $?` would exit 0, reporting a FAILED push as a
    # successful session. That is the defect that sank PR #9 here. Proven:
    #     if ! (exit 128); then rc=$?; fi    -> rc=0
    #     (exit 128) || rc=$?                 -> rc=128
    push_rc=0
    git push --set-upstream origin "$branch" >"$push_log" 2>&1 || push_rc=$?

    if (( push_rc == 0 )); then
        rm -f "$push_log"
        return 0
    fi

    push_kind="$(squad_credential_classify_git_failure "$(cat "$push_log")")"
    cat "$push_log" >&2

    if [[ "$push_kind" != "auth" ]]; then
        rm -f "$push_log"
        squad_push_log "Session FAILED: the push failed for a reason that is NOT a credential fault (git exit ${push_rc}). Nothing has been pushed."
        squad_push_log "  A branch ruleset refusal looks like this and exits 1, not 128 -- refreshing a token will not fix it."
        return "$push_rc"
    fi

    squad_push_log "The push was rejected because the CREDENTIAL was refused (git exit ${push_rc}). Re-reading the token file and retrying once."
    squad_credential_refresh_env || true

    push_rc=0
    git push --set-upstream origin "$branch" >"$push_log" 2>&1 || push_rc=$?

    if (( push_rc == 0 )); then
        rm -f "$push_log"
        squad_push_log "The retry succeeded: the token file had been refreshed and the branch is pushed."
        return 0
    fi

    cat "$push_log" >&2
    rm -f "$push_log"
    squad_push_log "Session FAILED (credential): the push was refused again after re-reading the token file (git exit ${push_rc})."
    squad_push_log "  The token this session started with can no longer push, and no refreshed token was delivered. Nothing has been pushed."
    squad_push_log "  ACA Sandboxes can be refreshed mid-session; ACA Jobs cannot (see docs/sandboxes.md, 'Refresh channel matrix'). Under Jobs, shorten the run or mint the token immediately before dispatch."
    return "$SQUAD_EXIT_CREDENTIAL"
}
