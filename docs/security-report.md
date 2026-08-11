# Squad on ACA security report

**Reviewed:** 10 August 2026; re-reviewed 11 August 2026 after the Copilot-plane fix
**Scope:** the GitHub dispatch path, the worker container, the Azure identity
and its role assignments, and the optional Squad Hub link.
**Method:** code review against the running system, `scripts/validate.ps1` (414
checks), the worker capability suites on Linux, and targeted verification of
individual controls.

This report states the controls that are in place and how each one is verified.

---

## What is being protected

Squad on ACA runs an AI coding agent as an Azure Container Apps job, triggered
from a GitHub issue. The agent works a repository, pushes a branch, and opens a
pull request.

Two properties shape every control below.

**A run costs money and holds a repository-write credential.** That is the
asset.

**The repository is the authority.** Nothing outside it decides who may start a
job.

---

## Who can start a run

Every route is gated on access to the repository.

| Route | Who | Enforced by |
|---|---|---|
| Apply the `squad-aca` label | Collaborators with Triage or above | GitHub |
| Comment `/squad-aca …` or an `@` mention | Owner, organisation member, or collaborator | `worker/lib/actions-event.js` |
| Run the workflow manually | Collaborators with Write or above | GitHub |
| Ralph's five-minute poll | Only issues already carrying the label | Whoever applied the label |

The comment gate reads `author_association`, which GitHub sets on the comment
and a commenter cannot change.

`CONTRIBUTOR` is **not** accepted. GitHub reports it for anyone who has ever had
a commit merged, which is a history and not a permission.

A comment carrying no command is ignored rather than refused, so ordinary
discussion on an issue produces no noise and no alarms.

Both trigger forms — the slash command and the `@` mention — are asserted to go
through the same gate, so the friendlier spelling is not a way around it.

**Granting access is one action:** add the person as a repository collaborator.
Any role works, including Read. Removing them revokes it immediately.

---

## The Azure identity

| Control | Behaviour |
|---|---|
| Role | `AcrPull` on the registry, and `Container Apps Jobs Operator` scoped to the **single session job** |
| Scope | Exactly the two calls Ralph makes, against the one job it makes them against |
| Older grants | A resource-group `Contributor` assignment is removed on deploy if one is found |
| Reconciliation | Resource-scoped assignments are dropped by a job delete, so `deploy.ps1` re-applies them on every run |
| Regression guard | `validate.ps1` fails the build if the deploy script grants `Contributor`, stops granting the job-scoped role, or stops removing the old one |
| Live drift check | `scripts/rbac-drift-check.ps1` reads the deployed identity's actual role assignments back from Azure and fails if anything is broader than intent — an unexpected role, scope, or principal — rather than trusting that what `deploy.ps1` last applied is still what is there |

### The deployed state is checked, not only the deploy script

`deploy.ps1` asserts what it applies, and `validate.ps1` asserts what the
script contains. Neither one reads the deployed state back and compares it
with intent, which is how a resource-group `Contributor` assignment can
survive after the script has stopped granting it — the same class of drift
that applies to job configuration and the identities attached to a session
job.

Two read-only checks close that gap by querying Azure directly:

| Check | Reads | Fails on |
|---|---|---|
| `scripts/rbac-drift-check.ps1` (CV-1) | The deployed identity's live role assignments | An unexpected role, an unexpected scope (for example, a resource-group-scoped grant), or an unexpected principal |
| `scripts/job-drift-check.ps1` (CV-2) | The live session job and its environment | The wrong image, a secret referenced by literal value instead of `secretRef`, a missing expected environment variable, or an identity attached to the job beyond the one session identity |

Both are read-only: each has exactly one call site that invokes the Azure CLI
(enforced by a static check in `scripts/validate.ps1`), that call site refuses
any mutating verb or unlisted command shape, and the comparer that decides
pass or fail has no reference to the Azure CLI at all — a mutating command
cannot reach Azure through either check even if the intent-resolution or
comparison logic is wrong.

Both are folded into `squad-aca doctor` (CV-3), so drift is visible during
ordinary use rather than only when somebody remembers to run the script by
hand, and a finding is reported as a failure, never a warning — drift is
something to act on, not merely note.

Every fixture proving a specific drift (a resource-group-scoped role
assignment, an extra identity, an inlined secret) is asserted to make the
check fail; a check that cannot fail proves nothing.

### The identity is not present in a session

