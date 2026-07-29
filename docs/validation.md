# Validation guide

This repository is script- and infrastructure-heavy, so validation is a mix of
static checks (run anywhere) and end-to-end (E2E) checks (run against a real ACA
deployment). Use this guide as the per-sprint gate and before any push.

## Quick start

```powershell
# Static validation: PowerShell parse, worker bash -n, secret scan, .NET scaffold
.\scripts\validate.ps1

# Also build the optional .NET/Aspire scaffold
.\scripts\validate.ps1 -RunDotnet
```

`validate.ps1` exits non-zero on any failure, so it is safe to wire into CI or a
pre-push hook.

## What `scripts/validate.ps1` checks

| Check | What it does | Why |
| --- | --- | --- |
| PowerShell parse | Parses every `scripts/*.ps1` (including `scripts/lib/`) with the PowerShell language parser | Catches syntax errors without executing deploy/dispatch logic |
| Worker `bash -n` | Runs `bash -n` on `worker/entrypoint.sh`, `worker/lib/squad-capability-preflight.sh`, and `worker/lib/ralph-dispatch.sh` (CRLF-normalized) | Catches shell syntax errors in the container entrypoint, capability preflight, and Ralph dispatch library |
| Secret scan | Scans tracked `docs/`, `scripts/`, `worker/`, and `aspire/` for token patterns and credential filenames (skips `bin/`, `obj/`, `node_modules/`, and binary files) | Keeps the public repo free of secrets |
| Session-managed env parity | Compares the session-managed env key lists in `scripts/lib/session-env.ps1` and `worker/lib/ralph-dispatch.sh` | Fails on drift so both dispatch paths strip the same keys and session isolation cannot regress |
| Sync guard enumeration | Asserts `Test-SyncSafety` (`scripts/lib/sync-safety.ps1`) uses repository-rooted, byte-safe NUL-delimited `git diff`/`git ls-files` enumeration with ordinal path de-duplication, then runs the real guard against a throwaway repo with nested, ignored, non-ASCII, and newline-parser regression cases | Proves every file `git add -A` would stage is scanned before `--sync-all`, including nested untracked files and quoted/escaped paths, while git-ignored files stay excluded |
| Logs fallback + exit code | Drives `Get-AcaExecutionLog` (`scripts/lib/aca-logs.ps1`) against a fake `az` placed first on `PATH`: extension present, extension absent, extension call failing, Log Analytics query failing, both paths unavailable, and a child-process exit-code assertion. Also re-runs the Log Analytics path under Windows PowerShell 5.1, the host the `squad-aca` shim uses | Regression guard for issue #13: `logs` must never exit 0 after a failed fetch, must never trigger the interactive extension-install prompt, and must fall back to Log Analytics when the `containerapp` extension is unavailable |
| .NET scaffold | Verifies `aspire/` structure and `.csproj` XML; optional `dotnet build` | Ensures the optional integration path stays coherent |
| Execution provider contract | Exercises `scripts/lib/squad-aca-provider.ps1` offline against the filesystem-backed fake provider: create/wait/status/logs/cancel/terminate state transitions, idempotent `terminate` (repeat and after external deletion), double `cancel`, handle opacity, and rejection of unknown, malformed, and foreign-provider handles | Proves the provider seam behaves per PRD #6 with no Azure subscription, so a future Sandboxes provider can be developed and tested offline |
| ACA Job adapter | Drives the **production** adapter (`scripts/lib/providers/squad-aca-job-provider.ps1`) against the fake `az` from `scripts/tests/cli-stub-harness.ps1`: `terminate` on a live execution, on an already-terminal/not-found one, under an auth failure, under RBAC/throttling/network/wrong-subscription/unrecognised failures, and with no `az` on `PATH`; plus `wait` polling `Provisioning -> Running` and timing out on an execution that never becomes ready | The fake provider proves the seam, not the adapter that ships. `terminate` used to return `Terminated = $true` for *every* non-zero `az` exit and label it `AlreadyTerminal`, so an auth failure read as a successful teardown; these checks fail if that returns |
| CLI behaviour regression | Drives `scripts/squad-aca.ps1` in a child process with stub `az`/`gh` binaries on `PATH` (`scripts/tests/cli-stub-harness.ps1`), asserting exit codes, **stdout content**, and the exact `az` call sequence for `sessions`, `logs`, `stop`, `smoke`, and `doctor` | The provider refactor must be observably invisible; this fails if a call site changes what a user sees, including the `stop` pass-through output and exit code when `az` fails |
| CLI golden gate wiring | Asserts every capture case in `scripts/tests/cli-capture-cases.ps1` has a committed golden, that the `stop` golden records `az` stdout, and that `.github/workflows/worker-tests.yml` actually runs `verify-cli-golden.ps1` | A guard that is not automated is not a guard; PR #9's regression class shipped once because the only stdout-comparing tool was a manual one |
| Worker capability tests | Not run by `validate.ps1` (needs `bash`+`node`); run `bash worker/tests/run-tests.sh` directly or via CI | Covers the capability manifest parser, the capability routing decision, preflight contract, Ralph transactional dispatch, and the harness itself |

