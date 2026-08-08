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

echo ""
echo "squad-hub supervision: ${TESTS_RUN} assertions, ${TESTS_FAILED} failed"
exit $(( TESTS_FAILED > 0 ? 1 : 0 ))
