# engineer History

## 2026-07-15: Initial charter

Created as the primary code-writing agent for Squad on ACA. Code-writing work should use `claude-opus-4.8` and should be routed here by default.

## 2026-07-28: Sprint 0 — baseline test-harness guardrails (issue #6)

Branch `squad/6-s0-baseline-guardrails`. Guardrails only — no SandboxGroups
feature work.

- **Harness self-test.** Added `worker/tests/test_run_tests.sh` (43 assertions).
  It runs the real `run-tests.sh` against a throwaway directory of synthetic
  suites via a new `SQUAD_ACA_TEST_DIR` override and asserts exit code, banner,
  and suite counts for fail / non-1 fail / pass / mixed / skip / skip+fail /
  all-skipped / empty dir / default discovery. Closes the PR #9 bug class, where
  `status=$?` was captured inside `if ! bash "$test_script"` (always 0) so a
  failing suite still printed the success banner and exited 0.
- **Runner accounting.** `run-tests.sh` now captures each suite's real exit
  code, counts passed/failed/skipped, prints a skip summary, and refuses to
  print the success banner when no suite executed (empty dir or all skipped).
  Default behaviour with the override unset is unchanged.
- **Declared dependencies.** New `worker/tests/lib/deps.sh` — `require_deps`
  emits a visible `SKIP: <suite> — missing <dep>` and exits 77 (never a pass),
  and never downloads a runtime. Existing suites declare git / node / mktemp /
  date.
- **CI.** `worker-tests.yml` path filters broadened to `scripts/**`, `config/**`
  (existing paths kept); the worker job now fails if any suite SKIPs on CI; new
  `powershell-validation` job runs `scripts/validate.ps1` on `windows-latest`
  with pre-installed pwsh (nothing downloaded).
- **Docs.** `docs/validation.md` gained a "Worker test harness guarantees"
  section: self-test, skip semantics, Linux-only constraint, and the CI
  PowerShell job rationale.

**Evidence** (WSL Ubuntu, Node 24.12.0, `bash worker/tests/run-tests.sh`):
before 4 suites / 136 assertions (11/62/40/23), after 5 suites / 179 assertions
(11/62/40/23/43) — the 136 pre-existing assertions are unchanged and green.
Re-injecting the PR #9 pattern makes `test_run_tests.sh` fail with 20+ assertion
failures and exit 1; injecting a failing assertion into `test_git_checkout.sh`
makes the runner print "One or more worker capability test suites FAILED." and
exit 1. Removing `node` from PATH produces three visible `SKIP:` lines,
`Suites: 2 passed, 0 failed, 3 skipped.`, and trips the new CI skip guard.
`scripts/validate.ps1` unchanged at 35 passed / 0 failed.

**Not done:** `scripts/validate.ps1` is still Windows-only (Windows path
separators), so the PowerShell CI job runs on `windows-latest` rather than
`ubuntu-latest`. Making it cross-platform is a control-plane change, out of
scope for a tests/CI/docs-only sprint; recorded as a follow-up in
`docs/validation.md`.