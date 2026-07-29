#!/usr/bin/env bash
# squad-policy.sh
#
# Issue #26 / PRD #6: enforcement half of tool and MCP approval parity.
#
# worker/lib/agent-policy.js DECIDES the policy. This file APPLIES it, and is
# the part that has to survive an agent that does not want it applied.
#
# WHY THE ENFORCEMENT IS HERE AND NOT IN COPILOT FLAGS
# ----------------------------------------------------
# The Copilot CLI (verified against the pinned @github/copilot 1.0.69-2 via
# `copilot help permissions`) has tool-granular and URL-granular permissions,
# and a single CWD-vs-everything path switch. It has NO path-scoped write
# permission and no `--deny-path`. "May write to the repository but not to
# .squad/policies" is therefore not expressible as a flag, at all. Enforcing
# governance through flags would be decoration, so it is enforced here:
#
#   1. PREVENTIVE  every governance path is stripped of write bits before the
#                  agent starts, and the four commands that could put them back
#                  (chmod, chown, chattr, setfacl) are on the CLI deny list in
#                  every tier.
#   2. DETECTIVE   a SHA-256 manifest of every governance file, plus the commit
#                  the session started from, is recorded OUTSIDE the repository
#                  in a 0700 directory before the agent starts, and verified
#                  after it finishes. Any difference -- content, added file,
#                  deleted file, or a change committed rather than left in the
#                  working tree -- fails the session BEFORE the push/PR step, so
#                  a governance rewrite never reaches the remote.
#
# HONEST BOUNDARY. The agent runs as the same uid that owns the checkout, and
# the shell tool is not path-confined. A determined agent can therefore still
# mutate a governance file; what it cannot do is have that mutation go
# unnoticed or be published. The preventive layer stops the accidental and the
# naive case; the detective layer is the one that cannot be argued away. A
# tamper-proof preventive control needs a uid or mount boundary that does not
# exist inside a single-user container -- see docs/architecture.md for which
# layer owns that.
#
# Two preventive limits are known and asserted in worker/tests, not merely
# described here:
#   - `chmod -R a-w` makes a file unwritable, but DELETING a file needs write on
#     its PARENT directory. `.squad/config.json` and `.squad/routing.md` sit
#     directly in `.squad/`, which a session legitimately writes to (run logs,
#     session state), so `.squad/` is not frozen and those two can be unlinked.
#     The manifest's `absent` markers catch exactly that.
#   - An agent that runs `chmod u+w` first defeats the mode bits entirely. That
#     is why `chmod`/`chown`/`chattr`/`setfacl` are denied at the CLI in every
#     tier AND why the baseline lives outside the checkout.
#
# FAIL CLOSED. Every failure path in this file aborts the session. There is no
# branch that logs a warning and continues, and no branch that falls back to a
# permissive flag set: "the policy could not be applied" and "the session runs
# with blanket allow" must never be the same outcome. That failure mode is what
# `--yolo` was.
#
# Exit codes used by the abort paths:
#   78  EX_CONFIG -- policy could not be applied, or was violated.

# Deliberately no `set -e` here: this file is SOURCED by worker/entrypoint.sh,
# which sets its own options. Every function returns a status the caller checks.

SQUAD_POLICY_LIB_DIR="${SQUAD_POLICY_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SQUAD_POLICY_RESOLVER="${SQUAD_POLICY_RESOLVER:-${SQUAD_POLICY_LIB_DIR}/agent-policy.js}"

SQUAD_POLICY_TIER=""
SQUAD_POLICY_REASON=""
SQUAD_POLICY_FLAGS=""
SQUAD_POLICY_ARGV=()
SQUAD_POLICY_SQUAD_FLAGS=""
SQUAD_POLICY_UNDELIVERABLE=()
SQUAD_POLICY_STATE_DIR="${SQUAD_POLICY_STATE_DIR:-}"
SQUAD_POLICY_HARDENED_PATHS=()

squad_policy_log() {
  printf '[squad-policy] %s\n' "$*"
}

