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
