<#
.SYNOPSIS
    Offline test harness that runs scripts/squad-aca.ps1 against stubbed `az`,
    `gh` and `squad` binaries on PATH.

.DESCRIPTION
    The CLI's observable behaviour is (a) what it prints, (b) the exit code it
    returns, and (c) the exact `az` command lines it issues. None of that can be
    asserted against a live subscription, so this harness fabricates a hermetic
    environment:

      * `az.cmd` and `gh.cmd` shims are written into a throwaway bin directory
        that is prepended to PATH. They append every invocation (one line per
        call, raw command line) to a log file and emit canned fixtures, so a
        test can assert exactly which Azure calls were made and in what order.
      * `squad.cmd` is stubbed in the same bin directory. `squad-aca doctor`
        reports whether the optional `squad` CLI is on PATH, so without a stub
        its table reads "ok" on a machine that has Squad installed and
        "optional" on one that does not -- and because `Format-Table -AutoSize`
        sizes the Status column to its widest cell, that one word re-pads every
        row of the table. Stubbing it makes the answer the same everywhere.
      * HOME / USERPROFILE are redirected to a throwaway directory holding a
        synthetic `~/.squad-on-aca/config.json`, so the developer's real
        deployment config can never influence a test run.
      * The CLI runs in a child process of the SAME PowerShell host, with
        stdout and stderr redirected to files, so the process exit code is
        observed exactly as a user's shell would see it. That child is started
        with DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 so dates and numbers render
        under the invariant culture rather than the host's locale.

    This mirrors the fake-`az`/fake-`gh`-on-PATH pattern already used by
    worker/tests/test_ralph_dispatch.sh. Nothing here touches Azure, GitHub, or
    the network.

    The fake `az` reads these environment variables, so a caller can drive the
    failure modes a live subscription would produce. Invoke-SquadCliCapture
    always resets them, so a CLI capture only ever sees default behaviour; the
    ACA-adapter checks in validate.ps1 set them directly:

      SQUAD_STUB_STOP_RC     exit code for `containerapp job stop`
      SQUAD_STUB_STOP_ERR    stderr line `containerapp job stop` emits (auth
                             failure, RBAC denial, throttling, not-found, ...)
      SQUAD_STUB_START_RC    exit code for `containerapp job start`
      SQUAD_STUB_EXEC_SEQ    marker file path; the FIRST
                             `containerapp job execution show` reports
                             Provisioning, later calls report Running
      SQUAD_STUB_EXEC_STUCK  "1" => every `execution show` reports Provisioning
      SQUAD_STUB_SBG_IDENTITY "1" => `az resource show` reports a managed
                             identity on the sandbox group (invariant 4 refusal)

    The fake `aca` (Sprint 5, ACA Sandboxes provider) reads these. It records
    every invocation to SQUAD_STUB_ACA_LOG exactly like the other shims, so a
    test can assert the argv sequence and its ORDER -- which is how "egress was
    applied before the worker was launched" becomes an assertion rather than a
    hope:

      SQUAD_STUB_ACA_RC        exit code for every `aca` call (default 0)
      SQUAD_STUB_ACA_ERR       stderr line every failing `aca` call emits
      SQUAD_STUB_ACA_EGRESS_RC exit code for `sandbox egress set` only
      SQUAD_STUB_ACA_DELETE_RC exit code for `sandbox delete` only
      SQUAD_STUB_ACA_DELETE_ERR stderr for `sandbox delete` only
      SQUAD_STUB_ACA_CANCEL_RC exit code for a cancel `sandbox exec` only
      SQUAD_STUB_ACA_CANCEL_ERR stderr for a cancel `sandbox exec` only. Cancel
                               needs its own pair because its failure
                               classification (auth / RBAC / throttling /
                               transport vs "already gone") is the same
                               classification terminate makes, and it has to be
                               driven independently of the launch exec's rc.
      SQUAD_STUB_ACA_POLL_DIR  directory holding the simulated sandbox state.
                               A poll (`sandbox exec` whose command reads the
                               state dir) reports phase/exit/marker from
                               phase.txt / exit.txt / done.txt in there, so a
                               test drives a long session by editing files.
      SQUAD_STUB_ACA_TIMEOUT_ONCE marker file; the FIRST `sandbox exec` fails
                               with the real client-timeout text
                               ("Network issue - retry policy expired"), later
                               ones succeed. Proves a transport timeout is
                               treated as inconclusive and re-polled.

    Used by scripts/validate.ps1 ("ACA Job adapter", "Sandbox provider" and
    "CLI behaviour regression" sections).
#>

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here. This file
# is dot-sourced into validate.ps1's scope and must not change its behaviour.

