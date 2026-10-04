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
#                  the session started from, is recorded IN THE MEMORY OF THE
#                  ENTRYPOINT SHELL before the agent starts (a copy is written
#                  to a 0700 directory outside the repo as a tripwire only --
#                  see the trust-boundary note in section 4a), and verified
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
  # Lets the caller (worker/entrypoint.sh) emit its governance report on an
  # abort raised from inside squad_policy_verify -- the F7 report matters most
  # exactly when the session is failing. Runs at most once.
  if [[ "${SQUAD_POLICY_ABORT_HOOK_RAN:-0}" != 1 ]] && declare -F squad_policy_on_abort >/dev/null 2>&1; then
    SQUAD_POLICY_ABORT_HOOK_RAN=1
    squad_policy_on_abort || true
  fi
  exit 78
}

# ---------------------------------------------------------------------------
# 0. Governance bundle parser
# ---------------------------------------------------------------------------
# Issue #113 perf follow-up. Every function below this point that needs a
# field out of worker/lib/agent-policy.js used to fork its OWN `node` process
# for that one field -- up to nine forks for a single harden/verify/resolve
# cycle. `node` startup is a rounding error on Linux CI but measured at several
# hundred ms to over a second under git-bash on Windows
# (worker/tests/test_governance_guard.sh's harden-heavy suite was the suite
# that made this visible: 88.5s on a clean baseline checkout vs 159.9s after
# issue #113 added more harden/verify cycles, enough to blow through
# run-tests.sh's 120s per-suite timeout). agent-policy.js's `bundle` and
# `harden-init` subcommands emit every field this file reads, from the SAME
# resolved policy object, in ONE process; this parser is the one place that
# has to agree with agent-policy.js's serializeGovernanceBundle on the line
# format, so that format is also documented there.
#
# squad_policy_bundle_assign exists only so the block-reading loop below can
# address "the array this block's 'kind' name maps to" without a `node`-style
# dynamic property lookup -- bash's nameref (`local -n`) is the same tool for
# the job.
squad_policy_bundle_assign() {
  local -n _squad_policy_bundle_target="$1"
  _squad_policy_bundle_target=("${SQUAD_POLICY_BUNDLE_BLOCK[@]}")
}

# Reads a bundle (as emitted by `agent-policy.js bundle` or `harden-init`) on
# stdin and populates every SQUAD_POLICY_* global the resolver can answer.
# Fail closed: a line this parser does not recognise is simply ignored, so a
# resolver that emitted nothing (or failed before writing anything) leaves
# every array empty -- the same "nothing is excluded, everything stays locked"
# posture the original per-field loaders documented.
squad_policy_parse_bundle() {
  local line mode="" remaining=0 name count target_var=""
  SQUAD_POLICY_BUNDLE_BLOCK=()
  SQUAD_POLICY_ARGV=()
  SQUAD_POLICY_UNDELIVERABLE=()
  SQUAD_POLICY_GOVERNANCE_PATHS=()
  SQUAD_POLICY_MUTABLE_PATTERNS=()
  SQUAD_POLICY_REPORTED_PATTERNS=()

  while IFS= read -r line; do
    if [[ -n "$mode" ]]; then
      SQUAD_POLICY_BUNDLE_BLOCK+=("$line")
      remaining=$((remaining - 1))
      if [[ "$remaining" -le 0 ]]; then
        squad_policy_bundle_assign "$target_var"
        mode=""
      fi
      continue
    fi
    case "$line" in
      "TIER "*) SQUAD_POLICY_TIER="${line#TIER }" ;;
      "REASON "*) SQUAD_POLICY_REASON="${line#REASON }" ;;
      "FLAGSTRING "*) SQUAD_POLICY_FLAGS="${line#FLAGSTRING }" ;;
      "SQUADFLAGSTRING "*) SQUAD_POLICY_SQUAD_FLAGS="${line#SQUADFLAGSTRING }" ;;
      "ARGV "*|"UNDELIVERABLE "*|"GOVPATHS "*|"MUTABLE "*|"REPORTED "*)
        name="${line%% *}"
        count="${line#* }"
        case "$name" in
          ARGV) target_var=SQUAD_POLICY_ARGV ;;
          UNDELIVERABLE) target_var=SQUAD_POLICY_UNDELIVERABLE ;;
          GOVPATHS) target_var=SQUAD_POLICY_GOVERNANCE_PATHS ;;
          MUTABLE) target_var=SQUAD_POLICY_MUTABLE_PATTERNS ;;
          REPORTED) target_var=SQUAD_POLICY_REPORTED_PATTERNS ;;
        esac
        SQUAD_POLICY_BUNDLE_BLOCK=()
        remaining="$count"
        if [[ "$remaining" -le 0 ]]; then
          # Zero-element block: there is no data line to wait for, so assign
          # the empty array immediately rather than treating the NEXT header
          # line as this block's (nonexistent) first element.
          squad_policy_bundle_assign "$target_var"
        else
          mode="$name"
        fi
        ;;
    esac
  done

  SQUAD_POLICY_BUNDLE_LOADED=1
  return 0
}

# Fetches `bundle` (no side effects, no pin) and parses it, once per process.
# squad_policy_harden loads the bundle itself via `harden-init` (which ALSO
# applies the audit-rotation pin in the same fork) and sets
# SQUAD_POLICY_BUNDLE_LOADED=1 itself, so a harden'd process never re-fetches
# here.
squad_policy_load_governance_bundle() {
  if [[ "${SQUAD_POLICY_BUNDLE_LOADED:-0}" -eq 1 ]]; then
    return 0
  fi
  squad_policy_parse_bundle < <(node "$SQUAD_POLICY_RESOLVER" bundle 2>/dev/null)
  return 0
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

  # Issue #113 perf: ONE `node` fork for tier/reason/flags/argv/squad-flags/
  # undeliverable together, instead of six. See squad_policy_parse_bundle.
  local bundle_output rc
  bundle_output="$(node "$SQUAD_POLICY_RESOLVER" bundle 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    squad_policy_log "Policy resolution failed (exit ${rc}): ${bundle_output}"
    squad_policy_abort "The session policy could not be resolved."
  fi
  squad_policy_parse_bundle <<<"$bundle_output"

  if [[ -z "$SQUAD_POLICY_TIER" || -z "$SQUAD_POLICY_FLAGS" ]]; then
    squad_policy_abort "The policy resolver produced an empty tier or flag set."
  fi

  # A resolver that ever emitted a blanket-allow flag would silently undo this
  # whole change, so the caller checks rather than trusts. This is cheap and it
  # is the last line of defence before the flags reach `copilot`.
  #
  # Security review of #112/#113 (F2): `--allow-all-urls` is added here too.
  # `copilot --help` documents `--yolo`/`--allow-all` as both expanding to
  # `--allow-all-tools --allow-all-paths --allow-all-urls` -- this case used to
  # catch two of those three expanded flags and miss the third, which is the
  # URL-exfiltration half of `--yolo`.
  case " $SQUAD_POLICY_FLAGS " in
    *" --yolo "*|*" --allow-all "*|*" --allow-all-paths "*|*" --allow-all-urls "*)
      squad_policy_abort "The resolved flag set contains a blanket-allow flag: ${SQUAD_POLICY_FLAGS}"
      ;;
  esac

  # The authoritative argv, one token per line, so a multi-word deny pattern
  # stays ONE argument. SQUAD_POLICY_ARGV is populated by the parse above
  # straight from the bundle's ARGV block.
  if [[ "${#SQUAD_POLICY_ARGV[@]}" -eq 0 ]]; then
    squad_policy_abort "The policy resolver produced an empty argv."
  fi

  if [[ -z "$SQUAD_POLICY_SQUAD_FLAGS" ]]; then
    squad_policy_abort "The policy resolver produced no --copilot-flags string."
  fi

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
  elif [[ "$via" == "hub" && "${SQUAD_HUB_APPROVAL:-ask}" == "auto" ]]; then
    # Watch-only (SQUAD_HUB_APPROVAL=auto): the hub sees the session, but the
    # agent keeps --allow-all-tools, so print the flags exactly as applied.
    squad_policy_log "Copilot flags (via Squad Hub, ACP, watch-only): ${SQUAD_POLICY_FLAGS}"
    squad_policy_log "  WATCH-ONLY: visible in the hub, nothing waits for approval (SQUAD_HUB_APPROVAL=auto)."
    squad_policy_log "  Deny patterns are unchanged and are still refused outright."
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
# Where the TRIPWIRE copies of the integrity state are written. Outside the
# checkout (so the agent's FILE tools, confined to the repo without
# `--allow-all-paths`, cannot reach it), 0700 under $HOME.
#
# Security re-review N1: this directory is NOT a trust boundary. It is owned by
# the same uid the agent runs as, and the agent's SHELL tool can `rm` or
# rewrite anything in it. Nothing read back from here is ever treated as the
# baseline -- see the trust-boundary note in section 4a. Do not move
# authoritative state back into this directory.
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

