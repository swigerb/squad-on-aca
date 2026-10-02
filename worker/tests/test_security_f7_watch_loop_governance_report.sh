#!/usr/bin/env bash
# F7 (security-review-112-113.md, MEDIUM, REJECTED #112).
#
# squad_policy_checkpoint (worker/entrypoint.sh) populates
# SQUAD_POLICY_REPORTED_CHANGES as a side effect of squad_policy_verify
# whenever this session legitimately rewrote a "reported-mutable" governance
# path (issue #113: .squad/casting/*.json, .squad/identity/now.md). Before
# this fix, the ONLY consumer of that array was
# squad_policy_reported_changes_report(), and the ONLY place that report was
# ever written to was a PR body, inside commit_and_push_if_needed. The
# `loop)` and `watch|triage)` branches call squad_policy_checkpoint but never
# commit_and_push_if_needed -- `squad watch`/`squad loop` drive their own git
# state and open their own PRs -- so on exactly the two modes #112 reworked, a
# reported-mutable change reached the container log and nothing durable.
#
# The fix is a new function, squad_watch_governance_report_if_any(), defined
# in worker/entrypoint.sh (not worker/lib/squad-policy.sh, which this
# reviewer does not own), that calls the existing, UNedited
# squad_policy_reported_changes_report() and -- if it produced anything --
# appends it to a durable file under SQUAD_POLICY_STATE_DIR, a private (0700)
# per-session directory outside the checkout that squad_policy_state_dir()
# already creates. It is wired into both the `loop)` and `watch|triage)`
# branches right after their existing squad_policy_checkpoint call.
#
# This suite proves, with the REAL functions from both files (no
# reimplementation, no mocked report text):
#   1. A real SQUAD_POLICY_REPORTED_CHANGES population, fed through the real
#      squad_policy_reported_changes_report() (sourced, unedited, from
#      worker/lib/squad-policy.sh) and the real
#      squad_watch_governance_report_if_any() (extracted from
#      worker/entrypoint.sh), lands in a real, readable
#      ${SQUAD_POLICY_STATE_DIR}/reported-changes.md file.
#   2. A SECOND checkpoint, simulating a long watch/loop session's next
#      polling round, APPENDS rather than overwrites -- so the audit trail
#      accumulates across a session instead of only keeping the last round.
#   3. When no reported-mutable change occurred (the common case), nothing is
#      written and no empty file is created.
#   4. When SQUAD_POLICY_STATE_DIR is unavailable, the function falls back to
#      logging the report inline rather than silently dropping it.
#   5. WIRING: the real loop)/watch|triage) branches call
#      squad_watch_governance_report_if_any after squad_policy_checkpoint, so
#      deleting the call site fails this suite even though parts 1-4 would
#      still pass in isolation.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
ENTRYPOINT="${WORKER_DIR}/entrypoint.sh"
SQUAD_POLICY_SH="${WORKER_DIR}/lib/squad-policy.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== F7: watch/loop durable governance report (security-review-112-113.md) =="

[[ -f "$ENTRYPOINT" ]] || { echo "FAIL: worker/entrypoint.sh is missing"; exit 1; }
[[ -f "$SQUAD_POLICY_SH" ]] || { echo "FAIL: worker/lib/squad-policy.sh is missing"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-f7-report-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

# ===========================================================================
# 1-4. BEHAVIOUR: extract the real function and call it for real, against the
#      real (unedited) squad_policy_reported_changes_report() sourced from
#      worker/lib/squad-policy.sh.
# ===========================================================================
REPORT_FN="$(awk '/^squad_watch_governance_report_if_any\(\) \{/,/^\}/' "$ENTRYPOINT")"
assert_ne "" "$REPORT_FN" \
  "squad_watch_governance_report_if_any() is present in worker/entrypoint.sh"

LOG_FN="$(awk '/^log\(\) \{/,/^\}/' "$ENTRYPOINT")"
assert_ne "" "$LOG_FN" \
  "entrypoint.sh's log() helper (used by the report function) is present"

run_report() {
  # $1 = SQUAD_POLICY_STATE_DIR to use ("" for "unset"), remaining args =
  # elements of SQUAD_POLICY_REPORTED_CHANGES.
  local state_dir="$1"; shift
  local driver="${WORK}/driver-$$-${RANDOM}.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    printf 'source %q\n' "$SQUAD_POLICY_SH"
    printf '%s\n' "$LOG_FN"
    printf '%s\n' "$REPORT_FN"
    if [[ -n "$state_dir" ]]; then
      printf 'SQUAD_POLICY_STATE_DIR=%q\n' "$state_dir"
    else
      printf 'unset SQUAD_POLICY_STATE_DIR\n'
      printf 'SQUAD_POLICY_STATE_DIR=""\n'
    fi
    printf 'SQUAD_POLICY_REPORTED_CHANGES=()\n'
    local item
    for item in "$@"; do
      printf 'SQUAD_POLICY_REPORTED_CHANGES+=(%q)\n' "$item"
    done
    echo 'squad_watch_governance_report_if_any'
  } > "$driver"
  bash "$driver"
  rm -f "$driver"
}

