#!/usr/bin/env bash
# Behavioural tests for manual workflow_dispatch input validation.
#
# The workflow is the human-facing trigger surface. A malformed input there must
# fail BEFORE Azure is asked to start anything, and it must fail with a reason a
# human can act on. This suite exercises the shared validator through the public
# CLI entry point so the workflow and any future caller observe the same rules.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WORKER_DIR}/.." && pwd)"
CLI="${WORKER_DIR}/lib/squad-dispatch.js"
TEST_TMP_ROOT="${TEST_DIR}/.tmp-dispatch-inputs"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== dispatch inputs =="
rm -rf "$TEST_TMP_ROOT"
mkdir -p "$TEST_TMP_ROOT"
trap 'rm -rf "$TEST_TMP_ROOT"' EXIT

GH_STUB="${TEST_TMP_ROOT}/fake-gh-inputs.js"
cat > "$GH_STUB" <<'NODE'
#!/usr/bin/env node
'use strict';

const args = process.argv.slice(2);
const target = args[1] || '';
const mode = process.env.FAKE_INPUTS_GH_MODE || '';
const existing = new Set(['main', 'release/1.2', 'feature/input-135']);

if (args[0] !== 'api') {
  process.stderr.write('gh: unsupported subcommand\n');
  process.exit(1);
}

if (mode === 'verify-fail') {
  process.stderr.write('gh: HTTP 403: Resource not accessible by integration (Not Found)\n');
  process.exit(1);
}

const prefix = 'repos/octo/demo/git/ref/heads/';
if (!target.startsWith(prefix)) {
  process.stderr.write('gh: unsupported api target\n');
  process.exit(1);
}

const branch = target.slice(prefix.length);
if (existing.has(branch)) {
  process.stdout.write(`${JSON.stringify({ ref: `refs/heads/${branch}` })}\n`);
  process.exit(0);
}

process.stderr.write('gh: Not Found (HTTP 404)\n');
process.exit(1);
NODE
chmod +x "$GH_STUB"

json_field() {
  node -e '
let value = JSON.parse(process.argv[1]);
for (const part of process.argv[2].split(".")) {
  value = value == null ? undefined : value[part];
}
process.stdout.write(value === undefined || value === null ? "" : String(value));
' "$1" "$2"
}

RUN_RC=0
RUN_STDOUT=''
RUN_STDERR=''
run_capture() {
  local name="$1"
  shift
  local stdout_file="${TEST_TMP_ROOT}/${name}.stdout"
  local stderr_file="${TEST_TMP_ROOT}/${name}.stderr"
  if SQUAD_GH_BIN="$GH_STUB" node "$CLI" validate-manual-inputs --repository octo/demo --repo-dir "$REPO_ROOT" "$@" >"$stdout_file" 2>"$stderr_file"; then
    RUN_RC=0
  else
    RUN_RC=$?
  fi
  RUN_STDOUT="$(cat "$stdout_file")"
  RUN_STDERR="$(cat "$stderr_file")"
}

run_capture defaults
assert_eq "0" "$RUN_RC" "omitting every manual input succeeds"
assert_eq "true" "$(json_field "$RUN_STDOUT" ok)" "the default validation result is ok"
assert_eq "" "$(json_field "$RUN_STDOUT" normalized.model)" "model defaults to empty"
assert_eq "" "$(json_field "$RUN_STDOUT" normalized.baseBranch)" "base_branch defaults to empty"
assert_eq "true" "$(json_field "$RUN_STDOUT" normalized.publishPr)" "publish_pr defaults to true"
assert_eq "" "$(json_field "$RUN_STDOUT" normalized.reviewer)" "reviewer defaults to empty"
assert_eq "false" "$(json_field "$RUN_STDOUT" normalized.watchOnly)" "watch_only defaults to false"

run_capture valid-model --model gpt-5.6-sol
assert_eq "0" "$RUN_RC" "a valid model override is accepted"
assert_eq "gpt-5.6-sol" "$(json_field "$RUN_STDOUT" normalized.model)" "the accepted model is preserved"

run_capture valid-branch --base-branch release/1.2
assert_eq "0" "$RUN_RC" "an existing base branch is accepted"
assert_eq "release/1.2" "$(json_field "$RUN_STDOUT" normalized.baseBranch)" "the accepted base branch is preserved"