Container Apps supplies the managed identity to the container as
`IDENTITY_ENDPOINT` and `IDENTITY_HEADER`. Every mode except `ralph` — the only
mode that calls Azure — has these removed from its environment.

**The removal happens before any child process is started.** Unsetting a
variable changes only the current shell; a process already running keeps the
environment it was given, so the ordering is the control rather than a detail of
it.

A mode added later is covered by default: the exemption names `ralph`
explicitly and drops everything else.

### Process isolation inside the container (PC-1, issue #86)

The identity-drop ordering above is correct whether or not Azure Container
Apps restricts one process from reading another's environment through
`/proc`. What was unknown is which of those is true on the platform, and that
decides whether the ordering is the *only* control standing between a session
and the identity, or one of two.

**Mechanism.** `worker/lib/proc-isolation-probe.sh` spawns a short-lived
child carrying only a synthetic, per-run random sentinel — never a real
credential — and the same-uid parent attempts to read that child's
`/proc/<pid>/environ`. It reports only whether the sentinel's *variable name*
was found, never any value; it always reaps the child it starts; and it
exits 0 unconditionally, so a probe failure can never fail a session. It
emits exactly one line, in a fixed format:

```
SQUAD-PROC-ISO v1 same-uid-environ-readable=yes|no|unknown proc-mounted=yes|no hidepid=0|1|2|unknown uid=<n> user=<name>
```

**Ordering.** The probe runs in `worker/entrypoint.sh` **unconditionally, in
every mode including `ralph`**, immediately after the identity-drop dispatch
and before the lease heartbeat — the first background child of any kind.
This mirrors the identity-drop control's own ordering rule rather than
introducing a second one: nothing in the entrypoint starts any child, real or
diagnostic, before the probe has run.

**Status: not yet observed in ACA; pending next operator deploy.** The
mechanism is proven on an ordinary Linux filesystem in CI —
`worker/tests/test_proc_isolation_probe.sh` reproduces every classification
(`yes`, `no`, `unknown`) against real and fabricated `/proc`-shaped inputs,
and `worker/tests/test_identity_drop_order.sh` asserts the probe call's
position relative to the identity drop and the lease heartbeat. What has
**not** happened is a deployed session or Ralph poll actually emitting the
`SQUAD-PROC-ISO` line where it can be read back — the worker image carrying
this probe has not yet been redeployed. `scripts/proc-isolation-report.ps1`
(below) will report `not-yet-observed` until that redeploy happens and a
session runs; **this report does not claim a result it has not seen**, and no
value here should be read as an implicit answer either way.

**Retraction: the prior "not-yet-observed" live run was never evidence.**
The initial version of this feature ran a real, read-only harvester pass
against the live deployment and reported `not-yet-observed`, which this
document originally recorded as if it were a meaningful (if inconclusive)
observation. It was not. Two independent defects made that parser
structurally incapable of ever observing the probe's line, regardless of
what the platform actually did:

1. `worker/entrypoint.sh` routed the probe's one documented line through its
   own `log()` helper, which prepends a fixed `"[squad-on-aca] "` literal.
   The parser's match was fully anchored at the start of the line
   (`^SQUAD-PROC-ISO v1 ...`), so a decorated line could never match.
2. `scripts/lib/proc-isolation-reader.ps1` read job logs without pinning
   `--format json`, leaving Azure's own default (`text`) in effect, which
   additionally prepends an ISO-8601 timestamp to every line — a second,
   independent reason the same anchored match could never succeed, and a
   wire shape the parser was never designed to unwrap in the first place.

A `not-yet-observed` result under those conditions is indistinguishable from
the probe never having run at all: the parser was asking a question it could
not have heard the answer to even if the platform had shouted it. This
security revision (R1–R8, the fix for this rejection) removes the `log()`
decoration so `worker/entrypoint.sh` calls the probe library's raw
`squad_proc_iso_run` directly, pins `--format json` on the one reader call
site, and rebuilds the parser to unwrap that format's `{"Log": ...}`
envelope (with a bounded, non-permissive backward-compatibility strip for
already-captured logs that carry the old timestamp/prefix shape). An
end-to-end contract test now runs the shipped probe under bash and feeds its
exact emitted bytes — raw, JSON-enveloped, and legacy-prefixed — through the
shipped parser, asserting every field, so this class of "silently
unobservable" defect cannot recur without failing that check.

