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
| Agent abstraction (optional) | Expose a session as an agent | `ISquadAgent` + `AcaSquadAgent` (`aspire/Squad.Aca.Agents`) |

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

`New-SessionExecutionProvider` in `scripts/squad-aca.ps1` always consults
`Resolve-SquadExecutionRoute`; the flag is enforced *inside* the gate rather
than by short-circuiting before it. With no capability resolution the gate
returns `aca-job` without reading the catalog, resolving a class, or looking for
`aca`, so "flag off, no manifest" is byte-identical to a build with no sandbox
code in it — which is what `scripts/tests/verify-cli-golden.ps1` and
`scripts/tests/compare-cli-baseline.ps1` verify.

Short-circuiting on the flag *before* the gate was the shape until issue #25.
It was safe only while `-CapabilityResolution` was always `$null`; the moment a
real decision flowed in, it became a silent downgrade — a repository whose
required capabilities the default worker cannot meet would have run there
anyway, unannounced. The gate distinguishes the two flag-off cases instead.

**Where the decision is made, and when (issue #25).** The route is resolved
**before any compute is requested**, by the same shared Node core Ralph and
Watch use:

```
squad-aca run
  -> Get-CapabilityManifestSource   (which working tree, if any, is this repo)
  -> Get-SquadDispatchDecision -RepoDir <tree>      [scripts/lib/dispatch-contract.ps1]
       -> node worker/lib/squad-dispatch.js decide --repo-dir <tree>
            -> dispatch-decision.js -> resolve-capability-route.js
  -> decision.routing.capability
  -> New-SessionExecutionProvider -CapabilityResolution <capability>
  -> Resolve-SquadExecutionRoute   (flag + approved-class gate)
  -> aca-job adapter | Sandboxes provider | refuse
```

Nothing is re-implemented in PowerShell: `dispatch-contract.ps1` remains a thin
shim that shells out and parses JSON, and `scripts/validate.ps1` asserts it
contains no route literal. `decision.routing.capability` — not
`decision.routing` — is what the gate is handed, because only the capability
decision carries `defaultImageSufficient`, and that field is what separates "the
default worker can serve this anyway" from "it cannot, so refuse".

**The manifest source is the local working tree**, and only when that tree is
provably the repository being dispatched. `squad-aca run` syncs the tree to the
branch the worker will clone immediately beforehand and already warns about
uncommitted drift; reading it adds no network call, so a dispatch cannot stall
or be rate-limited by a routing lookup, and it adds no observable behaviour to
the no-manifest path. Reading it can only produce a *hint*: the in-worker
preflight re-checks against the real clone before any repository code runs and
fails closed, so drift can cost a refused session but never grant one.

The failure modes are explicit, never a guess:

| Situation | Decision |
| --- | --- |
| No readable working tree for this repository (e.g. `--repo other/repo`) | Documented fall back to `aca-job`, **announced** with the reason; the in-worker preflight is the backstop |
| Manifest absent from a readable tree | `aca-job` — today's path, unchanged |
| Manifest present but unreadable, unparseable or invalid | `fail-closed`; `Get-SquadDispatchDecision` throws and nothing is dispatched |

**Lifecycle operations never re-resolve.** `sessions`, `logs`, and `stop`
recover the provider from the opaque execution handle
(`New-SessionExecutionProviderForHandle`), which already carries its provider
id. Re-resolving would answer *today's* routing question about *yesterday's*
session: edit `squad-capabilities.yml` after a dispatch and `stop` would address
the wrong substrate, reporting success while the real execution ran on. A
sandbox handle still requires the feature flag, so the kill switch keeps its
promise that this control plane never invokes `aca` while the flag is unset.

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
session names for the same issue therefore converge on **one** lease record.

Converging on one record is necessary but **not** sufficient. Both dispatchers
still have to be told different things, or both would dispatch. "Ralph ran
twice" and "Ralph and the CLI both fired" are handled by the claim outcome
(below), not by the key alone — the key only guarantees they are arguing over
the same row.

### Lifecycle

```
claimed ──► dispatched ──► running ──► succeeded | failed | cancelled
   │            │             ▲
   │            └─────────────┤ heartbeat (periodic, every
   │                          │ SQUAD_LEASE_HEARTBEAT_SECONDS)
   └──► released (retryable)  └──► reclaimed (by the sweeper)
```

`claimLease` returns one of four outcomes, and only two of them permit compute:

| Outcome | Meaning | Dispatch? |
| --- | --- | --- |
| `created` | No prior lease; this dispatcher owns it. | yes |
| `repaired` | A lease that is provably *not* being worked was adopted — a `released` or `reclaimed` lease, or a `claimed` lease older than the claim window. This is the crash-between-claim-and-compute repair path. | yes |
| `active` | Someone else holds the work: either a live execution, **or another dispatcher that is inside its own claim-to-compute window right now**. | **no** |
| `completed` | The work already reached a terminal state. | **no** |

`reclaimed` is terminal for the *sweeper* (it is never swept twice) but is
explicitly **repairable** for a *claimer*. A sweeper that permanently retired the
work it reclaimed would turn every transient stall into lost work, which is the
opposite of reclaiming it.

#### Two TTLs, because a claim and an execution are not the same thing

A `claimed` lease is **not** self-evidently a crashed one. The window between
writing the lease and requesting compute is not a millisecond: in
`worker/lib/ralph-dispatch.sh` it spans `mktemp`, an env build that shells out to
`node` and `az`, and then the job start — seconds. Ralph's cron and an operator's
`squad-aca ralph run` overlap by design, so two dispatchers landing in that
window is reachable through supported operation, not a theoretical race.

So `claimed` and `dispatched`/`running` age out on **different** clocks:

| State | TTL | Env override | Why |
| --- | --- | --- | --- |
| `claimed` | 300 s | `SQUAD_LEASE_CLAIM_TTL_SECONDS` | Only has to cover one env build plus one API call. Short, so a genuine crash self-heals in minutes. |
| `dispatched`, `running` | 3600 s | `SQUAD_LEASE_TTL_SECONDS` | Has to cover a whole agent session, refreshed by the worker's periodic heartbeat. |

The claim TTL is clamped to never exceed the session TTL, so lowering
`SQUAD_LEASE_TTL_SECONDS` cannot accidentally leave claims outliving executions.

**What a losing claimer sees.** It gets `outcome: "active"` together with the
current owner's lease record (`sessionId`, `state`, `dispatchSource`,
`updatedAt`) so it can say *who* holds the work. The CAS conflict path collapses
to the same answer: if two claimers both decide to adopt and one loses the
`409`, the loser re-reads and returns `active` rather than throwing. Adoption is
therefore decided by the store, not by who checked first.

