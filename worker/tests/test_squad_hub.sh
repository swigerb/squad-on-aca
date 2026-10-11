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
ANNOUNCE="$(env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE -u SQUAD_HUB_APPROVAL \
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
# 4b. Watch-only (SQUAD_HUB_APPROVAL=auto)
# ---------------------------------------------------------------------------
# Opt-in: the session stays visible in the hub, nothing waits for a person, and
# the deny list is byte-for-byte the same as in ask mode.
echo "-- watch-only approval mode --"

approval_status() {
  (
    source "$HUB_LIB"
    command() { if [[ "${2:-}" == "squad-hub" ]]; then return 0; fi; builtin command "$@"; }
    SQUAD_HUB_APPROVAL="$1" SQUAD_HUB_TOKEN='sqhd1.eyJhIjoxfQ.sig' squad_hub_preflight
  ) >/dev/null 2>&1
  printf '%s' "$?"
}
assert_eq "0"  "$(approval_status '')"     "an unset approval mode is accepted (default: ask)"
assert_eq "0"  "$(approval_status ask)"    "SQUAD_HUB_APPROVAL=ask is accepted"
assert_eq "0"  "$(approval_status auto)"   "SQUAD_HUB_APPROVAL=auto is accepted"
assert_eq "78" "$(approval_status Auto)"   "an unknown approval mode (wrong case) aborts rather than being guessed"
assert_eq "78" "$(approval_status yes)"    "an unknown approval mode aborts rather than being guessed"

hub_json_for() {
  env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE \
    SQUAD_MODE=prompt SQUAD_DISPATCH_SOURCE=local-cli SQUAD_HUB_APPROVAL="$1" \
    SQUAD_POLICY_RESOLVER="$RESOLVER" \
    bash -c 'source "'"$HUB_LIB"'"; squad_hub_policy_json' 2>&1
}
ASK_JSON="$(hub_json_for ask)"
AUTO_JSON="$(hub_json_for auto)"
assert_not_contains "$ASK_JSON" '"--allow-all-tools"' \
  "ask mode still drops --allow-all-tools, so ungated tools raise approval cards"
assert_contains "$AUTO_JSON" '"--allow-all-tools"' \
  "watch-only keeps --allow-all-tools, so nothing waits for a person"
SAME_DENY="$(ASK="$ASK_JSON" AUTO="$AUTO_JSON" node -e '
  const a = JSON.parse(process.env.ASK), b = JSON.parse(process.env.AUTO);
  const rest = b.filter((x, i) => !(i === 0 && x === "--allow-all-tools"));
  console.log(JSON.stringify(a) === JSON.stringify(rest) ? "identical" : "differs");
')"
assert_eq "identical" "$SAME_DENY" \
  "watch-only adds exactly --allow-all-tools and nothing else: deny list and flags are unchanged"
assert_contains "$AUTO_JSON" '"shell(git config)"' \
  "watch-only still carries multi-word deny patterns whole"

# The resolver guard still applies in watch-only: the RESOLVER must never emit
# --allow-all-tools for the hub; only this explicit opt-in may add it.
STUB_DIR="$(mktemp -d)"
printf '#!/usr/bin/env node\nprocess.stdout.write(JSON.stringify(["--allow-all-tools","--agent","squad"]) + "\\n");\n' > "${STUB_DIR}/leaky.js"
( source "$HUB_LIB"; SQUAD_HUB_APPROVAL=auto SQUAD_POLICY_RESOLVER="${STUB_DIR}/leaky.js" squad_hub_policy_json ) >/dev/null 2>&1
leak_auto_status="$?"
( source "$HUB_LIB"; SQUAD_HUB_APPROVAL=bogus SQUAD_POLICY_RESOLVER="$RESOLVER" squad_hub_policy_json ) >/dev/null 2>&1
bogus_policy_status="$?"
rm -rf "$STUB_DIR"
assert_eq "78" "$leak_auto_status" \
  "a resolver that leaks --allow-all-tools is refused in watch-only mode too"
assert_eq "78" "$bogus_policy_status" \
  "building the hub argv with an unknown approval mode aborts, even outside preflight"

# The log must state the policy that actually applies.
announce_for() {
  env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE -u SQUAD_HUB_APPROVAL \
    SQUAD_MODE=prompt SQUAD_DISPATCH_SOURCE=ralph SQUAD_HUB_APPROVAL="$1" \
    bash -c 'source "'"${WORKER_DIR}/lib/squad-policy.sh"'"; squad_policy_resolve >/dev/null 2>&1; squad_policy_announce hub' 2>&1
}
AUTO_ANNOUNCE="$(announce_for auto)"
assert_contains "$(printf '%s\n' "$AUTO_ANNOUNCE" | grep 'Copilot flags (via Squad Hub')" "--allow-all-tools" \
  "the watch-only announcement lists --allow-all-tools, because the session has it"
assert_contains "$AUTO_ANNOUNCE" "WATCH-ONLY" \
  "the watch-only announcement says so, in every session log"
assert_not_contains "$AUTO_ANNOUNCE" "a human at the hub answers" \
  "the watch-only announcement does not claim a human approves tools"
assert_contains "$(announce_for ask)" "MINUS --allow-all-tools" \
  "ask mode's announcement is unchanged"

# Ambient path: exactly the blocking hook goes, every reporting hook stays.
HOOK_HOME="$(mktemp -d)"
mkdir -p "$HOOK_HOME/hooks"
node -e '
  const ev = ["sessionStart","sessionEnd","userPromptSubmitted","postToolUse","agentStop","preToolUse"];
  const hooks = {}; for (const e of ev) hooks[e] = [{ type: "command", bash: `squad-hub hook ${e}`, timeoutSec: e === "preToolUse" ? 300 : 5 }];
  require("fs").writeFileSync(process.argv[1], JSON.stringify({ version: 1, hooks }));