**The live PC-1 answer remains genuinely pending**, exactly as before this
fix: nothing above changes the fact that no redeploy has happened under the
read-only constraint this work was produced under, so no session has yet run
with a parser that is actually capable of observing its output. What changed
is that the *next* operator deploy's `not-yet-observed`-or-otherwise result
will, for the first time, mean what it says.

**The blocker, exactly.** This work was produced under a hard read-only Azure
constraint: no deploy, no job start, no exec into a container, no image
build/push, and no mutation of any Azure resource. Establishing the live
answer requires a redeploy of the worker image and a session (or a Ralph
poll) actually running in ACA — both of which are deploy/execute actions
outside that boundary. The live PC-1 answer is therefore genuinely unknown as
of this writing, and is not fabricated or inferred here.

**Reading the result once it exists.** `scripts/proc-isolation-report.ps1` is
read-only: it lists existing job executions and reads their already-written
console logs (never starts one, never execs into a container, never
deploys), through the same single-chokepoint/allowlist pattern as
`rbac-drift-check.ps1` (CV-1) and `job-drift-check.ps1` (CV-2). It reports one
of `yes`, `no`, `unknown`, or `not-yet-observed` — and, distinctly, "live read
unavailable" when the question could not even be asked (unreachable
subscription, missing CLI extension), which is never conflated with
`not-yet-observed`.

**PC-2 (a second boundary) is explicitly declined for now, unchanged by this
revision.** The issue's own sprint plan makes PC-2 conditional on PC-1's
answer: "add a second boundary only if PC-1 says it is needed." Implementing
PC-2 — running identity-bearing helpers under a separate uid — would change
the highest-privilege path in this container (the one holding the Azure
identity) on the basis of a platform property that has not been confirmed on
this platform. That change cannot itself be verified under the same
read-only constraint that prevents observing PC-1's answer, so it is not
attempted now. **Reversal trigger:** if `scripts/proc-isolation-report.ps1`
(or a future live observation) ever reports `same-uid-environ-readable=yes`,
PC-2 is reopened as required rather than optional, because that answer means
the identity-drop ordering is the *only* control and a same-uid read is
genuinely possible.

---

## Reaching Azure from GitHub

Azure access from GitHub Actions is **OIDC federation only**. No Azure
credential is stored in the repository.

The federated identity that starts a job holds `Container Apps Jobs Operator`
scoped to that one job, and `deploy.ps1` reconciles that grant on every run
because a job delete removes it.

---

## The worker container

| Control | Behaviour |
|---|---|
| Tool policy | Composed per session from the mode and the dispatch source |
| Supervised sessions | Drop `--allow-all-tools`; the deny list is unchanged |
| Denied tools | Refused outright — no approval is offered for something the policy forbids |
| Capability manifest | Identifiers validated against fixed allowlists; the manifest carries no shell commands |
| Diagnostics | Only allowlisted identifier names and fixed reasons are emitted |
| Governance check | Runs before anything leaves the container |
| Sync guard | `squad-aca sync --sync-all` blocks obvious secret files and inline tokens before staging |

Supervision through Squad Hub **narrows** what runs unattended: operations that
previously ran with nobody watching require an answer, and the deny list remains
a floor that no surface can lift.

---

## Credentials

| | |
|---|---|
| Azure access from GitHub Actions | OIDC federation; no stored Azure secret |
| Squad Hub link | A **device token**, which can register a device and nothing else |
| Hub token format | Checked before deployment, and again at session start |
| Job secrets | Container Apps secrets, referenced rather than inlined |
| GitHub and Copilot tokens | Separable where policy requires it |
| Deployment outputs | `deploy.outputs.json` is git-ignored |

The Squad Hub integration is **optional on both sides**. A worker with no hub
configured behaves exactly as it does without it, and the image can be built
with no hub client in it at all.

---

## What a dispatched run can reach

The tool policy applied to a session is not prose. `worker/lib/agent-policy.js`
resolves it, and `buildPolicyMatrix()` produces **one resolved row per dispatch
source × mode** — every combination of `local-cli`, `ralph`, `watch`, `actions`
against every mode `worker/entrypoint.sh` branches on. The table is generated by
calling the same resolver a session calls, so a row cannot describe something
the code does not do.

| Property | Behaviour |
|---|---|
| Tier | `attended` only for an attended mode dispatched from `local-cli`; everything else, including an absent or unrecognised source, is `autonomous` |
| Registry | `KNOWN_SOURCES` matches `dispatch-decision.js`'s `DISPATCH_SOURCES`; `KNOWN_MODES` matches the entrypoint's `case` arms |
| Enforcement | `test_dispatch_registry_exhaustiveness.sh` scans every **production** dispatcher for literal `SQUAD_DISPATCH_SOURCE=` / `SQUAD_MODE=` assignments and fails the build if any names a source or mode with no registry entry |
| Agreement | `test_agent_policy.sh` asserts every matrix cell exists and equals a freshly resolved policy for that cell |

