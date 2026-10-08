#!/usr/bin/env bash
# Agent-supplied pull request title/body (issue #130).
#
# Sourced by worker/entrypoint.sh and by worker/tests. Sourcing has no side
# effects beyond defining functions, so the content and safety rules here are
# independently testable against plain local directories.
#
# An agent that wants a meaningful pull request title/body -- instead of the
# generic "Remote Squad session <name>" -- writes two OPTIONAL files before it
# exits:
#
#   .squad-pr/title      a single line, used verbatim as the PR title
#   .squad-pr/body.md     Markdown, used verbatim as the PR body (before the
#                         governance report is appended -- see
#                         squad_pr_content_finalize_body)
#
# These files are agent output, not repository content: worker/entrypoint.sh
# reads them BEFORE the publishing commit, and strips `.squad-pr/` from the
# worktree and the index so it can never end up in a commit this worker (or a
# well-behaved agent) makes -- see squad_pr_content_scrub.
#
# Precedence for the final title/body (entrypoint.sh's commit_and_push_if_needed):
#   1. An explicit dispatch-side override (PR_TITLE / PR_BODY session env --
#      carried from `squad-aca run --pr-title/--pr-body-file`, a manual Actions
#      dispatch, or a Ralph/CLI caller that set it directly).
#   2. An agent-supplied .squad-pr/title / .squad-pr/body.md.
#   3. The worker's own built-in default text.
#
# Safety rules applied to the agent-supplied files (NOT to an explicit
# dispatch-side PR_TITLE/PR_BODY override, which is already a trusted,
# validated value by the time it reaches this container):
#   * a symlink anywhere on the path (the file itself, or .squad-pr itself) is
#     REFUSED -- the content is never read, never followed;
#   * the title is capped at 256 UTF-8 characters;
#   * the body is capped at 60000 UTF-8 characters;
#   * control characters other than newline/tab are stripped (a title must
#     also not carry embedded newlines, which would forge extra lines wherever
#     it is echoed, e.g. a commit message or a log line).

# Provide a minimal log() when sourced standalone. entrypoint.sh's own richer
# log() is defined first there, so this never overrides it.
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[squad-on-aca] %s\n' "$*"; }
fi

SQUAD_PR_TITLE_CHAR_CAP=256
SQUAD_PR_BODY_CHAR_CAP=60000

# squad_pr_content_is_unsafe_path <path>
# True (0) if <path>, or any component of it that already exists, is a
# symlink. Deliberately conservative: it checks the leaf AND the immediate
# parent directory (.squad-pr itself), since a symlinked .squad-pr directory
# would let `.squad-pr/title` resolve outside the checkout even though the
# leaf name itself is not a symlink.
squad_pr_content_is_unsafe_path() {
  local path="$1" parent
  if [[ -L "$path" ]]; then
    return 0
  fi
  parent="$(dirname -- "$path")"
  if [[ -L "$parent" ]]; then
    return 0
  fi
  return 1
}

# squad_pr_content_strip_controls <text>
# Removes ASCII control characters (0x00-0x08, 0x0B-0x1F, 0x7F) while
# preserving newlines (0x0A) and tabs (0x09). Carriage returns (0x0D) are
# removed too, so a CRLF-authored file collapses to plain LF rather than
# leaving a stray \r that could forge a blank-looking extra line.
squad_pr_content_strip_controls() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177\015'
}

# squad_pr_content_cap_chars <text> <max-chars>
# Truncates <text> to at most <max-chars> UTF-8 characters. Uses `cut -c`
# (character-aware under a UTF-8 locale) rather than byte truncation, so a
# multi-byte character is never split.
squad_pr_content_cap_chars() {
  local text="$1" max="$2"
  LC_ALL=C.UTF-8 cut -c "1-${max}" <<<"$text" 2>/dev/null || printf '%s' "$text" | head -c "$max"
}

# squad_pr_content_read_title <repo_dir>
# Prints the sanitized title on stdout and returns 0 if .squad-pr/title exists,
# is not a symlink, and is non-empty after sanitizing. Returns 1 (prints
# nothing) if the file is absent. Returns 2 (prints nothing, logs why) if the
# file exists but is refused (a symlink).
squad_pr_content_read_title() {
  local repo_dir="$1" path="${1}/.squad-pr/title" raw sanitized
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 1
  fi
  if squad_pr_content_is_unsafe_path "$path"; then
    log "Refusing .squad-pr/title: it (or .squad-pr itself) is a symlink. Falling back to the next title source."
    return 2
  fi
  if [[ ! -f "$path" ]]; then
    log "Refusing .squad-pr/title: not a regular file. Falling back to the next title source."
    return 2
  fi
  raw="$(cat -- "$path" 2>/dev/null)" || return 2
  # A title is one line: the sanitizer removes embedded newlines as part of
  # stripping control characters, then the FIRST line (if more than one
  # somehow remains because tr dropped only \r, not \n, between them) is used.
  sanitized="$(printf '%s' "$raw" | squad_pr_content_strip_controls | tr '\n' ' ')"
  sanitized="$(squad_pr_content_cap_chars "$sanitized" "$SQUAD_PR_TITLE_CHAR_CAP")"
  # Trim surrounding whitespace so a file with trailing newlines doesn't
  # produce a title with trailing spaces.
  sanitized="$(printf '%s' "$sanitized" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ -z "$sanitized" ]]; then
    return 1
  fi
  printf '%s' "$sanitized"
  return 0
}

