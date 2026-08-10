# Squad on ACA runbook

This runbook explains how to deploy and operate Squad on Azure Container Apps.

## Assumptions and prerequisites

- **Azure**: `az` CLI signed in with rights to create resource groups, ACR, Container Apps, user-assigned identities, role assignments, Log Analytics, and optional Key Vault. Select the subscription with `az account set`.
- **GitHub**: `gh` CLI authenticated and `gh auth setup-git` configured. Tokens must support GitHub API work and Copilot CLI headless auth.
- **Local tooling**: PowerShell 5.1+ or PowerShell 7, Git, Node.js/npm. `bash` is needed for worker syntax validation.
- **Telemetry sink**: standalone Aspire Dashboard app `ca-squad-aca-aspire`, with browser-token UI auth, OTLP API-key auth, and internal-only OTLP ports.
- **Optional .NET/Aspire path**: .NET SDK 9.0+ and a .NET 9 runtime. See [../aspire/README.md](../aspire/README.md) and [architecture.md](architecture.md).

## Architecture

| Resource | Purpose |
| --- | --- |
| `<acr-name>` | ACR for the `squad-worker` image. |
| `uai-squad-aca-acrpull` | User-assigned identity used by ACA to pull from ACR and optionally read Key Vault secrets. |
| `cae-squad-aca` | Azure Container Apps environment. |
| `ca-squad-aca-aspire` | Aspire Dashboard with browser-token UI auth and OTLP API-key auth. |
| `caj-squad-aca-session` | Manual ACA job. Every execution is one remote Squad session pod. |
| `caj-squad-aca-ralph` | Scheduled ACA job. Ralph polls every 5 minutes. |
| `ca-squad-aca-watch` | Long-running watcher app for issue-driven unattended work. |
| `law-squad-aca` | Log Analytics workspace for ACA logs. |

## Session model

Every session runs in its own ACA job replica. The worker sets:

```text
SQUAD_DEPLOYMENT_MODE=squad-per-pod
SQUAD_POD_ID=<session name or ACA execution name>
OTEL_SERVICE_NAME=squad-<session name>
```

Dispatch uses a per-execution `az containerapp job start --env-vars` override. It reads the template, strips session-managed keys, overlays fresh session values, and passes a complete execution container spec with image, CPU, and memory.

## Scale-to-zero behavior

| Component | Idle behavior |
| --- | --- |
| `caj-squad-aca-session` | No running replica between executions. |
| `caj-squad-aca-ralph` | No running replica between scheduled polls. |
| `ca-squad-aca-watch` | Can be scaled to zero with `scripts/start-watch.ps1 -Stop`. |
| `ca-squad-aca-aspire` | Kept running by default so the dashboard is reachable. |

## Ralph job runner

`caj-squad-aca-ralph` runs every 5 minutes with:

```text
SQUAD_MODE=ralph
SQUAD_DEPLOYMENT_MODE=squad-per-pod
SQUAD_POD_ID=ralph-scheduled
```

The deployment uses `parallelism=1`, `replicaCompletionCount=1`, and `replicaTimeout=240`.

Ralph polls GitHub issues labeled `squad`, skips blocked/assigned/already-dispatched issues, adds `squad-aca:dispatched` after a confirmed start, and starts `caj-squad-aca-session` with a prompt for that issue.

The user-assigned managed identity has:

```text
AcrPull on the ACR
Container Apps Jobs Operator on the session job (resource-scoped)
```

The grant is reconciled by `deploy.ps1` on each run.

## GitHub remote sessions

Copilot CLI flags are composed per session by `worker/lib/agent-policy.js` from `SQUAD_MODE` and `SQUAD_DISPATCH_SOURCE`.

An attended session gets:

```text
--allow-all-tools --agent squad --remote --no-auto-update --deny-tool <pattern> ...
```

An unattended session also gets `--no-ask-user` and a longer deny list. `--yolo` is not used. `COPILOT_ALLOW_ALL=true` is not set in `worker/Dockerfile`.

