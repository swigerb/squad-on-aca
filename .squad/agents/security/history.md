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