#!/usr/bin/env bash
# Ralph transactional dispatch helpers.
#
# Sourced by worker/entrypoint.sh (ralph mode) and by worker/tests. Sourcing has
# no side effects beyond defining functions and the authoritative
# RALPH_MANAGED_ENV_KEYS list, so the dispatch contract is independently
# testable with fake `az`/`gh` on PATH.
#
# Design goals (see docs/runbook.md "Ralph job runner"):
#   * ONE routing decision. Ralph does NOT decide its own route. It calls
#     worker/lib/squad-dispatch.js -- the same file the PowerShell CLI and the
#     watcher call -- so all three dispatchers produce the same decision for the
#     same input. See worker/lib/dispatch-decision.js.
#   * Durable claim BEFORE compute. A lease record is written to the GitHub lease
#     ledger before `az containerapp job start` is invoked (PRD #6: "claim and
#     session state are written before compute is requested"). A crash between
#     the two is repaired on the next run, not duplicated, because the lease is
#     keyed on the ISSUE rather than on the timestamped session name.
#   * Transactional per issue: build+validate the env, claim the lease, START the
#     ACA session job, and only THEN add the dispatch label. A failed start
#     releases the lease and leaves the issue UNLABELED so it is retried next run
#     instead of being permanently skipped.
#   * Failure isolation: one bad issue is logged and skipped; the batch keeps
#     going. No single failure aborts the remaining dispatches.
#   * No secret/prompt leakage: env building and `az`/`gh` output are suppressed;
#     only generic, issue-scoped status is logged. The lease record carries
#     identifiers, a route, and timestamps -- never a prompt or a secret ref.

# Authoritative list of session-managed env keys. These are stripped from the
# session job template snapshot before fresh per-execution values are overlaid,
# so a value baked into the template (or left over from earlier tooling) can
# never leak into a new execution. This list is mirrored in
# scripts/lib/session-env.ps1 ($script:SessionManagedEnvKeys). Keep the two in
# sync: scripts/validate.ps1 fails the build if they drift. Keep this array free
# of comments and inline text so the drift check can parse it.
RALPH_MANAGED_ENV_KEYS=(
  GITHUB_REPOSITORY
  GITHUB_REF
  SQUAD_MODE
  SESSION_NAME
  SQUAD_DEPLOYMENT_MODE
  SQUAD_POD_ID
  OTEL_SERVICE_NAME
  ENABLE_GITHUB_REMOTE
  GITHUB_TOKEN
  COPILOT_GITHUB_TOKEN
  OTEL_EXPORTER_OTLP_HEADERS
  SQUAD_PROMPT
  SQUAD_TEAM
  RUN_COPILOT_SMOKE
  PUSH_CHANGES
  OUTPUT_BRANCH
  PR_TITLE
  PR_BODY
  COMMIT_MESSAGE
  RALPH_LABELS
  RALPH_MAX_ISSUES
  SQUAD_DISPATCH_ROUTE
  SQUAD_DISPATCH_SOURCE
  SQUAD_LEASE_KEY
)

# Absolute path to the shared dispatch CLI (worker/lib/squad-dispatch.js). The
# worker image installs it next to this file; tests point at the repository copy.
squad_dispatch_cli() {
  if [[ -n "${SQUAD_DISPATCH_CLI:-}" ]]; then
    printf '%s' "$SQUAD_DISPATCH_CLI"
    return 0
  fi
  printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/squad-dispatch.js"
}

squad_dispatch_decide() {
  # Resolves THE routing decision for one unit of work and writes it to stdout as
  # JSON. Ralph never interprets the decision beyond `routing.action`; the
  # decision document itself is handed straight to `claim`, so a claim can never
  # be made against a route computed some other way.
  local session_id="$1" repository="$2" issue_number="${3:-}"
  local -a args=(
    "$(squad_dispatch_cli)" decide
    --session-id "$session_id"
    --dispatch-source ralph
    --repository "$repository"
  )
  if [[ -n "$issue_number" ]]; then
    args+=(--issue "$issue_number")
  fi
  node "${args[@]}"
}

