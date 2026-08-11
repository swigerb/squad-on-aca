<#
.SYNOPSIS
    Offline stub harness for PC-1 (issue #86) live-mode integration tests.

.DESCRIPTION
    Creates a throwaway `az.cmd` shim on PATH that answers exactly the
    command shapes scripts/lib/proc-isolation-reader.ps1 issues (account
    show, containerapp job execution list, containerapp job logs show) for
    one synthetic deployment:

      resource group   : rg-pc1-stub
      name prefix       : pc1stub  (session job caj-pc1stub-session)

    Three response modes, selected by SQUAD_PROC_ISO_STUB_MODE:

      "observed-yes"   -- the most recent execution's log contains the
                          probe's line reporting same-uid-environ-readable=yes.
      "observed-no"    -- same, reporting =no.
      "fail-one"       -- L2: two executions are listed; the first one's log
                          read fails (exit 9), the second reads cleanly with
                          no probe line. A partial read must exit 3
                          (inconclusive-partial-read), never 0.
      "fail-all"       -- L2: two executions are listed and BOTH log reads
                          fail. Nothing was read, so nothing is known: this
                          must exit 2 (live read unavailable), never 0 /
                          not-yet-observed.
      "show-fails"     -- L3: `containerapp job show` fails, so the container
                          name cannot be resolved from the live template and
                          the reader must fall back to the job name as an
                          explicitly-reported assumption. The stub then
                          accepts the job name as --container.
      unset / anything else -- the execution's log contains ordinary lines
                          but no SQUAD-PROC-ISO line at all (not-yet-observed).

    The stub also enforces the WIRE SHAPE of every logs-show call, exactly as
    the live CLI does, so a regression is caught here rather than being
    discovered as an unexplained empty read against a real deployment:

      * `--format json` must be present (the parser's unwrap step depends on
        the NDJSON envelope; a default is not a contract).
      * `--tail` must be present and within 0-300; anything larger is what
        the real CLI rejects as a usage error, and is what both prior
        revisions silently sent.
      * `--container` must name the container the stub's own job template
        reports (`squad-probe`) -- not the job name -- unless the template
        read itself failed ("show-fails"), in which case the job name is the
        documented assumption.

    Every invocation is appended to SQUAD_PROC_ISO_STUB_LOG (raw argv, one
    call per line) so a test can assert the exact sequence of `az` calls this
    deployment shape produces -- and, just as importantly, that no other call
    was ever made (no mutating verb, no exec, no bare 'account set').

    Used by scripts/validate.ps1's "Process-isolation report (PC-1)" section.
#>

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here,
# matching scripts/tests/rbac-drift-stub-harness.ps1 and
# scripts/tests/job-drift-stub-harness.ps1.

$script:ProcIsoStubSubscriptionId = "aaaaaaaa-1111-1111-1111-111111111111"
$script:ProcIsoStubResourceGroup = "rg-pc1-stub"
$script:ProcIsoStubNamePrefix = "pc1stub"
$script:ProcIsoStubJobName = "caj-pc1stub-session"
$script:ProcIsoStubExecutionName = "caj-pc1stub-session-stub01"

function New-ProcIsoStubEnvironment {
    param(
        [string]$Root = (Join-Path ([System.IO.Path]::GetTempPath()) ("proc-iso-stub-" + [guid]::NewGuid().ToString("N")))
    )
    $binDir = Join-Path $Root "bin"
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $azLog = Join-Path $Root "az-calls.log"
    Set-Content -LiteralPath $azLog -Value "" -NoNewline -Encoding ascii

    Set-Content -LiteralPath (Join-Path $binDir "az.cmd") -Encoding ascii -Value @'
@echo off
setlocal enabledelayedexpansion
if not "%SQUAD_PROC_ISO_STUB_LOG%"=="" (>>"%SQUAD_PROC_ISO_STUB_LOG%" echo %*)
set "A1=%~1"
set "A2=%~2"
set "A3=%~3"
set "A4=%~4"
set "EXPECTED_CONTAINER=squad-probe"
if "%SQUAD_PROC_ISO_STUB_MODE%"=="show-fails" set "EXPECTED_CONTAINER=caj-pc1stub-session"
if "%A1%"=="account" goto piaccount
if "%A1%"=="containerapp" if "%A2%"=="job" if "%A3%"=="show" goto pishow
if "%A1%"=="containerapp" if "%A2%"=="job" if "%A3%"=="execution" if "%A4%"=="list" goto pilist
if "%A1%"=="containerapp" if "%A2%"=="job" if "%A3%"=="logs" if "%A4%"=="show" goto pilogs
>&2 echo ERROR: unhandled stub command: %*
exit /b 9

:piaccount
echo {"id":"aaaaaaaa-1111-1111-1111-111111111111","name":"PC1 Stub Subscription"}
exit /b 0

:pishow
rem L3: the job template is what names the container. In "show-fails" mode
rem this read is refused, so the reader must fall back to the job name AND
rem say out loud that it assumed it.
if "%SQUAD_PROC_ISO_STUB_MODE%"=="show-fails" goto pishowfail
echo squad-probe
exit /b 0
:pishowfail
>&2 echo ERROR: stub refuses 'containerapp job show' in show-fails mode
exit /b 9

:pilist
if "%SQUAD_PROC_ISO_STUB_MODE%"=="fail-one" goto pilisttwo
if "%SQUAD_PROC_ISO_STUB_MODE%"=="fail-all" goto pilisttwo
echo ["caj-pc1stub-session-stub01"]
exit /b 0
:pilisttwo
echo ["caj-pc1stub-session-stub01","caj-pc1stub-session-stub02"]
exit /b 0

:pilogs
rem Wire-shape enforcement, mirroring what the real CLI accepts.
echo %*|findstr /C:"--format json" >nul
if errorlevel 1 (
    >&2 echo ERROR: stub requires --format json on 'containerapp job logs show', got: %*
    exit /b 9
)
echo %*|findstr /C:"--container %EXPECTED_CONTAINER% " >nul
if errorlevel 1 (
    >&2 echo ERROR: stub requires --container %EXPECTED_CONTAINER% -- the name the job template reports -- got: %*
    exit /b 9
)
set "TAILV="
set "PREV="
for %%A in (%*) do (
    if "!PREV!"=="--tail" set "TAILV=%%A"
    set "PREV=%%A"
)
if not defined TAILV (
    >&2 echo ERROR: stub requires an explicit --tail on 'containerapp job logs show', got: %*
    exit /b 9
)
if !TAILV! GTR 300 (
    >&2 echo ERROR: argument --tail: invalid value !TAILV!: the value must be between 0 and 300
    exit /b 9
)
if !TAILV! LSS 0 (
    >&2 echo ERROR: argument --tail: invalid value !TAILV!: the value must be between 0 and 300
    exit /b 9
)
if "%SQUAD_PROC_ISO_STUB_MODE%"=="fail-all" goto pilogsfail
if not "%SQUAD_PROC_ISO_STUB_MODE%"=="fail-one" goto pilogsok
echo %*|findstr /C:"stub01" >nul
if errorlevel 1 goto pilogsok
goto pilogsfail

:pilogsfail
>&2 echo ERROR: (ContainerAppExecutionLogsNotAvailable) logs for this execution could not be read
exit /b 9

:pilogsok
echo {"Log":"ordinary startup line","TimeStamp":"2026-08-11T00:00:00.000000Z"}
if "%SQUAD_PROC_ISO_STUB_MODE%"=="observed-yes" (
    echo {"Log":"SQUAD-PROC-ISO v1 same-uid-environ-readable=yes proc-mounted=yes hidepid=0 uid=1000 user=squad","TimeStamp":"2026-08-11T00:00:01.000000Z"}
) else (
    if "%SQUAD_PROC_ISO_STUB_MODE%"=="observed-no" (
        echo {"Log":"SQUAD-PROC-ISO v1 same-uid-environ-readable=no proc-mounted=yes hidepid=2 uid=1000 user=squad","TimeStamp":"2026-08-11T00:00:01.000000Z"}
    )
)
echo {"Log":"ordinary shutdown line","TimeStamp":"2026-08-11T00:00:02.000000Z"}
exit /b 0
'@

    return [pscustomobject]@{
        Root   = $Root
        BinDir = $binDir
        AzLog  = $azLog
    }
}

function Invoke-ProcIsoCliCapture {
    <#
    .SYNOPSIS
        Runs scripts/proc-isolation-report.ps1 as a real child process under
        the stub `az.cmd`, and captures its actual exit code, stdout,
        stderr, and the exact call log -- mirrors
        Invoke-RbacDriftCliCapture / Invoke-JobDriftCliCapture.

    .PARAMETER Mode
        "observed-yes", "observed-no", or "" (not-yet-observed).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Stub,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$Mode = "",
        [string[]]$CliArguments = @()
    )

    $hostExe = (Get-Process -Id $PID).Path
    $outFile = Join-Path $Stub.Root ("stdout-" + [guid]::NewGuid().ToString("N") + ".txt")
    $errFile = Join-Path $Stub.Root ("stderr-" + [guid]::NewGuid().ToString("N") + ".txt")
    Reset-ProcIsoStubLog -Stub $Stub

    $prevPath = $env:PATH
    $prevMode = $env:SQUAD_PROC_ISO_STUB_MODE
    $prevLog = $env:SQUAD_PROC_ISO_STUB_LOG
    try {
        $env:PATH = "$($Stub.BinDir);$prevPath"
        $env:SQUAD_PROC_ISO_STUB_MODE = $Mode
        $env:SQUAD_PROC_ISO_STUB_LOG = $Stub.AzLog

        $defaultArgs = @(
            "-ResourceGroupName", $script:ProcIsoStubResourceGroup,
            "-NamePrefix", $script:ProcIsoStubNamePrefix,
            "-SubscriptionId", $script:ProcIsoStubSubscriptionId,
            "-JobName", $script:ProcIsoStubJobName
        )
        $argList = @("-NoProfile", "-NonInteractive", "-File", $ScriptPath) + $defaultArgs + $CliArguments
        $proc = Start-Process -FilePath $hostExe -ArgumentList $argList `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $exitCode = $proc.ExitCode
    } finally {
        $env:PATH = $prevPath
        $env:SQUAD_PROC_ISO_STUB_MODE = $prevMode
        $env:SQUAD_PROC_ISO_STUB_LOG = $prevLog
    }

    $stdout = ""
    $stderr = ""
    if (Test-Path -LiteralPath $outFile) { $stdout = [System.IO.File]::ReadAllText($outFile) }
    if (Test-Path -LiteralPath $errFile) { $stderr = [System.IO.File]::ReadAllText($errFile) }
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
        AzCalls  = Get-ProcIsoStubCalls -Stub $Stub
    }
}

function Reset-ProcIsoStubLog {
    param([Parameter(Mandatory = $true)][object]$Stub)
    Set-Content -LiteralPath $Stub.AzLog -Value "" -NoNewline -Encoding ascii
}

function Get-ProcIsoStubCalls {
    param([Parameter(Mandatory = $true)][object]$Stub)
    if (-not (Test-Path -LiteralPath $Stub.AzLog)) { return @() }
    return @(Get-Content -LiteralPath $Stub.AzLog | Where-Object { $_ -ne "" })
}

function Remove-ProcIsoStubEnvironment {
    param([Parameter(Mandatory = $true)][object]$Stub)
    Remove-Item -Recurse -Force -LiteralPath $Stub.Root -ErrorAction SilentlyContinue
}
