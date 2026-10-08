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

Squad CLI 0.13.1 and 1.0.1 still inject `--yolo` with `--additional-mcp-config` when they build its own Copilot command for `watch` and `loop`. The worker therefore passes:

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

### Session-only memory audit pin

`.squad/memory/config.json` holds a session-only pin (`policy.auditMaxBytes = 0`) that keeps squad-sdk from rotating the append-only audit log. The worker never commits it. It lives in the working tree and is sealed out of git staging by `squad_policy_seal_memory_audit_config_pin`. The seal's strength depends on whether the repository already tracks the path:

- **Tracked at the base commit.** The index entry is reset to the base blob and marked `--skip-worktree`. That is an index property: `add -A`, `add -f`, `commit -a`, `reset --hard`, `stash -u`, `clean -fdx` and forced branch switches leave the pin out of every commit. Only a deliberate `update-index --no-skip-worktree` exposes it, and that is detected.
- **Not tracked.** The path is ignored through `.git/info/exclude`. That stops `add -A` but **not** a deliberate `git add -f`, a mid-session `.gitignore` negation, or `git clean -x`, which deletes the pin. Making this an index property was evaluated and rejected: intent-to-add plus `--skip-worktree` breaks `stash`, `reset --hard` and `pull --rebase`.

Both seals are backed by continuous controls:

- The in-session sampler re-checks the seal every interval and remembers any break, so undoing it before verification does not hide it.
- The sampler re-pins the file within one interval if it is deleted or replaced, so rotation stays off for the whole session. Deleting the untracked pin is reported. Deleting the tracked pin, or changing its content in either case, is a violation.
- `worker/squad-agent` refuses (`78`) to start any watch/loop/triage iteration on a broken seal or an un-pinned file.
- Worker-generated `pre-commit` and `pre-push` hooks refuse a commit whose index carries the pin, and a push whose **range** of newly-pushed commits carries it on any commit -- not only the tip -- bounded by the session's recorded base commit, or by every ancestor of the pushed ref when no base was recorded (a new/unborn branch). Installation of these hooks is skipped, and logged but otherwise silent, in three cases: `core.hooksPath` is already set to something else; the checkout is a linked git worktree (hooks are shared with the common directory); or the repository already has a foreign `pre-commit`/`pre-push` hook without this session's marker (common in any repo using husky or lefthook). In each of these cases the prevention layer for an accidental, non-`--no-verify` commit or push is simply absent for that repository -- detection (the sampler and `squad_policy_verify`) is unaffected and remains active.
- `squad_push_branch` refuses (`78`, nothing pushed) every push the container makes. This includes the shutdown checkpoint, which skips its push instead. This backstop also walks the commit range being published, the same way the hooks do, so a mid-range commit that slipped past `--no-verify` is still caught here even if it was later undone by a further commit.
- git's own "use `-f`" and "`--sparse`" hints are switched off in the clone.

**Residual risk:** an agent can still publish the pin deliberately in a mode where it holds the push credential (watch/loop/triage), by using `commit --no-verify` and `push --no-verify`, removing the hooks, or calling the API directly. That is not prevented. It is detected, and fails the session, if the break is still present at verification, lasts long enough for one sampler tick (default 1 second) or one `squad-agent` iteration check, or if any commit still reachable from HEAD at verify time ever carried the pin -- the commit-range walk above -- even one later undone by a further ordinary commit; that ordinary case is caught because the offending commit survives in local history and on the remote, and the range walk finds it there. The one window this does not close is narrower than that: a scripted stage, commit (`--no-verify`), undo and push (`--no-verify`) that finishes and is rewritten out of local history -- not merely undone by a further commit -- inside a single sub-second tick leaves nothing in the checkout to detect; only the remote branch shows it. This is the same single-uid boundary as every other governance path.

**Accepted (security review finding 5):** with the tracked seal, git refuses a `checkout`, `merge`, `rebase` or `pull` that would change `.squad/memory/config.json`, including under `-f`, because the working tree differs from the index on purpose. This is accepted because it fails safe: the operation stops and nothing is published. git still prints its generic "commit your changes or stash them" advice for that refusal. For the tracked seal neither route exposes the pin: `commit -a`, `add -A`, `add -f` and `stash -u` all leave it out of the index. Only `update-index --no-skip-worktree` exposes it, and that is detected. The two hints that name an actual bypass are switched off in the clone: the "use `-f`" hint (`advice.addIgnoredFile`) and the "`--sparse`" hint (`advice.updateSparsePath`). An upstream that legitimately changes this file during a session is not a supported workflow; the session's own policy forbids changing it.

**Closed (security review finding 6):** the publication backstop runs inside `squad_push_branch` (and the checkpoint push), not only in `commit_and_push_if_needed`, so no push the container makes can bypass it.

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

## Squad install supply chain (issue #148)

The worker image installs Squad 1.0.1 from the official upstream GitHub release, not from npm. `worker/Dockerfile` pins `SQUAD_VERSION` and `SQUAD_SHA256` (the value published in that release's `SHA256SUMS.txt` for `squad-linux-x64.tar.gz`), downloads the archive to a file, and verifies it with `sha256sum -c` before `tar` touches it, so a mismatch fails the build. Nothing is piped into a shell. The bundle is extracted to `/opt/squad-<version>` (linked as `/opt/squad` and `/usr/local/bin/squad`), chowned `root:root`, and has every write bit stripped, so neither runtime user can change it. Nothing is fetched at runtime. `.github/workflows/worker-tests.yml` installs the same bundle the same way, reading the version and checksum from the Dockerfile.

Squad 1.0's casting commit manifest, `.squad/casting/registry-history.commit.json`, is governance in the same reported-mutable class as `registry.json` and `history.json`: writable, and every change is reported. Its transient lock, transaction journal, payload directory and temp files are not governance and are added to the checkout's local-only `info/exclude`, so they never fail a session and are never published.