Use `COPILOT_GITHUB_TOKEN` or `GH_TOKEN` for Copilot CLI headless auth. Fine-grained PATs with the GitHub Copilot Requests permission are preferred.

## Agent tool policy

Every session resolves a tier before the agent starts.

| Signal | Value | Tier |
| --- | --- | --- |
| `SQUAD_MODE` in `prompt`, `new-project`, `shell`, `smoke`, `telemetry-smoke` and `SQUAD_DISPATCH_SOURCE=local-cli` | A person started the run | `attended` |
| Anything else, including `ralph`, `watch`, `triage`, `loop`, `api`, unrecognised values, or absent `SQUAD_DISPATCH_SOURCE` | Unattended | `autonomous` |

| | attended | autonomous |
| --- | --- | --- |
| `shell(sudo)`, `shell(su)` | denied | denied |
| `shell(chmod)`, `shell(chown)`, `shell(chattr)`, `shell(setfacl)` | denied | denied |
| `shell(git config)`, `shell(gh auth)`, `shell(gh secret)`, `shell(gh variable)` | denied | denied |
| `shell(az)`, `shell(kubectl)`, `shell(terraform)`, `shell(docker)` | allowed | denied |
| `shell(gh api)`, `shell(gh repo delete)`, `shell(gh release delete)` | allowed | denied |
| `--no-ask-user` | no | yes |
| writes outside the checkout | denied | denied |
| writes to a governance path | denied | denied |
| appends to `.squad/agents/<name>/history.md` | allowed, append-only | allowed, append-only |

Governance paths are made read-only before the agent starts and their SHA-256 hashes are recorded outside the checkout:

```text
.squad/policies
.squad/agents
.squad/identity
.squad/config.json
.squad/routing.md
.squad/casting-policy.json
.squad/casting/policy.json
.squad/memory/config.json
.squad/memory/audit.jsonl
.squad/fact-checker/policy.md
.squad/fact-checker/audit-trail.md
.squad/rai/policy.md
.squad/rai/audit-trail.md
```

`.squad/agents/<name>/history.md` is append-only. A `history.md` file that did not exist when the session started cannot be created by the run.

`SQUAD_COPILOT_FLAGS` supports extras such as `--model` or `--log-level`. Permission-widening flags (`--yolo`, `--allow-all`, `--allow-all-paths`, `--add-dir`) abort the session with exit `78`.

Policy output is prefixed `[squad-policy]`. Read it with:

```powershell
.\scripts\logs.ps1
az containerapp job logs
```

Check tier resolution:

```powershell
$env:SQUAD_MODE = "ralph"; $env:SQUAD_DISPATCH_SOURCE = "ralph"
node .\worker\lib\agent-policy.js json
```

Classify governance paths:

```powershell
node .\worker\lib\agent-policy.js classify-governance-path .squad/agents/docs/history.md   # append-only
node .\worker\lib\agent-policy.js classify-governance-path .squad/agents/docs/charter.md   # locked
```

## Deploy

```powershell
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
```

Common defaults:

```text
Location: eastus2
Resource group: rg-squad-aca-dev-eastus2
```

For Key Vault-backed secret references:

```powershell
.\scripts\deploy.ps1 -UseKeyVault -KeyVaultName kv-your-squad-aca
```

Deployment output is written to ignored local file `deploy.outputs.json`.

`deploy.ps1` is idempotent and safe to re-run for upgrades, token rotation, and recovery. The Aspire dashboard app is updated in place with `az containerapp update --yaml`.

## Start a session

### Existing Squad repo

```powershell
cd path\to\existing-squad-repo
squad-aca "Use the existing Squad team to implement the next feature and open a PR"
```

Add `--sync-all` to commit and push the full working tree before dispatch.

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

Configure an existing deployment:

```powershell
squad-aca configure --resource-group <rg> --session-job <job> --subscription <azure-subscription-id>
```

### Session environment variables

Set on the session job by the control plane. Override them when starting a job
by hand.

