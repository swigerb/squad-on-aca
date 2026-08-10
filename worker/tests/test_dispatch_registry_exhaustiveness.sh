#!/usr/bin/env bash
# Issue #84 PI-1: "Enumerate, from the code, the tool policy actually applied
# to each dispatch source and each mode... fails if a new source or mode is
# added without an entry."
#
# worker/lib/agent-policy.js now carries a REGISTRY (KNOWN_SOURCES,
# KNOWN_MODES) that every cell of its resolved matrix is built from. A registry
# nobody checks against reality is decoration: this suite reads the actual
# PRODUCTION DISPATCHERS -- the files that literally set SQUAD_MODE or
# SQUAD_DISPATCH_SOURCE for a real session -- and fails if any of them uses a
# value the registry does not know about.
#
# WHAT COUNTS AS A "PRODUCTION DISPATCHER" HERE, AND WHY THE LIST IS EXPLICIT.
# This suite does not attempt to walk the whole repository: a fully general
# scan would have to parse bash, PowerShell, and YAML equivalently, and would
# either miss dynamic assignments (which carry no literal to check) or trip on
# prose that happens to contain the substrings. Instead it names, explicitly,
# every file known to assign a LITERAL value to one of these two variables for
# a session that actually runs:
#
#   worker/lib/ralph-dispatch.sh              Ralph's per-issue dispatch (OV_*)
#   .github/workflows/squad-dispatch.yml       the Actions dispatch trigger
#   scripts/deploy.ps1                          the three baked-in job templates
#   scripts/start-watch.ps1                     the watch app's own env
#   scripts/squad-aca.ps1                       the CLI's own -DispatchSource calls
#
# Test fixtures, golden captures, and this suite itself are EXCLUDED
# EXPLICITLY, not by a directory-name heuristic: worker/tests/**,
# scripts/tests/**, and this repository's docs are not dispatchers, they
# describe or exercise one. A corpus fixture that lists SQUAD_DISPATCH_SOURCE=
# api (to prove the fail-closed default still works) must never make this
# suite believe `api` is a registered source.
#
# MUTATION PROOF (issue #84, M2): adding a NEW production dispatcher that sets
# SQUAD_DISPATCH_SOURCE=api (or any other unregistered value) to the list below
# must fail this suite's "every literal found belongs to the registry"
# assertion. That is what makes this an exhaustiveness test rather than a
# snapshot: the registry is checked against what dispatches actually do, not
# copied from it once and left to drift.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WORKER_DIR}/.." && pwd)"
RESOLVER="${WORKER_DIR}/lib/agent-policy.js"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== dispatch registry exhaustiveness (issue #84 PI-1) =="

# The explicit, reviewed list of production dispatchers. NOT a glob: adding a
# new dispatcher means adding its path here, on purpose, in the same review
# that adds it -- exactly like KNOWN_SOURCES/KNOWN_MODES themselves.
PRODUCTION_DISPATCHERS=(
  "worker/lib/ralph-dispatch.sh"
  ".github/workflows/squad-dispatch.yml"
  "scripts/deploy.ps1"
  "scripts/start-watch.ps1"
  "scripts/squad-aca.ps1"
)

# Explicit test-dir / non-dispatcher exclusions. A production dispatcher path
# above is asserted NOT to fall under any of these, so the two lists cannot
# quietly overlap.
EXCLUDED_PREFIXES=(
  "worker/tests/"
  "scripts/tests/"
  "docs/"
  ".squad/"
)

for f in "${PRODUCTION_DISPATCHERS[@]}"; do
  for prefix in "${EXCLUDED_PREFIXES[@]}"; do
    case "$f" in
      "$prefix"*)
        echo "FAIL: '${f}' is listed as a production dispatcher but also matches the excluded prefix '${prefix}'"
        exit 1
        ;;
    esac
  done
  if [[ ! -f "${REPO_ROOT}/${f}" ]]; then
    echo "FAIL: production dispatcher '${f}' no longer exists -- update this suite's file list"
    exit 1
  fi
done

