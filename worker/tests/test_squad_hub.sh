#!/usr/bin/env bash
# Tests for Squad Hub supervision — worker/lib/squad-hub.sh and the hub policy.
#
# WHAT THIS SUITE IS ACTUALLY GUARDING
# ------------------------------------
# The integration exists so an ACA session can ASK a human instead of having
# destructive operations made unavailable outright. That is only acceptable if
# it is a TIGHTENING, and it is only a tightening while three things hold:
#
#   1. the deny list survives transport WHOLE. Its patterns contain spaces
#      -- `shell(git config)` -- and any channel that splits on whitespace
#      silently turns a security control into a torn string;
#   2. `--allow-all-tools` is DROPPED on the hub path. Left in, the agent
#      auto-approves everything, no card is ever raised, and the operator pays
#      for supervision they are not getting;
#   3. a session configured for supervision NEVER quietly runs unsupervised.
#      Falling back to blanket tool approval because a hub was unreachable
#      would be the exact silent downgrade this repository refuses elsewhere.
#
# The assertions are about the RESOLVED DECISION and the OBSERVED BEHAVIOUR --
# argv tokens, exit codes, refusals -- not about prose in the files. A test that
# greps for the word "deny" passes just as happily when the rule is shipped as
# when it is dropped.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
RESOLVER="${WORKER_DIR}/lib/agent-policy.js"
HUB_LIB="${WORKER_DIR}/lib/squad-hub.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== squad-hub supervision =="

policy() {
  local mode="$1" source="$2"
  shift 2
  env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE \
    SQUAD_MODE="$mode" \
    SQUAD_DISPATCH_SOURCE="$source" \
    node "$RESOLVER" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# 0. Off by default — the property everything else is allowed to assume
# ---------------------------------------------------------------------------
echo "-- optional by default --"

# The single most important assertion in this file. Supervision is a CHOICE.
# With neither variable set, squad_hub_enabled must say no, the entrypoint must
# take the path it always took, and a worker that has never heard of a hub must
# behave exactly as it did before this integration existed.
#
# Asserted first, and by BEHAVIOUR rather than by reading the entrypoint,
# because everything below it -- every refusal, every abort -- is only
# acceptable while this holds. A refusal that fires when no hub was asked for
# is not a safety property, it is an outage.
hub_enabled_rc() {
  env -u SQUAD_HUB_URL -u SQUAD_HUB_TOKEN "$@" \
    bash -c 'source "'"$HUB_LIB"'"; if squad_hub_enabled; then echo enabled; else echo disabled; fi' 2>&1
}

assert_eq "disabled" "$(hub_enabled_rc)" \
  "with NO hub configured, supervision is off -- the integration is opt-in"

assert_eq "enabled" "$(hub_enabled_rc SQUAD_HUB_URL=https://h.example SQUAD_HUB_TOKEN=sqhd1.x)" \
  "with both halves configured, supervision is on"

# Half a configuration is a mistake, not a preference. Either alone would
# otherwise deploy a job that cannot attach and cannot say why.
assert_contains "$(hub_enabled_rc SQUAD_HUB_URL=https://h.example)" "cannot attach" \
  "a URL with no token refuses rather than running half-configured"
assert_contains "$(hub_enabled_rc SQUAD_HUB_TOKEN=sqhd1.x)" "no hub to attach to" \
  "a token with no URL refuses rather than running half-configured"

# ---------------------------------------------------------------------------
# 1. The hub policy is the same policy, minus exactly one flag
# ---------------------------------------------------------------------------
echo "-- the hub argv --"

HUB_JSON="$(policy prompt ralph hub-argv-json)"

assert_ne "" "$HUB_JSON" "the resolver emits a hub argv at all"

# THE TIGHTENING. Without this the agent auto-approves everything, no approval
# card is ever raised, and attaching a human buys nothing.
case "$HUB_JSON" in
  *'"--allow-all-tools"'*)
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "FAIL: the hub argv still contains --allow-all-tools, so no approval would ever be raised" ;;
  *)
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "ok - --allow-all-tools is dropped on the hub path" ;;
esac

