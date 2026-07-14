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
    gh pr create --repo "$GITHUB_REPOSITORY" --base "${GITHUB_BASE_BRANCH:-main}" --head "$branch" --title "${PR_TITLE:-Remote Squad session ${SESSION_NAME}}" --body "${PR_BODY:-Created by Azure-hosted Squad session ${SESSION_NAME}.}" || true
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
  prompt)
    require SQUAD_PROMPT
    log "Running one-shot Squad prompt."
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
    log "Starting scheduled Ralph poll."
    export OTEL_EXPORTER_OTLP_ENDPOINT="$ASPIRE_OTLP_GRPC_ENDPOINT"
    export COPILOT_OTEL_ENABLED=false
    ralph_run_seconds="${RALPH_RUN_SECONDS:-240}"
    set +e
    timeout --kill-after=20s "$ralph_run_seconds" squad watch \
      --execute \
      --interval "${WATCH_INTERVAL_MINUTES:-9999}" \
      --timeout "${WATCH_TIMEOUT_MINUTES:-4}" \
      --max-concurrent "${WATCH_MAX_CONCURRENT:-1}" \
      --copilot-flags "$COPILOT_FLAGS" \
      --notify-level "${WATCH_NOTIFY_LEVEL:-important}" \
      --verbose
    ralph_exit=$?
    set -e
    if [[ "$ralph_exit" -eq 124 || "$ralph_exit" -eq 137 || "$ralph_exit" -eq 143 ]]; then
      log "Scheduled Ralph poll window complete."
      exit 0
    fi
    exit "$ralph_exit"
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
