#!/usr/bin/env bash
# Unit tests for worker/lib/resolve-capability-route.js
#
# Sprint 2 of PRD #6 produces a routing DECISION only. These tests prove the
# decision is deterministic (golden JSON), fails closed on anything ambiguous,
# and never leaks manifest values into its output.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WORKER_DIR}/.." && pwd)"
RESOLVER="${WORKER_DIR}/lib/resolve-capability-route.js"
CATALOG="${REPO_ROOT}/config/sandbox-classes.json"
FIXTURES="${TEST_DIR}/fixtures"
EXPECTED="${TEST_DIR}/expected"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-routing"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== resolve-capability-route.js =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

make_repo() {
  local dir="${TEST_TMP_ROOT}/repo-$$-${RANDOM}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# Builds a repo containing the given fixture (or none) and resolves a route.
resolve_fixture() {
  local fixture="${1:-}"
  local repo
  repo="$(make_repo)"
  if [[ -n "$fixture" ]]; then
    cp "${FIXTURES}/${fixture}" "${repo}/squad-capabilities.yml"
  fi
  node "$RESOLVER" "$repo" --catalog "$CATALOG" --pretty 2>&1
  local rc=$?
  rm -rf "$repo"
  return $rc
}

# --- 1. Golden decisions: deterministic, diffable, byte-for-byte stable -------

assert_golden() {
  local fixture="$1" golden="$2" label="$3"
  local out rc expected
  out="$(resolve_fixture "$fixture")"
  rc=$?
  expected="$(cat "${EXPECTED}/${golden}")"
  assert_eq "0" "$rc" "${label}: exits 0 (a decision was produced)"
  assert_eq "$expected" "$out" "${label}: matches golden ${golden}"
}

assert_golden "" "route-no-manifest.json" "no manifest"
assert_golden "routing-default-satisfied.yml" "route-default-satisfied.json" "satisfied by default profile"
assert_golden "routing-sandbox-python.yml" "route-sandbox-matched.json" "approved sandbox class matched"
assert_golden "routing-no-matching-class.yml" "route-no-matching-class.json" "no approved class"
assert_golden "routing-unapproved-egress.yml" "route-unapproved-egress.json" "egress outside approved templates"
assert_golden "malformed.yml" "route-malformed.json" "malformed manifest"

# --- 2. Backward compatibility: the no-manifest path is the common case -------

out="$(resolve_fixture "")"
assert_contains "$out" '"route": "aca-job"' "no manifest: routes to the existing ACA job"
assert_contains "$out" '"reason": "no-manifest"' "no manifest: reports the no-manifest reason code"
assert_contains "$out" '"manifestPresent": false' "no manifest: records that no manifest was present"

# Repeating the resolution is byte-for-byte identical (no timestamps, no
# environment-dependent ordering).
first="$(resolve_fixture "routing-sandbox-python.yml")"
second="$(resolve_fixture "routing-sandbox-python.yml")"
assert_eq "$first" "$second" "determinism: repeated resolution is byte-for-byte identical"

# Declaration order and duplicates must not change the decision.
repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: python3\n    required: true\n  - name: pip3\n    required: true\n  - name: git\n    required: true\n  - name: python3\n    required: true\negress:\n  - host: pypi.org\n  - host: files.pythonhosted.org\n  - host: pypi.org\nimage:\n  hint: ghcr.io/example/squad-worker-python:latest\n' > "${repo}/squad-capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" --pretty 2>&1)"
rc=$?
assert_eq "0" "$rc" "determinism: reordered/duplicated manifest still resolves"
assert_eq "$(cat "${EXPECTED}/route-sandbox-matched.json")" "$out" "determinism: reordered/duplicated manifest yields the same golden decision"
rm -rf "$repo"

# --- 3. Sandbox selection and the image hint ---------------------------------

out="$(resolve_fixture "routing-narrowed-egress.yml")"
assert_contains "$out" '"route": "sandbox"' "narrowed egress: routes to a sandbox"
assert_contains "$out" '"sandboxClass": "sandbox-node-lts"' "narrowed egress: selects the node class that permits NPM_TOKEN"
assert_contains "$out" '"imageHintPresent": false' "narrowed egress: records that no hint was declared"

# A path-traversal-shaped hint must never select a class and must never appear
# in the output. It can only ever match an administrator-approved alias.
out="$(resolve_fixture "routing-sandbox-hint-unrecognized.yml")"
assert_contains "$out" '"route": "sandbox"' "hostile hint: still routes on declared tools, not on the hint"
assert_contains "$out" '"sandboxClass": "sandbox-python-3-12"' "hostile hint: class comes from declared tools"
assert_contains "$out" '"imageHint": null' "hostile hint: unrecognized hint resolves to null, never to an image reference"
assert_contains "$out" '"imageHintPresent": true' "hostile hint: presence of a hint is still reported"
assert_contains "$out" '"imageHintRecognized": false' "hostile hint: hint is reported as unrecognized"
assert_not_contains "$out" "etc/passwd" "hostile hint: path-traversal payload never reaches the output"
assert_not_contains "$out" ".." "hostile hint: no traversal segment reaches the output"

# --- 4. Unapproved classes can never be selected ------------------------------

out="$(resolve_fixture "routing-no-matching-class.yml")"
assert_contains "$out" '"route": "fail-closed"' "unapproved class: docker requirement fails closed"
assert_not_contains "$out" "sandbox-container-build" "unapproved class: the unapproved docker class is never named as a target"
assert_contains "$out" '"unsatisfiedTools"' "unapproved class: reports which requirement blocked routing"

# Every class unapproved => nothing can ever be selected.
cat > "${TEST_TMP_ROOT}/catalog-none-approved.json" <<'JSON'
{
  "schemaVersion": 1,
  "provisional": true,
  "defaultWorker": {
    "id": "aca-job-default",
    "tools": ["git"],
    "credentials": [],
    "egress": { "defaultAction": "Allow", "trafficInspection": "None", "hostRules": [] }
  },
  "classes": [
    {
      "id": "sandbox-python-3-12",
      "approved": false,
      "image": { "reference": "REPLACE-ME/python", "tag": "PROVISIONAL", "digest": null, "pinned": false },
      "imageHintAliases": [],
      "resources": { "cpu": 1, "memoryGi": 2 },
      "tools": ["git", "pip3", "python3"],
      "allowedCredentials": [],
      "egress": { "defaultAction": "Allow", "trafficInspection": "Full", "hostRules": [] },
      "limits": { "maxConcurrentSandboxes": 1 }
    }
  ]
}
JSON
repo="$(make_repo)"
cp "${FIXTURES}/routing-sandbox-python.yml" "${repo}/squad-capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "${TEST_TMP_ROOT}/catalog-none-approved.json" --pretty 2>&1)"
rc=$?
assert_eq "0" "$rc" "all classes unapproved: still produces a decision"
assert_contains "$out" '"route": "fail-closed"' "all classes unapproved: fails closed"
assert_contains "$out" '"reason": "no-approved-sandbox-class"' "all classes unapproved: reports the approval gap"
rm -rf "$repo"

# --- 5. Invalid manifests fail closed, never silently aca-job -----------------

assert_invalid() {
  local fixture="$1" label="$2"
  local out rc
  out="$(resolve_fixture "$fixture")"
  rc=$?
  assert_eq "0" "$rc" "${label}: still produces a decision"
  assert_contains "$out" '"route": "fail-closed"' "${label}: fails closed"
  assert_contains "$out" '"reason": "manifest-invalid"' "${label}: reports manifest-invalid"
  assert_not_contains "$out" '"route": "aca-job"' "${label}: never silently routes to the ACA job"
}

assert_invalid "missing-version.yml" "missing version"
assert_invalid "invalid-version.yml" "unsupported version"
assert_invalid "unknown-top-level.yml" "unknown top-level key"
assert_invalid "duplicate-top-level.yml" "duplicate top-level key"
assert_invalid "duplicate-nested-required.yml" "duplicate nested key"
assert_invalid "wrong-tools-type.yml" "wrong type for tools"
assert_invalid "invalid-required-type.yml" "wrong type for required"
assert_invalid "malformed-array-element.yml" "unknown key inside a list item"
assert_invalid "missing-fields.yml" "list item missing its name"
assert_invalid "required-service.yml" "required external service"

# The unknown-key case must not echo the offending key name.
out="$(resolve_fixture "unknown-top-level.yml")"
assert_not_contains "$out" "unknown:" "unknown top-level key: raw key text is never echoed"

# --- 6. Hostile values never reach the output --------------------------------

out="$(resolve_fixture "routing-hostile-values.yml")"
assert_contains "$out" '"route": "aca-job"' "hostile free-form text: routing is unaffected"
assert_not_contains "$out" "HOSTILE_REASON_MARKER" "hostile free-form text: tools[].reason is never emitted"
assert_not_contains "$out" "HOSTILE_CREDENTIAL_REASON_MARKER" "hostile free-form text: credentials[].reason is never emitted"
assert_not_contains "$out" "HOSTILE_EGRESS_REASON_MARKER" "hostile free-form text: egress[].reason is never emitted"
assert_not_contains "$out" "HOSTILE_NOTES_MARKER" "hostile free-form text: notes is never emitted"
assert_not_contains "$out" "rm -rf" "hostile free-form text: shell-shaped payload is never emitted"
assert_not_contains "$out" "DROP TABLE" "hostile free-form text: injection-shaped payload is never emitted"

# Control characters are rejected upstream by the parser; the decision must stay
# fail-closed and carry no raw control byte.
esc=$'\x1b'
cr=$'\r'
repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: "git%s[31mred"\n    required: true\n' "$esc" > "${repo}/squad-capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" --pretty 2>&1)"
assert_contains "$out" '"route": "fail-closed"' "control characters: fail closed"
assert_not_contains "$out" "$esc" "control characters: no raw ESC byte in the decision"
assert_not_contains "$out" "$cr" "control characters: no raw CR byte in the decision"
rm -rf "$repo"

# A tool name that is character-safe but implausibly long is refused by the
# output safety layer, without echoing it.
long_name="$(node -e 'process.stdout.write("t".repeat(4096))')"
repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: %s\n    required: true\n' "$long_name" > "${repo}/squad-capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" --pretty 2>&1)"
rc=$?
assert_eq "0" "$rc" "oversized tool name: still produces a decision"
assert_contains "$out" '"route": "fail-closed"' "oversized tool name: fails closed"
assert_contains "$out" '"reason": "manifest-identifier-unsafe"' "oversized tool name: reports the identifier bound"
assert_not_contains "$out" "$long_name" "oversized tool name: the value is never echoed"
assert_contains "$out" '"requiredTools": []' "oversized tool name: no identifiers are emitted at all"
rm -rf "$repo"

# Same bound for an oversized egress host.
long_host="$(node -e 'process.stdout.write("h".repeat(400) + ".example.com")')"
repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: git\n    required: true\negress:\n  - host: %s\n' "$long_host" > "${repo}/squad-capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" --pretty 2>&1)"
assert_contains "$out" '"reason": "manifest-identifier-unsafe"' "oversized egress host: fails closed on the identifier bound"
assert_not_contains "$out" "$long_host" "oversized egress host: the value is never echoed"
rm -rf "$repo"

# An oversized image hint is refused the same way.
long_hint="$(node -e 'process.stdout.write("ghcr.io/" + "x".repeat(1024))')"
repo="$(make_repo)"
printf 'version: 1\ntools:\n  - name: git\n    required: true\nimage:\n  hint: %s\n' "$long_hint" > "${repo}/squad-capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" --pretty 2>&1)"
assert_contains "$out" '"reason": "manifest-identifier-unsafe"' "oversized image hint: fails closed on the identifier bound"
assert_not_contains "$out" "$long_hint" "oversized image hint: the value is never echoed"
rm -rf "$repo"