# squad_pr_content_read_body <repo_dir>
# Same contract as squad_pr_content_read_title, for .squad-pr/body.md.
# Newlines ARE preserved (this is a multi-line Markdown body).
squad_pr_content_read_body() {
  local repo_dir="$1" path="${1}/.squad-pr/body.md" raw sanitized
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 1
  fi
  if squad_pr_content_is_unsafe_path "$path"; then
    log "Refusing .squad-pr/body.md: it (or .squad-pr itself) is a symlink. Falling back to the next body source."
    return 2
  fi
  if [[ ! -f "$path" ]]; then
    log "Refusing .squad-pr/body.md: not a regular file. Falling back to the next body source."
    return 2
  fi
  raw="$(cat -- "$path" 2>/dev/null)" || return 2
  sanitized="$(printf '%s' "$raw" | squad_pr_content_strip_controls)"
  sanitized="$(squad_pr_content_cap_chars "$sanitized" "$SQUAD_PR_BODY_CHAR_CAP")"
  if [[ -z "$sanitized" ]]; then
    return 1
  fi
  printf '%s' "$sanitized"
  return 0
}

# squad_pr_content_scrub <repo_dir>
# Removes .squad-pr/ from both the working tree and the git index, so it can
# NEVER end up in a commit this worker makes -- regardless of whether the
# content was used, refused, or never written. Always returns 0: scrubbing is
# a hygiene step, not a gate, and a failure to remove an already-absent
# directory must never abort a session.
squad_pr_content_scrub() {
  local repo_dir="$1"
  if [[ -e "${repo_dir}/.squad-pr" || -L "${repo_dir}/.squad-pr" ]]; then
    git -C "$repo_dir" rm -rf --cached --ignore-unmatch -- .squad-pr >/dev/null 2>&1 || true
    rm -rf -- "${repo_dir:?}/.squad-pr" 2>/dev/null || true
  fi
  return 0
}

# squad_pr_content_resolve_title <repo_dir> <env_override>
# Precedence: a non-empty <env_override> wins outright (it is already a
# trusted, dispatch-validated value). Otherwise, read and sanitize
# .squad-pr/title. Prints the resolved title (possibly empty) on stdout.
squad_pr_content_resolve_title() {
  local repo_dir="$1" override="${2:-}"
  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return 0
  fi
  squad_pr_content_read_title "$repo_dir" || true
}

# squad_pr_content_resolve_body <repo_dir> <env_override>
# Same precedence as squad_pr_content_resolve_title, for the body.
squad_pr_content_resolve_body() {
  local repo_dir="$1" override="${2:-}"
  if [[ -n "$override" ]]; then
    printf '%s' "$override"
    return 0
  fi
  squad_pr_content_read_body "$repo_dir" || true
}

SQUAD_PR_CONTENT_HOOK_MARKER="squad-on-aca .squad-pr guard (worker/lib/squad-pr-content.sh)"

# squad_pr_content_hook_body
# Prints the POSIX sh snippet that refuses a commit/push carrying anything
# under .squad-pr/. Designed to be PREPENDED to an existing hook (see
# squad_pr_content_install_hooks) rather than to own the whole file: it
# `exit 1`s on violation and otherwise falls through, so whatever hook logic
# follows it (for example the pin-seal hook from worker/lib/squad-policy.sh)
# still runs untouched.
squad_pr_content_hook_body() {
  printf '# %s\n' "$SQUAD_PR_CONTENT_HOOK_MARKER"
  cat <<'HOOK_COMMON'
squad_pr_guard_refuse() {
  echo "squad-on-aca: $1 refused. .squad-pr/ is agent OUTPUT (a proposed PR title/body)," >&2
  echo "  not repository content, and must never be committed or pushed." >&2
  echo "  Unstage it with: git reset -q -- .squad-pr" >&2
  exit 1
}
HOOK_COMMON
  if [[ "${1:-pre-commit}" == pre-commit ]]; then
    cat <<'HOOK_PRE_COMMIT'
if git diff --cached --name-only -- .squad-pr 2>/dev/null | grep -q .; then
  squad_pr_guard_refuse "commit"
fi
HOOK_PRE_COMMIT
  else
    cat <<'HOOK_PRE_PUSH'
while read -r lref lsha rref rsha; do
  case "$lsha" in *[!0]*) ;; *) continue ;; esac
  if [ "$rsha" != "0000000000000000000000000000000000000000" ] && git rev-parse -q --verify "$rsha" >/dev/null 2>&1; then
    range="${rsha}..${lsha}"
  else
    range="$lsha"
  fi
  for c in $(git rev-list "$range" 2>/dev/null); do
    if git diff-tree --no-commit-id --name-only -r "$c" -- .squad-pr 2>/dev/null | grep -q .; then
      squad_pr_guard_refuse "push of ${lref} (commit ${c} carries .squad-pr/)"
    fi
  done
