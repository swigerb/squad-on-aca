#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[squad-on-aca] %s\n' "$*"
}

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log "Missing required environment variable: ${name}"
    exit 64
  fi
}

sanitize_name() {
  printf '%s' "${1:-session}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed -E 's/^-+|-+$//g' | cut -c 1-48
}

# Re-review N1 (the uid boundary). Runs AS ROOT, inside the privilege-drop
# block below, immediately before `runuser`: creates the root-owned 0711
# policy state directory and the root sealer that alone writes into it (see
# section 4c of worker/lib/squad-policy.sh). Everything after the drop --
# including the agent -- runs as a uid that cannot create, rewrite, rename or
# delete anything there. A container started as root that cannot set this up
# refuses to start rather than silently running without the boundary.
squad_root_seal_policy_state() {
  local lib="${SQUAD_POLICY_LIB:-/usr/local/lib/squad-on-aca/squad-policy.sh}"
  if [[ ! -f "$lib" ]]; then
    log "Agent policy library not found at ${lib}; cannot create the root-owned policy state store. Refusing to start."
    exit 78
  fi
  # shellcheck source=lib/squad-policy.sh
  source "$lib"
  if ! squad_policy_sealer_start "${SQUAD_POLICY_SEAL_BASE:-/run}"; then
    log "Could not create the root-owned policy state store under ${SQUAD_POLICY_SEAL_BASE:-/run}. Refusing to start without the governance uid boundary."
    exit 78
  fi
}

# PC-2 (issue #86): a second boundary, now required rather than optional.
#
# PC-1's live ACA diagnostic (docs/security-report.md; the exact deployed
# platform this image runs on) measured this platform's same-uid
# /proc/<pid>/environ read as POSSIBLE: same-uid-environ-readable=yes,
# hidepid=0. That means the identity-drop ordering below
# (squad_drop_azure_identity) is no longer the ONLY control standing between
# a session and the Azure identity -- on THIS platform, a same-uid neighbour
# really can read another process's environment out of /proc.
#
# Only `ralph` mode ever holds the identity (it is the only mode that runs
# `az login --identity`, a few dozen lines below); every OTHER mode runs an
# agent that executes attacker-influenced input -- an issue body, a comment, a
# file in the repository -- through Copilot. A Linux ptrace/DAC check gates
# every /proc/<pid>/environ read on a REAL UID match (or CAP_SYS_PTRACE),
# independent of hidepid, so giving ralph's process a UID that is never the
# same as the UID any agent-running mode uses closes the exact gap PC-1
# found -- a control that does not depend on ordering at all.
#
# This is the FIRST executable action in this script, before anything else
# -- including HOME, credentials, and every mode-specific branch below --
# runs. The image's container-default user is root (worker/Dockerfile has no
# trailing USER) SOLELY so this one `exec` can drop to the correct
# unprivileged user before a single credential, child process, or byte of
# user-influenced input is touched. `exec runuser` replaces THIS shell, but
# runuser itself forks: it stays alive as a ROOT parent that waits for the
# dropped child and relays its exit status (util-linux; verified: `runuser -u
# nobody -- sleep 3` shows a root `runuser` pid with the `nobody` child under
# it). That root parent runs no script code and reads no input. The only other
# root process is the policy sealer started just before the drop (re-review
# N1), which reads one pipe and writes only into its own root-owned directory.
# If the container is ever started as a non-root user directly (e.g. a
# developer running this script locally), `id -u` is already non-zero and
# this block is a no-op: nothing below depends on having been root.
#
# Issue #134: the session deadline (worker/lib/squad-deadline.sh) is measured
# from container start, so on the root path the instant is taken inside this
# block, before the re-exec, and carried across it by `runuser -p`. It is set
# unconditionally there, so a SQUAD_SESSION_START_EPOCH arriving in the
# dispatcher's environment can never move the deadline. (Kept to one line in
# the block: test_uid_separation.sh reads the drop from a fixed window.)
if [[ "$(id -u)" -eq 0 ]]; then
  export SQUAD_SESSION_START_EPOCH="$EPOCHSECONDS"
  SQUAD_RUNTIME_USER="squad"
  if [[ "${SQUAD_MODE:-smoke}" == "ralph" ]]; then
    SQUAD_RUNTIME_USER="squad-identity"
  fi
  squad_root_seal_policy_state
  # `-p` keeps every ACA-injected variable (and SQUAD_POLICY_SEAL_FD /
  # SQUAD_POLICY_SEALED_DIR) across the switch, but would also carry root's
  # HOME (/root) into a process that cannot write there. `env -u HOME` clears
  # it so the fallback below resolves HOME from the user this process becomes.
  exec env -u HOME runuser -p -u "$SQUAD_RUNTIME_USER" -- "$0" "$@"
fi

# A container never started as root (a developer running this script locally)
# records its start here instead.
export SQUAD_SESSION_START_EPOCH="${SQUAD_SESSION_START_EPOCH:-$EPOCHSECONDS}"

# The fallback is resolved from THIS process's actual user, never hard-coded
# to /home/squad -- after the PC-2 drop above, a ralph-mode process is
# squad-identity, whose home is /home/squad-identity, and a hard-coded
# /home/squad here would leave it writing outside its own, exclusively-owned
# directory.
export HOME="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
export COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh}"
export ASPIRE_OTLP_GRPC_ENDPOINT="${ASPIRE_OTLP_GRPC_ENDPOINT:-http://ca-squad-aspire:18889}"
export ASPIRE_OTLP_HTTP_ENDPOINT="${ASPIRE_OTLP_HTTP_ENDPOINT:-http://ca-squad-aspire:18890}"
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-$ASPIRE_OTLP_GRPC_ENDPOINT}"
export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-squad-$(sanitize_name "${SESSION_NAME:-remote}")}"
export COPILOT_OTEL_ENABLED="${COPILOT_OTEL_ENABLED:-false}"
export OTEL_METRIC_EXPORT_INTERVAL_MILLIS="${OTEL_METRIC_EXPORT_INTERVAL_MILLIS:-5000}"

if [[ -n "${GITHUB_TOKEN:-}" && -z "${GH_TOKEN:-}" ]]; then
  export GH_TOKEN="$GITHUB_TOKEN"
fi
# Issue #84 follow-up (Security blocker): record WHERE COPILOT_GITHUB_TOKEN
# came from at the moment it is established, rather than leaving every later
# consumer to infer it from a value comparison against GH_TOKEN. A value
# comparison alone cannot distinguish "the operator supplied a distinct
# Copilot credential that happens to equal the git token" from "this was
# defaulted from GH_TOKEN" -- and worker/lib/squad-credentials.sh's
# withholding needs the ACTUAL current value to decide what to hide, while a
# gate deciding whether to require a distinct credential wants to know the
# provenance too. Both are recorded; neither is inferred from the other later
# only.
#   explicit  the caller supplied COPILOT_GITHUB_TOKEN itself.
#   derived   no COPILOT_GITHUB_TOKEN was supplied, so it was defaulted from
#             GH_TOKEN -- this is the documented default deployment shape
#             (docs/security-report.md) and is shared with the git token BY
#             CONSTRUCTION.
#   none      neither was set; this session has no Copilot credential at all.
SQUAD_COPILOT_TOKEN_PROVENANCE="none"
if [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]]; then
  export COPILOT_GITHUB_TOKEN
  SQUAD_COPILOT_TOKEN_PROVENANCE="explicit"
elif [[ -n "${GH_TOKEN:-}" ]]; then
  export COPILOT_GITHUB_TOKEN="$GH_TOKEN"
  SQUAD_COPILOT_TOKEN_PROVENANCE="derived"
fi
export SQUAD_COPILOT_TOKEN_PROVENANCE

require GITHUB_REPOSITORY

SESSION_NAME="$(sanitize_name "${SESSION_NAME:-$(date +%Y%m%d-%H%M%S)}")"
SQUAD_POD_ID="$(sanitize_name "${SQUAD_POD_ID:-${CONTAINER_APP_JOB_EXECUTION_NAME:-${CONTAINER_APP_REPLICA_NAME:-$SESSION_NAME}}}")"
export SQUAD_DEPLOYMENT_MODE="${SQUAD_DEPLOYMENT_MODE:-squad-per-pod}"
export SQUAD_POD_ID
REPO_DIR="${WORKDIR:-/workspace}/${SESSION_NAME}/repo"
mkdir -p "$(dirname "$REPO_DIR")"

log "Node: $(node --version)"
log "Squad: $(squad version)"
log "Copilot: $(copilot --version | head -n 1)"
log "GitHub repository: ${GITHUB_REPOSITORY}"
log "Session: ${SESSION_NAME}"
log "Squad deployment mode: ${SQUAD_DEPLOYMENT_MODE}"
log "Squad pod ID: ${SQUAD_POD_ID}"
# The mode the rest of this script dispatches on. Exported so the shared policy
# resolver sees exactly the mode that runs, rather than having to guess a default
# for an unset variable — guessing an attended default is the fail-open shape
# this change removes (issue #26).
export SQUAD_MODE="${SQUAD_MODE:-smoke}"
log "Mode: ${SQUAD_MODE}"
log "Squad OTLP endpoint: ${ASPIRE_OTLP_GRPC_ENDPOINT}"
log "Copilot OTLP endpoint: ${ASPIRE_OTLP_HTTP_ENDPOINT}"

# --- Credentials (issue #32) -------------------------------------------------
# The token used to be baked into git config ONCE, at session start:
#
#   git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf ...
#
# The whole agent run sits between that line and the push in
# commit_and_push_if_needed. With a long-lived PAT that is harmless; with a
# GitHub App installation token, whose TTL is a hard 1 hour, it is a live
# failure mode -- and the LATEST possible one. Measured: a clone with an expired
# token succeeds (exit 0, no warning, because the repository is public), and the
# push then fails with exit 128 "Invalid username or token" after the entire run
# is spent.
#
# The rewrite is replaced by a credential helper that re-reads a 0600 token FILE
# on every git operation, so a refreshed file is picked up with no re-clone and
# no git config rewrite. Everything to do with that lives in
# worker/lib/squad-credentials.sh.
SQUAD_CREDENTIALS_LIB="${SQUAD_CREDENTIALS_LIB:-/usr/local/lib/squad-on-aca/squad-credentials.sh}"
if [[ ! -f "$SQUAD_CREDENTIALS_LIB" ]]; then
  log "Credential library not found at ${SQUAD_CREDENTIALS_LIB}."
  log "Without it the worker cannot install the credential helper, so a token refreshed mid-session could never be picked up and a long run would fail at the push. Refusing to start."
  exit 78