function New-SquadCliStubEnvironment {
    <#
    .SYNOPSIS
        Creates a throwaway stub environment (bin shims, fake HOME, fixtures).

    .OUTPUTS
        PSCustomObject with Root, BinDir, HomeDir, FixtureDir, WorkDir, AzLog
        and GhLog properties. Pass it to Invoke-SquadCliCapture and dispose of
        it with Remove-SquadCliStubEnvironment.
    #>
    param(
        [string]$Root = (Join-Path ([System.IO.Path]::GetTempPath()) ("squad-cli-stub-" + [guid]::NewGuid().ToString("N")))
    )

    $binDir = Join-Path $Root "bin"
    $homeDir = Join-Path $Root "home"
    $fixtureDir = Join-Path $Root "fixtures"
    $workDir = Join-Path $Root "work"
    # Durable-lease ledger for this stub run. Offline and throwaway: the fake
    # `gh` backs the GitHub Contents API with this directory.
    $leaseDir = Join-Path $Root "leases"
    foreach ($dir in @($Root, $binDir, $homeDir, $fixtureDir, $workDir, $leaseDir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $homeDir ".squad-on-aca") | Out-Null

    $azLog = Join-Path $Root "az-calls.log"
    $ghLog = Join-Path $Root "gh-calls.log"
    $squadLog = Join-Path $Root "squad-calls.log"
    $acaLog = Join-Path $Root "aca-calls.log"
    # Shared, ordered, cross-tool call log. `az` and the lease store both append
    # to it, so a test can assert that the lease write precedes the compute
    # request BY INDEX. It is deliberately NOT part of the golden capture: the
    # goldens cover observable CLI output, this covers ordering.
    $callLog = Join-Path $Root "dispatch-calls.log"
    Set-Content -LiteralPath $azLog -Value "" -NoNewline -Encoding ascii
    Set-Content -LiteralPath $ghLog -Value "" -NoNewline -Encoding ascii
    Set-Content -LiteralPath $squadLog -Value "" -NoNewline -Encoding ascii
    Set-Content -LiteralPath $acaLog -Value "" -NoNewline -Encoding ascii
    Set-Content -LiteralPath $callLog -Value "" -NoNewline -Encoding ascii

    # --- Synthetic deployment config (never the developer's real one) --------
    $config = [ordered]@{
        subscriptionId = "00000000-0000-0000-0000-000000000000"
        resourceGroup  = "rg-squad-stub"
        sessionJob     = "caj-squad-aca-session"
        ralphJob       = "caj-squad-aca-ralph"
        watchApp       = "ca-squad-aca-watch"
        aspireApp      = "ca-squad-aca-aspire"
        aspireLoginUrl = "https://aspire.stub.invalid/login"
    }
    $config | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $homeDir ".squad-on-aca\config.json") -Encoding utf8

    # --- Fixtures returned by the fake `az` ---------------------------------
    Set-Content -LiteralPath (Join-Path $fixtureDir "exec-list.json") -Encoding ascii -Value @'
[
  "caj-squad-aca-session-stub01",
  "caj-squad-aca-session-stub02"
]
'@

    # startTime deliberately carries NO UTC offset. ConvertFrom-Json turns an
    # offset-bearing instant into a DateTime with Kind=Local, so `sessions`
    # would render it in the host's time zone -- 03:04 on a UTC CI runner,
    # 22:04 the previous day on a UTC-5 laptop -- and, because
    # `Format-Table -AutoSize` sizes the Started column to its widest cell, the
    # whole table would re-pad with it. An offset-free timestamp parses as
    # Kind=Unspecified, so no conversion happens and every machine renders the
    # identical wall clock. This pins the value instead of masking it: the
    # Started column is still compared character for character.
    Set-Content -LiteralPath (Join-Path $fixtureDir "exec-show.json") -Encoding ascii -Value @'
{
  "properties": {
    "status": "Running",
    "startTime": "2026-01-02T03:04:05",
    "endTime": null,
    "template": {
      "containers": [
        {
          "env": [
            { "name": "SESSION_NAME", "value": "stub-session" },
            { "name": "SQUAD_MODE", "value": "prompt" },
            { "name": "GITHUB_REPOSITORY", "value": "octo/demo" },
            { "name": "GITHUB_REF", "value": "squad/stub-session" },
            { "name": "SQUAD_DISPATCH_ROUTE", "value": "aca-job" },
            { "name": "SQUAD_DISPATCH_SOURCE", "value": "local-cli" }
          ]
        }
      ]
    }
  }
}
'@

    # Same execution, still coming up. Used to prove the ACA adapter's `wait`
    # actually polls until the execution leaves Provisioning. Same offset-free
    # startTime, for the same time-zone reason as above.
    Set-Content -LiteralPath (Join-Path $fixtureDir "exec-show-provisioning.json") -Encoding ascii -Value @'
{
  "properties": {
    "status": "Provisioning",
    "startTime": "2026-01-02T03:04:05",
    "endTime": null,
    "template": {
      "containers": [
        {
          "env": [
            { "name": "SESSION_NAME", "value": "stub-session" },
            { "name": "SQUAD_MODE", "value": "prompt" },
            { "name": "GITHUB_REPOSITORY", "value": "octo/demo" },
            { "name": "GITHUB_REF", "value": "squad/stub-session" }
          ]
        }
      ]
    }
  }
}
'@

    Set-Content -LiteralPath (Join-Path $fixtureDir "template-env.json") -Encoding ascii -Value @'
[
  { "name": "ASPIRE_OTLP_GRPC_ENDPOINT", "value": "http://ca-squad-aca-aspire:18889" },
  { "name": "OTEL_EXPORTER_OTLP_HEADERS", "secretRef": "otlp-headers" },
  { "name": "SESSION_NAME", "value": "smoke-template" }
]
'@

    Set-Content -LiteralPath (Join-Path $fixtureDir "template-container.json") -Encoding ascii -Value @'
{
  "name": "squad-worker",
  "image": "ghcr.io/example/squad-worker:stub",
  "resources": { "cpu": 1.0, "memory": "2.0Gi" }
}
'@

    Set-Content -LiteralPath (Join-Path $fixtureDir "account-show.json") -Encoding ascii -Value @'
{ "name": "Stub Subscription", "id": "00000000-0000-0000-0000-000000000000" }
'@

    # --- Fixtures returned by the fake `aca` (Sprint 5, ACA Sandboxes) -------
    # A sandbox group with NO managed identity. This is the shape the provider
    # must see before it will run anything (PRD #6 invariant 4): private-registry
    # pulls use an ACR refresh token, never an identity the sandbox could reuse.
    Set-Content -LiteralPath (Join-Path $fixtureDir "sbg-identity-none.json") -Encoding ascii -Value @'
null
'@

    # The refusal case: a group that DOES carry an identity.
    Set-Content -LiteralPath (Join-Path $fixtureDir "sbg-identity-present.json") -Encoding ascii -Value @'
{ "type": "SystemAssigned", "principalId": "11111111-1111-1111-1111-111111111111" }
'@

    # `--name` on `aca sandboxgroup disk create` becomes a LABEL, not a
    # resolvable name, so a private disk has to be addressed by GUID resolved
    # from this listing.
    Set-Content -LiteralPath (Join-Path $fixtureDir "disk-list.json") -Encoding ascii -Value @'
[
  { "id": "aaaaaaaa-1111-2222-3333-444444444444", "name": "squad-worker-stub" },
  { "id": "bbbbbbbb-5555-6666-7777-888888888888", "name": "other-disk" }
]
'@

    Set-Content -LiteralPath (Join-Path $fixtureDir "sandbox-list.json") -Encoding ascii -Value @'
[
  { "labels": { "name": "squad-stub-session" }, "status": "Running" },
  { "labels": { "name": "not-ours" }, "status": "Running" }
]
'@

    # Concurrency ceiling: two OTHER squad-owned sandboxes are already live, so a
    # class with maxConcurrentSandboxes = 2 must refuse a third.
    Set-Content -LiteralPath (Join-Path $fixtureDir "sandbox-list-busy.json") -Encoding ascii -Value @'
[
  { "labels": { "name": "squad-other-one" }, "status": "Running" },
  { "labels": { "name": "squad-other-two" }, "status": "Running" },
  { "labels": { "name": "not-ours-either" }, "status": "Running" },
  { "labels": { "name": "not-ours-again" }, "status": "Running" }
]
'@

    # Reaper fixture. The dates are absolute rather than relative on purpose:
    # a fixture whose meaning depends on when the suite runs is the class of
    # non-determinism that already broke this repository's goldens on CI once.
    #   - squad-orphan-old   far past      -> a candidate
    #   - squad-fresh-one    far future    -> never a candidate
    #   - squad-unknown-age  no timestamp  -> undecidable, never deleted
    #   - not-ours-orphan    far past      -> not ours, never touched
    Set-Content -LiteralPath (Join-Path $fixtureDir "sandbox-list-reaper.json") -Encoding ascii -Value @'
[
  { "labels": { "name": "squad-orphan-old" }, "status": "Running", "createdAt": "2020-01-02T03:04:05" },
  { "labels": { "name": "squad-fresh-one" }, "status": "Running", "createdAt": "2099-01-02T03:04:05" },
  { "labels": { "name": "squad-unknown-age" }, "status": "Running" },
  { "labels": { "name": "not-ours-orphan" }, "status": "Running", "createdAt": "2020-01-02T03:04:05" }
]
'@

    # A listing whose labels are HOSTILE. The service is not a trusted source of
    # identifiers: these are shapes New-SandboxLabelName can never produce, and
    # each one reaches an argv (`sandbox delete -l name=<label>`) or a log line.
    #   - path traversal, to address a sibling resource
    #   - an embedded newline, to forge an audit record
    Set-Content -LiteralPath (Join-Path $fixtureDir "sandbox-list-hostile-label.json") -Encoding ascii -Value @'
[
  { "labels": { "name": "squad-../../other-tenant" }, "status": "Running", "createdAt": "2020-01-02T03:04:05" }
]
'@
    Set-Content -LiteralPath (Join-Path $fixtureDir "sandbox-list-hostile-label-2.json") -Encoding ascii -Value @'
[
  { "labels": { "name": "squad-ok\nDELETED everything" }, "status": "Running", "createdAt": "2020-01-02T03:04:05" }
]
'@
    # Brokered credential creation returns an OPAQUE id; the token itself is
    # written to stdin and never appears in the response.
    Set-Content -LiteralPath (Join-Path $fixtureDir "credential-create.json") -Encoding ascii -Value @'
{ "id": "cred-stub-0001", "type": "github-copilot" }
'@

    # --- Fake `az` ----------------------------------------------------------
    # Flat goto-based dispatch (no nested parenthesised blocks) so cmd.exe
    # parsing stays predictable for arguments containing [], {} and =.
    Set-Content -LiteralPath (Join-Path $binDir "az.cmd") -Encoding ascii -Value @'
@echo off
>>"%SQUAD_STUB_AZ_LOG%" echo %*
set "A1=%~1"
set "A2=%~2"
set "A3=%~3"
set "A4=%~4"
set "Q="
:sqparse
if "%~1"=="" goto sqdone
if "%~1"=="--query" set "Q=%~2"
shift
goto sqparse
:sqdone
if not "%A1%"=="containerapp" goto sqnotca
if not "%A2%"=="job" goto sqok
if "%A3%"=="execution" goto sqexec
if "%A3%"=="show" goto sqjobshow
if "%A3%"=="logs" goto sqjoblogs
if "%A3%"=="stop" goto sqjobstop
if "%A3%"=="start" goto sqjobstart
goto sqok
:sqexec
if "%A4%"=="list" type "%SQUAD_STUB_FIXTURES%\exec-list.json"
if "%A4%"=="show" goto sqexecshow
goto sqok
:sqexecshow
if "%SQUAD_STUB_EXEC_STUCK%"=="1" goto sqexecprov
if "%SQUAD_STUB_EXEC_SEQ%"=="" goto sqexecready
if exist "%SQUAD_STUB_EXEC_SEQ%" goto sqexecready
>"%SQUAD_STUB_EXEC_SEQ%" echo seen
goto sqexecprov
:sqexecprov
type "%SQUAD_STUB_FIXTURES%\exec-show-provisioning.json"
goto sqok
:sqexecready
type "%SQUAD_STUB_FIXTURES%\exec-show.json"
goto sqok
:sqjobshow
if "%Q%"=="properties.template.containers[0].env" goto sqtplenv
if "%Q%"=="properties.template.containers[0]" goto sqtplcontainer
echo /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-squad-stub/providers/Microsoft.App/jobs/stub
goto sqok
:sqtplenv
type "%SQUAD_STUB_FIXTURES%\template-env.json"
goto sqok
:sqtplcontainer
type "%SQUAD_STUB_FIXTURES%\template-container.json"
goto sqok
:sqjoblogs
echo STUB-LOG-LINE-1
echo STUB-LOG-LINE-2
goto sqok
:sqjobstop
echo STUB-STOP-ACK
if not "%SQUAD_STUB_STOP_ERR%"=="" >&2 echo %SQUAD_STUB_STOP_ERR%
exit /b %SQUAD_STUB_STOP_RC%
:sqjobstart
if not "%SQUAD_CALL_LOG%"=="" >>"%SQUAD_CALL_LOG%" echo az job-start
echo STUB-START-ACK
exit /b %SQUAD_STUB_START_RC%
:sqnotca
if "%A1%"=="resource" goto sqresource
if not "%A1%"=="account" goto sqok
if not "%A2%"=="show" goto sqok
type "%SQUAD_STUB_FIXTURES%\account-show.json"
goto sqok
:sqresource
if not "%A2%"=="show" goto sqok
if "%SQUAD_STUB_SBG_IDENTITY%"=="1" type "%SQUAD_STUB_FIXTURES%\sbg-identity-present.json"
if not "%SQUAD_STUB_SBG_IDENTITY%"=="1" type "%SQUAD_STUB_FIXTURES%\sbg-identity-none.json"
exit /b %SQUAD_STUB_SBG_RC%
:sqok
exit /b 0
'@

    # --- Fake `gh` ----------------------------------------------------------
    # `api` is answered here as well as by fake-gh.js: the lease store spawns
    # `gh` through SQUAD_GH_BIN, but `doctor` calls `gh` straight off PATH to
    # check whether the ACTIVE identity can WRITE to the repository (issue #22).
    # SQUAD_STUB_GH_PUSH / SQUAD_STUB_GH_LOGIN / SQUAD_STUB_GH_API_RC let a test
    # drive the read-only-account case and the probe-failed case without a
    # second harness.
    Set-Content -LiteralPath (Join-Path $binDir "gh.cmd") -Encoding ascii -Value @'
@echo off
>>"%SQUAD_STUB_GH_LOG%" echo %*
if "%~1"=="repo" goto ghrepo
if "%~1"=="pr" goto ghpr
if "%~1"=="api" goto ghapi
exit /b 0
:ghrepo
echo octo/demo
exit /b 0
:ghpr
echo []
exit /b 0
:ghapi
if not "%SQUAD_STUB_GH_API_RC%"=="" if not "%SQUAD_STUB_GH_API_RC%"=="0" exit /b %SQUAD_STUB_GH_API_RC%
if "%~2"=="user" goto ghuser
if "%SQUAD_STUB_GH_PUSH%"=="false" goto ghnopush
echo {"admin":true,"pull":true,"push":true}
exit /b 0
:ghnopush
echo {"admin":false,"pull":true,"push":false}
exit /b 0
:ghuser
if "%SQUAD_STUB_GH_LOGIN%"=="" echo octo-stub
if not "%SQUAD_STUB_GH_LOGIN%"=="" echo %SQUAD_STUB_GH_LOGIN%
exit /b 0
'@

    # --- Fake `squad` -------------------------------------------------------
    # `squad` is OPTIONAL for squad-aca (only `init` uses it, with an npx
    # fallback), so whether it is installed is a property of the developer's
    # machine, not of the CLI. `doctor` reports that as ok / optional. Stubbing
    # it makes the answer "installed" on every machine, which is what keeps the
    # doctor golden portable. It logs like the other shims, so if any command
    # ever starts shelling out to it that becomes a visible capture diff rather
    # than a silent behaviour change.
    Set-Content -LiteralPath (Join-Path $binDir "squad.cmd") -Encoding ascii -Value @'
@echo off
>>"%SQUAD_STUB_SQUAD_LOG%" echo %*
echo STUB-SQUAD-ACK
exit /b 0
'@

    # --- Fake `aca` (Sprint 5, ACA Sandboxes) -------------------------------
    # ACA Sandboxes are driven by a standalone `aca` binary, not by an `az`
    # extension, so this is a separate shim with its own log. The log is what
    # turns "egress is applied before any repository code runs" into an
    # assertion: a test reads the recorded argv sequence and compares INDEXES.
    #
    # Same flat goto dispatch as the fake `az`, for the same reason -- the
    # `-c` argument carries a whole shell command full of &, > and | and must
    # arrive intact. Delayed expansion is switched on only where the command
    # text has to be inspected.
    #
    # Sprint 7 added STDIN handling. `set /p` reads one line from standard
    # input, which is exactly how the real `aca` accepts a token that must not
    # appear on a command line. Recording what arrived on stdin to a file is
    # what turns "the credential is delivered out of band" into a behavioural
    # assertion: the test can prove BOTH that the token never appeared in the
    # recorded argv AND that the full value still reached the process.
    Set-Content -LiteralPath (Join-Path $binDir "aca.cmd") -Encoding ascii -Value @'
@echo off
>>"%SQUAD_STUB_ACA_LOG%" echo %*
set "A1=%~1"
set "A2=%~2"
set "A3=%~3"
set "CMD="
:acaparse
if "%~1"=="" goto acaparsed
if "%~1"=="-c" set "CMD=%~2"
shift
goto acaparse
:acaparsed
if "%A1%"=="sandboxgroup" goto acasbg
if not "%A1%"=="sandbox" goto acaok
if "%A2%"=="create" goto acacreate
if "%A2%"=="egress" goto acaegress
if "%A2%"=="lifecycle" goto acalifecycle
if "%A2%"=="exec" goto acaexec
if "%A2%"=="list" goto acalist
if "%A2%"=="delete" goto acadelete
goto acaok
:acasbg
if "%A2%"=="credential" goto acacred
if not "%A2%"=="disk" goto acaok
if not "%A3%"=="list" goto acaok
type "%SQUAD_STUB_FIXTURES%\disk-list.json"
exit /b %SQUAD_STUB_ACA_RC%
:acacred
if "%A3%"=="delete" goto acacreddel
if not "%A3%"=="create" goto acaok
set "TOK="
set /p TOK=
if not "%SQUAD_STUB_ACA_CRED_STDIN%"=="" >"%SQUAD_STUB_ACA_CRED_STDIN%" echo %TOK%
if not "%SQUAD_STUB_ACA_CRED_ERR%"=="" >&2 echo %SQUAD_STUB_ACA_CRED_ERR%
if not "%SQUAD_STUB_ACA_CRED_RC%"=="0" exit /b %SQUAD_STUB_ACA_CRED_RC%
if "%SQUAD_STUB_ACA_CRED_ID%"=="" goto acacredfixture
echo {"id": "%SQUAD_STUB_ACA_CRED_ID%"}
exit /b 0
:acacredfixture
type "%SQUAD_STUB_FIXTURES%\credential-create.json"
exit /b 0
:acacreddel
if not "%SQUAD_STUB_ACA_CREDDEL_ERR%"=="" >&2 echo %SQUAD_STUB_ACA_CREDDEL_ERR%
exit /b %SQUAD_STUB_ACA_CREDDEL_RC%
:acacreate
echo STUB-SANDBOX-CREATED
if not "%SQUAD_STUB_ACA_ERR%"=="" >&2 echo %SQUAD_STUB_ACA_ERR%
exit /b %SQUAD_STUB_ACA_RC%
:acaegress
if not "%SQUAD_STUB_ACA_EGRESS_ERR%"=="" >&2 echo %SQUAD_STUB_ACA_EGRESS_ERR%
exit /b %SQUAD_STUB_ACA_EGRESS_RC%
:acalifecycle
exit /b %SQUAD_STUB_ACA_RC%
:acalist
if "%SQUAD_STUB_ACA_LIST_RC%"=="" set "SQUAD_STUB_ACA_LIST_RC=%SQUAD_STUB_ACA_RC%"
if not "%SQUAD_STUB_ACA_LIST_ERR%"=="" >&2 echo %SQUAD_STUB_ACA_LIST_ERR%
if "%SQUAD_STUB_ACA_LIST_FIXTURE%"=="" goto acalistdefault
type "%SQUAD_STUB_FIXTURES%\%SQUAD_STUB_ACA_LIST_FIXTURE%"
exit /b %SQUAD_STUB_ACA_LIST_RC%
:acalistdefault
type "%SQUAD_STUB_FIXTURES%\sandbox-list.json"
exit /b %SQUAD_STUB_ACA_LIST_RC%
:acadelete
if not "%SQUAD_STUB_ACA_DELETE_ERR%"=="" >&2 echo %SQUAD_STUB_ACA_DELETE_ERR%
exit /b %SQUAD_STUB_ACA_DELETE_RC%
:acaexec
if "%SQUAD_STUB_ACA_TIMEOUT_ONCE%"=="" goto acaexec2
if exist "%SQUAD_STUB_ACA_TIMEOUT_ONCE%" goto acaexec2
>"%SQUAD_STUB_ACA_TIMEOUT_ONCE%" echo seen
>&2 echo Error: Network issue - retry policy expired
exit /b 1
:acaexec2
setlocal enabledelayedexpansion
if not "!CMD:squad-credentials-staged=!"=="!CMD!" goto acaseed
if not "!CMD:squad-launched=!"=="!CMD!" goto acalaunch
if not "!CMD:squad-cancelled=!"=="!CMD!" goto acacancel
if not "!CMD:echo marker=!"=="!CMD!" goto acapoll
if not "!CMD:tail -n=!"=="!CMD!" goto acalogs
endlocal
goto acaok
:acaseed
endlocal
set "TOK="
set /p TOK=
if not "%SQUAD_STUB_ACA_SEED_STDIN%"=="" >"%SQUAD_STUB_ACA_SEED_STDIN%" echo %TOK%
echo squad-credentials-staged
exit /b %SQUAD_STUB_ACA_SEED_RC%
:acalaunch
endlocal
echo squad-launched
exit /b %SQUAD_STUB_ACA_EXEC_RC%
:acacancel
endlocal
echo squad-cancelled
if not "%SQUAD_STUB_ACA_CANCEL_ERR%"=="" >&2 echo %SQUAD_STUB_ACA_CANCEL_ERR%
exit /b %SQUAD_STUB_ACA_CANCEL_RC%
:acalogs
endlocal
if exist "%SQUAD_STUB_ACA_POLL_DIR%\session-log.txt" type "%SQUAD_STUB_ACA_POLL_DIR%\session-log.txt"
exit /b %SQUAD_STUB_ACA_EXEC_RC%
:acapoll
endlocal
set "P=unknown"
set "E=none"
set "M=absent"
if exist "%SQUAD_STUB_ACA_POLL_DIR%\phase.txt" set /p P=<"%SQUAD_STUB_ACA_POLL_DIR%\phase.txt"
if exist "%SQUAD_STUB_ACA_POLL_DIR%\exit.txt" set /p E=<"%SQUAD_STUB_ACA_POLL_DIR%\exit.txt"
if exist "%SQUAD_STUB_ACA_POLL_DIR%\done.txt" set "M=done"
echo phase=%P%
echo exit=%E%
echo marker=%M%
exit /b %SQUAD_STUB_ACA_EXEC_RC%
:acaok
exit /b 0
'@

    return [pscustomobject]@{
        Root       = $Root
        BinDir     = $binDir
        HomeDir    = $homeDir
        FixtureDir = $fixtureDir
        WorkDir    = $workDir
        AzLog      = $azLog
        GhLog      = $ghLog
        SquadLog   = $squadLog
        AcaLog     = $acaLog
        LeaseDir   = $leaseDir
        CallLog    = $callLog
        FakeGhPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "worker\tests\lib\fake-gh.js")
    }
}

