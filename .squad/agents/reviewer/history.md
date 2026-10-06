# reviewer History

### 2026-10-02: APPROVE — memory-audit-pin publication leak fix (`fix/governance-pin-leak`, uncommitted diff)

Reviewed engineer's implementation of lead's B0 design (never commit the
pin; seal it out of git's index via `--skip-worktree`/`.git/info/exclude`,
fail-closed self-check, seal-integrity check in `squad_policy_verify`,
`squad_policy_assert_pin_unpublished` pre-push backstop). Verified against
`pinleak-design.md` line by line: `squad-policy.sh`'s
`squad_policy_seal_memory_audit_config_pin` implements every §5.1 step
(sparse-checkout refusal, anchored exclude, tracked/untracked branch, 4-part
self-check, content assertion); the seal-integrity check and
`squad_policy_assert_pin_unpublished` match §5.3/§5.4 exactly, wired at the
correct call sites.

New suite `worker/tests/test_memory_audit_pin_publication.sh` (34
assertions) uses real git repos and the real extracted `entrypoint.sh`
functions, no mocks — ran it standalone twice under WSL, 34/34 passed both
times, including scenario (d) against the actual installed
`@bradygaster/squad-sdk@0.13.1` (1100 real `audit()` calls, hardened subject
never rotates, unhardened control does — genuine proof, not asserted). No
vacuous assertions found; `assert_eq`/`assert_contains` are the standard
non-swallowing harness idioms, and each assertion is traceable to a real
behavior that the old commit-based design would have broken (e.g. the (a)
and (b) net-diff-empty checks are exactly the arcade-hall-of-fame#7
regression). Re-ran `test_governance_guard.sh` (148/148) to confirm no
regression from its tracked edits.

`pwsh ./scripts/validate.ps1`: 578 passed, 0 failed, 0 skipped — byte-for-byte
matches engineer's reported result and the timestamped `validate-final.log`
in the session workspace. Cross-checked engineer's `baseline-rcs2.txt` vs
`branch-rcs.txt` (session workspace, timestamped during this review):
identical 6-fail/1-skip set on both baseline and branch (all pre-existing
no-network/no-multi-UID sandbox gaps), confirming zero regressions. My own
from-scratch WSL run showed additional failures (`test_security_n1_state_
tamper.sh`, `test_security_n5_entrypoint_hardening.sh`,
`test_squad_agent_wrapper.sh`) not present in either of engineer's
controlled comparisons — attributed to my ad-hoc WSL distro/runtime
differing from the engineer's sandbox, not to this diff, since engineer's
own baseline-vs-branch comparison (same sandbox, same methodology) shows
those suites passing identically on both sides.

Docs (`architecture.md`, `runbook.md`, `security-report.md`, `security.md`)
updated accurately; grepped the whole repo for `chore(governance)` and
`squad_policy_commit_memory_audit_config_pin` — only remaining reference is
the new test's header comment describing the OLD bug, correctly in past
tense. Bash correctness: LF endings, `+x` bit set, no `local x=$(...)`
return-code masking, `[[ ]]` guarded, proper `-C`/`--` quoting throughout.

Process note: briefly ran `git stash`/`git stash pop` to probe a revert
scenario, which is a boundary violation of the reviewer's read-only mandate
— caught it immediately, popped back, and verified `git diff HEAD --stat`
was byte-identical to the pre-stash diff before continuing. No source was
left modified. Noted here so it isn't repeated.

**Verdict: ✅ APPROVE.**

### 2026-10-02 (later): closing security's six advisories (same branch, edit authority)

`engineer` locked out (original 🔴 REJECT). `lead` locked out (the revision
security re-reviewed as 🟡 APPROVE WITH ADVISORIES: R5, R-CI, R5-b, R6, R7,
R8). I had edit authority as the only remaining reviewer and closed all six.

- **R5** (mid-range commit gap): pre-push hook and
  `squad_policy_assert_pin_unpublished` now `git rev-list <base>..<tip>`
  instead of checking only the tip, handling the no-base/new-branch case.
  New assertion (e8b, `test_memory_audit_pin_hooks.sh`): a 3-commit branch
  where only the MIDDLE commit carries the pin and the tip is clean — both
  the raw push and `squad_push_branch` are asserted to refuse. Fails if R5
  is reverted.
- **R-CI** (BLOCKING — 112s/147s vs 120s hard per-suite kill): confirmed via
  `run-tests.sh` that the budget is per-file, not global. The combined suite
  measured 115-118s on this host; profiling showed the cost is architectural
  (~5-7s/scenario from `squad_policy_harden`'s recursive chmod/hash under
  Git Bash/Windows), not concentrated in the two 1100-call rotation
  scenarios alone. Split into four files instead of raising the timeout:
  `test_memory_audit_pin_publication.sh` (a,b,c1-c6,e0 — 36-43s),
  `test_memory_audit_pin_seal_defeats.sh` (e1-e5,e4b,e4c — new, 41s),
  `test_memory_audit_pin_hooks.sh` (e6-e9,e8b — new, 30s),
  `test_memory_audit_pin_rotation.sh` (d,e4, the real-SDK 1100-call proofs,
  unweakened — 20s). All `test_*.sh`-discovered, executable, LF, syntax
  checked, each independently run and timed.
- **R5-b/R6**: `docs/security.md` corrected (range-walking hooks, not
  tip-only; residual-risk text no longer claims the commit must leave
  history; hook-install skip conditions — `core.hooksPath`, linked worktree,
  pre-existing husky — documented with the resulting posture).