Ralph treats `active` differently depending on the owner's state, and the
distinction matters:

- owner is `dispatched`/`running`/terminal → **label** the issue. Compute exists;
  the issue should stop appearing as a candidate.
- owner is still `claimed` → **do not label**, skip and retry next run. If that
  dispatcher fails to start it will `release` the lease, and a labelled issue
  would never be offered again. Costing one extra evaluation is strictly better
  than silently dropping the work.

### Claim before compute

Every path writes the lease before it requests compute:

1. resolve the decision (`decide`),
2. write the lease (`claim`) — a durable record now exists,
3. request compute (`az containerapp job start` / `az containerapp update`),
4. mark `dispatched`; on any failure in step 3, `release` so the next run retries.

Step 4 is deliberately **best-effort**. Once step 3 succeeds the execution is
live, so a transient fault while recording `dispatched` must neither throw to the
caller (whose retry would find a `claimed` lease, be told `repaired`, and start a
second execution) nor `release` (which would hand live work to another
dispatcher). All three dispatchers warn and move on; the worker's heartbeat
reconciles the state.

The worker heartbeats **periodically** for the life of the execution — a
background ticker every `SQUAD_LEASE_HEARTBEAT_SECONDS` (default 300) — and
writes the terminal state from an `EXIT` trap (`worker/entrypoint.sh`), which
stops the ticker first. A single beat at start would be indistinguishable from no
heartbeat at all for any session that outlives the TTL: the sweeper would reclaim
a lease whose execution is still running, and the work would be re-dispatched
underneath itself.