The registry scan is the part that matters over time. A new dispatcher that
invents a source name would previously have fallen through this file's
fail-closed defaults with nobody having decided whether that was right. It now
fails a test instead, so the decision is made in review rather than at runtime.

---

## Issue-sourced input is untrusted

Trust is a **separate axis from the tier**. The tier answers "is a human
watching this run". Trust answers "was the text that became this prompt written
by somebody who can open an issue" — which is anybody.

Only `local-cli` is trusted. `ralph`, `watch`, `actions`, an unrecognised
source, and an **absent** source are all untrusted. That is fail-closed by
construction: a dispatcher cannot opt into the relaxed treatment by omitting a
variable.

An untrusted session receives four additional deny patterns on top of the
tier-based list:

| Denied on untrusted input | Why |
|---|---|
| `shell(git push)` | publishing is the entrypoint's own git invocation, never a tool call the agent makes |
| `shell(gh pr)` | the same argument for opening the pull request |
| `shell(curl)`, `shell(wget)` | the general-purpose fetchers — "fetch this and run it", "post the diff to…" is the shape being closed |

This is deliberately **not** a blanket denial of `git`, `gh`, `npm` or `pip`,
and `--no-remote` is not used. An issue-triggered session still has to do
useful work. The tests assert both directions: the remote policy is strictly
narrower, and the `local-cli` policy is byte-for-byte unchanged, so a change
that narrowed everything or nothing fails.

**One honest caveat about delivery.** Two of these patterns contain a space.
The worker's direct `copilot` invocation and Squad Hub's JSON channel carry
them whole. The `squad watch` / `squad loop` path takes the whole flag set as
one string and splits it on whitespace, which would tear a space-bearing
pattern into two arguments and silently stop it being a deny rule. Rather than
pretend otherwise, the resolver emits the deliverable subset separately, names
every dropped pattern in `undeliverableViaSquad`, and the entrypoint prints
that list into the session log. On that path `shell(git push)` and
`shell(gh pr)` are **not in force**, and the log says so. Closing it belongs to
the Squad runtime, not to this repository.

---

## The push credential and the agent

An issue-sourced prompt runs in a container that holds a repository-write
credential. Two options were evaluated.

**Full separation — declined.** The proposal was that the agent produce a diff
and something else publish it. It is declined for this iteration, for reasons
that are about the shape of the system rather than effort:

- The entrypoint and the agent **run as the same uid in the same container**. A
  publishing "step" placed after the agent is not a boundary; it is the same
  process tree with the same access to the same files and the same `/proc`.
  Separation would require a different process identity or a different
  execution boundary, which is a redesign of the worker, not a control added to
  it.
- There is **no external diff-export or publish channel**. Nothing outside the
  container is willing to receive a patch and push it on the session's behalf,
  so building the agent half of the split would produce a session that cannot
  publish at all.

Recorded here rather than built, exactly as the egress decision was.

**Withholding — built.** For `prompt` and `new-project` on an untrusted source,
the credential is taken away from the agent for the duration of the single
`copilot -p` call. Before the agent starts: the live token is moved into a
non-exported shell variable, `GH_TOKEN`/`GITHUB_TOKEN` are unset, a
`COPILOT_GITHUB_TOKEN` carrying that same value is unset the same way (see
below), the 0600 token file is deleted, and the git credential helper is
uninstalled. After the agent exits and **before** anything publishes, all of
them are restored, so a session still ends with a branch and a pull request.

| Property | Behaviour |
|---|---|
| Scope | `prompt` and `new-project`, untrusted source only; a trusted `local-cli` run is untouched |
| Ordering | Withhold → agent → restore → publish, asserted as a sequence, not inferred |
| Heartbeat | The lease heartbeat child is killed **before** any credential mutation and only restarted **after** the credential is fully back — a background child that straddled the window would have kept the token legible through `/proc/<pid>/environ` to exactly the agent it was being withheld from |
| Restore failure | Fatal, `exit 78`. "Could not undo the withholding" must never become "push anyway" or "stay withheld and fail at the very end" |
| Token in logs | The token never enters argv, `git config` output, `ps`, or a log line; the withhold and restore messages name the mode and source only |
| Agent failure | The agent exiting non-zero aborts the session under `set -Eeuo pipefail` before restore. The token file is already gone and the copy in memory dies with the process, so nothing is stranded on disk — but the lease's terminal state is written without a credential and is therefore best-effort on that path, and the sweeper reclaims on heartbeat expiry |

