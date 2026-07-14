# Remote Squad on Azure Container Apps

This runbook explains how to run Brady Gaster's Squad remotely on Azure Container Apps, keep code in GitHub, and monitor sessions in the Aspire Dashboard.

## Architecture

The deployment creates:

| Resource | Purpose |
| --- | --- |
| Azure Container Registry | Stores the `squad-worker` image. |
| Azure Container Apps environment | Hosts the dashboard, one-shot sessions, and watchers. |
| Aspire dashboard container app | Shows OpenTelemetry traces and metrics for all remote sessions. |
| Manual Container Apps job | Starts isolated one-shot Squad sessions on demand. |
| Watcher container app | Runs long-lived `squad watch --execute` loops for a repository or SubSquad. |
| Log Analytics workspace | Stores Container Apps logs. |

Each session clones a GitHub repository, initializes Squad if needed, activates a SubSquad when requested, and runs in one of four modes:

| Mode | Use |
| --- | --- |
| `smoke` | Validate GitHub, Squad CLI, and optional Copilot auth. |
| `prompt` | Run one non-interactive `copilot -p ... --agent squad` session. |
| `loop` | Run `squad loop` from a `loop.md` prompt. |
| `watch` | Run `squad watch --execute` against GitHub issues. |

## Authentication model

The worker uses two Azure Container Apps secrets:

| Secret | Used by |
| --- | --- |
| `github-token` | `git`, `gh`, issue and PR operations. |
| `copilot-github-token` | GitHub Copilot CLI. |

Copilot CLI supports `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, and `GITHUB_TOKEN` for headless automation. A fine-grained PAT with the GitHub "Copilot Requests" permission is preferred. GitHub CLI OAuth tokens are also supported by Copilot CLI.

Aspire is deployed with browser-token authentication for the UI and API-key authentication for OTLP. The login URL is written to `deploy.outputs.json` as `aspireLoginUrl`; do not commit that file.

## Deploy

From this repo on a machine with Azure CLI and GitHub CLI authenticated:

```powershell
.\scripts\deploy.ps1
```

The script targets subscription `3898b8ea-c676-4b43-95fc-d38425627d74` by default and creates:

```text
rg-squad-remote-dev-eastus
cae-squad-remote
ca-squad-remote-aspire
caj-squad-remote-session
ca-squad-remote-watch
```

Deployment output is written to `deploy.outputs.json`.

## Start a one-shot remote session

Run a smoke test:

```powershell
.\scripts\start-session.ps1 `
  -Repository swigerb/remote-squad-azure `
  -Mode smoke `
  -SessionName smoke-001
```

Run a Copilot-backed smoke test:

```powershell
.\scripts\start-session.ps1 `
  -Repository swigerb/remote-squad-azure `
  -Mode smoke `
  -RunCopilotSmoke `
  -SessionName copilot-smoke-001
```

Run a one-shot Squad prompt:

```powershell
.\scripts\start-session.ps1 `
  -Repository swigerb/your-repo `
  -Mode prompt `
  -SessionName docs-fix-001 `
  -Prompt "Use Squad to inspect the repo and propose the smallest documentation improvement. Do not push changes."
```

To let the session create a branch and PR when it changes files:

```powershell
.\scripts\start-session.ps1 `
  -Repository swigerb/your-repo `
  -Mode prompt `
  -SessionName docs-fix-001 `
  -Prompt "Fix the README quickstart typo and add a test or validation note." `
  -PushChanges `
  -OutputBranch squad/docs-fix-001
```

## Start a watcher

Watchers are for GitHub issue-driven work. Label issues with `squad` or `squad:*`.

```powershell
.\scripts\start-watch.ps1 `
  -Repository swigerb/your-repo `
  -IntervalMinutes 5 `
  -TimeoutMinutes 45 `
  -MaxConcurrent 1
```

Stop the watcher:

```powershell
.\scripts\start-watch.ps1 -Repository swigerb/your-repo -Stop
```

## Run SubSquads remotely

Commit `.squad/streams.json` to your target repository:

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

Start separate remote sessions:

```powershell
.\scripts\start-session.ps1 -Repository swigerb/your-repo -Mode smoke -SubSquad platform -SessionName platform-smoke
.\scripts\start-session.ps1 -Repository swigerb/your-repo -Mode smoke -SubSquad docs -SessionName docs-smoke
```

Start a SubSquad watcher:

```powershell
.\scripts\start-watch.ps1 -Repository swigerb/your-repo -SubSquad docs -IntervalMinutes 5
```

## Monitor sessions

Show Azure status:

```powershell
.\scripts\show-status.ps1
```

Open the Aspire dashboard from the `aspireLoginUrl` in `deploy.outputs.json`. Each session sets `OTEL_SERVICE_NAME` to `squad-<session-name>`, so traces and metrics are grouped by session or watcher.

## Operational notes

- Container Apps jobs are the safest way to run multiple isolated sessions. Start one execution per task.
- Use watchers for unattended issue processing only after smoke tests pass.
- Keep `.squad/` committed in each target repository when you want Squad knowledge to travel with the code.
- Use SubSquads to prevent remote sessions from competing for the same issue labels.
- Treat the GitHub and Copilot tokens as production credentials. Rotate them if they are copied outside Azure secrets.
