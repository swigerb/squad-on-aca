# Squad on Azure Container Apps

<p align="center">
  <img src="docs/images/squad-on-aca-logo.jpg" alt="Squad on Azure Container Apps logo" width="320">
</p>

Run Brady Gaster's Squad on Azure Container Apps (ACA): one isolated ACA job execution per Squad session, GitHub-hosted code and state, GitHub remote session access, and centralized Aspire telemetry.

## What you get

| Capability | ACA implementation |
| --- | --- |
| One Squad team per remote session | Manual ACA job execution (`caj-squad-aca-session`) |
| Ralph scheduler | Scheduled ACA job (`caj-squad-aca-ralph`) polls every 5 minutes and starts ACA session jobs |
| Pod/container mode | `SQUAD_DEPLOYMENT_MODE=squad-per-pod` and `SQUAD_POD_ID=<session>` by default |
| GitHub `/remote` session access | Copilot CLI runs with `--remote` by default |
| GitHub-backed code | Each session clones `owner/repo`, works in an isolated workspace, and can push a branch/PR |
| Monitoring | Standalone Aspire Dashboard on ACA as the default OTLP sink, with OTLP API-key auth and browser-token UI auth |
| Unattended work | ACA watcher app running `squad watch --execute` |
| Secure image pulls | ACR plus user-assigned managed identity |
| Token storage | ACA secrets by default; optional Key Vault references with `-UseKeyVault` |
| Second execution plane (opt-in preview) | ACA Sandboxes behind `SQUAD_ACA_ENABLE_SANDBOX`, for per-session isolation and default-deny egress. Off by default; ACA Jobs stay the default and the rollback path |
| CI/CD | GitHub Actions workflow with Azure OIDC login |

## Quick start

```powershell
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
.\scripts\squad-aca.ps1 install-command
```

Open a new terminal after `install-command`, then from any repo:

```powershell
squad-aca init --owner "<github-owner>" --name "my-app"
squad-aca "Build the first feature and open a PR"
```

Or use GitHub Copilot:

```powershell
copilot --agent squad-aca
```

The local Copilot session becomes the control plane. The actual Squad team runs in ACA.

## Assumptions and prerequisites

Before deploying or dispatching, this project assumes:

- **Azure**: an Azure subscription and `az` CLI signed in (`az login`), with rights
  to create resource groups, ACR, Container Apps, managed identities, role
  assignments, Log Analytics, and (optionally) Key Vault.
- **GitHub**: `gh` CLI authenticated (`gh auth login`) and `gh auth setup-git`
  configured, plus a token valid for Copilot CLI headless auth. A separate
  `COPILOT_GITHUB_TOKEN` is supported when your policy requires token separation.
- **Local tooling**: PowerShell 5.1+ (Windows PowerShell or PowerShell 7), Git,
  and Node.js/npm for the Squad and Copilot CLIs. `bash` (Git Bash or WSL) is
  needed only to run the worker entrypoint syntax check in `scripts/validate.ps1`.
- **Telemetry**: the current default OTLP sink is a **standalone Aspire Dashboard**
  running as a Container App. It uses browser-token UI auth and OTLP API-key auth;
  the OTLP ports are internal to the ACA environment.
- **Optional .NET/Aspire path**: the `aspire/` scaffold additionally requires the
  .NET SDK 9.0+ and a .NET 9 runtime. It is opt-in and not needed for the default
  ACA flow. See [aspire/README.md](aspire/README.md).

Deployment writes secrets/tokens to the local, gitignored `deploy.outputs.json`;
keep it private and never commit it.

Useful control-plane commands:

```powershell
squad-aca doctor            # validate local repo, GitHub, Azure, ACA, and Aspire config
squad-aca sessions          # list recent ACA-hosted Squad sessions
squad-aca logs <session>    # stream logs for a session name or execution id
squad-aca stop <session>    # stop a running ACA session
squad-aca open <session>    # open the session PR when available, otherwise Aspire
squad-aca sync              # push local .squad state before dispatch
squad-aca watch status      # inspect optional watcher app
squad-aca ralph status      # inspect scheduled Ralph dispatcher
squad-aca subsquad list     # list configured SubSquads
squad-aca telemetry smoke   # emit known-good logs/traces/metrics to Aspire
```

## Existing Squad repo flow

If you already have a repo with `.squad/` initialized:

```powershell
cd path\to\existing-squad-repo
squad-aca "Use the existing Squad team to implement the next feature and open a PR"
```

Before dispatching, `squad-aca`:

1. Verifies the ACA session job exists.
2. Verifies `.squad/team.md` exists locally.
3. Commits and pushes `.squad` state plus the `squad-aca` agent file if needed.
4. Starts `caj-squad-aca-session` against the current GitHub repo and branch.

If ACA has not been deployed or configured, it stops with a deploy/configure message instead of failing later in Azure.

To point the command at an existing ACA deployment:

```powershell
squad-aca configure --resource-group <rg> --session-job <job> --subscription <azure-subscription-id>
```