### Residual risk, stated plainly

Same-uid execution means this is **withholding, not separation**. A background
process planted by the agent that outlives the agent phase can observe the
token once it is restored, and `/proc` remains readable within the uid. The
control removes the credential from the agent's own reach during its own run;
it does not make it unreachable.

### Scope boundary

`watch`, `triage`, `loop` and `ralph` are **excluded**. Withholding a
credential for the length of a multi-hour polling loop is a different design
from withholding it for one bounded call, and it was not built. Those modes
hold the credential throughout. `smoke` never runs an attacker-supplied prompt
and `shell` runs an operator-supplied command, so neither is in scope either.

### The Copilot credential plane — closed

An earlier revision of this report recorded an open finding here: withholding
unset `GH_TOKEN` and `GITHUB_TOKEN` but not `COPILOT_GITHUB_TOKEN`, which
`worker/entrypoint.sh` defaults to `GH_TOKEN` whenever no separate Copilot
credential is supplied — the shape `deploy.ps1` takes whenever
`-CopilotGitHubToken` is not passed (it warns, and proceeds). A push-capable
credential under a second variable name is still a push-capable credential, and
a probe against the shipped library confirmed a child process inherited it
during the withheld window.

That gap is now closed, and re-verified against the code rather than the
commit message.

| Property | Behaviour |
|---|---|
| Withholding | `squad_credential_withhold` caches `COPILOT_GITHUB_TOKEN` in a non-exported variable and unsets it whenever its value equals the git token — the comparison runs **before** `GH_TOKEN` is unset, because it needs both live |
| Distinct credential | A `COPILOT_GITHUB_TOKEN` whose value differs from the git token is untouched: it is not the credential this control exists to hide, and a session deployed with a separate fine-grained PAT still authenticates to Copilot throughout the agent phase |
| Restore | Symmetric with the git token, after the git restore steps and before the heartbeat restarts, with the same fatal `exit 78` on failure |
| Fail closed | `squad_copilot_shared_token_gate` runs **before** withholding in both the `prompt` and `new-project` blocks and refuses to start the agent (`exit 78`) when the token is shared. The default deployment therefore does not run an issue-sourced agent with a collapsed credential plane; it refuses |
| Escape hatch | `SQUAD_ALLOW_SHARED_COPILOT_TOKEN=true` — the literal string, nothing else — proceeds with the shared token still exported, and logs it as a `WARNING` |
| Reported honestly | `resolveCredentialProfile` carries `copilotTokenEnv`, `copilotTokenShared` and `copilotTokenSharedAllowed`. On the escape-hatch path the profile reports `copilotTokenEnv: true` and a `reason` naming a **weakened** boundary, so nothing ever claims unqualified withholding while a push-capable token is still exported. The static matrix defaults every cell to the worst case (`copilotTokenShared: true`) rather than an optimistic guess |

Verified directly: `credential-profile` for `actions`/`prompt` reports
`copilotTokenEnv: false` with the shared token, `true` with a distinct one, and
`true` with `copilotTokenSharedAllowed: true` plus the weakened `reason` under
the escape hatch. The suite's value-scan of the whole exported environment —
by value, not by variable name — finds nothing equal to the withheld token
during the agent phase.

**The operational consequence is deliberate and worth stating.** A deployment
that never passed a distinct Copilot PAT used to run the agent with a
push-capable token in reach; it now aborts the session with `exit 78` before
the agent starts. `deploy.ps1` still warns and proceeds at deploy time, so the
refusal surfaces at the first issue-sourced session rather than at deployment.
Supply `-CopilotGitHubToken` with a fine-grained PAT, or set the escape hatch
knowingly.

### Residual risk on this control

- The escape hatch is a real weakening, not a formality. With it set, an
  untrusted agent keeps a push-capable `COPILOT_GITHUB_TOKEN`. It is explicit,
  logged as a `WARNING`, and reported in the policy profile — but it is not a
  lesser exposure than the original finding, only a consented one.
