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

## Sprint 6 - one dispatch decision for every dispatcher, plus durable leases

PRD #6 asked for two things that turn out to be the same thing: "Ralph, Watch,
and local CLI share one routing decision", and "claim and session state are
written before compute is requested". A shared decision that each dispatcher
recomputes is not shared; a claim written by three different code paths is
three different claims.

### One implementation, two thin callers

The routing decision and the whole lease lifecycle live in Node under
`worker/lib/` (`dispatch-decision.js`, `dispatch-lease.js`, and the CLI seam
`squad-dispatch.js`). `worker/lib/ralph-dispatch.sh` and the new
`scripts/lib/dispatch-contract.ps1` are shims: they shell out to
`node worker/lib/squad-dispatch.js` and parse JSON. Neither contains a routing
rule.

Node was chosen because it needed no new runtime anywhere: the Sprint 2
capability resolver this wraps is already Node, Ralph already shells to `node`,
and the worker image already ships it. Porting the resolver to PowerShell (or
re-deriving it in bash) would have created the second implementation the sprint
exists to prevent. `validate.ps1` now asserts, on the file itself, that
`dispatch-contract.ps1` contains no route literal in executable code - so a
future "small PowerShell adjustment" to the route fails a check rather than
drifting.

The `routing` object deliberately excludes dispatcher identity (that lives one
level up in `dispatchSource`), which lets the tests compare the three
dispatchers' decisions **byte-for-byte** instead of field-by-field.

If `node` is missing, dispatch fails closed. A local fallback guess would be the
second routing rule.

### Lease state lives in GitHub

On an orphan ref `squad-aca-leases`, one JSON blob per lease under `leases/`,
via the Contents API. Reasons, in order of weight:

1. **No new infrastructure.** GitHub is already this project's durable system of
   record, and Ralph already claimed work by labelling an issue - this extends a
   model that exists rather than adding a table, queue or storage account.
2. **Every dispatcher can already reach it** with the credential it already has.
3. **It survives a laptop reboot**, which the PRD explicitly requires.
4. **The Contents API supplies both lock primitives**: create-once (PUT without
   `sha` -> 422 if present) is the atomic claim; compare-and-swap (PUT with the
   read `sha` -> 409 if stale) is the atomic update. No lock service needed.
5. **Off the default branch**, so lease churn never pollutes `main`, never
   triggers CI, and never shows up in a PR diff.

The cost is a new hard dependency on `contents: write`, documented in the
runbook. That was accepted rather than degraded: running unleased work would
defeat the invariant the lease exists to enforce.

The lease key is the idempotency key - `issue-<n>` when an issue exists, else
`session-<id>`. Two dispatchers that pick different session names for the same
issue converge on one lease, which is what makes "Ralph ran twice" and "Ralph
and the CLI both fired" the same, already-handled case.

### `reclaimed` must be re-claimable (a real bug, caught by a test)

`reclaimed` is terminal for the sweeper (never swept twice) but repairable for a
claimer. The first implementation treated it as terminal for both, which meant
the sweeper permanently retired the work it reclaimed - every transient stall
became lost work, the exact opposite of reclaiming. `test_dispatch_contract.sh`
case 7 ("the reclaimed work can be claimed again") found it.

### Cleanup follows the existing pattern, not a new one

Gone-classification mirrors `Test-AcaJobExecutionGone` in
`squad-aca-job-provider.ps1`: deny-list first, so a message mentioning both
`401` and `not found` is a failure; `127`/`-1` exit codes are never "gone"; an
unrecognised failure is a failure. Already-cleaned, already-terminal and
externally-deleted are SUCCESS; auth, RBAC, throttling and network surface.

### Verification

- `scripts/validate.ps1`: **117 passed / 0 failed** (baseline 104 / 0; 13 new
  checks).
- Worker suite (WSL): **7 suites / 361 assertions, 0 failed, 0 skipped**
  (baseline 6 / 302). Ralph's suite went 23 -> 47 assertions; the no-secret and
  no-prompt-leak assertions are untouched.
- `verify-cli-golden.ps1`: **22/22**, after a deliberate `-Update`.
- `compare-cli-baseline.ps1 -BaselineRef main`: 9/22 byte-identical, 12/22
  ignoring error line numbers; 10 goldens changed for three intended reasons
  (the `leases` help line; `Route`/`Source` columns in `sessions`; three new
  `SQUAD_DISPATCH_*` env vars on `az containerapp job start`). The remaining
  three differ only by PowerShell error-record line annotations, which moved
  because `squad-aca.ps1` grew.

### `Format-Table` silently drops columns

Adding `Route` and `Source` pushed `sessions` past the implicit 120-column
width, and `Format-Table -AutoSize` responded by **omitting** `Source`
entirely - not truncating it. `-Wrap` fixes truncation but not omission. Pinned
with `Out-String -Width 200`, and recorded in `docs/validation.md` as a golden
portability pin, because a golden captured on a wide console and verified on a
narrow one would otherwise diff for reasons no user caused.

### Mutation results

Every new assertion was mutation-tested; each mutation was caught by the check
that exists for it:

| Mutation | Check that failed |
| --- | --- |
| `isGoneResult` returns true for any non-zero exit (401 read as "gone") | "Sweeping under an auth failure reported success" + "Completing a lease under an auth failure reported success" |
| A live lease no longer blocks a second claim | "Duplicate claim handling changed (first=created second=repaired)" + "Duplicate dispatch started 1 execution(s) on the second run" |
| `sweepLeases` never reclaims a stale lease | "Sweeper behaviour changed (first=0 second=0)" |
| PowerShell claims *after* `az containerapp job start` | "Claim-before-compute ordering broken (lease index=6, compute index=0)" |
| Ralph claims *after* `az containerapp job start` | "ordering: lease write index (7) precedes compute request index (1)" + "duplicate: az job start called exactly once across two runs (actual: 2)" |
| `reclaimed` no longer repairable | "sweeper: the reclaimed work can be claimed again" |

The ordering mutations are the ones that matter: both ordering checks compare
**indices in a shared, ordered call log** that the fake `az` and the fake `gh`
both append to. A presence-based check would have survived every one of them.

### Not done, deliberately

- No Sandboxes provider, no `aca` binary, no credential brokerage (Sprints 5/7).
  A `sandbox` route resolves but falls back to `aca-job` with
  `fallbackReason: sandbox-provider-unavailable`, so this branch does not depend
  on PR #19 landing.
- `scripts/show-status.ps1` still does not show route/source. It renders raw
  Azure JMESPath projections and has no access to the lease ledger; surfacing it
  there would mean a second rendering path for the same data. `sessions` and the
  new `leases` command are the surfaces.
## Sprint 5 - ACA Sandboxes provider behind a feature flag (PRD #6)

Branch `squad/6-s5-sandbox-provider`, worktree `wt-sfive`. Sprint 3 gave the
provider seam; Sprint 2 computed a route (`aca-job` | `sandbox` | `fail-closed`)
that nothing acted on. This sprint added the third provider and the gate that
finally acts on that decision - with the sandbox plane unreachable unless a flag
is explicitly turned on.

**What shipped**

- `scripts/lib/providers/squad-sandbox-provider.ps1` - all six contract
  operations over ACA Sandboxes, driven by the standalone `aca` binary (resolved
  through an overridable path so tests can stub it). Every preview-specific
  detail is inside this one file.
- `scripts/lib/squad-aca-provider.ps1` - `Test-SquadSandboxEnabled`,
  `Get-SquadSandboxCatalog`, `Get-SquadSandboxClass`,
  `Resolve-SquadExecutionRoute`, a `sandbox` branch in the factory, and an
  additive `-UntilTerminal` on `Wait-SquadExecution`.
- `scripts/lib/aca-logs.ps1` - extracted the shared `Invoke-CliSafe` that both
  `Invoke-AzPromptSafe` and the sandbox provider use, rather than inventing a
  second capture mechanism.
- `scripts/squad-aca.ps1` - `New-SessionExecutionProvider` checks the flag first
  and returns the ACA Jobs adapter immediately when it is off.
- `scripts/tests/cli-stub-harness.ps1` - an `aca.cmd` shim with its own ordered
  call log, an `az resource show` branch for the group identity check, and the
  `SQUAD_STUB_ACA_*` drivers. Extended, not duplicated.
- `scripts/validate.ps1` - two new sections (route gate; provider against the
  stubbed `aca`), 36 new checks.
- `docs/architecture.md`, `docs/runbook.md` updated.

**Decisions worth remembering**

- The flag is an environment variable (`SQUAD_ACA_ENABLE_SANDBOX`), not a config
  key. Adding a key to `Get-AcaConfig`'s fixed list would change what
  `configure` writes and put the goldens at risk for no benefit. An explicit
  `0`/`false` is a kill switch that beats an opted-in config.
- Flag OFF plus a `sandbox` decision fails **closed**, not back to `aca-job`. A
  `sandbox` route means the resolver already found the default image
  insufficient, so falling back would be exactly the "silently run unsafely"
  outcome PRD #6 forbids.
- The shipped catalog is still `provisional: true`, so the sandbox route fails
  closed even with the flag on until an administrator reviews it. That is a
  documented second prerequisite in the runbook, and the ON-path tests have to
  supply their own non-provisional catalog - which is itself the proof the gate
  bites.
- Session execution is **detached + poll**, never a synchronous exec.
  `aca sandbox exec` has a hard ~120s client timeout regardless of command
  duration; a 10-60 minute session held open by one exec dies at two minutes.
  Terminal state comes from the completion marker plus a recorded exit code -
  a marker with no exit code is `Unknown`, not `Succeeded`.
