#!/usr/bin/env bash
# Tiny bash test helper used by worker/tests/*.sh — no external dependency.
# Intentionally does NOT set -e: it is sourced by test drivers that need to
# keep running after a failed assertion so a full summary can be printed.
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$expected" != "$actual" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "FAIL: ${msg} (expected: '${expected}', actual: '${actual}')"
    return 0
  fi
  echo "ok - ${msg}"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "FAIL: ${msg} (expected output to contain: '${needle}')"
    echo "--- actual output ---"
    echo "$haystack"
    echo "---------------------"
    return 0
  fi
  echo "ok - ${msg}"
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "FAIL: ${msg} (expected output to omit: '${needle}')"
    echo "--- actual output ---"
    echo "$haystack"
    echo "---------------------"
    return 0
  fi
  echo "ok - ${msg}"
}

test_summary() {
  echo ""
  echo "${TESTS_RUN} assertions run, ${TESTS_FAILED} failed."
  if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}