' "$HOOK_HOME/hooks/squad-hub.json"
( source "$HUB_LIB"; COPILOT_HOME="$HOOK_HOME" squad_hub_hooks_observe_only ) >/dev/null 2>&1
observe_status="$?"
HOOK_KEYS="$(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks).sort().join(","))' "$HOOK_HOME/hooks/squad-hub.json")"
assert_eq "0" "$observe_status" "watch-only hook rewrite succeeds on a squad-hub v1 hook file"
assert_eq "agentStop,postToolUse,sessionEnd,sessionStart,userPromptSubmitted" "$HOOK_KEYS" \
  "watch-only removes ONLY preToolUse; every reporting hook stays, so the session stays visible"

printf '{"version":2,"hooks":{"preToolUse":[]}}' > "$HOOK_HOME/hooks/squad-hub.json"
( source "$HUB_LIB"; COPILOT_HOME="$HOOK_HOME" squad_hub_hooks_observe_only ) >/dev/null 2>&1
assert_ne "0" "$?" "an unrecognised hook file format is refused rather than guessed at"
rm -f "$HOOK_HOME/hooks/squad-hub.json"
( source "$HUB_LIB"; COPILOT_HOME="$HOOK_HOME" squad_hub_hooks_observe_only ) >/dev/null 2>&1
assert_ne "0" "$?" "a missing hook file is refused rather than reported as watch-only"
rm -rf "$HOOK_HOME"

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

# A supervised session is still a Copilot session and must export telemetry the
# same way the unsupervised `copilot -p` path does. It once shipped without this,
# so every hub-supervised run was invisible in Aspire.
HUB_RUN_BLOCK="$(sed -n '/^squad_hub_run()/,/"\${hub_oneshot\[@\]}"/p' "$HUB_LIB")"
assert_contains "$HUB_RUN_BLOCK" "COPILOT_OTEL_ENABLED=true" \
  "supervised sessions enable Copilot OpenTelemetry"
assert_contains "$HUB_RUN_BLOCK" "COPILOT_OTEL_EXPORTER_TYPE=otlp-http" \
  "supervised sessions export over OTLP/HTTP like the direct path"
assert_contains "$HUB_RUN_BLOCK" 'OTEL_EXPORTER_OTLP_ENDPOINT="${ASPIRE_OTLP_HTTP_ENDPOINT' \
  "supervised sessions point Copilot at the Aspire OTLP/HTTP endpoint"

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
ANNOUNCE_UNTRUSTED="$(env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE -u SQUAD_HUB_APPROVAL \
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

# ---------------------------------------------------------------------------
# Issue #126: the DAEMON must register under the aca- id, not squad-hub's hex
# ---------------------------------------------------------------------------
# `connect --name` sets only the display name. The daemon registers under
# config.deviceId, which squad-hub otherwise derives as 16 hex characters --
# refused by every token bound with `--prefix aca-`. Asserted by behaviour: run
# the seed against a scratch SQUAD_HUB_HOME and read back what squad-hub would.
echo "-- ambient device id (#126) --"

seed_in() {
  local home="$1"
  env -u CONTAINER_APP_JOB_EXECUTION_NAME SQUAD_HUB_HOME="$home" \
    CONTAINER_APP_REPLICA_NAME="ca-squad-aca-watch--0000006-ABC12" \
    bash -c 'source "'"$HUB_LIB"'"; squad_hub_seed_device_id' 2>&1
}
read_cfg() {
  node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log(c[process.argv[2]] ?? "")' "$1/config.json" "$2"
}

SEED_HOME="$(mktemp -d)"
seed_in "$SEED_HOME/fresh" >/dev/null
assert_eq "aca-ca-squad-aca-watch--0000006-abc12" "$(read_cfg "$SEED_HOME/fresh" deviceId)" \
  "a fresh squad-hub home gets the lowercased aca- device id the token allows"

mkdir -p "$SEED_HOME/existing"
printf '{"deviceId":"b2c77510dbf04f68","deviceName":"keep me","server":"https://hub.example"}' > "$SEED_HOME/existing/config.json"
seed_in "$SEED_HOME/existing" >/dev/null
assert_eq "aca-ca-squad-aca-watch--0000006-abc12" "$(read_cfg "$SEED_HOME/existing" deviceId)" \
  "a stale hex device id is replaced, so a restarted replica cannot keep the refused one"
assert_eq "keep me" "$(read_cfg "$SEED_HOME/existing" deviceName)" \
  "seeding the id leaves every other squad-hub setting alone"
assert_eq "https://hub.example" "$(read_cfg "$SEED_HOME/existing" server)" \
  "seeding the id does not drop the configured hub"

mkdir -p "$SEED_HOME/corrupt"
printf 'not json' > "$SEED_HOME/corrupt/config.json"
seed_rc=0; seed_in "$SEED_HOME/corrupt" >/dev/null || seed_rc=$?
assert_ne "0" "$seed_rc" \
  "an unreadable squad-hub config fails the seed instead of being silently overwritten"
rm -rf "$SEED_HOME"

# Order matters: the id must be in place BEFORE connect starts the daemon, or
# the first attach (the one connect waits on) still goes out under the hex id.
seed_line="$(printf '%s\n' "$AMBIENT_FN" | grep -n 'squad_hub_seed_device_id' | head -1 | cut -d: -f1)"
connect_line="$(printf '%s\n' "$AMBIENT_FN" | grep -n 'squad-hub connect' | head -1 | cut -d: -f1)"
if [[ -n "$seed_line" && -n "$connect_line" && "$seed_line" -lt "$connect_line" ]]; then seed_order=before; else seed_order=after-or-missing; fi
assert_eq "before" "$seed_order" \
  "ambient supervision seeds the daemon's device id before 'squad-hub connect'"
seed_guard="$(printf '%s\n' "$AMBIENT_FN" | awk '/squad_hub_seed_device_id/{f=1} f{print} f&&/^  fi/{exit}')"
assert_contains "$seed_guard" "squad_hub_abort" \
  "a failed seed aborts rather than attaching under an id the hub will refuse"

