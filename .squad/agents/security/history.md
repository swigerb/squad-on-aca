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