- Shared-ness is a value comparison against `GH_TOKEN`. That is the right test
  for this code path — `entrypoint.sh` always exports `GH_TOKEN` (from
  `GITHUB_TOKEN` when only that is set) before anything reaches withholding —
  but a future caller that reached `squad_credential_withhold` with the
  credential only on disk and no `GH_TOKEN` exported would not have its Copilot
  token compared against anything.
- Same-uid execution is unchanged by this work: this remains withholding, not
  separation, with the residual stated above.

---

## Egress

Outbound network access from a job is unrestricted, and that is a decision
rather than an oversight.

Filtering by hostname requires Azure Firewall — network security groups match on
address and service tag, not name — and a Container Apps environment cannot join
a virtual network after it has been created. Against that cost, every credential
remaining in a session has a legitimate destination that is also where it would
otherwise be sent, so a policy permitting GitHub permits the same traffic.

The decision is revisited if a session gains a credential whose legitimate
destination differs from that.

---

## How these controls are verified

`scripts/validate.ps1` — **485 checks, 0 failing.** It asserts behaviour rather
than structure: where a control is claimed, the check drives the code that
enforces it.

The live role-assignment and job-configuration drift checks (CV-1/CV-2) are
proven two ways: against a stubbed Azure CLI in `validate.ps1`, driving every
committed fixture to the exit code the check's contract keys off, and
read-only against a real deployed environment. Run there, CV-2 passed clean.
CV-1 found a stale resource-group `Contributor` grant on that environment —
exactly the drift class this report describes `deploy.ps1` removing on
redeploy, on an environment that has not been redeployed since. Azure access
for this verification is strictly read-only, so the grant was reported and
left in place rather than removed; redeploying (or removing it by hand)
closes that specific instance, and CV-1 running as part of `squad-aca doctor`
is what catches the next one.

The worker capability suites run on Linux in CI. A suite whose dependencies are
missing reports `SKIP`, and **a skip fails the job** rather than passing
quietly, so a partial run cannot be mistaken for a complete one.

The identity-ordering control is verified two ways: by reading the script, and
by reproducing the mechanism on a real Linux filesystem in CI — a child started
before the removal still holds the value, one started after does not. The test
also fails if any new background child is introduced ahead of the removal.

The containment controls above have their own suites:

| Suite | What it holds to account |
|---|---|
| `worker/tests/test_agent_policy.sh` | 246 assertions: the source × mode matrix agrees cell by cell with a freshly resolved policy; trust is orthogonal to tier; untrusted is narrower and `local-cli` is unchanged; space-bearing patterns are named as undeliverable on the `squad watch` path; and no matrix row reports `withheld: true` while a shared Copilot token stays exported |
| `worker/tests/test_dispatch_registry_exhaustiveness.sh` | A production dispatcher naming an unregistered source or mode fails the build |
| `worker/tests/test_squad_hub.sh` | 64 assertions: the trust-conditioned policy is the same policy on the hub channel, and the deny list survives transport whole |
| `worker/tests/test_credential_withholding.sh` | 62 assertions. Full lifecycle against an HTTPS git fixture: nothing push-capable visible during the agent phase, restore before publish, the heartbeat never straddling the boundary, and a restore with no withheld token fatal. It now also covers the Copilot plane — derived, explicit-equal, explicit-distinct and escape-hatch cases, the fail-closed gate, and a **value-scan of the whole exported environment** that would catch any future variable carrying the same token, whatever it is called |

Re-verified for this report on 11 August 2026: `scripts/validate.ps1` 414/414;
the worker suite 22/22 suites, 0 failed, 0 skipped — including
`test_agent_policy.sh` 246/246, `test_credential_withholding.sh` 62/62,
`test_squad_hub.sh` 64/64, `test_credentials.sh` 56/56 (the refresh path still
leaves a distinct Copilot token alone), `test_dispatch_registry_exhaustiveness.sh`
3/3 and `test_egress_honesty.sh` 41/41.

The Copilot-plane assertions were also mutation-tested independently against a
throwaway copy of the worker tree: removing the Copilot unset, inverting the
shared/distinct comparison, removing the gate's fatal exit, skipping the
Copilot restore, and defaulting the escape hatch to on each failed named
assertions (the value-scan, the gate's `78`, the restore check, and "an UNSET
`SQUAD_ALLOW_SHARED_COPILOT_TOKEN` fails closed" respectively). The reviewed
tree was never modified.

---

## Reporting a vulnerability

Please report privately:
<https://github.com/swigerb/squad-on-aca/security/advisories/new>.

Do not open a public issue for a suspected vulnerability.
