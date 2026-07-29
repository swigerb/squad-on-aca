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

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
