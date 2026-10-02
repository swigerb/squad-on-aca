# Security review — #112 (`squad-agent` wrapper) and #113 (governance classes)

- **Reviewer:** security
- **Date:** 2026-10-01
- **Branch:** `feat/squad-0.13-alignment`
- **Commits:** `63e61cc` (#112), `b9bac08` (#113)
- **Scope:** read-only. No repo file was modified. Known false positives named in the request
  (`--allow-all-tools` in the resolved argv, the parity default itself, the missing `{prompt}`
  token, `auditMaxBytes: 0`) are not reported as findings.

---

## Verdicts

| Commit | Verdict |
|---|---|
| `63e61cc` — #112 `worker/squad-agent` | **REJECTED** — 1 CRITICAL, 2 HIGH, 1 MEDIUM, 1 LOW |
| `b9bac08` — #113 governance classes | **APPROVED WITH FINDINGS** — 1 HIGH, 3 MEDIUM, 1 LOW |

The wrapper itself is well built: the JSON is parsed by `node` with the value passed through the
*environment* (never interpolated into shell), every expansion is quoted, every failure path aborts
78 before `exec`, and the argv ordering argument is correct. I found no injection and no fall-through
to an unprotected `exec`. #112 is rejected on one thing only: **the leash is owned by the user it
leashes.**

---

## Findings

### Proven

| # | Sev | File : lines | Attack path (who controls the input, what they get) | Conf |
|---|---|---|---|---|
| F1 | **CRITICAL** | `worker/Dockerfile:167,169` | `COPY --chown=squad:squad worker/squad-agent ... /usr/local/lib/squad-on-aca/` + `chmod +x` ⇒ the file is **owned by `squad`, mode 0755, owner-writable**. `worker/entrypoint.sh:49-61` drops `watch`/`loop` to exactly that user (`SQUAD_RUNTIME_USER="squad"`). The agent has `shell` and is denied only `sudo/su/chmod/chown/chattr/setfacl` — it does not need any of them, because it already owns the file: `printf '#!/bin/bash\nexec copilot --yolo "$@"\n' > /usr/local/lib/squad-on-aca/squad-agent`. `squad watch` re-`exec`s this script **once per agent spawn** for the life of the container (5-min interval, 45-min timeout), so the rewrite takes effect on the next spawn and every spawn after it. The path is outside `.squad/`, so no governance manifest, hash, or detector ever sees it, and the `watch/loop agent-cmd argv:` log line (printed once, at startup) continues to show the correct policy. The agent rewrites its own leash and the session reports clean. | 9/10 |
| F2 | **HIGH** | `worker/lib/agent-policy.js:426-431`; `worker/squad-agent:200,210`; `worker/lib/squad-policy.sh:156-161` | `--allow-all-urls` — one of the three flags this repo's own header says `--yolo` expands to ("`--yolo`, which the CLI defines as `--allow-all-tools --allow-all-paths --allow-all-urls`", `agent-policy.js:11-12`) — is absent from `FORBIDDEN_EXTRA_FLAGS`, from the wrapper's `POLICY_ARGV_FORBIDDEN`/`TRAILING_ARGV_FORBIDDEN`, and from `squad_policy_resolve`'s blanket-allow `case`. Anyone who can set one dispatch environment variable gets it. **Demonstrated:** `SQUAD_COPILOT_FLAGS='--allow-all-urls --allow-tool shell' node worker/lib/agent-policy.js watch-agent-argv-json` → `[... ,"--deny-tool","shell(wget)","--allow-all-urls","--allow-tool","shell"]`. It passes `validateExtraFlags`, passes `squad_policy_resolve`'s check, and passes the wrapper's "last gate before `exec copilot`". The wrapper's stated contract — no permission-widening flag reaches copilot — is not met for URL scope, which is the exfiltration surface. | 9/10 |
| F3 | **HIGH** | `worker/entrypoint.sh:788-800, 876-884, 1012-1020` (removal of `squad_policy_announce squad`); `worker/lib/squad-policy.sh:193-210` | #112 removed `squad_policy_announce squad` from both branches. That function was the **only** place the parity gap was ever stated: `"NOT enforced on this path: ${SQUAD_POLICY_UNDELIVERABLE[*]}"`. The three replacement `log` lines print the mode and the argv, and never name what is missing. **Demonstrated:** the default parity argv is `["--allow-all-tools","--agent","squad","--remote","--no-auto-update","--no-ask-user","--deny-tool","shell(sudo)",...,"shell(wget)"]` — it is silently missing `shell(git config)`, `shell(gh auth)`, `shell(gh secret)`, `shell(gh variable)` (four of the ten `COMMON_DENY_TOOLS`, of which `agent-policy.js:362-369` says "There is no run in which allowing them is correct, so there is no tier in which they are allowed"), plus `shell(gh api)`, `shell(gh repo delete)`, `shell(gh release delete)`. The parity *choice* is settled and fine; the *announcement* of it is now strictly worse than before this commit — an operator reading the new log sees an argv and has no signal that seven deny rules were dropped from it. `shell(git config)` is credential-helper RCE with the session token attached; `shell(gh auth)` is token disclosure. | 9/10 |
| F4 | **HIGH** | `worker/lib/squad-policy.sh:753-770` | Append-only is only pinned to the **baseline prefix**. `[[ "$csum" == "$bsum" ]] && continue` (line 759) short-circuits on a full-file hash match, and the fallback test is `[[ "$clen" -lt "$blen" ]]` (line 760). An agent holding `u+w` on `.squad/memory/audit.jsonl` (granted by `squad_policy_harden`'s second pass, line 642) can **truncate the file to exactly `blen` bytes** — erasing every audit record written during the session while leaving the baseline prefix byte-identical. `csum == bsum`, `clen == blen`, prefix matches: verify passes, logs "Governance integrity verified", and the truncated file is what gets committed and pushed. Detector (c)'s committed-blob check applies the identical prefix rule and passes for the same reason. The commit message claims "audit.jsonl append succeeds, truncate/rename are refused" — truncate-to-**zero** is refused; truncate-to-baseline-length is not. Same defect applies to the pre-existing `.squad/agents/*/history.md`, but #113 is what puts the SDK's real audit trail behind it. | 9/10 |
| F5 | **MEDIUM** | `worker/lib/agent-policy.js:1038-1050` (`classify-governance-path`) | The classifier answers "which mutable class is this in", not "is this protected", and returns `locked` for everything else — including paths that are **not governance paths at all**. **Demonstrated:** `.mcp.json => locked`, `.squad/team.md => locked`, `.squad/decisions.md => locked`, `.squad/ralph-instructions.md => locked`, `.squad/casting-registry.json => locked`. None of those appear in `governance-paths` output, so none is hashed, manifested, or `chmod a-w`'d. This directly answers the review question "confirm team.md stays locked": **`.squad/team.md` is not locked and never was** (pre-existing), and #113's new CLI now actively asserts that it is. `scripts/validate.ps1` §7 was rewritten to assert classes through this verb, so the duplicate-list drift it removed has been traded for a verb whose `locked` is not a protection claim. | 10/10 |
| F6 | **MEDIUM** | `worker/lib/squad-policy.sh:789-815` (detector d), `:840` | A reported-mutable change that is **made and then reverted before checkpoint is invisible**. Detector (d) compares baseline hash against the *verify-time* hash only; detector (c) explicitly skips the class (`squad_policy_is_reported_mutable "$p" && continue`, line 840). In a `watch` session (many agent spawns, one checkpoint at the end) an agent can rewrite `.squad/identity/now.md` — prose that subsequent spawns read as trusted team context — to steer every later spawn, then restore it before the loop ends. `SQUAD_POLICY_REPORTED_CHANGES` stays empty and the governance log says nothing changed. The class is documented as "allowed but visible"; the visibility half does not hold against a revert. | 8/10 |
| F7 | **MEDIUM** | `worker/entrypoint.sh:601-613` vs `:820, :961` | `squad_policy_reported_changes_report` is appended to the PR body **only** inside `commit_and_push_if_needed`. The `loop)` and `watch\|triage)` branches end at `squad_policy_checkpoint` and **never call `commit_and_push_if_needed`** — the watch agent opens its own PR through `gh`. So on exactly the two modes #112 reworked, reported-mutable changes reach the container log and nothing else: not the PR body, not the branch, not any artefact a reviewer sees. The "listed in the governance report **and the PR body**" claim in the commit message and in `agent-policy.js:556-566` is true for `prompt`/`new-project`/`shell` and false for `watch`/`loop`. | 9/10 |
| F8 | **MEDIUM** | `worker/squad-agent:176-183` | The wrapper hands `--additional-mcp-config @${REPO_DIR}/.mcp.json` to copilot, where `.mcp.json` is **repo content** and is not a governance path (F5: `classify-governance-path .mcp.json` says `locked`, but it is absent from `governance-paths`, so it is neither hashed nor locked). An MCP server entry is arbitrary code execution as `squad`, outside every `shell(...)` deny pattern. An agent can rewrite `.mcp.json` in iteration *n* and have the new server loaded at iteration *n+1* of the same watch loop. This is not a regression — Squad passed the same file, with `--yolo` — but #112 makes it this wrapper's own explicitly-constructed argument, and the TOCTOU between the `-f` test (line 181) and copilot's read is a non-issue next to the fact that the file is writable for the whole session. | 8/10 |
| F9 | **MEDIUM** | `worker/lib/squad-policy.sh:671,675` vs `GOVERNANCE_PATHS` | The harden log asserts, for both exception classes: *"Their containing directories stay locked, so no file can be created or deleted beside them."* `GOVERNANCE_PATHS` lists `.squad/memory/config.json`, `.squad/memory/audit.jsonl`, `.squad/casting/{policy,registry,history}.json` as **files**; `.squad/memory` and `.squad/casting` are never `chmod -R a-w`'d, so `unlink()`/`creat()` in those directories is permitted and untracked new files can be planted beside the protected ones. Deletion of a tracked file is still caught by detectors (a)/(b), so this is a **false statement in the control's own log**, not a bypass — but it is the statement an operator would rely on to conclude F4 is unreachable. | 9/10 |
| F10 | **LOW** | `worker/squad-agent:163-169` | `parsed.join("\n")` + `while IFS= read -r token; do [[ -n "$token" ]] && POLICY_ARGV+=("$token")` silently **drops empty argv elements** and **splits any element containing a newline into several**. Demonstrated in bash 5.1: input `["--deny-tool","","shell(x)"]` → `n=2 tokens=--deny-tool shell(x)`, i.e. a `--deny-tool <pattern>` pair desynchronised into a bare `--deny-tool` with no exit and no diagnostic (`set -e` does not fire — the failing `[[ ]]` is the last command of a loop body). Not reachable today: `splitFlags` whitespace-splits `SQUAD_COPILOT_FLAGS`, so no resolver-emitted token can contain a newline or be empty. Defensive only: use a NUL-delimited transport, or make the parser reject empty/newline-bearing elements the way it already rejects non-strings. | 9/10 |
| F11 | **LOW** | `worker/lib/squad-policy.sh:378-401, 744-770` | Manifest readers use default-IFS `read -r kind rel rest` / `read -r kind rel bsum blen`, so a governance path containing a space mis-parses (`.squad/agents/a b/history.md` → `rel=.squad/agents/a`, `blen=<sha>`). Traced through both detectors: the line stays in the locked comparison and the append-only lookup misses, so the outcome is a spurious **violation** (fail-closed DoS), never a bypass. Likewise a filename containing a newline injects a manifest line, but `squad_policy_filter_locked_lines` filters by **path, not kind-word** (lines 390-392), so a forged `reported`/`append-only` line cannot downgrade a real locked path. Worth a comment; not worth a fix. | 7/10 |

### Suspected — needs a test

- **S1 (LOW).** `squad_policy_harden` lock pass takes `chmod -R a-w "$target"` with `$target` as a
  command-line argument. GNU `chmod -R` dereferences a symlink given *as an argument* (it does not
  dereference ones found during the walk), while `[[ -d "$target" ]]` also follows and `find -P`
  does not. A repo that ships `.squad/agents` as a **symlink to a directory** would therefore get a
  `dir` manifest line with **zero `file` lines** under it — every charter in the tree unhashed and
  unmonitored (they would still be `a-w` via the dereferenced recursive chmod, so I could not
  construct a write; the loss is detection, not prevention). Needs a real hardened-repo test:
  symlink a governance directory and assert either a refusal or a complete manifest.
  I did **not** find a symlink path that leaks authority: `find ... -type f` uses `lstat`, so a
  symlink planted at `.squad/identity/now.md` is excluded from both the manifest and the `chmod u+w`
  second pass — `chmod u+w` is never applied to a symlink and so never dereferences into a locked
  file. That specific attack is closed.

---

## Recommended fixes (HIGH and above)

Per the reviewer protocol the author of a change is locked out of its fix. #112 and #113 were
authored on the `engineer` path, and `engineer` is additionally mid-flight on
`worker/lib/agent-policy.js` right now, so **`reviewer`** should implement F1–F4, with `docs`
updating the two commit/claim corrections (F3's log text, F4's "truncate is refused" claim).

- **F1 — `reviewer`.** `worker/Dockerfile`: move `worker/squad-agent` out of the
  `COPY --chown=squad:squad` list into its own `COPY --chown=root:root`, and set an explicit
  `chmod 0555` instead of `chmod +x`. The thing being protected (`copilot`, installed by
  `npm install -g` as root) is already root-owned; the gate in front of it must not be weaker than
  the thing it gates. Extend `worker/tests/test_image_layout.sh` and `scripts/validate.ps1`
  §"Shipped image layout" to assert owner `root` and absence of any write bit — the positive
  assertion #112 already added is the right place. Same treatment is warranted for the rest of
  `/usr/local/lib/squad-on-aca/` and `/usr/local/bin/squad-on-aca` (pre-existing, lower urgency:
  those are consumed once at container start, not re-`exec`'d per agent spawn).
- **F2 — `reviewer`.** Add `--allow-all-urls` to `FORBIDDEN_EXTRA_FLAGS`
  (`agent-policy.js:426`), to both lists in `worker/squad-agent:200,210`, and to
  `squad_policy_resolve`'s blanket-allow `case` (`squad-policy.sh:158`). Consider `--allow-tool`
  in the same change (deny rules out-rank allow rules per the CLI docs, so it is weaker, but it is
  still an unreviewed widening arriving from environment). Coordinate with the in-flight
  `agent-policy.js` edit.
- **F3 — `reviewer`.** In both the `loop)` and `watch|triage)` branches, add the line that was lost:
  log `SQUAD_POLICY_UNDELIVERABLE[*]` whenever `SQUAD_WATCH_AGENT_POLICY_MODE == parity`, with the
  reason reworded for this path ("parity mode intentionally keeps the pre-#112 effective deny set;
  these rules are NOT enforced; set `SQUAD_WATCH_STRICT_POLICY=true` to enforce them"). The
  settled parity decision is defensible precisely because it is announced; restore the announcement.
- **F4 — `reviewer`.** Make append-only mean "may only grow". Record a byte-length **high-water
  mark** per append-only path in `SQUAD_POLICY_STATE_DIR` (0700, outside the checkout, already out
  of the agent's file-tool reach) and fail verify on any decrease from it, rather than comparing
  only against the hardening-time baseline. Minimum acceptable alternative: `chattr +a` on
  `audit.jsonl` where the filesystem supports it. Add the regression test that truncates
  `audit.jsonl` to **exactly** its baseline length (not zero) and asserts a violation — the current
  suite only proves truncate-to-zero.

---

## Verified SAFE (coverage for the reviewer gate)

**`worker/squad-agent` (#112)**

1. **No shell injection, word-splitting, or glob expansion.** The untrusted value is handed to
   `node` through the environment (`POLICY_JSON="$POLICY_ARGV_JSON" node -e '...'`, line 135), never
   interpolated into the script text. No `eval`, no backticks on policy data, no unquoted
   expansion of any policy token, no `$(...)` on attacker data. `IFS=` is set on the `read` and
   never leaked globally. Final exec is `exec copilot "$@" "${POLICY_ARGV[@]}" "${MCP_ARGV[@]}"` —
   three quoted array expansions, so no element is re-split or globbed.
2. **Fail-closed completeness.** Every reachable failure aborts 78 *before* `exec`: node absent,
   copilot absent, env missing, env empty, invalid JSON, non-array, empty array, non-string
   element, zero usable tokens after parsing, widening flag in the resolved argv, widening flag in
   Squad's trailing args. `set -Eeuo pipefail` plus the `if ! policy_tokens_raw="$(...)"; then`
   capture means the node exit status cannot be swallowed. I traced every statement between the
   last check (line 215) and `exec` (line 228): there is nothing there. No path falls through to an
   unprotected copilot.
3. **Argv order cannot neutralise policy.** Squad's trailing args go first, policy and MCP args
   last, so a future Squad that appends its own `--deny-tool`/`--additional-mcp-config` cannot be
   last-wins over the wrapper's. Independently, Copilot documents deny rules as taking precedence
   over allow rules "even `--allow-all-tools`", so position cannot disable a deny rule.
4. **Squad cannot reintroduce `--yolo`.** `--agent-cmd` bypasses `buildAdditionalMcpConfigArgs()`
   entirely, and `--yolo`/`--allow-all`/`--allow-all-paths`/`--add-dir` are rejected from *both*
   sources anyway. `--additional-mcp-config` is emitted by the wrapper alone and is never paired
   with `--yolo`.
5. **The policy env cannot be pre-seeded by a dispatcher.** `worker/entrypoint.sh:318` and `:329`
   assign `SQUAD_AGENT_POLICY_ARGV_JSON` and `SQUAD_AGENT_REPO_DIR` **unconditionally** (no `:-`
   default), overwriting anything inherited, and abort via `squad_policy_abort` if the resolver
   exits non-zero or returns empty.
6. **No binary substitution.** `copilot` and `squad` are installed by `npm install -g` as root
   (`worker/Dockerfile:75`) into root-owned `/usr/local/lib/node_modules`; `/usr/local/bin` is
   root-owned. The agent cannot shadow `copilot` on PATH or replace the binary. (This is exactly
   the control F1 is missing.)
7. **The prompt is inert.** `-p <prompt with spaces>` arrives as ordinary `"$@"` elements and is
   forwarded as such; prompt text cannot become a flag unless it *is* a flag, which the trailing-arg
   check covers for the widening set.

**Governance (#113)**

8. **The path classifier is exact-match and fails safe.** All four patterns are `^...$`-anchored
   against a path normalised only for backslashes and a leading `./`. Executed against crafted
   inputs; every one of them fell back to the **strongest** class:
   `.squad/identity/now.md/../mission.md => locked`, `.squad/identity/./now.md => locked`,
   `.SQUAD/identity/now.md => locked`, `.squad/identity/mission.md => locked`,
   `.squad/agents/security/charter.md => locked`; and the legitimate ones classify correctly:
   `.squad/identity/now.md`, `.squad/casting/{policy,registry,history}.json => reported-mutable`
   (including `./`-prefixed and backslash forms), `.squad/memory/audit.jsonl => append-only`.
   **No input produced a weaker-than-true class.** (The separate problem is what `locked` *means*
   for an unprotected path — F5.)
9. **`identity/` stays locked except `now.md`.** `.squad/identity` is a whole-directory
   `GOVERNANCE_PATHS` entry; only the exact filename `now.md` is carved out. `mission.md` and
   everything else under it classify `locked` and are `chmod -R a-w`'d. `.squad/routing.md`,
   `.squad/config.json` (where the model policy actually lives), `.squad/casting-policy.json`,
   `.squad/policies`, `.squad/agents/**` (except `*/history.md`), `.squad/fact-checker/*` and
   `.squad/rai/*` are all still locked. Charters are locked.
10. **Reported-mutable does not leak authority, in this schema.** I read the actual files:
    `.squad/casting/policy.json` is a fictional-universe allowlist plus per-universe capacity
    counts, and `registry.json`/`history.json` are character-name bookkeeping. There is no model,
    tool, permission, path, or command field in any of them, and nothing in them is interpolated
    into a privileged path or command. The authority-bearing files (`config.json` with
    `agentModelOverrides`, `routing.md`, charters, `casting-policy.json` v1.2) all stayed locked.
    The one real influence channel is `identity/now.md` as trusted prose context for later spawns —
    that is F6, a visibility problem, not a privilege one.
11. **No symlink-based class laundering.** `squad_policy_write_manifest` and the `chmod u+w` second
    pass both walk with `find ... -type f` (default `-P`, `lstat`), so a symlink planted at a
    reported-mutable or append-only path is excluded from both. `chmod u+w` is therefore never
    applied to a symlink and never dereferences into a locked file. Writes *through* such a symlink
    land on a target that is itself `a-w` and separately hashed.
12. **Manifest line injection cannot downgrade a locked path.** A crafted filename containing a
    newline does inject a manifest line, but `squad_policy_filter_locked_lines` excludes lines by
    **path** (`squad_policy_is_mutable` / `is_reported_mutable`), not by the line's kind word, so a
    forged `reported`/`append-only` kind word on a real locked path is still compared. The code
    comment at lines 383-392 states this intent and the implementation matches it.
13. **Audit rotation cannot be re-enabled mid-session.** `.squad/memory/config.json` stays a plain
    locked path: the `auditMaxBytes: 0` pin is written *before* the lock pass and then `chmod a-w`,
    so the agent cannot rewrite its own rotation policy. The pin is committed before `base-commit`
    is captured, so it is correctly attributed to the session's starting state rather than flagged
    as an agent-made violation on every run. `rm`+recreate of `audit.jsonl` via the unlocked parent
    (F9) is still caught by detector (b)'s `clen -lt blen` and by the `absent`-line diff.
14. **The baseline is out of reach.** `squad_policy_state_dir` creates 0700 under `$HOME`, resolves
    symlinks with `pwd -P`, and **refuses** any location inside the checkout; with
    `--allow-all-paths` dropped, copilot's file tools are CWD-scoped and cannot reach it.
15. **Resolver call sites fail closed.** `squad_policy_load_governance_paths` /
    `..._mutable_patterns` / `..._reported_mutable_patterns` all degrade to an **empty** array,
    which means *nothing is excluded* and everything stays locked and hash-pinned — the correct
    direction. `squad_policy_harden` aborts outright if `node` or `sha256sum` is missing.
16. **Caching the resolver call did not change semantics.** The new
    `SQUAD_POLICY_GOVERNANCE_PATHS_LOADED` guard memoises a value that is a pure function of
    constants in `agent-policy.js` (the file's own "DETERMINISM IS THE CONTRACT"), and the cache is
    per-process, so harden and verify in the same shell see the identical list.

---

## Not reported (confirmed false positives)

`--allow-all-tools` in the resolved argv; the parity default itself; the absent `{prompt}` token;
`auditMaxBytes: 0` meaning "never rotate"; `squad watch` still being able to push and open PRs.
All four were verified as deliberate and correct as implemented.
