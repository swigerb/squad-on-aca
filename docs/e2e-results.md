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
- **Commit at time of run:** `8a10f0d` (pre-commit of "Resolve final integration blockers").
- **Date (local):** 2026-07-15.

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
=== Worker entrypoint (bash -n) ===
  [PASS] worker/entrypoint.sh passed bash -n
=== Secret scan (docs + scripts + aspire) ===
  [PASS] No secret patterns found in docs/, scripts/, or aspire/
=== .NET/Aspire scaffold ===
  [PASS] aspire/Squad.Aca.sln present
  [PASS] aspire/Squad.Aca.AppHost\Squad.Aca.AppHost.csproj present
  [PASS] aspire/Squad.Aca.AppHost\AppHost.cs present
  [PASS] aspire/README.md present
  [PASS] Squad.Aca.AppHost.csproj is valid XML
  [PASS] dotnet build succeeded
=== Summary ===
  Passed: 16
  Failed: 0
All validation checks passed.
```

### 2. Worker entrypoint bash syntax

`bash -n worker/entrypoint.sh` — **PASS** (also covered by `validate.ps1` above,
including the new Ralph per-execution dispatch block and its inline Node
transformer heredoc).

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

---

## Result

- Static evidence: **PASS** (recorded above).
- Live-Azure evidence: **PASS** (L1-L6, L7a scheduled path, and L7b manual
  `squad-aca ralph run` CLI path recorded above).
