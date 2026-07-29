#!/usr/bin/env bash
# Unit tests for worker/lib/verify-image-evidence.js
#
# The defect these exist for: config/sandbox-classes.json declared tools its
# pinned image did not contain, and nothing compared the two. Routing sent a
# Python repository to a class with no Python. The in-worker preflight refused
# the session -- correctly -- but the catalog had already lied.
#
# The rule under test is therefore: an approved class in a reviewed catalog may
# only claim tools that a live probe of the exact digest it pins actually
# observed, and the absence of that probe is a FAILURE, never a skip.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WORKER_DIR}/.." && pwd)"
VERIFIER="${WORKER_DIR}/lib/verify-image-evidence.js"
SHIPPED_CATALOG="${REPO_ROOT}/config/sandbox-classes.json"
SHIPPED_EVIDENCE="${REPO_ROOT}/config/image-evidence"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-evidence"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== verify-image-evidence.js =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

DIGEST_A="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DIGEST_B="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# Builds a throwaway case directory: catalog.json + evidence/.
make_case() {
  local name="$1"
  local dir="${TEST_TMP_ROOT}/${name}"
  mkdir -p "${dir}/evidence"
  printf '%s\n' "$dir"
}

# write_catalog <dir> <provisional> <approved> <digest> <tools-json> [reference]
write_catalog() {
  local dir="$1" provisional="$2" approved="$3" digest="$4" tools="$5"
  local reference="${6:-registry.example.test/squad-worker}"
  local digest_json="null"
  local pinned="false"
  if [[ "$digest" != "null" ]]; then
    digest_json="\"${digest}\""
    pinned="true"
  fi
  cat > "${dir}/catalog.json" <<JSON
{
  "schemaVersion": 1,
  "provisional": ${provisional},
  "defaultWorker": {
    "id": "aca-job-default",
    "tools": ["git"],
    "credentials": [],
    "egress": { "defaultAction": "Allow", "trafficInspection": "None", "hostRules": [] }
  },
  "classes": [
    {
      "id": "sandbox-under-test",
      "approved": ${approved},
      "image": { "reference": "${reference}", "tag": "t", "digest": ${digest_json}, "pinned": ${pinned} },
      "imageHintAliases": [],
      "resources": { "cpu": 1, "memoryGi": 2 },
      "tools": ${tools},
      "allowedCredentials": [],
      "egress": { "defaultAction": "Deny", "trafficInspection": "Full", "hostRules": [] },
      "limits": { "maxConcurrentSandboxes": 1 }
    }
  ]
}
JSON
}

# write_evidence <dir> <file-digest> <recorded-digest> <present-json> [reference] [absent-json]
write_evidence() {
  local dir="$1" file_digest="$2" recorded_digest="$3" present="$4"
  local reference="${5:-registry.example.test/squad-worker}"
  local absent="${6:-[]}"
  local file="${dir}/evidence/${file_digest/:/-}.json"
  cat > "$file" <<JSON
{
  "schemaVersion": 1,
  "image": { "reference": "${reference}", "digest": "${recorded_digest}" },
  "verifiedAt": "2026-07-29T20:45:23Z",
  "method": "aca sandbox exec: 'command -v <tool>' inside a sandbox created from this digest",
  "tools": { "present": ${present}, "absent": ${absent} }
}
JSON
}

# run_case <dir> -> prints report, returns the CLI exit code
run_case() {
  local dir="$1"
  node "$VERIFIER" --catalog "${dir}/catalog.json" --evidence-dir "${dir}/evidence" 2>&1
}

# --- 1. A truthful class passes ----------------------------------------------
# The positive control. Without it, every check below could be satisfied by a
# verifier that always fails.
dir="$(make_case truthful)"
write_catalog "$dir" false true "$DIGEST_A" '["git","python3"]'
write_evidence "$dir" "$DIGEST_A" "$DIGEST_A" '["bash","git","python3"]' "registry.example.test/squad-worker" '["pnpm"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "0" "$rc" "truthful class: exits 0"
assert_contains "$out" "image evidence OK" "truthful class: reports the catalog is backed by evidence"

