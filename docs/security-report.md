# Squad on ACA security report

**Reviewed:** 10 August 2026
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

`scripts/validate.ps1` — **414 checks, 0 failing.** It asserts behaviour rather
than structure: where a control is claimed, the check drives the code that
enforces it.

The worker capability suites run on Linux in CI. A suite whose dependencies are
missing reports `SKIP`, and **a skip fails the job** rather than passing
quietly, so a partial run cannot be mistaken for a complete one.

The identity-ordering control is verified two ways: by reading the script, and
by reproducing the mechanism on a real Linux filesystem in CI — a child started
before the removal still holds the value, one started after does not. The test
also fails if any new background child is introduced ahead of the removal.

---

## Reporting a vulnerability

Please report privately:
<https://github.com/swigerb/squad-on-aca/security/advisories/new>.

Do not open a public issue for a suspected vulnerability.
