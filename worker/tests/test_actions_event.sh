#!/usr/bin/env bash
# Behavioural tests for worker/lib/actions-event.js (issue #32 S2).
#
# The trigger surface is the part of this change that can cost real money by
# accident. Two failure modes matter more than anything else:
#
#   * a LOOP -- the App comments on an issue, that comment retriggers the
#     workflow, which starts another session, which comments again. Events
#     caused by GITHUB_TOKEN do not start new workflow runs, but an APP token
#     has no such protection, so the loop break has to be in this code;
#   * an OVER-TRIGGER -- any comment anywhere starting a billed session.
#
# So the suite is weighted towards REFUSALS, and every refusal asserts on a
# named reason rather than on prose, so rewording a message cannot silently
# turn a refusal into a dispatch.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
MODULE="${WORKER_DIR}/lib/actions-event.js"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== actions-event.js =="

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-actions-event.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# resolve <event-name> <payload-json> [extra args...]
resolve() {
  local event="$1" payload="$2"; shift 2
  printf '%s' "$payload" >"${WORK}/event.json"
  node "$MODULE" --event-name "$event" --event-path "${WORK}/event.json" \
    --trigger-label squad --command-prefix /squad --bot-login 'squad-on-aca-control-plane[bot]' "$@"
}
field() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);process.stdout.write(String(o[process.argv[1]]))})' "$1"; }

# ---------------------------------------------------------------------------
# Dispatching cases
# ---------------------------------------------------------------------------
labeled='{"action":"labeled","label":{"name":"squad"},"issue":{"number":7,"state":"open"},"sender":{"login":"swigerb"}}'
out="$(resolve issues "$labeled")"
assert_eq "true" "$(printf '%s' "$out" | field dispatch)" "applying the trigger label to an open issue dispatches"
assert_eq "label-applied" "$(printf '%s' "$out" | field reason)" "and says which trigger fired, by name"
assert_eq "7" "$(printf '%s' "$out" | field issueNumber)" "and carries the issue number the session will work"

comment='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"/squad fix the flaky test","user":{"login":"swigerb","type":"User"}}}'
out="$(resolve issue_comment "$comment")"
assert_eq "true" "$(printf '%s' "$out" | field dispatch)" "a comment carrying the command prefix dispatches"
assert_eq "command-comment" "$(printf '%s' "$out" | field reason)" "named as a command comment"
assert_eq "fix the flaky test" "$(printf '%s' "$out" | field prompt)" "the prompt is the text AFTER the command, so the session gets the instruction and not the command word"

# ---------------------------------------------------------------------------
# THE LOOP BREAK. This is the assertion that keeps a billed runaway from
# existing at all.
# ---------------------------------------------------------------------------
self='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"/squad go again","user":{"login":"squad-on-aca-control-plane[bot]","type":"Bot"}},"sender":{"login":"squad-on-aca-control-plane[bot]"}}'
out="$(resolve issue_comment "$self")"
assert_eq "false" "$(printf '%s' "$out" | field dispatch)" "a comment from THIS App carrying a valid command does NOT dispatch -- an App token retriggers workflows where GITHUB_TOKEN does not, so without this the session's own status comment would start another session, forever"
assert_eq "actor-is-this-app" "$(printf '%s' "$out" | field reason)" "and the refusal names the loop, so an operator is not left wondering why a legitimate-looking command did nothing"

self_label='{"action":"labeled","label":{"name":"squad"},"issue":{"number":7,"state":"open"},"sender":{"login":"squad-on-aca-control-plane[bot]"}}'
assert_eq "false" "$(resolve issues "$self_label" | field dispatch)" "the loop break covers LABELS too, not just comments -- a session that labels an issue must not trigger itself"

other_bot='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"/squad go","user":{"login":"dependabot[bot]","type":"Bot"}}}'
out="$(resolve issue_comment "$other_bot")"
assert_eq "false" "$(printf '%s' "$out" | field dispatch)" "a DIFFERENT bot issuing the command does not dispatch either -- not a loop, but not a human asking for work"
assert_eq "actor-is-a-bot" "$(printf '%s' "$out" | field reason)" "and it is refused for its own reason, distinct from the self-loop"

# ---------------------------------------------------------------------------
# Over-trigger refusals
# ---------------------------------------------------------------------------
quoted="$(printf '{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"> /squad fix it\\n\\nI would not do that.","user":{"login":"swigerb","type":"User"}}}')"
out="$(resolve issue_comment "$quoted")"
assert_eq "false" "$(printf '%s' "$out" | field dispatch)" "QUOTING someone else's command does not run it -- GitHub renders a reply as '> /squad ...', which is the ordinary way an unintended trigger happens"
assert_eq "comment-carries-no-command" "$(printf '%s' "$out" | field reason)" "the quoted command is treated as no command at all"

