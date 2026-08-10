<#
.SYNOPSIS
    Offline stub harness for CV-2 (issue #85) live-mode integration tests.

.DESCRIPTION
    Creates a throwaway `az.cmd` shim on PATH that answers exactly the command
    shapes scripts/lib/job-drift-reader.ps1 issues (account show, identity
    show, containerapp job show) for one synthetic deployment:

      resource group   : rg-cv2-stub
      name prefix       : cv2stub  (session identity uai-cv2stub-acrpull,
                           session job caj-cv2stub-session)
      registry          : acrcv2stub

    Two response modes, selected by SQUAD_JOB_STUB_CLEAN:

      unset / "0"  -- drifted: GITHUB_TOKEN carries an inlined literal value
                      instead of a secretRef, AND an extra, unexpected
                      user-assigned identity is attached. A run through this
                      mode is expected to exit 1.
      "1"          -- fully clean: every secret-backed env var is
                      secretRef-only, only the expected session identity is
                      attached. A run through this mode is expected to exit 0.

    Every invocation is appended to SQUAD_JOB_STUB_LOG (raw argv, one call per
    line) so a test can assert the exact sequence of `az` calls this
    deployment shape produces.

    Used by scripts/validate.ps1's "Job/environment drift check (CV-2)"
    section.
#>

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here, matching
# scripts/tests/rbac-drift-stub-harness.ps1.

$script:JobDriftStubSubscriptionId = "66666666-6666-6666-6666-666666666666"
$script:JobDriftStubResourceGroup = "rg-cv2-stub"
$script:JobDriftStubNamePrefix = "cv2stub"
$script:JobDriftStubSessionIdentityName = "uai-cv2stub-acrpull"
$script:JobDriftStubSessionJobName = "caj-cv2stub-session"
$script:JobDriftStubExpectedImage = "acrcv2stub.azurecr.io/squad-worker:stub"
$script:JobDriftStubSessionIdentityId = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-cv2-stub/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-cv2stub-acrpull"
$script:JobDriftStubExtraIdentityId = "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-cv2-stub/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-cv2stub-extra"

function New-JobDriftStubEnvironment {
    param(
        [string]$Root = (Join-Path ([System.IO.Path]::GetTempPath()) ("job-drift-stub-" + [guid]::NewGuid().ToString("N")))
    )
    $binDir = Join-Path $Root "bin"
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $azLog = Join-Path $Root "az-calls.log"
    Set-Content -LiteralPath $azLog -Value "" -NoNewline -Encoding ascii

    # Two full job JSON bodies (clean / drifted), and a small dispatcher batch
    # script. `az containerapp job show -o json` output must be valid JSON on
    # one logical response -- the batch below simply echoes one of two
    # pre-built JSON blobs depending on SQUAD_JOB_STUB_CLEAN.
    $cleanJobJson = @'
{"identity":{"type":"UserAssigned","userAssignedIdentities":{"/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-cv2-stub/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-cv2stub-acrpull":{"principalId":"77777777-7777-7777-7777-777777777777","clientId":"88888888-8888-8888-8888-888888888888"}}},"properties":{"template":{"containers":[{"image":"acrcv2stub.azurecr.io/squad-worker:stub","env":[{"name":"GITHUB_REPOSITORY","value":"acme/widgets"},{"name":"GITHUB_REF","value":"main"},{"name":"GITHUB_BASE_BRANCH","value":"main"},{"name":"GITHUB_TOKEN","secretRef":"github-token"},{"name":"COPILOT_GITHUB_TOKEN","secretRef":"copilot-github-token"},{"name":"ASPIRE_OTLP_GRPC_ENDPOINT","value":"http://aspire:18889"},{"name":"ASPIRE_OTLP_HTTP_ENDPOINT","value":"http://aspire:18890"},{"name":"OTEL_EXPORTER_OTLP_HEADERS","secretRef":"otlp-headers"},{"name":"SQUAD_DEPLOYMENT_MODE","value":"squad-per-pod"},{"name":"ENABLE_GITHUB_REMOTE","value":"true"},{"name":"SQUAD_COPILOT_FLAGS","value":""},{"name":"SQUAD_HUB_URL","value":"https://hub.example"},{"name":"SQUAD_HUB_TOKEN","secretRef":"squad-hub-token"},{"name":"AZURE_SUBSCRIPTION_ID","value":"66666666-6666-6666-6666-666666666666"},{"name":"AZURE_RESOURCE_GROUP","value":"rg-cv2-stub"},{"name":"AZURE_CLIENT_ID","value":"88888888-8888-8888-8888-888888888888"},{"name":"ACA_SESSION_JOB_NAME","value":"caj-cv2stub-session"}]}]}}}
'@
    $drifted_JobJson = @'
{"identity":{"type":"UserAssigned","userAssignedIdentities":{"/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-cv2-stub/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-cv2stub-acrpull":{"principalId":"77777777-7777-7777-7777-777777777777","clientId":"88888888-8888-8888-8888-888888888888"},"/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-cv2-stub/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-cv2stub-extra":{"principalId":"99999999-9999-9999-9999-999999999999","clientId":"00000000-0000-0000-0000-000000000000"}}},"properties":{"template":{"containers":[{"image":"acrcv2stub.azurecr.io/squad-worker:stub","env":[{"name":"GITHUB_REPOSITORY","value":"acme/widgets"},{"name":"GITHUB_REF","value":"main"},{"name":"GITHUB_BASE_BRANCH","value":"main"},{"name":"GITHUB_TOKEN","value":"INLINED-LITERAL-NOT-A-REAL-TOKEN-0000000000"},{"name":"COPILOT_GITHUB_TOKEN","secretRef":"copilot-github-token"},{"name":"ASPIRE_OTLP_GRPC_ENDPOINT","value":"http://aspire:18889"},{"name":"ASPIRE_OTLP_HTTP_ENDPOINT","value":"http://aspire:18890"},{"name":"OTEL_EXPORTER_OTLP_HEADERS","secretRef":"otlp-headers"},{"name":"SQUAD_DEPLOYMENT_MODE","value":"squad-per-pod"},{"name":"ENABLE_GITHUB_REMOTE","value":"true"},{"name":"SQUAD_COPILOT_FLAGS","value":""},{"name":"SQUAD_HUB_URL","value":"https://hub.example"},{"name":"SQUAD_HUB_TOKEN","secretRef":"squad-hub-token"},{"name":"AZURE_SUBSCRIPTION_ID","value":"66666666-6666-6666-6666-666666666666"},{"name":"AZURE_RESOURCE_GROUP","value":"rg-cv2-stub"},{"name":"AZURE_CLIENT_ID","value":"88888888-8888-8888-8888-888888888888"},{"name":"ACA_SESSION_JOB_NAME","value":"caj-cv2stub-session"}]}]}}}
'@
    Set-Content -LiteralPath (Join-Path $binDir "clean-job.json") -Value $cleanJobJson -NoNewline -Encoding ascii
    Set-Content -LiteralPath (Join-Path $binDir "drifted-job.json") -Value $drifted_JobJson -NoNewline -Encoding ascii

    Set-Content -LiteralPath (Join-Path $binDir "az.cmd") -Encoding ascii -Value @'
@echo off
setlocal enabledelayedexpansion
if not "%SQUAD_JOB_STUB_LOG%"=="" (>>"%SQUAD_JOB_STUB_LOG%" echo %*)
set "A1=%~1"
set "A2=%~2"
set "A3=%~3"
set "NAME="
:jdparse
if "%~1"=="" goto jdparsed
if "%~1"=="--name" set "NAME=%~2"
shift /1
goto jdparse
:jdparsed
if "%A1%"=="account" goto jdaccount
if "%A1%"=="identity" goto jdidentity
if "%A1%"=="containerapp" goto jdjob
>&2 echo ERROR: unhandled stub command: %*
exit /b 9

:jdaccount
echo {"id":"66666666-6666-6666-6666-666666666666","name":"CV2 Stub Subscription"}
exit /b 0

:jdidentity
echo "/subscriptions/66666666-6666-6666-6666-666666666666/resourceGroups/rg-cv2-stub/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai-cv2stub-acrpull"
exit /b 0

:jdjob
if "%SQUAD_JOB_STUB_CLEAN%"=="1" (
    type "%~dp0clean-job.json"
) else (
    type "%~dp0drifted-job.json"
)
exit /b 0
'@

    return [pscustomobject]@{
        Root   = $Root
        BinDir = $binDir
        AzLog  = $azLog
    }
}

function Invoke-JobDriftCliCapture {
    <#
    .SYNOPSIS
        Runs scripts/job-drift-check.ps1 as a real child process under the
        stub `az.cmd`, and captures its actual exit code, stdout, stderr, and
        the exact call log -- mirrors Invoke-RbacDriftCliCapture.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Stub,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [switch]$Clean,
        [string[]]$CliArguments = @()
    )

    $hostExe = (Get-Process -Id $PID).Path
    $outFile = Join-Path $Stub.Root ("stdout-" + [guid]::NewGuid().ToString("N") + ".txt")
    $errFile = Join-Path $Stub.Root ("stderr-" + [guid]::NewGuid().ToString("N") + ".txt")
    Reset-JobDriftStubLog -Stub $Stub

    $prevPath = $env:PATH
    $prevClean = $env:SQUAD_JOB_STUB_CLEAN
    $prevLog = $env:SQUAD_JOB_STUB_LOG
    try {
        $env:PATH = "$($Stub.BinDir);$prevPath"
        $env:SQUAD_JOB_STUB_CLEAN = if ($Clean) { "1" } else { "" }
        $env:SQUAD_JOB_STUB_LOG = $Stub.AzLog

        $defaultArgs = @(
            "-ResourceGroupName", $script:JobDriftStubResourceGroup,
            "-NamePrefix", $script:JobDriftStubNamePrefix,
            "-SubscriptionId", $script:JobDriftStubSubscriptionId,
            "-ExpectedImage", $script:JobDriftStubExpectedImage
        )
        $argList = @("-NoProfile", "-NonInteractive", "-File", $ScriptPath) + $defaultArgs + $CliArguments
        $proc = Start-Process -FilePath $hostExe -ArgumentList $argList `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $exitCode = $proc.ExitCode
    } finally {
        $env:PATH = $prevPath
        $env:SQUAD_JOB_STUB_CLEAN = $prevClean
        $env:SQUAD_JOB_STUB_LOG = $prevLog
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
        AzCalls  = Get-JobDriftStubCalls -Stub $Stub
    }
}

function Reset-JobDriftStubLog {
    param([Parameter(Mandatory = $true)][object]$Stub)
    Set-Content -LiteralPath $Stub.AzLog -Value "" -NoNewline -Encoding ascii
}

function Get-JobDriftStubCalls {
    param([Parameter(Mandatory = $true)][object]$Stub)
    if (-not (Test-Path -LiteralPath $Stub.AzLog)) { return @() }
    return @(Get-Content -LiteralPath $Stub.AzLog | Where-Object { $_ -ne "" })
}

function Remove-JobDriftStubEnvironment {
    param([Parameter(Mandatory = $true)][object]$Stub)
    Remove-Item -Recurse -Force -LiteralPath $Stub.Root -ErrorAction SilentlyContinue
}
