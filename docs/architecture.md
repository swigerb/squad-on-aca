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

`New-SquadExecutionProvider -Kind` accepts `aca-job` and `fake` today. A
Sandboxes provider plugs in there without touching CLI plumbing. Sandboxes are
**not** implemented yet.

## Unified dispatch contract and durable leases

Three things dispatch work: the local CLI (`squad-aca run`), Ralph (a cron-driven
ACA Job running `worker/lib/ralph-dispatch.sh`), and Watch (a hosted container
app). PRD #6 requires that all three *share one routing decision* and that
*claim and session state are written before compute is requested*.

### One implementation, two thin callers

The routing decision and the lease lifecycle live in **Node**, under
`worker/lib/`:

| File | Responsibility |
| --- | --- |
| `worker/lib/dispatch-decision.js` | The one routing decision. Wraps the Sprint 2 capability resolver and produces `{sessionId, dispatchSource, leaseKey, routing{…}}`. |
| `worker/lib/dispatch-lease.js` | The durable lease store, lifecycle, gone-classification and sweeper. |
| `worker/lib/squad-dispatch.js` | The CLI seam: `decide \| claim \| dispatched \| heartbeat \| complete \| release \| sweep \| list`. |

Bash and PowerShell do **not** re-implement any of it. `ralph-dispatch.sh` and
`scripts/lib/dispatch-contract.ps1` are shims that shell out to
`node worker/lib/squad-dispatch.js` and parse its JSON. Node was chosen because
the capability resolver it wraps is already Node, Ralph already shells to `node`,
and the worker image already ships it — so the shared core needed no new runtime
anywhere.

The `routing` object deliberately carries **no dispatcher identity**. Dispatcher
identity lives one level up, in `dispatchSource`. That means the same input
produces a byte-identical `routing` object from all three paths, and the test
suites compare it byte-for-byte rather than field-by-field.

If `node` is missing, dispatch **fails closed**. It never falls back to a
locally-guessed route: a second, divergent routing rule is exactly the failure
mode this contract exists to prevent.

### Where lease state lives, and why

Leases are stored **in GitHub**, on a dedicated orphan ref (`squad-aca-leases`)
in the same repository, one JSON blob per lease at `leases/<lease-key>.json`,
written through the Contents API.

- GitHub is already the durable system of record for this project (issues,
  labels, branches, PRs) and Ralph already claims work by labelling an issue.
  Extending that model adds **no new infrastructure** — no table, no queue, no
  blob account, no extra RBAC surface.
- All three dispatchers can already reach it. Ralph runs in ACA with a token,
  Watch runs in ACA with a token, the local CLI has `gh` — no dispatcher needs a
  new credential.
- It survives a laptop reboot. A local file would not, which the PRD rules out.
- The Contents API gives the two primitives a lease needs without a lock service:
  **create-once** (`PUT` without a `sha` returns `422` if the blob exists) is the
  atomic claim, and **compare-and-swap** (`PUT` with the `sha` you read, `409` on
  stale) is the atomic update.
- It is off the default branch, so lease churn never pollutes `main`'s history,
  never triggers CI, and never appears in a PR diff.

Cost: dispatch now requires `contents: write` on the repository. That is a real
new dependency and is called out in the runbook.

### Lease key = idempotency key

The lease key is `issue-<n>` when the work is tied to a GitHub issue, and
`session-<sanitized session id>` otherwise. Two dispatchers that pick different
session names for the same issue therefore converge on **one** lease, which is
what makes "Ralph ran twice" and "Ralph and the CLI both fired" the same,
already-handled case.

### Lifecycle

```
claimed ──► dispatched ──► running ──► succeeded | failed | cancelled
   │                          ▲
   │                          │ heartbeat
   └──► released (retryable)  └──► reclaimed (by the sweeper)
```

`claimLease` returns one of four outcomes, and only two of them permit compute:

| Outcome | Meaning | Dispatch? |
| --- | --- | --- |
| `created` | No prior lease; this dispatcher owns it. | yes |
| `repaired` | A `claimed`/`released`/`reclaimed` lease was adopted — this is the crash-between-claim-and-compute repair path. | yes |
| `active` | Someone else holds a live lease. | **no** |
| `completed` | The work already reached a terminal state. | **no** |

`reclaimed` is terminal for the *sweeper* (it is never swept twice) but is
explicitly **repairable** for a *claimer*. A sweeper that permanently retired the
work it reclaimed would turn every transient stall into lost work, which is the
opposite of reclaiming it.

### Claim before compute

Every path writes the lease before it requests compute:

1. resolve the decision (`decide`),
2. write the lease (`claim`) — a durable record now exists,
3. request compute (`az containerapp job start` / `az containerapp update`),
4. mark `dispatched`; on any failure in step 3, `release` so the next run retries.

The worker heartbeats on start and writes the terminal state from an `EXIT` trap
(`worker/entrypoint.sh`), so a lease reflects the execution that owns it.

The tests assert this ordering **by index** in a single ordered call log that
both the fake `az` and the fake `gh` append to. A presence check would still pass
if the order were inverted.

### Sweeper

`squad-aca leases sweep` (and Ralph, at the top of every run) reclaims:

- **orphaned claims** — a lease stuck in `claimed` past its TTL, i.e. a
  dispatcher that died between claim and compute;
- **expired heartbeats** — a `dispatched`/`running` lease whose worker stopped
  heartbeating.

Cleanup follows the same fail-closed rule as
`scripts/lib/providers/squad-aca-job-provider.ps1`: **already-cleaned,
already-terminal and externally-deleted are all SUCCESS**, but auth, RBAC,
throttling and network failures **surface**. Classification uses the same
deny-list-first shape as `Test-AcaJobExecutionGone` — a message that mentions
both `401` and `not found` is a failure, not a "gone", and an unrecognised
failure is a failure.

### Observability

`squad-aca sessions` shows the resolved `Route` and the dispatcher `Source` for
every execution (both are stamped into the execution environment as
`SQUAD_DISPATCH_ROUTE` / `SQUAD_DISPATCH_SOURCE`). `squad-aca leases` lists the
ledger itself. `scripts/show-status.ps1` is unchanged: it renders raw Azure
projections and has no access to the lease ledger.

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
