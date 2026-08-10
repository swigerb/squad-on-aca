# Architecture

Squad on ACA separates orchestration, control-plane commands, execution providers, execution substrates, and telemetry.

## Layered model

| Layer | Responsibility | Implementation |
| --- | --- | --- |
| Orchestration | Decide what work runs and coordinate the Squad team | Squad CLI inside the worker (`worker/entrypoint.sh`) |
| Control plane | Dispatch sessions, sync state, inspect runs | `scripts/squad-aca.ps1`, `scripts/*.ps1` |
| Execution provider | Provider-neutral session lifecycle | `scripts/lib/squad-aca-provider.ps1`, `scripts/lib/providers/*.ps1` |
| Execution substrate | Run each session in isolation | Azure Container Apps Jobs; optional ACA Sandboxes |
| Telemetry sink | Collect logs/traces/metrics | Standalone Aspire Dashboard |
| Resource modeling (optional) | Model resources as code | .NET Aspire AppHost (`aspire/`) |
| Agent abstraction (optional) | Expose a session as an agent | `ISquadAgent` + `AcaSquadAgent`; MAF `AIAgent` adapter |

## Default path

```text
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

- ACA Jobs are the default unit of isolation.
- The standalone Aspire Dashboard runs as a Container App with `BrowserToken` UI auth and `ApiKey` OTLP auth.
- Ralph is a mode of the shared worker image.

See [runbook.md](runbook.md) and [feature-parity.md](feature-parity.md).

## Execution provider boundary

All per-session lifecycle operations go through a provider seam.

```text
scripts/squad-aca.ps1            control plane / CLI
        │  dispatch request
        ▼
scripts/lib/squad-aca-provider.ps1        contract + route gate
        │  create / wait / status / logs / cancel / terminate
        ├── scripts/lib/providers/squad-aca-job-provider.ps1   (ACA Jobs, default)
        ├── scripts/lib/providers/squad-sandbox-provider.ps1   (ACA Sandboxes, feature-flagged off)
        └── scripts/lib/providers/squad-fake-provider.ps1      (offline tests)
```

| Operation | Meaning |
| --- | --- |
| `create` | Dispatch a new execution from a provider-neutral request. |
| `wait` | Block until the execution is ready or terminal. |
| `status` | List recent executions, or describe one handle. |
| `logs` | Return execution logs as `Lines` plus an optional `Notice`. |
| `cancel` | Ask the substrate to stop a running execution. |
| `terminate` | Idempotent teardown. Already-terminated, already-terminal, or externally-deleted is success; auth, RBAC, throttling, network, wrong-subscription, and missing-CLI failures surface as errors. |

`cancel` backs `squad-aca stop`. `terminate` is for cleanup paths.

Every operation after `create` takes an opaque execution handle with an `sqx1.` prefix. Callers pass it back verbatim.

The dispatch request carries `schemaVersion`, `sessionId`, `dispatchSource`, `repository`, `task`, `capabilityManifest`, `capabilityResolution`, `executionPreferences`, and `git`. The response carries `executionMode`, `sandboxClass`, `sessionHandle`, `status`, `statusPollRef`, and `fallbackReason`.

`Assert-AcaConfigured`, `doctor`, `ralph`, `watch`, `secrets`, `destroy`, `status`, and `new` remain infrastructure/configuration commands and call `az` or `gh` directly.

`New-SquadExecutionProvider -Kind` accepts `aca-job`, `sandbox`, and `fake`.

## ACA Sandboxes provider

`scripts/lib/providers/squad-sandbox-provider.ps1` implements the provider contract over Azure Container Apps Sandboxes, ARM type `Microsoft.App/sandboxGroups`, api-version `2026-02-01-preview`.

Sandboxes use the standalone `aca` binary, not `az`. Resolution order:

1. `-AcaCliPath`;
2. `SQUAD_ACA_SANDBOX_CLI`;
3. `PATH`;
4. `~/.aca/bin/aca.exe`.

### Route gate

`Resolve-SquadExecutionRoute` is the single route gate.

| Decision | Flag off | Flag on |
| --- | --- | --- |
| *(none)* | `aca-job` | `aca-job` |
| `aca-job` | `aca-job` | `aca-job` |
| `sandbox` | `aca-job` only if the default worker satisfies the manifest; otherwise `fail-closed` | `sandbox`, only for an approved class in a non-provisional catalog; anything else `fail-closed` |
| `fail-closed` | `fail-closed` | `fail-closed` |
| anything else | `fail-closed` | `fail-closed` |

The route is resolved before compute is requested:

```text
squad-aca run
  -> Get-CapabilityManifestSource
  -> Get-SquadDispatchDecision -RepoDir <tree>
       -> node worker/lib/squad-dispatch.js decide --repo-dir <tree>
            -> dispatch-decision.js -> resolve-capability-route.js
  -> decision.routing.capability
  -> New-SessionExecutionProvider -CapabilityResolution <capability>
  -> Resolve-SquadExecutionRoute
  -> aca-job adapter | Sandboxes provider | refuse