# Claiming LESS than the evidence records is fine: under-claiming routes a
# repository toward review, which is the fail-closed direction.
dir="$(make_case under-claim)"
write_catalog "$dir" false true "$DIGEST_A" '["git"]'
write_evidence "$dir" "$DIGEST_A" "$DIGEST_A" '["bash","git","python3"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "0" "$rc" "under-claiming class: exits 0 (a claim narrower than the evidence is honest)"

# --- 2. Declared tools exceeding the evidence FAIL ---------------------------
# This is the exact defect: the class claimed python3/pip3 and the image had
# neither.
dir="$(make_case over-claim)"
write_catalog "$dir" false true "$DIGEST_A" '["git","pip3","python3"]'
write_evidence "$dir" "$DIGEST_A" "$DIGEST_A" '["bash","git","node"]' "registry.example.test/squad-worker" '["pip3","python3"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "over-claiming class: exits non-zero"
assert_contains "$out" "claims 2 tool(s) the pinned image was not observed to provide" "over-claiming class: says how many claims are unbacked"
assert_contains "$out" "pip3, python3" "over-claiming class: names exactly which claims are unbacked"
assert_not_contains "$out" "image evidence OK" "over-claiming class: never reports OK"

# --- 3. Evidence for a DIFFERENT digest than the one pinned FAILS ------------
# Two shapes, because a re-pin can go wrong in two ways.
#
# 3a. Re-pinned to a new digest, evidence still only exists for the old one.
#     Evidence is keyed by digest, so the file the check looks for is simply
#     not there. THIS is what makes "re-pin without re-verifying" a build
#     failure rather than a silent carry-over.
dir="$(make_case repinned)"
write_catalog "$dir" false true "$DIGEST_B" '["git"]'
write_evidence "$dir" "$DIGEST_A" "$DIGEST_A" '["bash","git"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "re-pinned class: exits non-zero when evidence exists only for the previous digest"
assert_contains "$out" "no image evidence recorded for the pinned digest" "re-pinned class: says the pinned digest has no evidence"
assert_contains "$out" "sha256-bbbbbbbbbb" "re-pinned class: names the evidence file the new digest requires"

# 3b. The evidence file was copied under the new digest's name but still
#     records the old digest inside. The file name alone must not be trusted.
dir="$(make_case copied-evidence)"
write_catalog "$dir" false true "$DIGEST_B" '["git"]'
write_evidence "$dir" "$DIGEST_B" "$DIGEST_A" '["bash","git"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "copied evidence: exits non-zero when the recorded digest disagrees with the pinned one"
assert_contains "$out" "but the class pins" "copied evidence: reports the disagreement between recorded and pinned digest"

# 3c. Evidence recorded against a different image REPOSITORY at the same digest.
dir="$(make_case foreign-repo)"
write_catalog "$dir" false true "$DIGEST_A" '["git"]' "registry.example.test/squad-worker-python"
write_evidence "$dir" "$DIGEST_A" "$DIGEST_A" '["bash","git"]' "registry.example.test/squad-worker"
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "foreign repository: exits non-zero when evidence was recorded for another image repository"
assert_contains "$out" "recorded for image repository" "foreign repository: names the mismatch"

# --- 4. An approved, pinned class with NO evidence FAILS ---------------------
# The rule that makes the whole mechanism honest: missing input is a failure,
# never a skip. A check that passes when its evidence is absent is not a check.
dir="$(make_case no-evidence)"
write_catalog "$dir" false true "$DIGEST_A" '["git"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "no evidence: an approved pinned class with no evidence file exits non-zero"
assert_contains "$out" "no image evidence recorded for the pinned digest" "no evidence: says evidence is missing"
assert_contains "$out" "verify-image-tools.ps1" "no evidence: tells the operator which command produces it"