function Initialize-SquadCliStubRepository {
    <#
    .SYNOPSIS
        Turns the stub work directory into a real git repo with a local bare
        origin and a minimal .squad/ state tree.

    .DESCRIPTION
        `squad-aca run` refuses to dispatch without .squad/team.md and syncs
        Squad state (add / commit / push) before starting the execution. Both
        are real git operations, so covering `run` needs a real repository --
        just not a remote one. The "origin" here is a bare repo inside the same
        throwaway directory, so the push is local and offline.
    #>
    param([Parameter(Mandatory = $true)][object]$Stub)

    $origin = Join-Path $Stub.Root "origin.git"
    git init --quiet --bare $origin 2>&1 | Out-Null

    Push-Location $Stub.WorkDir
    try {
        git init --quiet --initial-branch=main 2>&1 | Out-Null
        git config user.email "stub@example.invalid" | Out-Null
        git config user.name "Squad Stub" | Out-Null
        git config commit.gpgsign false | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $Stub.WorkDir ".squad") | Out-Null
        Set-Content -LiteralPath (Join-Path $Stub.WorkDir ".squad\team.md") -Value "# Stub team" -Encoding utf8
        Set-Content -LiteralPath (Join-Path $Stub.WorkDir "README.md") -Value "# stub" -Encoding utf8
        git add -A 2>&1 | Out-Null
        git commit --quiet -m "stub baseline" 2>&1 | Out-Null
        git remote add origin $origin 2>&1 | Out-Null
        git push --quiet -u origin main 2>&1 | Out-Null
    } finally {
        Pop-Location
    }
    return $origin
}