# Watch-only on the ambient path: the blocking hook is removed AFTER the install
# that writes it (or the install would put it straight back), and a failure to
# remove it aborts rather than leaving sessions that still wait for approval.
install_line="$(printf '%s\n' "$AMBIENT_FN" | grep -n 'hooks install' | head -1 | cut -d: -f1)"
observe_line="$(printf '%s\n' "$AMBIENT_FN" | grep -n 'squad_hub_hooks_observe_only' | head -1 | cut -d: -f1)"
if [[ -n "$install_line" && -n "$observe_line" && "$install_line" -lt "$observe_line" ]]; then observe_order=after; else observe_order=before-or-missing; fi
assert_eq "after" "$observe_order" \
  "watch-only removes preToolUse after 'hooks install', not before it"
observe_guard="$(printf '%s\n' "$AMBIENT_FN" | awk '/squad_hub_hooks_observe_only/{f=1} f{print} f&&/^    fi/{exit}')"
assert_contains "$observe_guard" "squad_hub_abort" \
  "a failed watch-only rewrite aborts instead of running sessions that still block"

# ---------------------------------------------------------------------------
# 8. Device display metadata and PR reporting (#136)
# ---------------------------------------------------------------------------
echo "-- device metadata and PR reporting (#136) --"

issue_probe() {
  env -u OUTPUT_BRANCH -u PR_TITLE "$@" \
    bash -c 'source "'"$HUB_LIB"'"; out=""; if out="$(squad_hub_issue_number)"; then printf "rc=0|%s" "$out"; else rc=$?; printf "rc=%s|%s" "$rc" "$out"; fi'
}

assert_eq "rc=0|304" "$(issue_probe OUTPUT_BRANCH='squad/issue-304')" \
  "the issue number is parsed from OUTPUT_BRANCH first"
assert_eq "rc=0|304" "$(issue_probe OUTPUT_BRANCH='squad/bootstrap-foo' PR_TITLE='Squad: issue #304')" \
  "the issue number falls back to PR_TITLE when the branch is not an issue branch"
assert_eq "rc=1|" "$(issue_probe OUTPUT_BRANCH='squad/bootstrap-foo')" \
  "new-project style branches do not fabricate an issue number"

device_name_probe() {
  env -u OUTPUT_BRANCH -u PR_TITLE -u GITHUB_REPOSITORY -u SESSION_NAME "$@" \
    bash -c 'source "'"$HUB_LIB"'"; squad_hub_device_name'
}

assert_eq "#304 · AzureAIDriveThru" \
  "$(device_name_probe OUTPUT_BRANCH='squad/issue-304' GITHUB_REPOSITORY='swigerb/AzureAIDriveThru')" \
  "the device name is issue-first with the repository short name"
assert_eq "alpha-session" "$(device_name_probe SESSION_NAME='alpha-session')" \
  "without an issue, the device name falls back to SESSION_NAME"

LONG_REPO_SUFFIX="$(printf 'a%.0s' $(seq 1 260))"
LONG_DEVICE_NAME="$(device_name_probe OUTPUT_BRANCH='squad/issue-304' GITHUB_REPOSITORY="swigerb/${LONG_REPO_SUFFIX}")"
assert_eq "200" "${#LONG_DEVICE_NAME}" \
  "the computed device name is capped at 200 characters before it reaches the hub"

META_JSON="$(env -u CONTAINER_APP_JOB_NAME \
  OUTPUT_BRANCH='squad/issue-304' \
  PR_TITLE='Squad: issue #999' \
  GITHUB_REPOSITORY="octo/$(printf 'r%.0s' $(seq 1 260))" \
  CONTAINER_APP_JOB_EXECUTION_NAME="$(printf 'e%.0s' $(seq 1 260))" \
  bash -c 'source "'"$HUB_LIB"'"; squad_hub_device_meta_json')"
META_SUMMARY="$(META_JSON="$META_JSON" node -e '
  const meta = JSON.parse(process.env.META_JSON);
  const keys = Object.keys(meta).join(",");
  const summary = [
    keys,
    typeof meta.issue,
    meta.issue,
    String(meta.repo.length),
    String(meta.executionName.length),
    String(meta.jobName.length),
    meta.jobName === "" ? "empty" : "set",
  ];
  process.stdout.write(summary.join("|"));
')"
assert_eq "repo,issue,executionName,jobName|string|304|200|200|0|empty" "$META_SUMMARY" \
  "device metadata is valid JSON with exactly four string-valued keys and empty-string defaults"

assert_contains "$HUB_RUN_BLOCK" 'SQUAD_HUB_DEVICE_NAME="$device_name"' \
  "the oneshot env block exports the computed device name"
assert_contains "$HUB_RUN_BLOCK" 'SQUAD_HUB_DEVICE_META_JSON="$device_meta_json"' \
  "the oneshot env block exports the computed device metadata JSON"
# The role model pin (#135, then the per-role pin). The hub one-shot path cannot
# GUARANTEE a model on its own: `copilot --acp` ignores a --model argv flag, the
# pinned squad-hub build (0.6.0) neither reads a required model nor answers a
# capability probe, and a hub that treats the model as a preference falls back to
# its default with only a warning. So a session that REQUIRES a model is handed to
# the hub only when the hub says -- via the bounded, side-effect-free
# `squad-hub oneshot --capabilities` probe, {"protocolVersion":1,"requiredModel":
# true} -- that it can run `oneshot` strictly on SQUAD_HUB_MODEL with
# SQUAD_HUB_REQUIRE_MODEL=1 (exit 78 when the agent did not confirm the model);
# any other build is refused. These assertions are about the observed argv/env and
# exit codes of a stub hub, not about the prose in the file.
HUB_RUN_CODE="$(grep -v '^[[:space:]]*#' <<<"$HUB_RUN_BLOCK")"
assert_contains "$HUB_RUN_CODE" 'env "SQUAD_HUB_MODEL=${required_model}" SQUAD_HUB_REQUIRE_MODEL=1 squad-hub oneshot' \
  "a required model is forwarded as a command-scoped SQUAD_HUB_MODEL plus SQUAD_HUB_REQUIRE_MODEL=1"