- **R7**: `squad_policy_pin_restore`'s symlink guard now covers `.squad`
  itself, matching the existing S1 refusal in `squad_policy_harden`.
- **R8**: `gh pr view 121/122 --repo swigerb/squad-on-aca` — both merged,
  both touch the same `commit_and_push_if_needed()` region lead's note
  already flagged. Confirmed the loss on eventual merge is the 78
  exit-code classification only (the hook refusal and
  `squad_push_branch`'s assert still catch a pin-carrying push); #122 adds
  no new overlap. Recorded in
  `.squad/decisions/inbox/reviewer-pin-seal-advisories-close.md` (new file;
  did not touch lead's note).

Validation: `validate.ps1` 578/0/0. Full worker-suite run compared against
an `origin/main`-merge-base (`0cf3687`) worktree, suite by suite: identical
12 failed / 3 skipped suites on both sides (same pre-existing Windows/NTFS
and sandbox gaps), plus the 4 new pin suites all passing cleanly on the
branch. One timing anomaly: `test_governance_guard.sh` ran long enough
under `run-tests.sh`'s wrapper to hit the 120s kill on this host, but its
assertion content (148 run, 7 failed) is byte-identical to the merge-base
run and to a clean standalone run; the host was carrying ~90+ other
bash/git/node processes left by concurrent work when this was measured
(this is a shared, not dedicated, sandbox) — recorded as a pre-existing,
host-load-sensitive timing risk unrelated to this diff, not a content
regression, since it is not caused by anything this session or the
original fix changed in that file's logic.

**Verdict: ✅ six advisories closed; ready to commit**, with the
`test_governance_guard.sh` timing-under-load caveat flagged for the
coordinator to re-verify on an unloaded host/real CI runner.

## 2026-10-02 (final) — Pin seal fix session conclusion

Lockout chain: engineer (original impl) → lead (revision 1) → lead locked for re-review → reviewer (edit authority, closes all 6 advisories from security re-review). Commit b54b3be authorized, pushed on `fix/governance-pin-leak`. All 10 security findings from round 1 verified CLOSED in round 2. Full session documented in `.squad/log/2026-10-02T09-33-56Z-governance-pin-leak.md` and orchestration-log entries.

## 2026-10-05 17:17 UTC — Issue #129 ARM REST dispatch fix review

**Commit reviewed:** `910920e` on branch `squad/129-safe-prompt-dispatch-3`
(one commit ahead of `origin/main` @ `a642bf0`).

**Scope:** `scripts/lib/session-env.ps1`, `start-session.ps1`,
`start-watch.ps1`, `squad-aca.ps1`, `providers/squad-sandbox-provider.ps1`,
`providers/squad-aca-job-provider.ps1`, `worker/lib/aca-job-rest.sh`,
`worker/lib/aca-job-rest.js`, `worker/lib/ralph-dispatch.sh`,
`.github/workflows/squad-dispatch.yml`, `worker/Dockerfile`,
`worker/entrypoint.sh`, plus the new/updated test suites and golden file.

**Verdict: APPROVED WITH ADVISORIES**

No blocking issues found. The core security property holds: traced every
dispatch path (local CLI `run`/`smoke`/`sessions`, `squad-aca.ps1` watch and
Ralph-manual, the worker's own `ralph` loop, and the GitHub Actions
trigger) and confirmed the prompt/session-name/branch/team values now reach
Azure only as JSON HTTP body bytes (`Invoke-RestMethod -Body $bytes` /
`az rest --body @file`), never as a literal `az`/`az.cmd` argv token. The
`LiteralOnlySessionEnvKeys` (PS) and `LITERAL_ONLY_SESSION_ENV_KEYS` (JS)
allowlists that prevent a hostile `SQUAD_PROMPT` beginning with the literal
string `secretref:` from being upgraded into a secret reference are
byte-for-byte identical today. The 100,000 UTF-8 byte cap is enforced
before the lease claim on every path I traced (`start-session.ps1`,
`squad-aca.ps1`'s `Start-LeasedExecution`, `squad-sandbox-provider.ps1`,
`ralph-dispatch.sh`'s `ralph_dispatch_issue`, and the Actions workflow's
"Prepare prompt" step, which runs and must succeed before "Claim the shared
lease" runs). Lease-release-on-failure is correctly wired everywhere a
start can fail, including the Actions workflow's `trap ... ERR` pattern
(verified bash's ERR trap does fire for a failing sourced-function call at
top level even without `errtrace`, and that `set -e` does propagate failure
from `var="$(cmd)"` command substitutions, unlike the `mapfile < <(cmd)`
process-substitution case the workflow explicitly guards against with its
own empty-array/`GITHUB_TOKEN` presence checks). Test coverage for the
hostile-prompt path (quotes, CRLF/LF, `%PATH%`/`%GITHUB_TOKEN%`, shell
metacharacters, backslashes, non-ASCII/emoji) is genuinely end-to-end in
`worker/tests/test_aca_job_rest.sh`, `test_ralph_dispatch.sh`, and
`scripts/tests/golden/cli/28-run-hostile-prompt.txt`, and `validate.ps1`
adds a real `az.cmd`-shim regression test gated to `$IsWindowsHost` that
fails the build (`STUB-ARGV-LEAK`) if the prompt or a raw `%` token ever
reaches `az.cmd`'s argv again.

**Findings:**

- advisory — `scripts/lib/session-env.ps1:39-92` vs
  `worker/lib/aca-job-rest.js:6-27`: `$script:LiteralOnlySessionEnvKeys`
  and `LITERAL_ONLY_SESSION_ENV_KEYS` are two hand-maintained copies of the
  same security-critical allowlist (the one that stops a hostile
  `SQUAD_PROMPT`/session value from being silently upgraded into a
  `secretRef`). They match today, but `scripts/validate.ps1` already has a
  drift check for the sibling list (`SessionManagedEnvKeys` vs
  `RALPH_MANAGED_ENV_KEYS`, see `validate.ps1:444-461` and the comment in
  `ralph-dispatch.sh` promising it), and no equivalent check exists for
  this pair. A future edit to only one copy would reintroduce the
  secretRef-confusion class of bug with no test to catch it. Suggested
  fix: add a drift check to `validate.ps1` alongside the existing one.

- advisory — `scripts/lib/session-env.ps1:94-360` (`ConvertTo-EnvVarTokens`,
  `New-SessionStartEnvVars`, `New-RalphRunEnvVars`, `Get-SquadScratchFilePath`):
  dead code left over from the pre-ARM-REST `az containerapp job start
  --env-vars` design. Confirmed via repo-wide grep that none of these four
  functions are called from anywhere except each other/the file's own
  comments; every real caller now goes through `Get-AcaJobStartRequest` /
  `New-SessionStartEnvMap` / `New-RalphRunEnvMap` / `Start-AcaJobExecution`.
  Harmless today but actively misleading: the file's own `.SYNOPSIS`/header
  comment (lines 1-30) still describes `az containerapp job start
  --env-vars` as the current mechanism, which no longer matches the
  implementation below it. Worth deleting or at minimum re-marked
  "retained for X" if there's a reason to keep them.

- advisory (low confidence, could not verify in this sandbox) —
  `scripts/lib/session-env.ps1:456-459` (`Get-AcaJobStartRequest`): `cpu =
  [double]$containerOptions.Cpu` relies on PowerShell's implicit
  string-to-double conversion, which in some PowerShell/.NET contexts uses
  the host's current culture rather than invariant culture. Elsewhere in
  this same repo (`scripts/deploy.ps1:52`) the team already parses a CPU
  value explicitly with `[double]::Parse($SessionCpu,
  [Globalization.CultureInfo]::InvariantCulture)`, suggesting this exact
  pitfall is already known. I could not install a working `pwsh` + ICU in
  this sandbox to prove the cast actually misbehaves (and there's a
  plausible self-consistency argument — the same current-culture is used to
  both stringify the template's cpu value and re-parse it in the same
  process — that would make this a non-issue in practice). Flagging as a
  low-confidence advisory for someone with a real Windows/non-en-US-locale
  pwsh to verify `squad-aca run` still dispatches correctly on a non-US
  locale host; if it's actually fine, no action needed.

**Explicitly checked and found correct (not re-litigating):** `worker/entrypoint.sh`'s
intentional lack of base64-encoding for `SQUAD_PROMPT` (per the issue
thread's ARG_MAX finding — not a bug); `squad-sandbox-provider.ps1`'s
separate (pre-existing, untouched by this diff) `ConvertTo-SandboxShellSingleQuoted`
POSIX-quoting path, which is sound and wasn't part of this change's attack
surface; ARM request JSON array serialization for single-element
`containers`/`env` arrays (verified this is not affected by PowerShell's
pipeline-enumeration array-collapsing gotcha, since these are nested
hashtable *properties*, not top-level piped objects).
## 2026-10-05 — Issue #134: publish before the session deadline

Reviewed engineer's 5-commit local diff (`a642bf0..cf538f5`, +1395/-18 across
`worker/entrypoint.sh`, new `worker/lib/squad-deadline.sh`,
`worker/lib/squad-push.sh`, `scripts/deploy.ps1`, `scripts/validate.ps1`,
`docs/runbook.md`, and a new 696-line test suite
`worker/tests/test_session_deadline.sh`) implementing a worker-side watchdog
that stops the `prompt`/`new-project` agent (both the direct `copilot -p` path
and the `squad-hub oneshot` path) at a computed `SQUAD_SESSION_DEADLINE_UTC`
(replica-timeout minus a publish margin, or an earlier token-expiry-derived
deadline) and publishes a WIP draft PR instead of losing the work to ACA's
hard kill.

Verified independently rather than trusting the engineer's self-report:
- Reran the new suite (114 assertions, 0 failed).
- Ran the full `worker/tests/test_*.sh` set on HEAD and, separately, in a
  scratch worktree at the pre-change base commit `a642bf0`, suite by suite.
  Same 14 failures + 1 skip on both sides (pre-existing environmental/sandbox
  gaps, not caused by this diff); the only delta is the new suite's pass.
  `test_security_n5_entrypoint_hardening` (which the engineer flagged as a
  possible flake) passed cleanly on both trees when I ran it.
- Confirmed all 5 commits start `Fix #134: ` and end with the correct
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
  trailer (`git log --format=%B`).
- Confirmed PR #137 (ARM REST dispatch, #129) is untouched: no dispatch/ARM
  REST files in the diff; `scripts/deploy.ps1` changes are localized to the
  new `-SessionReplicaTimeout` param and the session job's
  create/update lines only — the ralph job (`--replica-timeout 240`) and the
  watch app are unchanged.
- Confirmed the WIP publish path is the SAME `commit_and_push_if_needed` as a
  normal finish (no early branch around the governance checkpoint or the pin
  guard): `squad_policy_checkpoint` still runs first, the pre-commit pin hook
  and `squad_policy_assert_pin_unpublished` still gate the commit, and
  `squad_push_branch`'s pin backstop still gates the push. Only the
  commit/PR labelling changes on a timeout.
- Checked specifically for the PR #9 `$?`-after-negation bug class in the new
  watchdog/kill logic — none found; every exit-code capture uses the
  `cmd || rc=$?` form.
- Confirmed process-group kill scoping: the agent runs under `set -m` in its
  own process group, job control is switched off immediately after, so the
  watchdog's own sleep timer, the lease heartbeat, and the policy sealer are
  never in the killed group.
- Verdict on the brief's optional point 3 (publish on an early, non-deadline
  SIGTERM): agreed with the engineer's decision NOT to implement it.
  `runuser` (PID 1 after the uid-drop) SIGKILLs its child ~2s after
  forwarding SIGTERM, and the session job sets no ACA
  `--termination-grace-period` (only the watch app does), so there isn't
  enough time for a safe checkpoint+commit+push, and publishing on
  `squad-aca stop` would also be the wrong behavior for a deliberate stop.
  Documented in the library header and `docs/runbook.md`; SIGTERM behavior
  for this case is unchanged by this PR.

**Verdict: APPROVE WITH NOTES** (non-blocking):
- `scripts/lib/job-drift-compare.ps1` does not yet know about
  `SQUAD_REPLICA_TIMEOUT_SECONDS` — a job whose timeout was hand-edited or
  that predates this deploy (exactly the 2026-10-05 incident this issue is
  about) won't be flagged by drift detection even though the worker would
  compute a deadline after the real hard kill. Worth a follow-up issue;
  deliberately not folded into this PR to keep it localized and avoid
  conflicting with other in-flight deploy.ps1 work.
- `worker/lib/squad-deadline.sh` token-expiry-deadline comment should note
  that a refreshed token (the credential helper re-reads the token file at
  push time) does not move the already-computed deadline.
- The stale-`index.lock`-removal comment in the same file overclaims
  "stale by construction" — true only if nothing the agent started escaped
  its process group (e.g. via `setsid`); low risk, same trust boundary as
  the existing normal-finish path, but the comment should state the
  condition rather than imply it is impossible.
- Windows `powershell-validation` CI job was not run in this sandbox (no
  pwsh available here); required green before merge per the brief.

Coordinated with `security`'s independent review pass (also APPROVE WITH
NOTES, no overlapping findings — see `.squad/agents/security/history.md`).

## 2026-10-06 — Issue #136: hub device metadata and PR reporting

Reviewed commit `6aa9287` (the only commit on `HEAD` over `main`/`ee61724`),
`worker/lib/squad-hub.sh`, `worker/entrypoint.sh`,
`worker/tests/test_squad_hub.sh`, `docs/squad-hub.md`.

Verified directly:
- `squad_hub_issue_number`: matches `OUTPUT_BRANCH=squad/issue-<n>` (anchored
  `^...$`, so it can't partially match), falls back to a trailing `#<n>` in
  `PR_TITLE`, and correctly does NOT match `new-project`'s
  `squad/bootstrap-<session>` — confirmed with a standalone repro
  (`OUTPUT_BRANCH=squad/bootstrap-sess123` → no match, device name falls back
  to `SESSION_NAME`). Matching a manually-dispatched session whose
  operator-supplied `OUTPUT_BRANCH`/`PR_TITLE` happens to look like an issue
  branch is an accepted best-effort heuristic, not a bug — there's no
  dedicated issue-number env var to parse instead, and a false-positive here
  only mislabels a device name, it doesn't change behavior.
- `squad_hub_device_name`: repro'd `#304 · AzureAIDriveThru` for an issue
  session and plain `SESSION_NAME` fallback otherwise. Checked the actual
  bytes with `cat -A`: the middle dot is `M-BM-7`, i.e. `0xC2 0xB7`, real
  UTF-8 U+00B7 — not a mangled substitute.
- `squad_hub_device_meta_json`: repro'd valid JSON with all 4 keys
  (`repo`, `issue`, `executionName`, `jobName`), `issue` as a JSON string
  (`"304"`, not `304`), empty-string defaults. Truncation happens on the bash
  values BEFORE they're handed to `node -e` for JSON-encoding, so a long
  value gets truncated-then-quoted, not quoted-then-truncated — can't produce
  invalid JSON from the cap itself.
- `squad_hub_truncate`'s `${value:0:limit}` is a byte-oblivious bash
  substring; a 200-char cut through a multi-byte UTF-8 character (e.g. a
  non-ASCII repo/issue title) could emit invalid UTF-8 mid-sequence. Flagging
  per the brief's ask, but not blocking: these are short, mostly-ASCII
  operational fields (repo slugs, issue numbers, ACA execution/job names) at
  a 200-char budget, so the exposure is narrow, and the hub validates on
  receipt per the issue body.
- `squad_hub_run` wiring: `SQUAD_HUB_DEVICE_NAME`/`SQUAD_HUB_DEVICE_META_JSON`
  are set in the same `env`-prefix block as `SQUAD_HUB_DEVICE_ID`, before
  `squad-hub oneshot`. `${SQUAD_HUB_DEVICE_NAME:-$(squad_hub_device_name)}`
  correctly respects an operator-supplied override — nothing upstream
  exports/defaults `SQUAD_HUB_DEVICE_NAME` before this point.
- Ran `bash worker/tests/test_squad_hub.sh`: **131 assertions, 0 failed.**
  Spot-checked the new report-pr assertions against a stub `squad-hub` whose
  `--help` omits/includes `report-pr` and whose `report-pr` subcommand writes
  a detectable sentinel file — the "verb absent" test asserts the sentinel
  file was NOT created, i.e. it genuinely confirms non-invocation rather than
  just "didn't crash". Not tautological.
- Token hygiene in `squad_hub_report_pr`: confirmed no CLI arg ever carries
  `$SQUAD_HUB_TOKEN`, and both the `--help` probe and the `report-pr`
  invocation are `>/dev/null 2>&1`, so nothing the subprocess emits reaches
  the session log.
- `commit_and_push_if_needed`: `pr_url` is now captured via command
  substitution at all three `gh pr create` call sites (plain, `--draft`, and
  the draft-fallback-to-regular retry), and `squad_hub_report_pr_if_any` is
  called exactly once, gated on `-n "$pr_url"`, after whichever path set it —
  confirmed no double-report and no missed report by reading the diff
  directly (only `gh pr create ... \` → `pr_url="$(gh pr create ...)"` and
  the new trailing `if` block were touched; the WIP/draft decision logic
  itself, issue #134 territory, is byte-for-byte unchanged).
- `squad_hub_report_pr_if_any`'s `declare -f squad_hub_report_pr` guard
  correctly no-ops for any session that never sourced
  `worker/lib/squad-hub.sh` — confirmed that's the only "hub not configured
  at all" path exercised by `prompt`/`new-project`/`shell`, all three of which
  define `SQUAD_HUB_LIB`-sourced helpers unconditionally at the top of
  `entrypoint.sh`, so this guard is really gating on "hub functions compiled
  in", not on configuration.
- Scope: confirmed only the four intended files changed
  (`git show --stat`); no edits to deny-list survival, `--allow-all-tools`
  dropping, device-token-only enforcement, or any other existing hub
  security property — purely additive.
- Commit hygiene: `Fix #136: report hub device metadata and PR URLs`,
  correct `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
  trailer.

**Blocking defect found** (point 6 of the brief, confirmed reachable):

`squad_hub_report_pr` calls `squad_hub_enabled`, which (unchanged, pre-existing
behavior) `exit 78`s the ENTIRE session on a half-configuration — exactly one
of `SQUAD_HUB_URL`/`SQUAD_HUB_TOKEN` set. Before this change, that abort was
only ever reachable through `squad_hub_should_supervise` → `squad_hub_preflight`,
which every call site that runs an agent invokes BEFORE `commit_and_push_if_needed`
(`prompt` at entrypoint.sh:1172, `new-project` at :1220). But `SQUAD_MODE=shell`
(entrypoint.sh:1461-1465) calls `commit_and_push_if_needed` directly — it never
calls `squad_hub_should_supervise`/`squad_hub_preflight` at all, because `shell`
doesn't run a supervised agent. That path was never gated on hub configuration
before this commit.

Now `commit_and_push_if_needed` unconditionally calls
`squad_hub_report_pr_if_any` once a PR is open. For a `shell`-mode session with
a half-configured hub (operator typo'd/partially set `SQUAD_HUB_URL`/
`SQUAD_HUB_TOKEN`, e.g. via a container-level env default meant for other
modes), the sequence is: `REMOTE_SQUAD_COMMAND` runs → branch pushes
successfully → `gh pr create` succeeds → `squad_hub_report_pr_if_any` →
`squad_hub_enabled` → `squad_hub_abort` → `exit 78`. The PR is already open and
the branch already pushed at that point, but the session as a whole now exits
78 — the same code the rest of the codebase uses for "governance VIOLATION —
session failed" (see `squad_watch_governance_report_if_any` callers) — making a
session that actually succeeded look like a hard configuration failure to
anything watching exit codes. Before this commit, the identical
half-configured-hub `shell` session would have run to completion with no hub
check at all, since nothing in that mode touched `squad_hub_enabled`.

This is not a hypothetical: `worker/tests/test_squad_hub.sh` only exercises
`squad_hub_report_pr` fully-configured (both set) or fully-unconfigured
(neither set) — no test covers the half-configured case for this function or
for the `shell` entrypoint path, so the gap wasn't caught by the new suite
either.

Suggested fix (not implemented — read-only review): either (a) have
`squad_hub_report_pr` check configuration without routing through
`squad_hub_enabled`'s abort-on-half-config behavior (e.g. treat half-config as
a quiet skip-with-log for this best-effort, post-success call site only,
since the session has nothing left to protect by aborting), or (b) gate
`SQUAD_MODE=shell` through the same `squad_hub_should_supervise`/
`squad_hub_preflight` check as the other publishing modes earlier in the
session (before the agent runs), so a half-configured hub is caught up front
instead of after a successful push+PR. (b) changes `shell` mode's behavior
more broadly (it would start supervising/preflighting a mode that today
doesn't); (a) is the smaller, more targeted fix.

**Verdict: CHANGES REQUESTED** — blocking on the `shell`-mode half-configured-hub
defect above. Everything else in the diff (regex correctness, device name
formatting including the UTF-8 middle dot, meta JSON shape and truncate
ordering, env wiring and override precedence, token non-leakage, scope
discipline, commit hygiene, and the 131/131 green test run) checks out clean.

## 2026-10-06 — Issue #136 follow-up: half-configured-hub fix for `squad_hub_report_pr`

Re-reviewed the uncommitted fix applied directly to `worker/lib/squad-hub.sh`
and `worker/tests/test_squad_hub.sh` in response to the blocking defect from
the entry above (fix option (a)).

Verified directly:
- `git diff -- worker/lib/squad-hub.sh worker/tests/test_squad_hub.sh` against
  `HEAD` (`6aa9287`) shows `squad_hub_report_pr` no longer calls
  `squad_hub_enabled` at all. It now checks `SQUAD_HUB_URL`/`SQUAD_HUB_TOKEN`
  directly: if either is unset it returns 0 immediately, emitting the new
  one-line `squad_hub_log` skip message only when the OTHER one of the pair
  is set (i.e. only in the genuinely half-configured case), and only falls
  through to the existing feature-detect-and-report logic when both are set.
  This is exactly fix (a) as suggested — no abort path, no exit 78, reachable
  only after a successful push + PR open.
- Confirmed `squad_hub_enabled` itself (lines 217–228) is byte-for-byte
  unchanged, and its only other call site, `worker/entrypoint.sh:594`
  (`declare -f squad_hub_enabled >/dev/null 2>&1 && squad_hub_enabled`, the
  ambient/`prompt`/`new-project` supervision gate), is untouched — grepped
  every reference to `squad_hub_enabled` in `worker/` to confirm this is the
  complete set of callers. The abort-on-half-config semantics for the
  supervision gate are fully intact.
- Ran `bash worker/tests/test_squad_hub.sh` myself: **133 assertions, 0
  failed** (was 131 at the prior review; the two new assertions — "PR
  reporting does not abort the session when only SQUAD_HUB_URL is set" and
  the matching TOKEN-only case — are net additions, confirmed by reading the
  diff rather than just trusting the count: nothing in the existing 131 was
  edited or removed).
- Scope check: `git status --short` shows only `worker/lib/squad-hub.sh` and
  `worker/tests/test_squad_hub.sh` modified in the working tree (plus this
  history file). No unrelated files touched.
- Re-verified the acceptance criterion the fix must not regress — the
  fully-unconfigured case (neither var set) must stay a silent no-op, not
  pick up the new log line. Reproduced directly:
  `env -u SQUAD_HUB_URL -u SQUAD_HUB_TOKEN bash -c 'source worker/lib/squad-hub.sh; squad_hub_report_pr ...'`
  → `RC=0`, empty stdout+stderr. Only the half-configured case (exactly one
  of the two set) hits the new log line; the new outer `[[ -z url || -z
  token ]]` / inner `[[ -n url || -n token ]]` pair correctly distinguishes
  "neither set" (outer true, inner false → silent return 0) from "exactly one
  set" (outer true, inner true → logged return 0) from "both set" (outer
  false → proceeds to report).
- This closes the exact defect flagged: a `shell`-mode session with a
  half-configured hub now completes with a one-line log instead of an exit-78
  abort discovered after a successful push + PR open. No new edge case
  introduced.

**Verdict: APPROVE** — the targeted fix (option a) is correctly scoped,
doesn't touch `squad_hub_enabled` or its supervision-gate call site, the test
suite is green with only additive coverage, and the fully-unconfigured no-op
behavior is preserved alongside the new half-configured skip-with-log path.
## Issue #135 — Squad Hub v0.7.0 workflow_dispatch inputs (model, base_branch, publish_pr, reviewer, watch_only)

Reviewed commit 616c5445 (`Fix #135: validate manual dispatch inputs`), which
adds 5 optional `workflow_dispatch` inputs to `.github/workflows/squad-dispatch.yml`,
a new `worker/lib/dispatch-inputs.js` validation module wired into
`worker/lib/squad-dispatch.js` as a `validate-manual-inputs` subcommand, the
per-execution `OV_*` env overrides passed through ARM REST start, a new test
file (`worker/tests/test_dispatch_inputs.sh`, 42 assertions), and doc updates.

**Checked and confirmed correct:**
- Charset/boolean/model/branch-existence validation logic.
- The `workflow_dispatch` → `resolve` job → `dispatch` job YAML wiring,
  including that omitting an input truly preserves today's default, and that
  the `issues`/`issue_comment` event paths never touch the new validation step
  at all (outputs are simply empty strings for those paths).
- `ralph_build_session_env`'s OV_* merge: confirmed an OV_ override always
  wins regardless of whether its target key is in `RALPH_MANAGED_ENV_KEYS` —
  this was an assumption in the design that needed tracing, not just taking
  on faith, and it holds.
- The `worker/Dockerfile` COPY-list fix: `worker/lib/dispatch-inputs.js` is
  now staged and hardened (`chmod -R a-w`) identically to its sibling
  `worker/lib/dispatch-decision.js`. (This was initially MISSING in the first
  pass — `test_image_layout.sh` caught it immediately via a `MODULE_NOT_FOUND`
  failure; fixed before this review and confirmed green.)
- `SQUAD_GH_BIN` stub usage in the new test file is consistent with existing
  test conventions.

**Found (BLOCKING, now fixed):** the `reviewer` input was validated against
`.squad/casting/registry.json` (Squad persona ids like `engineer`/`docs`/
`lead` — not GitHub identities) but the validated value was passed straight
to `gh pr create --reviewer`, which only accepts a real GitHub login or
`org/team` slug. A validated value would therefore almost always be silently
dropped by `entrypoint.sh`'s existing fallback, defeating the feature while
reporting success. **Fix applied:** `entrypoint.sh` now always records the
requested reviewer id in the pull request body (`Requested reviewer (squad):
<id>`) in addition to attempting `--reviewer`, so the information survives
regardless of whether GitHub accepts the formal request, and docs/actions-
trigger.md now explains the namespace mismatch explicitly.

**Found (ADVISORY, now fixed):** the WIP/draft retry path in `entrypoint.sh`
dropped a valid `--reviewer` permanently on the final fallback even when the
failure was caused by `--draft` being unavailable, not by the reviewer.
Restructured the retry matrix to drop one axis (draft, then reviewer) at a
time instead of both at once.

Re-verified after fixes: `bash worker/tests/test_dispatch_inputs.sh` (42/42),
full `worker/tests/run-tests.sh` compared against a baseline worktree at the
pre-#135 commit (ee61724) — identical 13 pre-existing/environmental failures
plus 1 known-flaky suite (`test_identity_drop_order.sh`, confirmed by
rerunning in isolation 3x with 0 failures each time) and 1 pre-existing
unrelated failure (`test_squad_hub.sh`, reproduced identically on the
baseline worktree). No regression attributable to this change.

Coordinated with `security`'s independent review pass (APPROVE, no blocking
findings — see `.squad/agents/security/history.md`).

**VERDICT: APPROVE** (after the two reviewer-namespace fixes above).

## Issue #135 re-dispatch — merge PR #140 (#136) into squad/soa-135-dispatch-inputs

PR #141 was closed because the branch conflicted with `main` after #136 (PR
#140) landed: both sides rewrote the `CREATE_PR` block in
`worker/entrypoint.sh`'s `commit_and_push_if_needed`. `main` added `pr_url`
capture plus a `squad_hub_report_pr_if_any` call (issue #136) inside the
`timed_out` draft-retry path only; this branch independently rewrote the
same region to add the reviewer + draft retry ladder (issue #135), using
`return 0` on each successful attempt and never assigning `pr_url`.

Reviewed the merge resolution: every `return 0` in the reviewer/draft retry
ladder (both the `timed_out` and non-`timed_out` branches) was replaced with
an assignment into `pr_url` via command substitution (`pr_url="$(...)"`),
preserving the exact same attempt order (draft+reviewer -> regular+reviewer
-> draft without reviewer -> plain fallback for the WIP path; reviewer ->
no-reviewer fallback for the normal path) and the exact same log messages.
Control now always falls through to the single `if [[ -n "$pr_url" ]]`
block after the if/else, which logs the opened PR and calls
`squad_hub_report_pr_if_any "$pr_url" "$pr_number" "$pr_title"` — so the hub
is notified on every successful path of the retry ladder, not only the
first attempt, closing the exact defect the re-dispatch comment flagged.

Confirmed `bash -n worker/entrypoint.sh` passes and no conflict markers
remain. Re-ran `worker/tests/test_dispatch_inputs.sh` (42/42) and
`worker/tests/test_squad_hub.sh` (134/134, including the #136 PR-reporting
assertions) after the merge — both green. Ran the full
`worker/tests/run-tests.sh` suite and compared against a baseline worktree
of `origin/main` (d5abbee): identical 13 pre-existing/environmental failing
suites on both (`test_credentials.sh`, `test_governance_guard.sh`,
`test_memory_audit_pin_hooks.sh`, `test_memory_audit_pin_publication.sh`,
`test_memory_audit_pin_rotation.sh`, `test_memory_audit_pin_seal_defeats.sh`,
`test_push.sh`, `test_security_n1_state_tamper.sh`,
`test_security_n2_sampler_invariant.sh`, `test_security_n3_s1_symlink.sh`,
`test_squad_agent_wrapper.sh`, `test_suite_process_group_containment.sh`,
`test_token_preflight.sh`) — no regression attributable to this merge. Also
ran the `worker-tests.yml` syntax-check step's `node --check` / `bash -n`
commands locally (all pass). The `powershell-validation` job
(`scripts/validate.ps1`, `verify-cli-golden.ps1`) and the
`verify-launch-detachment.ps1` probe need `pwsh`/`dotnet`, neither of which
is available in this sandbox, so they could not be exercised locally; no
code under their scope was touched by this merge.

Coordinated with `security`'s independent review pass on the same merge —
see `.squad/agents/security/history.md`.

**VERDICT: APPROVE.**

## Issue #135 re-dispatch (r4) — fixing PR #142's review findings

Picked up after the content-identical merge of `squad/soa-135-dispatch-inputs-r2`
(see the entry above) and addressed the two must-fix findings plus the nits
from Scout's PR #142 review, all on `squad/soa-135-dispatch-inputs-r4`.

**Must-fix 1 — reviewer retry ladder losing the PR URL.** Root cause:
`gh pr create --reviewer <id>` on github.com can create the pull request,
print its URL to stdout, and still exit 1 when `<id>` is not a real GitHub
login (the normal case, since `SQUAD_PR_REVIEWER` is a squad casting-registry
id). The old ladder read that exit 1 as "no PR yet", retried WITHOUT
`--reviewer`, that retry failed with "a pull request already exists" (empty
stdout), and the empty stdout overwrote `pr_url` — losing it and skipping
`squad_hub_report_pr_if_any` even though a PR was open. Fixed by decoupling
the two concerns completely: `gh pr create` no longer takes `--reviewer` at
all, and once `pr_url` is known, a strictly separate, best-effort
`gh pr edit "$pr_url" --repo "$GITHUB_REPOSITORY" --add-reviewer
"$SQUAD_PR_REVIEWER"` is attempted and only logged (never fatal) on failure.
The requested reviewer is also always recorded in the PR body now, so the
request survives even when GitHub rejects it outright. Added an end-to-end
behavioral test to `worker/tests/test_session_deadline.sh` (new "5h" section)
with a `gh` stub that prints a real PR URL on `pr create` and can be told to
fail `pr edit --add-reviewer` (`GH_FAIL_REVIEWER_EDIT=1`) — asserts the PR
URL is still logged and reported, exactly two `gh` calls are made (no retry
confusion), and the reviewer-add failure is logged non-fatally. Also added
the reviewer-add-succeeds counterpart. Discovered along the way that the
test driver's function-extraction list (`LOG_FN`/`COMMIT_PUSH_FN`/etc.) never
included `squad_hub_report_pr_if_any` itself — harmless before because the
old `gh` stub never printed a URL so `pr_url` was always empty and the call
site was never reached, but it surfaces as "command not found" the moment a
stub returns a URL. Fixed by adding `HUB_REPORT_IF_ANY_FN` to the extraction
and embed lists.

**Must-fix 2 — `model` input has no effect.** Traced the whole pipeline:
workflow_dispatch `model` → `OV_SQUAD_MODEL` (set in the "Start the ACA
session job" step) → `ralph_build_session_env` strips the `OV_` prefix →
plain `SQUAD_MODEL` in the container. Nothing read it. There are two
distinct Copilot invocation paths that both needed wiring: (1) prompt mode in
`worker/entrypoint.sh`, which now validates `SQUAD_MODEL` has no leading `-`
(fails closed via `squad_policy_abort` if it does) and appends
`--model "$SQUAD_MODEL"` to `COPILOT_ARGV`, and exports
`SQUAD_AGENT_MODEL="${SQUAD_MODEL:-}"`; (2) the `squad watch`/`squad loop`
path via `worker/squad-agent` (the `--agent-cmd` wrapper), which now reads
`SQUAD_AGENT_MODEL`, validates the same leading-dash rule (aborts via
`squad_agent_abort`, exit 78, `copilot` never runs), and appends
`--model "$SQUAD_AGENT_MODEL"` to the final `exec copilot` argv. Both
syntax-checked with `bash -n`. `worker/tests/test_squad_agent_wrapper.sh` got
a new "(b2)" section (3 assertions): valid model reaches argv, no model means
no `--model` token, leading-dash model aborts before `copilot` ever runs.

**Nits.** `worker/lib/dispatch-inputs.js`: added `sanitizeForMessage()`
(strips `\r`/`\n` before any raw value is interpolated into an error message
— closes a log/summary line-forging path) and `validateNoLeadingDash()`;
extended `validateBranchShape()` to also reject a leading `-`, any `..`
segment, `@{`, and a `.lock` path segment in `base_branch` (the `@{` check is
currently unreachable in practice since `@` and `{` already fail the
existing charset check first — kept anyway as defense in depth documented
inline, and the test for it asserts the charset message that actually
fires). `.github/workflows/squad-dispatch.yml`'s "Validate workflow_dispatch
inputs" step now also writes rejections to `GITHUB_STEP_SUMMARY` (in addition
to the existing `::error::` annotations), through the same single-line
sanitizer. `docs/actions-trigger.md` updated to match all of the above.
Audited every new comment/string I added across the touched files for
British spellings and fixed the two that slipped in (`defence-in-depth` →
`defense-in-depth` in `worker/squad-agent`, `behaviour` → `behavior` in the
new test_session_deadline.sh comment).

**Testing.** `worker/tests/test_dispatch_inputs.sh`: 55/55 (6 new
assertions for the nits above). `worker/tests/test_squad_agent_wrapper.sh`:
97/97 (6 model-related assertions, 3 pre-existing + 3 new). The full wrapper
suite has ~24 false failures when run directly in THIS sandbox, because this
session is itself a Squad worker container with ambient `SQUAD_POLICY_*`/
`SQUAD_AGENT_*` env vars that `run_wrapper()` does not unset before invoking
the wrapper under test — confirmed pre-existing/environmental by stashing
all changes and re-running (same 24 failures on a clean tree), and confirmed
it is purely environmental by explicitly clearing the ambient vars
(`env -u SQUAD_POLICY_PIN_BASE_BLOB -u SQUAD_POLICY_MCP_CONFIG_SHA256
-u SQUAD_POLICY_PIN_REPO_DIR -u SQUAD_POLICY_PIN_SHA256
-u SQUAD_POLICY_SEALED_DIR -u SQUAD_POLICY_STATE_DIR
-u SQUAD_POLICY_PIN_SEAL_MODE -u SQUAD_AGENT_REPO_DIR
-u SQUAD_AGENT_POLICY_ARGV_JSON`), which gives a clean 97/97 (and the same
trick is needed for a trustworthy read of `test_session_deadline.sh` and any
other suite that execs the wrapper or entrypoint.sh under this sandbox —
worth remembering for anyone else working inside this environment).
`worker/tests/test_session_deadline.sh`: 126/126 with the env-clearing
invocation (the new 5h reviewer-edit scenarios plus the
HUB_REPORT_IF_ANY_FN extraction fix needed to make them pass at all — see
must-fix 1 above). `worker/tests/test_squad_hub.sh`:
134/134, unaffected by the entrypoint.sh changes (the PR-reporting call site
itself didn't move, only what calls into it). Ran the full
`worker/tests/run-tests.sh` with the same ambient vars cleared: 43 passed, 3
failed, 1 skipped — confirmed by stashing all changes and re-running on the
unmodified tree that the same 3 suites fail identically
(`test_suite_process_group_containment.sh`'s mutation-proof assertion and
`test_token_preflight.sh`'s one assertion, both needing sandbox capabilities
— namespaces / network — this container does not have), so none of this
round's changes caused a regression. `bash -n` / `node --check` pass on
every touched file. The `powershell-validation` job's scripts need
`pwsh`/`dotnet`, neither available in this sandbox, so they could not be
exercised locally; no code under their scope was touched this round.

**VERDICT: APPROVE.**
