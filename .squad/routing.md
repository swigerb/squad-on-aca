# Work Routing

How to decide who handles what.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|----------|
| Product direction and architecture | lead | Scope, sequencing, design trade-offs, ACA architecture decisions |
| Implementation and scripts | engineer | PowerShell wrapper changes, worker entrypoint changes, Dockerfile updates, tests |
| Code review | reviewer | Review PRs, check quality, suggest improvements |
| Testing | engineer | Write tests, find edge cases, verify fixes |
| Security review | security | Secret handling, RBAC, managed identity, token flow |
| Developer experience | devrel | README, quickstarts, examples, release notes |
| Technical documentation | docs | Runbooks, architecture docs, API references |
| Scope & priorities | lead | What to build next, trade-offs, decisions |
| Session logging | Scribe | Automatic — never needs routing |
| RAI review | Rai | Content safety, bias checks, credential detection, ethical review |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, assign `squad:{member}` label | Lead |
| `squad:{name}` | Pick up issue and complete the work | Named member |

### How Issue Assignment Works

1. When a GitHub issue gets the `squad` label, the **Lead** triages it — analyzing content, assigning the right `squad:{member}` label, and commenting with triage notes.
2. When a `squad:{member}` label is applied, that member picks up the issue in their next session.
3. Members can reassign by removing their label and adding another member's label.
4. The `squad` label is the "inbox" — untriaged issues waiting for Lead review.

## Rules

0. **Development work routes through Squad.** Do not make implementation changes inline unless the user explicitly asks for local-only help. The coordinator routes development work to the team.
1. **Eager by default** — spawn all agents who could usefully start work, including anticipatory downstream work.
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for "what port does the server run on?"
4. **When two agents could handle it**, pick the one whose domain is the primary concern.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Anticipate downstream work.** If a feature is being built, spawn the tester to write test cases from requirements simultaneously.
7. **Issue-labeled work** — when a `squad:{member}` label is applied to an issue, route to that member. The Lead handles all `squad` (base label) triage.

## Model Policy

| Work | Agent | Required model |
|------|-------|----------------|
| Lead planning, sequencing, coordination | lead | `gpt-5.6-luna` |
| Code writing, tests, refactoring, scripts, Dockerfiles | engineer | `claude-opus-4.8` |

If any agent other than `engineer` needs to write implementation code, spawn or hand off that work to `engineer` so code-writing work uses Opus 4.8.

## Work Type → Agent

| Work Type | Primary | Secondary |
|-----------|---------|----------|
| lead | lead | — |
| implementation | engineer | reviewer |
| tests | engineer | reviewer |
| scripts | engineer | reviewer |
| Dockerfile | engineer | security |
| reviewer | reviewer | — |
| devrel | devrel | — |
| security | security | — |
| docs | docs | — |
