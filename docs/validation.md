# Validation guide

Use this guide before pushing and after deployment changes. Static checks run offline. Live checks require an ACA deployment.

## Quick start

```powershell
# Static validation: PowerShell parse, worker bash -n, secret scan, .NET projects.
# `dotnet build` and `dotnet test` on aspire/Squad.Aca.sln run automatically
# whenever a dotnet SDK is on PATH; without one they report a counted SKIP.
.\scripts\validate.ps1

# Strict .NET gate: a missing dotnet SDK becomes a FAILURE instead of a SKIP.
.\scripts\validate.ps1 -RunDotnet
```

`validate.ps1` exits non-zero on any failure.

## What `scripts/validate.ps1` checks

| Check | What it does |
| --- | --- |
| PowerShell parse | Parses every `scripts/*.ps1`, including `scripts/lib/`. |
| Worker `bash -n` | Runs `bash -n` on `worker/entrypoint.sh`, `worker/lib/squad-capability-preflight.sh`, and `worker/lib/ralph-dispatch.sh`. |
| Secret scan | Scans tracked `docs/`, `scripts/`, `worker/`, and `aspire/` for token patterns and credential filenames. |
| Session-managed env parity | Compares session-managed env key lists in `scripts/lib/session-env.ps1` and `worker/lib/ralph-dispatch.sh`. |
| Sync guard enumeration | Verifies `Test-SyncSafety` scans repository-rooted paths before `--sync-all`. |
| Logs fallback + exit code | Exercises `scripts/lib/aca-logs.ps1` against fake `az` paths and Log Analytics fallback. |
| .NET agent libraries | Verifies `aspire/` structure and runs `dotnet build` / `dotnet test` when an SDK is present. |
| Execution provider contract | Exercises `scripts/lib/squad-aca-provider.ps1` against the fake provider. |
| ACA Job adapter | Drives `scripts/lib/providers/squad-aca-job-provider.ps1` against stubbed `az`. |
| ACA Sandboxes provider | Drives `scripts/lib/providers/squad-sandbox-provider.ps1` against stubbed `aca` and shell probes. |
| Emitted-command shell portability | Screens sandbox-provider shell strings with `scripts/lib/squad-shell-portability.ps1`. |
| Sandbox controls | Checks credential delivery, egress policy generation, redaction, quota handling, reaper behavior, and revocation paths. |
| CLI behavior regression | Drives `scripts/squad-aca.ps1` with stub `az`/`gh` binaries and checks exit codes, stdout, and calls. |
| CLI golden gate wiring | Verifies capture cases and committed goldens under `scripts/tests/golden/cli/`. |
| Worker capability tests | Run separately with `bash worker/tests/run-tests.sh`; CI runs them on Linux. |
| Egress honesty | Confirms ACA Jobs report egress as advisory and do not echo manifest host text. |

The capability manifest contract is documented in [capability-manifest.md](capability-manifest.md).

## Skip semantics

When a dependency is unavailable, `validate.ps1` reports `[SKIP]` and counts it separately. A skip is not a pass.

```text
  Passed: 149
  Failed: 0
  Skipped: 1

Skipped (NOT passes -- the dependency was missing):
  - Worker-launch detachment is UNVERIFIED: wsl.exe is not on PATH. ...
```

CI runs on hosts with required dependencies. Treat skips in CI as failures to investigate.

## Shell portability of emitted commands

`aca sandbox exec -c '<command>'` runs under `/bin/sh`, which is `dash` on the class image. Every shell string emitted by the sandbox provider is inventoried by `scripts/lib/squad-shell-portability.ps1`.

| Id | Generator | What it is |
| --- | --- | --- |
| `launch` | `New-SandboxLaunchCommand` | Creates the state dir, sources and deletes staged credentials, detaches the worker. |
| `launch-inner` | inner `bash -c` payload | Detached wrapper. |
| `cancel` | `New-SandboxCancelCommand` | Process-group stop and verdict. |
| `poll` | `New-SandboxPollCommand` | Reads phase, exit code, and completion marker. |
| `credential-vault` | `New-SandboxCredentialVaultCommand` | Creates the `0700` directory for credential upload. |
| `logs` | `New-SandboxLogsCommand` | Tails `session.log`. |
| `credential-file` | `New-SandboxCredentialFileContent` | Credential file sourced by launch. |

Validation applies three gates:

1. Static screen in `validate.ps1` for bash-only syntax and non-portable idioms.
2. Anti-drift reflection so every `New-Sandbox*Command` generator is in the inventory.
3. Real-shell syntax checks through `verify-launch-detachment.ps1` with `dash -n` and `bash -n` on Linux/WSL.