squad_policy_abort() {
  squad_policy_log "$@"
  squad_policy_log "Refusing to run the session. A session whose policy cannot be applied must not run with blanket allow."
  exit 78
}

# ---------------------------------------------------------------------------
# 1. Resolve
# ---------------------------------------------------------------------------
# Populates SQUAD_POLICY_TIER / _REASON / _FLAGS from the shared resolver.
# Aborts if node is missing, the resolver is missing, or the resolver rejects
# the environment (for example SQUAD_COPILOT_FLAGS carrying `--yolo`).
squad_policy_resolve() {
  if ! command -v node >/dev/null 2>&1; then
    squad_policy_abort "node is not available, so the session policy cannot be resolved."
  fi
  if [[ ! -f "$SQUAD_POLICY_RESOLVER" ]]; then
    squad_policy_abort "Policy resolver not found at ${SQUAD_POLICY_RESOLVER}."
  fi

  local tier reason flags rc

  tier="$(node "$SQUAD_POLICY_RESOLVER" tier 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    squad_policy_log "Policy resolution failed (exit ${rc}): ${tier}"
    squad_policy_abort "The session policy could not be resolved."
  fi

  reason="$(node "$SQUAD_POLICY_RESOLVER" reason 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    squad_policy_log "Policy resolution failed (exit ${rc}): ${reason}"
    squad_policy_abort "The session policy could not be resolved."
  fi

  flags="$(node "$SQUAD_POLICY_RESOLVER" flags 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    squad_policy_log "Policy resolution failed (exit ${rc}): ${flags}"
    squad_policy_abort "The session policy could not be resolved."
  fi

  if [[ -z "$tier" || -z "$flags" ]]; then
    squad_policy_abort "The policy resolver produced an empty tier or flag set."
  fi

  # A resolver that ever emitted a blanket-allow flag would silently undo this
  # whole change, so the caller checks rather than trusts. This is cheap and it
  # is the last line of defence before the flags reach `copilot`.
  case " $flags " in
    *" --yolo "*|*" --allow-all "*|*" --allow-all-paths "*)
      squad_policy_abort "The resolved flag set contains a blanket-allow flag: ${flags}"
      ;;
  esac

  # The authoritative argv, one token per line, so a multi-word deny pattern
  # stays ONE argument. Anything that word-splits `$flags` loses those rules.
  SQUAD_POLICY_ARGV=()
  local token
  while IFS= read -r token; do
    [[ -n "$token" ]] && SQUAD_POLICY_ARGV+=("$token")
  done < <(node "$SQUAD_POLICY_RESOLVER" argv)
  if [[ "${#SQUAD_POLICY_ARGV[@]}" -eq 0 ]]; then
    squad_policy_abort "The policy resolver produced an empty argv."
  fi

  SQUAD_POLICY_SQUAD_FLAGS="$(node "$SQUAD_POLICY_RESOLVER" squad-flags 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 || -z "$SQUAD_POLICY_SQUAD_FLAGS" ]]; then
    squad_policy_abort "The policy resolver produced no --copilot-flags string."
  fi

  SQUAD_POLICY_UNDELIVERABLE=()
  while IFS= read -r token; do
    [[ -n "$token" ]] && SQUAD_POLICY_UNDELIVERABLE+=("$token")
  done < <(node "$SQUAD_POLICY_RESOLVER" undeliverable)

  SQUAD_POLICY_TIER="$tier"
  SQUAD_POLICY_REASON="$reason"
  SQUAD_POLICY_FLAGS="$flags"
  return 0
}

# Announce what will actually be applied, including the rules that a
# `squad --copilot-flags` handoff cannot carry. A downgrade nobody can see in
# the session log is the same failure mode as no control at all.
squad_policy_announce() {
  local via="${1:-direct}"
  squad_policy_log "Tier: ${SQUAD_POLICY_TIER} (${SQUAD_POLICY_REASON})"
  if [[ "$via" == "squad" ]]; then
    squad_policy_log "Copilot flags (via squad --copilot-flags): ${SQUAD_POLICY_SQUAD_FLAGS}"
    if [[ "${#SQUAD_POLICY_UNDELIVERABLE[@]}" -gt 0 ]]; then
      squad_policy_log "NOT enforced on this path: ${SQUAD_POLICY_UNDELIVERABLE[*]}"
      squad_policy_log "  Reason: 'squad --copilot-flags' splits its value on whitespace, so a multi-word deny pattern cannot survive it. Governance-path enforcement below is unaffected."
    fi
  else
    squad_policy_log "Copilot flags: ${SQUAD_POLICY_FLAGS}"
  fi
}

