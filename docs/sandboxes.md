# ACA Sandboxes

**Azure Container Apps Sandboxes** are a second execution plane for Squad
sessions, alongside ACA Jobs. They give a session per-session isolation and
default-deny, capability-scoped egress that the fixed worker image cannot.

ACA Jobs remain the **unconditional default and the rollback path**. Sandboxes
are an Azure public preview with no SLA, so the plane is off by default and
stays off until you turn it on for a specific invocation.

This page describes what the plane does, how to turn it on, what stops it being
reachable by accident, and where the operational detail lives. For the shortest
path to a first sandbox session, see
[ACA Sandboxes in the README](../README.md#aca-sandboxes).

## What the plane does today

The plane is wired end to end. `squad-aca run` reads the repository's
`squad-capabilities.yml` from your local working tree **before** it requests any
compute, resolves it through the same Node routing core Ralph and Watch use, and
dispatches to whichever plane the decision names.

- A repository whose manifest an **approved sandbox class** satisfies runs in a
  sandbox, with default-deny egress applied before any repository code.
- `sessions`, `logs`, and `stop` then address that session on the plane it
  actually runs on, recovered from its opaque execution handle rather than
  re-resolved. Re-resolving would answer a question about yesterday's session
  with today's manifest.
- A repository with **no manifest**, or one the **default worker image already
  satisfies**, is unaffected — byte for byte. That is the overwhelmingly common
  case and it still runs on ACA Jobs.

With the flag **off**, a repository that genuinely needs a non-default
capability is **refused**, not quietly run on the default worker
(`sandbox-feature-disabled-and-default-insufficient`). That is deliberate:
silently downgrading is the one outcome worse than not starting. Turning the
flag off is a kill switch, not a downgrade switch.

The in-worker capability preflight
(`worker/lib/squad-capability-preflight.sh`) still runs inside whichever image
booted, and is still the last word. Routing chooses *where* to run; the
preflight verifies the environment that actually started. There is deliberately
no "the catalog says so, skip the preflight" path.

## Prerequisites

Four things must be in place before a dispatch can reach a sandbox. The runbook
carries the full commands; this is what each one is for.

| Requirement | Why |
| --- | --- |
| The standalone `aca` CLI (v1.0.0-preview.1 or later) | Sandboxes are not driven by `az` — there is no `az containerapp sandbox` command. Resolution order is `SQUAD_ACA_SANDBOX_CLI`, then `aca` on `PATH`, then `~/.aca/bin/aca.exe`. |
| A sandbox group with **no managed identity** | Identity on ACA Sandboxes is group-scoped with no per-sandbox opt-out, so a group carrying one would let sandboxed code mint control-plane tokens. The provider verifies the group is identity-free and refuses to create a sandbox if it cannot prove it. |
| A **disk** built from an approved class's pinned image | `--disk` accepts public images only, so a private image must be addressed by `--disk-id <GUID>`. The `--name` given at `disk create` time is a label, not a resolvable name; take the GUID from `aca sandboxgroup disk list -o json`. |
| `sandboxGroup` and `sandboxDiskId` in `~/.squad-on-aca/config.json` | These travel from configuration to the provider by name. Without a group the identity-free precondition cannot complete; without a disk id nothing can be created. |

> **One disk serves every class.** The configured `sandboxDiskId` is used for
> whichever class a repository routes to — there is no per-class disk mapping.
> Build the disk from the image of the class your repositories will actually
> select, and add a second configured deployment if you need both. You may set
> `sandboxDiskLabel` instead of `sandboxDiskId`; the provider then resolves the
> label to a GUID through `aca sandboxgroup disk list` on every dispatch.

Full setup commands, including the ACR refresh-token dance that `disk create`
needs for a private registry, are in
[runbook.md, Prerequisites](runbook.md#prerequisites).

## How to enable it

```powershell
$env:SQUAD_ACA_ENABLE_SANDBOX = "1"     # accepted: 1 / true / yes / on / enabled
squad-aca run "<prompt>"
```

The flag is an environment variable rather than a config key on purpose: it is
per-invocation, nothing that syncs config can turn it on, and rolling back needs
no file edit. `0`, `false`, `no`, and `off` are an explicit kill switch — an
explicit value decides in both directions.

Run `squad-aca` from the working tree of the repository you are dispatching. The
manifest is read from that tree, and only when it is provably the same
repository; pointing `--repo` at a different one leaves nothing to read, so the
dispatch takes the default ACA Jobs route. It says so rather than guessing
silently — look for a `Capability routing read no manifest for …` warning.

## The fail-closed interlocks

Two independent interlocks must both be open before a dispatch can reach a
sandbox, so closing either one returns every *satisfiable* dispatch to ACA Jobs.

1. **The feature flag defaults off.** With it unset, the route gate resolves
   `aca-job` for a repository the default worker image can serve, and
   `fail-closed` for one it cannot. Nothing reads the class catalog or looks for
   the `aca` binary.
2. **The class catalog must be reviewed.** `config/sandbox-classes.json` carries
   `"provisional": false` only because an administrator reviewed every approved
   class and pinned it to an immutable `sha256` digest — an approved class
   without one is a catalog fault, not a warning. Setting `"provisional": true`
   fails every sandbox route closed again (`reason: catalog-provisional`), which
   is the supported way to withdraw the plane without a code change.

A third interlock is accidental but real: a deployment with no `sandboxGroup`
and no disk configured cannot reach the plane at all, whatever the flag says.

The shipped catalog keeps one deliberately unapproved class
(`sandbox-container-build`) so the approved-only filter stays exercised, and a
repository's manifest can only ever *request* a capability — it can never add a
class, add an egress destination, widen a credential list, or name an image.

## Why the plane exists

Sandboxes give a session two properties the ACA Jobs plane does not have.

- **Per-session isolation.** Each session gets its own sandbox rather than a
  replica of a shared, fixed worker image, so a repository that needs Python
  gets an image that has Python instead of failing preflight.
- **Default-deny, capability-scoped egress.** A class declares
  `defaultAction: Deny` plus an ordered allowlist, applied before any repository
  code runs, and a manifest may only **narrow** it. Feasibility testing measured
  allowlisted hosts returning `200`, non-allowlisted hosts returning `403`, and
  raw non-HTTP TCP refused, with an auditable allow/deny trail from
  `aca sandbox egress decisions`.

Both come at a cost worth understanding before a third party's data goes through
a sandbox: enforcing an allowlist on hostnames and paths requires terminating
TLS, so `trafficInspection: Full` means the inspecting proxy is inside the trust
boundary and sees plaintext request bodies. See
[runbook.md, incident R3](runbook.md#r3--trafficinspection-full-means-tls-interception).

## Where to go next

- [runbook.md — ACA Sandboxes](runbook.md#aca-sandboxes-preview-feature-flagged-off):
  [prerequisites](runbook.md#prerequisites),
  [credentials](runbook.md#credentials-four-planes-kept-separate),
  [concurrency, cost and orphans](runbook.md#concurrency-cost-and-orphans),
  [operating notes](runbook.md#operating-notes),
  [adding or re-pinning a class image](runbook.md#adding-or-re-pinning-a-sandbox-class-image),
  and the [incident runbook](runbook.md#incident-runbook).
- [architecture.md — ACA Sandboxes provider](architecture.md#aca-sandboxes-provider-feature-flagged-default-off):
  the provider boundary, the route gate, and the security invariants.
- [capability-manifest.md — Capability routing](capability-manifest.md#capability-routing):
  the manifest schema, the routing contract, and
  [the sandbox class catalog](capability-manifest.md#the-sandbox-class-catalog).
- [rollback.md — ACA Sandboxes](rollback.md#2-aca-sandboxes-feature-flagged-preview):
  the rollback procedure and its verification checklist.
- [adr/0001-aca-sandboxes-feasibility.md](adr/0001-aca-sandboxes-feasibility.md):
  the feasibility evidence and the decision to adopt the plane as opt-in.
