# ADR 0001: SandboxGroups feasibility gate for Sprint 0

## Status

Proposed

## Context

Upstream issue [swigerb/squad-on-aca#6](https://github.com/swigerb/squad-on-aca/issues/6) proposes Azure Container Apps (ACA) SandboxGroups as an **opt-in** execution provider, while the upstream repo owner's follow-up explicitly preserves ACA Jobs as the default substrate and rollback path and authorizes **Sprints 0-2 only** at this time.[^owner-comment]

Sprint 0 is an evidence-gathering gate, not an implementation sprint.[^owner-comment] This working repository is `tamirdresher/squad-on-aca`, and it is carrying out the authorized Sprints 0-2 implementation work under that upstream direction while still implementing ACA Jobs, not SandboxGroups, as reflected in this repo's existing feature-parity and runbook docs.[^feature-parity][^runbook]

Because this environment has no live Azure subscription access, this ADR records only documented evidence gathered from Microsoft Learn, the official ACA Sandboxes portal docs, and the repo owner's issue comment. It does **not** claim that we personally executed a create/readiness/cancel/delete spike.

## Decision

**Conditional GO for Sprints 0-2 only.**[^owner-comment]

- **Sprint 0:** complete feasibility research and decision capture.
- **Sprint 1:** capability resolution may proceed, but must remain provider-selection logic only.
- **Sprint 2:** provider abstraction may proceed, but must preserve ACA Jobs as the default behavior and rollback substrate.[^owner-comment]
- **Sprints 3+ are not authorized by this ADR.** They require re-evaluation after the BLOCKED/UNKNOWN items below are resolved with live Azure evidence and security review.[^owner-comment]

### Sprint-0 architectural guardrails

1. **State store:** keep future lifecycle state provider-neutral and external to any individual sandbox. No Azure-specific backend is selected in Sprint 0 because no verifiable SandboxGroups-specific guidance was found for claims/leases/TTL ownership.[^owner-comment]
2. **Identities:** any future sandbox runtime must use a sandbox-group-scoped managed identity with least privilege, separate from the current ACA Jobs/Ralph control-plane identity.[^identity-doc][^owner-comment]
3. **Credentials:** Sprint 3+ must not assume long-lived GitHub or Copilot PATs inside sandboxes. No verifiable official short-lived GitHub/Copilot credential pattern was found as of this writing, so this remains unresolved.[^owner-comment]
4. **Networking:** future sandbox execution should assume deny-by-default egress with explicit allow rules, and use VNet connections only when private-resource reachability is required.[^egress-doc][^vnet-doc]
5. **Sandbox class ownership:** repository manifests may request capabilities, but only administrator-approved sandbox classes may map those requests to images, identities, networking, and policies.[^owner-comment]

## Evidence

| Question | Evidence Found | Source / URL | Gate |
| --- | --- | --- | --- |
| What is the published status of SandboxGroups? | Official docs describe ACA Sandboxes as **preview** and warn that API/CLI/SDK surfaces may change and preview-created sandboxes may need recreation later. | Microsoft Learn Sandboxes overview: <https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview> | PASS |
| Is the published API/resource-provider story internally consistent? | No. The overview and portal quickstarts scope groups as `Microsoft.App/sandboxGroups`, while ARM template and REST references publish `Microsoft.ContainerInstance/sandboxGroups` preview APIs. | Overview: <https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview>; Python quickstart: <https://sandboxes.azure.com/docs/sandboxes/quickstart/setup-python-sdk>; ARM template: <https://learn.microsoft.com/en-us/azure/templates/microsoft.containerinstance/sandboxgroups>; REST create: <https://learn.microsoft.com/en-us/rest/api/container-instances/sandbox-groups/create-or-update?view=rest-container-instances-2026-07-01> | BLOCKED |
| Is there an official create/readiness signal? | Yes. Group docs say state moves `Creating -> Succeeded`; sandbox docs expose `Running` state and SDK `wait_for_running(timeout=120)` examples. | Group docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox-groups/>; lifecycle docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox/lifecycle> | PASS |
| Is there official evidence for bounded readiness timing? | Only preview quickstarts/portal docs: group provisioning is described as “about a second,” cold boot as “~2 seconds,” and resume as “~2 seconds,” but no SLA/SLO or region-specific bound was found. | Portal quickstart: <https://sandboxes.azure.com/docs/sandboxes/quickstart/setup-portal> | UNKNOWN |
| Is there official create/run evidence? | Yes, official quickstarts show creating a sandbox group, `begin_create_sandbox(...).result()`, running `exec`, and deleting the sandbox. | Python quickstart: <https://sandboxes.azure.com/docs/sandboxes/quickstart/setup-python-sdk> | PASS |
| Is sandbox stop/resume/delete documented? | Yes. Official lifecycle docs show `stop`, `resume`, `wait_for_running`, and lifecycle policies; group docs show group deletion. | Lifecycle: <https://sandboxes.azure.com/docs/sandboxes/sandbox/lifecycle>; group docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox-groups/> | PASS |
| Is delete idempotency documented? | Partially. REST delete for sandbox groups returns `204 No Content` when the group does not exist, which is idempotent at the group ARM layer. No equally explicit idempotency statement was found for individual sandbox delete/stop APIs. | REST delete: <https://learn.microsoft.com/en-us/rest/api/container-instances/sandbox-groups/delete?view=rest-container-instances-2026-07-01>; group docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox-groups/> | UNKNOWN |
| Is there documented support for default-deny egress? | Yes. Official egress docs show `--default Deny`, explicit allow rules, and `Full` traffic inspection. | Egress docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox/egress> | PASS |
| Is there documented support for VNet/private reachability? | Yes. Official docs show group-level VNet connections and a private-endpoint verification flow from inside a sandbox. | VNet docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox/vnet> | PASS |
| Is identity assignment documented? | Yes. Official docs show system-assigned and user-assigned identities on sandbox groups, plus data-plane role assignment requirements. | Identity docs: <https://sandboxes.azure.com/docs/sandboxes/identity>; group docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox-groups/> | PASS |
| Is identity **isolation** from control-plane identity / metadata endpoints demonstrated? | No verifiable evidence found as of this writing. Docs describe strong isolation and group identities, but do not explicitly prove denial of control-plane identity or metadata endpoint access from sandbox runtimes. | Overview: <https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview>; identity docs: <https://sandboxes.azure.com/docs/sandboxes/identity> | UNKNOWN |
| Is regional availability published as a SandboxGroups matrix? | No verifiable SandboxGroups-specific region matrix was found. Generic ACA FAQ points to a provider query for ACA managed environments, not sandboxes specifically. | ACA FAQ: <https://learn.microsoft.com/en-us/azure/container-apps/faq> | UNKNOWN |
| Are sandbox-specific quotas published? | No verifiable SandboxGroups-specific quota table was found. Published ACA quotas cover environments, cores, GPUs, and dynamic sessions, but not sandbox-group or per-sandbox limits. | ACA quotas: <https://learn.microsoft.com/en-us/azure/container-apps/quotas> | UNKNOWN |
| Is pricing documented? | Partially. Azure pricing says **“Azure Container Apps Express and Sandboxes follow the same pay-per-second pricing as Consumption Plan.”** The billing/pricing pages do not provide a separate SandboxGroups matrix beyond that model. | Pricing: <https://azure.microsoft.com/en-us/pricing/details/container-apps/>; billing: <https://learn.microsoft.com/en-us/azure/container-apps/billing> | PASS |
| Is external-delete detection/recovery documented? | No verifiable evidence found as of this writing. Official docs show list/get/delete, but no documented recovery contract for sandboxes deleted outside the control plane. | Group docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox-groups/>; lifecycle docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox/lifecycle> | UNKNOWN |
| Is rollback to ACA Jobs still available? | Yes. The repo already runs on ACA Jobs today, and the upstream owner explicitly requires Jobs to remain the default substrate and rollback path for this implementation repo as well. | Upstream owner comment on `swigerb/squad-on-aca#6`: <https://github.com/swigerb/squad-on-aca/issues/6#issuecomment-4987504741>; this repo's feature parity: <https://github.com/tamirdresher/squad-on-aca/blob/main/docs/feature-parity.md> | PASS |

## Validation Gates

1. **Sandbox can be created and reaches readiness within a bounded timeout — UNKNOWN**  
   Official docs show readiness states and quickstarts claim fast provisioning/cold boot, but we did not run a live Azure spike here and found no SLA/SLO-quality bound that we can verify from documentation alone.[^group-doc][^lifecycle-doc][^portal-quickstart]

2. **Sandbox can be cancelled/deleted idempotently — UNKNOWN**  
   Group delete looks idempotent at the ARM layer (`204` when absent), and sandbox stop/delete operations are documented, but we found no explicit official idempotency guarantee for individual sandbox lifecycle operations.[^rest-delete][^lifecycle-doc]

3. **External deletion can be detected and recovered — UNKNOWN**  
   No verifiable official recovery contract was found for sandboxes or groups deleted outside `squad-aca`.[^group-doc]

4. **Network and identity isolation are demonstrated — UNKNOWN**  
   The platform documents strong isolation, deny-by-default egress, traffic inspection, VNet attachment, and group-scoped managed identities, but we found no official proof that sandbox runtimes cannot reach control-plane identity/metadata surfaces, and we did not run live isolation tests.[^overview][^egress-doc][^vnet-doc][^identity-doc]

5. **Rollback to ACA Jobs remains available — PASS**  
   ACA Jobs are the repo's current implementation and the owner's explicit required rollback path; this documentation-only Sprint 0 work does not change that.[^owner-comment][^feature-parity][^runbook]

## Consequences

- Sprints 1-2 can proceed only as **non-runtime** work: capability resolution and provider abstraction that keep ACA Jobs as the default behavior.[^owner-comment]
- Sprint 3+ must pause until Azure evidence resolves the BLOCKED/UNKNOWN items above, especially API consistency, regional availability, quota visibility, credential strategy, and identity-isolation proof.
- The safest near-term architecture remains:
  - ACA Jobs for real execution and rollback.[^owner-comment]
  - SandboxGroups treated as a preview provider under explicit feature flagging only after re-approval.[^owner-comment]
  - Administrator-owned sandbox classes, not repository-owned privilege escalation.[^owner-comment]

## Open Questions

Carried forward from the upstream repo owner's comment, with current Sprint 0 disposition for this implementation repo:[^owner-comment]

1. **API stability — PARTIALLY ANSWERED / STILL OPEN.** Preview is confirmed, but official docs currently disagree on `Microsoft.App/sandboxGroups` vs `Microsoft.ContainerInstance/sandboxGroups`.[^overview][^arm-template][^rest-create]
2. **Regional availability — OPEN.** No verifiable SandboxGroups region matrix found.[^faq]
3. **Quota and pricing — PARTIALLY ANSWERED / STILL OPEN.** Pricing model is published as Consumption-plan-equivalent, but sandbox-specific quota limits were not found.[^pricing][^quotas]
4. **Readiness semantics — PARTIALLY ANSWERED / STILL OPEN.** Readiness states and example timings exist, but no verified production bound was found.[^group-doc][^lifecycle-doc][^portal-quickstart]
5. **Cancellation/deletion semantics — PARTIALLY ANSWERED / STILL OPEN.** Lifecycle operations are documented, but sandbox-level idempotency remains undocumented.[^lifecycle-doc][^rest-delete]
6. **External-delete recovery — OPEN.** No recovery contract found.[^group-doc]
7. **Networking — PARTIALLY ANSWERED / STILL OPEN.** Deny-by-default egress and VNet connectivity are documented; live proof for this workload remains outstanding.[^egress-doc][^vnet-doc]
8. **Identity isolation — OPEN.** Managed identity attachment is documented, but runtime isolation from control-plane identity/metadata endpoints is not proven.[^identity-doc][^overview]
9. **Credential injection — OPEN.** No verifiable official short-lived GitHub/Copilot credential pattern found.
10. **State store — OPEN.** No platform guidance found for `squad-aca` claims/leases/TTL storage; select this before durable lifecycle work.
11. **Sandbox class ownership — PARTIALLY ANSWERED / STILL OPEN.** Policy direction is clear: administrator-approved classes only, but the owning team/process is still a project decision.[^owner-comment]
12. **Logs and telemetry — OPEN.** Network audit exists, but provider-neutral status/log handling without secret leakage is not yet answered.[^egress-doc]
13. **Rollback — ANSWERED.** ACA Jobs remain the required default and rollback path.[^owner-comment]
14. **Failure taxonomy — OPEN.** No official mapping found for fail-closed vs retry vs fallback decisions.
15. **Security review — OPEN.** Required before production sandbox use.[^owner-comment]

[^owner-comment]: Upstream repo owner follow-up on `swigerb/squad-on-aca#6`, authorizing Sprints 0-2 work now being implemented in `tamirdresher/squad-on-aca`: <https://github.com/swigerb/squad-on-aca/issues/6#issuecomment-4987504741>
[^feature-parity]: Existing feature parity doc in this repo: <https://github.com/tamirdresher/squad-on-aca/blob/main/docs/feature-parity.md>
[^runbook]: Existing runbook in this repo: <https://github.com/tamirdresher/squad-on-aca/blob/main/docs/runbook.md>
[^overview]: Microsoft Learn Sandboxes overview: <https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview>
[^group-doc]: ACA Sandboxes group docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox-groups/>
[^lifecycle-doc]: ACA Sandboxes lifecycle docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox/lifecycle>
[^portal-quickstart]: ACA Sandboxes portal quickstart: <https://sandboxes.azure.com/docs/sandboxes/quickstart/setup-portal>
[^python-quickstart]: ACA Sandboxes Python quickstart: <https://sandboxes.azure.com/docs/sandboxes/quickstart/setup-python-sdk>
[^egress-doc]: ACA Sandboxes egress docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox/egress>
[^vnet-doc]: ACA Sandboxes VNet docs: <https://sandboxes.azure.com/docs/sandboxes/sandbox/vnet>
[^identity-doc]: ACA Sandboxes identity docs: <https://sandboxes.azure.com/docs/sandboxes/identity>
[^pricing]: Azure Container Apps pricing: <https://azure.microsoft.com/en-us/pricing/details/container-apps/>
[^billing]: Azure Container Apps billing: <https://learn.microsoft.com/en-us/azure/container-apps/billing>
[^quotas]: Azure Container Apps quotas: <https://learn.microsoft.com/en-us/azure/container-apps/quotas>
[^faq]: Azure Container Apps FAQ: <https://learn.microsoft.com/en-us/azure/container-apps/faq>
[^arm-template]: ARM template reference for sandboxGroups: <https://learn.microsoft.com/en-us/azure/templates/microsoft.containerinstance/sandboxgroups>
[^rest-create]: REST create/update for sandbox groups: <https://learn.microsoft.com/en-us/rest/api/container-instances/sandbox-groups/create-or-update?view=rest-container-instances-2026-07-01>
[^rest-delete]: REST delete for sandbox groups: <https://learn.microsoft.com/en-us/rest/api/container-instances/sandbox-groups/delete?view=rest-container-instances-2026-07-01>
