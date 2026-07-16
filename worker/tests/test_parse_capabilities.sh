#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
. worker/tests/lib/assert.sh

WORK_DIR="worker/tests/.work/parse"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/empty"

node - <<'NODE' > "$WORK_DIR/parsed.json"
const fs = require('node:fs');
const { parseCapabilityManifest } = require('./worker/lib/parse-capabilities');
const manifest = parseCapabilityManifest(fs.readFileSync('./worker/tests/fixtures/satisfied.yml', 'utf8'));
process.stdout.write(JSON.stringify(manifest, null, 2));
NODE
assert_contains "$(cat "$WORK_DIR/parsed.json")" '"version": "1"' "parser should normalize version"
assert_contains "$(cat "$WORK_DIR/parsed.json")" '"name": "git"' "parser should include tool names"

for fixture in satisfied required-sandbox optional-sandbox optional-fallback missing-required-credential missing-required-tool unknown-image-optional unknown-image-required invalid-version missing-version duplicate-top-level duplicate-nested-required unknown-top-level wrong-tools-type invalid-required-type malformed malformed-array-element missing-fields; do
  node worker/lib/resolve-capabilities.js --cwd . --manifest "worker/tests/fixtures/${fixture}.yml" > "$WORK_DIR/${fixture}.json"
  assert_json_file_equals "$WORK_DIR/${fixture}.json" "worker/tests/fixtures/expected/${fixture}.json"
done

node worker/lib/resolve-capabilities.js --cwd "$WORK_DIR/empty" > "$WORK_DIR/no-manifest.json"
assert_json_file_equals "$WORK_DIR/no-manifest.json" "worker/tests/fixtures/expected/no-manifest.json"

unknown_top_level_output="$(cat "$WORK_DIR/unknown-top-level.json")"
assert_contains "$unknown_top_level_output" 'redacted' 'unknown key diagnostics must be redacted'
assert_not_contains "$unknown_top_level_output" 'unknownField' 'raw top-level key must not leak'

unknown_image_output="$(cat "$WORK_DIR/unknown-image-required.json")"
assert_contains "$unknown_image_output" 'image:[redacted]' 'unknown image hints must be redacted'
assert_not_contains "$unknown_image_output" 'experimental-image' 'raw image hint must not leak'

printf 'parse/resolution tests passed\n'
