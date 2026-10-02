# Issue #112 follow-up: `SQUAD_WATCH_STRICT_POLICY` default and the remaining gap

## Status: Implemented (default), opt-in tightening not yet turned on anywhere

## Summary

The `--yolo` injection issue #112 described is fixed: `squad watch` and `squad
loop` now run through `worker/squad-agent` via `--agent-cmd`, which Squad's
`buildCustomAgentCommand()` reaches instead of `buildAdditionalMcpConfigArgs()`
-- so Squad never gets to prepend `--yolo` on their behalf, with or without a
`.mcp.json` in the repo.

That fix is necessarily paired with a second, narrower decision this note
records: whether watch/loop should also close the OTHER gap issue #112's body
raised in passing -- `undeliverableViaSquad`, the multi-word deny patterns
(`shell(git push)`, `shell(gh pr)`) that `squad --copilot-flags` has always
silently dropped (it word-splits its value on whitespace before handing it to
`copilot`).

## Decision

Default (`SQUAD_WATCH_STRICT_POLICY` unset or anything other than the literal
string `true`): **PARITY**. `worker/squad-agent` execs `copilot` with
`agent-policy.js`'s `watchAgentParityArgv` (the same `squadFlags` subset that
has always survived `--copilot-flags`), not the full deny set.

This is a deliberate choice NOT to close the gap by default, even though the
wrapper's direct `exec` makes closing it technically possible now (no
whitespace-splitting happens on this path either way). Watch agents
legitimately push branches and open pull requests as part of their normal,
intended operation. Silently starting to enforce `shell(git push)` and
`shell(gh pr)` against every unattended watcher, as a side effect of a
`--yolo`-injection fix nobody asked to also change watcher behaviour, would be
a policy tightening with no changelog entry a repo owner could find before an
always-on watcher (`ca-squad-aca-watch`) started failing its own pushes.

Opt-in (`SQUAD_WATCH_STRICT_POLICY=true`): **STRICT**. `worker/squad-agent`
execs `copilot` with `watchAgentStrictArgv` (the full argv, multi-word deny
rules included), closing the `undeliverableViaSquad` gap for watch/loop
specifically. `worker/entrypoint.sh` logs which mode is in force at the start
of every watch/loop session (`watch/loop agent-cmd policy mode: parity|strict`)
so the choice is never silent either way.

## What flipping `SQUAD_WATCH_STRICT_POLICY=true` would change

- `shell(git push)` and `shell(gh pr)` become hard-refused tool calls for the
  watch/loop dispatch source, the same way they already are for `ralph` and
  `actions` (see `UNTRUSTED_INPUT_DENY_TOOLS` / `AUTONOMOUS_DENY_TOOLS` in
  `worker/lib/agent-policy.js`).
- Any existing automation that depends on a watch/loop session pushing its own
  branch or opening its own PR (today's documented behaviour for those modes)
  would need to route that step through something other than the agent's own
  shell tool -- e.g. the worker's own `commit_and_push_if_needed` /
  `squad_push_branch` path, which is unaffected by this flag; it is not an
  agent tool call at all.
- No other mode is affected. `prompt`, `new-project`, `ralph`, `actions`, and
  `shell` do not read `SQUAD_WATCH_STRICT_POLICY` and are untouched by it.

## Remaining gap if left at the default

With the default (parity) in force, a watch/loop session's agent retains the
ability to run `git push` or `gh pr` via its shell tool, same as before this
fix. That is an accepted, logged trade-off, not an oversight: it is the same
shape of trust this repository already extends to those two modes elsewhere
(they are allowed to push/open PRs as their normal job), just not yet
enforced at the tool-call layer the way `ralph`/`actions` are. Turning it on
is a one-line environment change (`SQUAD_WATCH_STRICT_POLICY=true`) whenever an
operator decides the trade-off should flip for their deployment; this file
exists so that decision is made deliberately, not discovered as a surprise
after someone else already set it.

## Related

- Same repo: [#112](https://github.com/swigerb/squad-on-aca/issues/112) --
  Squad injects --yolo into watch/loop sessions when .mcp.json exists
- Same repo: [#114](https://github.com/swigerb/squad-on-aca/issues/114) --
  bump worker pins (Squad CLI 0.13.1, squad-hub 0.5.0), which this fix was a
  precondition for
- `worker/lib/agent-policy.js`: `resolvePolicy()`'s `watchStrictPolicy` input
  and `watchAgentParityArgv` / `watchAgentStrictArgv` / `watchAgentArgv`
  fields
- `worker/squad-agent`: the `--agent-cmd` wrapper itself
- `worker/tests/test_squad_agent_wrapper.sh`: behavioural proof for both modes