# --- 7. Manifest path safety --------------------------------------------------

repo="$(make_repo)"
outside_dir="$(make_repo)"
secret_payload="ROUTING_OUTSIDE_SECRET_SHOULD_NEVER_APPEAR"
printf 'version: 1\nnotes: %s\n' "$secret_payload" > "${outside_dir}/outside.yml"
ln -s "${outside_dir}/outside.yml" "${repo}/squad-capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" --pretty 2>&1)"
assert_contains "$out" '"route": "fail-closed"' "symlink escape: fails closed"
assert_contains "$out" '"reason": "manifest-path-unsafe"' "symlink escape: reports an unsafe manifest path"
assert_not_contains "$out" "$secret_payload" "symlink escape: target content is never leaked"
rm -rf "$repo" "$outside_dir"

repo="$(make_repo)"
cp "${FIXTURES}/routing-default-satisfied.yml" "${repo}/squad-capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" --manifest-path "/etc/hostname" --pretty 2>&1)"
assert_contains "$out" '"reason": "manifest-path-unsafe"' "absolute manifest path: refused"
out="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" --manifest-path "../../../../etc/hostname" --pretty 2>&1)"
assert_contains "$out" '"reason": "manifest-path-unsafe"' "escaping relative manifest path: refused"
rm -rf "$repo"