midline='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"maybe we should /squad this","user":{"login":"swigerb","type":"User"}}}'
assert_eq "false" "$(resolve issue_comment "$midline" | field dispatch)" "a command mentioned mid-sentence does not dispatch -- it must begin a line"

prefixy='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"/squadron reporting in","user":{"login":"swigerb","type":"User"}}}'
assert_eq "false" "$(resolve issue_comment "$prefixy" | field dispatch)" "a longer word that merely STARTS with the command does not dispatch"

bare='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"/squad","user":{"login":"swigerb","type":"User"}}}'
assert_eq "true" "$(resolve issue_comment "$bare" | field dispatch)" "the bare command with no arguments still dispatches"

wrong_label='{"action":"labeled","label":{"name":"bug"},"issue":{"number":7,"state":"open"},"sender":{"login":"swigerb"}}'
out="$(resolve issues "$wrong_label")"
assert_eq "false" "$(printf '%s' "$out" | field dispatch)" "labelling with anything else does not dispatch"
assert_eq "label-not-the-trigger-label" "$(printf '%s' "$out" | field reason)" "named so the workflow log says which of the many refusals applied"

closed='{"action":"labeled","label":{"name":"squad"},"issue":{"number":7,"state":"closed"},"sender":{"login":"swigerb"}}'
assert_eq "false" "$(resolve issues "$closed" | field dispatch)" "labelling a CLOSED issue does not dispatch -- the work is done and a session would burn a run reading it"

opened='{"action":"opened","issue":{"number":7,"state":"open"},"sender":{"login":"swigerb"}}'
assert_eq "false" "$(resolve issues "$opened" | field dispatch)" "merely opening an issue does not dispatch -- the label is the consent"

edited='{"action":"edited","issue":{"number":9,"state":"open"},"comment":{"body":"/squad go","user":{"login":"swigerb","type":"User"}}}'
assert_eq "false" "$(resolve issue_comment "$edited" | field dispatch)" "EDITING a comment to contain the command does not dispatch -- otherwise editing history replays work"

assert_eq "false" "$(resolve push '{"ref":"refs/heads/main"}' | field dispatch)" "an unrelated event type does not dispatch"

# ---------------------------------------------------------------------------
# "not for us" is not a crash
# ---------------------------------------------------------------------------
printf '%s' "$opened" >"${WORK}/e.json"
node "$MODULE" --event-name issues --event-path "${WORK}/e.json" >/dev/null 2>&1
assert_eq "0" "$?" "a decision NOT to dispatch exits 0 -- a workflow that treated 'this event is not for us' as a crash would show a red X on every unrelated comment in the repository"

node "$MODULE" --event-name issues --event-path "${WORK}/does-not-exist.json" >/dev/null 2>&1
bad_rc=$?
assert_ne "0" "$bad_rc" "an UNREADABLE payload is a real error and exits non-zero -- the opposite mistake, silently doing nothing when the trigger is broken, would look identical to a quiet repository"

# ---------------------------------------------------------------------------
# Session naming: two triggers on the same issue must not collide
# ---------------------------------------------------------------------------
a="$(GITHUB_RUN_ID=1111 resolve issues "$labeled" | field sessionName)"
b="$(GITHUB_RUN_ID=2222 resolve issues "$labeled" | field sessionName)"
assert_ne "$a" "$b" "two dispatches for the SAME issue produce different session names, so a second trigger cannot reuse the first execution's name"
assert_contains "$a" "7" "the session name carries the issue number, so an ACA execution can be traced back to its issue without a lookup"

weird='{"action":"labeled","label":{"name":"squad"},"issue":{"number":7,"state":"open"},"sender":{"login":"Some User/With Spaces"}}'
name="$(GITHUB_RUN_ID='Run/Id With Spaces!' resolve issues "$weird" | field sessionName)"
assert_eq "$name" "$(printf '%s' "$name" | tr -cd 'a-z0-9-')" "the session name contains only characters an ACA execution name accepts, even when the inputs do not"

# ---------------------------------------------------------------------------
# Lease-claim outcomes. THE DEFECT THIS SECTION EXISTS FOR:
#
# The workflow originally tested `.claimed` -- a field the claim response has
# never had. `jq '.claimed // false'` evaluated to "false" on every run, the
# start step was skipped by its own `if:`, and the workflow reported SUCCESS
# having dispatched nothing. It survived a live end-to-end test because every
# line it printed looked correct.
#
# The mapping lives in the module, not in a jq expression, because a jq
# expression inside a workflow is reachable by no test.
# ---------------------------------------------------------------------------
classify() { node "$MODULE" --claim-outcome "$1"; }

