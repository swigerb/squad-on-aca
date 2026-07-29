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
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node mktemp date

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
  # Shared, ordered, cross-tool log. The fake `gh` appends to the same file, so
  # a test can assert that the lease write precedes the compute request BY INDEX
  # rather than merely asserting both happened.
  if [[ -n "${SQUAD_CALL_LOG:-}" ]]; then
    echo "az job-start" >> "${SQUAD_CALL_LOG}"
  fi
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
# Fake `gh`. Delegates to worker/tests/lib/fake-gh.js so the `issue edit` calls
# Ralph makes and the Contents/git-refs API calls the lease store makes are
# served by ONE implementation -- the same one the PowerShell harness uses.
exec node "${FAKE_GH_JS}" "$@"
GH

chmod +x "${FAKE_BIN}/az" "${FAKE_BIN}/gh"
PATH="${FAKE_BIN}:${PATH}"

# The lease store spawns `gh` directly. Point it at the same fake so a test can
# never reach the network, and so `gh` resolution does not depend on PATH order.
export FAKE_GH_JS="${TEST_DIR}/lib/fake-gh.js"
export SQUAD_GH_BIN="$FAKE_GH_JS"
export SQUAD_DISPATCH_CLI="${WORKER_DIR}/lib/squad-dispatch.js"
# Pin the clock and the TTL so lease staleness is decided by the test, not by
# how long the suite happens to take.
export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"
export SQUAD_LEASE_TTL_SECONDS="3600"

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
  SQUAD_CALL_LOG="${TEST_TMP_ROOT}/calls.log"
  FAKE_GH_STATE="${TEST_TMP_ROOT}/ghstate"
  : > "$AZ_START_LOG"
  : > "$GH_LABEL_LOG"
  : > "$SQUAD_CALL_LOG"
  # A fresh lease ledger per test: leases are durable BY DESIGN, so without this
  # every case after the first would see the previous case's claim.
  rm -rf "$FAKE_GH_STATE"
  mkdir -p "$FAKE_GH_STATE"
  export AZ_START_LOG GH_LABEL_LOG SQUAD_CALL_LOG FAKE_GH_STATE
  unset AZ_FAIL_ISSUE
  unset FAKE_GH_FAIL_MODE
  export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"
}

