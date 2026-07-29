# security History

## 2026-07-28: PR #18 reviewer rejection — teardown correctness and guard integrity (PRD #6 Sprint 3)

Handled the reviewer rejection on PR #18 (`squad/6-s3-provider-abstraction`).
The original author (engineer) was locked out of this revision per the
reviewer-rejection lockout, so this revision was produced independently. The
reviewer's verified findings — zero observable CLI behaviour change holds, and
the issue #13 logs fix survives through the provider — were not re-litigated.
Three blocking findings were fixed.

**B1 — `terminate` reported success for every `az` failure.** The ACA Job
adapter ran `az containerapp job stop ... 1>$null 2>$null` and then set
`AlreadyTerminal = ($LASTEXITCODE -ne 0)` with `Terminated = $true`
unconditionally, so an auth failure, RBAC denial, throttling, wrong
subscription, or network timeout all read as "the execution was already gone" —
and a missing `az` could read a **stale** `$LASTEXITCODE` as a completed stop.
That is unconditional error swallowing, and Sprint 5 cleanup would have built on
it. `terminate` now runs `az` through `Invoke-AzPromptSafe`
(`scripts/lib/aca-logs.ps1`, which already solved the stale/missing-`az`
problem: it captures stdout, stderr and the real exit code, and reports 127 when
`az` cannot be run at all) and classifies the failure **fail-closed** in
`Test-AcaJobExecutionGone`: a real-failure signature wins over a "not found"
reading, `ResourceNotFoundError` (exit 3) and the not-found / already-terminal
messages return `AlreadyTerminal = $true`, and anything unrecognised is a
terminating error. PRD #6 idempotency is preserved; error swallowing is not.

**B2 — the idempotent-terminate checks tested the fake, not the adapter.** The
production adapter's `wait` and `terminate` had zero coverage, which is why B1
shipped. Added `scripts/validate.ps1` section 8b, which drives
`New-AcaJobExecutionProvider` itself against the fake `az` from
`scripts/tests/cli-stub-harness.ps1` (extended with `SQUAD_STUB_STOP_ERR`,
`SQUAD_STUB_EXEC_SEQ`, `SQUAD_STUB_EXEC_STUCK`): normal terminate, terminate on a
gone/already-terminal execution, terminate under an `az login` auth failure,
under RBAC / throttling / network / wrong-subscription / unrecognised failures,
terminate with no `az` on `PATH` after forcing `$LASTEXITCODE` to 0, plus `wait`
advancing `Provisioning -> Running` and timing out on an execution that never
becomes ready.

**B3 — the CI gate could not catch a `stop` output regression.** The `stop`
checks asserted only call count and exit code, so appending `| Out-Null` to the
adapter's cancel call passed while the user lost every byte `az` printed —
the exact class that closed PR #9. `compare-cli-baseline.ps1` did catch it, but
CI ran only `worker/tests/run-tests.sh` and `scripts/validate.ps1`, so the one
real guard was a manual developer tool. Fixed both halves: the `stop` checks now
assert stdout content, and the capture matrix moved into
`scripts/tests/cli-capture-cases.ps1`, shared by `compare-cli-baseline.ps1` and a
new `scripts/tests/verify-cli-golden.ps1` that diffs against goldens committed
under `scripts/tests/golden/cli/`. The `powershell-validation` job now runs the
verify form on every push and PR. Goldens were chosen over a CI-side differential
because comparing to `main` fails permanently once a CLI change is *intended*,
whereas a golden makes an intended change a reviewable diff; a new validate.ps1
section 10 asserts the goldens cover every case, that the `stop` golden records
`az` stdout, and that the workflow really invokes the script.

**Verification.** `scripts/validate.ps1`: **86 -> 101 passed, 0 failed**.
`compare-cli-baseline.ps1 -BaselineRef main`: 19/22 byte-identical, **22/22
identical ignoring PowerShell's error-record line annotation, exit 0** — the
zero-behaviour-change guarantee is intact. Worker suite: **6 suites / 302
assertions (123/11/62/40/23/43), 0 failed, 0 skipped**, unchanged.