# --- 1 & 2. Real durable write, then a real append on a second checkpoint --
STATE_DIR="${WORK}/policy-state"
mkdir -p "$STATE_DIR"
REPORT_FILE="${STATE_DIR}/reported-changes.md"

out1="$(run_report "$STATE_DIR" ".squad/casting/engineer.json (modified)" ".squad/identity/now.md (modified)")"
assert_eq "1" "$([[ -f "$REPORT_FILE" ]] && echo 1 || echo 0)" \
  "F7: a real reported-mutable change is written to a real ${REPORT_FILE##*/} file under the (real, mkdir'd) policy state dir"

content_after_1="$(cat "$REPORT_FILE" 2>/dev/null || true)"
assert_contains "$content_after_1" ".squad/casting/engineer.json (modified)" \
  "F7: the durable file's content is the REAL report produced by squad_policy_reported_changes_report() (sourced, unedited, from worker/lib/squad-policy.sh), not a reimplementation"
assert_contains "$content_after_1" ".squad/identity/now.md (modified)" \
  "F7: the durable file names identity/now.md too -- the second half of issue #113's reported-mutable class"
assert_contains "$out1" "$REPORT_FILE" \
  "F7: the function logs the exact durable file path, so an operator reading the session log knows where to look"

out2="$(run_report "$STATE_DIR" ".squad/casting/architect.json (modified)")"
content_after_2="$(cat "$REPORT_FILE" 2>/dev/null || true)"
assert_contains "$content_after_2" ".squad/casting/engineer.json (modified)" \
  "F7: a SECOND checkpoint (simulating the next watch/loop polling round) does not erase the FIRST round's entry -- the audit trail accumulates"
assert_contains "$content_after_2" ".squad/casting/architect.json (modified)" \
  "F7: the second round's own change is also present"
first_header_count="$(grep -c '^## Checkpoint at ' "$REPORT_FILE")"
assert_eq "2" "$first_header_count" \
  "F7: the file carries two distinct checkpoint headers -- one per round, not one merged/overwritten block"

# --- 3. Nothing reported -> nothing written -------------------------------
EMPTY_STATE_DIR="${WORK}/policy-state-empty"
mkdir -p "$EMPTY_STATE_DIR"
run_report "$EMPTY_STATE_DIR" >/dev/null
assert_eq "0" "$([[ -e "${EMPTY_STATE_DIR}/reported-changes.md" ]] && echo 1 || echo 0)" \
  "F7: a round with NO reported-mutable change creates no file at all -- an empty report is not treated as content"

# --- 4. No state dir available -> inline log fallback, not silent drop ----
out_no_state="$(run_report "" ".squad/casting/reviewer.json (modified)")"
assert_contains "$out_no_state" "no private policy state directory" \
  "F7: with no usable SQUAD_POLICY_STATE_DIR, the function says so explicitly instead of silently dropping the report"
assert_contains "$out_no_state" ".squad/casting/reviewer.json (modified)" \
  "F7: the fallback path still logs the actual report content inline, so the audit trail is not lost even without a state dir"

# ===========================================================================
# 5. WIRING: the real loop)/watch|triage) branches call the function right
#    after squad_policy_checkpoint.
# ===========================================================================
LOOP_BLOCK="$(awk '/^  loop\)$/,/^    ;;$/' "$ENTRYPOINT")"
WATCH_BLOCK="$(awk '/^  watch\|triage\)$/,/^    ;;$/' "$ENTRYPOINT")"

assert_contains "$LOOP_BLOCK" "squad_watch_governance_report_if_any" \
  "F7 wiring: the loop) branch calls squad_watch_governance_report_if_any"
assert_contains "$WATCH_BLOCK" "squad_watch_governance_report_if_any" \
  "F7 wiring: the watch|triage) branch calls squad_watch_governance_report_if_any"

loop_checkpoint_line="$(printf '%s\n' "$LOOP_BLOCK" | grep -n '^ *squad_policy_checkpoint$' | head -1 | cut -d: -f1)"
loop_report_line="$(printf '%s\n' "$LOOP_BLOCK" | grep -n '^ *squad_watch_governance_report_if_any$' | head -1 | cut -d: -f1)"
assert_eq "1" "$([[ -n "$loop_checkpoint_line" && -n "$loop_report_line" && "$loop_report_line" -gt "$loop_checkpoint_line" ]] && echo 1 || echo 0)" \
  "F7 wiring (loop): the durable report call comes AFTER squad_policy_checkpoint, so SQUAD_POLICY_REPORTED_CHANGES is already populated when it runs"

watch_checkpoint_line="$(printf '%s\n' "$WATCH_BLOCK" | grep -n '^ *squad_policy_checkpoint$' | head -1 | cut -d: -f1)"
watch_report_line="$(printf '%s\n' "$WATCH_BLOCK" | grep -n '^ *squad_watch_governance_report_if_any$' | head -1 | cut -d: -f1)"
assert_eq "1" "$([[ -n "$watch_checkpoint_line" && -n "$watch_report_line" && "$watch_report_line" -gt "$watch_checkpoint_line" ]] && echo 1 || echo 0)" \
  "F7 wiring (watch): the durable report call comes AFTER squad_policy_checkpoint, so SQUAD_POLICY_REPORTED_CHANGES is already populated when it runs"

test_summary
