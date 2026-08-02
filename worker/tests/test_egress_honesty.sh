#!/usr/bin/env bash
# Egress honesty (capability-manifest future-work sprint 3).
#
# The defect this suite exists for: the decision used to report a declared
# network destination as SATISFIED on the ACA Jobs plane, which has no
# per-execution network control of any kind. `defaultWorker.egress` in the
# catalog is {defaultAction: Allow, hostRules: []}, so egressAllows() returns
# true for any host, and the decision came back with
# `unsatisfiedEgressHosts: []` and no field distinguishing "this plane will
# enforce your egress" from "this plane will ignore it".
#
# What is asserted here, and why each assertion is written the way it is:
#
#   * VALUES, NOT SHAPES. Every check reads the actual field value out of the
#     decision. An assertion that only checked `route: aca-job` would stay green
#     with egressEnforced hard-coded either way, which is the failure mode that
#     has cost this repository real defects.
#   * BOTH DIRECTIONS. A false claim is satisfied by hard-coding false. Every
#     boolean claim below is paired with a case that must go the other way.
#   * POLICY, NOT ROUTE NAME. A test-local catalog gives the DEFAULT worker a
#     default-deny egress policy. If egressEnforced were derived from the route
#     name ("aca-job" => false) rather than from the selected profile's
#     egress.defaultAction, that case fails. Without it the field would be a
#     restatement of the route and would add nothing.
#   * THE ROUTE DOES NOT MOVE. ACA Jobs is the unconditional default and the
#     rollback path. A repository that adds two advisory lines to its manifest
#     must still dispatch. That guard is asserted here explicitly.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WORKER_DIR}/.." && pwd)"
RESOLVER="${WORKER_DIR}/lib/resolve-capability-route.js"
DISPATCH="${WORKER_DIR}/lib/squad-dispatch.js"
PREFLIGHT="${WORKER_DIR}/lib/squad-capability-preflight.sh"
CATALOG="${REPO_ROOT}/config/sandbox-classes.json"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-egress-honesty"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== egress honesty =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

# A distinctive, obviously-not-real host. It is the probe for the redaction
# assertions: if it turns up on an operator-facing surface, manifest text is
# reaching a place it must not.
ADVISORY_HOST="advisory-token-zzz.example.net"

make_repo() {
  local dir="${TEST_TMP_ROOT}/repo-$$-${RANDOM}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# Reads one field out of a decision document. Parsed with node rather than
# grepped, so an assertion cannot pass on a substring that happens to appear
# somewhere else in the JSON.
field() {
  local json="$1" path="$2"
  printf '%s' "$json" | node -e '
let raw = "";
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  let doc;
  try { doc = JSON.parse(raw); } catch (err) { process.stdout.write("PARSE-ERROR"); return; }
  let cur = doc;
  for (const key of process.argv[1].split(".")) {
    if (cur === null || cur === undefined) { process.stdout.write("MISSING"); return; }
    cur = cur[key];
  }
  if (cur === undefined) { process.stdout.write("MISSING"); return; }
  process.stdout.write(Array.isArray(cur) ? cur.join(",") : String(cur));
});
' "$path"
}

resolve() {
  local repo="$1" catalog="${2:-$CATALOG}"
  node "$RESOLVER" "$repo" --catalog "$catalog" --pretty 2>&1
}

# --- 1. Criterion 1: an egress-declaring manifest on the aca-job route --------
#
# The exact reproduction from ADR 0003, finding 3: a tool the default worker
# already has, plus a destination nothing will enforce.

repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: git\n    required: true\negress:\n  - host: %s\n    reason: probe\n' "$ADVISORY_HOST" \
  > "${repo}/squad-capabilities.yml"
aca_job_decision="$(resolve "$repo")"

assert_eq "aca-job" "$(field "$aca_job_decision" "route")" \
  "routing: a manifest declaring only advisory egress still dispatches to aca-job"
