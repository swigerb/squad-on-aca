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
# file does not exist yet at harden time) into the SAME private state
# directory the governance baseline lives in -- outside the agent's file-tool
# reach for the identical reason squad_policy_state_dir gives above. It is
# written ONCE, at harden time, before the agent ever runs; worker/squad-agent
# only ever READS it.
squad_policy_record_mcp_config_baseline() {
  local repo_dir="$1" state="$2" mcp="${1}/.mcp.json" hash
  if [[ -f "$mcp" ]]; then
    hash="$(sha256sum "$mcp" 2>/dev/null | awk '{print $1}')" || return 1
    [[ -n "$hash" ]] || return 1
  else
    hash="absent"
  fi
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
# 4a. Security review of #112/#113 (F4, F6) -- in-session high-water tracking
# ---------------------------------------------------------------------------
# squad_policy_verify runs EXACTLY ONCE per session, after the single
# `squad watch`/`squad loop` child process exits (worker/entrypoint.sh calls
# each mode's squad_policy_checkpoint exactly once). A comparison only at that
# one instant cannot see a path that changed and then changed BACK before
# verify ran:
#
#   F4 (HIGH): an append-only file (.squad/memory/audit.jsonl,
#   .squad/agents/<name>/history.md) grown during the session and then
#   TRUNCATED BACK to exactly its baseline length+hash passes both existing
#   checks in squad_policy_verify's detector (b) -- `csum == bsum` short-
#   circuits before the prefix/length checks ever run. The commit message for
#   #112/#113 claimed "truncate refused"; only truncate-to-ZERO (or to any
#   OTHER length that does not reproduce the baseline hash) was actually
#   refused.
#
#   F6 (MEDIUM): a reported-mutable file (.squad/identity/now.md,
#   .squad/casting/*.json) modified and then reverted to its baseline hash
#   before verify is invisible to detector (d) -- `now_sum != bsum` is the
#   ONLY thing that makes a change visible there, and a revert makes that
#   comparison come back clean.
#
# Both gaps share one root cause (a single end-of-session snapshot cannot see
# session-internal history) and one fix: record a high-water mark for each
# path WHILE THE SESSION RUNS, not just at hardening and at verify.
# squad_policy_highwater_scan (below) is that one sampling pass; it is called:
#   - once at harden time (seeding maxlen=<baseline length> /
#     everdiffered=0), by squad_policy_harden;
#   - periodically, by a background poller squad_policy_highwater_sampler_start
#     starts (bash sleep loop -- inotify-tools is not in this image, and
#     worker/Dockerfile is owned by a different reviewer in this round, so no
#     new system package can be added to get an event-driven alternative);
#   - once, synchronously, at the START of squad_policy_verify, closing the
#     race between the sampler's last tick and the comparison.
#
# WHERE THE STATE LIVES, AND WHY THAT IS SAFE. The high-water files live under
# "${SQUAD_POLICY_STATE_DIR}/highwater/", the SAME private (0700), outside-the-
# checkout directory the governance.sha256 baseline already lives in (see
# squad_policy_state_dir above). That is the existing, already-reviewed trust
# boundary this file relies on everywhere else -- dropping `--allow-all-paths`
# confines the agent's structured file tools to the repository working
# directory, so SQUAD_POLICY_STATE_DIR is out of their reach the same way
# governance.sha256 already is. This fix adds no NEW trust assumption; it
# reuses the one this file already depends on. A monotonic high-water mark
# (max-of-stored-and-current, never decreased) cannot be "laundered" by an
# agent that CAN reach it, because there is no operation on this state that
# moves it backward -- only squad_policy_highwater_scan ever writes it, and it
# only ever writes max(old, new).
squad_policy_highwater_dir() {
  printf '%s/highwater' "$1"
}

# ONE consolidated state file, "<rel> maxlen" / "<rel> everdiffered" lines,
# rather than one file per governance path. Governance-relative paths here
# come ONLY from squad_policy_load_governance_paths / the manifest walk (our
# own enumeration, never attacker-controlled), so there is nothing unsafe
# about every path sharing one file; the reason to consolidate is purely
# performance -- on Windows/MSYS a fork is measured in tens of milliseconds,
# and a scan that wrote one file PER path needed one `mv` fork per path, on
# every scan, which is what made the first working version of this function
# cost roughly (governance-path-count x ~100ms) per call. A single
# read-everything / write-everything-back pass needs exactly one `mv` no
# matter how many paths this repository has.
squad_policy_highwater_state_file() {
  printf '%s/highwater.state' "$1"
}

# Loads the consolidated state file (if any) into two caller-provided
# associative arrays (by nameref), keyed by governance-relative path:
#   ao_out[rel]=<maxlen bytes>         rp_out[rel]=<0|1 everdiffered>
# Plain `read` against a direct redirection -- no fork.
squad_policy_highwater_load() {
  local state="$1"
  local -n _ao_out="$2" _rp_out="$3"
  local f kind rel val
  f="$(squad_policy_highwater_state_file "$state")"
  [[ -f "$f" ]] || return 0
  while read -r kind rel val; do
    case "$kind" in
      append-only) _ao_out["$rel"]="$val" ;;
      reported)    _rp_out["$rel"]="$val" ;;
      *) : ;;
    esac
  done <"$f"
  return 0
}

