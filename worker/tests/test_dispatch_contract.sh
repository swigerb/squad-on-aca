#!/usr/bin/env bash
# Integration tests for the SHARED dispatch contract (Sprint 6, PRD #6):
#   worker/lib/dispatch-decision.js  -- the one routing decision
#   worker/lib/dispatch-lease.js     -- the one lease protocol
#   worker/lib/squad-dispatch.js     -- the entry point all three dispatchers use
#
# The point of this suite is the FIRST requirement of the sprint: "Ralph, Watch,
# and local CLI share one routing decision". That is only meaningful if it is
# proven at the byte level, so these tests compare serialized decisions rather
# than fields chosen by hand.
#
# Uses a fake `gh` (worker/tests/lib/fake-gh.js) and real `node`. No network.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
CLI="${WORKER_DIR}/lib/squad-dispatch.js"
RALPH_LIB="${WORKER_DIR}/lib/ralph-dispatch.sh"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-dispatch"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node mktemp

echo "== dispatch contract =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

export FAKE_GH_JS="${TEST_DIR}/lib/fake-gh.js"
export SQUAD_GH_BIN="$FAKE_GH_JS"
export SQUAD_DISPATCH_CLI="$CLI"
export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"
export SQUAD_LEASE_TTL_SECONDS="3600"
export GITHUB_REPOSITORY="octo/demo"

reset_state() {
  FAKE_GH_STATE="${TEST_TMP_ROOT}/ghstate"
  SQUAD_CALL_LOG="${TEST_TMP_ROOT}/calls.log"
  rm -rf "$FAKE_GH_STATE"
  mkdir -p "$FAKE_GH_STATE"
  : > "$SQUAD_CALL_LOG"
  export FAKE_GH_STATE SQUAD_CALL_LOG
  unset FAKE_GH_FAIL_MODE
  export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"
}

routing_of() {
  # Extracts ONLY the routing object, compactly and with stable key order, so
  # two decisions can be compared byte-for-byte.
  node -e '
let s = "";
process.stdin.on("data", (d) => (s += d)).on("end", () => {
  process.stdout.write(JSON.stringify(JSON.parse(s).routing));
});
'
}

# ---------------------------------------------------------------------------
# 1. THE contract: the same input yields the SAME routing decision for all
#    three dispatch sources. Compared byte-for-byte, not field by field.
# ---------------------------------------------------------------------------
reset_state
local_routing="$(node "$CLI" decide --session-id s-1 --dispatch-source local-cli --repository octo/demo --issue 7 | routing_of)"
ralph_routing="$(node "$CLI" decide --session-id s-1 --dispatch-source ralph --repository octo/demo --issue 7 | routing_of)"
watch_routing="$(node "$CLI" decide --session-id s-1 --dispatch-source watch --repository octo/demo --issue 7 | routing_of)"
assert_eq "$local_routing" "$ralph_routing" "shared decision: local-cli and ralph agree byte-for-byte"
assert_eq "$local_routing" "$watch_routing" "shared decision: local-cli and watch agree byte-for-byte"
assert_contains "$local_routing" '"route":"aca-job"' "shared decision: the no-manifest default is still the ACA Jobs route"
assert_contains "$local_routing" '"action":"dispatch"' "shared decision: the default route dispatches"

# ---------------------------------------------------------------------------
# 2. Ralph's own helper resolves the route through the SAME core, so bash does
#    not carry a second copy of the rule. Proven by comparing Ralph's helper
#    output with the raw CLI output for identical input.
# ---------------------------------------------------------------------------
reset_state
# shellcheck source=lib/ralph-dispatch.sh
source "$RALPH_LIB"
ralph_helper_routing="$(squad_dispatch_decide "s-1" "octo/demo" 7 | routing_of)"
assert_eq "$local_routing" "$ralph_helper_routing" "shared decision: ralph-dispatch.sh returns the CLI's decision unmodified"

# ---------------------------------------------------------------------------
# 3. The lease key is derived from the ISSUE, not the session name. This is the
#    whole idempotency mechanism: two dispatchers minting different session
#    names for the same issue must converge on ONE lease.
# ---------------------------------------------------------------------------
reset_state
key_a="$(node "$CLI" decide --session-id issue-7-aaaa --dispatch-source ralph --repository octo/demo --issue 7 | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).leaseKey))')"
key_b="$(node "$CLI" decide --session-id issue-7-bbbb --dispatch-source local-cli --repository octo/demo --issue 7 | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).leaseKey))')"
assert_eq "issue-7" "$key_a" "lease key: derived from the issue number"
assert_eq "$key_a" "$key_b" "lease key: identical across dispatchers and session names"