Run the real-shell probe when WSL is available:

```powershell
pwsh -NoProfile -File .\scripts\tests\verify-launch-detachment.ps1
```

## Credential handling under a one-hour token

The worker uses a git credential helper that re-reads a `0600` token file on every git operation.

| Suite | What it exercises |
|---|---|
| `worker/tests/test_credentials.sh` | Helper and token file against a local smart-HTTP remote. |
| `worker/tests/test_token_preflight.sh` | Lifetime versus estimated run duration and live credential probe. |
| `worker/tests/test_push.sh` | Exit-code propagation and retry-after-refresh path. |
| `worker/tests/test_credential_withholding.sh` | Partial credential withholding for untrusted `prompt`/`new-project` entrypoints (issue #84): no push credential or working helper while the agent runs, restore before publish, heartbeat never straddles the withhold/restore boundary, and a restore with no withheld token is fatal. Also covers the shared-`COPILOT_GITHUB_TOKEN` follow-up (see below): the token is withheld only when it equals the git push token, restored symmetrically and fatally, an explicit-distinct value is preserved, a full-environment value-scan finds no exported variable equal to the withheld push token, and `squad_copilot_shared_token_gate` fails closed before the agent starts unless `SQUAD_ALLOW_SHARED_COPILOT_TOKEN=true`. |

Run the worker suite on Linux:

```bash
bash worker/tests/run-tests.sh
```

## Source × mode policy matrix and trust axis (issue #84)

| Suite | What it exercises |
|---|---|
| `worker/tests/test_agent_policy.sh` | The `POLICY_MATRIX` built by `buildPolicyMatrix()` agrees, cell by cell, with a freshly resolved policy for every `KNOWN_SOURCES` x `KNOWN_MODES` combination; the trust axis (only `local-cli` trusted) is orthogonal to the attended/autonomous tier and narrows untrusted sources without touching `local-cli`'s effective policy; `UNTRUSTED_INPUT_DENY_TOOLS` never denies bare `git`/`gh`/`npm`/`pip`; space-bearing deny patterns are deliverable on argv/hub-json paths and undeliverable on the `squad watch` path; credential-withholding profiles per source/mode; the `copilotTokenEnv`/`copilotTokenShared`/`copilotTokenSharedAllowed` credential-profile fields across the matrix (derived/explicit-equal/explicit-distinct/escape-hatch cases resolved from a live environment via `resolvePolicyFromEnv`), and a matrix-wide invariant that `withheld:true` never co-occurs with an unqualified exported shared Copilot token. |

## Closing the Copilot-token gap in partial withholding (issue #84 follow-up)

The default deployment shape sets `COPILOT_GITHUB_TOKEN` to `GH_TOKEN` when no distinct value is supplied, so the original withholding above (which only cleared `GH_TOKEN`/`GITHUB_TOKEN`) left that shared, push-capable value exported under `COPILOT_GITHUB_TOKEN` while an untrusted agent ran. This is closed by provenance recording in `worker/entrypoint.sh`, symmetric withhold/restore of `COPILOT_GITHUB_TOKEN` in `worker/lib/squad-credentials.sh`, a fail-closed `squad_copilot_shared_token_gate` ahead of `squad_credential_withhold` in the `prompt`/`new-project` entrypoint blocks (bypassable only via `SQUAD_ALLOW_SHARED_COPILOT_TOKEN=true`), and the new `agent-policy.js` credential-profile fields above. See `docs/architecture.md`'s "Closing the Copilot-token gap in partial withholding" section for the design.

Mutation-proof targets covered by `worker/tests/test_credential_withholding.sh` (each fails a named, distinct assertion if the mutation were applied — restored in tests with explicit backups, never `git checkout`):

| Target | Mutation | Assertion that fails |
|---|---|---|
| M12 | Drop the Copilot-token unset from `squad_credential_withhold()` | The full-environment value-scan finds `COPILOT_GITHUB_TOKEN` still equal to the withheld push token while the agent runs. |
| M13 | Invert the shared/distinct equality check | An explicit-distinct `COPILOT_GITHUB_TOKEN` gets withheld (it should survive), or a derived/equal one is left exported (it should not). |
| M14 | Remove the fail-closed gate | `squad_copilot_shared_token_gate` no longer exits 78 for an untrusted `prompt`/`new-project` session with a shared token and no escape hatch. |
| M15 | Skip the Copilot token restore step | Post-agent, `COPILOT_GITHUB_TOKEN` remains unset/absent instead of being restored before publish. |
| M16 | Default the escape hatch to on | `SQUAD_ALLOW_SHARED_COPILOT_TOKEN` unset/empty/`false` no longer fails closed; the gate test asserts only the literal string `true` bypasses it. |

The pre-existing M1–M11 mutation-proof targets and their assertions in `test_credential_withholding.sh` and `test_agent_policy.sh` are unchanged by this work.

| `worker/tests/test_dispatch_registry_exhaustiveness.sh` | Scans every production dispatcher (excluding test directories) for literal `SQUAD_DISPATCH_SOURCE=`/`SQUAD_MODE=` assignments and fails if any names a source or mode absent from `agent-policy.js`'s registry — a new dispatcher cannot silently bypass the matrix. |
| `worker/tests/test_squad_hub.sh` | Trust-conditioned hub policy: untrusted sources' `hub-argv-json` carries the narrowed untrusted deny patterns; `local-cli`'s does not. |

## CLI contract validation

Run golden verification:

```powershell
pwsh -NoProfile -File .\scripts\tests\verify-cli-golden.ps1
pwsh -NoProfile -File .\scripts\tests\verify-cli-golden.ps1 -Update
```

Captures are compared against `scripts/tests/golden/cli/`.

For control-plane changes, compare against another revision:

```powershell
pwsh -NoProfile -File .\scripts\tests\compare-cli-baseline.ps1 -BaselineRef main
```

The comparison drives both revisions through the same stub environment and compares exit code, stdout, stderr, and recorded `az`/`gh`/`squad` argv.

## Worker test harness

Run the worker suite:

```bash
bash worker/tests/run-tests.sh
```

Golden routing decisions live under `worker/tests/expected/`. Regenerate a routing golden only when the decision change is intended:

```bash
node worker/lib/resolve-capability-route.js <repo-with-manifest> --pretty \
  > worker/tests/expected/<golden>.json
```

Declared dependencies use `worker/tests/lib/deps.sh`:

```bash
source "${TEST_DIR}/lib/deps.sh"
require_deps node git
```

| Suite | Declared dependencies |
| --- | --- |
| `test_capability_routing.sh` | `node` |
| `test_egress_honesty.sh` | `node` |
| `test_git_checkout.sh` | `git` |
| `test_parse_capabilities.sh` | `node` |
| `test_preflight.sh` | `node` |
| `test_ralph_dispatch.sh` | `node`, `mktemp`, `date` |
| `test_run_tests.sh` | `env`, `find` |
| `test_agent_policy.sh` | `node` |
| `test_dispatch_registry_exhaustiveness.sh` | `node`, `grep` |
| `test_credential_withholding.sh` | `node`, `git`, `openssl` |

A missing dependency exits `77` and is counted as a skip:

```text
SKIP: test_parse_capabilities.sh — missing node
```

Run the suite on Linux or WSL:

```powershell
wsl -d Ubuntu -e bash -c 'cd /path/to/repo && bash worker/tests/run-tests.sh'
```

Use a checkout path that contains no digits when running redaction assertions.

## PowerShell validation in CI

The `powershell-validation` job runs `scripts/validate.ps1` on `windows-latest`. The check is offline and uses pwsh 7 plus Git Bash preinstalled on the runner.

## Static checklist

- [ ] `.\scripts\validate.ps1` passes.
- [ ] Execution provider contract and CLI behavior regression sections report 0 failures.
- [ ] If the control plane changed, `.\scripts\tests\compare-cli-baseline.ps1 -BaselineRef main` exits 0.
- [ ] `bash -n worker/entrypoint.sh` passes.
- [ ] `node --check worker/lib/parse-capabilities.js` passes.
- [ ] `node --check worker/lib/resolve-capability-route.js` passes.
- [ ] `config/sandbox-classes.json` parses as JSON.
- [ ] `bash worker/tests/run-tests.sh` passes on Linux/WSL with 0 failed and 0 skipped.
- [ ] Secret scans are clean.
- [ ] `.\scripts\validate.ps1 -RunDotnet` passes when .NET changes are included.

## Live deployment checklist

- [ ] `squad-aca doctor` validates local repo, GitHub, Azure, ACA, and Aspire config.
- [ ] `squad-aca telemetry smoke` emits known-good logs/traces/metrics visible in Aspire.
- [ ] `scripts/start-session.ps1 -Mode smoke -RunCopilotSmoke` starts and exits cleanly.
- [ ] `caj-squad-aca-session` template env is identical before and after dispatch.
- [ ] A session that omits `SQUAD_PROMPT` does not inherit a previous prompt.
- [ ] Re-running `scripts/deploy.ps1` succeeds and updates the existing Aspire app.
- [ ] A `prompt` session opens a PR on `squad/<session>`.
- [ ] Ralph dispatch labels an actionable issue with `squad-aca:dispatched` after a confirmed start.

## Credential and access validation

### OTLP authentication

```powershell
Select-String -Path scripts\deploy.ps1 -Pattern 'AUTHMODE','BrowserToken','ApiKey','Unsecured'
```

Live check:

```powershell
az containerapp show -n ca-squad-aca-aspire -g <rg> `
  --query "properties.template.containers[0].env[?starts_with(name,'DASHBOARD__')]"
```

Expected modes are `DASHBOARD__FRONTEND__AUTHMODE=BrowserToken` and `DASHBOARD__OTLP__AUTHMODE=ApiKey`.

### OTLP ports

OTLP ports `18889` and `18890` are internal-only. UI port `18888` is external.

```powershell
az containerapp show -n ca-squad-aca-aspire -g <rg> `
  --query "properties.configuration.ingress.additionalPortMappings"
```

### RBAC / identity scope

The user-assigned managed identity holds `AcrPull` on the registry and `Container Apps Jobs Operator` scoped to the session job. `deploy.ps1` reconciles resource-scoped assignments on each run.

### Secret scans

```powershell
.\scripts\validate.ps1
git grep -nIE "gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|-----BEGIN [A-Z ]*PRIVATE KEY-----"
```

Verify ignore rules:

```powershell
git check-ignore .azure deploy.outputs.json .env
```

### Token separation

GitHub API work and Copilot headless auth can use separate tokens: `GITHUB_TOKEN`/`GH_TOKEN` and `COPILOT_GITHUB_TOKEN`.

### Rotation

```powershell
squad-aca secrets rotate --github-token <token> --copilot-token <token>
```

Re-run `scripts/deploy.ps1` to rotate the OTLP API key and dashboard browser token.

### Public repo sync guard

```powershell
Set-Content .env "GITHUB_TOKEN=ghp_<redacted-example-token>"
squad-aca sync --sync-all
Remove-Item .env
```

Override only for known-private repos with `SQUAD_ACA_ALLOW_UNSAFE_SYNC=1`.

### Image pinning

Check `worker/Dockerfile` pins:

- base image `node:24-bookworm-slim`;
- Copilot CLI `@github/copilot@1.0.69-2`;
- Squad CLI `@bradygaster/squad-cli@0.11.0`.

Pin the Aspire Dashboard image to a specific tag or digest for production.

## Optional .NET/Aspire validation

```powershell
cd aspire
dotnet build .\Squad.Aca.sln
dotnet test  .\Squad.Aca.sln
```

## Rollback and recovery

If validation fails after a deploy or config change, follow [rollback.md](rollback.md).

## Known limitations

- Live telemetry and session checks require an ACA deployment and Azure credentials.
- `bash -n` requires `bash` on PATH.
- `worker/tests/run-tests.sh` needs Linux/WSL.
- `scripts/validate.ps1` is Windows-only.
- Secret scans are pattern-based.

## Workflow files must parse

`validate.ps1` parses every file under `.github/workflows/` and asserts each one has a trigger and at least one job. Every `run:` block is extracted and checked with `bash -n`.

Build multi-line strings inside a `run:` block with `printf`:

```bash
body="$(printf '%s\n\n%s\n' \
  'A heading' \
  '| a | table |')"
```

## Shipped image layout

`worker/tests/test_image_layout.sh` builds a directory shaped like the worker image and runs the dispatcher from it with no `--catalog` override.

`scripts/deploy.ps1` builds with the repository root as context and `--file worker/Dockerfile <repoRoot>` so `config/sandbox-classes.json` can be copied into the image.

Relevant image paths:

```text
/usr/local/lib/squad-on-aca/
sandbox-classes.json
squad-dispatch.js
```

## Manifest path implementation

`CAPABILITY_MANIFEST_PATH` resolution lives in `worker/lib/locate-manifest.js`. The resolver requires it as a module, and the preflight executes it as a CLI.

`worker/tests/test_manifest_path_corpus.sh` runs each corpus row through both entry points.

| Locator exit | Meaning | Preflight |
|---|---|---|
| `0` + a path on stdout | present | proceeds with that path |
| `0` + empty stdout | contract violation | `69` |
| `3` | absent | `0`, skipping |
| `4` | unsafe | `78`, invalid or unsafe |
| `64`, `70`, `1`, anything else | unclaimed | `69` |

`69` means the image is incomplete. `78` means the manifest is invalid for the session.


