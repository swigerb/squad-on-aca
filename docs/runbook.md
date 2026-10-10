# Squad on ACA runbook

This runbook explains how to deploy and operate Squad on Azure Container Apps.

## Assumptions and prerequisites

- **Azure**: `az` CLI signed in with rights to create resource groups, ACR, Container Apps, user-assigned identities, role assignments, Log Analytics, and optional Key Vault. Select the subscription with `az account set`.
- **GitHub**: `gh` CLI authenticated and `gh auth setup-git` configured. Tokens must support GitHub API work and Copilot CLI headless auth.
- **Local tooling**: PowerShell 5.1+ or PowerShell 7, Git, Node.js/npm. `bash` is needed for worker syntax validation.
- **Telemetry sink**: standalone Aspire Dashboard app `ca-squad-aca-aspire`, with browser-token UI auth, OTLP API-key auth, and internal-only OTLP ports.
- **Optional .NET/Aspire path**: .NET SDK 9.0+ and a .NET 9 runtime. See [../aspire/README.md](../aspire/README.md) and [architecture.md](architecture.md).

## Architecture

| Resource | Purpose |
| --- | --- |
| `<acr-name>` | ACR for the `squad-worker` image. |
| `uai-squad-aca-acrpull` | User-assigned identity used by ACA to pull from ACR and optionally read Key Vault secrets. |
| `cae-squad-aca` | Azure Container Apps environment. |
| `ca-squad-aca-aspire` | Aspire Dashboard with browser-token UI auth and OTLP API-key auth. |
| `caj-squad-aca-session` | Manual ACA job. Every execution is one remote Squad session pod. |
| `caj-squad-aca-ralph` | Scheduled ACA job. Ralph polls every 5 minutes. |
| `ca-squad-aca-watch` | Long-running watcher app for issue-driven unattended work. |
| `law-squad-aca` | Log Analytics workspace for ACA logs. |

## Session model

Every session runs in its own ACA job replica. The worker sets:

```text
SQUAD_DEPLOYMENT_MODE=squad-per-pod
SQUAD_POD_ID=<session name or ACA execution name>
OTEL_SERVICE_NAME=squad-<session name>
```

Dispatch uses the ARM `POST .../jobs/<job>/start?api-version=2026-01-01` API with a JSON body. The control plane reads the stored job template, strips session-managed keys, overlays fresh session values, preserves secret-backed `secretRef` entries, and posts the complete container override as bytes or from a file. Prompt text, session names, branch names, and team names stay inside the request body; they are never placed on a process command line.

`SQUAD_PROMPT` is capped at **100,000 UTF-8 bytes** on every dispatch path. The measured hard ceiling is the Linux kernel's per-string `MAX_ARG_STRLEN` limit (131,072 bytes including `NAME=`), and the worker later appends its publish-contract note before it execs `copilot -p "$SQUAD_AGENT_PROMPT"`, so the control plane stops well short of that ceiling.

Session size comes from the job template, so `deploy.ps1 -SessionCpu` sets it for every dispatcher. The default is 2 vCPU / 4 GiB, enough for a Squad fan-out of several Copilot CLI agents. Memory is derived as 2x CPU (the ACA Consumption ratio); re-running `deploy.ps1` applies a new size to an existing job.

```powershell
.\scripts\deploy.ps1 -SessionCpu 4.0   # 4 vCPU / 8 GiB sessions
```

The session time limit comes from the job template too. `deploy.ps1 -SessionReplicaTimeout` (seconds, default `14400` = 4 h) sets the session job's `replicaTimeout` and its `SQUAD_REPLICA_TIMEOUT_SECONDS` environment variable from the same value, on create and on every redeploy, so the worker always knows the limit ACA enforces. The worker uses it to stop the agent and publish before the hard kill; see [Session deadline](#session-deadline). Before issue #134 the timeout was a hard-coded `7200`.

```powershell
.\scripts\deploy.ps1 -SessionReplicaTimeout 21600   # 6 h sessions
```

## Scale-to-zero behavior

| Component | Idle behavior |
| --- | --- |
| `caj-squad-aca-session` | No running replica between executions. |
| `caj-squad-aca-ralph` | No running replica between scheduled polls. |
| `ca-squad-aca-watch` | Can be scaled to zero with `scripts/start-watch.ps1 -Stop`. |
| `ca-squad-aca-aspire` | Kept running by default so the dashboard is reachable. |

## Ralph job runner

`caj-squad-aca-ralph` runs every 5 minutes with:

```text
SQUAD_MODE=ralph
SQUAD_DEPLOYMENT_MODE=squad-per-pod
SQUAD_POD_ID=ralph-scheduled
```

The deployment uses `parallelism=1`, `replicaCompletionCount=1`, and `replicaTimeout=240`.

Ralph polls GitHub issues labeled `squad`, skips blocked/assigned/already-dispatched issues, adds `squad-aca:dispatched` after a confirmed start, and starts `caj-squad-aca-session` with a prompt for that issue.

The user-assigned managed identity has:

```text
AcrPull on the ACR
Container Apps Jobs Operator on the session job (resource-scoped)
```

The grant is reconciled by `deploy.ps1` on each run.

## GitHub remote sessions

Copilot CLI flags are composed per session by `worker/lib/agent-policy.js` from `SQUAD_MODE` and `SQUAD_DISPATCH_SOURCE`.

An attended session gets:

```text
--allow-all-tools --agent squad --remote --no-auto-update --deny-tool <pattern> ...
```

An unattended session also gets `--no-ask-user` and a longer deny list. Neither attended nor unattended sessions pass `--yolo` to Copilot CLI. `COPILOT_ALLOW_ALL=true` is not set in `worker/Dockerfile`.

Use `COPILOT_GITHUB_TOKEN` or `GH_TOKEN` for Copilot CLI headless auth. Fine-grained PATs with the GitHub Copilot Requests permission are preferred.

### Who publishes

In `prompt` and `new-project` mode with `PUSH_CHANGES=true`, the worker publishes, not the agent. The agent's prompt ends with a note telling it to leave its work in the checkout (committing is fine) and not to run `git push` or `gh pr`. After the agent exits, the worker publishes uncommitted changes, new files, and commits the agent made itself to `OUTPUT_BRANCH` and opens the pull request. Commits that are already on the remote (an attended agent you allowed to push) are not published a second time.

