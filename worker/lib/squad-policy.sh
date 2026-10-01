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

# Loaded once per process and cached, same reasoning as the pattern arrays
# below: `harden` and `verify` each need the governance-paths list more than
# once (the manifest walk, the chmod lock/unlock passes, and the committed-
# change diff), and a fresh `node` fork per call is pure overhead for a value
# that never changes within one session.
#
# Fail closed: if the resolver cannot produce the list, the array stays empty,
# which means the lock/manifest loops below see nothing to protect -- the
# caller (`squad_policy_harden`) treats a missing `node`/resolver as a hard
# abort before this is ever reached, so an empty list here only happens if the
# resolver itself ran and legitimately returned nothing.
SQUAD_POLICY_GOVERNANCE_PATHS=()
squad_policy_load_governance_paths() {
  if [[ "${SQUAD_POLICY_GOVERNANCE_PATHS_LOADED:-0}" -eq 1 ]]; then
    return 0
  fi
  SQUAD_POLICY_GOVERNANCE_PATHS=()
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] && SQUAD_POLICY_GOVERNANCE_PATHS+=("$path")
  done < <(node "$SQUAD_POLICY_RESOLVER" governance-paths)
  SQUAD_POLICY_GOVERNANCE_PATHS_LOADED=1
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

# Issue #113: the REPORTED-MUTABLE sibling of the two functions above. Same
# single-source-of-truth argument, same fail-closed shape (an empty array
# means nothing is excluded, so everything stays locked and hash-pinned).
#
# squad_policy_is_reported_mutable <repo-relative-path>
# 0 == reported-mutable (excluded from BOTH the write lock and the append-only
#      rule; a difference at verify time is reported, never a violation)
# 1 == not in this class (still subject to the lock or the append-only rule)
squad_policy_load_reported_mutable_patterns() {
  if [[ "${SQUAD_POLICY_REPORTED_PATTERNS_LOADED:-0}" -eq 1 ]]; then
    return 0
  fi
  SQUAD_POLICY_REPORTED_PATTERNS=()
  local pattern
  while IFS= read -r pattern; do
    if [[ -n "$pattern" ]]; then
      SQUAD_POLICY_REPORTED_PATTERNS+=("$pattern")
    fi
  done < <(node "$SQUAD_POLICY_RESOLVER" reported-mutable-governance-patterns 2>/dev/null)
  SQUAD_POLICY_REPORTED_PATTERNS_LOADED=1
  return 0
}

