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
## PRD #6 Sprints 7 and 8: least-privilege credentials, enforced egress, and bounded blast radius

**The thing that changed.** Credential brokerage turned out to be a *platform
primitive*, not something to build. `aca sandboxgroup credential create --type
github-copilot` takes the token on **stdin** and returns an opaque id;
`aca sandbox create --credential <id>` (repeatable) references it. So Sprint 5's
admitted limitation - worker credentials riding in the launch command's argv -
is closed by using what the platform already has rather than inventing a
mechanism. On Linux an argv is world-readable at `/proc/<pid>/cmdline` for the
life of the process, so "we redact it in our logs" was never sufficient.

`Invoke-CliSafe` cannot write to a child's stdin (it uses `& $exe @args 2>&1`),
so `scripts/lib/aca-logs.ps1` gained `Invoke-CliSafeWithStdin`. Draining stdout
and stderr concurrently with `ReadToEndAsync()` matters: the obvious
`Register-ObjectEvent` + `BeginOutputReadLine` version returned empty streams,
and the naive sequential read deadlocks on a full pipe.

**No native type exists for a plain git/`gh` push token.** I am not going to
call that "brokered". That plane is written to the **stdin** of a staging
`aca sandbox exec` into a `umask 077` file that the launch command sources and
then deletes, so its on-disk lifetime is the gap between two execs. It is in no
argument vector on either side of the boundary, but it is a Squad mechanism, not
a platform one. **Caveat, stated plainly: stdin on `aca sandbox exec` is
assumed, not live-verified.** Only the `credential create` stdin path was
verified against a real subscription. If `exec` turns out not to accept stdin,
this plane needs rework; the Copilot plane does not.

**The classic-token footgun is real and it is ours.** `--type github-copilot`
accepts only `github_pat_`; `gh auth token` returns a classic `ghp_`; and
`scripts/deploy.ps1` defaults `-CopilotGitHubToken` to the **same value** as
`-GitHubToken`. So the single most likely input is exactly the one the platform
rejects, *and* the two planes were already one token. Rejected locally, before
any CLI call, with a message that names `deploy.ps1` specifically - discovering
it from a service round trip means the token has already crossed the wire and
been written to someone else's log. `deploy.ps1` now warns when it collapses the
planes; the default is retained so existing ACA Jobs deployments keep working.

**Egress narrowing is enforced at the point of policy generation.** Sprint 2
enforces it in the resolver, but the resolver is a different process boundary,
and enforcing a rule in exactly one place means it holds only as long as nobody
builds a policy by another route - and this provider *is* another route. Every
emitted pattern and action is copied from the approved class template; a
requested host the template does not cover is a hard failure before anything is
created or billed; and a **provenance assertion** proves every emitted rule
exists verbatim in the template rather than asserting it in a comment. Hostile
manifest text cannot reach the policy even in a rejected build, because the
emitted set is a subset of the template by construction.

**Bounded blast radius.** A per-class concurrency ceiling (a class with no
`limits.maxConcurrentSandboxes` is a *configuration error*, never "unlimited"),
auto-suspend pinned deliberately rather than left at the 600 s default that
would suspend a live session, and a label-based reaper that dry-runs by default,
never touches a sandbox that is not `squad-*`, and never deletes one whose age
it cannot establish. A seven-value failure taxonomy (`auth`, `capability`,
`quota`, `readiness`, `execution`, `transport`, `config`) is tagged into the
message. Quota is classified **before** auth on purpose: several services return
403 for a quota refusal, and reading "you have hit your ceiling" as "your
credentials are bad" sends an operator to rotate a perfectly good token.

**Credential lifecycle.** Brokered credentials live on the **group** and inherit
group RBAC (risk R2), so they outlive the sandbox that used them. They are
revoked on `terminate` *and* `cancel`, on a `create` that fails after brokering,
and a revocation that fails is reported as still-live rather than swallowed.
`credential list`/`show` and `egress show`/`export` are refused at the argv gate
outright - a value this process never holds cannot be logged, cannot land in a
captured golden, and cannot be echoed by an error path nobody audited.
`egress decisions` stays allowed; it is the audit trail, not the policy.

