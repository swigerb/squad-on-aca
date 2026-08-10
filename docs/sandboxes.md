# ACA Sandboxes

Azure Container Apps Sandboxes are a second execution plane for Squad sessions, alongside ACA Jobs. They provide per-session isolation and default-deny, capability-scoped egress.

ACA Jobs remain the default and rollback path. Sandboxes are Azure public preview, off by default, and enabled per invocation.

## Current behavior

`squad-aca run` reads `squad-capabilities.yml` from the local working tree before requesting compute, resolves it through the shared Node routing core, and dispatches to the plane named by the decision.

- A repository whose manifest an approved sandbox class satisfies runs in a sandbox.
- `sessions`, `logs`, and `stop` address that session through its opaque execution handle.
- A repository with no manifest, or one the default worker image satisfies, runs on ACA Jobs.
- With the flag off, a repository that needs a non-default capability is refused with `sandbox-feature-disabled-and-default-insufficient`.

The in-worker capability preflight (`worker/lib/squad-capability-preflight.sh`) still runs inside the image that starts.

## Prerequisites

| Requirement | Details |
| --- | --- |
| Standalone `aca` CLI v1.0.0-preview.1 or later | Sandboxes are not driven by `az`. Resolution order is `SQUAD_ACA_SANDBOX_CLI`, then `aca` on `PATH`, then `~/.aca/bin/aca.exe`. |
| Sandbox group with no managed identity | Create the group without `--identity`. The provider verifies this before dispatch. |
| Disk built from an approved class image | `--disk` accepts public images only, so use `--disk-id <GUID>` for private images. Take the GUID from `aca sandboxgroup disk list -o json`. |
| `sandboxGroup` and `sandboxDiskId` in `~/.squad-on-aca/config.json` | These values are passed to the provider by name. |

One disk serves the configured deployment. Build the disk from the image your repositories will select, or configure a separate deployment.

Full commands are in [runbook.md#aca-sandboxes-preview-feature-flagged-off](runbook.md#aca-sandboxes-preview-feature-flagged-off).

## Enable it

```powershell
$env:SQUAD_ACA_ENABLE_SANDBOX = "1"     # accepted: 1 / true / yes / on / enabled
squad-aca run "<prompt>"
```

`0`, `false`, `no`, and `off` explicitly disable the plane.

Run `squad-aca` from the working tree of the repository you are dispatching. If `--repo` names a different repository, the control plane cannot read the local manifest and uses the default ACA Jobs route. The CLI prints a `Capability routing read no manifest for …` warning.

## Interlocks

Both interlocks must permit a sandbox route:

1. `SQUAD_ACA_ENABLE_SANDBOX` must be enabled.
2. `config/sandbox-classes.json` must have `"provisional": false` and approved classes pinned by digest.

A deployment without `sandboxGroup` and a disk id cannot reach the plane.

The shipped catalog includes an unapproved `sandbox-container-build` class as a validation fixture. A repository manifest can request capabilities only. It cannot add a class, add an egress destination, widen a credential list, or name an execution image.

## Credential refresh

GitHub App installation tokens have a one-hour TTL. The worker reads its token through `worker/lib/squad-git-credential-helper.sh`, which re-reads a `0600` token file on every git operation.

| Plane | Mid-session refresh |
|---|---|
| ACA Sandboxes | Yes. `aca sandbox fs write` can update the credential file in a running sandbox. |
| ACA Jobs | No. There is no exec or file channel into a running job execution. |

Under ACA Jobs, `worker/lib/squad-token-preflight.sh` checks credential lifetime against `SQUAD_ESTIMATED_RUN_MINUTES` before the agent starts.

Push failure classification:

| Situation | git exit | Classified | What happens |
|---|---|---|---|
| Token rejected | `128` | `auth` | Re-read the token file, retry once, then exit `77` if it still fails. |
| Branch ruleset refusal | `1` | `execution` | Propagated unchanged. |

## Plane capabilities

| Capability | ACA Jobs | ACA Sandboxes |
| --- | --- | --- |
| Per-session image class | Fixed worker image | Approved class image |
| Egress policy | Advisory only | Default-deny allowlist before repository code |
| Lifecycle | ACA job execution | Sandbox create, detached launch, poll, stop, delete |
| Credential delivery | ACA secrets | Per-session file upload or native brokerage |

## Links

- [runbook.md#aca-sandboxes-preview-feature-flagged-off](runbook.md#aca-sandboxes-preview-feature-flagged-off)
- [architecture.md#aca-sandboxes-provider](architecture.md#aca-sandboxes-provider)
- [capability-manifest.md#capability-routing](capability-manifest.md#capability-routing)
- [rollback.md#2-aca-sandboxes-feature-flagged-preview](rollback.md#2-aca-sandboxes-feature-flagged-preview)