```

| Situation | Decision |
| --- | --- |
| No readable working tree for this repository, for example `--repo other/repo` | Fall back to `aca-job` with an announced reason; the in-worker preflight is the backstop |
| Manifest absent from a readable tree | `aca-job` |
| Manifest present but unreadable, unparseable, or invalid | `fail-closed` |

Lifecycle operations use the provider encoded in the handle. They do not re-resolve routing.

### Sandbox execution model

`aca sandbox exec` has a hard client transport timeout around 120 seconds. Sessions launch detached and are polled.

`create` performs these steps:

1. Assert the target sandbox group has no managed identity.
2. Create the sandbox:
   ```text
   aca sandbox create --disk-id <GUID> --label name=squad-<session> --cpu … --memory …
   ```
3. Apply egress policy:
   ```text
   aca sandbox egress set … --default Deny --rule <pattern>:<action> … --traffic-inspection …
   ```
4. Set lifecycle:
   ```text
   aca sandbox lifecycle set … --auto-suspend enable --idle-timeout-seconds …
   ```
5. Launch the worker detached:
   ```text
   aca sandbox exec -l name=… -c "prelude && { setsid nohup bash -c '…' </dev/null >/dev/null 2>&1 & } && …"
   ```

The brace group in step 5 is required. `{ … & }` scopes backgrounding to the redirected `setsid` command, so the prelude runs synchronously and the exec returns immediately.

`status` reads phase, exit code, and completion marker. A completion marker without an exit code is `Unknown`. Transport failures are reported as inconclusive and polled again.

### Sandbox controls

- `--identity`, `--system-assigned`, and `--mi-user-assigned` are rejected before the process starts.
- The target group is asserted identity-free.
- Private-registry pulls use an ACR refresh token:
  ```text
  --username 00000000-0000-0000-0000-000000000000 --token …
  ```
- Default-deny egress plus the class allowlist is applied before repository code runs.
- Tokens, egress policy values, and remote command text are redacted from rendered argv and captured output.
- Every sandbox is labelled `name=squad-<session id>`.
- Credentials are delivered by file, not as launch-command environment assignments.

## Unified dispatch contract and durable leases

Local CLI, Ralph, Watch, and Actions dispatch through the same Node core under `worker/lib/`.

| File | Responsibility |
| --- | --- |
| `worker/lib/dispatch-decision.js` | Routing decision. Wraps the capability resolver and produces `{sessionId, dispatchSource, leaseKey, routing{…}}`. |
| `worker/lib/dispatch-lease.js` | Durable lease store, lifecycle, gone-classification, and sweeper. |
| `worker/lib/squad-dispatch.js` | CLI seam: `decide`, `claim`, `dispatched`, `heartbeat`, `complete`, `release`, `sweep`, `list`. |

If `node` is missing, dispatch fails closed.

Leases are stored in GitHub on the orphan ref `squad-aca-leases`, under `leases/<lease-key>.json`, through the Contents API. Dispatch requires `contents: write`.

The lease key is `issue-<n>` for issue work and `session-<sanitized session id>` otherwise.

```text
claimed -> dispatched -> running -> succeeded | failed | cancelled
   |            |             ^
   |            +-------------| heartbeat (periodic, every SQUAD_LEASE_HEARTBEAT_SECONDS)
   +-> released (retryable)  +-> reclaimed (by the sweeper)
