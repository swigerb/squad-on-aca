# Rollback and recovery

This guide covers how to undo or recover each moving part of Squad on ACA when a
deploy, config change, or session goes wrong. Steps are ordered from least to
most disruptive: prefer the narrowest rollback that fixes the problem, and only
fall back to a full resource-group destroy/redeploy as a last resort.

All commands are public-repo-safe. Replace placeholders such as `<rg>`,
`<github-owner>/<repo>`, and `<azure-subscription-id>` with your own values;
never commit real subscription IDs, tokens, or private URLs.

## Before you roll back

- Capture the current state so you can compare after recovery:
  ```powershell
  .\scripts\show-status.ps1
  squad-aca sessions --limit 20
  ```
- Note the last-known-good Git commit and worker image tag. Rollback usually
  means redeploying a previous commit or re-pinning a previous image.
- Keep `deploy.outputs.json` handy (it is gitignored) — it holds resource names
  and the Aspire browser token you will need for verification.

## 1. Optional .NET/Aspire path

The .NET/Aspire path — the AppHost, the `Squad.Aca.Agents` contract, and the
`Squad.Aca.Agents.MAF` adapter — is opt-in and not part of the default ACA flow,
so "rolling it back" means reverting local changes under `aspire/`. No Azure
teardown is required, and nothing under `aspire/` runs inside a session.

- Discard uncommitted edits:
  ```powershell
  git checkout -- aspire/
  ```
- Revert a merged change by commit:
  ```powershell
  git revert <commit-sha>
  ```
- Remove local build output if a bad restore left artifacts behind:
  ```powershell
  Remove-Item -Recurse -Force aspire/Squad.Aca.AppHost/bin, aspire/Squad.Aca.AppHost/obj
  ```
- Re-validate the structure, build, and offline tests:
  ```powershell
  .\scripts\validate.ps1 -RunDotnet
  ```

The default ACA deployment keeps working regardless of the AppHost state.

## 2. ACA Sandboxes (feature-flagged, preview)

Use this when a sandbox-routed session misbehaves, when a credential is
suspected exposed, or when you simply want every dispatch back on ACA Jobs.
**ACA Jobs are the unconditional default and the rollback path**; this section
is a documented, tested procedure, not a hope.

### The two independent fail-closed interlocks

Both must be open for a dispatch to reach a sandbox. Either one alone returns
every dispatch to ACA Jobs, so a rollback that touches only one is still safe:

1. **The feature flag.** `SQUAD_ACA_ENABLE_SANDBOX` is unset or falsy by
   default. With it off, `New-SessionExecutionProvider` returns the ACA Jobs
   adapter *before* it reads the class catalog, resolves a route, or looks for
   the `aca` binary.
2. **The catalog's `provisional` marker.** `config/sandbox-classes.json` ships
   with `"provisional": true`, which makes the sandbox route fail closed
   (`reason: catalog-provisional`) **even with the flag on**. Only an
   administrator setting `"provisional": false` — after reviewing each class's
   image, egress template and `limits` — opens it.

`scripts/validate.ps1` asserts both interlocks, and
`scripts/tests/verify-cli-golden.ps1` plus
`scripts/tests/compare-cli-baseline.ps1 -BaselineRef main` assert that with the
flag off the control plane behaves byte-for-byte as it does with no sandbox code
present.

### Immediate rollback to ACA Jobs

```powershell
Remove-Item Env:SQUAD_ACA_ENABLE_SANDBOX      # or, as an explicit kill switch:
$env:SQUAD_ACA_ENABLE_SANDBOX = "0"
```

`0`, `false`, `no` and `off` are an explicit kill switch: they win even over a
deployment config that opted in. The flag is an environment variable, not a
config key, so rolling back needs no file edit and nothing that syncs config can
turn it back on.

To roll back for **everyone**, not just your shell, set the catalog back to
provisional — this is the interlock that survives someone else's environment:

```powershell
# config/sandbox-classes.json
#   "provisional": true
.\scripts\validate.ps1
```

### Then clean up what is already running

Turning the flag off does **not** tear down sandboxes that are already running,
and it does **not** revoke credentials.

```powershell
aca sandbox list -o json                            # squad-<session id> is ours
aca sandbox delete -l name=squad-<session> --yes
aca sandboxgroup credential delete --id <id> --yes  # credentials live on the GROUP
```

`squad-aca stop <session>` does both automatically for a session it still knows
about, and reports loudly if a credential could not be revoked. For anything it
could not reach, use the reaper and the credential delete above — see
[runbook.md](runbook.md) (*Concurrency, cost and orphans*).

### Verify the rollback

- [ ] `squad-aca run "<prompt>"` dispatches to an ACA Job
      (`squad-aca sessions` shows a job execution, not a sandbox).
- [ ] `aca sandbox list -o json` contains no `squad-*` entries.
- [ ] `aca sandboxgroup credential list` contains nothing belonging to a
      finished session. **Do not capture this output** — it returns values.
- [ ] `.\scripts\validate.ps1`, `verify-cli-golden.ps1` and
      `compare-cli-baseline.ps1 -BaselineRef main` all pass.