# THE HARD FLOOR. Every deny pattern the reviewed policy resolved must still be
# there. Measured against Copilot CLI 1.0.78 over ACP, a denied tool raises NO
# permission request -- it is refused outright -- so these patterns are what
# keeps a human at the hub from being ABLE to approve something forbidden.
assert_contains "$HUB_JSON" '"--deny-tool"'          "the hub argv still carries deny rules"
assert_contains "$HUB_JSON" '"shell(sudo)"'          "shell(sudo) survives to the hub path"
assert_contains "$HUB_JSON" '"shell(az)"'            "shell(az) survives to the hub path"

# The multi-word patterns are the whole reason this channel is JSON. A
# space-separated variable tears `shell(git config)` into `shell(git` and
# `config)`; Copilot then refuses to start, so the rule fails closed -- and the
# session never runs at all.
assert_contains "$HUB_JSON" '"shell(git config)"'      "a multi-word deny pattern survives as ONE argument"
assert_contains "$HUB_JSON" '"shell(gh auth)"'         "shell(gh auth) survives whole"
assert_contains "$HUB_JSON" '"shell(gh repo delete)"'  "a three-word deny pattern survives whole"

# The ANNOUNCEMENT must match the argv, or the log is evidence of a session
# that did not happen. It printed the full flag list -- --allow-all-tools
# included -- on the line directly above "MINUS --allow-all-tools", so an
# operator reading the log saw a MORE permissive session than the one that ran.
# Wrong in the safe direction is still wrong: there is no way to tell from the
# log which of the two contradicting lines to believe.
ANNOUNCE="$(env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE \
  SQUAD_MODE=prompt SQUAD_DISPATCH_SOURCE=ralph \
  bash -c 'source "'"${WORKER_DIR}/lib/squad-policy.sh"'"; squad_policy_resolve >/dev/null 2>&1; squad_policy_announce hub' 2>&1)"
FLAGS_LINE="$(printf '%s\n' "$ANNOUNCE" | grep 'Copilot flags (via Squad Hub')"
assert_not_contains "$FLAGS_LINE" "--allow-all-tools" \
  "the announced hub flags do NOT list --allow-all-tools, because the session will not have it"
assert_contains "$FLAGS_LINE" "shell(git config)" \
  "the announcement still shows the deny patterns that ARE applied"

# It has to be parseable as an array of strings, because that is precisely what
# the hub's channel demands; anything else makes the hub refuse to start.
PARSE_CHECK="$(printf '%s' "$HUB_JSON" | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    try {
      const a = JSON.parse(s);
      if (!Array.isArray(a) || a.some(x => typeof x !== "string")) { console.log("not-an-array-of-strings"); return; }
      console.log("ok:" + a.length);
    } catch (e) { console.log("unparseable"); }
  });
')"
assert_contains "$PARSE_CHECK" "ok:" "the hub argv parses as a JSON array of strings"

# The agent selection has to survive too, or a hub session silently stops being
# a Squad session.
assert_contains "$HUB_JSON" '"--agent"' "the hub argv still selects an agent"
assert_contains "$HUB_JSON" '"squad"'   "the hub argv still selects the squad agent"

# An unattended run must keep its ask_user guard. Squad Hub answers TOOL
# approvals, not `ask_user` questions, so an ask_user call would still hang.
assert_contains "$(policy ralph ralph hub-argv-json)" '"--no-ask-user"' \
  "an autonomous hub session still refuses ask_user, which the hub cannot answer"

# ---------------------------------------------------------------------------
# 2. When supervision is on, and when it is off
# ---------------------------------------------------------------------------
echo "-- enabling --"

# `squad_hub_enabled` ABORTS on a half-configuration, so it is exercised in a
# subshell and judged by exit status. The status is read AFTER the subshell
# returns, not printed from inside it: `exit 78` in there never reaches a
# printf on the next line, and the assertion would compare against an empty
# string forever.
hub_enabled_status() {
  local url="$1" token="$2"
  (
    source "$HUB_LIB"
    SQUAD_HUB_URL="$url" SQUAD_HUB_TOKEN="$token" squad_hub_enabled
  ) >/dev/null 2>&1
  printf '%s' "$?"
}

assert_eq "1" "$(hub_enabled_status '' '')" \
  "with neither set, supervision is simply off (this is the default path)"
assert_eq "0" "$(hub_enabled_status 'https://hub.example' 'sqhd1.abc.def')" \
  "with both set, supervision is on"

# A half-configuration is a MISTAKE, not an opt-out. Treating it as "off" would
# run unsupervised for an operator who was trying to configure supervision.
assert_eq "78" "$(hub_enabled_status 'https://hub.example' '')" \
  "a URL with no token refuses, rather than silently running unsupervised"