- `Network issue - retry policy expired` is **inconclusive**, never a failure.
  Reading it as a failure would kill healthy hour-long sessions at the two-minute
  mark.
- Ordering in `create` is a security control: identity assertion -> create ->
  egress -> lifecycle -> detached launch. A failure between egress and launch
  tears the sandbox down and rethrows the original error, so repository code can
  never run without policy and a policy-less sandbox is never left billing. The
  test asserts call **indexes**, not just presence.
- `terminate` reuses `Test-AcaJobExecutionGone` rather than inventing a second
  classifier, with two narrowings: transport-inconclusive is never "gone", and
  the Azure-CLI exit-3 convention is neutralised because `aca` documents no such
  rule.

**Verification**

- `scripts/validate.ps1`: **140 passed / 0 failed** (baseline 104/0; +36).
- `scripts/tests/verify-cli-golden.ps1`: **22 cases, 22 matching goldens**, exit 0.
- `scripts/tests/compare-cli-baseline.ps1 -BaselineRef main`: 19/22 byte-identical,
  **22/22 identical ignoring PowerShell's error-record line annotation**, exit 0.
- Worker suite (WSL): **6 suites / 302 assertions (123/11/62/40/23/43), 0 failed,
  0 skipped** - unchanged; this sprint added no bash tests.
- **12 mutations, 12 killed.** Egress moved after the launch, a synchronous
  (non-detached) launch, inconclusive-as-failure, terminate succeeding on every
  non-zero exit, the identity assertion removed, redaction removed, the flag
  defaulting ON, flag-OFF downgrading instead of failing closed, unapproved
  classes accepted, terminal state from the marker alone, no teardown after a
  policy failure, and auto-suspend left at its 600s default - each failed at
  least one check, and each failed a check that names the actual defect.

**Deliberately not done**

- Ralph/Watch wiring (Sprint 6) and credential brokerage (Sprint 7). Worker
  credentials are still environment assignments inside the launch command, so
  they appear in that one `aca` process argv on the client; the provider never
  repeats them into a response, an error, or a rendered argv. Recorded as a
  known limitation in `docs/architecture.md`.
- Repeated `--rule` on `aca sandbox egress set` is an **assumption**: only a
  single `--rule` was verified live, but the ADR's policy shape needs several.
  Worth confirming against a live sandbox before the first real run.
- The CLI cannot yet produce a `sandbox` decision end-to-end, because the Sprint
  2 resolver runs inside the worker. `New-SessionExecutionProvider` accepts a
  `-CapabilityResolution` so the wiring is a one-line change when a control-plane
  resolution exists.

## 2026-07-29 — Sprint 6: repairing the Sprint 5 merge into `squad/6-s6-unified-dispatch`

`origin/main` (Sprint 5, PR #19) was merged into this branch as `72af864`. The
sole conflict was `scripts/tests/cli-stub-harness.ps1`, and the resolution was
**not** a union: it parsed, but it silently dropped four of Sprint 6's seven
hunks in that file. Comparing the merge result against both parents is the only
way this shows up — `git diff HEAD^1 HEAD` listed Sprint 6 lines as *removals*.

Kept from Sprint 6 (3 hunks): the `$leaseDir` ledger directory, the
`SQUAD_DISPATCH_ROUTE` / `SQUAD_DISPATCH_SOURCE` entries in the job-show
fixture, and the `SQUAD_CALL_LOG` append in the fake `az` `:sqjobstart` label.

Dropped from Sprint 6 (4 hunks), now restored:

- `$callLog = Join-Path $Root "dispatch-calls.log"` and its truncation.
- The `LeaseDir` / `CallLog` / `FakeGhPath` properties on the stub object.
- `SQUAD_GH_BIN`, `FAKE_GH_STATE`, `FAKE_GH_FAIL_MODE`, `SQUAD_CALL_LOG`,
  `SQUAD_LEASE_NOW`, `SQUAD_LEASE_TTL_SECONDS`, `SQUAD_LEASE_BRANCH` in the
  save/restore env-name list.
- The whole "Dispatch leases (Sprint 6)" assignment block in
  `Invoke-SquadCliCapture`.

Both env-var lists — the `envNames` save/restore list and the reset block — are
exactly the place both sprints appended, and exactly where the loss happened.
Sprint 5's additions were intact; Sprint 6's were gone.

**One root cause, two symptoms.** With `$Stub.CallLog` absent,
`Get-Content -LiteralPath $null` threw — that is the "Dispatch ordering checks
threw: Cannot bind argument to parameter 'LiteralPath' because it is null."
With `SQUAD_GH_BIN` / `FAKE_GH_STATE` unset, the lease store in every capture
shelled out to a `gh` that could not serve the offline ledger, so the
claim-before-compute step failed and `smoke` never reached
`az containerapp job start` — that is "squad-aca smoke dispatch changed:" with
an empty call list. Neither was a golden problem.

The repaired file is now a strict union: the only lines it drops relative to
`HEAD^1` are three doc/comment lines main legitimately rewrote, and the only
lines it drops relative to `HEAD^2` are the three main lines Sprint 6 extends.

**Goldens: no regeneration was needed.** The 22 captures auto-merged correctly —
they already carry Sprint 6's `Route`/`Source` columns and
`SQUAD_DISPATCH_ROUTE` / `SQUAD_DISPATCH_SOURCE` / `SQUAD_LEASE_KEY` env stamps
*and* main's `### ACA CALLS` section. That section is empty in all 22, which is
the Sprint 5 claim ("nothing shells out to `aca` with the flag off") holding
under Sprint 6's dispatch path. `verify-cli-golden.ps1` is 22/22 with no
`-Update`. Portability pins are untouched: offset-free fixture timestamps,
`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`, the stubbed `squad` on PATH, and the
forced `SQUAD_ACA_ENABLE_SANDBOX=""` in every capture.

**Verification.** `validate.ps1` 163 passed / 0 failed / 0 skipped (was 161/2/0).
`verify-cli-golden.ps1` 22/22, exit 0. `verify-launch-detachment.ps1` PASS
(streams EOF in 2ms against a 3s worker). Worker suite under WSL: 7 suites,
361 assertions (123/35/11/62/40/47/43), 0 failed, 0 skipped.

**Mutations re-run against the merged harness** — all three still caught, with
the same messages recorded when they were first written:

| Mutation | Check that failed |
| --- | --- |
| PowerShell claims *after* `az containerapp job start` | "Claim-before-compute ordering broken (lease index=6, compute index=0)" + "Duplicate dispatch started 1 execution(s) on the second run" |
| Ralph claims *after* `az containerapp job start` | "ordering: lease write index (7) precedes compute request index (1)" + "duplicate: az job start called exactly once across two runs (actual: 2)" |
| `isGoneResult` returns true for any non-zero exit | 14 worker assertions across two suites (auth/forbidden/throttle/network sweep classification, missing-gh) + "Sweeping under an auth failure reported success" + "Completing a lease under an auth failure reported success" |

The ordering assertions are still by INDEX, not by presence, and the merged
`aca` call log is a separate file from `dispatch-calls.log`, so main's `aca`
stub reset cannot disturb the ordering evidence.

## 2026-07-29 — PR #21 reviewer rejection: sandbox failure classifier + baseline archive scope

Not my PR. The author (**security**) is locked out, and the reviewer assigned
me on the merits: B1 is a classifier-ordering and test-sensitivity problem, and
B2's root cause is a dependency my own Sprint 6 (PR #20) introduced without
widening the baseline tool's archive scope. Scope was deliberately narrow — the
credential design, the egress matcher and the merge tree were all verified sound
by the reviewer and I did not touch them.

**B1 part 2 — the classifier was actually wrong.** `Get-SandboxFailureKind`
matched `"429"`, `"401"` and `"403"` as bare substrings through
`[regex]::Escape()`, with `"429"` first in an ordered classifier. Azure decorates
every auth failure with a correlation, object or trace GUID, and GUIDs are hex,
so `AuthorizationFailed … Correlation ID: 1b8f429c-…` classified as `quota`. The
direction of failure is the harmful one: a rotated-out credential surfaced as
`[squad-sandbox:quota]` — "a ceiling was hit, retry later" — and an unattended
dispatcher would retry a credential fault forever. That is the exact harm the
taxonomy was added to prevent, inverted.

Numeric codes are now written `(?<![0-9A-Za-z-])429(?![0-9A-Za-z-])`. A plain
`\b` is **not** sufficient: `\b` treats `-` as a word boundary, so
`Correlation ID: 1b8f-429c` would still match. Requiring the delimiter to be
neither alphanumeric nor a hyphen kills every GUID occurrence — GUID groups are
4/4/4/4/12 hex characters, so a group is never exactly `429`, and every embedded
occurrence is bounded by a hex digit or a hyphen on at least one side. A real
code (`HTTP 429`, `(403)`, `status=401,`) always is delimited by a space,
parenthesis, comma or colon. I also pulled the named-code discipline across from
`Test-AcaJobExecutionGone`: `throttl`, `rate limit`, `Retry-After` on the quota
side; `AuthorizationPermissionMismatch`, `does not have authorization`,
`ExpiredAuthenticationToken`, `InvalidAuthenticationToken`,
`authentication failed` on the auth side.

**B1 part 1 — the guard could not see the property it was named for.** The
reviewer moved `$auth` ahead of `$quota` and the suite still reported 200/0/0.
No fixture was ambiguous between the two lists, so both orderings agreed on
every input. This is the *fifth* recurrence of this defect class in the
programme (PR #9's runner, Sprint 3 B1, Sprint 5 `cancel`, Sprint 6 B3, now
here), so the fix had to be structural, not another hand-written case.

Three devices, in order of how much they cost to bypass:

1. **Order is now data.** `$script:SandboxFailureRules` is an ordered array of
   `[pscustomobject]@{ Kind; Patterns }`, so a test can *walk* the classifier
   instead of only calling it.
2. **`DecidedBy`.** `Get-SandboxFailureClassification` returns
   `Kind` / `DecidedBy` / `Pattern`, mirroring `classifyGhFailure`'s `decidedBy`
   in `worker/lib/dispatch-lease.js` after Sprint 6's B3 fix.
   `Get-SandboxFailureKind` is a one-line wrapper, so no caller changed. Without
   this a precedence is not assertable at all: where only one list matches, both
   orderings agree.
3. **An adjacency audit.** validate computes, from the *shipping* pattern lists,
   which rules match each fixture; each ambiguous fixture declares
   `Also = @(...)`; the suite asserts the declared ambiguity really holds, and
   then asserts that **every adjacent pair of rules has at least one spanning
   fixture**. Adding a rule or deleting a discriminating fixture is now itself a
   failing check. A separate structural assertion rejects any pattern matching
   `^\d{3}$`, so the bare-substring mistake cannot be reintroduced.

Discriminating fixtures added: `403 Forbidden (QuotaExceeded)` (quota∩auth),
`AuthorizationFailed … 1b8f429c-…`, `AADSTS700016 … 5c429abc-…`,
`401 Unauthorized (request id 0000429f-…)`,
`still provisioning. Request ID: 4291aaaa-…`,
`(AuthorizationFailed) the sandbox is still provisioning` (auth∩readiness), and
`429 TooManyRequests (connection reset by peer)` (transport∩quota).

**B2 — the tool could not report "unchanged".** `compare-cli-baseline.ps1`
materialised the baseline with `git archive … $BaselineRef scripts`.
`scripts/lib/dispatch-contract.ps1` resolves `worker/lib/squad-dispatch.js` as a
*sibling* of `scripts/`, so six baseline cases died with `Cannot find module`
and the tool reported 16/22 "OBSERVABLE BEHAVIOUR CHANGED" even for two
identical trees. I archived the whole ref rather than adding `worker` to the
pathspec, so no future cross-directory dependency can recur this — the repo is
296 tracked files. A fail-loud guard now asserts the materialised baseline
contains `scripts\squad-aca.ps1` and `worker\lib\squad-dispatch.js`, which is
what turns a re-narrowed scope into a loud failure instead of a silent 16/22.
`-BaselineRef HEAD` and `-BaselineRef main` are both 22/22 byte-identical.

**Non-blocking items 3-6.** `Test-SandboxHostCoveredByPattern` got 22 direct
assertions using the reviewer's fuzz list (`github.com.evil.net`,
`evilgithub.com`, bare `*`, `*.`, `**`, trailing dot, `gıthub.com`,
`xn--gthub-jua.com`). `Invoke-CliSafeWithStdin`'s `"timed out after 120s"` is
now an inconclusive pattern *and* exit 124 is an explicit transport rule, so a
client timeout on the credential broker is `transport`, not `execution`.
Service-supplied labels from `Get-SquadSandboxInventory` now go through
`Assert-SandboxIdentifier` on both listing paths — I chose throw over skip
because silently dropping a malformed `squad-` label under-counts the
concurrency ceiling, which spends money. Two hostile listing fixtures (path
traversal, embedded newline) back that. The two tautological detachment
assertions were replaced with (a) the launch generator's refusal of a
credential-bearing env assignment, exercised *with* the probe token, and (b) a
behavioural `ARGVLEAK` sweep taken inside the worker.

