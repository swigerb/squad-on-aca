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
#
# WATCH-ONLY (SQUAD_HUB_APPROVAL=auto)
# ------------------------------------
# Opt-in, per deployment. The session still attaches to the hub, so it is
# visible there and can be stopped from there, but nothing waits for a person:
#
#   * one-shot sessions keep `--allow-all-tools`, so Copilot raises no
#     permission request;
#   * watch/loop install every reporting hook EXCEPT `preToolUse`, the only
#     one that blocks the agent for an answer.
#
# The deny list is identical in both modes and stays a hard floor: a denied
# tool is refused outright whichever mode is set. What watch-only gives up is
# the human decision on UNGATED tools -- which is exactly what an operator who
# sets it is asking for, so it is announced in every session log, never
# implied. Any value other than `ask` (the default) or `auto` aborts.
SQUAD_HUB_APPROVAL="${SQUAD_HUB_APPROVAL:-ask}"

SQUAD_HUB_EXIT_NO_APPROVER=75
SQUAD_HUB_EXIT_REFUSED=77
SQUAD_HUB_DEVICE_TOKEN_PREFIX="sqhd1."

# The device id this job registers under.
#
# A device token may be minted with a device-id PREFIX binding, and the docs
# here tell an operator to use one (`--prefix aca-`) precisely so a credential
# shipped to a cloud job cannot claim to be someone's laptop. The hub enforces
# that binding at registration: a device id that does not start with the bound
# prefix is refused.
#
# So the id cannot be left to squad-hub's default. Its default is a hash of the
# app name -- stable, which is right for a long-lived replica, and hex, which
# can never begin with "aca-". Following the documented advice would have
# refused every session with exit 77.
#
# Per EXECUTION, not per app: two concurrent job executions are two separate
# ephemeral devices, and squad-hub is explicit that two attachments sharing one
# id fight over the same device slot.
SQUAD_HUB_DEVICE_ID_PREFIX="${SQUAD_HUB_DEVICE_ID_PREFIX:-aca-}"

# Compose the device id this execution registers under.
#
# ACA sets CONTAINER_APP_JOB_EXECUTION_NAME for a job and
# CONTAINER_APP_REPLICA_NAME for an app; the last fallback keeps this working
# in a plain container and in the test suite, where neither exists.
squad_hub_device_id() {
  local unique="${CONTAINER_APP_JOB_EXECUTION_NAME:-${CONTAINER_APP_REPLICA_NAME:-${HOSTNAME:-$$}}}"
  # Lowercased because the hub normalises the bound prefix to lower case and
  # then does a plain prefix test; a capital here would silently not match.
  printf '%s%s' "$SQUAD_HUB_DEVICE_ID_PREFIX" "$unique" | tr '[:upper:]' '[:lower:]'
}

# Cap a string before it ever leaves this container.
#
# The hub validates these fields too, but the worker owns NOT emitting an
# oversized value in the first place. Centralising the cap keeps the helpers
# below simple and makes the tests ask one question.
squad_hub_truncate() {
  local value="${1:-}" limit="${2:-200}"
  printf '%s' "${value:0:limit}"
}

