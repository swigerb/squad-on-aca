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
