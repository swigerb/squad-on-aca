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
# THE ONE NARROW EXCLUSION: AGENT HISTORY
# ---------------------------------------
# `.squad/agents/<name>/history.md` is an append-only WORK LOG, not policy. See
# MUTABLE_GOVERNANCE_PATTERNS in agent-policy.js for why locking it protects
# nothing and costs the audit trail. Two properties make the exclusion narrow
# rather than a hole, and both are behavioural assertions in
# worker/tests/test_governance_guard.sh:
#
#   1. It is the FILE that is unlocked, never the DIRECTORY. Hardening does
#      `chmod -R a-w` over `.squad/agents` first and only then puts `u+w` back on
#      the matching files. `chmod` on a file needs ownership, not parent write,
#      so this ordering is expressible: `.squad/agents/<name>/` stays mode-locked
#      and therefore still refuses `creat()` and `unlink()`. "history is
#      writable" cannot become "the agents directory is writable", and
#      `charter.md` beside it is untouched.
#   2. It stays in the manifest under a DIFFERENT RULE rather than being dropped
#      from it. The baseline records `append-only <path> <sha256> <bytes>`;
#      verification re-hashes the first `<bytes>` bytes of the current file. An
#      append passes and is REPORTED with its size; a truncation, a rewrite of
#      already-written history, a deletion, or a history file that did not exist
#      at hardening time all fail the session exactly like any other governance
#      violation.
#
# The prefix check is deliberate, not decoration: the stated reason for
# unlocking history is that it is the audit trail, and an audit trail an agent
# can rewrite is not one. It costs one `head -c | sha256sum` per file and is
# directly testable, so it clears the "do not add a control you cannot test"
# bar. What is NOT attempted is semantic validation of what gets appended --
# that would need a schema this log does not have.
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
SQUAD_POLICY_MUTABLE_PATTERNS=()
SQUAD_POLICY_UNLOCKED_FILES=()

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
  elif [[ "$via" == "hub" ]]; then
    # The hub path carries the SAME policy minus --allow-all-tools, over a JSON
    # channel that keeps multi-word deny patterns whole -- so nothing is
    # undeliverable here, and saying which flag was dropped (and why that is a
    # tightening) is the part an operator reading a log actually needs.
    #
    # Printed with --allow-all-tools REMOVED, not merely annotated. It read
    # "Copilot flags (via Squad Hub, ACP): --allow-all-tools ..." on the line
    # directly above "MINUS --allow-all-tools", so the log showed a session
    # MORE permissive than the one that actually ran. This repository's whole
    # position is that a log which misstates the applied policy is as bad as no
    # policy; that holds when the misstatement is in the safe direction too,
    # because an operator who spots it has no way to tell which line is lying.
    squad_policy_log "Copilot flags (via Squad Hub, ACP): ${SQUAD_POLICY_FLAGS//--allow-all-tools /}"
    squad_policy_log "  MINUS --allow-all-tools: a human at the hub answers what would otherwise auto-run."
    squad_policy_log "  Deny patterns are unchanged and are still refused outright, never offered for approval."
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
# 3. Governance path classification
# ---------------------------------------------------------------------------
# The append-only exclusion is defined ONCE, in agent-policy.js, and read from
# here. Restating the pattern in bash would be a second source of truth for a
# security boundary, and the copy that drifts is always the one nobody reads.
#
# Loaded once per process and cached: the classifier is called for every
# governance file in the tree, twice per session, and a `node` fork per file
# would be the slowest thing in the worker.
#
# Fail closed: if the resolver cannot produce the patterns, the array stays
# empty, which means NOTHING is excluded and every governance file is locked and
# hash-pinned. A broken exclusion must degrade towards more protection, never
# less.
squad_policy_load_mutable_patterns() {
  if [[ "${SQUAD_POLICY_MUTABLE_PATTERNS_LOADED:-0}" -eq 1 ]]; then
    return 0
  fi
  SQUAD_POLICY_MUTABLE_PATTERNS=()
  local pattern
  while IFS= read -r pattern; do
    if [[ -n "$pattern" ]]; then
      SQUAD_POLICY_MUTABLE_PATTERNS+=("$pattern")
    fi
  done < <(node "$SQUAD_POLICY_RESOLVER" mutable-governance-patterns 2>/dev/null)
  SQUAD_POLICY_MUTABLE_PATTERNS_LOADED=1
  return 0
}

