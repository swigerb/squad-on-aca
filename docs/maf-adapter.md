# Calling Squad on ACA from a Microsoft Agent Framework pipeline

This page covers the Microsoft Agent Framework (MAF) adapter for Squad on ACA.

Companion docs:

- [agent-contract.md](agent-contract.md): `squad-aca --json` wire contract.
- [../aspire/Squad.Aca.Agents.MAF.Sample/README.md](../aspire/Squad.Aca.Agents.MAF.Sample/README.md): runnable sample host arguments and exit codes.

## Status

| Capability | State |
|---|---|
| Dispatch to an ACA Job, poll, terminal status | Supported |
| Dispatch to an approved sandbox class | Supported |
| `fail-closed` reaches the caller with its reason intact | Supported |
| Cancellation stops ACA Jobs sessions | Supported |
| Cancellation stops sandbox sessions | Supported |
| Long-run default | `RunToCompletion`; `DispatchOnly` is opt-in |
| Fresh ACA Job `executionHandle` | `null`; use `statusPollRef` |
| `fallbackReason` | Non-`null` only when the route deviated |

## Layering

[`ISquadAgent`](../aspire/Squad.Aca.Agents) is the framework-free .NET contract for dispatching a Squad session. `aspire/Squad.Aca.Agents.MAF` holds the `Microsoft.Agents.AI` reference and adapts `ISquadAgent` to `AIAgent`.

```text
MAF pipeline (host app)
  └─ AIAgent  "squad-on-aca"          Squad.Aca.Agents.MAF
       └─ ISquadAgent                 Squad.Aca.Agents
            └─ squad-aca --json       control plane
                 └─ ACA Job | ACA Sandbox
```

## Pinned version

| | |
|---|---|
| Package | `Microsoft.Agents.AI` |
| Version validated against | `1.16.0` |
| Target framework | `net9.0` |

The adapter suppresses `MEAI001` only in [`SquadBackgroundResponse.cs`](../aspire/Squad.Aca.Agents.MAF/SquadBackgroundResponse.cs). `validate.ps1` asserts the project file does not suppress it globally.

## Registration

```csharp
services.AddSingleton<ISquadAgent>(sp => new AcaSquadAgent(/* ... */));

services.AddSquadAcaAgent(options =>
{
    options.DefaultRepository = "octo/example";
    options.RunTimeout        = TimeSpan.FromMinutes(90);
});
```

`AddSquadAcaAgent()` registers the concrete `SquadAcaAIAgent` and the base `AIAgent`, resolving to the same instance.

Keyed overloads:

```csharp
services.AddKeyedSquadAcaAgent("frontend", o => o.DefaultRepository = "octo/web");
services.AddKeyedSquadAcaAgent("backend",  o => o.DefaultRepository = "octo/api");
```

Both forms accept an explicit inner-agent factory:

```csharp
AddSquadAcaAgent(sp => myAgent, configure)
```

## Runnable sample

```powershell
dotnet run --project aspire/Squad.Aca.Agents.MAF.Sample -- `
  "fix the flaky test" --repo owner/repo --ref my-branch --no-push
```

The sample resolves the base `AIAgent`.

## Long-running sessions

MAF `RunAsync` is request/response. A Squad session can run for 10 to 60 minutes.

`RunToCompletion` is the default. `DispatchOnly` is available through:

1. `SquadAcaAgentRunOptions.LongRunMode = SquadLongRunMode.DispatchOnly`.
2. `AgentRunOptions.AllowBackgroundResponses = true`.
3. `SquadAcaAgentOptions.DefaultLongRunMode`.

`DispatchOnly` returns after dispatch with the execution handle on `AgentResponse.ContinuationToken`. Passing that token back on `AgentRunOptions.ContinuationToken` performs one non-blocking status read.

The token payload is a schema-stamped `squad-aca/continuation@1` document carrying the handle and session name.

## Polling

| | |
|---|---|
| First read | After the first interval |
| Interval | 5 s, multiplied by 1.5 per poll, capped at 60 s |
| Final wait | Clamped to the remaining budget |
| Steady state | At most about 60 reads/hour |

Terminal states are `Succeeded`, `Failed`, `TimedOut`, and `Cancelled`. `Unknown` is not terminal.

## Timeout and cancellation

`RunTimeout` defaults to 90 minutes and throws `SquadAgentRunTimeoutException`. The exception carries the handle, session name, elapsed time, and last observed status.

By default, timeout and caller cancellation issue a stop for the ACA session before returning or rethrowing. A cancelled dispatch stops nothing because no handle exists yet.

The stop uses a fresh `CancellationTokenSource(StopTimeout)` so the stop request can complete even when the caller token is already cancelled. Stop failure is reported through the return value, `SquadAgentRunTimeoutException.SessionCancelled`, and diagnostics.

## Lifecycle and cost

A terminal sandbox session is not deleted automatically. `cancel` stops the worker. `terminate` deletes the sandbox and goes through the ACA control plane. Hosts that dispatch to sandboxes must run teardown or reaping. See [runbook.md#concurrency-cost-and-cleanup](runbook.md#concurrency-cost-and-cleanup).

ACA Job executions exit when they reach terminal state.

## Streaming

`RunStreamingAsync` emits status transitions:

```text
Dispatched squad-1234 to an ACA Job.
Status: Running (phase: cloning).
Status: Running (phase: agent).
Completed: Succeeded (exit code 0).
```

Repeated identical statuses are not re-emitted.

## Fail-closed

`SquadRouteFailedClosedException` is raised by `ISquadAgent` when a route fails closed. It carries the reason, sandbox class, and exit code. The adapter passes it through unchanged.

## Redaction

| Field type | Handling |
| --- | --- |
| Descriptive fields: status, phase, sandbox class, fallback reason, route, detail | Redacted through `SecretRedactor` before response, exception, or diagnostics. |
| Identity fields: session name, execution name, handle | Not redacted; callers must round-trip them to `squad-aca sessions --session` and `squad-aca stop`. |

## Structured results

Programs read `AgentResponse.AdditionalProperties`.

| Key | Meaning |
|---|---|
| `squad.sessionName` | Session name, verbatim |
| `squad.handle` | Execution handle, verbatim; `null` for a freshly dispatched ACA Job |
| `squad.route` | `aca-job` or `sandbox` |
| `squad.executionMode` | `Job` or `Sandbox` |
| `squad.sandboxClass` | Sandbox class, redacted |
| `squad.fallbackReason` | Non-`null` only if the route deviated |
| `squad.dispatched` | Whether the control plane accepted the dispatch |
| `squad.status` / `squad.phase` | Last observed state, redacted |
| `squad.exitCode` | Exit code once terminal |
| `squad.terminal` | Whether this response is final |
| `squad.longRunMode` | Which mode ran |

`AgentResponse.RawRepresentation` carries the typed `SquadSessionStatus` or `SquadSessionResult`.

## Tests

[`aspire/Squad.Aca.Agents.MAF.Tests`](../aspire/Squad.Aca.Agents.MAF.Tests) is offline. It uses a scripted `ISquadAgent` and a virtual polling clock.
