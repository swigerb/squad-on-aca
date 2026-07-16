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
if [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]]; then
  export COPILOT_GITHUB_TOKEN
elif [[ -n "${GH_TOKEN:-}" ]]; then
  export COPILOT_GITHUB_TOKEN="$GH_TOKEN"
fi

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
log "Mode: ${SQUAD_MODE:-smoke}"
log "Squad OTLP endpoint: ${ASPIRE_OTLP_GRPC_ENDPOINT}"
log "Copilot OTLP endpoint: ${ASPIRE_OTLP_HTTP_ENDPOINT}"

if [[ -n "${GH_TOKEN:-}" ]]; then
  git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
fi
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

if [[ ! -f ".squad/team.md" ]]; then
  log "No .squad/team.md found; initializing a default Squad in the ephemeral workspace."
  squad init --preset "${SQUAD_PRESET:-default}" --no-workflows
fi

if [[ -n "${SQUAD_TEAM:-}" ]]; then
  log "Activating SubSquad: ${SQUAD_TEAM}"
  squad subsquads activate "$SQUAD_TEAM" || true
fi

if [[ -z "${SQUAD_COPILOT_FLAGS:-}" ]]; then
  if [[ "${ENABLE_GITHUB_REMOTE:-true}" == "true" ]]; then
    COPILOT_FLAGS="--yolo --agent squad --remote --no-auto-update"
  else
    COPILOT_FLAGS="--yolo --agent squad --no-remote --no-auto-update"
  fi
else
  COPILOT_FLAGS="$SQUAD_COPILOT_FLAGS"
fi
log "Copilot flags: ${COPILOT_FLAGS}"

commit_and_push_if_needed() {
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
  git push --set-upstream origin "$branch"
  if [[ "${CREATE_PR:-true}" == "true" ]]; then
    gh pr create --repo "$GITHUB_REPOSITORY" --base "${GITHUB_BASE_BRANCH:-${GITHUB_REF:-main}}" --head "$branch" --title "${PR_TITLE:-Remote Squad session ${SESSION_NAME}}" --body "${PR_BODY:-Created by Azure-hosted Squad session ${SESSION_NAME}.}" || true
  fi
}

case "${SQUAD_MODE:-smoke}" in
  smoke)
    log "Running smoke checks."
    gh repo view "$GITHUB_REPOSITORY" --json nameWithOwner,defaultBranchRef >/tmp/repo.json
    cat /tmp/repo.json
    squad status || true
    if [[ "${RUN_COPILOT_SMOKE:-false}" == "true" ]]; then
      OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_HTTP_ENDPOINT" \
        COPILOT_OTEL_ENABLED=true \
        COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
        copilot -p "You are validating a remote Squad container. Reply with a one-sentence status only." $COPILOT_FLAGS --silent
    else
      log "Skipping Copilot prompt smoke. Set RUN_COPILOT_SMOKE=true to exercise Copilot."
    fi
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
    ;;
  prompt)
    require SQUAD_PROMPT
    log "Running one-shot Squad prompt."
    OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_HTTP_ENDPOINT" \
      COPILOT_OTEL_ENABLED=true \
      COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
      copilot -p "$SQUAD_PROMPT" $COPILOT_FLAGS
    commit_and_push_if_needed
    ;;
  new-project)
    SQUAD_PROMPT="${SQUAD_PROMPT:-Initialize this repository as a new project with Squad. Review the existing README, create a useful project structure, commit the initial .squad team state and starter files, and open a pull request with the bootstrap changes.}"
    export PUSH_CHANGES="${PUSH_CHANGES:-true}"
    export OUTPUT_BRANCH="${OUTPUT_BRANCH:-squad/bootstrap-${SESSION_NAME}}"
    export PR_TITLE="${PR_TITLE:-Bootstrap project with Squad on ACA}"
    log "Running new-project bootstrap Squad prompt."
    OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_HTTP_ENDPOINT" \
      COPILOT_OTEL_ENABLED=true \
      COPILOT_OTEL_EXPORTER_TYPE=otlp-http \
      copilot -p "$SQUAD_PROMPT" $COPILOT_FLAGS
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
    export OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_GRPC_ENDPOINT"
    export COPILOT_OTEL_ENABLED=false
    squad loop --interval "${LOOP_INTERVAL_MINUTES:-10}" --timeout "${LOOP_TIMEOUT_MINUTES:-30}" --copilot-flags "$COPILOT_FLAGS"
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
    gh label create "$RALPH_DISPATCH_LABEL" --repo "$GITHUB_REPOSITORY" --color 5319E7 --description "Dispatched by Squad on ACA Ralph" --force >/dev/null 2>&1 || true

    issues_json="$(mktemp)"
    gh issue list \
      --repo "$GITHUB_REPOSITORY" \
      --state open \
      --label "${RALPH_LABELS:-squad}" \
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
    ;;
  watch|triage)
    log "Starting Squad watch."
    export OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_GRPC_ENDPOINT"
    export COPILOT_OTEL_ENABLED=false
    squad watch \
      --execute \
      --interval "${WATCH_INTERVAL_MINUTES:-5}" \
      --timeout "${WATCH_TIMEOUT_MINUTES:-45}" \
      --max-concurrent "${WATCH_MAX_CONCURRENT:-1}" \
      --copilot-flags "$COPILOT_FLAGS" \
      --notify-level "${WATCH_NOTIFY_LEVEL:-important}" \
      --verbose
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
