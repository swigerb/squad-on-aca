# ADR 0001 — Azure Container Apps Sandboxes feasibility

- **Status:** Accepted — **GO**
- **Date:** 2026-07-28
- **Deciders:** Squad (lead, engineer, security), repository owner
- **Context:** PRD [#6](https://github.com/swigerb/squad-on-aca/issues/6) — adding an opt-in, capability-aware execution plane alongside ACA Jobs
- **Supersedes:** the Sprint 0 ADR proposed in PR [#9](https://github.com/swigerb/squad-on-aca/pull/9) (closed), which recorded 4 of 5 gates as `UNKNOWN`

## Context

PRD #6 proposes routing some remote Squad sessions to isolated sandboxes instead
of the single fixed-image ACA Job. That proposal only holds if the underlying
service can actually satisfy the PRD's security invariants — in particular
**invariant 3** (default-deny, capability-scoped egress) and **invariant 4**
(control-plane credentials never reachable from inside the sandbox).

PR #9 could not answer those questions and honestly recorded them as `UNKNOWN`.
This ADR resolves them with evidence captured live against a real subscription.

### Naming correction

The PRD refers to "ACA SandboxGroups". Two corrections matter for implementation:

1. The product is **Azure Container Apps Sandboxes** (public preview, announced
   2026-06-02). The ARM resource type is `Microsoft.App/sandboxGroups`
   (api-version `2026-02-01-preview`), with child type
   `sandboxGroups/vnetConnections`.
2. It is **not** `Microsoft.App/sessionPools` (dynamic sessions), which is a
   different and older product. Microsoft positions Sandboxes as the next
   evolution of dynamic sessions. An earlier research pass in this programme
   conflated the two and reached the wrong conclusions; that analysis was
   discarded.

## Evidence

Captured 2026-07-28/29 against subscription `3898b8ea-c676-4b43-95fc-d38425627d74`
(tenant `197e89d9-8805-4125-8caa-30120a6201c7`), resource group
`rg-squad-aca-dev-eastus2`, using `aca` CLI `1.0.0-preview.1`
(installer SHA-256 verified `d52f60a3…ab034`).

### G1 — Resource type and region — PASS

`Microsoft.App/sandboxGroups` is registered and `eastus2` — the repo's default
deploy region (`scripts/deploy.ps1 -Location eastus2`) — is supported. No region
change is required.

### G2 — Group provisioning — PASS

`aca sandboxgroup create --name sbg-squad-aca --location eastus2` reached
`provisioningState: Succeeded`.

```json
"properties": {
  "allowedLocations": ["eastus2"],
  "connections": [],
  "managementEndpoint": "https://management.eastus2.azuredevcompute.io",
  "provisioningState": "Succeeded"
}
```

**The data plane is not ARM.** Sandboxes, exec, files, and egress live on
`management.{region}.azuredevcompute.io`. `az rest` reaches the *group* only.
Consequently there are no `az containerapp sandbox` commands, and the sandbox
lifecycle must be driven by the standalone `aca` binary or the Python SDK.

### G3 — Invariant 4: control-plane credentials unreachable — PASS (conditionally)

The group was created **without** a managed identity; the ARM resource has no
`identity` property.

Identity environment variables are nonetheless injected into every sandbox:

```
IDENTITY_ENDPOINT=http://100.64.100.2/msi/token
IDENTITY_HEADER=<redacted>
```

Their presence is misleading, but the endpoint **fails closed**:

```json
{"error":"unauthorized_client",
 "error_description":"Sandbox does not have an associated sandbox group with managed identity"}
```

Raw IMDS (`169.254.169.254`) returned empty for both the instance-metadata and
token endpoints. No token was obtainable by any path tested.

**Invariant 4 holds — but only while the group has no managed identity.**

### G4 — Invariant 3: default-deny, capability-scoped egress — PASS

Egress policy is native and per-sandbox. No NSG, UDR, or firewall appliance is
required.

```json
{"defaultAction": "Deny",
 "hostRules": [{"pattern": "*.github.com", "action": "Allow"},
               {"pattern": "registry.npmjs.org", "action": "Allow"}],
 "trafficInspection": "Full"}
```

| Probe | Expected | Observed |
|---|---|---|
| `https://api.github.com/rate_limit` (allowlisted) | allowed | **200** |
| `https://registry.npmjs.org/express` (allowlisted) | allowed | **200** |
| `https://example.com` (not allowlisted) | blocked | **403** |
| Raw TCP `/dev/tcp/1.1.1.1/53` (non-HTTP) | blocked | **Connection refused** |

Raw non-HTTP TCP is blocked, so this is a genuine egress boundary rather than an
HTTP-proxy allowlist.

`aca sandbox egress decisions` returns a structured allow/deny audit trail with
timestamp, host, method, path, scheme, and `matchedRule`, satisfying the PRD's
requirement that every allowed and denied outbound request be auditable.

### G5 — Rollback remains available — PASS

The ACA Jobs path is untouched and remains the default. `caj-squad-aca-session`
and `caj-squad-aca-ralph` are deployed and healthy, and a live smoke dispatch
succeeded during the same session.

## Decision

**GO.** Proceed with ACA Sandboxes as an opt-in execution plane, keeping ACA Jobs
as the default and the rollback path, exactly as PRD #6 specifies.

Both hard security invariants are satisfiable natively — and are in fact
*stronger* than what the current ACA Jobs plane provides, since Jobs offer
neither scoped egress nor per-run isolation.

## Consequences

Binding constraints for later sprints:

1. **Squad workers run in a dedicated, identity-free sandbox group.** Managed
   identity is group-scoped and there is no documented way to opt one sandbox out
   of its group's identity. Microsoft's own `sandbox-inception` sample uses
   `ManagedIdentityCredential()` *inside* a sandbox to manage sibling sandboxes —
   the same capability an attacker would get. CI must assert `identity` is absent
   on the squad group. Do **not** attach a user-assigned identity for ACR pull.
2. **`aca` is a runtime dependency** of the sandbox provider, pinned by version
   and checksum. It is a dependency-free static binary, so this is tractable;
   the broken `containerapp` az extension is not a blocker.
3. **`trafficInspection: Full` implies TLS interception.** It is mandatory for
   default-deny, so the egress proxy is inside the trust boundary and must be
   documented as such.
4. **Egress rule values are readable to anyone with group read access.** RBAC on
   the group must be scoped to the orchestrator, and `egress show`/`export`
   output must never be logged.
5. **Preview, with no SLA.** PRD #6's opt-in, feature-flagged design is the
   correct posture. ACA Jobs stay the default until this matures.

## Risks carried forward

| ID | Risk | Rating | Mitigation |
|---|---|---|---|
| R1 | Group-scoped MI reachable from inside a sandbox | HIGH | Dedicated identity-free group; CI asserts `identity` absent |
| R2 | Egress rule values readable with group read access | HIGH | Scope RBAC to orchestrator; never log egress policy dumps |
| R3 | `trafficInspection: Full` terminates TLS | MEDIUM | Document proxy as in-trust-boundary; verify issuer |
| R4 | Auto-suspend may fire during long runs | MEDIUM | Set explicit idle timeout; verify with a long-run probe |
| R5 | No Terraform/.NET SDK; data-plane REST undocumented | MEDIUM | Pin `aca` binary by version + checksum |
| R7 | Leaked sandboxes on abnormal exit | LOW-MED | Label-based reaper, auto-delete policy, push-before-teardown |
| R8 | Preview instability, no SLA | MEDIUM | Feature flag; ACA Jobs remain default and rollback |

## Open questions deferred

- Cold-start and allocation latency with the real (large) `squad-worker` image.
- Whether a long `exec` can be interrupted by auto-suspend, and whether the
  worker must therefore be launched detached with status polling.
- Private ACR pull without attaching a group identity (fallback: publish the
  image to a public registry).
- Snapshot retention, cost after preview, and per-subscription quotas.