assert_not_contains "$(grep -v '^[[:space:]]*#' "$HUB_LIB")" 'SQUAD_HUB_REQUIRED_MODEL' \
  "no invented SQUAD_HUB_REQUIRED_MODEL variable remains in the hub library"
assert_not_contains "$(grep -v '^[[:space:]]*#' "$HUB_LIB")" 'capabilities --json' \
  "the retired 'capabilities --json' probe is gone"
assert_not_contains "$(sed -n '/^squad_hub_policy_json()/,/^}/p' "$HUB_LIB")" '--model' \
  "the model is not smuggled into the hub argv JSON, which copilot --acp would silently ignore"

PIN_STUB_ROOT="$(mktemp -d)"
mkdir -p "${PIN_STUB_ROOT}/bin" "${PIN_STUB_ROOT}/repo"
cat > "${PIN_STUB_ROOT}/bin/squad-hub" <<'HUBSTUB'
#!/usr/bin/env bash
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hub_env_names() { env | sed -n 's/^\(SQUAD_HUB_[A-Z_]*\)=.*/\1/p' | sort | tr '\n' ' '; }
run_session() {
  : > "${root}/oneshot.hit"
  echo run >> "${root}/oneshot.count"
  printf '%s' "$*" > "${root}/oneshot.argv"
  printf '%s' "${SQUAD_HUB_MODEL-<unset>}" > "${root}/oneshot.model"
  printf '%s' "${SQUAD_HUB_REQUIRE_MODEL-<unset>}" > "${root}/oneshot.require"
  printf '%s' "${SQUAD_HUB_AGENT_EXTRA_ARGS_JSON-<unset>}" > "${root}/oneshot.argvjson"
  printf '%s' "${SQUAD_HUB_PROMPT-<unset>}" > "${root}/oneshot.prompt"
  printf '%s' "${SQUAD_HUB_URL-<unset>}|${SQUAD_HUB_TOKEN-<unset>}|${SQUAD_HUB_DEVICE_ID-<unset>}" > "${root}/oneshot.identity"
  # The strict contract: a required model the agent cannot confirm sends no
  # prompt and exits 78.
  if [[ "${SQUAD_HUB_REQUIRE_MODEL:-}" == 1 && ",${STUB_AVAILABLE_MODELS:-model-alpha}," != *",${SQUAD_HUB_MODEL:-},"* ]]; then
    echo "required-model-refused code=MODEL_UNAVAILABLE reason=not offered" >&2
    exit 78
  fi
  : > "${root}/oneshot.prompt-sent"
  exit "${STUB_ONESHOT_EXIT:-0}"
}
case "${1:-}" in
  oneshot)
    if [[ "${2:-}" == "--capabilities" ]]; then
      printf '%s' "$*" > "${root}/capabilities.argv"
      hub_env_names > "${root}/capabilities.hubenv"
      case "${STUB_CAP_MODE:-old}" in
        json) printf '%s' "${STUB_CAP_JSON:-}"; exit 0 ;;
        big) printf '{"protocolVersion":1,"requiredModel":true,"pad":"%s"}' "$(head -c 5000 /dev/zero | tr '\0' a)"; exit 0 ;;
        fail) echo 'capabilities failed' >&2; exit 1 ;;
        hang) exec sleep 30 ;;
        # A valid, complete "yes" and a clean exit 0 -- but a descendant the hub never
        # reaped is still running (immune to TERM and HUP) and holds the probe's stdout.
        bg) (trap '' TERM HUP INT; exec sleep 25) & echo $! > "${root}/capabilities.child"
            printf '%s' "${STUB_CAP_JSON:-}"; exit 0 ;;
        # A hub that hangs AND has such a descendant.
        hangbg) (trap '' TERM HUP INT; exec sleep 25) & echo $! > "${root}/capabilities.child"
                exec sleep 30 ;;
        # A hub that will not stop writing; records how much its stdout file holds.
        flood) head -c 5000000 /dev/zero | tr '\0' a
               if [[ -r /proc/$$/fd/1 ]]; then wc -c < /proc/$$/fd/1 | tr -d '[:space:]' > "${root}/capabilities.written"; fi
               exit 0 ;;
        # squad-hub 0.6.0: oneshot ignores its argv, needs the cloud device
        # variables, and would otherwise go on to attach and run a session.
        old)
          if [[ -z "${SQUAD_HUB_URL:-}" || -z "${SQUAD_HUB_TOKEN:-}" ]]; then
            echo 'SQUAD_HUB_URL and SQUAD_HUB_TOKEN are required for a cloud device' >&2
            exit 64
          fi
          run_session "$@"
          ;;
      esac
    fi
    run_session "$@"
    ;;
  *) echo "squad-hub: unknown command '${1:-}'" >&2; exit 2 ;;
esac
HUBSTUB
chmod +x "${PIN_STUB_ROOT}/bin/squad-hub"

