#!/usr/bin/env bash
# squad-credentials.sh
#
# Everything the worker does with the GitHub credential, in one place, so the
# entrypoint reads as a sequence of decisions rather than a pile of git plumbing.
#
# Sourced by worker/entrypoint.sh, which runs under bash with `set -Eeuo
# pipefail`, so bash syntax is legitimate here. The CREDENTIAL HELPER
# (squad-git-credential-helper.sh) is a separate file and is strict POSIX sh,
# because git executes it directly on an image whose /bin/sh is dash.
#
# THE PROBLEM THIS SOLVES (issue #32). A GitHub App installation token has a
# hard 1-hour TTL. A Squad session clones, runs an agent for 10-60 minutes, then
# pushes. Baking the token into git config at session start means the push at
# the END uses a credential captured at the BEGINNING. Measured:
#
#     clone with an expired token, public repo -> exit 0 (succeeds, no warning)
#     push  with an expired token              -> exit 128, "Invalid username or token"
#     the session aborts (`set -Eeuo pipefail`, unguarded call site)
#
# The failure is loud but maximally late: after the agent has finished, so the
# whole run is spent and nothing is pushed.
#
# THE SHAPE OF THE FIX, in three parts:
#
#   1. A token FILE (mode 0600) that is the single source of truth, plus a git
#      credential helper that re-reads it on EVERY git operation. A refreshed
#      file is picked up with no re-clone and no git config rewrite. Proven by
#      probe: expired token -> push exit 128 -> rewrite ONLY the token file ->
#      push exit 0, same repository, same process.
#   2. `gh` re-reads the same file into its environment immediately before each
#      invocation that matters. `gh` is a FRESH PROCESS every time, but an
#      already-exported GH_TOKEN in this long-running shell would hand it the
#      stale value.
#   3. A push failure that is really a credential fault is CLASSIFIED as one and
#      retried once against the current file contents, instead of being reported
#      as a generic execution failure.
#
# Nothing here ever puts the token in argv, in `git config` output, in `ps`, or
# in a log line.

# EX_NOPERM. The exit code a session uses when the credential -- not the work --
# is what failed. It is deliberately distinct from 64 (usage), 70 (internal) and
# 78 (config) which this entrypoint already uses, so a control plane can tell
# "rotate the credential" from "fix the deployment" from "inspect the session".
#
# This is unrelated to the 77 that worker/tests/run-tests.sh uses as its SKIP
# code; that number lives in the test harness domain and never becomes a
# session's exit status.
SQUAD_EXIT_CREDENTIAL=77

# Where the token lives. The control plane may override it (the ACA Sandboxes
# provider points it at the 0700 session state directory it can write into); the
# default is a private directory in the worker's own home.
export SQUAD_GIT_TOKEN_FILE="${SQUAD_GIT_TOKEN_FILE:-${HOME:-/home/squad}/.squad-on-aca/git-token}"

# The host the helper is scoped to. Overridable so a probe can point the whole
# mechanism at a local authenticated server rather than github.com -- which is
# the only way to prove the helper is actually CONSULTED, since a clone of a
# public repository succeeds whether or not it was.
export SQUAD_GIT_CREDENTIAL_HOST="${SQUAD_GIT_CREDENTIAL_HOST:-github.com}"

SQUAD_GIT_CREDENTIAL_HELPER="${SQUAD_GIT_CREDENTIAL_HELPER:-/usr/local/lib/squad-on-aca/squad-git-credential-helper.sh}"

squad_credentials_log() {
  printf '[squad-credentials] %s\n' "$*"
}

# ---------------------------------------------------------------------------
# The token file
# ---------------------------------------------------------------------------

# Write a token to the token file with the content never appearing in argv.
# The directory is created under `umask 077` and the file is created by a
# redirection under the same umask, so it is 0600 from the instant it exists --
# never written wide and narrowed afterwards, which would leave a window.
squad_credential_write_token() {
  local token="$1"
  local dir
  dir="$(dirname "$SQUAD_GIT_TOKEN_FILE")"
  ( umask 077; mkdir -p "$dir" ) || return 1
  chmod 700 "$dir" 2>/dev/null || true
  ( umask 077; printf '%s\n' "$token" > "$SQUAD_GIT_TOKEN_FILE" ) || return 1
  chmod 600 "$SQUAD_GIT_TOKEN_FILE" 2>/dev/null || true
  return 0
}