For credential exposure, identity, TLS-interception and orphan **incidents** —
as opposed to a routine rollback — follow the incident runbook in
[runbook.md](runbook.md).

## 3. ACA worker image / session job

Use this when a new worker image regresses sessions, Ralph, or the watcher.

- Roll the session/Ralph/watch jobs back to a previous image tag by redeploying
  with the last-known-good `worker/Dockerfile` pins:
  ```powershell
  git checkout <last-good-commit> -- worker/
  .\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
  ```
- Stop in-flight executions that are failing:
  ```powershell
  squad-aca stop <session-or-execution>
  ```
- Confirm the jobs are back on the expected image:
  ```powershell
  az containerapp job show -n caj-squad-aca-session -g <rg> `
    --query "properties.template.containers[0].image"
  ```
- If a specific execution is stuck, it has no persistent replica between runs, so
  stopping it and re-dispatching a fresh session is the recovery path.
- **Watcher image pull fails with `UNAUTHORIZED` after an ACR change:** an existing
  `ca-<prefix>-watch` created against an older ACR keeps stale registry settings.
  Re-running `scripts/deploy.ps1` now self-heals this by first pruning any stale
  registry entries (`az containerapp registry list`/`remove` for every server that
  differs from the current `<loginServer>`), then calling
  `az containerapp registry set --server <loginServer> --identity <identityId>`
  before the image update. The prune step keeps `az containerapp show` from listing
  two registries; a failed removal only logs a warning and does not fail the deploy
  as long as the current registry set and image update succeed. To repair manually
  without a full redeploy:
  ```powershell
  az containerapp registry set -n ca-squad-aca-watch -g <rg> `
    --server <acr-name>.azurecr.io --identity <user-assigned-identity-resource-id>
  ```
  Session/Ralph jobs self-heal on redeploy because a changed login server changes
  the image string, forcing a delete + recreate with the current registry settings.

## 4. Aspire token / secrets

Use this after a suspected token leak, a bad rotation, or a lost browser token.

- Regenerate the OTLP API key and dashboard browser token by re-running deploy;
  both are regenerated (`New-HexToken`) and re-applied:
  ```powershell
  .\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
  ```
- Rotate GitHub/Copilot tokens:
  ```powershell
  squad-aca secrets rotate --github-token <token> --copilot-token <token>
  ```
- Verify the old values no longer authenticate and that auth modes are intact
  (`BrowserToken` for UI, `ApiKey` for OTLP, never `Unsecured`):
  ```powershell
  az containerapp show -n ca-squad-aca-aspire -g <rg> `
    --query "properties.template.containers[0].env[?starts_with(name,'DASHBOARD__')]"
  ```
- Pick up the new browser token from the regenerated `deploy.outputs.json`. Never
  paste tokens into tracked files or share the dashboard URL publicly.

## 5. Ralph / watch

Use this to stop unattended dispatch without touching the rest of the deployment.

- Pause Ralph (stops scheduled polling; the job definition stays in place):
  ```powershell
  squad-aca ralph pause
  # resume when recovered:
  squad-aca ralph resume
  ```
- Stop the long-running watcher (scales it to zero):
  ```powershell
  squad-aca watch stop
  # or via the script:
  .\scripts\start-watch.ps1 -Repository "<github-owner>/<repo>" -Stop
  ```
- If Ralph dispatched work from a mislabeled issue, remove the `squad-aca:dispatched`
  label and stop the started session:
  ```powershell
  squad-aca stop <session-or-execution>
  ```
- Confirm nothing is still dispatching:
  ```powershell
  squad-aca ralph status
  squad-aca sessions --limit 20
  ```

## 6. Full resource-group destroy / redeploy

Last resort when the environment is unrecoverable or you want a clean rebuild.

- Tear down everything Squad created:
  ```powershell
  squad-aca destroy --yes
  ```
  This removes the ACA environment, jobs, dashboard, identity, ACR, and Log
  Analytics that the deploy created. It is destructive and irreversible.
- Rebuild from scratch:
  ```powershell
  .\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
  ```
  Add `-UseKeyVault -KeyVaultName <kv-name>` for Key Vault-backed secrets.
- Re-validate before resuming work:
  ```powershell
  .\scripts\validate.ps1
  squad-aca doctor
  ```
- A fresh deploy regenerates all tokens, so distribute the new browser token and
  rotate any downstream references.

## Post-rollback verification

After any rollback, confirm the system is healthy:

- [ ] `.\scripts\validate.ps1` passes.
- [ ] `squad-aca doctor` reports repo, GitHub, Azure, ACA, and Aspire config OK.
- [ ] A smoke session starts and exits cleanly
      (`.\scripts\start-session.ps1 -Mode smoke -RunCopilotSmoke`).
- [ ] OTLP auth modes are intact (`BrowserToken` UI, `ApiKey` OTLP, never
      `Unsecured`) and OTLP ports stay internal-only.
- [ ] No secrets were introduced (`.\scripts\validate.ps1` secret scan is clean).
