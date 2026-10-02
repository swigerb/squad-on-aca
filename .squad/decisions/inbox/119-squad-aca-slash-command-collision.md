# Issue #119: Does `/squad-aca` also trigger the gh-aw `/squad` router?

## Status: Ready for Implementation (verdict: DOES NOT COLLIDE)

## Verdict

**DOES NOT COLLIDE.** A `/squad-aca ...` comment does not activate Squad's gh-aw `/squad` router. gh-aw's `slash_command` compiles to a **whole-token prefix match with a required delimiter** (space, `\n`, `\r`, or exact-equality), not a bare substring/prefix match on the string `/squad`. `/squad-aca` fails every branch of that match because the character immediately after `/squad` is `-`, which is none of the required delimiters.

## Evidence

**Primary — the actual compiled `slash_command: name: squad` lock file**, found via GitHub code search in `github/gh-aw` (the gh-aw project's own dogfooded "Squad" router, same frontmatter shape — `slash_command: name: squad`, `events: [issues, issue_comment, pull_request_review_comment]` — as `bradygaster/squad`'s `workflows/squad.md` template, confirmed identical below):

File: [`github/gh-aw` — `.github/workflows/squad.lock.yml`](https://github.com/github/gh-aw/blob/main/.github/workflows/squad.lock.yml), line 115 (checked 2026-10-01, commit `45658d8c16ac2406553c01495f051962415c7282`):

```
if: "needs.pre_activation.outputs.activated == 'true' && ((github.event_name == 'issues' || github.event_name == 'issue_comment' || github.event_name == 'pull_request_review_comment') && (github.event_name == 'issues' && (startsWith(github.event.issue.body, '/squad ') || startsWith(github.event.issue.body, '/squad\n') || startsWith(github.event.issue.body, '/squad\r') || github.event.issue.body == '/squad') || github.event_name == 'issue_comment' && (startsWith(github.event.comment.body, '/squad ') || startsWith(github.event.comment.body, '/squad\n') || startsWith(github.event.comment.body, '/squad\r') || github.event.comment.body == '/squad') && github.event.issue.pull_request == null || github.event_name == 'pull_request_review_comment' && (startsWith(github.event.comment.body, '/squad ') || startsWith(github.event.comment.body, '/squad\n') || startsWith(github.event.comment.body, '/squad\r') || github.event.comment.body == '/squad')) || !(github.event_name == 'issues' || github.event_name == 'issue_comment' || github.event_name == 'pull_request_review_comment'))"
```

Stripped to the part that matters: the body (or issue body) must satisfy one of exactly four conditions —
`startsWith(body, '/squad ')`, `startsWith(body, '/squad\n')`, `startsWith(body, '/squad\r')`, or `body == '/squad'`.

A comment body `"/squad-aca do the thing"` satisfies **none** of these: the 7th character is `-`, not a space/`\n`/`\r`, and the body is not the literal string `/squad`. The condition is false, the gh-aw router's `activation` job does not run, and nothing downstream fires.

**Corroborating — the template that would actually be installed.** `bradygaster/squad`'s source template at [`workflows/squad.md`](https://github.com/bradygaster/squad/blob/main/workflows/squad.md) (checked 2026-10-01, blob `62683f7a924099b53831bf279a566ba77faa0ad7`) declares the identical trigger shape:

```yaml
on:
  bots: ["github-actions[bot]"]
  roles: all
  slash_command:
    name: squad
    events:
      - issues
      - issue_comment
      - pull_request_comment
```

Since gh-aw is one compiler (`gh aw compile`) and this is the same `slash_command: name: squad` declaration the `github/gh-aw` repo itself dogfoods, the generated condition shape (the four-branch `startsWith(...'/squad ')` / exact-equality guard) is what `gh aw compile` would emit for this repo too.

**Corroborating — documented semantics.** gh-aw's own command-trigger docs (<https://github.github.com/gh-aw/reference/command-triggers/>, checked 2026-10-01): *"The command must be the **first word** of the comment or body text to avoid accidental triggers."* "First word" is a delimiter-bounded match, consistent with the compiled condition above, not a bare substring/prefix test.

**Corroborating — the bug this issue references.** `bradygaster/squad#1824` was about `/squad cast` silently no-oping when the command was **not** the first thing in the body (e.g., preceded by a greeting) — fixed in Squad 0.13.1 to fail loudly instead of silently. That bug is itself evidence the matcher is strict about position/boundary, not loose about the command string.

## This repo's side (verified directly, not assumed)

`.github/workflows/squad-dispatch.yml` (line 57) matches on `vars.SQUAD_COMMAND_PREFIX || '/squad-aca'`, dispatched to `worker/lib/actions-event.js`'s `extractCommand()`. That function requires the trimmed line to equal the token exactly or start with `token + ' '` — i.e. it is equally strict, and in no direction does it use `/squad` as a prefix of its own matching. This confirms `/squad-aca` is `squad-on-aca`'s own distinct, non-overlapping token; the open question was only ever about the *other* side (gh-aw's `/squad`), which is now settled above.

## Confidence

**High, but not 100% certain without a live repo with both installed.** The compiled condition is read directly from a real `.lock.yml` produced by the actual gh-aw compiler for the exact `slash_command: name: squad` frontmatter `bradygaster/squad` ships, which is as close to authoritative as static evidence gets. What would make it certain: posting `/squad-aca test` in an issue of a repo that has *both* `squad-dispatch.yml` and an installed, compiled Squad gh-aw router, and confirming the gh-aw workflow run list shows no triggered/skipped run for that comment (only `squad-dispatch` fires). This is the live-repo test the issue itself calls out as the only fully dispositive check, and it has not been run — the evidence above is all static/code-level.

## Decision

No code change needed. `/squad-aca` and gh-aw's `/squad` do not collide because gh-aw requires a boundary character (space/newline/CR) or exact-string match immediately after the command name, and `-aca` is none of those. No rename is recommended.

## Action Items

- Documentation only — add the "Proposed docs wording" section below to `docs/actions-trigger.md` (left to the docs agent to place, per this session's file-ownership split).
- No workflow or script changes required.

## Proposed docs wording

Add this as a subsection of `docs/actions-trigger.md` (e.g., after the trigger description, near where `/squad-aca` is first mentioned):

```markdown
### Does `/squad-aca` collide with Squad's own `/squad` gh-aw router?

No. Squad 0.12+ repos may also carry a GitHub Agentic Workflows (gh-aw) router
that responds to `/squad`. squad-on-aca's trigger is the distinct command
`/squad-aca`, and the two do not collide.

gh-aw compiles `slash_command: name: squad` into a condition that requires a
delimiter immediately after the command name — the comment body must start
with `/squad ` (space), `/squad\n`, `/squad\r`, or equal `/squad` exactly. A
comment body of `/squad-aca ...` satisfies none of those: the character right
after `/squad` is `-`, not a delimiter. Verified against the compiled
`squad.lock.yml` gh-aw itself ships (<https://github.com/github/gh-aw/blob/main/.github/workflows/squad.lock.yml>),
which uses the same `slash_command: name: squad` frontmatter as
`bradygaster/squad`'s router template.

If a future Squad release changes the gh-aw router's matching semantics (for
example to a looser prefix match), this note should be re-verified against
that release's compiled lock file rather than assumed to still hold.
```

## Related

- Issue: [#119 — Verify: does /squad-aca also trigger the gh-aw /squad router?](https://github.com/swigerb/squad-on-aca/issues/119)
- Upstream bug this references: [bradygaster/squad#1824](https://github.com/bradygaster/squad/issues/1824) — `/squad cast` silently no-ops unless first in body; fixed in 0.13.1 to fail loudly
- Source of the compiled condition: [github/gh-aw `.github/workflows/squad.lock.yml`](https://github.com/github/gh-aw/blob/main/.github/workflows/squad.lock.yml)
- Source of the installed template: [bradygaster/squad `workflows/squad.md`](https://github.com/bradygaster/squad/blob/main/workflows/squad.md)
- This repo's matching side: `.github/workflows/squad-dispatch.yml` line 57, `worker/lib/actions-event.js` `extractCommand()`
