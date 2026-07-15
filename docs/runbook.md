# Squad on ACA runbook

This runbook explains how to deploy and operate Squad on Azure Container Apps.

## Assumptions and prerequisites

- **Azure**: `az` CLI signed in with rights to create resource groups, ACR,
  Container Apps, user-assigned identities, role assignments, Log Analytics, and
  optional Key Vault. A selected subscription (`az account set`).
- **GitHub**: `gh` CLI authenticated and `gh auth setup-git` configured. Tokens
  valid for GitHub API work and Copilot CLI headless auth (optionally separate).
- **Local tooling**: PowerShell 5.1+ (Windows PowerShell or PowerShell 7), Git,
  Node.js/npm. `bash` (Git Bash or WSL) only for `scripts/validate.ps1`'s worker
  entrypoint check.
- **Telemetry sink**: the current default is a **standalone Aspire Dashboard**
  deployed as a Container App (`ca-squad-aca-aspire`). It is the OTLP sink for all
  sessions, with browser-token UI auth and OTLP API-key auth, and internal-only
  OTLP ports.
- **Optional .NET/Aspire path**: requires .NET SDK 9.0+ and a .NET 9 runtime; it
  is opt-in and not required for the default ACA flow. See
  [../aspire/README.md](../aspire/README.md) and [architecture.md](architecture.md).

## Architecture

The deployment creates:

| Resource | Purpose |
| --- | --- |
| `<acr-name>` | ACR for the `squad-worker` image. |
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

Dispatch never mutates the shared job template. `scripts/start-session.ps1` (and
Ralph) read the job template's environment once (an immutable read), strip the
session-managed keys, overlay the fresh session values, and pass the complete set
to `az containerapp job start --env-vars`. That start override applies to a single
execution only — image, CPU/memory, registry, and secrets are inherited from the
stored template, which is never written. This eliminates two prior hazards:
omitted variables persisting between sessions, and concurrent dispatches racing on
a shared `job update`.

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

Ralph polls GitHub issues labeled `squad`, skips blocked/assigned/already-dispatched issues, adds the `squad-aca:dispatched` label (the `squad:*` namespace is reserved by Squad member-routing workflows, so Ralph uses the ACA-specific `squad-aca:dispatched` marker to avoid triggering member assignment), and starts `caj-squad-aca-session` with a prompt for that issue. Each dispatch builds a complete, isolated environment from an immutable snapshot of the session job template and passes it to `az containerapp job start --env-vars`, so the shared session job template is never mutated (no stale-value leak, no concurrent-dispatch race). The session job is the ACA equivalent of an agent Kubernetes Job.

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
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
```

Common defaults:

```text
Location: eastus2
Resource group: rg-squad-aca-dev-eastus2
```

For production-style secret references:

```powershell
.\scripts\deploy.ps1 -UseKeyVault -KeyVaultName kv-your-squad-aca
```

Deployment output is written to ignored local file `deploy.outputs.json`.

`deploy.ps1` is idempotent and safe to re-run for upgrades, token rotation, and
recovery. The Aspire dashboard app is created on first deploy and updated in place
on subsequent runs (`az containerapp update --yaml`), so re-running rotates the
OTLP API key and dashboard browser token and rolls a new revision instead of
failing because the app already exists. BrowserToken UI auth, ApiKey OTLP auth,
and internal-only OTLP ports are defined in the deployment YAML and preserved on
every run.

## Start a session

### Existing Squad repo

From any existing repository with `.squad/` already initialized:

```powershell
cd path\to\existing-squad-repo
squad-aca "Use the existing Squad team to implement the next feature and open a PR"
```

The command validates the ACA deployment, verifies `.squad/team.md`, syncs `.squad` state to GitHub, and starts an ACA-hosted session against the current repository and branch. If local non-Squad files are uncommitted, the command warns that ACA will not see them. Add `--sync-all` to commit and push the full working tree before dispatch.

Control-plane commands:

```powershell
squad-aca doctor
squad-aca sessions --limit 20
squad-aca logs <session-or-execution> --tail 200
squad-aca stop <session-or-execution>
squad-aca open <session-or-execution>
squad-aca sync --dry-run
squad-aca sync --sync-all
squad-aca watch start --repo "<github-owner>/<repo>"
squad-aca watch stop
squad-aca ralph status
squad-aca ralph run --repo "<github-owner>/<repo>"
squad-aca ralph pause
squad-aca ralph resume
squad-aca subsquad list
squad-aca subsquad run docs "Update the docs and open a PR"
squad-aca upgrade --deploy
squad-aca telemetry smoke
squad-aca secrets rotate
squad-aca export squad-export.json
squad-aca import squad-export.json
```

Destructive command:

```powershell
squad-aca destroy --yes
```

If ACA is not configured:

```powershell
squad-aca configure --resource-group <rg> --session-job <job> --subscription <azure-subscription-id>
```

or deploy:

```powershell
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
```

Recommended developer flow:

```powershell
squad-aca init --owner "<github-owner>" --name "my-app"
squad-aca "Build the first feature and open a PR"
```

Copilot control-plane flow:

```powershell
copilot --agent squad-aca
```

Then ask Copilot for work normally. The installed `squad-aca` agent dispatches the actual Squad session to ACA.

Smoke test:

```powershell
.\scripts\start-session.ps1 -Repository "<github-owner>/<repo>" -Mode smoke -RunCopilotSmoke -SessionName smoke-001
```

Prompt session:

```powershell
.\scripts\start-session.ps1 `
  -Repository "<github-owner>/<repo>" `
  -Mode prompt `
  -SessionName docs-001 `
  -Prompt "Use Squad to improve the docs. Open a PR if changes are needed." `
  -PushChanges `
  -OutputBranch squad/docs-001
