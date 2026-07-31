# Calling Squad on ACA from a Microsoft Agent Framework pipeline

This is the page to land on for the agent integration. It covers what the
integration is, what is proven, what is opt-in, and what is currently broken.
Two companion documents:

- [`docs/agent-contract.md`](agent-contract.md) — the `squad-aca --json` wire
  contract the .NET side parses. Read it when you care about the documents on
  the wire, or when you want to consume the control plane from something other
  than .NET.
- [ADR 0002](adr/0002-squad-on-aca-as-a-maf-agent.md) — why Squad on ACA is
  *exposed as* an agent rather than *built on* the framework internally.

## Status at a glance

Verified live against real Azure on 2026-07-31 through the sample host below;
the run-by-run evidence is in [`docs/e2e-results.md`](e2e-results.md).

| Claim | State |
|---|---|
| Dispatch to an ACA Job, poll, terminal status | **Verified** — `Succeeded` in 1 m 19 s |
| Dispatch to an approved sandbox class | **Verified** — `sandbox-python-3-12`, `Succeeded` in 43.8 s |
| `fail-closed` reaches the caller with its reason intact | **Verified** — exit 3, nothing started |
| Cancellation stops the session — **ACA Jobs** | **Verified** — Azure independently reported `Stopped` |
| Cancellation stops the session — **sandbox** | **Broken.** The stop reports success and the worker keeps running: [#36](https://github.com/swigerb/squad-on-aca/issues/36) |
| Long-run default | `RunToCompletion`. `DispatchOnly` is opt-in — see [The long-run problem](#the-long-run-problem) |
| `executionHandle` on a fresh ACA Job dispatch | **`null`**, by design. `statusPollRef` carries the session id instead |
| `fallbackReason` | Non-`null` **only** when the route deviated from what was asked for |
| A terminal session | Is **not** a stopped bill — see [Lifecycle and cost](#lifecycle-and-cost) |

## The layering

[`ISquadAgent`](../aspire/Squad.Aca.Agents) is the .NET contract for dispatching a
Squad session. It is deliberately framework-free: the library it lives in has
**zero package references**, and [`scripts/validate.ps1`](../scripts/validate.ps1)
fails the build if that ever stops being true.

That property is worth keeping, and it is also why the Agent Framework adapter is
a *different project*. `aspire/Squad.Aca.Agents.MAF` holds the only
`Microsoft.Agents.AI` reference in the repository:

```
MAF pipeline (host app)
  └─ AIAgent  "squad-on-aca"          Squad.Aca.Agents.MAF   <-- the only MAF dependency
       └─ ISquadAgent                 Squad.Aca.Agents       <-- zero packages
            └─ squad-aca --json       control plane
                 └─ ACA Job | ACA Sandbox
```

A caller that wants the contract without the framework references one project. A
caller that wants a MAF `AIAgent` references two. Nothing forces the first caller
to take a dependency it did not ask for, and — the point of the arrangement — an
Agent Framework API change cannot reach the contract or the control plane,
because neither can see it.

## The pinned version

| | |
|---|---|
| Package | `Microsoft.Agents.AI` |
| Version validated against | **1.16.0** (exact pin, not a range) |
| Target framework | `net9.0` |

`Microsoft.Agents.AI` ships `netstandard2.0`, `net472`, `net8.0`, `net9.0` and
`net10.0` asset groups, so `net9.0` resolves to a first-class `net9.0` build
rather than falling back to `netstandard2.0`.

Two notes that contradict the assumptions this work started from, and are worth
recording because they change the risk calculus:

1. **The package is no longer preview.** `Microsoft.Agents.AI` reached 1.0.0 GA
   and has shipped through 1.16.0. The quarantine was designed against a preview
   package; it stays anyway, because a stable package is not a frozen one and the
   cost of the separation is one `.csproj`.

2. **Part of the surface the adapter uses is still experimental.**
   `AgentRunOptions.ContinuationToken` and `AgentResponse.ContinuationToken` are
   marked `[Experimental("MEAI001")]` even in the stable release. Under
   `TreatWarningsAsErrors` that is a hard build error, so the adapter suppresses
   MEAI001 in exactly one file — [`SquadBackgroundResponse.cs`](../aspire/Squad.Aca.Agents.MAF/SquadBackgroundResponse.cs)
   — and never project-wide. A project-level `<NoWarn>` would silently opt every
   future file into an unstable API; `validate.ps1` asserts the csproj does not
   mention MEAI001 at all.

The version is pinned exactly rather than floated. A `1.*` would let a routine
restore change the compiled surface of a shipped adapter with no diff to review,
which is precisely the instability the quarantine exists to contain.

## Registration

```csharp
services.AddSingleton<ISquadAgent>(sp => new AcaSquadAgent(/* ... */));

services.AddSquadAcaAgent(options =>
{
    options.DefaultRepository = "octo/example";
    options.RunTimeout        = TimeSpan.FromMinutes(90);
});
```

`AddSquadAcaAgent()` registers the concrete `SquadAcaAIAgent` **and** the base
`AIAgent`, resolving to the *same* instance. Two instances over one control plane
would poll independently, time out independently, and stop each other's sessions
on cancellation.

Keyed overloads exist for pipelines that run more than one Squad agent:

```csharp
services.AddKeyedSquadAcaAgent("frontend", o => o.DefaultRepository = "octo/web");
services.AddKeyedSquadAcaAgent("backend",  o => o.DefaultRepository = "octo/api");
```

A keyed agent prefers an `ISquadAgent` registered under the same key and falls
back to the unkeyed one, so a host with a single control plane does not have to
register a redundant keyed copy of it.

Both forms also take an explicit inner-agent factory
(`AddSquadAcaAgent(sp => myAgent, configure)`) when the inner agent is not in DI.

### A host you can actually run

`aspire/Squad.Aca.Agents.MAF.Sample` is a working host built exactly this way.
It resolves the **base `AIAgent`**, not `SquadAcaAIAgent` — a MAF pipeline holds
`AIAgent`, so resolving the concrete type would prove the concrete type works and
say nothing about whether a pipeline that has never heard of Squad can drive it.

```powershell
dotnet run --project aspire/Squad.Aca.Agents.MAF.Sample -- `
  "fix the flaky test" --repo owner/repo --ref my-branch --no-push
```

It is also the harness that produced the live evidence in
[`docs/e2e-results.md`](e2e-results.md) — see its
[README](../aspire/Squad.Aca.Agents.MAF.Sample/README.md) for every argument and
the exit-code legend.

## The long-run problem

MAF's `RunAsync` is request/response. A Squad session runs **10 to 60 minutes**.
Something has to give, and the three ways to resolve it are not equally safe.

### The decision

**`RunToCompletion` is the default. `DispatchOnly` is available and has to be
asked for.**

The reasoning is about what a caller is promised, not about which is more
convenient. A MAF caller that did not set `AllowBackgroundResponses` is promised
a finished response, and in a workflow that response's text feeds the next node.
Returning a receipt there is not a smaller answer — it is a *wrong* one, and
nothing in the type system objects. The failure is silent: the next node happily
summarises `"Dispatched session squad-1234"` and the pipeline reports success.

Defaulting the other way makes the dangerous case the quiet one. Defaulting to
completion makes the dangerous case *loud*: a caller who genuinely cannot wait
40 minutes finds out immediately, at the first run, and switches modes. A caller
who could have waited never notices there was a decision to make.

Fire-and-forget is not worse — it is only worse **by accident**. So it stays, and
there are two ways to ask for it, in precedence order:

1. `SquadAcaAgentRunOptions.LongRunMode = SquadLongRunMode.DispatchOnly` — the
   explicit, Squad-typed request.
2. `AgentRunOptions.AllowBackgroundResponses = true` — MAF's own vocabulary for
   exactly this. Honouring it matters: it is how a caller that has never heard of
   this adapter still gets receipt-and-poll semantics from generic code.
3. Otherwise `SquadAcaAgentOptions.DefaultLongRunMode`, which is
   `RunToCompletion` unless the host changes it.

### `DispatchOnly` and resuming

`DispatchOnly` returns as soon as the control plane accepts the dispatch, with
the execution handle on `AgentResponse.ContinuationToken`. Passing that token
back on a later `AgentRunOptions.ContinuationToken` performs **one non-blocking
status read** — the caller already holds the token and decides its own cadence,
so blocking there would turn the poll they asked for back into the wait they
opted out of.

The token is re-attached while the session is unfinished and **dropped once it is
terminal**. That is how a caller knows to stop asking, and it is MAF's own
protocol rather than a Squad-specific one invented alongside it.

The token payload is a schema-stamped `squad-aca/continuation@1` document
carrying the handle and session name. It is validated on read: a token from some
other agent produces a `SquadContractException` naming what it got, not a
`NullReferenceException` three frames later.

### Polling

| | |
|---|---|
| First read | *after* the first interval — a session dispatched a millisecond ago is never terminal, and reading immediately just spends a control-plane call to learn that |
| Interval | 5 s, × 1.5 per poll, capped at 60 s |
| Final wait | clamped to the remaining budget, so the last poll lands *on* the deadline instead of most of an interval past it |
| Steady state | ≤ ~60 reads/hour |

Terminal states are `Succeeded`, `Failed`, `TimedOut`, `Cancelled` — the same set
the control plane uses. **`Unknown` is deliberately not terminal.** It means "the
control plane could not tell", which is a reason to keep asking, not a result.
It cannot loop forever because the timeout bounds it.

### The bound

`RunTimeout` defaults to **90 minutes** and throws
`SquadAgentRunTimeoutException`, which carries the handle, the session name, the
elapsed time and the last observed status. The handle is the point: a run that
times out has *not* necessarily failed, and the caller needs to be able to go
look.

By default (`CancelSessionOnTimeout`) the session is also stopped, for the same
reason cancellation stops it. The message says which happened, in three
distinguishable forms — "The session was asked to stop." / "The stop request did
not succeed; the session may still be running." / "The session was left
running." — because "your run timed out" and "your run timed out and something is
still billing" are different operational situations.

### Cancellation stops the session

A cancelled MAF call issues a stop for the ACA session **before** rethrowing, so
a caller that awaits the throw knows the stop was at least attempted.

The load-bearing detail is which token the stop runs on. It gets a **fresh**
`CancellationTokenSource(StopTimeout)` — forwarding the caller's already-cancelled
token would abort the stop on its very first await and leave a billed ACA session
running with nobody watching it. That is the difference between *cancelled* and
*orphaned*, and it is one line of code apart.

The stop never propagates its own failure. The caller is already on the way out
with a cancellation or a timeout, and replacing that with "the stop also failed"
would hide the reason the run ended. The outcome is reported three other ways
instead: the return value, `SquadAgentRunTimeoutException.SessionCancelled`, and
the diagnostic sink.

A cancelled *dispatch* stops nothing, because there is no handle yet.

> **Live caveat — the sandbox plane does not honour this yet
> ([#36](https://github.com/swigerb/squad-on-aca/issues/36)).** Verified against
> real Azure on 2026-07-31: on the **ACA Jobs** plane a cancelled MAF call really
> does stop the session (`az containerapp job execution list` independently
> reported `Stopped`). On the **sandbox** plane the control plane reports a
> successful cancel while the worker keeps running — `procps` is absent from the
> pinned class image, so the provider's `pkill` exits 127 into a discarded
> stderr and the surrounding command still exits 0. The adapter's half of the
> contract is correct; the layer beneath it is not. Evidence and root cause:
> [`docs/e2e-results.md` S3-5](e2e-results.md). Until #36 is fixed, treat a
> successful cancel on the sandbox plane as unproven and confirm the session
> yourself.

## Lifecycle and cost

A **terminal session is not a stopped bill.** Both live sandboxes were still
`Running` after their sessions reached a terminal state, and that is deliberate:
`cancel` leaves the sandbox up so its logs stay readable. Teardown is a separate
operation — `terminate` — and it goes through the ACA control plane rather than
through a shell inside the guest, so it is unaffected by #36.

Nothing in the MAF surface tears a sandbox down. `RunAsync` returning
`Succeeded`, a cancellation, and a `SquadAgentRunTimeoutException` all leave the
substrate exactly as the control plane left it. A host that dispatches to the
sandbox plane needs its own teardown or reaping story; see
[`docs/runbook.md`](runbook.md#concurrency-cost-and-orphans). On the ACA Jobs
plane the question does not arise — a job execution that reaches a terminal
state has already exited.

## Streaming

`RunStreamingAsync` emits **real status transitions**, not a final string cut into
pieces. There is no token stream to relay here — the control plane reports states,
so that is what is streamed:

```
Dispatched squad-1234 to an ACA Job.
Status: Running (phase: cloning).
Status: Running (phase: agent).
Completed: Succeeded (exit code 0).
```

Both surfaces run the same private engine, so the dispatch, the backoff, the
timeout and the cancel-on-cancellation rule exist **once**. A defect in any of
them fails both, rather than only whichever one a test happened to call.

Repeated identical statuses are not re-emitted; a 40-minute session should not
produce 60 updates that all say `Running`.

## What survives the adapter

### `fail-closed`

`SquadRouteFailedClosedException` is raised by `ISquadAgent` when a session's
route deviated and the repository's policy is to refuse rather than fall back.
It carries the actionable reason, the sandbox class and the exit code.

`_inner.RunSessionAsync` is called **outside every `try`/`catch` in the adapter**,
on purpose. The exception arrives at the MAF caller exactly as it left the
contract. A caller that catches `SquadRouteFailedClosedException` and reads
`.Reason` gets the same answer through a MAF pipeline as through a direct call —
"the route deviated to a sandbox and this repository does not permit that" rather
than "the agent run failed".

This is the one place where doing nothing was the design work.

### Secrets

The redaction split is inherited from the contract and preserved verbatim:

- **Descriptive** fields — status, phase, sandbox class, fallback reason, route,
  detail — are passed through `SecretRedactor` before they reach a response, an
  exception message, or the diagnostic sink.
- **Identity** fields — session name, execution name, handle — are **not**
  redacted, because they must round-trip byte-for-byte to
  `squad-aca sessions --session` and `squad-aca stop`. A redacted handle is a
  handle that cannot stop a session.

## Structured results

Text is for humans. Programs read `AgentResponse.AdditionalProperties`:

| Key | Meaning |
|---|---|
| `squad.sessionName` | session name, verbatim |
| `squad.handle` | execution handle, verbatim — `null` for a freshly dispatched ACA Job |
| `squad.route` | `aca-job` or `sandbox` |
| `squad.executionMode` | `Job` or `Sandbox` |
| `squad.sandboxClass` | sandbox class, redacted |
| `squad.fallbackReason` | non-`null` **only** if the route deviated |
| `squad.dispatched` | whether the control plane accepted the dispatch |
| `squad.status` / `squad.phase` | last observed state, redacted |
| `squad.exitCode` | exit code once terminal |
| `squad.terminal` | whether this response is final |
| `squad.longRunMode` | which mode actually ran |

`AgentResponse.RawRepresentation` carries the typed `SquadSessionStatus` or
`SquadSessionResult` for callers that would rather not read a dictionary.

> `executionHandle` is `null` for a freshly dispatched ACA Job — ACA names
> executions asynchronously. Poll with the session name; see
> [agent-contract.md](agent-contract.md).

## Tests

[`aspire/Squad.Aca.Agents.MAF.Tests`](../aspire/Squad.Aca.Agents.MAF.Tests) is
entirely offline: a scripted `ISquadAgent`, a virtual polling clock, no Azure, no
control plane, no network. A 90-minute timeout is exercised in milliseconds
because the clock is a seam, not a `Thread.Sleep`.

The fakes record what was asked of them, not just what they returned.
`FakeSquadAgent.StopCall.TokenAlreadyCancelled` exists for one assertion: that
the stop issued during cancellation was *not* handed the caller's dead token.
Without it, "cancellation stops the session" passes against an implementation
that orphans every session it touches.