squad_lease_claim() {
  # Writes the lease BEFORE compute is requested. Reads the decision on stdin.
  # Prints the claim outcome (created | repaired | active | completed) on stdout.
  local repository="$1" claim_json
  claim_json="$(node "$(squad_dispatch_cli)" claim --repository "$repository")" || return 1
  printf '%s' "$claim_json" | squad_json_field outcome
}

squad_lease_op() {
  # dispatched | heartbeat | complete | release | sweep, with output suppressed.
  local op="$1" repository="$2"
  shift 2
  node "$(squad_dispatch_cli)" "$op" --repository "$repository" "$@"
}

squad_json_field() {
  # Reads JSON on stdin and prints one dotted field. Empty string when absent.
  local field="$1"
  SQUAD_JSON_FIELD="$field" node -e '
const chunks = [];
process.stdin.on("data", (d) => chunks.push(d));
process.stdin.on("end", () => {
  let value;
  try {
    value = JSON.parse(chunks.join(""));
  } catch (err) {
    process.stdout.write("");
    return;
  }
  for (const part of String(process.env.SQUAD_JSON_FIELD).split(".")) {
    if (value === null || typeof value !== "object") { value = undefined; break; }
    value = value[part];
  }
  process.stdout.write(value === undefined || value === null ? "" : String(value));
});
'
}

# Provide a minimal logger when sourced outside entrypoint.sh (for example in
# tests). entrypoint.sh defines its own richer log() first, so this never
# overrides it.
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[squad-on-aca] %s\n' "$*"; }
fi

ralph_build_session_env() {
  # Builds the complete per-execution env for one dispatch.
  #
  # Reads:
  #   SJ_ENV  - the session job template's container env as a JSON array
  #             (name/value/secretRef entries).
  #   OV_*    - per-execution overrides; each OV_FOO becomes FOO=<value>.
  #   RALPH_MANAGED_ENV_KEYS - the authoritative managed-key list (global array).
  #
  # Writes a NUL-delimited list of NAME=VALUE tokens to stdout on success.
  #
  # Exits non-zero WITHOUT emitting a usable env when the template env is
  # malformed JSON, is not an array, or a required override is missing, so a
  # broken/incomplete env can never be dispatched.
  local managed_json="[" first=1 key
  for key in "${RALPH_MANAGED_ENV_KEYS[@]}"; do
    if [[ $first -eq 1 ]]; then first=0; else managed_json+=","; fi
    managed_json+="\"${key}\""
  done
  managed_json+="]"

  RALPH_MANAGED_JSON="$managed_json" node - <<'NODE'
const managed = new Set(JSON.parse(process.env.RALPH_MANAGED_JSON || '[]'));

let template;
try {
  template = JSON.parse(process.env.SJ_ENV || '[]');
} catch (err) {
  process.stderr.write('ralph: session job template env is malformed JSON; refusing to dispatch.\n');
  process.exit(1);
}
if (!Array.isArray(template)) {
  process.stderr.write('ralph: session job template env is not a JSON array; refusing to dispatch.\n');
  process.exit(1);
}

const merged = new Map();
for (const e of template) {
  if (!e || !e.name) continue;
  if (managed.has(e.name)) continue;
  merged.set(e.name, e.secretRef ? `secretref:${e.secretRef}` : String(e.value ?? ''));
}
for (const [k, v] of Object.entries(process.env)) {
  if (!k.startsWith('OV_')) continue;
  merged.set(k.slice(3), String(v ?? ''));
}

// A dispatch is only valid if it carries the core session identity and prompt.
const required = ['GITHUB_REPOSITORY', 'SQUAD_MODE', 'SESSION_NAME', 'SQUAD_PROMPT'];
const missing = required.filter((k) => !merged.get(k));
if (missing.length) {
  process.stderr.write(`ralph: refusing to dispatch; missing required env: ${missing.join(', ')}\n`);
  process.exit(1);
}

const out = [];
for (const [k, v] of merged) out.push(`${k}=${v}`);
process.stdout.write(out.join('\0'));
NODE
}