### Pull request base branch

The worker opens the pull request against `GITHUB_BASE_BRANCH` for that execution, resolved on every dispatch path (PowerShell CLI, Ralph/bash, and the GitHub Actions workflow) as: the explicit `--branch`/dispatch base when one was provided, otherwise the repository's **real** default branch fetched at dispatch time. `GITHUB_BASE_BRANCH` is a session-managed key on every dispatch path, so each execution's ARM REST `jobs/<job>/start` request body always carries a fresh value — a stale job-template value from an earlier deploy never wins.

Before opening the pull request, the worker verifies the resolved base branch exists on `origin` (`git ls-remote --exit-code --heads origin <branch>`). If it does not, the worker exits `78` with a clear error instead of silently falling back to `main`.

### Pull request title and body

The agent may leave `.squad-pr/title` and `.squad-pr/body.md` in the checkout to supply a meaningful PR title and body. The worker:

- refuses symlinks at either path (falls back to its own default text, logs why);
- caps the title at 256 characters and the body at 60000 characters;
- strips unsafe control characters, preserving body newlines;
- reads these files **before** the commit, then scrubs `.squad-pr/` from both the worktree and the index unconditionally — it is agent *output*, never repository content, and is never committed;
- passes the resolved title/body to `gh pr create` via `--title`/`--body-file` (a temp file), never by interpolating untrusted text into a shell string;
- always appends the existing governance report to the body after the resolved text — the report can never be replaced by agent-supplied content.

`squad-aca run` also accepts `--pr-title <title>` and `--pr-body-file <path>` (read locally and carried as `PR_TITLE`/`PR_BODY` through the session environment, including the ARM REST JSON body). Precedence, highest to lowest: `--pr-title`/`--pr-body-file` flags, then `.squad-pr/title`/`.squad-pr/body.md` from the agent, then the worker's own default title/body text.

`.squad-pr/` is excluded locally (`.git/info/exclude`) and refused by the worker's additive pre-commit/pre-push hooks even if an agent or earlier process forces it into the index.

### Session deadline

