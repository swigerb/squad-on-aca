# Architecture

Squad on ACA keeps a clear separation of layers. The default path is a thin ACA
remote-runner / control plane. An **optional** .NET/Aspire integration path can
be layered on top without changing that default.

## Layered model

| Layer | Responsibility | Implementation |
| --- | --- | --- |
| Orchestration | Decide what work runs and coordinate the Squad team | Squad CLI inside the worker (`worker/entrypoint.sh`) |
| Control plane | Dispatch sessions, sync state, inspect runs | `scripts/squad-aca.ps1`, `scripts/*.ps1` |
| Execution provider | Provider-neutral session lifecycle (create/wait/status/logs/cancel/terminate) | `scripts/lib/squad-aca-provider.ps1`, `scripts/lib/providers/*.ps1` |
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

## Execution provider boundary

The control plane no longer talks to an execution substrate directly. Everything
that starts, watches, or stops a session goes through a **provider seam**:

```
scripts/squad-aca.ps1            control plane / CLI
        │  dispatch request  (provider-neutral, PRD #6 shape)
        ▼
scripts/lib/squad-aca-provider.ps1        the contract
        │  create / wait / status / logs / cancel / terminate
        ├── scripts/lib/providers/squad-aca-job-provider.ps1   (production: ACA Jobs)
        └── scripts/lib/providers/squad-fake-provider.ps1      (offline tests)
```

### The contract

| Operation | Meaning |
| --- | --- |
| `create` | Dispatch a new execution from a provider-neutral request. |
| `wait` | Block until the execution is ready (running) or terminal. |
| `status` | List recent executions, or describe the one behind a handle. |
| `logs` | Emit an execution's logs. |
| `cancel` | Ask the substrate to stop a running execution, reporting the substrate's own result. |
| `terminate` | **Idempotent** teardown. Already-terminated, already-terminal, or externally-deleted is a success. |

`cancel` and `terminate` are deliberately different operations. `squad-aca stop`
maps to `cancel`, because its observable contract today is "run the substrate's
stop and show me what happened" — including failures. `terminate` is the
idempotent teardown PRD #6 requires for cleanup paths, and is not wired to a CLI
command yet.

### Opaque handles

Every operation after `create` takes an **opaque execution handle** — a `sqx1.`
prefixed token that encodes the owning provider plus a provider-private payload.
Callers must pass it back verbatim; they cannot assume it is an ACA Job execution
name, and decoding it for a different provider is an error. Records returned by
`status` keep the handle separate from a `Display` object, so the CLI renders
substrate-shaped columns without any call site being able to round-trip an
identifier out of them.

### Request and response

The dispatch request carries `schemaVersion`, `sessionId`, `dispatchSource`,
`repository`, `task`, `capabilityManifest`, `capabilityResolution`,
`executionPreferences`, and `git` — nothing in it names an Azure resource, an
image, a job, or a sandbox. The response carries `executionMode`,
`sandboxClass`, `sessionHandle`, `status`, `statusPollRef`, and
`fallbackReason`. `capabilityResolution` is the slot the Sprint 2 capability
resolver fills; the seam passes `$null` today.

`create` never writes its own response to the pipeline — it returns it through an
`-Outcome` hashtable — so substrate dispatch output still passes through to the
user byte for byte.

### What is deliberately *not* behind the seam

`Assert-AcaConfigured`, `doctor`, `ralph`, `watch`, `secrets`, `destroy`,
`status`, and `new` still call `az`/`gh` directly. They are infrastructure and
configuration-plane operations, not per-execution lifecycle, so routing them
through an execution provider would add risk without helping a future substrate.

### Extension point

`New-SquadExecutionProvider -Kind` accepts `aca-job` and `fake` today. A
Sandboxes provider plugs in there without touching CLI plumbing. Sandboxes are
**not** implemented yet.

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