# Derive the issue number attached to this session, if any.
#
# There is no dedicated SQUAD_ISSUE_NUMBER-style env var in the worker today.
# The two untrusted dispatchers that DO attach an issue both set the same
# visible OUTPUT_BRANCH / PR_TITLE shapes instead:
#   * .github/workflows/squad-dispatch.yml -> squad/issue-<n>, "Squad: issue #<n>"
#   * worker/lib/ralph-dispatch.sh        -> squad/issue-<n>, "Squad: issue #<n>"
# Parse the branch first (the stronger signal), then fall back to the title.
# new-project uses squad/bootstrap-<session>, which must not match.
squad_hub_issue_number() {
  if [[ "${OUTPUT_BRANCH:-}" =~ ^squad/issue-([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${PR_TITLE:-}" =~ \#([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# The hub shows a human-friendly device name beside the stable device id.
#
# When this session is attached to an issue, the name leads with that issue so a
# phone-sized screen still tells an approver WHICH work they are looking at.
# Without an issue, the session name is the next most specific label we have.
squad_hub_device_name() {
  local issue repo_short
  issue="$(squad_hub_issue_number || true)"
  if [[ -n "$issue" ]]; then
    repo_short="${GITHUB_REPOSITORY##*/}"
    squad_hub_truncate "#${issue} · ${repo_short}" 200
    return 0
  fi
  squad_hub_truncate "${SESSION_NAME:-squad-session}" 200
}

# Session metadata the hub can index without parsing a display name.
#
# String-only by contract: even the issue number is carried as a string, and an
# absent field is the empty string rather than null. Values are capped before the
# JSON leaves bash, so the worker's own size budget is enforced locally.
squad_hub_device_meta_json() {
  local issue repo execution_name job_name
  issue="$(squad_hub_issue_number || true)"
  repo="$(squad_hub_truncate "${GITHUB_REPOSITORY:-}" 200)"
  issue="$(squad_hub_truncate "$issue" 200)"
  execution_name="$(squad_hub_truncate "${CONTAINER_APP_JOB_EXECUTION_NAME:-}" 200)"
  job_name="$(squad_hub_truncate "${CONTAINER_APP_JOB_NAME:-}" 200)"
  SQUAD_HUB_META_REPO="$repo" \
  SQUAD_HUB_META_ISSUE="$issue" \
  SQUAD_HUB_META_EXECUTION_NAME="$execution_name" \
  SQUAD_HUB_META_JOB_NAME="$job_name" \
  node -e '
    process.stdout.write(JSON.stringify({
      repo: process.env.SQUAD_HUB_META_REPO || "",
      issue: process.env.SQUAD_HUB_META_ISSUE || "",
      executionName: process.env.SQUAD_HUB_META_EXECUTION_NAME || "",
      jobName: process.env.SQUAD_HUB_META_JOB_NAME || "",
    }));
  '
}

# Pin the id the squad-hub DAEMON registers under (issue #126).
#
# `squad_hub_run` hands the id to `squad-hub oneshot` through
# SQUAD_HUB_DEVICE_ID, which oneshot reads. The ambient path cannot: it goes
# through `squad-hub connect`, whose `--name` sets only the DISPLAY name. The
# daemon `connect` starts registers under its stable `config.deviceId`, and when
# that is unset squad-hub derives one -- sha1(hostname|user), 16 hex characters
# that can never begin with "aca-". `connect` validates the token with a probe
# whose id IS built from the token's prefix, so the probe passes and only the
# real attach is refused: "this token may not register that device id", on
# every watch cycle, for as long as the token was prefix-bound.
#
# squad-hub keeps `deviceId` across `connect` (it only patches server, token
# and name), so writing it into squad-hub's own config before connecting is
# enough. Same file squad-hub reads: SQUAD_HUB_HOME, else ~/.squad-hub.
squad_hub_seed_device_id() {
  local home="${SQUAD_HUB_HOME:-${HOME}/.squad-hub}"
  mkdir -p "$home" || return 1
  SQUAD_HUB_CONFIG_FILE="${home}/config.json" \
  SQUAD_HUB_SEED_DEVICE_ID="$(squad_hub_device_id)" \
  node -e '
    const fs = require("fs");
    const file = process.env.SQUAD_HUB_CONFIG_FILE;
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {
      if (e.code !== "ENOENT") { console.error(`unreadable ${file}: ${e.message}`); process.exit(1); }
    }
    if (!cfg || typeof cfg !== "object" || Array.isArray(cfg)) cfg = {};
    cfg.deviceId = process.env.SQUAD_HUB_SEED_DEVICE_ID;
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2));
  '
}

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
  squad_hub_approval_mode >/dev/null
  return 0
}

# `ask` (default) or `auto` (watch-only). Anything else is a typo in a security
# setting, and guessing which one was meant is how a session ends up less
# supervised than its operator believes -- so it aborts.
squad_hub_approval_mode() {
  case "${SQUAD_HUB_APPROVAL:-ask}" in
    ask|"") printf 'ask' ;;
    auto) printf 'auto' ;;
    *)
      squad_hub_abort \
        "SQUAD_HUB_APPROVAL='${SQUAD_HUB_APPROVAL}' is not a known approval mode." \
        "Use 'ask' (a person approves ungated tools) or 'auto' (watch-only: visible in the hub, nothing waits)."
      ;;
  esac
}

