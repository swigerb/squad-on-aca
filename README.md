# Squad on Azure Container Apps

Run Brady Gaster's Squad on Azure Container Apps (ACA): one isolated ACA job execution per Squad session, GitHub-hosted code and state, GitHub remote session access, and centralized Aspire telemetry.

## What you get

| Capability | ACA implementation |
| --- | --- |
| One Squad team per remote session | Manual ACA job execution (`caj-squad-aca-session`) |
| Pod/container mode | `SQUAD_DEPLOYMENT_MODE=squad-per-pod` and `SQUAD_POD_ID=<session>` by default |
| GitHub `/remote` session access | Copilot CLI runs with `--remote` by default |
| GitHub-backed code | Each session clones `owner/repo`, works in an isolated workspace, and can push a branch/PR |
| Monitoring | Aspire Dashboard on ACA with OTLP API-key auth and browser-token UI auth |
| Unattended work | ACA watcher app running `squad watch --execute` |
| Secure image pulls | ACR plus user-assigned managed identity |
| Token storage | ACA secrets by default; optional Key Vault references with `-UseKeyVault` |

## Quick start

```powershell
.\scripts\deploy.ps1
.\scripts\start-session.ps1 -Repository swigerb/squad-on-aca -Mode smoke -RunCopilotSmoke -SessionName smoke-001
.\scripts\show-status.ps1
```

Open the Aspire login URL from `deploy.outputs.json` to see traces and logs grouped by `squad-<session-name>`.

## Run a Squad session

```powershell
.\scripts\start-session.ps1 `
  -Repository swigerb/your-repo `
  -Mode prompt `
  -SessionName feature-123 `
  -Prompt "Use Squad to implement issue #123. Create a branch and PR." `
  -PushChanges `
  -OutputBranch squad/feature-123
```

Each execution schedules a new ACA job replica, sets `SQUAD_POD_ID=feature-123`, enables GitHub remote control, and exports telemetry to Aspire.

## Run a watcher

```powershell
.\scripts\start-watch.ps1 -Repository swigerb/your-repo -IntervalMinutes 5
```

Label work with `squad` or `squad:*`. For SubSquads, commit `.squad/streams.json` and pass `-SubSquad docs` or another stream name.

## Production secrets

Use Key Vault-backed Container Apps secrets:

```powershell
.\scripts\deploy.ps1 -UseKeyVault -KeyVaultName kv-your-squad-aca
```

See [docs/runbook.md](docs/runbook.md) and [docs/feature-parity.md](docs/feature-parity.md).