fi
# shellcheck source=lib/squad-credentials.sh
source "$SQUAD_CREDENTIALS_LIB"

SQUAD_PUSH_LIB="${SQUAD_PUSH_LIB:-/usr/local/lib/squad-on-aca/squad-push.sh}"
if [[ ! -f "$SQUAD_PUSH_LIB" ]]; then
  log "Push library not found at ${SQUAD_PUSH_LIB}."
  log "Without it the worker would push without classifying a credential failure, so an expired token would end the run as an anonymous non-zero after the whole agent run is spent. Refusing to start."
  exit 78
fi
# shellcheck source=lib/squad-push.sh
source "$SQUAD_PUSH_LIB"

# Issue #115: forwards SIGTERM/SIGINT from this script to the backgrounded
# `squad watch`/`squad loop` child so Squad can drain instead of being killed
# abruptly when ACA stops this replica. See worker/lib/squad-signal-forwarding.sh.
SQUAD_SIGNAL_FORWARDING_LIB="${SQUAD_SIGNAL_FORWARDING_LIB:-/usr/local/lib/squad-on-aca/squad-signal-forwarding.sh}"
if [[ ! -f "$SQUAD_SIGNAL_FORWARDING_LIB" ]]; then
  log "Signal forwarding library not found at ${SQUAD_SIGNAL_FORWARDING_LIB}."
  log "Without it watch/loop would run as this script's foreground child, which never receives a forwarded SIGTERM, so ACA stopping this replica would kill Squad mid-turn instead of letting it drain. Refusing to start."
  exit 78
fi
# shellcheck source=lib/squad-signal-forwarding.sh
source "$SQUAD_SIGNAL_FORWARDING_LIB"

# Issue #134: the session deadline and the watchdog `prompt` / `new-project`
# run their agent under, so a session still working when the replica timeout
# approaches publishes its work as a draft WIP pull request instead of losing
# it. See worker/lib/squad-deadline.sh.
SQUAD_DEADLINE_LIB="${SQUAD_DEADLINE_LIB:-/usr/local/lib/squad-on-aca/squad-deadline.sh}"
if [[ ! -f "$SQUAD_DEADLINE_LIB" ]]; then
  log "Session deadline library not found at ${SQUAD_DEADLINE_LIB}."
  log "Without it a prompt or new-project session would run with no deadline, and an agent still working when ACA kills the replica would lose all of its work unpublished. Refusing to start."
  exit 78
fi
# shellcheck source=lib/squad-deadline.sh
source "$SQUAD_DEADLINE_LIB"

# PC-1 (issue #86): the process-isolation probe. Sourced (not executed) so its
# functions are available to call after the identity drop, below. A missing
# probe library never blocks a session -- unlike the credential/push libraries
# above, this is defence-in-depth diagnostics, not something a session's
# correctness depends on.
SQUAD_PROC_ISO_LIB="${SQUAD_PROC_ISO_LIB:-/usr/local/lib/squad-on-aca/proc-isolation-probe.sh}"
if [[ -f "$SQUAD_PROC_ISO_LIB" ]]; then
  # shellcheck source=lib/proc-isolation-probe.sh
  source "$SQUAD_PROC_ISO_LIB"
else
  log "Process-isolation probe library not found at ${SQUAD_PROC_ISO_LIB}; skipping (PC-1, issue #86)."
fi

if [[ -n "${GH_TOKEN:-}" ]]; then
  squad_credential_write_token "$GH_TOKEN"
fi
squad_credential_install_helper

git config --global user.name "${GIT_AUTHOR_NAME:-Remote Squad}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-squad-on-aca@users.noreply.github.com}"
git config --global --add safe.directory "$REPO_DIR" || true

rm -rf "$REPO_DIR"
git clone --depth "${GIT_CLONE_DEPTH:-1}" "https://github.com/${GITHUB_REPOSITORY}.git" "$REPO_DIR"
cd "$REPO_DIR"

if [[ -n "${GITHUB_REF:-}" ]]; then
  GIT_CHECKOUT_LIB="${GIT_CHECKOUT_LIB:-/usr/local/lib/squad-on-aca/git-checkout.sh}"
  if [[ -f "$GIT_CHECKOUT_LIB" ]]; then
    # shellcheck source=lib/git-checkout.sh
    source "$GIT_CHECKOUT_LIB"
    checkout_github_ref "${GITHUB_REF}"
  else
    log "Git checkout helper not found at ${GIT_CHECKOUT_LIB}; falling back to inline checkout."
    git fetch --depth "${GIT_CLONE_DEPTH:-1}" origin "${GITHUB_REF}" || true
    git checkout "${GITHUB_REF}" || git checkout -B "${GITHUB_REF}" "origin/${GITHUB_REF}"
  fi
fi

# What HEAD was before anyone worked in this checkout. Commits the agent makes
# itself are measured against this when deciding whether there is anything to
# publish (see squad_session_has_publishable_work).
SQUAD_SESSION_BASE_COMMIT="$(git rev-parse --verify --quiet HEAD 2>/dev/null || true)"

# --- Externalized Squad state gate (issue #117) ------------------------------
# squad-aca clones this repo into THIS ephemeral container, hardens `.squad/`
# in THIS checkout, then commits and pushes from THIS checkout. Squad 0.13
# supports two layouts where the real mutable state is NOT in the repo's own
# `.squad/`:
#   - `stateLocation: "external"` (written by `squad externalize`): state
#     moves to a per-user app-data directory outside the repo entirely.
#   - a `teamRoot` other than `.` (written by `squad init --mode remote`):
#     state lives in another `.squad/`, resolved relative to the project root.
# In a fresh container neither of those directories exists (or if it did, it
# would not belong to this checkout), so a session would either start without
# the real team, or `squad init` would silently fabricate a NEW local team
# that masks the problem. Worse, the governance hardening below targets
# `${REPO_DIR}/.squad/...` paths that would not hold the real state at all --
# the lock and the audit trail would be silently meaningless. Called AFTER
# the repo is cloned/checked out (so it reads the config this session
# actually targets) and BEFORE `squad init`, the health gate, or policy
# hardening -- all of which assume local state and must never run against an
# unsupported layout.
#
# Mirrors Squad's OWN config.json validation (verified against the published
# @bradygaster/squad-sdk@0.13.1 package's dist/resolution.js: loadDirConfig()
# only recognizes a config.json that has BOTH a numeric `version` and a
# string `teamRoot` -- anything else, including no .squad/config.json at all,
# resolves to ordinary local state exactly like Squad itself would resolve
# it). Uses `node`, not grep, for the same reason the rest of this script
# does: grepping for `stateLocation`/`teamRoot` would false-positive on those
# strings appearing in comments or unrelated string values.
squad_external_state_gate() {
  local config_path="${REPO_DIR}/.squad/config.json"
  [[ -f "$config_path" ]] || return 0

  local reason
  reason="$(SQUAD_EXTERNAL_STATE_CONFIG_PATH="$config_path" node -e '
    const fs = require("fs");
    let parsed;
    try {
      parsed = JSON.parse(fs.readFileSync(process.env.SQUAD_EXTERNAL_STATE_CONFIG_PATH, "utf8"));
    } catch {
      process.exit(0);
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      process.exit(0);
    }
    const hasVersion = typeof parsed.version === "number";
    const hasTeamRoot = typeof parsed.teamRoot === "string";
    if (!hasVersion || !hasTeamRoot) {
      // Not a config.json Squad itself would recognize; treat as local state.
      process.exit(0);
    }
    if (parsed.stateLocation === "external") {
      process.stdout.write("external\tstateLocation is \u0027external\u0027 (state was moved out of the repo by \u0027squad externalize\u0027, into a per-user app-data directory outside this checkout)");
      process.exit(0);
    }
    if (parsed.teamRoot !== ".") {
      process.stdout.write("remote-teamRoot\tteamRoot is \u0027" + parsed.teamRoot + "\u0027, not \u0027.\u0027 (a satellite/remote team root outside this checkout)");
      process.exit(0);
    }
  ' 2>/dev/null)" || reason=""
  [[ -n "$reason" ]] || return 0

  local detail="${reason#*$'\t'}"
  log "Externalized Squad state detected: ${detail}."
  log "squad-aca only clones, hardens, and commits/pushes THIS checkout's .squad/ -- if the real Squad state lives elsewhere, the governance lock and audit trail would protect a directory that does not hold it, and writes here would not reach the real state. Run 'squad internalize' (or point teamRoot back at '.') before dispatching to ACA. Refusing to start."
  exit 78
}

squad_external_state_gate

CAPABILITY_PREFLIGHT_SCRIPT="/usr/local/lib/squad-on-aca/squad-capability-preflight.sh"
CAPABILITY_MANIFEST_RELATIVE="${CAPABILITY_MANIFEST_PATH:-squad-capabilities.yml}"
capability_preflight_disabled=false
case "${SQUAD_CAPABILITY_PREFLIGHT:-}" in
  disabled|disable|off|false|0) capability_preflight_disabled=true ;;
esac
if [[ "${SKIP_CAPABILITY_PREFLIGHT:-false}" == "true" ]]; then
  capability_preflight_disabled=true
fi
if [[ -x "$CAPABILITY_PREFLIGHT_SCRIPT" ]]; then
  "$CAPABILITY_PREFLIGHT_SCRIPT" "$REPO_DIR"
elif [[ "$capability_preflight_disabled" == "true" ]]; then
  log "Capability preflight script not found at ${CAPABILITY_PREFLIGHT_SCRIPT}; preflight explicitly disabled, continuing."
elif [[ -f "${REPO_DIR}/${CAPABILITY_MANIFEST_RELATIVE}" ]]; then
  log "Capability preflight script missing at ${CAPABILITY_PREFLIGHT_SCRIPT} but this repository declares a capability manifest (${CAPABILITY_MANIFEST_RELATIVE}); failing closed so unsupported requirements are not silently ignored."
  log "Set SQUAD_CAPABILITY_PREFLIGHT=disabled (or SKIP_CAPABILITY_PREFLIGHT=true) to override at your own risk."
  exit 78
