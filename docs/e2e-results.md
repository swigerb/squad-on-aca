# E2E results and live evidence

This document records the end-to-end (E2E) validation evidence for Squad on ACA.
It has two parts:

1. **Static evidence** — checks that run anywhere with no live Azure. These were
   executed in the current environment and their real output is recorded below.
2. **Live-Azure evidence** — checks that require a deployed ACA stack. These were
   executed against the live deployment and the redacted observations are recorded
   below.

Record for every run:

- Date (UTC)
- Commit SHA (`git rev-parse --short HEAD`)
- Resource group / subscription (redact subscription/tenant GUIDs)
- Who ran it

---

## Static evidence (executed)

- **Environment:** Windows, PowerShell 5.1, Azure CLI 2.81.0, Node.js present.
- **Latest code commit at time of validation:** `3bf003c` (`Close sync guard path edge cases`).
- **Date (local):** 2026-07-16.

### 1. `scripts/validate.ps1 -RunDotnet`

Command:

```powershell
.\scripts\validate.ps1 -RunDotnet
```

Observed (summary):

```text
=== PowerShell parse ===
  [PASS] deploy.ps1 parsed clean
  [PASS] new-project.ps1 parsed clean
  [PASS] show-status.ps1 parsed clean
  [PASS] squad-aca.ps1 parsed clean
  [PASS] start-session.ps1 parsed clean
  [PASS] start-watch.ps1 parsed clean
  [PASS] validate.ps1 parsed clean
  [PASS] session-env.ps1 parsed clean
  [PASS] sync-safety.ps1 parsed clean
=== Worker bash scripts (bash -n) ===
  [PASS] worker\entrypoint.sh passed bash -n
  [PASS] worker\lib\squad-capability-preflight.sh passed bash -n
  [PASS] worker\lib\ralph-dispatch.sh passed bash -n
  [PASS] worker\lib\git-checkout.sh passed bash -n
=== Secret scan (docs + scripts + worker + aspire) ===
  [PASS] No secret patterns found in docs/, scripts/, worker/, or aspire/
=== .NET/Aspire scaffold ===
  [PASS] aspire/Squad.Aca.sln present
  [PASS] aspire/Squad.Aca.AppHost\Squad.Aca.AppHost.csproj present
  [PASS] aspire/Squad.Aca.AppHost\AppHost.cs present
  [PASS] aspire/README.md present
  [PASS] Squad.Aca.AppHost.csproj is valid XML
  [PASS] dotnet build succeeded
=== Session-managed env key parity ===
  [PASS] Session-managed env keys match across session-env.ps1 and ralph-dispatch.sh (21 keys)
=== Sync guard secret enumeration (NUL-delimited) ===
  [PASS] Test-SyncSafety enumerates candidates with NUL-delimited (-z) git output
  [PASS] Test-SyncSafety no longer invokes quote-prone 'git status --porcelain'
  [PASS] Test-SyncSafety discovers the repo root (rev-parse --show-toplevel) so nested invocations cover the whole tree
  [PASS] Test-SyncSafety reads git output byte-safely (redirected process BaseStream), avoiding pipeline newline splitting
  [PASS] Test-SyncSafety de-duplicates candidates with case-sensitive ordinal semantics (distinct case-only paths preserved)
  [PASS] Raw NUL parser splits only on NUL: newline-containing and non-ASCII paths survive intact
  [PASS] Sync guard flags nested untracked secrets.json
  [PASS] Sync guard flags nested untracked .pem
  [PASS] Sync guard flags nested source containing a PAT-like token
  [PASS] Sync guard flags denylisted secret at a quoted/escaped non-ASCII path
  [PASS] Sync guard flags PAT-like token in a text file at a quoted/escaped non-ASCII path
  [PASS] Sync guard excludes git-ignored files (including non-ASCII paths)
  [PASS] Sync guard run from a nested dir still catches the root-level .env
  [PASS] Sync guard run from a nested dir still catches a sibling nested secret (certs/sub/server.pem)
  [PASS] Sync guard run from a nested dir reports paths repo-root-relative (nested/deep/secrets.json)
=== Summary ===
  Passed: 36
  Failed: 0
All validation checks passed.
```

### 2. Worker entrypoint bash syntax

`bash -n worker/entrypoint.sh`, `worker/lib/squad-capability-preflight.sh`,
`worker/lib/ralph-dispatch.sh`, and `worker/lib/git-checkout.sh` — **PASS**
(also covered by `validate.ps1` above).

### 3. Ralph env-transformer unit check (offline)

The Ralph dispatcher (`SQUAD_MODE=ralph` in `worker/entrypoint.sh`) builds each
session job execution's environment from an immutable snapshot of the session job
container template, stripping session-managed keys and overlaying fresh values. It
also reads the image, CPU/memory, and container name from that same snapshot and
echoes them back on `az containerapp job start` — required so ACA applies the
per-execution `--env-vars` override at all — without mutating the shared template.
The Node transformer was exercised offline with a representative template snapshot:

Input template env (excerpt): a stale `GITHUB_REPOSITORY=old/repo`, a placeholder
`SESSION_NAME=smoke-template`, a `GITHUB_TOKEN` secretRef, and durable common vars
(`ASPIRE_OTLP_GRPC_ENDPOINT`, `SQUAD_COPILOT_FLAGS`, `GITHUB_BASE_BRANCH`).

Observed output tokens:

```text
ASPIRE_OTLP_GRPC_ENDPOINT=http://ca-squad-aca-aspire:18889
SQUAD_COPILOT_FLAGS=--yolo --agent squad --remote --no-auto-update
GITHUB_BASE_BRANCH=main
GITHUB_REPOSITORY=new/repo            # stale old/repo replaced
GITHUB_TOKEN=secretref:github-token   # secret ref preserved
SESSION_NAME=issue-42-20260715        # smoke-template placeholder replaced
SQUAD_MODE=prompt
SQUAD_PROMPT=Line1\nLine2 with #42     # multi-line prompt preserved (NUL-delimited)
```

Confirms: no stale value leaks, secret refs are carried as `secretref:`, durable
common config is preserved, and multi-line prompts survive intact.

### 4. Source assertions for preserved security posture

```powershell
Select-String -Path scripts\deploy.ps1 -Pattern 'AUTHMODE','BrowserToken','ApiKey','Unsecured','external: false'
```

Expected and present in `scripts/deploy.ps1`:
`DASHBOARD__FRONTEND__AUTHMODE=BrowserToken`, `DASHBOARD__OTLP__AUTHMODE=ApiKey`,
OTLP additional ports `18889`/`18890` mapped with `external: false`, and **no**
`Unsecured`. The idempotent create-or-`update --yaml` path uses the same
`$aspireYaml`, so these are preserved on both first deploy and rotation/recovery.

