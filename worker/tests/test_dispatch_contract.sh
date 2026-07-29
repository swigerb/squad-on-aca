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
  unset FAKE_GH_FAIL_PATH
  unset SQUAD_LEASE_CLAIM_TTL_SECONDS
  unset SQUAD_LEASE_RETENTION_SECONDS
  unset SQUAD_LEASE_SWEEP_MAX_READS
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
#
#    THIS IS THE BACK-TO-BACK CASE, deliberately. An earlier version of this
#    test inserted `dispatched` between the two claims, which meant the second
#    claim was decided by the ACTIVE_STATES branch -- and the `claimed` branch,
#    the one a real concurrent dispatcher actually hits, was never exercised.
#    Nothing may run between these two claims.
# ---------------------------------------------------------------------------
reset_state
decision="$(node "$CLI" decide --session-id issue-8-a --dispatch-source ralph --repository octo/demo --issue 8)"
first="$(printf '%s' "$decision" | node "$CLI" claim --repository octo/demo)"
other="$(node "$CLI" decide --session-id issue-8-b --dispatch-source watch --repository octo/demo --issue 8 | node "$CLI" claim --repository octo/demo)"
assert_contains "$first" '"outcome":"created"' "cross-dispatcher: the first claim creates the lease"
assert_contains "$other" '"outcome":"active"' "cross-dispatcher: a SECOND dispatcher claiming back-to-back is told the lease is active (no double dispatch)"
assert_not_contains "$other" '"outcome":"repaired"' "cross-dispatcher: a live claim is never adopted as a crashed one"
assert_contains "$other" '"dispatchSource":"ralph"' "cross-dispatcher: the lease still names its original owner"
assert_contains "$other" '"attempts":1' "cross-dispatcher: a losing claim does not bump the attempt count"

# The same rule must hold once compute really is running.
node "$CLI" dispatched --repository octo/demo --lease-key issue-8 >/dev/null
after_dispatch="$(node "$CLI" decide --session-id issue-8-c --dispatch-source local-cli --repository octo/demo --issue 8 | node "$CLI" claim --repository octo/demo)"
assert_contains "$after_dispatch" '"outcome":"active"' "cross-dispatcher: a dispatched lease is still active for a third claimer"

# ---------------------------------------------------------------------------
# 4b. A claim is adopted ONLY after it has been silent past the claim window.
#     The claim -> compute window is seconds; the session TTL is an hour. Using
#     the session TTL here would pin an issue for an hour after a dispatcher
#     died mid-window, and using no gate at all hands two dispatchers the same
#     lease. Both thresholds are asserted against the pinned clock.
# ---------------------------------------------------------------------------
reset_state
export SQUAD_LEASE_CLAIM_TTL_SECONDS="300"
node "$CLI" decide --session-id issue-13-a --dispatch-source ralph --repository octo/demo --issue 13 \
  | node "$CLI" claim --repository octo/demo >/dev/null
export SQUAD_LEASE_NOW="2024-05-01T00:04:00.000Z"   # 240s: inside the claim window
inside="$(node "$CLI" decide --session-id issue-13-b --dispatch-source local-cli --repository octo/demo --issue 13 | node "$CLI" claim --repository octo/demo)"
assert_contains "$inside" '"outcome":"active"' "claim window: a 4-minute-old claim is still owned (claim TTL 300s)"
export SQUAD_LEASE_NOW="2024-05-01T00:06:00.000Z"   # 360s: past the claim window
outside="$(node "$CLI" decide --session-id issue-13-c --dispatch-source local-cli --repository octo/demo --issue 13 | node "$CLI" claim --repository octo/demo)"
assert_contains "$outside" '"outcome":"repaired"' "claim window: a 6-minute-old claim IS adopted as abandoned"
assert_contains "$outside" '"attempts":2' "claim window: adopting reuses the SAME record and bumps attempts"
assert_contains "$outside" '"dispatchSource":"local-cli"' "claim window: the adopting dispatcher becomes the owner"
unset SQUAD_LEASE_CLAIM_TTL_SECONDS
export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"

# ---------------------------------------------------------------------------
# 4c. A `released` handback is still adoptable immediately -- there is no owner
#     to race -- and a `dispatched` lease whose heartbeat aged out is too.
# ---------------------------------------------------------------------------
reset_state
node "$CLI" decide --session-id issue-14-a --dispatch-source ralph --repository octo/demo --issue 14 \
  | node "$CLI" claim --repository octo/demo >/dev/null