| Variable | Purpose |
|---|---|
| `SQUAD_MODE` | `prompt`, `new-project`, `loop`, `squad`, `shell`, `smoke`, `telemetry-smoke`, or `ralph`. |
| `SQUAD_PROMPT` | What the session should do. Required by `prompt`. |
| `SESSION_NAME` | Names the run in logs and in the hub. |
| `SQUAD_POD_ID` | Identifies the pod for SubSquad routing. |
| `GITHUB_REPOSITORY` | The `owner/repo` the session works in. |
| `SQUAD_DISPATCH_SOURCE` | Who started the run: `local-cli`, `ralph`, or `actions`. Feeds the tool policy. |
| `SQUAD_COPILOT_FLAGS` | Extra Copilot CLI flags. Cleared on every deploy. |
| `SQUAD_HUB_URL` / `SQUAD_HUB_TOKEN` | Attach the session to a Squad Hub. Both empty turns supervision off. |
| `SQUAD_HUB_ONESHOT` | Run one session, then exit. Used by dispatched cloud runs. |
| `AZURE_RESOURCE_GROUP`, `AZURE_CLIENT_ID`, `ACA_SESSION_JOB_NAME` | Used by `ralph` to start session jobs. |
| `RALPH_LABELS` | Issue labels Ralph dispatches. Default `squad-aca`. |
| `RALPH_MAX_ISSUES` | Issues per Ralph run. Default `3`. |

Developer flow:

```powershell
squad-aca init --owner "<github-owner>" --name "my-app"
squad-aca "Build the first feature and open a PR"
```

Copilot control-plane flow:

```powershell
copilot --agent squad-aca
```

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

`logs` reads console output through the first available path:

1. `az containerapp job logs show`, when the `containerapp` Azure CLI extension is installed.
2. Log Analytics fallback, using `law-squad-aca` or the configured workspace.

Check the active path:

```powershell
squad-aca doctor
```

Install log extensions when needed:

```powershell
az extension add --name containerapp
az extension add --name log-analytics
```

Configure a non-default workspace:

```powershell
squad-aca configure --log-analytics-workspace <workspace-name>
```

Manual Log Analytics query:

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

The Azure identity behind `AZURE_CLIENT_ID` needs rights to create and update resource groups, ACR, Container Apps, managed identities, role assignments, Log Analytics, and optional Key Vault resources.

## ACA Sandboxes (preview, feature-flagged OFF)

`squad-aca` can dispatch a session to Azure Container Apps Sandboxes instead of an ACA Job. ACA Jobs are the default and rollback path. Sandboxes are off by default.

### Prerequisites

1. Install the standalone `aca` CLI v1.0.0-preview.1 or later. It is not an `az` extension. Override the path with `SQUAD_ACA_SANDBOX_CLI`.
2. Create a sandbox group with no managed identity:

```powershell
aca sandboxgroup create --name sbg-squad-aca --location eastus2 --set-config
```

Do not pass `--identity`.

3. Create a disk built from the worker image:

```powershell
az acr login --name <acr> --expose-token
az account set --subscription <sub>
aca sandboxgroup disk create --image <acr>.azurecr.io/squad-worker:<tag> `
    --name squad-worker --username 00000000-0000-0000-0000-000000000000 --token <acr refresh token>
aca sandboxgroup disk list -o json
```

Use the GUID from `aca sandboxgroup disk list -o json` as `sandboxDiskId`.

4. Use a reviewed class catalog at `config/sandbox-classes.json` with `"provisional": false` and pinned `sha256` digests for approved classes.
5. Add sandbox settings to `~/.squad-on-aca/config.json`:

```powershell
squad-aca configure --resource-group <rg> --session-job <job> --subscription <sub>
# then add, by hand, to ~/.squad-on-aca/config.json:
#   "sandboxGroup":  "sbg-squad-aca",
#   "sandboxDiskId": "<GUID from `aca sandboxgroup disk list -o json`>"
```

### Enable the flag

```powershell
$env:SQUAD_ACA_ENABLE_SANDBOX = "1"     # accepted: 1 / true / yes / on / enabled
squad-aca run "<prompt>"
```

With the flag off, a repository that requires a non-default capability is refused with `sandbox-feature-disabled-and-default-insufficient`.

### Credentials

| Plane | Reaches the sandbox? | How |
| --- | --- | --- |
| Control plane (`az`/`aca` login) | No | Stays on the operator machine. |
| Runtime Azure managed identity | No | The sandbox group carries no identity. |
| GitHub (`git` / `gh` push) | Yes | Uploaded as a file with `aca sandbox fs write` into a `0700` state directory. |
| Copilot | Yes | Uploaded file, or native brokerage with `aca sandboxgroup credential create --type github-copilot` when using a fine-grained PAT. |

For local `run`, `squad-aca.ps1` resolves the git token from `SQUAD_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, or `gh auth token`. It resolves the Copilot token from `SQUAD_COPILOT_GITHUB_TOKEN` or `COPILOT_GITHUB_TOKEN`. If no Copilot token is set, the git token serves both planes.