else
  log "Capability preflight script not found at ${CAPABILITY_PREFLIGHT_SCRIPT} and no manifest present; skipping."
fi

# --- Token preflight (issue #32) ---------------------------------------------
# Fail at minute 2, not minute 55. The clone above succeeds with an EXPIRED
# token when the repository is public, so nothing so far has proved the
# credential can do the one thing the session ends with. This gate exercises it
# and compares its remaining lifetime against the estimated run duration. It
# runs BEFORE anything that starts an agent, and after the clone so it can
# report against the repository this session actually targets.
TOKEN_PREFLIGHT_SCRIPT="${TOKEN_PREFLIGHT_SCRIPT:-/usr/local/lib/squad-on-aca/squad-token-preflight.sh}"
token_preflight_disabled=false
case "${SQUAD_TOKEN_PREFLIGHT:-}" in
  disabled|disable|off|false|0) token_preflight_disabled=true ;;
esac
if [[ "${SKIP_TOKEN_PREFLIGHT:-false}" == "true" ]]; then
  token_preflight_disabled=true
fi
if [[ -x "$TOKEN_PREFLIGHT_SCRIPT" ]]; then
  "$TOKEN_PREFLIGHT_SCRIPT"
elif [[ "$token_preflight_disabled" == "true" ]]; then
  log "Token preflight script not found at ${TOKEN_PREFLIGHT_SCRIPT}; preflight explicitly disabled, continuing."
elif [[ "${PUSH_CHANGES:-false}" == "true" ]]; then
  log "Token preflight script missing at ${TOKEN_PREFLIGHT_SCRIPT} but this session intends to PUSH; failing closed rather than discovering an unusable credential after the whole agent run."
  log "Set SQUAD_TOKEN_PREFLIGHT=disabled (or SKIP_TOKEN_PREFLIGHT=true) to override at your own risk."
  exit 78
else
  log "Token preflight script not found at ${TOKEN_PREFLIGHT_SCRIPT} and this session does not push; skipping."
fi

if [[ ! -f ".squad/team.md" ]]; then
  log "No .squad/team.md found; initializing a default Squad in the ephemeral workspace."
  squad init --preset "${SQUAD_PRESET:-default}" --no-workflows
fi

if [[ -n "${SQUAD_TEAM:-}" ]]; then
  log "Activating SubSquad: ${SQUAD_TEAM}"
  squad subsquads activate "$SQUAD_TEAM" || true
fi

# --- Session health gate (issue #116) ----------------------------------------
# Squad 0.13 ships `squad health --json` (schema `squad-health/v1`): checks
# team, registry-charters, routing, state-backend, and env-vars, and is built
# for "gate dispatch on readiness" (verified against the published
# @bradygaster/squad-cli@0.13.1 package's dist/cli/commands/health.js --
# overall `status` is `pass`/`fail` only, no `warn`; each check's own
# `status` is `pass`/`fail`/`skip`; failing check ids live at
# `.checks[].id`). Gating here -- AFTER `squad init`/SubSquad activation
# finishes writing the governance state those checks read, and BEFORE
# squad_policy_harden -- means a session whose Squad state is already broken
# fails before it ever hardens policy or runs an agent against repository
# content, instead of surfacing as an obscure mid-run failure.
#
# Only the modes that actually run an agent pay for this: a one-shot
# `copilot -p` (prompt, new-project) or a mode that owns its own
# dispatch loop and spawns Copilot itself (loop, watch, triage). smoke,
# telemetry-smoke, ralph, and shell never dispatch an agent against
# repository content, so gating them would add a check with nothing at
# stake.
squad_health_gate_applies_to_mode() {
  case "$1" in
    prompt|new-project|loop|watch|triage) return 0 ;;
    *) return 1 ;;
  esac
}

# Degrades honestly rather than failing unsafe in either direction: an older
# Squad CLI that predates `squad health --json` (missing command/flag, or
# output this parser cannot read as a `squad-health/v1` report) reports
# UNAVAILABLE -- never silently treated as a pass, and never a hard failure
# either, since a session on an older CLI still has to keep working. Only a
# genuine, successfully-parsed `status: "fail"` fails closed (exit 78), and
# it always logs the failing check ids so an operator can see what was wrong
# -- never just "failed".
squad_health_gate() {
  local json rc=0
  json="$(squad health --json 2>&1)" || rc=$?
  local parsed parse_rc=0
  parsed="$(SQUAD_HEALTH_GATE_JSON="$json" node -e '
    let report;
    try {
      report = JSON.parse(process.env.SQUAD_HEALTH_GATE_JSON || "");
    } catch {
      process.exit(2);
    }
    if (!report || report.schema !== "squad-health/v1" || typeof report.status !== "string" || !Array.isArray(report.checks)) {
      process.exit(2);
    }
    const failingIds = report.checks
      .filter((check) => check && check.status === "fail")
      .map((check) => check.id)
      .join(",");
    process.stdout.write(report.status + "\t" + failingIds);
    process.exit(report.status === "fail" ? 1 : 0);
  ' 2>/dev/null)" && parse_rc=0 || parse_rc=$?
  if [[ "$parse_rc" -eq 2 ]]; then
    log "Squad health: UNAVAILABLE -- 'squad health --json' (exit ${rc}) did not return a readable squad-health/v1 report; this CLI predates Squad 0.13's health gate, or does not support it. Continuing without a health gate -- an older CLI must still work."
    return 0
  fi
  local status="${parsed%%$'\t'*}"
  local failing="${parsed#*$'\t'}"
  if [[ "$status" == "fail" ]]; then
    log "Squad health: FAIL -- failing checks: ${failing:-<none reported>}"
    log "A session whose Squad state is not ready must not dispatch an agent against it; refusing to start."
    exit 78
  fi
  log "Squad health: ${status^^} -- all checks passed."
  return 0
}

if squad_health_gate_applies_to_mode "${SQUAD_MODE:-smoke}"; then
  squad_health_gate
else
  log "Squad health gate skipped: mode '${SQUAD_MODE:-smoke}' does not dispatch an agent."
fi

# --- Agent policy (issue #26, PRD #6) ----------------------------------------
# Isolation is not authorization. Until now every session ran Copilot with
# `--yolo` (== --allow-all-tools --allow-all-paths --allow-all-urls) on top of a
# Dockerfile that set COPILOT_ALLOW_ALL=true, so REMOTE execution applied WEAKER
# policy than a developer's own machine -- the escalation PRD #6 forbids.
#
# Policy is now resolved by one shared module (worker/lib/agent-policy.js) that
# both execution planes reach through this single entrypoint, and enforced by
# worker/lib/squad-policy.sh. Nothing here falls back to a permissive default:
# if the policy cannot be resolved or applied, the session aborts.
#
# Ordering matters. Hardening runs AFTER `squad init` and SubSquad activation --
# session bootstrap legitimately creates the very governance files the agent
# must not then rewrite -- and BEFORE anything that runs an agent.
SQUAD_POLICY_LIB="${SQUAD_POLICY_LIB:-/usr/local/lib/squad-on-aca/squad-policy.sh}"
if [[ ! -f "$SQUAD_POLICY_LIB" ]]; then
  log "Agent policy library not found at ${SQUAD_POLICY_LIB}."
  log "A session whose policy cannot be applied must not run with blanket allow; refusing to start."
  exit 78
fi
# shellcheck source=lib/squad-policy.sh
source "$SQUAD_POLICY_LIB"

squad_policy_resolve
squad_policy_harden "$REPO_DIR"

COPILOT_ARGV=("${SQUAD_POLICY_ARGV[@]}")
SQUAD_COPILOT_FLAG_STRING="$SQUAD_POLICY_SQUAD_FLAGS"

# --- watch/loop agent-cmd wrapper policy (issue #112) ------------------------
# `squad watch` and `squad loop` own their own loop and spawn Copilot
# themselves through Squad's `buildAdditionalMcpConfigArgs()`, which prepends
# `--yolo` whenever the team root has a `.mcp.json` -- and `squad init` always
# creates one. There is no flag that turns this off, so both modes are instead
# pointed at /usr/local/lib/squad-on-aca/squad-agent via `--agent-cmd`, which
# bypasses that code path entirely. See worker/squad-agent's own header for
# the full rationale, including why it is registered with no `{prompt}` token.
#
# squad-agent does not re-derive policy; it reads the SAME resolver
# squad_policy_resolve above already used, asked for the one JSON array it is
# built to parse (`watch-agent-argv-json`). SQUAD_WATCH_STRICT_POLICY (default
# false) picks which of agent-policy.js's two variants that resolves to:
# PARITY (default) is today's effective deny set -- the squadFlags subset that
# has always survived `squad --copilot-flags`'s whitespace split -- so turning
# this fix on does not also start silently enforcing `shell(git push)` /
# `shell(gh pr)` against a watch agent that legitimately pushes and opens PRs
# today. STRICT closes that gap by handing squad-agent the FULL argv,
# multi-word deny rules included. See agent-policy.js's `watchStrictPolicy` doc
# and .squad/decisions/inbox/ for the follow-up this trade-off is tracked
# under.
SQUAD_WATCH_STRICT_POLICY="${SQUAD_WATCH_STRICT_POLICY:-false}"
export SQUAD_WATCH_STRICT_POLICY

SQUAD_AGENT_POLICY_ARGV_JSON="$(node "$SQUAD_POLICY_RESOLVER" watch-agent-argv-json 2>&1)"; rc=$?
if [[ "$rc" -ne 0 || -z "$SQUAD_AGENT_POLICY_ARGV_JSON" ]]; then
  squad_policy_abort "The policy resolver produced no watch/loop agent-cmd argv (exit ${rc}): ${SQUAD_AGENT_POLICY_ARGV_JSON}"
fi
export SQUAD_AGENT_POLICY_ARGV_JSON

# The same directory every other mode clones into. squad-agent reads this
# rather than re-deriving a workspace path from its own idea of $PWD or
# $WORKDIR, so there is exactly one place that decides where the repo lives.
SQUAD_AGENT_REPO_DIR="$REPO_DIR"
export SQUAD_AGENT_REPO_DIR

SQUAD_WATCH_AGENT_POLICY_MODE="$(node "$SQUAD_POLICY_RESOLVER" watch-agent-policy-mode 2>&1)"

