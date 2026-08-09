# Supervising a session with Squad Hub

A session on this platform runs with every tool pre-approved and, for
unattended runs, with questions disabled. That is the right decision given the
constraint: a container has no TTY and no approver, so a permission prompt is
an unbounded hang on a job that bills by the minute. Destructive operations are
therefore made **unavailable** rather than approval-gated.

[Squad Hub][hub] removes the constraint. It puts a human in front of an
approval card from anywhere, including a phone. So a supervised session can
afford to **ask**.

This is entirely optional. With no hub configured, nothing below applies.

[hub]: https://github.com/swigerb/squad-hub

## This is a tightening, not a relaxation

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

Mint a device token, bound to a device-id prefix so a credential shipped to a
cloud job cannot claim to be your laptop:

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

### The prefix has to match what the job registers as

`--prefix` is not decoration: **the hub enforces it at registration**, and a
device id that does not start with it is refused with exit **77**.

Each execution registers as `aca-<job execution name>` —
`SQUAD_HUB_DEVICE_ID_PREFIX` (default `aca-`) plus the ACA execution name,
lowercased, because the hub's prefix test is. Per *execution*, not per job: two
attachments sharing one id fight over the same device slot, so two concurrent
executions must be two devices.

Mint with a different prefix and you must set `SQUAD_HUB_DEVICE_ID_PREFIX` to
match. `deploy.ps1` reads the binding out of the token and refuses a mismatch
at the desk rather than letting it surface as an exit 77 in a container nobody
is watching.

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

## Leaving it out

Supervision is opt-in, and opting out is free. With neither `SQUAD_HUB_URL` nor
`SQUAD_HUB_TOKEN` set, a session runs exactly as it does without any of this —
same flags, same modes, same behaviour.

That holds at build time too. `squad-hub` is installed by default because it
costs one small dependency and lets an operator turn supervision on with two
environment variables instead of a rebuild. The image does not require it:

```powershell
# a worker with no squad-hub in it at all
az acr build --build-arg SQUAD_HUB_SPEC=none ...

# an unreleased build, for integration work
az acr build --build-arg SQUAD_HUB_SPEC=github:swigerb/squad-hub#<sha> ...
```

Convenience may make supervision easy to switch on. It must not make it
impossible to leave out, and an npm outage must never break the image for
people who never attach to a hub.

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
| A tool asks and no hub is connected | **Exit 75**, rather than billing to the ceiling. There is definitively no approver, so waiting achieves nothing. |
| The hub refuses the device | **Exit 77**, immediately. Retrying a policy refusal never succeeds. The message names the id this job registered as, so you can compare it with the token's prefix. |
| A half-configuration, a non-device token, or a missing library | **Exit 78**, before the agent starts. |
| The agent finishes | Exit 0, then `commit_and_push_if_needed` runs as usual, governance checkpoint included. |

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
| `worker/lib/squad-hub.sh` | The supervision path: preflight, device identity, policy transport, exit-code mapping. |
| `worker/lib/agent-policy.js` | `hub-argv-json` — the same policy, minus `--allow-all-tools`. |
| `worker/tests/test_squad_hub.sh` | 51 assertions, mostly about what it refuses. |
| `worker/Dockerfile` | `SQUAD_HUB_SPEC` — pinned npm by default, `none`, or a git ref. Asserts at build time that the installed CLI has the verb this repository calls. |
| `scripts/deploy.ps1` | `-SquadHubUrl` / `-SquadHubToken`, the credential preflight, and the device-prefix check. |

The contract runs one way: **Squad Hub owns the device protocol and documents
it; this repository depends on it.** Never the reverse.