CAPABLE='{"protocolVersion":1,"requiredModel":true}'
hub_run_with() {
  # usage: hub_run_with <cap-mode> [VAR=value ...]   (sets PIN_RUN_OUT, PIN_RUN_RC)
  local cap_mode="$1"
  shift
  rm -f "${PIN_STUB_ROOT}"/oneshot.* "${PIN_STUB_ROOT}"/capabilities.*
  PIN_RUN_OUT="$(env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE \
    -u SQUAD_MODEL -u SQUAD_MODEL_PINNED -u SQUAD_HUB_MODEL -u SQUAD_HUB_REQUIRE_MODEL \
    PATH="${PIN_STUB_ROOT}/bin:$PATH" SQUAD_MODE=prompt SQUAD_DISPATCH_SOURCE=local-cli \
    SQUAD_POLICY_RESOLVER="$RESOLVER" REPO_DIR="${PIN_STUB_ROOT}/repo" \
    SQUAD_HUB_URL=https://hub.example SQUAD_HUB_TOKEN=sqhd1.x \
    STUB_CAP_MODE="$cap_mode" "$@" \
    bash -c 'source "'"$HUB_LIB"'"; squad_hub_run "a prompt"; rc=$?; echo "AFTER model=${SQUAD_HUB_MODEL-<unset>} require=${SQUAD_HUB_REQUIRE_MODEL-<unset>}"; exit $rc' 2>&1)"
  PIN_RUN_RC=$?
}
hub_state() { [[ -e "${PIN_STUB_ROOT}/$1" ]] && echo present || echo absent; }
hub_file() { cat "${PIN_STUB_ROOT}/$1" 2>/dev/null || printf '<missing>'; }

# An older hub (the pinned 0.6.0): `oneshot` ignores --capabilities. With the hub
# variables scrubbed from the probe it stops at the missing URL (exit 64) -- and a
# probe that was NOT scrubbed would have started a real session here.
hub_run_with old SQUAD_MODEL=model-alpha
assert_eq "78" "$PIN_RUN_RC" "a model-required session is refused by a hub that does not know the capability probe (exit 78)"
assert_contains "$PIN_RUN_OUT" "model-alpha" "the refusal names the required model"
assert_contains "$PIN_RUN_OUT" "oneshot --capabilities" "the refusal names the probe the hub did not answer"
assert_contains "$PIN_RUN_OUT" '"requiredModel":true' "the refusal says what answer it needed"
assert_contains "$PIN_RUN_OUT" "squad-hub@0.6.0" "the refusal says which pinned hub build lacks it"
assert_not_contains "$PIN_RUN_OUT" "unset SQUAD_HUB" "the refusal never tells the operator to unset the Hub configuration"
assert_not_contains "$PIN_RUN_OUT" "without hub supervision" "the refusal never suggests dropping hub supervision"
assert_eq "present" "$(hub_state capabilities.argv)" "the capability was asked for, not guessed from a version"
assert_eq "oneshot --capabilities" "$(hub_file capabilities.argv)" "the capability probe is exactly: squad-hub oneshot --capabilities"
assert_eq "" "$(hub_file capabilities.hubenv)" "the probe runs with every SQUAD_HUB_* variable (URL, token, ...) removed from its environment"
assert_eq "absent" "$(hub_state oneshot.hit)" "the probe did not start a session on a hub that ignores --capabilities"
assert_eq "absent" "$(hub_state oneshot.count)" "squad-hub oneshot is never run on a hub that cannot guarantee the model"
assert_contains "$PIN_RUN_OUT" "Refusing to run the session" "the refusal is the worker's own fail-closed abort"

# Every other way of not clearly saying "yes" is a no.
hub_run_with fail SQUAD_MODEL=model-alpha
assert_eq "78" "$PIN_RUN_RC" "a capability probe that exits non-zero refuses the session"
assert_eq "absent" "$(hub_state oneshot.hit)" "...and oneshot is not invoked after a failed capability probe"
for doc in \
  'not json' \
  '' \
  '[]' \
  'null' \
  '"protocolVersion"' \
  '{}' \
  '{"protocolVersion":1}' \
  '{"requiredModel":true}' \
  '{"protocolVersion":1,"requiredModel":false}' \
  '{"protocolVersion":1,"requiredModel":"true"}' \
  '{"protocolVersion":1,"requiredModel":1}' \
  '{"protocolVersion":1,"requiredModel":null}' \
  '{"protocolVersion":"1","requiredModel":true}' \
  '{"protocolVersion":2,"requiredModel":true}' \
  '{"protocolVersion":0,"requiredModel":true}' \
  '{"protocolVersion":1.5,"requiredModel":true}' \
  '{"schema":1,"capabilities":{"oneshotRequiredModel":true}}' \
  $'starting hub...\n{"protocolVersion":1,"requiredModel":true}' \
  '{"protocolVersion":1,"requiredModel":true} trailing'; do
  hub_run_with json SQUAD_MODEL=model-alpha STUB_CAP_JSON="$doc"
  assert_eq "78:absent" "${PIN_RUN_RC}:$(hub_state oneshot.hit)" \
    "probe output [${doc//$'\n'/\\n}] is not a strict yes: refused (78), oneshot not invoked"
done
hub_run_with big SQUAD_MODEL=model-alpha
assert_eq "78:absent" "${PIN_RUN_RC}:$(hub_state oneshot.hit)" "a probe answer longer than 4096 bytes is refused even when it is otherwise the right document"
hub_run_with hang SQUAD_MODEL=model-alpha SQUAD_HUB_CAPABILITY_TIMEOUT_SECONDS=1
assert_eq "78:absent" "${PIN_RUN_RC}:$(hub_state oneshot.hit)" \
  "a capability probe that hangs is bounded by a timeout and refuses the session"
assert_eq "present" "$(hub_state capabilities.argv)" "...after it was actually asked"

