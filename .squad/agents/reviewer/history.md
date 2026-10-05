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