The capability manifest contract itself is documented in
[capability-manifest.md](capability-manifest.md): manifest schema, built-in
tool/credential allowlists, the advisory-only handling of `services`/`egress`
(required services are rejected at validation), the routing contract and
administrator sandbox class catalog, and the entrypoint fail-closed
behavior when the packaged preflight script is missing.

## Proving the CLI has not changed

Two guards drive the same 22-invocation matrix (`scripts/tests/cli-capture-cases.ps1`)
through the stubbed `az`/`gh` environment. A capture records the exit code,
every recorded `az`/`gh` argv, **stdout**, and stderr — stdout deliberately,
because PR #9 was closed for an observable `stop` output regression and a guard
that only counts `az` calls cannot see one. Neither touches Azure, GitHub, or
the network.

### Golden gate (automated, runs in CI)

```powershell
pwsh -NoProfile -File .\scripts\tests\verify-cli-golden.ps1           # verify
pwsh -NoProfile -File .\scripts\tests\verify-cli-golden.ps1 -Update   # regenerate
```

Captures are compared against files committed under `scripts/tests/golden/cli/`,
the same pattern the worker suite uses for routing decisions. The
`powershell-validation` job in `.github/workflows/worker-tests.yml` runs the
verify form on every push and pull request, so a change to what `squad-aca`
prints fails a job instead of reaching review unnoticed. An **intended** CLI
change is a reviewable diff: regenerate with `-Update`, read the diff, commit it.

Goldens are made machine-portable — temp roots, home directories, PowerShell's
error-record source-line annotation, its caret/source echo (which is truncated to
the host console width), and ANSI SGR colour sequences are folded out — so the
same files verify on a developer box and on a CI runner. Everything observable
(exit codes, `az`/`gh` argv, message text) is compared as-is. Generate and verify
them with **PowerShell 7** (`pwsh`), the host CI uses; Windows PowerShell 5.1
renders error records differently.

### Differential capture (manual, strongest claim)

When a change touches the control plane — particularly the execution provider
seam — also prove the stronger claim against another revision:

```powershell
pwsh -NoProfile -File .\scripts\tests\compare-cli-baseline.ps1 -BaselineRef main
```

It materialises the baseline revision's `scripts/` with `git archive`, drives
both revisions through the same stub environment (`help`, `sessions`, `logs`,
`stop`, `smoke`, `telemetry smoke`, `status`, `doctor`, `run`, `sync`, plus
failure paths), and compares exit code, stdout, stderr, and every recorded
`az`/`gh` argv. It exits non-zero if observable behaviour differs.

This one stays a developer tool rather than a CI gate: it needs a second
revision materialised, and it fails permanently once a CLI change is *intended*.

It reports two counts. The raw count is byte-for-byte. The second ignores the
two things that cannot survive a refactor: PowerShell annotates an uncaught
error with the **source line number** of the `throw`, so any change to a file's
length shifts that annotation, and PowerShell 7 wraps error records in **ANSI
SGR colour sequences**. The exception text, exit code, and call sequences are
still compared unnormalised.

## Worker test harness guarantees

The worker suite is the only executable test coverage in this repository, so the
harness itself is treated as production code and is tested. Run it with:

```bash
bash worker/tests/run-tests.sh
```

### The harness self-test

`worker/tests/test_run_tests.sh` tests `run-tests.sh`. This exists because a
prior runner could not report failure: it captured the suite status inside
`if ! bash "$test_script"`, where `$?` is the *negated* status and is therefore
always `0`. A failing suite left the status at `0`, so the runner printed
"All worker capability tests passed." and exited `0` — a permanently green gate.

The self-test runs the **real** runner against a throwaway directory of
synthetic suites (via the `SQUAD_ACA_TEST_DIR` override, which exists only for
this purpose — with it unset the runner behaves exactly as before and runs the
suites beside itself). It asserts the exit code, banner, and suite counts for
every outcome: failing suite, non-`1` failure code, all passing, mixed
pass/fail, a failure in the middle, skip, skip + failure, all-skipped, an empty
test directory, and default suite discovery. Fixtures live under a self-cleaning
temp root and never appear in a normal run.

The runner also refuses to print the success banner when **no suite actually
executed** — an empty test directory or a run where every suite skipped exits
non-zero, because a run that proved nothing must never read as green.

### Golden decision fixtures

`worker/tests/test_capability_routing.sh` asserts the capability routing
decision byte-for-byte against golden JSON in `worker/tests/expected/`, using
manifests from `worker/tests/fixtures/routing-*.yml`. The resolver emits keys in
a fixed order and sorts/de-duplicates every array specifically so those goldens
are meaningful: a decision that changes for any reason shows up as a readable
diff rather than as a reshuffle.

Regenerate a golden only when the change to the decision is intended, and review
the diff:

```bash
node worker/lib/resolve-capability-route.js <repo-with-manifest> --pretty \
  > worker/tests/expected/<golden>.json
```

Golden files are LF-normalized via `.gitattributes` so they stay byte-stable on
Windows checkouts.

### Declared dependencies and skip semantics

Each suite declares what it needs up front via `worker/tests/lib/deps.sh`:

```bash
source "${TEST_DIR}/lib/deps.sh"
require_deps node git
```

| Suite | Declared dependencies |
| --- | --- |
| `test_capability_routing.sh` | `node` |
| `test_git_checkout.sh` | `git` |
| `test_parse_capabilities.sh` | `node` |
| `test_preflight.sh` | `node` |
| `test_ralph_dispatch.sh` | `node`, `mktemp`, `date` |
| `test_run_tests.sh` | `env`, `find` |

When every dependency is present, `require_deps` is a silent no-op. When one is
genuinely absent the suite prints a visible line and exits `77`:

```text
SKIP: test_parse_capabilities.sh — missing node
```

`run-tests.sh` counts exit `77` as a **skip**, never a pass, and ends the run
with an explicit accounting:

```text
Suites: 2 passed, 0 failed, 3 skipped.
Skipped suites (NOT counted as passes):
  - test_parse_capabilities.sh
```

Nothing is ever downloaded or installed during a test run: a missing runtime is
reported, not silently provisioned. A run that quietly bootstrapped `node` would
no longer be testing the environment it claims to test.

On CI every declared dependency is present, so the `worker-tests` job in
[`.github/workflows/worker-tests.yml`](../.github/workflows/worker-tests.yml)
**fails when any suite reports a skip** — a partial green is treated as a
regression.

### Linux-only constraint (no Git Bash / Cygwin)

The suite must be run on Linux — WSL on a Windows workstation, or the
`ubuntu-latest` runner in CI:

```powershell
wsl -d Ubuntu -e bash -c 'cd /path/to/repo && bash worker/tests/run-tests.sh'
```

It cannot run under Git Bash or Cygwin. `worker/lib/squad-capability-preflight.sh`
hardens its temporary directory handling and refuses to proceed when the temp
path is predictable, which is exactly what the Git Bash/Cygwin `TMPDIR` emulation
produces. That refusal is correct behaviour — the preflight is doing its job —
so the fix is to run the suite on a real Linux environment rather than to weaken
the guard. This is also why `validate.ps1` only runs `bash -n` on the worker
scripts (a syntax check, which Git Bash handles fine) and leaves the behavioural
suite to WSL/CI.

