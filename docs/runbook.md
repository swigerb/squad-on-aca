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

Copilot CLI flags are **not** a fixed string any more. They are composed per session by `worker/lib/agent-policy.js` from `SQUAD_MODE` and `SQUAD_DISPATCH_SOURCE` — see [Agent tool policy](#agent-tool-policy) below. An attended session gets:

```text
--allow-all-tools --agent squad --remote --no-auto-update --deny-tool <pattern> ...
```

and an unattended one additionally gets `--no-ask-user` and a longer deny list.

`--yolo` is no longer used anywhere. It expanded to `--allow-all-tools --allow-all-paths --allow-all-urls`, which meant a remote session could write outside its checkout while the same agent on a developer's machine could not — remote execution applying *weaker* policy than local. `COPILOT_ALLOW_ALL=true` has likewise been removed from `worker/Dockerfile`.

`--remote` enables GitHub web/mobile remote access for running sessions. Use a `COPILOT_GITHUB_TOKEN` or `GH_TOKEN` that is valid for Copilot CLI headless auth. Fine-grained PATs with the GitHub "Copilot Requests" permission are preferred; GitHub CLI OAuth tokens are also supported by Copilot CLI.

## Agent tool policy

Every session resolves a **tier** before any agent starts. The tier decides which tools the agent may use; a separate filesystem guard decides which paths it may write.

### Which tier a session gets

| Signal | Value | Tier |
| --- | --- | --- |
| `SQUAD_MODE` ∈ `prompt`, `new-project`, `shell`, `smoke`, `telemetry-smoke` **and** `SQUAD_DISPATCH_SOURCE` = `local-cli` | a person just typed a command | `attended` |
| anything else — `ralph`, `watch`, `triage`, `loop`, any `api` dispatch, any unrecognised value, **or an absent `SQUAD_DISPATCH_SOURCE`** | nobody is watching | `autonomous` |

The default is `autonomous`. "Nobody said who started this" is not evidence that a human did.

### What each tier permits

Both tiers get `--allow-all-tools` (the CLI documents it as required for non-interactive mode) and both are confined to the checkout, because `--allow-all-paths` is no longer passed. Denial rules take precedence over `--allow-all-tools` in the Copilot CLI, so the deny list is what actually bounds the session.

| | attended | autonomous |
| --- | --- | --- |
| `shell(sudo)`, `shell(su)` | denied | denied |
| `shell(chmod)`, `shell(chown)`, `shell(chattr)`, `shell(setfacl)` | denied | denied |
| `shell(git config)`, `shell(gh auth)`, `shell(gh secret)`, `shell(gh variable)` | denied | denied |
| `shell(az)`, `shell(kubectl)`, `shell(terraform)`, `shell(docker)` | allowed | **denied** |
| `shell(gh api)`, `shell(gh repo delete)`, `shell(gh release delete)` | allowed | **denied** |
| `--no-ask-user` (cannot block on a prompt) | no | **yes** |
| writes outside the checkout | denied | denied |
| writes to a governance path | denied | denied |
| appends to `.squad/agents/<name>/history.md` | allowed (append-only) | allowed (append-only) |

Destructive infrastructure verbs are **unavailable** to an unattended run rather than approval-gated, because there is no one to approve them. On an attended run they remain available and are gated by the human who started it.

### Governance paths

These are made read-only before the agent starts and their SHA-256 hashes are recorded outside the checkout:

`.squad/policies`, `.squad/agents`, `.squad/identity`, `.squad/config.json`, `.squad/routing.md`, `.squad/casting-policy.json`, `.squad/casting/policy.json`, `.squad/memory/config.json`, `.squad/memory/audit.jsonl`, `.squad/fact-checker/policy.md`, `.squad/fact-checker/audit-trail.md`, `.squad/rai/policy.md`, `.squad/rai/audit-trail.md`

The set is identical for both tiers.

#### The one exclusion: agent history is append-only, not locked

`.squad/agents/<name>/history.md` is **excluded from the write lock**, so an autonomous run *can* append to its own work log. Nothing else under `.squad/agents/` is excluded — in particular `.squad/agents/<name>/charter.md` stays locked, because a charter defines what an agent is *permitted to do* and is squarely governance.

The reasoning, recorded here so the exception is not later mistaken for an oversight and "fixed" back:

- `history.md` is an **append-only work log**, not policy. It records what an agent *did*; it grants an agent nothing.
- Locking it therefore prevents **no** privilege escalation. What it does prevent is the run recording what it did — it destroys the audit trail PRD #6 explicitly asks for ("every lifecycle event is correlated by one stable session/run ID", and auditability generally).
- Ralph and Watch are autonomous by definition. "A human can write it up afterwards" is not available on exactly the paths where the record matters most.

Excluded from the *lock* does **not** mean excluded from the *check*. A path that neither layer covers is a foothold, so history stays in the integrity manifest under a different rule:

| | locked governance paths | `.squad/agents/<name>/history.md` |
| --- | --- | --- |
| Mode bits | `a-w` | `u+w` on the **file only** |
| Containing directory | `a-w` | `a-w` — unchanged |
| Manifest line | `file <path> <sha256>` | `append-only <path> <sha256> <bytes>` |
| Rule at verification | must be byte-identical | may **grow**; the first `<bytes>` bytes must still hash to `<sha256>` |
| A permitted change | none | logged as `Agent history appended (permitted): … +N bytes` |
| Truncation / rewrite / deletion | exit 78 | exit 78 |

Two consequences worth knowing before you file a bug about them:

- **The agent directory does not open.** Hardening runs `chmod -R a-w` over `.squad/agents` *first*, then puts `u+w` back on the matching files. `chmod` on a file needs ownership, not write permission on its parent, so `.squad/agents/<name>/` stays mode-locked and still refuses `creat()` and `unlink()`. A run can append to `history.md`; it cannot create a file beside it, delete one, add a new agent directory, or touch `charter.md`.
- **A run may append to history, not mint it.** A `history.md` that did not exist when the session started is a *new governance file* and fails the session, exactly like any other. If you add an agent, seed its `history.md` in the same reviewed PR that adds its charter.

Nothing else changed: an autonomous session still cannot write `.squad/policies`, `.squad/identity`, `.squad/config.json`, `.squad/routing.md`, or any memory/approval/audit state. Record decisions in the issue, the PR, or `.squad/decisions.md` as before.

### Operator extras

`SQUAD_COPILOT_FLAGS` still works for genuine extras such as `--model` or `--log-level`. A permission-widening flag in it (`--yolo`, `--allow-all`, `--allow-all-paths`, `--add-dir`) **aborts the session with exit 78** rather than being silently ignored — a silently dropped escalation attempt looks identical to a working one from the caller's side.

### Diagnosing a run blocked by policy

All policy output is prefixed `[squad-policy]` in the session log (`.\scripts\logs.ps1` or `az containerapp job logs`).

**Exit code 78** always means "policy could not be applied, or was violated". The session did not push.

| Log line | Cause | Fix |
| --- | --- | --- |
| `Agent policy library not found at …` | the image predates this change, or the Dockerfile `COPY` lost `lib/squad-policy.sh` | rebuild and redeploy the worker image |
| `SQUAD_COPILOT_FLAGS contains permission-widening flag(s): …` | an old job template still injects `--yolo` | redeploy with `scripts/deploy.ps1`, which explicitly clears the variable; `az containerapp job update --set-env-vars` merges, so the old value survives until something sets it empty |
| `node is not available` / `sha256sum is not available` | the image is missing a base tool | rebuild from `worker/Dockerfile` |
| `Could not create a private policy state directory outside the checkout` | `$HOME` is unset or unwritable in the container | check the job's user and `HOME`; the baseline must not live inside the repository |
| `GOVERNANCE VIOLATION: a protected path changed during this session` | the agent modified a governance file | the following `+`/`-` lines name the exact files; nothing was pushed. Make the change yourself in a reviewed PR |
| `GOVERNANCE VIOLATION: protected path(s) changed in commits made during this session` | the change was committed rather than left in the working tree | same — the commit is still local to the dead container |
| `GOVERNANCE VIOLATION: … was REWRITTEN, not appended to` | the run edited or truncated an agent's `history.md` instead of appending to it | history is append-only; the bytes recorded before the session started must still be there. Re-run appending, or make the edit yourself in a reviewed PR |
| `GOVERNANCE VIOLATION: the work log … did not exist when this session started` | the run created a `history.md` for an agent that had none | a session may append to history, not mint it. Seed the file in the PR that adds the agent |
| `Agent history appended (permitted): … +N bytes` | informational — the audit trail grew by `N` bytes and the prior content is intact | none; this is the exclusion working as intended |
| `Permission denied` writing under `.squad/` in agent output | the agent tried to edit governance state | expected; the agent should route the change through a PR |
| `NOT enforced on this path: shell(git config) …` | informational, on `squad watch` / `squad loop` only | see the limitation note below; governance enforcement is unaffected |

To see the tier a session chose without running it:

```powershell
$env:SQUAD_MODE = "ralph"; $env:SQUAD_DISPATCH_SOURCE = "ralph"
node .\worker\lib\agent-policy.js json
```

To ask whether a specific path is locked or append-only — the same question the worker asks, from the same resolver:

```powershell
node .\worker\lib\agent-policy.js classify-governance-path .squad/agents/security/history.md   # append-only
node .\worker\lib\agent-policy.js classify-governance-path .squad/agents/security/charter.md   # locked
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
4. **A reviewed class catalog.** `config/sandbox-classes.json` is reviewed and
   pinned: `"provisional": false`, and every `approved: true` class names an
   immutable `sha256` digest. An approved class without a pinned digest is a
   **catalog fault**, not a warning — `validateCatalog` rejects the whole
   catalog, and every route fails closed until it is fixed. Setting
   `"provisional": true` again fails every sandbox route closed even with the
   flag on (`reason: catalog-provisional`), which is the supported way to
   withdraw the plane without a code change. Nothing else can grant a class: a
   repository's `image.hint` may only select among approved classes, and the
   catalog deliberately retains one unapproved class so the approved-only filter
   is exercised.
5. **`sandboxGroup` and `sandboxDiskId` in `~/.squad-on-aca/config.json`.**
   These travel from configuration to the Sandboxes provider by name. Without a
   group the provider cannot complete its identity-free precondition and refuses
   to create; without a disk id it refuses to dispatch (`--disk` accepts public
   images only).

   ```powershell
   squad-aca configure --resource-group <rg> --session-job <job> --subscription <sub>
   # then add, by hand, to ~/.squad-on-aca/config.json:
   #   "sandboxGroup":  "sbg-squad-aca",
   #   "sandboxDiskId": "<GUID from `aca sandboxgroup disk list -o json`>"
   ```

### Enabling the flag

```powershell
$env:SQUAD_ACA_ENABLE_SANDBOX = "1"     # accepted: 1 / true / yes / on / enabled
squad-aca run "<prompt>"
```

The flag is an environment variable rather than a config key on purpose: it is
per-invocation, nothing that syncs config can turn it on, and rolling back needs
no file edit.

> **What the flag does today (issue #25).** It makes the plane reachable.
> `squad-aca run` reads `squad-capabilities.yml` from your working tree before
> requesting any compute, resolves it through the shared Node routing core, and
> dispatches to the plane the decision names. A repository an approved sandbox
> class satisfies runs in a sandbox; `sessions`, `logs`, and `stop` then address
> it there, recovered from the execution handle rather than re-resolved.
>
> A repository with **no manifest**, or one the **default worker image already
> satisfies**, still runs on ACA Jobs — byte for byte. ACA Jobs remain the
> default and the rollback path.
>
> With the flag **off**, a repository that genuinely requires a non-default
> capability is **refused** (`sandbox-feature-disabled-and-default-insufficient`),
> not quietly run on the default worker. Turning the flag off is a kill switch,
> not a downgrade switch.
>
> **Diagnosing a route.** `squad-aca run` prints the sandbox name and the fact
> that default-deny egress was applied. If a dispatch you expected to sandbox
> went to ACA Jobs, look for a `Capability routing read no manifest for ...`
> warning: it names exactly why no manifest was consulted (usually `--repo`
> naming a repository other than the working tree you ran from). If a dispatch
> is refused, the message names the route gate's reason verbatim.

### Credentials (four planes, kept separate)

PRD #6 requires four credential planes that never collapse into one. What
actually reaches a sandbox, and how:

| Plane | Reaches the sandbox? | How |
| --- | --- | --- |
| Control plane (your `az`/`aca` login) | **Never** | Stays on the operator's machine. Nothing in the sandbox can mint it. |
| Runtime Azure (managed identity) | **Absent by design** | The group carries no identity, so in-sandbox token minting fails closed (`unauthorized_client`). See R1 below. |
| GitHub (git / `gh` push) | Yes | **Uploaded as a file** with `aca sandbox fs write` into a `0700` state directory; the launch command sources it and deletes it. In no argument vector. |
| Copilot | Yes | Same uploaded file (its own `export COPILOT_GITHUB_TOKEN=` line), **or** the platform's native brokerage — `aca sandboxgroup credential create --type github-copilot` with the token on **stdin**, then `aca sandbox create --credential <opaque id>` — when you supply a fine-grained PAT. |

Neither token is ever a CLI argument, an environment variable in the launch
command, or a value this tool prints. On Linux an argument vector is world-
readable at `/proc/<pid>/cmdline` for the life of the process, which is why
"we redact it in our logs" is not sufficient.

#### How credentials actually reach a sandbox session

Four `aca` calls, in this order, before the worker is launched:

1. **Where the tokens come from.** For a local `run`, `squad-aca.ps1` resolves
   the **git plane** from `SQUAD_GITHUB_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN`,
   and falls back to `gh auth token`. It resolves the **Copilot plane** only
   from `SQUAD_COPILOT_GITHUB_TOKEN` or `COPILOT_GITHUB_TOKEN`; if neither is
   set, the git token serves both planes and the CLI says so on stdout. If no
   token can be found at all, the run is **refused up front** — before any
   sandbox exists, so nothing is billed. (ACA Jobs are unaffected: they still
   receive `secretref:` pointers from the deployment secret store, and the
   dispatcher never holds those values.)
2. **Vault.** `aca sandbox exec … -c 'umask 077; mkdir -p <state> && chmod 700
   <state> && rm -f <state>/.squad-creds && echo squad-credentials-vault-$(stat
   -c %a <state>)'`. The provider parses that mode and **refuses to upload**
   unless it is exactly `700` — see the note below.
3. **Upload.** The tokens are written to a short-lived local file under
   `~/.squad-on-aca/.credstage/` (ACL-locked to the current user before any byte
   is written), uploaded with `aca sandbox fs write --path <state>/.squad-creds
   --file <local>`, and the local file is deleted in a `finally` — including
   when the upload fails.
4. **Launch.** The launch command begins `if [ -f <state>/.squad-creds ]; then
   . <state>/.squad-creds; rm -f <state>/.squad-creds; fi`, so the tokens exist
   only in the worker's environment. `New-SandboxLaunchCommand` **throws** if
   any of `GH_TOKEN`, `GITHUB_TOKEN` or `COPILOT_GITHUB_TOKEN` appears in the
   environment it is asked to build.

**Why the directory is 0700 and the file is 0644.** `aca sandbox exec` runs as
the unprivileged session user, but `aca sandbox fs write` uploads as **root**
with mode `0644`, and the session user cannot `chmod` a root-owned file
(`Operation not permitted`). The containing directory is therefore the only
access control available, so the provider verifies it is `0700` and refuses
rather than placing a token somewhere world-readable. The session user *can*
still `rm` the file, because unlink depends on directory write permission and
the state directory is not sticky — which is what makes source-then-remove work.

**`aca sandbox exec` does not forward stdin.** Piping into it delivers an empty
stream to the remote command (`"hello" | aca sandbox exec -c 'read X; echo
"[$X]"'` prints `[]`). Any credential design that relies on `exec` stdin will
fail live with a bare exit 1 and no error output. `fs write` is the supported
path. Brokerage (`sandboxgroup credential create`) *does* read stdin and is
unaffected.

#### Diagnosing a credential failure

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Refusing to dispatch … no GitHub credential` at dispatch time, no sandbox created | Neither `SQUAD_GITHUB_TOKEN`/`GH_TOKEN`/`GITHUB_TOKEN` nor `gh auth token` produced a token | `gh auth login`, or set `GH_TOKEN` |
| `Refusing to broker … a classic personal access token` | A `ghp_`/`gho_`/`ghs_` token was nominated for `--type github-copilot` | Mint a fine-grained PAT and set `SQUAD_COPILOT_GITHUB_TOKEN=github_pat_…` |
| `Refusing to upload credentials … is mode '<x>', not 700` | The state directory was not private | Usually a stale sandbox or a changed image `umask`; delete the sandbox and retry |
| Worker log: `Error: No authentication information found` | The credential never arrived — check that a `sandbox fs write … .squad-creds` call preceded the launch | This is the Sprint 8 defect; if it reappears, `New-SessionExecutionProvider` has stopped passing `WorkerSecrets` |
| Worker log: `ProxyResponseError: HTTP 403 … does not appear to originate from GitHub` | The credential is fine; **egress** is blocking the Copilot API | The class egress template must allow `*.githubcopilot.com` and `*.githubusercontent.com` |

Inside a live sandbox, the useful checks are `ls -la /tmp/squad-session`
(the directory must be `drwx------` and `.squad-creds` must be **gone** after
launch) and an argv sweep that cannot match itself:

```bash
P=$(printf "%s_" gho); for f in /proc/[0-9]*/cmdline; do \
  tr "\0" " " < "$f" | grep -q "$P" && echo "LEAK: $f"; done; echo done
```

**The classic-token footgun.** `--type github-copilot` accepts only a
**fine-grained** PAT (`github_pat_`) and rejects a classic `ghp_` token. But
`gh auth token` returns a **classic** token, and `scripts/deploy.ps1` defaults
`-CopilotGitHubToken` to the **same value** as `-GitHubToken` — so the single
most likely input is exactly the one the platform rejects, and the two
credential planes are one token unless you pass `-CopilotGitHubToken`
explicitly. Mint a fine-grained PAT for the Copilot plane:

```powershell
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" `
  -DefaultRepository "<github-owner>/<repo>" `
  -CopilotGitHubToken "<a fine-grained PAT, github_pat_...>"
```

The provider refuses a classic token **before** it calls the CLI, so a
mis-scoped token is never transmitted or written to a service-side log.

**Revoking a brokered credential.** Credentials are created on the **group**
and inherit group RBAC, so they outlive the sandbox that used them. `terminate`
and `cancel` revoke them automatically and warn loudly if a revocation fails. By
hand:

```powershell
aca sandboxgroup credential delete --id <credential id> --yes
```

Do **not** run `aca sandboxgroup credential list` / `show` or
`aca sandbox egress show` / `export` while capturing a transcript: they return
the **values**. The provider refuses to run them at all for that reason.
`aca sandbox egress decisions -l name=squad-<session> -o json` is the safe
audit trail (timestamp, host, method, path, scheme, `matchedRule`).

### Concurrency, cost and orphans

A sandbox bills from creation until it is deleted; auto-suspend stops the meter
but does **not** delete. Three controls, all of which must be present:

1. **A per-class ceiling.** Every class in `config/sandbox-classes.json` must
   declare `limits.maxConcurrentSandboxes`. A class without one is a
   **configuration error**, not an unbounded budget — dispatch refuses with
   `[squad-sandbox:quota]`/`[squad-sandbox:config]` before anything is created.
2. **Pinned auto-suspend.** The platform default is enabled at 600 s, which
   would suspend a live session; the provider sets it explicitly (1800 s idle,
   20 s poll).
3. **A label-based reaper.** Every sandbox is labelled `squad-<session id>`,
   which is what makes "is this ours?" decidable. Dry run first — it never
   deletes without `-Delete`, and never deletes a sandbox whose age it cannot
   establish:
   ```powershell
   . .\scripts\lib\providers\squad-sandbox-provider.ps1
   $ctx = (New-SandboxExecutionProvider -Class $class -SandboxGroup sbg-squad-aca).Context
   Invoke-SquadSandboxReaper -Context $ctx                          # dry run
   Invoke-SquadSandboxReaper -Context $ctx -KeepSessionIds @('<live session>') -Delete
   ```
   Or by hand: `aca sandbox list -o json`, then
   `aca sandbox delete -l name=squad-<session> --yes`.

Failures are tagged so they can be told apart:
`[squad-sandbox:auth]`, `[squad-sandbox:capability]`, `[squad-sandbox:quota]`,
`[squad-sandbox:readiness]`, `[squad-sandbox:execution]`,
`[squad-sandbox:transport]`, `[squad-sandbox:config]`. Quota is classified
**before** auth deliberately: several services return `403` for a quota refusal,
and reading "you have hit your ceiling" as "your credentials are bad" sends an
operator to rotate a perfectly good token.

The inverse mistake is worse, so numeric status codes are **never** matched as
bare substrings. Azure decorates auth failures with correlation, object and
trace GUIDs, and a GUID such as `1b8f429c-…` contains `429`; matching that would
tag a rotated-out credential `[squad-sandbox:quota]` — "a ceiling was hit, retry
later" — and an unattended dispatcher would then retry a credential fault
indefinitely. A code only counts when it is delimited by something that is
neither alphanumeric nor a hyphen (`HTTP 429`, `(403)`, `status=401,`), which no
GUID occurrence ever is. `[squad-sandbox:transport]` wins over everything: our
own client give-up (exit `124`, "timed out after 120s") is not a verdict about
the sandbox.

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

### Adding or re-pinning a sandbox class image

A class's `tools[]` list in `config/sandbox-classes.json` is a **claim about a
specific image digest**, and `worker/lib/verify-image-evidence.js` refuses to let
that claim ship unbacked. The full procedure, in order:

**1. Build the image.** Extend the published worker — a sandbox worker still
needs `entrypoint.sh`, the capability preflight and `/usr/local/lib/squad-on-aca/*`.
Build server-side; no local Docker is required.

```powershell
az account set --subscription 3898b8ea-c676-4b43-95fc-d38425627d74
az acr build --registry acrsquadacah81u42kq `
  --image "squad-worker-python:<tag>" worker/images/python
az acr repository show --name acrsquadacah81u42kq `
  --image "squad-worker-python:<tag>" --query digest -o tsv
```

`worker/images/python/Dockerfile` is the worked example. Its build-time smoke
test is the first gate: the build fails if Python 3.12, the Node toolchain, or
any Squad library is missing.

**2. Edit the catalog.** Set the class's `image.reference`, `image.tag`,
`image.digest` and `image.pinned: true`, and write the `tools[]` you believe the
image provides. Do not guess — the next step will contradict you if you do.

**3. Verify live and record the evidence.** This is the only step that observes
what is actually inside the image. It creates a real disk and sandbox, so it
costs money and must clean up after itself (it does, by default).

```powershell
pwsh -NoProfile -File .\scripts\verify-image-tools.ps1 -ClassId sandbox-python-3-12
```

The script acquires an ACR pull token, creates a disk from the pinned digest,
boots a probe sandbox, runs `command -v` for every declared tool plus a control
set, captures `--version` strings, and writes
`config/image-evidence/<digest-with-':'-replaced-by-'-'>.json`. It deletes the
probe sandbox unconditionally and the probe disk unless `-KeepDisk` is passed.

Useful switches:

| Switch | Effect |
| --- | --- |
| `-ClassId <id>` | Which class to verify. Required. |
| `-AdditionalTools a,b` | Probe extra tools beyond the declared list, so `absent` records a real MISS list, not just a pass. Use `-Command` form: `pwsh -NoProfile -Command "& .\scripts\verify-image-tools.ps1 -ClassId x -AdditionalTools jq,make"`. |
| `-KeepDisk` | Leave the disk behind for reuse by real sessions. Record the disk id. |
| `-DiskLabel <name>` | Reuse or create a disk under a specific label. |

**If a declared tool comes back MISS, fix the claim or fix the image — never the
evidence.** Editing an evidence file by hand to make a check pass reintroduces
exactly the defect this mechanism exists to catch.

**4. Confirm the offline check agrees**, and run the gates:

```powershell
node worker\lib\verify-image-evidence.js
pwsh -NoProfile -File .\scripts\validate.ps1
```

**5. Commit the evidence file with the catalog change.** They are a pair. A
catalog edit without its evidence file fails CI; an evidence file for a digest
nothing pins is harmless but pointless.

**What CI proves versus what this procedure proves.** GitHub Actions cannot pull
a private ACR image, so CI proves only the bookkeeping: that evidence exists for
the digest pinned *today*, is well formed, names the pinned image reference, and
covers every declared tool. Because the evidence filename is derived from the
digest, re-pinning without re-running step 3 fails offline — which is the point.
Only step 3 observes image contents. And neither replaces the in-worker
capability preflight, which still runs in every session and is the final check.

**Cleanup obligation.** Probe sandboxes and disks cost money. The script cleans
up its own; if it is interrupted, sweep by hand:

```powershell
$aca = "C:\Users\<you>\.aca\bin\aca.exe"
$c = @("-s", "<sub>", "-g", "rg-squad-aca-dev-eastus2", "--sandbox-group", "sbg-squad-aca")
& $aca @c sandbox list -o json                 # probe-<digest prefix> is ours
& $aca @c sandbox delete --id <sandbox id> --yes
& $aca @c sandboxgroup disk list -o json       # evidence-<digest prefix>
& $aca @c sandboxgroup disk delete --id <disk id>
```

Two `aca` CLI details that bite here: global options such as `--sandbox-group`
must come **before** the subcommand, and `sandbox delete` **prompts** unless
`--yes` is passed — an unattended delete without it silently leaves the sandbox
running. The script passes `--yes` and then re-lists to confirm nothing it
created survived; a `LEAKED probe sandbox(es) still present` warning means sweep
by hand with the commands above.

### Incident runbook

Risk IDs are from [adr/0001-aca-sandboxes-feasibility.md](adr/0001-aca-sandboxes-feasibility.md).
Every one of these is **live-verified behaviour**, not speculation.

#### R1 — managed identity is group-scoped, with no per-sandbox opt-out

*Symptom:* a sandbox can mint Azure tokens, or you discover the group was
created with `--identity`.

*Why it matters:* identity is a property of the **group**. There is no way to
give one sandbox an identity and withhold it from another, so a single
identity-bearing group turns every sandbox in it into an escalation path.
`IDENTITY_ENDPOINT` and `IDENTITY_HEADER` are injected into every sandbox
**regardless** — misleading but inert while the group has no identity (raw IMDS
returns empty and minting fails `unauthorized_client`).

*Response:*
1. Stop dispatching: `Remove-Item Env:SQUAD_ACA_ENABLE_SANDBOX`.
2. Delete every `squad-*` sandbox in the group (see the reaper above). Assume
   anything they could reach with that identity was reachable.
3. Create a **new** group with no `--identity` and rebuild the disk there.
   Do not try to strip the identity from the existing group and reuse it.
4. Review the identity's role assignments for what was actually exposed.

The provider asserts the group is identity-free before every dispatch and
refuses to run otherwise, and refuses to issue any `aca` command carrying
`--identity`. This incident should therefore only arise from out-of-band
changes.

#### R2 — egress and credential values are readable to anyone with group read access

*Symptom:* a person or a CI job with read access to the sandbox group runs
`aca sandboxgroup credential list` or `aca sandbox egress show`.

*Why it matters:* brokered credentials live on the **group**, not the sandbox,
and inherit group RBAC. Group read is effectively credential read.

*Response:*
1. Treat every credential brokered on that group as exposed. Revoke:
   ```powershell
   aca sandboxgroup credential delete --id <id> --yes
   ```
   (`terminate`/`cancel` do this automatically; do it by hand for anything they
   reported as **unrevoked**.)
2. Rotate the upstream tokens — revoking the brokered copy does not invalidate
   the GitHub/Copilot PAT it was minted from:
   ```powershell
   squad-aca secrets rotate --github-token <new> --copilot-token <new fine-grained PAT>
   ```
3. Audit group RBAC and remove read access that does not need to exist.

*Prevention:* keep the sandbox group in its own resource group with a minimal
reader set. This tool never reads those values back; the readback subcommands
are refused outright so they cannot reach a session log or a CI transcript.

#### R3 — `trafficInspection: Full` means TLS interception

*Symptom:* none — this is a standing property of the approved classes.

*Why it matters:* enforcing an allowlist on **hostnames and paths** requires
terminating TLS. The inspecting proxy is therefore **inside the trust
boundary** and sees plaintext request bodies, including anything the worker
sends to GitHub. This is a deliberate trade: default-deny egress is worth more
than end-to-end confidentiality to an already-allowlisted host. Say so out loud
before anyone puts a third party's data through a sandbox.

*Response if the proxy is believed compromised:* treat every credential and every
request body that transited it as exposed — follow R2 step 1–2, and rotate any
secret the worker sent to an allowed host. Sessions cannot be made safe
retroactively by narrowing egress.

*If a workload cannot accept interception,* do not run it in a sandbox: keep it
on ACA Jobs, where there is no inspecting proxy (and no egress control either —
that is the trade, in the other direction).

#### R7 — orphan sandboxes

*Symptom:* `aca sandbox list -o json` shows `squad-*` sandboxes with no live
session; unexplained spend.

*Why it matters:* an orchestrator that dies between `create` and `terminate`
leaves a sandbox behind with nothing tracking it. Auto-suspend stops the meter
for an **idle** sandbox but never deletes it, and a sandbox whose worker is
still looping is never idle.

*Response:*
1. `Invoke-SquadSandboxReaper -Context $ctx` — dry run, lists candidates.
2. Cross-check the candidate labels against `squad-aca sessions`.
3. `Invoke-SquadSandboxReaper -Context $ctx -KeepSessionIds @(<live ids>) -Delete`.
4. Revoke any credentials that belonged to the orphans (R2 step 1) — deleting a
   sandbox does **not** delete the group-scoped credentials it referenced.

Run the dry run on a schedule; it is read-only and cheap.

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

## Dispatch leases

Every dispatch — local CLI, Ralph, or Watch — writes a durable **lease** before
it asks Azure for compute. The lease is the record of who owns a piece of work,
which route was chosen, and whether that work is still alive. See
[architecture.md](architecture.md#unified-dispatch-contract-and-durable-leases)
for the model.

**Where it lives.** In this repository, on an orphan ref named
`squad-aca-leases`, one JSON blob per lease under `leases/`. It is off the
default branch, so it never appears in a PR diff and never triggers CI.

**Prerequisite.** Dispatch now needs `contents: write` on the repository (a
GitHub token with `repo` scope, or a fine-grained token granting *Contents:
Read and write*). Without it, dispatch **fails closed** rather than running
unleased work. This is a new requirement as of Sprint 6.

### Inspect leases

```powershell
squad-aca leases                      # list every lease for the current repo
squad-aca leases list --repo owner/repo
```

Each row shows the lease key, state, resolved route, dispatcher source, session
id, start time and last heartbeat. `squad-aca sessions` shows `Route` and
`Source` alongside each execution.

You can also read the ledger directly:

```powershell
gh api repos/OWNER/REPO/contents/leases?ref=squad-aca-leases --jq '.[].name'
gh api repos/OWNER/REPO/contents/leases/issue-42.json?ref=squad-aca-leases --jq '.content' | base64 -d
```

### Clear a stuck lease

A lease is "stuck" when work is not running but the lease still reads
`claimed`, `dispatched` or `running` — usually a dispatcher that died between
claiming and starting compute, or a worker killed before it could write its
terminal state.

1. **Confirm nothing is actually running.**

   ```powershell
   squad-aca sessions
   ```

   If an execution is genuinely alive, stop it first: `squad-aca stop <session>`.

2. **Sweep.** This is the supported route and is safe to run at any time.

   ```powershell
   squad-aca leases sweep
   ```

   The sweeper reclaims only leases whose heartbeat has aged out past the TTL
   (`SQUAD_LEASE_TTL_SECONDS`, default 1 hour) and leaves live ones alone. It is
   idempotent: running it twice reclaims nothing the second time. Ralph sweeps
   automatically at the start of every run.

3. **Re-dispatch.** A reclaimed lease is *repairable*, not retired — the next
   dispatch of the same work adopts it and starts cleanly. You do not need to
   delete anything.

4. **Only if the ledger itself is corrupt**, delete the blob by hand:

   ```powershell
   gh api -X DELETE repos/OWNER/REPO/contents/leases/issue-42.json `
     -f message="clear corrupt lease" -f branch=squad-aca-leases -f sha=<blob-sha>
   ```

   Deleting a lease is always safe from an idempotency standpoint — a missing
   lease is treated as "gone", which is a SUCCESS — but you lose the audit trail
   for that piece of work.

**If a sweep errors, do not ignore it.** Auth, RBAC, throttling and network
failures are surfaced deliberately and never reported as a clean sweep. A
failing sweep almost always means the token lost `contents: write`.

### `404 Not Found` on a lease write, and the multi-account hazard

If a dispatch fails like this:

```
Cannot claim a dispatch lease: the shared dispatch core exited 1.
squad-dispatch: Lease store could not create the 'squad-aca-leases' base commit:
'gh' exited 1 and the failure is not 'already gone or already terminal'.
gh: Not Found (HTTP 404) {"message":"Not Found", ... "status":"404"}
```

the repository almost certainly exists and you can almost certainly read it.
**GitHub reports a write denial on a repository you can only read as
`404 Not Found`, not `403 Forbidden`** — it will not confirm that a resource you
cannot write to is there. So a bare 404 on a lease write means *this identity
cannot write here* far more often than it means *this thing is missing*.

The usual cause is that **more than one GitHub account is authenticated and `gh`
is using the active one**, which may not be the account that owns the
repository. `gh` picks the active account for every call; nothing warns you that
it is the wrong one.

Since the fix for [#22](https://github.com/swigerb/squad-on-aca/issues/22), a 404
on a lease write is followed by one permission probe and the message says so
directly:

```
... The authenticated gh identity (read-only-bot) has push=false on owner/repo.
GitHub reports a write denial on a readable repository as 404 Not Found.
Run 'gh auth status' and select an account with write access.
```

The probe runs only on an already-failing path, and if the probe itself fails
the original message is reported unchanged.

**Check it directly:**

```powershell
gh auth status                                   # which account is ACTIVE?
gh api user --jq .login                          # who is gh actually acting as?
gh api repos/OWNER/REPO --jq .permissions        # {"admin":..,"push":..,"pull":..}
```

`push: false` is the answer. Switch account and re-run:

```powershell
gh auth switch --user <account-with-write-access>
```

**`squad-aca doctor` checks this for you.** It reports two separate rows:

| Row | Means |
| --- | --- |
| `GitHub auth` | `gh auth status` succeeded — *some* account is signed in |
| `GitHub push` | the **active** identity's `push` permission on this repository |

`GitHub auth ok` on its own does not mean dispatch will work; `GitHub push` is
the row that answers that. It reports `unknown` rather than guessing when the
permission cannot be read.

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
