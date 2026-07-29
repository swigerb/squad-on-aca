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

    Used by scripts/validate.ps1 ("ACA Job adapter" and "CLI behaviour
    regression" sections).
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
    foreach ($dir in @($Root, $binDir, $homeDir, $fixtureDir, $workDir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $homeDir ".squad-on-aca") | Out-Null

    $azLog = Join-Path $Root "az-calls.log"
    $ghLog = Join-Path $Root "gh-calls.log"
    $squadLog = Join-Path $Root "squad-calls.log"
    Set-Content -LiteralPath $azLog -Value "" -NoNewline -Encoding ascii
    Set-Content -LiteralPath $ghLog -Value "" -NoNewline -Encoding ascii
    Set-Content -LiteralPath $squadLog -Value "" -NoNewline -Encoding ascii

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
            { "name": "GITHUB_REF", "value": "squad/stub-session" }
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
echo STUB-START-ACK
exit /b %SQUAD_STUB_START_RC%
:sqnotca
if not "%A1%"=="account" goto sqok
if not "%A2%"=="show" goto sqok
type "%SQUAD_STUB_FIXTURES%\account-show.json"
goto sqok
:sqok
exit /b 0
'@

    # --- Fake `gh` ----------------------------------------------------------
    Set-Content -LiteralPath (Join-Path $binDir "gh.cmd") -Encoding ascii -Value @'
@echo off
>>"%SQUAD_STUB_GH_LOG%" echo %*
if "%~1"=="repo" goto ghrepo
if "%~1"=="pr" goto ghpr
exit /b 0
:ghrepo
echo octo/demo
exit /b 0
:ghpr
echo []
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

    return [pscustomobject]@{
        Root       = $Root
        BinDir     = $binDir
        HomeDir    = $homeDir
        FixtureDir = $fixtureDir
        WorkDir    = $workDir
        AzLog      = $azLog
        GhLog      = $ghLog
        SquadLog   = $squadLog
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
        Truncates the recorded az/gh/squad invocation logs between cases.
    #>
    param([Parameter(Mandatory = $true)][object]$Stub)
    Set-Content -LiteralPath $Stub.AzLog -Value "" -NoNewline -Encoding ascii
    Set-Content -LiteralPath $Stub.GhLog -Value "" -NoNewline -Encoding ascii
    if ($Stub.SquadLog) { Set-Content -LiteralPath $Stub.SquadLog -Value "" -NoNewline -Encoding ascii }
}

function Get-SquadCliStubCall {
    <#
    .SYNOPSIS
        Returns the recorded command lines for the fake az (default), gh or
        squad.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Stub,
        [ValidateSet("az", "gh", "squad")][string]$Tool = "az"
    )
    $path = switch ($Tool) {
        "gh"    { $Stub.GhLog }
        "squad" { $Stub.SquadLog }
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
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Stub,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$CliArguments = @(),
        [int]$StopExitCode = 0,
        [int]$StartExitCode = 0
    )

    $hostExe = (Get-Process -Id $PID).Path
    $outFile = Join-Path $Stub.Root ("out-" + [guid]::NewGuid().ToString("N") + ".txt")
    $errFile = Join-Path $Stub.Root ("err-" + [guid]::NewGuid().ToString("N") + ".txt")

    $envNames = @("PATH", "HOME", "HOMEDRIVE", "HOMEPATH", "USERPROFILE",
                  "DOTNET_SYSTEM_GLOBALIZATION_INVARIANT",
                  "SQUAD_STUB_AZ_LOG", "SQUAD_STUB_GH_LOG", "SQUAD_STUB_SQUAD_LOG",
                  "SQUAD_STUB_FIXTURES",
                  "SQUAD_STUB_STOP_RC", "SQUAD_STUB_START_RC",
                  "SQUAD_STUB_STOP_ERR", "SQUAD_STUB_EXEC_SEQ", "SQUAD_STUB_EXEC_STUCK")
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
    }
}

function Remove-SquadCliStubEnvironment {
    param([Parameter(Mandatory = $true)][object]$Stub)
    if ($Stub -and $Stub.Root -and (Test-Path $Stub.Root)) {
        Remove-Item -LiteralPath $Stub.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
