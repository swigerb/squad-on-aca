# Feature parity with squad-on-aks

This project is the Azure Container Apps counterpart to the AKS pattern in `tamirdresher/squad-on-aks`.

| `squad-on-aks` feature | ACA equivalent in this repo | Status |
| --- | --- | --- |
| AKS cluster | Azure Container Apps environment | Included |
| Ralph CronJob | Long-running watcher app, plus manual job executions for sessions | Included |
| Agent pods/jobs | ACA manual job executions | Included |
| One pod per work session | `caj-squad-aca-session` starts a new execution per `start-session.ps1` call | Included |
| KEDA scale-to-zero | ACA jobs are zero-cost when idle; watcher app can scale to 0/1 | Included |
| ACR image build | `az acr build` from `worker/Dockerfile` | Included |
| Managed image pull | User-assigned managed identity with `AcrPull` | Included |
| Kubernetes secrets | ACA secrets | Included |
| Key Vault CSI | Key Vault-backed ACA secret references via `-UseKeyVault` | Included |
| GitHub token auth | `GITHUB_TOKEN`, `GH_TOKEN`, and `COPILOT_GITHUB_TOKEN` wired as secrets | Included |
| Copilot CLI auth | Headless token auth through `COPILOT_GITHUB_TOKEN` | Included |
| GitHub Actions CI/CD | Not required for local deploy; scripts are CI-friendly | Scripted, not workflowed |
| Helm chart | PowerShell and ACA resources | ACA-native replacement |
| KEDA ScaledObject by issue depth | ACA watcher handles issue polling; ACA jobs can be started per issue/session | ACA-native replacement |
| Workload Identity for Key Vault | User-assigned managed identity for ACR pull and optional Key Vault secret reads | Included |
| Prometheus metrics | Aspire/OpenTelemetry dashboard | ACA-native replacement |
| Kubernetes pod-aware mode | `SQUAD_DEPLOYMENT_MODE=squad-per-pod`, `SQUAD_POD_ID=<session>` | Included |
| SubSquads | `SQUAD_TEAM` passed per session/watch execution | Included |
| GitHub remote session access | Copilot CLI `--remote` default | Included |

## Important differences

- ACA Jobs are the primary unit of isolation. You do not manage Kubernetes pods, Helm, or kubeconfig.
- ACA does not need KEDA for per-session scale-to-zero. A manual job execution starts only when you request a session.
- The watcher app is intentionally separate from one-shot session jobs. Use it for unattended issue processing after smoke tests pass.
- Aspire is hosted as a Container App instead of a local Docker container.
