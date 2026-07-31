# ADR 0002 — Expose Squad on ACA as a Microsoft Agent Framework agent, rather than building the worker on the framework

- **Status:** Accepted — **implemented** (Option B); Option A **deferred**
- **Date:** 2026-07-30 (decision) · 2026-07-31 (implemented and live-verified)
- **Deciders:** Squad (lead, engineer, security, docs), repository owner
- **Context:** issue [#33](https://github.com/swigerb/squad-on-aca/issues/33) — making Squad on ACA callable as an agent from a Microsoft Agent Framework (MAF) pipeline

> This ADR is a historical record of a decision and the evidence behind it. The
> integration is built and verified end to end. For how to **use** it, see
> [docs/maf-adapter.md](../maf-adapter.md); for the wire contract underneath it,
> see [docs/agent-contract.md](../agent-contract.md). This document explains
> *why* the framework sits outside the worker and what constrains anyone who
> wants to change that.

## Context

[`Squad.Agents.AI`](https://github.com/bradygaster/squad/blob/dev/src/Squad.Agents.AI/README.md)
exposes a Squad *team* as a MAF `AIAgent` by wrapping the GitHub Copilot SDK.
That raises two questions for this repository which are easy to conflate:

| | Integration point | Direction |
|---|---|---|
| **Option A** | Replace `copilot -p` inside `worker/entrypoint.sh` with a .NET host calling `AddSquadAgent()` | Squad on ACA *uses* MAF internally |
| **Option B** | Implement the existing `ISquadAgent` seam so a MAF pipeline can call Squad on ACA | Squad on ACA *is callable from* MAF |

They are not two designs for the same thing. Option A changes what runs inside
the session container. Option B changes nothing about the session and adds a
caller in front of the control plane.

## Decision

**Do Option B. Defer Option A.**

Squad on ACA is exposed as a MAF `AIAgent`. The worker, the tool-policy tiers,
the governance guard, and the ACA Jobs default are untouched, and the MAF
package is not on the execution path at all.

Three structural choices carry the decision:

1. **A framework-free contract.** `aspire/Squad.Aca.Agents` defines
   `ISquadAgent` and implements it (`AcaSquadAgent`) with **zero package
   references**, machine-asserted by `scripts/validate.ps1`. A caller that wants
   the contract without the framework references one project.
2. **The adapter is quarantined.** `aspire/Squad.Aca.Agents.MAF` holds the only
   `Microsoft.Agents.AI` reference in the repository, pinned exactly at
   `1.16.0`. An Agent Framework API change cannot reach the contract or the
   control plane, because neither can see it.
3. **`--json`, not output parsing.** The human-readable CLI output is pinned
   byte-for-byte by golden captures whose purpose is catching *unintended* UX
   changes. Making it load-bearing for a machine contract would turn every
   deliberate wording change into a breaking API change. `run`, `sessions` and
   `status` grew an opt-in `--json` mode instead, which left all 22 pre-existing
   goldens byte-identical.

## Why Option A is deferred

The documented `SquadAgent` builds its session with:

```csharp
OnPermissionRequest = PermissionHandler.ApproveAll,
```

That is a blanket allow. It is what `--yolo` did before
[#26](https://github.com/swigerb/squad-on-aca/issues/26) removed it from this
repository. Today `COPILOT_ARGV` is built from `SQUAD_POLICY_ARGV`: an
`attended` or `autonomous` tier, `--deny-tool` rules that outrank
`--allow-all-tools`, `.squad/` governance paths locked and SHA-256 verified, and
exit 78 if a permission-widening flag is smuggled in. Adopting Option A as
documented would put a blanket allow back inside the container that change
removed it from.

The published `SquadAgentOptions` surface exposes `CliPath`, `CliArgs`,
`Environment`, `ConfigureCopilotClient`, `AgentFileName` and telemetry knobs —
but **no permission seam**. `ConfigureCopilotClient` customizes
`CopilotClientOptions`, not `SessionConfig`, so it cannot reach
`OnPermissionRequest`.

There is a plausible escape: `CliArgs` is settable, and denials are documented
to outrank `--allow-all-tools`, which would make `ApproveAll` largely inert.
Plausible is not verified. **Option A stays closed until that is tested**, and
the test is the deliverable — not the argument.

Option B carries none of that risk: it does not change the worker, does not
touch the permission model, and adds no dependency to the execution path.

## A correction worth recording

`Microsoft.Agents.AI` was assumed to be a preview package throughout the
planning of this work, and the quarantine in choice 2 above was designed against
that assumption. **The assumption was wrong.** The package reached 1.0.0 GA and
has shipped through 1.16.0; the version this repository pins is a stable
release.

The quarantine was kept anyway, for two reasons that survive the correction:

- A stable package is not a frozen one, and the cost of the separation is one
  `.csproj`.
- Part of the surface the adapter uses is still `[Experimental("MEAI001")]` even
  in the stable release — `AgentRunOptions.ContinuationToken` and
  `AgentResponse.ContinuationToken`, which are exactly what the long-run story
  is built on. The suppression is confined to a single file rather than applied
  project-wide, so a future file cannot opt into an unstable API by accident;
  `validate.ps1` asserts the `.csproj` never mentions MEAI001.

Recorded because a decision that happens to survive a false premise is still a
decision taken on a false premise, and the next person deserves to know which
part of the reasoning was load-bearing.

## Consequences

Binding constraints for whoever changes this next:

1. **`Squad.Aca.Agents` must keep zero package references.** `validate.ps1`
   fails the build otherwise. If the contract ever needs a dependency, that is a
   decision to take deliberately and record, not a restore to accept.
2. **The `Microsoft.Agents.AI` pin is exact, not a range.** A `1.*` would let a
   routine restore change the compiled surface of a shipped adapter with no diff
   to review. `validate.ps1` asserts the exact pin, the one-way dependency
   direction, and solution membership.
3. **MEAI001 stays suppressed per-file.** A project-level `<NoWarn>` silently
   opts every future file into an unstable API.
4. **`--json` is versioned by its `schema` value.** A breaking change to any
   document mints a new one (`…@2`); consumers reject an unrecognised schema
   rather than best-effort-parsing it. Adding a key is not breaking.
5. **`RunToCompletion` is the default long-run mode.** A MAF caller that did not
   ask for a background response is promised a finished answer, and in a
   workflow that text feeds the next node — so returning a receipt there is not
   a smaller answer but a wrong one, and nothing in the type system objects.
   `DispatchOnly` stays available via `SquadAcaAgentRunOptions.LongRunMode` or
   MAF's own `AllowBackgroundResponses`.
6. **Cancellation on the sandbox plane is broken and must not be claimed.**
   [#36](https://github.com/swigerb/squad-on-aca/issues/36): the provider's
   `pkill` is absent from the pinned class image, exits 127 into a discarded
   stderr, and is masked by a trailing `echo`, so a cancel reports success while
   the worker runs on. ACA Jobs cancellation is verified and unaffected. Any
   documentation that claims cancellation must say which plane it means.
7. **A terminal session is not a stopped bill.** `cancel` deliberately leaves a
   sandbox up so logs stay readable; teardown is `terminate`'s job, and no MAF
   surface performs it.
8. **Adopting Option A later reopens the permission question, not just a
   dependency question.** The blocker is `OnPermissionRequest`, and the
   acceptance test is behavioural: prove a `--deny-tool` rule supplied through
   `CliArgs` still refuses a tool inside a real session.

## Open questions for upstream

Carried from issue #33 and still unanswered:

1. Is `OnPermissionRequest` configurable from `SquadAgentOptions`, or is
   `ApproveAll` fixed? (Gates Option A.)
2. Do `--deny-tool` flags supplied via `CliArgs` survive to the CLI process and
   still bind?
3. Is `Squad.Agents.AI` expected to reach stable, and on what horizon?
4. Does its subagent span emission duplicate what Copilot CLI already emits
   natively with `COPILOT_OTEL_ENABLED=true`?

## Evidence

Live, 2026-07-31, driven by `aspire/Squad.Aca.Agents.MAF.Sample` resolving the
base `AIAgent` from DI — recorded in full in
[docs/e2e-results.md](../e2e-results.md).

| Claim | Observed |
|---|---|
| ACA Jobs dispatch, poll, terminal status | `Succeeded` in 1 m 19.3 s; `caj-squad-aca-session-7pzwpc2` corroborated from Azure |
| `executionHandle` null on a fresh Jobs dispatch | Confirmed against the real control plane, not a fake told to return null |
| Sandbox dispatch to an approved class | `sandbox-python-3-12`, `Succeeded` in 43.8 s |
| `fail-closed` survives the adapter | Exit 3 carrying `sandbox-feature-disabled-and-default-insufficient`; no ACA execution created |
| Cancellation — ACA Jobs | `Stopped`, reported by the ACA control plane rather than by the client |
| Cancellation — sandbox | **Failed.** Worker ran 51 s past the cancel and completed normally. Filed as #36 |
| Offline regression contract | 114 .NET tests, `validate.ps1` 307/0/0, 26 CLI goldens byte-identical |