assert_eq "78" "$(hub_enabled_status '' 'sqhd1.abc.def')" \
  "a token with no URL refuses, rather than silently running unsupervised"

# ---------------------------------------------------------------------------
# 3. The credential must be a DEVICE token
# ---------------------------------------------------------------------------
echo "-- credential preflight --"

preflight_status() {
  (
    source "$HUB_LIB"
    # `command -v squad-hub` is the second half of the preflight; stub it so
    # this case is about the TOKEN, on a machine that may not have the CLI.
    command() { if [[ "${2:-}" == "squad-hub" ]]; then return 0; fi; builtin command "$@"; }
    SQUAD_HUB_TOKEN="$1" squad_hub_preflight
  ) >/dev/null 2>&1
  printf '%s' "$?"
}

assert_eq "0"  "$(preflight_status 'sqhd1.eyJhIjoxfQ.sig')" "a device token is accepted"

# The escalation this check exists to stop. A personal token shipped to a
# container hands that job everything its owner can do; a device token can be a
# device and nothing else.
#
# The PAT-shaped value is BUILT rather than written out: the repository's own
# secret scan (scripts/validate.ps1) rightly refuses a literal that looks like a
# credential, and a test fixture is not worth an exception to that rule.
fake_pat="ghp_$(printf 'a%.0s' $(seq 1 36))"
assert_eq "78" "$(preflight_status "$fake_pat")" \
  "a GitHub PAT is REFUSED where a device token belongs"
assert_eq "78" "$(preflight_status 'eyJ0aWQiOiJsb2NhbCJ9.sig')" \
  "a hub user token is refused too -- it is not a device credential"
assert_eq "78" "$(preflight_status 'sqhd2.abc.def')" \
  "a token with a near-miss prefix is refused rather than hopefully accepted"

# ---------------------------------------------------------------------------
# 4. The refusals never degrade into a weaker run
# ---------------------------------------------------------------------------
echo "-- refusing rather than downgrading --"

# The resolver is the source of the hub argv. If it cannot answer, the session
# must stop -- not proceed with whatever the direct path would have used.
(
  source "$HUB_LIB"
  SQUAD_POLICY_RESOLVER="/nonexistent/agent-policy.js" squad_hub_policy_json
) >/dev/null 2>&1
missing_resolver_status="$?"
assert_eq "78" "$missing_resolver_status" \
  "an unavailable policy resolver refuses the session rather than running without a policy"

# The guard inside squad_hub_policy_json: if a future edit ever let
# --allow-all-tools through to the hub path, the session must stop rather than
# quietly buy supervision that raises no cards.
STUB_DIR="$(mktemp -d)"
printf '#!/usr/bin/env node\nprocess.stdout.write(JSON.stringify(["--allow-all-tools","--agent","squad"]) + "\\n");\n' > "${STUB_DIR}/leaky.js"
(
  source "$HUB_LIB"
  SQUAD_POLICY_RESOLVER="${STUB_DIR}/leaky.js" squad_hub_policy_json
) >/dev/null 2>&1
allow_all_leak_status="$?"
rm -rf "$STUB_DIR"
assert_eq "78" "$allow_all_leak_status" \
  "a hub argv that still contains --allow-all-tools is refused, not run"

# ---------------------------------------------------------------------------
# 5. The entrypoint wiring
# ---------------------------------------------------------------------------
echo "-- entrypoint wiring --"

ENTRY="${WORKER_DIR}/entrypoint.sh"

# A hub configured with the library missing is the same class of failure as a
# missing policy library: refuse, never fall back.
assert_contains "$(cat "$ENTRY")" 'Refusing to run unsupervised with blanket tool approval instead.' \
  "a missing supervision library with a hub configured refuses the session"

# Both agent-running one-shot modes have to branch, or one of them keeps
# running unsupervised while the operator believes otherwise.
PROMPT_BLOCK="$(sed -n '/^  prompt)/,/^    ;;/p' "$ENTRY")"
assert_contains "$PROMPT_BLOCK" "squad_hub_should_supervise" "prompt mode branches on supervision"
assert_contains "$PROMPT_BLOCK" "squad_hub_run"              "prompt mode runs the supervised path"
assert_contains "$PROMPT_BLOCK" "copilot -p"                 "prompt mode keeps its unsupervised path unchanged"
assert_contains "$PROMPT_BLOCK" "commit_and_push_if_needed"  "prompt mode still pushes and checkpoints afterwards"