function Reset-SquadCliStubLog {
    <#
    .SYNOPSIS
        Truncates the recorded az/gh/squad/aca invocation logs between cases.
    #>
    param([Parameter(Mandatory = $true)][object]$Stub)
    Set-Content -LiteralPath $Stub.AzLog -Value "" -NoNewline -Encoding ascii
    Set-Content -LiteralPath $Stub.GhLog -Value "" -NoNewline -Encoding ascii
    if ($Stub.SquadLog) { Set-Content -LiteralPath $Stub.SquadLog -Value "" -NoNewline -Encoding ascii }
    if ($Stub.AcaLog) { Set-Content -LiteralPath $Stub.AcaLog -Value "" -NoNewline -Encoding ascii }
}

function Get-SquadCliStubCall {
    <#
    .SYNOPSIS
        Returns the recorded command lines for the fake az (default), gh, squad
        or aca.

    .DESCRIPTION
        The `aca` log is ordered, and that order is the point: a caller can
        assert that the egress call was recorded BEFORE the exec that launched
        the worker, which is the only way to test "policy is applied before any
        repository code runs" rather than merely "policy is applied".
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Stub,
        [ValidateSet("az", "gh", "squad", "aca")][string]$Tool = "az"
    )
    $path = switch ($Tool) {
        "gh"    { $Stub.GhLog }
        "squad" { $Stub.SquadLog }
        "aca"   { $Stub.AcaLog }
        default { $Stub.AzLog }
    }
    if (-not $path -or -not (Test-Path $path)) { return @() }
    $raw = Get-Content -LiteralPath $path -Raw
    if (-not $raw) { return @() }
    return @(($raw -split "`r?`n") | Where-Object { $_ -ne "" } | ForEach-Object { $_.Trim() })
}

