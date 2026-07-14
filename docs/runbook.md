# Squad on ACA runbook

This runbook explains how to deploy and operate Squad on Azure Container Apps.

## Architecture

The deployment creates:

| Resource | Purpose |
| --- | --- |
| `acrsquadacabrswig` | ACR for the `squad-worker` image. |
| `uai-squad-aca-acrpull` | User-assigned identity used by ACA to pull from ACR and optionally read Key Vault secrets. |
| `cae-squad-aca` | Azure Container Apps environment. |
| `ca-squad-aca-aspire` | Aspire Dashboard with browser-token UI auth and OTLP API-key auth. |
| `caj-squad-aca-session` | Manual ACA job. Every execution is one remote Squad session pod. |
| `caj-squad-aca-ralph` | Scheduled ACA job. Ralph polls every 5 minutes, like the AKS CronJob pattern. |
| `ca-squad-aca-watch` | Long-running watcher app for issue-driven unattended work. |
| `law-squad-aca` | Log Analytics workspace for ACA logs. |

## Session model

Every session runs in its own ACA job replica. The worker sets:

```text
SQUAD_DEPLOYMENT_MODE=squad-per-pod
SQUAD_POD_ID=<session name or ACA execution name>
OTEL_SERVICE_NAME=squad-<session name>
```

This matches Squad's containerized/Kubernetes pod-aware mode. The whole team you normally run from one CLI session lives inside that one ACA execution.

## Scale-to-zero behavior

ACA uses jobs for the expensive work, so idle cost is intentionally low:

| Component | Idle behavior |
| --- | --- |
| `caj-squad-aca-session` | No running replica between executions. |
| `caj-squad-aca-ralph` | No running replica between scheduled polls. |
| `ca-squad-aca-watch` | Can be scaled to zero with `scripts/start-watch.ps1 -Stop`. |
| `ca-squad-aca-aspire` | Kept running by default so the dashboard is always reachable. |

This is the ACA equivalent of the AKS pattern where agents run as Kubernetes Jobs and Ralph runs as a CronJob. KEDA is not required for per-session scale-to-zero because ACA Jobs are already event/manual/schedule triggered.

## Ralph job runner

Ralph is the scheduled poller, not the worker image. The worker image is shared by Ralph, on-demand sessions, and the watcher.

`caj-squad-aca-ralph` runs every 5 minutes with:

```text
SQUAD_MODE=ralph
SQUAD_DEPLOYMENT_MODE=squad-per-pod
SQUAD_POD_ID=ralph-scheduled
```

ACA does not expose Kubernetes `concurrencyPolicy: Forbid`. The deployment uses `parallelism=1`, `replicaCompletionCount=1`, and `replicaTimeout=240`. Ralph is a short dispatcher that exits after starting session jobs, keeping runtime below the 5-minute schedule.

Ralph polls GitHub issues labeled `squad`, skips blocked/assigned/already-dispatched issues, adds the `squad:dispatched` label, and starts `caj-squad-aca-session` with a prompt for that issue. The session job is the ACA equivalent of an agent Kubernetes Job.

The user-assigned managed identity has:

```text
AcrPull on ACR
Contributor on the resource group
```

The Contributor assignment lets Ralph start ACA session job executions. Scope it more narrowly if your tenant has a custom role for `Microsoft.App/jobs/start/action`.

## GitHub remote sessions

Copilot CLI runs with:

```text
--yolo --agent squad --remote --no-auto-update
```

`--remote` enables GitHub web/mobile remote access for running sessions. Use a `COPILOT_GITHUB_TOKEN` or `GH_TOKEN` that is valid for Copilot CLI headless auth. Fine-grained PATs with the GitHub "Copilot Requests" permission are preferred; GitHub CLI OAuth tokens are also supported by Copilot CLI.

## Deploy

```powershell
.\scripts\deploy.ps1
```

Defaults:

```text
Subscription: 3898b8ea-c676-4b43-95fc-d38425627d74
Location: eastus2
Resource group: rg-squad-aca-dev-eastus2
Default repo: swigerb/squad-on-aca
```

For production-style secret references:

```powershell
.\scripts\deploy.ps1 -UseKeyVault -KeyVaultName kv-your-squad-aca
```

Deployment output is written to ignored local file `deploy.outputs.json`.

## Start a session

Smoke test:

```powershell
.\scripts\start-session.ps1 -Repository swigerb/squad-on-aca -Mode smoke -RunCopilotSmoke -SessionName smoke-001
```

Prompt session:

```powershell
.\scripts\start-session.ps1 `
  -Repository swigerb/your-repo `
  -Mode prompt `
  -SessionName docs-001 `
  -Prompt "Use Squad to improve the docs. Open a PR if changes are needed." `
  -PushChanges `
  -OutputBranch squad/docs-001
```

Loop session:

```powershell
.\scripts\start-session.ps1 -Repository swigerb/your-repo -Mode loop -SessionName daily-loop
```

## Start a project without a repo

Use `scripts/new-project.ps1` when you have an idea but no GitHub repository yet:

```powershell
.\scripts\new-project.ps1 `
  -Owner swigerb `
  -Name my-new-squad-project `
  -Description "A new app bootstrapped by Squad on ACA"
```

The helper:

1. Creates `owner/name` on GitHub with README and `.gitignore`.
2. Starts `caj-squad-aca-session` with `SQUAD_MODE=new-project`.
3. Lets Squad initialize `.squad/` and starter project files.
4. Pushes the work to `squad/<session-name>` and opens a PR.

If the repo already exists, pass `-UseExisting`.

## Start a watcher

```powershell
.\scripts\start-watch.ps1 -Repository swigerb/your-repo -IntervalMinutes 5 -TimeoutMinutes 45
```

Stop the watcher:

```powershell
.\scripts\start-watch.ps1 -Repository swigerb/your-repo -Stop
```

## Run SubSquads

Commit `.squad/streams.json` to the target repo:

```json
{
  "defaultWorkflow": "branch-per-issue",
  "workstreams": [
    {
      "name": "platform",
      "labelFilter": "team:platform",
      "folderScope": ["src", "infra"],
      "description": "Platform and infrastructure work"
    },
    {
      "name": "docs",
      "labelFilter": "team:docs",
      "folderScope": ["docs", "README.md"],
      "description": "Documentation work"
    }
  ]
}
```

Start scoped sessions:

```powershell
.\scripts\start-session.ps1 -Repository swigerb/your-repo -Mode prompt -SubSquad docs -SessionName docs-001 -Prompt "Work the next docs issue."
.\scripts\start-watch.ps1 -Repository swigerb/your-repo -SubSquad platform
```

## Monitor

```powershell
.\scripts\show-status.ps1
```

Open `aspireLoginUrl` from `deploy.outputs.json`. Filter by service name:

```text
squad-smoke-001
squad-docs-001
squad-watch-default
```

## CI/CD

The repo includes `.github/workflows/deploy-aca.yml`. Configure these GitHub secrets before running it:

```text
AZURE_CLIENT_ID
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
SQUAD_GITHUB_TOKEN
SQUAD_COPILOT_GITHUB_TOKEN
```

The Azure identity behind `AZURE_CLIENT_ID` needs rights to create/update resource groups, ACR, Container Apps, managed identities, role assignments, Log Analytics, and optional Key Vault resources.

## Security notes

- Use a separate GitHub token for GitHub API work and Copilot headless auth when your policy requires separation.
- Use `-UseKeyVault` for Key Vault-backed Container Apps secrets.
- Keep `deploy.outputs.json` private; it contains the Aspire browser token.
- `.squad/` should live in the target GitHub repo when you want Squad memory and team state to travel with code.
