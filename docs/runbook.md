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
execution only, and the stored template is never written. Dispatch also reads the
image, CPU/memory, and container name from the same immutable template and echoes
them back on `job start` — not because the template needs mutating, but because
ACA only applies the per-execution `--env-vars` override reliably when the start
call also supplies a complete execution container spec (image + resources).
Without them, the worker still observes the template's baked-in values (for
example a `smoke-template` placeholder). Registry and secrets continue to resolve
from the stored template. This eliminates two prior hazards: omitted variables
persisting between sessions, and concurrent dispatches racing on a shared
`job update`.

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

Dispatch is transactional and isolated per issue (see `worker/lib/ralph-dispatch.sh`). For each issue Ralph builds and validates the env, starts the ACA session job, and adds the `squad-aca:dispatched` label **only after a confirmed start**. If env building or the job start fails, the issue is left **unlabeled** so the next scheduled run retries it rather than skipping it permanently, and Ralph logs the failure and continues to the next issue — a single bad issue never aborts the rest of the batch. Prompts and secret references are never written to logs. The set of session-managed env keys stripped from the template snapshot is mirrored in `scripts/lib/session-env.ps1` and `worker/lib/ralph-dispatch.sh`; `scripts/validate.ps1` fails on any drift between the two.

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

## Session logs

```powershell
squad-aca logs <session-or-execution> --tail 200
```

`logs` resolves the execution the same way `sessions`, `stop`, and `open` do, then reads console output through the first path that is available:

1. **`az containerapp job logs show`** — used when the `containerapp` Azure CLI extension is installed. This is the nicer path when it exists.
2. **Log Analytics fallback** — used otherwise. The deployment already provisions the `law-squad-aca` workspace (`deploy.ps1` writes its name to `deploy.outputs.json` as `logAnalyticsWorkspace`). Querying it does require the `log-analytics` az extension; what it avoids is the `containerapp` extension. When this path is used, `logs` prints a one-line note naming the workspace it read.

`az containerapp job logs show` is the **only** command the control plane uses that lives in the `containerapp` CLI extension; `run`, `status`, `sessions`, `stop`, and `doctor` are all core `az`. On hosts where the extension cannot be installed (for example an Azure CLI whose bundled Python lacks `_ctypes`, which breaks the `kubernetes` → `python-dateutil` build chain), only `logs` was affected — and it used to fail silently with exit 0. It now always propagates a non-zero exit code, and it never triggers the interactive "install the extension now?" prompt, which would otherwise block on stdin in CI, Ralph, and Watch contexts.

Check which path is active:

```powershell
squad-aca doctor
```

The `Logs path` row reports `ok` (containerapp extension present), `fallback` (Log Analytics will be used), or `failed` (neither path is available).

If both paths fail, `logs` exits non-zero and prints the remediation directly. To fix it:

```powershell
az extension add --name containerapp     # native path
az extension add --name log-analytics    # fallback path
```

If the deployment uses a workspace other than `law-squad-aca`:

```powershell
squad-aca configure --log-analytics-workspace <workspace-name>
```

The equivalent manual query, useful when you want raw Log Analytics access:

```powershell
$wsid = az monitor log-analytics workspace show `
  --resource-group <rg> --workspace-name law-squad-aca --query customerId -o tsv
az monitor log-analytics query -w $wsid --analytics-query @"
ContainerAppConsoleLogs_CL
| where ContainerGroupName_s startswith '<execution-name>'
| top 200 by TimeGenerated desc
| project TimeGenerated, Log_s
| order by TimeGenerated asc
"@
```

Log Analytics ingestion can lag a few minutes after a session starts. An execution with no rows yet produces a warning, not an error.

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

## ACA Sandboxes (preview, feature-flagged OFF)

`squad-aca` can dispatch a session to **Azure Container Apps Sandboxes** instead
of an ACA Job. This is **off by default and must stay off unless you have a
reason to turn it on.** ACA Jobs are the default and the rollback path.

### Prerequisites

1. **The standalone `aca` CLI.** Sandboxes are not driven by `az`; there is no
   `az containerapp sandbox` command. Install the `aca` binary (v1.0.0-preview.1
   or later; it lands in `~/.aca/bin/aca.exe` on Windows). Override the path with
   `SQUAD_ACA_SANDBOX_CLI` if it is somewhere else.
2. **A sandbox group with no managed identity.**
   ```powershell
   aca sandboxgroup create --name sbg-squad-aca --location eastus2 --set-config
   ```
   Do **not** pass `--identity`. The provider asserts the group is identity-free
   and refuses to run if it is not: private-registry pulls use an ACR refresh
   token instead, so an identity would only add an escalation path out of the
   sandbox.
3. **A disk built from the worker image.**
   ```powershell
   az acr login --name <acr> --expose-token         # NOTE: this silently switches
   az account set --subscription <sub>              # the active subscription -- re-assert it
   aca sandboxgroup disk create --image <acr>.azurecr.io/squad-worker:<tag> `
       --name squad-worker --username 00000000-0000-0000-0000-000000000000 --token <acr refresh token>
   aca sandboxgroup disk list -o json               # take the GUID from here
   ```
   `--name` on `disk create` becomes a **label**, not a resolvable name, and
   `--disk` accepts public images only — a private disk must be addressed by
   `--disk-id <GUID>`.
