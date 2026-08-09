# Validation guide

This repository is script- and infrastructure-heavy, so validation is a mix of
static checks (run anywhere) and end-to-end (E2E) checks (run against a real ACA
deployment). Use this guide as the per-sprint gate and before any push.

## Quick start

```powershell
# Static validation: PowerShell parse, worker bash -n, secret scan, .NET projects.
# `dotnet build` and `dotnet test` on aspire/Squad.Aca.sln run automatically
# whenever a dotnet SDK is on PATH; without one they report a counted SKIP.
.\scripts\validate.ps1

# Strict .NET gate: a missing dotnet SDK becomes a FAILURE instead of a SKIP.
# This is what CI uses, so "no SDK on the runner" cannot pass quietly.
.\scripts\validate.ps1 -RunDotnet
```

`validate.ps1` exits non-zero on any failure, so it is safe to wire into CI or a
pre-push hook.

## What `scripts/validate.ps1` checks

| Check | What it does | Why |
| --- | --- | --- |
| PowerShell parse | Parses every `scripts/*.ps1` (including `scripts/lib/`) with the PowerShell language parser | Catches syntax errors without executing deploy/dispatch logic |
| Worker `bash -n` | Runs `bash -n` on `worker/entrypoint.sh`, `worker/lib/squad-capability-preflight.sh`, and `worker/lib/ralph-dispatch.sh` (CRLF-normalized) | Catches shell syntax errors in the container entrypoint, capability preflight, and Ralph dispatch library |
| Secret scan | Scans tracked `docs/`, `scripts/`, `worker/`, and `aspire/` for token patterns and credential filenames (skips `bin/`, `obj/`, `node_modules/`, and binary files) | Keeps the public repo free of secrets |
| Session-managed env parity | Compares the session-managed env key lists in `scripts/lib/session-env.ps1` and `worker/lib/ralph-dispatch.sh` | Fails on drift so both dispatch paths strip the same keys and session isolation cannot regress |
| Sync guard enumeration | Asserts `Test-SyncSafety` (`scripts/lib/sync-safety.ps1`) uses repository-rooted, byte-safe NUL-delimited `git diff`/`git ls-files` enumeration with ordinal path de-duplication, then runs the real guard against a throwaway repo with nested, ignored, non-ASCII, and newline-parser regression cases | Proves every file `git add -A` would stage is scanned before `--sync-all`, including nested untracked files and quoted/escaped paths, while git-ignored files stay excluded |
| Logs fallback + exit code | Drives `Get-AcaExecutionLog` (`scripts/lib/aca-logs.ps1`) against a fake `az` placed first on `PATH`: extension present, extension absent, extension call failing, Log Analytics query failing, both paths unavailable, and a child-process exit-code assertion. Also re-runs the Log Analytics path under Windows PowerShell 5.1, the host the `squad-aca` shim uses | Regression guard for issue #13: `logs` must never exit 0 after a failed fetch, must never trigger the interactive extension-install prompt, and must fall back to Log Analytics when the `containerapp` extension is unavailable |
| .NET agent libraries | Verifies `aspire/` structure and `.csproj` XML, asserts `Squad.Aca.Agents` has **zero** package references and that `Microsoft.Agents.AI` is pinned exactly in `Squad.Aca.Agents.MAF` alone, and runs `dotnet build` + `dotnet test` when an SDK is present | Ensures the optional integration path stays coherent, and keeps the agent contract free of the Agent Framework dependency so a restore failure in the adapter cannot take the contract down with it |
| Execution provider contract | Exercises `scripts/lib/squad-aca-provider.ps1` offline against the filesystem-backed fake provider: create/wait/status/logs/cancel/terminate state transitions, idempotent `terminate` (repeat and after external deletion), double `cancel`, handle opacity, and rejection of unknown, malformed, and foreign-provider handles | Proves the provider seam behaves per PRD #6 with no Azure subscription, so a future Sandboxes provider can be developed and tested offline |
| ACA Job adapter | Drives the **production** adapter (`scripts/lib/providers/squad-aca-job-provider.ps1`) against the fake `az` from `scripts/tests/cli-stub-harness.ps1`: `terminate` on a live execution, on an already-terminal/not-found one, under an auth failure, under RBAC/throttling/network/wrong-subscription/unrecognised failures, and with no `az` on `PATH`; plus `wait` polling `Provisioning -> Running` and timing out on an execution that never becomes ready | The fake provider proves the seam, not the adapter that ships. `terminate` used to return `Terminated = $true` for *every* non-zero `az` exit and label it `AlreadyTerminal`, so an auth failure read as a successful teardown; these checks fail if that returns |
| ACA Sandboxes provider | Drives `scripts/lib/providers/squad-sandbox-provider.ps1` against a stub `aca`, and — the assertions a stub cannot make — evaluates the **actually emitted** launch and credential-staging commands through `sh -c` (dash) under WSL: timing when the caller's streams reach EOF against a still-running worker, and proving a token written to **stdin** reaches the worker verbatim through a `0600` file that the launch sources and removes. Also covers `Protect-SandboxText` directly at realistic credential lengths, and `cancel`'s failure classification | A detach is a shell-grammar property, not a substring: `&` binds looser than `&&`, so a command containing every character of a detach can still hold the exec open until its ~120 s timeout. Credential delivery is the same class of claim: only a real shell can distinguish "the token is not in the argv because it is on stdin" from "the token is not in the argv because it is not delivered at all" |
| Emitted-command shell portability | Screens **every** shell string the sandbox provider emits (`scripts/lib/squad-shell-portability.ps1`) for bashisms — `$(< file)` above all — and asserts by reflection that no `New-Sandbox*Command` generator exists outside the inventory. `verify-launch-detachment.ps1` additionally parses each one with **both** `dash -n` and `bash -n` on a real Linux host | `aca sandbox exec` runs its `-c` payload under `/bin/sh`, which is **dash** on the class image. `$(< file)` is valid bash and silently expands to the empty string under dash — no error, no exit code — which is how issue #36 shipped a cancel that read an empty `/proc` scan and reported a live worker as already-dead. See [Shell portability of emitted commands](#shell-portability-of-emitted-commands) |
| Sandbox security controls (Sprint 7/8) | Adversarial, offline: the Copilot and git tokens must appear in **no** recorded `aca` argv while provably arriving on stdin; a classic `ghp_`/`gho_`/`ghs_` token is refused **before** any CLI call with a message naming `deploy.ps1`'s single-token default; a manifest that requests an egress host outside the approved class template is refused at policy generation with nothing created; every emitted egress rule must trace to the template; ~12 hostile identifier classes (traversal, CRLF, NUL, leading `-`, over-length) are rejected before API construction and never echoed; hostile manifest text reaches neither policy, error, nor status payload; credential/egress **readback** subcommands are refused outright; the per-class concurrency ceiling holds and a class with no ceiling is a config error; the orphan reaper's selection, keep-list and undecidable-age behaviour; the auth/quota/readiness/transport/execution failure taxonomy; and credential revocation on terminate, on mid-create failure, and when revocation itself fails | An argument vector is world-readable at `/proc/<pid>/cmdline`, brokered credentials live on the **group** and outlive their sandbox, and a leaked sandbox bills indefinitely. Each control is mutation-tested: breaking it must fail a named check, not merely change some text |
| CLI behaviour regression | Drives `scripts/squad-aca.ps1` in a child process with stub `az`/`gh` binaries on `PATH` (`scripts/tests/cli-stub-harness.ps1`), asserting exit codes, **stdout content**, and the exact `az` call sequence for `sessions`, `logs`, `stop`, `smoke`, and `doctor` | The provider refactor must be observably invisible; this fails if a call site changes what a user sees, including the `stop` pass-through output and exit code when `az` fails |
| CLI golden gate wiring | Asserts every capture case in `scripts/tests/cli-capture-cases.ps1` has a committed golden, that the `stop` golden records `az` stdout, and that `.github/workflows/worker-tests.yml` actually runs `verify-cli-golden.ps1` | A guard that is not automated is not a guard; PR #9's regression class shipped once because the only stdout-comparing tool was a manual one |
| Worker capability tests | Not run by `validate.ps1` (needs `bash`+`node`); run `bash worker/tests/run-tests.sh` directly or via CI | Covers the capability manifest parser, the capability routing decision, preflight contract, Ralph transactional dispatch, and the harness itself |
| Egress honesty | Drives `scripts/squad-aca.ps1` through the CLI stub harness with a manifest whose declared egress host is a **distinctive token**, and asserts: the route is still `aca-job` and a job actually starts; the CLI warns that *N* destinations will not be enforced on the named route; the token appears in **neither** stdout nor stderr; a manifest declaring no egress produces **no** such warning. Structurally: `squad-capability-preflight.sh` no longer says `advisory only, not enforced yet` and is keyed on `SQUAD_EXECUTION_MODE`; `resolve-capability-route.js` derives `egressEnforced` from the profile's `egress.defaultAction` and contains no route-name substitute; and `worker/tests/test_egress_honesty.sh` still carries all five paired claims | The decision used to report a declared destination as *satisfied* on the ACA Jobs plane, which has no per-execution network control at all — `defaultWorker.egress` is `{Allow, []}`, so `egressAllows()` returned true for any host. **No enforcement was added**; the decision stopped claiming a control it cannot back. The count-not-hosts rule is a redaction property, not cosmetics: `egress[].host` is repository-controlled text landing in an operator terminal and in session logs. Both directions of every boolean are asserted, because a boolean checked one way is satisfied by a constant |

