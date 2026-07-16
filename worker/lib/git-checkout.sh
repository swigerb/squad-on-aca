#!/usr/bin/env bash
# Git ref checkout helper for the Squad on ACA worker.
#
# Sourced by worker/entrypoint.sh (right after the shallow clone) and by
# worker/tests. Sourcing has no side effects beyond defining functions, so the
# checkout contract is independently testable against real local git repos with
# no network access.
#
# Why this exists: after `git clone --depth N`, checking out an arbitrary
# GITHUB_REF (a temporary branch such as `review/cap-ok-20260716105335`, a tag,
# or a branch name containing slashes) is not as simple as
# `git checkout "$ref"`. A `git fetch origin "$ref"` in a shallow clone updates
# FETCH_HEAD but does NOT create a `refs/remotes/origin/<ref>` tracking ref, so
# both `git checkout "$ref"` and `git checkout -B "$ref" "origin/$ref"` fail
# with "did not match any file(s)" / "is not a commit". This helper resolves the
# ref through every viable path and fails loudly instead of silently continuing
# on the wrong (default-branch) commit.

# Provide a minimal log() when sourced standalone (e.g. from tests). entrypoint.sh
# defines its own richer log() first, so this never overrides it.
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[squad-on-aca] %s\n' "$*"; }
fi

# checkout_github_ref <ref>
# Checks out <ref> in the current git repository, handling shallow clones and
# refs with slashes. Returns non-zero (and logs) if the ref cannot be resolved,
# so callers running under `set -e` abort rather than proceed on the wrong tree.
checkout_github_ref() {
  local ref="$1"
  local depth="${GIT_CLONE_DEPTH:-1}"

  if [[ -z "$ref" ]]; then
    log "checkout_github_ref: no ref provided"
    return 2
  fi

  # Fetch the requested ref. In a shallow clone this typically only populates
  # FETCH_HEAD (no origin/<ref> tracking ref is created), so each resolution
  # path below is handled explicitly. A failed fetch is tolerated because the
  # ref may already be present from the initial clone (e.g. the default branch).
  git fetch --depth "$depth" origin "$ref" || true

  # 1. Ref is already resolvable locally: the default branch from the initial
  #    clone, an existing local branch, or a tag. Preserves prior behavior for
  #    main and other normal branches.
  if git checkout "$ref" 2>/dev/null; then
    return 0
  fi

  # 2. A remote-tracking ref exists (non-shallow remotes, or refs git chose to
  #    track). Create/reset the local branch from it.
  if git rev-parse --verify --quiet "refs/remotes/origin/${ref}^{commit}" >/dev/null 2>&1; then
    git checkout -B "$ref" "origin/${ref}"
    return 0
  fi

  # 3. Shallow fetch only populated FETCH_HEAD (the common case for temporary
  #    and slash-bearing branches like review/cap-ok-...). Create the local
  #    branch from exactly what we just fetched.
  if git rev-parse --verify --quiet 'FETCH_HEAD^{commit}' >/dev/null 2>&1; then
    git checkout -B "$ref" FETCH_HEAD
    return 0
  fi

  log "Unable to check out requested ref: ${ref} (not resolvable locally, no origin/${ref}, and FETCH_HEAD is empty)"
  return 1
}
