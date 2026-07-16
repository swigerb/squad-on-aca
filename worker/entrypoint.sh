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
  git fetch --depth "${GIT_CLONE_DEPTH:-1}" origin "${GITHUB_REF}" || true
  git checkout "${GITHUB_REF}" || git checkout -B "${GITHUB_REF}" "origin/${GITHUB_REF}"
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

    az login --identity --client-id "$AZURE_CLIENT_ID" --allow-no-subscriptions >/dev/null
    if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
      az account set --subscription "$AZURE_SUBSCRIPTION_ID"
    fi

    # The `squad:*` namespace is reserved by Squad's member-routing workflows
    # (.github/workflows/squad-issue-assign.yml treats any `squad:*` label as a
    # member label), so Ralph uses the ACA-specific `squad-aca:dispatched` marker
    # to avoid triggering member assignment.
    dispatch_label="${RALPH_DISPATCH_LABEL:-squad-aca:dispatched}"
    blocked_labels_regex='(^|,)(blocked|status:blocked|status:wontfix|status:on-hold)(,|$)'
    gh label create "$dispatch_label" --repo "$GITHUB_REPOSITORY" --color 5319E7 --description "Dispatched by Squad on ACA Ralph" --force >/dev/null 2>&1 || true

    issues_json="$(mktemp)"
    gh issue list \
      --repo "$GITHUB_REPOSITORY" \
      --state open \
      --label "${RALPH_LABELS:-squad}" \
      --limit "${RALPH_MAX_ISSUES:-3}" \
      --json number,title,url,labels,assignees > "$issues_json"

    mapfile -t issue_rows < <(node - "$issues_json" "$dispatch_label" "$blocked_labels_regex" <<'NODE'
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

    session_job_name="${session_job_spec[0]:-}"
    session_job_image="${session_job_spec[1]:-}"
    session_job_cpu="${session_job_spec[2]:-}"
    session_job_memory="${session_job_spec[3]:-}"
    session_job_env_json="${session_job_spec[4]:-[]}"

    # ACA only applies the per-execution --env-vars override when a complete
    # execution container spec is supplied, so fail clearly if the immutable
    # template is missing image or resources rather than dispatching a run that
    # would silently ignore the env override.
    if [[ -z "$session_job_image" || -z "$session_job_cpu" || -z "$session_job_memory" ]]; then
      log "Session job container template is missing image/cpu/memory; ACA cannot apply per-execution env without a complete container spec. Aborting Ralph dispatch."
      exit 1
    fi
    if [[ -z "$session_job_name" ]]; then
      session_job_name="$ACA_SESSION_JOB_NAME"
    fi

    for row in "${issue_rows[@]}"; do
      IFS=$'\t' read -r issue_number issue_title issue_url <<< "$row"
      session_name="issue-${issue_number}-$(date +%Y%m%d%H%M%S)"
      prompt="Ralph dispatched GitHub issue #${issue_number}: ${issue_title}

Issue URL: ${issue_url}

Use Squad to inspect the repository, work the issue if it is actionable, create a branch, commit changes, and open a pull request. If blocked, comment on the issue with the blocker and stop."

      log "Dispatching issue #${issue_number} to ACA session job ${session_name}."
      gh issue edit "$issue_number" --repo "$GITHUB_REPOSITORY" --add-label "$dispatch_label" >/dev/null || true

      # Build the complete env set for THIS execution. Session-managed keys are
      # stripped from the template snapshot and replaced with fresh values; all
      # other template variables (Aspire endpoints, Azure identity, secret refs,
      # Copilot flags) are carried forward. NUL-delimited so multi-line prompts
      # survive intact.
      mapfile -d '' -t start_env < <(
        SJ_ENV="$session_job_env_json" \
        OV_GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
        OV_GITHUB_REF="${GITHUB_REF:-${GITHUB_BASE_BRANCH:-main}}" \
        OV_SQUAD_MODE="prompt" \
        OV_SESSION_NAME="$session_name" \
        OV_SQUAD_POD_ID="$session_name" \
        OV_SQUAD_DEPLOYMENT_MODE="squad-per-pod" \
        OV_OTEL_SERVICE_NAME="squad-$session_name" \
        OV_ENABLE_GITHUB_REMOTE="true" \
        OV_GITHUB_TOKEN="secretref:github-token" \
        OV_COPILOT_GITHUB_TOKEN="secretref:copilot-github-token" \
        OV_OTEL_EXPORTER_OTLP_HEADERS="secretref:otlp-headers" \
        OV_SQUAD_PROMPT="$prompt" \
        OV_PUSH_CHANGES="true" \
        OV_OUTPUT_BRANCH="squad/issue-${issue_number}" \
        OV_PR_TITLE="Squad: issue #${issue_number}" \
        node - <<'NODE'
const managed = new Set([
  'GITHUB_REPOSITORY','GITHUB_REF','SQUAD_MODE','SESSION_NAME','SQUAD_DEPLOYMENT_MODE',
  'SQUAD_POD_ID','OTEL_SERVICE_NAME','ENABLE_GITHUB_REMOTE','GITHUB_TOKEN',
  'COPILOT_GITHUB_TOKEN','OTEL_EXPORTER_OTLP_HEADERS','SQUAD_PROMPT','SQUAD_TEAM',
  'RUN_COPILOT_SMOKE','PUSH_CHANGES','OUTPUT_BRANCH','PR_TITLE','PR_BODY',
  'COMMIT_MESSAGE','RALPH_LABELS','RALPH_MAX_ISSUES',
]);
const merged = new Map();
let template = [];
try { template = JSON.parse(process.env.SJ_ENV || '[]') || []; } catch { template = []; }
for (const e of template) {
  if (!e || !e.name) continue;
  if (managed.has(e.name)) continue;
  merged.set(e.name, e.secretRef ? `secretref:${e.secretRef}` : String(e.value ?? ''));
}
for (const [k, v] of Object.entries(process.env)) {
  if (!k.startsWith('OV_')) continue;
  merged.set(k.slice(3), String(v ?? ''));
}
const out = [];
for (const [k, v] of merged) out.push(`${k}=${v}`);
process.stdout.write(out.join('\0'));
NODE
      )

      az containerapp job start \
        --name "$ACA_SESSION_JOB_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --image "$session_job_image" \
        --cpu "$session_job_cpu" \
        --memory "$session_job_memory" \
        --container-name "$session_job_name" \
        --env-vars "${start_env[@]}" >/dev/null
    done

    log "Ralph dispatched ${#issue_rows[@]} issue(s)."
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
