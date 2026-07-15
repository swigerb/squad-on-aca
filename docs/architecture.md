# Architecture

Squad on ACA keeps a clear separation of layers. The default path is a thin ACA
remote-runner / control plane. An **optional** .NET/Aspire integration path can
be layered on top without changing that default.

## Layered model

| Layer | Responsibility | Implementation |
| --- | --- | --- |
| Orchestration | Decide what work runs and coordinate the Squad team | Squad CLI inside the worker (`worker/entrypoint.sh`) |
| Control plane | Dispatch sessions, sync state, inspect runs | `scripts/squad-aca.ps1`, `scripts/*.ps1` |
| Execution substrate | Run each session in isolation | Azure Container Apps Jobs |
| Telemetry sink | Collect logs/traces/metrics | Standalone Aspire Dashboard (default OTLP sink) |
| Resource modeling (optional) | Model resources as code | .NET Aspire AppHost (`aspire/`) |
| Agent abstraction (optional) | Expose a session as an agent | Agent Framework seam (`aspire/.../AgentAbstraction.cs`) |

## Default path (unchanged)

```
Developer / Copilot control plane (local)
        │  squad-aca "<prompt>"  /  scripts/start-session.ps1
        ▼
Azure Container Apps
  ├── caj-squad-aca-session   (manual job: one Squad team per execution)
  ├── caj-squad-aca-ralph     (scheduled job: polls issues, dispatches sessions)
  ├── ca-squad-aca-watch      (optional long-running watcher, scale 0/1)
  └── ca-squad-aca-aspire     (standalone Aspire Dashboard = OTLP sink)
        ▲
        │ OTLP (gRPC 18889 / HTTP 18890, internal-only, ApiKey auth)
Worker container (squad-worker image) emits telemetry
```

- ACA Jobs are the unit of isolation. There is no Kubernetes, Helm, or KEDA.
- The **standalone Aspire Dashboard** is the current default telemetry sink. It
  runs as a Container App with **BrowserToken** UI auth and **ApiKey** OTLP auth.
  OTLP ports are internal to the ACA environment.
- Ralph is a mode of the shared worker image, not a separate image.

See [runbook.md](runbook.md) for resource details and
[feature-parity.md](feature-parity.md) for the mapping to `squad-on-aks`.

## Optional .NET/Aspire integration path

The `aspire/` directory adds an **opt-in** path. It does not replace the ACA
Jobs architecture; it layers on top:

- **Aspire models resources.** The `Squad.Aca.AppHost` project models the Aspire
  Dashboard OTLP sink and the `squad-worker` container as code, so you can run a
  local, telemetry-wired smoke of the worker before dispatching to ACA.
- **Agent Framework exposes the agent abstraction.** `AgentAbstraction.cs`
  defines a compile-safe `ISquadAgent` seam. A real Microsoft Agent Framework
  `AIAgent` adapter implements it by dispatching to ACA. Preview packages are not
  referenced by default to keep restore stable.
- **ACA remains the execution substrate.** Even with the AppHost, production work
  still runs as ACA Job executions.
- **Squad remains the orchestration system.** The AppHost does not orchestrate
  the team; Squad does, inside the worker.

### When to use which

| You want to… | Use |
| --- | --- |
| Deploy and run Squad on ACA | Default path (`scripts/deploy.ps1`, `squad-aca`) |
| Reproduce telemetry locally / model resources as code | Optional AppHost (`aspire/`) |
| Expose a Squad session as an Agent Framework agent | Optional agent seam (`aspire/.../AgentAbstraction.cs`) |

The two paths share the same OTLP auth posture (BrowserToken UI, ApiKey OTLP,
internal-only OTLP ports) and the same worker image.

## Assumptions and prerequisites

See the [README](../README.md#assumptions-and-prerequisites) and
[runbook](runbook.md#assumptions-and-prerequisites) for the full list (Azure CLI,
GitHub CLI, PowerShell, tokens, and — for the optional path — the .NET SDK).