# SECURITY REVIEW F3 (security-review-112-113.md, HIGH, REJECTED #112):
# `squad_policy_announce squad` used to be called on both the `loop)` and
# `watch|triage)` branches below. It was removed because its "squad" branch
# narrates "squad --copilot-flags" specifically -- which does not apply once
# those two modes are pointed at the --agent-cmd wrapper -- but removing the
# call also removed the ONLY place the parity gap was ever stated: "NOT
# enforced on this path: ...". PARITY mode (the default) is deliberate and
# stays exactly as it is: it keeps today's effective deny set (the same
# subset `squad --copilot-flags` could ever carry), specifically so a
# watch/loop agent can still push and open its own PRs the way it does
# today. What must come back is the ANNOUNCEMENT of which multi-word deny
# rules (shell(git push), shell(git config), shell(gh auth), ...) are
# consequently NOT enforced on this path -- an operator reading the log
# otherwise has no way to tell seven-plus deny rules were dropped from it.
#
# Implemented HERE, in entrypoint.sh, rather than by editing
# squad_policy_announce in worker/lib/squad-policy.sh: that function's
# existing branches do not know about SQUAD_WATCH_AGENT_POLICY_MODE, and this
# review's reviewer-protocol lockout keeps this fix scoped to files this
# agent owns. SQUAD_POLICY_UNDELIVERABLE is already populated above (by
# squad_policy_resolve's bundle fetch) -- the exact same array
# squad_policy_announce's "squad" branch itself reads -- so this is a
# restoration of the old visibility, not a new computation.
squad_watch_policy_announce_undelivered() {
  if [[ "$SQUAD_WATCH_AGENT_POLICY_MODE" == "parity" ]]; then
    if [[ "${#SQUAD_POLICY_UNDELIVERABLE[@]}" -gt 0 ]]; then
      log "NOT enforced on this path: ${SQUAD_POLICY_UNDELIVERABLE[*]}"
      log "  Reason: parity mode intentionally keeps the pre-#112 effective deny set (the same subset 'squad --copilot-flags' could ever carry), so a watch/loop agent can still push and open PRs as it does today. These rules are NOT enforced. Set SQUAD_WATCH_STRICT_POLICY=true to enforce them."
    fi
  else
    log "Policy mode: strict -- the full deny set, including multi-word rules, is handed to squad-agent's resolved argv. Nothing is undeliverable on this path."
  fi
}

# --- Squad Hub supervision (optional) ----------------------------------------
# Loaded next to the policy it depends on, and BEFORE any mode runs an agent.
# Absent library with a hub configured is a refusal, not a downgrade: the whole
# point of the library is to keep a supervised session from quietly becoming an
# unsupervised one.
SQUAD_HUB_LIB="${SQUAD_HUB_LIB:-/usr/local/lib/squad-on-aca/squad-hub.sh}"
if [[ -f "$SQUAD_HUB_LIB" ]]; then
  # shellcheck source=lib/squad-hub.sh
  source "$SQUAD_HUB_LIB"
elif [[ -n "${SQUAD_HUB_URL:-}" || -n "${SQUAD_HUB_TOKEN:-}" ]]; then
  log "A hub was configured but the supervision library is missing at ${SQUAD_HUB_LIB}."
  log "Refusing to run unsupervised with blanket tool approval instead."
  exit 78
fi

# One question, asked the same way by every mode that runs an agent.
squad_hub_should_supervise() {
  declare -f squad_hub_enabled >/dev/null 2>&1 && squad_hub_enabled
}

# --- Credential withholding for untrusted-input agent calls (issue #84 PI-3) -
# Asked immediately before the SAME two modes invoke Copilot (directly, or via
# Squad Hub's oneshot verb), so the answer is always current:
# SQUAD_POLICY_RESOLVER is the same resolver squad_policy_resolve already used,
# asked a different question.
squad_credential_should_withhold() {
  local answer
  answer="$(node "$SQUAD_POLICY_RESOLVER" should-withhold-credential 2>/dev/null)" || answer="0"
  [[ "$answer" == "1" ]]
}

# Verified once per session, before anything is published. Called at the top of
# commit_and_push_if_needed so a governance rewrite can never reach the remote,
# and at the end of every mode that runs an agent so a non-pushing session still
# fails rather than reporting success.
SQUAD_POLICY_VERIFIED=0
SQUAD_POLICY_IN_VERIFY=0
squad_policy_checkpoint() {
  if [[ "$SQUAD_POLICY_VERIFIED" -eq 1 ]]; then
    return 0
  fi
  SQUAD_POLICY_VERIFIED=1
  SQUAD_POLICY_IN_VERIFY=1
  if ! squad_policy_verify "$REPO_DIR"; then
    SQUAD_POLICY_IN_VERIFY=0
    # F7: the report is written BEFORE the failing exit, in every mode -- a
    # violation is exactly when it matters most.
    squad_watch_governance_report_if_any "governance VIOLATION -- session failed (exit 78)" || true
    log "Session FAILED: a governance path was modified by this run. Nothing has been pushed."
    exit 78
  fi
  SQUAD_POLICY_IN_VERIFY=0
  return 0
}

# squad_policy_verify aborts (78) on its own when the policy state itself was
# tampered with; worker/lib/squad-policy.sh calls this hook first so that path
# also leaves a report behind.
squad_policy_on_abort() {
  [[ "${SQUAD_POLICY_IN_VERIFY:-0}" -eq 1 ]] || return 0
  squad_watch_governance_report_if_any "governance state TAMPERED -- session failed (exit 78)" || true
}

# Re-review N5. squad_run_foreground_with_signal_forwarding restores the
# default TERM/INT disposition before it returns, so a shutdown signal landing
# during the checkpoint would kill this shell mid-verify and skip the report.
# Between these two calls TERM/INT are only RECORDED; once the checkpoint and
# the report are done, a recorded signal ends the session (the work it asked to
# stop has already drained). ACA's grace-period SIGKILL cannot be deferred.
SQUAD_DEFERRED_SIGNAL=""
squad_defer_shutdown_signals() {
  SQUAD_DEFERRED_SIGNAL=""
  trap 'SQUAD_DEFERRED_SIGNAL=TERM; log "SIGTERM received during the governance checkpoint; deferring it until the checkpoint and report complete."' TERM
  trap 'SQUAD_DEFERRED_SIGNAL=INT; log "SIGINT received during the governance checkpoint; deferring it until the checkpoint and report complete."' INT
}
squad_release_shutdown_signals() {
  trap - TERM INT
  if [[ -n "$SQUAD_DEFERRED_SIGNAL" ]]; then
    log "Honouring the deferred SIG${SQUAD_DEFERRED_SIGNAL}: governance checkpoint and report are complete; exiting."
    exit 0
  fi
}

# SECURITY REVIEW F7 (security-review-112-113.md, MEDIUM, REJECTED #112):
# squad_policy_reported_changes_report() (worker/lib/squad-policy.sh) -- the
# markdown summary of this session's "reported-mutable" governance changes
# (issue #113: .squad/casting/*.json, .squad/identity/now.md) -- is only ever
# appended to a PR body, inside commit_and_push_if_needed. The `loop)` and
# `watch|triage)` branches below call squad_policy_checkpoint (which
# populates SQUAD_POLICY_REPORTED_CHANGES as a side effect of
# squad_policy_verify) but never commit_and_push_if_needed: `squad watch`/
# `squad loop` open their OWN PRs through `gh`, driven entirely by Squad's
# internal git state, not this container's. So on exactly the two modes #112
# reworked, a reported-mutable change reaches the container log and nothing
# durable -- not a PR body, not a branch, not any artefact a reviewer sees
# once the container exits, on what can be a long-running session.
#
# The fix must NOT make watch/loop start pushing or opening PRs themselves --
# that is a real behaviour change, out of scope here, and would duplicate the
# PR watch/loop already opens on its own. Instead, the SAME report
# squad_policy_reported_changes_report() would have put in a PR body is
# appended (never overwritten) to a durable file and to the container log.
#
# Re-review N1 corrected where that file lives. SQUAD_POLICY_STATE_DIR is owned
# by the agent's own uid, so a report there could simply be deleted. When the
# container started as root, the report goes to the ROOT-OWNED sealed store
# (worker/lib/squad-policy.sh section 4c) instead, which the agent cannot
# touch; the state directory is only the fallback for a session that never
# had root (local runs, tests) and is labelled as agent-writable in the log.
# squad_policy_checkpoint also calls this, with a verdict, BEFORE its exit 78:
# the violation path is where the report matters most.
#
# squad_policy_reported_changes_report is CALLED here, not edited: it already
# does exactly the summarising this needs, and it lives in
# worker/lib/squad-policy.sh, which this fix does not touch.
squad_watch_governance_report_if_any() {
  local verdict="${1:-}" report block
  report="$(squad_policy_reported_changes_report)"
  [[ -z "$report" && -z "$verdict" ]] && return 0

  block="$(
    printf '\n## Checkpoint at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -n "$verdict" ]] && printf '\n**Verdict: %s**\n' "$verdict"
    [[ -n "$report" ]] && printf '%s\n' "$report"
    :
  )"

  # Re-review N1/F7: the durable copy lives in the ROOT-OWNED sealed store
  # when this session has one -- the agent (another uid) cannot delete or
  # rewrite it. The container log gets it too, unconditionally.
  if squad_policy_seal_report "$block"; then
    log "Governance report for this checkpoint was appended to the root-owned ${SQUAD_POLICY_SEALED_DIR}/reported-changes.md (not writable by the agent's uid):"
    log "$block"
    return 0
  fi

  if [[ -z "${SQUAD_POLICY_STATE_DIR:-}" || ! -d "$SQUAD_POLICY_STATE_DIR" ]]; then
    log "Reported-mutable governance changes occurred this session, but no private policy state directory is available to durably record them. Logging the report inline instead:"
    log "$block"
    return 0
  fi

  # No root sealer (not started as root): best effort only. This directory is
  # owned by the agent's own uid, so the copy here is NOT tamper-proof; the
  # inline log line below is the durable record.
  local report_file="${SQUAD_POLICY_STATE_DIR}/reported-changes.md"
  printf '%s\n' "$block" >>"$report_file" || true
  log "Reported-mutable governance changes this session were appended to ${report_file} (agent-writable; no root-sealed store in this session -- see F7 in security-review-112-113.md):"
  log "$block"
}