The tests assert this ordering **by index** in a single ordered call log that
both the fake `az` and the fake `gh` append to. A presence check would still pass
if the order were inverted.

### Sweeper

`squad-aca leases sweep` (and Ralph, at the top of every run) reclaims:

- **orphaned claims** — a lease stuck in `claimed` past the *claim* TTL, i.e. a
  dispatcher that died between claim and compute;
- **expired heartbeats** — a `dispatched`/`running` lease whose worker stopped
  heartbeating.

…and **prunes** terminal leases (`succeeded`, `failed`, `cancelled`, `released`,
`reclaimed`) that have been untouched for longer than the retention window
(`SQUAD_LEASE_RETENTION_SECONDS`, default 7 days) via the Contents API `DELETE`.

#### Both growth and cost are bounded, on purpose

Every `run`, `smoke`, `telemetry smoke` and Ralph issue mints a lease. Without a
delete path the ledger is append-only, and two things break at scale:

- the Contents API directory listing caps at **1000 entries**, past which the
  ledger silently stops enumerating and the sweeper stops seeing leases it should
  reclaim;
- a sweep that reads every key costs `1 + N` API calls, and Ralph sweeps on a
  five-minute cron — 288 runs/day. At 600 leases that is ~173,000 calls/day,
  roughly 7,200/hr against a 5,000/hr authenticated REST budget.

The failure mode is severe *because* classification is correct: a `429` surfaces,
`claimLease` throws, and Ralph skips **every** issue without labelling. Dispatch
stops entirely, with no operator-visible cause. So:

| Bound | Mechanism | Knob |
| --- | --- | --- |
| Ledger size | terminal leases past the retention window are deleted | `SQUAD_LEASE_RETENTION_SECONDS` (7 d) |
| Per-run API cost | at most `1 + budget` calls, regardless of ledger size | `SQUAD_LEASE_SWEEP_MAX_READS` (50) |
| Coverage under the cap | the start offset rotates with the clock, so successive sweeps walk the whole ledger instead of re-reading the same prefix | derived, no knob |
| Listing cap | `truncated: true` is reported and logged, never silently short | — |

Rotation is derived from the clock (`floor(epoch / 300) * budget mod total`)
rather than a persisted cursor: it costs zero extra API calls and has no blob of
its own to fail, corrupt, or contend on.

`sweepLeases` reports `{ reclaimed, pruned, skipped, examined, total, budget,
truncated }`, so a partial pass is always distinguishable from a complete one.

Cleanup follows the same fail-closed rule as
`scripts/lib/providers/squad-aca-job-provider.ps1`: **already-cleaned,
already-terminal and externally-deleted are all SUCCESS**, but auth, RBAC,
throttling and network failures **surface**. Classification uses the same
deny-list-first shape as `Test-AcaJobExecutionGone` — a message that mentions
both `401` and `not found` is a failure, not a "gone", and an unrecognised
failure is a failure.

That ordering is load-bearing and easy to lose, so `classifyGhFailure` reports
**which rule decided** (`real-failure`, `gone`, `unrecognised`, …) rather than
just a boolean, and the tests assert the deciding rule. Asserting only the
boolean cannot catch a swapped loop order: whenever a message matches just one
list, both orderings agree. The realistic input is a message that matches both —
GitHub masks a permission denial on a private resource as `HTTP 404: Not Found` —
so the fake `gh` ships fail modes whose text carries **both** signatures
(`masked403`, `masked401`, `masked429`, `masked500`) plus an `unrecognised` mode
that matches neither.

### Observability