assert_eq "start" "$(classify created | field action)" "a NEW lease means start the session -- 'created' is what a successful first claim actually returns"
assert_eq "start" "$(classify repaired | field action)" "a REPAIRED lease means start too: a dispatcher that crashed between claim and dispatch must not strand the issue forever"
assert_eq "stand-down" "$(classify active | field action)" "'active' means another dispatcher holds it -- stand down, which is correct behaviour and not an error"
assert_eq "stand-down" "$(classify already-terminal | field action)" "'already-terminal' means the work finished -- stand down"
assert_eq "stand-down" "$(classify completed | field action)" "'completed' means the lease for this key is in a terminal SUCCESS state and was NOT adopted, so there is no lease to run under -- starting anyway would dispatch an unleased session and delete the double-dispatch protection"
assert_eq "lease-already-succeeded" "$(classify completed | field reason)" "and it says so by name, because 'the work is already done' and 'someone else is doing it' need different responses from an operator"
assert_eq "error" "$(classify refused | field action)" "'refused' means routing could not be resolved, which is a real failure and must not look like a polite decision not to run"
assert_eq "error" "$(classify claimed | field action)" "the field the workflow ORIGINALLY tested -- 'claimed' -- is not a real outcome, and is treated as an ERROR rather than as a silent stand-down"
assert_eq "error" "$(classify '' | field action)" "an EMPTY outcome is an error; empty is what a jq lookup of a nonexistent field yields, and that is precisely how the original defect stayed invisible"
assert_eq "error" "$(classify something-new-in-a-future-release | field action)" "an UNRECOGNISED outcome is an error, so a new lease state added later cannot silently become 'do nothing'"

node "$MODULE" --claim-outcome created >/dev/null 2>&1
assert_eq "0" "$?" "a startable outcome exits 0"
node "$MODULE" --claim-outcome claimed >/dev/null 2>&1
assert_ne "0" "$?" "an ERROR outcome exits non-zero, so the workflow step FAILS instead of skipping a start and reporting green"

# ---------------------------------------------------------------------------
# Requester attribution and the @mention form (sprint 3)
# ---------------------------------------------------------------------------
out="$(resolve issues "$labeled")"
assert_eq "swigerb" "$(printf '%s' "$out" | field requester)" "a label dispatch records WHO asked, so the resulting commits can credit them instead of appearing from nowhere"

out="$(resolve issue_comment "$comment")"
assert_eq "swigerb" "$(printf '%s' "$out" | field requester)" "a command dispatch records the commenter as the requester"
assert_eq "command" "$(printf '%s' "$out" | field trigger)" "and records WHICH form triggered it"

mention='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"@squad-on-aca-control-plane please fix the flaky test","user":{"login":"swigerb","type":"User"}}}'
out="$(resolve issue_comment "$mention")"
assert_eq "true" "$(printf '%s' "$out" | field dispatch)" "@mentioning the App dispatches -- mentioning a bot is what people try first, so supporting only a slash command loses those requests silently"
assert_eq "mention" "$(printf '%s' "$out" | field trigger)" "the mention form is recorded distinctly from the slash command"
assert_eq "please fix the flaky test" "$(printf '%s' "$out" | field prompt)" "the mention's prompt excludes the mention itself"

mention_bot='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"@squad-on-aca-control-plane[bot] go","user":{"login":"swigerb","type":"User"}}}'
assert_eq "true" "$(resolve issue_comment "$mention_bot" | field dispatch)" "the literal '[bot]' suffix GitHub renders is accepted too, since that is what a copy-paste of the rendered name produces"

mention_quoted="$(printf '{\"action\":\"created\",\"issue\":{\"number\":9,\"state\":\"open\"},\"comment\":{\"body\":\"> @squad-on-aca-control-plane go\",\"user\":{\"login\":\"swigerb\",\"type\":\"User\"}}}')"
assert_eq "false" "$(resolve issue_comment "$mention_quoted" | field dispatch)" "a QUOTED mention does not dispatch -- the mention form is subject to the same line-start rule as the command"

mention_mid='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"I think @squad-on-aca-control-plane could help here","user":{"login":"swigerb","type":"User"}}}'
assert_eq "false" "$(resolve issue_comment "$mention_mid" | field dispatch)" "mentioning the App mid-sentence does NOT dispatch -- talking ABOUT the bot is not asking it to do something, and this is the single most likely accidental trigger"

self_mention='{"action":"created","issue":{"number":9,"state":"open"},"comment":{"body":"@squad-on-aca-control-plane retry","user":{"login":"squad-on-aca-control-plane[bot]","type":"Bot"}},"sender":{"login":"squad-on-aca-control-plane[bot]"}}'
assert_eq "false" "$(resolve issue_comment "$self_mention" | field dispatch)" "the App mentioning ITSELF does not dispatch -- the loop break covers the new trigger form too"

printf '%s' "$mention" >"${WORK}/event.json"
no_bot="$(node "$MODULE" --event-name issue_comment --event-path "${WORK}/event.json" --trigger-label squad --command-prefix /squad)"
assert_eq "false" "$(printf '%s' "$no_bot" | field dispatch)" "with NO bot login configured the mention form is inert rather than matching some arbitrary '@' prefix -- there is no identity to mention"

test_summary