**Verification.** `validate.ps1` 205 passed / 0 failed / 0 skipped (was
200/0/0). `verify-cli-golden.ps1` 22/22. `verify-launch-detachment.ps1` PASS
(CREDMODE=600, ARGVLEAK=absent, CREDFILE_AFTER=absent).
`compare-cli-baseline.ps1` 22/22 against both `HEAD` and `main` (was 16/22).
Worker suite under WSL: 7 suites, 409 assertions (123/76/11/62/40/54/43),
0 failed, 0 skipped. `### ACA CALLS` empty in all 22 goldens.

**Mutations** — all six caught, all reverted, tree clean afterwards:

| Mutation | Check that failed |
| --- | --- |
| `$auth` block moved ahead of `$quota` | "'ERROR: 403 Forbidden (QuotaExceede' -> auth (wanted quota)"; "was decided by 'auth', wanted 'quota'"; "Classification rule order is wrong: transport > auth > quota > readiness" (202/3) |
| bare `"429"` restored | four GUID-bearing auth/readiness fixtures all -> quota; "Bare HTTP status codes … will fire on GUIDs: quota: '429'" (203/2) |
| host matcher -> `$Host_.EndsWith($Pattern.Substring(2))` | `evilgithub.com`, `xgithub.com`, `notgithub.com`, `github.com` and `evil.example.com` vs `*.` all covered (wanted False) (204/1) |
| archive scope back to `$BaselineRef scripts` | "the materialised baseline (HEAD) has no worker\lib\squad-dispatch.js -- the archive scope is wrong" |
| launch leaks the token into argv | "ARGVLEAK=present … the staged token appeared in a process ARGUMENT VECTOR" |
| `$script:SandboxSecretEnvNames` guard removed | "the launch generator accepted a credential-bearing env assignment (GH_TOKEN) instead of refusing it" |

**Lesson recorded for the next agent.** `git checkout -- <file>` to revert a
mutation reverts *everything* uncommitted in that file — I lost all four
provider edits once and had to reapply them. Commit before mutation-testing.
Also: a PowerShell hashtable's missing key yields `$null` and `@($null)` has
Count 1, so ambiguity declarations must be read with `.ContainsKey()`.

## Sprint 9 — issues #17 and #22 (`fix/issues-seventeen-twentytwo`)

**#17 — a test whose result depended on where the repo was checked out.**
`test_parse_capabilities.sh:52` asserted `assert_not_contains "$out" '2'` to
prove the parser does not echo an invalid manifest version. The intent was
right; the assertion was not. The parser prefixes every error with the manifest
path it was handed, so the assertion also asserted something about the
developer's home directory. Same commit, correct parser, two answers:
`~/verifys2` -> 62 assertions run, 1 failed; digit-free path -> 62 run, 0
failed. CI stayed green only because the runner's workspace path contains no
`2`.

The fix asserts the specific thing the test cares about. `run_parser` sets
`out`, `rc` and `body`, where `body` is the output with the manifest path the
test itself supplied masked to `<manifest-path>`. All 21 invocations were
converted; every `assert_not_contains` now runs against `body`, presence
assertions still use `out`. The mask pattern is quoted *inside* the expansion
(`${out//"$manifest"/...}`) so bash matches it literally — a checkout path with
glob metacharacters cannot mis-mask and silently weaken the assertion. The
version literal is read out of the fixture with `sed` and pinned with
`assert_eq "2"`, so the absence assertion cannot become vacuous if someone
edits `invalid-version.yml`.

I rejected stripping the first output line: the parse-error path (`malformed.yml`
and the leak-token fixture) emits the path AND the message on ONE line, so
line-stripping would have made those absence assertions vacuous — a worse
defect than the one being fixed.

**Environment-coupling audit (the "while you are there" ask).** I read every
`assert_not_contains` in the worker suite and looked for coupling to checkout
path, temp path, hostname, timezone, locale and username. Only the parse suite
was affected. The routing resolver emits a pure JSON decision object with no
filesystem paths, so `test_capability_routing.sh`'s `assert_not_contains "$out"
".."` is safe. `test_preflight.sh` matches long distinctive sentinels, not bare
characters. No hostname/TZ/locale/username coupling anywhere; the CLI harness
already pins `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT` and offset-free timestamps.
Nothing else needed fixing, so nothing else was touched.

**#22 — a 404 that meant "you cannot write here".** The final live E2E run
failed at lease claim with a bare `gh: Not Found (HTTP 404)`. The repository
existed and was readable; the active `gh` account simply had `push: false`.
GitHub masks a write denial on a readable repository as 404, never 403, so the
real cause was invisible.

The handling was already correct and I changed none of it. The 404 was NOT
misread as "already gone", the lease store failed closed, and dispatch stopped
rather than starting compute without a durable claim. `classifyGhFailure`,
`REAL_FAILURE_PATTERNS`, `GONE_PATTERNS`, `isGoneResult` and the deny-list-first
ordering are byte-identical, and I added an assertion pinning that the exact
404 text from the incident still classifies as `gone`. This programme rejected
that defect class five times; a confusing message is the cheaper problem.

The four lease WRITE sites (base commit, ref, lease write, prune) now report
through `ghWriteFailure`. When — and only when — a write failure looks like a
404, it reads `repos/{owner}/{repo} --jq .permissions` once and, on `push:false`,
names the identity, the repository, the 404-masking rule and the fix. Costs
nothing on the success path (pinned by an assertion counting `gh` calls). If the
probe itself fails, the original message is reported verbatim: a diagnostic must
never mask the error it was explaining, and must never claim a permission it did
not observe. `probeLogin` reads raw text rather than JSON, because real
`gh api --jq .login` prints a bare unquoted string, and constrains it to the
GitHub username grammar so a diagnostic cannot become an injection vector.

`doctor` gained a `GitHub push` row. It previously reported `GitHub auth ok` for
an identity that could not write — that is precisely what let this reach a live
run. "`gh auth status` succeeded" answers a different question from "can this
identity write here". It reports `unknown` rather than guessing when the
permission cannot be read. While there I found that the `GitHub auth` row could
never report failure: native commands set `$LASTEXITCODE` but do not throw, so
the surrounding `catch` was dead code and the row was unconditionally `ok`
whenever `gh` existed. Now it checks the exit code.

**Other GitHub write paths — checked, reported, not "fixed".**
`deleteLeaseRecord` treats a 404 as "already gone", which is correct and
required for idempotency; with `push:false`, `claimLease` fails first, so a
prune is unreachable. Ralph's `gh issue edit --add-label` writes swallow all
failures by design (labelling must never fail a dispatch) and are equally
unreachable once the claim has failed. The exposure is confined to the lease
writes fixed here. I did not widen the change to satisfy symmetry.

**Goldens.** `11-doctor.txt` only, regenerated deliberately with `-Update`.
Exactly three added lines: `api user --jq .login` and
`api repos/octo/demo --jq .permissions` under `### GH CALLS`, and
`GitHub push     ok      octo-stub has push access to octo/demo` under
`### STDOUT`. No other golden moved; `### ACA CALLS` is empty in all 22.

