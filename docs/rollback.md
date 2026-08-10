# Rollback and recovery

Use the narrowest rollback that restores service. Commands use placeholders such as `<rg>`, `<github-owner>/<repo>`, and `<azure-subscription-id>`.

## Before you roll back

Capture current state:

```powershell
.\scripts\show-status.ps1
squad-aca sessions --limit 20
```

Record the last-known-good Git commit and worker image tag. Keep `deploy.outputs.json` private and available for verification.

## 1. Optional .NET/Aspire path

The .NET/Aspire path is opt-in and does not run inside a session.

Discard local edits:

```powershell
git checkout -- aspire/
```

Revert a merged change:

```powershell
git revert <commit-sha>
```

Remove local build output:

```powershell
Remove-Item -Recurse -Force aspire/Squad.Aca.AppHost/bin, aspire/Squad.Aca.AppHost/obj
```

Validate:

```powershell
.\scripts\validate.ps1 -RunDotnet
```

## 2. ACA Sandboxes (feature-flagged, preview)

ACA Jobs are the default and rollback path.

### Disable the plane

```powershell
Remove-Item Env:SQUAD_ACA_ENABLE_SANDBOX
$env:SQUAD_ACA_ENABLE_SANDBOX = "0"
```

`0`, `false`, `no`, and `off` are explicit off values.

To disable the plane for every operator, set the catalog back to provisional and validate:

```powershell
# config/sandbox-classes.json
#   "provisional": true
.\scripts\validate.ps1
```

### Clean up running sandboxes

```powershell
aca sandbox list -o json
aca sandbox delete -l name=squad-<session> --yes
aca sandboxgroup credential delete --id <id> --yes
```

`squad-aca stop <session>` performs session cleanup for sessions it can still resolve. Use the reaper in [runbook.md#concurrency-cost-and-cleanup](runbook.md#concurrency-cost-and-cleanup) for remaining `squad-*` sandboxes.

### Verify rollback

- [ ] `squad-aca run "<prompt>"` dispatches to an ACA Job.
- [ ] `squad-aca sessions` shows a job execution, not a sandbox.
- [ ] `aca sandbox list -o json` contains no `squad-*` entries.
- [ ] `aca sandboxgroup credential list` contains no finished-session credentials. Do not capture this output.
- [ ] `.\scripts\validate.ps1`, `verify-cli-golden.ps1`, and `compare-cli-baseline.ps1 -BaselineRef main` pass.

## 3. ACA worker image / session job

Redeploy the last-known-good worker:

```powershell
git checkout <last-good-commit> -- worker/
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
```

Stop failing executions:

```powershell
squad-aca stop <session-or-execution>
```

Confirm the image:

```powershell
az containerapp job show -n caj-squad-aca-session -g <rg> `
  --query "properties.template.containers[0].image"
```

Repair watcher registry settings when needed:

```powershell
az containerapp registry set -n ca-squad-aca-watch -g <rg> `
  --server <acr-name>.azurecr.io --identity <user-assigned-identity-resource-id>
```

## 4. Aspire token / secrets

Regenerate the OTLP API key and dashboard browser token:

```powershell
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
```

Rotate GitHub/Copilot tokens:

```powershell
squad-aca secrets rotate --github-token <token> --copilot-token <token>
```

Verify dashboard auth variables:

```powershell
az containerapp show -n ca-squad-aca-aspire -g <rg> `
  --query "properties.template.containers[0].env[?starts_with(name,'DASHBOARD__')]"
```

Read the new browser token from `deploy.outputs.json`.

## 5. Ralph / watch

Pause Ralph:

```powershell
squad-aca ralph pause
squad-aca ralph resume
```

Stop watcher:

```powershell
squad-aca watch stop
.\scripts\start-watch.ps1 -Repository "<github-owner>/<repo>" -Stop
```

Stop work from a mislabeled issue:

```powershell
squad-aca stop <session-or-execution>
```

Confirm dispatch is stopped:

```powershell
squad-aca ralph status
squad-aca sessions --limit 20
```

## 6. Full resource-group destroy / redeploy

Destroy all created resources:

```powershell
squad-aca destroy --yes
```

Redeploy:

```powershell
.\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"
```

Add Key Vault-backed secrets:

```powershell
.\scripts\deploy.ps1 -UseKeyVault -KeyVaultName <kv-name>
```

Validate:

```powershell
.\scripts\validate.ps1
squad-aca doctor
```

## Post-rollback verification

- [ ] `.\scripts\validate.ps1` passes.
- [ ] `squad-aca doctor` reports repo, GitHub, Azure, ACA, and Aspire config OK.
- [ ] A smoke session starts and exits cleanly: `.\scripts\start-session.ps1 -Mode smoke -RunCopilotSmoke`.
- [ ] OTLP auth modes are `BrowserToken` for UI and `ApiKey` for OTLP.
- [ ] OTLP ports stay internal-only.
- [ ] The secret scan in `.\scripts\validate.ps1` is clean.