**Mutation-tested the new checks.** Re-applying the reviewer's three mutations:
a no-op ACA `terminate` fails 4 adapter checks; `throw "MUTANT wait"` in ACA
`wait` fails both wait checks; `| Out-Null` on the ACA `cancel` az call fails
both new `stop` stdout checks *and* the golden gate (cases 07, 08, 10). All
mutations reverted; tree verified clean.

**Also fixed (reviewer non-blocking).** `squad-aca-provider.ps1` now dot-sources
`aca-logs.ps1` itself, so `logs` and the new `terminate` no longer depend on
`squad-aca.ps1` happening to load line 13 before line 14 — this became mandatory
once `terminate` took a dependency on `Invoke-AzPromptSafe`. `docs/validation.md`
no longer claims the normaliser "ignores one thing only" (it also strips ANSI SGR
sequences, and the golden normaliser additionally folds out host-width-dependent
error decoration). The handle-opacity assertion message no longer claims more
than it tests; `docs/architecture.md` now states plainly that handle opacity is a
convention, not a security boundary.

**Not done, deliberately.** No Sandboxes provider, no `aca` binary usage, no
feature flag — Sprint 5. `terminate` is still not wired to any CLI command, so
`squad-aca stop` keeps its exact pass-through semantics. `worker/lib/*` and
`worker/entrypoint.sh` untouched. `compare-cli-baseline.ps1` was left as a
developer tool rather than promoted to CI, for the reason recorded above.

## Golden gate CI failure: pinned the environment the goldens depend on

**What happened.** I predicted this in the previous entry: *"Goldens verified
only on this machine under pwsh 7; the first CI run is the real proof."* It was.
The gate failed on `windows-latest` in 4 of 22 cases — and it failed correctly.
It caught real non-determinism in its own fixtures, not a CLI regression.

Two classes:

1. **Time zone** (02, 03, 16). The stub `az` fixture returned
   `"startTime": "2026-01-02T03:04:05+00:00"`. `ConvertFrom-Json` turns an
   offset-bearing instant into `Kind=Local`, so `sessions` rendered
   `1/1/2026 10:04:05 PM` on my UTC-4 box and `1/2/2026 3:04:05 AM` on the UTC
   runner. Because `Format-Table -AutoSize` sizes every column to its widest
   cell, that one value re-padded the header and separator rows too.
2. **Optional tool availability** (11-doctor). `squad` is installed here and not
   on the runner, so `doctor` printed `squad ok` vs `squad optional` — and again
   the Status column width rippled through all 12 rows of the table.

**Fix: pin, do not mask.** A mask deletes the value it hides; every masked byte
is a byte the gate can no longer regress on. So each dependency is pinned at its
source in `cli-stub-harness.ps1`:

* *Time zone* — the `exec-show*.json` fixtures now carry an **offset-free**
  `startTime`. That parses as `Kind=Unspecified`, so no local conversion
  happens and every machine renders the identical wall clock. The `Started`
  column is still compared character for character.
* *Culture* — the CLI child process is started with
  `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`. Windows .NET has no per-process
  time-zone or culture override, but it does honour this switch, so dates and
  numbers no longer render in the capture machine's locale. This was not one of
  the two CI failures; it is the same class of hole, found while fixing them.
* *Optional tools* — `squad.cmd` is now stubbed into the harness bin directory
  alongside `az.cmd`/`gh.cmd`, so `doctor` reports it installed everywhere. It
  logs its argv like the other shims, and captures gained a `### SQUAD CALLS`
  section, so a command that starts shelling out to `squad` is a visible diff
  rather than a silent change.

Nothing was regenerated "on CI's values" and no assertion was weakened.

**Documented honestly.** The reviewer previously (correctly) pinged an
inaccurate claim that the normaliser "ignores one thing only". `docs/validation.md`
now has a "What makes a golden portable" section listing the three pins and the
**complete** ten-item list of masks (`<TS>`, `<SCRIPTS>`, `<STUB>`, `<LINE>`,
`<TMP>`, `<HOME>`, `<SHA>`, ANSI SGR, the console-width-truncated error-record
source echo, CRLF→LF), plus a copy-pasteable local CI simulation. The same list
is mirrored in `Get-PortableCapture` and referenced from `verify-cli-golden.ps1`.

