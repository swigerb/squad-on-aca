# Squad on ACA security report

**Reviewed:** 2 October 2026 for the Squad 0.13.1 alignment branch.  
**Scope:** GitHub dispatch, worker container, watch/loop Copilot invocation, `.squad/` governance protection, Azure identity handling, and the optional Squad Hub link.  
**Method:** source review against `worker/`, `scripts/`, and the security review inbox; validation is `scripts/validate.ps1`.

This report describes the controls that are currently implemented. It does not claim controls the code does not enforce.

---

## Current posture

| Area | Current behavior |
| --- | --- |
| Squad version | Worker installs `@bradygaster/squad-cli@0.13.1`. |
| Copilot version | Worker installs `@github/copilot@1.0.69-2`; it was not bumped with Squad. |
| Squad Hub | Docker build arg defaults to `SQUAD_HUB_SPEC=squad-hub@0.5.0`; `none` omits it. |
| watch/loop Copilot launch | `squad watch` and `squad loop` use `--agent-cmd /usr/local/lib/squad-on-aca/squad-agent`, not Squad's default Copilot command builder. |
| Blanket permission flags | The worker does not pass `--yolo`, `--allow-all`, `--allow-all-paths`, or `--allow-all-urls`; policy resolution and the wrapper fail closed on those flags. |
| Health gate | Modes that run an agent parse `squad health --json` before hardening and before the agent starts. Parsed `status: "fail"` exits `78` in the worker and logs failing check ids. |
| External state | `stateLocation: "external"` and live `teamRoot` values other than `"."` are refused because ACA can only harden and commit the cloned repo's `.squad/`. |
| Governance state | Baseline authority is in entrypoint memory plus a root-owned sealed store under `/run`; agent-writable disk copies are tripwires only. |

---

## Start authorization

Every start route is gated on repository access.

| Route | Who | Enforced by |
| --- | --- | --- |
| Apply the `squad-aca` label | Collaborators with Triage or above | GitHub |
| Comment `/squad-aca …` or mention the control-plane agent | Owner, organisation member, or collaborator | `worker/lib/actions-event.js` |
| Run the workflow manually | Collaborators with Write or above | GitHub |
| Ralph poll | Only issues already carrying the watched label | Whoever applied the label |

`CONTRIBUTOR` is not accepted because it is commit history, not current permission.

Squad Hub does not grant repository access. A hub action opens a GitHub request by the user's own GitHub identity; the repository gate still decides.

---

## Azure identity

The managed identity is scoped to `AcrPull` on the registry and `Container Apps Jobs Operator` on the one session job. `deploy.ps1` reconciles that role assignment and removes the older resource-group `Contributor` grant if found. GitHub Actions uses OIDC federation rather than stored Azure credentials.

Every mode except `ralph` removes the Container Apps identity environment (`IDENTITY_ENDPOINT`, `IDENTITY_HEADER`, MSI/IMDS variables, and `AZURE_CLIENT_ID`) before any child process starts. `ralph` keeps the identity because it is the mode that starts ACA jobs.

The process-isolation probe was **observed live in ACA** with `same-uid-environ-readable=yes`, so the PC-2 reversal trigger has fired and PC-2 was implemented. The image now has two unprivileged users: `squad` for agent-running modes and `squad-identity` for `ralph`. The live PC-2 evidence recorded the split as `uid=1001 user=squad` for an agent-running mode and `uid=1002 user=squad-identity` for `ralph`. That preserves a UID boundary for the only mode that keeps the Azure identity.

---

## Copilot policy and watch/loop wrapper

`worker/lib/agent-policy.js` is the policy source of truth. It resolves:

- an attended/autonomous tier;
- a trusted/untrusted input axis;
- Copilot argv;
- the watch/loop parity argv and strict argv;
- governance path classes.

Unknown or absent source/mode values fail closed to autonomous and untrusted.

For `watch` and `loop`, upstream Squad would otherwise build the Copilot command and inject `--yolo` when `.mcp.json` exists. The worker bypasses that path with `--agent-cmd /usr/local/lib/squad-on-aca/squad-agent`.

The wrapper:

1. Requires `SQUAD_AGENT_POLICY_ARGV_JSON` to be a JSON array of non-empty strings with no embedded newlines.
2. Rejects permission-widening flags in the resolved policy argv and in trailing argv from Squad.
3. Hashes `.mcp.json` once, compares it with `SQUAD_POLICY_MCP_CONFIG_SHA256`, the state-dir tripwire, and the root-sealed copy when present.
4. Adds `--additional-mcp-config @<repo>/.mcp.json` only after the digest check passes.
5. `exec`s `copilot` so no wrapper process remains.

### PARITY default

`SQUAD_WATCH_STRICT_POLICY` defaults to false. In that **PARITY** mode the wrapper uses `watchAgentParityArgv`, the same effective deny subset the previous `squad --copilot-flags` route could deliver. Single-word deny rules such as `shell(sudo)`, `shell(az)`, `shell(curl)`, and `shell(wget)` are enforced.

Multi-word deny rules are **announced as not enforced** on this path. That includes common deny rules such as `shell(git config)`, `shell(gh auth)`, `shell(gh secret)`, and `shell(gh variable)`, autonomous rules such as `shell(gh api)`, `shell(gh repo delete)`, and `shell(gh release delete)`, and untrusted-input rules such as `shell(git push)` and `shell(gh pr)`.

Set `SQUAD_WATCH_STRICT_POLICY=true` to use `watchAgentStrictArgv`, the full policy argv.

---

## Squad health gate

For `prompt`, `new-project`, `loop`, `watch`, and `triage`, `worker/entrypoint.sh` runs `squad health --json` after clone/init/SubSquad activation and before policy hardening.

The accepted schema is:

```json
{
  "schema": "squad-health/v1",
  "status": "pass",
  "checks": [
    { "id": "team", "status": "pass", "message": "..." }
  ]
}
```

The overall status is `pass` or `fail`; check status is `pass`, `fail`, or `skip`. The check ids in Squad 0.13.1 are `team`, `registry-charters`, `routing`, `state-backend`, and `env-vars`. There is no `warn` status.

A parsed `fail` logs the failing check ids and exits `78` in the worker. An unavailable or unreadable health report is logged as unavailable and is not reported as a pass. `squad-aca doctor` surfaces the same state in a `Squad health` row.

---

## Externalized Squad state refusal

A `.squad/config.json` is live only when it has both numeric `version` and string `teamRoot`, matching Squad 0.13.1's config resolution. Given a live config, ACA refuses:

- `stateLocation: "external"`;
- any `teamRoot` other than `"."`.

Reason: the ACA worker clones one repository, hardens that checkout's `.squad/`, and commits/pushes from that checkout. If the real team state lives elsewhere, the governance lock and audit report would protect the wrong directory.

Exit-code honesty:

| Surface | Behavior |
| --- | --- |
| Worker (`entrypoint.sh`) | Fails closed with exit `78` after clone and before `squad init`, the health gate, hardening, or agent start. |
| `squad-aca run` | PowerShell throws before compute is requested; the surfaced process exit is `1`, not `78`. |
| `squad-aca doctor` | Reports `Squad state location` as failed in the table; this local check does not use the worker's exit `78`. |

---

## Governance classes

`worker/lib/agent-policy.js` defines these path classes and emits them to `worker/lib/squad-policy.sh` and `scripts/validate.ps1`.

| Class | Paths | Enforcement |
| --- | --- | --- |
| Locked | `.squad/policies`; `.squad/agents` except existing `.squad/agents/<name>/history.md`; `.squad/identity` except `.squad/identity/now.md`; `.squad/config.json`; `.squad/routing.md`; `.squad/casting-policy.json`; `.squad/memory/config.json`; `.squad/fact-checker/policy.md`; `.squad/fact-checker/audit-trail.md`; `.squad/rai/policy.md`; `.squad/rai/audit-trail.md` | Made read-only; content changes, additions, deletions, committed changes, and missing sealed/tripwire state are violations. |
| Append-only | `.squad/agents/<name>/history.md`; `.squad/memory/audit.jsonl` | Existing files may grow only. Baseline prefix, length/high-water marks, and fingerprints are checked. |
| Reported-mutable | `.squad/casting/policy.json`; `.squad/casting/registry.json`; `.squad/casting/history.json`; `.squad/identity/now.md` | Changes are allowed but reported. The report is appended to the PR body on entrypoint-created PRs and written to the sealed report store. |

