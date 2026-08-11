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

export HOME="${HOME:-/home/squad}"
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
squad_policy_checkpoint() {
  if [[ "$SQUAD_POLICY_VERIFIED" -eq 1 ]]; then
    return 0
  fi
  SQUAD_POLICY_VERIFIED=1
  if ! squad_policy_verify "$REPO_DIR"; then
    log "Session FAILED: a governance path was modified by this run. Nothing has been pushed."
    exit 78
  fi
  return 0
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

  if git diff --quiet && git diff --cached --quiet; then
    log "No changes to push."
    return 0
  fi

  local branch="${OUTPUT_BRANCH:-squad/${SESSION_NAME}}"
  git checkout -B "$branch"
  git add -A
  git commit -m "${COMMIT_MESSAGE:-Remote Squad session ${SESSION_NAME}}"

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
    gh pr create --repo "$GITHUB_REPOSITORY" --base "${GITHUB_BASE_BRANCH:-${GITHUB_REF:-main}}" --head "$branch" --title "${PR_TITLE:-Remote Squad session ${SESSION_NAME}}" --body "${PR_BODY:-Created by Azure-hosted Squad session ${SESSION_NAME}.}" || true
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
      OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_HTTP_ENDPOINT" \
        COPILOT_OTEL_ENABLED=true \
        COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
        copilot -p "You are validating a remote Squad container. Reply with a one-sentence status only." "${COPILOT_ARGV[@]}" --silent
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
    if squad_hub_should_supervise; then
      squad_hub_preflight
      squad_policy_announce hub
      squad_hub_run "$SQUAD_PROMPT"
    else
      squad_policy_announce direct
      OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_HTTP_ENDPOINT" \
        COPILOT_OTEL_ENABLED=true \
        COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
        copilot -p "$SQUAD_PROMPT" "${COPILOT_ARGV[@]}"
    fi
    if [[ "$__squad_credential_withheld" -eq 1 ]]; then
      squad_credential_restore
    fi
    commit_and_push_if_needed
    ;;
  new-project)
    SQUAD_PROMPT="${SQUAD_PROMPT:-Initialize this repository as a new project with Squad. Review the existing README, create a useful project structure, commit the initial .squad team state and starter files, and open a pull request with the bootstrap changes.}"
    export PUSH_CHANGES="${PUSH_CHANGES:-true}"
    export OUTPUT_BRANCH="${OUTPUT_BRANCH:-squad/bootstrap-${SESSION_NAME}}"
    export PR_TITLE="${PR_TITLE:-Bootstrap project with Squad on ACA}"
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
    if squad_hub_should_supervise; then
      squad_hub_preflight
      squad_policy_announce hub
      squad_hub_run "$SQUAD_PROMPT"
    else
      squad_policy_announce direct
      OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_HTTP_ENDPOINT" \
        COPILOT_OTEL_ENABLED=true \
        COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
        copilot -p "$SQUAD_PROMPT" "${COPILOT_ARGV[@]}"
    fi
    if [[ "$__squad_credential_withheld" -eq 1 ]]; then
      squad_credential_restore
    fi
    commit_and_push_if_needed
    ;;
  loop)
    if [[ -n "${LOOP_MARKDOWN:-}" ]]; then
      printf '%s\n' "$LOOP_MARKDOWN" > loop.md
    elif [[ ! -f loop.md ]]; then
      squad loop --init
      sed -i 's/configured: false/configured: true/' loop.md
    fi
    log "Starting Squad loop."
    squad_policy_announce squad
    export OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_GRPC_ENDPOINT"
    export COPILOT_OTEL_ENABLED=false
    squad loop --interval "${LOOP_INTERVAL_MINUTES:-10}" --timeout "${LOOP_TIMEOUT_MINUTES:-30}" --copilot-flags "$SQUAD_COPILOT_FLAG_STRING"
    squad_policy_checkpoint
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

    # Snapshot the session job's container template ONCE (immutable read):
    # name, image, resources, and env. Each dispatch below builds a complete,
    # isolated env override from this snapshot AND echoes the stored image and
    # resources back on `job start`. In live ACA E2E, `job start --env-vars`
    # alone does NOT apply the per-execution override (the worker still sees the
    # template's baked-in values); ACA only applies it when a complete execution
    # container spec (image + resources) is also supplied. Reading and echoing
    # the stored image/resources does NOT mutate the shared session job template,
    # so cross-session leakage and concurrent-dispatch races are still avoided.
    session_job_container_json="$(az containerapp job show \
      --name "$ACA_SESSION_JOB_NAME" \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --query "properties.template.containers[0]" -o json)"

    mapfile -t session_job_spec < <(SJ_CONTAINER="$session_job_container_json" node - <<'NODE'
let c = {};
try { c = JSON.parse(process.env.SJ_CONTAINER || '{}') || {}; } catch { c = {}; }
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
    squad_policy_announce squad
    export OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_GRPC_ENDPOINT"
    export COPILOT_OTEL_ENABLED=false
    squad watch \
      --execute \
      --interval "${WATCH_INTERVAL_MINUTES:-5}" \
      --timeout "${WATCH_TIMEOUT_MINUTES:-45}" \
      --max-concurrent "${WATCH_MAX_CONCURRENT:-1}" \
      --copilot-flags "$SQUAD_COPILOT_FLAG_STRING" \
      --notify-level "${WATCH_NOTIFY_LEVEL:-important}" \
      --verbose
    squad_policy_checkpoint
    ;;
  shell)
    log "Starting requested shell command."
    require REMOTE_SQUAD_COMMAND
    bash -lc "$REMOTE_SQUAD_COMMAND"
    commit_and_push_if_needed
    ;;
  *)
    log "Unknown SQUAD_MODE: ${SQUAD_MODE}"
    exit 64
    ;;
esac
