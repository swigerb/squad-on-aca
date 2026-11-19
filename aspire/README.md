# Optional .NET / Aspire integration path

This directory is an **optional** integration path for Squad on ACA. It is
**not** required to deploy or run Squad on Azure Container Apps, and it does
**not** replace the ACA Jobs control plane in [`../scripts`](../scripts) and
[`../worker`](../worker).

## Why this exists

The primary architecture keeps `squad-aca` as a thin ACA remote-runner / control
plane. These projects add a separate, opt-in path that layers cleanly on top:

| Layer | Responsibility | Where |
| --- | --- | --- |
| **Aspire** | Models resources (the Aspire Dashboard OTLP sink + the `squad-worker` container) as code | `Squad.Aca.AppHost` |
| **Agent contract** | Dispatches a Squad session from .NET over `squad-aca --json` | `Squad.Aca.Agents` (net9.0, zero package references) |
| **Agent Framework** | Exposes that contract as a MAF `AIAgent` | `Squad.Aca.Agents.MAF` (net10.0, the only `Microsoft.Agents.AI` reference) |
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
  Squad.Aca.Agents.MAF/        # net10.0, the ONLY Microsoft.Agents.AI reference
    SquadAcaAIAgent.cs         # AIAgent over ISquadAgent (dispatch, poll, stop)
    SquadAcaAgentOptions.cs    # long-run mode, timeout, backoff, stop budget
    SquadAcaAgentRunOptions.cs # per-run overrides (AgentRunOptions subclass)
    SquadAcaAgentSession.cs    # AgentSession carrying the last handle
    SquadBackgroundResponse.cs # the only MEAI001 suppression in the repo
    SquadContinuationToken.cs  # squad-aca/continuation@1, schema-checked
    ISquadPollingClock.cs      # the seam that tests a 90-minute timeout in ms
    SquadAcaAgentServiceCollectionExtensions.cs  # AddSquadAcaAgent()
  Squad.Aca.Agents.MAF.Tests/  # xunit, fully offline
  Squad.Aca.Agents.MAF.Sample/ # runnable MAF host; the live end-to-end evidence
    Program.cs                 # resolves the base AIAgent from DI and calls it
    SampleOptions.cs           # prompt/repo/mode from arguments or environment
```

## `Squad.Aca.Agents` — the agent contract

`ISquadAgent` is what a Microsoft Agent Framework `AIAgent` wraps:

```
MAF pipeline
  └─ AIAgent                (Squad.Aca.Agents.MAF, the only Microsoft.Agents.AI reference)
       └─ ISquadAgent       (this library, net9.0, zero package references)
            └─ squad-aca --json  ->  ACA Job | ACA Sandbox
