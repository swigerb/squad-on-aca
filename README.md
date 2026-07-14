# Remote Squad on Azure

Azure Container Apps deployment for running Brady Gaster's Squad remotely while keeping code and Squad state in GitHub.

## What this repo provides

- A `squad-worker` container image with Node.js, Git, GitHub CLI, GitHub Copilot CLI, and `@bradygaster/squad-cli`.
- An Azure Container Apps deployment script for:
  - Aspire Dashboard
  - Manual remote Squad session jobs
  - Long-running Squad watchers
  - Log Analytics
  - Azure Container Registry
- PowerShell scripts to start sessions, run watchers, and inspect status.

## Quick start

```powershell
.\scripts\deploy.ps1
.\scripts\start-session.ps1 -Repository swigerb/remote-squad-azure -Mode smoke -SessionName smoke-001
.\scripts\show-status.ps1
```

See [docs/remote-squad-runbook.md](docs/remote-squad-runbook.md) for the full developer runbook.
