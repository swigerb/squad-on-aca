#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'ASSERTION FAILED: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="${3:-values differ}"
  [[ "$expected" == "$actual" ]] || fail "$message (expected: $expected, actual: $actual)"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-missing substring}"
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing: $needle)"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-unexpected substring present}"
  [[ "$haystack" != *"$needle"* ]] || fail "$message (unexpected: $needle)"
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
}

assert_json_file_equals() {
  local actual="$1"
  local expected="$2"
  node - "$actual" "$expected" <<'NODE'
const fs = require('node:fs');
const [actualPath, expectedPath] = process.argv.slice(2);
const actual = JSON.parse(fs.readFileSync(actualPath, 'utf8'));
const expected = JSON.parse(fs.readFileSync(expectedPath, 'utf8'));
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  console.error('Actual:', JSON.stringify(actual, null, 2));
  console.error('Expected:', JSON.stringify(expected, null, 2));
  process.exit(1);
}
NODE
}