Run it from a **checkout path that contains no digits**. Several redaction
assertions prove the parser never echoes a raw manifest value by asserting that
value's absence from the error output, and those errors legitimately include the
manifest's absolute path. A working copy at, say, `~/sq-s2` puts a `2` in every
error line and trips the "does not echo the raw manifest version" assertion —
a false failure caused by the path, not by the code.

### PowerShell validation in CI

The `powershell-validation` job runs `scripts/validate.ps1` on `windows-latest`.
Every check in that script is offline — none of it touches Azure — so nothing is
gated on credentials. The runner ships pwsh 7 and Git Bash pre-installed, so no
PowerShell runtime is downloaded at test time and the `bash -n` section executes
instead of skipping.

It runs on `windows-latest` rather than `ubuntu-latest` (which also ships pwsh)
because `validate.ps1` resolves repo paths with Windows separators today, so it
cannot execute unmodified under Linux pwsh. Making `validate.ps1` fully
cross-platform is a worthwhile follow-up; it is deliberately out of scope for a
guardrails-only sprint that touches tests, CI, and docs.

## Sprint validation checklist

Run these in order. Static checks first (fast, no Azure), then E2E.

### 1. Static (no Azure required)

- [ ] `.\scripts\validate.ps1` passes.
- [ ] The **Execution provider contract** and **CLI behaviour regression**
      sections of `validate.ps1` report 0 failures. Any change to
      `scripts/squad-aca.ps1` must keep the CLI regression section green — it is
      the guard against a behaviour change slipping in behind the provider seam.
