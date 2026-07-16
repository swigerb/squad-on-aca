# SandboxGroups feasibility (Sprint 0)

This document summarizes the Sprint 0 feasibility gate for ACA SandboxGroups. The formal decision record is [ADR 0001](adr/0001-sandboxgroups-feasibility.md).

The authorization source is upstream `swigerb/squad-on-aca`, where issue `swigerb/squad-on-aca#6` and the owner's conditional-GO comment were filed; the implementation work summarized here is happening in this repository, `tamirdresher/squad-on-aca`.[^owner-comment]

## Bottom line

- **Authorized now:** Sprints **0-2 only**.[^owner-comment]
- **Not authorized now:** Sprints **3-6** (actual SandboxGroups execution, durable lifecycle, and production security hardening).[^owner-comment]
- **Current implementation in this repo:** ACA Jobs remain the only implemented execution plane.[^feature-parity][^runbook]
- **Current decision:** treat SandboxGroups as a preview provider candidate, not a replacement for ACA Jobs.[^owner-comment]

## What we were able to verify

| Topic | What the docs say | Verdict |
| --- | --- | --- |
| Status | SandboxGroups / ACA Sandboxes are in **preview**, and Microsoft warns the API/CLI/SDK surface may change. | PASS |
| Basic lifecycle | Official docs show create, `Running`, stop, resume, snapshots, delete, and group `Creating -> Succeeded` lifecycle states. | PASS |
| Networking controls | Official docs show deny-by-default egress, traffic inspection, network audit, VNet attachment, and private-endpoint verification flows. | PASS |
| Identity attachment | Official docs show system-assigned and user-assigned identities on sandbox groups plus explicit data-plane RBAC. | PASS |
| Pricing model | Azure pricing says Sandboxes follow the same pay-per-second model as ACA Consumption. | PASS |
| Rollback path | ACA Jobs remain the repo's default execution substrate and fallback path. | PASS |

## What is still unresolved

| Topic | Why unresolved | Verdict |
| --- | --- | --- |
| API stability | Official docs currently disagree on `Microsoft.App/sandboxGroups` vs `Microsoft.ContainerInstance/sandboxGroups`. | BLOCKED |
| Regional matrix | No verifiable SandboxGroups-specific supported-region matrix was found. | UNKNOWN |
| Quotas | No verifiable SandboxGroups-specific quota table was found. | UNKNOWN |
| Bounded readiness | Quickstarts claim very fast create/resume times, but we did not run a live spike and found no SLA-quality bound. | UNKNOWN |
| Delete idempotency | Group delete looks idempotent at ARM level, but sandbox-level idempotency is not clearly documented. | UNKNOWN |
| External delete recovery | No official recovery contract was found. | UNKNOWN |
| Identity isolation proof | Docs show strong isolation and managed identity support, but not explicit proof that sandbox runtimes cannot reach control-plane identity/metadata surfaces. | UNKNOWN |
| GitHub/Copilot short-lived credentials | No verifiable official credential-injection pattern was found for this use case. | UNKNOWN |

## Validation gates

- **Sandbox can be created and reaches readiness within a bounded timeout:** **UNKNOWN**
- **Sandbox can be cancelled/deleted idempotently:** **UNKNOWN**
- **External deletion can be detected and recovered:** **UNKNOWN**
- **Network and identity isolation are demonstrated:** **UNKNOWN**
- **Rollback to ACA Jobs remains available:** **PASS**

## Engineering guidance for this repo

1. **Do not implement SandboxGroups execution in this repository yet.**
2. **Do keep Sprint 1-2 work provider-neutral**: capability resolution and provider abstraction only.[^owner-comment]
3. **Do preserve ACA Jobs as the default path and rollback path.**[^owner-comment]
4. **Do assume sandbox classes are admin-owned**, not repository-owned privilege grants.[^owner-comment]
5. **Do plan for deny-by-default egress and least-privilege identities** if SandboxGroups execution is ever approved later.[^egress-doc][^identity-doc]

## Important explicit non-goal

**SandboxGroups execution is not enabled or implemented anywhere in this codebase by Sprint 0.** This repo still executes Squad sessions through ACA Jobs today.[^feature-parity][^runbook]

## Sources

- Upstream repo owner Sprint plan and open questions on `swigerb/squad-on-aca#6`: <https://github.com/swigerb/squad-on-aca/issues/6#issuecomment-4987504741>
- Formal ADR: [ADR 0001](adr/0001-sandboxgroups-feasibility.md)
- Microsoft Learn Sandboxes overview: <https://learn.microsoft.com/en-us/azure/container-apps/sandboxes-overview>
- ACA Sandboxes portal docs: <https://sandboxes.azure.com/docs/sandboxes/>
- Azure pricing: <https://azure.microsoft.com/en-us/pricing/details/container-apps/>

[^owner-comment]: Upstream repo owner follow-up on `swigerb/squad-on-aca#6`, authorizing Sprints 0-2 work now being implemented in `tamirdresher/squad-on-aca`: <https://github.com/swigerb/squad-on-aca/issues/6#issuecomment-4987504741>
[^feature-parity]: <https://github.com/tamirdresher/squad-on-aca/blob/main/docs/feature-parity.md>
[^runbook]: <https://github.com/tamirdresher/squad-on-aca/blob/main/docs/runbook.md>
[^egress-doc]: <https://sandboxes.azure.com/docs/sandboxes/sandbox/egress>
[^identity-doc]: <https://sandboxes.azure.com/docs/sandboxes/identity>