**Verification.** `validate.ps1` 213 passed / 0 failed / 0 skipped (was
205/0/0). `verify-cli-golden.ps1` 22/22. `verify-launch-detachment.ps1` PASS.
`compare-cli-baseline.ps1 -BaselineRef HEAD` 22/22. Worker suite under WSL:
7 suites, 426 assertions (123/92/11/63/40/54/43), 0 failed, 0 skipped, **at a
digit-free path AND at a path containing `2`** — that pair is the #17 proof.
Parse suite 62 -> 63; dispatch contract 76 -> 92.

**Mutations** — all caught, all reverted, tree clean afterwards:

| Mutation | Check that failed |
| --- | --- |
| parser echoes the raw version (`${manifest.version}`) | `invalid-version.yml does not echo the raw manifest version`, plus three related redaction assertions — 63 run, **4 failed at BOTH** `~/mutfree` and `~/mut2dir`, identically. Before the fix the same suite failed at one path and passed at the other. |
| base-commit write reverted to `ghFailure` | `404 on write: names the identity and the permission it lacks`; `... explains why the status code is misleading`; `... tells the operator how to fix it` (92 run, 3 failed) and `validate.ps1` "A 404 lease write no longer explains the push-permission cause" (212/1) |
| `doctor` push row removed | `validate.ps1` "doctor no longer reports GitHub push access", "still reports a read-only identity as healthy", "does not fail safe when the permission read fails" (210/3) and `verify-cli-golden.ps1` 21/22 |

**Lesson recorded.** A validate guard written as a bare regex over a test file
matched my own explanatory comment about the old assertion and failed the build.
Anchor structural guards to `^\s*` so prose that quotes the banned pattern is
still allowed — a rule you cannot document is a rule people will route around.

## 2026-07-29 - Catalog image accuracy: the tools a class claims must be the tools its image has (`fix/catalog-image-accuracy`)

**The defect.** PR #28 wired capability resolution and pinned
`config/sandbox-classes.json` to a real digest, then marked the catalog reviewed
(`provisional: false`) while pointing **both** approved classes at the same
`squad-worker` image. Between them they claimed `python3`, `pip3`, `jq`, `make`
and `pnpm` that image does not carry. A live end-to-end run routed a Python
repository to `sandbox-python-3-12` exactly as designed - sandbox created,
default-deny egress applied, worker launched detached, branch cloned - and then
the in-worker preflight refused the session for missing `python3`/`pip3`. The
defence in depth worked. The catalog should not have lied in the first place.

**Per class, and why.**

| Class | Decision | Now claims |
| --- | --- | --- |
| `sandbox-node-lts` | **Correct the claim.** Its distinguishing capability over the default worker is NODE_AUTH_TOKEN/NPM_TOKEN plus default-deny egress, not extra binaries. Building an image for `jq`/`make`/`pnpm` would have invented a need. | Re-pinned to `squad-worker:9972cf4` `sha256:266a8c31...`; tools reduced to bash, curl, git, node, npm, sh, yarn. |
| `sandbox-python-3-12` | **Build a real image.** It is the class that proves the routing premise: a repository needing Python must get an image that has Python. | New `squad-worker-python:9972cf4-py312` `sha256:748bcf32...`; keeps python3, pip3, jq, make - all now genuinely present. |
| `sandbox-container-build` | Unchanged, unapproved - the negative fixture. | n/a |

**The image.** `worker/images/python/Dockerfile` extends the published worker so
`entrypoint.sh`, the preflight and `/usr/local/lib/squad-on-aca/*` survive. It is
not `apt-get install python3`: bookworm ships 3.11 and the class id promises
3.12, so it multi-stage-copies CPython 3.12 from `python:3.12-slim-bookworm` -
`libpython3.12.so.1.0`, the stdlib, headers and entry points only, never all of
`/usr/local`, which would clobber the Node toolchain. A build-time smoke test
fails the build if Python 3.12, Node, or any Squad library is missing. Built with
`az acr build` (no local Docker). Live audit inside the pinned digest:
`HAVE az bash curl gh git jq make node npm pip pip3 python python3 sh yarn`,
`MISS pnpm`, `python3 -> Python 3.12.13`.

**The important half: making the claim falsifiable.** A tool list nothing
verifies is the declaration-without-evidence defect this programme keeps
rejecting, so the fix is a check, not a promise.

* `config/image-evidence/<digest-with-':'-as-'-'>.json` records what a digest was
  observed to provide. **The filename is derived from the digest** - that is the
  whole mechanism. Re-pinning changes the file the check looks for, so a re-pin
  without re-verification fails offline.
* `worker/lib/verify-image-evidence.js` (offline, runs in CI) requires, for every
  approved class in a reviewed catalog: evidence exists (**missing is a failure,
  never a skip**), is well formed, records the digest its filename encodes,
  names the pinned image reference, and covers **every** declared tool.
* `scripts/verify-image-tools.ps1` (live, operator-run) boots the pinned digest
  as a real sandbox, probes `command -v` per tool, captures versions, writes the
  evidence.
* Scope: evidence is required only when `provisional` is `false`, mirroring the
  existing digest-pinning rule. A provisional catalog is already report-only.
  That boundary is asserted in the suite so it reads as decided, not overlooked.

**The honest boundary, stated in the docs rather than implied.** CI cannot pull a
private ACR image. CI proves the *bookkeeping* - evidence exists for the digest
pinned today, is well formed, belongs to the pinned repository, covers every
claim. Only a live run proves *image contents*. Neither replaces the in-worker
preflight, which stays the final check; no "catalog says so, skip it" path was
added and none will be.

**Deliberate design split.** `validateCatalog` in `resolve-capability-route.js`
stays pure and filesystem-free: it runs on the dispatch hot path and inside the
worker image, where evidence files are not shipped. The evidence check is a
separate filesystem-aware module that only gates run.

**A routing test changed, and the change is the point.**
`routing-narrowed-egress.yml` required `pnpm`, which the node image does not
have; with the claim corrected it no longer matched any approved class. The
fixture now requires `npm` (which the image genuinely has and which actually
pairs with NPM_TOKEN), and a new assertion pins the corrected behaviour: a
manifest requiring `pnpm` now **fails closed at routing** - one stage earlier,
before a sandbox has been created and paid for - instead of routing to a sandbox
that would refuse it at the preflight. The false claim cannot be restored: the
evidence check rejects it.

**A real leak, found by looking instead of trusting.** `aca sandbox delete`
**prompts** without `--yes`, so the script's unattended cleanup silently left two
probe sandboxes running. Found by listing the group rather than believing the
script's own "deleted" message. Fixed by passing `--yes` and then **re-listing to
confirm** - the script now warns `LEAKED probe sandbox(es) still present` rather
than assuming an exit code means the resource is gone. Verified live on both
classes afterwards; the group lists zero sandboxes.

**Verification.** `validate.ps1` 274 passed / 0 failed / 0 skipped (was 265/0/0).
`verify-cli-golden.ps1` 22/22, `### ACA CALLS` empty in all 22.
`verify-launch-detachment.ps1` PASS. `compare-cli-baseline.ps1 -BaselineRef HEAD`
22/22 byte-identical. Worker suite under WSL: 10 suites, 739 assertions, 0
failed, 0 skipped (was 9 / 690) - new `test_image_evidence.sh` 43, routing
128 -> 134.

**Mutations** - all caught, all reverted, tree clean afterwards:

| Mutation | Check that failed |
| --- | --- |
| over-claim guard removed (`unbacked = []`) | `over-claiming class: exits non-zero`, `... says how many claims are unbacked`, `... names exactly which claims are unbacked`, `... never reports OK`, plus both `--json` assertions (43 run, 6 failed) |
| digest-match guard removed | `copied evidence: exits non-zero when the recorded digest disagrees with the pinned one`, `... reports the disagreement` (43 run, 2 failed) |
| missing evidence treated as a silent skip | `re-pinned class:` x3, `no evidence:` x3, `absent evidence directory: still a failure, not a skip`, `clearing provisional on the same catalog turns it into a failure` (43 run, 8 failed) |
| image-reference guard removed | `foreign repository: exits non-zero when evidence was recorded for another image repository`, `... names the mismatch` (43 run, 2 failed) |
| catalog re-adds `jq` to `sandbox-node-lts` | `validate.ps1` "The shipped catalog claims tools its pinned images were not observed to provide" (273/1) and the offline check: `claims 1 tool(s) the pinned image was not observed to provide: jq` |
| python class re-pinned to an unprobed digest | `no image evidence recorded for the pinned digest (expected .../sha256-0000...json)` |
| evidence file deleted | same missing-evidence failure, naming the file and the command that produces it |
| evidence document records a foreign digest | `records digest sha256:266a8c31..., but the class pins sha256:748bcf32...` |

**Lesson recorded.** A cleanup routine that reports success from an exit code it
never checked against reality is the same defect class as a catalog that claims
tools nobody probed: a declaration with nothing behind it. Both were in this
change; both are now verified rather than asserted.
---

## Sprint 8 — sandbox credential delivery (`fix/sandbox-credential-delivery`)

A live end-to-end run reached the agent invocation and died with
`Error: No authentication information found`. Session state was correct
(`phase=done`, `exit-code=1`), so the detached-and-poll machinery was fine —
`/workspace/<session>/.squad-creds` was simply never created.

**Two defects, not one.**

1. **The dispatcher never fed the mechanism.** `New-SessionExecutionProvider`
   in `scripts/squad-aca.ps1` built the sandbox provider with `Class`, `Config`
   and `ScriptDir` only. `New-SandboxExecutionProvider` defaults
   `WorkerSecrets` to `@{}`, so the staging step became a no-op and the
   launch's `if [ -f ... ]` guard swallowed the absence in silence. A second,
   quieter instance of the same class: `scripts/lib/squad-aca-provider.ps1`
   copies provider options by an explicit NAME LIST, so `BrokeredCredentials`
   was dropped until it was added there too.
2. **The Sprint 7 delivery mechanism could not work against the real
   platform.** `aca sandbox exec` does **not** forward stdin — measured live:
   `"hello" | aca sandbox exec -c 'IFS= read -r X; echo "GOT=[$X]"'` prints
   `GOT=[]`. Every stdin-staging test passed because they all ran the shipping
   *strings* against a local shell, never against `aca`. The replacement is
   `aca sandbox fs write --path <dest> --file <local>`.

**What the platform actually does.** `exec` runs as the unprivileged session
user; `fs write` uploads as **root, mode 0644**, and the session user cannot
`chmod` it. So the containing directory is the only control: the provider
creates the state directory under `umask 077`, has the sandbox report
`stat -c %a`, and **refuses to upload** unless that is exactly `700`. `rm` of
the root-owned file still works, because unlink depends on directory write
permission and the state directory is not sticky — so source-then-remove holds.

**Where tokens come from for a local run.** Git plane: `SQUAD_GITHUB_TOKEN` /
`GH_TOKEN` / `GITHUB_TOKEN`, then `gh auth token`. Copilot plane: only
`SQUAD_COPILOT_GITHUB_TOKEN` / `COPILOT_GITHUB_TOKEN`; otherwise the git token
serves both with a loud note. No token at all is refused **before** the first
`aca` call, so a credential-less run is never billed. Brokerage is
**nomination-based** (`BrokeredCredentials` is separate from `WorkerSecrets`):
"broker whatever is present" would refuse every session whose Copilot token is
the reused git token, and "broker whatever looks brokerable" would silently skip
one the operator meant to broker. The caller states intent.

**A third gap the live run exposed.** With credentials arriving, the agent got
as far as `ProxyResponseError: HTTP 403 … does not appear to originate from
GitHub`. That is not a credential failure — the class egress templates allowed
`*.github.com` only, and the Copilot CLI talks to `api.githubcopilot.com`. A
credential the sandbox cannot use is not delivered, so
`*.githubcopilot.com` and `*.githubusercontent.com` were added to both approved
classes. The next run pushed a branch.

**Live proof.** Session `credproof3`, class `sandbox-python-3-12`:
`exit-code 0`, the Squad agent created, committed and pushed `CREDPROOF.md`
(commit `21bb3aa` on `e2e/sandbox-canary`). In-sandbox afterwards:
`/tmp/squad-session` is `drwx------`, `.squad-creds` is absent, and a
self-match-free `/proc/*/cmdline` sweep reported `ARGVLEAK_COUNT=0`. Every
probe sandbox was deleted with `--yes` and `aca sandbox list` is empty.

**Mutation results** (274 -> 284 checks):

| Mutation | Detected by |
| --- | --- |
| drop `WorkerSecrets` from the sandbox provider options (the original defect) | `A sandbox-routed run staged no credential before launch` |
| drop `BrokeredCredentials` from the option name list | `Credential brokerage is not wired into sandbox create` |
| drop the Copilot plane from `$script:SandboxCredentialPlanes` | five checks, incl. `verify-launch-detachment.ps1` `SEEN3=MISSING` and the launch deny-list |
| both planes share one token | `The Copilot env plane was not staged separately` |
| remove `COPILOT_GITHUB_TOKEN` from `$script:SandboxSecretEnvNames` | `Secret env name(s) accepted into the launch command: COPILOT_GITHUB_TOKEN` |
| `Resolve-SessionSandboxCredential` returns silently instead of throwing | `A credential-less sandbox run was not refused up front` |
| skip `Test-SandboxCredentialToken` for a nominated Copilot credential | `The classic-PAT Copilot case is wrong (acaCalls=1)` |
| accept any vault mode instead of exactly 700 | `The vault-mode guard is wrong` |
| leave the local staging file behind | `local credential staging file(s) survived` |
| upload an empty credential file | `The uploaded credential file content is wrong` |
| put the token in `sandbox exec` argv | ten failures, incl. the argv guard throwing |

**Lessons recorded.**

- A test that runs the shipping *string* in a local shell proves the string is
  correct, not that the transport carries it. Sprint 7's credential mechanism
  passed every such test and delivered nothing. Probe the real platform.
- `git checkout -- <file>` on **uncommitted** work destroys it. Reverting a
  mutation this way cost a full rebuild of two files. Commit first, always.
- A structural option list (`squad-aca-provider.ps1`) silently drops anything
  not named in it. New provider options need an entry there or they vanish.
- cmd's `set /p` cannot split a bare-LF payload; `more > file` can. Relevant
  whenever a Windows stub has to observe a POSIX-shaped stream.
- A stray `#>` inside comment-based help breaks PowerShell parsing far from the
  edit. `[System.Management.Automation.Language.Parser]::ParseFile` locates it.
## Issue #33 sprint 1 — Squad on ACA callable as an agent (`feat/33-s1-agent-core`)

**The seam was under-specified, and the only machine-readable surface was 22
byte-pinned golden captures.** `AgentAbstraction.cs` lived inside the AppHost
and returned `SquadSessionResult(SessionName, Dispatched, Detail)`. A MAF caller
needs more than that: it has to know *where* its work ran (`aca-job` /
`sandbox` / `fail-closed`), get a handle it can poll, and see the sandbox class
and the reason the route deviated. Everything the control plane already knows —
`Resolve-SquadExecutionRoute`, the dispatch decision in
`worker/lib/squad-dispatch.js`, `New-SessionExecutionProvider` — was reachable
only by scraping human text. Scraping it would have made the goldens
load-bearing for a machine contract, so any future wording change becomes a
breaking API change.

**Three schemas, opt-in, strictly additive.** `squad-aca run|status|sessions`
gained a `--json` switch emitting `squad-aca/run@1`, `squad-aca/status@1` and
`squad-aca/sessions@1` with a fixed key order and every key always present.
Under `--json` the pass-through `az` output is *moved* to stderr (`6>&1` plus
`[Console]::Error.WriteLine`), never dropped — PR #9 was closed for swallowing
`az` output and that lesson holds here. No existing invocation changed, so all
22 original captures stayed byte-identical; four new capture cases (23-26)
cover the JSON paths.

**Two nullability decisions are the contract's real content.**
`executionHandle` is `null` for an ACA Job dispatch, because ACA names an
execution asynchronously and the CLI would otherwise have to invent one; hence
`statusPollRef`, which is the handle when there is one and the session id when
there is not, and which is what becomes `SquadSessionResult.Handle`.
`routeReason` is always present, `fallbackReason` only when the route actually
*deviated* — the three ordinary reasons map to `null`, so a caller can test
`fallbackReason != null` to mean "something did not go to plan".

**Fail-closed is a failure, not a quiet success.** `AcaSquadAgent` checks the
route *before* the exit code, specifically so a fail-closed reason survives even
though fail-closed also exits 1. Reversing those two checks is mutation M04 and
the test catches it.

**A defect the repo's own scanner found.** The first test fixtures contained
literal credential-shaped strings, and `validate.ps1` failed six checks. The
temptation was an exception list. Instead `FakeCredentials.cs` assembles the
shapes at runtime from fragments, so nothing credential-shaped is ever on disk
and the scanner keeps its teeth.

**Live proof.** `validate.ps1` 285/0/0 -> 294/0/0. `verify-cli-golden.ps1`
22/22 -> 26/26 with the original 22 byte-identical.
`compare-cli-baseline.ps1 -BaselineRef HEAD` clean.
`verify-launch-detachment.ps1` PASS. `dotnet build aspire/Squad.Aca.sln`
succeeded with 0 warnings under `TreatWarningsAsErrors`. `dotnet test` 47/0.
Worker suite in WSL unchanged at 10 suites / 739 assertions / 0 failed /
0 skipped.