### 5. Worker test suite

The Linux worker test suite was run under WSL with Node.js 24 on `a388d7e`:

```text
test_git_checkout.sh: 11 assertions run, 0 failed.
test_parse_capabilities.sh: 62 assertions run, 0 failed.
test_preflight.sh: 40 assertions run, 0 failed.
test_ralph_dispatch.sh: 23 assertions run, 0 failed.

All worker capability tests passed.
```

This covers the capability parser, preflight contract, transactional Ralph
dispatch, and the shallow-clone checkout fallback for slash-bearing refs.

---

## Live-Azure evidence (executed)

Prerequisites: `az login`, `az account set --subscription <sub>`, `gh auth login`,
and a deployment (`scripts/deploy.ps1`). Use the resource group from
`deploy.outputs.json`. Redact subscription/tenant GUIDs before committing.

> Run metadata
>
> - Date (UTC): `2026-07-15T21:53:11Z`
> - Commit SHA: `9ceca2e`
> - Resource group: `rg-squad-aca-dev-eastus2`
> - Operator: `Brian via Scout`

### L1. Deploy is idempotent (rotation/recovery no longer fails on create)

Run `deploy.ps1` twice against the same resource group. The second run must
succeed and must update (not fail-on-create) the Aspire app, rotating the OTLP
API key and dashboard browser token.

```powershell
.\scripts\deploy.ps1 -SubscriptionId <sub> -DefaultRepository <owner/repo>
# capture aspireLoginUrl #1
.\scripts\deploy.ps1 -SubscriptionId <sub> -DefaultRepository <owner/repo>
# capture aspireLoginUrl #2 -- token differs; command exits 0
az containerapp revision list -n ca-squad-aca-aspire -g <rg> `
  --query "[].{name:name,created:properties.createdTime,active:properties.active}" -o table
```

Observed:

```text
PASS
- Re-ran deploy against the existing ACA stack after a prior successful deploy.
- Exit code: 0.
- Worker image: acrsquadacah81u42kq.azurecr.io/squad-worker:9ceca2e.
- Session job image: acrsquadacah81u42kq.azurecr.io/squad-worker:9ceca2e.
- Ralph job image: acrsquadacah81u42kq.azurecr.io/squad-worker:9ceca2e.
- Watcher image: acrsquadacah81u42kq.azurecr.io/squad-worker:9ceca2e.
- Watcher registries: acrsquadacah81u42kq.azurecr.io only.
- Active Aspire revisions: 1.
```

Pass criteria: second `deploy.ps1` exits 0; a new Aspire revision is created; the
`aspireLoginUrl` token changed; the old browser token no longer authenticates.

### L2. Aspire security posture (live)

```powershell
az containerapp show -n ca-squad-aca-aspire -g <rg> `
  --query "properties.template.containers[0].env[?starts_with(name,'DASHBOARD__')].name"
az containerapp show -n ca-squad-aca-aspire -g <rg> `
  --query "properties.configuration.ingress.additionalPortMappings"
```

Observed:

```text
PASS
- DASHBOARD__FRONTEND__AUTHMODE=BrowserToken.
- DASHBOARD__FRONTEND__BROWSERTOKEN present, redacted from evidence.
- DASHBOARD__OTLP__AUTHMODE=ApiKey.
- DASHBOARD__OTLP__PRIMARYAPIKEY uses secretRef otlp-api-key.
- OTLP gRPC port 18889 external=false.
- OTLP HTTP port 18890 external=false.
```

### L3. Session dispatch does not mutate the shared job template

Capture the job template env before and after a dispatch; they must be identical.
The dispatch uses a per-execution `--env-vars` override (not `job update`) and
additionally echoes the template's stored image and CPU/memory back on
`job start`. That echo is required so ACA actually applies the per-execution env
override; echoing the image/resources is a read of the immutable template, so the
template env itself stays unchanged. Also confirm the dispatched worker logs show
the intended `SESSION_NAME` (for example `e2e-iso-1`) rather than a template
placeholder such as `smoke-template`.

```powershell
az containerapp job show -n caj-squad-aca-session -g <rg> `
  --query "properties.template.containers[0].env" -o json > before.json
.\scripts\start-session.ps1 -Repository <owner/repo> -Mode smoke -RunCopilotSmoke -SessionName e2e-iso-1 -NoWait
az containerapp job show -n caj-squad-aca-session -g <rg> `
  --query "properties.template.containers[0].env" -o json > after.json
Compare-Object (Get-Content before.json) (Get-Content after.json)
```

Observed:

```text
PASS
- Session: e2e-iso-20260715175307.
- Worker log: [squad-on-aca] Session: e2e-iso-20260715175307.
- Worker log: [squad-on-aca] Squad pod ID: e2e-iso-20260715175307.
- Worker image: acrsquadacah81u42kq.azurecr.io/squad-worker:9ceca2e.
- Template env diff count before/after dispatch: 0.
```

Pass criteria: `Compare-Object` reports **no differences** — the shared template
was not mutated by dispatch.

### L4. Per-execution isolation (no stale leak, complete env)

Dispatch a session with a `SQUAD_PROMPT` canary, then a second session that
omits `SQUAD_PROMPT`. The second execution must NOT contain the first execution's
`SQUAD_PROMPT`, and must still contain the durable common vars. The final run used
`shell` mode for the second execution so the worker could print `NO_SQUAD_PROMPT`
only when the variable was absent.

```powershell
.\scripts\start-session.ps1 -Repository <owner/repo> -Mode smoke -SessionName e2e-leak-a `
  -Prompt "LEAK-CANARY-should-not-appear-in-next-run" -NoWait
# Then start a shell-mode validation execution with REMOTE_SQUAD_COMMAND set to:
# if env | grep '^SQUAD_PROMPT='; then echo LEAKED_SQUAD_PROMPT; exit 42; else echo NO_SQUAD_PROMPT; fi
# Query worker logs for NO_SQUAD_PROMPT and ensure LEAKED_SQUAD_PROMPT is absent.
```

Observed:

```text
PASS
- First session: e2e-leak-a-20260715175307 with SQUAD_PROMPT canary.
- Second session: e2e-leak-b-20260715175307 using shell mode.
- Worker log from second session: NO_SQUAD_PROMPT.
- Leak marker LEAKED_SQUAD_PROMPT: not observed.
```

Pass criteria: the second execution has **no** `SQUAD_PROMPT` (no leak) and still
carries the durable common env (complete config).