assert_eq "default-profile-satisfies-manifest" "$(field "$aca_job_decision" "reason")" \
  "routing: the advisory-egress manifest keeps the default-profile reason code"
assert_eq "false" "$(field "$aca_job_decision" "egressEnforced")" \
  "egress honesty: an egress-declaring manifest on the aca-job route reports egressEnforced false"
assert_eq "$ADVISORY_HOST" "$(field "$aca_job_decision" "egressAdvisoryHosts")" \
  "egress honesty: the unenforced destination is listed in egressAdvisoryHosts"
assert_eq "$ADVISORY_HOST" "$(field "$aca_job_decision" "egressHosts")" \
  "egress honesty: the declared destination is still reported as declared"

# The old defect stated positively: the decision reported an empty unsatisfied
# set and nothing else, which a consumer could only read as "satisfied". The
# unsatisfied set still means what it always meant -- "no approved class permits
# this" -- and is still empty here; what has changed is that the decision now
# also carries the enforcement claim, so the two cannot be confused.
assert_eq "" "$(field "$aca_job_decision" "unsatisfiedEgressHosts")" \
  "egress honesty: unsatisfiedEgressHosts keeps its documented meaning (no approved class permits it)"
assert_contains "$aca_job_decision" '"egressEnforced": false' \
  "egress honesty: the emitted decision carries egressEnforced"
assert_contains "$aca_job_decision" '"egressAdvisoryHosts"' \
  "egress honesty: the emitted decision carries egressAdvisoryHosts"

compact="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" 2>&1)"
assert_contains "$compact" '"unsatisfiedEgressHosts":[],"egressEnforced":false,"egressAdvisoryHosts":["'"$ADVISORY_HOST"'"],"catalogSchemaVersion":1' \
  "egress honesty: the new fields are emitted in the documented key order"
rm -rf "$repo"

# --- 2. Criterion 2: the same host on an enforcing plane ----------------------
#
# python3 forces the approved sandbox-python-3-12 class, whose template is
# default-deny and permits pypi.org. Same declaration shape, opposite verdict --
# which is what stops a hard-coded `false` from passing section 1.

repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: python3\n    required: true\n  - name: pip3\n    required: true\negress:\n  - host: pypi.org\n    reason: package installs\n' \
  > "${repo}/squad-capabilities.yml"
sandbox_decision="$(resolve "$repo")"

assert_eq "sandbox" "$(field "$sandbox_decision" "route")" \
  "egress honesty: the enforcing case actually reaches the sandbox plane"
assert_eq "sandbox-python-3-12" "$(field "$sandbox_decision" "sandboxClass")" \
  "egress honesty: the enforcing case selects the default-deny class"
assert_eq "true" "$(field "$sandbox_decision" "egressEnforced")" \
  "egress honesty: an egress-declaring manifest routed to an approved sandbox class reports egressEnforced true"
assert_eq "" "$(field "$sandbox_decision" "egressAdvisoryHosts")" \
  "egress honesty: an enforced destination is NOT listed as advisory"
rm -rf "$repo"

# --- 3. Criterion 3: nothing declared is not the same as unenforced -----------

repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: git\n    required: true\n' > "${repo}/squad-capabilities.yml"
no_egress_decision="$(resolve "$repo")"
assert_eq "aca-job" "$(field "$no_egress_decision" "route")" \
  "egress honesty: a manifest declaring no egress still routes to aca-job"
assert_eq "true" "$(field "$no_egress_decision" "egressEnforced")" \
  "egress honesty: a manifest declaring no egress reports egressEnforced true"
assert_eq "" "$(field "$no_egress_decision" "egressAdvisoryHosts")" \
  "egress honesty: a manifest declaring no egress has an empty advisory list"
rm -rf "$repo"

repo="$(make_repo)"
no_manifest_decision="$(resolve "$repo")"
assert_eq "no-manifest" "$(field "$no_manifest_decision" "reason")" \
  "egress honesty: the no-manifest path is unchanged"