```

Three properties are deliberate and enforced:

- **Zero package references.** `scripts/validate.ps1` fails the build if a
  `<PackageReference>` appears in `Squad.Aca.Agents.csproj`. A restore failure
  in the Agent Framework adapter must not be able to take the contract — and
  everything that depends on it — down with it.
- **`net9.0`.** The existing dependency-free contract target is retained for
  compatibility. The optional AppHost, adapter, sample and test hosts now target
  `net10.0`; this does not change the production shell/worker control plane.
- **`--json`, not output parsing.** `AcaSquadAgent` talks to the control plane
  through `squad-aca run|status|sessions --json`. The human-readable output is
  pinned byte-for-byte by 22 golden captures whose purpose is to catch
  *unintended* UX changes; making it load-bearing for a machine contract would
  turn every deliberate wording change into a breaking API change. See
  [`../docs/agent-contract.md`](../docs/agent-contract.md).

There is deliberately **no poll-to-completion** operation *here*. Squad sessions
run 10–60 minutes and MAF's `RunAsync` is request/response; reconciling those is
an adapter decision, and it is made in `Squad.Aca.Agents.MAF` below.
`RunSessionAsync` returns an opaque handle, and `GetSessionStatusAsync` /
`CancelSessionAsync` address that handle.

A **fail-closed** route throws `SquadRouteFailedClosedException` with the
resolver's reason preserved. A repository whose required capabilities cannot be
met must never look like a dispatch that worked.

## `Squad.Aca.Agents.MAF` — the Agent Framework adapter

A separate project, holding the **only** `Microsoft.Agents.AI` reference in the
repository. A caller that wants the contract without the framework references one
project; a caller that wants an `AIAgent` references two.

```csharp
services.AddSingleton<ISquadAgent>(sp => new AcaSquadAgent(/* ... */));
services.AddSquadAcaAgent(o => o.DefaultRepository = "octo/example");
```

`AddSquadAcaAgent()` registers `SquadAcaAIAgent` and the base `AIAgent` as the
**same** instance; `AddKeyedSquadAcaAgent(key, ...)` does the keyed equivalent.

The long-run answer, in one line: **`RunToCompletion` is the default** — a MAF
caller that did not ask for a background response is promised a finished answer,
and in a workflow that text feeds the next node, so a receipt there is not a
smaller answer but a wrong one. `DispatchOnly` is available via
`AgentRunOptions.AllowBackgroundResponses` or `SquadAcaAgentRunOptions.LongRunMode`.
Cancellation and timeout both **stop** the ACA session — on a fresh token, since
the caller's is already dead — rather than orphaning it.

Full rationale, the pinned version, the polling schedule and the MEAI001 finding:
[`../docs/maf-adapter.md`](../docs/maf-adapter.md).

## Package references

The AppHost pins the following (already in `Squad.Aca.AppHost.csproj`):

- SDK: standard `Microsoft.NET.Sdk` (no nested AppHost SDK)
- `Aspire.Hosting.AppHost` `17.0.0`
- `Aspire.Hosting.Dotnet` `17.0.0`

The Microsoft **Agent Framework** package `Microsoft.Agents.AI` is pinned at an
exact **`1.28.0`** in `Squad.Aca.Agents.MAF` and referenced **nowhere else**. It
has since reached GA, but the quarantine stays: a stable package is not a frozen
one, part of the surface the adapter uses is still `[Experimental]`, and the cost
of the separation is one `.csproj`. Do not add the package to
`Squad.Aca.Agents`, which `scripts/validate.ps1` enforces along with the exact
pin, the one-way dependency, and solution membership.

Other direct packages, verified against the configured `azure-default` NuGet
feed on 2026-11-18:

| Package | Exact version |
| --- | --- |
| Microsoft.Extensions.Hosting | 11.0.0 |
| Microsoft.Extensions.DependencyInjection / .Abstractions | 11.0.0 |
| Microsoft.NET.Test.Sdk | 18.12.0 |
| xunit | 2.9.3 |
| xunit.runner.visualstudio | 4.0.1 |

These are the latest stable versions returned by that feed. The Extensions
11.0.0 packages include .NET 10-compatible assets; their major version does not
require retargeting the host to .NET 11. Exact transitive graphs are recorded in
the adjacent `packages.lock.json` files.
Aspire 17 uses the CLI bundle instead of injecting OS-specific dashboard/DCP
NuGet packages. No AppHost lock is included in this candidate: its local
validation packages are not the signed release distribution.

### Aspire 17 migration and validation-source limitation

The AppHost follows the [Aspire 17 release guidance](https://aspire.dev/whats-new/aspire-17/) and
[project-resource migration guide](https://aspire.dev/integrations/dotnet/migrate-dotnet-project-resource/)
with .NET 10, explicit AppHost/Dotnet 17.0.0 packages, and the **Aspire CLI
17.0.0 bundle**.
There are no .NET project resources in this AppHost, so there are no
`AddProject` registrations or generated `Projects.*` types to migrate.
Resource names, auth modes, ports, worker references and environment settings
are unchanged.

The signed Windows CLI came from the official
[17.0.0 release](https://github.com/microsoft/aspire/releases/tag/v17.0.0);
its Authenticode signature and SHA-256/SHA-512 checks were verified. The release
commit is `2d325b13709752ba6d9a943635c5e2940a2530c0`.

The approved NuGet proxy previously returned 13.6.5, not 17.0.0. Local compile
validation therefore used **unsigned Debug CI nupkgs**, version 17.0.0, from
the same release commit: [run 44203911604](https://github.com/microsoft/aspire/actions/runs/44203911604),
artifact `14382652960` (`built-nugets`), archive SHA-256
`6e522a103ff37924122e9ebea3a8bf33f21b3349e11e0b59bc86ac51cc2a15aa`.
These are **local API/build validation only**, not signed production release
package verification. Aspire packages were mapped exclusively to the local
artifact source, other packages to the approved proxy, and the NuGet cache was
isolated per repository. No global NuGet configuration or cache was changed.
**Unsigned Debug CI package hashes differ from signed Release NuGet hashes,
even for the same 17.0.0 ID/version.** The generated development-only AppHost
lock was removed from the candidate and archived outside the checkout; it must
not be committed, described as a signed-release lock, or used to enable CI
locked-mode restore. No tracked NuGet lock existed in this checkout. The
independently restored, non-Aspire agent/sample/test locks are retained.
Generate/review an AppHost release lock only when approved signed 17.0.0 nupkgs
are available. Existing lock enforcement must not be bypassed to accept CI
hashes; no signed-package restore is certified here.

The optional dashboard container remains explicitly held at
`mcr.microsoft.com/dotnet/aspire-dashboard:9.4`: the intended
`mcr.microsoft.com/aspire/dashboard:17.0` returned `MANIFEST_UNKNOWN`.
Upgrading the AppHost does not upgrade that separate image. No container was
launched and no nonexistent tag was substituted. CI/source acquisition and
runtime/publish validation remain outstanding. Do not install an Aspire workload.

The production worker's existing Squad **1.0.1** release bundle, Copilot
**1.0.69-2** and optional squad-hub **0.7.2** remain operational holds: their
compatibility requires separately authorized worker validation, not just a
NuGet compile. No worker image, deployment script or production default changed.
No npm install was run; npm-family traffic must use only
`https://packagefeedproxy.microsoft.io/npm/`, with no public fallbacks.

