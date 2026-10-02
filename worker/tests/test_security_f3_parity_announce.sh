#!/usr/bin/env bash
# F3 (security-review-112-113.md, HIGH, REJECTED #112).
#
# #112 removed `squad_policy_announce squad` from the `loop)` and
# `watch|triage)` branches of worker/entrypoint.sh. That call was the ONLY
# place the parity gap was ever stated: "NOT enforced on this path: ...".
# PARITY mode (the default) is a deliberate, settled trade-off -- it keeps
# today's effective deny set (the same subset `squad --copilot-flags` could
# ever carry) so a watch/loop agent can still push and open its own PRs, the
# way it does today -- and this suite does NOT test that choice, let alone
# change it. What #112 broke is the ANNOUNCEMENT of the choice: after it, an
# operator reading the session log sees an argv and a mode name and has no
# way to tell that `shell(git push)`, `shell(git config)`, `shell(gh auth)`,
# and other multi-word deny rules are silently not enforced on this path.
#
# The fix restores the announcement as a new function,
# squad_watch_policy_announce_undelivered(), defined in worker/entrypoint.sh
# itself (not in worker/lib/squad-policy.sh, which this reviewer does not
# own) and called from both the `loop)` and `watch|triage)` branches right
# after the existing "watch/loop agent-cmd argv:" log line.
#
# This suite proves two separate things, neither of them by inspection alone:
#
#   1. BEHAVIOUR. The real squad_watch_policy_announce_undelivered(), EXTRACTED
#      from worker/entrypoint.sh with the same awk-range technique
#      worker/tests/test_no_orphan_children.sh and
#      worker/tests/test_identity_drop_order.sh already use for functions in
#      this same file, is sourced and actually CALLED under three realistic
#      SQUAD_WATCH_AGENT_POLICY_MODE / SQUAD_POLICY_UNDELIVERABLE
#      combinations, and its real stdout is asserted -- not a reimplementation
#      of what it is supposed to print.
#   2. WIRING. The `loop)` and `watch|triage)` case blocks, extracted from the
#      SAME real file, each call squad_watch_policy_announce_undelivered
#      after the existing argv log line -- so a future edit that re-deletes
#      the call site (restoring exactly #112's regression) fails this suite
#      even though the function itself would still behave correctly in
#      isolation.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
ENTRYPOINT="${WORKER_DIR}/entrypoint.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== F3: watch/loop parity-gap announcement (security-review-112-113.md) =="

[[ -f "$ENTRYPOINT" ]] || { echo "FAIL: worker/entrypoint.sh is missing"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-f3-announce-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

# ===========================================================================
# 1. BEHAVIOUR: extract and actually run the real function.
# ===========================================================================
ANNOUNCE_FN="$(awk '/^squad_watch_policy_announce_undelivered\(\) \{/,/^\}/' "$ENTRYPOINT")"
assert_ne "" "$ANNOUNCE_FN" \
  "squad_watch_policy_announce_undelivered() is present in worker/entrypoint.sh"

LOG_FN="$(awk '/^log\(\) \{/,/^\}/' "$ENTRYPOINT")"
assert_ne "" "$LOG_FN" \
  "entrypoint.sh's log() helper (used by the announce function) is present"

# $1 = SQUAD_WATCH_AGENT_POLICY_MODE, remaining args = the elements
# SQUAD_POLICY_UNDELIVERABLE should hold (each may legitimately contain
# spaces -- that is the whole point of F3's multi-word deny patterns -- so
# these are passed as real argv elements, never flattened through a string
# that word-splitting could re-cut on its own).
run_announce() {
  local mode="$1"; shift
  local driver="${WORK}/driver-${mode}-$$-${RANDOM}.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf '%s\n' "$LOG_FN"
    printf '%s\n' "$ANNOUNCE_FN"
    printf 'SQUAD_WATCH_AGENT_POLICY_MODE=%q\n' "$mode"
    printf 'SQUAD_POLICY_UNDELIVERABLE=()\n'
    local item
    for item in "$@"; do
      printf 'SQUAD_POLICY_UNDELIVERABLE+=(%q)\n' "$item"
    done
    echo 'squad_watch_policy_announce_undelivered'
  } > "$driver"
  bash "$driver"
  rm -f "$driver"
}

# --- 1a. Parity mode, a real non-empty undeliverable set (the actual
#     multi-word deny rules F3's attack path names) -------------------------
out_parity="$(run_announce parity "shell(git push)" "shell(git config)" "shell(gh auth)")"
assert_contains "$out_parity" "NOT enforced on this path:" \
  "F3 parity mode: the parity-gap warning line is printed again (this is exactly the line #112 deleted)"
assert_contains "$out_parity" "shell(git push)" \
  "F3 parity mode: the actually-undeliverable rules are named, not just a generic warning"