function Invoke-SquadCliCapture {
    <#
    .SYNOPSIS
        Runs squad-aca.ps1 in a child process under the stub environment and
        captures stdout, stderr, and the real process exit code.

    .PARAMETER ScriptPath
        Full path to the squad-aca.ps1 under test. Parameterised so the same
        harness can drive a baseline copy of the script for differential
        comparison against another revision.

    .PARAMETER StopExitCode
        Exit code the fake `az containerapp job stop` returns. Used to prove the
        CLI propagates an Azure failure instead of swallowing it.

    .PARAMETER GhPush
        What the fake `gh api repos/<owner>/<name> --jq .permissions` reports for
        `push`. "false" drives the issue #22 case: an identity that can read the
        repository but not write to it.

    .PARAMETER GhApiExitCode
        Exit code the fake `gh api` returns. Non-zero drives the probe-failed
        fallback, where a diagnostic must not replace the real error.

    .PARAMETER GhFailMode / GhFailPath / GhPermissions / GhLogin
        Passed through to worker/tests/lib/fake-gh.js, which backs the lease
        store. Same knobs the bash suite uses, so both languages are driven
        against one implementation of GitHub's semantics.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Stub,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$CliArguments = @(),
        [int]$StopExitCode = 0,
        [int]$StartExitCode = 0,
        [string]$GhPush = "true",
        [string]$GhLogin = "octo-stub",
        [int]$GhApiExitCode = 0,
        [string]$GhFailMode = "",
        [string]$GhFailPath = "",
        [string]$GhPermissions = ""
    )

    $hostExe = (Get-Process -Id $PID).Path
    $outFile = Join-Path $Stub.Root ("out-" + [guid]::NewGuid().ToString("N") + ".txt")
    $errFile = Join-Path $Stub.Root ("err-" + [guid]::NewGuid().ToString("N") + ".txt")

    $envNames = @("PATH", "HOME", "HOMEDRIVE", "HOMEPATH", "USERPROFILE",
                  "DOTNET_SYSTEM_GLOBALIZATION_INVARIANT",
                  "SQUAD_STUB_AZ_LOG", "SQUAD_STUB_GH_LOG", "SQUAD_STUB_SQUAD_LOG",
                  "SQUAD_STUB_ACA_LOG",
                  "SQUAD_STUB_FIXTURES",
                  "SQUAD_STUB_STOP_RC", "SQUAD_STUB_START_RC",
                  "SQUAD_STUB_STOP_ERR", "SQUAD_STUB_EXEC_SEQ", "SQUAD_STUB_EXEC_STUCK",
                  "SQUAD_STUB_SBG_IDENTITY", "SQUAD_STUB_SBG_RC",
                  "SQUAD_STUB_ACA_RC", "SQUAD_STUB_ACA_ERR",
                  "SQUAD_STUB_ACA_EXEC_RC", "SQUAD_STUB_ACA_EGRESS_RC", "SQUAD_STUB_ACA_EGRESS_ERR",
                  "SQUAD_STUB_ACA_DELETE_RC", "SQUAD_STUB_ACA_DELETE_ERR",
                  "SQUAD_STUB_ACA_CANCEL_RC", "SQUAD_STUB_ACA_CANCEL_ERR",
                  "SQUAD_STUB_ACA_POLL_DIR", "SQUAD_STUB_ACA_TIMEOUT_ONCE",
                  "SQUAD_ACA_ENABLE_SANDBOX", "SQUAD_ACA_SANDBOX_CLI",
                  "SQUAD_STUB_GH_PUSH", "SQUAD_STUB_GH_LOGIN", "SQUAD_STUB_GH_API_RC",
                  "SQUAD_GH_BIN", "FAKE_GH_STATE", "FAKE_GH_FAIL_MODE", "FAKE_GH_FAIL_PATH",
                  "FAKE_GH_PERMISSIONS", "FAKE_GH_LOGIN", "SQUAD_CALL_LOG",
                  "SQUAD_LEASE_NOW", "SQUAD_LEASE_TTL_SECONDS", "SQUAD_LEASE_BRANCH")
    $saved = @{}
    foreach ($name in $envNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }

    $exitCode = $null
    try {
        $env:PATH = "$($Stub.BinDir);$($env:PATH)"
        # Cover every way a PowerShell host derives $HOME (5.1 uses
        # HOMEDRIVE+HOMEPATH; 7 prefers HOME, then USERPROFILE).
        $root = [System.IO.Path]::GetPathRoot($Stub.HomeDir).TrimEnd('\')
        $env:HOME = $Stub.HomeDir
        $env:USERPROFILE = $Stub.HomeDir
        $env:HOMEDRIVE = $root
        $env:HOMEPATH = $Stub.HomeDir.Substring($root.Length)
        $env:SQUAD_STUB_AZ_LOG = $Stub.AzLog
        $env:SQUAD_STUB_GH_LOG = $Stub.GhLog
        $env:SQUAD_STUB_SQUAD_LOG = $Stub.SquadLog
        $env:SQUAD_STUB_FIXTURES = $Stub.FixtureDir
        # Dates and numbers otherwise render under the host's locale, so a
        # capture taken on an en-US box would not match one taken on a de-DE
        # box. .NET honours this switch on every platform, including Windows,
        # where there is no per-process time-zone or culture override.
        $env:DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = "1"
        $env:SQUAD_STUB_STOP_RC = "$StopExitCode"
        $env:SQUAD_STUB_START_RC = "$StartExitCode"
        # The adapter-level checks in validate.ps1 drive these; a CLI capture
        # must always see the default (quiet, sequence-free) stub behaviour.
        $env:SQUAD_STUB_STOP_ERR = ""
        $env:SQUAD_STUB_EXEC_SEQ = ""
        $env:SQUAD_STUB_EXEC_STUCK = ""
        $env:SQUAD_STUB_SBG_IDENTITY = ""
        $env:SQUAD_STUB_SBG_RC = "0"
        # The `aca` shim is on PATH for every capture so that any command which
        # ever starts shelling out to it shows up as a capture diff -- and the
        # captures RECORD its calls in an `### ACA CALLS` section, which is what
        # makes that claim true rather than aspirational. It must be quiet and
        # default-configured, exactly like the `az` shim.
        $env:SQUAD_STUB_ACA_LOG = $Stub.AcaLog
        $env:SQUAD_STUB_ACA_RC = "0"
        $env:SQUAD_STUB_ACA_ERR = ""
        $env:SQUAD_STUB_ACA_EXEC_RC = "0"
        $env:SQUAD_STUB_ACA_EGRESS_RC = "0"
        $env:SQUAD_STUB_ACA_EGRESS_ERR = ""
        $env:SQUAD_STUB_ACA_DELETE_RC = "0"
        $env:SQUAD_STUB_ACA_DELETE_ERR = ""
        $env:SQUAD_STUB_ACA_CANCEL_RC = "0"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = ""
        $env:SQUAD_STUB_ACA_POLL_DIR = ""
        $env:SQUAD_STUB_ACA_TIMEOUT_ONCE = ""
        # THE golden-portability pin for Sprint 5. A CLI capture must always be
        # taken with the sandbox feature flag OFF, whatever the developer's shell
        # happens to have exported -- that is what makes "flag off is
        # byte-identical to main" a property the golden gate actually tests
        # rather than an accident of the machine it ran on.
        $env:SQUAD_ACA_ENABLE_SANDBOX = ""
        $env:SQUAD_ACA_SANDBOX_CLI = ""
        # --- Dispatch leases (Sprint 6) -------------------------------------
        # Every dispatch now writes a durable lease through `gh` before compute
        # is requested. The lease store spawns `gh` itself, so it is pointed at
        # the SAME offline fake the worker suite uses -- one implementation of
        # GitHub's semantics for both languages. The clock and TTL are pinned so
        # a capture can never depend on how long the run took, and the ledger is
        # a throwaway directory inside the stub root.
        $env:SQUAD_GH_BIN = $Stub.FakeGhPath
        $env:FAKE_GH_STATE = $Stub.LeaseDir
        $env:FAKE_GH_FAIL_MODE = $GhFailMode
        $env:FAKE_GH_FAIL_PATH = $GhFailPath
        $env:FAKE_GH_PERMISSIONS = $GhPermissions
        $env:FAKE_GH_LOGIN = $GhLogin
        # `doctor` asks `gh` on PATH whether the ACTIVE identity can write here
        # (issue #22). Pinned so the answer is a property of the stub, not of the
        # developer's GitHub account, which is what keeps the doctor golden
        # portable.
        $env:SQUAD_STUB_GH_PUSH = $GhPush
        $env:SQUAD_STUB_GH_LOGIN = $GhLogin
        $env:SQUAD_STUB_GH_API_RC = "$GhApiExitCode"
        $env:SQUAD_CALL_LOG = $Stub.CallLog
        $env:SQUAD_LEASE_NOW = "2024-05-01T00:00:00.000Z"
        $env:SQUAD_LEASE_TTL_SECONDS = "3600"
        $env:SQUAD_LEASE_BRANCH = "squad-aca-leases"

        $argList = @("-NoProfile", "-NonInteractive", "-File", $ScriptPath) + $CliArguments
        $proc = Start-Process -FilePath $hostExe -ArgumentList $argList `
            -WorkingDirectory $Stub.WorkDir -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $exitCode = $proc.ExitCode
    } finally {
        foreach ($name in $envNames) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
        }
    }

    $stdout = ""
    $stderr = ""
    if (Test-Path $outFile) { $stdout = [System.IO.File]::ReadAllText($outFile) }
    if (Test-Path $errFile) { $stderr = [System.IO.File]::ReadAllText($errFile) }
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ExitCode   = $exitCode
        StdOut     = $stdout
        StdErr     = $stderr
        AzCalls    = @(Get-SquadCliStubCall -Stub $Stub -Tool az)
        GhCalls    = @(Get-SquadCliStubCall -Stub $Stub -Tool gh)
        SquadCalls = @(Get-SquadCliStubCall -Stub $Stub -Tool squad)
        AcaCalls   = @(Get-SquadCliStubCall -Stub $Stub -Tool aca)
    }
}

function Remove-SquadCliStubEnvironment {
    param([Parameter(Mandatory = $true)][object]$Stub)
    if ($Stub -and $Stub.Root -and (Test-Path $Stub.Root)) {
        Remove-Item -LiteralPath $Stub.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