node "$CLI" release --repository octo/demo --lease-key issue-14 --reason "compute-request-failed" >/dev/null
released_retry="$(node "$CLI" decide --session-id issue-14-b --dispatch-source ralph --repository octo/demo --issue 14 | node "$CLI" claim --repository octo/demo)"
assert_contains "$released_retry" '"outcome":"repaired"' "handback: a released lease is adopted immediately, with no waiting"

reset_state
node "$CLI" decide --session-id issue-15-a --dispatch-source ralph --repository octo/demo --issue 15 \
  | node "$CLI" claim --repository octo/demo >/dev/null
node "$CLI" dispatched --repository octo/demo --lease-key issue-15 >/dev/null
export SQUAD_LEASE_NOW="2024-05-01T00:30:00.000Z"
mid_run="$(node "$CLI" decide --session-id issue-15-b --dispatch-source ralph --repository octo/demo --issue 15 | node "$CLI" claim --repository octo/demo)"
assert_contains "$mid_run" '"outcome":"active"' "session TTL: a 30-minute-old execution is NOT adopted (the claim TTL must not apply to a running session)"
export SQUAD_LEASE_NOW="2024-05-01T02:00:00.000Z"
aged_out="$(node "$CLI" decide --session-id issue-15-c --dispatch-source ralph --repository octo/demo --issue 15 | node "$CLI" claim --repository octo/demo)"
assert_contains "$aged_out" '"outcome":"repaired"' "session TTL: an execution whose heartbeat aged out IS adopted"
export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"

# ---------------------------------------------------------------------------
# 5. Ordering by INDEX inside a single claim: the lease blob is written before
#    `claim` returns, so no caller can request compute first.
# ---------------------------------------------------------------------------
reset_state
node "$CLI" decide --session-id issue-9-a --dispatch-source local-cli --repository octo/demo --issue 9 \
  | node "$CLI" claim --repository octo/demo >/dev/null
write_idx="$(grep -n '^gh lease-write issue-9.json$' "$SQUAD_CALL_LOG" | head -n 1 | cut -d: -f1)"
read_idx="$(grep -n '^gh api GET repos/octo/demo/contents/leases/issue-9.json$' "$SQUAD_CALL_LOG" | head -n 1 | cut -d: -f1)"
assert_eq "1" "$([[ -n "$write_idx" ]] && echo 1 || echo 0)" "claim: writes the lease blob"
# Real ordering, both falsifiable:
#   * create-once requires reading before writing, so the GET must precede the PUT;
#   * the lease write is the LAST thing `claim` does, so nothing can be deferred
#     past it. (The previous assertion here compared a grep line number against
#     the file's line count, which is true by construction and could never fail.)
assert_eq "1" "$([[ -n "$read_idx" && -n "$write_idx" && "$read_idx" -lt "$write_idx" ]] && echo 1 || echo 0)" \
  "claim: reads the lease (index $read_idx) before writing it (index $write_idx) -- create-once, not blind overwrite"
last_idx="$(wc -l < "$SQUAD_CALL_LOG" | tr -d ' ')"
assert_eq "$last_idx" "$write_idx" "claim: the lease write is the LAST call the claim makes, so nothing is deferred past it"

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
#
#     The masked* modes are the ones that matter for ORDERING: each carries BOTH
#     a real-failure signature AND a "gone" token, so they are decided by the
#     deny list running FIRST. Without them, moving the deny list after the gone
#     list (the Sprint 3 B1 / Sprint 5 `cancel` defect) left this whole suite
#     green. masked403 is also the most likely real input: GitHub masks a
#     permission denial on a private resource as HTTP 404 / "Not Found".
#     `unrecognised` matches neither list and must fail CLOSED.
# ---------------------------------------------------------------------------
for mode in auth forbidden throttle network masked403 masked401 masked429 masked500 unrecognised; do
  reset_state
  export FAKE_GH_FAIL_MODE="$mode"
  out="$(node "$CLI" sweep --repository octo/demo 2>&1)"
  rc=$?
  unset FAKE_GH_FAIL_MODE
  assert_eq "1" "$rc" "failure classification: '${mode}' surfaces as a failure, not a clean sweep"
  assert_not_contains "$out" '"reclaimed"' "failure classification: '${mode}' produces no sweep result"
done