## Prerequisites

- .NET SDK **10.0.404**, also pinned in CI; .NET 10 runtime for the sample/tests.
- The signed **Aspire CLI 17.0.0 bundle** available on the process `PATH`.
- A container runtime (Docker/Podman) if you want Aspire to actually start the
  dashboard/worker containers. Building the solution does not require one.
- Access to your approved configured NuGet source for the first restore.

## Build

For the bounded local validation workspace, from the repository root (the
verified CLI/artifact and source-mapped config must already have been supplied):

```powershell
$validation = (Resolve-Path ..\.tools\aspire17-release).Path
$env:NUGET_PACKAGES = Join-Path $validation 'validation-cache-squad-on-aca'
$env:ASPIRE_HOME = Join-Path $validation 'home'
$env:PATH = (Join-Path $validation 'win-x64') + [IO.Path]::PathSeparator + $env:PATH
$cli = Join-Path $validation 'win-x64\aspire.exe'
$bundle = Join-Path $validation 'home\bundle'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = 'true'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = 'true'
dotnet restore .\aspire\Squad.Aca.sln --configfile (Join-Path $validation 'validation.NuGet.config') --disable-parallel -m:1 /nodeReuse:false -p:AspireCliPath="$cli" -p:AspireCliBundlePath="$bundle"
dotnet build .\aspire\Squad.Aca.sln --no-restore -m:1 /nodeReuse:false -p:AspireCliPath="$cli" -p:AspireCliBundlePath="$bundle"
dotnet test .\aspire\Squad.Aca.sln --no-build --no-restore -m:1 /nodeReuse:false
```

These settings are process-local. For ordinary builds, first provide approved
signed 17.0.0 packages and generate a release lock as described above; do not
configure the unsigned validation source globally or in production CI.
The shared verified bundle is reused read-only; these commands do not run
`aspire setup`, generate new Aspire locks, or change global tooling.

The tests are fully offline: every one fakes `ISquadCliInvoker`, so none of them
starts PowerShell, contacts Azure, or opens a socket. `scripts/validate.ps1` runs
both commands automatically whenever a dotnet SDK is on PATH.

The upgrade checks built the AppHost and sample without launching either and
passed **67 MAF tests + 47 contract tests**. No container, server, Azure resource
or live session was started. Runtime telemetry/deployment compatibility was not
tested and is not implied by those compile/unit checks.

If restore fails in a locked-down environment, the projects still parse and
review as source; the static structure checks in `scripts/validate.ps1` continue
to run. See [`../docs/validation.md`](../docs/validation.md) for guidance.

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
- The AppHost mirrors the OTLP auth posture of `scripts/deploy.ps1`; do not
  weaken it to `Unsecured`.
