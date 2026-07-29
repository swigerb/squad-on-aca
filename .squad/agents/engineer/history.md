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
## 2026-07-29: Sprint 3 - provider-neutral execution boundary (issue #6)

**Branch:** `squad/6-s3-provider-abstraction`

Introduced the execution provider seam PRD #6 needs before a Sandboxes provider
can exist. Sprint 3 is a **zero-observable-behaviour-change** sprint: the seam
goes in, nothing a user sees moves.

- **Contract.** `scripts/lib/squad-aca-provider.ps1` defines six operations -
  `create` / `wait` / `status` / `logs` / `cancel` / `terminate` - dispatched
  through one choke point (`Invoke-SquadProviderOperation`) so an off-contract
  operation cannot be called. Includes the PRD #6 request
  (`schemaVersion`, `sessionId`, `dispatchSource`, `repository`, `task`,
  `capabilityManifest`, `capabilityResolution`, `executionPreferences`, `git`)
  and response (`executionMode`, `sandboxClass`, `sessionHandle`, `status`,
  `statusPollRef`, `fallbackReason`).
- **Opaque handles.** `sqx1.`-prefixed tokens encoding provider id + a
  provider-private payload. Decoding rejects malformed handles and handles
  minted by another provider, so no call site can assume a handle is an ACA Job
  execution name.
- **ACA Job adapter.** `scripts/lib/providers/squad-aca-job-provider.ps1`
  preserves today's behaviour exactly. `create` and `cancel` write nothing of
  their own to the pipeline so substrate output still passes through untouched;
  records keep the opaque handle separate from a `Display` object so
  `squad-aca sessions` renders the same eight columns.
- **Fake provider.** `scripts/lib/providers/squad-fake-provider.ps1` - state in
  JSON files, no network, no clock dependence, `wait` never sleeps. This is what
  makes Sprint 5 testable without a live subscription.
- **`cancel` vs `terminate`.** `squad-aca stop` maps to `cancel` (substrate
  semantics, failures passed through). `terminate` is the idempotent teardown
  PRD #6 requires and is deliberately **not** wired to a CLI command this
  sprint. Conflating the two is what produced the PR #9 `stop` regression.
- **CLI routed through the seam:** `run`, `smoke`, `telemetry smoke`,
  `sessions`, `logs`, `stop`, `open`. Left alone on purpose:
  `Assert-AcaConfigured`, `doctor`, `ralph`, `watch`, `secrets`, `destroy`,
  `status`, `new` - infrastructure/config-plane calls, not per-execution
  lifecycle, so moving them adds risk with no Sprint 5 payoff.
- **No Sandboxes code.** `New-SquadExecutionProvider -Kind` accepts `aca-job`
  and `fake` only. No `aca` binary invocation, no feature flag.

**Evidence.**

Differential CLI capture: `git archive main scripts` materialised main's
scripts; a 22-case harness ran both revisions under stub `az`/`gh` binaries
(fake `HOME`, synthetic config, local bare-repo `origin` for the `run` cases)
recording exit code, stdout, stderr, and every `az`/`gh` argv. **19 of 22 cases
are byte-identical by SHA-256.** The 3 that differ (`stop` on an unknown
session, `secrets` usage error, `run` with no prompt) differ **only** in the
source line number PowerShell prints in its own error-record annotation
(`squad-aca.ps1:528` -> `:538`); the exception text, exit code, and az/gh call
sequences match exactly. Normalising that annotation gives **22 of 22
identical**. Line numbers shift whenever a file gains lines, so this is not
removable without freezing the file layout.

`scripts/validate.ps1`: before 35 passed / 0 failed, after **70 passed / 0
failed** - 20 new provider contract checks (section 7) and 11 new CLI
regression checks (section 8), the latter driving the real CLI against stub
`az`/`gh` and asserting exit codes, rendered columns, and exact az call
sequences. Worker suite unchanged: **5 suites / 179 assertions
(11/62/40/23/43), 0 failed, 0 skipped.**

**Not done:** no bash suite was added. The worker CI job fails on any SKIP, and
a PowerShell-dependent suite would skip on a runner without `pwsh`; the new
PowerShell tests therefore live in `validate.ps1`, which CI already runs on
`windows-latest`. Section 8 skips (does not fail) on non-Windows because the
stub binaries are `.cmd` - the same Windows-only constraint `validate.ps1`
already carries.

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
## 2026-07-28: Sprint 2 — capability routing decision (issue #6)

Branch `squad/6-s2-capability-resolution`. Routing decision only: computed and
reported, never acted upon. No sandbox is created, no dispatch changes, no
execution-path changes.

- **Resolver.** New `worker/lib/resolve-capability-route.js` builds on the
  existing `parse-capabilities.js` (requires and reuses its parser/validator;
  that file is untouched) and emits stable JSON — `schemaVersion`, `route`,
  `reason`, `requiredTools[]`, `requiredCredentials[]`, `egressHosts[]`,
  `imageHint`, `defaultImageSufficient`, `sandboxClass`, `manifestPresent`,
  `manifestVersion`, plus hint provenance, unsatisfied-requirement lists,
  catalog provenance, and a fixed `detail` string. Fixed key order, arrays
  de-duplicated and sorted by code unit, so it is golden-testable and diffable.
  Routes: no manifest → `aca-job` (preserved byte-for-byte), satisfied by the
  default profile → `aca-job`, exceeds it with an approved class → `sandbox`,
  otherwise → `fail-closed`. Malformed/invalid manifests, unsafe manifest
  paths, and unusable catalogs all fail closed, never a silent `aca-job`.
