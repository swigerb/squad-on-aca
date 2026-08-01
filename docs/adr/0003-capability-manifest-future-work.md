# ADR 0003 — Disposition of the four capability-manifest "future work" efforts

- **Status:** Accepted — **planning only**; three efforts scheduled, one deferred
- **Date:** 2026-08-01
- **Deciders:** Squad (lead), repository owner
- **Context:** `docs/capability-manifest.md`, section
  "[What's deliberately out of scope in this phase](../capability-manifest.md#whats-deliberately-out-of-scope-in-this-phase)",
  which names four follow-on efforts
- **Companion:** [docs/plans/capability-manifest-future-work.md](../plans/capability-manifest-future-work.md)
  is the sprint plan this ADR authorises. This document records *why*; that one
  records *what and how it will be falsified*.

> This ADR was written against the tree at commit `17541eb` on `main`. Every
> claim marked **verified** below was reproduced by running the code, not by
> reading it. Claims that could not be reproduced in this session are marked
> **unverified** and are listed again under
> [Open questions](#open-questions-that-must-be-answered-before-implementation).

## Context

The out-of-scope section of `docs/capability-manifest.md` was written in the
voice of the pull request that introduced the manifest. Several sprints have
landed since. Before scheduling any of the four named efforts, each claim in
that section was checked against the tree. **Four of them are stale, and one of
those conceals a live defect.** A plan that scheduled the section as written
would have built things that already exist and missed the thing that is broken.

The rest of this document records what is actually true, what was decided for
each effort, and what must be measured before implementation begins.

## What is actually true today

### Finding 1: the packaging gap is a live defect, not deferred work — verified

The section says:

> Resolution for a dispatch runs control-plane side, against the repository
> working tree, before any compute is requested.

That is true of the PowerShell CLI and of GitHub Actions. It is **not** true of
Ralph, and Ralph is deployed.

`scripts/deploy.ps1` creates `caj-<prefix>-ralph`, a cron job on
`*/5 * * * *` running the worker image with `SQUAD_MODE=ralph`.
`worker/entrypoint.sh` sources `/usr/local/lib/squad-on-aca/ralph-dispatch.sh`,
which calls `squad_dispatch_decide` → `node /usr/local/lib/squad-on-aca/squad-dispatch.js decide`
for **every** candidate issue. That path loads the administrator catalog through
`catalogSearchPaths()` in `worker/lib/resolve-capability-route.js`, which looks
in exactly two places when nothing is configured:

1. `<__dirname>/sandbox-classes.json` → `/usr/local/lib/squad-on-aca/sandbox-classes.json`
2. `<__dirname>/../../config/sandbox-classes.json` → `/usr/local/config/sandbox-classes.json`

`worker/Dockerfile` copies fourteen library files into
`/usr/local/lib/squad-on-aca/`. `config/sandbox-classes.json` is not among them,
and nothing sets `SQUAD_SANDBOX_CLASS_CATALOG`. Neither search path exists in the
image.

Reproduced by copying only the shipped library files into an image-shaped
directory and invoking the CLI exactly as Ralph does:

```
$ node <imagelib>/squad-dispatch.js decide --session-id s1 \
    --dispatch-source ralph --repository o/r
{"schemaVersion":1,...,"routing":{"route":"fail-closed","reason":"catalog-unavailable","action":"refuse",...}}
squad-dispatch: cannot resolve a dispatch route: sandbox class catalog not found
EXIT=70
```

`ralph-dispatch.sh` handles that non-zero exit by logging
`Ralph: routing refused or unavailable for issue #N; skipping without labeling`
and returning 1. The job then completes. **Ralph fails safe and dispatches
nothing, and its log message is indistinguishable from a legitimate capability
refusal.**

This is the repository's recurring defect class — a mechanism that is present,
correct, and never exercised — and the reason no gate caught it is textbook:
**every** routing assertion in `worker/tests/test_capability_routing.sh` passes
`--catalog "$CATALOG"` explicitly, and `test_dispatch_contract.sh` and
`test_ralph_dispatch.sh` both export
`SQUAD_DISPATCH_CLI="${WORKER_DIR}/lib/squad-dispatch.js"`, so the repo-relative
fallback resolves. The default search path is exercised only in the *failing*
direction (the "missing catalog exits 70" cases). It is the
`--trigger-label squad` defect again, one layer down.

Two mitigating facts, stated so the severity is not overclaimed:

- The in-image use of `squad-dispatch.js` for **lease** operations
  (`heartbeat`, `complete`) is unaffected; those subcommands never load the
  catalog.
- `deploy.ps1` sets `RALPH_LABELS=squad`, while issue #32 moved remote dispatch
  to the `squad-aca` label. Whether Ralph currently finds any candidate issues
  at all — and therefore whether this defect is presently firing or merely
  armed — is **unverified**. It does not change the disposition.

### Finding 2: two manifest-path implementations — confirmed, but the stated reason has expired

The section says the resolver mirrors the preflight's resolution "because the
phase that introduced it deliberately did not modify the shipped
`squad-capability-preflight.sh`", and that the two "should be unified" when
"Sprint 3 introduces the provider seam".

The duplication is real and confirmed:
`worker/lib/resolve-capability-route.js` lines 576–625 (`realpath`, `isWithin`,
`locateManifest`) and `worker/lib/squad-capability-preflight.sh` lines 177–228
(an inline `node - <<'NODE'` heredoc) implement the same five rules — reject
absolute paths, reject control characters, reject escapes from the working tree,
reject symlinks, require a regular file.

The *rationale* is stale. Sprint 3 landed; the provider seam exists
(`scripts/lib/providers/`). The unification did not happen and the comment now
points at a milestone in the past.

The two copies have already drifted in one respect: the resolver wraps the
repository `realpath` in `try/catch` and returns `unsafe`, while the preflight
lets the throw surface as a non-zero node exit. Both currently reach the same
verdict, which is precisely why nothing has caught the drift.

### Finding 3: the egress claim is stale on one plane and wrong on the other — verified

The section says:

> `egress[]` entries are advisory today because the worker's network policy is
> not manifest-driven.

**On the Sandboxes plane that is stale.** `New-SandboxEgressPolicy` in
`scripts/lib/providers/squad-sandbox-provider.ps1` generates the policy from the
approved class template plus the manifest's request, where the request may only
narrow; refuses a class whose `defaultAction` is not `Deny`; refuses a requested
host the template does not already permit; and carries a provenance assertion
that every emitted rule is value-identical to a template rule. It is applied
before repository code runs and was live-verified (see
[ADR 0001, G4](0001-aca-sandboxes-feasibility.md#g4--invariant-3-default-deny-capability-scoped-egress--pass)).

**On the Jobs plane it is worse than "advisory".** `config/sandbox-classes.json`
declares the default worker's egress as
`{"defaultAction": "Allow", "trafficInspection": "None", "hostRules": []}`, and
`egressAllows()` in the resolver returns `true` for any host under that policy.
So a manifest that declares a destination and needs no special tooling is
reported as *satisfied* by a plane that enforces nothing. Reproduced against a
manifest declaring only `git` and `egress: [{host: evil.example.com}]`:

```json
{
  "route": "aca-job",
  "reason": "default-profile-satisfies-manifest",
  "egressHosts": ["evil.example.com"],
  "unsatisfiedEgressHosts": [],
  "detail": "Every required capability is already provided by the default worker profile, so the existing ACA job is used."
}
```

Nothing in the decision distinguishes "this plane will enforce your egress" from
"this plane will ignore it". `unsatisfiedEgressHosts: []` is a positive claim of
satisfaction. That is a silent, machine-readable assertion of a control that
does not exist — a strictly worse failure mode than an honest advisory, and the
in-worker preflight's own message (`"advisory only, not enforced yet"`, line 355
of `squad-capability-preflight.sh`) now contradicts the sandbox provider.

`scripts/lib/providers/squad-aca-job-provider.ps1` contains no egress logic of
any kind (confirmed: the string `egress` appears twice, both in unrelated
comments), and the deployed Container Apps environment is not VNet-injected —
`az containerapp env create` in `deploy.ps1` passes no
`--infrastructure-subnet-resource-id`.

### Finding 4: credentials — the consumption half is built, the minting half is blocked

The section's description of today's credentials is still accurate: a long-lived
`GITHUB_TOKEN`/`COPILOT_GITHUB_TOKEN` pair provisioned as ACA job secrets at
deploy time, and one shared user-assigned managed identity.

Two things in it are stale:

- "The `credentials[]` list is a natural input to a future design" understates
  what exists. Issue #32 built the entire **consumption** side of short-lived
  credentials: `worker/lib/squad-git-credential-helper.sh` re-reads a `0600`
  token file on every git operation; `worker/lib/squad-token-preflight.sh`
  exercises the credential and compares remaining lifetime against
  `SQUAD_ESTIMATED_RUN_MINUTES` before the agent starts;
  `New-SandboxLocalCredentialFile` and `Invoke-SquadSandboxCredentialRefresh`
  deliver and swap the file on the Sandboxes plane. What is missing is only the
  **minting**.
- "This PR does not change the managed identity's permissions or introduce any
  new Azure role assignments" is no longer a true statement about the tree.
  `deploy.ps1` now creates `AcrPull` on the ACR **and `Contributor` at
  resource-group scope** for the session identity, and separately reconciles a
  `Microsoft.App/jobs`-scoped grant for the Actions identity because
  delete-and-recreate of the session job destroys a resource-scoped assignment.

Verified as absent: no code anywhere in the tree mints a GitHub App installation
token. Verified as inert: **nothing sets `SQUAD_TOKEN_EXPIRES_AT`.** The only
occurrences outside the preflight itself are in its own tests. With a classic
PAT there is no expiry header either, so the token preflight's lifetime check
logs `Token expiry is UNKNOWN ... remaining lifetime was NOT checked` on every
real session today. It is honest about that, and it is correct not to guess —
but it means the gate is dormant, not active.

### Finding 5: the section's closing paragraph is entirely stale

> None of the above is implemented by this PR. This PR only adds the manifest
> schema, the preflight check, and the documented seams above…

The routing decision, the provider seam, dispatch acting on the decision,
catalog review with digest pinning, and digest-keyed image evidence have all
landed. The paragraph reads as present tense and is now simply wrong.

## Decision

| # | Effort | Decision | One-line reason |
|---|---|---|---|
| 1 | Packaging the catalog into the worker image | **Do it — first, and as a defect fix** | Ralph cannot resolve a route inside the image today |
| 2 | One manifest-path implementation | **Do it** | Two copies of a security boundary have already begun to drift |
| 3 | Controlled egress | **Do the honesty half; reject per-task egress on Jobs** | The Sandboxes half is built; the Jobs half is not achievable per task without abandoning the rollback path |
| 4 | Short-lived, least-privilege credentials | **Defer — no sprint** | Blocked on a secret nobody holds, and it would reduce availability on the default plane |

### Effort 1: package the catalog and prove the default search path

**Decision: do it, as sprint 1, and label it a defect fix rather than future
work.**

It buys a working Ralph, and it closes the gap between what the tests exercise
and what the image runs. It costs one `COPY` line and one new test suite.

The valuable part is not the `COPY` line — it is the assertion that the shipped
layout resolves a route **without** `--catalog` and **without**
`SQUAD_SANDBOX_CLASS_CATALOG`. Shipping the file without that assertion would
reproduce the original defect the next time the Dockerfile is edited.

**Alternatives considered and rejected:**

- *Set `SQUAD_SANDBOX_CLASS_CATALOG` on the Ralph job in `deploy.ps1`.*
  Rejected: it points at a path that still does not exist in the image, so it
  fixes nothing; and if it were made to point at a mounted copy it would move the
  control plane's most security-relevant input into deploy-time configuration,
  where a typo fails closed silently and only Ralph notices.
- *Have Ralph resolve routes control-plane side and pass the decision in.*
  Rejected: Ralph exists precisely to be an in-container dispatcher on a cron; a
  design where it cannot decide is a different feature.
- *Delete the in-image search path and make the catalog mandatory via flag.*
  Rejected: it would break `ralph-dispatch.sh`, which passes no `--catalog`, and
  would move the failure from "missing file" to "missing flag" without making
  anything observable.
- *Do nothing and accept that Ralph is dead.* Rejected: a cron job that runs
  every five minutes and reports plausible-sounding skips is worse than no cron
  job, because it consumes the operator's belief that dispatch is covered.

### Effort 2: one manifest-path implementation

**Decision: do it, as sprint 2.**

Buys: one place where the manifest-path rules live, so a change to those rules
cannot apply to routing but not to the in-worker gate (or the reverse). Two
implementations of a path-traversal boundary is the shape of a future CVE.

Costs: it introduces a failure mode that does not exist today. The preflight's
inline heredoc has no external dependency; a shared module does. If the module is
not shipped, the preflight must refuse the session, not silently report "no
manifest". That new refusal path is the most important thing the sprint has to
prove, and it is why this sprint follows the packaging sprint rather than
preceding it.

**Alternatives considered and rejected:**

- *Leave them duplicated and add a test that the two agree.* Rejected as
  decorative: a cross-check that both copies reject `../../../etc/passwd` passes
  whether or not they share code, and cannot catch a rule added to one copy and
  not the other — which is exactly the drift being guarded against.
- *Move the rules into the preflight and have the resolver shell out to it.*
  Rejected: the resolver runs on the control plane where bash is not guaranteed
  (the PowerShell CLI path), and the preflight is a session gate with its own
  exit-code contract.
- *Reimplement the rules in PowerShell for the control plane.* Rejected on the
  same grounds the dispatch core was written once in Node
  (`scripts/lib/dispatch-contract.ps1`): a second implementation of a decision is
  the failure this repository already paid for.

### Effort 3: controlled egress

**Decision: build the honesty half. Reject per-task egress enforcement on the
ACA Jobs plane.**

The decision document must stop asserting that an unenforced destination is
satisfied. A route to `aca-job` with a non-empty `egressHosts` must say, in the
machine-readable decision and on the operator-visible surface, that the plane
will not enforce it.

Per-task egress on Jobs is rejected, not merely deferred, because ACA Jobs has no
per-execution network control. The only lever is the Container Apps
**environment** — VNet injection plus a firewall or NSG — which is shared by the
session job, the Ralph job, the watcher job and the Aspire app, and is therefore
environment-wide, not per-task. Adopting it would mean:

- rebuilding the environment into a VNet, which changes the rollback path
  itself; and
- an allowlist that is the union of every task's needs, which is the opposite of
  capability-scoped.

That is a materially different product decision from "make the manifest drive
the network policy", and the manifest is the wrong place to record it. A
repository that genuinely needs enforced egress should be routed to a sandbox
class, which already enforces it.

**Buys:** the routing decision stops making a claim it cannot back, and an
operator gets a reason to opt into the sandbox plane that is stated in terms of
the control they lose by not doing so.
**Costs:** a schema addition to a golden-pinned decision document (26 CLI
goldens plus worker goldens), and a permanent, documented asymmetry between the
two planes.

**Alternatives considered and rejected:**

- *Fail closed when a manifest declares egress and the route is `aca-job`.*
  Rejected, loudly: ACA Jobs is the unconditional default and the rollback path.
  A repository that adds two advisory lines to its manifest would stop
  dispatching entirely, and the rollback path would refuse work it accepts today.
- *Change `defaultWorker.egress.defaultAction` to `Deny` in the catalog.*
  Rejected for the same reason and worse: `egressAllows()` would then reject
  every declared host, no approved class would necessarily cover it, and the
  route would become `fail-closed`. Same availability regression, arrived at by
  accident rather than by decision. (This is, however, an excellent *mutation* —
  see the sprint plan.)
- *Enforce egress in-worker with iptables or a proxy.* Rejected: the worker runs
  unprivileged as `squad` and the agent it runs has shell access, so anything the
  worker can configure the workload can undo. An egress control inside the blast
  radius is not a control.
- *VNet-inject the environment now.* Rejected as above — environment-wide, not
  per-task, and it perturbs the rollback path.

### Effort 4: short-lived, least-privilege credentials

**Decision: defer. No sprint is scheduled, and none should be until two
preconditions are met.**

This is not a scheduling preference. Three things are true at once:

1. **The work is blocked on a secret nobody holds.** GitHub App `4448714` is
   installed on this repository as installation `150377869` with
   `contents:write`, `issues:write`, `pull_requests:write`, `metadata:read`, and
   its installation-token TTL is measured at exactly 3600 seconds. Its private
   key was generated and deleted before being stored. Minting requires
   regenerating the key and placing it somewhere the control plane can read.
   That is a human action with a security review attached, not a sprint task.
2. **The obvious storage location is unavailable.** Key Vault is unusable in this
   tenant: `HateSubWidePolicy` forces `publicNetworkAccess: Disabled` and
   silently reverts attempts to enable it. The repository's existing pattern is
   ACA secrets — but minting must happen *before* compute is requested, in the
   control plane, so the key is needed in **GitHub Actions secrets** for the
   workflow path and on the operator's machine for the `squad-aca run` path.
   ACA secrets are the wrong shape for this: they are readable by the thing
   being credentialed. That is a design decision with no obvious answer, and
   making it inside a sprint would mean making it quickly.
3. **On the default plane it would reduce availability.** A GitHub App
   installation token lives 3600 seconds and, per the
   [refresh channel matrix](../sandboxes.md#refresh-channel-matrix), **cannot be
   refreshed inside a running ACA Job** — `az containerapp job` has no `exec`,
   `job execution` is view-only, and `az containerapp exec` targets Container
   Apps. Squad sessions routinely run 10–60 minutes, and the token clock starts
   at mint time, before queueing, image pull and clone. A per-task token on the
   Jobs plane therefore converts some sessions that succeed today into sessions
   that `squad-token-preflight.sh` correctly refuses to start. Trading a working
   session for a well-audited refusal on the plane that is the rollback path is
   a regression, and it must be a decision made against measured run durations,
   not an assumption.

**What this buys by waiting:** the run-duration distribution is already
recoverable from data the system writes today. `worker/lib/dispatch-lease.js`
stamps `startedAt` and `updatedAt` on every lease and `squad-dispatch.js list`
prints them. The 3600-second question can be answered with **no code at all**.
That analysis is a precondition, not a sprint.

**Alternatives considered and rejected:**

- *Ship minting for the Sandboxes plane only, where refresh works.* Rejected
  for now: it is technically sound and is the most likely shape of the eventual
  design, but it is still blocked on precondition 1 and 2, and shipping it
  Sandboxes-only creates a credential model that differs by plane — which is a
  thing to decide deliberately, with the duration data in hand, rather than as a
  side effect of what happened to be implementable.
- *Mint a token per task and simply raise `SQUAD_ESTIMATED_RUN_MINUTES`.*
  Rejected: the estimate does not extend the token. It only changes how early the
  preflight refuses.
- *Store the App private key as an ACA secret.* Rejected: the secret would be
  mounted into the container running untrusted repository code, so a key capable
  of minting `contents:write` tokens for the installation would sit inside the
  blast radius — strictly worse than the long-lived PAT it replaces.
- *Per-task Azure identity.* Rejected as out of scope for now for an independent
  reason: the session identity currently holds `Contributor` at **resource-group
  scope**, and `deploy.ps1` deletes and recreates the session job on image
  change, destroying resource-scoped assignments. A per-task identity design has
  to survive that lifecycle and to narrow an RG-wide grant at the same time.
  Those are two separate pieces of work, and neither is unblocked by the
  manifest.
- *Invent a sprint anyway so all four efforts have one.* Rejected explicitly.
  The only candidate that needed no private key was "have the control plane set
  `SQUAD_TOKEN_EXPIRES_AT`" — and with a classic PAT the control plane has no
  truthful value to set, so the sprint would wire a variable with nothing to put
  in it and assert a gate that still logs `UNKNOWN`. That is a decorative test by
  the definition this repository uses, and saying so is the correct output.

## Consequences

- Ralph is presently unable to dispatch from inside the image. Until sprint 1
  lands, no operator should read "Ralph found no undispatched actionable issues"
  or "routing refused or unavailable" as evidence that dispatch is healthy.
- The two planes will remain asymmetric on egress indefinitely, and that
  asymmetry becomes explicit in the routing decision rather than implicit in a
  provider that has no egress code.
- ACA Jobs remains the unconditional default and the rollback path. None of the
  three scheduled sprints changes which route is chosen for any manifest.
- `worker/lib/squad-capability-preflight.sh` will continue to print
  `advisory only, not enforced yet` for a declared egress host even when the
  session is running inside a sandbox that *is* enforcing it. That message is
  wrong on the sandbox plane. Correcting it is in-scope for sprint 3 and is
  called out there, because it is worker code and this planning pass may not
  touch it.
- The regression contract is unchanged and every sprint preserves it:
  `scripts/validate.ps1` 363/0/0 (plus that sprint's new checks), 14 worker
  suites / 911 assertions (plus new), 26 byte-identical CLI goldens (sprint 3
  regenerates them deliberately), 114 .NET tests, 0 broken markdown links, and
  both probes.

## Open questions that must be answered before implementation

Each question names how it is answered, and each answer is empirical.

1. **Does adding the catalog to the worker image break digest-keyed image
   evidence?** `config/sandbox-classes.json` pins `sandbox-node-lts` to a digest
   of the very image that would now contain the catalog, so the pinned digest
   cannot be known before the build. **Unverified.** Answer by building the
   image with the `COPY` added and running `scripts/validate.ps1` plus
   `worker/lib/verify-image-evidence.js` against the existing catalog. The
   expected outcome is that nothing fails because the class is *not* re-pinned
   and the old digest keeps its evidence — but that must be observed, and if it
   holds, the deliberate one-build lag needs recording in the catalog comment.
   Sprint 1 must not be merged before this is run.
2. **Does any consumer pin the decision `schemaVersion` strictly?** Sprint 3 adds
   fields to a schema-versioned, golden-pinned document. Answer by grepping
   every consumer of `schemaVersion` in `scripts/`, `worker/`, `aspire/` and
   `.github/workflows/` for an equality comparison, and by running the CLI golden
   comparison before deciding whether to bump. **Unverified.**
3. **Is Ralph currently finding candidate issues at all?** `deploy.ps1` sets
   `RALPH_LABELS=squad`, while issue #32 moved remote dispatch to `squad-aca`.
   This decides whether the packaging defect is firing or merely armed, and it
   may indicate a second, independent defect. Answer by reading the deployed
   Ralph job's env vars with `az containerapp job show` and its recent execution
   logs. **Unverified — no Azure access was used in this planning pass.**
4. **What is the real distribution of session wall-clock durations?** This is the
   gate on effort 4. Answer with no new code, from `startedAt`/`updatedAt` on
   existing lease records via `node worker/lib/squad-dispatch.js list`. If the
   95th percentile plus dispatch overhead is comfortably under 3600 seconds, a
   Jobs-plane per-task token becomes arguable; if it is not, effort 4 is
   Sandboxes-only by measurement rather than by preference.
5. **Where can a GitHub App private key live in this tenant?** Key Vault is
   ruled out. Answer by deciding, with the repository owner, between GitHub
   Actions secrets (control-plane only, no local `squad-aca run` support) and a
   split model, and by confirming that the chosen store is never mounted into
   the worker. Effort 4 does not start until this is settled and the key is
   regenerated.
6. **Does the preflight still behave identically when its path resolution moves
   into a shared module?** Sprint 2's premise. Answer by running the same corpus
   of path cases through both entry points and comparing verdicts case by case,
   before and after the change.

## Evidence

Reproduced in this planning pass against commit `17541eb`, with no Azure access:

- `scripts/validate.ps1` — **363 passed / 0 failed / 0 skipped** (baseline,
  before any edit).
- In-image catalog resolution — `squad-dispatch.js decide` from a directory
  containing only the files `worker/Dockerfile` copies: exit **70**,
  `route: fail-closed`, `reason: catalog-unavailable`, `action: refuse`.
- Egress satisfaction on the default route — resolver against a manifest
  declaring `git` and `egress: [{host: evil.example.com}]`: `route: aca-job`,
  `reason: default-profile-satisfies-manifest`, `unsatisfiedEgressHosts: []`.
- `worker/Dockerfile` `COPY` set — fourteen files, no `sandbox-classes.json`.
- `grep -c egress scripts/lib/providers/squad-aca-job-provider.ps1` — two
  matches, both unrelated comments.
- `SQUAD_TOKEN_EXPIRES_AT` producers in the tree — none.
- GitHub App private-key minting code in the tree — none.