assert_eq "true" "$(field "$no_manifest_decision" "egressEnforced")" \
  "egress honesty: no manifest at all reports egressEnforced true"
assert_eq "" "$(field "$no_manifest_decision" "egressAdvisoryHosts")" \
  "egress honesty: no manifest at all has an empty advisory list"
rm -rf "$repo"

# --- 4. The flag reads the POLICY, not the route name ------------------------
#
# A test-local catalog whose DEFAULT worker carries a real default-deny policy.
# The route is still aca-job -- the profile satisfies everything -- so a flag
# derived from the route name would report false here. A flag derived from
# egress.defaultAction reports true. This is the case that makes the field
# something other than a restatement of `route`.

cat > "${TEST_TMP_ROOT}/catalog-default-deny.json" <<JSON
{
  "schemaVersion": 1,
  "provisional": false,
  "defaultWorker": {
    "id": "aca-job-default",
    "tools": ["git"],
    "credentials": [],
    "egress": {
      "defaultAction": "Deny",
      "trafficInspection": "Full",
      "hostRules": [{ "pattern": "${ADVISORY_HOST}", "action": "Allow" }]
    }
  },
  "classes": []
}
JSON

repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: git\n    required: true\negress:\n  - host: %s\n    reason: probe\n' "$ADVISORY_HOST" \
  > "${repo}/squad-capabilities.yml"
deny_decision="$(resolve "$repo" "${TEST_TMP_ROOT}/catalog-default-deny.json")"

assert_eq "aca-job" "$(field "$deny_decision" "route")" \
  "egress honesty: the default-deny catalog case still resolves to aca-job (so the route name cannot be what changed)"
assert_eq "true" "$(field "$deny_decision" "egressEnforced")" \
  "egress honesty: a default profile with defaultAction Deny reports egressEnforced true on the aca-job route"
assert_eq "" "$(field "$deny_decision" "egressAdvisoryHosts")" \
  "egress honesty: a default profile with defaultAction Deny does not report a permitted host as advisory"
rm -rf "$repo"

# The negative half of the same catalog: a host the default-deny template does
# NOT permit cannot reach aca-job at all, so "enforced" is never claimed for a
# destination the policy rejects.
repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: git\n    required: true\negress:\n  - host: blocked.example.org\n    reason: probe\n' \
  > "${repo}/squad-capabilities.yml"
blocked_decision="$(resolve "$repo" "${TEST_TMP_ROOT}/catalog-default-deny.json")"
assert_eq "fail-closed" "$(field "$blocked_decision" "route")" \
  "egress honesty: a default-deny profile that does not permit a host does not route to aca-job"
assert_eq "blocked.example.org" "$(field "$blocked_decision" "unsatisfiedEgressHosts")" \
  "egress honesty: the rejected host is reported as unsatisfied"
assert_eq "false" "$(field "$blocked_decision" "egressEnforced")" \
  "egress honesty: a fail-closed route never claims enforcement for a declared destination"
rm -rf "$repo"

# --- 5. The dispatch decision surfaces the claim, as a COUNT ------------------

repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: git\n    required: true\negress:\n  - host: %s\n    reason: probe\n' "$ADVISORY_HOST" \
  > "${repo}/squad-capabilities.yml"
dispatch_out="$(node "$DISPATCH" decide --session-id s-egress --dispatch-source local-cli \
  --repository octo/demo --issue 7 --repo-dir "$repo" --catalog "$CATALOG" 2>/dev/null)"
dispatch_rc=$?

assert_eq "0" "$dispatch_rc" "dispatch: an advisory-egress manifest still produces a dispatchable decision"
assert_eq "dispatch" "$(field "$dispatch_out" "routing.action")" \
  "dispatch: an advisory-egress manifest is dispatched, not refused"