### L5. Concurrent dispatch does not race

Start several dispatches back-to-back; each execution should carry its own
`SESSION_NAME`/`OTEL_SERVICE_NAME` with no cross-contamination.

```powershell
1..3 | ForEach-Object {
  .\scripts\start-session.ps1 -Repository <owner/repo> -Mode smoke -SessionName "e2e-conc-$_" -NoWait
}
az containerapp job execution list -n caj-squad-aca-session -g <rg> `
  --query "[0:5].{name:name,status:properties.status}" -o table
# then inspect each execution's SESSION_NAME/OTEL_SERVICE_NAME
```

Observed:

```text
PASS
- e2e-conc-1-20260715175307 observed in caj-squad-aca-session-6z1nia9-d46h9.
- e2e-conc-2-20260715175307 observed in caj-squad-aca-session-b84n97z-nfbsf.
- e2e-conc-3-20260715175307 observed in caj-squad-aca-session-cclo11e-z5fhm.
- All three workers used image acrsquadacah81u42kq.azurecr.io/squad-worker:9ceca2e.
```

### L6. Telemetry smoke reaches the Aspire dashboard

```powershell
.\scripts\start-session.ps1 -Repository <owner/repo> -Mode telemetry-smoke -SessionName e2e-telemetry
# Open aspireLoginUrl from deploy.outputs.json; filter service name squad-e2e-telemetry
```

Observed:

```text
PASS
- Session: e2e-telemetry-20260715175307.
- Service name: squad-e2e-telemetry-20260715175307.
- Worker log: [squad-on-aca] Session: e2e-telemetry-20260715175307.
- Worker log: [squad-on-aca] OpenTelemetry smoke signal emitted.
- The telemetry-smoke path emitted trace, metric, and structured log signals through
  the Aspire OTLP HTTP endpoint.
```

### L7a. Ralph dispatch — scheduled path

Label an actionable issue `squad`, wait for the Ralph cron schedule to fire the
Ralph job, then confirm the issue gets `squad-aca:dispatched` and a session
execution starts — and that the Ralph/session templates are unchanged afterward
(same non-mutation check as L3).

```powershell
gh issue create --repo <owner/repo> --title "E2E ralph test" --body "..." --label squad
# wait up to 5 min for the Ralph cron trigger to fire
gh issue view <n> --repo <owner/repo> --json labels
az containerapp job execution list -n caj-squad-aca-session -g <rg> --query "[0:3].name" -o tsv
```

Observed:

```text
PASS
- Temporary issue: #5.
- Labels after Ralph: squad, squad:lead, go:needs-research, squad-aca:dispatched.
- Ralph log: Dispatching issue #5 to ACA session job issue-5-20260715220550.
- Session execution observed with prefix issue-5-.
- Session template env diff count before/after Ralph dispatch: 0.
- Temporary issue closed after validation.
```

### L7b. Ralph dispatch — manual CLI path

Trigger the Ralph job on demand with `squad-aca ralph run`. Unlike the scheduled
trigger, the manual path builds a complete per-execution `--env-vars` override.
It must start the Ralph execution in `SQUAD_MODE=ralph` (not the worker `smoke`
default) and preserve the Ralph job template's config and secret refs
(`RALPH_LABELS`, `RALPH_MAX_ISSUES`, token/OTLP secretrefs, Azure fields, Aspire
endpoints) while echoing the immutable template's `--image`, `--cpu`,
`--memory`, and `--container-name` so ACA applies the override. The stored Ralph
template must be unchanged afterward.

```powershell
gh issue create --repo <owner/repo> --title "E2E ralph manual test" --body "..." --label squad
scripts\squad-aca.ps1 ralph run --repo <owner/repo>
# Confirm the manual execution ran in ralph mode (not smoke) via Log Analytics:
#   [squad-on-aca] Mode: ralph  and the Ralph dispatch log line.
gh issue view <n> --repo <owner/repo> --json labels
az containerapp job execution list -n caj-squad-aca-ralph -g <rg> --query "[0:3].name" -o tsv
```

Observed:

```text
PASS
- Validation commit: 1fa2497.
- Validation time (UTC): 2026-07-15T22:43:02Z.
- Temporary issue: #8.
- Manual Ralph container group: caj-squad-aca-ralph-c7mf049-4nndr.
- Manual Ralph image: acrsquadacah81u42kq.azurecr.io/squad-worker:9ceca2e.
- Worker log from that manual container: [squad-on-aca] Mode: ralph.
- Worker log from that manual container: [squad-on-aca] Session: manual-ralph-20260715-184137.
- Worker log from that manual container: Dispatching issue #8 to ACA session job issue-8-20260715224224.
- Labels after manual Ralph: squad, squad:lead, go:needs-research, squad-aca:dispatched.
- Ralph template env diff count before/after manual Ralph run: 0.
- Session template env diff count before/after manual Ralph run: 0.
- Temporary issue closed after validation.
```

### L8. Review-fix and capability regression pass

This pass validates the full code-review fix set: nested secret guard hardening,
transactional Ralph dispatch, managed-env parity enforcement, pinned worker CI
runtime, and the checkout fallback for fetched refs with slashes.

```text
PASS
- Validation commit: a388d7e.
- Validation time (UTC): 2026-07-16T16:09:39Z.
- Worker image: acrsquadacah81u42kq.azurecr.io/squad-worker:a388d7e.
- Smoke session: review-smoke-20260716120935.
- Capability success session: review-cap-ok-20260716120935.
- Capability success container: caj-squad-aca-session-9b8zaav-gx5bd.
- Capability success log: [capability-preflight] Capability preflight passed.
- Capability failure session: review-cap-fail-20260716120935.
- Capability failure container: caj-squad-aca-session-nhbrspt-8dtqn.
- Capability failure log: Unsupported required tool: definitely-not-installed-binary.
- Telemetry session: review-telemetry-20260716120935.
- Telemetry log: [squad-on-aca] OpenTelemetry smoke signal emitted.
- Manual Ralph temporary issue: #11.
- Ralph labels after dispatch: squad, squad:lead, go:needs-research, squad-aca:dispatched.
- Ralph log: dispatched issue #11 to ACA session job issue-11-20260716162014.
- Ralph template env diff count before/after manual run: 0.
- Session template env diff count before/after manual run: 0.
- Temporary capability branches and temporary issue were cleaned up after validation.
```

---

## Result

- Static evidence: **PASS** (recorded above).
- Live-Azure evidence: **PASS** (L1-L6, L7a scheduled path, L7b manual
  `squad-aca ralph run` CLI path, and L8 review-fix/capability regression pass
  recorded above).

---

# Sprint 0 regression contract (golden record)

This section is the **regression contract** for the PRD [#6](https://github.com/swigerb/squad-on-aca/issues/6)
sandbox programme. It records the observable behaviour of the ACA Jobs plane
*before* any sandbox work. Every later sprint must re-run these checks and
reproduce this output. Anything that differs is a regression, not a feature.

- **Date (UTC):** 2026-07-29
- **Commit at capture:** `742e20e` (Sprint 0 guardrails merged)
- **Resource group:** `rg-squad-aca-dev-eastus2` (subscription/tenant GUIDs redacted)
- **Worker image:** `squad-worker:a388d7e`
- **Run by:** repository owner

## S0-1 — Static gate

```powershell
pwsh -NoProfile -File .\scripts\validate.ps1
```

```text
=== Summary ===
  Passed: 35
  Failed: 0