# Index (1-based) of the first line in the shared call log matching a pattern,
# or 0 when absent. Ordering assertions compare these indices.
call_index() {
  local pattern="$1"
  grep -n -- "$pattern" "$SQUAD_CALL_LOG" 2>/dev/null | head -n 1 | cut -d: -f1
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

# ---------------------------------------------------------------------------
# 7. Claim-before-compute ORDERING. Asserted by INDEX in the shared call log,
#    not by presence: a lease that is written after `az containerapp job start`
#    would satisfy a presence check while violating the PRD invariant "claim and
#    session state are written before compute is requested".
# ---------------------------------------------------------------------------
reset_state
ralph_dispatch_issue 30 "Ordered dispatch" "https://example/30" >/dev/null 2>&1
lease_idx="$(call_index '^gh lease-write issue-30.json$')"
start_idx="$(call_index '^az job-start$')"
assert_eq "1" "$([[ -n "$lease_idx" ]] && echo 1 || echo 0)" "ordering: a lease was written for issue #30"
assert_eq "1" "$([[ -n "$start_idx" ]] && echo 1 || echo 0)" "ordering: compute was requested for issue #30"
assert_eq "1" "$([[ -n "$lease_idx" && -n "$start_idx" && "$lease_idx" -lt "$start_idx" ]] && echo 1 || echo 0)" \
  "ordering: lease write index ($lease_idx) precedes compute request index ($start_idx)"

# ---------------------------------------------------------------------------
# 8. Duplicate dispatch is idempotent: a second Ralph run over the SAME issue
#    must not start a second execution, and must not re-label.
# ---------------------------------------------------------------------------
reset_state
ralph_dispatch_issue 31 "Only once" "https://example/31" >/dev/null 2>&1
out="$(ralph_dispatch_issue 31 "Only once" "https://example/31" 2>&1)"
rc=$?
assert_eq "0" "$rc" "duplicate: second dispatch reports success"
assert_eq "1" "$(grep -c '^start$' "$AZ_START_LOG")" "duplicate: az job start called exactly once across two runs"
assert_contains "$out" "already has a live lease" "duplicate: second run reports the existing lease"

# ---------------------------------------------------------------------------
# 9. Crash between claim and compute is REPAIRED, not duplicated. The first run
#    claims and then fails to start (leaving a `claimed`, never-dispatched
#    lease). The second run must adopt that lease and dispatch exactly once in
#    total -- not skip forever, and not create a second lease.
# ---------------------------------------------------------------------------
reset_state
export AZ_FAIL_ISSUE=32
ralph_dispatch_issue 32 "Crashed mid-flight" "https://example/32" >/dev/null 2>&1
unset AZ_FAIL_ISSUE
assert_eq "0" "$(grep -c '^32$' "$GH_LABEL_LOG")" "crash repair: the crashed run left issue #32 unlabeled"
: > "$AZ_START_LOG"
out="$(ralph_dispatch_issue 32 "Crashed mid-flight" "https://example/32" 2>&1)"
rc=$?
assert_eq "0" "$rc" "crash repair: the retry dispatches successfully"
assert_eq "1" "$(grep -c '^start$' "$AZ_START_LOG")" "crash repair: the retry starts compute exactly once"
assert_eq "1" "$(grep -c '^32$' "$GH_LABEL_LOG")" "crash repair: issue #32 labeled exactly once overall"
lease_count="$(node "$SQUAD_DISPATCH_CLI" list --repository "$GITHUB_REPOSITORY" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).leases.length)))')"
assert_eq "1" "$lease_count" "crash repair: exactly one lease record exists for issue #32"

# ---------------------------------------------------------------------------
# 9b. CONCURRENT dispatchers. Ralph's cron and an operator's `squad-aca ralph
#     run` overlap by design (the cron fires every five minutes and the manual
#     command is always available). If the other dispatcher is still inside its
#     own claim-to-compute window -- which spans mktemp, an env build that
#     shells to node and az, and the job start itself, i.e. SECONDS, not
#     milliseconds -- Ralph must NOT treat that live claim as a crashed one.
#
#     Two things are asserted, and the second is the subtle one:
#       * no second execution starts (the actual double-dispatch bug), and
#       * the issue is NOT labeled. Labeling here would retire an issue that
#         the OTHER dispatcher may still fail and release, silently dropping
#         the work. A contended claim is "come back next run", not "done".
# ---------------------------------------------------------------------------
reset_state
# Another dispatcher claims first and is still mid-flight (clock unmoved).
node "$SQUAD_DISPATCH_CLI" decide --session-id issue-35-other --dispatch-source local-cli \
  --repository "$GITHUB_REPOSITORY" --issue 35 \
  | node "$SQUAD_DISPATCH_CLI" claim --repository "$GITHUB_REPOSITORY" >/dev/null 2>&1
out="$(ralph_dispatch_issue 35 "Contended" "https://example/35" 2>&1)"
rc=$?
assert_eq "0" "$rc" "contended claim: Ralph reports success (the work is owned, not failed)"
assert_eq "0" "$(grep -c '^start$' "$AZ_START_LOG")" "contended claim: NO second execution starts while the other dispatcher holds a live claim"
assert_eq "0" "$(grep -c '^35$' "$GH_LABEL_LOG")" "contended claim: issue #35 is NOT labeled, so it stays retryable if the owner never dispatches"
assert_contains "$out" "skipping" "contended claim: logs that it skipped rather than dispatched"

# ...and once that window elapses without the owner reaching compute, the claim
# IS adoptable, so a genuine crash still self-heals rather than wedging.
export SQUAD_LEASE_NOW="2024-05-01T00:30:00.000Z"
out="$(ralph_dispatch_issue 35 "Contended" "https://example/35" 2>&1)"
rc=$?
export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"
assert_eq "0" "$rc" "abandoned claim: the retry after the claim window dispatches"
assert_eq "1" "$(grep -c '^start$' "$AZ_START_LOG")" "abandoned claim: compute starts exactly once in total across both runs"
assert_eq "1" "$(grep -c '^35$' "$GH_LABEL_LOG")" "abandoned claim: issue #35 labeled exactly once in total"

# ---------------------------------------------------------------------------
# 10. The sweeper reclaims a stale lease and is idempotent when run twice.
# ---------------------------------------------------------------------------
reset_state
ralph_dispatch_issue 33 "Goes stale" "https://example/33" >/dev/null 2>&1
# Move the clock past the TTL. The lease's heartbeat is pinned at claim time, so
# this is the only thing that makes it stale -- no sleeping, no wall clock.
export SQUAD_LEASE_NOW="2024-05-01T02:00:00.000Z"
sweep_one="$(node "$SQUAD_DISPATCH_CLI" sweep --repository "$GITHUB_REPOSITORY")"
sweep_two="$(node "$SQUAD_DISPATCH_CLI" sweep --repository "$GITHUB_REPOSITORY")"
assert_contains "$sweep_one" '"key":"issue-33","reason":"heartbeat-expired"' "sweeper: reclaims the stale lease"
assert_not_contains "$sweep_two" '"key":"issue-33","reason":"heartbeat-expired"' "sweeper: second run reclaims nothing (idempotent)"
assert_contains "$sweep_two" '"reclaimed":[]' "sweeper: second run reports an empty reclaim set"

# ---------------------------------------------------------------------------
# 11. Cleanup under an auth failure THROWS instead of reporting success.
#     Idempotency is not "ignore every failure": a 401 must never be read as
#     "already cleaned", or a sweeper would report tearing down leases it never
#     touched. Mirrors Test-AcaJobExecutionGone's deny-list-first rule.
# ---------------------------------------------------------------------------
reset_state
ralph_dispatch_issue 34 "Auth fails later" "https://example/34" >/dev/null 2>&1
export FAKE_GH_FAIL_MODE=auth
sweep_err="$(node "$SQUAD_DISPATCH_CLI" sweep --repository "$GITHUB_REPOSITORY" 2>&1)"
sweep_rc=$?
complete_err="$(node "$SQUAD_DISPATCH_CLI" complete --repository "$GITHUB_REPOSITORY" --lease-key issue-34 --state succeeded 2>&1)"
complete_rc=$?
unset FAKE_GH_FAIL_MODE
assert_eq "1" "$sweep_rc" "auth failure: sweep exits non-zero instead of reporting success"
assert_contains "$sweep_err" "HTTP 401" "auth failure: sweep surfaces the credential fault"
assert_eq "1" "$complete_rc" "auth failure: completing a lease exits non-zero"
assert_contains "$complete_err" "HTTP 401" "auth failure: completion surfaces the credential fault"

# ---------------------------------------------------------------------------
# 12. An externally-deleted lease is SUCCESS (the idempotent half of the rule
#     above), so a repaired or manually cleared ledger does not wedge dispatch.
# ---------------------------------------------------------------------------
reset_state
gone_out="$(node "$SQUAD_DISPATCH_CLI" complete --repository "$GITHUB_REPOSITORY" --lease-key issue-404 --state succeeded 2>&1)"
gone_rc=$?
assert_eq "0" "$gone_rc" "already gone: completing a nonexistent lease succeeds"
assert_contains "$gone_out" '"outcome":"gone"' "already gone: reported as gone rather than as a failure"

# ---------------------------------------------------------------------------
# 13. Dispatch does not leak secrets or prompt bodies into the lease record.
# ---------------------------------------------------------------------------
reset_state
ralph_dispatch_issue 35 "Sensitive" "https://example/35" >/dev/null 2>&1
lease_json="$(node "$SQUAD_DISPATCH_CLI" list --repository "$GITHUB_REPOSITORY")"
assert_not_contains "$lease_json" "secretref:" "lease record: contains no secret references"
assert_not_contains "$lease_json" "Issue URL" "lease record: contains no prompt body"
assert_contains "$lease_json" '"dispatchSource":"ralph"' "lease record: records the dispatcher source"
assert_contains "$lease_json" '"route":"aca-job"' "lease record: records the resolved route"

test_summary