**The pins are themselves guarded.** `validate.ps1` section 10 gained three
checks (101 → 104): the stub fixtures carry no UTC offset, the capture child
pins invariant globalization, and `squad` is stubbed onto PATH. Removing a pin
is now a failing check here, not a red CI run days later.

**Verification — under CI-like conditions, not just mine.** I changed the
machine time zone with `tzutil` and stripped `squad` from PATH:

* TZ **UTC**, no `squad`: goldens **22/22, exit 0**.
* TZ **Tokyo Standard Time (UTC+9)**, no `squad`: goldens **22/22, exit 0** and
  `validate.ps1` **104/0**. Time zone restored afterwards.
* Normal environment: `validate.ps1` **104 passed / 0 failed**;
  `verify-cli-golden.ps1` **22/22, exit 0**;
  `compare-cli-baseline.ps1 -BaselineRef main` 19/22 byte-identical, **22/22
  ignoring the error-line annotation, exit 0**.
* Worker suite: **6 suites / 302 assertions (123/11/62/40/23/43), 0 failed,
  0 skipped**.
* Goldens confirmed byte-LF in the worktree, matching
  `.gitattributes` (`scripts/tests/golden/cli/*.txt text eol=lf`).

**Mutation-tested again — the one thing this gate exists to catch.** Re-applied
`| Out-Null` to the ACA `cancel` az call: `verify-cli-golden.ps1` exits **1** on
`07-stop-byexec`, `08-stop-latest`, `10-stop-azfail` (the lost `STUB-STOP-ACK`
line), and `validate.ps1` exits **1** with both `stop` stdout failures. The
normalisation does not mask the PR #9 regression class. Mutation reverted;
`git status --short` clean for `scripts/lib/`.

**Lesson recorded.** Local success proved nothing; the runner was the test. Any
future change to the harness or goldens should be run through the documented
local CI simulation before pushing.


## 2026-08-14: PR #19 reviewer rejection - a launch that does not detach and a redactor that never redacts (PRD #6 Sprint 5)