`squad-aca sessions` shows the resolved `Route` and the dispatcher `Source` for
every execution (both are stamped into the execution environment as
`SQUAD_DISPATCH_ROUTE` / `SQUAD_DISPATCH_SOURCE`). `squad-aca leases` lists the
ledger itself. `scripts/show-status.ps1` is unchanged: it renders raw Azure
projections and has no access to the lease ledger.

## Agent tool policy (issue #26, PRD #6)

> Isolation is not authorization.

Until this change, every session on both planes ran Copilot with `--yolo` on an
image that also set `COPILOT_ALLOW_ALL=true`. `--yolo` expands to
`--allow-all-tools --allow-all-paths --allow-all-urls`, so a *remote* session
could write anywhere on the filesystem while the same agent on a developer's
machine was confined to its working directory. Remote execution applied **weaker**
policy than local — privilege escalation by choosing a substrate, which PRD #6
forbids. This predates the sandbox programme and affected both planes.

### What the Copilot CLI actually gives us

Verified against the pinned `@github/copilot@1.0.69-2` (`copilot help permissions`),
not assumed:

| Capability | Flag | Available? |
| --- | --- | --- |
| Deny a tool or shell subcommand | `--deny-tool 'shell(git config)'` | yes — and *"denial rules always take precedence over allow rules, even `--allow-all-tools`"* |
| Allow a tool | `--allow-tool` | yes |
| Hide tools from the model | `--available-tools` / `--excluded-tools` | yes |
| Confine file tools to the working directory | default; `--allow-all-paths` disables it | yes |
| Never block on an approval prompt | `--no-ask-user` | yes |
| **Deny a specific path while allowing the rest of the repo** | — | **no. There is no `--deny-path`, and `write` is all-or-nothing.** |

That last row is the finding that shapes everything else: *"may write the
repository but not `.squad/policies`"* is **not expressible as a Copilot flag**.
Enforcing governance through flags would be decoration, so it is enforced at the
filesystem instead.

Two behaviours were also confirmed empirically against the pinned binary:
a `--deny-tool 'shell(git config)'` rule really does block the call
(*"Permission to run this tool was denied due to the following rules"*), and
without `--allow-all-paths` a write outside the working directory is refused
(*"Permission denied and could not request permission from user"*) while a write
inside it succeeds. `--allow-all-urls` turned out to be unnecessary: both the
shell tool and web-fetch worked without it, so it is not passed.

### The tier model

An approval gate assumes a human. Ralph is a five-minute cron and Watch is a
polling loop, so "remove `--yolo` and prompt" would hang every unattended run
until timeout. Instead the *available* tool set narrows when nobody is watching.

`worker/lib/agent-policy.js` is a pure function of `SQUAD_MODE`,
`SQUAD_DISPATCH_SOURCE`, `ENABLE_GITHUB_REMOTE` and `SQUAD_COPILOT_FLAGS`:

- **attended** — an attended mode (`prompt`, `new-project`, `shell`, `smoke`,
  `telemetry-smoke`) dispatched from `local-cli`.
- **autonomous** — everything else, including every unrecognised value and an
  *absent* dispatch source. This is the default, and it is the fail-closed
  direction: treating "nobody said" as attended would make the strict tier
  opt-out by omitting a variable.