To include all local working-tree changes, not just Squad state, add `--sync-all`.

## Direct script quick start

If you do not want to install the `squad-aca` command:

```powershell
.\scripts\start-session.ps1 -Repository "<github-owner>/<repo>" -Mode smoke -RunCopilotSmoke -SessionName smoke-001
.\scripts\show-status.ps1
```

Open the Aspire login URL from `deploy.outputs.json` to see traces and logs grouped by `squad-<session-name>`.

## Scale-to-zero model

Squad on ACA is job-first, so most compute is zero when idle:

| Component | Scales to zero? | Notes |
| --- | --- | --- |
| Session jobs (`caj-squad-aca-session`) | Yes | A job execution starts for a Squad session, then exits. No idle replica remains. |
| Ralph (`caj-squad-aca-ralph`) | Yes between runs | A scheduled job wakes every 5 minutes, dispatches work, then exits. |
| Watcher (`ca-squad-aca-watch`) | Yes when stopped | The optional watcher app is configured for 0/1 replicas. |
| Aspire (`ca-squad-aca-aspire`) | No, by default | Kept at 1 replica so the dashboard is always available. Set it to 0 only if you are comfortable restarting it before viewing telemetry. |

ACA does not need KEDA for per-session scale-to-zero. ACA Jobs already provide the same cost shape as Kubernetes Jobs: no execution, no running agent pod.

## Run a Squad session

Simple command:

```powershell
squad-aca "Use Squad to implement issue #123. Create a branch and PR."
```

Explicit script command:

```powershell
.\scripts\start-session.ps1 `
  -Repository "<github-owner>/<repo>" `
  -Mode prompt `
  -SessionName feature-123 `
  -Prompt "Use Squad to implement issue #123. Create a branch and PR." `
  -PushChanges `
  -OutputBranch squad/feature-123
```

Each execution schedules a new ACA job replica, sets `SQUAD_POD_ID=feature-123`, enables GitHub remote control, and exports telemetry to Aspire.

## Start without an existing repo

Use the new-project helper. It creates a GitHub repo with an initial default branch, then starts a remote Squad bootstrap session:

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

The helper starts `SQUAD_MODE=new-project`, which initializes Squad state in the ACA session and opens a bootstrap PR from a `squad/bootstrap-*` branch.

## Ralph versus worker image

The worker image contains Node.js, Azure CLI, GitHub CLI, Copilot CLI, and Squad CLI. Ralph is not the image; Ralph is a scheduled job mode in that image. `caj-squad-aca-ralph` runs `SQUAD_MODE=ralph` every 5 minutes, polls GitHub issues, marks actionable issues as dispatched, and starts new `caj-squad-aca-session` executions as the agent pods.

## Run a watcher

```powershell
squad-aca status
.\scripts\start-watch.ps1 -Repository "<github-owner>/<repo>" -IntervalMinutes 5
```

Label work with `squad` or `squad:*`. For SubSquads, commit `.squad/streams.json` and pass `-SubSquad docs` or another stream name.

## Production secrets

Use Key Vault-backed Container Apps secrets:

```powershell
.\scripts\deploy.ps1 -UseKeyVault -KeyVaultName kv-your-squad-aca
```

## Optional .NET / Aspire integration path

`squad-aca` stays a thin ACA remote-runner / control plane. For teams that want
to model resources as code or expose a session as an agent, the repo includes an
**optional, opt-in** .NET/Aspire scaffold under [`aspire/`](aspire/). It does not
replace the ACA Jobs architecture:

- **Aspire** models resources (the standalone Aspire Dashboard OTLP sink and the
  `squad-worker` container).
- **Agent Framework** exposes the Squad session as an agent abstraction (a
  compile-safe seam; preview packages are not referenced by default).
- **ACA** remains the production execution substrate.
- **Squad** remains the orchestration system.

```powershell
cd aspire
dotnet build .\Squad.Aca.sln
cd Squad.Aca.AppHost
dotnet run   # brings up the Aspire Dashboard OTLP sink locally
```

See [aspire/README.md](aspire/README.md) and [docs/architecture.md](docs/architecture.md).

## Validation

Run the static validation gate before pushing:

```powershell
.\scripts\validate.ps1            # PS parse, worker bash -n, secret scan, scaffold check
.\scripts\validate.ps1 -RunDotnet # also build the optional aspire scaffold
```

See [docs/validation.md](docs/validation.md) for the full sprint/E2E checklist and
security validation steps (OTLP auth, exposure, RBAC, secret scans, token
separation, rotation, public sync guard, image pinning).

The worker's capability-aware preflight has its own dependency-free test suite.
When `bash` and `node` are available, run it directly:

```bash
bash worker/tests/run-tests.sh   # parser + preflight unit/integration tests
node --check worker/lib/parse-capabilities.js
```

The same suite runs in CI via [`.github/workflows/worker-tests.yml`](.github/workflows/worker-tests.yml).

## Capability-aware execution