**Behavioural tests, per the standard this programme now holds.**
`verify-launch-detachment.ps1` was extended rather than duplicated: it now runs
the shipping staging command with a throwaway token on stdin in a real shell and
asserts the file is `0600` *at creation*, the value reaches the worker
**verbatim**, the file is **gone** after the launch, and the token is in neither
command string. That distinguishes "not in the argv because it is on stdin" from
"not in the argv because it is not delivered at all" - which a pure absence
assertion cannot do, and which is exactly the failure mode Sprint 5 shipped.

**Mutation results - 14 mutations, 12 kills, 2 honest survivors.**

| Mutation | Result |
| --- | --- |
| M1 credential token moved into argv instead of stdin | killed - 6 checks incl. "Sandbox create did not issue the expected aca sequence" |
| M2 classic `ghp_`/`gho_`/`ghs_` rejection removed | killed - "The classic-token guard is wrong (bad=ghp_ gave a non-actionable message ...)" |
| M3 egress accepts an uncovered requested host | killed - "Egress widening was not refused at generation time (creates=1)" + hostile-manifest check |
| M4 concurrency ceiling not enforced | killed - "The concurrency ceiling did not hold" + "A class with no ceiling was treated as unlimited" |
| M5 terminate stops revoking brokered credentials | killed - 3 checks incl. "terminate did not revoke the brokered credential" |
| M6 quota classified after auth | killed - "Failure classification is wrong: 'ERROR: QuotaExceeded...' -> execution" |
| M7 leading-dash (argument injection) check removed | killed - "The argument-injection diagnosis was lost" |
| M7b per-kind allowlist weakened to `.*` | killed - "Identifier validation gaps: accepted: path traversal; embedded traversal; shell metacharacters; command substitution; pipe" |
| M8 launch command re-injects `GH_TOKEN` | killed - "A secret env name was accepted into the launch command" |
| M9 credential/egress readback no longer refused | killed - "Readback refusal is wrong (allowed=... credential list; ... egress show ...)" |
| M10 reaper deletes sandboxes of undecidable age | killed - 3 checks incl. "The reaper deleted a kept session (deleted=squad-unknown-age)" |
| M11 manifest text emitted as an egress rule | killed by the **provenance assertion** - "a generated rule is not present in the approved class template" |
| M12 provenance assertion alone removed | **SURVIVED** |
| M12b provenance assertion *and* rule construction both broken | killed - "argv=... --rule api.github.com:Allow --rule *.github.com:Allow" |

The two survivors, honestly: **M7 originally survived** because the leading-dash
check is redundant with the per-kind allowlist (`-identity` fails both). Rather
than claim a control that no test could distinguish, I added a check that pins
the *diagnosis* - an operator told "not a well-formed label" hunts for a typo,
one told "a CLI parses this as a flag" hunts for where the value came from - and
M7 now dies. **M12 still survives and that is correct**: the provenance
assertion is a backstop that is unreachable while the code above it is right, so
nothing can violate it in isolation. M12b shows the pair is caught. I could have
manufactured a test that reached in and broke provenance artificially; that
would have been a test of the test.