# Extract every literal SQUAD_MODE / SQUAD_DISPATCH_SOURCE value from the named
# files. Two shapes are recognised, covering every dispatcher in the list
# above:
#   bash/YAML/PowerShell-string   SQUAD_MODE=<word>  /  SQUAD_DISPATCH_SOURCE=<word>
#                                  (with an optional OV_ prefix, ralph-dispatch.sh
#                                  and the Actions workflow's override convention)
#   PowerShell parameter           -DispatchSource "<word>"  /  -DispatchSource '<word>'
# A DYNAMIC assignment -- `$request.dispatchSource`, `$DispatchSource`,
# `${SQUAD_MODE:-smoke}` -- is not a literal and is deliberately not matched:
# there is nothing here for the registry to check, and the value it carries at
# runtime is checked by resolvePolicy's own fail-closed default instead.
mapfile -t found_pairs < <(REPO_ROOT="$REPO_ROOT" node - "${PRODUCTION_DISPATCHERS[@]}" <<'NODE'
const fs = require('fs');
const path = require('path');

const repoRoot = process.env.REPO_ROOT;
const files = process.argv.slice(2);

const patterns = [
  { kind: 'mode', re: /(?:OV_)?SQUAD_MODE\s*=\s*["']?([A-Za-z][A-Za-z0-9_-]*)["']?/g },
  { kind: 'source', re: /(?:OV_)?SQUAD_DISPATCH_SOURCE\s*=\s*["']?([A-Za-z][A-Za-z0-9_-]*)["']?/g },
  { kind: 'source', re: /-DispatchSource\s+["']([A-Za-z][A-Za-z0-9_-]*)["']/g },
];

const seen = new Set();
for (const rel of files) {
  const full = path.join(repoRoot, rel);
  const text = fs.readFileSync(full, 'utf8');
  for (const { kind, re } of patterns) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(text))) {
      const value = m[1];
      const key = `${kind}\t${value}\t${rel}`;
      if (seen.has(key)) continue;
      seen.add(key);
      console.log(`${kind}\t${value}\t${rel}`);
    }
  }
}
NODE
)

if [[ "${#found_pairs[@]}" -eq 0 ]]; then
  echo "FAIL: the scan found NO literal SQUAD_MODE/SQUAD_DISPATCH_SOURCE assignments in any production dispatcher"
  echo "  Either the regexes above no longer match how these files are written, or the file list is stale."
  echo "  A scan that silently finds nothing is worse than one that fails loudly: fix this suite, not the registry."
  exit 1
fi

echo "Found $(printf '%s\n' "${found_pairs[@]}" | wc -l) literal assignment(s) across ${#PRODUCTION_DISPATCHERS[@]} production dispatcher(s):"
printf '  %s\n' "${found_pairs[@]}"

known_json="$(node -e "
const p = require(process.argv[1]);
console.log(JSON.stringify({ sources: p.KNOWN_SOURCES, modes: p.KNOWN_MODES }));
" "$RESOLVER")"
known_sources_json="$(node -e "console.log(JSON.stringify(JSON.parse(process.argv[1]).sources))" "$known_json")"
known_modes_json="$(node -e "console.log(JSON.stringify(JSON.parse(process.argv[1]).modes))" "$known_json")"

unregistered=0
for row in "${found_pairs[@]}"; do
  kind="${row%%$'\t'*}"
  rest="${row#*$'\t'}"
  value="${rest%%$'\t'*}"
  file="${rest#*$'\t'}"

  if [[ "$kind" == "mode" ]]; then
    in_registry="$(node -e "process.stdout.write(${known_modes_json}.includes(process.argv[1]) ? '1' : '0')" "$value")"
  else
    in_registry="$(node -e "process.stdout.write(${known_sources_json}.includes(process.argv[1]) ? '1' : '0')" "$value")"
  fi

  if [[ "$in_registry" != "1" ]]; then
    unregistered=$((unregistered + 1))
    echo "FAIL: ${file} sets SQUAD_$([[ "$kind" == mode ]] && echo MODE || echo DISPATCH_SOURCE)=${value}, which is not in agent-policy.js's KNOWN_$([[ "$kind" == mode ]] && echo MODES || echo SOURCES)"
  fi
done

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$unregistered" -eq 0 ]]; then
  echo "ok - every literal SQUAD_MODE/SQUAD_DISPATCH_SOURCE assignment found in a production dispatcher is in the registry"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "FAIL: ${unregistered} unregistered assignment(s) found (see above) -- a new source or mode was added to a dispatcher without a matching agent-policy.js registry entry"
fi

# The registry itself must not be trivially empty either -- an exhaustiveness
# check against an empty registry would pass for the wrong reason.
assert_eq "1" "$(node -e "process.stdout.write(${known_sources_json}.length > 0 ? '1' : '0')")" \
  "KNOWN_SOURCES is non-empty"
assert_eq "1" "$(node -e "process.stdout.write(${known_modes_json}.length > 0 ? '1' : '0')")" \
  "KNOWN_MODES is non-empty"

test_summary
