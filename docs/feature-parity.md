# Feature parity with squad-on-aks

This project is the Azure Container Apps counterpart to the AKS pattern in `tamirdresher/squad-on-aks`.

| `squad-on-aks` feature | ACA equivalent in this repo | Status |
| --- | --- | --- |
| AKS cluster | Azure Container Apps environment | Included |
| Ralph CronJob | Scheduled ACA Job `caj-squad-aca-ralph` with cron `*/5 * * * *`, `parallelism=1`, and a 240-second timeout | Included |
| `concurrencyPolicy: Forbid` | ACA has no exact flag; Ralph is a short dispatcher that exits after starting session jobs, keeping runtime below the 5-minute cadence | Approximate ACA equivalent |
| Agent pods/jobs | ACA manual job executions from `caj-squad-aca-session`; each execution is a full Squad team session pod | Included |
| One pod per work session | `caj-squad-aca-session` starts a new execution per `start-session.ps1` call | Included |
| KEDA scale-to-zero | ACA jobs are zero-cost when idle; watcher app can scale to 0/1 | Included |
| New project bootstrap | `scripts/new-project.ps1` creates/seeds a GitHub repo and starts `SQUAD_MODE=new-project` | Included |
| ACR image build | `az acr build` from `worker/Dockerfile` | Included |
| Managed image pull | User-assigned managed identity with `AcrPull` | Included |
| Kubernetes secrets | ACA secrets | Included |
| Key Vault CSI | Key Vault-backed ACA secret references via `-UseKeyVault` | Included |
| GitHub token auth | `GITHUB_TOKEN`, `GH_TOKEN`, and `COPILOT_GITHUB_TOKEN` wired as secrets | Included |
| Copilot CLI auth | Headless token auth through `COPILOT_GITHUB_TOKEN` | Included |
| GitHub Actions CI/CD | `.github/workflows/deploy-aca.yml` runs `scripts/deploy.ps1` with Azure OIDC login | Included |
| Helm chart | PowerShell deployment scripts and ACA resources | ACA-native replacement |
| KEDA ScaledObject by issue depth | ACA watcher handles issue polling; ACA jobs can be started per issue/session | ACA-native replacement |
| Workload Identity for Key Vault | User-assigned managed identity for ACR pull and optional Key Vault secret reads | Included |
| Prometheus metrics | Aspire/OpenTelemetry dashboard and Log Analytics | ACA-native replacement |
| Kubernetes pod-aware mode | `SQUAD_DEPLOYMENT_MODE=squad-per-pod`, `SQUAD_POD_ID=<session>` | Included |
| SubSquads | `SQUAD_TEAM` passed per session/watch execution | Included |
| GitHub remote session access | Copilot CLI `--remote` default | Included |

## Important differences

- ACA Jobs are the primary unit of isolation. You do not manage Kubernetes pods, Helm, or kubeconfig.
- ACA does not need KEDA for per-session scale-to-zero. A manual job execution starts only when you request a session.
- The scheduled Ralph job is the CronJob equivalent. The watcher app is an optional always-on monitor for teams that prefer continuous watch mode.
- Aspire is hosted as a Container App instead of a local Docker container.

## Aspire: telemetry sink vs. optional AppHost

There are two distinct Aspire concepts in this repo. Keep them separate:

| Concept | What it is | Required? | Where |
| --- | --- | --- | --- |
| Standalone Aspire Dashboard | The default OTLP **sink** deployed as a Container App (`ca-squad-aca-aspire`) with BrowserToken UI auth and ApiKey OTLP auth | Yes (default telemetry path) | `scripts/deploy.ps1` |
| .NET Aspire **AppHost** | An **optional** integration path that models resources as code and can run a local telemetry-wired worker smoke | No (opt-in) | `aspire/` |

The AppHost does not replace the ACA Jobs architecture and does not orchestrate
the Squad team. It layers on top: Aspire models resources, the Agent Framework
seam exposes the agent abstraction, ACA remains the execution substrate, and
Squad remains the orchestration system. See
[architecture.md](architecture.md#optional-netaspire-integration-path).

## Ralph and worker image

Ralph is not a separate container image. The `squad-worker` image contains all runtime tools. Ralph is selected by setting `SQUAD_MODE=ralph`, which polls GitHub issues and starts one `caj-squad-aca-session` execution per actionable issue.

## ACA job model

| ACA job | Trigger | Purpose |
| --- | --- | --- |
| `caj-squad-aca-ralph` | Schedule, every 5 minutes | Ralph poller, equivalent to AKS CronJob |
| `caj-squad-aca-session` | Manual | One full remote Squad team session per execution |
| `ca-squad-aca-watch` | Container App, scale 0/1 | Optional long-running watcher |

Ralph uses the user-assigned managed identity to call Azure and start ACA job executions. The identity receives `AcrPull` for image pulls and `Contributor` on the resource group so it can start session jobs. The broad `Contributor` grant is a documented existing risk; see [validation.md](validation.md#rbac--identity-scope) for a narrower custom-role hardening path.