squad_policy_is_reported_mutable() {
  local rel="$1" pattern
  squad_policy_load_reported_mutable_patterns
  for pattern in "${SQUAD_POLICY_REPORTED_PATTERNS[@]:-}"; do
    [[ -n "$pattern" ]] || continue
    if [[ "$rel" =~ $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# True for either kind of exclusion from the write lock -- used by
# squad_policy_harden's second chmod pass, which restores write access the
# same way (chmod u+w) regardless of which rule then governs the content.
squad_policy_is_unlockable() {
  local rel="$1"
  squad_policy_is_mutable "$rel" && return 0
  squad_policy_is_reported_mutable "$rel" && return 0
  return 1
}

# squad_policy_verify's part (a) compares every LOCKED path's manifest line
# unchanged. Append-only and reported-mutable paths are excluded from that
# comparison by PATH, not by the manifest line's literal kind word: a deleted
# append-only or reported-mutable file manifests as an `absent` line on
# whichever side it is missing from, not an `append-only`/`reported` line, and
# excluding only those two kind-words would let that `absent` line slip
# through part (a) as an apparent locked-path change. That is exactly
# backwards for the reported-mutable class, where a deletion is supposed to be
# PERMITTED (and handled by part (d)), not flagged here and separately
# excused. `dir` lines are passed through unfiltered -- a directory path never
# matches either pattern, so the check is simply a no-op for them.
squad_policy_filter_locked_lines() {
  local src="$1" dest="$2" kind rel rest
  : >"$dest"
  # Deliberately plain `read` (default IFS) so the line splits on whitespace
  # into kind/rel/rest the same way every other manifest reader in this file
  # does -- `IFS= read` would disable field splitting entirely and leave the
  # whole line in $kind, silently defeating every check below.
  while read -r kind rel rest; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" != "dir" ]]; then
      squad_policy_is_mutable "$rel" && continue
      squad_policy_is_reported_mutable "$rel" && continue
    fi
    if [[ -n "$rest" ]]; then
      printf '%s %s %s\n' "$kind" "$rel" "$rest" >>"$dest"
    else
      printf '%s %s\n' "$kind" "$rel" >>"$dest"
    fi
  done <"$src"
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
#   reported <path> <sha256>            Issue #113: MAY be rewritten freely;
#                                       a different hash at verify time is
#                                       REPORTED, never a violation
#
# The append-only kind exists so that "expected to change" and "must not change"
# are distinguishable IN THE BASELINE rather than by dropping the path from it.
# A dropped path is invisible to an operator reading the manifest and invisible
# to the diff; a differently-typed path is neither. `reported` exists for the
# same reason, for a class of path that is allowed to change arbitrarily
# (casting/*.json, identity/now.md -- see REPORTED_MUTABLE_GOVERNANCE_PATTERNS
# in agent-policy.js) rather than only by growing.
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

  squad_policy_load_governance_paths
  for path in "${SQUAD_POLICY_GOVERNANCE_PATHS[@]:-}"; do
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
  done

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
  elif squad_policy_is_reported_mutable "$rel"; then
    printf 'reported %s %s\n' "$rel" "$sum"
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

# Issue #113: pin `.squad/memory/config.json`'s `policy.auditMaxBytes` to 0
# before the baseline is recorded and before the path is locked.
#
# VERIFIED, not assumed: @bradygaster/squad-sdk 0.13.1, dist/memory/index.js,
# `rotateAuditIfNeeded()`:
#     const maxBytes = config.policy.auditMaxBytes;
#     if (maxBytes <= 0) return;
# `auditMaxBytes <= 0` is squad-sdk's OWN "rotation disabled" sentinel -- read
# from the function body (retrieved via `npm pack
# @bradygaster/squad-sdk@0.13.1`), not guessed from the key's name. `0` means
# "never rotate", not "always rotate", so pinning it is the SAFE direction.
#
# WHY PIN RATHER THAN JUST DETECT THE RENAME
# -------------------------------------------
# `.squad/memory/audit.jsonl` is append-only (MUTABLE_GOVERNANCE_PATTERNS), and
# the append-only rule is a prefix-hash check: appends pass, anything else --
# including the rename `rotateAuditIfNeeded()` performs once the file crosses
# `auditMaxBytes` -- fails the session exactly like a genuine deletion. Brian
# asked for the SAFER, more testable option of the two offered. Detecting the
# rotation after the fact only tells us it happened AFTER the append-only
# verifier has already failed the session for what looks exactly like the
# audit trail being deleted -- the "detection" and "false-positive governance
# failure" are the same event, so there is nothing to choose between
# detecting it and preventing it; preventing it is strictly better and is
# directly testable (write more than the default 1_048_576-byte threshold
# worth of audit records and assert no `audit.1.jsonl` appears). So prevention
# is what is implemented; "detect the rename" is not a fallback this file
# also carries, because a rename that is actually impossible needs no
# detector.
#
# Fail CLOSED: if the pin cannot be written, hardening aborts. Running the
# session with rotation still enabled would make a routine audit-trail
# rotation indistinguishable from an agent deleting its own audit trail, and
# that is not a degraded mode this file is willing to run in.
squad_policy_pin_memory_audit_config() {
  local repo_dir="$1"
  local config_path="${repo_dir}/.squad/memory/config.json"

  mkdir -p "${repo_dir}/.squad/memory" 2>/dev/null || true

  if ! node -e '
    const fs = require("fs");
    const target = process.argv[1];
    let config = {};
    if (fs.existsSync(target)) {
      const raw = fs.readFileSync(target, "utf8");
      if (raw.trim() !== "") {
        config = JSON.parse(raw);
      }
    }
    config.policy = config.policy || {};
    config.policy.auditMaxBytes = 0;
    fs.writeFileSync(target, JSON.stringify(config, null, 2) + "\n");
  ' "$config_path" 2>&1; then
    squad_policy_abort "Could not pin .squad/memory/config.json policy.auditMaxBytes to 0; refusing to run with audit-trail rotation enabled."
  fi

  # `.squad/memory/config.json` stays a plain LOCKED governance path (it is
  # not append-only, and it is not the casting/identity runtime state Issue
  # #113 made reported-mutable) -- an agent has no business changing its own
  # audit-rotation policy mid-session. But THIS write happens before the lock
  # is even applied, as part of hardening itself, and `squad_policy_harden`
  # records `base-commit` for the "was a protected path changed in a commit
  # made during this session" detector (c) right after this function returns.
  # Left uncommitted, this pin would be an uncommitted change to a LOCKED path
  # sitting in the working tree at session start; the session's own
  # `git add -A && git commit` (worker/entrypoint.sh) would then sweep it in,
  # and detector (c) would flag it as a governance violation every single run
  # -- not because the agent did anything, but because the CONTROL did.
  # Committing the pin here, before `base-commit` is captured, makes it part
  # of the commit the session starts FROM rather than a change the session
  # made, so the real question -- did the AGENT touch a locked path -- stays
  # answerable. If git is unavailable or this is not a git checkout, there is
  # nothing to commit against and the working-tree write still stands (and is
  # still picked up by the baseline manifest a few lines later in
  # `squad_policy_harden`).
  if command -v git >/dev/null 2>&1 && git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "$repo_dir" diff --quiet -- .squad/memory/config.json 2>/dev/null \
        || ! git -C "$repo_dir" ls-files --error-unmatch .squad/memory/config.json >/dev/null 2>&1; then
      git -C "$repo_dir" add -- .squad/memory/config.json 2>/dev/null || true
      if ! git -C "$repo_dir" diff --cached --quiet -- .squad/memory/config.json 2>/dev/null; then
        git -C "$repo_dir" -c user.name="${GIT_AUTHOR_NAME:-squad-policy}" \
            -c user.email="${GIT_AUTHOR_EMAIL:-squad-policy@local}" \
            commit -m "chore(governance): pin audit.jsonl rotation off for this session (#113)" \
            -- .squad/memory/config.json >/dev/null 2>&1 || true
      fi
    fi
  fi
  return 0
}

squad_policy_harden() {
  local repo_dir="$1"
  local state path target

  if ! command -v sha256sum >/dev/null 2>&1; then
    squad_policy_abort "sha256sum is not available, so governance integrity cannot be recorded."
  fi
  if ! command -v node >/dev/null 2>&1; then
    squad_policy_abort "node is not available, so the audit-rotation pin cannot be applied."
  fi

  squad_policy_pin_memory_audit_config "$repo_dir"

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
  squad_policy_load_governance_paths
  for path in "${SQUAD_POLICY_GOVERNANCE_PATHS[@]:-}"; do
    [[ -n "$path" ]] || continue
    target="${repo_dir}/${path}"
    [[ -e "$target" ]] || continue
    if ! chmod -R a-w "$target" 2>/dev/null; then
      squad_policy_abort "Could not make governance path '${path}' read-only."
    fi
    SQUAD_POLICY_HARDENED_PATHS+=("$path")
  done

  # SECOND PASS, and the ordering is the control. The recursive lock above has
  # already frozen every governance directory; this puts the owner write bit
  # back on the append-only and reported-mutable FILES only. `chmod` on a file
  # requires ownership, not write permission on its parent, so an unlocked file
  # can sit inside a directory that still refuses `creat()` and `unlink()`.
  # Doing it the other way round -- excluding the path from the recursive
  # `chmod` -- would not express that, because the exclusion would have to be a
  # directory to allow the file to be created, and a writable directory is a
  # writable directory.
  SQUAD_POLICY_UNLOCKED_FILES=()
  SQUAD_POLICY_REPORTED_MUTABLE_FILES=()
  local file rel
  for path in "${SQUAD_POLICY_HARDENED_PATHS[@]:-}"; do
    [[ -n "$path" ]] || continue
    target="${repo_dir}/${path}"
    if [[ -d "$target" ]]; then
      while IFS= read -r -d '' file; do
        rel="${file#"${repo_dir}/"}"
        squad_policy_is_unlockable "$rel" || continue
        if ! chmod u+w "$file" 2>/dev/null; then
          squad_policy_abort "Could not restore write access to '${rel}'."
        fi
        if squad_policy_is_mutable "$rel"; then
          SQUAD_POLICY_UNLOCKED_FILES+=("$rel")
        else
          SQUAD_POLICY_REPORTED_MUTABLE_FILES+=("$rel")
        fi
      done < <(find "$target" -type f -print0 2>/dev/null | sort -z)
    else
      squad_policy_is_unlockable "$path" || continue
      if ! chmod u+w "$target" 2>/dev/null; then
        squad_policy_abort "Could not restore write access to '${path}'."
      fi
      if squad_policy_is_mutable "$path"; then
        SQUAD_POLICY_UNLOCKED_FILES+=("$path")
      else
        SQUAD_POLICY_REPORTED_MUTABLE_FILES+=("$path")
      fi
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
  if [[ "${#SQUAD_POLICY_REPORTED_MUTABLE_FILES[@]}" -gt 0 ]]; then
    squad_policy_log "Reported-mutable exception (Squad 0.13 runtime state; writable this session, changes listed in the governance report and the PR body): ${SQUAD_POLICY_REPORTED_MUTABLE_FILES[*]}"
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
#      prefix-checked the same way, or a reported-mutable path, which may
#      differ freely (d).
#   d. every `reported` line (Issue #113: casting/*.json, identity/now.md) may
#      change arbitrarily -- rewritten, recreated, or removed -- and is never a
#      violation; a difference is collected into SQUAD_POLICY_REPORTED_CHANGES
#      for the governance report and the PR body.
squad_policy_verify() {
  local repo_dir="$1"
  local state="$SQUAD_POLICY_STATE_DIR"
  local baseline current violated=0 appended=0 reported_count=0
  SQUAD_POLICY_REPORTED_CHANGES=()

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
  # Append-only and reported-mutable PATHS are held out of this comparison ON
  # PURPOSE and checked by (b)/(d) instead. This filters by PATH, not by the
  # line's literal kind word: a deleted append-only or reported-mutable file
  # manifests as an `absent` line on the side where it is missing, not an
  # `append-only`/`reported` line, and a kind-only filter would let that
  # `absent` line slip through as an apparent locked-path change -- which is
  # exactly backwards for the reported-mutable class, where a deletion is
  # supposed to be PERMITTED, not flagged here and then separately excused.
  # Neither manifest is dropped wholesale: an operator reading either file
  # still sees the path and its hash, which is what makes "this was expected
  # to change" reviewable rather than invisible.
  squad_policy_filter_locked_lines "$baseline" "${state}/governance.locked.baseline"
  squad_policy_filter_locked_lines "$current"  "${state}/governance.locked.now"
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

  # --- (d) the reported-mutable half ----------------------------------------
  # Issue #113: casting/*.json and identity/now.md are runtime state Squad 0.13
  # legitimately rewrites. Unlike append-only, ANY difference is permitted --
  # rewritten, recreated, or removed -- so this loop never sets `violated`. It
  # exists purely to COLLECT what changed, so the change is visible in the
  # session log and can be surfaced in the PR body (see
  # squad_policy_reported_changes_report below), rather than silently allowed.
  while read -r kind rel bsum; do
    [[ "$kind" == "reported" ]] || continue
    local now_sum
    now_sum="$(awk -v P="$rel" '$1=="reported" && $2==P {print $3; exit}' "$current")"
    if [[ -z "$now_sum" ]]; then
      reported_count=$((reported_count + 1))
      SQUAD_POLICY_REPORTED_CHANGES+=("${rel} (removed)")
      squad_policy_log "Reported-mutable change (permitted): ${rel} was removed during this session."
      continue
    fi
    if [[ "$now_sum" != "$bsum" ]]; then
      reported_count=$((reported_count + 1))
      SQUAD_POLICY_REPORTED_CHANGES+=("${rel} (modified)")
      squad_policy_log "Reported-mutable change (permitted): ${rel} was modified during this session."
    fi
  done <"$baseline"

  # The mirror of the append-only "new file" check above, but PERMITTED rather
  # than a violation: a reported-mutable path that did not exist at hardening
  # time and was created during the session (for example a fresh
  # casting/registry.json) is exactly the kind of change this class exists to
  # allow.
  while read -r kind rel csum; do
    [[ "$kind" == "reported" ]] || continue
    if ! grep -q "^reported ${rel} " "$baseline" 2>/dev/null; then
      reported_count=$((reported_count + 1))
      SQUAD_POLICY_REPORTED_CHANGES+=("${rel} (created)")
      squad_policy_log "Reported-mutable change (permitted): ${rel} was created during this session."
    fi
  done <"$current"

  # --- (c) committed changes -------------------------------------------------
  # A change that was committed rather than left in the working tree.
  # `git diff <base>` sees it even if the working tree hashes match the baseline
  # again.
  local base_commit
  base_commit="$(cat "${state}/base-commit" 2>/dev/null || true)"
  if [[ -n "$base_commit" ]]; then
    local p committed committed_head violating=()
    squad_policy_load_governance_paths
    local -a paths=("${SQUAD_POLICY_GOVERNANCE_PATHS[@]:-}")
    committed="$(cd "$repo_dir" && git diff --name-only "$base_commit" -- "${paths[@]}" 2>/dev/null || true)"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      squad_policy_is_mutable "$p" && continue
      # A committed change to a reported-mutable path is already captured by
      # the hash-based detector (d) above (it compares the CURRENT working-tree
      # file, which reflects a committed change unless the agent also reverted
      # the working tree afterward -- see the KNOWN GAP note below). It must
      # not ALSO be flagged as a hard violation here, or "changes allowed"
      # would not actually mean allowed for a committed casting update.
      squad_policy_is_reported_mutable "$p" && continue
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

  if [[ "$appended" -gt 0 || "$reported_count" -gt 0 ]]; then
    local extras=()
    if [[ "$appended" -gt 0 ]]; then
      extras+=("${appended} permitted append-only work-log update(s), listed above")
    fi
    if [[ "$reported_count" -gt 0 ]]; then
      extras+=("${reported_count} permitted reported-mutable change(s), listed above")
    fi
    local extras_joined
    extras_joined="$(IFS='; '; echo "${extras[*]}")"
    squad_policy_log "Governance integrity verified: no protected path changed (${extras_joined})."
  else
    squad_policy_log "Governance integrity verified: no protected path changed."
  fi
  return 0
}

# Issue #113: a multi-line markdown fragment summarising this session's
# REPORTED_CHANGES (casting/*.json, identity/now.md), for appending to the
# pull request body. Empty output (nothing printed, nothing returned) when
# squad_policy_verify found no reported-mutable change -- entrypoint.sh appends
# this unconditionally, and an empty addendum must not alter the PR body at
# all.
squad_policy_reported_changes_report() {
  if [[ "${#SQUAD_POLICY_REPORTED_CHANGES[@]}" -eq 0 ]]; then
    return 0
  fi
  printf '\n\n## Reported-mutable governance changes\n\n'
  printf 'Squad 0.13 runtime state this session legitimately rewrote (casting state and `identity/now.md`). These are ALLOWED, not governance violations -- listed here for visibility:\n\n'
  local c
  for c in "${SQUAD_POLICY_REPORTED_CHANGES[@]}"; do
    printf -- '- %s\n' "$c"
  done
}