Credential flow:

1. Create the state directory:
   ```text
   aca sandbox exec … -c 'umask 077; mkdir -p <state> && chmod 700 <state> && rm -f <state>/.squad-creds && echo squad-credentials-vault-$(stat -c %a <state>)'
   ```
2. Upload credentials:
   ```text
   aca sandbox fs write --path <state>/.squad-creds --file <local>
   ```
3. Launch sources and removes the file:
   ```text
   if [ -f <state>/.squad-creds ]; then . <state>/.squad-creds; rm -f <state>/.squad-creds; fi
   ```

`aca sandbox exec` does not forward stdin. Use `fs write` for file delivery. Brokerage with `sandboxgroup credential create` reads stdin.

Troubleshooting:

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Refusing to dispatch … no GitHub credential` | No usable git token | Run `gh auth login`, or set `GH_TOKEN`. |
| `Refusing to broker … a classic personal access token` | `--type github-copilot` requires a fine-grained PAT | Set `SQUAD_COPILOT_GITHUB_TOKEN=github_pat_…`. |
| `Refusing to upload credentials … is mode '<x>', not 700` | State directory is not private | Delete the sandbox and retry. |
| Worker log: `Error: No authentication information found` | Credential file did not arrive | Check for `sandbox fs write … .squad-creds` before launch. |
| Worker log: `ProxyResponseError: HTTP 403 … does not appear to originate from GitHub` | Copilot API blocked by egress policy | Allow `*.githubcopilot.com` and `*.githubusercontent.com` in the class template. |

Mint a fine-grained PAT for the Copilot plane:

```powershell
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" `
  -DefaultRepository "<github-owner>/<repo>" `
  -CopilotGitHubToken "<a fine-grained PAT, github_pat_...>"
```

Delete a brokered credential by hand:

```powershell
aca sandboxgroup credential delete --id <credential id> --yes
```

Do not capture output from `aca sandboxgroup credential list`, `aca sandboxgroup credential show`, `aca sandbox egress show`, or `aca sandbox egress export`; they return values. Use `aca sandbox egress decisions -l name=squad-<session> -o json` for the audit trail.
### Concurrency, cost, and cleanup

Stop a sandbox session:

```powershell
squad-aca stop <session>
```

Sandbox stop reports one of these tokens:

| Token | Meaning | What to do |
| --- | --- | --- |
| `killed` / `already-dead` / `already-terminal` | Success | Nothing |
| `no-pidfile` | No pid was recorded | Delete the sandbox: `aca sandbox delete -l name=<name> --yes` |
| `bad-pidfile` | Pid file is unusable | Delete the sandbox |
| `not-ours` | Pid is alive but not the worker entrypoint | Delete the sandbox |
| `kill-failed` | Signal was rejected | Delete the sandbox |
| `survived` | Worker did not stop | Delete the sandbox |
| `no-proc` / `scan-failed` | `/proc` could not be read | Delete the sandbox |

A sandbox bills from creation until it is deleted. Auto-suspend stops the meter but does not delete the sandbox.

Required controls:

1. Every class in `config/sandbox-classes.json` declares `limits.maxConcurrentSandboxes`.
2. The provider sets auto-suspend explicitly: 1800 s idle, 20 s poll.
3. Every sandbox is labelled `squad-<session id>`.