# ---------------------------------------------------------------------------
# 10b. The deny-list must decide, and WHICH rule decided must be observable.
#
#      Asserting only isGone/true-false cannot guard the ordering: for every
#      input where a single list matches, both orderings agree. classifyGhFailure
#      reports `decidedBy`, so swapping the two loops changes 'real-failure' to
#      'gone' and fails here even where the boolean would have agreed.
# ---------------------------------------------------------------------------
classify_decided_by() {
  CLASSIFY_TEXT="$1" node -e '
const lease = require(process.env.LEASE_LIB);
process.stdout.write(lease.classifyGhFailure({ exitCode: 1, stderr: process.env.CLASSIFY_TEXT, stdout: "" }).decidedBy);
'
}
export LEASE_LIB="${WORKER_DIR}/lib/dispatch-lease.js"

assert_eq "real-failure" "$(classify_decided_by 'gh: HTTP 403: Resource not accessible by integration (Not Found)')" \
  "deny-list first: a 403 that also says 'Not Found' is decided by the DENY list (a masked permission denial is not a 'gone')"
assert_eq "real-failure" "$(classify_decided_by 'gh: Bad credentials (HTTP 401) - Not Found')" \
  "deny-list first: a 401 that also says 'Not Found' is decided by the DENY list"
assert_eq "real-failure" "$(classify_decided_by 'gh: HTTP 429: API rate limit exceeded (the resource does not exist)')" \
  "deny-list first: a 429 that also says 'does not exist' is decided by the DENY list"
assert_eq "real-failure" "$(classify_decided_by 'gh: HTTP 502: Bad gateway - Not Found')" \
  "deny-list first: a 5xx that also says 'Not Found' is decided by the DENY list"
assert_eq "gone" "$(classify_decided_by 'gh: Not Found (HTTP 404)')" \
  "deny-list first: a plain 404 with no failure signature is still correctly 'gone'"
assert_eq "unrecognised" "$(classify_decided_by 'gh: the remote end did something nobody wrote down')" \
  "fail closed: an unrecognised failure is a failure, not a 'gone'"
assert_eq "gh-unavailable" "$(CLASSIFY_TEXT="x" node -e 'const l=require(process.env.LEASE_LIB);process.stdout.write(l.classifyGhFailure({exitCode:127,stderr:"gh: Not Found",stdout:""}).decidedBy)')" \
  "fail closed: a missing gh is never 'gone', even when its message says 'Not Found'"

# The same rule, driven through the REAL stack rather than the classifier alone.
# FAKE_GH_FAIL_PATH scopes the fault to ONE lease blob, so the directory listing
# still succeeds and the sweeper must surface the masked 403 on that record
# instead of skipping it as "gone" and reporting a clean sweep.
reset_state
node "$CLI" decide --session-id issue-60-a --dispatch-source ralph --repository octo/demo --issue 60 \
  | node "$CLI" claim --repository octo/demo >/dev/null
export FAKE_GH_FAIL_MODE="masked403"
export FAKE_GH_FAIL_PATH="leases/issue-60.json"
scoped_out="$(node "$CLI" sweep --repository octo/demo 2>&1)"
scoped_rc=$?
unset FAKE_GH_FAIL_MODE FAKE_GH_FAIL_PATH
assert_eq "1" "$scoped_rc" "scoped fault: a masked 403 on ONE lease fails the sweep instead of being read as 'gone'"
assert_contains "$scoped_out" "HTTP 403" "scoped fault: the sweep surfaces the underlying permission denial"
assert_not_contains "$scoped_out" '"outcome":"swept"' "scoped fault: no sweep result is emitted"

# ---------------------------------------------------------------------------
# 10c. LEDGER GROWTH IS BOUNDED. Nothing used to delete a lease record: every
#      run, smoke and Ralph issue minted a permanent blob. Terminal records past
#      the retention window are now pruned, so the ledger tracks work in flight
#      rather than work ever done.
# ---------------------------------------------------------------------------
reset_state
export SQUAD_LEASE_RETENTION_SECONDS="86400"
for n in 70 71 72 73 74 75; do
  node "$CLI" decide --session-id "issue-${n}-a" --dispatch-source ralph --repository octo/demo --issue "$n" \
    | node "$CLI" claim --repository octo/demo >/dev/null
  node "$CLI" complete --repository octo/demo --lease-key "issue-${n}" --state succeeded >/dev/null
done
lease_count_before="$(node "$CLI" list --repository octo/demo | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).leases.length)))')"
assert_eq "6" "$lease_count_before" "ledger bound: six completed leases exist before the retention window elapses"

# Inside the retention window a sweep must NOT delete anything: a lease is
# evidence, and deleting it early would let finished work be re-dispatched.
export SQUAD_LEASE_NOW="2024-05-01T06:00:00.000Z"
sweep_early="$(node "$CLI" sweep --repository octo/demo)"
assert_contains "$sweep_early" '"pruned":[]' "ledger bound: nothing is pruned inside the retention window"

