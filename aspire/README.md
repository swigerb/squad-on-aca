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
| **Agent Framework** | Exposes the Squad session as an agent abstraction | `Squad.Aca.Agents` (contract + control-plane implementation, no preview dep) |
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
    appsettings.json           # non-secret defaults
    appsettings.Development.json  # gitignored; put local overrides/tokens here
  Squad.Aca.Agents/            # net9.0, ZERO package references
    AgentAbstraction.cs        # ISquadAgent + its records (the contract)
    AcaSquadAgent.cs           # ISquadAgent over `squad-aca --json`
    ISquadCliInvoker.cs        # the fakeable process seam
    SquadCliProcessInvoker.cs  # the real `pwsh -File squad-aca.ps1` runner
    SquadCliLocator.cs         # entry-point discovery, no hardcoded paths
    SquadAgentOptions.cs
    SquadAgentExceptions.cs
    SecretRedactor.cs
  Squad.Aca.Agents.Tests/      # xunit, fully offline
```

## `Squad.Aca.Agents` — the agent contract

`ISquadAgent` is what a Microsoft Agent Framework `AIAgent` wraps:

```
MAF pipeline
  └─ AIAgent                (sprint 2, isolated, may take a preview dependency)
       └─ ISquadAgent       (this library, net9.0, zero package references)
            └─ squad-aca --json  ->  ACA Job | ACA Sandbox
```

Three properties are deliberate and enforced:

- **Zero package references.** `scripts/validate.ps1` fails the build if a
  `<PackageReference>` appears in `Squad.Aca.Agents.csproj`. A preview restore
  failure in the sprint-2 adapter must not be able to take the contract — and
  everything that depends on it — down with it.
- **`net9.0`.** The AppHost is `net9.0`, so a `net10.0` contract could not be
  referenced from it without an unrelated Aspire bump; `Microsoft.Agents.AI`
  targets `net8.0`+, so a sprint-2 adapter on `net8.0`/`9.0`/`10.0` can reference
  this without an SDK bump either.
- **`--json`, not output parsing.** `AcaSquadAgent` talks to the control plane
  through `squad-aca run|status|sessions --json`. The human-readable output is
  pinned byte-for-byte by 22 golden captures whose purpose is to catch
  *unintended* UX changes; making it load-bearing for a machine contract would
  turn every deliberate wording change into a breaking API change. See
  [`../docs/agent-contract.md`](../docs/agent-contract.md).

There is deliberately **no poll-to-completion** operation. Squad sessions run
10–60 minutes and MAF's `RunAsync` is request/response; reconciling those is an
adapter decision. `RunSessionAsync` returns an opaque handle, and
`GetSessionStatusAsync` / `CancelSessionAsync` address that handle.

A **fail-closed** route throws `SquadRouteFailedClosedException` with the
resolver's reason preserved. A repository whose required capabilities cannot be
met must never look like a dispatch that worked.

## Package references

The AppHost pins the following (already in `Squad.Aca.AppHost.csproj`):

- SDK: `Aspire.AppHost.Sdk` `9.4.0`
- `Aspire.Hosting.AppHost` `9.4.0`

The Microsoft **Agent Framework** packages (`Microsoft.Agents.AI.*`) are preview
and intentionally **not** referenced anywhere in this solution. To adopt them,
add a **separate** project that references `Squad.Aca.Agents` and implements an
`AIAgent` over `ISquadAgent`; do not add the package to `Squad.Aca.Agents`
itself, which `scripts/validate.ps1` enforces.

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
dotnet test  .\Squad.Aca.sln
```

The tests are fully offline: every one fakes `ISquadCliInvoker`, so none of them
starts PowerShell, contacts Azure, or opens a socket. `scripts/validate.ps1` runs
both commands automatically whenever a dotnet SDK is on PATH.

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
- ACA deployment keeps OTLP ports (18889/18890) **internal-only**. This local
  AppHost exposes OTLP endpoints for developer smoke testing.

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
