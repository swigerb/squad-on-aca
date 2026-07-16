#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
. worker/tests/lib/assert.sh

WORK_DIR="worker/tests/.work/preflight"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/sandbox-repo" "$WORK_DIR/fail-repo" "$WORK_DIR/empty-repo"
cp worker/tests/fixtures/required-sandbox.yml "$WORK_DIR/sandbox-repo/squad-capabilities.yml"
cp worker/tests/fixtures/missing-required-tool.yml "$WORK_DIR/fail-repo/squad-capabilities.yml"

sandbox_output="$(SANDBOX_CLASSES_PATH="$ROOT_DIR/config/sandbox-classes.json" worker/lib/squad-capability-preflight.sh "$WORK_DIR/sandbox-repo" 2>"$WORK_DIR/sandbox.stderr")"
printf '%s\n' "$sandbox_output" > "$WORK_DIR/sandbox.json"
assert_json_file_equals "$WORK_DIR/sandbox.json" "worker/tests/fixtures/expected/required-sandbox.json"
assert_contains "$(cat "$WORK_DIR/sandbox.stderr")" 'recorded only' 'sandbox route should stay non-executing in sprints 0-2'

set +e
SANDBOX_CLASSES_PATH="$ROOT_DIR/config/sandbox-classes.json" worker/lib/squad-capability-preflight.sh "$WORK_DIR/fail-repo" > "$WORK_DIR/fail.json" 2>"$WORK_DIR/fail.stderr"
status=$?
set -e
assert_eq '78' "$status" 'fail-closed preflight should exit 78'
assert_json_file_equals "$WORK_DIR/fail.json" "worker/tests/fixtures/expected/missing-required-tool.json"
assert_contains "$(cat "$WORK_DIR/fail.stderr")" 'failed closed' 'fail-closed stderr should be explicit'
assert_not_contains "$(cat "$WORK_DIR/fail.stderr")" 'kubectl' 'stderr should not leak raw manifest values'

aca_output="$(SANDBOX_CLASSES_PATH="$ROOT_DIR/config/sandbox-classes.json" worker/lib/squad-capability-preflight.sh "$WORK_DIR/empty-repo" 2>"$WORK_DIR/aca.stderr")"
printf '%s\n' "$aca_output" > "$WORK_DIR/aca.json"
assert_json_file_equals "$WORK_DIR/aca.json" "worker/tests/fixtures/expected/no-manifest.json"
assert_contains "$(cat "$WORK_DIR/aca.stderr")" 'resolved to aca-job' 'no-manifest preflight should preserve aca-job default'

printf 'preflight tests passed\n'