**Mutation results** (54 mutations, 54 killed, 0 survived; every one of the 42
test methods kills at least one mutation):

| Mutation | Detected by |
| --- | --- |
| sandbox route reported as `aca-job` | `SandboxDispatch_CarriesRouteSandboxClassAndHandle` |
| sandbox execution mode reported as `aca-job` | `GetSessionStatus_AddressesTheHandleAndDoesNotReResolveTheRoute` |
| `fail-closed` route no longer recognised | `FailClosedRoute_ThrowsAndDoesNotLookLikeADispatch` |
| exit code checked before route, so the reason is lost | `FailClosedRoute_ThrowsAndDoesNotLookLikeADispatch` |
| fail-closed reason / sandbox class dropped | `FailClosedRoute_ThrowsAndDoesNotLookLikeADispatch` |
| `dispatched:false` treated as success | `NotDispatchedWithoutFailClosed_IsStillAFailure` |
| missing `dispatched` defaults to true | `MissingDispatchedFlag_ThrowsInsteadOfDefaultingToTrue` |
| whitespace-only stdout falls through to the parser | `EmptyOutput_ThrowsContractException` |
| unparseable output classified as dispatch failure | `MalformedJson_ThrowsContractException` |
| `run` / `sessions` stop requesting `--json` | `RunSession_RequestsJsonModeAndPassesRequestFields`, `GetSessionStatus_AddressesTheHandleAndDoesNotReResolveTheRoute` |
| wrong session-name / sub-squad / output-branch flag, `--no-push` inverted | `RunSession_RequestsJsonModeAndPassesRequestFields` |
| status or cancel re-resolves the route by passing `--repo` | `GetSessionStatus_…`, `CancelSession_AddressesTheHandleAndDoesNotReResolveTheRoute` |
| empty `sessions` array yields a half-populated status | `GetSessionStatus_WithNoMatchingSession_FailsLoudly` |
| status drops exit code / phase / route / sandbox class | `GetSessionStatus_ReadsTerminalAcaJobState`, `GetSessionStatus_AddressesTheHandleAndDoesNotReResolveTheRoute` |
| non-zero exit from `run` / `sessions` / `stop` swallowed | `NonZeroExitWithAnOtherwiseValidDocument_IsStillAFailure`, `GetSessionStatus_NonZeroExit_IsSurfaced`, `CancelSession_NonZeroExit_IsSurfaced` |
| empty-output failure message loses the exit code | `NonZeroExitWithNoOutput_IsSurfacedWithItsExitCode` |
| blank / missing `statusPollRef` accepted as pollable | `DispatchedWithABlankPollReference_ThrowsToo` |
| wrong `schema` accepted | `WrongSchema_ThrowsContractException` |
| unknown route silently falls back to `aca-job` | `UnknownRoute_ThrowsInsteadOfSilentlyFallingBack` |
| missing required string substituted with a placeholder | `MissingRequiredField_ThrowsInsteadOfSubstitutingAPlaceholder` |
| status handle echoes the request instead of the substrate's | `GetSessionStatus_ReadsTerminalAcaJobState` |
| empty handle reaches the CLI | `EmptyHandle_IsRejectedBeforeTheCliIsInvoked` |
| returned fallback reason not redacted | `TokenIsNeverPresentInAnyReturnedValue` |
| diagnostic sink receives unredacted stderr | `TokenInControlPlaneStderr_NeverReachesTheDiagnosticSink` |
| exception base constructor stops redacting | `ExceptionMessages_AreRedactedByTheBaseConstructor` |
| each of eight redaction patterns removed individually | `CredentialShapes_AreReplaced`, `AuthorizationHeaders_AreReplaced`, `AssignedSecrets_AreReplaced`, `ExceptionMessages_AreRedactedByTheBaseConstructor` |
| `secretref:` indirection redacted as if it were a secret | `SecretRefIndirection_IsPreserved` |
| redactor rewrites text it should leave alone | 25 checks, incl. `AcaJobDispatch_MapsEveryContractValue` |
| `Redact(null)` returns null instead of empty | `NullAndEmpty_AreSafe` |
| explicit `CliPath` / `SQUAD_ACA_CLI` ignored; stale path returned | `ExplicitCliPath_WinsOverEverythingElse`, `EnvironmentVariable_IsUsedWhenNoExplicitPathIsSet`, `MissingExplicitPath_FallsThroughToTheEnvironmentVariable` |
| upward search looks in the wrong place | `UpwardSearch_FindsScriptsSquadAcaAboveTheStartDirectory` |
| resolution failure no longer names where it looked | `NothingResolves_ThrowsAndNamesEveryPlaceItLooked` |
| a poll-to-completion operation is added to `ISquadAgent` | `ISquadAgent_DoesNotExposePollToCompletion` |

One mutation was found **equivalent** and dropped rather than reported as a
survivor: echoing the raw payload instead of `Summarize(...)` into the
unparseable-JSON message is unobservable, because the exception base
constructor already redacts. That is defence in depth working as intended,
proven by the mutation that removes the base-constructor redaction.

**Lessons recorded.**

- A mutation harness that replaces the *first* textual occurrence will
  silently no-op if the anchor also appears in an XML doc comment, and the
  result is indistinguishable from a surviving mutant. Anchor on code, and
  treat every survivor as "prove the mutation actually landed" first.
- Inserting a member immediately before a documented method orphans that
  method's `<param>` tags onto the new one (CS1572/CS1573). With
  `GenerateDocumentationFile` plus `TreatWarningsAsErrors`, that is a build
  break, not a survivor — anchor above the doc comment.
- `TreatWarningsAsErrors` makes naive mutations (`if (false)`, removing a null
  guard) fail to compile. Runtime-opaque forms — `if (cli.ExitCode >= 0)`,
  `if (!fileExists(x))`, `return text!;` — mutate behaviour without changing
  compilability, and are the only ones that actually test the tests.
- A test that never kills any mutation is decoration. Cross-referencing the
  killer list against the full test list found three such tests here; each got
  a mutation written specifically for it.
- Redaction has to be split: descriptive fields (`SandboxClass`,
  `FallbackReason`, `Status`, `Detail`) are redacted, identity fields
  (`SessionName`, `ExecutionName`, `Handle`) are not, because they must
  round-trip into `sessions --session` and `stop`. Redacting everything would
  have produced handles that address nothing.
- PowerShell `if/else` is not an expression: `-Status (if ($x) {…} else {…})`
  does not parse. Assign to a variable first.
- In a worktree, `.git` is a *file*. `Out-File .git\COMMIT_EDITMSG` fails;
  write the message to a temp file in the repo root instead.

---

## Issue #33 sprint 2 — the Agent Framework adapter (`feat/33-s2-maf-adapter`)

Sprint 1 built `ISquadAgent` and deliberately stopped short of MAF. This sprint
wraps it as an `AIAgent` in a **separate project**, `aspire/Squad.Aca.Agents.MAF`,
which holds the only `Microsoft.Agents.AI` reference in the repository.

**The package is no longer preview.** The isolation was designed against a
preview dependency; `Microsoft.Agents.AI` has since reached GA and shipped
through **1.16.0**, which is what is pinned — exactly, not as a range. The
quarantine stayed anyway. A stable package is not a frozen one, part of the
surface the adapter uses is still `[Experimental]`, and the cost of the
separation is one `.csproj` against the benefit of a framework break that
cannot reach the contract or the control plane.

**MEAI001 is the real preview finding.** `AgentRunOptions.ContinuationToken` and
`AgentResponse.ContinuationToken` are `[Experimental("MEAI001")]` even in the
stable release, which under `TreatWarningsAsErrors` is a hard build error. The
suppression lives in exactly one file, `SquadBackgroundResponse.cs`, never in
the csproj — a project-wide `<NoWarn>` would silently opt every future file into
an unstable API, which is the quarantine failure mode one level down.
`validate.ps1` asserts the csproj does not mention MEAI001 at all.

**The API is not the one the older docs describe.** 1.16.0 uses `AgentSession`
(not `AgentThread`) and `AgentResponse`/`AgentResponseUpdate` (not
`AgentRunResponse`/`...Update`); the abstract members are `CreateSessionCoreAsync`,
`SerializeSessionCoreAsync`, `DeserializeSessionCoreAsync`, `RunCoreAsync`,
`RunCoreStreamingAsync`. This was established by loading the assembly under a
`MetadataLoadContext` and dumping the real surface, because guessing at it from
sample code cost time before that.

### The long-run decision: `RunToCompletion` is the default

MAF's `RunAsync` is request/response; a Squad session runs 10–60 minutes. Both
modes exist and the mode is selectable. The default is the part that matters.

A MAF caller that did not set `AllowBackgroundResponses` is promised a finished
response, and in a workflow that response's text feeds the next node. Returning
a receipt there is not a smaller answer — it is a *wrong* one, and nothing in
the type system objects. The failure is silent: the next node happily summarises
`"Dispatched session squad-1234"` and the pipeline reports success.

Defaulting to fire-and-forget makes the dangerous case the quiet one.
Defaulting to completion makes it loud — a caller who cannot wait 40 minutes
finds out at the first run and switches modes. Fire-and-forget is not worse; it
is only worse **by accident**.