# A custom in-repo manifest path is honored.
repo="$(make_repo)"
mkdir -p "${repo}/config"
cp "${FIXTURES}/routing-default-satisfied.yml" "${repo}/config/capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" --manifest-path "config/capabilities.yml" --pretty 2>&1)"
assert_eq "$(cat "${EXPECTED}/route-default-satisfied.json")" "$out" "custom manifest path: resolves the same decision"
out="$(CAPABILITY_MANIFEST_PATH="config/capabilities.yml" node "$RESOLVER" "$repo" --catalog "$CATALOG" --pretty 2>&1)"
assert_eq "$(cat "${EXPECTED}/route-default-satisfied.json")" "$out" "CAPABILITY_MANIFEST_PATH: honored the same way"
rm -rf "$repo"

# Resolving must never write into the repository working tree.
repo="$(make_repo)"
cp "${FIXTURES}/routing-sandbox-python.yml" "${repo}/squad-capabilities.yml"
node "$RESOLVER" "$repo" --catalog "$CATALOG" >/dev/null 2>&1
listing="$(cd "$repo" && ls -A)"
assert_eq "squad-capabilities.yml" "$listing" "resolver: creates nothing inside the repository working tree"
rm -rf "$repo"

# --- 8. Catalog faults fail closed and are reported as control-plane faults ---