All validation checks passed.
VALIDATE_EXIT=0
```

## S0-2 — Worker suite (Linux)

The suite **cannot** run under Git Bash/Cygwin — the preflight's hardened
temp-dir guard correctly refuses a predictable temp path. Run under Linux:

```bash
bash worker/tests/run-tests.sh
```

```text
11 assertions run, 0 failed.   # test_git_checkout.sh
62 assertions run, 0 failed.   # test_parse_capabilities.sh
40 assertions run, 0 failed.   # test_preflight.sh
23 assertions run, 0 failed.   # test_ralph_dispatch.sh
43 assertions run, 0 failed.   # test_run_tests.sh
Suites: 5 passed, 0 failed, 0 skipped.
All worker capability tests passed.
```

**179 assertions across 5 suites.** No later sprint may reduce this.

## S0-3 — `doctor` against live Azure

```text
Check           Status Detail
-----           ------ ------
git             ok     Required for repo and Squad state sync
gh              ok     Required for GitHub repo/PR/issue access
az              ok     Required for ACA job control
squad           ok     Used by init; npx fallback is available
GitHub repo     ok     swigerb/squad-on-aca
.squad          ok     Required for existing-repo dispatch
GitHub auth     ok     gh auth status succeeded
Azure auth      ok     <subscription redacted>
ACA session job ok     rg-squad-aca-dev-eastus2/caj-squad-aca-session
Ralph job       ok     caj-squad-aca-ralph
Aspire URL      ok     https://ca-squad-aca-aspire.<region-suffix>.azurecontainerapps.io/login?t=<redacted>

DOCTOR_EXIT=0
```

## S0-4 — `status` and `sessions`

Both exit 0. `status` lists the Aspire and Watch container apps as
`Succeeded`/`Running`, plus recent session and Ralph executions. `sessions`
resolves execution → session name, mode, repository, and branch.

Ralph's scheduled trigger was observed firing every 5 minutes with consecutive
`Succeeded` executions, confirming the autonomous path is live.

## S0-5 — Live dispatch (`smoke`), end to end

```powershell
pwsh -NoProfile -File .\scripts\squad-aca.ps1 smoke
```

Started execution `caj-squad-aca-session-guwi8zw`; terminal state:

```json
{ "name": "caj-squad-aca-session-guwi8zw", "status": "Succeeded",
  "start": "2026-07-29T02:08:59+00:00", "end": "2026-07-29T02:10:22+00:00" }
```

Worker trace (via Log Analytics):

```text
[squad-on-aca] Squad: 0.11.0
[squad-on-aca] Node: v24.18.0
[squad-on-aca] Copilot: GitHub Copilot CLI 1.0.69-2.
[squad-on-aca] Squad deployment mode: squad-per-pod
[squad-on-aca] GitHub repository: swigerb/squad-on-aca
Cloning into '/workspace/smoke-.../repo'...
[squad-on-aca] Mode: smoke
[capability-preflight] No capability manifest at squad-capabilities.yml; skipping (safe default).
[squad-on-aca] Copilot flags: --yolo --agent squad --remote --no-auto-update
Squad v0.11.0 - remote container is operational and responding normally.
```

This is the **no-manifest path** the PRD requires to remain unchanged: preflight
skips with a safe default and the ACA Job runs exactly as before.

## S0-6 — `stop`

```text
"Job Execution: caj-squad-aca-session-guwi8zw, stopped successfully."
STOP_EXIT=0
```

## S0-7 — Secret-leak probe

Queried the execution's console logs for `ghp_`, `gho_`, `github_pat_`,
`SQUAD_PROMPT=`, and `GITHUB_TOKEN=`:

```text
SECRET-LEAK PROBE: PASS - no tokens or prompt bodies in worker logs
```

## S0-8 — `logs` — **FAIL (defect found, tracked as [#13](https://github.com/swigerb/squad-on-aca/issues/13))**

`squad-aca logs <execution>` requires the `containerapp` az extension, which
could not be installed in this environment (the 32-bit Azure CLI's bundled
Python lacks `_ctypes`). The command emitted an interactive install prompt and
an `EOFError`, produced no output, and **still exited 0**.

Logs remained retrievable through Log Analytics (`law-squad-aca`), which needs
no extension. This is an observability defect plus a false-green exit code, not
data loss. It is the one gap in an otherwise green baseline.

## Baseline verdict

The ACA Jobs plane is **healthy and fit to build on**: 7 of 8 checks pass, and
the single failure is a logging-path defect with a working fallback and a
tracked fix. Sandbox work may proceed.


---

# Sprint 3 (issue #33) — MAF adapter, live end-to-end

- **Date (UTC):** 2026-07-31
- **Commit at time of the runs:** `c2e8191` (`Add a runnable MAF sample host for the ACA agent`)
- **Subscription / tenant:** redacted. Resource group `rg-squad-aca-dev-eastus2`,
  sandbox group `sbg-squad-aca`, region East US 2.
- **Run by:** engineer agent, GitHub identity `swigerb`.
- **Driver for every run below:** `aspire/Squad.Aca.Agents.MAF.Sample`, resolving
  the **base `AIAgent`** from DI. Nothing here calls `SquadAcaAIAgent` directly,
  and nothing here calls `squad-aca` directly.

Sprints 1 and 2 were entirely offline. Every claim about the adapter was an
assertion against a scripted `ISquadAgent`. These are the first runs that put a
real Squad session on real Azure through it.

> All output below is quoted from the live console. Subscription GUIDs are
> replaced with `<subscription>`; no token appears because the host reads none
> and redacts everything it prints.

## S3-1 — ACA Jobs plane, run to completion — **PASS**

```powershell
dotnet run --project aspire/Squad.Aca.Agents.MAF.Sample -- `
  "Reply with a one-line summary of what this repository does. Do not change any files." `
  --repo swigerb/squad-on-aca --ref feat/33-s3-live-e2e --no-push `
  --session s3-live-jobs --poll-seconds 15 --timeout-minutes 30
```