# The probe is bounded as a TREE, not just as a process. Each stub below really
# leaves a descendant that ignores TERM and holds the probe's stdout (25s), the
# way a build that forgot to reap a helper would. A pipe reader waits for EOF
# until that descendant exits -- 25s with a 3s probe timeout.
mkdir -p "${PIN_STUB_ROOT}/tmp"
pid_gone() {
  # kill -0 succeeds for a zombie, which is already dead: treat state Z as gone.
  local pid="$1" i state
  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || return 0
    if [[ -r "/proc/${pid}/stat" ]]; then
      state="$(sed -E 's/^[0-9]+ \(.*\) (.).*/\1/' "/proc/${pid}/stat" 2>/dev/null)"
      [[ "$state" == Z ]] && return 0
    fi
    sleep 0.1
  done
  return 1
}
probe_tree_case() {
  # usage: probe_tree_case <label> <cap-mode> [VAR=value ...]
  local label="$1" mode="$2" started child
  shift 2
  started=$SECONDS
  hub_run_with "$mode" SQUAD_MODEL=model-alpha SQUAD_HUB_CAPABILITY_TIMEOUT_SECONDS=3 TMPDIR="${PIN_STUB_ROOT}/tmp" "$@"
  PROBE_TOOK=$((SECONDS - started))
  child="$(hub_file capabilities.child)"
  PROBE_CHILD="$child"
  assert_eq "78:absent" "${PIN_RUN_RC}:$(hub_state oneshot.hit)" "${label}: the session is refused (78) and oneshot is not invoked"
  assert_eq "absent" "$(hub_state oneshot.count)" "${label}: squad-hub oneshot is never run"
  if [[ "$PROBE_TOOK" -lt 12 ]]; then
    assert_eq "ok" "ok" "${label}: the probe returned in ${PROBE_TOOK}s -- inside its own deadline, not the descendant's 25s"
  else
    assert_eq "under 12s" "${PROBE_TOOK}s" "${label}: the probe is bounded as a tree"
  fi
  assert_eq "" "$(ls -A "${PIN_STUB_ROOT}/tmp")" "${label}: the probe's private answer file is removed"
}
probe_tree_case "valid answer, exit 0, descendant left running" bg STUB_CAP_JSON="$CAPABLE"
assert_contains "$PIN_RUN_OUT" "left processes running" "...and the log says why a valid-looking answer was not accepted"
assert_ne "" "$PROBE_CHILD" "...the stub really started a descendant (pid ${PROBE_CHILD:-none})"
if pid_gone "$PROBE_CHILD"; then
  assert_eq "ok" "ok" "...and that descendant was stopped by the probe's own cleanup, not left to run out its 25s"
else
  assert_eq "gone" "alive (pid ${PROBE_CHILD})" "...and that descendant was stopped by the probe's own cleanup"
  kill -s KILL "$PROBE_CHILD" 2>/dev/null || true
fi
probe_tree_case "hung hub with a TERM-immune descendant" hangbg
assert_ne "" "$PROBE_CHILD" "...the stub really started a descendant (pid ${PROBE_CHILD:-none})"
if pid_gone "$PROBE_CHILD"; then
  assert_eq "ok" "ok" "...and the deadline removed that descendant too"
else
  assert_eq "gone" "alive (pid ${PROBE_CHILD})" "...and the deadline removed that descendant too"
  kill -s KILL "$PROBE_CHILD" 2>/dev/null || true
fi
probe_tree_case "a hub that writes without end" flood
# The on-disk cap is RLIMIT_FSIZE, which Linux enforces and Git Bash on Windows
# does not (the refusal above does not depend on it: the answer is over 4096 bytes
# either way). So the size is only asserted where the limit exists.
written="$(hub_file capabilities.written)"
if [[ "$(uname -s)" == Linux ]]; then
  if [[ "$written" =~ ^[0-9]+$ && "$written" -le 16384 ]]; then
    assert_eq "ok" "ok" "...the probe's stdout file stopped at ${written} bytes of the 5000000 the hub tried to write (cap 16384)"
  else
    assert_eq "at most 16384 bytes" "${written} bytes" "...the probe's stdout file is capped on disk"
  fi
else
  echo "SKIP: the on-disk cap of a flooded probe answer is only measured on Linux (this host does not enforce RLIMIT_FSIZE); the refusal above still ran."
fi

# A hub that does say yes gets the model explicitly, for this one command only.
hub_run_with json SQUAD_MODEL=model-alpha STUB_CAP_JSON="$CAPABLE"
assert_eq "0" "$PIN_RUN_RC" "a hub that answers the probe with protocolVersion 1 / requiredModel true runs the session"
assert_eq "present" "$(hub_state oneshot.hit)" "the capable hub's oneshot is invoked"
assert_eq "oneshot" "$(hub_file oneshot.argv)" "the supervised session is a plain 'squad-hub oneshot' (no --capabilities)"
assert_eq "model-alpha" "$(hub_file oneshot.model)" "the resolved model reaches oneshot as SQUAD_HUB_MODEL"
assert_eq "1" "$(hub_file oneshot.require)" "oneshot is told SQUAD_HUB_REQUIRE_MODEL=1"
assert_eq "present" "$(hub_state oneshot.prompt-sent)" "the capable hub confirmed the available model and sent the prompt"
assert_contains "$PIN_RUN_OUT" "AFTER model=<unset> require=<unset>" "the model variables were scoped to the oneshot command and not left in the caller's environment"
assert_eq "a prompt" "$(hub_file oneshot.prompt)" "the prompt is still delivered through the one-shot environment"
assert_contains "$(hub_file oneshot.identity)" "https://hub.example|sqhd1.x|aca-" \
  "supervision is intact: the same hub URL, device token and aca- device id reach oneshot"
assert_not_contains "$(hub_file oneshot.argvjson)" "--model" "no --model rides in the hub agent argv, where copilot --acp would ignore it"
assert_contains "$(hub_file oneshot.argvjson)" '"shell(git config)"' "the supervised tool policy (deny list) is unchanged by the model gate"
assert_not_contains "$(hub_file oneshot.argvjson)" '"--allow-all-tools"' "ask mode still drops --allow-all-tools on the required-model path"
assert_contains "$PIN_RUN_OUT" "Required model: model-alpha" "the log says which model the hub was required to use"
hub_run_with json SQUAD_MODEL=model-alpha SQUAD_HUB_APPROVAL=auto STUB_CAP_JSON="$CAPABLE"
assert_contains "$(hub_file oneshot.argvjson)" '"--allow-all-tools"' "watch-only approval (auto) is unchanged by the model gate"
hub_run_with json SQUAD_MODEL=Model-Alpha SQUAD_HUB_MODEL=model-alpha STUB_CAP_JSON="$CAPABLE" STUB_AVAILABLE_MODELS=Model-Alpha
assert_eq "0:Model-Alpha" "${PIN_RUN_RC}:$(hub_file oneshot.model)" \
  "an ambient SQUAD_HUB_MODEL that names the same model (any case) is accepted and replaced by the resolved id"

