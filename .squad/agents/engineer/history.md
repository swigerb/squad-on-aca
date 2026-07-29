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

## 2026-07-28: `squad-aca logs` exit-code + Log Analytics fallback (issue #13)

Branch `squad/13-logs-fallback`. Two independent defects, both fixed.

- **False green.** `Invoke-Logs` ended with the `az` call, so `$LASTEXITCODE`
  was never inspected and a run that produced no logs still exited 0 — the
  CLI instance of the class of bug that closed PR #9. Log retrieval now lives
  in `scripts/lib/aca-logs.ps1`, every `az` exit code is checked, and a total
  failure throws (exit 1).
- **Extension dependency.** `az containerapp job logs show` is the only
  control-plane call that needs the `containerapp` CLI extension; `run`,
  `status`, `sessions`, `stop`, and `doctor` are core `az`. Added a Log
  Analytics fallback against the workspace `deploy.ps1` already provisions
  (`law-squad-aca`), so `logs` works wherever `status` works.
- **Prompt hazard.** All `az` calls run with
  `AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no` (previous value restored, set or
  unset), so a missing extension can never block on stdin in CI/Ralph/Watch.
- **Config.** `deploy.ps1` now emits `logAnalyticsWorkspace`; `Get-AcaConfig`
  defaults it to `law-squad-aca`; `squad-aca configure
  --log-analytics-workspace` overrides it. No hardcoded resource names in the
  log path.
- **Doctor.** One new row, `Logs path`, reporting `ok` / `fallback` / `failed`.
- **5.1 trap found while testing.** Windows PowerShell 5.1 does not unroll a
  JSON array from `ConvertFrom-Json` the way pwsh 7 does, so the fallback
  returned blank lines under the `.cmd` shim while passing under pwsh. Rows are
  now flattened explicitly, and `validate.ps1` re-runs the fallback under 5.1
  so the two hosts cannot diverge again.

**Evidence.** `scripts/validate.ps1`: 35 passed / 0 failed before, 50 passed /
0 failed after (+1 parse for the new lib, +14 new checks). Worker suite
unchanged: 5 suites, 179 assertions (11/62/40/23/43), 0 failed, 0 skipped.
With a stubbed `az` that refuses the extension, `squad-aca logs <execution>`
printed the old prompt/EOFError text and `LOGS_EXIT=0` before the fix, and
prints actionable remediation with `LOGS_EXIT=1` after. `help`, `sessions`,
`stop`, and `status` output is byte-identical before and after; `doctor`
differs only by the new row.

**Not done:** no live-Azure re-run of the fallback against the real
`law-squad-aca` workspace in this session — the query shape is the one already
recorded in issue #13 as verified live, and everything here was proven offline
with a stubbed CLI.