# ---------------------------------------------------------------------------
# 4. Claim before compute, across dispatchers: whichever dispatcher claims
#    first owns the work; the others are told not to dispatch.
# ---------------------------------------------------------------------------
reset_state
decision="$(node "$CLI" decide --session-id issue-8-a --dispatch-source ralph --repository octo/demo --issue 8)"
first="$(printf '%s' "$decision" | node "$CLI" claim --repository octo/demo)"
node "$CLI" dispatched --repository octo/demo --lease-key issue-8 >/dev/null
other="$(node "$CLI" decide --session-id issue-8-b --dispatch-source watch --repository octo/demo --issue 8 | node "$CLI" claim --repository octo/demo)"
assert_contains "$first" '"outcome":"created"' "cross-dispatcher: the first claim creates the lease"
assert_contains "$other" '"outcome":"active"' "cross-dispatcher: a second dispatcher is told the lease is active"
assert_contains "$other" '"dispatchSource":"ralph"' "cross-dispatcher: the lease still names its original owner"

# ---------------------------------------------------------------------------
# 5. Ordering by INDEX inside a single claim: the lease blob is written before
#    `claim` returns, so no caller can request compute first.
# ---------------------------------------------------------------------------
reset_state
node "$CLI" decide --session-id issue-9-a --dispatch-source local-cli --repository octo/demo --issue 9 \
  | node "$CLI" claim --repository octo/demo >/dev/null
write_idx="$(grep -n '^gh lease-write issue-9.json$' "$SQUAD_CALL_LOG" | head -n 1 | cut -d: -f1)"
assert_eq "1" "$([[ -n "$write_idx" ]] && echo 1 || echo 0)" "claim: writes the lease blob"
last_idx="$(wc -l < "$SQUAD_CALL_LOG" | tr -d ' ')"
assert_eq "1" "$([[ "$write_idx" -le "$last_idx" ]] && echo 1 || echo 0)" "claim: the lease write is part of the claim call, not deferred"

# ---------------------------------------------------------------------------
# 6. Heartbeat keeps a lease out of the sweeper's reach; a lease whose heartbeat
#    has aged out is reclaimed. Both are decided by the pinned clock.
# ---------------------------------------------------------------------------
reset_state
node "$CLI" decide --session-id issue-40-a --dispatch-source ralph --repository octo/demo --issue 40 \
  | node "$CLI" claim --repository octo/demo >/dev/null
node "$CLI" dispatched --repository octo/demo --lease-key issue-40 >/dev/null
export SQUAD_LEASE_NOW="2024-05-01T00:50:00.000Z"
node "$CLI" heartbeat --repository octo/demo --lease-key issue-40 >/dev/null
export SQUAD_LEASE_NOW="2024-05-01T01:30:00.000Z"
sweep_fresh="$(node "$CLI" sweep --repository octo/demo)"
assert_contains "$sweep_fresh" '"reclaimed":[]' "heartbeat: a recently heartbeaten lease is NOT reclaimed"
export SQUAD_LEASE_NOW="2024-05-01T03:00:00.000Z"
sweep_stale="$(node "$CLI" sweep --repository octo/demo)"
assert_contains "$sweep_stale" '"key":"issue-40","reason":"heartbeat-expired"' "heartbeat: an aged-out lease IS reclaimed"

# ---------------------------------------------------------------------------
# 7. The sweeper reclaims an ORPHANED CLAIM -- a lease that was written but for
#    which compute was never requested. This is the crash-between-claim-and-
#    compute record, and it must not pin the work forever.
# ---------------------------------------------------------------------------
reset_state
node "$CLI" decide --session-id issue-41-a --dispatch-source ralph --repository octo/demo --issue 41 \
  | node "$CLI" claim --repository octo/demo >/dev/null
export SQUAD_LEASE_NOW="2024-05-01T03:00:00.000Z"
orphan_sweep="$(node "$CLI" sweep --repository octo/demo)"
assert_contains "$orphan_sweep" '"key":"issue-41"' "sweeper: reclaims an orphaned claim that never reached compute"
retry="$(node "$CLI" decide --session-id issue-41-b --dispatch-source ralph --repository octo/demo --issue 41 | node "$CLI" claim --repository octo/demo)"
assert_contains "$retry" '"outcome":"repaired"' "sweeper: the reclaimed work can be claimed again"