Precedence: `SquadAcaAgentRunOptions.LongRunMode` → `AllowBackgroundResponses ==
true` ⇒ `DispatchOnly` → `SquadAcaAgentOptions.DefaultLongRunMode`. Honouring
MAF's own flag matters: it is how generic code that has never heard of this
adapter still gets receipt-and-poll semantics.

`DispatchOnly` returns the handle on `AgentResponse.ContinuationToken`; passing
it back performs one non-blocking read, and the token is re-attached while
non-terminal and **dropped once terminal**, which is how a caller knows to stop
asking. That reuses MAF's protocol instead of inventing a parallel one.

Polling waits *before* its first read (a session dispatched a millisecond ago is
never terminal), backs off 5 s → ×1.5 → 60 s cap, and clamps the final wait to
the remaining budget so it lands on the deadline rather than past it. `Unknown`
is deliberately **not** terminal — it means "could not tell", which is a reason
to keep asking — and the 90-minute bound is what makes that safe.

### Cancellation stops the session; the token it uses is the whole trick

A cancelled run issues the stop **before** rethrowing, on a **fresh**
`CancellationTokenSource(StopTimeout)`. Forwarding the caller's already-cancelled
token would abort the stop on its first await and leave a billed ACA session
running with nobody watching it. That is the difference between *cancelled* and
*orphaned*, and it is one line apart. `FakeSquadAgent.StopCall.TokenAlreadyCancelled`
exists solely to make that observable; without it, "cancellation stops the
session" passes against an implementation that orphans everything it touches.

Timeout does the same and throws `SquadAgentRunTimeoutException` carrying the
handle — a run that timed out has not necessarily failed, and the caller needs
to be able to go look.

**Fail-closed survives because the adapter does nothing.** `_inner.RunSessionAsync`
is called outside every `try`/`catch`, so `SquadRouteFailedClosedException`
reaches the MAF caller exactly as it left the contract. Verified, not assumed:
MAF's base `RunAsync` does not wrap exceptions.

### Mutation results — 32 designed, 32 killed, 0 survived

The first pass left four survivors and one bad anchor. All four were real gaps:

| survivor | why it survived | fix |
|---|---|---|
| deadline check removed | presented as a **hang**, not a failure — the clamp then hands back a non-positive wait forever | `FakePollingClock` now refuses a non-positive wait (a correct loop never asks for one), plus a test pinning the exact 5+5+2 sequence that ends a 12 s budget |
| first poll forced to zero wait | the test counted the waits without looking at them | assert the interval's value and that no status read preceded it |
| schema check removed from the continuation token | the fixture token had no handle, so the handle check rejected it either way | give the foreign token a handle; assert the message names both schemas |
| `AIAgent` registered as a second instance | stale anchor, mutation never applied | anchor on the comment + call together |

One mutation was **equivalent** and dropped rather than counted: redaction
removed from the timeout *message*. `SquadAgentException` already redacts every
message it is handed, so no test could distinguish it. The redundant call was
deleted and the mutation retargeted at the `LastStatus` **property**, which
nothing else redacts. Same precedent as sprint 1 — delete the unreachable line,
do not pad the count.

### Gates

| gate | before | after |
|---|---|---|
| `validate.ps1` | 294 / 0 / 0 | **303 / 0 / 0** (+9 new checks) |
| CLI goldens | 26/26 byte-identical | 26/26 byte-identical |
| `verify-launch-detachment.ps1` | PASS | PASS |
| worker suite | 10 suites / 739 assertions | 10 suites / 739 assertions |
| .NET tests | 47 | **47 + 67 = 114** |

The nine new checks are: three expected files, two csproj-XML parses, the exact
version pin, the absence of a project-wide MEAI001 suppression, the one-way
dependency (`Squad.Aca.Agents` must not reference the adapter), and **solution
membership**. That last one matters more than it looks: `dotnet build`/`test`
drive the solution, so a project missing from it is a project CI never compiles
and never tests — and the build stays green, because the code was never looked
at.

**CI restore: no finding.** The worry was that a preview package would not
restore under CI's 9.0.x-only SDK. It is not preview, and it restores. Proven by
installing 9.0.316 to a scratch directory and running restore, build and test
against it with no prerelease flag and no extra feed: 114/114 passed. No
conditional project, no feed pin, no visible skip needed.

**Lessons recorded.**

- `git checkout -- <dir>` after `git status` in the *same* command destroyed four
  uncommitted fixes. Sprint 1 recorded this lesson and it still happened. Commit
  before any operation that can discard the working tree — and never put a
  destructive command on the same line as the diagnostic that would have warned
  you.
- A mutation that causes an **infinite loop** is not "survived", it is
  undiagnosed. A harness must distinguish hang from pass, and the better fix is
  to make the fake reject the impossible input so the hang becomes a clean
  failure. `FakePollingClock` refusing a non-positive wait converts an unbounded
  spin — which against a real control plane is a rate limit, not a test problem
  — into an assertion.
- A negative test proves nothing if a *different* guard would reject the input
  anyway. The foreign-token test had a token with no handle, so it passed with
  the schema check deleted. Construct the fixture so the guard under test is the
  only thing standing between the input and success.
- A virtual clock is what makes a 90-minute timeout and a backoff curve testable
  at all. Shrinking the real timeouts until a test can afford to wait proves the
  loop terminates and nothing about whether it waited the right amount, which is
  the only property a rate limit cares about.
- `MetadataLoadContext` is the way to inspect a package whose dependencies are
  not loadable in-process; plain `Assembly.LoadFrom` fails on the first missing
  transitive reference.
- An explicit `PackageReference` that is *lower* than a transitive one is
  `NU1605`, not a pin. Pin at or above what the graph already resolved.

---

## Sprint 3 — issue #33 — live end-to-end (branch `feat/33-s3-live-e2e`)

### What was built

`aspire/Squad.Aca.Agents.MAF.Sample` — a real Microsoft Agent Framework host.
`Host.CreateApplicationBuilder` → `AddSquadAcaAgent()` → resolve the **base
`AIAgent`** → invoke → print route, handle, terminal status, elapsed. Prompt,
repository, ref, mode and timeouts come from arguments or `SQUAD_ACA_SAMPLE_*`
environment variables; there is no inferred repository and no hardcoded prompt.
Added to `Squad.Aca.sln` so CI compiles it.

Resolving `AIAgent` rather than `SquadAcaAIAgent` is deliberate. Resolving the
concrete type would have proved the concrete type works and said nothing about
whether a MAF pipeline that has never heard of Squad can drive it — which is the
entire claim of the adapter.

`--cancel-after-seconds` exists solely to make a genuinely cancelled *live* run
producible. It is the only way the "cancellation stops the session rather than
orphaning it" claim can be checked against something other than a fake, and it
is what found the defect below.

### Gate deltas

| Gate | Before | After |
|---|---|---|
| `validate.ps1` | 303 / 0 / 0 | **307 / 0 / 0** |
| CLI goldens | 26 | 26 |
| `verify-launch-detachment.ps1` | PASS | PASS |
| worker suite | 10 suites / 739 assertions | 10 suites / 739 assertions |
| .NET tests | 114 | 114 |
| `Squad.Aca.Agents` package refs | 0 | 0 |

The +4 is additive and mechanical: two new `$expected` file entries, one
automatic per-`.csproj` XML check (validate.ps1 loops over every csproj under
`aspire/`), and one new assertion that no `Console` write in the sample skips
`SecretRedactor`.

### Live results

Four of five claims held. Full evidence in `docs/e2e-results.md` (S3-1…S3-6).

- **ACA Jobs, run to completion** — route `aca-job`, `Succeeded`, 1 m 19 s.
  `executionHandle` was genuinely null and `statusPollRef` carried the id, as
  documented. First time that preference met a control plane that actually
  returns null rather than a fake told to.
- **Cancellation on Jobs** — client said cancelled; **Azure independently
  reported the execution `Stopped`**. This is the one that mattered and it holds.
- **`fail-closed`** — surfaced as `SquadRouteFailedClosedException` with reason
  `sandbox-feature-disabled-and-default-insufficient`, exit 3, in 8.2 s with no
  execution created. Classified before the exit code, so the reason survived the
  control plane also exiting 1.
- **Sandbox plane** — route `sandbox`, class `sandbox-python-3-12`, `Succeeded`,
  phase `done`, 43.8 s, default-deny egress with exactly the manifest's hosts.
- **Cancellation on the sandbox plane — FAILED.**

### The defect

`squad-sandbox-provider.ps1`'s `cancel` kills the worker with
`pkill -f /usr/local/bin/squad-on-aca >/dev/null 2>&1`. **`procps` is not in the
pinned `sandbox-python-3-12` image**, so `pkill` exits 127; its stderr is
discarded; and because the chain ends in `echo squad-cancelled`, the whole
command exits **0**. The provider reads 0, returns `Cancelled = $true`, and the
caller is told the session stopped.

Measured live: cancel landed at 12:56:02, the worker ran on for another **51
seconds** and completed normally at 12:56:53, overwriting the `143`/`cancelled`
the cancel had written with its own `0`/`done`.

The comment directly above that code says a caller told "cancelled" must never
stop looking at a session that is still running and still billing. The
classification around the call honours that scrupulously. The command being
classified cannot fail.

Not fixed in this sprint: the constraints forbade touching error classification,
and a portable-kill rewrite needs its own offline coverage against an image with
no `procps`. Filed, not patched in passing.

### Lessons

- **A command whose last statement is `echo` cannot report failure.** Every
  guard downstream of that chain was correct and every one of them was fed a
  zero. Exit-status discipline in a shell one-liner is not a style question; it
  is the difference between a cancel and a lie about a cancel.
