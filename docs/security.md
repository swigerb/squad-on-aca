# Security

Squad on ACA runs an AI coding agent against your repository, in your Azure subscription, with credentials that can push branches and open pull requests. Treat the ability to start a run as the thing worth controlling.

For the full posture and verification evidence, see the [security report](security-report.md).

## Who can start a run

Everything is gated on access to **this repository**.

| Route | Who |
|---|---|
| Apply the `squad-aca` label to an issue | Collaborators with **Triage** or above |
| Comment `/squad-aca <instruction>` or `@squad-on-aca-control-plane <instruction>` | **Owner, organisation member, or collaborator** |
| Run the workflow manually | Collaborators with **Write** or above |
| Ralph's poll | Only issues that already carry the label |

Full detail: [actions-trigger.md](actions-trigger.md#who-may-trigger-a-run).

`CONTRIBUTOR` is not a permission. GitHub reports it for commit history, not current access, and it is not accepted by the comment gate.

Squad Hub grants nothing here. Its desktop/mobile action opens a GitHub request made by that person's GitHub account; this repository still decides whether the run starts.

## Azure access

The user-assigned managed identity holds only:

```text
AcrPull on the registry
Container Apps Jobs Operator on the session job (resource-scoped)
```

GitHub Actions reaches Azure through OIDC federation. No Azure credential is stored in the repository.

Every mode except `ralph` removes `IDENTITY_ENDPOINT`, `IDENTITY_HEADER`, `MSI_ENDPOINT`, `MSI_SECRET`, `IMDS_ENDPOINT`, and `AZURE_CLIENT_ID` before any background child or agent starts. `ralph` is the only mode that calls Azure.

## Agent tool policy

`worker/lib/agent-policy.js` resolves one policy before any agent starts. The default for unrecognised source or mode is fail-closed (`autonomous` and untrusted).

All sessions run Copilot without `--yolo`, `--allow-all`, `--allow-all-paths`, or `--allow-all-urls`. `--allow-all-tools` is still present because Copilot CLI requires it for non-interactive mode; deny rules are the enforcement surface and take precedence.

`SQUAD_COPILOT_FLAGS` may add non-policy extras such as model or log-level flags. The resolver and the `squad-agent` wrapper refuse permission-widening flags before `exec copilot`.

### watch/loop wrapper

Squad CLI 0.13.1 still injects `--yolo` with `--additional-mcp-config` when it builds its own Copilot command for `watch` and `loop`. The worker therefore passes:

```text
--agent-cmd /usr/local/lib/squad-on-aca/squad-agent
```

The wrapper is the last gate before `exec copilot`. It parses `SQUAD_AGENT_POLICY_ARGV_JSON`, rejects missing or malformed policy, rejects permission-widening argv, computes the harden-time `.mcp.json` digest, and adds `--additional-mcp-config @<repo>/.mcp.json` only when the current digest matches the sealed baseline. If `.mcp.json` changes during a hardened session, the wrapper exits `78` instead of loading it.

### PARITY vs strict watch/loop policy

By default, watch/loop uses **PARITY** mode: the wrapper enforces the same single-word deny subset the old `squad --copilot-flags` path could effectively deliver. Multi-word deny rules are explicitly announced as not enforced on that path. They include rules such as `shell(git config)`, `shell(gh auth)`, `shell(gh api)`, `shell(git push)`, and `shell(gh pr)`.

Set `SQUAD_WATCH_STRICT_POLICY=true` to use the full argv from `agent-policy.js`, including multi-word deny rules.

## Governance classes

Classes are defined in `worker/lib/agent-policy.js` and applied by `worker/lib/squad-policy.sh` and `scripts/validate.ps1`.

| Class | Exact paths |
| --- | --- |
| Locked | `.squad/policies`; `.squad/agents` except existing `.squad/agents/<name>/history.md`; `.squad/identity` except `.squad/identity/now.md`; `.squad/config.json`; `.squad/routing.md`; `.squad/casting-policy.json`; `.squad/memory/config.json`; `.squad/fact-checker/policy.md`; `.squad/fact-checker/audit-trail.md`; `.squad/rai/policy.md`; `.squad/rai/audit-trail.md` |
| Append-only | `.squad/agents/<name>/history.md`; `.squad/memory/audit.jsonl` |
| Reported-mutable | `.squad/casting/policy.json`; `.squad/casting/registry.json`; `.squad/casting/history.json`; `.squad/identity/now.md` |

Locked paths are made read-only and any content, add, delete, or committed change fails the session. Append-only files may only grow from the harden-time prefix. Reported-mutable files may change, but the change is listed in the governance report and appended to the PR body when the entrypoint creates the PR.

## Trust boundary

The agent runs as the unprivileged `squad` uid after `runuser`. Before that drop, the root entrypoint starts a sealer that creates a root-owned `0711` directory under `/run`. The harden-time governance baseline, `.mcp.json` digest, and base commit are written there as root-owned `0644` files. They are readable by design; the threat model is tampering, not secrecy.

The agent uid cannot write, rename, create, or delete files in that sealed store. Verification requires the in-memory baseline and the sealed copies to agree. Governance reports are also appended to the sealed store, including on exit-`78` violation paths.

Residual risks are documented in the [security report](security-report.md#residual-risks).

## Secrets

- Job credentials are Container Apps secrets, referenced rather than inlined.
- `deploy.outputs.json` is git-ignored. Keep it private.
- Use `-UseKeyVault` for Key Vault-backed secrets.
- `squad-aca sync --sync-all` blocks obvious secret files and inline tokens before staging.

## Reporting a vulnerability

Please report privately:
<https://github.com/swigerb/squad-on-aca/security/advisories/new>.

Do not open a public issue for a suspected vulnerability.