Run the reaper:

```powershell
. .\scripts\lib\providers\squad-sandbox-provider.ps1
$ctx = (New-SandboxExecutionProvider -Class $class -SandboxGroup sbg-squad-aca).Context
Invoke-SquadSandboxReaper -Context $ctx
Invoke-SquadSandboxReaper -Context $ctx -KeepSessionIds @('<live session>') -Delete
```

Or clean up by hand:

```powershell
aca sandbox list -o json
aca sandbox delete -l name=squad-<session> --yes
```

Failure tags:

```text
[squad-sandbox:auth]
[squad-sandbox:capability]
[squad-sandbox:quota]
[squad-sandbox:readiness]
[squad-sandbox:execution]
[squad-sandbox:transport]
[squad-sandbox:config]
```

### Roll back to ACA Jobs

```powershell
Remove-Item Env:SQUAD_ACA_ENABLE_SANDBOX
$env:SQUAD_ACA_ENABLE_SANDBOX = "0"
```

`0`, `false`, `no`, and `off` are explicit off values. Turning the flag off does not delete running sandboxes.

Find and remove running sandboxes:

```powershell
aca sandbox list -o json
aca sandbox delete -l name=squad-<session> --yes
```

### Operating notes

- Treat `Network issue — retry policy expired` from `aca sandbox exec` as inconclusive and re-poll.
- Launch sessions detached and poll them. Do not hold a session open with one `aca sandbox exec`.
- Keep the lifecycle poll interval below the idle timeout.
- Session results are pushed to GitHub by the worker before terminal state. The sandbox disk is scratch.
- If `az acr login --expose-token` changes the active subscription, run `az account set --subscription <sub>` again.

### Add or re-pin a sandbox class image

1. Build the image:

```powershell
az account set --subscription 3898b8ea-c676-4b43-95fc-d38425627d74
az acr build --registry acrsquadacah81u42kq `
  --image "squad-worker-python:<tag>" worker/images/python
az acr repository show --name acrsquadacah81u42kq `
  --image "squad-worker-python:<tag>" --query digest -o tsv
```

2. Edit `config/sandbox-classes.json`: set `image.reference`, `image.tag`, `image.digest`, `image.pinned: true`, and `tools[]`.

3. Verify live and record evidence:

```powershell
pwsh -NoProfile -File .\scripts\verify-image-tools.ps1 -ClassId sandbox-python-3-12
```

Useful switches:

| Switch | Effect |
| --- | --- |
| `-ClassId <id>` | Which class to verify. Required. |
| `-AdditionalTools a,b` | Probe extra tools beyond the declared list. |
| `-KeepDisk` | Leave the disk behind for reuse by real sessions. |
| `-DiskLabel <name>` | Reuse or create a disk under a specific label. |

4. Confirm the offline check and gates:

```powershell
node worker\lib\verify-image-evidence.js
pwsh -NoProfile -File .\scripts\validate.ps1
```

5. Commit the evidence file with the catalog change.

Cleanup after an interrupted probe:

```powershell
$aca = "C:\Users\<you>\.aca\bin\aca.exe"
$c = @("-s", "<sub>", "-g", "rg-squad-aca-dev-eastus2", "--sandbox-group", "sbg-squad-aca")
& $aca @c sandbox list -o json
& $aca @c sandbox delete --id <sandbox id> --yes
& $aca @c sandboxgroup disk list -o json
& $aca @c sandboxgroup disk delete --id <disk id>
```

Global `aca` options such as `--sandbox-group` must come before the subcommand. `sandbox delete` prompts unless `--yes` is passed.

## Rollback and recovery

Use [rollback.md](rollback.md) for ordered recovery procedures:

1. Optional .NET/Aspire path.
2. ACA Sandboxes.
3. ACA worker image / session job.
4. Aspire token / secrets.
5. Ralph / watch.
6. Full resource-group destroy / redeploy.

## Dispatch leases

