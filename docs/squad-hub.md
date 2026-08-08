# Supervising a session with Squad Hub

A session on this platform runs with every tool pre-approved and, for
unattended runs, with questions disabled. That is the right decision given the
constraint: a container has no TTY and no approver, so a permission prompt is
an unbounded hang on a job that bills by the minute. Destructive operations are
therefore made **unavailable** rather than approval-gated.

[Squad Hub][hub] removes the constraint. It puts a human in front of an
approval card from anywhere, including a phone. So a supervised session can
afford to **ask**.

[hub]: https://github.com/swigerb/squad-hub

## This is a tightening, not a relaxation

The obvious worry is that attaching a hub is a way to get more permission. It
is the opposite, and the reason is worth stating precisely.

A supervised session runs with **`--allow-all-tools` dropped** and the deny
list **unchanged**. Measured against Copilot CLI 1.0.78 over ACP:

| | |
|---|---|
| A tool on the **deny list** | raises **no permission request at all**. It is refused outright — "denied by policy". |
| A tool that is merely **ungated** | raises a request carrying the **literal command**, and waits for a person. |

So a human at the hub is never even *offered* the chance to approve something
`worker/lib/agent-policy.js` forbids. **The deny list stays a hard floor that
no surface can lift.** What changes is that the things which previously ran
with nobody watching now need an answer.

The set of operations that execute without human review therefore **shrinks**.

## Turning it on

Nothing changes unless you pass both halves. Mint a device token first, bound
to a device-id prefix so a credential shipped to a cloud job cannot claim to be
your laptop:

```bash
squad-hub device-token --hub https://your-hub.example --token <your own token> \
    --label "aca jobs" --prefix aca- --ttl-hours 4
```

Then deploy with it:

```powershell
./scripts/deploy.ps1 -ResourceGroup rg -SquadHubUrl https://your-hub.example `
    -SquadHubToken sqhd1....
```

The token is stored as a container secret and referenced, never written into
the job template as a literal.

## Why a DEVICE token, and nothing else

A device token can be a device and **nothing else**. It cannot read the hub's
API, start work on another device, or watch anyone's sessions. Shipping a
personal token to a container instead would hand that job everything its owner
can do.

`deploy.ps1` refuses a credential without the `sqhd1.` prefix at the desk, and
`worker/lib/squad-hub.sh` refuses it again at session start — the second check
matters because a job's environment can be edited after deployment.

Short lifetimes matter more here than anywhere else. A leaked job secret that
expires in four hours is worth an afternoon; one that never expires is worth
whatever it can reach.

## What it refuses to do

**It never falls back to the unsupervised path.** An operator who configured a
hub asked for a session a human is watching. Quietly running it with blanket
tool approval because the hub was unreachable would be the exact silent
downgrade this repository refuses everywhere else. A session that cannot be
supervised does not run.

**A half-configuration is a mistake, not an opt-out.** A URL with no token
cannot attach and a token with no URL has nowhere to go, so either alone stops
the deploy rather than quietly running unsupervised.

## What happens when things go wrong

| Situation | What happens |
|---|---|
| The hub is unreachable at start | The session still runs — the hub is an observer, never a dependency. It warns that nobody can approve a tool call. |
| A tool asks and no hub is connected | The job stops with **exit 75** rather than billing to its ceiling. There is definitively no approver, so waiting achieves nothing. |
| The hub refuses the device | **Exit 77**, immediately. Retrying a policy refusal never succeeds, and a container looping on one looks healthy while doing nothing. |
| The agent finishes | Exit 0, then `commit_and_push_if_needed` runs exactly as it does today, governance checkpoint included. |

## Scope

**ACA Jobs only.** Approved sandbox classes are default-deny with an allowlist
covering GitHub, npm, Node and PyPI, and nothing else — a hub on any other host
is refused, and widening that needs an administrator-approved change to the
class. Sandboxes keep the unattended behaviour they have today.

Supervision applies to the modes that run a one-shot agent: `prompt` and
`new-project`. `loop`, `watch` and `ralph` drive the agent through the Squad
runtime rather than invoking it directly, so they are unchanged.

## Where the parts live

| | |
|---|---|
| `worker/lib/squad-hub.sh` | The supervision path: preflight, policy transport, exit-code mapping. |
| `worker/lib/agent-policy.js` | `hub-argv-json` — the same policy, minus `--allow-all-tools`. |
| `worker/tests/test_squad_hub.sh` | 32 assertions, mostly about what it refuses. |
| `scripts/deploy.ps1` | `-SquadHubUrl` / `-SquadHubToken`, and the credential preflight. |

The contract runs one way: **Squad Hub owns the device protocol and documents
it; this repository depends on it.** Never the reverse.