Repositories can commit a `squad-capabilities.yml` manifest declaring the
tools, credentials, services, and egress a session needs. A preflight step runs
after clone and before Squad/Copilot starts, failing fast with an actionable
error when a required tool or credential is missing instead of failing mid-task.
The manifest never carries shell commands, and the check adds no network, RBAC,
or egress. See [docs/capability-manifest.md](docs/capability-manifest.md) for the
manifest contract, built-in allowlists, security posture, and configuration.

The manifest also produces a deterministic routing decision — run on the default
ACA job, run on an approved sandbox class, or fail closed. ACA Sandboxes are the
execution plane that decision can route to, and they are described next.

## ACA Sandboxes (opt-in preview)

**Azure Container Apps Sandboxes** are a second execution plane alongside ACA
Jobs, not a replacement. ACA Jobs remain the unconditional default and the
rollback path. Sandboxes are a public preview with no SLA, so the plane is off
by default and stays off until you turn it on for a specific invocation.

### What it does today

Enabling the flag opens the route gate and nothing more. No `squad-aca` command
yet passes the capability resolution to `New-SessionExecutionProvider`, so every
dispatch reaches the gate with no decision and routes to `aca-job`. Turning the
flag on changes nothing observable yet. Wiring the resolution through is later
work, so do not plan real sessions on this plane.

### How to enable it

```powershell
$env:SQUAD_ACA_ENABLE_SANDBOX = "1"     # accepted: 1 / true / yes / on / enabled
squad-aca run "<prompt>"
```

The flag is an environment variable rather than a config key on purpose: it is
per-invocation, nothing that syncs config can turn it on, and rolling back needs
no file edit. `0`, `false`, `no`, and `off` are an explicit kill switch.

### Two independent fail-closed interlocks

Both must be open before a dispatch can reach a sandbox, so clearing either one
returns every dispatch to ACA Jobs:

1. **The feature flag defaults off.** With it unset, `New-SessionExecutionProvider`
   returns the ACA Jobs adapter before it reads the class catalog, resolves a
   route, or looks for the `aca` binary.
2. **The class catalog ships provisional.** `config/sandbox-classes.json` sets
   `"provisional": true` with placeholder images, egress rules, and cost
   ceilings, so the sandbox route fails closed **even with the flag on**
   (`reason: catalog-provisional`). An administrator must review each class,
   pin real image references, and set `"provisional": false`.

### Why the plane exists

Sandboxes give a session two properties the ACA Jobs plane does not have:

- **Per-session isolation.** Each session gets its own sandbox rather than a
  replica of a shared, fixed worker image.
- **Default-deny, capability-scoped egress.** A class declares
  `defaultAction: Deny` plus an allowlist, applied before any repository code
  runs. Feasibility testing measured allowlisted hosts returning `200`,
  non-allowlisted hosts returning `403`, and raw non-HTTP TCP refused, with an
  auditable allow/deny trail from `aca sandbox egress decisions`.

### Prerequisites

- **The standalone `aca` CLI.** Sandboxes are not driven by `az`; there is no
  `az containerapp sandbox` command.
- **A sandbox group with no managed identity.** Identity on ACA Sandboxes is
  group-scoped with no per-sandbox opt-out, so a group carrying one would let
  sandboxed code mint control-plane tokens. The provider verifies the group is
  identity-free and refuses to create a sandbox if it cannot prove that.

### Where to go next

- [docs/runbook.md](docs/runbook.md#aca-sandboxes-preview-feature-flagged-off) —
  [prerequisites](docs/runbook.md#prerequisites),
  [credentials](docs/runbook.md#credentials-four-planes-kept-separate),
  [concurrency, cost and orphans](docs/runbook.md#concurrency-cost-and-orphans),
  [rollback](docs/runbook.md#rollback-to-aca-jobs), and the
  [incident runbook](docs/runbook.md#incident-runbook).
- [docs/architecture.md](docs/architecture.md#aca-sandboxes-provider-feature-flagged-default-off) —
  the provider boundary, the route gate, and the security invariants.
- [docs/rollback.md](docs/rollback.md#2-aca-sandboxes-feature-flagged-preview) —
  the rollback procedure and its verification checklist.
- [docs/adr/0001-aca-sandboxes-feasibility.md](docs/adr/0001-aca-sandboxes-feasibility.md) —
  the feasibility evidence and the decision to adopt the plane as opt-in.

## Security notes

- The user-assigned managed identity currently holds **Contributor** on the
  resource group so Ralph can start session job executions. This is broader than
  strictly required and is documented as an existing risk with a custom-role
  hardening path in [docs/validation.md](docs/validation.md#rbac--identity-scope).
- OTLP auth is preserved: **BrowserToken** for the UI and **ApiKey** for OTLP,
  never `Unsecured`. OTLP ports stay internal to the ACA environment.
- `squad-aca sync --sync-all` runs a public repo secret guard that blocks obvious
  secret files and inline tokens before staging.

See [docs/runbook.md](docs/runbook.md), [docs/rollback.md](docs/rollback.md), [docs/architecture.md](docs/architecture.md), and [docs/feature-parity.md](docs/feature-parity.md).