```

Loop session:

```powershell
.\scripts\start-session.ps1 -Repository "<github-owner>/<repo>" -Mode loop -SessionName daily-loop
```

## Start a project without a repo

Use `scripts/new-project.ps1` when you have an idea but no GitHub repository yet:

```powershell
squad-aca new --owner "<github-owner>" --name my-new-squad-project --description "A new app bootstrapped by Squad on ACA"
```

Direct script form:

```powershell
.\scripts\new-project.ps1 `
  -Owner "<github-owner>" `
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
.\scripts\start-watch.ps1 -Repository "<github-owner>/<repo>" -IntervalMinutes 5 -TimeoutMinutes 45
```

Stop the watcher:

```powershell
.\scripts\start-watch.ps1 -Repository "<github-owner>/<repo>" -Stop
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
.\scripts\start-session.ps1 -Repository "<github-owner>/<repo>" -Mode prompt -SubSquad docs -SessionName docs-001 -Prompt "Work the next docs issue."
.\scripts\start-watch.ps1 -Repository "<github-owner>/<repo>" -SubSquad platform
```

## Monitor

```powershell
squad-aca status
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

## Rollback and recovery

When a deploy, config change, or session goes wrong, use the ordered recovery
procedures in [rollback.md](rollback.md). They run from least to most disruptive:

1. **Optional .NET/Aspire path** — revert local scaffold changes; no Azure teardown.
2. **ACA worker image / session job** — redeploy the last-known-good image and stop
   failing executions.
3. **Aspire token / secrets** — regenerate the OTLP API key and dashboard browser
   token via `scripts/deploy.ps1`, and rotate GitHub/Copilot tokens with
   `squad-aca secrets rotate`.
4. **Ralph / watch** — `squad-aca ralph pause` and `squad-aca watch stop` to halt
   unattended dispatch without touching the rest of the deployment.
5. **Full resource-group destroy / redeploy** — `squad-aca destroy --yes` then
   `scripts/deploy.ps1` as a last resort.

Each procedure ends with the post-rollback verification checklist in
[rollback.md](rollback.md#post-rollback-verification).

## Security notes

- Use a separate GitHub token for GitHub API work and Copilot headless auth when your policy requires separation.
- Use `-UseKeyVault` for Key Vault-backed Container Apps secrets.
- Keep `deploy.outputs.json` private; it contains the Aspire browser token. It is gitignored along with `.azure/` and `.env`.
- `.squad/` should live in the target GitHub repo when you want Squad memory and team state to travel with code.
- **RBAC (existing risk):** the user-assigned managed identity holds `Contributor`
  on the resource group so Ralph can start session job executions. This is broader
  than required. Do not broaden it further. A custom-role hardening path (limited
  to `Microsoft.App/jobs/start/action` + read) is documented in
  [validation.md](validation.md#rbac--identity-scope); adopt it only if it does not
  break deployment.
- **OTLP auth is preserved:** BrowserToken for the UI, ApiKey for OTLP, never
  `Unsecured`. OTLP ports stay internal to the ACA environment.
- **Public sync guard:** `squad-aca sync --sync-all` blocks obvious secret files
  and inline tokens before staging. Override only for known-private repos with
  `SQUAD_ACA_ALLOW_UNSAFE_SYNC=1`.
- **Validation:** run `scripts/validate.ps1` and follow
  [validation.md](validation.md) for the full security validation checklist.
