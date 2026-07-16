#!/usr/bin/env bash
# Integration tests for worker/lib/ralph-dispatch.sh transactional dispatch.
# Uses fake `az` and `gh` on PATH (real `node`, `mktemp`, `date`). No Azure or
# GitHub access is performed.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
LIB="${WORKER_DIR}/lib/ralph-dispatch.sh"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-ralph"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

echo "== ralph-dispatch.sh =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

# --- Fake az / gh -----------------------------------------------------------
# The fakes record every invocation (one line per call) to files under
# $FAKE_STATE_DIR so tests can assert exactly what was started / labeled.
FAKE_BIN="${TEST_TMP_ROOT}/bin"
mkdir -p "$FAKE_BIN"

cat > "${FAKE_BIN}/az" <<'AZ'
#!/usr/bin/env bash
# Fake `az`. Records `containerapp job start` calls and fails when the current
# --env-vars set contains SESSION_NAME=issue-${AZ_FAIL_ISSUE}-...
if [[ "${1:-}" == "containerapp" && "${2:-}" == "job" && "${3:-}" == "start" ]]; then
  # One fixed marker line per start call; args contain multi-line prompts, so
  # never echo "$*" (it would inflate line counts).
  echo "start" >> "${AZ_START_LOG}"
  if [[ -n "${AZ_FAIL_ISSUE:-}" ]]; then
    for arg in "$@"; do
      if [[ "$arg" == "SESSION_NAME=issue-${AZ_FAIL_ISSUE}-"* ]]; then
        echo "fake az: simulated start failure" >&2
        exit 1
      fi
    done
  fi
  exit 0
fi
# login / account set / anything else: succeed quietly.
exit 0
AZ

cat > "${FAKE_BIN}/gh" <<'GH'
#!/usr/bin/env bash
# Fake `gh`. Records `issue edit ... --add-label` calls with the issue number.
if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
  issue="${3:-}"
  printf '%s\n' "$issue" >> "${GH_LABEL_LOG}"
  exit 0
fi
exit 0
GH

chmod +x "${FAKE_BIN}/az" "${FAKE_BIN}/gh"
PATH="${FAKE_BIN}:${PATH}"

# --- Config globals the dispatch functions require --------------------------
export ACA_SESSION_JOB_NAME="caj-squad-aca-session"
export AZURE_RESOURCE_GROUP="rg-squad-test"
export GITHUB_REPOSITORY="octo/demo"
export RALPH_DISPATCH_LABEL="squad-aca:dispatched"
export RALPH_SESSION_JOB_IMAGE="ghcr.io/example/squad-worker:latest"
export RALPH_SESSION_JOB_CPU="1.0"
export RALPH_SESSION_JOB_MEMORY="2.0Gi"
export RALPH_SESSION_JOB_CONTAINER="squad-worker"
# A well-formed template env with one carried-forward var and a secret ref.
export RALPH_SESSION_JOB_ENV_JSON='[{"name":"ASPIRE_OTLP_GRPC_ENDPOINT","value":"http://ca-squad-aspire:18889"},{"name":"OTEL_EXPORTER_OTLP_HEADERS","secretRef":"otlp-headers"},{"name":"SESSION_NAME","value":"smoke-template"}]'

# shellcheck source=lib/ralph-dispatch.sh
source "$LIB"

reset_state() {
  AZ_START_LOG="${TEST_TMP_ROOT}/az-start.log"
  GH_LABEL_LOG="${TEST_TMP_ROOT}/gh-label.log"
  : > "$AZ_START_LOG"
  : > "$GH_LABEL_LOG"
  export AZ_START_LOG GH_LABEL_LOG
  unset AZ_FAIL_ISSUE
}

# ---------------------------------------------------------------------------
# 1. Success path: a valid dispatch starts the job once and labels the issue
#    exactly once.
# ---------------------------------------------------------------------------
reset_state
out="$(ralph_dispatch_issue 10 "Add a feature" "https://example/10" 2>&1)"
rc=$?
assert_eq "0" "$rc" "success: dispatch returns 0"
assert_eq "1" "$(grep -c '^start$' "$AZ_START_LOG")" "success: az job start called exactly once"
assert_eq "1" "$(grep -c '^10$' "$GH_LABEL_LOG")" "success: issue #10 labeled exactly once"
assert_contains "$out" "dispatched issue #10" "success: logs a dispatch confirmation"