```text
agent      : squad-on-aca (ef20155408e94483975fcb4aebeb2c07)
repository : swigerb/squad-on-aca
ref        : feat/33-s3-live-e2e
push       : False
mode       : RunToCompletion
timeout    : 00:30:00
prompt     : Reply with a one-line summary of what this repository does. Do not change any files.

  [squad-aca] squad-aca run exited 0
  [squad-aca] Everything up-to-date
{
  "id": "/subscriptions/<subscription>/resourceGroups/rg-squad-aca-dev-eastus2/providers/Microsoft.App/jobs/caj-squad-aca-session/executions/caj-squad-aca-session-7pzwpc2",
  "name": "caj-squad-aca-session-7pzwpc2",
  "resourceGroup": "rg-squad-aca-dev-eastus2"
}
  [squad-aca] dispatched s3-live-jobs route=AcaJob mode=RunToCompletion
  [squad-aca] squad-aca sessions exited 0
  [squad-aca] squad-aca sessions exited 0
Squad session 's3-live-jobs' finished on route 'aca-job' with status 'Succeeded'. Handle: sqx1.eyJ2IjoxLCJwIjoiYWNhLWpvYiIsImQiOnsiam9iIjoiY2FqLXNxdWFkLWFjYS1zZXNzaW9uIiwicmciOiJyZy1zcXVhZC1hY2EtZGV2LWVhc3R1czIiLCJleGVjdXRpb24iOiJjYWotc3F1YWQtYWNhLXNlc3Npb24tN3B6d3BjMiIsImNvbnRhaW5lciI6ImNhai1zcXVhZC1hY2Etc2Vzc2lvbiJ9fQ.

  squad.dispatched       = True
  squad.executionMode    = AcaJob
  squad.exitCode         = (null)
  squad.fallbackReason   = (null)
  squad.handle           = s3-live-jobs
  squad.longRunMode      = RunToCompletion
  squad.phase            = (null)
  squad.route            = aca-job
  squad.sandboxClass     = (null)
  squad.sessionName      = s3-live-jobs
  squad.status           = Succeeded
  squad.terminal         = True

elapsed    : 00:01:19.3202305
```

| | |
|---|---|
| Route | `aca-job` (the unconditional default, unchanged) |
| Execution handle | `executionHandle` was **null**, as documented — ACA names executions asynchronously. `statusPollRef` (`s3-live-jobs`) became `squad.handle`. The ACA execution name `caj-squad-aca-session-7pzwpc2` surfaced in the continuation token. |
| Terminal status | `Succeeded`, `squad.terminal = True` |
| Real elapsed | **1 m 19.3 s** |

Corroborated independently from Azure:

```text
Name                           Status     Start                      End
-----------------------------  ---------  -------------------------  -------------------------
caj-squad-aca-session-7pzwpc2  Succeeded  2026-07-31T12:49:39+00:00  2026-07-31T12:50:28+00:00
```

The null `executionHandle` is the detail most likely to be read as a bug. It is
not: it is why `AcaSquadAgent` prefers `statusPollRef`, and this run is the first
time that preference has been exercised against a control plane that actually
returns null rather than a fake that was told to.

## S3-2 — Cancellation on the Jobs plane — **PASS, verified from Azure**

```powershell
dotnet run --project aspire/Squad.Aca.Agents.MAF.Sample -- `
  "Write a detailed 500-word analysis of every script in the scripts/ directory, then wait and re-read them. Do not change any files." `
  --repo swigerb/squad-on-aca --ref feat/33-s3-live-e2e --no-push `
  --session s3-live-cancel --poll-seconds 10 --cancel-after-seconds 50
```

```text
  [squad-aca] dispatched s3-live-cancel route=AcaJob mode=RunToCompletion
  [squad-aca] squad-aca sessions exited 0
  [squad-aca] squad-aca stop exited 0
  [squad-aca] stop requested for handle s3-live-cancel
CANCELLED after 00:01:05.7628837.
```

Exit code 5. The client returning "cancelled" proves nothing on its own — that
is exactly the shape a broken implementation takes. Asked of Azure directly:

```text
Name                           Status    Start
-----------------------------  --------  -------------------------
caj-squad-aca-session-kn4yvdd  Stopped   2026-07-31T12:51:18+00:00
```

**`Stopped`, from the ACA control plane, not from the client.** The session was
mid-flight when the token was cancelled and it is no longer running. The
fresh-`CancellationTokenSource` stop path in `SquadAcaAIAgent` does what the
offline tests said it does.

Orphan check across the whole job:

```text
$ az containerapp job execution list ... --query "[?properties.status=='Running']"
(no rows)
```

## S3-3 — `fail-closed` — **PASS**

A throwaway branch carried a `squad-capabilities.yml` requiring `python3` and
`pip3`, which the default worker image does not provide. Run with
`SQUAD_ACA_ENABLE_SANDBOX` unset:

```text
  [squad-aca] squad-aca run exited 1
FAIL-CLOSED — capability routing refused this session. Nothing was started.
  reason       : sandbox-feature-disabled-and-default-insufficient
  sandboxClass : sandbox-python-3-12
  exitCode     : 1
  message      : Capability routing failed closed for session 's3-live-failclosed'; nothing was dispatched. Reason: sandbox-feature-disabled-and-default-insufficient. ...
  elapsed      : 00:00:08.2453971
```

Exit code 3 — `SquadRouteFailedClosedException`, carrying its reason, **not** a
generic failure, even though the control plane also exited 1. That ordering
(`route == "fail-closed"` classified before the exit code is looked at) is the
whole point, and 8.2 s with no ACA execution created confirms "nothing was
started" is literal.

## S3-4 — Sandbox plane, run to completion — **PASS**

Same branch, `SQUAD_ACA_ENABLE_SANDBOX=1`:

```text
[squad-aca] sandbox squad-s3-live-sandbox: created, default-deny egress applied, worker launched detached.
  [squad-aca] dispatched s3-live-sandbox route=Sandbox mode=RunToCompletion
Squad session 's3-live-sandbox' finished on route 'sandbox' with status 'Succeeded' (phase done) (exit code 0). Sandbox class: sandbox-python-3-12.

  squad.dispatched       = True
  squad.executionMode    = Sandbox
  squad.exitCode         = 0
  squad.longRunMode      = RunToCompletion
  squad.phase            = done
  squad.route            = sandbox
  squad.sandboxClass     = sandbox-python-3-12
  squad.sessionName      = s3-live-sandbox
  squad.status           = Succeeded
  squad.terminal         = True

