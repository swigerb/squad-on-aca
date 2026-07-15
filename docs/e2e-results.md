# E2E results and live evidence

This document records the end-to-end (E2E) validation evidence for Squad on ACA.
It has two parts:

1. **Static evidence** — checks that run anywhere with no live Azure. These were
   executed in the current environment and their real output is recorded below.
2. **Live-Azure evidence** — checks that require a deployed ACA stack. These are
   templated with the exact commands to run and the observations to capture. The
   **main orchestrator (or an operator with Azure credentials) must run the
   commands in an environment with `az login` and a deployment, then paste the
   observed output into the placeholders.** The subagent that authored this file
   deliberately runs only static local validation and does not create or mutate
   live Azure resources.

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
template, stripping session-managed keys and overlaying fresh values. The Node
transformer was exercised offline with a representative template snapshot:

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

## Live-Azure evidence (to be filled by the orchestrator/operator)

Prerequisites: `az login`, `az account set --subscription <sub>`, `gh auth login`,
and a deployment (`scripts/deploy.ps1`). Use the resource group from
`deploy.outputs.json`. Redact subscription/tenant GUIDs before committing.

> Run metadata
>
> - Date (UTC): `____`
> - Commit SHA: `____`
> - Resource group: `____`
> - Operator: `____`

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
____ (paste: second deploy exit code 0; new revision created; browser token rotated)
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
____ (paste: DASHBOARD__FRONTEND__AUTHMODE=BrowserToken, DASHBOARD__OTLP__AUTHMODE=ApiKey;
      ports 18889/18890 external=false)
```

### L3. Session dispatch does not mutate the shared job template

Capture the job template env before and after a dispatch; they must be identical
(the dispatch used a per-execution `--env-vars` override, not `job update`).

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
____ (paste: Compare-Object returns nothing -> template unchanged)
```

Pass criteria: `Compare-Object` reports **no differences** — the shared template
was not mutated by dispatch.

### L4. Per-execution isolation (no stale leak, complete env)

Dispatch a `prompt` session, then a `smoke` session that omits `SQUAD_PROMPT`.
The second execution must NOT contain the first execution's `SQUAD_PROMPT`, and
must still contain the durable common vars.

```powershell
.\scripts\start-session.ps1 -Repository <owner/repo> -Mode prompt -SessionName e2e-leak-a `
  -Prompt "LEAK-CANARY-should-not-appear-in-next-run" -NoWait
.\scripts\start-session.ps1 -Repository <owner/repo> -Mode smoke -SessionName e2e-leak-b -NoWait
# For execution e2e-leak-b, inspect its env:
$exec = az containerapp job execution list -n caj-squad-aca-session -g <rg> `
  --query "[?contains(name,'')].name" -o tsv   # pick the e2e-leak-b execution
az containerapp job execution show -n caj-squad-aca-session -g <rg> --job-execution-name <exec> `
  --query "properties.template.containers[0].env[?name=='SQUAD_PROMPT']"
az containerapp job execution show -n caj-squad-aca-session -g <rg> --job-execution-name <exec> `
  --query "properties.template.containers[0].env[?name=='ASPIRE_OTLP_GRPC_ENDPOINT']"
```

Observed:

```text
____ (paste: SQUAD_PROMPT absent in e2e-leak-b; ASPIRE_OTLP_GRPC_ENDPOINT present)
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
____ (paste: each execution shows its own SESSION_NAME e2e-conc-1/2/3 and matching
      OTEL_SERVICE_NAME squad-e2e-conc-N)
```

### L6. Telemetry smoke reaches the Aspire dashboard

```powershell
.\scripts\start-session.ps1 -Repository <owner/repo> -Mode telemetry-smoke -SessionName e2e-telemetry
# Open aspireLoginUrl from deploy.outputs.json; filter service name squad-e2e-telemetry
```

Observed:

```text
____ (paste: trace/metric/log for squad-e2e-telemetry visible in the dashboard)
```

### L7. Ralph dispatch (scheduled path)

Label an actionable issue `squad`, wait for the Ralph schedule (or run
`squad-aca ralph run`), then confirm the issue gets `squad:dispatched` and a
session execution starts — and that the Ralph/session templates are unchanged
afterward (same non-mutation check as L3).

```powershell
gh issue create --repo <owner/repo> --title "E2E ralph test" --body "..." --label squad
# wait up to 5 min or: squad-aca ralph run --repo <owner/repo>
gh issue view <n> --repo <owner/repo> --json labels
az containerapp job execution list -n caj-squad-aca-session -g <rg> --query "[0:3].name" -o tsv
```

Observed:

```text
____ (paste: squad:dispatched label added; new caj-squad-aca-session execution;
      template env unchanged before/after)
```

---

## Result

- Static evidence: **PASS** (recorded above).
- Live-Azure evidence: **PENDING** — orchestrator/operator to complete L1–L7 and
  set this line to PASS/FAIL with the run metadata filled in.
