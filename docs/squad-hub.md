# Supervising a session with Squad Hub

[Squad Hub][hub] lets a human answer tool-approval requests for a running ACA Jobs session.

Supervision is optional. With no hub configured, sessions use the standard tool policy.

[hub]: https://github.com/swigerb/squad-hub

## Tool policy with supervision

A supervised session drops `--allow-all-tools` and keeps the deny list.

| Tool request | Result |
|---|---|
| A tool on the deny list | Refused by policy. No approval request is created. |
| An ungated tool | Approval request is sent to the hub with the literal command. |

## Watch-only mode

Set `SQUAD_HUB_APPROVAL=auto` to keep sessions visible in the hub, and stoppable from it, without approving tools one by one. The default is `ask`.

| | `ask` (default) | `auto` (watch-only) |
|---|---|---|
| Session visible in the hub, can be stopped there | yes | yes |
| A tool on the deny list | refused outright | refused outright |
| An ungated tool | waits for a person in the hub | runs |
| One-shot (`prompt`, `new-project`) | `--allow-all-tools` dropped | `--allow-all-tools` kept |
| `watch` / `loop` | every hook, including the blocking `preToolUse` | every reporting hook; `preToolUse` removed |

The deny list is identical in both modes. Every session log states the mode (`WATCH-ONLY` in the policy announcement). Any other value exits `78`.

In a watch-only `watch`/`loop` container, `squad-hub hooks status` reports `missing preToolUse`. That is the intended state, not a broken install.

```powershell
./scripts/deploy.ps1 -SquadHubUrl https://your-hub.example -SquadHubToken sqhd1.... -SquadHubApproval auto
```

## Enable supervision

Mint a device token bound to the `aca-` prefix:

```bash
squad-hub device-token --hub https://your-hub.example --token <your own token> \
    --label "aca jobs" --prefix aca- --ttl-hours 4
```

Deploy with the hub URL and token:

```powershell
./scripts/deploy.ps1 -ResourceGroup rg -SquadHubUrl https://your-hub.example `
    -SquadHubToken sqhd1....
```

The token is stored as a container secret and referenced by the job.

### Device prefix

Each execution registers as `aca-<job execution name>` by default. Set `SQUAD_HUB_DEVICE_ID_PREFIX` when you mint a token with a different prefix. A prefix mismatch exits `77`.

`deploy.ps1` reads the binding from the token and refuses a mismatch before deployment.

### Device name and metadata

Before `squad-hub oneshot` starts, the worker also sets:

| Variable | Value |
|---|---|
| `SQUAD_HUB_DEVICE_NAME` | `#<issue> · <repo-short-name>` when the session is attached to an issue, else `${SESSION_NAME:-squad-session}` |
| `SQUAD_HUB_DEVICE_META_JSON` | JSON object with string keys `repo`, `issue`, `executionName`, `jobName` |

`repo` is the full `owner/repo` slug. `issue` is the issue number as a string, or `""` when there is no issue. `executionName` and `jobName` come from ACA Jobs when present. Every value is capped at 200 characters before it is sent to the hub. An explicit `SQUAD_HUB_DEVICE_NAME` override is respected.

### Token type

Use a device token with the `sqhd1.` prefix. `deploy.ps1` checks it before deployment, and `worker/lib/squad-hub.sh` checks it at session start.

## PR reporting

After the worker opens a pull request, it tries to report `{url, number, title}` to the hub for that session. This uses `squad-hub report-pr`, which arrives in `squad-hub` v0.7.0. The worker image is still pinned to `squad-hub@0.6.0`, so the worker feature-detects the verb with `squad-hub --help`: if `report-pr` is absent, it logs one line and skips reporting.

With no hub configured, PR reporting is a no-op. With a hub configured, report failures stay non-fatal: the pull request is already open, so the worker logs the failure and continues.

## Opt out

With neither `SQUAD_HUB_URL` nor `SQUAD_HUB_TOKEN` set, the session runs without hub supervision.

Build without `squad-hub`:

```powershell
# a worker with no squad-hub in it at all
az acr build --build-arg SQUAD_HUB_SPEC=none ...

# an unreleased build, for integration work
az acr build --build-arg SQUAD_HUB_SPEC=github:swigerb/squad-hub#<sha> ...
```

## Failure behavior

| Situation | What happens |
|---|---|
| The hub is unreachable at start | The session runs and warns that no approver is connected. |
| A tool asks and no hub is connected | Exit `75`. |
| The hub refuses the device | Exit `77`. |
| A half-configuration, a non-device token, or a missing library | Exit `78` before the agent starts. |
| The agent finishes | Exit `0`, then `commit_and_push_if_needed` runs with the governance checkpoint. |

## Scope

Supervision applies to ACA Jobs and to one-shot agent modes `prompt` and `new-project`. `loop`, `watch`, and `ralph` are unchanged.

## Files

| File | Purpose |
|---|---|
| `worker/lib/squad-hub.sh` | Supervision path: preflight, device identity, policy transport, approval mode, exit-code mapping. |
| `worker/entrypoint.sh` | PR creation and the best-effort `squad_hub_report_pr_if_any` call after `gh pr create` succeeds. |
| `worker/lib/agent-policy.js` | `hub-argv-json`: same policy, minus `--allow-all-tools`. |
| `worker/tests/test_squad_hub.sh` | Hub behavior tests. |
| `worker/Dockerfile` | `SQUAD_HUB_SPEC`: pinned npm package by default, `none`, or a git ref. |
| `scripts/deploy.ps1` | `-SquadHubUrl`, `-SquadHubToken`, `-SquadHubApproval`, credential preflight, and device-prefix check. |