ralph_dispatch_issue() {
  # Dispatches a single issue transactionally. Returns 0 when the ACA session job
  # was started (whether or not labeling succeeded), non-zero when the issue was
  # NOT dispatched (env invalid or job start failed) so the caller can count it
  # and move on. A non-dispatched issue is never labeled.
  #
  # Requires these globals to be set by the caller:
  #   ACA_SESSION_JOB_NAME, AZURE_RESOURCE_GROUP, GITHUB_REPOSITORY,
  #   RALPH_DISPATCH_LABEL, RALPH_SESSION_JOB_ENV_JSON, RALPH_SESSION_JOB_IMAGE,
  #   RALPH_SESSION_JOB_CPU, RALPH_SESSION_JOB_MEMORY, RALPH_SESSION_JOB_CONTAINER
  local issue_number="$1" issue_title="$2" issue_url="$3"
  local session_name prompt env_file decision claim_outcome route lease_key
  local -a start_env

  session_name="issue-${issue_number}-$(date +%Y%m%d%H%M%S)"
  prompt="Ralph dispatched GitHub issue #${issue_number}: ${issue_title}

Issue URL: ${issue_url}

Use Squad to inspect the repository, work the issue if it is actionable, create a branch, commit changes, and open a pull request. If blocked, comment on the issue with the blocker and stop."

  # ONE routing decision, resolved by the shared dispatch core rather than by
  # any Ralph-local rule. A refused route (exit 65) is fail-closed: no lease, no
  # compute, no label.
  if ! decision="$(squad_dispatch_decide "$session_name" "$GITHUB_REPOSITORY" "$issue_number" 2>/dev/null)"; then
    log "Ralph: routing refused or unavailable for issue #${issue_number}; skipping without labeling."
    return 1
  fi
  route="$(printf '%s' "$decision" | squad_json_field routing.route)"
  lease_key="$(printf '%s' "$decision" | squad_json_field leaseKey)"
  if [[ -z "$route" || -z "$lease_key" ]]; then
    log "Ralph: routing decision for issue #${issue_number} was incomplete; skipping without labeling."
    return 1
  fi

  # CLAIM BEFORE COMPUTE. The lease is durable and keyed on the issue, so a
  # crash anywhere below repairs on the next run instead of double-dispatching.
  if ! claim_outcome="$(printf '%s' "$decision" | squad_lease_claim "$GITHUB_REPOSITORY" 2>/dev/null)"; then
    log "Ralph: could not claim a lease for issue #${issue_number}; skipping without labeling."
    return 1
  fi
  case "$claim_outcome" in
    active|completed)
      # Another dispatcher already owns (or finished) this work. Do NOT start a
      # second execution; just reconcile the label so the issue stops appearing
      # as a candidate. This is the crash-between-claim-and-label repair path.
      gh issue edit "$issue_number" --repo "$GITHUB_REPOSITORY" --add-label "$RALPH_DISPATCH_LABEL" >/dev/null 2>&1 || true
      log "Ralph: issue #${issue_number} already has a live lease (${claim_outcome}); not dispatching again."
      return 0
      ;;
    created|repaired) ;;
    *)
      log "Ralph: unexpected lease outcome for issue #${issue_number}; skipping without labeling."
      return 1
      ;;
  esac

  env_file="$(mktemp 2>/dev/null)" || {
    squad_lease_op release "$GITHUB_REPOSITORY" --lease-key "$lease_key" >/dev/null 2>&1 || true
    log "Ralph: could not allocate a temp file for issue #${issue_number}; skipping without labeling."
    return 1
  }

  # Build and VALIDATE the env first. stderr is suppressed so a malformed
  # template or missing value cannot leak env contents into the logs. If this
  # fails we skip the issue WITHOUT starting a job or adding a label.
  if ! SJ_ENV="$RALPH_SESSION_JOB_ENV_JSON" \
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
       OV_SQUAD_DISPATCH_ROUTE="$route" \
       OV_SQUAD_DISPATCH_SOURCE="ralph" \
       OV_SQUAD_LEASE_KEY="$lease_key" \
       ralph_build_session_env > "$env_file" 2>/dev/null
  then
    rm -f "$env_file"
    squad_lease_op release "$GITHUB_REPOSITORY" --lease-key "$lease_key" >/dev/null 2>&1 || true
    log "Ralph: could not build a valid env for issue #${issue_number}; skipping without labeling."
    return 1
  fi

  mapfile -d '' -t start_env < "$env_file"
  rm -f "$env_file"

  if [[ "${#start_env[@]}" -eq 0 ]]; then
    squad_lease_op release "$GITHUB_REPOSITORY" --lease-key "$lease_key" >/dev/null 2>&1 || true
    log "Ralph: env build for issue #${issue_number} produced no variables; skipping without labeling."
    return 1
  fi

  # Start the ACA session job BEFORE labeling. Output is suppressed so prompts
  # and secret references are never written to logs. A failed start releases the
  # lease and leaves the issue unlabeled so the next scheduled run retries it.
  if ! az containerapp job start \
        --name "$ACA_SESSION_JOB_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --image "$RALPH_SESSION_JOB_IMAGE" \
        --cpu "$RALPH_SESSION_JOB_CPU" \
        --memory "$RALPH_SESSION_JOB_MEMORY" \
        --container-name "$RALPH_SESSION_JOB_CONTAINER" \
        --env-vars "${start_env[@]}" >/dev/null 2>&1
  then
    squad_lease_op release "$GITHUB_REPOSITORY" --lease-key "$lease_key" >/dev/null 2>&1 || true
    log "Ralph: failed to start ACA session job for issue #${issue_number}; leaving it undispatched for retry."
    return 1
  fi

  # Compute is live: move the lease out of `claimed` so a concurrent dispatcher
  # sees an active owner rather than a repairable claim.
  squad_lease_op dispatched "$GITHUB_REPOSITORY" --lease-key "$lease_key" >/dev/null 2>&1 || true

  # Label ONLY after a confirmed start. A labeling failure here is non-fatal:
  # the job is already running, so we log it and let the (idempotent) next run
  # reconcile the label rather than treating the dispatch as failed.
  if ! gh issue edit "$issue_number" --repo "$GITHUB_REPOSITORY" --add-label "$RALPH_DISPATCH_LABEL" >/dev/null 2>&1; then
    log "Ralph: dispatched issue #${issue_number} to ${session_name} but could not add the '${RALPH_DISPATCH_LABEL}' label; it may be re-dispatched next run."
    return 0
  fi

  log "Ralph: dispatched issue #${issue_number} to ACA session job ${session_name}."
  return 0
}

run_ralph_dispatch() {
  # Dispatches every candidate issue independently. Requires the global array
  # `issue_rows` (tab-separated: number, title, url) plus the config globals
  # documented on ralph_dispatch_issue. A failure on one issue is counted and
  # logged; the loop always continues to the next issue.
  local row issue_number issue_title issue_url
  local dispatched=0 failed=0

  # Reclaim leases whose heartbeat has aged out before dispatching. Sweeping is
  # idempotent and never fatal: a sweep failure must not block new work.
  if ! squad_lease_op sweep "${GITHUB_REPOSITORY:-}" >/dev/null 2>&1; then
    log "Ralph: stale-lease sweep did not complete; continuing with dispatch."
  fi

  for row in "${issue_rows[@]}"; do
    IFS=$'\t' read -r issue_number issue_title issue_url <<< "$row"
    if ralph_dispatch_issue "$issue_number" "$issue_title" "$issue_url"; then
      dispatched=$((dispatched + 1))
    else
      failed=$((failed + 1))
    fi
  done
  log "Ralph dispatch complete: ${dispatched} dispatched, ${failed} failed of ${#issue_rows[@]} candidate issue(s)."
  return 0
}