# --- Lease heartbeat (Sprint 6, PRD #6) --------------------------------------
# A session started by any dispatcher carries SQUAD_LEASE_KEY. Report liveness
# PERIODICALLY and record a terminal state on exit, so the sweeper can tell a
# live execution from an orphaned claim. Every call is best-effort: a lease that
# cannot be updated must never take down a session that is doing real work, and
# the sweeper reclaims it on heartbeat expiry anyway.
#
# The heartbeat must be periodic, not one-shot. A single heartbeat at start means
# a session that outlives SQUAD_LEASE_TTL_SECONDS (default 3600) is swept as
# stale WHILE IT IS STILL RUNNING, and its lease becomes re-claimable by another
# dispatcher -- the exact double-dispatch the lease exists to prevent. Squad
# sessions routinely run 10-60+ minutes.
SQUAD_DISPATCH_CLI="${SQUAD_DISPATCH_CLI:-/usr/local/lib/squad-on-aca/squad-dispatch.js}"
SQUAD_LEASE_HEARTBEAT_SECONDS="${SQUAD_LEASE_HEARTBEAT_SECONDS:-300}"
SQUAD_LEASE_HEARTBEAT_PID=""

squad_lease_report() {
  local op="$1"
  shift
  [[ -n "${SQUAD_LEASE_KEY:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || return 0
  [[ -f "$SQUAD_DISPATCH_CLI" ]] || return 0
  # The heartbeat runs for the WHOLE session (every 300s by default), so by the
  # last tick the GH_TOKEN this shell exported at startup may be an hour old.
  # `gh` is spawned fresh by dispatch-lease.js and inherits this environment, so
  # re-reading the token file here is what keeps a long session's lease writable
  # after a refresh. Best-effort, like every other lease call.
  squad_credential_refresh_env || true
  node "$SQUAD_DISPATCH_CLI" "$op" \
    --repository "$GITHUB_REPOSITORY" \
    --lease-key "$SQUAD_LEASE_KEY" "$@" >/dev/null 2>&1 || true
}

# Issue #92 (root cause of the intermittent CI hang, verified against the
# heartbeat stop/restart behaviour #91 introduced in squad_credential_restore):
# a step -- a GitHub Actions step, or any shell that pipes its output somewhere
# -- ends when its OUTPUT PIPE CLOSES, not when the foreground script exits. A
# background child that inherits stdout/stderr keeps that pipe open for as long
# as the child lives, even after every visible command has finished. This loop
# is exactly such a child: it is forked with `&` and, before this fix, wrote to
# whatever stdout/stderr it was forked with -- the entrypoint's at session
# start, and (via squad_credential_restore) the SAME inherited descriptors
# again on every restart after a credential-withholding window. It never exits
# on its own (`while true`), so any stdout it inherited stays open forever.
# Redirecting INSIDE the function -- rather than trusting every call site to
# remember to redirect -- means a future restart (there is already one, and
# #91 shows there can be more) can never reintroduce this by omission.
squad_lease_heartbeat_loop() {
  while true; do
    sleep "$SQUAD_LEASE_HEARTBEAT_SECONDS"
    squad_lease_report heartbeat
  done >/dev/null 2>&1 </dev/null
}

squad_lease_finish() {
  local code=$?
  # Stop the ticker first, so it cannot resurrect the lease to `running` after
  # the terminal state has been written.
  if [[ -n "$SQUAD_LEASE_HEARTBEAT_PID" ]]; then
    # Issue #92-shaped leak (see squad_credential_withhold in
    # worker/lib/squad-credentials.sh for the full explanation): the
    # heartbeat's own `while true; do sleep N; done` forks a grandchild that
    # survives a signal aimed only at $SQUAD_LEASE_HEARTBEAT_PID. Because the
    # heartbeat is forked with job control on below, its PID is also its own
    # process group id, so signalling the group takes the sleep down with it.
    kill -TERM -- "-$SQUAD_LEASE_HEARTBEAT_PID" 2>/dev/null \
      || kill "$SQUAD_LEASE_HEARTBEAT_PID" 2>/dev/null || true
    wait "$SQUAD_LEASE_HEARTBEAT_PID" 2>/dev/null || true
    SQUAD_LEASE_HEARTBEAT_PID=""
  fi
  if [[ "$code" -eq 0 ]]; then
    squad_lease_report complete --state succeeded
  elif [[ "${SQUAD_SESSION_TIMED_OUT:-0}" -eq 1 ]]; then
    # Issue #134: stopped at the session deadline. Its work was published (as
    # a draft WIP pull request) before this exit, so the lease says so rather
    # than reading like any other failure.
    squad_lease_report complete --state failed --reason "session-deadline-exit-${code}"
  else
    squad_lease_report complete --state failed --reason "exit-${code}"
  fi
  return "$code"
}

# Take the Azure identity away from every mode that does not need it.
#
# Container Apps injects a managed identity into the container as
# IDENTITY_ENDPOINT plus IDENTITY_HEADER (its own scheme; there is no
# 169.254.169.254 here). Any process in the container can exchange those for an
# ARM access token with a single HTTP call -- `curl` is enough, and `curl` is
# not on the deny list, so blocking `az` blocks a command and not the
# capability.
#
# The thing running in this container is an agent executing a prompt, and a
# prompt is attacker-influenced input: an issue body, a comment, a file in a
# repository. So the identity is removed from the environment for every mode
# that has no business using it, which is every mode except `ralph`. Only Ralph
# calls Azure (`containerapp job show`/`start`), and it is the only mode that
# runs `az login --identity`.
#
# THIS MUST RUN BEFORE ANY CHILD PROCESS IS STARTED, and that is why it sits
# here rather than next to the mode dispatch below.
#
# `unset` changes THIS shell. A process already spawned keeps the copy of the
# environment it was given, and on Linux any process running as the same user
# can read it out of /proc/<pid>/environ. The lease heartbeat below is a
# long-lived background child that runs for the whole session, so dropping the
# identity after starting it left the credential legible to exactly the agent it
# was being taken away from. Found in review, and the reason the order here is
# load-bearing rather than tidy.
#
# The heartbeat itself only talks to GitHub, so it loses nothing by starting
# without the Azure identity.
squad_drop_azure_identity() {
  if [[ -z "${IDENTITY_ENDPOINT:-}${IDENTITY_HEADER:-}${MSI_ENDPOINT:-}${MSI_SECRET:-}" ]]; then
    return 0
  fi
  unset IDENTITY_ENDPOINT IDENTITY_HEADER MSI_ENDPOINT MSI_SECRET IMDS_ENDPOINT
  # AZURE_CLIENT_ID alone is not a credential -- it names an identity, it does
  # not authenticate as one -- but leaving it behind invites a library into a
  # retry loop against an endpoint that is deliberately gone.
  unset AZURE_CLIENT_ID
  log "Azure identity removed from this session's environment (mode '${SQUAD_MODE}' does not call Azure)."
}

case "${SQUAD_MODE:-smoke}" in
  ralph)
    : # Ralph is the one mode that calls Azure; it keeps its identity.
    ;;
  *)
    squad_drop_azure_identity
    ;;
esac

# PC-1 (issue #86): run the process-isolation probe UNCONDITIONALLY, in every
# mode including ralph, right after the identity-drop dispatch above and
# before the lease heartbeat (the first background child) is started below.
#
# This is unconditional-on-mode by design and unrelated to whether THIS
# session happened to hold an Azure identity: the question it answers --
# "can a same-uid process on this platform read another process's
# /proc/<pid>/environ at all" -- is a property of the platform, not of this
# session, so every mode's run contributes an observation.
#
# It runs after the identity drop (never before: even though the probe only
# ever touches its own synthetic sentinel, ordering it after keeps a single,
# simple rule -- nothing in this file starts any child, real or diagnostic,
# before the identity is out of the shell's own environment) and before ANY
# background child, so it cannot itself become the same category of leak the
# identity-drop ordering exists to close.
#
# R1 (issue #86 security revision): call the RAW squad_proc_iso_run, never
# route its output through this file's log() wrapper. log() prepends a fixed
# "[squad-on-aca] " literal to whatever it is given
# (worker/entrypoint.sh:log()), which decorates the probe's one documented
# line and changes exactly what a downstream reader would have to expect on
# the wire. squad_proc_iso_probe.sh already owns emitting exactly one safe
# line to stdout and exits 0 unconditionally (squad_proc_iso_run's own
# internal fallback covers a failure inside the probe itself) -- there is
# nothing left for this file to add, and doing so would mean the probe
# library no longer solely owns its own emitted line.
if declare -F squad_proc_iso_run >/dev/null 2>&1; then
  squad_proc_iso_run
fi

if [[ -n "${SQUAD_LEASE_KEY:-}" ]]; then
  squad_lease_report heartbeat
  # Redirected here too, in addition to inside squad_lease_heartbeat_loop
  # itself (issue #92) -- belt and braces, so this call site is correct even
  # if the function body is ever refactored. `set -m` also gives this
  # backgrounded job its own process group (pgid == its own pid), so
  # squad_lease_finish / squad_credential_withhold can signal the whole group
  # and take the loop's sleep grandchild down with it instead of orphaning it.
  set -m
  squad_lease_heartbeat_loop >/dev/null 2>&1 </dev/null &
  SQUAD_LEASE_HEARTBEAT_PID=$!
  set +m
  trap squad_lease_finish EXIT
fi