Every dispatch writes a durable lease before it asks Azure for compute. See [architecture.md#unified-dispatch-contract-and-durable-leases](architecture.md#unified-dispatch-contract-and-durable-leases).

Leases live in the same repository on orphan ref `squad-aca-leases`, one JSON blob per lease under `leases/`. Dispatch requires `contents: write`.

### Inspect leases

```powershell
squad-aca leases
squad-aca leases list --repo owner/repo
```

Read the ledger directly:

```powershell
gh api repos/OWNER/REPO/contents/leases?ref=squad-aca-leases --jq '.[].name'
gh api repos/OWNER/REPO/contents/leases/issue-42.json?ref=squad-aca-leases --jq '.content' | base64 -d
```

### Clear a stuck lease

1. Confirm nothing is running:

```powershell
squad-aca sessions
```

Stop any live execution first:

```powershell
squad-aca stop <session>
```

2. Sweep:

```powershell
squad-aca leases sweep
```

The sweeper uses `SQUAD_LEASE_TTL_SECONDS`, default 1 hour. Ralph sweeps automatically at the start of every run.

3. Re-dispatch the work. A reclaimed lease is repairable.

4. Delete a corrupt blob only when the ledger itself is corrupt:

```powershell
gh api -X DELETE repos/OWNER/REPO/contents/leases/issue-42.json `
  -f message="clear corrupt lease" -f branch=squad-aca-leases -f sha=<blob-sha>
```

If a sweep errors, check auth, RBAC, throttling, network, and `contents: write`.

### 404 on a lease write

If a lease write fails with `gh: Not Found (HTTP 404)`, check the active GitHub identity. GitHub can report a write denial on a readable repository as 404.

```powershell
gh auth status
gh api user --jq .login
gh api repos/OWNER/REPO --jq .permissions
```

Switch to an account with write access:

```powershell
gh auth switch --user <account-with-write-access>
```

`squad-aca doctor` reports both `GitHub auth` and `GitHub push`.

## Who can run Squad on ACA

A run costs money and executes an agent with a token that can write to the
repository, so every route is gated on repository access.

| Route | Who can use it |
|---|---|
| Apply the `squad-aca` label to an issue | Collaborators with **Triage** or above |
| Comment `/squad-aca <instruction>` or `@squad-on-aca-control-plane <instruction>` | **Owner, organisation member, or collaborator** |
| Run the workflow manually | Collaborators with **Write** or above |
| Ralph's poll | Only picks up issues that already carry the label |

**To let somebody run it: add them in Settings → Collaborators and teams.** Any
role works, including Read. Removing them revokes it immediately.

`CONTRIBUTOR` is **not** a permission and is **not** accepted. GitHub reports it
for anyone who has ever had a commit merged, which on a public repository is
anybody who once landed a pull request; they have no access. The thing you grant
is a **collaborator**.

Squad Hub grants nothing here. Its **Start a new ACA job…** action writes a
GitHub URL and opens it; the request is created by the person's own GitHub
account, and this repository decides whether it runs. Someone added to Squad Hub
cannot run jobs here unless you also add them to this repository.

Full detail: [actions-trigger.md](actions-trigger.md#who-may-trigger-a-run).

## Operational safeguards

- Use separate GitHub and Copilot tokens when your policy requires separation.
- Use `-UseKeyVault` for Key Vault-backed Container Apps secrets.
- Keep `deploy.outputs.json` private. It contains deployment outputs and tokens. It is gitignored with `.azure/` and `.env`.
- Keep `.squad/` in the target GitHub repo when you want Squad memory and team state to travel with code.
- The user-assigned managed identity holds `AcrPull` on the registry and `Container Apps Jobs Operator` scoped to the session job.
- Every mode except `ralph` has `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` removed before the agent starts.
- OTLP auth modes are `BrowserToken` for UI and `ApiKey` for OTLP. OTLP ports stay internal to the ACA environment.
- `squad-aca sync --sync-all` blocks obvious secret files and inline tokens before staging. Override only for known-private repos with `SQUAD_ACA_ALLOW_UNSAFE_SYNC=1`.
- Run `scripts/validate.ps1` before pushing.