run_capture valid-publish --publish-pr false
assert_eq "0" "$RUN_RC" "publish_pr=false is accepted"
assert_eq "false" "$(json_field "$RUN_STDOUT" normalized.publishPr)" "publish_pr=false is normalised"

run_capture valid-reviewer --reviewer ENGINEER
assert_eq "0" "$RUN_RC" "a registry reviewer id is accepted case-insensitively"
assert_eq "engineer" "$(json_field "$RUN_STDOUT" normalized.reviewer)" "reviewer ids are normalised to lowercase"

run_capture valid-watch --watch-only true
assert_eq "0" "$RUN_RC" "watch_only=true is accepted"
assert_eq "true" "$(json_field "$RUN_STDOUT" normalized.watchOnly)" "watch_only=true is normalised"

run_capture valid-combined \
  --model gpt-5.6-sol \
  --base-branch feature/input-135 \
  --publish-pr false \
  --reviewer Reviewer \
  --watch-only true
assert_eq "0" "$RUN_RC" "all five manual inputs are accepted together"
assert_eq "gpt-5.6-sol" "$(json_field "$RUN_STDOUT" normalized.model)" "combined validation keeps model"
assert_eq "feature/input-135" "$(json_field "$RUN_STDOUT" normalized.baseBranch)" "combined validation keeps base_branch"
assert_eq "false" "$(json_field "$RUN_STDOUT" normalized.publishPr)" "combined validation keeps publish_pr"
assert_eq "reviewer" "$(json_field "$RUN_STDOUT" normalized.reviewer)" "combined validation keeps reviewer"
assert_eq "true" "$(json_field "$RUN_STDOUT" normalized.watchOnly)" "combined validation keeps watch_only"

run_capture invalid-model --model 'gpt 5'
assert_eq "65" "$RUN_RC" "an invalid model is rejected with EX_REFUSED"
assert_eq "false" "$(json_field "$RUN_STDOUT" ok)" "an invalid model returns ok=false"
assert_contains "$RUN_STDERR" "squad-dispatch: model may contain only" "the model rejection is explained on stderr"

run_capture invalid-branch-chars --base-branch 'release;rm'
assert_eq "65" "$RUN_RC" "a base_branch with unsafe characters is rejected"
assert_contains "$RUN_STDERR" "squad-dispatch: base_branch may contain only" "the base_branch charset rejection is explained"

run_capture invalid-reviewer-chars --reviewer 'fact checker'
assert_eq "65" "$RUN_RC" "a reviewer with unsafe characters is rejected"
assert_contains "$RUN_STDERR" "squad-dispatch: reviewer may contain only" "the reviewer charset rejection is explained"

run_capture invalid-publish --publish-pr yes
assert_eq "65" "$RUN_RC" "publish_pr rejects any value other than true or false"
assert_contains "$RUN_STDERR" "squad-dispatch: publish_pr must be exactly 'true' or 'false'" "publish_pr errors name the allowed literals"

run_capture invalid-watch --watch-only no
assert_eq "65" "$RUN_RC" "watch_only rejects any value other than true or false"
assert_contains "$RUN_STDERR" "squad-dispatch: watch_only must be exactly 'true' or 'false'" "watch_only errors name the allowed literals"

run_capture unknown-reviewer --reviewer ghost
assert_eq "65" "$RUN_RC" "an unknown reviewer id is rejected"
assert_contains "$RUN_STDERR" "squad-dispatch: reviewer 'ghost' is not an active squad member id" "unknown reviewers name the registry requirement"

run_capture missing-branch --base-branch missing-branch
assert_eq "65" "$RUN_RC" "a missing base branch is rejected"
assert_contains "$RUN_STDERR" "squad-dispatch: base_branch 'missing-branch' does not exist in octo/demo." "missing branches say which repository was checked"

FAKE_INPUTS_GH_MODE=verify-fail run_capture unverifiable-branch --base-branch main
assert_eq "65" "$RUN_RC" "a branch probe failure is rejected"
assert_contains "$RUN_STDERR" "squad-dispatch: base_branch 'main' could not be verified in octo/demo:" "branch probe failures are distinct from missing branches"

run_capture help --help
assert_eq "0" "$RUN_RC" "validate-manual-inputs --help succeeds"
assert_contains "$RUN_STDERR" "usage: squad-dispatch.js validate-manual-inputs" "the help text names the subcommand"

test_summary
