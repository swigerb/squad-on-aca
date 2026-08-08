#!/usr/bin/env bash
# Supervise a session with Squad Hub, so a human can answer its approvals.
#
# WHY THIS EXISTS
# ---------------
# This worker runs its agent with `--allow-all-tools`, and it is right to. A
# container has no TTY and no approver, so a permission prompt would hang until
# the job's ceiling -- billing for hours to achieve nothing. Destructive
# operations are therefore made UNAVAILABLE rather than approval-gated, because
# an approval gate with no approver is a hang.
#
# Squad Hub removes the premise. It puts a human in front of an approval card
# from anywhere, including a phone. So a session supervised by a hub can afford
# to ASK.
#
# WHY THIS IS A TIGHTENING, NOT A RELAXATION
# ------------------------------------------
# The hub path drops `--allow-all-tools` and keeps everything else, deny
# patterns included. Measured against Copilot CLI 1.0.78 over ACP:
#
#   * a tool on the deny list raises NO permission request at all. It is
#     refused outright -- "denied by policy" -- so a person is never even
#     offered the chance to approve something this policy forbids. The deny
#     list resolved by agent-policy.js remains a hard floor that no human, on
#     any surface, can lift.
#   * a tool that is merely ungated DOES raise a request, carrying the literal
#     command. Those are the decisions a person now makes, and which previously
#     happened with nobody watching at all.
#
# So the set of things that run without human review SHRINKS. That is the whole
# case for the integration, and it is why the deny list is passed through
# untouched rather than being trimmed for the hub.
#
# WHAT IT REFUSES TO DO
# ---------------------
# It never falls back to the unsupervised path. An operator who configured a
# hub asked for a session a human is watching; quietly running it with blanket
# tool approval because the hub was unreachable would be the exact silent
# downgrade this repository refuses everywhere else.
#
# It also refuses a credential that is not a DEVICE token. A device token can
# be a device and nothing else -- it cannot read the hub's API, drive another
# device, or watch anyone's sessions. Shipping a personal token to a container
# instead would hand a job everything its owner can do.

SQUAD_HUB_EXIT_NO_APPROVER=75
SQUAD_HUB_EXIT_REFUSED=77
SQUAD_HUB_DEVICE_TOKEN_PREFIX="sqhd1."

squad_hub_log() {
  printf '[squad-hub] %s\n' "$*"
}

squad_hub_abort() {
  squad_hub_log "$@"
  squad_hub_log "Refusing to run the session. A session configured for hub supervision must not"
  squad_hub_log "silently fall back to running unsupervised with blanket tool approval."
  exit 78
}

# Configured means BOTH halves. A URL with no token cannot attach, and a token
# with no URL has nowhere to go; either alone is a misconfiguration rather than
# an opt-out, so it is reported instead of ignored.
squad_hub_enabled() {
  if [[ -z "${SQUAD_HUB_URL:-}" && -z "${SQUAD_HUB_TOKEN:-}" ]]; then
    return 1
  fi
  if [[ -z "${SQUAD_HUB_URL:-}" ]]; then
    squad_hub_abort "SQUAD_HUB_TOKEN is set but SQUAD_HUB_URL is not, so there is no hub to attach to."
  fi
  if [[ -z "${SQUAD_HUB_TOKEN:-}" ]]; then
    squad_hub_abort "SQUAD_HUB_URL is set but SQUAD_HUB_TOKEN is not, so this device cannot attach."
  fi
  return 0
}

# A device token is recognisable without doing any crypto: the hub mints them
# with a distinctive prefix precisely so a caller can route on sight. Checking
# it here turns "the wrong credential was shipped to a container" into a clear
# refusal at second two, rather than a 401 buried in a log at minute forty.
squad_hub_preflight() {
  if [[ "${SQUAD_HUB_TOKEN}" != "${SQUAD_HUB_DEVICE_TOKEN_PREFIX}"* ]]; then
    squad_hub_abort \
      "SQUAD_HUB_TOKEN does not look like a device token (expected the \"${SQUAD_HUB_DEVICE_TOKEN_PREFIX}\" prefix)." \
      "A device token is minted FOR a device and can be a device and nothing else." \
      "Mint one with: squad-hub device-token --hub <url> --token <your own token> --prefix aca-"
  fi
  if ! command -v squad-hub >/dev/null 2>&1; then
    squad_hub_abort "squad-hub is not installed in this image, so the session cannot be supervised."
  fi
  return 0
}

# The resolved policy, as JSON, for the hub's own argv channel.
#
# JSON because the patterns contain spaces -- `shell(git config)` -- and the
# hub's space-separated variable would tear them in half. Copilot then refuses
# to start ("Invalid rule format: shell(git"), so a mangled rule fails closed;
# it still means the session never runs, which is why the JSON channel exists.
squad_hub_policy_json() {
  local resolver="${SQUAD_POLICY_RESOLVER:-/usr/local/lib/squad-on-aca/agent-policy.js}"
  local json rc
  json="$(node "$resolver" hub-argv-json 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 || -z "$json" ]]; then
    squad_hub_abort "The policy resolver produced no hub argv (exit ${rc}): ${json}"
  fi
  if [[ "$json" == *'"--allow-all-tools"'* ]]; then
    # The one thing the hub variant exists to remove. If it survived, the
    # session would attach a human to a run that never asks them anything --
    # all of the cost and none of the benefit.
    squad_hub_abort "The hub policy still contains --allow-all-tools, so no approval would ever be raised."
  fi
  printf '%s' "$json"
}

# Run ONE supervised session and return its exit code.
#
# `squad-hub oneshot` is the hub's documented entry point for a job platform.
# Everything travels by environment because that is what a job platform can
# set, and the exit codes are the contract.
squad_hub_run() {
  local prompt="$1"
  local policy_json
  policy_json="$(squad_hub_policy_json)"

  squad_hub_log "Supervising this session with the hub at ${SQUAD_HUB_URL}."
  squad_hub_log "Tool policy: --allow-all-tools dropped, deny list intact."
  squad_hub_log "  A denied tool is still refused outright and is never offered to a human."
  squad_hub_log "  Anything else now asks, and waits for a person to answer."

  local rc=0
  SQUAD_HUB_ONESHOT=1 \
  SQUAD_HUB_PROMPT="$prompt" \
  SQUAD_HUB_CWD="$REPO_DIR" \
  SQUAD_HUB_AGENT_EXTRA_ARGS_JSON="$policy_json" \
    squad-hub oneshot || rc=$?

  case "$rc" in
    0)
      squad_hub_log "Supervised session completed."
      ;;
    "$SQUAD_HUB_EXIT_NO_APPROVER")
      squad_hub_log "The session asked for permission and no hub was connected, so nobody could answer."
      squad_hub_log "It was stopped rather than billed to the job timeout."
      squad_hub_log "Either make the hub reachable, or dispatch this run unattended."
      ;;
    "$SQUAD_HUB_EXIT_REFUSED")
      squad_hub_log "The hub refused this device. Retrying a policy refusal never succeeds."
      squad_hub_log "Check that the device token is current and that its prefix matches this job."
      ;;
    *)
      squad_hub_log "Supervised session failed (exit ${rc})."
      ;;
  esac
  return "$rc"
}
