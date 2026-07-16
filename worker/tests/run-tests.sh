#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

status=0
for test_script in worker/tests/test_*.sh; do
  printf '==> %s\n' "$test_script"
  if ! bash "$test_script"; then
    status=$?
    break
  fi
  printf '\n'
done

if [[ $status -ne 0 ]]; then
  exit $status
fi

printf 'All worker tests passed.\n'