- **`>/dev/null 2>&1` on the one command that must work is how a 127 becomes
  invisible.** The redirect was there to keep output tidy. It hid the only
  signal that mattered.
- **Fakes agree with you about the environment.** Every offline test asserted
  the cancel *command* was issued. None could assert the binary existed. The
  gap between "we sent the right string" and "the string did anything" is
  exactly the gap a live sprint exists to close, and it stayed open for six
  sprints.
- **A terminal session is not a stopped bill.** Both sandboxes were still
  `Running` after their sessions reported `Succeeded` — by design, since `cancel`
  leaves the sandbox up for logs and teardown is `terminate`'s job. Report the
  group listing, never the delete messages.
- **`aca sandbox delete` needs `--yes`**, and the listing afterwards is the only
  evidence worth anything. Confirmed again this sprint.
- **The client returning "cancelled" is worthless as evidence.** It is the exact
  shape a broken implementation takes. Only `az containerapp job execution list`
  saying `Stopped` — or a file mtime inside the guest — settles it.
- Live control-plane output echoes the subscription GUID (the `az` job-execution
  JSON is relayed verbatim). Redaction at the print site handles tokens; GUIDs
  still have to be redacted by hand when the output goes into `docs/`.

## Issue #32 S1 - the credential must survive the run, not just start it

The token was baked into git config once, at session start; the push is 10 to 60
minutes later. With a PAT that is harmless. A GitHub App installation token has a
measured TTL of exactly 3600 seconds, so it is not.

- **A clone proves nothing about a credential on a PUBLIC repository.** Measured:
  clone with an expired token exits 0, no warning. The push is the first
  operation that actually tests it, and it fails at the LATEST possible moment,
  after the whole run is spent. Any test asserting "the clone worked" would stay
  green with the credential helper deleted.
- **The fix is a git credential helper re-reading a 0600 token FILE**, not a
  config rewrite. Proven end to end: stale token -> push refused -> rewrite ONLY
  the token file -> push succeeds, same working copy, no re-clone, and no
  credential or url config changed.
- **`if ! git push ...; then rc=$?; fi` sets rc to 0, always.** Inside the
  then-branch of a negated condition `True` is the status of the NEGATION, which
  is 0 exactly when the command failed. The caller's `exit "$rc"` therefore
  reported a REFUSED push as a successful session. This is the PR #9 defect,
  reintroduced in new code while the surrounding comment cited PR #9 by name.
  Writing about a trap is not the same as avoiding it.
- **Inline logic in entrypoint.sh is untestable logic.** Nothing under
  worker/tests/ sources entrypoint.sh, which is exactly why the above had no
  coverage. Extracting to worker/lib/ and testing the lib is the convention here
  for a reason; the push now lives in worker/lib/squad-push.sh.
- **A ruleset refusal is exit 1; an expired token is exit 128.** Different
  faults, different remedies. Measured against a real ruleset. Retrying a
  ruleset refusal after a token refresh wastes the retry and misdescribes the
  fault, so only `auth` is retried.
- **ACA Jobs cannot be refreshed mid-session.** `az containerapp job` has no
  `exec`; `job execution` is view-only; `az containerapp exec` targets
  Container Apps. Verified against the CLI. Sandboxes can, via
  `aca sandbox fs write`. There is deliberately NO Jobs refresh test.
- **A test helper that is not executable looks exactly like an auth failure.**
  The credential cases passed for the wrong reason until the helper was copied
  and chmod +x'd the way the Dockerfile does. The `ANONYMOUS` line in the
  fixture's auth log is what exposed it - an exit code alone would not have.

## Issue #32 S2 - Actions as trigger transport, not a second control plane

- **ACA silently ignores a PARTIAL container override.** `job start --env-vars`
  is applied only when name, image, cpu AND memory are all supplied. With a
  partial spec the execution starts, reports success, and runs the TEMPLATE's
  baked-in values - so a session dispatched to work an issue would quietly run
  `SQUAD_MODE=smoke` instead. Ralph already guarded this; the Actions path
  nearly relearned it. Reading an existing dispatcher before writing a new one
  is what caught it.
- **There is no `issue` mode.** Unknown SQUAD_MODE exits 64. Sessions dispatch
  as `prompt`, the mode Ralph uses.
- **A lease prevents a CONCURRENT double dispatch, not a SEQUENTIAL one.** Once
  released, Ralph's five-minute poll finds the issue unlabelled and dispatches
  again. The `squad-aca:dispatched` marker is the other half, and must be
  applied only after a CONFIRMED start or a failed dispatch is never retried.
- **An App token retriggers workflows where GITHUB_TOKEN does not.** The
  built-in token's inability to start new runs is a real safety property that
  disappears the moment an App credential is used. The loop break belongs in the
  resolver, checked before any other branch.
- **A guard nothing can falsify is worse than no guard.** A "skip lines starting
  with >" quote guard was written, then deleted: a line beginning with `>`
  cannot also begin with the command prefix, so removing it changed no outcome
  and no mutation could catch its absence. It was inviting a test that passed
  for a reason unrelated to the code it claimed to cover. The line-start rule is
  what actually makes quoting inert, and mutating THAT fails four assertions.
- **Scope proof needs a negative control.** "The identity can start the job"
  says nothing about whether it can also start every other job. Reading a
  SIBLING job and requiring a refusal is what makes the scoping claim real.
- **The federated path was written but never run.** Zero repository secrets,
  zero workflow runs, zero federated credentials. A workflow file is not
  evidence; a green run is.

## Issue #32 - the green run that did nothing

- **A workflow gated on a field that does not exist reports SUCCESS forever.**
  The claim response carries `outcome`; the workflow tested `.claimed`.
  `jq -r '.claimed // false'` yields "false" for a missing field, so the start
  step was skipped by its own `if:` and the run went green having dispatched
  nothing - while HOLDING a lease for a session that never existed.
- **It survived a live end-to-end test.** Every printed line was correct: the
  event resolved, OIDC succeeded, the lease was really created. Only the absence
  of a new ACA execution exposed it. "The workflow passed" is not evidence that
  the workflow did anything.
- **jq in YAML is logic no test can reach**, exactly like the push logic in
  entrypoint.sh. The lease vocabulary now lives in a tested module.
- **A default of "do nothing" is how this class of defect hides.** An
  unrecognised outcome must be an ERROR, not a polite stand-down.
- **Assert the effect, not just the decision.** The run now fails if the lease
  said start and no execution name exists.
- **The lease store WRITES to the repository**, so a dispatcher needs
  `contents: write`. With `contents: read` the claim fails 403 immediately
  after a successful Azure login, which reads like an Azure fault and is not.

## Issue #32 - ACA --env-vars REPLACES the container environment

- Passing only per-execution overrides drops every secret-backed variable in the
  job template. The session pulls the image, clones the repo, and dies with
  `Error: No authentication information found` - which reads like a Copilot
  problem and is a dispatch problem.
- The failure is LATE and misattributed. Everything up to the clone succeeds.
- Ralph already solved this with `ralph_build_session_env` (merges values and
  `secretref:` entries, 54 assertions). Reusing it beat writing a second
  merger that would drift. Reading the existing dispatcher first has now caught
  three separate traps in this sprint.
- A live green workflow proved the TRIGGER, not the SESSION. Confirming the ACA
  execution exists is necessary but still not sufficient; its exit status is the
  next assertion, and it was Failed.

## Issue #32 - the env builder SKIPS managed keys by design

- `ralph_build_session_env` contains `if (managed.has(e.name)) continue` when
  copying the template: every key in RALPH_MANAGED_ENV_KEYS is deliberately NOT
  inherited, because the caller is expected to supply it. Reusing the function
  without reading its CALL SITE produced a session with no GH_TOKEN at all.
- Reading a shared function is not enough; read how the existing caller uses it.
  Ralph passes `OV_GITHUB_TOKEN=secretref:github-token` and two more explicitly.
- `deploy.ps1` RECREATES the session job, which DELETES any role assignment
  scoped to that job resource. The Actions identity silently lost its grant on
  redeploy and the next run failed with "No subscriptions found" - which reads
  like an OIDC fault and is an RBAC one.
- S1's token preflight earned itself here: it caught the missing credential two
  minutes in, naming the fix, instead of failing at the push after a full run.

## Issue #32 S3 - the interaction surface

- **GitHub attributes a commit ENTIRELY by author email, not by the push token.**
  Measured across three commits pushed with the SAME App installation token:
  only the one authored as `<BOT_USER_ID>+<slug>[bot]@users.noreply.github.com`
  linked. The App ID is NOT the bot user id - using it produces a silently
  unlinked commit that looks fine until you notice there is no avatar.
- Sessions keep a MACHINE author (the work is machine-authored) and credit the
  requester with `Co-authored-by:`. That links correctly and does not
  misrepresent who wrote the code.
- **The status comment must be posted with GITHUB_TOKEN.** Events caused by
  GITHUB_TOKEN cannot start new workflow runs; any other credential retriggers
  this same workflow on its own comment and loops, billing by the minute. Two
  independent guards now: this, and the resolver refusing its own identity.
- **@mention mid-sentence is the most likely accidental trigger.** "I think
  @squad-... could help here" is talking ABOUT the bot, not asking it. The
  line-start rule covers the mention form exactly as it covers the command.
- With no bot login configured the mention form is INERT rather than matching an
  arbitrary "@" prefix - there is no identity to mention.