assert_contains "$out_parity" "shell(git config)" \
  "F3 parity mode: shell(git config) (credential-helper RCE with the session token attached, per the review) is named as undeliverable"
assert_contains "$out_parity" "shell(gh auth)" \
  "F3 parity mode: shell(gh auth) (token disclosure, per the review) is named as undeliverable"
assert_contains "$out_parity" "parity mode intentionally keeps" \
  "F3 parity mode: the announcement explains WHY (the settled parity trade-off), not just THAT"
assert_contains "$out_parity" "SQUAD_WATCH_STRICT_POLICY=true" \
  "F3 parity mode: the announcement tells the operator how to enforce the missing rules instead"

# --- 1b. Parity mode, nothing undeliverable: the conditional genuinely
#     gates on content, not merely on mode -- this would be a decorative
#     always-on message otherwise. -------------------------------------------
out_parity_empty="$(run_announce parity)"
assert_not_contains "$out_parity_empty" "NOT enforced on this path:" \
  "F3 parity mode with an EMPTY undeliverable set prints no false warning -- the gate is on content, not merely 'mode == parity'"

# --- 1c. Strict mode: the text must differ -- no undeliverable warning, and
#     an explicit statement that strict mode leaves nothing undeliverable.
#     This is the pair that makes 1a non-vacuous: a function that printed the
#     SAME text regardless of mode would pass 1a alone. ----------------------
out_strict="$(run_announce strict "shell(git push)" "shell(git config)")"
assert_not_contains "$out_strict" "NOT enforced on this path:" \
  "F3 strict mode: no parity-gap warning is printed even though SQUAD_POLICY_UNDELIVERABLE is non-empty -- strict mode hands squad-agent the FULL argv, so the parity-only warning does not apply"
assert_contains "$out_strict" "strict" \
  "F3 strict mode: the announcement names the mode actually in effect"
assert_contains "$out_strict" "Nothing is undeliverable on this path" \
  "F3 strict mode: the announcement states the full deny set IS enforced here, the mirror image of the parity warning"

# ===========================================================================
# 2. WIRING: the real loop)/watch|triage) branches call the function, after
#    the existing argv log line -- so deleting just the call site (restoring
#    #112's actual regression) fails this suite even though part 1 above
#    would still pass in isolation.
# ===========================================================================
LOOP_BLOCK="$(awk '/^  loop\)$/,/^    ;;$/' "$ENTRYPOINT")"
WATCH_BLOCK="$(awk '/^  watch\|triage\)$/,/^    ;;$/' "$ENTRYPOINT")"

assert_ne "" "$LOOP_BLOCK" "the loop) case block is present in worker/entrypoint.sh"
assert_ne "" "$WATCH_BLOCK" "the watch|triage) case block is present in worker/entrypoint.sh"

assert_contains "$LOOP_BLOCK" "squad_watch_policy_announce_undelivered" \
  "F3 wiring: the loop) branch calls squad_watch_policy_announce_undelivered"
assert_contains "$WATCH_BLOCK" "squad_watch_policy_announce_undelivered" \
  "F3 wiring: the watch|triage) branch calls squad_watch_policy_announce_undelivered"

# Ordering: the argv log line must come before the announce call in BOTH
# blocks, matching the real log a reviewer would read top-to-bottom.
loop_argv_line="$(printf '%s\n' "$LOOP_BLOCK" | grep -n 'watch/loop agent-cmd argv:' | head -1 | cut -d: -f1)"
loop_announce_line="$(printf '%s\n' "$LOOP_BLOCK" | grep -n '^ *squad_watch_policy_announce_undelivered$' | head -1 | cut -d: -f1)"
assert_eq "1" "$([[ -n "$loop_argv_line" && -n "$loop_announce_line" && "$loop_announce_line" -gt "$loop_argv_line" ]] && echo 1 || echo 0)" \
  "F3 wiring (loop): the parity-gap announcement is called AFTER the argv is logged, so it reads as a continuation of the same policy narration"

watch_argv_line="$(printf '%s\n' "$WATCH_BLOCK" | grep -n 'watch/loop agent-cmd argv:' | head -1 | cut -d: -f1)"
watch_announce_line="$(printf '%s\n' "$WATCH_BLOCK" | grep -n '^ *squad_watch_policy_announce_undelivered$' | head -1 | cut -d: -f1)"
assert_eq "1" "$([[ -n "$watch_argv_line" && -n "$watch_announce_line" && "$watch_announce_line" -gt "$watch_argv_line" ]] && echo 1 || echo 0)" \
  "F3 wiring (watch): the parity-gap announcement is called AFTER the argv is logged, so it reads as a continuation of the same policy narration"

test_summary