NEWPROJ_BLOCK="$(sed -n '/^  new-project)/,/^    ;;/p' "$ENTRY")"
assert_contains "$NEWPROJ_BLOCK" "squad_hub_should_supervise" "new-project mode branches on supervision"
assert_contains "$NEWPROJ_BLOCK" "squad_hub_run"              "new-project mode runs the supervised path"
assert_contains "$NEWPROJ_BLOCK" "commit_and_push_if_needed"  "new-project mode still pushes and checkpoints afterwards"

# The library and the CLI have to be IN the image, or every supervised session
# refuses at run time on a machine nobody can reach.
DOCKERFILE="$(cat "${WORKER_DIR}/Dockerfile")"
assert_contains "$DOCKERFILE" "worker/lib/squad-hub.sh" "the supervision library is copied into the image"
assert_contains "$DOCKERFILE" "squad-hub@"              "squad-hub is installed, at a pinned version"

# ---------------------------------------------------------------------------
# THE INTEGRATION IS OPTIONAL, AND MUST STAY OPTIONAL
# ---------------------------------------------------------------------------
# A worker that never attaches to a hub is the normal case. Convenience is
# allowed to make supervision easy to switch on; it is not allowed to make it
# impossible to leave out. Two distinct properties, both asserted:
#
#   1. BUILD-time: the image must build with no squad-hub in it at all, so an
#      npm outage, an unpublished version, or a policy against the dependency
#      cannot break a worker for people who never use the hub.
#   2. RUN-time: with no hub configured, nothing about a session changes.
#
# Property 2 is covered by the supervision-gate assertions elsewhere in this
# file. These cover property 1, which the verb assertion very nearly destroyed:
# an unconditional `|| exit 1` made squad-hub a hard build dependency.
assert_contains "$DOCKERFILE" 'SQUAD_HUB_SPEC" = "none"' \
  "the image can be built with NO squad-hub at all (SQUAD_HUB_SPEC=none)"

# The install must not sit in the unconditional `npm install -g` line, or
# `none` would install a package literally named "none" and the opt-out would
# be a confusing failure instead of an opt-out.
NPM_LINE="$(grep 'npm install -g @github/copilot' "${WORKER_DIR}/Dockerfile")"
assert_not_contains "$NPM_LINE" "SQUAD_HUB_SPEC" \
  "squad-hub is installed conditionally, not welded into the unconditional install line"

# The default still installs it: opting out should be a choice, not the price
# of admission for everyone.
assert_contains "$DOCKERFILE" "ARG SQUAD_HUB_SPEC=squad-hub@" \
  "the squad-hub install defaults to a pinned npm version, not a git ref"
assert_not_contains "$DOCKERFILE" "ARG SQUAD_HUB_SPEC=github:" \
  "the DEFAULT install is never a git ref -- that is for an explicit override only"

# A pinned version that lacks `oneshot` builds, deploys, and then fails at the
# agent with "Supervised session failed (exit 2)" -- the CLI prints its usage
# and exits 2, which points at nothing. squad-hub@0.2.0 did exactly that.
# The image must prove the verb exists at BUILD time.
assert_contains "$DOCKERFILE" "squad-hub oneshot" \
  "the build asserts the installed squad-hub actually has the 'oneshot' verb"

# ...but that assertion must live INSIDE the install branch. Outside it, an
# image built with SQUAD_HUB_SPEC=none would fail on a missing command -- the
# opt-out would not opt out of anything.
#
# EVERY verb check is measured, not "the" one. This originally took the first
# match and compared it, which silently stopped measuring anything the moment a
# second verb assertion was added: `cut -d: -f1` then yields two lines, and the
# comparison errors rather than answering. A guard that cannot fail when the
# property breaks is worse than no guard.
BRANCH_LINE="$(grep -n 'SQUAD_HUB_SPEC" = "none"' "${WORKER_DIR}/Dockerfile" | cut -d: -f1 | head -1)"
VERB_CHECK_LINES="$(grep -n "squad-hub --help" "${WORKER_DIR}/Dockerfile" | cut -d: -f1)"
verb_checks_ok=1
verb_check_count=0
if [[ -z "$VERB_CHECK_LINES" || -z "$BRANCH_LINE" ]]; then
  verb_checks_ok=0
