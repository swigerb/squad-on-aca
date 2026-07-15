# Optional .NET / Aspire integration path

This directory is an **optional** integration path for Squad on ACA. It is
**not** required to deploy or run Squad on Azure Container Apps, and it does
**not** replace the ACA Jobs control plane in [`../scripts`](../scripts) and
[`../worker`](../worker).

## Why this exists

The primary architecture keeps `squad-aca` as a thin ACA remote-runner / control
plane. This scaffold adds a separate, opt-in path that layers cleanly on top:

| Layer | Responsibility | Where |
| --- | --- | --- |
| **Aspire** | Models resources (the Aspire Dashboard OTLP sink + the `squad-worker` container) as code | `Squad.Aca.AppHost` |
| **Agent Framework** | Exposes the Squad session as an agent abstraction | `AgentAbstraction.cs` (seam only) |
| **ACA** | Remains the production execution substrate | `../scripts/deploy.ps1` |
| **Squad** | Remains the orchestration system inside the worker | `../worker` |

Use it to run a local, telemetry-wired smoke of the worker against a real Aspire
Dashboard before dispatching work to ACA.

## Layout

```
aspire/
  Squad.Aca.sln
  Squad.Aca.AppHost/
    Squad.Aca.AppHost.csproj   # Aspire AppHost project
    AppHost.cs                 # models the dashboard + optional worker container
    AgentAbstraction.cs        # compile-safe Agent Framework seam (no preview dep)
    appsettings.json           # non-secret defaults
    appsettings.Development.json  # gitignored; put local overrides/tokens here
```

## Package references

The AppHost pins the following (already in `Squad.Aca.AppHost.csproj`):

- SDK: `Aspire.AppHost.Sdk` `9.4.0`
- `Aspire.Hosting.AppHost` `9.4.0`

The Microsoft **Agent Framework** packages (`Microsoft.Agents.AI.*`) are preview
and intentionally **not** referenced here, to keep restore stable. To adopt them,
add e.g. `Microsoft.Agents.AI` and implement `ISquadAgent` (see
`AgentAbstraction.cs`).

## Prerequisites

- .NET SDK 9.0+ (validated with the 10.0 SDK targeting `net9.0`).
- .NET 9 runtime present (`dotnet --list-runtimes`).
- A container runtime (Docker/Podman) if you want Aspire to actually start the
  dashboard/worker containers. Building the solution does not require one.
- Network access to `nuget.org` for the first restore.

## Build

```powershell
cd aspire
dotnet build .\Squad.Aca.sln
```

If restore fails in a locked-down environment, the project and `AppHost.cs`
remain valid, reviewable scaffolding. See
[`../docs/validation.md`](../docs/validation.md) for guidance.

## Run (local telemetry smoke)

```powershell
cd aspire\Squad.Aca.AppHost
dotnet run
```

This starts the standalone Aspire Dashboard (the default OTLP sink) with:

- UI auth = **BrowserToken** (never `Unsecured`)
- OTLP auth = **ApiKey** (never `Unsecured`)
- OTLP ports (18889/18890) modeled as **internal-only** endpoints

To also start the `squad-worker` container wired to the dashboard, set
`Squad:RunWorker=true` and provide a repository:

```powershell
$env:Squad__RunWorker = "true"
$env:Squad__GitHubRepository = "<github-owner>/<repo>"
dotnet run
```

## Security

- No secrets are committed. The browser token and OTLP API key are read from
  configuration/user-secrets/environment at run time and generated when absent.
- Put local tokens only in `appsettings.Development.json` (gitignored) or use
  `dotnet user-secrets`.
- This scaffold mirrors the OTLP auth posture of `scripts/deploy.ps1`; do not
  weaken it to `Unsecured`.
