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
      unset / anything else -- the execution's log contains ordinary lines
                          but no SQUAD-PROC-ISO line at all (not-yet-observed).

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
if not "%SQUAD_PROC_ISO_STUB_LOG%"=="" (>>"%SQUAD_PROC_ISO_STUB_LOG%" echo %*)
set "A1=%~1"
set "A2=%~2"
set "A3=%~3"
set "A4=%~4"
if "%A1%"=="account" goto piaccount
if "%A1%"=="containerapp" if "%A2%"=="job" if "%A3%"=="execution" if "%A4%"=="list" goto pilist
if "%A1%"=="containerapp" if "%A2%"=="job" if "%A3%"=="logs" if "%A4%"=="show" goto pilogs
>&2 echo ERROR: unhandled stub command: %*
exit /b 9

:piaccount
echo {"id":"aaaaaaaa-1111-1111-1111-111111111111","name":"PC1 Stub Subscription"}
exit /b 0

:pilist
echo ["caj-pc1stub-session-stub01"]
exit /b 0

:pilogs
echo ordinary startup line
if "%SQUAD_PROC_ISO_STUB_MODE%"=="observed-yes" (
    echo SQUAD-PROC-ISO v1 same-uid-environ-readable=yes proc-mounted=yes hidepid=0 uid=1000 user=squad
) else (
    if "%SQUAD_PROC_ISO_STUB_MODE%"=="observed-no" (
        echo SQUAD-PROC-ISO v1 same-uid-environ-readable=no proc-mounted=yes hidepid=2 uid=1000 user=squad
    )
)
echo ordinary shutdown line
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
