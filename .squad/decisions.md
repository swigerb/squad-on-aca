# Squad Decisions

## Active Decisions

### 2026-07-28: All Squad members run Claude Opus 5 only

**Decision:** Every Squad member — lead, engineer, reviewer, security, docs, devrel, scribe, ralph, Rai, fact-checker — uses `claude-opus-5`. This supersedes the 2026-07-15 split model policy (`gpt-5.6-luna` for lead, `claude-opus-4.8` for engineer).

**Why:** Owner directive for the ACA SandboxGroups PRD (#6) programme. A single high-capability model across planning, implementation, review, and security removes model-capability variance as a confounding variable when auditing why a sprint gate passed or failed.

**Implications:**

- `.squad/config.json` sets `defaultModel: claude-opus-5` **and** an explicit `agentModelOverrides` entry for every member, because Layer 0 per-agent overrides take precedence over `defaultModel`. Setting `defaultModel` alone would have left the two stale overrides in force.
- `.squad/routing.md` Model Policy table updated to match.

### 2026-07-28: Close PR #9 and rebuild SandboxGroups work on current main

**Decision:** PR #9 ("SandboxGroups Sprints 0-2") is closed rather than rebased. Its ADR, provider-contract shape, and sandbox-class catalog concept are harvested and reimplemented against current `main`.

**Why:** PR #9 branched from `2d9df19`, 21 commits behind `main`. In the interim `main` landed `cc43649 Add capability-aware worker preflight` plus sync-guard, fetched-ref checkout, and Ralph dispatch hardening. The PR therefore contains an independent parallel implementation of the same subsystem. Measured against `main`, its six shared core files are **+439 / −997 lines** — merging it would delete shipped hardening. It also drops `test_git_checkout.sh` and `test_ralph_dispatch.sh` (−34 assertions).

Critically, its `worker/tests/run-tests.sh` captures `status=$?` *inside* `if ! bash "$t"; then`, where `$?` is the negated (zero) status. A failing suite therefore sets `status=0`, breaks the loop, and prints "All worker tests passed." This was verified: `test_cli_regressions.sh` exits 1 while the runner exits 0. The PR's claim that all tests pass was produced by a harness structurally incapable of reporting failure.

**Implications:**

- These conflicts are semantic, not textual; rebase would not resolve them.
- The false-green harness bug class is fixed on `main` in Sprint 0, with a self-test that deliberately fails a suite and asserts the runner exits non-zero.
- Sprint 0 also broadens CI path filters to cover `scripts/**` and `config/**`, which PR #9 changed with no CI coverage at all.

### 2026-07-15: Route development through Squad with explicit model policy

> **Superseded 2026-07-28** — the model split below no longer applies. All members now run `claude-opus-5`. The routing half of this decision (development work goes through Squad) remains in force.

**Decision:** Development work in this repo should route through Squad. The Lead handles planning, sequencing, and coordination using `gpt-5.6-luna`. Code-writing work routes to `engineer` using `claude-opus-4.8`.

**Why:** Squad on ACA is now a public remote-runner project with enough moving parts that repo history, architecture decisions, implementation handoffs, and validation evidence should be maintained by the Squad itself.

**Implications:**

- The coordinator should avoid inline implementation work unless the user explicitly asks for local-only help.
- Implementation, tests, scripts, Dockerfiles, and refactoring route to `engineer`.
- Review work still routes to `reviewer`, and security-sensitive changes route to `security`.

### 2026-10-02: Squad v0.13.1 alignment (#112–#119)

**By:** Security, Engineer, Lead, Reviewer  
**Scope:** Eight GitHub issues across governance, Squad CLI version pins, signal handling, health gating, external-state refusal, upstream docs, and slash-command collision analysis. All implemented, tested, security-reviewed, and committed locally on `feat/squad-0.13-alignment` (local branch, never pushed).

**Decisions:**

#### #112 — `--yolo` via watch/loop

`squad watch` and `squad loop` now run with `--agent-cmd /usr/local/lib/squad-on-aca/squad-agent`. The wrapper execs `copilot -p <prompt>` plus the resolved policy argv **without** `--yolo`, failing closed (exit 78) if the policy cannot be resolved. The policy is transported through the environment as a JSON array, so the wrapper never re-resolves it differently.

**Parity decision:** watch/loop keep today's effective deny set (`squadFlags` subset). Multi-word deny rules are announced as NOT enforced on this path, so watch agents can still push and open PRs. `SQUAD_WATCH_STRICT_POLICY=true` is the opt-in that uses the full argv. Follow-up note in `.squad/decisions/inbox/112-watch-strict-policy-followup.md` makes strict the default once multi-word rules are enforceable on this path.

#### #113 — governance locks vs Squad 0.13 runtime state

Three classes defined in `worker/lib/agent-policy.js` and consumed by `worker/lib/squad-policy.sh` and `scripts/validate.ps1`:
- **locked** — `charter.md` and everything else previously locked, plus all of `.squad/identity/` except `now.md`.
- **append-only** — `.squad/memory/audit.jsonl`. Rotation made impossible mid-session via a high-water mark.
- **reported-mutable** (new) — `.squad/casting/{policy,registry,history}.json`, `.squad/identity/now.md`. Hashed at baseline; changes are allowed but listed in the governance report and PR body. Change-then-revert is still reported.

#### #114 — version pins

`worker/Dockerfile` → `@bradygaster/squad-cli@0.13.1` and `SQUAD_HUB_SPEC=squad-hub@0.5.0`. Copilot CLI stays at `1.0.69-2`.

#### #115 — signal handling

`worker/lib/squad-signal-forwarding.sh` runs the `squad watch`/`squad loop` child in the background, traps TERM/INT, forwards them, and waits so the true child exit code is recovered. Verified present on both `containerapp create` and `update` in the Azure CLI source.

#### #116 — `squad health --json` gate

Runs after bootstrap and before hardening in every mode that runs an agent. Fails closed (exit 78) on `status: "fail"`, logging the failing check ids.

#### #117 — externalized state / remote teamRoot

`stateLocation: "external"` or a non-`"."` `teamRoot` in `.squad/config.json` is refused by `squad-aca doctor`, `squad-aca run`, and by the worker before the agent starts. Exit code 78 from worker; documented as a known limitation.

#### #118 — upstream docs

Linked `scenarios/azure-container-apps`, `reference/container-image`, `features/security-hardening`, and explained how squad-on-aca differs. Documented the ID-based OIDC subject format alongside the classic form. Noted upstream `bradygaster/squad#2140`.

#### #119 — `/squad-aca` vs the gh-aw `/squad` router

**Conclusion: it does not collide.** gh-aw's `slash_command` compiles to a whole-token prefix match with a required delimiter. `/squad-aca` fails because the character immediately after `/squad` is `-`, not a delimiter.

**Test results:** `scripts/validate.ps1`: 578 passed, 0 failed. `worker/tests/run-tests.sh`: 24 suites passed, 12 failed (identical pre-existing failures).

**Security:** Three review rounds. Round 1 rejected with 10 findings (F1–F10); Round 2 rejected with 5 new findings (N1–N5) after fixes; Round 3 approved. All 10 original findings closed; residual risks 1–6 documented in `docs/security.md`.

### 2026-10-02: Memory audit pin publication seal — never commit; index seal

**By:** Lead, Engineer, Security (reviewer), Reviewer  
**Branch:** `fix/governance-pin-leak` (committed as b54b3be and pushed; no PR, no merge)  
**Context:** Issue #113's pin (`policy.auditMaxBytes = 0` in `.squad/memory/config.json`) was committed and leaked into published branches (swigerb/arcade-hall-of-fame#7).

**Decision:** Replace the committed-pin design with an index seal. The pin is never committed; instead:
- **Tracked files:** `git reset HEAD -- path` + `update-index --skip-worktree`
- **Untracked files:** anchored `.git/info/exclude` entry
- **Continuous enforcement:** background pin tick (every 1s), pre-commit/pre-push hooks, agent-wrapper gate (per iteration), pre-push assert in `commit_and_push_if_needed`, seal-integrity check at verify

The file stays LOCKED and manifest-hashed. Rotation is prevented mid-session via a high-water mark on `audit.jsonl`.

**Outcome:** All 10 security findings closed. Six advisories remain (R5, R-CI, R5-b, R6, R7, R8); all acknowledged and resolved by reviewer. `validate.ps1`: 578/0. Four test suites split from combined file to fit 120s per-suite budget.

**Residual risk (accepted):** In watch/loop/triage the agent holds the push credential and could publish deliberately with `--no-verify` or REST API. A publish-and-undo within one sampler tick leaves no local trace.

### 2026-10-02: #118 Federated Credential Subject Formats

**By:** Lead  
**Status:** Documentation-only  
**Summary:** GitHub Actions sends different OIDC subject formats (classic vs ID-based). Both credentials must be configured; this is manual setup documented in `docs/actions-trigger.md`.

### 2026-10-02: #119 `/squad-aca` Slash Command Collision

**By:** Lead  
**Status:** No collision  
**Evidence:** Verified against `github/gh-aw` compiled `.lock.yml` and `bradygaster/squad` template. gh-aw requires a boundary character after the command name; `-aca` is none of those.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