# An entirely absent evidence DIRECTORY is the same failure, not a skip.
dir="$(make_case no-evidence-dir)"
write_catalog "$dir" false true "$DIGEST_A" '["git"]'
out="$(node "$VERIFIER" --catalog "${dir}/catalog.json" --evidence-dir "${dir}/nonexistent" 2>&1)"; rc=$?
assert_eq "1" "$rc" "absent evidence directory: still a failure, not a skip"

# An approved class in a reviewed catalog with no digest at all cannot be
# verified, and says so rather than passing vacuously.
dir="$(make_case unpinned)"
write_catalog "$dir" false true "null" '["git"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "unpinned approved class: exits non-zero"
assert_contains "$out" "has no sha256 image.digest" "unpinned approved class: says there is nothing immutable to verify"

# --- 5. Malformed evidence is a failure, not a pass --------------------------
dir="$(make_case bad-json)"
write_catalog "$dir" false true "$DIGEST_A" '["git"]'
printf '{ not json' > "${dir}/evidence/${DIGEST_A/:/-}.json"
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "unparseable evidence: exits non-zero"
assert_contains "$out" "is not valid JSON" "unparseable evidence: says the file could not be parsed"

dir="$(make_case empty-present)"
write_catalog "$dir" false true "$DIGEST_A" '["git"]'
write_evidence "$dir" "$DIGEST_A" "$DIGEST_A" '[]'
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "empty evidence: a probe that observed nothing proves nothing"
assert_contains "$out" "observed nothing" "empty evidence: says the probe observed nothing"

dir="$(make_case contradictory)"
write_catalog "$dir" false true "$DIGEST_A" '["git"]'
write_evidence "$dir" "$DIGEST_A" "$DIGEST_A" '["git","python3"]' "registry.example.test/squad-worker" '["python3"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "contradictory evidence: a tool recorded as both present and absent fails"
assert_contains "$out" "both present and absent" "contradictory evidence: names the contradiction"

dir="$(make_case wrong-schema)"
write_catalog "$dir" false true "$DIGEST_A" '["git"]'
cat > "${dir}/evidence/${DIGEST_A/:/-}.json" <<JSON
{
  "schemaVersion": 99,
  "image": { "reference": "registry.example.test/squad-worker", "digest": "${DIGEST_A}" },
  "verifiedAt": "yesterday",
  "method": "",
  "tools": { "present": ["git"], "absent": [] }
}
JSON
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "malformed evidence: wrong schema version, unparseable timestamp and empty method all fail"
assert_contains "$out" "schemaVersion must be 1" "malformed evidence: reports the schema version"
assert_contains "$out" "verifiedAt must be a UTC timestamp" "malformed evidence: reports the unusable timestamp"
assert_contains "$out" "method must describe how the image was probed" "malformed evidence: reports the missing method"

# --- 6. Scope: unapproved and provisional ------------------------------------
# An UNAPPROVED class can never be selected, so it needs no evidence. This is
# asserted rather than assumed, so that "approved" stays the thing that pulls
# the requirement in.
dir="$(make_case unapproved)"
write_catalog "$dir" false false "$DIGEST_A" '["docker","git"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "0" "$rc" "unapproved class: needs no evidence, because it can never be selected"

# ...but evidence that IS present for an unapproved class must still be well
# formed, or approving the class later would inherit a broken record.
dir="$(make_case unapproved-bad-evidence)"
write_catalog "$dir" false false "$DIGEST_A" '["docker","git"]'
printf '{ not json' > "${dir}/evidence/${DIGEST_A/:/-}.json"
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "unapproved class: a broken evidence file that exists is still a failure"

# A PROVISIONAL catalog is report-only and cannot reach the execution plane at
# all (the route gate refuses it), so evidence is not required there. Pinning
# the boundary explicitly means a future reader can see it was decided, not
# overlooked.
dir="$(make_case provisional)"
write_catalog "$dir" true true "$DIGEST_A" '["git","python3"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "0" "$rc" "provisional catalog: evidence is not required for a report-only catalog"