repo="$(make_repo)"
cp "${FIXTURES}/routing-default-satisfied.yml" "${repo}/squad-capabilities.yml"
out="$(node "$RESOLVER" "$repo" --catalog "${TEST_TMP_ROOT}/definitely-absent-catalog.json" --pretty 2>&1)"
rc=$?
assert_eq "70" "$rc" "missing catalog: exits 70 (EX_SOFTWARE)"
assert_contains "$out" '"route": "fail-closed"' "missing catalog: still writes a fail-closed decision"
assert_contains "$out" '"reason": "catalog-unavailable"' "missing catalog: reports a control-plane fault"

printf 'not json at all\n' > "${TEST_TMP_ROOT}/catalog-bad.json"
out="$(node "$RESOLVER" "$repo" --catalog "${TEST_TMP_ROOT}/catalog-bad.json" --pretty 2>&1)"
rc=$?
assert_eq "70" "$rc" "unparseable catalog: exits 70"
assert_contains "$out" '"reason": "catalog-unavailable"' "unparseable catalog: fails closed"

printf '{"schemaVersion": 99, "provisional": true, "classes": []}\n' > "${TEST_TMP_ROOT}/catalog-wrong-version.json"
out="$(node "$RESOLVER" "$repo" --catalog "${TEST_TMP_ROOT}/catalog-wrong-version.json" --pretty 2>&1)"
rc=$?
assert_eq "70" "$rc" "unsupported catalog schema: exits 70"
assert_contains "$out" '"reason": "catalog-unavailable"' "unsupported catalog schema: fails closed"
rm -rf "$repo"

# --- 9. The shipped catalog is well-formed and honest about being provisional -

out="$(node -e '
const { validateCatalog } = require(process.argv[1]);
const catalog = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const errors = validateCatalog(catalog);
process.stdout.write(errors.length === 0 ? "valid" : errors.join("; "));
' "$RESOLVER" "$CATALOG" 2>&1)"
assert_eq "valid" "$out" "shipped catalog: passes catalog validation"

out="$(node -e '
const catalog = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(String(catalog.provisional));
' "$CATALOG" 2>&1)"
assert_eq "true" "$out" "shipped catalog: is marked provisional (report-only until reviewed)"

out="$(node -e '
const catalog = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(Array.isArray(catalog.$comment) && catalog.$comment.join(" ").includes("PROVISIONAL") ? "documented" : "missing");
' "$CATALOG" 2>&1)"
assert_eq "documented" "$out" "shipped catalog: carries the provisional header comment"

# --- 10. Egress template matching semantics ----------------------------------

egress_check() {
  node -e '
const { hostMatchesPattern } = require(process.argv[1]);
process.stdout.write(String(hostMatchesPattern(process.argv[2], process.argv[3])));
' "$RESOLVER" "$1" "$2"
}

assert_eq "true" "$(egress_check "api.github.com" "*.github.com")" "egress: wildcard matches a subdomain"
assert_eq "true" "$(egress_check "a.b.github.com" "*.github.com")" "egress: wildcard matches a nested subdomain"
assert_eq "false" "$(egress_check "github.com" "*.github.com")" "egress: wildcard does not match the bare apex"
assert_eq "false" "$(egress_check "evilgithub.com" "*.github.com")" "egress: wildcard does not match a lookalike apex"
assert_eq "false" "$(egress_check "github.com.evil.net" "*.github.com")" "egress: wildcard does not match a suffix-smuggling host"
assert_eq "true" "$(egress_check "registry.npmjs.org" "registry.npmjs.org")" "egress: exact host matches"
assert_eq "true" "$(egress_check "registry.npmjs.org:443" "registry.npmjs.org")" "egress: an explicit port does not defeat the host match"
assert_eq "false" "$(egress_check "registry.npmjs.org.evil.net" "registry.npmjs.org")" "egress: exact host does not match a longer host"

# --- 11. CLI contract ---------------------------------------------------------

out="$(node "$RESOLVER" 2>&1)"
rc=$?
assert_eq "64" "$rc" "no repo argument is EX_USAGE"
assert_contains "$out" "Usage:" "no repo argument prints usage"

repo="$(make_repo)"
cp "${FIXTURES}/routing-default-satisfied.yml" "${repo}/squad-capabilities.yml"
compact="$(node "$RESOLVER" "$repo" --catalog "$CATALOG" 2>&1)"
assert_contains "$compact" '{"schemaVersion":1,"route":"aca-job","reason":"default-profile-satisfies-manifest"' "compact output keeps the documented key order"
rm -rf "$repo"

test_summary
