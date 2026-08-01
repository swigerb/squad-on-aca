# lead History

## 2026-08-01: Planning pass on the four capability-manifest "future work" efforts

Planning only, on branch `docs/future-work-plan` from `main` at `17541eb`. No
implementation code: nothing under `worker/lib/`, `scripts/lib/`, or
`.github/workflows/` was touched. Produced
`docs/adr/0003-capability-manifest-future-work.md` (decision record) and
`docs/plans/capability-manifest-future-work.md` (sprint plan), and corrected the
"What's deliberately out of scope in this phase" section of
`docs/capability-manifest.md` rather than deleting it.

**The section was checked claim by claim before anything was scheduled, and four
claims were stale.** The most important correction is that the packaging item is
not deferred work — it is a live defect. `scripts/deploy.ps1` runs Ralph as a
`*/5 * * * *` ACA job on the worker image; `worker/lib/ralph-dispatch.sh` calls
`squad-dispatch.js decide` for every candidate issue; and `catalogSearchPaths()`
looks only at `<__dirname>/sandbox-classes.json` and
`<__dirname>/../../config/sandbox-classes.json`, neither of which exists in the
image. Reproduced by copying only the files `worker/Dockerfile` copies into a
throwaway directory and running the shipped entry point exactly as Ralph does:
exit **70**, `route: fail-closed`, `reason: catalog-unavailable`,
`action: refuse`. Ralph then logs `routing refused or unavailable ... skipping
without labeling` — indistinguishable from a legitimate capability refusal. The
reason 911 assertions missed it is the `--trigger-label squad` defect one layer
down: every routing assertion in `test_capability_routing.sh` passes
`--catalog "$CATALOG"` explicitly, and `test_dispatch_contract.sh` and
`test_ralph_dispatch.sh` export `SQUAD_DISPATCH_CLI="${WORKER_DIR}/lib/..."`, so
the repo-relative fallback resolves and the default search path is exercised only
in the failing direction.

**Egress was stale in both directions.** `New-SandboxEgressPolicy` already
generates a manifest-narrowed, provenance-checked, default-deny policy on the
Sandboxes plane, so "advisory today" is wrong there. On the Jobs plane it is
worse than advisory: `defaultWorker.egress` is
`{"defaultAction": "Allow", "hostRules": []}`, so a manifest declaring
`egress: [{host: evil.example.com}]` with only `git` required resolves to
`route: aca-job`, `reason: default-profile-satisfies-manifest`,
`unsatisfiedEgressHosts: []` — a positive, machine-readable claim of a control
that does not exist. Reproduced with the resolver. `squad-aca-job-provider.ps1`
contains no egress logic (`egress` appears twice, both unrelated comments) and
the Container Apps environment is not VNet-injected, so per-task enforcement on
Jobs was **rejected** rather than deferred; sprint 3 builds the honesty half
only.

**Credentials: deferred with no sprint, and I said so rather than inventing
one.** The consumption side is fully built and proven (credential helper, token
preflight, `0600` delivery, sandbox refresh); minting is blocked on a private key
that was deleted, Key Vault is unusable in this tenant, and a non-refreshable
3600-second token on the Jobs plane would refuse sessions that succeed today.
The only candidate sprint that needed no private key — having the control plane
set `SQUAD_TOKEN_EXPIRES_AT` — was rejected as decorative, because with a classic
PAT there is no truthful value to set (verified: nothing in the tree sets that
variable, so the preflight's lifetime gate is presently dormant). The
run-duration precondition is answerable with **no code** from `startedAt` /
`updatedAt` on existing lease records.

Every sprint carries a mutation table naming what must be broken and which named
assertion must fail, with both directions required for every boolean claim and an
explicit rule that a test may not pass an override production does not pass.
Three abandon conditions are stated, including "if criterion 3 cannot be made to
hold, abandon sprint 2 and keep the duplication" — unification of the manifest-path
logic creates a fail-open failure mode that does not exist today.

**Unverified and recorded as such:** whether adding the catalog to the image
breaks digest-keyed evidence for the self-referentially pinned `sandbox-node-lts`
class; whether any consumer compares the decision `schemaVersion` for equality;
whether Ralph currently finds candidates at all, given `deploy.ps1` still sets
`RALPH_LABELS=squad` while issue #32 moved dispatch to `squad-aca`. No Azure
access was used in this pass.

**Evidence.** Documentation only. `scripts/validate.ps1`: **363 passed / 0
failed / 0 skipped**, identical to the baseline captured before any edit.
Markdown links: **94 checked, 0 broken** (up from 79; 15 links added, no
existing link or heading changed). No secrets, tokens, or subscription/tenant
GUIDs beyond identifiers already present in the repository.