# ---------------------------------------------------------------------------
# 2. State directory
# ---------------------------------------------------------------------------
# The integrity baseline must live where the agent's FILE tools cannot reach it.
# Dropping `--allow-all-paths` confines those tools to the repository working
# directory, so anywhere outside the checkout qualifies; 0700 under $HOME is the
# same shape squad-capability-preflight.sh already uses for its work directory.
squad_policy_state_dir() {
  local repo_dir="$1"
  local dir="${SQUAD_POLICY_STATE_DIR}"
  if [[ -z "$dir" ]]; then
    dir="${HOME:-/tmp}/.squad-policy/${SESSION_NAME:-session}"
  fi

  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || return 1

  # Must not live inside the checkout, even after symlink resolution.
  local real_state real_repo
  real_state="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  real_repo="$(cd "$repo_dir" 2>/dev/null && pwd -P)" || return 1
  case "$real_state/" in
    "$real_repo"/*) return 1 ;;
  esac

  printf '%s' "$real_state"
  return 0
}

# ---------------------------------------------------------------------------
# 3. Manifest
# ---------------------------------------------------------------------------
# One SHA-256 line per governance FILE, plus an explicit marker for every
# governance path that is absent.
#
# NOTE ON THE `absent` MARKERS. They are manifest COMPLETENESS, not an
# independent control, and this file will not claim otherwise: the baseline-vs-
# current diff already detects a path appearing or disappearing, because the
# corresponding `file` lines appear or disappear with it. Deleting the `absent`
# branch is therefore NOT detectable on its own, and worker/tests does not
# pretend to detect it. What the markers buy is a baseline that states what was
# checked rather than what happened to exist, so a protected path that is absent
# at hardening time is visibly accounted for instead of silently unrepresented.
squad_policy_write_manifest() {
  local repo_dir="$1" out="$2"
  local path

  : >"$out" || return 1

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    local target="${repo_dir}/${path}"
    if [[ -d "$target" ]]; then
      printf 'dir %s\n' "$path" >>"$out"
      # -print0/sort -z keeps ordering stable regardless of locale or readdir
      # order, so an identical tree always produces an identical manifest.
      while IFS= read -r -d '' file; do
        local sum
        sum="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')" || return 1
        [[ -n "$sum" ]] || return 1
        printf 'file %s %s\n' "${file#"${repo_dir}/"}" "$sum" >>"$out"
      done < <(find "$target" -type f -print0 2>/dev/null | sort -z)
    elif [[ -f "$target" ]]; then
      local sum
      sum="$(sha256sum "$target" 2>/dev/null | awk '{print $1}')" || return 1
      [[ -n "$sum" ]] || return 1
      printf 'file %s %s\n' "$path" "$sum" >>"$out"
    else
      printf 'absent %s\n' "$path" >>"$out"
    fi
  done < <(node "$SQUAD_POLICY_RESOLVER" governance-paths)

  return 0
}

# ---------------------------------------------------------------------------
# 4. Harden
# ---------------------------------------------------------------------------
# Called AFTER session bootstrap (`squad init`, SubSquad activation) and
# immediately BEFORE the agent runs, because bootstrap legitimately creates the
# very files the agent must not then rewrite.
squad_policy_harden() {
  local repo_dir="$1"
  local state path target

  if ! command -v sha256sum >/dev/null 2>&1; then
    squad_policy_abort "sha256sum is not available, so governance integrity cannot be recorded."
  fi

  state="$(squad_policy_state_dir "$repo_dir")" || \
    squad_policy_abort "Could not create a private policy state directory outside the checkout."
  SQUAD_POLICY_STATE_DIR="$state"

  if ! squad_policy_write_manifest "$repo_dir" "${state}/governance.sha256"; then
    squad_policy_abort "Could not record the governance integrity baseline."
  fi

  # The commit the session started from. Catches a governance change that the
  # agent COMMITS -- the working tree would look clean, but this does not.
  ( cd "$repo_dir" && git rev-parse HEAD 2>/dev/null ) >"${state}/base-commit" || true

  SQUAD_POLICY_HARDENED_PATHS=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    target="${repo_dir}/${path}"
    [[ -e "$target" ]] || continue
    if ! chmod -R a-w "$target" 2>/dev/null; then
      squad_policy_abort "Could not make governance path '${path}' read-only."
    fi
    SQUAD_POLICY_HARDENED_PATHS+=("$path")
  done < <(node "$SQUAD_POLICY_RESOLVER" governance-paths)

  if [[ "${#SQUAD_POLICY_HARDENED_PATHS[@]}" -gt 0 ]]; then
    squad_policy_log "Governance paths locked read-only: ${SQUAD_POLICY_HARDENED_PATHS[*]}"
  else
    squad_policy_log "Governance paths locked read-only: none present in this repository."
  fi
  squad_policy_log "Governance baseline recorded at ${state}/governance.sha256"
  return 0
}

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
# Returns 0 when governance is intact, 1 when it changed, and ABORTS (78) when
# the check itself could not run -- an unverifiable session is not a passing
# one. Restores write bits on success so ordinary git operations downstream are
# unaffected.
squad_policy_verify() {
  local repo_dir="$1"
  local state="$SQUAD_POLICY_STATE_DIR"
  local baseline current violated=0

  if [[ -z "$state" || ! -d "$state" ]]; then
    squad_policy_abort "The governance baseline is missing; this session cannot be verified."
  fi
  baseline="${state}/governance.sha256"
  if [[ ! -f "$baseline" ]]; then
    squad_policy_abort "The governance baseline file is missing; this session cannot be verified."
  fi

  current="${state}/governance.now.sha256"
  if ! squad_policy_write_manifest "$repo_dir" "$current"; then
    squad_policy_abort "Could not recompute the governance manifest; this session cannot be verified."
  fi

  if ! diff -u "$baseline" "$current" >"${state}/governance.diff" 2>&1; then
    violated=1
    squad_policy_log "GOVERNANCE VIOLATION: a protected path changed during this session."
    while IFS= read -r line; do
      case "$line" in
        ---*|+++*|@@*) continue ;;
        -*|+*) squad_policy_log "  ${line}" ;;
      esac
    done <"${state}/governance.diff"
  fi

  # Second, independent detector: a change that was committed rather than left
  # in the working tree. `git diff <base>..HEAD` sees it even if the working
  # tree hashes match the baseline again.
  local base_commit
  base_commit="$(cat "${state}/base-commit" 2>/dev/null || true)"
  if [[ -n "$base_commit" ]]; then
    local paths=() p committed
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(node "$SQUAD_POLICY_RESOLVER" governance-paths)
    committed="$(cd "$repo_dir" && git diff --name-only "$base_commit" -- "${paths[@]}" 2>/dev/null || true)"
    if [[ -n "$committed" ]]; then
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: protected path(s) changed in commits made during this session:"
      while IFS= read -r p; do
        [[ -n "$p" ]] && squad_policy_log "  ${p}"
      done <<<"$committed"
    fi
  fi

  # Restore write bits regardless of the outcome so the workspace stays usable
  # for teardown and diagnostics. The integrity answer is already recorded.
  local path
  for path in "${SQUAD_POLICY_HARDENED_PATHS[@]:-}"; do
    [[ -n "$path" ]] || continue
    chmod -R u+w "${repo_dir}/${path}" 2>/dev/null || true
  done

  if [[ "$violated" -eq 1 ]]; then
    squad_policy_log "Governance is enforced identically on every execution substrate; see docs/runbook.md#diagnosing-a-run-blocked-by-policy."
    return 1
  fi

  squad_policy_log "Governance integrity verified: no protected path changed."
  return 0
}