# The probe answer does not depend on who is asking: the same document is also
# accepted pretty-printed and with fields the worker does not know.
hub_run_with json SQUAD_MODEL=model-alpha STUB_CAP_JSON=$'{\n  "protocolVersion": 1,\n  "requiredModel": true,\n  "extra": "ignored"\n}\n'
assert_eq "0:present" "${PIN_RUN_RC}:$(hub_state oneshot.hit)" "the probe document may be pretty-printed and carry extra fields"

# Two different models asked for is an ambiguity, refused before the hub is asked.
hub_run_with json SQUAD_MODEL=model-alpha SQUAD_HUB_MODEL=stale-other STUB_CAP_JSON="$CAPABLE"
assert_eq "78:absent:absent" "${PIN_RUN_RC}:$(hub_state oneshot.hit):$(hub_state capabilities.argv)" \
  "an ambient SQUAD_HUB_MODEL that disagrees with the pinned model is refused without asking the hub"
assert_contains "$PIN_RUN_OUT" "SQUAD_HUB_MODEL='stale-other' disagrees" "the refusal names both the variable and its value"
assert_not_contains "$PIN_RUN_OUT" "SQUAD_HUB_URL" "the conflict refusal does not point at the hub URL/token configuration"

# The strict hub's refusal to confirm the model is the session's result.
hub_run_with json SQUAD_MODEL=model-unavailable STUB_CAP_JSON="$CAPABLE" STUB_AVAILABLE_MODELS=model-alpha
assert_eq "78" "$PIN_RUN_RC" "a hub whose agent did not confirm the required model (exit 78) ends the session with 78"
assert_contains "$PIN_RUN_OUT" "did not confirm the required model 'model-unavailable'" "the log says the required model was not confirmed"
assert_contains "$PIN_RUN_OUT" "No retry, no fallback model" "the log says there is no retry or fallback"
assert_eq "absent" "$(hub_state oneshot.prompt-sent)" "no prompt was sent on a model the agent did not confirm"
assert_eq "1" "$(wc -l < "${PIN_STUB_ROOT}/oneshot.count" | tr -d ' ')" "oneshot was attempted exactly once, with no retry"
hub_run_with json SQUAD_MODEL=model-alpha STUB_CAP_JSON="$CAPABLE" STUB_ONESHOT_EXIT=3
assert_eq "3" "$PIN_RUN_RC" "any other non-zero hub exit is still the session's exit status"

# Without a required model nothing changes: no probe, and whatever Hub model
# configuration the operator set is passed through exactly as it was.
hub_run_with old
assert_eq "0" "$PIN_RUN_RC" "an unpinned session is supervised by any hub build"
assert_eq "absent" "$(hub_state capabilities.argv)" "an unpinned session does not probe the hub's capabilities"
assert_eq "<unset>|<unset>" "$(hub_file oneshot.model)|$(hub_file oneshot.require)" "an unpinned session forwards no model and no requirement"
hub_run_with old SQUAD_HUB_MODEL=operator-choice
assert_eq "operator-choice|<unset>" "$(hub_file oneshot.model)|$(hub_file oneshot.require)" \
  "an unpinned session leaves the operator's own SQUAD_HUB_MODEL alone (it is not the repository's pin)"
assert_contains "$PIN_RUN_OUT" "AFTER model=operator-choice" "...and the caller's environment is untouched"

# An inconsistent or malformed requirement is refused before the hub is asked.
hub_run_with json SQUAD_MODEL_PINNED=1 STUB_CAP_JSON="$CAPABLE"
assert_eq "78:absent:absent" "${PIN_RUN_RC}:$(hub_state oneshot.hit):$(hub_state capabilities.argv)" \
  "SQUAD_MODEL_PINNED=1 with no SQUAD_MODEL is refused without asking the hub"
for bad_model in '-model-alpha' 'model alpha'; do
  hub_run_with json SQUAD_MODEL="$bad_model" STUB_CAP_JSON="$CAPABLE"
  assert_eq "78:absent:absent" "${PIN_RUN_RC}:$(hub_state oneshot.hit):$(hub_state capabilities.argv)" \
    "unusable model id [${bad_model}] is refused without asking the hub"
done
rm -rf "$PIN_STUB_ROOT"

report_pr_status() {
  env -u SQUAD_HUB_URL -u SQUAD_HUB_TOKEN \
    bash -c 'source "'"$HUB_LIB"'"; squad_hub_report_pr "$1" "$2" "$3" "$4" >/dev/null 2>&1; printf "%s" "$?"' \
    _ "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}
assert_eq "0" "$(report_pr_status https://github.com/octo/demo/pull/304 304 'Title' 'session-304')" \
  "PR reporting is a no-op when no hub is configured"

# `shell` mode (worker/entrypoint.sh) calls commit_and_push_if_needed directly,
# with NO earlier squad_hub_should_supervise/squad_hub_preflight check at all --
# so a half-configured hub (operator set one of SQUAD_HUB_URL/SQUAD_HUB_TOKEN,
# not both) is discovered for the first time at THIS call site, after the
# branch is already pushed and the pull request already open. This function
# must never escalate that into a session failure the way squad_hub_enabled's
# abort does for the supervision gate -- it must behave exactly like "hub not
# configured": skip quietly (one log line) and return success.
half_configured_report_pr_status() {
  env -u SQUAD_HUB_URL -u SQUAD_HUB_TOKEN "$@" \
    bash -c 'source "'"$HUB_LIB"'"; squad_hub_report_pr "https://github.com/octo/demo/pull/304" 304 Title session-304 >/dev/null 2>&1; printf "%s" "$?"'
}
assert_eq "0" "$(half_configured_report_pr_status SQUAD_HUB_URL=https://hub.example)" \
  "PR reporting does not abort the session when only SQUAD_HUB_URL is set (#136 review fix)"
assert_eq "0" "$(half_configured_report_pr_status SQUAD_HUB_TOKEN=sqhd1.x)" \
  "PR reporting does not abort the session when only SQUAD_HUB_TOKEN is set (#136 review fix)"

REPORT_STUB_ROOT="$(mktemp -d)"
REPORT_STUB_DIR="${REPORT_STUB_ROOT}/bin"
mkdir -p "$REPORT_STUB_DIR"

cat > "${REPORT_STUB_DIR}/squad-hub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --help)
    printf '%s\n' "${STUB_HELP_OUTPUT:-}"
    ;;
  report-pr)
    printf '%s\n' "$@" > "${STUB_ARGV_FILE}"
    printf '%s' "${SQUAD_HUB_DEVICE_ID:-}" > "${STUB_ARGV_FILE}.device"
    if [[ -n "${STUB_SENTINEL_FILE:-}" ]]; then
      : > "${STUB_SENTINEL_FILE}"
    fi
    exit "${STUB_REPORT_PR_EXIT_CODE:-0}"
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "${REPORT_STUB_DIR}/squad-hub"