# Is this the watch-only mode? Decided in THIS shell, never in a `$(...)`
# subshell, so an invalid value aborts the session instead of only the subshell.
squad_hub_auto_approve() {
  case "${SQUAD_HUB_APPROVAL:-ask}" in
    auto) return 0 ;;
    ask|"") return 1 ;;
    *) squad_hub_approval_mode >/dev/null; return 1 ;;
  esac
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
  if squad_hub_auto_approve; then
    # Watch-only, asked for explicitly. Restore exactly the one flag the hub
    # variant removed, in the position the direct path uses, and nothing else:
    # every deny pattern in the resolver's output is carried over untouched.
    json="$(SQUAD_HUB_POLICY_JSON="$json" node -e '
      const argv = JSON.parse(process.env.SQUAD_HUB_POLICY_JSON);
      if (!Array.isArray(argv)) process.exit(2);
      process.stdout.write(JSON.stringify(["--allow-all-tools", ...argv]));
    ')" || squad_hub_abort "Could not build the watch-only hub argv."
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
  local policy_json device_name device_meta_json
  policy_json="$(squad_hub_policy_json)"
  device_name="${SQUAD_HUB_DEVICE_NAME:-$(squad_hub_device_name)}"
  device_name="$(squad_hub_truncate "$device_name" 200)"
  device_meta_json="$(squad_hub_device_meta_json)"

  squad_hub_log "Supervising this session with the hub at ${SQUAD_HUB_URL}."
  squad_hub_log "Registering as device $(squad_hub_device_id)."
  squad_hub_log "Reporting this session as \"${device_name}\"."
  if squad_hub_auto_approve; then
    squad_hub_log "Approval mode: auto (watch-only, SQUAD_HUB_APPROVAL=auto)."
    squad_hub_log "  The session is visible in the hub and can be stopped there; nothing waits for a person."
    squad_hub_log "  Tool policy: --allow-all-tools kept, deny list intact. A denied tool is still refused outright."
  else
    squad_hub_log "Tool policy: --allow-all-tools dropped, deny list intact."
    squad_hub_log "  A denied tool is still refused outright and is never offered to a human."
    squad_hub_log "  Anything else now asks, and waits for a person to answer."
  fi

  local rc=0
  # Same telemetry wiring as the unsupervised `copilot -p` path in entrypoint.sh.
  # squad-hub spawns `copilot --acp` with its own environment, so without these
  # the global default (COPILOT_OTEL_ENABLED=false, gRPC endpoint) wins and a
  # supervised session never reaches Aspire.
  OTEL_EXPORTER_OTLP_ENDPOINT="${ASPIRE_OTLP_HTTP_ENDPOINT:-$OTEL_EXPORTER_OTLP_ENDPOINT}" \
  COPILOT_OTEL_ENABLED=true \
  COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
  SQUAD_HUB_ONESHOT=1 \
  SQUAD_HUB_PROMPT="$prompt" \
  SQUAD_HUB_CWD="$REPO_DIR" \
  SQUAD_HUB_DEVICE_ID="$(squad_hub_device_id)" \
  SQUAD_HUB_DEVICE_NAME="$device_name" \
  SQUAD_HUB_DEVICE_META_JSON="$device_meta_json" \
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
      squad_hub_log "This job registers as \"$(squad_hub_device_id)\", so a token minted with"
      squad_hub_log "--prefix must use a prefix that id starts with (default \"aca-\")."
      ;;
    *)
      squad_hub_log "Supervised session failed (exit ${rc})."
      ;;
  esac
  return "$rc"
}