export SQUAD_LEASE_NOW="2024-05-03T00:00:00.000Z"
sweep_prune="$(node "$CLI" sweep --repository octo/demo)"
lease_count_after="$(node "$CLI" list --repository octo/demo | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).leases.length)))')"
assert_contains "$sweep_prune" '"key":"issue-70"' "ledger bound: a terminal lease past the retention window IS pruned"
assert_eq "0" "$lease_count_after" "ledger bound: the ledger SHRINKS -- it is not append-only"
unset SQUAD_LEASE_RETENTION_SECONDS
export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"

# ---------------------------------------------------------------------------
# 10d. SWEEP COST IS BOUNDED. Ralph sweeps at the top of every run on a
#      five-minute cron -- 288 runs/day. A sweep that costs one API call per
#      lease exhausts GitHub's 5,000/hr budget once a few hundred leases have
#      accumulated, and the resulting 429 makes `claimLease` throw, which stops
#      dispatch for EVERY issue. So per-run cost must not scale with ledger size.
#
#      Proven by comparing the API-call count for two ledgers of very different
#      sizes under the same read budget. An O(n) sweep produces different counts.
# ---------------------------------------------------------------------------
sweep_api_calls_for() {
  # Builds a ledger of $1 live leases, then counts `gh api` calls in ONE sweep.
  local count="$1" i
  reset_state
  export SQUAD_LEASE_SWEEP_MAX_READS="3"
  for ((i = 0; i < count; i += 1)); do
    node "$CLI" decide --session-id "issue-8${i}-a" --dispatch-source ralph --repository octo/demo --issue "8${i}" \
      | node "$CLI" claim --repository octo/demo >/dev/null
  done
  : > "$SQUAD_CALL_LOG"
  node "$CLI" sweep --repository octo/demo >/dev/null
  grep -c '^gh api ' "$SQUAD_CALL_LOG"
}

small_calls="$(sweep_api_calls_for 4)"
large_calls="$(sweep_api_calls_for 16)"
unset SQUAD_LEASE_SWEEP_MAX_READS
assert_eq "$small_calls" "$large_calls" \
  "sweep bound: a 16-lease ledger costs the SAME number of API calls as a 4-lease ledger ($small_calls), so per-run cost is O(1) in ledger size"
assert_eq "4" "$large_calls" "sweep bound: one sweep costs 1 listing + at most SQUAD_LEASE_SWEEP_MAX_READS (3) reads"

# The budget must not silently drop work: a sweep reports how much of the ledger
# it covered, and its offset rotates with the clock so successive runs cover all
# of it. Without rotation a capped sweep would examine the same prefix forever.
reset_state
export SQUAD_LEASE_SWEEP_MAX_READS="2"
# Keep every claim comfortably inside its window across the three rotation
# steps, so this block measures COVERAGE and nothing else.
export SQUAD_LEASE_CLAIM_TTL_SECONDS="3600"
for n in 90 91 92 93 94 95; do
  node "$CLI" decide --session-id "issue-${n}-a" --dispatch-source ralph --repository octo/demo --issue "$n" \
    | node "$CLI" claim --repository octo/demo >/dev/null
done
capped="$(node "$CLI" sweep --repository octo/demo)"
assert_contains "$capped" '"examined":2' "sweep bound: the capped sweep examines exactly the budget"
assert_contains "$capped" '"total":6' "sweep bound: the capped sweep reports the FULL ledger size, so a partial pass is visible"
seen=""
for slot_time in "2024-05-01T00:00:00.000Z" "2024-05-01T00:05:00.000Z" "2024-05-01T00:10:00.000Z"; do
  export SQUAD_LEASE_NOW="$slot_time"
  seen="${seen}$(node "$CLI" sweep --repository octo/demo | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).skipped.map(x=>x.key).join("\n")))')"$'\n'
done
total_seen="$(printf '%s' "$seen" | grep -c '^issue-9')"
distinct_seen="$(printf '%s' "$seen" | grep '^issue-9' | sort -u | wc -l | tr -d ' ')"
assert_eq "6" "$total_seen" "sweep rotation: three capped sweeps examine 3 x 2 = 6 records"
assert_eq "6" "$distinct_seen" "sweep rotation: successive sweeps advance, so all 6 DISTINCT leases are covered rather than the same prefix repeatedly"
unset SQUAD_LEASE_SWEEP_MAX_READS
unset SQUAD_LEASE_CLAIM_TTL_SECONDS
export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"

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