# Security review of #112/#113 (F8). `.mcp.json` is repo-controlled and is
# deliberately NOT a governance path (it is not in GOVERNANCE_PATHS, not
# append-only, not reported-mutable -- Squad itself may legitimately need to
# add an MCP server to it). That means nothing stops an autonomous session
# from rewriting it mid-loop to point at an attacker-controlled MCP server --
# and worker/squad-agent, run fresh for every `squad watch`/`squad loop`
# iteration, would otherwise load whatever is on disk at THAT moment with no
# check at all. squad_policy_verify cannot close this alone: it runs exactly
# once, after the whole session's `squad watch`/`loop` process exits, which is
# too late to stop the NEXT spawn within that same session from already having
# read a rewritten .mcp.json.
#
# This records a SHA-256 baseline (or the literal sentinel `absent` when the
# file does not exist yet at harden time), ONCE, at harden time, before the
# agent ever runs. Security re-review N1/N3: the state directory is NOT out of
# the agent's reach (same uid, shell tool), so the authoritative copy travels
# in the exported environment -- see section 4a -- and the file in the state
# directory is only a tripwire.
squad_policy_record_mcp_config_baseline() {
  local repo_dir="$1" state="$2" mcp="${1}/.mcp.json" hash
  if [[ -f "$mcp" ]]; then
    hash="$(sha256sum "$mcp" 2>/dev/null | awk '{print $1}')" || return 1
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  else
    hash="absent"
  fi
  SQUAD_POLICY_MCP_DIGEST="$hash"
  # Security re-review N1/N3: the AUTHORITATIVE copy for worker/squad-agent is
  # this environment variable, inherited by `squad watch`/`squad loop` and so
  # by every wrapper spawn; the agent cannot rewrite an ancestor's
  # environment. The file below is a tripwire the wrapper ALSO checks (missing
  # or different => refuse), never the source of truth.
  SQUAD_POLICY_MCP_CONFIG_SHA256="$hash"
  export SQUAD_POLICY_MCP_CONFIG_SHA256
  printf '%s\n' "$hash" > "${state}/mcp-config.sha256" || return 1
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
#
# Issue #113 perf: this, squad_policy_load_mutable_patterns and
# squad_policy_load_reported_mutable_patterns all used to fork their OWN
# `node` process for their one field; now they are three thin wrappers over
# the SAME cached bundle fetch (squad_policy_load_governance_bundle), so
# three forks become (at most) one, shared with squad_policy_resolve's and
# squad_policy_harden's bundle fetch when those already ran first in this
# process.
SQUAD_POLICY_GOVERNANCE_PATHS=()
squad_policy_load_governance_paths() {
  squad_policy_load_governance_bundle
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
  squad_policy_load_governance_bundle
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
  squad_policy_load_governance_bundle
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
# excused. `dir` and `symlink` lines are passed through unfiltered -- neither
# may ever be excused by a mutable pattern.
#
# Re-review N1: stdin -> stdout. It used to write intermediate files into the
# policy state directory, which the agent can reach.
squad_policy_filter_locked_lines() {
  local kind rel rest
  # Deliberately plain `read` (default IFS) so the line splits on whitespace
  # into kind/rel/rest the same way every other manifest reader in this file
  # does -- `IFS= read` would disable field splitting entirely and leave the
  # whole line in $kind, silently defeating every check below.
  while read -r kind rel rest; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" != "dir" && "$kind" != "symlink" ]]; then
      squad_policy_is_mutable "$rel" && continue
      squad_policy_is_reported_mutable "$rel" && continue
    fi
    if [[ -n "$rest" ]]; then
      printf '%s %s %s\n' "$kind" "$rel" "$rest"
    else
      printf '%s %s\n' "$kind" "$rel"
    fi
  done
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

# Security review of #112/#113 (F9). squad_policy_harden's own log used to
# claim, for EVERY append-only/reported-mutable exception, "Their containing
# directories stay locked, so no file can be created or deleted beside them."
# That is true for `.squad/agents/<name>/history.md` (parent `.squad/agents`)
# and `.squad/identity/now.md` (parent `.squad/identity`) -- both parents are
# themselves GOVERNANCE_PATHS directory entries, so squad_policy_harden's
# `chmod -R a-w` genuinely locks them. It is FALSE for
# `.squad/memory/audit.jsonl` (parent `.squad/memory`) and
# `.squad/casting/*.json` (parent `.squad/casting`): neither `.squad/memory`
# nor `.squad/casting` is itself a GOVERNANCE_PATHS entry -- only the
# individual FILES under them are -- so neither directory is ever passed to
# `chmod -R a-w`, and a new file beside audit.jsonl or any casting/*.json CAN
# be freely created or removed.
#
# The fix taken here is to CORRECT THE CLAIM rather than lock the two
# directories: locking them would need a POSIX directory permission bit,
# which `test_governance_guard.sh` already documents does not hold on Windows
# (7 pre-existing directory-permission assertions are skipped-as-failing
# there for exactly this reason) -- adding two more untestable-on-Windows
# directory locks would only grow that list, not shrink it, and this review
# round is explicit that no NEW failures of that kind should be introduced.
# Correctness here is therefore an honest LOG MESSAGE, split by whether the
# containing directory is actually one of GOVERNANCE_PATHS (or nested under
# one), checked against the real, already-loaded
# SQUAD_POLICY_GOVERNANCE_PATHS array -- not a hand-maintained second list
# that could drift from it.
squad_policy_parent_dir_is_locked() {
  local rel="$1" parent="${rel%/*}" p
  for p in "${SQUAD_POLICY_GOVERNANCE_PATHS[@]:-}"; do
    [[ -n "$p" ]] || continue
    if [[ "$parent" == "$p" || "$parent" == "$p"/* ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 4a. TRUST BOUNDARY for governance state (security re-review N1, N2, N3)
# ---------------------------------------------------------------------------
# READ THIS BEFORE MOVING ANY GOVERNANCE STATE ONTO DISK.
#
# WHO CAN TOUCH WHAT. worker/entrypoint.sh drops to the `squad` uid with
# `runuser` (PC-2) before ANY of this file runs, and the Copilot agent runs as
# that SAME uid. The agent's shell tool is not path-confined and `rm`, `mv`,
# `printf >`, `sh -c` are not on the deny list. So, for the agent:
#   - every FILE this process can write, the agent can delete, rename or
#     rewrite -- SQUAD_POLICY_STATE_DIR (`$HOME/.squad-policy/...`, mode 0700)
#     included: 0700 keeps out OTHER uids, and the agent is not another uid;
#   - a "root-owned file in an agent-writable directory" would not help
#     either: unlink() needs write on the PARENT, not on the file;
#   - `$HOME` of the `squad` user is agent-writable by definition.
# The previous round kept the governance baseline, the .mcp.json baseline, the
# base commit and the F4/F6 high-water marks in that directory, and the
# security re-review proved one `rm` undid all of them (A2, A4, A5b, A5c).
#
# WHERE AUTHORITY LIVES NOW. Two independent layers, either of which alone
# defeats A2/A4/A5b/A5c:
#
#   0. THE UID BOUNDARY (section 4c). When worker/entrypoint.sh starts as root
#      (the container default), it creates a root-owned 0711 directory under
#      /run and a ROOT sealer process, BEFORE `runuser` drops to `squad`. Only
#      the sealer (uid 0) ever writes there. At the end of harden -- before
#      any agent exists -- this process hands the baseline to the sealer over
#      a pipe, waits for the sealed root-owned 0644 copies, and reads them
#      back against memory. The agent (uid `squad`) cannot unlink, rename,
#      create or rewrite anything there: unlink/rename/create need write on a
#      root-owned 0711 directory, and rewrite needs write on a root-owned 0644
#      file. verify and worker/squad-agent then require the sealed copies to
#      still match. Without root at container start (a developer running the
#      script directly, the test suites) there is no sealer and layers 1-4
#      stand alone -- that is logged, never silent.
#
# What the agent also CANNOT reach without ptrace is the MEMORY of the
# entrypoint shell that runs both squad_policy_harden and squad_policy_verify
# (the agent is a DESCENDANT of it, and Yama's default ptrace_scope=1 forbids
# a descendant attaching to an ancestor; /proc/<pid>/mem is gated by the same
# ptrace check). So, as defence in depth:
#
#   1. AUTHORITATIVE state is held ONLY in non-exported shell variables of the
#      hardening process: the baseline manifest
#      (SQUAD_POLICY_BASELINE_MANIFEST), the base commit, the .mcp.json digest,
#      the inode/ctime fingerprints of every writable governance file, and the
#      sampler's pid/fd/nonce. They are reset when this file is sourced, so
#      nothing is inherited from the environment. squad_policy_verify NEVER
#      reads a baseline back from disk, and never round-trips a comparison
#      through a temp file a lingering agent process could swap.
#   2. On-disk copies (governance.sha256, mcp-config.sha256, base-commit) are
#      still written, for operators -- but they are TRIPWIRES, not inputs. At
#      verify, a missing state directory, or any of those files missing or
#      differing from the in-memory value, is TAMPER EVIDENCE: every detector
#      still runs (so the log says what else changed) and the session then
#      aborts with exit 78. Missing state is never "nothing to check".
#   3. The ONE value a different process needs -- worker/squad-agent's
#      .mcp.json check, run by `squad watch`/`squad loop` for every iteration
#      -- travels in the ENVIRONMENT (SQUAD_POLICY_MCP_CONFIG_SHA256). That env
#      is copied from this process into `squad watch`'s at spawn; the agent
#      (a child of a child of `squad watch`) cannot alter an ancestor's
#      environment, so every subsequent spawn sees the harden-time digest.
#      The threat is integrity, not secrecy, so it does not matter that the
#      agent can READ it.
#   4. The high-water sampler (N2) keeps its marks in ITS OWN memory, never on
#      disk, and hands them back over a pipe only this process holds the read
#      end of, terminated by a nonce only this process and the sampler know.
#      Killing or stopping the sampler is detected (dead pid, no answer) and is
#      itself a violation.
#
# RESIDUAL (asserted, not hidden): a same-uid process that can ptrace the
# entrypoint shell (kernel.yama.ptrace_scope=0, or CAP_SYS_PTRACE) can rewrite
# this memory -- but NOT the root-sealed copies (layer 0), which verify also
# requires. `chattr +a` on append-only files would need CAP_LINUX_IMMUTABLE,
# which Docker's and ACA's default capability set does not grant and this
# image cannot verify it has; it is a documented residual, not code.
#
# NOTHING IN THIS SECTION MAY BE "OPTIMISED" BACK ONTO DISK. If a value has to
# be shared with another process, pass it by environment at spawn time (as in
# 3) and make the reader fail closed when it is missing.
unset SQUAD_POLICY_BASELINE_MANIFEST SQUAD_POLICY_BASELINE_TAKEN SQUAD_POLICY_BASE_COMMIT \
      SQUAD_POLICY_MCP_DIGEST SQUAD_POLICY_SAMPLER_PID SQUAD_POLICY_SAMPLER_FD \
      SQUAD_POLICY_SAMPLER_NONCE SQUAD_POLICY_SAMPLER_COLLECTED SQUAD_POLICY_SAMPLER_VERDICT \
      SQUAD_POLICY_FINGERPRINTS SQUAD_POLICY_HWM_AO SQUAD_POLICY_HWM_RP \
      SQUAD_POLICY_HWM_AO_REL SQUAD_POLICY_HWM_AO_ABS SQUAD_POLICY_HWM_AO_BLEN \
      SQUAD_POLICY_HWM_RP_REL SQUAD_POLICY_HWM_RP_ABS SQUAD_POLICY_HWM_RP_BSUM \
      SQUAD_POLICY_SEAL_EXPECTED SQUAD_POLICY_HARDEN_SHELL_PID 2>/dev/null
SQUAD_POLICY_SEAL_EXPECTED=0
SQUAD_POLICY_HARDEN_SHELL_PID=""
SQUAD_POLICY_BASELINE_MANIFEST=""
SQUAD_POLICY_BASELINE_TAKEN=0
SQUAD_POLICY_BASE_COMMIT=""
SQUAD_POLICY_MCP_DIGEST=""
SQUAD_POLICY_SAMPLER_PID=""
SQUAD_POLICY_SAMPLER_FD=""
SQUAD_POLICY_SAMPLER_NONCE=""
SQUAD_POLICY_SAMPLER_COLLECTED=0
SQUAD_POLICY_SAMPLER_VERDICT=""
declare -gA SQUAD_POLICY_FINGERPRINTS=()
declare -gA SQUAD_POLICY_HWM_AO=()
declare -gA SQUAD_POLICY_HWM_RP=()
declare -ga SQUAD_POLICY_HWM_AO_REL=() SQUAD_POLICY_HWM_AO_ABS=() SQUAD_POLICY_HWM_AO_BLEN=()
declare -ga SQUAD_POLICY_HWM_RP_REL=() SQUAD_POLICY_HWM_RP_ABS=() SQUAD_POLICY_HWM_RP_BSUM=()

# 128 bits from bash's CSPRNG ($SRANDOM, bash >= 5.1), falling back to
# /dev/urandom. Never exported, never written to disk.
squad_policy_nonce() {
  if [[ -n "${SRANDOM:-}" ]]; then
    printf '%08x%08x%08x%08x' "$SRANDOM" "$SRANDOM" "$SRANDOM" "$SRANDOM"
    return 0
  fi
  od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n'
}

# Inode + ctime fingerprint, one `stat` fork for every file given, printed as
# "<fingerprint>\t<path>" lines. ctime cannot be set from user space (no
# utimes() for ctime; only CAP_SYS_TIME could fake it by moving the clock), and
# it moves on EVERY write, truncate and chmod -- so "content equal to baseline,
# fingerprint different" proves the file was touched and put back, no matter
# how quickly. That is what makes the exact-to-baseline half of F4/F6 an
# INVARIANT checked from end state, rather than a race against a sampler.
squad_policy_fingerprints() {
  [[ "$#" -gt 0 ]] || return 0
  stat --printf '%i/%z\t%n\n' -- "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 4c. Root-sealed state: the uid boundary (re-review N1; layer 0 above)
# ---------------------------------------------------------------------------
# worker/entrypoint.sh, while still root, calls squad_policy_sealer_start:
# a fresh root-owned 0711 directory (mktemp under /run, so nothing can
# pre-create or pre-link it) and a ROOT process reading records from a pipe.
# The write end is exported as SQUAD_POLICY_SEAL_FD and survives the
# `runuser` drop. Records, one per line:
#   FILE <name> <base64>  each of SQUAD_POLICY_SEAL_NAMES exactly once;
#   SEAL                  writes the root-owned 0644 copies, then the
#                         `sealed` marker LAST. A malformed, unknown,
#                         duplicate or missing record before SEAL writes
#                         `seal-error` instead and the sealer exits, so
#                         harden aborts (78);
#   REPORT <base64>       after SEAL only: appended to reported-changes.md
#                         (the F7 governance report), size-capped.
# After SEAL, FILE/SEAL are ignored: nothing can change a sealed copy.
# Framing is by record, not EOF: root's `runuser` parent also holds the write
# end for the whole session, so EOF only arrives when the session ends.
#
# Who holds the write end: the entrypoint shell, plus whatever it spawned
# BEFORE harden (bootstrap). The agent is started through
# squad_policy_exec_agent, which closes it. A process that does reach it can
# only (a) seal FIRST with forged content -- harden reads the sealed copies
# back against memory and aborts: a denial of service, not a bypass -- or (b)
# append noise to the report. It cannot alter or remove a sealed copy: only
# uid 0 can write that directory or those files.
#
# Readable (0711 dir, 0644 files) on purpose: worker/squad-agent and verify run
# as the unprivileged uid and must READ the sealed copies. The threat is
# integrity, not secrecy -- every value here is recomputable by the agent.
SQUAD_POLICY_SEAL_NAMES=(governance.sha256 mcp-config.sha256 base-commit)

# Runs AS ROOT, in its own process, reading records on stdin.
squad_policy_sealer_main() {
  local dir="$1" max="${SQUAD_POLICY_SEAL_REPORT_MAX_BYTES:-4194304}"
  local line verb rest name payload n sealed=0 size=0 full=0 report
  local -A pending=()
  set +eEu +o pipefail 2>/dev/null
  trap - ERR EXIT RETURN DEBUG
  trap '' TERM INT HUP PIPE
  umask 022
  report="${dir}/reported-changes.md"
  _sqp_seal_fail() {
    printf '%s\n' "$1" >"${dir}/.seal-error.tmp" 2>/dev/null
    mv -f "${dir}/.seal-error.tmp" "${dir}/seal-error" 2>/dev/null
    exit 0
  }
  while IFS= read -r line; do
    verb="${line%% *}"
    rest=""
    [[ "$line" == *" "* ]] && rest="${line#* }"
    if [[ "$sealed" -eq 0 ]]; then
      case "$verb" in
        FILE)
          [[ "$rest" == *" "* ]] || _sqp_seal_fail "malformed FILE record"
          name="${rest%% *}"
          payload="${rest#* }"
          case "$name" in
            governance.sha256|mcp-config.sha256|base-commit) ;;
            *) _sqp_seal_fail "FILE record names an unknown file" ;;
          esac
          [[ -z "${pending[$name]+x}" ]] || _sqp_seal_fail "duplicate FILE record for ${name}"
          [[ "$payload" =~ ^[A-Za-z0-9+/]*=*$ ]] || _sqp_seal_fail "FILE record for ${name} is not base64"
          pending["$name"]="$payload"
          ;;
        SEAL)
          for n in "${SQUAD_POLICY_SEAL_NAMES[@]}"; do
            [[ -n "${pending[$n]+x}" ]] || _sqp_seal_fail "SEAL before a FILE record for ${n}"
          done
          for n in "${SQUAD_POLICY_SEAL_NAMES[@]}"; do
            printf '%s' "${pending[$n]}" | base64 -d >"${dir}/.${n}.tmp" 2>/dev/null || \
              _sqp_seal_fail "could not decode ${n}"
            chmod 0644 "${dir}/.${n}.tmp" && mv -f "${dir}/.${n}.tmp" "${dir}/${n}" || \
              _sqp_seal_fail "could not write ${n}"
          done
          : >"${dir}/.sealed.tmp" && chmod 0644 "${dir}/.sealed.tmp" && \
            mv -f "${dir}/.sealed.tmp" "${dir}/sealed" || _sqp_seal_fail "could not write the sealed marker"
          sealed=1
          ;;
        *) _sqp_seal_fail "unexpected record before SEAL" ;;
      esac
      continue
    fi
    [[ "$verb" == REPORT && "$full" -eq 0 ]] || continue
    [[ "$rest" =~ ^[A-Za-z0-9+/]*=*$ ]] || continue
    printf '%s' "$rest" | base64 -d 2>/dev/null | head -c "$((max - size))" >>"$report"
    chmod 0644 "$report" 2>/dev/null
    size="$(stat -c '%s' -- "$report" 2>/dev/null || echo "$max")"
    if [[ "$size" -ge "$max" ]]; then
      printf '\n[report truncated at %s bytes]\n' "$max" >>"$report"
      full=1
    fi
  done
  [[ "$sealed" -eq 1 ]] || _sqp_seal_fail "the seal channel closed before SEAL"
  exit 0
}

# Called by worker/entrypoint.sh AS ROOT, before the privilege drop. Leaves
# SQUAD_POLICY_SEAL_FD (write end) and SQUAD_POLICY_SEALED_DIR exported.
squad_policy_sealer_start() {
  local base="${1:-/run}" dir
  [[ "$(id -u)" -eq 0 ]] || return 1
  dir="$(mktemp -d "${base}/squad-policy.XXXXXXXX")" || return 1
  chown 0:0 "$dir" && chmod 0711 "$dir" || return 1
  exec {SQUAD_POLICY_SEAL_FD}> >(squad_policy_sealer_main "$dir" >/dev/null 2>&1)
  [[ -n "${SQUAD_POLICY_SEAL_FD:-}" ]] || return 1
  SQUAD_POLICY_SEALED_DIR="$dir"
  export SQUAD_POLICY_SEAL_FD SQUAD_POLICY_SEALED_DIR
  return 0
}

squad_policy_seal_send() {
  local fd="${SQUAD_POLICY_SEAL_FD:-}"
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  ( trap '' PIPE; printf '%s\n' "$1" >&"$fd" ) 2>/dev/null
}

# One line per problem; no output means the sealed copies are intact and match
# this process's in-memory baseline.
squad_policy_seal_problems() {
  local dir="${SQUAD_POLICY_SEALED_DIR:-}" i name f got
  local -a want=("$SQUAD_POLICY_BASELINE_MANIFEST" "$SQUAD_POLICY_MCP_DIGEST" "$SQUAD_POLICY_BASE_COMMIT")
  [[ -f "${dir}/sealed" ]] || echo "the root-sealed marker ${dir}/sealed is missing"
  for i in 0 1 2; do
    name="${SQUAD_POLICY_SEAL_NAMES[$i]}"
    f="${dir}/${name}"
    if [[ ! -f "$f" ]]; then
      echo "the root-sealed ${name} is missing"
      continue
    fi
    [[ "$(stat -c '%u' -- "$f" 2>/dev/null)" == 0 ]] || echo "the root-sealed ${name} is not owned by root"
    got="$(<"$f")"
    [[ "$got" == "${want[$i]}" ]] || echo "the root-sealed ${name} does not match the harden-time value"
  done
}

# Last step of harden, before any agent exists. Fail closed: a session that
# was promised a uid boundary (either variable set) and cannot get one aborts.
squad_policy_seal_commit() {
  local fd="${SQUAD_POLICY_SEAL_FD:-}" dir="${SQUAD_POLICY_SEALED_DIR:-}"
  local timeout="${SQUAD_POLICY_SEAL_TIMEOUT_SECONDS:-10}" owner i problems
  SQUAD_POLICY_SEAL_EXPECTED=0
  if [[ -z "$fd" && -z "$dir" ]]; then
    squad_policy_log "No root-sealed state store: this process was not started as root by worker/entrypoint.sh, so there is no uid boundary; governance state relies on the in-memory baseline and tripwires only."
    return 0
  fi
  if [[ ! "$fd" =~ ^[0-9]+$ || -z "$dir" ]]; then
    squad_policy_abort "The root-sealed state store is half-configured (SQUAD_POLICY_SEAL_FD='${fd}', SQUAD_POLICY_SEALED_DIR='${dir}')."
  fi
  if [[ -L "$dir" || ! -d "$dir" ]] || ! owner="$(stat -c '%u' -- "$dir" 2>/dev/null)" || [[ "$owner" != 0 ]]; then
    squad_policy_abort "The root-sealed state store ${dir} is not a root-owned directory; it is not a uid boundary."
  fi
  if [[ -w "$dir" ]]; then
    squad_policy_abort "The root-sealed state store ${dir} is writable by uid $(id -u); it is not a uid boundary."
  fi
  local -a vals=("$SQUAD_POLICY_BASELINE_MANIFEST" "$SQUAD_POLICY_MCP_DIGEST" "$SQUAD_POLICY_BASE_COMMIT")
  for i in 0 1 2; do
    squad_policy_seal_send "FILE ${SQUAD_POLICY_SEAL_NAMES[$i]} $(printf '%s\n' "${vals[$i]}" | base64 -w0)" || \
      squad_policy_abort "Could not hand the governance baseline to the root sealer."
  done
  squad_policy_seal_send "SEAL" || squad_policy_abort "Could not hand the governance baseline to the root sealer."
  for ((i = 0; i < timeout * 10; i++)); do
    [[ -e "${dir}/sealed" || -e "${dir}/seal-error" ]] && break
    sleep 0.1
  done
  if [[ -e "${dir}/seal-error" ]]; then
    squad_policy_abort "The root sealer refused the governance baseline: $(head -c 200 "${dir}/seal-error" 2>/dev/null)"
  fi
  [[ -e "${dir}/sealed" ]] || squad_policy_abort "The root sealer did not seal the governance baseline within ${timeout}s."
  problems="$(squad_policy_seal_problems)"
  if [[ -n "$problems" ]]; then
    squad_policy_abort "The root-sealed governance baseline does not match this process's (something sealed first): ${problems//$'\n'/; }"
  fi
  SQUAD_POLICY_SEAL_EXPECTED=1
  squad_policy_log "Governance baseline sealed in root-owned ${dir} (uid $(id -u) cannot write, rename or delete it)."
  return 0
}

# F7: hands a report block to the root sealer. Non-zero when there is no
# sealed store (the caller falls back).
squad_policy_seal_report() {
  [[ "${SQUAD_POLICY_SEAL_EXPECTED:-0}" == 1 ]] || return 1
  local f="${SQUAD_POLICY_SEALED_DIR}/reported-changes.md" before now i
  before="$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)"
  squad_policy_seal_send "REPORT $(printf '%s\n' "$1" | base64 -w0)" || return 1
  # The entrypoint usually exits right after this, and with it the container;
  # give the sealer a moment to land the append first.
  for ((i = 0; i < 30; i++)); do
    now="$(stat -c '%s' -- "$f" 2>/dev/null || echo 0)"
    [[ "$now" != "$before" ]] && return 0
    sleep 0.1
  done
  return 0
}

# Starts an agent (or anything that will run one) with this shell's private
# policy descriptors closed: the sampler's read end (stealing its answer is a
# violation, i.e. a DoS) and the seal channel. MUST run in a child -- a
# `( ... )` subshell or a background job -- because it execs or exits; it
# refuses to run in the hardening shell itself.
squad_policy_exec_agent() {
  if [[ "$BASHPID" == "$$" || "$BASHPID" == "${SQUAD_POLICY_HARDEN_SHELL_PID:-}" ]]; then
    squad_policy_abort "squad_policy_exec_agent was called in the hardening shell itself; it must run in a subshell or background job."
  fi
  if [[ -n "${SQUAD_POLICY_SAMPLER_FD:-}" ]]; then
    exec {SQUAD_POLICY_SAMPLER_FD}<&-
  fi
  if [[ -n "${SQUAD_POLICY_SEAL_FD:-}" ]]; then
    exec {SQUAD_POLICY_SEAL_FD}>&-
  fi
  unset SQUAD_POLICY_SEAL_FD
  if declare -F -- "$1" >/dev/null 2>&1; then
    "$@"
    exit $?
  fi
  exec "$@"
}

# ---------------------------------------------------------------------------
# 4b. In-session high-water tracking (F4, F6; re-review N2)
# ---------------------------------------------------------------------------
# What end state alone cannot show: an append-only file grown during the
# session and then PARTIALLY truncated to a length still ABOVE its baseline
# (valid prefix, legitimate-looking append) -- the removed tail leaves no
# trace in content, and its ctime legitimately moved because of the append.
# That sub-case is only observable WHILE it happens, so a sampler watches the
# writable governance files and keeps a monotonic high-water mark.
#
# HONEST LIMIT (N2). Sampling cannot be an invariant: a grow-then-partially-
# truncate completed entirely inside one interval is not seen. The interval
# defaults to 1s (was 5s). Everything else the previous round leaned on the
# sampler for is now an invariant from end state: truncate-to-exact-baseline
# and modify-then-revert are caught by the ctime fingerprint (4a) regardless
# of timing. The only true fix for the residual is kernel-enforced append-only
# (`chattr +a`, CAP_LINUX_IMMUTABLE before the privilege drop) or inotify --
# see the trust-boundary note above for why chattr is a documented residual.
#
# The sampler is a process substitution, so:
#   - it inherits the in-memory baseline by fork() and never reads disk state;
#   - its marks live in ITS memory; nothing is written to the state directory;
#   - its stdout is a pipe whose read end only this shell holds; on SIGUSR1 it
#     runs one last scan, prints its marks and `END <nonce>`, and exits;
#   - it ignores TERM/INT/HUP (a group-wide shutdown signal must not erase the
#     evidence before the checkpoint runs) and exits on its own within one
#     interval of the hardening shell going away.
# Forged lines can only RAISE a mark (verify merges with max()), and a forged
# terminator without the nonce is ignored, so even a process that somehow got
# the write end cannot launder a mark downward.

# Parses the in-memory baseline into the per-class arrays the scan walks.
squad_policy_highwater_prepare() {
  local repo_dir="$1" kind rel bsum blen
  SQUAD_POLICY_HWM_AO_REL=(); SQUAD_POLICY_HWM_AO_ABS=(); SQUAD_POLICY_HWM_AO_BLEN=()
  SQUAD_POLICY_HWM_RP_REL=(); SQUAD_POLICY_HWM_RP_ABS=(); SQUAD_POLICY_HWM_RP_BSUM=()
  SQUAD_POLICY_HWM_AO=(); SQUAD_POLICY_HWM_RP=()
  while read -r kind rel bsum blen; do
    case "$kind" in
      append-only)
        SQUAD_POLICY_HWM_AO_REL+=("$rel"); SQUAD_POLICY_HWM_AO_ABS+=("${repo_dir}/${rel}")
        SQUAD_POLICY_HWM_AO_BLEN+=("$blen"); SQUAD_POLICY_HWM_AO["$rel"]="$blen"
        ;;
      reported)
        SQUAD_POLICY_HWM_RP_REL+=("$rel"); SQUAD_POLICY_HWM_RP_ABS+=("${repo_dir}/${rel}")
        SQUAD_POLICY_HWM_RP_BSUM+=("$bsum"); SQUAD_POLICY_HWM_RP["$rel"]=0
        ;;
      *) : ;;
    esac
  done <<<"$SQUAD_POLICY_BASELINE_MANIFEST"
}

# One sampling pass. Updates SQUAD_POLICY_HWM_AO / SQUAD_POLICY_HWM_RP in the
# CALLING process's memory only (in practice: the sampler's). Batched: one
# `wc -c` fork for every append-only file and one `sha256sum` fork for every
# reported-mutable file, not one per path.
squad_policy_highwater_scan() {
  local p i rel len csum line sum rest wc_len
  if [[ "${#SQUAD_POLICY_HWM_AO_REL[@]}" -gt 0 ]]; then
    local -A curlen=()
    local -a existing=()
    for p in "${SQUAD_POLICY_HWM_AO_ABS[@]}"; do
      [[ -f "$p" ]] && existing+=("$p")
    done
    if [[ "${#existing[@]}" -gt 0 ]]; then
      while read -r wc_len rest; do
        [[ -n "$wc_len" ]] || continue
        [[ "$rest" == total ]] && continue
        curlen["$rest"]="$wc_len"
      done < <(wc -c "${existing[@]}" 2>/dev/null)
    fi
    for ((i = 0; i < ${#SQUAD_POLICY_HWM_AO_REL[@]}; i++)); do
      rel="${SQUAD_POLICY_HWM_AO_REL[$i]}"
      len="${curlen[${SQUAD_POLICY_HWM_AO_ABS[$i]}]:-0}"
      if [[ "$len" -gt "${SQUAD_POLICY_HWM_AO[$rel]:-0}" ]]; then
        SQUAD_POLICY_HWM_AO["$rel"]="$len"
      fi
    done
  fi
  if [[ "${#SQUAD_POLICY_HWM_RP_REL[@]}" -gt 0 ]]; then
    local -A cursum=()
    local -a existing_rp=()
    for p in "${SQUAD_POLICY_HWM_RP_ABS[@]}"; do
      [[ -f "$p" ]] && existing_rp+=("$p")
    done
    if [[ "${#existing_rp[@]}" -gt 0 ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        sum="${line%% *}"; rest="${line#* }"; rest="${rest# }"; rest="${rest#\*}"
        cursum["$rest"]="$sum"
      done < <(sha256sum "${existing_rp[@]}" 2>/dev/null)
    fi
    for ((i = 0; i < ${#SQUAD_POLICY_HWM_RP_REL[@]}; i++)); do
      rel="${SQUAD_POLICY_HWM_RP_REL[$i]}"
      csum="${cursum[${SQUAD_POLICY_HWM_RP_ABS[$i]}]:-}"
      if [[ "$csum" != "${SQUAD_POLICY_HWM_RP_BSUM[$i]}" ]]; then
        SQUAD_POLICY_HWM_RP["$rel"]=1
      fi
    done
  fi
  return 0
}

squad_policy_highwater_sampler_start() {
  local repo_dir="$1"
  local interval="${SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS:-1}"
  local parent="$BASHPID" nonce
  nonce="$(squad_policy_nonce)"
  [[ -n "$nonce" ]] || return 1
  SQUAD_POLICY_SAMPLER_NONCE="$nonce"
  SQUAD_POLICY_SAMPLER_COLLECTED=0
  SQUAD_POLICY_SAMPLER_VERDICT=""
  if [[ -n "$SQUAD_POLICY_SAMPLER_FD" ]]; then
    exec {SQUAD_POLICY_SAMPLER_FD}<&-
    SQUAD_POLICY_SAMPLER_FD=""
  fi
  squad_policy_highwater_prepare "$repo_dir"
  # shellcheck disable=SC2064
  exec {SQUAD_POLICY_SAMPLER_FD}< <(
    exec </dev/null 2>/dev/null
    if [[ -n "${SQUAD_POLICY_SEAL_FD:-}" ]]; then
      exec {SQUAD_POLICY_SEAL_FD}>&-
    fi
    set +eEu +o pipefail 2>/dev/null
    trap - ERR EXIT RETURN DEBUG
    trap '' TERM INT HUP PIPE
    _sqp_dump=0
    _sqp_sleep=""
    trap '_sqp_dump=1; [[ -n "$_sqp_sleep" ]] && kill "$_sqp_sleep" 2>/dev/null' USR1
    while [[ "$_sqp_dump" -eq 0 ]] && kill -0 "$parent" 2>/dev/null; do
      sleep "$interval" &
      _sqp_sleep=$!
      wait "$_sqp_sleep" 2>/dev/null
      _sqp_sleep=""
      squad_policy_highwater_scan
    done
    if [[ "$_sqp_dump" -eq 1 ]]; then
      squad_policy_highwater_scan
      for _sqp_r in "${!SQUAD_POLICY_HWM_AO[@]}"; do
        printf 'hwm-ao %s %s\n' "$_sqp_r" "${SQUAD_POLICY_HWM_AO[$_sqp_r]}"
      done
      for _sqp_r in "${!SQUAD_POLICY_HWM_RP[@]}"; do
        printf 'hwm-rp %s %s\n' "$_sqp_r" "${SQUAD_POLICY_HWM_RP[$_sqp_r]}"
      done
      printf 'END %s\n' "$nonce"
    fi
    exit 0
  )
  SQUAD_POLICY_SAMPLER_PID="$!"
  [[ -n "$SQUAD_POLICY_SAMPLER_PID" && -n "$SQUAD_POLICY_SAMPLER_FD" ]] || return 1
  return 0
}

# Collects the sampler's marks into this shell's SQUAD_POLICY_HWM_AO/RP
# (max-merge). Returns 0 when the sampler answered, 1 (with the reason logged)
# when it was killed, stopped, never started, or did not answer with the
# nonce -- each of which means in-session observation was interfered with, a
# violation in its own right. Idempotent within one process: a second verify
# reuses the already-merged marks (and the first verdict).
squad_policy_highwater_collect() {
  if [[ "$SQUAD_POLICY_SAMPLER_COLLECTED" -eq 1 ]]; then
    [[ "$SQUAD_POLICY_SAMPLER_VERDICT" == ok ]] && return 0
    squad_policy_log "GOVERNANCE VIOLATION: ${SQUAD_POLICY_SAMPLER_VERDICT}"
    return 1
  fi
  SQUAD_POLICY_SAMPLER_COLLECTED=1
  local pid="$SQUAD_POLICY_SAMPLER_PID" fd="$SQUAD_POLICY_SAMPLER_FD" nonce="$SQUAD_POLICY_SAMPLER_NONCE"
  local timeout="${SQUAD_POLICY_SAMPLER_COLLECT_TIMEOUT_SECONDS:-20}"
  local reason="" line kind rel val got_end=0 n=0 remaining deadline
  if [[ -z "$pid" || -z "$fd" ]]; then
    reason="the in-session governance sampler was never started in this process, so in-session truncation could not be observed."
  elif ! kill -0 "$pid" 2>/dev/null; then
    reason="the in-session governance sampler (pid ${pid}) is no longer running -- it was killed during the session. In-session observation was interfered with."
  elif read -r -t 0 -u "$fd" 2>/dev/null; then
    # Nothing may be on the pipe before WE ask: data (or EOF) here means the
    # sampler was signalled by someone else, dumped and exited -- and a not-
    # yet-reaped zombie still passes kill -0 above.
    reason="the in-session governance sampler (pid ${pid}) answered before verification asked -- it was signalled during the session and stopped observing."
  elif ! kill -USR1 "$pid" 2>/dev/null; then
    reason="the in-session governance sampler (pid ${pid}) could not be signalled."
  else
    deadline=$((SECONDS + timeout))
    while :; do
      remaining=$((deadline - SECONDS))
      [[ "$remaining" -gt 0 ]] || break
      local read_rc=0
      IFS= read -r -t "$remaining" -u "$fd" line || read_rc=$?
      if [[ "$read_rc" -ne 0 ]]; then
        # >128 is a timeout OR a trapped signal interrupting the read (the
        # entrypoint defers shutdown TERM/INT during the checkpoint, re-review
        # N5): retry until the deadline instead of reporting a mute sampler.
        [[ "$read_rc" -gt 128 ]] && continue
        break
      fi
      n=$((n + 1))
      [[ "$n" -le 100000 ]] || break
      if [[ "$line" == "END ${nonce}" ]]; then
        got_end=1
        break
      fi
      read -r kind rel val <<<"$line"
      [[ "$val" =~ ^[0-9]+$ ]] || continue
      case "$kind" in
        hwm-ao)
          if [[ "$val" -gt "${SQUAD_POLICY_HWM_AO[$rel]:-0}" ]]; then
            SQUAD_POLICY_HWM_AO["$rel"]="$val"
          fi
          ;;
        hwm-rp)
          [[ "$val" == 1 ]] && SQUAD_POLICY_HWM_RP["$rel"]=1
          ;;
        *) : ;;
      esac
    done
    if [[ "$got_end" -ne 1 ]]; then
      reason="the in-session governance sampler (pid ${pid}) did not answer within ${timeout}s with its session nonce -- it was stopped, killed or impersonated during the session."
    fi
  fi
  if [[ -n "$fd" ]]; then
    # No redirection on this `exec`: `exec {fd}<&- 2>/dev/null` would also
    # silence this shell's stderr for the rest of the session.
    exec {fd}<&-
  fi
  SQUAD_POLICY_SAMPLER_FD=""
  if [[ -n "$reason" ]]; then
    SQUAD_POLICY_SAMPLER_VERDICT="$reason"
    squad_policy_log "GOVERNANCE VIOLATION: ${reason}"
    return 1
  fi
  SQUAD_POLICY_SAMPLER_VERDICT=ok
  return 0
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
# Issue #113 perf: this used to fork `sha256sum` (and `awk` to pull the hash
# back out of it, and sometimes `wc` for an append-only file's byte length)
# ONCE PER GOVERNANCE FILE. That is a rounding error on Linux CI, but this
# function runs TWICE per harden/verify cycle, and each external-process fork
# measured several tens of milliseconds on Windows/git-bash (MSYS emulates
# `fork()`; it does not have one) -- with the Issue #113 reported-mutable set
# (casting/*.json x3, identity/now.md) adding four more governance files, that
# per-file cost is what actually grew, not the one-time `node` resolution.
#
# The fix is NOT "skip hashing some files" (that would be exactly the
# coverage loss this file refuses to ship) -- it is forking `sha256sum` and
# `wc` ONCE EACH for the WHOLE governance set instead of once per file, AND
# ONE `find`+`sort` for every governance DIRECTORY TOGETHER instead of one
# find+sort per directory. Passing every directory target to a single `find`
# call still produces a fully deterministic file list -- `sort -z` orders the
# WHOLE combined NUL-terminated stream byte-for-byte, so "same directories,
# same files" always yields the same manifest regardless of how many roots
# were given to `find` in one call versus several -- and every external-
# process fork measured several tens of milliseconds on Windows/git-bash, so
# collapsing N finds into one is not a rounding error at this suite's scale
# (22 harden/verify cycles).
#
# SQUAD_POLICY_MANIFEST_RELS/_ABS cache the exact (rel, abs) file list this
# walk produced, in manifest order, so squad_policy_harden's unlock pass can
# reuse it instead of re-walking the same directories a second time -- see
# the comment at that loop.
#
# Security re-review N1/S1: the manifest is printed to STDOUT (the caller
# decides where it goes -- harden writes the operator tripwire copy, verify
# captures it straight into memory), and it carries a fifth kind:
#
#   symlink <path>                      a governance path, a component of one,
#                                       or an entry under a governance
#                                       directory, is a SYMBOLIC LINK
#
# GNU find (verified on findutils 4.8.0, Linux) does NOT descend into a
# symlink named as a starting point under its default -P, so a symlinked
# governance directory used to manifest as a bare `dir` line with ZERO file
# lines: `chmod -R a-w` still followed the link (prevention), but nothing
# beneath it was hashed (detection silently lost). The decision is to REFUSE
# rather than chase links: squad_policy_harden aborts (78) on any `symlink`
# line, and squad_policy_verify treats one appearing mid-session as a
# violation. Governance must be real files at real paths in the checkout.
SQUAD_POLICY_MANIFEST_RELS=()
SQUAD_POLICY_MANIFEST_ABS=()
squad_policy_write_manifest() {
  local repo_dir="$1"
  local path target comp acc

  squad_policy_load_governance_paths

  local -a rel_order=() abs_order=() dir_targets=() links=()
  local -A link_seen=()
  for path in "${SQUAD_POLICY_GOVERNANCE_PATHS[@]:-}"; do
    [[ -n "$path" ]] || continue
    target="${repo_dir}/${path}"
    # Every component, not just the leaf: `.squad` itself as a symlink moves
    # every governance path at once.
    acc=""
    local linked=0
    local -a comps=()
    IFS='/' read -r -a comps <<<"$path"
    for comp in "${comps[@]}"; do
      acc="${acc:+${acc}/}${comp}"
      if [[ -L "${repo_dir}/${acc}" ]]; then
        if [[ -z "${link_seen[$acc]:-}" ]]; then
          link_seen["$acc"]=1
          links+=("$acc")
        fi
        linked=1
        break
      fi
    done
    [[ "$linked" -eq 0 ]] || continue
    if [[ -d "$target" ]]; then
      printf 'dir %s\n' "$path"
      dir_targets+=("$target")
    elif [[ -f "$target" ]]; then
      rel_order+=("$path")
      abs_order+=("$target")
    else
      printf 'absent %s\n' "$path"
    fi
  done

  if [[ "${#dir_targets[@]}" -gt 0 ]]; then
    local file rel
    # -print0/sort -z keeps ordering stable regardless of locale or readdir
    # order, so an identical set of trees always produces an identical
    # manifest, the same guarantee the old per-directory find+sort gave.
    # `-type l` is listed so a symlink INSIDE a governance directory (which
    # `-type f` skips and GNU `chmod -R` does not follow) is reported, not
    # silently left out of both the hash and the lock.
    while IFS= read -r -d '' file; do
      rel="${file#"${repo_dir}/"}"
      if [[ -L "$file" ]]; then
        links+=("$rel")
        continue
      fi
      rel_order+=("$rel")
      abs_order+=("$file")
    done < <(find "${dir_targets[@]}" \( -type f -o -type l \) -print0 2>/dev/null | sort -z)
  fi

  SQUAD_POLICY_MANIFEST_RELS=("${rel_order[@]}")
  SQUAD_POLICY_MANIFEST_ABS=("${abs_order[@]}")

  squad_policy_write_manifest_file_lines rel_order abs_order || return 1
  for path in "${links[@]}"; do
    printf 'symlink %s\n' "$path"
  done
  return 0
}

# squad_policy_write_manifest_file_lines <rel-array-name> <abs-array-name>
# Prints one `file`/`append-only`/`reported` line per entry in the two arrays
# (same index order) to stdout. Hashing and length-checking are each ONE
# external-process fork for every file passed in, not one fork per file.
squad_policy_write_manifest_file_lines() {
  local -n _rel_ref="$1"
  local -n _abs_ref="$2"
  local n="${#_rel_ref[@]}"
  [[ "$n" -gt 0 ]] || return 0

  local -A sums=() lens=()
  local line sum rest abs_path

  # One `sha256sum` fork for every governance file, in one shot. coreutils
  # (and the Windows sha256sum shipped with Git for Windows) print one
  # "<hash> <mode><path>" line per argument, in argument order -- <mode> is
  # ` ` (text) or `*` (binary); sha256sum defaults to binary mode on
  # Windows/MSYS, so the `*` marker is always stripped before using the
  # filename as the lookup key below, not just handled defensively.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    sum="${line%% *}"
    rest="${line#* }"
    rest="${rest# }"
    rest="${rest#\*}"
    sums["$rest"]="$sum"
  done < <(sha256sum "${_abs_ref[@]}" 2>/dev/null)

  # Byte lengths are only needed for append-only paths (the prefix-hash check
  # in squad_policy_verify); everything else only needs the hash above. Build
  # that subset, then ONE `wc -c` fork for all of them -- `wc -c` with more
  # than one file prints a trailing "total" line, so that line (which has no
  # matching governance path) is simply never looked up below.
  local -a mutable_abs=()
  local i
  for ((i = 0; i < n; i++)); do
    squad_policy_is_mutable "${_rel_ref[$i]}" || continue
    mutable_abs+=("${_abs_ref[$i]}")
  done
  if [[ "${#mutable_abs[@]}" -gt 0 ]]; then
    local wc_len
    # Plain `read` (default IFS), not `${line%% *}`/`${line##* }`: `wc -c`
    # right-justifies its counts to the width of the WIDEST number it prints
    # (including the trailing "total"), so any shorter count is left-padded
    # with a space. `${line%% *}` removes the LONGEST matching suffix, and
    # when the line itself starts with that pad space, the whole line matches
    # " *" and the count comes out empty -- which made this block silently
    # drop a file's length, `squad_policy_write_manifest_file_lines` then hit
    # its `[[ -n "$len" ]] || return 1` guard, and the manifest was never
    # written. Word-splitting on whitespace (what the rest of this file's
    # manifest readers already use) does not care how many pad spaces precede
    # the first field.
    while read -r wc_len rest; do
      [[ -n "$wc_len" ]] || continue
      [[ "$rest" == total ]] && continue
      lens["$rest"]="$wc_len"
    done < <(wc -c "${mutable_abs[@]}" 2>/dev/null)
  fi

  local rel
  for ((i = 0; i < n; i++)); do
    rel="${_rel_ref[$i]}"
    abs_path="${_abs_ref[$i]}"
    sum="${sums[$abs_path]:-}"
    [[ -n "$sum" ]] || return 1
    if squad_policy_is_mutable "$rel"; then
      local len="${lens[$abs_path]:-}"
      [[ -n "$len" ]] || return 1
      printf 'append-only %s %s %s\n' "$rel" "$sum" "$len"
    elif squad_policy_is_reported_mutable "$rel"; then
      printf 'reported %s %s\n' "$rel" "$sum"
    else
      printf 'file %s %s\n' "$rel" "$sum"
    fi
  done

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
#
# Issue #113 perf: the pin ITSELF used to be applied by an inline `node -e`
# fork in this file. It is now applied by agent-policy.js's
# pinMemoryAuditConfig(), called as part of the single `harden-init` fork
# squad_policy_harden makes (pin + governance bundle together, one process).
# squad_policy_commit_memory_audit_config_pin below is the part that stays in
# bash: it shells out to `git`, not `node`, to commit the pin before
# `base-commit` is captured.
#
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
squad_policy_commit_memory_audit_config_pin() {
  local repo_dir="$1"
  if command -v git >/dev/null 2>&1 && git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
    # Issue #113 perf: this used to run `git diff --quiet` and, if THAT found
    # no difference (true for an untracked file -- `git diff` does not cover
    # untracked paths), a SECOND detection fork (`git ls-files
    # --error-unmatch`) before ever staging anything. `git add` is a safe
    # no-op when the file is already tracked and unchanged, so staging it
    # unconditionally and then asking ONE question -- "is anything staged for
    # this path?" (`git diff --cached --quiet`) -- replaces both detection
    # forks with the one check that actually decides whether a commit is
    # needed, for every case (new file, changed file, unchanged file) alike.
    git -C "$repo_dir" add -- .squad/memory/config.json 2>/dev/null || true
    if ! git -C "$repo_dir" diff --cached --quiet -- .squad/memory/config.json 2>/dev/null; then
      git -C "$repo_dir" -c user.name="${GIT_AUTHOR_NAME:-squad-policy}" \
          -c user.email="${GIT_AUTHOR_EMAIL:-squad-policy@local}" \
          commit -m "chore(governance): pin audit.jsonl rotation off for this session (#113)" \
          -- .squad/memory/config.json >/dev/null 2>&1 || true
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

  mkdir -p "${repo_dir}/.squad/memory" 2>/dev/null || true

  # Issue #113 perf: `harden-init` applies the audit-rotation pin AND returns
  # the governance bundle (paths/patterns) in the SAME `node` process -- the
  # ONE fork this function needs, instead of the four separate forks
  # (pin, governance-paths, mutable-governance-patterns,
  # reported-mutable-governance-patterns) it used to make.
  local bundle_output rc
  bundle_output="$(node "$SQUAD_POLICY_RESOLVER" harden-init "$repo_dir" 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    squad_policy_log "Policy resolution failed while hardening (exit ${rc}): ${bundle_output}"
    squad_policy_abort "Could not pin .squad/memory/config.json policy.auditMaxBytes to 0; refusing to run with audit-trail rotation enabled."
  fi
  squad_policy_parse_bundle <<<"$bundle_output"

  squad_policy_commit_memory_audit_config_pin "$repo_dir"

  state="$(squad_policy_state_dir "$repo_dir")" || \
    squad_policy_abort "Could not create a private policy state directory outside the checkout."
  SQUAD_POLICY_STATE_DIR="$state"
  # Security review of #112/#113 (F8): exported (not just set in this
  # process) specifically so worker/squad-agent -- a CHILD process `squad
  # watch`/`squad loop` spawns fresh for every iteration -- can find this same
  # private directory and check the .mcp.json baseline recorded below. Before
  # this, SQUAD_POLICY_STATE_DIR only lived in entrypoint.sh's own shell; a
  # grandchild process never saw it.
  export SQUAD_POLICY_STATE_DIR

  # Security re-review N1: the baseline is captured into THIS process's
  # memory (see the trust-boundary note in section 4a) and the file written
  # beside it is an operator-facing tripwire copy only. Written to the file
  # first, in this same shell, because squad_policy_write_manifest also fills
  # SQUAD_POLICY_MANIFEST_RELS/_ABS for the unlock pass below -- a `$(...)`
  # capture would lose them in the subshell. No agent is running yet, so
  # reading the file straight back cannot be raced.
  if ! squad_policy_write_manifest "$repo_dir" >"${state}/governance.sha256"; then
    squad_policy_abort "Could not record the governance integrity baseline."
  fi
  SQUAD_POLICY_BASELINE_MANIFEST="$(<"${state}/governance.sha256")"

  # S1: refuse, rather than half-protect, a governance path that is (or sits
  # under, or contains) a symbolic link. See squad_policy_write_manifest.
  local -a s1_links=()
  local s1_kind s1_rel s1_rest
  while read -r s1_kind s1_rel s1_rest; do
    [[ "$s1_kind" == symlink ]] && s1_links+=("$s1_rel")
  done <<<"$SQUAD_POLICY_BASELINE_MANIFEST"
  if [[ "${#s1_links[@]}" -gt 0 ]]; then
    squad_policy_abort "Governance path(s) are symbolic links: ${s1_links[*]}. A symlinked governance path cannot be both locked and integrity-checked (GNU find does not walk a symlinked directory, so nothing under it would be hashed). Replace the link with the real files."
  fi

  if ! squad_policy_record_mcp_config_baseline "$repo_dir" "$state"; then
    squad_policy_abort "Could not record the .mcp.json integrity baseline."
  fi

  # The commit the session started from. Catches a governance change that the
  # agent COMMITS -- the working tree would look clean, but this does not.
  # Held in memory (authority) and mirrored to disk (tripwire).
  SQUAD_POLICY_BASE_COMMIT="$( cd "$repo_dir" && git rev-parse HEAD 2>/dev/null )" || SQUAD_POLICY_BASE_COMMIT=""
  printf '%s\n' "$SQUAD_POLICY_BASE_COMMIT" >"${state}/base-commit" || \
    squad_policy_abort "Could not record the base commit."

  SQUAD_POLICY_HARDENED_PATHS=()
  squad_policy_load_governance_paths
  # Issue #113 perf: ONE `chmod -R a-w` for every governance path that exists,
  # instead of one fork per path -- the set this loop locks grew by four
  # entries (casting/*.json, identity/now.md) and a `chmod` per entry is pure
  # per-process overhead for a value that is identical whether it is applied
  # to one path or all of them at once.
  local -a existing_targets=()
  for path in "${SQUAD_POLICY_GOVERNANCE_PATHS[@]:-}"; do
    [[ -n "$path" ]] || continue
    target="${repo_dir}/${path}"
    [[ -e "$target" ]] || continue
    existing_targets+=("$target")
    SQUAD_POLICY_HARDENED_PATHS+=("$path")
  done
  if [[ "${#existing_targets[@]}" -gt 0 ]]; then
    if ! chmod -R a-w "${existing_targets[@]}" 2>/dev/null; then
      squad_policy_abort "Could not make one or more governance paths read-only: ${SQUAD_POLICY_HARDENED_PATHS[*]}"
    fi
  fi

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
  # Issue #113 perf: this used to re-walk every governance DIRECTORY with its
  # own `find`+`sort` to classify unlockable files, duplicating the walk
  # squad_policy_write_manifest just did two lines above to build the SAME
  # baseline. SQUAD_POLICY_MANIFEST_RELS/_ABS cache that walk's exact (rel,
  # abs) file list (directory-sourced AND plain-file governance paths alike),
  # so this pass reuses it directly -- one loop over an already-built array,
  # not a second filesystem traversal. Classification itself
  # (squad_policy_is_mutable / squad_policy_is_reported_mutable) stays
  # per-file bash regex matching, not a fork; only the redundant `find` is
  # gone. The `chmod u+w` itself is still ONE batched call for everything
  # this pass collects.
  local i rel
  local -a to_unlock=()
  for ((i = 0; i < ${#SQUAD_POLICY_MANIFEST_RELS[@]}; i++)); do
    rel="${SQUAD_POLICY_MANIFEST_RELS[$i]}"
    squad_policy_is_unlockable "$rel" || continue
    to_unlock+=("${SQUAD_POLICY_MANIFEST_ABS[$i]}")
    if squad_policy_is_mutable "$rel"; then
      SQUAD_POLICY_UNLOCKED_FILES+=("$rel")
    else
      SQUAD_POLICY_REPORTED_MUTABLE_FILES+=("$rel")
    fi
  done
  if [[ "${#to_unlock[@]}" -gt 0 ]]; then
    if ! chmod u+w "${to_unlock[@]}" 2>/dev/null; then
      squad_policy_abort "Could not restore write access to one or more append-only/reported-mutable files: ${SQUAD_POLICY_UNLOCKED_FILES[*]} ${SQUAD_POLICY_REPORTED_MUTABLE_FILES[*]}"
    fi
  fi

  # Security re-review N2: fingerprint every writable governance file AFTER
  # both chmod passes (chmod moves ctime). Held in memory only. See
  # squad_policy_fingerprints for why this turns "restored to the exact
  # baseline" from a sampling race into an end-state invariant.
  SQUAD_POLICY_FINGERPRINTS=()
  if [[ "${#to_unlock[@]}" -gt 0 ]]; then
    if ! command -v stat >/dev/null 2>&1; then
      squad_policy_abort "stat is not available, so writable governance files cannot be fingerprinted."
    fi
    local fp_line fp fp_path
    while IFS= read -r fp_line; do
      [[ -n "$fp_line" ]] || continue
      fp="${fp_line%%$'\t'*}"
      fp_path="${fp_line#*$'\t'}"
      SQUAD_POLICY_FINGERPRINTS["${fp_path#"${repo_dir}/"}"]="$fp"
    done < <(squad_policy_fingerprints "${to_unlock[@]}")
    for fp_path in "${SQUAD_POLICY_UNLOCKED_FILES[@]}" "${SQUAD_POLICY_REPORTED_MUTABLE_FILES[@]}"; do
      [[ -n "${SQUAD_POLICY_FINGERPRINTS[$fp_path]:-}" ]] || \
        squad_policy_abort "Could not fingerprint ${fp_path}."
    done
  fi

  # Last, so its first sample sees the fully hardened tree. Fail closed: a
  # session whose in-session observation could not be started does not run.
  if ! squad_policy_highwater_sampler_start "$repo_dir"; then
    squad_policy_abort "Could not start the in-session governance sampler."
  fi
  SQUAD_POLICY_BASELINE_TAKEN=1
  SQUAD_POLICY_HARDEN_SHELL_PID="$BASHPID"

  # Layer 0 (section 4c): hand the baseline to the root sealer, if this
  # session has one, and confirm it sealed exactly what is in memory.
  squad_policy_seal_commit

  if [[ "${#SQUAD_POLICY_HARDENED_PATHS[@]}" -gt 0 ]]; then
    squad_policy_log "Governance paths locked read-only: ${SQUAD_POLICY_HARDENED_PATHS[*]}"
  else
    squad_policy_log "Governance paths locked read-only: none present in this repository."
  fi
  if [[ "${#SQUAD_POLICY_UNLOCKED_FILES[@]}" -gt 0 ]]; then
    squad_policy_log "Append-only exception (work log, not policy; still integrity-checked): ${SQUAD_POLICY_UNLOCKED_FILES[*]}"
    # Security review of #112/#113 (F9): split by whether the containing
    # directory is ACTUALLY a locked governance path, rather than claiming it
    # for all of them. See squad_policy_parent_dir_is_locked's doc above.
    local -a ao_dir_locked=() ao_dir_open=() rel
    for rel in "${SQUAD_POLICY_UNLOCKED_FILES[@]}"; do
      if squad_policy_parent_dir_is_locked "$rel"; then
        ao_dir_locked+=("$rel")
      else
        ao_dir_open+=("$rel")
      fi
    done
    if [[ "${#ao_dir_locked[@]}" -gt 0 ]]; then
      squad_policy_log "  Their containing directories stay locked, so no file can be created or deleted beside them: ${ao_dir_locked[*]}"
    fi
    if [[ "${#ao_dir_open[@]}" -gt 0 ]]; then
      squad_policy_log "  Their containing directories do NOT stay locked (not a GOVERNANCE_PATHS directory entry) -- a file CAN be created or deleted beside them, though the files themselves stay append-only: ${ao_dir_open[*]}"
    fi
  fi
  if [[ "${#SQUAD_POLICY_REPORTED_MUTABLE_FILES[@]}" -gt 0 ]]; then
    squad_policy_log "Reported-mutable exception (Squad 0.13 runtime state; writable this session, changes listed in the governance report and the PR body): ${SQUAD_POLICY_REPORTED_MUTABLE_FILES[*]}"
    local -a rm_dir_locked=() rm_dir_open=()
    for rel in "${SQUAD_POLICY_REPORTED_MUTABLE_FILES[@]}"; do
      if squad_policy_parent_dir_is_locked "$rel"; then
        rm_dir_locked+=("$rel")
      else
        rm_dir_open+=("$rel")
      fi
    done
    if [[ "${#rm_dir_locked[@]}" -gt 0 ]]; then
      squad_policy_log "  Their containing directories stay locked, so no file can be created or deleted beside them: ${rm_dir_locked[*]}"
    fi
    if [[ "${#rm_dir_open[@]}" -gt 0 ]]; then
      squad_policy_log "  Their containing directories do NOT stay locked (not a GOVERNANCE_PATHS directory entry) -- a file CAN be created or deleted beside them, though changing the files themselves still only ever REPORTS, never blocks: ${rm_dir_open[*]}"
    fi
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
#   s. (S1) no governance path may be, or contain, a symbolic link.
#
# Security re-review N1/N2: every comparison is against what THIS process
# recorded in memory at harden time (section 4a). The files in the state
# directory are tripwires: missing or altered => GOVERNANCE STATE TAMPERED and
# an abort (78) after the detectors have logged what else changed. Nothing is
# written to the state directory here.
squad_policy_verify() {
  local repo_dir="$1"
  local state="$SQUAD_POLICY_STATE_DIR"
  local baseline current violated=0 appended=0 reported_count=0
  local -a tampered=()
  SQUAD_POLICY_REPORTED_CHANGES=()

  # Security re-review N1: the baseline is whatever THIS process recorded in
  # memory at harden time -- never a file. A process that never hardened has
  # nothing trustworthy to compare against, whatever happens to be on disk.
  if [[ "${SQUAD_POLICY_BASELINE_TAKEN:-0}" != 1 || -z "$SQUAD_POLICY_BASELINE_MANIFEST" ]]; then
    squad_policy_abort "The governance baseline was never recorded by this process; this session cannot be verified."
  fi
  baseline="$SQUAD_POLICY_BASELINE_MANIFEST"

  # --- tripwires --------------------------------------------------------------
  # The on-disk copies are not inputs; they are evidence. Missing or different
  # => the agent reached the policy state directory. Collected here, every
  # detector below still runs so the log shows what else was touched, and the
  # session is then aborted (78) at the end.
  local disk
  if [[ -z "$state" || ! -d "$state" ]]; then
    tampered+=("the policy state directory ${state:-<unset>} was removed")
  else
    if [[ ! -f "${state}/governance.sha256" ]]; then
      tampered+=("governance.sha256 was deleted")
    else
      disk="$(<"${state}/governance.sha256")"
      [[ "$disk" == "$baseline" ]] || tampered+=("governance.sha256 was rewritten")
    fi
    if [[ ! -f "${state}/mcp-config.sha256" ]]; then
      tampered+=("mcp-config.sha256 was deleted")
    else
      disk="$(<"${state}/mcp-config.sha256")"
      [[ "$disk" == "$SQUAD_POLICY_MCP_DIGEST" ]] || tampered+=("mcp-config.sha256 was rewritten")
    fi
    if [[ ! -f "${state}/base-commit" ]]; then
      tampered+=("base-commit was deleted")
    else
      disk="$(<"${state}/base-commit")"
      [[ "$disk" == "$SQUAD_POLICY_BASE_COMMIT" ]] || tampered+=("base-commit was rewritten")
    fi
  fi
  if [[ "${SQUAD_POLICY_MCP_CONFIG_SHA256:-}" != "$SQUAD_POLICY_MCP_DIGEST" ]]; then
    tampered+=("SQUAD_POLICY_MCP_CONFIG_SHA256 no longer matches the harden-time .mcp.json digest")
  fi
  # Layer 0: the root-sealed copies. Only uid 0 can change them, so a problem
  # here means the boundary itself failed -- still never "nothing to check".
  if [[ "$SQUAD_POLICY_SEAL_EXPECTED" == 1 ]]; then
    local seal_problem
    while IFS= read -r seal_problem; do
      [[ -n "$seal_problem" ]] && tampered+=("$seal_problem")
    done < <(squad_policy_seal_problems)
  fi
  if [[ "${#tampered[@]}" -gt 0 ]]; then
    violated=1
    squad_policy_log "GOVERNANCE STATE TAMPERED: the on-disk policy state no longer matches what this process recorded at harden time:"
    local t
    for t in "${tampered[@]}"; do
      squad_policy_log "  ${t}"
    done
    squad_policy_log "  Verification continues against the in-memory baseline; the session will be aborted (78) afterwards."
  fi

  # Security review F4/F6, re-review N2: collect the sampler's high-water marks
  # FIRST (it runs one last scan when asked), then compute the authoritative
  # end state below. A killed / stopped / silent sampler is a violation.
  if ! squad_policy_highwater_collect; then
    violated=1
  fi

  if ! current="$(squad_policy_write_manifest "$repo_dir")"; then
    squad_policy_abort "Could not recompute the governance manifest; this session cannot be verified."
  fi

  # Fingerprints of every writable governance file, now. One `stat` fork.
  local -A fp_now=()
  local -a fp_targets=()
  local r fp_line
  for r in "${!SQUAD_POLICY_FINGERPRINTS[@]}"; do
    [[ -f "${repo_dir}/${r}" ]] && fp_targets+=("${repo_dir}/${r}")
  done
  if [[ "${#fp_targets[@]}" -gt 0 ]]; then
    while IFS= read -r fp_line; do
      [[ -n "$fp_line" ]] || continue
      r="${fp_line#*$'\t'}"
      fp_now["${r#"${repo_dir}/"}"]="${fp_line%%$'\t'*}"
    done < <(squad_policy_fingerprints "${fp_targets[@]}")
  fi

  # --- (s) S1: a symlink appearing under governance mid-session ----------------
  local kind rel bsum blen csum clen now_line hwm rest
  while read -r kind rel rest; do
    [[ "$kind" == symlink ]] || continue
    violated=1
    squad_policy_log "GOVERNANCE VIOLATION: ${rel} is now a symbolic link. A governance path may not be replaced by, or contain, a link -- nothing behind it would be hashed."
  done <<<"$current"

  # --- (a) the immutable half -----------------------------------------------
  # Append-only and reported-mutable PATHS are held out of this comparison ON
  # PURPOSE and checked by (b)/(d) instead. This filters by PATH, not by the
  # line's literal kind word: a deleted append-only or reported-mutable file
  # manifests as an `absent` line on the side where it is missing, not an
  # `append-only`/`reported` line, and a kind-only filter would let that
  # `absent` line slip through as an apparent locked-path change -- which is
  # exactly backwards for the reported-mutable class, where a deletion is
  # supposed to be PERMITTED, not flagged here and then separately excused.
  # Both sides are compared from memory (process substitution), never via a
  # file in the agent-writable state directory.
  local diff_out line
  if ! diff_out="$(diff -u <(squad_policy_filter_locked_lines <<<"$baseline") <(squad_policy_filter_locked_lines <<<"$current") 2>&1)"; then
    violated=1
    squad_policy_log "GOVERNANCE VIOLATION: a protected path changed during this session."
    while IFS= read -r line; do
      case "$line" in
        ---*|+++*|@@*) continue ;;
        -*|+*) squad_policy_log "  ${line}" ;;
      esac
    done <<<"$diff_out"
  fi

  # --- (b) the append-only half ---------------------------------------------
  while read -r kind rel bsum blen; do
    [[ "$kind" == "append-only" ]] || continue
    now_line="$(awk -v P="$rel" '$1=="append-only" && $2==P {print $3" "$4; exit}' <<<"$current")"
    if [[ -z "$now_line" ]]; then
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: the append-only work log ${rel} was DELETED during this session."
      continue
    fi
    csum="${now_line%% *}"
    clen="${now_line##* }"
    # The sampler's high-water mark: never below `blen`, only ever revised
    # upward, so `hwm > blen` proves the file grew past baseline at some point.
    hwm="${SQUAD_POLICY_HWM_AO[$rel]:-$blen}"
    [[ -n "$hwm" ]] || hwm="$blen"
    [[ "$hwm" -ge "$blen" ]] || hwm="$blen"
    if [[ "$csum" == "$bsum" ]]; then
      if [[ "$hwm" -gt "$blen" ]]; then
        violated=1
        squad_policy_log "GOVERNANCE VIOLATION: ${rel} grew to ${hwm} bytes during this session and was then TRUNCATED BACK to its exact baseline length and hash (${blen} bytes / ${bsum}). A work log that can be restored to its starting point after growing is not an audit trail."
      elif [[ "${fp_now[$rel]:-}" != "${SQUAD_POLICY_FINGERPRINTS[$rel]:-}" ]]; then
        # Re-review N2 (repro A1): the same exploit completed inside one
        # sampler interval. Content is back to the exact baseline bytes, but
        # the inode/ctime fingerprint is not -- the file was written (or
        # replaced, or chmod'ed) and put back. Timing-independent.
        violated=1
        squad_policy_log "GOVERNANCE VIOLATION: ${rel} was MODIFIED AND RESTORED to its exact baseline bytes during this session (inode/ctime ${SQUAD_POLICY_FINGERPRINTS[$rel]:-?} -> ${fp_now[$rel]:-?}). A work log that is rewritten and put back is not an audit trail."
      fi
      continue
    fi
    if [[ "$clen" -lt "$blen" ]] || [[ "$(squad_policy_prefix_sha "${repo_dir}/${rel}" "$blen")" != "$bsum" ]]; then
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: ${rel} was REWRITTEN, not appended to. A work log an agent can edit is not an audit trail."
      squad_policy_log "  baseline: ${blen} bytes / ${bsum}"
      squad_policy_log "  now:      ${clen} bytes / ${csum}"
      continue
    fi
    if [[ "$clen" -lt "$hwm" ]]; then
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: ${rel} grew to ${hwm} bytes during this session and was TRUNCATED to ${clen} bytes before verification. Data appended during the session was removed; a work log may only grow."
      continue
    fi
    appended=$((appended + 1))
    squad_policy_log "Agent history appended (permitted): ${rel} +$((clen - blen)) bytes, prior ${blen} bytes unchanged."
  done <<<"$baseline"

  # A path that is append-only NOW but was not in the baseline is a new
  # governance file, not a permitted append.
  while read -r kind rel csum clen; do
    [[ "$kind" == "append-only" ]] || continue
    if ! awk -v P="$rel" '$1=="append-only" && $2==P {found=1} END {exit !found}' <<<"$baseline"; then
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: the work log ${rel} did not exist when this session started; a session may append to history, not create it."
    fi
  done <<<"$current"

  # --- (d) the reported-mutable half ----------------------------------------
  # Never sets `violated`; collects what changed for the log and the PR body.
  while read -r kind rel bsum; do
    [[ "$kind" == "reported" ]] || continue
    local now_sum everdiff
    now_sum="$(awk -v P="$rel" '$1=="reported" && $2==P {print $3; exit}' <<<"$current")"
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
      continue
    fi
    # Final content equals the baseline. Either the sampler saw it differ
    # (sticky flag), or the fingerprint shows it was written and put back --
    # the latter regardless of timing (re-review N2, repro A4).
    everdiff="${SQUAD_POLICY_HWM_RP[$rel]:-0}"
    if [[ "$everdiff" == "1" || "${fp_now[$rel]:-}" != "${SQUAD_POLICY_FINGERPRINTS[$rel]:-}" ]]; then
      reported_count=$((reported_count + 1))
      SQUAD_POLICY_REPORTED_CHANGES+=("${rel} (modified then reverted)")
      squad_policy_log "Reported-mutable change (permitted): ${rel} was modified during this session and reverted to its baseline value before verification."
    fi
  done <<<"$baseline"

  while read -r kind rel csum; do
    [[ "$kind" == "reported" ]] || continue
    if ! awk -v P="$rel" '$1=="reported" && $2==P {found=1} END {exit !found}' <<<"$baseline"; then
      reported_count=$((reported_count + 1))
      SQUAD_POLICY_REPORTED_CHANGES+=("${rel} (created)")
      squad_policy_log "Reported-mutable change (permitted): ${rel} was created during this session."
    fi
  done <<<"$current"

  # --- (c) committed changes -------------------------------------------------
  # A change that was committed rather than left in the working tree. The base
  # commit comes from memory (re-review N1), not from the state directory.
  local base_commit="$SQUAD_POLICY_BASE_COMMIT"
  if [[ -n "$base_commit" ]]; then
    local p committed committed_head violating=()
    squad_policy_load_governance_paths
    local -a paths=("${SQUAD_POLICY_GOVERNANCE_PATHS[@]:-}")
    committed="$(cd "$repo_dir" && git diff --name-only "$base_commit" -- "${paths[@]}" 2>/dev/null || true)"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      squad_policy_is_mutable "$p" && continue
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
    # form. Read straight from git through a pipe -- no intermediate file a
    # lingering process could swap.
    committed_head="$(cd "$repo_dir" && git diff --name-only "$base_commit" HEAD -- "${paths[@]}" 2>/dev/null || true)"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      squad_policy_is_mutable "$p" || continue
      now_line="$(awk -v P="$p" '$1=="append-only" && $2==P {print $3" "$4; exit}' <<<"$baseline")"
      if [[ -z "$now_line" ]]; then
        violated=1
        squad_policy_log "GOVERNANCE VIOLATION: ${p} was committed during this session but was not in the governance baseline."
        continue
      fi
      bsum="${now_line%% *}"
      blen="${now_line##* }"
      if ! ( cd "$repo_dir" && git cat-file -e "HEAD:${p}" ) 2>/dev/null; then
        violated=1
        squad_policy_log "GOVERNANCE VIOLATION: the append-only work log ${p} was DELETED in a commit made during this session."
        continue
      fi
      clen="$( (cd "$repo_dir" && git show "HEAD:${p}") 2>/dev/null | wc -c | tr -d '[:space:]')"
      csum="$( (cd "$repo_dir" && git show "HEAD:${p}") 2>/dev/null | head -c "$blen" | sha256sum | awk '{print $1}')"
      if [[ "${clen:-0}" -lt "$blen" ]] || [[ "$csum" != "$bsum" ]]; then
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
  local -a restore_targets=()
  for path in "${SQUAD_POLICY_HARDENED_PATHS[@]:-}"; do
    [[ -n "$path" ]] || continue
    restore_targets+=("${repo_dir}/${path}")
  done
  if [[ "${#restore_targets[@]}" -gt 0 ]]; then
    chmod -R u+w "${restore_targets[@]}" 2>/dev/null || true
  fi
  # That chmod moves every writable file's ctime; refresh the in-memory
  # fingerprints so a later verify in this same process compares against the
  # post-verify state rather than flagging its own restore.
  if [[ "${#fp_targets[@]}" -gt 0 ]]; then
    while IFS= read -r fp_line; do
      [[ -n "$fp_line" ]] || continue
      r="${fp_line#*$'\t'}"
      SQUAD_POLICY_FINGERPRINTS["${r#"${repo_dir}/"}"]="${fp_line%%$'\t'*}"
    done < <(squad_policy_fingerprints "${fp_targets[@]}")
  fi

  if [[ "${#tampered[@]}" -gt 0 ]]; then
    squad_policy_abort "Governance policy state was TAMPERED WITH during this session (${tampered[*]}). Missing or altered integrity state is a violation, never 'nothing to check'."
  fi

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