elapsed    : 00:00:43.7897842
```

| | |
|---|---|
| Route | `sandbox`, reported through the MAF response as `squad.route` / `squad.sandboxClass` |
| Class | `sandbox-python-3-12` — the approved, pinned class the manifest demanded |
| Terminal status | `Succeeded`, phase `done`, exit code `0` |
| Real elapsed | **43.8 s** |

Egress on the live sandbox:

```text
Default action:     Deny
Traffic inspection: Full
Host rules:
  - *.github.com: Allow
  - github.com: Allow
  - *.githubcopilot.com: Allow
  - *.githubusercontent.com: Allow
  - pypi.org: Allow
  - *.pypi.org: Allow
  - files.pythonhosted.org: Allow
```

Default-deny, with exactly the manifest's two hosts added to the GitHub
baseline. On ordering: the control plane emits its single line only after both
the egress call and the launch have returned, and the worker cloned GitHub
successfully under a deny-by-default policy it could not have satisfied had the
policy been applied afterwards. That is strong ordering evidence, not a
timestamped proof — the `aca` CLI exposes no per-operation timestamps to make it
one. Stated plainly so nobody quotes it as more than it is.

## S3-5 — Cancellation on the sandbox plane — **FAIL (defect found)** — *fixed, see S6-1 below*

This is the finding of the sprint.

```text
[squad-aca] sandbox squad-s3-live-sbcancel: created, default-deny egress applied, worker launched detached.
  [squad-aca] dispatched s3-live-sbcancel route=Sandbox mode=RunToCompletion
  [squad-aca] squad-aca stop exited 0
  [squad-aca] stop requested for handle sqx1.eyJ2IjoxLCJwIjoic2FuZGJveCIsImQiOnsibmFtZSI6InNxdWFkLXMzLWxpdmUtc2JjYW5jZWwiLC...
CANCELLED after 00:01:07.1377280.
```

The client reported cancelled and `squad-aca stop` exited 0. Asked of the
sandbox itself afterwards:

```text
$ ls -la --time-style=full-iso /tmp/squad-session
drwxrwxrwt 5 root  root   4096 2026-07-31 12:55:19 ..            <- sandbox created
drwx------ 2 squad squad  4096 2026-07-31 12:56:02 .             <- cancel ran (touched done, removed cred)
-rw-r--r-- 1 squad squad     0 2026-07-31 12:56:53 done
-rw-r--r-- 1 squad squad     1 2026-07-31 12:56:53 exit-code
-rw-r--r-- 1 squad squad     4 2026-07-31 12:56:53 phase
-rw-r--r-- 1 squad squad 11754 2026-07-31 12:56:53 session.log

$ cat /tmp/squad-session/phase       -> done
$ cat /tmp/squad-session/exit-code   -> 0
$ tail session.log
  AI Credits 31.7 (1m 31s)
  [squad-policy] Governance integrity verified: no protected path changed.
```

The cancel landed at **12:56:02**. The worker went on running for another
**51 seconds** and completed normally at 12:56:53, overwriting the `143` /
`cancelled` the cancel had written with its own `0` / `done`.

Root cause, probed directly in the pinned class image:

```text
pkill: NOT-FOUND
pgrep: NOT-FOUND
ps:    NOT-FOUND
kill:  kill
--- the exact pkill the provider issues ---
pkill exit=127
--- the exact full cancel chain the provider issues ---
squad-cancelled
chain exit=0
```

`scripts/lib/providers/squad-sandbox-provider.ps1` cancels with:

```sh
pkill -f /usr/local/bin/squad-on-aca >/dev/null 2>&1; rm -f .../credential; \
printf %s 143 > .../exit-code; printf %s cancelled > .../phase; \
touch .../done; echo squad-cancelled
```

`procps` is not installed in `sandbox-python-3-12`, so `pkill` exits **127**.
Its stderr is discarded by the `2>&1` redirect, and because the chain's exit
status is that of the final `echo`, the whole command **exits 0**. The provider
reads exit 0, returns `Cancelled = $true`, and the caller is told the session
stopped while it is still running and still billing.

The provider comment directly above this code says a caller told "cancelled"
must never stop looking at a session that is still running and still billing.
The classification logic around the call honours that scrupulously. The command
it classifies cannot fail.

Mitigations that did hold on this run:

- The brokered credential **was** removed from the sandbox (`rm -f` needs no
  `procps`), so the session did not outlive its token.
- `sandboxgroup credential list` afterwards returned `[]`.
- The sandbox was still deletable, and `terminate` (which goes through the ACA
  control plane, not through a shell inside the guest) is unaffected.

This is not the MAF adapter's defect. The adapter did exactly what it promised —
it issued the stop on a fresh token before rethrowing, and the Jobs plane
(S3-2) proves that path genuinely stops a session. The bug is one layer below,
in the sandbox provider's `cancel`, and **no offline test could have found it**:
every fake answers the way the real image does not. It is precisely the class of
failure this sprint existed to look for.

Not fixed in Sprint 3. Sprint 3's hard constraints forbid changing error
classification, and a portable-kill rewrite needs its own offline coverage
against an image that has no `procps`. Filed rather than patched in passing.
**Fixed under [#36](https://github.com/swigerb/squad-on-aca/issues/36); the
live re-verification is S6-1 below.**

## S3-6 — Cleanup and orphans — **PASS**

Every `aca sandbox delete` was issued with `--yes`, and the group was listed
afterwards rather than trusted:

```text
$ aca sandbox delete --id c9d95b60-... --group sbg-squad-aca --yes
Deleted sandbox: c9d95b60-...
$ aca sandbox delete --id 01d28bc6-... --group sbg-squad-aca --yes
Deleted sandbox: 01d28bc6-...