else
  while read -r ln; do
    [[ -z "$ln" ]] && continue
    verb_check_count=$((verb_check_count + 1))
    if [[ "$ln" -le "$BRANCH_LINE" ]]; then verb_checks_ok=0; fi
  done <<< "$VERB_CHECK_LINES"
fi
if [[ "$verb_checks_ok" -eq 1 && "$verb_check_count" -ge 2 ]]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "ok - all ${verb_check_count} verb assertions are inside the install branch, so opting out still builds"
else
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "FAIL: expected >=2 verb assertions, all inside the install branch (found ${verb_check_count}, ok=${verb_checks_ok}); SQUAD_HUB_SPEC=none would fail the build"
fi

# The library and the image have to agree on which verb is being called, or
# the assertion above guards the wrong thing.
assert_contains "$(cat "$HUB_LIB")" "squad-hub oneshot" \
  "the supervision library calls the same verb the image checks for"

# ---------------------------------------------------------------------------
# 6. Device identity — the binding that makes the token safe to ship
# ---------------------------------------------------------------------------
echo "-- device identity --"

# A device token is minted with a device-id prefix binding so a credential
# shipped to a cloud job cannot claim to be someone's laptop. The hub ENFORCES
# that binding at registration, which means the id this job registers under has
# to actually start with the bound prefix.
#
# It cannot be left to squad-hub's default. That default is a hex hash of the
# app name, and a hex string can never begin with "aca-" -- so following this
# repository's own documented advice would have refused every supervised
# session with exit 77. These assertions exist because that shipped once.
hub_device_id() {
  env -u CONTAINER_APP_JOB_EXECUTION_NAME -u CONTAINER_APP_REPLICA_NAME "$@" \
    bash -c 'source "'"$HUB_LIB"'"; squad_hub_device_id'
}

DID="$(hub_device_id CONTAINER_APP_JOB_EXECUTION_NAME=caj-squad-aca-session-abc123)"
assert_eq "aca-caj-squad-aca-session-abc123" "$DID" \
  "the device id STARTS with the prefix a bound token requires, and carries the execution"

# Two executions of the same job must not share one device slot: squad-hub is
# explicit that two attachments on one id fight over it.
DID2="$(hub_device_id CONTAINER_APP_JOB_EXECUTION_NAME=caj-squad-aca-session-def456)"
assert_ne "$DID" "$DID2" "two job executions register as two devices, not one"

# The hub lowercases the bound prefix and then does a plain prefix test, so an
# id with a capital in it would silently fail to match.
assert_eq "aca-caj-squad-aca-upper" "$(hub_device_id CONTAINER_APP_JOB_EXECUTION_NAME=CAJ-Squad-ACA-UPPER)" \
  "the device id is lowercased, because the hub's prefix test is"

# An operator who minted with a different prefix must be able to match it
# without editing the image.
assert_eq "job-xyz" "$(hub_device_id SQUAD_HUB_DEVICE_ID_PREFIX=job- CONTAINER_APP_JOB_EXECUTION_NAME=xyz)" \
  "the prefix is overridable, for a token minted with a different one"

# Off ACA there is no execution name; the id must still be composed rather than
# left bare, or every device would register as the prefix alone and collide.
assert_eq "aca-box42" "$(hub_device_id HOSTNAME=box42)" \
  "outside ACA the id still has a unique part"

# And it has to actually reach squad-hub, or none of the above matters.
assert_contains "$(cat "$HUB_LIB")" 'SQUAD_HUB_DEVICE_ID="$(squad_hub_device_id)"' \
  "the composed device id is passed to squad-hub oneshot"

# ---------------------------------------------------------------------------
# 7. Trust-conditioned hub policy (issue #84 PI-2)
# ---------------------------------------------------------------------------
# Squad Hub supervision runs the SAME resolver as the direct path, so an
# untrusted dispatch source attached to a human at the hub is narrower in
# exactly the same way it is narrower off the hub -- the hub is a channel for
# approving what the policy still allows, not a way to relax the policy.
echo "-- trust-conditioned hub policy --"

# `ralph` above is already the untrusted source this whole file exercises
# (see section 1); restate that here explicitly, and add the trusted side, so
# a reader does not have to infer trust from an incidental choice of fixture.
assert_contains "$HUB_JSON" '"shell(git push)"' \
  "hub-argv-json for the untrusted source (ralph) carries the untrusted-input deny pattern shell(git push)"