The autonomous tier is a strict superset of the attended denials, adding the
irreversible infrastructure verbs (`az`, `kubectl`, `terraform`, `docker`,
`gh api`, `gh repo delete`, `gh release delete`) and `--no-ask-user`. Destructive
operations are **unavailable** to an unattended run rather than approval-gated,
because there is nobody to approve them. See
[runbook.md#agent-tool-policy](runbook.md#agent-tool-policy) for the full table.

### Why parity is structural, not asserted

Both planes launch through the *same* `worker/entrypoint.sh`, which reaches the
*same* resolver. Nothing composes flags anywhere else; `scripts/deploy.ps1` now
explicitly clears `SQUAD_COPILOT_FLAGS` rather than injecting a flag string, and
`New-SandboxWorkerEnvironment` carries `SQUAD_DISPATCH_SOURCE` so a
Ralph-dispatched sandbox session cannot resolve to the attended tier while the
same session on ACA Jobs resolves to the autonomous one.

There is **no deliberate local/remote asymmetry**. The only asymmetry is between
*attended* and *unattended*, and it is available on both substrates.

### Governance-path enforcement

Two layers, applied after `squad init` / SubSquad activation (bootstrap
legitimately creates these files) and before any agent runs:

1. **Preventive** — every governance path is stripped of write bits, and
   `chmod`, `chown`, `chattr`, `setfacl` are denied at the CLI in *both* tiers so
   they cannot be put back with a tool call.
2. **Detective** — a SHA-256 manifest of every governance file plus the session's
   base commit is recorded in a `0700` directory **outside the checkout** (which
   the agent's file tools can no longer reach, because `--allow-all-paths` is
   gone) and re-verified before the push and at the end of every agent-running
   mode. Any difference — content, added file, deleted file, or a change that was
   *committed* rather than left in the working tree — exits 78 and nothing is
   pushed.

### The one exclusion: agent history is a work log, not policy

`.squad/agents/<name>/history.md` is excluded from the write lock. The pattern is
anchored at both ends (`^\.squad/agents/[^/]+/history\.md$`), so it matches
neither `charter.md` beside it, nor `.squad/agents/history.md`, nor a nested
`a/b/history.md`, nor a `.bak` lookalike.

**Why it is excluded.** `history.md` records what an agent *did*; it grants an
agent nothing. Locking it prevents no privilege escalation — it only destroys the
audit trail PRD #6 asks for, on exactly the unattended paths (Ralph, Watch) where
nobody else is around to write the record. A charter is the opposite: it states
what an agent is *permitted to do*, so it is governance and stays locked. That
distinction — *log of what happened* versus *statement of what is allowed* — is
the boundary, and it is where the exclusion is anchored.

**Why it is not a hole.** A path excluded from both the lock and the detector is
a foothold. This one is excluded from the lock only:

| | locked governance path | `.squad/agents/<name>/history.md` |
| --- | --- | --- |
| File mode | `a-w` | `u+w` |
| **Containing directory mode** | `a-w` | **`a-w` — unchanged** |
| Manifest line | `file <path> <sha256>` | `append-only <path> <sha256> <bytes>` |
| Verification rule | byte-identical | may grow; first `<bytes>` bytes must still hash to `<sha256>` |
| Permitted change | none | logged with its byte delta |
| Truncate / rewrite / delete / mint | exit 78 | exit 78 |

Two design points carry that table:

- **Ordering, not exclusion.** Hardening runs `chmod -R a-w` over `.squad/agents`
  *first* and only then restores `u+w` on the matching files. `chmod` on a file
  needs ownership, not write permission on its parent, so an unlocked file can
  sit inside a directory that still refuses `creat()` and `unlink()`. Expressing
  it the other way round — excluding the path from the recursive `chmod` — could
  not produce this shape, because the *directory* would have to be writable for
  the file to be creatable, and a writable directory is a writable directory.
  "History is writable" therefore cannot become "the agents directory is
  writable".
- **A prefix hash, not a lower bound.** The baseline pins the file's length *and*
  the hash of that many bytes, and verification re-hashes the prefix. A size-only
  check would wave through a rewrite that happens to be longer. Semantic
  validation of *what* gets appended is deliberately not attempted — this log has
  no schema — but "everything already written is still there, byte for byte" is
  cheap, exact, and directly testable, which is the bar a control has to clear
  before it is worth adding.

This is also why the manifest keeps the path under a different rule rather than
dropping it: an operator reviewing the baseline can see the file, its hash and
its length, and the session log states that history changed and by how much. A
path silently omitted from the baseline would be reviewable by nobody.

Consequence, accepted: a `history.md` that did not exist at hardening time cannot
be created by the run — that is a *new* governance file and fails the session.
Seed it in the reviewed PR that adds the agent.

### What this does NOT enforce, and who owns it

An honest boundary is worth more than a half-enforced control:

| Not enforced here | Why | Owner |
| --- | --- | --- |
| A determined agent editing a governance file anyway | It runs as the uid that owns the checkout, and the shell tool is not path-confined. `chmod u+w` defeats the mode bits. The detective layer means it cannot go *unnoticed* or be *published*, which is the property that actually matters. A tamper-proof preventive control needs a uid or mount boundary that does not exist in a single-user container. | Container/runtime layer (a non-owning uid, or a read-only mount) |
| Deleting `.squad/config.json` or `.squad/routing.md` | Unlinking a file needs write on its *parent*, and `.squad/` itself must stay writable for run state. Caught by the manifest, not by mode bits — asserted as a documented gap in `worker/tests/test_governance_guard.sh`. | Detective layer (accepted) |
| *What* an agent appends to its own `history.md` | The exclusion guarantees the log can only grow and that everything already written is intact. It does not guarantee the appended text is true — a work log has no schema to validate against, and a control that only appeared to check would be worse than none. | Reviewer / the PR the session opens |
| Multi-word deny patterns on `squad watch` / `squad loop` | `@bradygaster/squad-cli@0.11.0` consumes `--copilot-flags` as one string and splits it with `.trim().split(/\s+/)` in nine `dist/` modules, so `shell(git config)` cannot survive the handoff. Single-word patterns do. The dropped rules are logged by name at session start rather than silently downgraded. | Squad runtime (`--copilot-flags` needs to accept an array, or `squad` needs its own policy input) |
| Per-path *write* permission inside Copilot | The CLI has no `--deny-path`; `write` is all-or-nothing. | Copilot CLI |
| An interactive approval gate with an aborting timeout | Viable for a human-attended `squad-aca run`; useless for a cron-triggered Ralph, and there is no TTY in either container. Not implemented rather than implemented decoratively. | Copilot CLI / Squad runtime |
| Network egress and credential brokerage | Untouched by this change. | Sprint 7 egress layer, credential broker |

### Failure mode

Every failure path exits **78** (`EX_CONFIG`). There is no branch that logs a
warning and continues and no fallback to a permissive flag set: "the policy could
not be applied" and "the session runs with blanket allow" must never be the same
outcome. That equivalence *was* `--yolo`.

## Optional .NET/Aspire integration path

The `aspire/` directory adds an **opt-in** path. It does not replace the ACA
Jobs architecture; it layers on top:

- **Aspire models resources.** The `Squad.Aca.AppHost` project models the Aspire
  Dashboard OTLP sink and the `squad-worker` container as code, so you can run a
  local, telemetry-wired smoke of the worker before dispatching to ACA.
- **Agent Framework exposes the agent abstraction.** The `Squad.Aca.Agents`
  class library defines `ISquadAgent` and implements it (`AcaSquadAgent`) over
  the control plane's machine-readable `--json` mode. It has **zero package
  references**, so a Microsoft Agent Framework `AIAgent` adapter — which does
  take a preview dependency — lives in its own project and cannot destabilise
  the contract. See [agent-contract.md](agent-contract.md).
- **ACA remains the execution substrate.** Even with the AppHost, production work
  still runs as ACA Job executions.
- **Squad remains the orchestration system.** The AppHost does not orchestrate
  the team; Squad does, inside the worker.

### When to use which

| You want to… | Use |
| --- | --- |
| Deploy and run Squad on ACA | Default path (`scripts/deploy.ps1`, `squad-aca`) |
| Reproduce telemetry locally / model resources as code | Optional AppHost (`aspire/`) |
| Expose a Squad session as an Agent Framework agent | Agent contract library (`aspire/Squad.Aca.Agents`, [agent-contract.md](agent-contract.md)) |

The two paths share the same OTLP auth posture (BrowserToken UI, ApiKey OTLP,
internal-only OTLP ports) and the same worker image.

## Assumptions and prerequisites

See the [README](../README.md#assumptions-and-prerequisites) and
[runbook](runbook.md#assumptions-and-prerequisites) for the full list (Azure CLI,
GitHub CLI, PowerShell, tokens, and — for the optional path — the .NET SDK).