# The same catalog reviewed is a failure -- so clearing "provisional" is what
# pulls the evidence requirement in, and cannot be done quietly.
dir="$(make_case provisional-cleared)"
write_catalog "$dir" false true "$DIGEST_A" '["git","python3"]'
out="$(run_case "$dir")"; rc=$?
assert_eq "1" "$rc" "clearing provisional on the same catalog turns it into a failure"

# --- 7. The SHIPPED catalog is actually backed ------------------------------
# Everything above runs against synthetic fixtures. This runs against the file
# that ships and the evidence committed beside it.
out="$(node "$VERIFIER" --catalog "$SHIPPED_CATALOG" --evidence-dir "$SHIPPED_EVIDENCE" 2>&1)"; rc=$?
assert_eq "0" "$rc" "shipped catalog: every approved class is backed by evidence for the digest it pins"
assert_contains "$out" "image evidence OK" "shipped catalog: reports OK"

# The two approved classes must pin DIFFERENT images. Pinning one image for
# both is what made the false claims possible in the first place.
node_digest="$(node -e '
const c = require(process.argv[1]);
const cls = c.classes.find((x) => x.id === "sandbox-node-lts");
process.stdout.write(cls.image.digest + " " + cls.image.reference);
' "$SHIPPED_CATALOG")"
py_digest="$(node -e '
const c = require(process.argv[1]);
const cls = c.classes.find((x) => x.id === "sandbox-python-3-12");
process.stdout.write(cls.image.digest + " " + cls.image.reference);
' "$SHIPPED_CATALOG")"
if [[ "$node_digest" == "$py_digest" ]]; then
  assert_eq "different" "same" "shipped catalog: the node and python classes pin different images"
else
  assert_eq "different" "different" "shipped catalog: the node and python classes pin different images"
fi

# The python class is the one that proves the routing premise. Its evidence must
# record python3 and pip3 as PRESENT -- the two tools the live preflight
# refused a session over.
py_present="$(node -e '
const { verifyCatalogEvidence } = require(process.argv[1]);
const fs = require("fs");
const path = require("path");
const catalog = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const cls = catalog.classes.find((x) => x.id === "sandbox-python-3-12");
const file = path.join(process.argv[3], cls.image.digest.replace(":", "-") + ".json");
const doc = JSON.parse(fs.readFileSync(file, "utf8"));
process.stdout.write(doc.tools.present.join(" "));
' "$VERIFIER" "$SHIPPED_CATALOG" "$SHIPPED_EVIDENCE")"
assert_contains "$py_present" "python3" "shipped python class: its pinned image was observed to provide python3"
assert_contains "$py_present" "pip3" "shipped python class: its pinned image was observed to provide pip3"

# --- 8. CLI contract ---------------------------------------------------------
out="$(node "$VERIFIER" --catalog "${TEST_TMP_ROOT}/does-not-exist.json" --evidence-dir "$SHIPPED_EVIDENCE" 2>&1)"; rc=$?
assert_eq "70" "$rc" "missing catalog: exits 70 (EX_SOFTWARE), never 0"

out="$(node "$VERIFIER" --nonsense 2>&1)"; rc=$?
assert_eq "64" "$rc" "unrecognized argument: exits 64 (EX_USAGE), never 0"

dir="$(make_case json-output)"
write_catalog "$dir" false true "$DIGEST_A" '["git","python3"]'
write_evidence "$dir" "$DIGEST_A" "$DIGEST_A" '["git"]'
out="$(node "$VERIFIER" --catalog "${dir}/catalog.json" --evidence-dir "${dir}/evidence" --json 2>&1)"; rc=$?
assert_eq "1" "$rc" "--json: still exits non-zero on a problem"
assert_contains "$out" '"ok": false' "--json: emits a machine-readable verdict"

test_summary