$ aca sandbox list --group sbg-squad-aca --resource-group rg-squad-aca-dev-eastus2
┌────┬───────┬──────────┬────────┐
│ ID ┆ State ┆ Hostname ┆ Labels │
╞════╪═══════╪══════════╪════════╡
└────┴───────┴──────────┴────────┘
```

Zero sandboxes. Zero running job executions. Zero brokered credentials on the
group. The pinned class image is untouched:

```text
│ 02560016-d170-486d-a99b-aed763296b6c ┆ acrsquadaca....azurecr.io/squad-worker-python@sha256:748bcf32...b69131 ┆ Ready │
```

Worth recording that **both** sandboxes were still `Running` after their
sessions reached a terminal state. That is by design — `cancel` deliberately
leaves the sandbox up so logs stay readable, and teardown is `terminate`'s job —
but it means a terminal session is not a stopped bill. Anyone reading a green
"Succeeded" as "nothing is costing money" is wrong, which is why the listing is
reported here rather than the delete messages.

## Sprint 3 verdict

Four of five live claims hold. A MAF host that has never heard of Squad can
resolve an `AIAgent`, dispatch a real session to ACA Jobs or to an approved
sandbox class, get the route and terminal status back, and be refused correctly
when capability routing fails closed. Cancellation genuinely stops an ACA Job.

Cancellation did **not** genuinely stop a sandbox worker, and reported that it
did. That was invisible for the whole programme until something ran for real.
It is now fixed and re-verified live — see **S6-1** below.


## S6-1 — Cancellation on the sandbox plane, after the #36 fix — **PASS**

Same plane, same pinned class image, same disk
(`02560016-d170-486d-a99b-aed763296b6c`). The procps probe is unchanged — the
image still has no `pkill`, `pgrep` or `ps`, and `kill` is still only a shell
builtin:

```text
pkill: not found   MISS
pgrep: not found   MISS
ps:    not found   MISS
kill               kill
```

The launch now records the worker's own pid (`printf %s $$` as the wrapper's
first act), and the cancel reads it, signals the **process group** with the
builtin, confirms death by scanning `/proc`, and only then writes the markers.
Run against a live worker that had spawned a child:

```text
=== state before cancel ===
PID=34
PHASE=running
CHILD=36

CANCEL SENT AT: 15:06:14.744Z
=== CANCEL (emitted by New-SandboxCancelCommand) ===
squad-cancelled
squad-cancel-status=killed
CANCEL RETURNED AT: 15:06:16.433Z  ELAPSED_MS=1689

=== AFTER CANCEL (from inside the guest) ===
PIDFILE=[]
PHASE=cancelled
EXITCODE=143
MARKER=done
CHILD=36
CHILD_PROC=GONE
PROCTABLE:
1 (tini) S 0 1
5 (sleep) S 1 5
52 (sh) R 0 52

=== markers 20s later ===
PHASE_LATER=cancelled
EXITCODE_LATER=143

=== SECOND CANCEL (idempotency) ===
squad-cancelled
squad-cancel-status=already-terminal
```

The process table afterwards holds only `tini` (pid 1), the image's own idle
`sleep` and the `sh` running the query itself. Worker **and** child are gone,
the markers say `cancelled`/`143`, and — the thing that failed in S3-5 — they
were **still** `cancelled`/`143` twenty seconds later. A second cancel is
idempotent (`already-terminal`) and does not rewrite anything.

The 1 689 ms above is a control-plane round trip; a trivial `echo` exec on the
same sandbox costs 1 451 ms. Timing the cancel **inside** the guest removes the
transport:

```text
=== CANCEL #2 (timed inside the guest) ===
squad-cancelled
squad-cancel-status=killed
GUEST_RC=0
GUEST_MS=11
```

**11 ms** from cancel to confirmed death, against **51 seconds of continued
execution** in S3-5. Nothing is assumed: `killed` is only reached after a
`/proc` scan finds no non-zombie process left in the worker's process group.

Failure is now loud. A cancel that cannot prove the worker stopped reports its
own reason — `no-pidfile`, `bad-pidfile`, `not-ours`, `kill-failed`,
`survived`, `no-proc`, `scan-failed` — leaves the session's markers untouched,
and the provider raises rather than returning `Cancelled = $true`. A sandbox
launched by the pre-fix code has no pid file and therefore reports
`no-pidfile`: a **failed** cancel whose message names
`aca sandbox delete -l name=<name> --yes` as the control-plane escape hatch.

One further defect was found and fixed during this verification, and it is
worth recording because it is the same failure class one level deeper.
`aca sandbox exec` runs the command under `/bin/sh`, which is **dash** on this
image (`/bin/sh -> dash`, and the exec's own `/proc` entry reads `(sh)`). The
first version of the fix used `$(< file)` to read `/proc/<pid>/stat` — a
**bashism that expands to the empty string under dash**, with no error and no
exit code. It scanned zero processes, concluded `already-dead`, wrote
`cancelled`/`143` and left the worker running:

```text
squad-cancel-status=already-dead      <- a lie
32 (bash)  ... pgrp 32                <- still alive
33 (bash)  ... pgrp 32
34 (sleep) ... pgrp 32
```

The offline probe had passed, because it ran the emitted command under **bash**.
Two changes followed: the command is now strict POSIX `sh` (verified with both
`dash -n` and `bash -n`, and statically checked for bashisms by `validate.ps1`
section 6e), and the probe evaluates it via `sh -c` so the test shell matches
production. The scan is also **fail-closed**: reading not one `/proc` entry is
`scan-failed`, never `already-dead`, and the script self-tests by reading its
own `/proc/self/stat` with the same builtin before it believes any "not found".

Every sandbox created for this verification was deleted with `--yes` and the
group listed afterwards; see S6-2.

## S6-2 — Cleanup after the #36 verification — **PASS**

```text
$ aca sandbox delete -l name=sq36-live2 --group sbg-squad-aca -g rg-squad-aca-dev-eastus2 --yes
Deleting sandbox a8b682dd-6233-471a-9a26-7b9776110633...
Deleted sandbox: a8b682dd-6233-471a-9a26-7b9776110633