`.squad/identity/now.md` is the only mutable file under `.squad/identity/`. Everything else under `.squad/identity/` remains locked.

`.squad/memory/audit.jsonl` is append-only. Audit rotation is pinned off during hardening so a rename does not look like a legitimate fresh audit file.

---

## Governance trust boundary

The governing baseline is not trusted from an agent-writable directory.

1. Before `runuser`, the root entrypoint starts a root sealer.
2. The sealer creates a fresh root-owned `0711` directory under `/run`.
3. After hardening and before the agent starts, the unprivileged hardening process sends the governance manifest, `.mcp.json` digest, and base commit to the sealer.
4. The sealer writes root-owned `0644` files and the `sealed` marker last.
5. Verification requires both the in-memory baseline and the sealed files to match.

The sealed files are readable by design. The threat is tampering, not secrecy; the agent can recompute the values but cannot write, rename, create, or delete in the sealed directory.

The governance report is also appended through the sealer. That report is produced on the violation path, including `exit 78`, so the failure mode preserves evidence instead of only stopping the run.

---

## Graceful watch/loop shutdown

`worker/lib/squad-signal-forwarding.sh` runs `squad watch` and `squad loop` as a background child. On SIGTERM or SIGINT it forwards the signal to Squad and waits inside the trap for Squad's real exit status, avoiding the bash `wait` 128+signal synthetic status.

`deploy.ps1` sets `--termination-grace-period 300` on `ca-squad-aca-watch`.

Squad 0.13's `--sentinel-file` for watch is undocumented upstream and inverted: watch creates the file at startup and stops when it is removed, checking between polling rounds. `squad-aca watch stop` is not wired to remove it because the file lives inside the replica filesystem and would need an exec channel into the replica or a shared volume. The supported stop path scales the watcher to zero, which sends SIGTERM and uses the forwarding path.

---

## Residual risks

These are accepted limitations of the current design, not controls.

1. **No kernel append-only bit.** `chattr +a` is not used because `node:24-bookworm-slim` does not ship `chattr`, and Docker/ACA's default capability set does not include `CAP_LINUX_IMMUTABLE`. The high-water sampler runs at a 1-second default interval, so a grow-then-partial-truncate completed entirely inside one sampler tick can go unseen. End-state fingerprints still catch truncate-to-baseline and modify-then-revert cases.
2. **Seal pipe exposure through `/proc`.** A process at the agent uid can reopen the sealer pipe through `/proc` if it can find an inherited descriptor. Before the seal, that can seal first with forged content and cause hardening to abort when memory and sealed files disagree: denial of service, not a bypass. After the seal, `FILE` and `SEAL` records are ignored and only `REPORT` records are accepted, so the effect is appending noise to the governance report.
3. **PARITY mode is intentionally weaker than strict mode.** By default, watch/loop preserves the prior effective deny set and announces multi-word deny rules as not enforced. `SQUAD_WATCH_STRICT_POLICY=true` is required for the full argv.
4. **Sentinel stop is not connected to the local CLI.** The watch sentinel lives inside the replica filesystem. Without an exec channel or shared volume, `squad-aca watch stop` cannot remove it; shutdown uses SIGTERM forwarding instead.
5. **Externalized Squad state is unsupported.** The refusal is deliberate. PowerShell control-plane commands surface exit `1`; only the worker path exits `78`.
6. **Reported-mutable visibility depends on the path that publishes.** Entry-point-created PRs get the report appended to the body. Watch/loop write the report to logs and the sealed report store because Squad owns its own PR creation on that path.

---

## Verification

`scripts/validate.ps1` is the repository-level verification command. It checks policy resolution, governance classes, watch/loop wrapper packaging, health-gate behavior, external-state refusal, Dockerfile pins, and documentation-sensitive claims.

The security-review inbox findings F1-F10, S1, and N1-N5 drove the current hardening. The current code closes the direct wrapper-writable, permission-flag, missing announcement, `.mcp.json` tamper, report durability, and root-seal trust-boundary findings. The residual risks above are the remaining limitations called out by the re-review and by the current source comments.

---

## Reporting a vulnerability

Please report privately:
<https://github.com/swigerb/squad-on-aca/security/advisories/new>.

Do not open a public issue for a suspected vulnerability.