REPORT_ARGS_FILE="${REPORT_STUB_ROOT}/report-pr.argv"
REPORT_SENTINEL_FILE="${REPORT_STUB_ROOT}/report-pr.hit"
SUCCESS_LOG="$(env \
  PATH="${REPORT_STUB_DIR}:$PATH" \
  STUB_HELP_OUTPUT='usage: squad-hub report-pr' \
  STUB_ARGV_FILE="$REPORT_ARGS_FILE" \
  SQUAD_HUB_URL='https://hub.example' \
  SQUAD_HUB_TOKEN='sqhd1.device-token' \
  CONTAINER_APP_JOB_EXECUTION_NAME='caj-squad-aca-session-ABC123' \
  bash -c 'source "'"$HUB_LIB"'"; squad_hub_report_pr "https://github.com/octo/demo/pull/304" "304" "Hub title"')"
SUCCESS_ARGS="$(paste -sd ' ' "$REPORT_ARGS_FILE")"
SUCCESS_DEVICE="$(cat "${REPORT_ARGS_FILE}.device")"
assert_contains "$SUCCESS_LOG" "Reported pull request #304 to the hub." \
  "PR reporting logs success when squad-hub report-pr succeeds"
assert_eq "report-pr --url https://github.com/octo/demo/pull/304 --number 304 --title Hub title" "$SUCCESS_ARGS" \
  "PR reporting passes url, number, and title (no --session: the hub targets this device's latest session)"
assert_eq "aca-caj-squad-aca-session-abc123" "$SUCCESS_DEVICE" \
  "PR reporting runs report-pr under the same aca- device id as the oneshot session"

rm -f "$REPORT_ARGS_FILE" "${REPORT_ARGS_FILE}.device" "$REPORT_SENTINEL_FILE"
SKIP_LOG="$(env \
  PATH="${REPORT_STUB_DIR}:$PATH" \
  STUB_HELP_OUTPUT='usage: squad-hub oneshot' \
  STUB_ARGV_FILE="$REPORT_ARGS_FILE" \
  STUB_SENTINEL_FILE="$REPORT_SENTINEL_FILE" \
  SQUAD_HUB_URL='https://hub.example' \
  SQUAD_HUB_TOKEN='sqhd1.device-token' \
  bash -c 'source "'"$HUB_LIB"'"; squad_hub_report_pr "https://github.com/octo/demo/pull/305" "305" "Skipped title" "session-305"; printf "|rc=%s" "$?"')"
assert_contains "$SKIP_LOG" "has no 'report-pr' verb yet" \
  "PR reporting logs a one-line skip when this image's squad-hub lacks report-pr"
assert_contains "$SKIP_LOG" "|rc=0" \
  "PR reporting still returns success when report-pr is unavailable"
assert_eq "0" "$([[ -f "$REPORT_SENTINEL_FILE" ]] && echo 1 || echo 0)" \
  "without the verb, PR reporting does not try to invoke report-pr"

rm -f "$REPORT_ARGS_FILE"
FAIL_LOG="$(env \
  PATH="${REPORT_STUB_DIR}:$PATH" \
  STUB_HELP_OUTPUT='usage: squad-hub report-pr' \
  STUB_ARGV_FILE="$REPORT_ARGS_FILE" \
  STUB_REPORT_PR_EXIT_CODE='9' \
  SQUAD_HUB_URL='https://hub.example' \
  SQUAD_HUB_TOKEN='sqhd1.device-token' \
  bash -c 'source "'"$HUB_LIB"'"; squad_hub_report_pr "https://github.com/octo/demo/pull/306" "306" "Failing title" "session-306"; printf "|rc=%s" "$?"')"
assert_contains "$FAIL_LOG" "Could not report pull request #306 to the hub" \
  "PR reporting logs a non-fatal failure when report-pr itself fails"
assert_contains "$FAIL_LOG" "|rc=0" \
  "a failed report-pr invocation never fails the session"
rm -rf "$REPORT_STUB_ROOT"

COMMIT_PUSH_FN="$(awk '/^commit_and_push_if_needed\(\) \{/,/^\}/' "$ENTRY")"
assert_contains "$ENTRYPOINT_SRC" "squad_hub_report_pr_if_any()" \
  "entrypoint.sh defines the PR-reporting wrapper next to the supervision helper"
assert_contains "$COMMIT_PUSH_FN" "squad_hub_report_pr_if_any" \
  "commit_and_push_if_needed reports the opened pull request through the wrapper"

echo ""
echo "squad-hub supervision: ${TESTS_RUN} assertions, ${TESTS_FAILED} failed"
exit $(( TESTS_FAILED > 0 ? 1 : 0 ))