- **Administrator catalog.** New `config/sandbox-classes.json`, control-plane
  owned and explicitly not repository-controlled. Each class pins id, image
  reference, resource limits, tools, egress host templates, allowed credential
  types, and concurrency/cost limits; `defaultWorker` captures the current ACA
  job profile so "satisfied by the default image" is data, not a hard-coded
  branch. `egress` mirrors the real ACA Sandboxes policy shape
  (`Microsoft.App/sandboxGroups`, `2026-02-01-preview`): `defaultAction` +
  ordered `hostRules[]` of `{pattern, action}` + `trafficInspection`. Ships
  `provisional: true` with a `$comment` header; every value is placeholder data
  pending administrator review, and the decision surfaces `catalogProvisional`.
- **Security invariants.** A manifest can only *request*; everything grantable
  comes from the catalog. `image.hint` only disambiguates among approved
  classes and is never used as an image reference — the emitted `imageHint` is
  always a catalog-owned string or `null`, so a path-traversal-shaped hint
  resolves to `null` and never reaches the output. Repository egress entries can
  only narrow within a class template. Output carries names/counts/fixed reason
  codes only; free-form `reason`/`notes` text never appears. An identifier that
  is character-safe but implausibly long fails closed without being echoed.
- **Preflight untouched as the final gate.** `squad-capability-preflight.sh`
  changed only in two comment/doc-anchor strings (the renamed
  `#future-per-task-images-and-sandboxes` heading and the corrected product
  name); no logic, no guard, no exit code changed.
- **Tests.** New `worker/tests/test_capability_routing.sh` (123 assertions) in
  the existing style with `lib/assert.sh` + `require_deps node`, golden JSON in
  `worker/tests/expected/` and manifests in `worker/tests/fixtures/routing-*.yml`.
  Covers no-manifest, satisfied-by-default, sandbox-matched, no-matching-class,
  egress-outside-template, malformed, unknown keys, duplicate keys, wrong types,
  control characters, oversized tool/host/hint identifiers, path-traversal and
  injection-shaped values (proving nothing leaks), symlink/absolute/escaping
  manifest paths, catalog faults (missing, unparseable, unsupported schema),
  egress wildcard semantics including suffix-smuggling, and determinism under
  reordered/duplicated entries.
- **CI/docs.** `worker-tests.yml` syntax gate now `node --check`s the resolver
  and parses the catalog. `docs/capability-manifest.md` gained the routing
  contract and catalog documentation; `docs/validation.md` gained the golden
  fixture workflow and the new suite's dependencies; terminology corrected from
  "SandboxGroups" to Azure Container Apps Sandboxes across docs.

**Evidence** (WSL Ubuntu, Node 24.12.0, `bash worker/tests/run-tests.sh`):
before 5 suites / 179 assertions (11/62/40/23/43), after 6 suites / 302
assertions (123/11/62/40/23/43) — the 179 pre-existing assertions are unchanged
and green, `Suites: 6 passed, 0 failed, 0 skipped.` Mutation-tested the new
suite: making unapproved classes selectable fails 5 assertions, echoing the raw
manifest hint fails 3, routing an invalid manifest to `aca-job` fails 32, and
removing the identifier length bound fails 3.

**Not done:** neither the resolver nor the catalog is copied into the worker
image, and nothing calls the resolver — deliberate, since Sprint 2 must not
change the execution path. The resolver mirrors rather than shares the
preflight's hardened manifest-path resolution, because modifying the shipped
preflight was out of scope; unifying them is recorded as a follow-up in
`docs/capability-manifest.md`. The catalog remains `provisional: true` and must
be reviewed before Sprint 5 acts on any decision.
### Sprint 3 addendum: merged `main` (Sprints 2 and 4, plus the #16 logs fix)

`main` advanced from `742e20e` to `9fe6823` mid-sprint (#14 Sandboxes
feasibility, #15 capability routing, #16 `squad-aca logs` exit-code and Log
Analytics fallback). #16 rewrote the exact `Invoke-Logs` body this sprint
routed through the provider, so `main` was merged in rather than left to
conflict - shipping the seam unmerged would have silently reverted the #13
fix.

Resolution: the ACA Job adapter's `logs` operation now delegates to
`Get-AcaExecutionLog` (`scripts/lib/aca-logs.ps1`), keeping the extension ->
Log Analytics -> throw behaviour intact, and the contract's `logs` operation
returns a provider-neutral `Lines` + optional `Notice` result instead of
streaming. `Invoke-Logs` keeps the presentation (fallback notice, empty-result
warning, line output); the provider owns the fetch.

Re-verified after the merge:
- `compare-cli-baseline.ps1 -BaselineRef main` (now `9fe6823`): **19/22
  byte-identical, 22/22 identical ignoring PowerShell's error-record line
  annotation**, exit 0.
- `compare-cli-baseline.ps1 -BaselineRef 742e20e` (the pre-merge branch base):
  same result, exit 0 - Sprint 3 in isolation was already clean.
- `scripts/validate.ps1`: **86 passed / 0 failed** (35 at Sprint 0, 71 after
  Sprint 3's own sections, 86 once #16's 15 logs checks merged in).
- Worker suite: **6 suites / 302 assertions (123/11/62/40/23/43), 0 failed, 0
  skipped** - unchanged from `main`; this sprint added no bash tests.