commit_and_push_if_needed() {
  # Governance integrity is checked BEFORE anything leaves the container. A
  # session that rewrote a protected path fails here and publishes nothing.
  squad_policy_checkpoint

  if [[ "${PUSH_CHANGES:-false}" != "true" ]]; then
    return 0
  fi

  if ! squad_session_has_publishable_work "$REPO_DIR" "${SQUAD_SESSION_BASE_COMMIT:-}"; then
    log "No changes to push."
    return 0
  fi

  local branch="${OUTPUT_BRANCH:-squad/${SESSION_NAME}}"
  # Issue #134: a session the watchdog stopped at its deadline publishes
  # through this SAME function -- the governance checkpoint above, the
  # pre-commit pin hook and squad_push_branch's pin backstop below all run
  # exactly as for a finished session. Only the labels differ: the commit
  # message, the PR title and body say WIP, and the PR is opened as a draft
  # (squad_deadline_wip_*, worker/lib/squad-deadline.sh). For every other
  # session timed_out is 0 and nothing below changes.
  local timed_out="${SQUAD_SESSION_TIMED_OUT:-0}"
  local commit_message="${COMMIT_MESSAGE:-Remote Squad session ${SESSION_NAME}}"
  local wip_commit="" wip_files=0
  git checkout -B "$branch"
  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    if [[ "$timed_out" -eq 1 ]]; then
      wip_files="$(git diff --cached --name-only | wc -l | tr -d '[:space:]')"
      commit_message="$(squad_deadline_wip_commit_message "$commit_message")"
    fi
    local commit_rc=0
    git commit -m "$commit_message" || commit_rc=$?
    if (( commit_rc != 0 )); then
      # The worker-generated pre-commit hook refuses a commit that would carry
      # the session-only memory audit pin; report that as the policy failure it
      # is (78), not as a generic error.
      if [[ -n "${SQUAD_POLICY_PIN_SEAL_MODE:-}" ]] && ! squad_policy_assert_pin_unpublished "$REPO_DIR"; then
        exit 78
      fi
      exit "$commit_rc"
    fi
    if [[ "$timed_out" -eq 1 ]]; then
      wip_commit="$(git rev-parse --short HEAD)"
    fi
  else
    log "Publishing the commits the agent made itself."
  fi

  # The session-only memory audit pin publication check runs inside
  # squad_push_branch (worker/lib/squad-push.sh), so it gates every push this
  # container makes, not only this one; see squad_policy_seal_memory_audit_
  # config_pin (worker/lib/squad-policy.sh) for what is prevented and what is
  # only detected.

  # THE PUSH IS THE MOMENT THE CREDENTIAL IS FIRST REALLY TESTED (issue #32).
  # Everything before it -- including the clone -- succeeds against a public
  # repository with an expired token. The push does not: it fails with exit 128
  # and "Invalid username or token".
  #
  # Two things happen here that did not before:
  #
  #   * the credential helper re-reads the token FILE for this push, so a token
  #     the control plane refreshed mid-session is used automatically. That is
  #     why the retry below is worth anything: the mitigation was proven by
  #     probe (expired -> exit 128 -> rewrite ONLY the token file -> exit 0,
  #     same repository, same process, no git config change);
  #   * a failure whose text says the CREDENTIAL was rejected is classified as
  #     `auth` using the shared taxonomy and exits ${SQUAD_EXIT_CREDENTIAL},
  #     instead of aborting as an anonymous non-zero and being read as "the
  #     agent's work failed".
  # The push is the moment the credential is first really tested (issue #32).
  # Everything before it -- including the clone -- succeeds against a public
  # repository with an expired token. The push does not: it fails with exit 128
  # and "Invalid username or token".
  #
  # The logic lives in worker/lib/squad-push.sh because nothing under
  # worker/tests/ sources this file, so exit-code handling written inline here
  # would be untestable -- and untested exit-code handling is what sank PR #9.
  squad_push_branch "$branch" || exit $?

  if [[ "${CREATE_PR:-true}" == "true" ]]; then
    # `gh` reads GH_TOKEN from its environment. It is a fresh process, so it
    # WOULD honour a refreshed token -- except that this shell exported GH_TOKEN
    # at startup and an exported variable is frozen for the life of the shell.
    # Re-read the file into the environment immediately before the call.
    squad_credential_refresh_env || true
    # Issue #113: casting/*.json and identity/now.md are a NEW "reported-mutable"
    # governance class -- changes are allowed (squad_policy_checkpoint above
    # does not fail the session over them) but must be VISIBLE, not silently
    # folded into "Created by Azure-hosted Squad session". squad_policy_verify
    # (run by squad_policy_checkpoint) populates SQUAD_POLICY_REPORTED_CHANGES;
    # the report function below is a no-op (empty string) when there were none,
    # so a session that touched no reported-mutable path gets an unchanged body.
    local pr_body="${PR_BODY:-Created by Azure-hosted Squad session ${SESSION_NAME}.}"
    local pr_title="${PR_TITLE:-Remote Squad session ${SESSION_NAME}}"
    if [[ "$timed_out" -eq 1 ]]; then
      pr_body="$(squad_deadline_wip_pr_body "$pr_body" "$wip_commit" "$wip_files")"
      pr_title="$(squad_deadline_wip_pr_title "$pr_title")"
    fi
    # `--reviewer` only resolves to a real request if SQUAD_PR_REVIEWER happens
    # to match an actual GitHub login or org/team slug. The dispatch-side
    # validation (worker/lib/dispatch-inputs.js) only guarantees it is an
    # ACTIVE SQUAD CASTING REGISTRY id (issue #135) -- a distinct namespace
    # that `gh` knows nothing about -- so `--reviewer` commonly fails even for
    # a validated value. The requested reviewer is therefore ALWAYS recorded in
    # the PR body too, so the information survives even when GitHub never
    # receives (or rejects) the formal reviewer request.
    if [[ -n "${SQUAD_PR_REVIEWER:-}" ]]; then
      pr_body+="$(printf '\n\nRequested reviewer (squad): %s' "$SQUAD_PR_REVIEWER")"
    fi
    pr_body+="$(squad_policy_reported_changes_report)"
    local -a pr_create_args=(
      gh pr create
      --repo "$GITHUB_REPOSITORY"
      --base "${GITHUB_BASE_BRANCH:-${GITHUB_REF:-main}}"
      --head "$branch"
      --title "$pr_title"
      --body "$pr_body"
    )
    local -a pr_reviewer_args=()
    if [[ -n "${SQUAD_PR_REVIEWER:-}" ]]; then
      pr_reviewer_args=(--reviewer "$SQUAD_PR_REVIEWER")
    fi
    if [[ "$timed_out" -eq 1 ]]; then
      # Draft pull requests are not available on every plan (a private
      # repository on GitHub Free cannot have them), and `gh pr create --draft`
      # then fails outright. The branch is already pushed, so a failed draft
      # must not also cost the pull request: retry as a regular one, whose
      # title and body still say WIP. The reviewer is dropped ONLY as the last
      # resort, one axis (draft, then reviewer) at a time, so a bad reviewer
      # never costs the draft attempt and a bad draft never costs the reviewer.
      if ! "${pr_create_args[@]}" "${pr_reviewer_args[@]}" --draft; then
        if [[ "${#pr_reviewer_args[@]}" -gt 0 ]]; then
          log "Could not open the WIP pull request as a draft with reviewer ${SQUAD_PR_REVIEWER}; retrying as a regular pull request, keeping the reviewer."
          if "${pr_create_args[@]}" "${pr_reviewer_args[@]}"; then
            return 0
          fi
          log "Could not open the WIP pull request with reviewer ${SQUAD_PR_REVIEWER}; retrying without --reviewer (the requested reviewer is still recorded in the pull request body)."
          if "${pr_create_args[@]}" --draft; then
            return 0
          fi
        else
          log "Could not open the WIP pull request as a draft; opening it as a regular pull request, still titled and described as WIP."
        fi
        "${pr_create_args[@]}" || true
      fi
    else
      if ! "${pr_create_args[@]}" "${pr_reviewer_args[@]}"; then
        if [[ "${#pr_reviewer_args[@]}" -gt 0 ]]; then
          log "Could not open the pull request with reviewer ${SQUAD_PR_REVIEWER}; retrying without --reviewer (the requested reviewer is still recorded in the pull request body)."
          "${pr_create_args[@]}" || true
        else
          true
        fi
      fi
    fi
  fi
}

case "${SQUAD_MODE:-smoke}" in
  smoke)
    log "Running smoke checks."
    squad_policy_announce direct
    # Runs seconds after start, so the exported token is almost certainly still
    # good -- but the same rule is applied everywhere `gh` is invoked, because a
    # call site that is an exception today becomes the one that was forgotten
    # tomorrow.
    squad_credential_refresh_env || true
    gh repo view "$GITHUB_REPOSITORY" --json nameWithOwner,defaultBranchRef >/tmp/repo.json
    cat /tmp/repo.json
    squad status || true
    if [[ "${RUN_COPILOT_SMOKE:-false}" == "true" ]]; then
      ( OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_HTTP_ENDPOINT" \
        COPILOT_OTEL_ENABLED=true \
        COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
        squad_policy_exec_agent \
          copilot -p "You are validating a remote Squad container. Reply with a one-sentence status only." "${COPILOT_ARGV[@]}" --silent )
    else
      log "Skipping Copilot prompt smoke. Set RUN_COPILOT_SMOKE=true to exercise Copilot."
    fi
    squad_policy_checkpoint
    ;;
  telemetry-smoke)
    log "Running OpenTelemetry smoke signal."
    tmpdir="$(mktemp -d)"
    cd "$tmpdir"
    npm init -y >/dev/null
    npm install --silent \
      @opentelemetry/api \
      @opentelemetry/api-logs \
      @opentelemetry/sdk-node \
      @opentelemetry/sdk-metrics \
      @opentelemetry/sdk-logs \
      @opentelemetry/exporter-trace-otlp-proto \
      @opentelemetry/exporter-metrics-otlp-proto \
      @opentelemetry/exporter-logs-otlp-proto
    cat > telemetry-smoke.mjs <<'NODE'
import { trace, metrics } from '@opentelemetry/api';
import { logs, SeverityNumber } from '@opentelemetry/api-logs';
import { NodeSDK } from '@opentelemetry/sdk-node';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { SimpleLogRecordProcessor } from '@opentelemetry/sdk-logs';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-proto';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-proto';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-proto';

const httpEndpoint = process.env.ASPIRE_OTLP_HTTP_ENDPOINT;
const session = process.env.SESSION_NAME || 'telemetry-smoke';
const headerText = process.env.OTEL_EXPORTER_OTLP_HEADERS || '';
const headers = Object.fromEntries(
  headerText.split(',').filter(Boolean).map(pair => {
    const idx = pair.indexOf('=');
    return idx === -1 ? [pair, ''] : [pair.slice(0, idx), pair.slice(idx + 1)];
  }),
);