In `prompt` and `new-project` mode (direct and Squad Hub `oneshot`), the agent runs under a watchdog (`worker/lib/squad-deadline.sh`, issue #134). Without it, a session still working when ACA reached `replicaTimeout` was killed with all of its work unpublished.

- **The deadline.** At container start the worker computes `SQUAD_SESSION_DEADLINE_UTC` = start + `SQUAD_REPLICA_TIMEOUT_SECONDS` (default `7200` when unset) - `SQUAD_PUBLISH_MARGIN_SECONDS` (default `900`). If `SQUAD_TOKEN_EXPIRES_AT` is set and its expiry minus the margin is earlier, that wins. A malformed value, or a margin that is not smaller than the timeout, exits `64` before any agent starts. The deadline is logged, exported to the agent, and stated in the publishing note at the end of its prompt: by the deadline, commit a coherent, tested slice, list what is left under `Remaining:`, and stop.
- **At the deadline**, if the agent is still running, the worker sends SIGINT to the agent's process group, SIGTERM 60 s later (`SQUAD_DEADLINE_INT_GRACE_SECONDS`), and SIGKILL 30 s after that (`SQUAD_DEADLINE_TERM_GRACE_SECONDS`). Anything still left in the group is then killed, so nothing writes to the checkout while it is committed. A stale `.git/index.lock` left behind by the agent is removed.
- **Then the normal publish runs**: the same governance checkpoint, the pin hook and the pin backstop as any other session. A tree with changes is committed as `WIP: <commit message> (stopped at session deadline)`. The branch is pushed to `OUTPUT_BRANCH` (default `squad/<session>`). The pull request is opened with `--draft`, a `WIP:` title, a body that says the session stopped at its deadline, and a `## Remaining` checklist. If the repository cannot have draft pull requests, a regular pull request is opened, still titled and described as WIP. A governance violation or a staged `.squad/memory/config.json` still refuses the publish with `78`, exactly as it would for a finished session.
- **The session exits `124`** after publishing, and the lease records `session-deadline-exit-124`. An agent that exits by itself before the deadline behaves as before: exit 0 publishes normally, and a non-zero exit ends the session with the agent's status and publishes nothing.

With `PUSH_CHANGES=false` the agent is still stopped at the deadline (exit `124`), but nothing is published.

**A replica SIGTERM before the deadline does not publish.** This covers `squad-aca stop`, which cancels the execution, and any other early kill. That signal keeps its previous behavior: the session ends and nothing is pushed. This is deliberate:

- `squad-aca stop` is an intentional stop, and publishing at that point would push work the operator just chose to abandon.
- `runuser`, the replica's PID 1, SIGKILLs the session 2 s after forwarding SIGTERM (util-linux `su-common.c`). That is too little time for a governance-checked commit and push.

The deadline margin is what protects work against the replica timeout. Give a session more time with `deploy.ps1 -SessionReplicaTimeout`, not a smaller margin.

## Squad health gate

For modes that run an agent (`prompt`, `new-project`, `loop`, `watch`, and `triage`), the worker runs `squad health --json` after clone, `squad init` if needed, and SubSquad activation, but before policy hardening and before any agent starts.

The parsed report must use this schema:

```json
{ "schema": "squad-health/v1", "status": "pass", "checks": [{ "id": "team", "status": "pass", "message": "..." }] }
```

The overall status is `pass` or `fail`; check status is `pass`, `fail`, or `skip`. The check ids emitted by Squad 0.13.1 and 1.0.1 are `team`, `registry-charters`, `routing`, `state-backend`, and `env-vars`. There is no `warn` status.

On Squad 1.0.1 a repository that still carries the 0.13 casting layout fails `registry-charters` ("Cannot read a consistent casting registry/history pair: ..."). The worker still refuses the session with exit 78, and its log names the fix: run `squad upgrade` with Squad 1.0.1 or later, then commit `.squad/casting/registry.json`, `.squad/casting/history.json` and `.squad/casting/registry-history.commit.json`, and pin `.squad/casting/*.json text eol=lf` in `.gitattributes` (the commit manifest hashes exact bytes).

A parsed `status: "fail"` fails closed in the worker with exit `78` and logs the failing check ids:

```text
Squad health: FAIL -- failing checks: routing,state-backend
A session whose Squad state is not ready must not dispatch an agent against it; refusing to start.
```

A CLI that predates `squad health --json`, or output that is not a readable `squad-health/v1` report, is logged as `UNAVAILABLE` and is not counted as a pass. `squad-aca doctor` has a matching `Squad health` row: `ok` for `pass`, `failed` with failing check ids for `fail`, and `unknown` for an unavailable or unreadable health report.


## Agent tool policy

Every session resolves a tier before the agent starts.

| Signal | Value | Tier |
| --- | --- | --- |
| `SQUAD_MODE` in `prompt`, `new-project`, `shell`, `smoke`, `telemetry-smoke` and `SQUAD_DISPATCH_SOURCE=local-cli` | A person started the run | `attended` |
| Anything else, including `ralph`, `watch`, `triage`, `loop`, `api`, unrecognised values, or absent `SQUAD_DISPATCH_SOURCE` | Unattended | `autonomous` |

| | attended | autonomous |
| --- | --- | --- |
| `shell(sudo)`, `shell(su)` | denied | denied |
| `shell(chmod)`, `shell(chown)`, `shell(chattr)`, `shell(setfacl)` | denied | denied |
| `shell(git config)`, `shell(gh auth)`, `shell(gh secret)`, `shell(gh variable)` | denied | denied |
| `shell(az)`, `shell(kubectl)`, `shell(terraform)`, `shell(docker)` | allowed | denied |
| `shell(gh api)`, `shell(gh repo delete)`, `shell(gh release delete)` | allowed | denied |
| `--no-ask-user` | no | yes |
| writes outside the checkout | denied | denied |
| writes to a governance path | denied | denied |
| appends to `.squad/agents/<name>/history.md` | allowed, append-only | allowed, append-only |

Governance paths are classified before the agent starts:

| Class | Paths | Runtime behavior |
| --- | --- | --- |
| Locked | `.squad/policies`, `.squad/agents` except existing `.squad/agents/<name>/history.md`, `.squad/identity` except `.squad/identity/now.md`, `.squad/config.json`, `.squad/routing.md`, `.squad/casting-policy.json`, `.squad/memory/config.json`, `.squad/fact-checker/policy.md`, `.squad/fact-checker/audit-trail.md`, `.squad/rai/policy.md`, `.squad/rai/audit-trail.md` | Write bits are removed and any content, add, delete, or committed change is a governance violation. |
| Append-only | `.squad/agents/<name>/history.md`, `.squad/memory/audit.jsonl` | Existing files may grow only; rewrite, deletion, or truncation below the recorded high-water mark fails the session. A new `history.md` that did not exist at hardening time cannot be created by the run. |
| Reported-mutable | `.squad/casting/policy.json`, `.squad/casting/registry.json`, `.squad/casting/history.json`, `.squad/identity/now.md` | Changes are allowed, listed in the governance report, and appended to the PR body when the entrypoint creates the PR. Watch/loop also write the report to the root-sealed store. |

The baseline is held in entrypoint memory and, in the container, sealed into a root-owned `0711` directory under `/run` before the `runuser` drop. Sealed files are root-owned `0644`: readable by design, because this is an integrity boundary, not a secrecy boundary. A policy failure or governance violation aborts with worker exit `78` and still tries to emit the governance report. The session-only memory-audit-rotation pin is one such locked path: the worker never commits it; it lives in the working tree, sealed out of git staging (an index property when the path is tracked, only an ignore rule when it is not). The sampler, `worker/squad-agent`, git hooks and `squad_push_branch` detect or refuse a broken seal (exit `78`, nothing pushed by the container). A deleted pin is re-pinned. See [security.md](security.md#session-only-memory-audit-pin) for exactly what is prevented and what is only detected.

`SQUAD_COPILOT_FLAGS` supports extras such as `--model` or `--log-level`. Permission-widening flags (`--yolo`, `--allow-all`, `--allow-all-paths`, `--allow-all-urls`, `--add-dir`) abort the worker session with exit `78`. A `--model` in it must match the pinned model (see [Model pin](#model-pin)).

### Model pin

Every Copilot launch the worker makes runs on an explicit `--model`, resolved once before `copilot` starts by `squad_policy_resolve_model` (`worker/lib/squad-policy.sh`, backed by `agent-policy.js model-pin`). The model comes from the checked-out repository's `.squad/config.json`, for the role the session plays, so the policy stays per role and no single model is applied to everything:

| Session mode | Role | Model comes from |
| --- | --- | --- |
| `prompt`, `new-project`, `smoke` (this includes every session Ralph dispatches) | `lead`, the coordinator | `agentModelOverrides.lead`, else `defaultModel` |
| `watch`, `triage`, `loop` (the sessions that run Ralph's charter) | `ralph` | `agentModelOverrides.ralph`, else `defaultModel` |
| `ralph` dispatcher, `telemetry-smoke`, `shell` | none: no Copilot session starts | not applicable |

- There is no model list in the image: the worker checks only that the value is a plain token, so a model newer than the image is never rejected by a stale catalog. `defaultModel: "auto"` means the repository does not choose.
- An operator override (`SQUAD_MODEL`, `SQUAD_AGENT_MODEL`, `COPILOT_MODEL`, or `--model` in `SQUAD_COPILOT_FLAGS`, including the `model` dispatch input) is accepted only when it names the same model as the policy. A different one aborts with exit `78` and an error naming both; there is no fallback to either. Overrides that disagree with each other, with no policy to arbitrate, also abort.
- The role comes from the session mode, so the lead and Ralph are configured separately: there is no one global model. When the repository has no entry for the role and `defaultModel` stands in for it, the session log says so with a `WARNING:` line naming the missing `agentModelOverrides.<role>` entry; the warning is never a way past a declared model, which is still pinned. `defaultModel: "auto"` (or an `auto` role entry) is a different thing from "nothing declared": the log says Copilot chooses the model for the role on purpose. Only a repository that declares nothing for the role runs on Copilot's own default, logged as `Model: NOT PINNED` with "declared none for this role".
- `--model` is forwarded exactly once. Every spelling the operator supplied (`--model X`, `--model=X`, repeated, any combination of `SQUAD_MODEL`, `SQUAD_AGENT_MODEL`, `COPILOT_MODEL` and `SQUAD_COPILOT_FLAGS`) is validated and then removed, and the resolved model is emitted as the single `--model <model>` right after the caller's `-p <prompt>`. Repeated matching values collapse to that one; a conflicting one is refused (`78`). `SQUAD_COPILOT_FLAGS` is split on whitespace with no quote handling, so a quoted model value is refused as not a model id.
- `worker/squad-agent` (the watch/loop agent) refuses to start if the pin was required but the model did not arrive, and rejects any different `--model` it is handed.
- `prompt`, `new-project` and `smoke`: if the pinned model is unavailable or over quota, Copilot exits non-zero and that is the session's result: no retry, no other model, and no output is read for a success message. Nothing is published.
- `watch`, `triage` and `loop`: Squad itself does not stop when its agent exits non-zero (`watch` keeps polling, `loop` logs the failure and reschedules). Copilot has no distinct exit status for "the model could not be selected", so for a pinned session **any** non-zero exit of the pinned Copilot that the wrapper did not cause itself is treated as terminal. `worker/squad-agent` runs Copilot as a child, records the status in `<WORKDIR>/<session>/model-pin-failure` and exits with it; once that file exists no further Copilot launch can start (a second one exits `78` without running Copilot); the worker sends `TERM` to the Squad process it owns (and `KILL` to that process and its process group after `SQUAD_FOREGROUND_STOP_GRACE_SECONDS`, default 120), runs the governance checkpoint and report as usual, and exits with the recorded status. A pinned session starts Squad in its own process group, so when Squad ends abnormally (a non-zero status, a forwarded signal, or the stop above) the worker also sweeps that one group, and the agent wrapper or Copilot a dead Squad left behind cannot outlive the session. A clean exit `0` sweeps nothing. Only the owned pid and the owned process group are ever signalled: nothing is killed by name and nothing is published. A clean exit `0` continues normally, and a Copilot stopped by a signal the wrapper forwarded is not recorded as a failure. This is a deliberate change from keep-polling: a pinned session that fails to start Copilot for any reason now ends after one attempt rather than being retried on every interval.
- Hub supervision of `prompt` and `new-project` sessions with a pinned model is capability-gated. The worker runs the bounded, side-effect-free probe `squad-hub oneshot --capabilities` (limit `SQUAD_HUB_CAPABILITY_TIMEOUT_SECONDS`, default 10; every `SQUAD_HUB_*` variable removed, stdin closed, stderr discarded). The bound covers the probe's whole process tree: it runs in a process group of its own writing to a private, size-capped file (not a pipe, so a descendant holding stdout cannot stall the reader), and that group is killed when the probe ends however it ended -- a probe that leaves anything running is refused like any other answer that is not a clean yes. It proceeds only when its stdout is a JSON object with `protocolVersion` equal to `1` and `requiredModel` equal to the literal `true` (a capable Hub prints `{"protocolVersion":1,"requiredModel":true}`). Only then does it run `squad-hub oneshot` with `SQUAD_HUB_MODEL=<resolved model>` and `SQUAD_HUB_REQUIRE_MODEL=1`, set for that command only, so the Hub confirms the model from the ACP config its agent returns before the first prompt or sends none. Anything else (a Hub that does not know the flag, a non-zero or timed-out probe, malformed or oversized output, no `requiredModel`, an operator `SQUAD_HUB_MODEL` naming a different model) is refused with exit `78` before `oneshot` is started; a capable Hub that could not confirm the model exits `78` having sent no prompt. Both end the session with no retry and no fallback model, and no version is guessed and no HTTP endpoint or log line is consulted. The Hub's own configuration is not the problem and the operator is not told to unset it. Approval supervision, device identity and the lease are unchanged. The image still pins `squad-hub@0.6.0`, which does not implement the probe (installed, with the variables scrubbed it exits `64` asking for `SQUAD_HUB_URL`/`SQUAD_HUB_TOKEN`), so hub-supervised pinned `prompt`/`new-project` sessions stay refused until a Hub release that implements it exists and the image pin is moved; this repository does not change the pin. Watch/loop under the hub go through `worker/squad-agent` and do not need the capability.

`worker/tests/test_model_pin.sh` runs the real entrypoint blocks and asserts the argv `copilot` actually receives.
## watch/loop policy

The `watch` and `loop` modes run continuously and spawn their own Copilot CLI invocations. squad-on-aca routes these through a wrapper at `/usr/local/lib/squad-on-aca/squad-agent` (instead of the default `copilot` CLI path) that:

1. Resolves the session's `attended` or `autonomous` policy tier (same rules as above).
2. Runs `copilot -p <prompt>` with the resolved policy argv (an `exec` when no model is pinned; as a supervised child when one is, so a failure can be recorded — see [Model pin](#model-pin)), so permission-widening flags abort with exit 78.
3. Adds `--additional-mcp-config @<repo>/.mcp.json` itself (without `--yolo`) so `squad_state_*` tools keep working.
4. Refuses to start (exit 78) if the policy cannot be resolved.

This prevents watch/loop from inheriting the upstream Squad behavior of injecting `--yolo` whenever `.mcp.json` exists.

### Policy gap: multi-word deny rules

By default the watch/loop wrapper runs in **PARITY** mode: it uses the same effective deny-rule subset that the previous `squad --copilot-flags` path could deliver. Single-word deny rules such as `shell(sudo)`, `shell(az)`, `shell(curl)`, and `shell(wget)` are enforced. Multi-word deny rules are announced in the log as not enforced on this path; that includes `shell(git config)`, `shell(gh auth)`, `shell(gh secret)`, `shell(gh variable)`, `shell(gh api)`, `shell(gh repo delete)`, `shell(gh release delete)`, `shell(git push)`, and `shell(gh pr)`.

To opt in to the full argv, including the multi-word deny rules, set:

```powershell
$env:SQUAD_WATCH_STRICT_POLICY = "true"
```

This makes `worker/entrypoint.sh` export the `watchAgentStrictArgv` from `worker/lib/agent-policy.js` instead of `watchAgentParityArgv`. By default, `SQUAD_WATCH_STRICT_POLICY` is unset or `false`, preserving today's effective single-word enforcement for backward compatibility.

Policy output is prefixed `[squad-policy]`. Read it with:

```powershell
.\scripts\logs.ps1
az containerapp job logs
```

Check tier resolution:

```powershell
$env:SQUAD_MODE = "ralph"; $env:SQUAD_DISPATCH_SOURCE = "ralph"
node .\worker\lib\agent-policy.js json
```


### Graceful watch/loop shutdown

`worker/lib/squad-signal-forwarding.sh` runs `squad watch` and `squad loop` as a background child and forwards SIGTERM/SIGINT to that child, then waits for the child's real exit status. This lets Squad drain an in-flight turn when ACA stops or scales down the watcher. `deploy.ps1` sets `--termination-grace-period 300` on `ca-squad-aca-watch` so ACA gives the forwarded signal time to work.

Squad 0.13 also has an undocumented `--sentinel-file` flag. Its behavior is inverted from the obvious reading: watch creates the sentinel file at startup and stops when the file is removed, checking between polling rounds. `squad-aca watch stop` is not wired to delete that file because the file lives inside the replica filesystem; doing so would need an exec channel such as `az containerapp exec` or a shared volume that this deployment does not create. The supported stop path is scaling the watcher to zero, which sends SIGTERM and uses the forwarding path above.

Classify governance paths:

```powershell
node .\worker\lib\agent-policy.js classify-governance-path .squad/agents/docs/history.md   # append-only
node .\worker\lib\agent-policy.js classify-governance-path .squad/agents/docs/charter.md   # locked
```


## Externalized Squad state refusal

Squad on ACA only supports Squad state that lives in this repository's own `.squad/` directory. A `.squad/config.json` is considered live only when it has both a numeric `version` and a string `teamRoot`. Given a live config, these layouts are refused:

- `stateLocation: "external"`, written by `squad externalize`.
- `teamRoot` with any value other than `"."`, such as a remote/satellite team root.

`squad-aca doctor` reports a failed `Squad state location` row; it does not use the worker's exit `78` for this local check. `squad-aca run` refuses before starting compute and surfaces a PowerShell `throw`, which exits `1`, not `78`. Inside ACA, `worker/entrypoint.sh` checks after clone and before `squad init`, the health gate, policy hardening, or the agent; that worker path fails closed with exit `78`.

Remediate by running `squad internalize`, setting `teamRoot` back to `.`, or dispatching from the repository that actually owns the team state.

## Deploy

```powershell
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
```

Common defaults:

```text
Location: centralus
Resource group: rg-squad-aca-dev-centralus
```

For Key Vault-backed secret references:

```powershell
.\scripts\deploy.ps1 -UseKeyVault -KeyVaultName kv-your-squad-aca
```

Deployment output is written to ignored local file `deploy.outputs.json`.

`deploy.ps1` is idempotent and safe to re-run for upgrades, token rotation, and recovery. The Aspire dashboard app is updated in place with `az containerapp update --yaml`.

## Start a session

### Existing Squad repo

```powershell
cd path\to\existing-squad-repo
squad-aca "Use the existing Squad team to implement the next feature and open a PR"
```

Add `--sync-all` to commit and push the full working tree before dispatch.

Control-plane commands:

```powershell
squad-aca doctor
squad-aca sessions --limit 20
squad-aca logs <session-or-execution> --tail 200
squad-aca stop <session-or-execution>
squad-aca open <session-or-execution>
squad-aca sync --dry-run
squad-aca sync --sync-all
squad-aca watch start --repo "<github-owner>/<repo>"
squad-aca watch stop
squad-aca ralph status
squad-aca ralph run --repo "<github-owner>/<repo>"
squad-aca ralph pause
squad-aca ralph resume
squad-aca subsquad list
squad-aca subsquad run docs "Update the docs and open a PR"
squad-aca upgrade --deploy
squad-aca telemetry smoke
squad-aca secrets rotate
squad-aca export squad-export.json
squad-aca import squad-export.json
```

Destructive command:

```powershell
squad-aca destroy --yes
```

Configure an existing deployment:

```powershell
squad-aca configure --resource-group <rg> --session-job <job> --subscription <azure-subscription-id>
```

### Session environment variables

Set on the session job by the control plane. Override them when starting a job
by hand.

| Variable | Purpose |
|---|---|
| `SQUAD_MODE` | `prompt`, `new-project`, `loop`, `watch`, `triage`, `shell`, `smoke`, `telemetry-smoke`, or `ralph`. |
| `SQUAD_PROMPT` | What the session should do. Required by `prompt`. Capped at 100,000 UTF-8 bytes before dispatch. |
| `SESSION_NAME` | Names the run in logs and in the hub. |
| `SQUAD_POD_ID` | Identifies the pod for SubSquad routing. Set to the session name on every dispatch path. |
| `OTEL_SERVICE_NAME` | Groups traces/logs as `squad-<session>`. Set on every dispatch path. |
| `GITHUB_REPOSITORY` | The `owner/repo` the session works in. |
| `SQUAD_DISPATCH_SOURCE` | Who started the run: `local-cli`, `ralph`, or `actions`. Feeds the tool policy. |
| `SQUAD_COPILOT_FLAGS` | Extra Copilot CLI flags. Cleared on every deploy. |
| `SQUAD_HUB_URL` / `SQUAD_HUB_TOKEN` | Attach the session to a Squad Hub. Both empty turns supervision off. |
| `SQUAD_HUB_ONESHOT` | Run one session, then exit. Used by dispatched cloud runs. |
| `AZURE_RESOURCE_GROUP`, `AZURE_CLIENT_ID`, `ACA_SESSION_JOB_NAME` | Used by `ralph` to start session jobs. |
| `RALPH_LABELS` | Issue labels Ralph dispatches. Default `squad-aca`. |
| `RALPH_MAX_ISSUES` | Issues per Ralph run. Default `3`. |
| `SQUAD_REPLICA_TIMEOUT_SECONDS` | The session job's `replicaTimeout`, set by `deploy.ps1 -SessionReplicaTimeout`. Defaults to `7200` when unset. Used to compute the session deadline. |
| `SQUAD_PUBLISH_MARGIN_SECONDS` | How long before the replica timeout the agent is stopped so its work can be published. Default `900`. |
| `SQUAD_TOKEN_EXPIRES_AT` | Optional ISO-8601 expiry of the session's GitHub token. If it is earlier, the deadline becomes this time minus the margin. |
| `SQUAD_SESSION_DEADLINE_UTC` | Computed by the worker and exported to the agent; never read from the inbound environment. When the agent is stopped and its work published as a draft WIP pull request. |
| `SQUAD_DEADLINE_INT_GRACE_SECONDS` / `SQUAD_DEADLINE_TERM_GRACE_SECONDS` | Time after SIGINT before SIGTERM (default `60`), and after SIGTERM before SIGKILL (default `30`). |

Developer flow:

```powershell
squad-aca init --owner "<github-owner>" --name "my-app"
squad-aca "Build the first feature and open a PR"
```

Copilot control-plane flow:

```powershell
copilot --agent squad-aca
```

Smoke test:

```powershell
.\scripts\start-session.ps1 -Repository "<github-owner>/<repo>" -Mode smoke -RunCopilotSmoke -SessionName smoke-001
```

Prompt session:

```powershell
.\scripts\start-session.ps1 `
  -Repository "<github-owner>/<repo>" `
  -Mode prompt `
  -SessionName docs-001 `
  -Prompt "Use Squad to improve the docs. Open a PR if changes are needed." `
  -PushChanges `
  -OutputBranch squad/docs-001
```

Loop session:

```powershell
.\scripts\start-session.ps1 -Repository "<github-owner>/<repo>" -Mode loop -SessionName daily-loop
```
## Session logs

```powershell
squad-aca logs <session-or-execution> --tail 200
```

`logs` reads console output through the first available path:

1. `az containerapp job logs show`, when the `containerapp` Azure CLI extension is installed.
2. Log Analytics fallback, using `law-squad-aca` or the configured workspace.

Check the active path:

```powershell
squad-aca doctor
```

Install log extensions when needed:

```powershell
az extension add --name containerapp
az extension add --name log-analytics
```

Configure a non-default workspace:

```powershell
squad-aca configure --log-analytics-workspace <workspace-name>
```

Manual Log Analytics query:

```powershell
$wsid = az monitor log-analytics workspace show `
  --resource-group <rg> --workspace-name law-squad-aca --query customerId -o tsv
az monitor log-analytics query -w $wsid --analytics-query @"
ContainerAppConsoleLogs_CL
| where ContainerGroupName_s startswith '<execution-name>'
| top 200 by TimeGenerated desc
| project TimeGenerated, Log_s
| order by TimeGenerated asc
"@
```

Log Analytics ingestion can lag a few minutes after a session starts. An execution with no rows yet produces a warning, not an error.

## Start a project without a repo

```powershell
squad-aca new --owner "<github-owner>" --name my-new-squad-project --description "A new app bootstrapped by Squad on ACA"
```

Direct script form:

```powershell
.\scripts\new-project.ps1 `
  -Owner "<github-owner>" `
  -Name my-new-squad-project `
  -Description "A new app bootstrapped by Squad on ACA"
```

If the repo already exists, pass `-UseExisting`.

## Start a watcher

```powershell
.\scripts\start-watch.ps1 -Repository "<github-owner>/<repo>" -IntervalMinutes 5 -TimeoutMinutes 45
```

Stop the watcher:

```powershell
.\scripts\start-watch.ps1 -Repository "<github-owner>/<repo>" -Stop
```

## Run SubSquads

Commit `.squad/streams.json` to the target repo:

```json
{
  "defaultWorkflow": "branch-per-issue",
  "workstreams": [
    {
      "name": "platform",
      "labelFilter": "team:platform",
      "folderScope": ["src", "infra"],
      "description": "Platform and infrastructure work"
    },
    {
      "name": "docs",
      "labelFilter": "team:docs",
      "folderScope": ["docs", "README.md"],
      "description": "Documentation work"
    }
  ]
}
```

Start scoped sessions:

```powershell
.\scripts\start-session.ps1 -Repository "<github-owner>/<repo>" -Mode prompt -SubSquad docs -SessionName docs-001 -Prompt "Work the next docs issue."
.\scripts\start-watch.ps1 -Repository "<github-owner>/<repo>" -SubSquad platform
```

## Monitor

```powershell
squad-aca status
.\scripts\show-status.ps1
```

Open `aspireLoginUrl` from `deploy.outputs.json`. Filter by service name:

```text
squad-smoke-001
squad-docs-001
squad-watch-default
```

## CI/CD

The repo includes `.github/workflows/deploy-aca.yml`. Configure these GitHub secrets before running it:

```text
AZURE_CLIENT_ID
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
SQUAD_GITHUB_TOKEN
SQUAD_COPILOT_GITHUB_TOKEN
```

The Azure identity behind `AZURE_CLIENT_ID` needs rights to create and update resource groups, ACR, Container Apps, managed identities, role assignments, Log Analytics, and optional Key Vault resources.

## ACA Sandboxes (preview, feature-flagged OFF)

`squad-aca` can dispatch a session to Azure Container Apps Sandboxes instead of an ACA Job. ACA Jobs are the default and rollback path. Sandboxes are off by default.

### Prerequisites

1. Install the standalone `aca` CLI v1.0.0-preview.1 or later. It is not an `az` extension. Override the path with `SQUAD_ACA_SANDBOX_CLI`.
2. Create a sandbox group with no managed identity:

```powershell
aca sandboxgroup create --name sbg-squad-aca --location centralus --set-config
```

Do not pass `--identity`.

3. Create a disk built from the worker image:

```powershell
az acr login --name <acr> --expose-token
az account set --subscription <sub>
aca sandboxgroup disk create --image <acr>.azurecr.io/squad-worker:<tag> `
    --name squad-worker --username 00000000-0000-0000-0000-000000000000 --token <acr refresh token>
aca sandboxgroup disk list -o json
```

Use the GUID from `aca sandboxgroup disk list -o json` as `sandboxDiskId`.

4. Use a reviewed class catalog at `config/sandbox-classes.json` with `"provisional": false` and pinned `sha256` digests for approved classes.
5. Add sandbox settings to `~/.squad-on-aca/config.json`:

```powershell
squad-aca configure --resource-group <rg> --session-job <job> --subscription <sub>
# then add, by hand, to ~/.squad-on-aca/config.json:
#   "sandboxGroup":  "sbg-squad-aca",
#   "sandboxDiskId": "<GUID from `aca sandboxgroup disk list -o json`>"
```

### Enable the flag

```powershell
$env:SQUAD_ACA_ENABLE_SANDBOX = "1"     # accepted: 1 / true / yes / on / enabled
squad-aca run "<prompt>"
```

With the flag off, a repository that requires a non-default capability is refused with `sandbox-feature-disabled-and-default-insufficient`.

### Credentials

| Plane | Reaches the sandbox? | How |
| --- | --- | --- |
| Control plane (`az`/`aca` login) | No | Stays on the operator machine. |
| Runtime Azure managed identity | No | The sandbox group carries no identity. |
| GitHub (`git` / `gh` push) | Yes | Uploaded as a file with `aca sandbox fs write` into a `0700` state directory. |
| Copilot | Yes | Uploaded file, or native brokerage with `aca sandboxgroup credential create --type github-copilot` when using a fine-grained PAT. |

For local `run`, `squad-aca.ps1` resolves the git token from `SQUAD_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, or `gh auth token`. It resolves the Copilot token from `SQUAD_COPILOT_GITHUB_TOKEN` or `COPILOT_GITHUB_TOKEN`. If no Copilot token is set, the git token serves both planes.

Credential flow:

1. Create the state directory:
   ```text
   aca sandbox exec … -c 'umask 077; mkdir -p <state> && chmod 700 <state> && rm -f <state>/.squad-creds && echo squad-credentials-vault-$(stat -c %a <state>)'
   ```
2. Upload credentials:
   ```text
   aca sandbox fs write --path <state>/.squad-creds --file <local>
   ```
3. Launch sources and removes the file:
   ```text
   if [ -f <state>/.squad-creds ]; then . <state>/.squad-creds; rm -f <state>/.squad-creds; fi
   ```

`aca sandbox exec` does not forward stdin. Use `fs write` for file delivery. Brokerage with `sandboxgroup credential create` reads stdin.

Troubleshooting:

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Refusing to dispatch … no GitHub credential` | No usable git token | Run `gh auth login`, or set `GH_TOKEN`. |
| `Refusing to broker … a classic personal access token` | `--type github-copilot` requires a fine-grained PAT | Set `SQUAD_COPILOT_GITHUB_TOKEN=github_pat_…`. |
| `Refusing to upload credentials … is mode '<x>', not 700` | State directory is not private | Delete the sandbox and retry. |
| Worker log: `Error: No authentication information found` | Credential file did not arrive | Check for `sandbox fs write … .squad-creds` before launch. |
| Worker log: `ProxyResponseError: HTTP 403 … does not appear to originate from GitHub` | Copilot API blocked by egress policy | Allow `*.githubcopilot.com` and `*.githubusercontent.com` in the class template. |

Mint a fine-grained PAT for the Copilot plane:

```powershell
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" `
  -DefaultRepository "<github-owner>/<repo>" `
  -CopilotGitHubToken "<a fine-grained PAT, github_pat_...>"
```

Delete a brokered credential by hand:

```powershell
aca sandboxgroup credential delete --id <credential id> --yes
```

Do not capture output from `aca sandboxgroup credential list`, `aca sandboxgroup credential show`, `aca sandbox egress show`, or `aca sandbox egress export`; they return values. Use `aca sandbox egress decisions -l name=squad-<session> -o json` for the audit trail.
### Concurrency, cost, and cleanup

Stop a sandbox session:

```powershell
squad-aca stop <session>
```

Sandbox stop reports one of these tokens:

| Token | Meaning | What to do |
| --- | --- | --- |
| `killed` / `already-dead` / `already-terminal` | Success | Nothing |
| `no-pidfile` | No pid was recorded | Delete the sandbox: `aca sandbox delete -l name=<name> --yes` |
| `bad-pidfile` | Pid file is unusable | Delete the sandbox |
| `not-ours` | Pid is alive but not the worker entrypoint | Delete the sandbox |
| `kill-failed` | Signal was rejected | Delete the sandbox |
| `survived` | Worker did not stop | Delete the sandbox |
| `no-proc` / `scan-failed` | `/proc` could not be read | Delete the sandbox |

A sandbox bills from creation until it is deleted. Auto-suspend stops the meter but does not delete the sandbox.

Required controls:

1. Every class in `config/sandbox-classes.json` declares `limits.maxConcurrentSandboxes`.
2. The provider sets auto-suspend explicitly: 1800 s idle, 20 s poll.
3. Every sandbox is labelled `squad-<session id>`.

Run the reaper:

```powershell
. .\scripts\lib\providers\squad-sandbox-provider.ps1
$ctx = (New-SandboxExecutionProvider -Class $class -SandboxGroup sbg-squad-aca).Context
Invoke-SquadSandboxReaper -Context $ctx
Invoke-SquadSandboxReaper -Context $ctx -KeepSessionIds @('<live session>') -Delete
```

Or clean up by hand:

```powershell
aca sandbox list -o json
aca sandbox delete -l name=squad-<session> --yes
```

Failure tags:

```text
[squad-sandbox:auth]
[squad-sandbox:capability]
[squad-sandbox:quota]
[squad-sandbox:readiness]
[squad-sandbox:execution]
[squad-sandbox:transport]
[squad-sandbox:config]
```

### Roll back to ACA Jobs

```powershell
Remove-Item Env:SQUAD_ACA_ENABLE_SANDBOX
$env:SQUAD_ACA_ENABLE_SANDBOX = "0"
```

`0`, `false`, `no`, and `off` are explicit off values. Turning the flag off does not delete running sandboxes.

Find and remove running sandboxes:

```powershell
aca sandbox list -o json
aca sandbox delete -l name=squad-<session> --yes
```

### Operating notes

- Treat `Network issue — retry policy expired` from `aca sandbox exec` as inconclusive and re-poll.
- Launch sessions detached and poll them. Do not hold a session open with one `aca sandbox exec`.
- Keep the lifecycle poll interval below the idle timeout.
- Session results are pushed to GitHub by the worker before terminal state. The sandbox disk is scratch.
- If `az acr login --expose-token` changes the active subscription, run `az account set --subscription <sub>` again.

### Add or re-pin a sandbox class image

1. Build the image:

```powershell
az account set --subscription 3898b8ea-c676-4b43-95fc-d38425627d74
az acr build --registry acrsquadacah81u42kq `
  --image "squad-worker-python:<tag>" worker/images/python
az acr repository show --name acrsquadacah81u42kq `
  --image "squad-worker-python:<tag>" --query digest -o tsv
```

2. Edit `config/sandbox-classes.json`: set `image.reference`, `image.tag`, `image.digest`, `image.pinned: true`, and `tools[]`.

3. Verify live and record evidence:

```powershell
pwsh -NoProfile -File .\scripts\verify-image-tools.ps1 -ClassId sandbox-python-3-12
```

Useful switches:

| Switch | Effect |
| --- | --- |
| `-ClassId <id>` | Which class to verify. Required. |
| `-AdditionalTools a,b` | Probe extra tools beyond the declared list. |
| `-KeepDisk` | Leave the disk behind for reuse by real sessions. |
| `-DiskLabel <name>` | Reuse or create a disk under a specific label. |

4. Confirm the offline check and gates:

```powershell
node worker\lib\verify-image-evidence.js
pwsh -NoProfile -File .\scripts\validate.ps1
```

5. Commit the evidence file with the catalog change.

Cleanup after an interrupted probe:

```powershell
$aca = "C:\Users\<you>\.aca\bin\aca.exe"
$c = @("-s", "<sub>", "-g", "rg-squad-aca-dev-centralus", "--sandbox-group", "sbg-squad-aca")
& $aca @c sandbox list -o json
& $aca @c sandbox delete --id <sandbox id> --yes
& $aca @c sandboxgroup disk list -o json
& $aca @c sandboxgroup disk delete --id <disk id>
```

Global `aca` options such as `--sandbox-group` must come before the subcommand. `sandbox delete` prompts unless `--yes` is passed.

## Rollback and recovery

Use [rollback.md](rollback.md) for ordered recovery procedures:

1. Optional .NET/Aspire path.
2. ACA Sandboxes.
3. ACA worker image / session job.
4. Aspire token / secrets.
5. Ralph / watch.
6. Full resource-group destroy / redeploy.

## Dispatch leases

Every dispatch writes a durable lease before it asks Azure for compute. See [architecture.md#unified-dispatch-contract-and-durable-leases](architecture.md#unified-dispatch-contract-and-durable-leases).

Leases live in the same repository on orphan ref `squad-aca-leases`, one JSON blob per lease under `leases/`. Dispatch requires `contents: write`.

### Inspect leases

```powershell
squad-aca leases
squad-aca leases list --repo owner/repo
```

Read the ledger directly:

```powershell
gh api repos/OWNER/REPO/contents/leases?ref=squad-aca-leases --jq '.[].name'
gh api repos/OWNER/REPO/contents/leases/issue-42.json?ref=squad-aca-leases --jq '.content' | base64 -d
```

### Clear a stuck lease

1. Confirm nothing is running:

```powershell
squad-aca sessions
```

Stop any live execution first:

```powershell
squad-aca stop <session>
```

2. Sweep:

```powershell
squad-aca leases sweep
```

The sweeper uses `SQUAD_LEASE_TTL_SECONDS`, default 1 hour. Ralph sweeps automatically at the start of every run.

3. Re-dispatch the work. A reclaimed lease is repairable.

4. Delete a corrupt blob only when the ledger itself is corrupt:

```powershell
gh api -X DELETE repos/OWNER/REPO/contents/leases/issue-42.json `
  -f message="clear corrupt lease" -f branch=squad-aca-leases -f sha=<blob-sha>
```

If a sweep errors, check auth, RBAC, throttling, network, and `contents: write`.

### 404 on a lease write

If a lease write fails with `gh: Not Found (HTTP 404)`, check the active GitHub identity. GitHub can report a write denial on a readable repository as 404.

```powershell
gh auth status
gh api user --jq .login
gh api repos/OWNER/REPO --jq .permissions
```

Switch to an account with write access:

```powershell
gh auth switch --user <account-with-write-access>
```

`squad-aca doctor` reports both `GitHub auth` and `GitHub push`.

## Who can run Squad on ACA

A run costs money and executes an agent with a token that can write to the
repository, so every route is gated on repository access.

| Route | Who can use it |
|---|---|
| Apply the `squad-aca` label to an issue | Collaborators with **Triage** or above |
| Comment `/squad-aca <instruction>` or `@squad-on-aca-control-plane <instruction>` | **Owner, organisation member, or collaborator** |
| Run the workflow manually | Collaborators with **Write** or above |
| Ralph's poll | Only picks up issues that already carry the label |

**To let somebody run it: add them in Settings → Collaborators and teams.** Any
role works, including Read. Removing them revokes it immediately.

`CONTRIBUTOR` is **not** a permission and is **not** accepted. GitHub reports it
for anyone who has ever had a commit merged, which on a public repository is
anybody who once landed a pull request; they have no access. The thing you grant
is a **collaborator**.

Squad Hub grants nothing here. Its **Start a new ACA job…** action writes a
GitHub URL and opens it; the request is created by the person's own GitHub
account, and this repository decides whether it runs. Someone added to Squad Hub
cannot run jobs here unless you also add them to this repository.

Full detail: [actions-trigger.md](actions-trigger.md#who-may-trigger-a-run).

## Operational safeguards

- Use separate GitHub and Copilot tokens when your policy requires separation.
- Use `-UseKeyVault` for Key Vault-backed Container Apps secrets.
- Keep `deploy.outputs.json` private. It contains deployment outputs and tokens. It is gitignored with `.azure/` and `.env`.
- Keep `.squad/` in the target GitHub repo when you want Squad memory and team state to travel with code.
- The user-assigned managed identity holds `AcrPull` on the registry and `Container Apps Jobs Operator` scoped to the session job.
- Every mode except `ralph` has `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` removed before the agent starts.
- OTLP auth modes are `BrowserToken` for UI and `ApiKey` for OTLP. OTLP ports stay internal to the ACA environment.
- `squad-aca sync --sync-all` blocks obvious secret files and inline tokens before staging. Override only for known-private repos with `SQUAD_ACA_ALLOW_UNSAFE_SYNC=1`.
- Run `scripts/validate.ps1` before pushing.