Assigned as the fixer because the author is locked out of this revision and I
had already fixed the equivalent class of defect on Sprint 3 (PR #18): a
swallowed-error teardown plus tests that could not detect their own defect. Same
class again, different file.

**B1 - the launch command did not detach.** `New-SandboxLaunchCommand` emitted
`prelude && setsid nohup bash -c '...' </dev/null >/dev/null 2>&1 & printf ... ; echo squad-launched`.
In POSIX/bash grammar `&` is a list terminator with *lower* precedence than
`&&`, so it backgrounds the entire AND-list, and the three redirections bind
only to the final simple command. The async subshell therefore inherited the
exec's fd 0/1/2 for the whole worker run. I reproduced the precedence directly:

```
bash -c "true && sleep 4 >/dev/null 2>&1 & echo returned" | cat   -> 4s
bash -c "true;   sleep 4 >/dev/null 2>&1 & echo returned" | cat   -> 0s
```

Against live Azure that means `aca sandbox exec` holds open to its ~120s client
timeout, `create` throws, and its own `catch` calls `terminate` - destroying a
healthy 10-60 minute session two minutes in. Two secondary consequences of the
same mis-scoping: `printf %s running > $StateDir/phase` ran in the foreground
racing a backgrounded `mkdir -p` (on a fresh sandbox the state dir does not
exist yet), and `rm -f done exit-code` became asynchronous relative to the
poller.

Fixed by brace-grouping the launch so the `&` terminates a list containing only
the redirected `setsid`:

```
prelude && { setsid nohup bash -c '...' </dev/null >/dev/null 2>&1 & } \
  && printf %s running > S/phase && echo squad-launched
```

The brace group is a compound command that returns 0 immediately, so the whole
line stays one `&&` chain. The prelude now runs synchronously and *gates* the
launch (a failed `mkdir` means no worker and no `squad-launched`, which the
caller greps for), `phase=running` cannot race an async `mkdir`, and the `rm -f`
is ordered before any poll.

**Why nothing caught it.** `validate.ps1:1476/1481` were pure substring
assertions (`-like "*setsid nohup bash -c *"`, `-like "*</dev/null >/dev/null 2>&1 &*"`).
Both substrings are present in a command whose shell semantics do not detach - I
confirmed both still return `True` against the broken shape. The stub `aca.cmd`
never evaluates the `-c` payload in a shell; it only greps it for
`squad-launched`. No check in the suite could distinguish "detaches" from
"contains the characters of a detach."

**The behavioural test.** New `scripts/tests/verify-launch-detachment.ps1`
generates the command from the *shipping* generator and evaluates it in a real
POSIX shell (native `bash` on Linux, `wsl.exe -d <Distro>` on Windows; Git Bash
is deliberately excluded because it has no `setsid` and would produce a false
FAIL rather than an honest skip). The oracle matters: PowerShell's
native-command pipeline is *not* reliable here - every shape returned ~0.1s. The
reliable oracle is `out=$( <command> )` **inside bash**, because command
substitution reads the pipe until every writer closes it, which is exactly the
condition that holds `aca sandbox exec` open. It asserts the caller returns
inside a 1500ms budget against a 3s worker, that `squad-launched` was printed,
that `phase` is `running` at return and `done` afterwards, and that the exit
code and completion marker land. Exit 0 pass / 1 fail / **77 skip**, mirroring
`worker/tests/lib/deps.sh`. `validate.ps1` gained `Add-Skip`, prints
`Skipped: N` under a heading that says skips are NOT passes, and a byte-for-byte
identity check that the probed command is the shipped one.

**The CI gap I nearly shipped.** `powershell-validation` runs on
`windows-latest`, which has no WSL - so the new check could only ever SKIP
there, reproducing the exact "test that cannot detect its own defect" failure I
was sent to fix. The probe is therefore also wired into the `ubuntu-latest`
`worker-tests` job with exit 77 forced to a job failure, and `validate.ps1`
asserts that wiring exists (both the script reference and the 77-is-a-failure
handling) so it cannot be quietly removed.

**B2 - `Protect-SandboxText` was a no-op for realistic credential lengths.**
`if ([string]$secret.Length -lt 8)` parses as `[string]($secret.Length)` because
member access binds tighter than a cast. PowerShell then coerces the right
operand to the left's type, making it the *lexical* comparison `"40" -lt "8"`,
which is `$true`. Only lengths 8, 9 and 80-99 were ever scrubbed; a 40-char
classic PAT, a 36-char GUID and a 1200-char JWT all passed through verbatim.
`Get-SandboxSafeArgv` still redacted on the argv side so nothing leaked today,
but the documented defence-in-depth against a CLI echoing a secret back in its
own error text was absent - and it backs every thrown error in the file. Fixed
by dropping the cast. The reviewer had replaced the whole function body with
`return [string]$Text` and the suite still reported 140/0, because the function
appeared only at its definition and three call sites and never in a test.

**Mutation results - four mutations, four kills.**

| Mutation | Result |
| --- | --- |
| Restore the mis-scoped `&` | 149/1 - `ELAPSED_MS=3013` against a 3s worker, `phase` not `running` at return |
| `Protect-SandboxText` body -> `return [string]$Text` | 147/3 - leaked at 27, 36, 40, 64, 93, 1200 |
| Reinstate only the `[string]` cast | 147/3 - leaked at 27, 36, 40, 64, 1200 but **not 93**, pinning the 80-99 lexical window exactly |
| `cancel` back to the `Write-Host` swallow | 146/3 |

**Skip honesty proved, not assumed.** Pointing the probe at a nonexistent distro
gave 146 passed / 0 failed / **1 skipped**, exit 0, with the skip listed under
"Skipped (NOT passes -- the dependency was missing)". Three checks dropped out
rather than silently passing.

**Non-blocking items, all genuine, all fixed.** `cancel` classified failures the
way `terminate` was hardened on Sprint 3 - same `Test-SandboxGone` /
`Test-SandboxTransportInconclusive` mechanism, no second invention - instead of
`Write-Host`-ing a non-zero exit and returning success. `validate.ps1` no longer
prints the raw token-bearing launch argv on failure. `cli-capture-cases.ps1`
gained an `### ACA CALLS` section so the harness comment about the `aca` shim is
true; goldens were regenerated deliberately and the diff is exactly one added
line per file with nothing under it - the emptiness *is* the flag-off guarantee.
The overstated commit claim that the route gate "acts on the Sprint 2 capability
decision" was corrected in docs only: all six `New-SessionExecutionProvider`
call sites still omit `-CapabilityResolution`, so the sandbox branch is
unreachable from the CLI even with the flag on. Wiring it is Sprint 6+; I did
not wire it.

**Verification.** `validate.ps1` 140 -> **150 passed / 0 failed / 0 skipped**;
`verify-cli-golden.ps1` **22/22, exit 0**; `compare-cli-baseline.ps1
-BaselineRef main` 19/22 byte-identical, **22/22 ignoring error line numbers,
exit 0**; worker suite **6 suites / 302 assertions (123/11/62/40/23/43), 0
failed, 0 skipped**; the probe's native-`bash` branch - the path CI takes -
executed end to end and passed, not just the Windows/WSL branch.

**Lesson recorded.** Both defects were assertions that matched the *shape* of a
guarantee rather than the guarantee. A substring of a detach is not a detach,
and a redactor with no test is a comment. Where a check needs a dependency, it
must run where the dependency exists and skip loudly where it does not.

## 2026-08-21: PR #20 reviewer rejection - two dispatchers both told "you own it", an unbounded ledger, and a fourth invisible recurrence of the deny-list defect (PRD #6 Sprint 6)

**The author was locked out; I fixed all three blocking findings plus four
non-blocking ones in `worker/lib/dispatch-lease.js` and its two shims.**

**B1 - concurrent claims both won.** `decideExistingClaim` adopted any `claimed`
lease unconditionally, on the assumption that a claim in flight is a crashed
one. It is not. The claim-to-compute window in `ralph-dispatch.sh` spans
`mktemp`, an env build that shells to `node` and `az`, and the job start -
seconds - and Ralph's five-minute cron overlaps a manual `squad-aca ralph run`
by design. Two dispatchers therefore got `created` and `repaired`, both of which
mean "dispatch", for one issue.

The fix is two TTLs, not one. A `claimed` lease and a `running` lease have
nothing in common except a record: a claim only has to cover one env build
(`SQUAD_LEASE_CLAIM_TTL_SECONDS`, 300s, clamped to never exceed the session
TTL), while an execution has to cover a whole agent session (3600s, refreshed by
the heartbeat). `STATE_CLAIMED` now takes the same staleness gate `ACTIVE_STATES`
always had, against the clock that matches what a claim is allowed to be doing.
Adoption also moved behind a single `adoptLease` helper that catches the CAS
`409` and re-reads: if two claimers both decide a lease is abandoned, the store
decides the winner and the loser is told `active`, not handed a second "you own
it". A losing claimer gets the owner's record back so it can say who holds the
work.

The knock-on mattered more than the gate. Ralph labelled the issue on `active`.
With `active` now also meaning "another dispatcher is mid-claim", labelling
would retire an issue whose would-be owner may still fail and `release` -
silently dropping the work. Ralph now reads the owner's state alongside the
outcome and skips *without* labelling when the owner is still `claimed`. One
extra evaluation next run beats losing the work.

**B2 - the ledger only ever grew and the sweeper read every key.** There was no
delete path at all; every `run`, `smoke`, `telemetry smoke` and Ralph issue
minted a permanent blob, and Ralph swept 288 times a day at `1 + N` calls.
The severity came from the error handling being *correct*: a 429 surfaces,
`claimLease` throws, and Ralph skips every issue - a total outage with no
operator-visible cause. Bounded on both axes: terminal leases past
`SQUAD_LEASE_RETENTION_SECONDS` (7d) are deleted via the Contents API, and a
sweep costs at most `1 + SQUAD_LEASE_SWEEP_MAX_READS` (50) calls regardless of
ledger size. Coverage under the cap comes from a start offset derived from the
clock rather than a persisted cursor - zero extra API calls, no blob of its own
to corrupt or contend on. The 1000-entry listing cap is now reported as
`truncated` and logged by both shims instead of silently short-changing the
sweep.

**B3 - the documented ordering was untestable, and this is the fourth
recurrence.** Sprint 3 B1, Sprint 5 `cancel`, and now here. The implementation
was correct; the tests could not tell. None of the four fail-mode texts carried
a `GONE_PATTERNS` token, so the deny-list was never the deciding factor and the
reviewer's swap of the two loops passed 163 checks and 361 assertions unchanged.

The root cause is that `isGone` is not observable enough to guard an ordering:
whenever a message matches only one list, both orderings produce the same
boolean, so no assertion on the boolean can ever fail. `classifyGhFailure` now
returns *which rule decided* (`real-failure`/`gone`/`unrecognised`/...), and the
tests assert that. The fake `gh` gained four fail modes whose text carries BOTH
signatures - `masked403`, `masked401`, `masked429`, `masked500`, modelled on the
real shape, since GitHub masks a permission denial on a private resource as
`HTTP 404: Not Found` - plus `unrecognised`, which matches neither. The
previously-documented-but-never-used `FAKE_GH_FAIL_PATH` knob is now exercised,
scoping a masked 403 to one blob so the directory listing still succeeds.

I did not consolidate the JS and PowerShell classifiers. They are separate
because they classify different tools (`gh` vs `az`) with different message
shapes, and unifying them would mean shelling to node for every PowerShell
classification. What I consolidated instead is the *decision*: one function in
JS, and both languages now assert the deciding rule rather than the answer.

**Non-blocking items 4-7, all genuine, all fixed.** The vacuous
`write_idx <= last_idx` assertion (a `grep -n` line number compared against
itself) was replaced with two falsifiable ones: GET-before-PUT, and the lease
write being the last call of the claim. `Invoke-Leases` lost its bare
`Format-Table -AutoSize`; the validate check I added for it also caught `doctor`
carrying the same defect on a `Detail` column that holds an Aspire URL, so that
was fixed too and its golden regenerated - one blank line, reviewed. The
worker's heartbeat fired once and then not again, so any session outliving the
one-hour TTL was swept as stale mid-flight and its lease became re-claimable
while the execution was live; it is now a background ticker torn down by the
EXIT trap before the terminal write. The `dispatched` writes in the CLI and
Watch moved inside their own try: once compute is live, a transient 429 must
neither throw to the user (whose retry would be told `repaired` and start a
second execution) nor release (which would hand live work away). All three
dispatchers now warn and let the heartbeat reconcile.

**Verification.** `validate.ps1` 163 -> **173 passed / 0 failed / 0 skipped**;
worker suite **7 suites / 361 -> 409 assertions (123/76/11/62/40/54/43), 0
failed, 0 skipped**; `verify-cli-golden.ps1` **22/22** with `### ACA CALLS`
empty in all 22; `verify-launch-detachment.ps1` **PASS**. Each fix was
mutation-proven: removing the claim gate failed 6 contract + 4 Ralph assertions
and 2 validate checks; restoring unbounded growth and cost failed 5 contract
assertions and 2 validate checks; swapping the two classification loops - the
mutation that was previously invisible to the entire suite - failed 15 contract
assertions and 1 validate check.

**Lesson recorded.** The recurring defect is not the ordering; it is asserting
an *outcome* where the guarantee is a *precedence*. A precedence is only
observable on an input that satisfies both branches, and no fixture in this
programme had ever supplied one. Where code chooses between rules, the choice
itself has to be part of the return value, or the choice cannot be tested. The
same applies to B1: converging on one lease record was asserted, but "and
exactly one of them is told to dispatch" never was, and the one test that
should have covered it had a line inserted in the middle of the race.