**Not testable offline, stated rather than glossed:** real TLS interception
behaviour under `trafficInspection: Full` (R3); real quota exhaustion from the
service (only the *classification* of its message is tested); real credential
revocation semantics and whether a revoked id is immediately rejected; whether
group RBAC actually exposes credential values to a reader (R2 is taken from the
ADR's live verification, not re-verified here); and stdin acceptance by
`aca sandbox exec`, as above. Also **not done, deliberately**: Ralph/Watch
dispatch wiring is Sprint 6 on a separate branch, and all six
`New-SessionExecutionProvider` call sites still omit `-CapabilityResolution`, so
the sandbox route remains unreachable from the CLI even with the flag on.

**Interlocks unchanged.** ACA Jobs remain the unconditional default;
`SQUAD_ACA_ENABLE_SANDBOX` stays default-off; `config/sandbox-classes.json`
stays `"provisional": true` so the route fails closed even with the flag on.
Both interlocks, credential revocation, orphan reaping and immediate rollback
are now a documented, ordered procedure in `docs/rollback.md` (a new section 2),
with an incident runbook for R1/R2/R3/R7 in `docs/runbook.md`.

**Verification.** `validate.ps1` 150 -> **177 passed / 0 failed / 0 skipped** (+27 new checks);
`verify-cli-golden.ps1` **22/22, exit 0**; `verify-launch-detachment.ps1`
**PASS** (`ELAPSED_MS=3`, `CREDMODE=600`, token verbatim, `CREDFILE_AFTER=absent`);
`compare-cli-baseline.ps1 -BaselineRef main` **22/22 ignoring error line
numbers, exit 0** - **no goldens were changed**; worker suite **6 suites / 302
assertions (123/11/62/40/23/43), 0 failed, 0 skipped**.

**Lesson recorded.** The strongest control here is the one I did not write: the
platform already had credential brokerage, and the right move was to find it
rather than to build a bespoke mechanism and defend it. The second lesson is
that a surviving mutation is information, not an embarrassment - M12 survives
because it guards a state the code cannot reach, and saying so is worth more
than a test engineered to kill it.

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

## Issue #26: tool approval parity - `--yolo` removed from both planes, and the honest boundary around what a flag can enforce

**The defect.** `worker/entrypoint.sh` ran every session with `--yolo` on an
image that also set `COPILOT_ALLOW_ALL=true`, and `deploy.ps1` injected the same
flag string through the job template. `--yolo` is `--allow-all-tools
--allow-all-paths --allow-all-urls`, so a remote session could write anywhere on
the filesystem while the same agent on a developer's machine was confined to its
working directory. Remote execution applied *weaker* policy than local - the
escalation PRD #6 explicitly forbids - and none of the eight sprints had touched
it. It affected both planes, so "the sandbox is isolated" was never an answer.

**The investigation came before the design, and changed it.** The pinned
`@github/copilot@1.0.69-2` was installed into a scratch tree and interrogated
directly rather than trusted: `--deny-tool` accepts two-word subcommand patterns
and denials outrank `--allow-all-tools`; a real probe confirmed `shell(git
config)` is refused with *"Permission to run this tool was denied due to the
following rules"*; a write outside the working directory is refused once
`--allow-all-paths` is gone; `--allow-all-urls` turned out to gate neither the
shell tool nor web-fetch, so it is simply not passed. The finding that mattered
was negative: there is **no `--deny-path`**, and `write` is all-or-nothing. A
control paper had assumed "restrict writes to `.squad/policies` via flags" would
be possible. It is not expressible at all, so governance had to move to the
filesystem or be decoration.

The second constraint was found the same way: `@bradygaster/squad-cli@0.11.0`
splits `--copilot-flags` with `.trim().split(/\s+/)` in nine `dist/` modules, so
a multi-word deny pattern cannot survive `squad watch` / `squad loop`. Rather
than quietly emit a weaker set on that path, the resolver publishes two surfaces
and the session log names every rule the handoff cannot carry. That gap belongs
to the Squad runtime and is written down as such.

**What was built.** One pure resolver (`worker/lib/agent-policy.js`) decides a
tier from `SQUAD_MODE` + `SQUAD_DISPATCH_SOURCE`; one bash layer
(`worker/lib/squad-policy.sh`) applies it. Both planes reach both through the
single entrypoint, so parity is structural rather than asserted. Unattended runs
lose the irreversible infrastructure verbs outright rather than being
approval-gated, because Ralph is a five-minute cron and there is nobody to
approve anything. Governance paths are made read-only *and* fingerprinted into a
0700 directory outside the checkout, re-verified before the push and at the end
of every agent-running mode; every failure path exits 78 and nothing is pushed.

**Two things I had to correct in my own work.** The resolver originally treated
an absent `SQUAD_DISPATCH_SOURCE` as attended - fail-open, and exactly the shape
this change exists to remove; it is now autonomous, which in turn exposed that
`New-SandboxWorkerEnvironment` never carried the dispatch source at all, so a
Ralph-dispatched sandbox session would have resolved to the *attended* tier while
the identical ACA Jobs session resolved to *autonomous*. That is escalation by
choosing a substrate, sitting in the repository the whole time, and the parity
check that found it drives the real env builders rather than hand-written maps.

**The mutation that failed to be detected, kept in the report.** Removing the
manifest's `absent` markers changed nothing: the baseline-vs-current diff already
detects a path appearing or disappearing. My own comment had claimed otherwise.
The claim was wrong, so the comment was corrected and the markers reclassified as
manifest completeness rather than a control - an undetectable "control" is a
liability, and the honest move was to stop calling it one instead of inventing an
assertion to protect it.

**Verification.** `validate.ps1` 213 -> **240 passed / 0 failed / 0 skipped**;
worker suite **7 -> 9 suites, 426 -> 623 assertions, 0 failed / 0 skipped**;
`verify-cli-golden.ps1` 22/22 and `compare-cli-baseline.ps1` byte-identical
22/22 - **no golden changed**; `verify-launch-detachment.ps1` PASS. Sixteen
mutations were run; fifteen produced a specific named failure and the sixteenth
is reported above as undetected with the reason.

**Lesson recorded.** Investigate the enforcement point before designing the
control. Two of the three shapes the issue proposed were unimplementable as
written, and only reading the pinned binary's own help - and then running it -
revealed which. The related habit: when a mutation you expected to be caught
isn't, the first hypothesis should be that the control does less than its comment
claims, not that the test is weak.

## Issue #26 follow-up: narrowing the governance lock so an agent can still record what it did

**What I flagged, and what the owner decided.** Locking `.squad/agents` wholesale
meant an autonomous ACA run could no longer append to
`.squad/agents/<name>/history.md`. I surfaced that as a deliberate behaviour
change rather than quietly exempting it. The owner's decision: narrow the lock.
The reasoning is worth keeping, because the exception will look like an oversight
to whoever reads it next. `history.md` is an **append-only work log**, not
policy. It records what an agent *did*; it grants an agent nothing. Locking it
prevents **no** privilege escalation - it only destroys the audit trail PRD #6
asks for, on exactly the unattended paths (Ralph, Watch) where nobody else is
around to write the record. A charter is the opposite: it states what an agent is
*permitted to do*. That distinction - *log of what happened* versus *statement of
what is allowed* - is where the boundary now sits.

**What is excluded.** Exactly `^\.squad/agents/[^/]+/history\.md$`, anchored at
both ends. Not `.squad/agents/**`. `charter.md` beside it,
`.squad/agents/history.md`, `a/b/history.md` and `history.md.bak` all stay
locked, and each of those is a named assertion rather than a claim.

**The part I nearly got wrong: the directory.** `history.md` sits inside a
directory whose other contents are locked, so the real question was not "can the
run append?" but "does unlocking the file unlock the directory?". It must not, or
"history is writable" becomes "the agents directory is writable" and an agent can
add or delete files beside a charter it cannot edit. The answer is ordering, not
exclusion: hardening runs `chmod -R a-w` over `.squad/agents` **first** and only
then restores `u+w` on the matching files. `chmod` on a file needs ownership, not
write on its parent, so the file opens and the directory does not. Expressing it
the other way round - excluding the path from the recursive `chmod` - could not
have produced that shape, because the directory would have had to be writable for
the file to be creatable. Create, delete, new-agent-directory and charter-write
are each asserted against a real hardened filesystem.

**The detector: I did not drop history from the manifest.** A path excluded from
both the lock and the integrity check is a foothold. History stays in the
baseline under a different rule - `append-only <path> <sha256> <bytes>` instead of
`file <path> <sha256>` - and verification re-hashes the first `<bytes>` bytes. An
append passes and is **reported with its byte delta**; a truncation, a rewrite
(even a longer one, which a size-only check would wave through), a deletion, or a
history file that did not exist at hardening time all fail the session at 78.

**I chose to add the append-only check rather than call it over-engineering.**
The argument for skipping it is that a work log is low-value. The argument
against - which won - is that the *stated reason* for unlocking the file is that
it is the audit trail, and an audit trail an agent can rewrite is not one; the
exclusion would otherwise have bought an attacker a silent, freely writable file
inside the governance tree. It costs one `head -c | sha256sum` per file, and it is
directly testable, which is the bar. The committed form gets the same check, so
an agent cannot commit a truncated history and hide it by restoring the working
tree. What I did **not** add is any validation of *what* gets appended: that needs
a schema this log does not have, and a control that only appears to check is
worse than none.

**Accepted consequence, documented rather than hidden.** A `history.md` that did
not exist when the session started cannot be created by the run - that is a new
governance file. Three agents in this repository (`devrel`, `lead`, `reviewer`)
have no history file; theirs must be seeded in the PR that adds them.

**Mutation.** Widening the pattern to `^\.squad/agents/.+$` failed 9 governance-
guard assertions, 5 agent-policy assertions and 2 validate checks. The one that
matters names the real defect behaviourally: *"an autonomous run CANNOT write
.squad/agents/<name>/charter.md - a charter is what an agent is permitted to do
(expected: 'original ...', actual: 'TAMPERED')"* - a real write to a real charter
on a real hardened filesystem, not a grep.

**Verification.** `validate.ps1` 240 -> **247 passed / 0 failed / 0 skipped**;
worker suite **9 suites, 623 -> 668 assertions, 0 failed / 0 skipped**
(governance guard 70 -> 104, agent policy 127 -> 138); `verify-cli-golden.ps1`
22/22 and `compare-cli-baseline.ps1` byte-identical 22/22 - **no golden
changed**; `verify-launch-detachment.ps1` PASS. Tier resolution, exit-78
fail-closed behaviour, the blanket-allow rejection, the `SQUAD_DISPATCH_SOURCE`
parity fix and the baseline-outside-checkout abort are all untouched.

**Lesson recorded.** "Lock the governance directory" was the right instinct and
the wrong granularity. The useful question is not *is this path under governance?*
but *does writing here change what the agent is allowed to do, or only the record
of what it did?* - and when the answer is the second, locking it costs
auditability and buys nothing. The follow-on discipline: an exception to a
security control must be narrower than the control, must stay inside the
detective layer, and must be documented with its reasoning, or the next reader
will "fix" it back.
## Issue #36 - the sandbox cancel that could not fail

**The defect.** The sandbox provider's `cancel` emitted
`pkill -f <entrypoint> >/dev/null 2>&1; ...; echo squad-cancelled`. `procps` is
not in the pinned class image, so `pkill` exited **127** into a discarded
stderr, and the chain's exit status was the trailing `echo`'s - which cannot
fail. The provider read exit 0 and returned `Cancelled = $true`. Measured live:
the cancel landed at 12:56:02, the worker ran a further **51 seconds**,
completed normally at 12:56:53, and **overwrote** the `cancelled`/`143` markers
with its own `done`/`0`. Fourth instance in this programme of one defect class:
a control that fails open and cannot detect its own failure.

**The mechanism chosen.** `kill` is a shell **builtin**, so it needs no
`procps`; `setsid` at launch makes the worker a session leader, so its pgid
equals its pid and one `kill -TERM -<pid>` reaches the wrapper, the entrypoint
and any Copilot child. The launch now records the worker's own pid (`printf %s
$$` as the wrapper's first act - not `$!` from the parent, because `setsid(1)`
forks only conditionally). The cancel reads it, refuses pids below 2, checks
`/proc/<pid>/cmdline` still holds the entrypoint (pid-reuse guard), signals the
group, escalates `TERM` -> `KILL` on a bounded budget, and confirms death by
scanning `/proc` for any **non-zombie** process left in the group. The
`cancelled`/`143` markers are written **only after** confirmed death, which is
what closes the race that let the worker overwrite them. The script prints
`squad-cancel-status=<token>`; the provider believes the **token**, not the exit
code, and treats a missing token with exit 0 as a **failure**. Everything else -
`Test-SandboxGone`, `Get-SandboxFailureClassification`, `Get-SandboxFailureKind`
and the deny-list-first ordering - was left untouched; the Sprint 5 path still
runs verbatim when the transport itself fails.

**A pre-existing sandbox has no pid file.** It reports `no-pidfile`, a **failed**
cancel, and the message names `aca sandbox delete -l name=<name> --yes` as the
control-plane escape hatch. Reporting success there would have been the same lie
in a new place.

**The second defect, found only by running it for real.** The first fix passed a
14-case behavioural probe and every gate - and then failed live, reporting
`squad-cancel-status=already-dead` while `/proc` showed the worker and both its
children alive. Root cause: `aca sandbox exec` runs the command under `/bin/sh`,
which is **dash** on this image. `$(< file)` is a **bashism that expands to the
empty string under dash** - no error, no exit code. The scan read nothing, and
"nothing" was being read as "the worker is gone". The probe had not caught it
because the probe ran the emitted command under **bash**. Three consequences,
all shipped: the command is strict POSIX `sh` (checked with `dash -n` and
`bash -n`, and statically screened for bashisms by a new `validate.ps1` section
6e); the probe now evaluates it via `sh -c`; and the scan is **fail-closed** -
reading not one `/proc` entry is `scan-failed`, never `already-dead`, and the
script self-tests by reading its own `/proc/self/stat` with the same builtin
before it believes any "not found".

**Live proof.** Fresh sandbox from disk `02560016-...`. Worker pid 34 with child
36. `squad-cancel-status=killed`; inside the guest afterwards the pid file was
gone, `phase=cancelled`, `exit-code=143`, `CHILD_PROC=GONE`, and the process
table held only `tini`, the image's idle `sleep` and the query's own `sh`. Still
`cancelled`/`143` twenty seconds later. A second cancel returned
`already-terminal` without rewriting anything. Timed inside the guest to remove
the control-plane round trip: **11 ms** from cancel to confirmed death, against
51 seconds of continued execution before. Both sandboxes created were deleted
with `--yes` and the group listed afterwards: empty.

**Mutation.** 14 mutations, **14 caught**. Six deserve naming. Using `pkill`
instead of the builtin -> the probe's C1/C2 (no kill under a procps-free PATH).
Signalling the leader instead of the group -> caught only by **elapsed time**:
the child is a plain `sleep`, so it dies on the first TERM if and only if the
signal went to the group; otherwise the whole 10 s grace is burned before the
SIGKILL sweeps it up. That mutant survived the first harness run and the
assertion was added for it. Removing the verification step -> C8 (`survived`).
Writing the markers unconditionally -> C3/C4/C5/C8. Removing the fail-closed
empty-scan branch -> C13. Reverting one `/proc` read to `$(< ... )` -> C1/C2
under dash. On the PowerShell side: adding a failure token to the success
allow-list, `Succeeded = $true`, and believing exit 0 with no verdict (the
original #36 shape) are each caught by `validate.ps1` section 6c.

**Verification.** `validate.ps1` 307 -> **315 passed / 0 failed / 0 skipped**;
`verify-cli-golden.ps1` **26/26 byte-identical, no golden changed**;
`verify-launch-detachment.ps1` **PASS**; new
`scripts/tests/verify-sandbox-cancel.ps1` **PASS, 14 cases under dash**; worker
suite **10 suites / 739 assertions**, 0 failed; .NET **114** (47 + 67);
`Squad.Aca.Agents` still has zero package references.

**Lesson recorded.** A test that substring-matches an emitted command proves the
characters of a kill, not a kill - that is what shipped #36. But the sharper
lesson is the second one: a behavioural test that runs the command **in the
wrong shell** is the same failure wearing a better disguise, and it is more
dangerous because it looks like evidence. Run the artefact you ship, in the
interpreter production actually uses, against a real process - and when a probe
reads nothing, make "nothing" a refusal rather than a verdict.

## Issue #40 - the probe that ran in the wrong shell

**The gap, not a bug.** `aca sandbox exec` hands its `-c` payload to `/bin/sh`,
which on the pinned class image is **dash**. Confirmed independently on a fresh
sandbox: `SHELL=/bin/sh`, `$(< /tmp/t)` returned `[]` with no error and no exit
code, while `$(cat /tmp/t)` returned `[hello]`. That silent empty is what shipped
the broken cancel in #36 - the `/proc` scan read nothing and "nothing" was read
as "the worker is gone".

The #36 fix closed that for **cancel** only: `verify-sandbox-cancel.ps1` runs the
emitted command through `sh -c`, the script is checked with `dash -n` as well as
`bash -n`, and a static bashism screen was added. Launch, poll and the
credential seed got none of it, and `verify-launch-detachment.ps1` still
evaluated the launch under **bash**. There was no live defect. That is the point:
a probe that evaluates real behaviour in the wrong interpreter can be green while
production fails, and a green gate that looks meaningful is worse than a missing
one.

**Headline: no shipping command contained a bashism.** Every emitted command was
screened and every one came back clean. Nothing was fixed because nothing was
broken. The change is entirely in what the gates can see.

**What the provider actually emits.** Found by reading
`scripts/lib/providers/squad-sandbox-provider.ps1`, not by trusting a list. Five
generators - `New-SandboxLaunchCommand`, `New-SandboxCancelCommand`,
`New-SandboxPollCommand`, `New-SandboxCredentialVaultCommand`,
`New-SandboxCredentialFileContent` - plus **two** the brief did not mention. The
`logs` operation built its `tail` command as an inline literal at the call site,
so no screen could reach it; it was extracted verbatim into
`New-SandboxLogsCommand` and `validate.ps1` now asserts the emitted text is
byte-identical, so the extraction cannot have changed behaviour. And the launch's
detached wrapper is a `bash -c '...'` payload single-quoted **inside** the launch:
neither `dash -n` nor `bash -n` parses it when parsing the launch, so the
detachment probe recovers it by regex and checks it as its own command
(`launch-inner`). Seven commands covered, not four.

**One inventory, two consumers.** `scripts/lib/squad-shell-portability.ps1` holds
the screen and builds the inventory by calling the **shipping generators**, so it
can never describe a command that is not the one that ships. Both `validate.ps1`
section 6e (offline) and `verify-launch-detachment.ps1` (real shell) consume it,
so the offline gate and the behavioural probe cannot disagree about what exists.
22 patterns; the message for each names the **defect** it causes under dash, not
the pattern. Anti-drift is by reflection: `validate.ps1` enumerates every
`New-Sandbox*Command` the provider actually defines and fails any that is not in
the inventory, so the screen cannot quietly stop being complete.

**Probes moved into the right shell.** `verify-launch-detachment.ps1` now proves
`/bin/sh` really is dash before believing anything else - a live canary in the
same run, `$(< f)` must come back empty while `$(cat f)` returns `hello` - then
evaluates the emitted launch, the credential-vault exec and the credentialed
launch through `sh -c`. It kept its behavioural character: it still times when
the caller's streams reach EOF against a live 3 s worker rather than matching
text. Detachment is measured under **both** dash and bash, because the inner
wrapper genuinely is `bash -c` and the pre-#40 probe caught a real mis-scoped `&`
under bash; running both adds coverage instead of trading it.
`verify-sandbox-cancel.ps1` had already moved its cancel across; its **launch**
fixtures now go through `sh -c` too, so the state every case reads was built the
way a real sandbox builds it.

**Mutation.** A screen that has never rejected anything is a comment.
Reintroducing `$(< file)` into each of the six generators in turn, one at a time,
reverting between: **6 of 6 rejected**, each naming the real defect
("...expands to NOTHING, with no error and no exit code... the exact defect that
reported a live worker as already-dead in issue #36"). The launch mutation was
also run through `verify-launch-detachment.ps1`, which failed **twice** - once
for `launch` and once for `launch-inner`, proving the recovered inner wrapper is
really being screened. Adding a `New-SandboxUnscreenedCommand` generator outside
the inventory failed the anti-drift check by name. And the probe was mutated the
other way to prove it was not weakened: scoping the launch's `&` over the whole
`&&`-list held the caller 3012 ms under dash and 3018 ms under bash against a
1500 ms budget, and both were reported. Nothing was traded for the shell change.

**Verification.** `validate.ps1` 315 -> **316 passed / 0 failed / 0 skipped**
(the +1 is section 1, which emits one parse pass per `.ps1` under `scripts/`;
section 6e itself was deliberately kept to a single pass/fail pair so the count
tracks files, not opinions). `verify-cli-golden.ps1` **26/26 byte-identical, no
golden changed**. `verify-launch-detachment.ps1` **PASS**, `SH_IMPL=dash`,
`SH_BASHISM=[]`, `SH_POSIX=[hello]`, 14 clean `dash -n`/`bash -n` results,
`ELAPSED_MS=3` / `BASH_ELAPSED_MS=6`. `verify-sandbox-cancel.ps1` **PASS, 14
cases**, C2c control still showing the pre-#36 shape succeeding while the worker
lives. Worker suite **10 suites / 739 assertions**, 0 failed. .NET **114**
(47 + 67) after `dotnet clean`. `Squad.Aca.Agents` still zero package references.
dash obtained from WSL Ubuntu: `/usr/bin/dash`, `/bin/sh -> dash`, and the
in-run canary rather than the symlink is what the probe trusts.

**Left uncovered, deliberately.** The screen is syntax and idiom; a perfectly
portable and perfectly wrong command passes it, which is why the behavioural
probes exist and why neither replaces the other. Runtime-interpolated values are
not screened - a hostile *value* is the identifier and manifest validation's job.
`worker/` shell is bash by declaration and stays under `bash -n` and the worker
suite. `credential-file` is screened as `sh` although a bash wrapper could also
read it, deliberately holding it to the stricter of its two readers.

**Lesson recorded.** #36's lesson was that a substring match proves the
characters of a kill, not a kill. #40's is narrower and meaner: it is not enough
to run the real artefact against a real process if you run it under the wrong
interpreter, because the gate stays green and *looks like evidence*. Prove the
interpreter in the same run that uses it, and screen every command the process
emits - including the ones that never had a function to hide behind.