assert_contains "$HUB_JSON" '"shell(gh pr)"' \
  "hub-argv-json for the untrusted source (ralph) carries shell(gh pr)"
assert_contains "$HUB_JSON" '"shell(curl)"' \
  "hub-argv-json for the untrusted source (ralph) carries shell(curl)"
assert_contains "$HUB_JSON" '"shell(wget)"' \
  "hub-argv-json for the untrusted source (ralph) carries shell(wget)"

LOCAL_HUB_JSON="$(policy prompt local-cli hub-argv-json)"
assert_not_contains "$LOCAL_HUB_JSON" '"shell(git push)"' \
  "hub-argv-json for the TRUSTED source (local-cli) does NOT carry shell(git push) -- local is unchanged on the hub path too"
assert_not_contains "$LOCAL_HUB_JSON" '"shell(gh pr)"' \
  "hub-argv-json for local-cli does NOT carry shell(gh pr)"
assert_not_contains "$LOCAL_HUB_JSON" '"shell(curl)"' \
  "hub-argv-json for local-cli does NOT carry shell(curl)"
assert_not_contains "$LOCAL_HUB_JSON" '"shell(wget)"' \
  "hub-argv-json for local-cli does NOT carry shell(wget)"

# watch and actions are the other two untrusted, unattended dispatch sources;
# both must be narrower on the hub path exactly as ralph is.
WATCH_HUB_JSON="$(policy prompt watch hub-argv-json)"
ACTIONS_HUB_JSON="$(policy prompt actions hub-argv-json)"
for label_json in "watch:${WATCH_HUB_JSON}" "actions:${ACTIONS_HUB_JSON}"; do
  label="${label_json%%:*}"
  json="${label_json#*:}"
  assert_contains "$json" '"shell(git push)"' "hub-argv-json for untrusted source '${label}' carries shell(git push)"
  assert_contains "$json" '"shell(gh pr)"'    "hub-argv-json for untrusted source '${label}' carries shell(gh pr)"
done

# The hub's own announcement must reflect the same narrowing an operator would
# see off the hub — a hub session must not look MORE permissive in the log
# than the direct path for the same untrusted source.
ANNOUNCE_UNTRUSTED="$(env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE \
  SQUAD_MODE=prompt SQUAD_DISPATCH_SOURCE=ralph \
  bash -c 'source "'"${WORKER_DIR}/lib/squad-policy.sh"'"; squad_policy_resolve >/dev/null 2>&1; squad_policy_announce hub' 2>&1)"
UNTRUSTED_FLAGS_LINE="$(printf '%s\n' "$ANNOUNCE_UNTRUSTED" | grep 'Copilot flags (via Squad Hub')"
assert_contains "$UNTRUSTED_FLAGS_LINE" "shell(git push)" \
  "the hub announcement for an untrusted source shows the untrusted-input deny patterns being applied"


# =============================================================================
# Issue #107: a configured hub must not be silently ignored
# =============================================================================
#
# `watch` and `loop` own their own loop and spawn Copilot themselves, so there
# is no single session to hand to `squad-hub oneshot`. Before this, they simply
# never contacted a hub that was configured, valid and reachable -- and said
# nothing about it. An operator saw work happening and an empty hub.
#
# The assertions below are about the RESOLVED BEHAVIOUR of the entrypoint and
# the library, not about comments describing it.

ENTRYPOINT_SRC="$(cat "${WORKER_DIR}/entrypoint.sh")"

# Every mode that RUNS AN AGENT must reach the hub by one of the two routes:
#   squad_hub_run              -- one session (prompt, new-project)
#   squad_hub_supervise_ambient -- the container attaches (watch, loop)
# Extracted per mode block so a call in a NEIGHBOURING mode cannot satisfy it.
mode_block() {
  printf '%s\n' "$ENTRYPOINT_SRC" | awk -v want="$1" '
    index($0, "  " want ")") == 1 { inb=1; next }
    inb && /^  [a-z|_-]+\)[ \t]*$/ { exit }
    inb { print }
  '
}

for mode in "watch|triage" "loop"; do
  block="$(mode_block "$mode")"
  assert_contains "$block" "squad_hub_supervise_ambient" \
    "mode '${mode}' attaches to a configured hub instead of ignoring it"
  assert_contains "$block" "squad_hub_should_supervise" \
    "mode '${mode}' only attaches when a hub is actually configured"