# ---------------------------------------------------------------------------
# 2. Failed start leaves NO label (issue stays retryable).
# ---------------------------------------------------------------------------
reset_state
export AZ_FAIL_ISSUE=11
out="$(ralph_dispatch_issue 11 "Broken thing" "https://example/11" 2>&1)"
rc=$?
unset AZ_FAIL_ISSUE
assert_eq "1" "$rc" "failed start: dispatch returns non-zero"
assert_eq "1" "$(grep -c '^start$' "$AZ_START_LOG")" "failed start: az job start was attempted"
assert_eq "0" "$(grep -c '^11$' "$GH_LABEL_LOG")" "failed start: issue #11 was NOT labeled"
assert_contains "$out" "failed to start" "failed start: logs the start failure"

# ---------------------------------------------------------------------------
# 3. Malformed template env prevents dispatch entirely: no job start, no label,
#    and no prompt/secret leakage in output.
# ---------------------------------------------------------------------------
reset_state
saved_env_json="$RALPH_SESSION_JOB_ENV_JSON"
export RALPH_SESSION_JOB_ENV_JSON='{ this is not valid json'
out="$(ralph_dispatch_issue 12 "Env is broken" "https://example/12" 2>&1)"
rc=$?
export RALPH_SESSION_JOB_ENV_JSON="$saved_env_json"
assert_eq "1" "$rc" "malformed env: dispatch returns non-zero"
assert_eq "0" "$(grep -c '^start$' "$AZ_START_LOG")" "malformed env: az job start was NOT called"
assert_eq "0" "$(grep -c '^12$' "$GH_LABEL_LOG")" "malformed env: issue #12 was NOT labeled"
assert_not_contains "$out" "secretref:" "malformed env: does not leak secret references"
assert_not_contains "$out" "Issue URL" "malformed env: does not leak the prompt body"

# ---------------------------------------------------------------------------
# 4. Failure isolation across a batch: the first issue's start fails, the
#    remaining issues still dispatch and get labeled.
# ---------------------------------------------------------------------------
reset_state
export AZ_FAIL_ISSUE=20
issue_rows=(
  "$(printf '20\tFirst fails\thttps://example/20')"
  "$(printf '21\tSecond ok\thttps://example/21')"
  "$(printf '22\tThird ok\thttps://example/22')"
)
# Run under `set -e` to prove one failure cannot abort the batch in production.
out="$(set -e; run_ralph_dispatch 2>&1)"
rc=$?
unset AZ_FAIL_ISSUE
assert_eq "0" "$rc" "batch isolation: run_ralph_dispatch completes cleanly under set -e"
assert_eq "0" "$(grep -c '^20$' "$GH_LABEL_LOG")" "batch isolation: failed issue #20 not labeled"
assert_eq "1" "$(grep -c '^21$' "$GH_LABEL_LOG")" "batch isolation: issue #21 dispatched and labeled"
assert_eq "1" "$(grep -c '^22$' "$GH_LABEL_LOG")" "batch isolation: issue #22 dispatched and labeled"
assert_contains "$out" "2 dispatched, 1 failed" "batch isolation: summary counts dispatched vs failed"
unset issue_rows

# ---------------------------------------------------------------------------
# 5. Built env strips template session-managed keys and overlays fresh values:
#    the template's SESSION_NAME=smoke-template must NOT survive.
# ---------------------------------------------------------------------------
reset_state
env_out="$(SJ_ENV="$RALPH_SESSION_JOB_ENV_JSON" \
  OV_GITHUB_REPOSITORY="octo/demo" \
  OV_SQUAD_MODE="prompt" \
  OV_SESSION_NAME="issue-99-xyz" \
  OV_SQUAD_PROMPT="do the thing" \
  ralph_build_session_env | tr '\0' '\n')"
rc=$?
assert_eq "0" "$rc" "env build: valid env exits 0"
assert_contains "$env_out" "SESSION_NAME=issue-99-xyz" "env build: fresh SESSION_NAME overlaid"
assert_not_contains "$env_out" "SESSION_NAME=smoke-template" "env build: stale template SESSION_NAME stripped"
assert_contains "$env_out" "ASPIRE_OTLP_GRPC_ENDPOINT=http://ca-squad-aspire:18889" "env build: non-managed template var carried forward"

# ---------------------------------------------------------------------------
# 6. Missing a required override fails the env build (no dispatch possible).
# ---------------------------------------------------------------------------
reset_state
if SJ_ENV="[]" OV_GITHUB_REPOSITORY="octo/demo" OV_SQUAD_MODE="prompt" \
   ralph_build_session_env >/dev/null 2>&1; then
  build_rc=0
else
  build_rc=1
fi
assert_eq "1" "$build_rc" "env build: missing required SESSION_NAME/SQUAD_PROMPT fails"

test_summary