assert_eq "aca-job" "$(field "$dispatch_out" "routing.executionMode")" \
  "dispatch: the execution mode is unchanged"
assert_eq "false" "$(field "$dispatch_out" "routing.egressEnforced")" \
  "egress honesty: the dispatch decision carries egressEnforced"
assert_eq "1" "$(field "$dispatch_out" "routing.egressAdvisoryHostCount")" \
  "egress honesty: the dispatch decision states the COUNT of unenforced destinations"
assert_eq "$ADVISORY_HOST" "$(field "$dispatch_out" "routing.capability.egressAdvisoryHosts")" \
  "egress honesty: the host list stays in the machine-readable capability decision"

# The dispatch-level routing statement itself carries no manifest text. Checked
# by stripping the embedded capability document and asserting the remainder is
# free of the token: the dispatchers render `routing`, and a host string there
# would be repository-controlled text on an operator surface.
routing_only="$(printf '%s' "$dispatch_out" | node -e '
let raw = "";
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  const doc = JSON.parse(raw);
  const routing = Object.assign({}, doc.routing);
  delete routing.capability;
  process.stdout.write(JSON.stringify(routing));
});
')"
assert_not_contains "$routing_only" "$ADVISORY_HOST" \
  "egress honesty: the dispatch routing statement reports the count, never the host string"
rm -rf "$repo"

# --- 6. The in-worker preflight tells the truth about the plane it is on ------
#
# The old message said "advisory only, not enforced yet" on BOTH planes. That is
# now wrong inside a sandbox, where New-SandboxEgressPolicy generated and applied
# a default-deny policy before this script ran.

repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: git\n    required: true\negress:\n  - host: %s\n    reason: probe\n' "$ADVISORY_HOST" \
  > "${repo}/squad-capabilities.yml"

jobs_out="$(env -u SQUAD_EXECUTION_MODE bash "$PREFLIGHT" "$repo" 2>&1)"
jobs_rc=$?
assert_eq "0" "$jobs_rc" "preflight: a declared egress host never blocks the session"
assert_contains "$jobs_out" "NOT ENFORCED on this plane" \
  "preflight: on the ACA Jobs plane a declared egress host is reported as NOT enforced"
assert_not_contains "$jobs_out" "not enforced yet" \
  "preflight: the stale 'not enforced yet' wording is gone"

sandbox_out="$(SQUAD_EXECUTION_MODE=sandbox bash "$PREFLIGHT" "$repo" 2>&1)"
sandbox_rc=$?
assert_eq "0" "$sandbox_rc" "preflight: the sandbox plane also does not block on a declared egress host"
assert_contains "$sandbox_out" "ENFORCED on this plane" \
  "preflight: inside a sandbox the same host is reported as enforced"
assert_not_contains "$sandbox_out" "NOT ENFORCED on this plane" \
  "preflight: the sandbox message is not the Jobs message"

assert_not_contains "$jobs_out" "$ADVISORY_HOST" \
  "preflight: the Jobs-plane message never prints the declared host"
assert_not_contains "$sandbox_out" "$ADVISORY_HOST" \
  "preflight: the sandbox-plane message never prints the declared host"
rm -rf "$repo"

# --- 7. This sprint added no enforcement -------------------------------------
#
# Stated as an executable assertion rather than a comment, because "controlled
# egress landed" is exactly how a reader misreads this work. The ACA Jobs
# provider still contains no egress code, and if that ever changes the claim
# above ("that plane applies no per-execution network policy") becomes false and
# has to be revisited deliberately.
job_provider="${REPO_ROOT}/scripts/lib/providers/squad-aca-job-provider.ps1"
egress_calls="$(grep -c -i 'New-SandboxEgressPolicy\|--egress\|networkPolicy' "$job_provider" || true)"
assert_eq "0" "$egress_calls" \
  "egress honesty: the ACA Jobs provider still applies no egress policy, which is what egressEnforced false reports"

test_summary