const traceExporter = new OTLPTraceExporter({ url: `${httpEndpoint}/v1/traces`, headers });
const metricExporter = new OTLPMetricExporter({ url: `${httpEndpoint}/v1/metrics`, headers });
const logExporter = new OTLPLogExporter({ url: `${httpEndpoint}/v1/logs`, headers });

const sdk = new NodeSDK({
  traceExporter,
  metricReader: new PeriodicExportingMetricReader({
    exporter: metricExporter,
    exportIntervalMillis: 1000,
  }),
  logRecordProcessors: [new SimpleLogRecordProcessor({ exporter: logExporter })],
});

await sdk.start();

const tracer = trace.getTracer('squad-on-aca');
await tracer.startActiveSpan('squad-on-aca.telemetry-smoke', async span => {
  span.setAttribute('squad.session', session);
  span.setAttribute('squad.platform', 'azure-container-apps');
  span.addEvent('telemetry smoke span emitted from ACA');

  const meter = metrics.getMeter('squad-on-aca');
  const counter = meter.createCounter('squad_aca_e2e_telemetry_smoke_total', {
    description: 'E2E telemetry smoke signals emitted by Squad on ACA',
  });
  counter.add(1, { session, platform: 'aca' });

  const logger = logs.getLogger('squad-on-aca');
  logger.emit({
    severityNumber: SeverityNumber.INFO,
    severityText: 'Information',
    body: `Squad on ACA telemetry smoke log for ${session}`,
    attributes: {
      'squad.session': session,
      'squad.platform': 'azure-container-apps',
    },
  });

  await new Promise(resolve => setTimeout(resolve, 3000));
  span.end();
});