# One sampling pass over every append-only / reported-mutable path named in
# <baseline>. Write-then-rename (never a direct overwrite) so a concurrent
# reader -- squad_policy_verify's own synchronous call, racing the background
# sampler's last tick -- never observes a half-written state file.
#
# Batched exactly the way squad_policy_write_manifest_file_lines already
# batches hashing/length-checking: ONE `wc -c` fork for every append-only
# target that currently exists, ONE `sha256sum` fork for every
# reported-mutable target that currently exists, and ONE `mv` for the whole
# scan (see squad_policy_highwater_state_file's doc) -- not one fork of each
# per path. This runs on every sampler tick during a real session (where the
# interval is seconds, so per-tick cost barely matters) AND synchronously,
# twice, in every test scenario that hardens and verifies (seed at harden,
# final scan at verify) -- where it does matter, directly against this
# review round's 120s/suite budget.
squad_policy_highwater_scan() {
  local repo_dir="$1" baseline="$2" state="$3"
  [[ -f "$baseline" ]] || return 0
  [[ -d "$state" ]] || mkdir -p "$state" 2>/dev/null || return 1

  local -a ao_rel=() ao_bsum=() ao_blen=() ao_abs=()
  local -a rp_rel=() rp_bsum=() rp_abs=()
  local kind rel bsum blen
  # Reading the baseline directly (no `awk` pre-filter fork) and discarding
  # non-matching `kind` values in bash itself: one fewer process per scan,
  # same effect, since `dir`/`file`/`absent` lines just fall through `case`.
  while read -r kind rel bsum blen; do
    case "$kind" in
      append-only)
        ao_rel+=("$rel"); ao_bsum+=("$bsum"); ao_blen+=("$blen"); ao_abs+=("${repo_dir}/${rel}")
        ;;
      reported)
        rp_rel+=("$rel"); rp_bsum+=("$bsum"); rp_abs+=("${repo_dir}/${rel}")
        ;;
      *) : ;;
    esac
  done <"$baseline"

  local -A ao_hwm=() rp_diff=()
  squad_policy_highwater_load "$state" ao_hwm rp_diff

  local p i len maxlen csum everdiff

  if [[ "${#ao_rel[@]}" -gt 0 ]]; then
    local -A curlen=()
    local -a existing_ao=()
    for p in "${ao_abs[@]}"; do
      [[ -f "$p" ]] && existing_ao+=("$p")
    done
    if [[ "${#existing_ao[@]}" -gt 0 ]]; then
      local wc_len rest
      # Same right-justified-count caveat squad_policy_write_manifest_file_lines
      # documents: plain word-splitting `read`, not `${line%% *}`.
      while read -r wc_len rest; do
        [[ -n "$wc_len" ]] || continue
        [[ "$rest" == total ]] && continue
        curlen["$rest"]="$wc_len"
      done < <(wc -c "${existing_ao[@]}" 2>/dev/null)
    fi
    for ((i = 0; i < ${#ao_rel[@]}; i++)); do
      rel="${ao_rel[$i]}"; blen="${ao_blen[$i]}"
      len="${curlen[${ao_abs[$i]}]:-0}"
      maxlen="${ao_hwm[$rel]:-$blen}"
      [[ -n "$maxlen" ]] || maxlen="$blen"
      if [[ "$len" -gt "$maxlen" ]]; then
        maxlen="$len"
      fi
      ao_hwm["$rel"]="$maxlen"
    done
  fi

  if [[ "${#rp_rel[@]}" -gt 0 ]]; then
    local -A cursum=()
    local -a existing_rp=()
    for p in "${rp_abs[@]}"; do
      [[ -f "$p" ]] && existing_rp+=("$p")
    done
    if [[ "${#existing_rp[@]}" -gt 0 ]]; then
      local line sum rest
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        sum="${line%% *}"
        rest="${line#* }"
        rest="${rest# }"
        rest="${rest#\*}"
        cursum["$rest"]="$sum"
      done < <(sha256sum "${existing_rp[@]}" 2>/dev/null)
    fi
    for ((i = 0; i < ${#rp_rel[@]}; i++)); do
      rel="${rp_rel[$i]}"; bsum="${rp_bsum[$i]}"
      csum="${cursum[${rp_abs[$i]}]:-}"
      everdiff="${rp_diff[$rel]:-0}"
      if [[ "$everdiff" != "1" && "$csum" != "$bsum" ]]; then
        everdiff=1
      fi
      rp_diff["$rel"]="$everdiff"
    done
  fi

  local f tmp r
  f="$(squad_policy_highwater_state_file "$state")"
  tmp="${f}.tmp"
  : >"$tmp"
  {
    for r in "${!ao_hwm[@]}"; do
      printf 'append-only %s %s\n' "$r" "${ao_hwm[$r]}"
    done
    for r in "${!rp_diff[@]}"; do
      printf 'reported %s %s\n' "$r" "${rp_diff[$r]}"
    done
  } >>"$tmp"
  mv -f "$tmp" "$f"

  return 0
}

# Background poller: re-runs squad_policy_highwater_scan every
# SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS (default 5; tests override this to
# something sub-second for determinism and speed) until the private state
# directory it reads from is gone. That self-check -- not a signal, not a
# parent-death notification bash cannot portably get without extra tooling --
# is deliberate: several existing call sites harden a session and never verify
# it (the governance-guard suite has scenarios like this on purpose, to test
# the preventive lock in isolation), which would otherwise leak this poller
# for the life of the test process. Once ${state} is removed (the session's
# own cleanup, or a test's `rm -rf` of its scratch root), the poller notices
# on its NEXT tick and exits on its own -- a bounded leak of at most one
# interval, not a permanent one. `exec </dev/null >/dev/null 2>&1` detaches
# from whatever stdout/stderr this function was called with, so launching it
# from inside a `$(...)` command substitution (as every scenario in
# test_governance_guard.sh does) does not hang waiting for the backgrounded
# subshell to close an inherited pipe.
squad_policy_highwater_sampler_start() {
  local repo_dir="$1" baseline="$2" state="$3"
  local interval="${SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS:-5}"
  (
    exec </dev/null >/dev/null 2>&1
    while [[ -d "$state" ]]; do
      sleep "$interval"
      [[ -d "$state" ]] || break
      squad_policy_highwater_scan "$repo_dir" "$baseline" "$state"
    done
  ) &
  printf '%s' "$!" >"${state}/highwater.sampler.pid" 2>/dev/null || true
  disown "$!" 2>/dev/null || true
  return 0
}

# Stops the poller started above (if any) and waits for it, so
# squad_policy_verify's own final, synchronous squad_policy_highwater_scan
# call never races a sampler tick still in flight.
squad_policy_highwater_sampler_stop() {
  local state="$1" pidfile pid
  pidfile="${state}/highwater.sampler.pid"
  [[ -f "$pidfile" ]] || return 0
  read -r pid <"$pidfile" 2>/dev/null
  rm -f "$pidfile" 2>/dev/null
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
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
SQUAD_POLICY_MANIFEST_RELS=()
SQUAD_POLICY_MANIFEST_ABS=()
squad_policy_write_manifest() {
  local repo_dir="$1" out="$2"
  local path target

  : >"$out" || return 1

  squad_policy_load_governance_paths

  local -a rel_order=() abs_order=() dir_targets=()
  for path in "${SQUAD_POLICY_GOVERNANCE_PATHS[@]:-}"; do
    [[ -n "$path" ]] || continue
    target="${repo_dir}/${path}"
    if [[ -d "$target" ]]; then
      printf 'dir %s\n' "$path" >>"$out"
      dir_targets+=("$target")
    elif [[ -f "$target" ]]; then
      rel_order+=("$path")
      abs_order+=("$target")
    else
      printf 'absent %s\n' "$path" >>"$out"
    fi
  done

  if [[ "${#dir_targets[@]}" -gt 0 ]]; then
    local file
    # -print0/sort -z keeps ordering stable regardless of locale or readdir
    # order, so an identical set of trees always produces an identical
    # manifest, the same guarantee the old per-directory find+sort gave.
    while IFS= read -r -d '' file; do
      rel_order+=("${file#"${repo_dir}/"}")
      abs_order+=("$file")
    done < <(find "${dir_targets[@]}" -type f -print0 2>/dev/null | sort -z)
  fi

  SQUAD_POLICY_MANIFEST_RELS=("${rel_order[@]}")
  SQUAD_POLICY_MANIFEST_ABS=("${abs_order[@]}")

  squad_policy_write_manifest_file_lines "$out" rel_order abs_order
}

# squad_policy_write_manifest_file_lines <out> <rel-array-name> <abs-array-name>
# Appends one `file`/`append-only`/`reported` line per entry in the two arrays
# (same index order) to <out>. Hashing and length-checking are each ONE
# external-process fork for every file passed in, not one fork per file.
squad_policy_write_manifest_file_lines() {
  local out="$1"
  local -n _rel_ref="$2"
  local -n _abs_ref="$3"
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
  done >>"$out"

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

  if ! squad_policy_write_manifest "$repo_dir" "${state}/governance.sha256"; then
    squad_policy_abort "Could not record the governance integrity baseline."
  fi

  if ! squad_policy_record_mcp_config_baseline "$repo_dir" "$state"; then
    squad_policy_abort "Could not record the .mcp.json integrity baseline."
  fi

  # Security review of #112/#113 (F4, F6): seed the in-session high-water
  # state from the baseline we just wrote (maxlen=<baseline length> for every
  # append-only path, everdiffered=0 for every reported-mutable path), then
  # start the background sampler that keeps it current for the rest of the
  # session. Both run in the already-hardened baseline's own private state
  # directory; see squad_policy_highwater_scan's doc above for why that is
  # safe. Seeding failure aborts hardening the same way the two baselines
  # above do; the sampler itself is best-effort (its own doc above covers the
  # bounded-leak case of a session that hardens and never verifies).
  if ! squad_policy_highwater_scan "$repo_dir" "${state}/governance.sha256" "$state"; then
    squad_policy_abort "Could not seed the in-session high-water integrity state."
  fi
  squad_policy_highwater_sampler_start "$repo_dir" "${state}/governance.sha256" "$state"

  # The commit the session started from. Catches a governance change that the
  # agent COMMITS -- the working tree would look clean, but this does not.
  ( cd "$repo_dir" && git rev-parse HEAD 2>/dev/null ) >"${state}/base-commit" || true

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

  # Security review of #112/#113 (F4, F6): stop the background sampler FIRST
  # (so it cannot write a stale tick after this point), then run ONE final,
  # synchronous squad_policy_highwater_scan against the manifest we just
  # recomputed above. That ordering closes the race between "sampler's last
  # tick" and "the comparisons below" -- the state the (b)/(d) loops read is
  # never older than the `current` manifest they are read alongside.
  squad_policy_highwater_sampler_stop "$state"
  squad_policy_highwater_scan "$repo_dir" "$baseline" "$state" || true

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
  # Security review of #112/#113 (F4, F6): load the in-session high-water
  # state ONCE (not once per path) -- the state file itself is small, but on
  # Windows/MSYS loading it with a per-path fork rather than one bash `read`
  # pass is the difference this review round's perf budget cares about.
  local -A SQUAD_POLICY_HWM_AO=() SQUAD_POLICY_HWM_RP=()
  squad_policy_highwater_load "$state" SQUAD_POLICY_HWM_AO SQUAD_POLICY_HWM_RP

  local kind rel bsum blen csum clen now_line hwm
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
    # Security review of #112/#113 (F4): the in-session high-water mark for
    # this path, seeded at harden time and kept current by the background
    # sampler (squad_policy_highwater_scan). It is NEVER smaller than `blen`
    # (seeded from it) and is only ever revised upward, so `hwm > blen` is
    # itself proof that the file grew past baseline length at some point
    # during the session, independent of whatever length/hash it holds now.
    hwm="${SQUAD_POLICY_HWM_AO[$rel]:-$blen}"
    [[ -n "$hwm" ]] || hwm="$blen"
    if [[ "$csum" == "$bsum" ]]; then
      if [[ "$hwm" -gt "$blen" ]]; then
        # THE EXACT F4 EXPLOIT: grow during the session, then truncate back
        # to precisely the baseline length and hash. `csum == bsum` alone
        # used to short-circuit this whole loop with a silent `continue` --
        # looking identical to a session that never touched the file at all.
        violated=1
        squad_policy_log "GOVERNANCE VIOLATION: ${rel} grew to ${hwm} bytes during this session and was then TRUNCATED BACK to its exact baseline length and hash (${blen} bytes / ${bsum}). A work log that can be restored to its starting point after growing is not an audit trail."
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
      # Still a valid baseline-prefix and still longer than the baseline, but
      # SHORTER than what was observed mid-session: some of what was appended
      # during the session was removed again before verification.
      violated=1
      squad_policy_log "GOVERNANCE VIOLATION: ${rel} grew to ${hwm} bytes during this session and was TRUNCATED to ${clen} bytes before verification. Data appended during the session was removed; a work log may only grow."
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
    local now_sum everdiff
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
      continue
    fi
    # Security review of #112/#113 (F6): `now_sum == bsum` here means the
    # FINAL state matches the baseline -- exactly what a change-then-revert
    # looks like, same as what left this path invisible before. `everdiffered`
    # is a STICKY flag the background sampler (squad_policy_highwater_scan)
    # only ever sets to 1, never clears, the first time a mid-session sample
    # did not match the baseline hash -- so it survives the revert even
    # though this final comparison no longer can. Reported-mutable changes
    # are never violations (that is the whole point of the class), so this
    # still never sets `violated`; it only makes the change VISIBLE.
    everdiff="${SQUAD_POLICY_HWM_RP[$rel]:-0}"
    if [[ "$everdiff" == "1" ]]; then
      reported_count=$((reported_count + 1))
      SQUAD_POLICY_REPORTED_CHANGES+=("${rel} (modified then reverted)")
      squad_policy_log "Reported-mutable change (permitted): ${rel} was modified during this session and reverted to its baseline value before verification."
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
  # Issue #113 perf: ONE `chmod -R u+w` for every hardened path, the same
  # batching squad_policy_harden applies to the lock side of this operation.
  local path
  local -a restore_targets=()
  for path in "${SQUAD_POLICY_HARDENED_PATHS[@]:-}"; do
    [[ -n "$path" ]] || continue
    restore_targets+=("${repo_dir}/${path}")
  done
  if [[ "${#restore_targets[@]}" -gt 0 ]]; then
    chmod -R u+w "${restore_targets[@]}" 2>/dev/null || true
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