# squad_policy_is_mutable <repo-relative-path>
# 0 == append-only (excluded from the write lock, still integrity-checked)
# 1 == locked
squad_policy_is_mutable() {
  local rel="$1" pattern
  squad_policy_load_mutable_patterns
  for pattern in "${SQUAD_POLICY_MUTABLE_PATTERNS[@]:-}"; do
    [[ -n "$pattern" ]] || continue
    if [[ "$rel" =~ $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# SHA-256 of the FIRST <bytes> bytes of a file. This is the whole append-only
# check: if the prefix still hashes to what the baseline recorded, everything
# that was already written is still there, byte for byte, and whatever follows
# was added after it.
squad_policy_prefix_sha() {
  local file="$1" bytes="$2"
  head -c "$bytes" "$file" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
}

squad_policy_byte_len() {
  wc -c <"$1" 2>/dev/null | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# 4. Manifest
# ---------------------------------------------------------------------------
# One line per governance FILE, plus an explicit marker for every governance
# path that is absent. Three line kinds:
#
#   dir <path>                          a protected directory was walked
#   file <path> <sha256>                MUST NOT CHANGE
#   append-only <path> <sha256> <bytes> MAY GROW; the first <bytes> bytes must
#                                       still hash to <sha256>
#   absent <path>                       protected path not present at baseline
#
# The append-only kind exists so that "expected to change" and "must not change"
# are distinguishable IN THE BASELINE rather than by dropping the path from it.
# A dropped path is invisible to an operator reading the manifest and invisible
# to the diff; a differently-typed path is neither.
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
        squad_policy_manifest_line "$file" "${file#"${repo_dir}/"}" >>"$out" || return 1
      done < <(find "$target" -type f -print0 2>/dev/null | sort -z)
    elif [[ -f "$target" ]]; then
      squad_policy_manifest_line "$target" "$path" >>"$out" || return 1
    else
      printf 'absent %s\n' "$path" >>"$out"
    fi
  done < <(node "$SQUAD_POLICY_RESOLVER" governance-paths)

  return 0
}

squad_policy_manifest_line() {
  local file="$1" rel="$2"
  local sum
  sum="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')" || return 1
  [[ -n "$sum" ]] || return 1
  if squad_policy_is_mutable "$rel"; then
    local len
    len="$(squad_policy_byte_len "$file")"
    [[ -n "$len" ]] || return 1
    printf 'append-only %s %s %s\n' "$rel" "$sum" "$len"
  else
    printf 'file %s %s\n' "$rel" "$sum"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 5. Harden
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

  # SECOND PASS, and the ordering is the control. The recursive lock above has
  # already frozen every governance directory; this puts the owner write bit
  # back on the append-only FILES only. `chmod` on a file requires ownership,
  # not write permission on its parent, so an unlocked `history.md` can sit
  # inside a directory that still refuses `creat()` and `unlink()`. Doing it the
  # other way round -- excluding the path from the recursive `chmod` -- would
  # not express that, because the exclusion would have to be a directory to
  # allow the file to be created, and a writable directory is a writable
  # directory.
  SQUAD_POLICY_UNLOCKED_FILES=()
  local file rel
  for path in "${SQUAD_POLICY_HARDENED_PATHS[@]:-}"; do
    [[ -n "$path" ]] || continue
    target="${repo_dir}/${path}"
    if [[ -d "$target" ]]; then
      while IFS= read -r -d '' file; do
        rel="${file#"${repo_dir}/"}"
        squad_policy_is_mutable "$rel" || continue
        if ! chmod u+w "$file" 2>/dev/null; then
          squad_policy_abort "Could not restore append access to '${rel}'."
        fi
        SQUAD_POLICY_UNLOCKED_FILES+=("$rel")
      done < <(find "$target" -type f -print0 2>/dev/null | sort -z)
    else
      squad_policy_is_mutable "$path" || continue
      if ! chmod u+w "$target" 2>/dev/null; then
        squad_policy_abort "Could not restore append access to '${path}'."
      fi
      SQUAD_POLICY_UNLOCKED_FILES+=("$path")
    fi
  done

  if [[ "${#SQUAD_POLICY_HARDENED_PATHS[@]}" -gt 0 ]]; then
    squad_policy_log "Governance paths locked read-only: ${SQUAD_POLICY_HARDENED_PATHS[*]}"
  else
    squad_policy_log "Governance paths locked read-only: none present in this repository."
  fi
  if [[ "${#SQUAD_POLICY_UNLOCKED_FILES[@]}" -gt 0 ]]; then
    squad_policy_log "Append-only exception (work log, not policy; still integrity-checked): ${SQUAD_POLICY_UNLOCKED_FILES[*]}"
    squad_policy_log "  Their containing directories stay locked, so no file can be created or deleted beside them."
  fi
  squad_policy_log "Governance baseline recorded at ${state}/governance.sha256"
  return 0
}

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
# Returns 0 when governance is intact, 1 when it changed, and ABORTS (78) when
# the check itself could not run -- an unverifiable session is not a passing
# one. Restores write bits on success so ordinary git operations downstream are
# unaffected.
#
# Three detectors, evaluated independently and OR'd into one verdict:
#   a. the `dir`/`file`/`absent` lines must be IDENTICAL to the baseline;
#   b. every `append-only` line must still be present, and may only have GROWN
#      from the prefix the baseline pinned -- a permitted append is logged with
#      its byte delta, so "history changed" is visible in the session log rather
#      than silently allowed;
#   c. nothing under a governance path may differ between the base commit and
#      the working tree, except an append-only path, whose committed form is
#      prefix-checked the same way.
squad_policy_verify() {
  local repo_dir="$1"
  local state="$SQUAD_POLICY_STATE_DIR"
  local baseline current violated=0 appended=0

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

  # --- (a) the immutable half -----------------------------------------------
  # `append-only` lines are held out of this comparison ON PURPOSE and checked
  # by (b) instead. They are NOT dropped from the manifest: an operator reading
  # either file still sees the path, its hash and its length, which is what
  # makes "this was expected to change" reviewable rather than invisible.
  grep -v '^append-only ' "$baseline" >"${state}/governance.locked.baseline" 2>/dev/null || true
  grep -v '^append-only ' "$current"  >"${state}/governance.locked.now" 2>/dev/null || true
  if ! diff -u "${state}/governance.locked.baseline" "${state}/governance.locked.now" >"${state}/governance.diff" 2>&1; then
    violated=1
    squad_policy_log "GOVERNANCE VIOLATION: a protected path changed during this session."
    while IFS= read -r line; do
      case "$line" in
        ---*|+++*|@@*) continue ;;
        -*|+*) squad_policy_log "  ${line}" ;;
      esac
    done <"${state}/governance.diff"
  fi

  # --- (b) the append-only half ---------------------------------------------
  local kind rel bsum blen csum clen now_line
  while read -r kind rel bsum blen; do
    [[ "$kind" == "append-only" ]] || continue
    now_line="$(awk -v P="$rel" '$1=="append-only" && $2==P {print $3" "$4; exit}' "$current")"
    if [[ -z "$now_line" ]]; then
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: the append-only work log ${rel} was DELETED during this session."
      continue
    fi
    csum="${now_line%% *}"
    clen="${now_line##* }"
    [[ "$csum" == "$bsum" ]] && continue
    if [[ "$clen" -lt "$blen" ]] || [[ "$(squad_policy_prefix_sha "${repo_dir}/${rel}" "$blen")" != "$bsum" ]]; then
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: ${rel} was REWRITTEN, not appended to. A work log an agent can edit is not an audit trail."
      squad_policy_log "  baseline: ${blen} bytes / ${bsum}"
      squad_policy_log "  now:      ${clen} bytes / ${csum}"
      continue
    fi
    appended=$((appended + 1))
    squad_policy_log "Agent history appended (permitted): ${rel} +$((clen - blen)) bytes, prior ${blen} bytes unchanged."
  done <"$baseline"

  # A path that is append-only NOW but was not in the baseline is a new
  # governance file, not a permitted append. (a) cannot see it, because both
  # sides hold `append-only` lines out of the comparison, so it is caught here.
  while read -r kind rel csum clen; do
    [[ "$kind" == "append-only" ]] || continue
    if ! grep -q "^append-only ${rel} " "$baseline" 2>/dev/null; then
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: the work log ${rel} did not exist when this session started; a session may append to history, not create it."
    fi
  done <"$current"

  # --- (c) committed changes -------------------------------------------------
  # A change that was committed rather than left in the working tree.
  # `git diff <base>` sees it even if the working tree hashes match the baseline
  # again.
  local base_commit
  base_commit="$(cat "${state}/base-commit" 2>/dev/null || true)"
  if [[ -n "$base_commit" ]]; then
    local paths=() p committed committed_head violating=()
    while IFS= read -r p; do
      [[ -n "$p" ]] && paths+=("$p")
    done < <(node "$SQUAD_POLICY_RESOLVER" governance-paths)
    committed="$(cd "$repo_dir" && git diff --name-only "$base_commit" -- "${paths[@]}" 2>/dev/null || true)"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      squad_policy_is_mutable "$p" && continue
      violating+=("$p")
    done <<<"$committed"
    if [[ "${#violating[@]}" -gt 0 ]]; then
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: protected path(s) changed in commits made during this session:"
      for p in "${violating[@]}"; do
        squad_policy_log "  ${p}"
      done
    fi

    # The append-only paths get the same treatment against their COMMITTED
    # form. Without this, an agent could commit a truncated history file and
    # then restore the working-tree copy: (b) would compare clean and the
    # truncation would still be what gets pushed.
    committed_head="$(cd "$repo_dir" && git diff --name-only "$base_commit" HEAD -- "${paths[@]}" 2>/dev/null || true)"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      squad_policy_is_mutable "$p" || continue
      now_line="$(awk -v P="$p" '$1=="append-only" && $2==P {print $3" "$4; exit}' "$baseline")"
      if [[ -z "$now_line" ]]; then
        violated=1
        squad_policy_log "GOVERNANCE VIOLATION: ${p} was committed during this session but was not in the governance baseline."
        continue
      fi
      bsum="${now_line%% *}"
      blen="${now_line##* }"
      if ! ( cd "$repo_dir" && git show "HEAD:${p}" ) >"${state}/committed-blob" 2>/dev/null; then
        violated=1
        squad_policy_log "GOVERNANCE VIOLATION: the append-only work log ${p} was DELETED in a commit made during this session."
        continue
      fi
      clen="$(squad_policy_byte_len "${state}/committed-blob")"
      if [[ "${clen:-0}" -lt "$blen" ]] || [[ "$(squad_policy_prefix_sha "${state}/committed-blob" "$blen")" != "$bsum" ]]; then
        violated=1
        squad_policy_log "GOVERNANCE VIOLATION: ${p} was REWRITTEN, not appended to, in a commit made during this session."
      else
        squad_policy_log "Agent history appended in a commit (permitted): ${p} +$((clen - blen)) bytes."
      fi
    done <<<"$committed_head"
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

  if [[ "$appended" -gt 0 ]]; then
    squad_policy_log "Governance integrity verified: no protected path changed (${appended} permitted append-only work-log update(s), listed above)."
  else
    squad_policy_log "Governance integrity verified: no protected path changed."
  fi
  return 0
}