4. **A reviewed class catalog.** `config/sandbox-classes.json` ships with
   `"provisional": true` and placeholder images, egress rules and cost ceilings.
   While it is provisional the sandbox route **fails closed even with the flag
   on** (`reason: catalog-provisional`). An administrator must review the classes,
   set `approved: true` on the ones that are genuinely approved, and set
   `"provisional": false` on the catalog. Nothing else can grant a class: a
   repository's `image.hint` may only select among approved classes.

### Enabling the flag

```powershell
$env:SQUAD_ACA_ENABLE_SANDBOX = "1"     # accepted: 1 / true / yes / on / enabled
squad-aca run "<prompt>"
```

The flag is an environment variable rather than a config key on purpose: it is
per-invocation, nothing that syncs config can turn it on, and rolling back needs
no file edit.

> **What the flag does today.** It opens the route gate — nothing more. No
> `squad-aca` command yet hands the Sprint 2 capability resolution to
> `New-SessionExecutionProvider`, so every dispatch reaches the gate with no
> decision and still runs on ACA Jobs. Turning the flag on therefore changes
> nothing observable yet; the sandbox path becomes reachable when the resolution
> is wired through (PRD #6, Sprint 6+).

### Rollback to ACA Jobs

```powershell
Remove-Item Env:SQUAD_ACA_ENABLE_SANDBOX      # or, as an explicit kill switch:
$env:SQUAD_ACA_ENABLE_SANDBOX = "0"
```

`0`, `false`, `no` and `off` are an explicit kill switch: they win even over a
deployment config that opted in. With the flag off, `New-SessionExecutionProvider`
returns the ACA Jobs adapter before it reads the class catalog, resolves a route,
or looks for `aca` — the control plane behaves exactly as it does with no sandbox
code present, which `scripts/tests/verify-cli-golden.ps1` and
`scripts/tests/compare-cli-baseline.ps1 -BaselineRef main` both check.

Turning the flag off does **not** tear down sandboxes that are already running.
Find and remove them by label:

```powershell
aca sandbox list -o json                       # squad-<session id> is ours
aca sandbox delete -l name=squad-<session> --yes
```

### Operating notes

* `aca sandbox exec` has a hard **~120 s client timeout** and then reports
  `Network issue — retry policy expired`. The sandbox is **unharmed** and the work
  is almost certainly still running. Treat that message as **inconclusive** and
  re-poll — never as a failed session. The provider does exactly this; do the same
  by hand.
* Sessions are launched **detached** and polled. Never try to hold a session open
  with a single `aca sandbox exec`; it will die at the two-minute mark.
* Auto-suspend defaults to **enabled at 600 s**. The provider pins it explicitly
  (1800 s idle, 20 s poll). If you change either by hand, keep the poll interval
  well under the idle timeout or a live session can be suspended between polls.
* Session results are pushed to GitHub by the worker's own run before the session
  reaches a terminal state. The sandbox disk is scratch — never the only copy.
* A `403 CheckAccess` from `aca` that makes no sense is usually
  `az acr login --expose-token` having switched your active subscription. Re-run
  `az account set --subscription <sub>`.

## Rollback and recovery

When a deploy, config change, or session goes wrong, use the ordered recovery
procedures in [rollback.md](rollback.md). They run from least to most disruptive:

1. **Optional .NET/Aspire path** — revert local scaffold changes; no Azure teardown.
2. **ACA Sandboxes** — unset `SQUAD_ACA_ENABLE_SANDBOX` (or set it to `0`) to
   return every dispatch to ACA Jobs, then delete any leftover `squad-*` sandboxes
   as shown above.
3. **ACA worker image / session job** — redeploy the last-known-good image and stop
   failing executions.
4. **Aspire token / secrets** — regenerate the OTLP API key and dashboard browser
   token via `scripts/deploy.ps1`, and rotate GitHub/Copilot tokens with
   `squad-aca secrets rotate`.
5. **Ralph / watch** — `squad-aca ralph pause` and `squad-aca watch stop` to halt
   unattended dispatch without touching the rest of the deployment.
6. **Full resource-group destroy / redeploy** — `squad-aca destroy --yes` then
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