The capability manifest contract itself is documented in
[capability-manifest.md](capability-manifest.md): manifest schema, built-in
tool/credential allowlists, the advisory-only handling of `services`/`egress`
(required services are rejected at validation), the routing contract and
administrator sandbox class catalog, and the entrypoint fail-closed
behavior when the packaged preflight script is missing.

### Skip semantics in `validate.ps1`

Two checks depend on something `validate.ps1` cannot provide for itself: the
`bash -n` worker syntax check needs `bash`, and the sandbox **detachment** check
needs a real Linux shell (`wsl -d Ubuntu -e bash`). A check that could not
execute is reported as `[SKIP]` and counted separately in the summary — never as
a pass — mirroring `worker/tests/lib/deps.sh` (exit `77` → `run-tests.sh`
reports a skip):

```text
  Passed: 149
  Failed: 0
  Skipped: 1

Skipped (NOT passes -- the dependency was missing):
  - Worker-launch detachment is UNVERIFIED: wsl.exe is not on PATH. ...
```

A skip that silently counted as a pass is a check that stops existing the moment
its dependency goes missing. CI runs on a host where the dependency is present,
so a skip there is a signal to investigate, not to ignore.

## Shell portability of emitted commands

`aca sandbox exec -c '<command>'` does **not** run `<command>` under bash. It
runs it under `/bin/sh`, which on the pinned class image is **dash**. Verified
directly on a fresh sandbox:

```text
SHELL=/bin/sh
bashism_result=[]        # $(< /tmp/t)   -- silently empty: no error, no exit code
posix_result=[hello]     # $(cat /tmp/t)
```

That silent-empty behaviour is not a curiosity; it is how issue #36 shipped a
cancel command that looked correct. The `/proc` scan read nothing, and "nothing"
was interpreted as "the worker is gone", so a running worker was reported as
already-dead. The command was valid bash and it was tested — under bash.

Issue #40 generalised the fix. A probe that evaluates real behaviour in the
*wrong shell* can pass while production fails, and that is harder to notice than
a missing test, because the gate is green and looks meaningful.

### What is guaranteed

**Every shell string the sandbox provider emits is covered**, not just cancel.
The inventory lives in `scripts/lib/squad-shell-portability.ps1` and is built by
calling the **shipping generators**, so it can never describe a command that is
not the one that ships:

| Id | Generator | What it is |
| --- | --- | --- |
| `launch` | `New-SandboxLaunchCommand` | Creates the state dir, sources and deletes staged credentials, detaches the worker |
| `launch-inner` | (the `bash -c '...'` payload inside `launch`) | The detached wrapper. Single-quoted inside `launch`, so neither `dash -n` nor `bash -n` reaches it when parsing the outer command; the detachment probe recovers and checks it separately |
| `cancel` | `New-SandboxCancelCommand` | The procps-free process-group kill and its verdict |
| `poll` | `New-SandboxPollCommand` | Reads phase, exit code and completion marker |
| `credential-vault` | `New-SandboxCredentialVaultCommand` | Creates the `0700` directory the credential file is uploaded into |
| `logs` | `New-SandboxLogsCommand` | Tails `session.log` |
| `credential-file` | `New-SandboxCredentialFileContent` | The bytes of the credential file the launch sources |

Three independent gates apply to that inventory:

1. **Static screen** (`validate.ps1`, offline, no dependencies). Rejects the
   bashism class that caused #36 — command substitution of a bare redirect
   (`$(< file)`) above all — plus `[[ ]]`, arrays and array subscripts, `local`,
   the `function` keyword, `+=` string append, here-strings (`<<<`), process
   substitution (`<(...)`/`>(...)`), `${var^^}`/`${var,,}`/`${!var}`/
   `${var:offset:length}`, `echo -e`/`-n`, `&>`/`>&word`/`|&`, `$'...'`,
   `==` inside `[ ]`, `source`, `pushd`/`popd`, `declare`/`typeset`/`let`/
   `select`/`mapfile`/`shopt`, `export -f`, `trap ... ERR`, `wait -n`, bash-only
   `read` flags, `{1..9}` brace ranges, and `read -r X < f` with the stderr
   redirect placed after the input redirect. Each pattern's message names the
   *real defect* it causes under dash, not the pattern. `${var:-default}` and
   `${var:+alt}` are portable and are deliberately **not** matched.
2. **Anti-drift reflection** (`validate.ps1`). Enumerates every
   `New-Sandbox*Command` function actually defined by the provider and fails if
   one is not in the inventory. Adding a new emitted command without covering it
   is a validation failure, so the screen cannot quietly stop being complete.
3. **Real-shell syntax check** (`verify-launch-detachment.ps1`, needs WSL).
   Writes each command to a file through a quoted heredoc and parses it with
   both `dash -n` **and** `bash -n`. Both, because the launch's inner wrapper is
   genuinely executed by `bash -c` — running only one would trade coverage
   rather than add it.

`verify-launch-detachment.ps1` also evaluates behaviour in the right shell. It
proves `/bin/sh` on the probe host really is dash before believing anything else
(a live canary: `$(< f)` must return nothing while `$(cat f)` returns `hello`),
runs the emitted launch and the credential-seed command through `sh -c`, and
still asserts stream-EOF ordering against a live worker rather than matching
text. The detachment measurement is taken under dash **and** bash: a mis-scoped
`&` is caught by both.

### What is NOT guaranteed

* **Behavioural correctness.** The screen is a syntax and idiom check. A command
  that is perfectly portable and perfectly wrong passes it. That is why the
  behavioural probes exist and why neither replaces the other.