- [ ] If the sprint touched the control plane,
      `.\scripts\tests\compare-cli-baseline.ps1 -BaselineRef main` exits 0 (see
      [Proving the CLI has not changed](#proving-the-cli-has-not-changed)).
- [ ] `bash -n worker/entrypoint.sh` passes (also covered by validate.ps1).
- [ ] `node --check worker/lib/parse-capabilities.js` passes.
- [ ] `node --check worker/lib/resolve-capability-route.js` passes and
      `config/sandbox-classes.json` parses as JSON.
- [ ] `bash worker/tests/run-tests.sh` passes on Linux/WSL (capability parser,
      capability routing, preflight, Ralph dispatch, and the harness self-test)
      with **0 failed and 0 skipped** — see
      [Worker test harness guarantees](#worker-test-harness-guarantees).
- [ ] `git grep` finds no personal subscription IDs, tenant IDs, tokens, or user
      handles in tracked files (see [Secret scans](#secret-scans)).
- [ ] Optional: `.\scripts\validate.ps1 -RunDotnet` builds `aspire/Squad.Aca.sln`.

### 2. E2E (requires an ACA deployment)

Record real command output in [e2e-results.md](e2e-results.md) (static evidence is
already captured there; the live-Azure sections L1–L7 are filled by the
orchestrator/operator against a real deployment).

- [ ] `squad-aca doctor` — validates local repo, GitHub, Azure, ACA, and Aspire
      config.
- [ ] `squad-aca telemetry smoke` (or `SQUAD_MODE=telemetry-smoke`) — emits
      known-good logs/traces/metrics and they appear in the Aspire Dashboard,
      grouped by `squad-<session>`.
- [ ] `scripts/start-session.ps1 -Mode smoke -RunCopilotSmoke` — a session job
      execution starts, clones the repo, and exits cleanly.
- [ ] **Template non-mutation:** the `caj-squad-aca-session` template env is
      identical before and after a dispatch (dispatch uses a per-execution
      `az containerapp job start --env-vars` override, never `job update`). The
      dispatch also echoes the template's image and CPU/memory back on `job start`
      — a read of the immutable template, not a write — because ACA only applies
      the per-execution env override when a complete execution container spec is
      supplied. See [e2e-results.md](e2e-results.md) L3.
- [ ] **Per-execution isolation:** a session that omits `SQUAD_PROMPT` does not
      inherit a previous session's prompt, and still carries the durable common
      env. See [e2e-results.md](e2e-results.md) L4.
- [ ] **Idempotent deploy:** re-running `scripts/deploy.ps1` succeeds and updates
      the existing Aspire app (rotates OTLP key + browser token) instead of
      failing on create. See [e2e-results.md](e2e-results.md) L1.
- [ ] **Watcher registry idempotency:** re-running `scripts/deploy.ps1` against an
      existing `ca-<prefix>-watch` whose ACR changed (new `$loginServer`/ACR name)
      first removes stale registry entries whose server differs from `$loginServer`
      (`az containerapp registry list`/`remove`), then updates the watcher registry
      config via `az containerapp registry set`
      (`--server $loginServer --identity $identityId`) before the image update, so
      the image pull does not fail with `UNAUTHORIZED` and `az containerapp show`
      lists only the current registry. A failed stale-entry removal logs a warning
      but does not fail the deploy. Session/Ralph jobs get the
      same effect automatically: a changed login server changes the full image
      string, so deploy deletes and recreates them with the current
      `--registry-server`/`--registry-identity` (the job update path only runs when
      the login server is unchanged, so its registry config is already correct).
- [ ] A `prompt` session opens a PR on `squad/<session>`.
- [ ] Ralph dispatch: an actionable labeled issue gets the `squad-aca:dispatched`
      label and a session job execution starts, with no shared-template mutation.
      (The `squad:*` namespace is reserved by Squad member-routing workflows, so
      Ralph uses `squad-aca:dispatched` to avoid triggering member assignment.)

## Security validation

These map to the Security review items. Each has a concrete way to verify it.

### OTLP authentication

- **Expected:** Dashboard UI auth = `BrowserToken`, OTLP auth = `ApiKey`. Never
  `Unsecured`.
- **Verify (source):**
  ```powershell
  Select-String -Path scripts\deploy.ps1 -Pattern 'AUTHMODE','BrowserToken','ApiKey','Unsecured'
  ```
  Expect `DASHBOARD__FRONTEND__AUTHMODE=BrowserToken`,
  `DASHBOARD__OTLP__AUTHMODE=ApiKey`, and **no** `Unsecured`.
- **Verify (live):**
  ```powershell
  az containerapp show -n ca-squad-aca-aspire -g <rg> `
    --query "properties.template.containers[0].env[?starts_with(name,'DASHBOARD__')]"
  ```

### OTLP exposure (ports internal only)

- **Expected:** UI port `18888` is external; OTLP `18889`/`18890` are
  internal-only (`external: false`).
- **Verify (source):** in `scripts/deploy.ps1`, the `additionalPortMappings` for
  18889/18890 have `external: false`.
- **Verify (live):**
  ```powershell
  az containerapp show -n ca-squad-aca-aspire -g <rg> `
    --query "properties.configuration.ingress.additionalPortMappings"
  ```
  Both OTLP ports must show `"external": false`.

### RBAC / identity scope

- **Current state (documented risk):** the user-assigned managed identity is
  granted **Contributor** on the resource group so Ralph can start session job
  executions (`Microsoft.App/jobs/start/action`). This is broader than needed.
- **Do not broaden** identity/RBAC further.
- **Future improvement / optional hardening:** replace Contributor with a custom
  role limited to job start + read. Only adopt if it does not break deployment.
  Example custom role definition (review before applying):
  ```jsonc
  {
    "Name": "Squad ACA Job Dispatcher",
    "IsCustom": true,
    "Description": "Start and read ACA jobs for Squad dispatch",
    "Actions": [
      "Microsoft.App/jobs/read",
      "Microsoft.App/jobs/start/action",
      "Microsoft.App/jobs/executions/read"
    ],
    "AssignableScopes": ["/subscriptions/<sub-id>/resourceGroups/<rg>"]
  }
  ```
  Validate a session dispatch still succeeds after swapping the role before
  removing Contributor.

### Secret scans

- **Verify no secrets are committed:**
  ```powershell
  .\scripts\validate.ps1   # includes the docs/scripts/aspire secret scan
  git grep -nIE "gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  ```
  Both should return nothing.
- **Verify ignore rules:** `.azure/`, `.env`, and `deploy.outputs.json` are in
  `.gitignore`:
  ```powershell
  git check-ignore .azure deploy.outputs.json .env
  ```

### Token separation

- **Expected:** GitHub API work and Copilot headless auth can use separate
  tokens (`GITHUB_TOKEN`/`GH_TOKEN` vs `COPILOT_GITHUB_TOKEN`).
- **Verify:** `scripts/deploy.ps1` wires `copilot-github-token` as a distinct
  secret; `worker/entrypoint.sh` prefers `COPILOT_GITHUB_TOKEN` and only falls
  back to `GH_TOKEN` when it is unset.

### Rotation

- **Rotate GitHub/Copilot tokens:**
  ```powershell
  squad-aca secrets rotate --github-token <token> --copilot-token <token>
  ```
- **Rotate OTLP API key / dashboard browser token:** re-run `scripts/deploy.ps1`;
  both are regenerated with `New-HexToken` and re-applied. Re-running is
  **idempotent**: the Aspire app is updated in place via
  `az containerapp update --yaml` (a full create-or-update PUT that rotates the
  secret and browser token and rolls a new revision), not recreated, so rotation
  and recovery no longer fail on an existing app. Confirm old values no longer
  authenticate.

### Public repo sync guard

- **Expected:** `squad-aca sync --sync-all` refuses to stage obvious secret files
  or inline tokens before `git add -A`.
- **Verify:** create a throwaway file and confirm the guard blocks it:
  ```powershell
  Set-Content .env "GITHUB_TOKEN=ghp_<redacted-example-token>"
  squad-aca sync --sync-all   # must fail with a "secret guard" message
  Remove-Item .env
  ```
  The guard blocks at least: `.env`, `deploy.outputs.json`, `.azure`, `*.pfx`,
  `*.pem`, `id_rsa`/`id_ed25519`, `appsettings*.Development.json`, and inline
  token patterns. Intentional override: `SQUAD_ACA_ALLOW_UNSAFE_SYNC=1` (only for
  known-private repos).

### Image pinning

- **Expected:** the worker image pins tool versions rather than floating latest
  for the risky dependencies.
- **Verify:** `worker/Dockerfile` pins the base image (`node:24-bookworm-slim`),
  Copilot CLI (`@github/copilot@1.0.69-2`), and Squad CLI
  (`@bradygaster/squad-cli@0.11.0`).
- **Note:** the Aspire Dashboard image is pulled by tag (`:latest` in
  `scripts/deploy.ps1`, `:9.4` in the optional AppHost). For production, pin the
  dashboard to a specific tag/digest.

## Optional .NET/Aspire scaffold validation

```powershell
cd aspire
dotnet build .\Squad.Aca.sln          # restore + compile
```

If restore is not feasible (offline, restricted feeds, or preview packages are
unavailable), that is expected and acceptable: the scaffold is optional. The
project files and `AppHost.cs` remain valid, reviewable scaffolding, and the
static structure check in `validate.ps1` still passes. Document the restore
failure reason in your sprint notes and keep the scaffold explicit rather than
vendoring preview packages.

## Rollback and recovery

If validation fails after a deploy or config change, or a session/Ralph/watch run
misbehaves, follow [rollback.md](rollback.md). It covers per-component recovery
(optional .NET/Aspire path, ACA worker image/session job, Aspire token/secrets,
Ralph/watch) and, as a last resort, a full resource-group destroy/redeploy. Each
rollback ends with a post-rollback verification checklist that re-runs
`scripts/validate.ps1` and `squad-aca doctor`.

## Known limitations

- E2E telemetry and session checks require a live ACA deployment and Azure
  credentials; they cannot run in a pure static/offline gate.
- `bash -n` requires a `bash` on PATH (Git Bash or WSL on Windows). validate.ps1
  skips it gracefully when bash is absent.
- The behavioural worker suite (`worker/tests/run-tests.sh`) needs a real Linux
  environment; Git Bash and Cygwin cannot run it. See
  [Linux-only constraint](#linux-only-constraint-no-git-bash--cygwin).
- `scripts/validate.ps1` is Windows-only today (it resolves repo paths with
  Windows separators), so the CI PowerShell job runs on `windows-latest`.
- The secret scans are pattern-based and catch common token shapes, not every
  possible secret. They complement, not replace, a dedicated secret-scanning
  tool in CI.