done
exit 0
HOOK_PRE_PUSH
  fi
}

# squad_pr_content_install_hooks <repo_dir>
# Best-effort, additive pre-commit/pre-push guard: refuses any commit or push
# that carries `.squad-pr/`. ADDITIVE, not exclusive -- if a hook already
# exists (for example the pin-seal hook installed by
# worker/lib/squad-policy.sh's squad_policy_pin_install_hooks), this PREPENDS
# the guard rather than replacing the file, so existing governance hooks keep
# running exactly as before. Idempotent: skipped if the marker is already
# present. Never writes to a `core.hooksPath` outside this checkout's own git
# directory, and never writes into a shared linked-worktree hooks directory.
# Always returns 0; what it did or skipped is logged.
squad_pr_content_install_hooks() {
  local top="$1" dirs git_dir common_dir hooks_cfg hooks name target existing rest first_line
  if hooks_cfg="$(git -C "$top" config --get core.hooksPath 2>/dev/null)" && [[ -n "$hooks_cfg" ]]; then
    log "squad-pr-content: .squad-pr guard not installed: core.hooksPath is set ('${hooks_cfg}')."
    return 0
  fi
  dirs="$(git -C "$top" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null)" || dirs=""
  git_dir="${dirs%%$'\n'*}"
  common_dir="${dirs#*$'\n'}"
  if [[ -z "$dirs" || "$dirs" != *$'\n'* || -z "$git_dir" || -z "$common_dir" ]]; then
    log "squad-pr-content: .squad-pr guard not installed: could not resolve the git directory."
    return 0
  fi
  if [[ "$git_dir" != "$common_dir" ]]; then
    log "squad-pr-content: .squad-pr guard not installed: ${top} is a linked worktree (hooks are shared with ${common_dir})."
    return 0
  fi
  hooks="${git_dir}/hooks"
  mkdir -p "$hooks" 2>/dev/null || {
    log "squad-pr-content: .squad-pr guard not installed: could not create ${hooks}."
    return 0
  }
  for name in pre-commit pre-push; do
    target="${hooks}/${name}"
    if [[ -e "$target" || -L "$target" ]] && grep -qF "$SQUAD_PR_CONTENT_HOOK_MARKER" "$target" 2>/dev/null; then
      continue
    fi
    rest=""
    if [[ -e "$target" ]]; then
      existing="$(cat -- "$target" 2>/dev/null)" || existing=""
      first_line="$(printf '%s\n' "$existing" | head -n1)"
      if [[ "$first_line" == '#!'* ]]; then
        rest="$(printf '%s\n' "$existing" | tail -n +2)"
      else
        rest="$existing"
      fi
    fi
    {
      printf '#!/bin/sh\n'
      squad_pr_content_hook_body "$name"
      if [[ -n "$rest" ]]; then
        printf '%s\n' "$rest"
      fi
    } >"${target}.squad-pr-tmp" 2>/dev/null && mv -f "${target}.squad-pr-tmp" "$target" && chmod 0755 "$target" 2>/dev/null \
      || { rm -f "${target}.squad-pr-tmp" "$target" 2>/dev/null; log "squad-pr-content: .squad-pr guard not installed: could not write ${target}."; continue; }
    log "squad-pr-content: .squad-pr guard installed in ${name}."
  done
  squad_pr_content_install_exclude "$top" "$git_dir"
  return 0
}

# squad_pr_content_install_exclude <repo_dir> <git_dir>
# Adds `.squad-pr/` to this checkout's LOCAL-ONLY ignore list
# (<git_dir>/info/exclude), so `git add -A`/`git status` treat it as ignored
# without touching the repository's own (committed, shared) .gitignore.
# Best-effort and idempotent; never fails the session.
squad_pr_content_install_exclude() {
  local top="$1" git_dir="$2" exclude_file
  exclude_file="${git_dir}/info/exclude"
  mkdir -p "$(dirname -- "$exclude_file")" 2>/dev/null || return 0
  if [[ -f "$exclude_file" ]] && grep -qxF '.squad-pr/' "$exclude_file" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' '.squad-pr/' >>"$exclude_file" 2>/dev/null || true
  return 0
}