# Report the pull request this session opened, if this image knows how.
#
# The worker image pins squad-hub@0.6.0 until the hub's v0.7.0 rollout, so this
# must detect the new verb rather than assume it.
#
# Deliberately NOT squad_hub_enabled: that function `squad_hub_abort`s (exit 78)
# on a half-configuration, which is correct for the SUPERVISION gate -- a
# session that was asked to run supervised must never quietly run unsupervised
# instead. This call site is different. `shell` mode calls
# commit_and_push_if_needed with no earlier hub check at all (it never calls
# squad_hub_should_supervise/squad_hub_preflight), so a half-configured hub
# would otherwise be discovered for the FIRST time here -- after the branch is
# already pushed and the pull request already open -- and would abort a
# successful session over a reporting step the brief says must "never fail the
# session". So the check here is read-only: both halves present, or skip.
squad_hub_report_pr() {
  local url="$1" number="$2" title="${3:-}" session="${4:-${SESSION_NAME:-}}"
  if [[ -z "${SQUAD_HUB_URL:-}" || -z "${SQUAD_HUB_TOKEN:-}" ]]; then
    if [[ -n "${SQUAD_HUB_URL:-}" || -n "${SQUAD_HUB_TOKEN:-}" ]]; then
      squad_hub_log "Hub half-configured (one of SQUAD_HUB_URL/SQUAD_HUB_TOKEN is unset); skipping PR reporting rather than failing an already-published session over it."
    fi
    return 0
  fi
  if [[ -z "$url" || -z "$number" ]]; then
    squad_hub_log "No pull request to report to the hub."
    return 0
  fi
  if ! command -v squad-hub >/dev/null 2>&1 || ! squad-hub --help 2>&1 | grep -q 'report-pr'; then
    squad_hub_log "This image's squad-hub has no 'report-pr' verb yet (needs squad-hub >= 0.7.0); skipping PR reporting to the hub."
    return 0
  fi

  local args=(report-pr --url "$url" --number "$number")
  [[ -n "$title" ]] && args+=(--title "$title")
  [[ -n "$session" ]] && args+=(--session "$session")

  if squad-hub "${args[@]}" >/dev/null 2>&1; then
    squad_hub_log "Reported pull request #${number} to the hub."
  else
    squad_hub_log "Could not report pull request #${number} to the hub (non-fatal; the PR is already open)."
  fi
  return 0
}

# --- ambient supervision, for the modes that own their own loop ---------------
#
# `squad_hub_run` above supervises ONE session, which is what `prompt` and
# `new-project` need. `watch`, `loop` and `ralph` are different: the `squad` CLI
# owns the loop and spawns Copilot itself, many times, so there is no single
# session to wrap and no seam to wrap it at.
#
# That gap is why a hub could be configured, valid and reachable and still show
# nothing at all for the modes doing the actual work.
#
# The seam that does exist is Copilot's own hooks. They are user-level, so they
# fire for EVERY Copilot session on the machine, whoever spawned it -- verified
# against Copilot CLI 1.0.79 by spawning a session from an unrelated parent
# process and watching it register itself. So instead of wrapping the loop, the
# container attaches once as a device and lets each session the loop starts
# report itself.
#
# Requires squad-hub >= 0.4.1, which is where `hooks` arrived.

# Is ambient supervision actually available in this image?
#
# Asked rather than assumed, because the image can legitimately be built with
# SQUAD_HUB_SPEC=none, or pinned to a version that predates `hooks`. A missing
# verb must read as "this image cannot do it" rather than as a crash.
squad_hub_has_hooks() {
  command -v squad-hub >/dev/null 2>&1 \
    && squad-hub --help 2>&1 | grep -q 'squad-hub hooks'
}

