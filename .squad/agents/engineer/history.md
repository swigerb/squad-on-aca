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