# Echo the CURRENT token. Returns non-zero (and echoes nothing) when there is
# none, so a caller can distinguish "no credential configured" from "empty
# credential" without inspecting the file itself.
squad_credential_read_token() {
  local token=""
  [[ -r "$SQUAD_GIT_TOKEN_FILE" ]] || return 1
  IFS= read -r token 2>/dev/null < "$SQUAD_GIT_TOKEN_FILE" || token=""
  token="${token%$'\r'}"
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

# ---------------------------------------------------------------------------
# git wiring
# ---------------------------------------------------------------------------

# Install the credential helper and REMOVE everything that could answer instead
# of it.
#
# Three separate hazards are closed here, in this order, and the order matters:
#
#   1. A leftover `url.<...>.insteadOf` rewrite (what this change replaces)
#      would rewrite the remote URL to embed a FROZEN token, and the helper
#      would never be consulted at all. Any config that survived from an earlier
#      image or an earlier run in the same HOME is removed.
#   2. A pre-existing `credential.helper` (from /etc/gitconfig, from the base
#      image, or from a future change here) is consulted alongside ours, and
#      git uses the FIRST helper that answers. A stale cached credential would
#      therefore win over a freshly refreshed file. Both the generic key and the
#      host-scoped key are cleared.
#   3. git resets a helper LIST when it sees an empty helper value, so the empty
#      entry is written first and ours is appended after it. That is what makes
#      a helper configured in a lower-priority file (system config) unable to
#      come back.
#
# The helper is configured with an ABSOLUTE PATH. git treats a helper value
# starting with `/` as a command to execute; a bare word gets a
# `git-credential-` prefix, which would silently look for a binary that does not
# exist.
squad_credential_install_helper() {
  local key="credential.https://${SQUAD_GIT_CREDENTIAL_HOST}"
  local name

  # 1. any URL rewrite -- this is what the credential helper replaces.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    git config --global --unset-all "$name" >/dev/null 2>&1 || true
  done < <(git config --global --name-only --get-regexp '^url\..*\.insteadof$' 2>/dev/null || true)

  # 2. any helper that could answer before ours.
  git config --global --unset-all credential.helper >/dev/null 2>&1 || true
  git config --global --unset-all "${key}.helper" >/dev/null 2>&1 || true

  # 3. reset the accumulated list, then append ours.
  git config --global --add "${key}.helper" "" || return 1
  git config --global --add "${key}.helper" "$SQUAD_GIT_CREDENTIAL_HELPER" || return 1
  git config --global "${key}.username" "${SQUAD_GIT_CREDENTIAL_USERNAME:-x-access-token}" || return 1

  # No credential is ever cached to disk by git itself.
  git config --global credential.useHttpPath false >/dev/null 2>&1 || true

  # Without this, a git that gets no credential PROMPTS. In a container with no
  # tty that eventually errors, but only after hanging, and the error text is
  # about a terminal rather than about a credential. Failing immediately with
  # "could not read Username ... terminal prompts disabled" is both faster and
  # classifiable.
  export GIT_TERMINAL_PROMPT=0

  return 0
}

# What `git config` reports for the helper, as one line per non-empty entry.
# Used by the preflight and by tests: the wiring is asserted by asking GIT, not
# by re-reading the code that wrote it.
squad_credential_configured_helpers() {
  local key="credential.https://${SQUAD_GIT_CREDENTIAL_HOST}.helper"
  git config --global --get-all "$key" 2>/dev/null | while IFS= read -r v; do
    [[ -n "$v" ]] && printf '%s\n' "$v"
  done
  return 0
}

# Any surviving URL rewrite, one `name=value` per line. Empty output is the
# healthy state.
squad_credential_url_rewrites() {
  git config --global --get-regexp '^url\..*\.insteadof$' 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# `gh` and node-spawned `gh`
# ---------------------------------------------------------------------------

# Re-export GH_TOKEN/GITHUB_TOKEN from the CURRENT token file.
#
# `gh` reads GH_TOKEN from its environment and is a fresh process every time, so
# it would honour a refreshed value -- except that this shell exported GH_TOKEN
# once at startup and an exported variable is frozen for the life of the shell.
# Calling this immediately before an invocation is what closes that gap, and it
# also covers `gh` processes spawned by node (worker/lib/dispatch-lease.js),
# which inherit this shell's environment.
#
# COPILOT_GITHUB_TOKEN is deliberately NOT touched. It is a separate credential
# plane (see $script:SandboxCredentialPlanes in the sandbox provider) which may
# hold a DIFFERENT token; overwriting it here would silently hand the git
# credential to the Copilot plane.
squad_credential_refresh_env() {
  local token
  if token="$(squad_credential_read_token)" && [[ -n "$token" ]]; then
    export GH_TOKEN="$token"
    export GITHUB_TOKEN="$token"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Issue #84 PI-3: withholding the push credential from an untrusted-input agent
# ---------------------------------------------------------------------------
# An issue/comment-sourced prompt is the least trusted input this system
# takes, and today the agent process that runs it holds the SAME
# repository-write credential that later pushes the branch and opens the PR.
# Full separation (a different process identity or execution boundary
# publishing on the agent's behalf) was evaluated and declined as
# disproportionate for this iteration -- see docs/architecture.md. What is
# implemented instead is WITHHOLDING: for the bounded duration of the single
# `copilot -p` (or `squad-hub oneshot`) call, the credential is not in the
# environment, not on disk, and not wired into git. It is restored before
# worker/entrypoint.sh's commit_and_push_if_needed runs, so the session still
# ends with a branch and a pull request.
#
# This is scoped to CREDENTIAL_WITHHOLD_MODES (agent-policy.js: `prompt` and
# `new-project`) on an UNTRUSTED dispatch source. It is NOT separation: the
# agent runs under the same uid that performs the push, so nothing here
# defends against a sufficiently determined process going looking for the
# token elsewhere. What it removes is the credential being handed to the
# agent's own environment, file tools, and git wiring for the window in which
# an attacker-controlled prompt is running -- see resolveCredentialProfile in
# worker/lib/agent-policy.js for the full rationale.
#
# The withheld token lives ONLY in a non-exported shell variable
# (SQUAD_CREDENTIAL_WITHHELD_TOKEN). A non-exported variable is not copied into
# any child process's environment, which is the entire point: the agent this
# code starts AFTER withholding must not inherit it.
SQUAD_CREDENTIAL_WITHHELD_TOKEN=""
SQUAD_CREDENTIAL_IS_WITHHELD=0

# Security follow-up (issue #84 blocker): withholding GH_TOKEN/GITHUB_TOKEN
# alone left COPILOT_GITHUB_TOKEN visible to the agent whenever
# worker/entrypoint.sh had defaulted it from GH_TOKEN (the default deployment
# shape -- see docs/security-report.md's "Open finding"). A push-capable
# credential under a different variable name is still a push-capable
# credential. squad_credential_withhold now also caches and unsets
# COPILOT_GITHUB_TOKEN whenever its value equals the git token being
# withheld -- the SAME non-exported-variable technique, so it never reaches a
# child process either. A COPILOT_GITHUB_TOKEN that is a genuinely DIFFERENT,
# separately scoped credential (an explicit, distinct value) is left alone:
# it is not the credential this control exists to hide.
SQUAD_CREDENTIAL_WITHHELD_COPILOT_TOKEN=""
SQUAD_CREDENTIAL_COPILOT_IS_WITHHELD=0

# True when COPILOT_GITHUB_TOKEN's CURRENT value is identical to GH_TOKEN's.
# This is a plain value comparison, not a re-derivation of
# SQUAD_COPILOT_TOKEN_PROVENANCE: a token recorded as "explicit" at
# entrypoint startup (worker/entrypoint.sh) can still happen to equal the git
# token, and R2 requires that case to be withheld too -- provenance alone
# would let it slip through.
squad_copilot_token_is_shared() {
  [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]] || return 1
  [[ -n "${GH_TOKEN:-}" ]] || return 1
  [[ "$COPILOT_GITHUB_TOKEN" == "$GH_TOKEN" ]]
}

# Fail closed BEFORE the agent starts when an untrusted-input session's
# COPILOT_GITHUB_TOKEN is the same value as the git push token about to be
# withheld. Withholding GH_TOKEN/GITHUB_TOKEN alone does not close the
# exposure Security flagged if the agent can still read an equally
# push-capable token out of COPILOT_GITHUB_TOKEN. Called only from the
# `squad_credential_should_withhold` branches in worker/entrypoint.sh, i.e.
# only for the untrusted prompt/new-project sessions this control applies to.
#
# The ONE escape hatch is SQUAD_ALLOW_SHARED_COPILOT_TOKEN=true, and it is
# deliberately not a silent downgrade: it is logged as a WARNING here, and
# `resolveCredentialProfile` in worker/lib/agent-policy.js reports
# `copilotTokenSharedAllowed: true` / a weakened `reason` string in the
# credential profile so the policy report never claims an unqualified
# `withheld: true` while a shared Copilot token stays exported.
squad_copilot_shared_token_gate() {
  squad_copilot_token_is_shared || return 0
  if [[ "${SQUAD_ALLOW_SHARED_COPILOT_TOKEN:-}" == "true" ]]; then
    squad_credentials_log "WARNING: COPILOT_GITHUB_TOKEN carries the same push-capable value as the git token for this untrusted-input session (provenance: ${SQUAD_COPILOT_TOKEN_PROVENANCE:-unknown}), and SQUAD_ALLOW_SHARED_COPILOT_TOKEN=true was set. Proceeding with a WEAKENED credential boundary: the Copilot plane keeps a push-capable token exported to the agent."
    return 0
  fi
  squad_credentials_log "FATAL: this untrusted-input session's COPILOT_GITHUB_TOKEN carries the same push-capable value as the git token (provenance: ${SQUAD_COPILOT_TOKEN_PROVENANCE:-unknown}). Withholding the git credential alone would not close this exposure. Supply a separately scoped Copilot credential (a fine-grained PAT distinct from the git push token) via COPILOT_GITHUB_TOKEN, or set SQUAD_ALLOW_SHARED_COPILOT_TOKEN=true to proceed anyway with that documented, weakened boundary. Refusing to start the agent."
  exit 78
}

# Remove the token file from disk. Idempotent; used both by withholding and by
# anything that wants "no credential on disk" as a precondition.
squad_credential_remove_token_file() {
  rm -f "$SQUAD_GIT_TOKEN_FILE" 2>/dev/null || true
}

# The mirror image of squad_credential_install_helper: remove OUR configured
# helper entry so git is left with NO helper for this host, rather than one
# that would answer with nothing (which is indistinguishable, from the
# agent's shell tools, from "ask git yourself and see"). Idempotent.
squad_credential_uninstall_helper() {
  local key="credential.https://${SQUAD_GIT_CREDENTIAL_HOST}"
  git config --global --unset-all "${key}.helper" >/dev/null 2>&1 || true
  return 0
}

# Withhold the credential from everything started after this call returns.
#
# ORDERING IS THE CONTROL, not a detail of it -- exactly the same argument as
# squad_drop_azure_identity above, and for the same reason. The periodic lease
# heartbeat (squad_lease_heartbeat_loop) is a BACKGROUND CHILD that may already
# be running by the time an untrusted prompt/new-project session reaches this
# point: it was forked once, early, right after squad_drop_azure_identity, and
# it holds whatever GH_TOKEN/GITHUB_TOKEN this shell had exported AT FORK TIME
# in its own process environment forever after -- unsetting the variable in
# THIS shell does not reach a process that already exists, and re-reading the
# token file in its next tick would not remove what it already has. Left
# running through the withheld window, the heartbeat child would keep the
# credential legible (via /proc/<pid>/environ) to exactly the agent it is being
# withheld from. So the heartbeat is stopped BEFORE the credential is touched,
# and only restarted (squad_credential_restore) once the credential is back --
# never straddling the withheld window in either direction.
squad_credential_withhold() {
  if [[ -n "$SQUAD_LEASE_HEARTBEAT_PID" ]]; then
    # Issue #92-shaped leak: squad_lease_heartbeat_loop's own `while true; do
    # sleep N; done` forks a grandchild (the sleep) that is not
    # $SQUAD_LEASE_HEARTBEAT_PID itself. Signalling only that PID can leave the
    # sleep orphaned and running for a full tick, still holding whatever it
    # inherited at fork time -- the same shape run-tests.sh's own containment
    # fix (this same issue) exists to close. Because the heartbeat is forked
    # with job control on (see squad_credential_restore / entrypoint.sh), its
    # PID is also its own process group id, so signalling the group takes the
    # sleep down with it; falling back to the bare PID keeps this correct even
    # for a heartbeat that, for whatever reason, was not its own group leader.
    kill -TERM -- "-$SQUAD_LEASE_HEARTBEAT_PID" 2>/dev/null \
      || kill "$SQUAD_LEASE_HEARTBEAT_PID" 2>/dev/null || true
    wait "$SQUAD_LEASE_HEARTBEAT_PID" 2>/dev/null || true
    SQUAD_LEASE_HEARTBEAT_PID=""
  fi

  SQUAD_CREDENTIAL_WITHHELD_TOKEN="$(squad_credential_read_token 2>/dev/null || true)"

  # Security follow-up (issue #84 blocker): COPILOT_GITHUB_TOKEN must be
  # withheld too whenever it carries the same value as the git token --
  # checked (and cached) BEFORE GH_TOKEN is unset below, since the comparison
  # needs both values live. A genuinely distinct Copilot credential is left
  # untouched. `squad_copilot_shared_token_gate` has already refused to reach
  # this point for a shared token with no escape hatch, so the
  # SQUAD_ALLOW_SHARED_COPILOT_TOKEN check here is defense in depth, not the
  # only gate -- it is what keeps this function correct even if called
  # directly.
  SQUAD_CREDENTIAL_COPILOT_IS_WITHHELD=0
  if squad_copilot_token_is_shared && [[ "${SQUAD_ALLOW_SHARED_COPILOT_TOKEN:-}" != "true" ]]; then
    SQUAD_CREDENTIAL_WITHHELD_COPILOT_TOKEN="$COPILOT_GITHUB_TOKEN"
    unset COPILOT_GITHUB_TOKEN
    SQUAD_CREDENTIAL_COPILOT_IS_WITHHELD=1
  fi

  unset GH_TOKEN GITHUB_TOKEN
  squad_credential_remove_token_file
  squad_credential_uninstall_helper
  SQUAD_CREDENTIAL_IS_WITHHELD=1
}

# Restore the credential after the agent has exited, and before anything
# publishes. Every step is checked; a restore failure is FATAL (session abort),
# because "the withholding could not be undone" must never be silently treated
# as "the session can still push" -- and must never be treated as "the
# credential can just stay withheld", which would fail the push at the very end
# after the whole agent run, the exact late-failure shape issue #32 removed.
squad_credential_restore() {
  [[ "$SQUAD_CREDENTIAL_IS_WITHHELD" -eq 1 ]] || return 0

  if [[ -z "$SQUAD_CREDENTIAL_WITHHELD_TOKEN" ]]; then
    squad_credentials_log "FATAL: no withheld credential is available to restore. The session cannot publish its work."
    exit 78
  fi
  if ! squad_credential_write_token "$SQUAD_CREDENTIAL_WITHHELD_TOKEN"; then
    squad_credentials_log "FATAL: could not rewrite the token file while restoring the withheld credential."
    exit 78
  fi
  if ! squad_credential_install_helper; then
    squad_credentials_log "FATAL: could not reinstall the git credential helper while restoring the withheld credential."
    exit 78
  fi
  if ! squad_credential_refresh_env; then
    squad_credentials_log "FATAL: could not refresh GH_TOKEN/GITHUB_TOKEN while restoring the withheld credential."
    exit 78
  fi

  # Security follow-up (issue #84 blocker): restore COPILOT_GITHUB_TOKEN
  # symmetrically with the git token above -- same fatal-on-failure shape, so
  # a restore that cannot bring the Copilot credential back is never silently
  # treated as "close enough" (the agent has already exited by this point, so
  # there is no more agent-visibility reason to keep it withheld; staying
  # withheld here would only reproduce issue #32's late-failure shape for
  # whatever downstream step needs it next).
  if [[ "$SQUAD_CREDENTIAL_COPILOT_IS_WITHHELD" -eq 1 ]]; then
    if [[ -z "$SQUAD_CREDENTIAL_WITHHELD_COPILOT_TOKEN" ]]; then
      squad_credentials_log "FATAL: no withheld Copilot credential is available to restore."
      exit 78
    fi
    export COPILOT_GITHUB_TOKEN="$SQUAD_CREDENTIAL_WITHHELD_COPILOT_TOKEN"
    SQUAD_CREDENTIAL_WITHHELD_COPILOT_TOKEN=""
    SQUAD_CREDENTIAL_COPILOT_IS_WITHHELD=0
  fi

  SQUAD_CREDENTIAL_WITHHELD_TOKEN=""
  SQUAD_CREDENTIAL_IS_WITHHELD=0

  # Restart the heartbeat AFTER the credential is verifiably back, so the new
  # child forks with the restored token file already in place and never with a
  # stale or absent one. Only if a lease is actually in play for this session.
  #
  # Issue #92: this restart is a SECOND opportunity for the background child
  # to inherit whatever stdout/stderr this shell has at the moment -- the
  # entrypoint's first fork is not the only one, and every fork of a
  # `while true` loop that never exits must be redirected independently of
  # what squad_lease_heartbeat_loop's own body does. Redirected here AND
  # inside the function itself (belt and braces; see worker/entrypoint.sh).
  if [[ -n "${SQUAD_LEASE_KEY:-}" ]] && declare -f squad_lease_heartbeat_loop >/dev/null 2>&1; then
    # `set -m` gives this backgrounded job its own process group (pgid == its
    # own pid), so squad_credential_withhold can signal the whole group and
    # take its sleep-loop grandchild down with it too -- see the comment
    # there and worker/entrypoint.sh's initial fork, which does the same.
    set -m
    squad_lease_heartbeat_loop >/dev/null 2>&1 </dev/null &
    SQUAD_LEASE_HEARTBEAT_PID=$!
    set +m
  fi
  squad_credentials_log "Push credential restored after the agent exited."
}


# ---------------------------------------------------------------------------
# Failure classification
# ---------------------------------------------------------------------------

# The signatures git and `gh` emit when the CREDENTIAL is the problem.
#
# EVERY ENTRY IS A MULTI-WORD PHRASE OR A NUMBER ANCHORED TO ONE. That is not a
# style choice. This repository has already shipped a classifier that matched
# the bare substring "429", which then matched the hex of
# `Correlation ID: 1b8f429c-...` and turned every GUID-bearing auth message into
# a quota verdict -- so an unattended dispatcher retried a rotated-out
# credential forever. A bare "401"/"403" here would reproduce that defect with
# the roles reversed. `requested URL returned error: 403` cannot appear inside a
# GUID; `403` alone can.
#
# Kept in sync with the `auth` rule of $script:SandboxFailureRules in
# scripts/lib/providers/squad-sandbox-provider.ps1 -- ONE taxonomy, two
# languages. scripts/validate.ps1 asserts that every phrase below is also
# recognised there.
SQUAD_CREDENTIAL_FAULT_PATTERNS=(
  'Invalid username or token'
  'Invalid username or password'
  'Authentication failed for'
  'could not read Username'
  'could not read Password'
  'terminal prompts disabled'
  'Bad credentials'
  'Write access to repository not granted'
  'requested URL returned error: 40[13]'
  'Support for password authentication was removed'
  'token has expired'
  'Resource not accessible by integration'
)

# Classify the text of a failed git/gh invocation using the SHARED taxonomy
# names (see $script:SandboxFailureKinds): `auth` when the credential is what
# failed, `execution` otherwise.
#
# `execution` is the fallthrough on purpose. Claiming a credential fault for an
# unrecognised message would send an operator to rotate a perfectly good token,
# which is the mirror image of the defect described above.
squad_credential_classify_git_failure() {
  local text="$1"
  local pattern
  for pattern in "${SQUAD_CREDENTIAL_FAULT_PATTERNS[@]}"; do
    if printf '%s' "$text" | grep -Eq -- "$pattern"; then
      printf 'auth'
      return 0
    fi
  done
  printf 'execution'
  return 0
}