```

| Outcome | Meaning | Dispatch? |
| --- | --- | --- |
| `created` | No prior lease; this dispatcher owns it. | yes |
| `repaired` | A released, reclaimed, or stale claimed lease was adopted. | yes |
| `active` | Someone else holds the work. | no |
| `completed` | The work already reached a terminal state. | no |

| State | TTL | Env override | Meaning |
| --- | --- | --- | --- |
| `claimed` | 300 s | `SQUAD_LEASE_CLAIM_TTL_SECONDS` | Covers the claim-to-compute window. |
| `dispatched`, `running` | 3600 s | `SQUAD_LEASE_TTL_SECONDS` | Covers an agent session, refreshed by heartbeat. |

Every path writes the lease before it requests compute:

1. resolve the decision (`decide`);
2. write the lease (`claim`);
3. request compute (`az containerapp job start` / `az containerapp update`);
4. mark `dispatched`; on a step 3 failure, `release`.

`squad-aca leases sweep` and Ralph reclaim orphaned claims and expired heartbeats. Terminal leases are pruned after `SQUAD_LEASE_RETENTION_SECONDS` (default 7 days). Per-run sweep cost is capped by `SQUAD_LEASE_SWEEP_MAX_READS` (default 50).

`squad-aca sessions` shows `Route` and `Source`. `squad-aca leases` lists the ledger.

## Agent tool policy

Every session resolves a tier before any agent starts.

| Signal | Tier |
| --- | --- |
| `SQUAD_MODE` in `prompt`, `new-project`, `shell`, `smoke`, `telemetry-smoke` and `SQUAD_DISPATCH_SOURCE=local-cli` | `attended` |
| Any other value, including absent `SQUAD_DISPATCH_SOURCE` | `autonomous` |

Both tiers run with `--allow-all-tools` and without `--allow-all-paths`. Deny rules take precedence over `--allow-all-tools`.

| | attended | autonomous |
| --- | --- | --- |
| `shell(sudo)`, `shell(su)` | denied | denied |
| `shell(chmod)`, `shell(chown)`, `shell(chattr)`, `shell(setfacl)` | denied | denied |
| `shell(git config)`, `shell(gh auth)`, `shell(gh secret)`, `shell(gh variable)` | denied | denied |
| `shell(az)`, `shell(kubectl)`, `shell(terraform)`, `shell(docker)` | allowed | denied |
| `shell(gh api)`, `shell(gh repo delete)`, `shell(gh release delete)` | allowed | denied |
| `--no-ask-user` | no | yes |
| writes outside the checkout | denied | denied |
| writes to a governance path | denied | denied |
| appends to `.squad/agents/<name>/history.md` | allowed, append-only | allowed, append-only |

Governance paths are made read-only before the agent starts and hash-verified before push and at session end:

```text
.squad/policies
.squad/agents
.squad/identity
.squad/config.json
.squad/routing.md
.squad/casting-policy.json
.squad/casting/policy.json
.squad/memory/config.json
.squad/memory/audit.jsonl
.squad/fact-checker/policy.md
.squad/fact-checker/audit-trail.md
.squad/rai/policy.md
.squad/rai/audit-trail.md
```

`.squad/agents/<name>/history.md` is append-only. It may grow; the pre-session prefix must remain byte-identical.

Failures exit `78` (`EX_CONFIG`). See [runbook.md#agent-tool-policy](runbook.md#agent-tool-policy).

## Optional .NET/Aspire integration path

The `aspire/` directory adds an opt-in path:

- `Squad.Aca.AppHost` models the Aspire Dashboard OTLP sink and `squad-worker` container as code.
- `Squad.Aca.Agents` defines `ISquadAgent` and implements `AcaSquadAgent` over `squad-aca --json`.
- `Squad.Aca.Agents.MAF` adapts `ISquadAgent` to Microsoft Agent Framework `AIAgent`.
- ACA remains the execution substrate.
- Squad remains the orchestration system.

| You want to | Use |
| --- | --- |
| Deploy and run Squad on ACA | Default path (`scripts/deploy.ps1`, `squad-aca`) |
| Reproduce telemetry locally / model resources as code | Optional AppHost (`aspire/`) |
| Expose a Squad session as an Agent Framework agent | MAF adapter (`aspire/Squad.Aca.Agents.MAF`, [maf-adapter.md](maf-adapter.md)) |

See [agent-contract.md](agent-contract.md) and [maf-adapter.md](maf-adapter.md).

## Assumptions and prerequisites

See the [README](../README.md#assumptions-and-prerequisites) and [runbook](runbook.md#assumptions-and-prerequisites).
