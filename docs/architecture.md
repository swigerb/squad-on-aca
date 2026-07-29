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
scripts/lib/squad-aca-provider.ps1        the contract + the route gate
        │  create / wait / status / logs / cancel / terminate
        ├── scripts/lib/providers/squad-aca-job-provider.ps1   (production: ACA Jobs, the default)
        ├── scripts/lib/providers/squad-sandbox-provider.ps1   (ACA Sandboxes, feature-flagged OFF)
        └── scripts/lib/providers/squad-fake-provider.ps1      (offline tests)
```

### The contract

| Operation | Meaning |
| --- | --- |
| `create` | Dispatch a new execution from a provider-neutral request. |
| `wait` | Block until the execution is ready (running) or terminal. |
| `status` | List recent executions, or describe the one behind a handle. |
| `logs` | Return an execution's logs as `Lines` plus an optional `Notice` the caller prints verbatim. Which of a substrate's log paths produced them is the provider's business. |
| `cancel` | Ask the substrate to stop a running execution, reporting the substrate's own result. |
| `terminate` | **Idempotent** teardown. Already-terminated, already-terminal, or externally-deleted is a success. Idempotent is not "ignore every failure": a substrate error that says nothing about the execution's state (auth, RBAC, throttling, network, wrong subscription, a missing CLI binary) must surface as an error. |

`cancel` and `terminate` are deliberately different operations. `squad-aca stop`
maps to `cancel`, because its observable contract today is "run the substrate's
stop and show me what happened" — including failures. `terminate` is the
idempotent teardown PRD #6 requires for cleanup paths, and is not wired to a CLI
command yet.

The ACA Job adapter classifies a failed `az containerapp job stop`
**fail-closed**: a known real-failure signature wins over a "not found" reading,
Azure CLI's `ResourceNotFoundError` (exit 3) and the not-found/already-terminal
messages report `AlreadyTerminal`, and anything unrecognised is an error. It runs
`az` through `Invoke-AzPromptSafe` (`scripts/lib/aca-logs.ps1`), which captures
stderr and reports a distinct exit code when `az` cannot be run at all — so a
stale `$LASTEXITCODE` from an earlier command can never be read as a successful
stop. `scripts/validate.ps1` exercises all of this against a stubbed `az`.

### Opaque handles

Every operation after `create` takes an **opaque execution handle** — a `sqx1.`
prefixed token that encodes the owning provider plus a provider-private payload.
Opacity here is a *convention*, not a security boundary: the payload is base64
and anyone who wants to decode it can. What the convention buys is that no call
site can accidentally depend on "the handle is an ACA Job execution name".
Callers must pass it back verbatim, and decoding a handle for a different
provider is an error. Records returned by `status` keep the handle separate from
a `Display` object, so the CLI renders substrate-shaped columns without any call
site being able to round-trip an identifier out of them.

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

The ACA Job adapter's `logs` operation delegates to `Get-AcaExecutionLog`
(`scripts/lib/aca-logs.ps1`), which prefers the `containerapp` CLI extension,
falls back to Log Analytics, and throws when both fail (issue #13). The seam
does not change that behaviour; it only moves the decision of *how* to fetch
logs behind the provider, leaving `Invoke-Logs` responsible for presentation.
`scripts/lib/squad-aca-provider.ps1` dot-sources `aca-logs.ps1` itself, so the
adapter's `logs` and `terminate` operations do not depend on the caller having
loaded it first.

### What is deliberately *not* behind the seam

`Assert-AcaConfigured`, `doctor`, `ralph`, `watch`, `secrets`, `destroy`,
`status`, and `new` still call `az`/`gh` directly. They are infrastructure and
configuration-plane operations, not per-execution lifecycle, so routing them
through an execution provider would add risk without helping a future substrate.

### Extension point

`New-SquadExecutionProvider -Kind` accepts `aca-job`, `sandbox` and `fake`. A
further substrate plugs in there without touching CLI plumbing.

## ACA Sandboxes provider (feature-flagged, default OFF)

`scripts/lib/providers/squad-sandbox-provider.ps1` implements the same six
operations over **Azure Container Apps Sandboxes** (ARM `Microsoft.App/sandboxGroups`,
api-version `2026-02-01-preview`). ACA Jobs remain the unconditional default and
the rollback path; see `docs/runbook.md` for how to switch the flag on and off.

Every preview-specific detail lives inside that one file. Sandboxes are driven by
a standalone **`aca` binary**, not by an `az` extension — there is no
`az containerapp sandbox` command — and only the sandbox *group* is
ARM-reachable, so the group's managed-identity check is the one `az` call the
provider makes. `aca` is resolved through an overridable path
(`-AcaCliPath`, then `SQUAD_ACA_SANDBOX_CLI`, then `PATH`, then
`~/.aca/bin/aca.exe`) so the offline tests can stub it exactly like `az` and `gh`.

### The route gate

`Resolve-SquadExecutionRoute` is the single place the Sprint 2 capability
decision (`aca-job` | `sandbox` | `fail-closed`) is acted on, and the single
place the feature flag is enforced:

| Decision | Flag OFF | Flag ON |
| --- | --- | --- |
| *(none)* | `aca-job` | `aca-job` |
| `aca-job` | `aca-job` | `aca-job` |
| `sandbox` | `aca-job` **only if** the default worker satisfies the manifest, otherwise `fail-closed` | `sandbox`, but only for an **approved** class in a **non-provisional** catalog; anything else `fail-closed` |
| `fail-closed` | `fail-closed` | `fail-closed` |
| anything else | `fail-closed` | `fail-closed` |

A `sandbox` decision means the resolver already found the default image
insufficient, so with the flag off it fails closed rather than silently running
a session whose required capabilities cannot be met. Only administrator-approved
classes from `config/sandbox-classes.json` are reachable; a repository's
`image.hint` can at most *select among* them.

`New-SessionExecutionProvider` in `scripts/squad-aca.ps1` checks the flag
**first** and returns the ACA Jobs adapter immediately when it is off, without
reading the catalog, resolving a route, or looking for `aca`. That is what makes
"flag off" byte-identical to a build with no sandbox code in it, and it is what
`scripts/tests/verify-cli-golden.ps1` and `scripts/tests/compare-cli-baseline.ps1`
verify.

**The gate exists; it is not yet fed.** No `New-SessionExecutionProvider` call
site in `scripts/squad-aca.ps1` passes `-CapabilityResolution`, so every CLI
dispatch reaches the gate with *no* decision — the `(none)` row above — and the
`sandbox` branch is unreachable from the CLI **even with the flag on**. That is
the correct state for a default-off sprint: the routing table and the provider
are testable in isolation before anything can select them. Handing the Sprint 2
resolution to the gate is later work (PRD #6, Sprint 6+); until then, describing
this as "the capability decision is now acted on" overstates what ships.

### Session execution model: detached + poll

`aca sandbox exec` has a hard **~120 s client transport timeout**, constant
regardless of how long the remote command runs, after which it fails with
`Network issue — retry policy expired`. The sandbox itself is unharmed. Squad
sessions run 10–60 minutes, so **a session is never a single synchronous exec**.

`create` performs, in this order — and the order is a security control, not a
style choice:

1. assert the target sandbox group has **no managed identity** (fail closed if
   the check cannot be completed);
2. `aca sandbox create --disk-id <GUID> --label name=squad-<session> --cpu … --memory …`
   (`--disk` accepts public images only, so a private disk must be addressed by
   the GUID resolved from `aca sandboxgroup disk list -o json`);
3. `aca sandbox egress set … --default Deny --rule <pattern>:<action> … --traffic-inspection …`
   — **before** any repository code exists in the sandbox;
4. `aca sandbox lifecycle set … --auto-suspend enable --idle-timeout-seconds …`
   (auto-suspend otherwise defaults to enabled at 600 s and would suspend a live
   session);
5. `aca sandbox exec -l name=… -c "prelude && { setsid nohup bash -c '…' </dev/null >/dev/null 2>&1 & } && …"`
   — the **detached** worker launch, and the first repository code to run.

The brace group in step 5 is load-bearing. In POSIX/bash grammar `&` is a list
terminator that binds *looser* than `&&`, so writing

```text
prelude && setsid nohup bash -c '…' </dev/null >/dev/null 2>&1 &
```

backgrounds the **entire** `&&`-list and binds the three redirections to the last
simple command only — the async subshell keeps the exec's own fd 0/1/2 open for
the whole worker run, the launching exec blocks to its ~120 s timeout, and
`create`'s teardown then destroys a perfectly healthy session two minutes in.
`{ … & }` scopes the `&` to the redirected `setsid` alone, so the prelude runs
synchronously (and gates the launch), `phase=running` cannot race an asynchronous
`mkdir`, and the exec returns immediately. `validate.ps1` proves this by running
the emitted command in a real shell rather than by matching its text.

Any failure between steps 3 and 5 tears the sandbox down and rethrows the
original error, so repository code can never run in a sandbox whose egress policy
was not applied, and a policy-less sandbox is never left billing.

The detached wrapper records terminal state so a poll never has to infer it: the
worker runs (its own run includes the `git push`, so results are in GitHub before
the session is terminal — invariant 9), then its exit code is written, then the
phase, then the completion marker is touched **last**.

`status` is a short exec that reads that state; `wait` is a poll loop of those
short execs. Terminal state comes from the **completion marker plus a recorded
exit code** — a marker with no exit code is `Unknown`, not `Succeeded` — and never
from an exec's own exit status, which reports the transport rather than the
session. A transport failure is reported **inconclusive** and re-polled, never as
a failed session.

### Security invariants enforced by this provider

* `--identity`, `--system-assigned` and `--mi-user-assigned` are rejected on any
  argv before the process starts, and the target group is asserted
  identity-free. Private-registry pulls use an ACR refresh token
  (`--username 00000000-0000-0000-0000-000000000000 --token …`), which is exactly
  what removes the need for an identity.
* Default-deny egress plus the class's allowlist is applied before any repository
  code runs.
* Tokens, egress policy values (`--default`, `--rule`, `--traffic-inspection`)
  and remote command text are redacted from every rendered argv, and known secret
  values are scrubbed out of captured output, so they cannot reach an error
  message or a log.
* `terminate` is idempotent — already-deleted is success — but auth, RBAC,
  throttling, network and transport failures throw, because none of them says
  anything about whether the sandbox still exists. It reuses
  `Test-AcaJobExecutionGone`, the same fail-closed classifier the ACA Job adapter
  uses, rather than inventing a second mechanism.
* Every sandbox is labelled `name=squad-<session id>` so a reaper can find
  orphans.

**Known limitation (PRD #6 Sprint 7 owns it).** Worker credentials are currently
delivered as environment assignments inside the launch command, so they appear in
that one `aca` process argv on the client. The provider never repeats them —
not into the dispatch response, not into an error message, not into a rendered
argv — but replacing this with credential brokerage is Sprint 7's job.

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