await sdk.shutdown().catch(error => console.error('OpenTelemetry SDK shutdown failed:', error.message));
NODE
    node telemetry-smoke.mjs
    log "OpenTelemetry smoke signal emitted."
    squad_policy_checkpoint
    ;;
  prompt)
    require SQUAD_PROMPT
    # Issue #134: compute the session deadline BEFORE the prompt is composed --
    # squad_publish_contract_note states it to the agent -- and refuse (64) a
    # replica timeout / margin that cannot produce one.
    squad_session_deadline_init || exit $?
    SQUAD_AGENT_PROMPT="${SQUAD_PROMPT}$(squad_publish_contract_note)"
    log "Running one-shot Squad prompt."
    # Issue #84 PI-3: withhold the push credential from the agent for an
    # untrusted-input session (an issue/comment-sourced prompt), and restore it
    # BEFORE commit_and_push_if_needed so the session still ends with a branch
    # and a pull request. A trusted local-cli session is unaffected.
    __squad_credential_withheld=0
    if squad_credential_should_withhold; then
      # Security follow-up (issue #84 blocker): fail closed BEFORE the agent
      # starts if COPILOT_GITHUB_TOKEN is shared with the git token -- see
      # squad_copilot_shared_token_gate in worker/lib/squad-credentials.sh.
      squad_copilot_shared_token_gate
      log "Untrusted-input session (mode '${SQUAD_MODE}', source '${SQUAD_DISPATCH_SOURCE:-<unset>}'): withholding the push credential from the agent. It will be restored after the agent exits and before publishing."
      squad_credential_withhold
      __squad_credential_withheld=1
    fi
    # Issue #134: both paths run under the deadline watchdog, which stops the
    # agent at SQUAD_SESSION_DEADLINE_UTC so what it has done is published
    # below instead of being lost to the replica's hard kill. It is a plain
    # statement on purpose (never `|| rc=$?`): see squad_deadline_run_agent
    # for why errexit must stay live inside the agent's subshell. The OTel
    # variables are passed with `env` because the agent is now a background
    # job of this shell rather than a `( ... )` subshell; what Copilot
    # receives is unchanged.
    if squad_hub_should_supervise; then
      squad_hub_preflight
      squad_policy_announce hub
      squad_deadline_run_agent "$SQUAD_SESSION_DEADLINE_EPOCH" \
        squad_policy_exec_agent squad_hub_run "$SQUAD_AGENT_PROMPT"
    else
      squad_policy_announce direct
      squad_deadline_run_agent "$SQUAD_SESSION_DEADLINE_EPOCH" \
        squad_policy_exec_agent \
          env OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_HTTP_ENDPOINT" \
          COPILOT_OTEL_ENABLED=true \
          COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
          copilot -p "$SQUAD_AGENT_PROMPT" "${COPILOT_ARGV[@]}"
    fi
    # A failed agent that was NOT stopped by the deadline ends the session
    # here with its own status, publishing nothing -- as before. A stopped one
    # continues, and publishes as WIP.
    squad_deadline_settle_agent "$REPO_DIR"
    if [[ "$__squad_credential_withheld" -eq 1 ]]; then
      squad_credential_restore
    fi
    commit_and_push_if_needed
    squad_deadline_finish_session
    ;;
  new-project)
    SQUAD_PROMPT="${SQUAD_PROMPT:-Initialize this repository as a new project with Squad. Review the existing README, create a useful project structure, commit the initial .squad team state and starter files, and open a pull request with the bootstrap changes.}"
    export PUSH_CHANGES="${PUSH_CHANGES:-true}"
    export OUTPUT_BRANCH="${OUTPUT_BRANCH:-squad/bootstrap-${SESSION_NAME}}"
    export PR_TITLE="${PR_TITLE:-Bootstrap project with Squad on ACA}"
    # Issue #134: same deadline as `prompt` -- new-project publishes through
    # the same commit_and_push_if_needed and loses its work the same way.
    squad_session_deadline_init || exit $?
    SQUAD_AGENT_PROMPT="${SQUAD_PROMPT}$(squad_publish_contract_note)"
    log "Running new-project bootstrap Squad prompt."
    # Issue #84 PI-3: same withholding as `prompt`. new-project is the OTHER
    # entrypoint-publishes mode: it always intends to push (PUSH_CHANGES
    # defaults true above) and can equally be reached with an
    # attacker-controlled task description on an untrusted dispatch source.
    __squad_credential_withheld=0
    if squad_credential_should_withhold; then
      # Security follow-up (issue #84 blocker): same fail-closed gate as
      # `prompt` above.
      squad_copilot_shared_token_gate
      log "Untrusted-input session (mode '${SQUAD_MODE}', source '${SQUAD_DISPATCH_SOURCE:-<unset>}'): withholding the push credential from the agent. It will be restored after the agent exits and before publishing."
      squad_credential_withhold
      __squad_credential_withheld=1
    fi
    # Issue #134: the same watchdog as `prompt` -- see the comment there.
    if squad_hub_should_supervise; then
      squad_hub_preflight
      squad_policy_announce hub
      squad_deadline_run_agent "$SQUAD_SESSION_DEADLINE_EPOCH" \
        squad_policy_exec_agent squad_hub_run "$SQUAD_AGENT_PROMPT"
    else
      squad_policy_announce direct
      squad_deadline_run_agent "$SQUAD_SESSION_DEADLINE_EPOCH" \
        squad_policy_exec_agent \
          env OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_HTTP_ENDPOINT" \
          COPILOT_OTEL_ENABLED=true \
          COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
          copilot -p "$SQUAD_AGENT_PROMPT" "${COPILOT_ARGV[@]}"
    fi
    squad_deadline_settle_agent "$REPO_DIR"
    if [[ "$__squad_credential_withheld" -eq 1 ]]; then
      squad_credential_restore
    fi
    commit_and_push_if_needed
    squad_deadline_finish_session
    ;;
  loop)
    if [[ -n "${LOOP_MARKDOWN:-}" ]]; then
      printf '%s\n' "$LOOP_MARKDOWN" > loop.md
    elif [[ ! -f loop.md ]]; then
      squad loop --init
      sed -i 's/configured: false/configured: true/' loop.md
    fi
    log "Starting Squad loop."
    # Issue #112: `--agent-cmd`, NOT `--copilot-flags`. squad-agent now owns
    # the whole resolved argv (read from SQUAD_AGENT_POLICY_ARGV_JSON, which
    # was exported above); passing --copilot-flags here as well would be a
    # second, competing source of truth for the same decision -- and the one
    # this fix exists to stop using, since it is the path that cannot carry a
    # multi-word deny pattern and the path squad-cli's --yolo injection was
    # found on. squad_policy_announce is not called here for the same reason:
    # its "squad" branch narrates --copilot-flags specifically, which no
    # longer applies to this invocation, and its other branches describe the
    # FULL argv regardless of the parity/strict choice squad-agent actually
    # makes -- so the log line below reports what will truly be exec'd instead.
    log "Tier: ${SQUAD_POLICY_TIER} (${SQUAD_POLICY_REASON})"
    log "watch/loop agent-cmd policy mode: ${SQUAD_WATCH_AGENT_POLICY_MODE} (SQUAD_WATCH_STRICT_POLICY=${SQUAD_WATCH_STRICT_POLICY})"
    log "watch/loop agent-cmd argv: ${SQUAD_AGENT_POLICY_ARGV_JSON}"
    squad_watch_policy_announce_undelivered
    export OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_GRPC_ENDPOINT"
    export COPILOT_OTEL_ENABLED=false
    # Same shape as watch: the loop belongs to `squad`, so the container
    # attaches and each session it starts reports itself.
    if squad_hub_should_supervise; then
      squad_hub_supervise_ambient
      trap squad_hub_release_ambient EXIT
    fi
    # Issue #115: run in the background with SIGTERM/SIGINT forwarded, so ACA
    # stopping this replica lets Squad drain instead of being killed abruptly
    # mid-cycle. See squad_run_foreground_with_signal_forwarding above.
    # squad_policy_exec_agent runs INSIDE the forwarding wrapper's background
    # job, closes the policy sampler/seal descriptors there, then execs
    # `squad` -- so `$!` is still squad's own pid and forwarding is unchanged.
    squad_run_foreground_with_signal_forwarding \
      squad_policy_exec_agent \
      squad loop --interval "${LOOP_INTERVAL_MINUTES:-10}" --timeout "${LOOP_TIMEOUT_MINUTES:-30}" --agent-cmd /usr/local/lib/squad-on-aca/squad-agent
    squad_defer_shutdown_signals
    squad_policy_checkpoint
    squad_watch_governance_report_if_any
    squad_release_shutdown_signals
    ;;
  ralph)
    log "Starting scheduled Ralph dispatcher."
    require AZURE_RESOURCE_GROUP
    require ACA_SESSION_JOB_NAME
    require AZURE_CLIENT_ID

    RALPH_DISPATCH_LIB="${RALPH_DISPATCH_LIB:-/usr/local/lib/squad-on-aca/ralph-dispatch.sh}"
    if [[ ! -f "$RALPH_DISPATCH_LIB" ]]; then
      log "Ralph dispatch library not found at ${RALPH_DISPATCH_LIB}; cannot dispatch."
      exit 70
    fi
    # shellcheck source=lib/ralph-dispatch.sh
    source "$RALPH_DISPATCH_LIB"

    az login --identity --client-id "$AZURE_CLIENT_ID" --allow-no-subscriptions >/dev/null
    if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
      az account set --subscription "$AZURE_SUBSCRIPTION_ID"
    fi

    # The `squad:*` namespace is reserved by Squad's member-routing workflows
    # (.github/workflows/squad-issue-assign.yml treats any `squad:*` label as a
    # member label), so Ralph uses the ACA-specific `squad-aca:dispatched` marker
    # to avoid triggering member assignment.
    RALPH_DISPATCH_LABEL="${RALPH_DISPATCH_LABEL:-squad-aca:dispatched}"
    blocked_labels_regex='(^|,)(blocked|status:blocked|status:wontfix|status:on-hold)(,|$)'
    # `az login --identity` above can take a while, and Ralph itself is a
    # long-lived dispatcher: everything from here on is `gh`, so re-read the
    # token file into the environment first.
    squad_credential_refresh_env || true
    gh label create "$RALPH_DISPATCH_LABEL" --repo "$GITHUB_REPOSITORY" --color 5319E7 --description "Dispatched by Squad on ACA Ralph" --force >/dev/null 2>&1 || true

    issues_json="$(mktemp)"
    squad_credential_refresh_env || true
    gh issue list \
      --repo "$GITHUB_REPOSITORY" \
      --state open \
      --label "${RALPH_LABELS:-squad-aca}" \
      --limit "${RALPH_MAX_ISSUES:-3}" \
      --json number,title,url,labels,assignees > "$issues_json"

    mapfile -t issue_rows < <(node - "$issues_json" "$RALPH_DISPATCH_LABEL" "$blocked_labels_regex" <<'NODE'
const fs = require('fs');
const [file, dispatchLabel, blockedRegexText] = process.argv.slice(2);
const blockedRegex = new RegExp(blockedRegexText);
const issues = JSON.parse(fs.readFileSync(file, 'utf8'));
for (const issue of issues) {
  const labels = (issue.labels || []).map(l => l.name);
  const labelText = labels.join(',');
  if ((issue.assignees || []).length > 0) continue;
  if (labels.includes(dispatchLabel)) continue;
  if (blockedRegex.test(labelText)) continue;
  console.log([issue.number, issue.title.replace(/\t/g, ' '), issue.url].join('\t'));
}
NODE
    )

    if [[ "${#issue_rows[@]}" -eq 0 ]]; then
      log "Ralph found no undispatched actionable issues."
      squad_policy_checkpoint
      exit 0
    fi

    # Snapshot the session job definition ONCE (immutable ARM read). Ralph then
    # POSTs JSON to `/start`, so prompts and other free-text session values never
    # appear on a process command line.
    session_job_subscription_id="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null)}"
    if [[ -z "$session_job_subscription_id" ]]; then
      log "Could not determine the Azure subscription for Ralph dispatch."
      exit 1
    fi
    RALPH_SESSION_JOB_DEFINITION_JSON="$(squad_fetch_job_definition \
      "$session_job_subscription_id" \
      "$AZURE_RESOURCE_GROUP" \
      "$ACA_SESSION_JOB_NAME")"
    export RALPH_SESSION_JOB_DEFINITION_JSON

    mapfile -t session_job_spec < <(SJ_JOB_DEFINITION="$RALPH_SESSION_JOB_DEFINITION_JSON" node - <<'NODE'
let job = {};
try { job = JSON.parse(process.env.SJ_JOB_DEFINITION || '{}') || {}; } catch { job = {}; }
const c = ((((job || {}).properties || {}).template || {}).containers || [])[0] || {};
const name = String(c.name || '');
const image = String(c.image || '');
const cpu = c.resources && c.resources.cpu != null ? String(c.resources.cpu) : '';
const memory = c.resources && c.resources.memory ? String(c.resources.memory) : '';
process.stdout.write([name, image, cpu, memory, JSON.stringify(c.env || [])].join('\n'));
NODE
    )

    RALPH_SESSION_JOB_CONTAINER="${session_job_spec[0]:-}"
    RALPH_SESSION_JOB_IMAGE="${session_job_spec[1]:-}"
    RALPH_SESSION_JOB_CPU="${session_job_spec[2]:-}"
    RALPH_SESSION_JOB_MEMORY="${session_job_spec[3]:-}"
    RALPH_SESSION_JOB_ENV_JSON="${session_job_spec[4]:-[]}"

    # ACA only applies the per-execution --env-vars override when a complete
    # execution container spec is supplied, so fail clearly if the immutable
    # template is missing image or resources rather than dispatching a run that
    # would silently ignore the env override.
    if [[ -z "$RALPH_SESSION_JOB_IMAGE" || -z "$RALPH_SESSION_JOB_CPU" || -z "$RALPH_SESSION_JOB_MEMORY" ]]; then
      log "Session job container template is missing image/cpu/memory; ACA cannot apply per-execution env without a complete container spec. Aborting Ralph dispatch."
      exit 1
    fi
    if [[ -z "$RALPH_SESSION_JOB_CONTAINER" ]]; then
      RALPH_SESSION_JOB_CONTAINER="$ACA_SESSION_JOB_NAME"
    fi

    # Dispatch each issue transactionally and in isolation: env is built and
    # validated, the ACA session job is started, and the dispatch label is added
    # ONLY after a confirmed start. A failure on one issue is logged and skipped
    # so the rest of the batch still runs. See worker/lib/ralph-dispatch.sh.
    run_ralph_dispatch
    squad_policy_checkpoint
    ;;
  watch|triage)
    log "Starting Squad watch."
    # Issue #112: `--agent-cmd`, NOT `--copilot-flags` -- see the matching
    # comment in the `loop)` branch above for why both would be a double
    # source of truth, and why squad_policy_announce is skipped in favour of
    # the explicit lines below. F3: squad_watch_policy_announce_undelivered
    # restores the parity-gap warning squad_policy_announce used to print.
    log "Tier: ${SQUAD_POLICY_TIER} (${SQUAD_POLICY_REASON})"
    log "watch/loop agent-cmd policy mode: ${SQUAD_WATCH_AGENT_POLICY_MODE} (SQUAD_WATCH_STRICT_POLICY=${SQUAD_WATCH_STRICT_POLICY})"
    log "watch/loop agent-cmd argv: ${SQUAD_AGENT_POLICY_ARGV_JSON}"
    squad_watch_policy_announce_undelivered
    export OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_GRPC_ENDPOINT"
    export COPILOT_OTEL_ENABLED=false
    # `squad watch` owns its own loop and spawns Copilot itself, so there is no
    # single session to hand to the hub. Attach the CONTAINER instead and let
    # each session report itself. Before the loop starts, or the first
    # iterations run unwatched.
    if squad_hub_should_supervise; then
      squad_hub_supervise_ambient
      trap squad_hub_release_ambient EXIT
    fi
    # Issue #115: Squad 0.13 ships an UNDOCUMENTED `--sentinel-file <path>`
    # flag (not listed by `squad watch --help`; found by reading
    # dist/cli/commands/watch/index.js in the published @bradygaster/squad-cli
    # package). Its semantics are the opposite of the naive reading: `watch`
    # creates the file itself at startup if it doesn't exist, and a round stops
    # the run once that file is REMOVED -- not once it is created. It is
    # checked once at the START of each polling round (detectStopSignal, read
    # before any work that round), so it is a between-round "don't start the
    # next cycle" signal, complementary to -- and not a substitute for -- the
    # SIGTERM forwarding above, which drains an ALREADY in-flight round.
    #
    # Wiring `squad-aca watch stop` (scripts/squad-aca.ps1) to delete this file
    # is NOT implemented: the file lives inside this container's own ephemeral
    # filesystem (${WORKDIR:-/workspace}/${SESSION_NAME}), and nothing mounts
    # or exposes that path to a process running outside the container. Reaching
    # it would require `az containerapp exec` (an Azure call, and one this
    # container's user has no standing access path for from the local CLI) or
    # a shared volume mount that does not exist in scripts/deploy.ps1 today.
    # `squad-aca watch stop` already gets a REAL graceful stop today via the
    # SIGTERM-forwarding fix above: it runs `az containerapp update --min-replicas 0`
    # (scripts/start-watch.ps1), which ACA enacts by sending SIGTERM to this
    # container -- now forwarded to Squad -- so that path does not need the
    # sentinel file at all.
    export SQUAD_WATCH_SENTINEL_FILE="${SQUAD_WATCH_SENTINEL_FILE:-${WORKDIR:-/workspace}/${SESSION_NAME}/watch-sentinel}"
    mkdir -p "$(dirname "$SQUAD_WATCH_SENTINEL_FILE")"
    squad_run_foreground_with_signal_forwarding \
      squad_policy_exec_agent \
      squad watch \
      --execute \
      --interval "${WATCH_INTERVAL_MINUTES:-5}" \
      --timeout "${WATCH_TIMEOUT_MINUTES:-45}" \
      --max-concurrent "${WATCH_MAX_CONCURRENT:-1}" \
      --agent-cmd /usr/local/lib/squad-on-aca/squad-agent \
      --notify-level "${WATCH_NOTIFY_LEVEL:-important}" \
      --sentinel-file "$SQUAD_WATCH_SENTINEL_FILE" \
      --verbose
    squad_defer_shutdown_signals
    squad_policy_checkpoint
    squad_watch_governance_report_if_any
    squad_release_shutdown_signals
    ;;
  shell)
    log "Starting requested shell command."
    require REMOTE_SQUAD_COMMAND
    ( squad_policy_exec_agent bash -lc "$REMOTE_SQUAD_COMMAND" )
    commit_and_push_if_needed
    ;;
  *)
    log "Unknown SQUAD_MODE: ${SQUAD_MODE}"
    exit 64
    ;;
esac