# Attach this container to the hub, and make every Copilot session it starts
# report itself.
#
# Fails loudly. A mode that was told to supervise and then quietly did not is
# the whole defect this exists to close: the operator sets a URL and a token,
# sees no error, and reasonably concludes the work is supervised.
squad_hub_supervise_ambient() {
  squad_hub_preflight

  if ! squad_hub_has_hooks; then
    squad_hub_abort \
      "This image's squad-hub has no 'hooks' verb, so ${SQUAD_MODE:-this mode} cannot be supervised." \
      "Ambient supervision needs squad-hub >= 0.4.1." \
      "Rebuild with --build-arg SQUAD_HUB_SPEC=squad-hub@0.4.1 (or later), or unset SQUAD_HUB_URL/SQUAD_HUB_TOKEN to run unattended on purpose."
  fi

  squad_hub_log "Supervising this container with the hub at ${SQUAD_HUB_URL}."
  squad_hub_log "Attaching as device $(squad_hub_device_id)."

  if ! squad_hub_seed_device_id; then
    squad_hub_abort \
      "Could not set the squad-hub device id to $(squad_hub_device_id)." \
      "Without it the daemon registers under a hex id that an aca- bound token refuses."
  fi

  # `connect`, not `start`. Two reasons, both found by reading the CLI rather
  # than assuming:
  #
  #   * `start` accepts no --name, so the device would appear under the
  #     container's hostname -- a random ACA replica id nobody can identify.
  #   * `start` returns 0 even when the hub REFUSES the attach; it prints
  #     "(NOT connected)" and exits successfully. An abort keyed on its exit
  #     code would therefore never fire, and the mode would run unsupervised
  #     while reporting that it was supervised -- the exact defect this
  #     replaces, reintroduced one layer down.
  #
  # `connect` validates the token, attaches, and returns non-zero when the hub
  # refuses. It starts the daemon itself.
  if ! squad-hub connect \
        --hub "$SQUAD_HUB_URL" \
        --token "$SQUAD_HUB_TOKEN" \
        --name "$(squad_hub_device_id)"; then
    squad_hub_abort \
      "Could not attach to the hub at ${SQUAD_HUB_URL} as $(squad_hub_device_id)." \
      "A device that cannot attach cannot be supervised, and this mode was asked to be." \
      "Check the device token is current, and that its --prefix matches this device id."
  fi

  # Installed AFTER the daemon is up, so the first session cannot fire a hook
  # into nothing. squad-hub 0.4.1+ leaves an unsupervised session alone when the
  # daemon is unreachable, so this does not degrade unrelated work in the image.
  if ! squad-hub hooks install --force; then
    squad_hub_abort "Could not install the Copilot hooks, so sessions this mode starts would not be visible."
  fi

  if squad_hub_auto_approve; then
    if ! squad_hub_hooks_observe_only; then
      squad_hub_abort \
        "Could not make the installed hooks watch-only, so sessions would still wait for approval." \
        "Use SQUAD_HUB_APPROVAL=ask, or check the squad-hub hook file format for this image's squad-hub."
    fi
    squad_hub_log "Approval mode: auto (watch-only, SQUAD_HUB_APPROVAL=auto)."
    squad_hub_log "Every Copilot session started here will register itself and report what it is doing."
    squad_hub_log "Nothing waits for a person; the deny list still refuses forbidden tools outright."
    return 0
  fi

  squad_hub_log "Every Copilot session started here will register itself, report what it is doing,"
  squad_hub_log "and ask before it acts. An approval nobody answers is refused, never granted."
  return 0
}

# Watch-only for the ambient path: drop the ONE hook that blocks for an answer.
#
# Watch/loop agents run with `--allow-all-tools`; squad-hub's `preToolUse` hook
# is what turns each tool call into an approval card (its "ask" overrides
# allow-all). Every other hook only REPORTS -- registration, prompts, tool
# results, turn ends -- and is what keeps the session visible. Removing exactly
# `preToolUse` therefore keeps the visibility and removes the wait.
#
# Edits squad-hub's own file in Copilot's hooks dir (COPILOT_HOME, else
# ~/.copilot, the same resolution squad-hub uses), and refuses any shape it does
# not recognise rather than guessing: an unexpected format must not leave a
# session believed watch-only that still blocks, or the reverse.
squad_hub_hooks_observe_only() {
  local file="${COPILOT_HOME:-${HOME}/.copilot}/hooks/squad-hub.json"
  SQUAD_HUB_HOOK_FILE="$file" node -e '
    const fs = require("fs");
    const file = process.env.SQUAD_HUB_HOOK_FILE;
    let cfg;
    try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {
      console.error(`cannot read ${file}: ${e.message}`); process.exit(1);
    }
    const hooks = cfg && cfg.hooks;
    if (!cfg || cfg.version !== 1 || !hooks || typeof hooks !== "object" || !hooks.sessionStart) {
      console.error(`${file} is not a squad-hub v1 hook file`); process.exit(1);
    }
    delete hooks.preToolUse;
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2));
    const check = JSON.parse(fs.readFileSync(file, "utf8"));
    if (check.hooks.preToolUse || !check.hooks.sessionStart) process.exit(1);
  '
}

# Detach, on the way out.
#
# Best effort by design: the work is already finished by the time this runs, and
# a failure to tidy up must not turn a successful session into a failed one.
squad_hub_release_ambient() {
  command -v squad-hub >/dev/null 2>&1 || return 0
  squad-hub hooks remove >/dev/null 2>&1 || true
  squad-hub stop >/dev/null 2>&1 || true
  return 0
}
