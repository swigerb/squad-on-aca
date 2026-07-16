# Validation guide

This repository is script- and infrastructure-heavy, so validation is a mix of
static checks (run anywhere) and end-to-end (E2E) checks (run against a real ACA
deployment). Use this guide as the per-sprint gate and before any push.

## Quick start

```powershell
# Static validation: PowerShell parse, worker bash -n, secret scan, .NET scaffold
.\scripts\validate.ps1

# Also build the optional .NET/Aspire scaffold
.\scripts\validate.ps1 -RunDotnet
```

`validate.ps1` exits non-zero on any failure, so it is safe to wire into CI or a
pre-push hook.

## What `scripts/validate.ps1` checks

| Check | What it does | Why |
| --- | --- | --- |
| PowerShell parse | Parses every `scripts/*.ps1` (including `scripts/lib/`) with the PowerShell language parser | Catches syntax errors without executing deploy/dispatch logic |
| Worker `bash -n` | Runs `bash -n` on `worker/entrypoint.sh`, `worker/lib/squad-capability-preflight.sh`, and `worker/lib/ralph-dispatch.sh` (CRLF-normalized) | Catches shell syntax errors in the container entrypoint, capability preflight, and Ralph dispatch library |
| Secret scan | Scans tracked `docs/`, `scripts/`, `worker/`, and `aspire/` for token patterns and credential filenames (skips `bin/`, `obj/`, `node_modules/`, and binary files) | Keeps the public repo free of secrets |
| Session-managed env parity | Compares the session-managed env key lists in `scripts/lib/session-env.ps1` and `worker/lib/ralph-dispatch.sh` | Fails on drift so both dispatch paths strip the same keys and session isolation cannot regress |
| Sync guard `-uall` | Asserts `Test-SyncSafety` (`scripts/lib/sync-safety.ps1`) enumerates with `git status --porcelain -uall`, then runs the real guard against a throwaway repo with nested untracked secrets | Proves nested untracked secrets are scanned before `--sync-all` and git-ignored files stay excluded |
| .NET scaffold | Verifies `aspire/` structure and `.csproj` XML; optional `dotnet build` | Ensures the optional integration path stays coherent |
| Worker capability tests | Not run by `validate.ps1` (needs `bash`+`node`); run `bash worker/tests/run-tests.sh` directly or via CI | Covers the capability manifest parser, preflight contract, and Ralph transactional dispatch |

The capability manifest contract itself is documented in
[capability-manifest.md](capability-manifest.md): manifest schema, built-in
tool/credential allowlists, the advisory-only handling of `services`/`egress`
(required services are rejected at validation), and the entrypoint fail-closed
behavior when the packaged preflight script is missing.

## Sprint validation checklist

Run these in order. Static checks first (fast, no Azure), then E2E.

### 1. Static (no Azure required)