done

# prompt/new-project keep the one-session route; ambient there would attach a
# whole container for a single run.
for mode in "prompt" "new-project"; do
  block="$(mode_block "$mode")"
  assert_contains "$block" "squad_hub_run" \
    "mode '${mode}' still supervises its single session directly"
done

# The library must actually provide what the entrypoint calls. A missing
# function in bash is a runtime error at the worst moment, not a load error.
HUB_LIB_SRC="$(cat "$HUB_LIB")"
for fn in squad_hub_supervise_ambient squad_hub_release_ambient squad_hub_has_hooks; do
  assert_contains "$HUB_LIB_SRC" "${fn}()" \
    "the supervision library defines ${fn}, which entrypoint.sh calls"
done

# ATTACH BEFORE THE LOOP STARTS. Iterations that run before anything is
# listening are lost, which looks exactly like the bug this replaces.
WATCH_BLOCK="$(mode_block "watch|triage")"
# Matched against the COMMAND, not any line mentioning it: the block carries a
# comment explaining why `squad watch` needs this, and that comment sits above
# the call -- so a naive grep reports the wrong order and fails a correct file.
ambient_line="$(printf '%s\n' "$WATCH_BLOCK" | grep -n '^ *squad_hub_supervise_ambient' | head -1 | cut -d: -f1)"
squad_line="$(printf '%s\n' "$WATCH_BLOCK" | grep -n '^ *squad watch ' | head -1 | cut -d: -f1)"
if [[ -n "$ambient_line" && -n "$squad_line" && "$ambient_line" -lt "$squad_line" ]]; then
  assert_eq "ok" "ok" "watch attaches to the hub BEFORE it starts the loop"
else
  assert_eq "before" "after" "watch attaches to the hub BEFORE it starts the loop"
fi

# A version without `hooks` cannot supervise a loop. Caught at BUILD, because
# the alternative is a container that runs perfectly and reports nothing.
assert_contains "$DOCKERFILE" "squad-hub hooks" \
  "the build asserts the installed squad-hub actually has the 'hooks' verb"

# The pin is a floor: hooks arrived in 0.4.1, and 0.4.0 crashes the daemon on
# its first heartbeat once hooks are installed.
PINNED="$(printf '%s\n' "$DOCKERFILE" | grep -o 'squad-hub@[0-9][0-9.]*' | head -1)"
PINNED_VER="${PINNED#squad-hub@}"
lowest="$(printf '%s\n0.4.1\n' "$PINNED_VER" | sort -V | head -1)"
assert_eq "0.4.1" "$lowest" \
  "the pinned squad-hub (${PINNED_VER}) is at least 0.4.1, where 'hooks' arrived"

# Ambient supervision must FAIL LOUDLY, never downgrade. A mode told to
# supervise that quietly did not is the whole defect.
AMBIENT_FN="$(printf '%s\n' "$HUB_LIB_SRC" | awk '/^squad_hub_supervise_ambient\(\)/{f=1} f{print} f&&/^}/{exit}')"
assert_contains "$AMBIENT_FN" "squad_hub_abort" \
  "ambient supervision aborts rather than running unsupervised when it cannot attach"
assert_contains "$AMBIENT_FN" "hooks install" \
  "ambient supervision installs the hooks that make each spawned session visible"
assert_contains "$AMBIENT_FN" "squad-hub connect" \
  "ambient supervision attaches the container as a device"

# NOT `squad-hub start`. It accepts no --name, so the device appears under a
# random ACA replica hostname; and it returns 0 even when the hub REFUSES the
# attach, printing "(NOT connected)" and exiting successfully. An abort keyed
# on its exit code would never fire, and the mode would run unsupervised while
# reporting that it was supervised -- this defect, reintroduced one layer down.
assert_not_contains "$AMBIENT_FN" "squad-hub start" \
  "ambient supervision does not use 'start', which succeeds even when the hub refuses"
assert_contains "$AMBIENT_FN" 'name "$(squad_hub_device_id)"' \
  "the container attaches under a nameable device id, not the replica hostname"

echo ""
echo "squad-hub supervision: ${TESTS_RUN} assertions, ${TESTS_FAILED} failed"
exit $(( TESTS_FAILED > 0 ? 1 : 0 ))
