#!/usr/bin/env bash
# TEMPORARY — issue #92 sprint 1 proof. This suite deliberately hangs forever
# and is committed ONLY to watch the real GitHub Actions job fail in minutes
# instead of GitHub's six-hour default, proving the workflow's timeout-minutes
# and worker/tests/run-tests.sh's per-suite `timeout` wrapper actually work in
# CI (not just in a local/synthetic harness). Removed in the very next commit.
set -uo pipefail
echo "== TEMPORARY deliberate hang proof (issue #92) =="
sleep 999999
