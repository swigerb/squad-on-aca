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
| Session logging | scribe | Automatic — never needs routing. Spawned with its explicit model; see Model Policy. |
| RAI review | rai | Content safety, bias checks, credential detection, ethical review |
| An executor is stuck | advisor | Two defensible designs, a failing premise, or the same fix failing twice. Guidance only -- the executor keeps the work. |

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
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks. Spawn it as `name: "scribe"` with `model: "claude-haiku-5.5"` (`agentModelOverrides.scribe`) — never a template default.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for "what port does the server run on?"
4. **When two agents could handle it**, pick the one whose domain is the primary concern.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Anticipate downstream work.** If a feature is being built, spawn the tester to write test cases from requirements simultaneously.
7. **Issue-labeled work** — when a `squad:{member}` label is applied to an issue, route to that member. The Lead handles all `squad` (base label) triage.

## Model Policy

The team runs the [advisor strategy][adv]: a cheaper model drives the work end to
end, and escalates to a frontier model only when it hits something it cannot
reasonably settle.

[adv]: https://claude.com/blog/the-advisor-strategy

| Tier | Model | Who | Why |
|------|-------|-----|-----|
| Advisor | `gpt-6.1-sol` | advisor, lead, security, rai, fact-checker | Roles that **judge** rather than execute. A bad call here costs the team a cycle or blocks a release. |
| Executor | `claude-sonnet-5.5` | engineer, reviewer, devrel, ralph | Roles that **drive**: call tools, read results, iterate. They escalate rather than guess. |
| Scribe | `claude-haiku-5.5` | scribe, docs | High volume, low ambiguity. |

`.squad/config.json` sets `defaultModel` to the **executor** model and lists every
member explicitly, because Layer 0a beats Layer 0b and an unlisted agent is easy
to misread as deliberate. A new agent added later lands on the executor tier by
default rather than silently inheriting the frontier one.

The names in the **Who** column are the exact config keys: the lowercase
`.squad/agents/<name>/` folder, which is also the casting registry key and the
spawn `name`. Display names such as `Rai`, `Scribe` or `Fact Checker` are not keys;
a lookup under one never matches and silently falls through to `defaultModel`.
`developer` is not a member; that work is `engineer`.

Every spawn — including the after-agent Scribe — passes the member's model from
`agentModelOverrides` explicitly; see Per-Agent Model Selection in
`.github/agents/squad.agent.md`, which overrides any template default. If the
configured model is unavailable or out of quota, stop and report which member and
model. Do not retry on another model and do not omit the `model` parameter.

This table supersedes the earlier model mapping (2026-10-09, issue #150). The
earlier mappings are preserved as superseded entries in `.squad/decisions.md`.
It records the instructions the coordinator reads; it is not a runtime guarantee
that a spawn used the configured model.

### Escalating to the advisor

**Do** — two defensible designs where the wrong one is expensive to unwind; a
failure suggesting the premise is wrong rather than the code; a security or
data-loss consequence you are unsure of; the same fix failing twice.

**Don't** — you know what to do and it is merely tedious; a lookup would answer
it; to have work checked, which is the reviewer's job and happens after; or out
of caution, because an escalation you did not need teaches the team that
escalation is free.

**One honest limitation.** Anthropic's advisor tool performs the handoff inside a
single API request. Squad cannot: an agent needing another agent must end its turn
and let the coordinator bring one in. So each escalation costs a round trip, which
is precisely why the rule above matters.

Implementation code still routes to `engineer` — not because of the model, but
because it owns the implementation.

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
| stuck executor | advisor | — |
