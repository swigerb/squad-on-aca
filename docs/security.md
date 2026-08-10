# Security

Squad on ACA runs an AI coding agent against your repository, in your Azure
subscription, with a credential that can push branches and open pull requests.
Treat the ability to start a run as the thing worth controlling.

For the full posture and how each control is verified, see the
[security report](security-report.md).

## Who can start a run

Everything is gated on access to **this repository**.

| Route | Who |
|---|---|
| Apply the `squad-aca` label to an issue | Collaborators with **Triage** or above |
| Comment `/squad-aca <instruction>` or `@squad-on-aca-control-plane <instruction>` | **Owner, organisation member, or collaborator** |
| Run the workflow manually | Collaborators with **Write** or above |
| Ralph's poll | Only issues that already carry the label |

Full detail: [actions-trigger.md](actions-trigger.md#who-may-trigger-a-run).

### Adding someone

**Settings → Collaborators and teams → Add people.** That is the whole
mechanism. Any role works, including Read. Removing them revokes it the same
minute.

| Role | Comment the command | Apply the label | Push |
|---|---|---|---|
| Read | yes | no | no |
| Triage | yes | yes | no |
| Write | yes | yes | yes |

### `CONTRIBUTOR` is not a permission

GitHub reports `CONTRIBUTOR` for anyone who has ever had a commit merged here.
It is not access, and it is not accepted. The thing you grant is a
**collaborator**, which GitHub reports as `COLLABORATOR`.

### Squad Hub grants nothing here

Squad Hub's **Start a new ACA job…** action writes a GitHub URL and opens it.
The request is created by that person's own GitHub account, and this repository
decides whether it runs. Someone added to Squad Hub cannot run jobs here unless
you also add them to this repository.

## Azure access

The user-assigned managed identity holds:

```text
AcrPull on the registry
Container Apps Jobs Operator on the session job (resource-scoped)
```

That is the two calls Ralph makes, against the one job it makes them against.
`validate.ps1` fails the build if a deploy widens it.

GitHub Actions reaches Azure through **OIDC federation**. No Azure credential is
stored in the repository.

**Sessions do not hold the Azure identity.** Every mode except `ralph` has
`IDENTITY_ENDPOINT` and `IDENTITY_HEADER` removed from its environment, before
any child process is started.

## Tool policy

A supervised session drops `--allow-all-tools` and keeps the deny list. A tool
on the deny list raises no approval at all — it is refused rather than offered.
See [squad-hub.md](squad-hub.md).

## Secrets

- Job credentials are Container Apps secrets, referenced rather than inlined.
- `deploy.outputs.json` is git-ignored. Keep it private.
- Use `-UseKeyVault` for Key Vault-backed secrets.
- `squad-aca sync --sync-all` blocks obvious secret files and inline tokens
  before staging.

## Reporting a vulnerability

Please report privately:
<https://github.com/swigerb/squad-on-aca/security/advisories/new>.

Do not open a public issue for a suspected vulnerability.