* **Runtime-interpolated data.** The inventory is generated with representative
  arguments. A hostile *value* reaching a command is the job of the identifier
  and manifest validation (see [Security validation](#security-validation)), not
  of this screen.
* **Anything outside the provider's emitters.** Shell that the worker container
  runs from `worker/` is bash by declaration (`#!/usr/bin/env bash`) and is
  covered by `bash -n` and the worker suite instead.
* **The credential file's consumer.** `credential-file` is screened as `sh`
  because the launch sources it with `.` under `/bin/sh`. It is deliberately
  held to the stricter of its two possible readers.
* **Shells other than dash and bash.** The class image ships dash; if that ever
  changes, this guarantee changes with it and the canary in the detachment probe
  is what will say so.

### Proving the screen works

A screen that has never rejected anything is a comment. It is mutation-tested:
reintroducing `$(< file)` into each of the six generators must produce a failure
that names the real defect, and adding a `New-Sandbox*Command` generator outside
the inventory must fail the anti-drift check. Both are reproduced by editing the
generator, running `validate.ps1` (or `verify-launch-detachment.ps1` for the
probe path), and reverting.

## Credential handling under a one-hour token

Issue #32 replaced the token baked into `url.<...>.insteadOf` at session start
with a git credential helper that re-reads a `0600` token file on every git
operation. Three suites cover it, and all three run against **real** git rather
than a simulation:

| Suite | What it exercises |
|---|---|
| `worker/tests/test_credentials.sh` | The helper and the token file, against a real smart-HTTP remote (`worker/tests/lib/fake-git-https-server.js`, driving the actual `git http-backend`) that answers `401` until a correct credential arrives. |
| `worker/tests/test_token_preflight.sh` | The fail-fast gate: lifetime versus estimated run duration, live credential probe, and the setups it refuses to start under. |
| `worker/tests/test_push.sh` | Exit-code propagation and the retry-after-refresh path. |

### Why the obvious test would have been worthless

`swigerb/squad-on-aca` is a **public** repository. An unauthenticated clone
succeeds, and so does a clone with an expired token — exit 0, no warning. A test
that observed "the clone worked" would stay green with the credential helper
deleted entirely.

So the fixture demands a credential and records what crossed the wire:

```
PRESENTED x-access-token:ghs-rotated-bbbbbbbbbbbbbbbbbbbbbbbbbbbb
```

The assertion is about the credential, not the exit code. There is also an
`ANONYMOUS` control: with no helper configured the same fixture refuses the
push, which is what makes every success below evidence rather than coincidence.

### The regression that made `test_push.sh` necessary

The push logic used to live inline in `worker/entrypoint.sh`. Nothing under
`worker/tests/` sources that file, so it was logic no test could reach — and it
shipped with the exact defect that sank PR #9:

```bash
if ! git push ...; then
  push_rc=$?      # 0, ALWAYS: $? here is the status of the NEGATION
fi
```

Proven in a real shell:

```
if ! (exit 128); then rc=$?; fi   ->  rc=0
(exit 128) || rc=$?                ->  rc=128
```

The caller ended with `exit "$push_rc"`, so a push git had **refused** would
have exited 0 and the session would have been recorded as successful with
nothing pushed. The logic now lives in `worker/lib/squad-push.sh` so it can be
executed by a test, and `test_push.sh` case B asserts a refused push returns
non-zero while case C — the control — runs the *old* shape against the same
refused push and shows it returning 0. Without case C, case B could pass for the
wrong reason.

Re-introducing the old shape fails five named assertions.

### What is NOT covered

- **A mid-session refresh under ACA Jobs**, because there is no channel to
  perform one — see `docs/sandboxes.md`, "Refresh channel matrix". A test
  implying otherwise would restate a wish.
- **Real GitHub tokens.** The suites use a local fixture; the live path is
  exercised by the token preflight against the real API at session start.

## Proving the CLI has not changed

Two guards drive the same 22-invocation matrix (`scripts/tests/cli-capture-cases.ps1`)
through the stubbed `az`/`gh`/`squad`/`aca` environment. A capture records the
exit code, every recorded `az`/`gh`/`squad`/`aca` argv, **stdout**, and stderr —
stdout deliberately, because PR #9 was closed for an observable `stop` output
regression and a guard that only counts `az` calls cannot see one. Neither
touches Azure, GitHub, or the network.

The `### ACA CALLS` section is empty in all 22 human-output goldens, and that
emptiness *is* the flag-off guarantee written down rather than merely asserted:
the `aca` shim is on `PATH` for every capture, so the first command that ever
shells out to `aca` with `SQUAD_ACA_ENABLE_SANDBOX` unset shows up as a golden
diff.

Four further cases (`23-run-json`, `24-sessions-json`, `25-status-json`,
`26-sessions-json-session`) pin the opt-in machine-readable contract described in
[agent-contract.md](agent-contract.md). They are strictly additive: `--json` is
never passed by cases `01`–`22`, so those goldens are byte-identical to what they
were before the flag existed. That is deliberate — the human output and the
machine contract have to be able to change independently, or neither can change
at all.

### Golden gate (automated, runs in CI)

```powershell
pwsh -NoProfile -File .\scripts\tests\verify-cli-golden.ps1           # verify
pwsh -NoProfile -File .\scripts\tests\verify-cli-golden.ps1 -Update   # regenerate
```

Captures are compared against files committed under `scripts/tests/golden/cli/`,
the same pattern the worker suite uses for routing decisions. The
`powershell-validation` job in `.github/workflows/worker-tests.yml` runs the
verify form on every push and pull request, so a change to what `squad-aca`
prints fails a job instead of reaching review unnoticed. An **intended** CLI
change is a reviewable diff: regenerate with `-Update`, read the diff, commit it.

#### What makes a golden portable

The first CI run of this gate failed on two environment dependencies that a
single-machine capture cannot expose: rendered timestamps moved with the host
time zone, and `doctor`'s `squad` row read `ok` on a machine with Squad
installed and `optional` on the runner — and because `Format-Table -AutoSize`
sizes each column to its widest cell, that one word re-padded every row of the
table. Both are now **pinned at the source** rather than masked, because a mask
throws away the value it hides:

| Environment dependence | How it is pinned | Where |
| --- | --- | --- |
| Host time zone | The stub `az` execution fixtures carry an **offset-free** `startTime`. `ConvertFrom-Json` parses an offset-bearing instant as `Kind=Local` and `sessions` would then render it in the host's zone; offset-free parses as `Kind=Unspecified`, so no conversion happens and every machine renders the identical wall clock. The `Started` column is still compared character for character. | `cli-stub-harness.ps1` |
| Host culture (date/number formats) | The CLI child process is started with `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`, so output renders under the invariant culture instead of the machine's locale. .NET honours this on Windows, where there is no per-process culture or time-zone override. | `cli-stub-harness.ps1` |
| Optional tool availability | `squad` is stubbed onto PATH next to the `az`/`gh` shims, so `doctor` reports it installed on every machine. The stub logs its argv like the others, so if a command ever starts shelling out to `squad` that is a visible capture diff, not a silent change. | `cli-stub-harness.ps1` |
| Host console width | `sessions` pipes `Format-Table -AutoSize` through `Out-String -Width 200`. Without an explicit width, `Format-Table` sizes to the host's console (120 columns when there is no console) and **silently drops trailing columns that do not fit** — it does not truncate them, it omits them. That is how the `Source` column disappeared entirely when Sprint 6 widened the table. `-Wrap` prevents truncation but not dropping; only an explicit `-Width` does. | `scripts/squad-aca.ps1` (`Invoke-Sessions`) |

What is left genuinely cannot be pinned, so it is masked. This is the
**complete** list of masks applied to a golden (`Get-NormalizedCapture` and
`Get-PortableCapture` in `cli-capture-cases.ps1`):

1. `<TS>` — timestamps of the form `yyyyMMdd-HHmmss` (generated session/branch names).
2. `<SCRIPTS>` — the absolute path of the `scripts/` tree under capture.
3. `<STUB>` — the GUID in the throwaway stub root directory name.
4. `<LINE>` — the line number in a `squad-aca.ps1:<n>` error header.
5. `<TMP>` — the temp root (`GetTempPath()`, `%TEMP%`, `%TMP%`, and the 8.3 form `C:\Users\X~1\AppData\Local\Temp`).
6. `<HOME>` — the user profile root (`%USERPROFILE%`, `$HOME`, and any `C:\Users\<name>` prefix).
7. `<SHA>` — 40-hex git object ids from the stub repo's throwaway commits.
8. ANSI SGR colour sequences (PowerShell 7 colourises error records) are deleted.
9. PowerShell's error-record source decoration — the `Line |` header, the `<LINE> |` echo of the offending source line, and its `|  ~~~~` caret underline — is dropped. Its content is truncated to the host console width, so it is not portable. The `Exception: <file>:<line>` header, the message text, and the exit code are kept.
10. CRLF is folded to LF.

Nothing else is touched. Exit codes, every recorded `az`/`gh`/`squad` argv, and
all message text — including the `az containerapp job stop` stdout that PR #9
lost — are compared byte for byte.

Generate and verify goldens with **PowerShell 7** (`pwsh`), the host CI uses;
Windows PowerShell 5.1 renders error records differently. The goldens are
LF-normalized via `.gitattributes` (`scripts/tests/golden/cli/*.txt text eol=lf`)
so a Windows checkout does not diff on line endings.

Before pushing a change to the harness or the goldens, reproduce the runner's
environment locally — the whole point of this section is that passing on one
machine proves nothing:

```powershell
# CI runs in UTC and has no `squad` installed.
$orig = (tzutil /g)
try {
    tzutil /s "UTC"
    pwsh -NoProfile -Command @'
$env:PATH = (($env:PATH -split ';') | Where-Object { $_ -notlike '*npm*' }) -join ';'
./scripts/tests/verify-cli-golden.ps1
'@
} finally { tzutil /s "$orig" }
```

### Differential capture (manual, strongest claim)

When a change touches the control plane — particularly the execution provider
seam — also prove the stronger claim against another revision:

```powershell
pwsh -NoProfile -File .\scripts\tests\compare-cli-baseline.ps1 -BaselineRef main
```

It materialises the baseline revision's `scripts/` with `git archive`, drives
both revisions through the same stub environment (`help`, `sessions`, `logs`,
`stop`, `smoke`, `telemetry smoke`, `status`, `doctor`, `run`, `sync`, plus
failure paths), and compares exit code, stdout, stderr, and every recorded
`az`/`gh`/`squad` argv. It exits non-zero if observable behaviour differs.

This one stays a developer tool rather than a CI gate: it needs a second
revision materialised, and it fails permanently once a CLI change is *intended*.

It reports two counts. The raw count is byte-for-byte. The second ignores the
two things that cannot survive a refactor: PowerShell annotates an uncaught
error with the **source line number** of the `throw`, so any change to a file's
length shifts that annotation, and PowerShell 7 wraps error records in **ANSI
SGR colour sequences**. The exception text, exit code, and call sequences are
still compared unnormalised.

## Worker test harness guarantees

The worker suite is the only executable test coverage in this repository, so the
harness itself is treated as production code and is tested. Run it with:

```bash
bash worker/tests/run-tests.sh
```

### The harness self-test

`worker/tests/test_run_tests.sh` tests `run-tests.sh`. This exists because a
prior runner could not report failure: it captured the suite status inside
`if ! bash "$test_script"`, where `$?` is the *negated* status and is therefore
always `0`. A failing suite left the status at `0`, so the runner printed
"All worker capability tests passed." and exited `0` — a permanently green gate.

The self-test runs the **real** runner against a throwaway directory of
synthetic suites (via the `SQUAD_ACA_TEST_DIR` override, which exists only for
this purpose — with it unset the runner behaves exactly as before and runs the
suites beside itself). It asserts the exit code, banner, and suite counts for
every outcome: failing suite, non-`1` failure code, all passing, mixed
pass/fail, a failure in the middle, skip, skip + failure, all-skipped, an empty
test directory, and default suite discovery. Fixtures live under a self-cleaning
temp root and never appear in a normal run.

The runner also refuses to print the success banner when **no suite actually
executed** — an empty test directory or a run where every suite skipped exits
non-zero, because a run that proved nothing must never read as green.

### Golden decision fixtures

`worker/tests/test_capability_routing.sh` asserts the capability routing
decision byte-for-byte against golden JSON in `worker/tests/expected/`, using
manifests from `worker/tests/fixtures/routing-*.yml`. The resolver emits keys in
a fixed order and sorts/de-duplicates every array specifically so those goldens
are meaningful: a decision that changes for any reason shows up as a readable
diff rather than as a reshuffle.

Regenerate a golden only when the change to the decision is intended, and review
the diff:

```bash
node worker/lib/resolve-capability-route.js <repo-with-manifest> --pretty \
  > worker/tests/expected/<golden>.json
```

Golden files are LF-normalized via `.gitattributes` so they stay byte-stable on
Windows checkouts.

### Declared dependencies and skip semantics

Each suite declares what it needs up front via `worker/tests/lib/deps.sh`:

```bash
source "${TEST_DIR}/lib/deps.sh"
require_deps node git
```

| Suite | Declared dependencies |
| --- | --- |
| `test_capability_routing.sh` | `node` |
| `test_egress_honesty.sh` | `node` |
| `test_git_checkout.sh` | `git` |
| `test_parse_capabilities.sh` | `node` |
| `test_preflight.sh` | `node` |
| `test_ralph_dispatch.sh` | `node`, `mktemp`, `date` |
| `test_run_tests.sh` | `env`, `find` |

When every dependency is present, `require_deps` is a silent no-op. When one is
genuinely absent the suite prints a visible line and exits `77`:

```text
SKIP: test_parse_capabilities.sh — missing node
```

`run-tests.sh` counts exit `77` as a **skip**, never a pass, and ends the run
with an explicit accounting:

```text
Suites: 2 passed, 0 failed, 3 skipped.
Skipped suites (NOT counted as passes):
  - test_parse_capabilities.sh
```

Nothing is ever downloaded or installed during a test run: a missing runtime is
reported, not silently provisioned. A run that quietly bootstrapped `node` would
no longer be testing the environment it claims to test.

On CI every declared dependency is present, so the `worker-tests` job in
[`.github/workflows/worker-tests.yml`](../.github/workflows/worker-tests.yml)
**fails when any suite reports a skip** — a partial green is treated as a
regression.

### Linux-only constraint (no Git Bash / Cygwin)

The suite must be run on Linux — WSL on a Windows workstation, or the
`ubuntu-latest` runner in CI:

```powershell
wsl -d Ubuntu -e bash -c 'cd /path/to/repo && bash worker/tests/run-tests.sh'
```

It cannot run under Git Bash or Cygwin. `worker/lib/squad-capability-preflight.sh`
hardens its temporary directory handling and refuses to proceed when the temp
path is predictable, which is exactly what the Git Bash/Cygwin `TMPDIR` emulation
produces. That refusal is correct behaviour — the preflight is doing its job —
so the fix is to run the suite on a real Linux environment rather than to weaken
the guard. This is also why `validate.ps1` only runs `bash -n` on the worker
scripts (a syntax check, which Git Bash handles fine) and leaves the behavioural
suite to WSL/CI.

Run it from a **checkout path that contains no digits**. Several redaction
assertions prove the parser never echoes a raw manifest value by asserting that
value's absence from the error output, and those errors legitimately include the
manifest's absolute path. A working copy at, say, `~/sq-s2` puts a `2` in every
error line and trips the "does not echo the raw manifest version" assertion —
a false failure caused by the path, not by the code.

### PowerShell validation in CI

The `powershell-validation` job runs `scripts/validate.ps1` on `windows-latest`.
Every check in that script is offline — none of it touches Azure — so nothing is
gated on credentials. The runner ships pwsh 7 and Git Bash pre-installed, so no
PowerShell runtime is downloaded at test time and the `bash -n` section executes
instead of skipping.

It runs on `windows-latest` rather than `ubuntu-latest` (which also ships pwsh)
because `validate.ps1` resolves repo paths with Windows separators today, so it
cannot execute unmodified under Linux pwsh. Making `validate.ps1` fully
cross-platform is a worthwhile follow-up; it is deliberately out of scope for a
guardrails-only sprint that touches tests, CI, and docs.

## Sprint validation checklist

Run these in order. Static checks first (fast, no Azure), then E2E.

### 1. Static (no Azure required)

- [ ] `.\scripts\validate.ps1` passes.
- [ ] The **Execution provider contract** and **CLI behaviour regression**
      sections of `validate.ps1` report 0 failures. Any change to
      `scripts/squad-aca.ps1` must keep the CLI regression section green — it is
      the guard against a behaviour change slipping in behind the provider seam.
- [ ] If the sprint touched the control plane,
      `.\scripts\tests\compare-cli-baseline.ps1 -BaselineRef main` exits 0 (see
      [Proving the CLI has not changed](#proving-the-cli-has-not-changed)).
- [ ] `bash -n worker/entrypoint.sh` passes (also covered by validate.ps1).
- [ ] `node --check worker/lib/parse-capabilities.js` passes.
- [ ] `node --check worker/lib/resolve-capability-route.js` passes and
      `config/sandbox-classes.json` parses as JSON.
- [ ] `bash worker/tests/run-tests.sh` passes on Linux/WSL (capability parser,
      capability routing, preflight, Ralph dispatch, and the harness self-test)
      with **0 failed and 0 skipped** — see
      [Worker test harness guarantees](#worker-test-harness-guarantees).
- [ ] `git grep` finds no personal subscription IDs, tenant IDs, tokens, or user
      handles in tracked files (see [Secret scans](#secret-scans)).
- [ ] `.\scripts\validate.ps1` reports `dotnet build succeeded` and
      `dotnet test succeeded` (or a visible SKIP if this machine has no SDK — a
      SKIP is never a pass). Use `-RunDotnet` to make a missing SDK fail.

### 2. E2E (requires an ACA deployment)

Record real command output in [e2e-results.md](e2e-results.md) (static evidence is
already captured there; the live-Azure sections L1–L7 are filled by the
orchestrator/operator against a real deployment).

- [ ] `squad-aca doctor` — validates local repo, GitHub, Azure, ACA, and Aspire
      config.
- [ ] `squad-aca telemetry smoke` (or `SQUAD_MODE=telemetry-smoke`) — emits
      known-good logs/traces/metrics and they appear in the Aspire Dashboard,
      grouped by `squad-<session>`.
- [ ] `scripts/start-session.ps1 -Mode smoke -RunCopilotSmoke` — a session job
      execution starts, clones the repo, and exits cleanly.
- [ ] **Template non-mutation:** the `caj-squad-aca-session` template env is
      identical before and after a dispatch (dispatch uses a per-execution
      `az containerapp job start --env-vars` override, never `job update`). The
      dispatch also echoes the template's image and CPU/memory back on `job start`
      — a read of the immutable template, not a write — because ACA only applies
      the per-execution env override when a complete execution container spec is
      supplied. See [e2e-results.md](e2e-results.md) L3.
- [ ] **Per-execution isolation:** a session that omits `SQUAD_PROMPT` does not
      inherit a previous session's prompt, and still carries the durable common
      env. See [e2e-results.md](e2e-results.md) L4.
- [ ] **Idempotent deploy:** re-running `scripts/deploy.ps1` succeeds and updates
      the existing Aspire app (rotates OTLP key + browser token) instead of
      failing on create. See [e2e-results.md](e2e-results.md) L1.
- [ ] **Watcher registry idempotency:** re-running `scripts/deploy.ps1` against an
      existing `ca-<prefix>-watch` whose ACR changed (new `$loginServer`/ACR name)
      first removes stale registry entries whose server differs from `$loginServer`
      (`az containerapp registry list`/`remove`), then updates the watcher registry
      config via `az containerapp registry set`
      (`--server $loginServer --identity $identityId`) before the image update, so
      the image pull does not fail with `UNAUTHORIZED` and `az containerapp show`
      lists only the current registry. A failed stale-entry removal logs a warning
      but does not fail the deploy. Session/Ralph jobs get the
      same effect automatically: a changed login server changes the full image
      string, so deploy deletes and recreates them with the current
      `--registry-server`/`--registry-identity` (the job update path only runs when
      the login server is unchanged, so its registry config is already correct).
- [ ] A `prompt` session opens a PR on `squad/<session>`.
- [ ] Ralph dispatch: an actionable labeled issue gets the `squad-aca:dispatched`
      label and a session job execution starts, with no shared-template mutation.
      (The `squad:*` namespace is reserved by Squad member-routing workflows, so
      Ralph uses `squad-aca:dispatched` to avoid triggering member assignment.)

## Security validation

These map to the Security review items. Each has a concrete way to verify it.

### OTLP authentication

- **Expected:** Dashboard UI auth = `BrowserToken`, OTLP auth = `ApiKey`. Never
  `Unsecured`.
- **Verify (source):**
  ```powershell
  Select-String -Path scripts\deploy.ps1 -Pattern 'AUTHMODE','BrowserToken','ApiKey','Unsecured'
  ```
  Expect `DASHBOARD__FRONTEND__AUTHMODE=BrowserToken`,
  `DASHBOARD__OTLP__AUTHMODE=ApiKey`, and **no** `Unsecured`.
- **Verify (live):**
  ```powershell
  az containerapp show -n ca-squad-aca-aspire -g <rg> `
    --query "properties.template.containers[0].env[?starts_with(name,'DASHBOARD__')]"
  ```

### OTLP exposure (ports internal only)

- **Expected:** UI port `18888` is external; OTLP `18889`/`18890` are
  internal-only (`external: false`).
- **Verify (source):** in `scripts/deploy.ps1`, the `additionalPortMappings` for
  18889/18890 have `external: false`.
- **Verify (live):**
  ```powershell
  az containerapp show -n ca-squad-aca-aspire -g <rg> `
    --query "properties.configuration.ingress.additionalPortMappings"
  ```
  Both OTLP ports must show `"external": false`.

### RBAC / identity scope

- **Current state:** the user-assigned managed identity holds **AcrPull** on the
  registry and **Container Apps Jobs Operator** scoped to the **session job**.
  That covers `Microsoft.App/jobs/read` and `Microsoft.App/jobs/*/action`, which
  is exactly the two calls Ralph makes (`containerapp job show`, `job start`).
- It previously held **Contributor** on the resource group. `deploy.ps1` now
  removes that grant when it finds one, because narrowing only new deployments
  would leave every existing environment broad forever.
- **Do not broaden** identity/RBAC further. `validate.ps1` fails the build if the
  deploy script grants Contributor on the resource group again, if it stops
  granting the job-scoped role, or if it stops removing the old grant.
- **Resource-scoped assignments are fragile by design.** A `containerapp job
  delete` — which happens on every image-changing deploy — takes the assignment
  with it. Both this grant and the GitHub Actions trigger's grant are therefore
  reconciled on every deploy rather than created once.
- **A custom role is not needed.** `Container Apps Jobs Operator` scoped to a
  single job is narrower than a custom role scoped to a resource group, and it
  is built in, so there is nothing to keep in step with the platform.

### Egress

Unrestricted, deliberately. The reasoning, what it does and does not protect now
that the identity is out of the session, and the price of changing it, are in
[egress-assessment.md](egress-assessment.md).

### Secret scans

- **Verify no secrets are committed:**
  ```powershell
  .\scripts\validate.ps1   # includes the docs/scripts/aspire secret scan
  git grep -nIE "gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  ```
  Both should return nothing.
- **Verify ignore rules:** `.azure/`, `.env`, and `deploy.outputs.json` are in
  `.gitignore`:
  ```powershell
  git check-ignore .azure deploy.outputs.json .env
  ```

### Token separation

- **Expected:** GitHub API work and Copilot headless auth can use separate
  tokens (`GITHUB_TOKEN`/`GH_TOKEN` vs `COPILOT_GITHUB_TOKEN`).
- **Verify:** `scripts/deploy.ps1` wires `copilot-github-token` as a distinct
  secret; `worker/entrypoint.sh` prefers `COPILOT_GITHUB_TOKEN` and only falls
  back to `GH_TOKEN` when it is unset.

### Rotation

- **Rotate GitHub/Copilot tokens:**
  ```powershell
  squad-aca secrets rotate --github-token <token> --copilot-token <token>
  ```
- **Rotate OTLP API key / dashboard browser token:** re-run `scripts/deploy.ps1`;
  both are regenerated with `New-HexToken` and re-applied. Re-running is
  **idempotent**: the Aspire app is updated in place via
  `az containerapp update --yaml` (a full create-or-update PUT that rotates the
  secret and browser token and rolls a new revision), not recreated, so rotation
  and recovery no longer fail on an existing app. Confirm old values no longer
  authenticate.

### Public repo sync guard

- **Expected:** `squad-aca sync --sync-all` refuses to stage obvious secret files
  or inline tokens before `git add -A`.
- **Verify:** create a throwaway file and confirm the guard blocks it:
  ```powershell
  Set-Content .env "GITHUB_TOKEN=ghp_<redacted-example-token>"
  squad-aca sync --sync-all   # must fail with a "secret guard" message
  Remove-Item .env
  ```
  The guard blocks at least: `.env`, `deploy.outputs.json`, `.azure`, `*.pfx`,
  `*.pem`, `id_rsa`/`id_ed25519`, `appsettings*.Development.json`, and inline
  token patterns. Intentional override: `SQUAD_ACA_ALLOW_UNSAFE_SYNC=1` (only for
  known-private repos).

### Image pinning

- **Expected:** the worker image pins tool versions rather than floating latest
  for the risky dependencies.
- **Verify:** `worker/Dockerfile` pins the base image (`node:24-bookworm-slim`),
  Copilot CLI (`@github/copilot@1.0.69-2`), and Squad CLI
  (`@bradygaster/squad-cli@0.11.0`).
- **Note:** the Aspire Dashboard image is pulled by tag (`:latest` in
  `scripts/deploy.ps1`, `:9.4` in the optional AppHost). For production, pin the
  dashboard to a specific tag/digest.

## Optional .NET/Aspire validation

```powershell
cd aspire
dotnet build .\Squad.Aca.sln          # restore + compile
dotnet test  .\Squad.Aca.sln          # agent contract + MAF adapter tests (offline)
```

`Squad.Aca.Agents.Tests` is fully offline by construction: the only seam to the
outside world is `ISquadCliInvoker`, and every test supplies a fake, so no test
starts PowerShell, contacts Azure, or opens a socket. `Squad.Aca.Agents.MAF.Tests`
is offline for the same reason — a scripted `ISquadAgent` and a virtual polling
clock, so a 90-minute timeout is exercised in milliseconds. There is therefore no
credential or network reason to gate these tests behind a flag, and
`validate.ps1` runs them whenever a dotnet SDK is present.

If restore is not feasible (offline or restricted feeds), that is expected and
acceptable: the path is optional. The project files still parse and review as
source, and the static structure check in `validate.ps1` still passes. Document
the restore failure reason in your sprint notes and keep the dependency explicit
rather than vendoring packages.

## Rollback and recovery

If validation fails after a deploy or config change, or a session/Ralph/watch run
misbehaves, follow [rollback.md](rollback.md). It covers per-component recovery
(optional .NET/Aspire path, ACA worker image/session job, Aspire token/secrets,
Ralph/watch) and, as a last resort, a full resource-group destroy/redeploy. Each
rollback ends with a post-rollback verification checklist that re-runs
`scripts/validate.ps1` and `squad-aca doctor`.

## Known limitations

- E2E telemetry and session checks require a live ACA deployment and Azure
  credentials; they cannot run in a pure static/offline gate.
- `bash -n` requires a `bash` on PATH (Git Bash or WSL on Windows). validate.ps1
  skips it gracefully when bash is absent.
- The behavioural worker suite (`worker/tests/run-tests.sh`) needs a real Linux
  environment; Git Bash and Cygwin cannot run it. See
  [Linux-only constraint](#linux-only-constraint-no-git-bash--cygwin).
- `scripts/validate.ps1` is Windows-only today (it resolves repo paths with
  Windows separators), so the CI PowerShell job runs on `windows-latest`.
- The secret scans are pattern-based and catch common token shapes, not every
  possible secret. They complement, not replace, a dedicated secret-scanning
  tool in CI.

## Workflow files must parse

Sprints 3 and 4 of #32 both merged a workflow **GitHub could not parse**, and
every check in `validate.ps1` passed.

The failure mode is unusually quiet:

- it is not a failed **step**, it is a failed **run**, named after the *file*
  rather than a job;
- there are no jobs and no log — `gh run view --log-failed` answers
  `log not found`;
- CI stays **green**, because CI runs `validate.ps1` and the worker suite, and
  neither of them parsed YAML.

The specific trap: inside a YAML block scalar (`run: |`), **a line beginning at
column 0 ends the block.** A markdown table in a `gh issue comment --body`, or a
multi-line commit message, is all column-0 lines. Grep-based checks cannot see
this — every string they search for is still in the file, in the right order,
on the right lines.

`validate.ps1` now parses every file under `.github/workflows/` and asserts each
one is a mapping with a trigger and at least one job. `worker-tests.yml`
installs PyYAML explicitly rather than trusting the runner image, because on CI
a counted SKIP is not a pass.

Build multi-line strings inside a `run:` block with `printf`, never as a
literal:

```bash
body="$(printf '%s\n\n%s\n' \
  'A heading' \
  '| a | table |')"
```
Every `run:` block is also extracted and checked with `bash -n`, because a
workflow's shell scripts are scripts nothing else in this repository executes.

That gate catches **syntax**. It cannot catch **ordering** — `set -u` finding a
variable used before it is assigned is a runtime error, and it happened: a
refactor moved a `commit_message=` assignment below its own use, and the only
thing that noticed was a live dispatch. The live end-to-end run is therefore
still the last gate, not a formality. Both are worth having; neither replaces
the other.
## The shipped image layout

`worker/tests/test_image_layout.sh` builds a throwaway directory shaped like the
worker image and runs the dispatcher from it with **no `--catalog` override**,
because that is how Ralph calls it.

It exists because the packaged layout was never tested. Every routing assertion
passed `--catalog` explicitly, and the dispatch suites exported
`SQUAD_DISPATCH_CLI` pointing at the repository tree — so the one path
production actually uses was the one path nothing exercised. `config/sandbox-classes.json`
was absent from the image, and `squad-dispatch.js decide` exited **70** with
`catalog-unavailable` on every Ralph run.

**The layout is derived by parsing the Dockerfile `COPY` lines, not hard-coded.**
That is the difference between a test and a decoration: with a hard-coded list,
deleting the catalog from `COPY` would break nothing and the suite would stay
green while the image shipped broken.

### The build context is the repository root

`config/sandbox-classes.json` lives outside `worker/`, and **a `COPY` cannot
reach above its build context.** Proven, not assumed:

```
COPY ../config/sandbox-classes.json /usr/local/lib/squad-on-aca/
ERROR: "/config/sandbox-classes.json": not found
```

So `scripts/deploy.ps1` builds with `--file worker/Dockerfile <repoRoot>`, and a
root `.dockerignore` keeps the uploaded context small (0.6 MB of `worker/` would
otherwise become 45 MB of repository). `validate.ps1` asserts the root context
and the `--file` flag stay together, because separating them breaks every `COPY`.

### Verified against the real image, not a simulation

An image-shaped directory is still a proxy. The change was also built in ACR
with the exact command `deploy.ps1` runs, and exercised in the built image:

```
$ ls /usr/local/lib/squad-on-aca/
...  sandbox-classes.json  squad-dispatch.js  ...

$ node /usr/local/lib/squad-on-aca/squad-dispatch.js decide ... (no --catalog)
{"routing":{"route":"aca-job","action":"dispatch",
 "capability":{"catalogSchemaVersion":1,"catalogProvisional":false, ...}}}
```

And the negative control, the image deployed before this change, with ACR
reporting the exit code itself:

```
squad-dispatch: cannot resolve a dispatch route: sandbox class catalog not found
failed to run step ID: acb_step_0: exit status 70
```

A note on how that exit code was obtained, because the first attempt was wrong:
an `echo EXIT=$?` inside an `az acr run` step reports **0 even for a deliberate
`exit 70`** — the task engine consumes `$?` before the shell sees it. Any exit
code read that way is fiction. Let ACR fail the step and report the status.
## One manifest-path implementation

The rule that decides whether the capability manifest at
`CAPABILITY_MANIFEST_PATH` is safe to read used to exist **twice**: once in
`worker/lib/resolve-capability-route.js` (routing, outside the session) and once
as an inline `node - <<'NODE'` heredoc inside
`worker/lib/squad-capability-preflight.sh` (the in-session gate). Both refuse a
path that escapes the repository, is absolute, is a symlink, or is not a regular
file. Two copies of a security rule drift silently: a fix applied to one leaves
the other protecting less, and nothing fails.

Sprint 2 collapsed them into `worker/lib/locate-manifest.js`. The resolver
`require()`s it; the preflight `exec`s it as a CLI.

### The corpus is driven through *both* entry points

`worker/tests/test_manifest_path_corpus.sh` reads
`worker/tests/fixtures/manifest-path-corpus.txt` and runs every shared row
through the resolver **and** through the real preflight script. That is the
whole point: **one mutation to the shared module must fail two assertions, one
per entry point.** If it fails only one, the two callers are not sharing code and
the unification is a claim rather than a fact — so `validate.ps1` asserts the
suite names both entry points, and asserts the preflight contains none of
`isWithin`, `realpathSync`, `lstatSync`, `existsSync`, `statSync`,
`path.isAbsolute`, `path.resolve`, `path.relative`.

Two subtleties are pinned by name because they are current behaviour and easy to
"fix" into a regression:

- **A dangling symlink is `absent`, not `unsafe`.** `fs.existsSync` follows the
  link and returns false, so the `lstat` symlink check is never reached. Moving
  the symlink check earlier would change this.
- **A symlink *inside* the tree pointing at a regular file inside the tree is
  still `unsafe`.** The resolver rejects *any* symlink at the manifest path. It
  is the `isWithin` check, not the symlink check, that catches a symlink
  pointing outside — so deleting the symlink check does **not** fail a
  symlink-escape assertion, only the inside-the-tree one.

The resolver side of the corpus goes through
`resolve-capability-route.js`'s **export**, not through `locate-manifest.js`
directly. Testing the shared module directly would pass unchanged if the
resolver quietly kept a private copy.

Verdicts are compared as **text plus exit code**, not exit code alone. Under a
mutation that lets `..` escape the tree, `../../../../etc/hostname` resolves as
*present*, the parser then rejects `/etc/hostname` as malformed, and the
preflight **still exits 78**. An assertion on the exit code alone stays green
while the traversal boundary is gone.

### Why criterion 3 exists: a missing module must refuse, not skip

If `locate-manifest.js` is not in the image, the preflight must **refuse the
session** — exit **69** (`EX_UNAVAILABLE`), with a message naming the missing
file. It must not report "no capability manifest present" and it must not exit 0.

This is not defensive tidiness. Deleting one filename from a Dockerfile `COPY`
line is a one-character-class edit that CI does not obviously punish, and the
failure it would otherwise produce is *"no manifest present, skipping (safe
default)"* — a **fail-open on a security boundary**, strictly worse than the
duplication that was removed. Sprint 1 shipped exactly this class of defect: a
`COPY` that could not reach above its build context, invisible to both the plan
and an image-shaped simulation because neither built anything.

So the design makes the downgrade unreachable:

| Locator exit | Meaning | Preflight |
|---|---|---|
| `0` + a path on stdout | present | proceeds with that path |
| `0` + empty stdout | (contract violation) | **69** |
| `3` | absent | `0`, "skipping (safe default)" |
| `4` | unsafe | `78`, "invalid or unsafe" |
| `64`, `70`, `1`, anything else | unclaimed | **69** |

The old scheme — "any non-zero means unsafe" plus an `__ABSENT__` stdout
sentinel — could not express this. A module that failed to load (node exits 1)
and a hostile path landed on the same branch, so the gate was fail-closed *by
luck*, and one plausible refactor (an `exit 0` fast-path) would have flipped it.
Distinct exit codes make "the module is missing" impossible to mistake for a
verdict.

`69` is deliberately **not** `78`: an operator can tell *your image is
incomplete* from *your manifest is wrong* without reading the source.

### The missing-module test derives its layout from the Dockerfile

The criterion-3 assertions build a worker library directory by **parsing the
`COPY` instructions in `worker/Dockerfile`**, the same way `test_image_layout.sh`
does. A hard-coded file list would keep the suite green for the one edit the
criterion exists to catch — removing `locate-manifest.js` from `COPY` — because
the missing-module case deletes the file itself and so is indifferent to whether
it was ever shipped. The parser is strict and loud: line continuations, the JSON
array form, and `--from=` all abort the suite rather than falling back to a
guess. A positive assertion (*the layout the Dockerfile actually ships resolves a
manifest path*) is what fails when the file is un-shipped.