- [ ] `.\scripts\validate.ps1` passes.
- [ ] `bash -n worker/entrypoint.sh` passes (also covered by validate.ps1).
- [ ] `node --check worker/lib/parse-capabilities.js` passes.
- [ ] `bash worker/tests/run-tests.sh` passes (capability parser + preflight suite).
- [ ] `git grep` finds no personal subscription IDs, tenant IDs, tokens, or user
      handles in tracked files (see [Secret scans](#secret-scans)).
- [ ] Optional: `.\scripts\validate.ps1 -RunDotnet` builds `aspire/Squad.Aca.sln`.

### 2. E2E (requires an ACA deployment)

Record real command output in [e2e-results.md](e2e-results.md) (static evidence is
already captured there; the live-Azure sections L1–L7 are filled by the
orchestrator/operator against a real deployment).

- [ ] `squad-aca doctor` — validates local repo, GitHub, Azure, ACA, and Aspire
      config.
- [ ] `squad-aca telemetry smoke` (or `SQUAD_MODE=telemetry-smoke`) — emits
      known-good logs/traces/metrics and they appear in the Aspire Dashboard,
      grouped by `squad-<session>`.
- [ ] `scripts/start-session.ps1 -Mode smoke -RunCopilotSmoke` — a session job
      execution starts, clones the repo, and exits cleanly.
- [ ] **Template non-mutation:** the `caj-squad-aca-session` template env is
      identical before and after a dispatch (dispatch uses a per-execution
      `az containerapp job start --env-vars` override, never `job update`). The
      dispatch also echoes the template's image and CPU/memory back on `job start`
      — a read of the immutable template, not a write — because ACA only applies
      the per-execution env override when a complete execution container spec is
      supplied. See [e2e-results.md](e2e-results.md) L3.
- [ ] **Per-execution isolation:** a session that omits `SQUAD_PROMPT` does not
      inherit a previous session's prompt, and still carries the durable common
      env. See [e2e-results.md](e2e-results.md) L4.
- [ ] **Idempotent deploy:** re-running `scripts/deploy.ps1` succeeds and updates
      the existing Aspire app (rotates OTLP key + browser token) instead of
      failing on create. See [e2e-results.md](e2e-results.md) L1.
- [ ] **Watcher registry idempotency:** re-running `scripts/deploy.ps1` against an
      existing `ca-<prefix>-watch` whose ACR changed (new `$loginServer`/ACR name)
      first removes stale registry entries whose server differs from `$loginServer`
      (`az containerapp registry list`/`remove`), then updates the watcher registry
      config via `az containerapp registry set`
      (`--server $loginServer --identity $identityId`) before the image update, so
      the image pull does not fail with `UNAUTHORIZED` and `az containerapp show`
      lists only the current registry. A failed stale-entry removal logs a warning
      but does not fail the deploy. Session/Ralph jobs get the
      same effect automatically: a changed login server changes the full image
      string, so deploy deletes and recreates them with the current
      `--registry-server`/`--registry-identity` (the job update path only runs when
      the login server is unchanged, so its registry config is already correct).
- [ ] A `prompt` session opens a PR on `squad/<session>`.
- [ ] Ralph dispatch: an actionable labeled issue gets the `squad-aca:dispatched`
      label and a session job execution starts, with no shared-template mutation.
      (The `squad:*` namespace is reserved by Squad member-routing workflows, so
      Ralph uses `squad-aca:dispatched` to avoid triggering member assignment.)

## Security validation

These map to the Security review items. Each has a concrete way to verify it.

### OTLP authentication

- **Expected:** Dashboard UI auth = `BrowserToken`, OTLP auth = `ApiKey`. Never
  `Unsecured`.
- **Verify (source):**
  ```powershell
  Select-String -Path scripts\deploy.ps1 -Pattern 'AUTHMODE','BrowserToken','ApiKey','Unsecured'
  ```
  Expect `DASHBOARD__FRONTEND__AUTHMODE=BrowserToken`,
  `DASHBOARD__OTLP__AUTHMODE=ApiKey`, and **no** `Unsecured`.
- **Verify (live):**
  ```powershell
  az containerapp show -n ca-squad-aca-aspire -g <rg> `
    --query "properties.template.containers[0].env[?starts_with(name,'DASHBOARD__')]"
  ```

### OTLP exposure (ports internal only)

- **Expected:** UI port `18888` is external; OTLP `18889`/`18890` are
  internal-only (`external: false`).
- **Verify (source):** in `scripts/deploy.ps1`, the `additionalPortMappings` for
  18889/18890 have `external: false`.
- **Verify (live):**
  ```powershell
  az containerapp show -n ca-squad-aca-aspire -g <rg> `
    --query "properties.configuration.ingress.additionalPortMappings"
  ```
  Both OTLP ports must show `"external": false`.

### RBAC / identity scope

- **Current state (documented risk):** the user-assigned managed identity is
  granted **Contributor** on the resource group so Ralph can start session job
  executions (`Microsoft.App/jobs/start/action`). This is broader than needed.
- **Do not broaden** identity/RBAC further.
- **Future improvement / optional hardening:** replace Contributor with a custom
  role limited to job start + read. Only adopt if it does not break deployment.
  Example custom role definition (review before applying):
  ```jsonc
  {
    "Name": "Squad ACA Job Dispatcher",
    "IsCustom": true,
    "Description": "Start and read ACA jobs for Squad dispatch",
    "Actions": [
      "Microsoft.App/jobs/read",
      "Microsoft.App/jobs/start/action",
      "Microsoft.App/jobs/executions/read"
    ],
    "AssignableScopes": ["/subscriptions/<sub-id>/resourceGroups/<rg>"]
  }
  ```
  Validate a session dispatch still succeeds after swapping the role before
  removing Contributor.

### Secret scans

- **Verify no secrets are committed:**
  ```powershell
  .\scripts\validate.ps1   # includes the docs/scripts/aspire secret scan
  git grep -nIE "gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  ```
  Both should return nothing.
- **Verify ignore rules:** `.azure/`, `.env`, and `deploy.outputs.json` are in
  `.gitignore`:
  ```powershell
  git check-ignore .azure deploy.outputs.json .env
  ```

### Token separation

- **Expected:** GitHub API work and Copilot headless auth can use separate
  tokens (`GITHUB_TOKEN`/`GH_TOKEN` vs `COPILOT_GITHUB_TOKEN`).
- **Verify:** `scripts/deploy.ps1` wires `copilot-github-token` as a distinct
  secret; `worker/entrypoint.sh` prefers `COPILOT_GITHUB_TOKEN` and only falls
  back to `GH_TOKEN` when it is unset.

### Rotation

- **Rotate GitHub/Copilot tokens:**
  ```powershell
  squad-aca secrets rotate --github-token <token> --copilot-token <token>
  ```
- **Rotate OTLP API key / dashboard browser token:** re-run `scripts/deploy.ps1`;
  both are regenerated with `New-HexToken` and re-applied. Re-running is
  **idempotent**: the Aspire app is updated in place via
  `az containerapp update --yaml` (a full create-or-update PUT that rotates the
  secret and browser token and rolls a new revision), not recreated, so rotation
  and recovery no longer fail on an existing app. Confirm old values no longer
  authenticate.

### Public repo sync guard

- **Expected:** `squad-aca sync --sync-all` refuses to stage obvious secret files
  or inline tokens before `git add -A`.
- **Verify:** create a throwaway file and confirm the guard blocks it:
  ```powershell
  Set-Content .env "GITHUB_TOKEN=ghp_<redacted-example-token>"
  squad-aca sync --sync-all   # must fail with a "secret guard" message
  Remove-Item .env
  ```
  The guard blocks at least: `.env`, `deploy.outputs.json`, `.azure`, `*.pfx`,
  `*.pem`, `id_rsa`/`id_ed25519`, `appsettings*.Development.json`, and inline
  token patterns. Intentional override: `SQUAD_ACA_ALLOW_UNSAFE_SYNC=1` (only for
  known-private repos).

### Image pinning

- **Expected:** the worker image pins tool versions rather than floating latest
  for the risky dependencies.
- **Verify:** `worker/Dockerfile` pins the base image (`node:24-bookworm-slim`),
  Copilot CLI (`@github/copilot@1.0.69-2`), and Squad CLI
  (`@bradygaster/squad-cli@0.11.0`).
- **Note:** the Aspire Dashboard image is pulled by tag (`:latest` in
  `scripts/deploy.ps1`, `:9.4` in the optional AppHost). For production, pin the
  dashboard to a specific tag/digest.

## Optional .NET/Aspire scaffold validation

```powershell
cd aspire
dotnet build .\Squad.Aca.sln          # restore + compile
```

If restore is not feasible (offline, restricted feeds, or preview packages are
unavailable), that is expected and acceptable: the scaffold is optional. The
project files and `AppHost.cs` remain valid, reviewable scaffolding, and the
static structure check in `validate.ps1` still passes. Document the restore
failure reason in your sprint notes and keep the scaffold explicit rather than
vendoring preview packages.

## Rollback and recovery

If validation fails after a deploy or config change, or a session/Ralph/watch run
misbehaves, follow [rollback.md](rollback.md). It covers per-component recovery
(optional .NET/Aspire path, ACA worker image/session job, Aspire token/secrets,
Ralph/watch) and, as a last resort, a full resource-group destroy/redeploy. Each
rollback ends with a post-rollback verification checklist that re-runs
`scripts/validate.ps1` and `squad-aca doctor`.

## Known limitations

- E2E telemetry and session checks require a live ACA deployment and Azure
  credentials; they cannot run in a pure static/offline gate.
- `bash -n` requires a `bash` on PATH (Git Bash or WSL on Windows). validate.ps1
  skips it gracefully when bash is absent.
- The secret scans are pattern-based and catch common token shapes, not every
  possible secret. They complement, not replace, a dedicated secret-scanning
  tool in CI.