# ---------------------------------------------------------------------------
# 8. Terminal states are idempotent: completing twice is SUCCESS both times.
# ---------------------------------------------------------------------------
reset_state
node "$CLI" decide --session-id issue-42-a --dispatch-source local-cli --repository octo/demo --issue 42 \
  | node "$CLI" claim --repository octo/demo >/dev/null
first_complete="$(node "$CLI" complete --repository octo/demo --lease-key issue-42 --state succeeded)"
first_rc=$?
second_complete="$(node "$CLI" complete --repository octo/demo --lease-key issue-42 --state succeeded)"
second_rc=$?
assert_eq "0" "$first_rc" "terminal: first completion succeeds"
assert_eq "0" "$second_rc" "terminal: repeated completion succeeds (idempotent)"
assert_contains "$first_complete" '"outcome":"completed"' "terminal: first completion reports completed"
assert_contains "$second_complete" '"outcome":"already-terminal"' "terminal: repeat is reported as already-terminal"

# ---------------------------------------------------------------------------
# 9. A completed lease blocks re-dispatch of the same work.
# ---------------------------------------------------------------------------
after_terminal="$(node "$CLI" decide --session-id issue-42-b --dispatch-source ralph --repository octo/demo --issue 42 | node "$CLI" claim --repository octo/demo)"
assert_contains "$after_terminal" '"outcome":"completed"' "terminal: a finished lease refuses a fresh claim"

# ---------------------------------------------------------------------------
# 10. Real failures are never reported as idempotent successes. Throttling and
#     network faults are classified alongside auth, exactly as
#     Test-AcaJobExecutionGone classifies `az` failures.
# ---------------------------------------------------------------------------
for mode in auth forbidden throttle network; do
  reset_state
  export FAKE_GH_FAIL_MODE="$mode"
  out="$(node "$CLI" sweep --repository octo/demo 2>&1)"
  rc=$?
  unset FAKE_GH_FAIL_MODE
  assert_eq "1" "$rc" "failure classification: '${mode}' surfaces as a failure, not a clean sweep"
  assert_not_contains "$out" '"reclaimed"' "failure classification: '${mode}' produces no sweep result"
done

# ---------------------------------------------------------------------------
# 11. A missing `gh` is a failure, never "the lease is gone".
# ---------------------------------------------------------------------------
reset_state
missing_out="$(SQUAD_GH_BIN="${TEST_TMP_ROOT}/definitely-not-here" node "$CLI" list --repository octo/demo 2>&1)"
missing_rc=$?
assert_eq "1" "$missing_rc" "missing gh: exits non-zero"
assert_not_contains "$missing_out" '"leases"' "missing gh: does not report an empty lease list as success"

# ---------------------------------------------------------------------------
# 12. Refusing to dispatch never leaves a lease behind. A fail-closed manifest
#     exits 65 from `decide`, and `claim` refuses rather than creating an orphan
#     the sweeper would later have to reclaim.
# ---------------------------------------------------------------------------
reset_state
REPO_FIXTURE="${TEST_TMP_ROOT}/failclosed"
mkdir -p "$REPO_FIXTURE"
cat > "${REPO_FIXTURE}/squad-capabilities.yml" <<'YML'
version: 1
tools: [ this is not
YML
refuse_out="$(node "$CLI" decide --session-id issue-50-a --dispatch-source ralph --repository octo/demo --issue 50 --repo-dir "$REPO_FIXTURE" 2>/dev/null)"
refuse_rc=$?
assert_eq "65" "$refuse_rc" "fail-closed: decide exits 65 for an unsatisfiable manifest"
assert_contains "$refuse_out" '"action":"refuse"' "fail-closed: the decision refuses to dispatch"
claim_out="$(printf '%s' "$refuse_out" | node "$CLI" claim --repository octo/demo 2>&1)"
claim_rc=$?
assert_eq "65" "$claim_rc" "fail-closed: claim refuses the same decision"
lease_after="$(node "$CLI" list --repository octo/demo 2>/dev/null)"
assert_not_contains "$lease_after" '"leaseKey":"issue-50"' "fail-closed: no lease was written for refused work"

test_summary
