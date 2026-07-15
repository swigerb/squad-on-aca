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

The .NET/Aspire AppHost is opt-in and not part of the default ACA flow, so
"rolling it back" means reverting local scaffold changes — no Azure teardown is
required.

- Discard uncommitted scaffold edits:
  ```powershell
  git checkout -- aspire/
  ```
- Revert a merged scaffold change by commit:
  ```powershell
  git revert <commit-sha>
  ```
- Remove local build output if a bad restore left artifacts behind:
  ```powershell
  Remove-Item -Recurse -Force aspire/Squad.Aca.AppHost/bin, aspire/Squad.Aca.AppHost/obj
  ```
- Re-validate the scaffold structure and (optionally) rebuild:
  ```powershell
  .\scripts\validate.ps1 -RunDotnet
  ```

The default ACA deployment keeps working regardless of the AppHost state.

## 2. ACA worker image / session job

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

## 3. Aspire token / secrets

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

## 4. Ralph / watch

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
- If Ralph dispatched work from a mislabeled issue, remove the `squad:dispatched`
  label and stop the started session:
  ```powershell
  squad-aca stop <session-or-execution>
  ```
- Confirm nothing is still dispatching:
  ```powershell
  squad-aca ralph status
  squad-aca sessions --limit 20
  ```

## 5. Full resource-group destroy / redeploy

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