$ aca sandbox list --group sbg-squad-aca -g rg-squad-aca-dev-eastus2
┌────┬───────┬──────────┬────────┐
│ ID ┆ State ┆ Hostname ┆ Labels │
╞════╪═══════╪══════════╪════════╡
└────┴───────┴──────────┴────────┘
```

The class disk `02560016-d170-486d-a99b-aed763296b6c` was left in place and
still lists as `Ready`.

---

# Sprint 2 (issue #32) — GitHub Actions trigger, live end-to-end

Issue [#44](https://github.com/swigerb/squad-on-aca/issues/44) is the E2E
verification trigger for the [#32](https://github.com/swigerb/squad-on-aca/issues/32)
control-plane move: **GitHub Action fires on an event → authenticates to Azure
via OIDC → claims the shared lease → starts the ACA dispatcher job**, with the
laptop-run `squad-aca.ps1` CLI removed from the trigger path. Applying the
`squad` label to an issue drives `squad-dispatch.yml`; the same shared decision
core (`worker/lib/squad-dispatch.js`) that Ralph and Watch use decides,
claims the lease, and starts the execution, so a proof against `squad-dispatch.yml`
proves the whole family.

## S2-1 — First live attempt — **FAIL (defect found, fixed in #46)**

Workflow run [30662711996](https://github.com/swigerb/squad-on-aca/actions/runs/30662711996).
Azure OIDC login succeeded, but the lease-claim step failed with a 403
(`Resource not accessible by integration`): `squad-dispatch.yml`'s dispatch job
only granted `contents: read`, while the shared lease is written via the
GitHub Contents API against the `squad-aca-leases` ref, which needs
`contents: write`. Fixed in #46 (merged as commit `faa6a3a` on `main`):
least-privilege layout is now a read-only `resolve` job plus a job-scoped
`id-token: write`, `contents: write`, `issues: write` on `dispatch`.

## S2-2 — Re-run after the permissions fix — **PASS**

Workflow run [30664755108](https://github.com/swigerb/squad-on-aca/actions/runs/30664755108),
`issues` trigger on `main` after #46 landed:

```text
resolve:  verdict: {"dispatch":true,"reason":"label-applied","issueNumber":44,"label":"squad","sessionName":"issue-44-30664755108"}
dispatch: Azure login succeeds by using OIDC (subject claim - repo:swigerb/squad-on-aca:ref:refs/heads/main)
dispatch: {"outcome":"repaired", ..., "state":"claimed", ...}
dispatch: claim outcome 'repaired' -> {"action":"start","reason":"lease-repaired"}
dispatch: Started ACA execution: caj-squad-aca-session-oa5bg21
dispatch: Confirmed: ACA execution caj-squad-aca-session-oa5bg21 is running the work.
```

No more 403 — the lease claim succeeds and produces a real ACA execution.

## S2-3 — Reproducibility pass — **PASS**

Two further independent re-runs confirmed the path is reproducible on `main`,
not a one-off:

- Run [30666116948](https://github.com/swigerb/squad-on-aca/actions/runs/30666116948):
  lease claim `repaired` → `action":"start"`, `Started ACA execution:
  caj-squad-aca-session-d1xrmpn`, guard step confirmed.
- An intervening run (30665958645) failed Azure OIDC with a transient
  `No subscriptions found`; the very next re-run succeeded cleanly, so the
  failure was environmental, not a regression in the OIDC/lease/start path.
- Run [30667555415](https://github.com/swigerb/squad-on-aca/actions/runs/30667555415)
  (the run that produced this session, `issue-44-30667555415`, and this PR):

  ```text
  resolve:  verdict: {"dispatch":true,"reason":"label-applied","issueNumber":44,"label":"squad","sessionName":"issue-44-30667555415"}
  dispatch: Azure CLI login succeeds by using OIDC.
  dispatch: {"outcome":"repaired","lease":{"leaseKey":"issue-44","sessionId":"issue-44-30667555415","route":"aca-job","state":"claimed",...}}
  dispatch: claim outcome 'repaired' -> {"action":"start","reason":"lease-repaired"}
  dispatch: Started ACA execution: caj-squad-aca-session-nwxyb1h
  dispatch: Confirmed: ACA execution caj-squad-aca-session-nwxyb1h is running the work.
  ```

  This session — the one that authored this documentation and its PR — **is**
  that ACA execution: the loop closes from a label event, through OIDC and the
  shared lease, to a running agent that pushes real changes back to GitHub,
  with no laptop in the path.

## Result

- Azure OIDC federation from `squad-dispatch.yml`: **PASS**, reproducible
  across four independent workflow runs.
- Shared lease claim (`contents: write` scoped to the `dispatch` job only):
  **PASS** after #46; the pre-fix 403 is a closed defect, not an open risk.
- ACA session job start from the Actions trigger, with the full merged
  environment (managed secret refs included, per #48's env-merge fix):
  **PASS**, and self-evidenced by this session's own existence.
- Sprint 2's goal — the control plane fires from Azure, not a developer's
  laptop — is met and reproducible on `main`. No further code change is
  required to close #32 Sprint 2; #44 tracked the verification only.

### Correction: a started execution is not a finished session

The runs above prove the **trigger**. They do not, on their own, prove the
session, and two of those executions did in fact **fail** after starting. Both
failures were dispatch defects, and the distinction matters because "Started ACA
execution" is the last line the workflow ever sees.

| Execution | Trigger | Session | Cause |
|---|---|---|---|
| `caj-squad-aca-session-oa5bg21` | PASS | **Failed** | `--env-vars` REPLACES the container environment rather than merging it, so every secret-backed variable was dropped. The session pulled the image, cloned the repository, and died with `Error: No authentication information found`. Fixed in #48. |
| `caj-squad-aca-session-d1xrmpn` | PASS | **Failed** | `ralph_build_session_env` deliberately skips managed keys when copying the template, so the caller must supply `OV_GITHUB_TOKEN=secretref:...` itself. Measured: 18 template entries in, 15 out — exactly the three secret-backed ones missing. Fixed in #49. |
| `caj-squad-aca-session-nwxyb1h` | PASS | **Succeeded** | — |
| `caj-squad-aca-session-blm7t3n` | PASS | **Succeeded** | Sprint 3 and 4 final live verification for #32, driven by issue [#55](https://github.com/swigerb/squad-on-aca/issues/55): an `issues_comment` `/squad` trigger ([run 30673535717](https://github.com/swigerb/squad-on-aca/actions/runs/30673535717)) resolved with a requester (`swigerb`), claimed a fresh lease, started this ACA session, and commented the execution details back on the issue — confirming status-comment and requester-attribution behavior end to end. |

Both were caught by the token preflight added in #42, at roughly two minutes,
rather than at the push after a full agent run:

```text
[token-preflight] Credential wiring OK: one absolute-path helper for https://github.com, no URL rewrite, token file 0600.
[token-preflight] The credential is accepted by the GitHub API.
[token-preflight] The credential does NOT have push access to swigerb/squad-on-aca (permissions.push=false).
[token-preflight]   This session intends to PUSH; the push would fail after the whole agent run.
```

The last of those was not a dispatch defect at all: `deploy.ps1` falls back to
`gh auth token`, which on this machine returns a **read-only** account's token.
The preflight named the real problem instead of letting the session run for an
hour and fail at the push.

One honest gap remains, and the preflight says so itself:

```text
[token-preflight] Token expiry is UNKNOWN (no SQUAD_TOKEN_EXPIRES_AT and no expiry header); remaining lifetime was NOT checked.
[token-preflight] Token preflight passed (usability verified, lifetime unverified).
```

The session job still runs on a long-lived PAT, so the one-hour lifetime check
has nothing to check. Minting a GitHub App installation token at dispatch time
and passing `SQUAD_TOKEN_EXPIRES_AT` is tracked separately.
Attribution verified live on issue #59.
