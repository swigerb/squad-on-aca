<#
.SYNOPSIS
    Offline stub harness for CV-1 (issue #85) live-mode integration tests.

.DESCRIPTION
    Creates a throwaway `az.cmd` shim on PATH that answers exactly the command
    shapes scripts/lib/rbac-drift-reader.ps1 issues (identity show, acr
    show/list, containerapp job show, account show, role assignment list --
    both the principal-anchored `--assignee ... --all` form and the bounded
    `--scope` form) for one synthetic deployment:

      resource group   : rg-cv1-stub
      name prefix       : cv1stub  (session identity uai-cv1stub-acrpull,
                           session job caj-cv1stub-session, optional GitHub
                           Actions identity uai-cv1stub-gha)
      registry          : acrcv1stub

    Two response modes, selected by SQUAD_RBAC_STUB_CLEAN:

      unset / "0"  -- mirrors the REAL live state security's CV-1 contract
                      reports: the session identity's AcrPull grant matches
                      intent, it ALSO holds a resource-group Contributor grant
                      (drift), the job-scoped grant is absent (drift), and the
                      GitHub Actions identity does not exist (absent, info).
                      A run through this mode is expected to exit 1.
      "1"          -- fully clean: session identity holds exactly AcrPull +
                      job-scoped Container Apps Jobs Operator, GitHub Actions
                      identity exists and holds exactly the job-scoped grant.
                      A run through this mode is expected to exit 0.

    Every invocation is appended to SQUAD_RBAC_STUB_LOG (raw argv, one call per
    line) so a test can assert the exact sequence of `az` calls this deployment
    shape produces, and -- just as importantly -- that no other call was ever
    made (no mutating verb, no --include-inherited, no bare 'account set',
    every line pinning --subscription).

    Used by scripts/validate.ps1's "RBAC drift check (CV-1)" section.
#>

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here, matching
# scripts/tests/cli-stub-harness.ps1.

$script:RbacDriftStubSubscriptionId = "11111111-1111-1111-1111-111111111111"
$script:RbacDriftStubResourceGroup = "rg-cv1-stub"
$script:RbacDriftStubNamePrefix = "cv1stub"
$script:RbacDriftStubAcrName = "acrcv1stub"
$script:RbacDriftStubSessionIdentityName = "uai-cv1stub-acrpull"
$script:RbacDriftStubSessionJobName = "caj-cv1stub-session"
$script:RbacDriftStubGithubActionsIdentityName = "uai-cv1stub-gha"
$script:RbacDriftStubSessionPrincipalId = "22222222-2222-2222-2222-222222222222"
$script:RbacDriftStubSessionClientId = "33333333-3333-3333-3333-333333333333"
$script:RbacDriftStubGithubActionsPrincipalId = "44444444-4444-4444-4444-444444444444"
$script:RbacDriftStubGithubActionsClientId = "55555555-5555-5555-5555-555555555555"
$script:RbacDriftStubRegistryScopeId = "/subscriptions/$($script:RbacDriftStubSubscriptionId)/resourceGroups/$($script:RbacDriftStubResourceGroup)/providers/Microsoft.ContainerRegistry/registries/$($script:RbacDriftStubAcrName)"
$script:RbacDriftStubJobScopeId = "/subscriptions/$($script:RbacDriftStubSubscriptionId)/resourceGroups/$($script:RbacDriftStubResourceGroup)/providers/Microsoft.App/jobs/$($script:RbacDriftStubSessionJobName)"
$script:RbacDriftStubResourceGroupScopeId = "/subscriptions/$($script:RbacDriftStubSubscriptionId)/resourceGroups/$($script:RbacDriftStubResourceGroup)"

function New-RbacDriftStubEnvironment {
    param(
        [string]$Root = (Join-Path ([System.IO.Path]::GetTempPath()) ("rbac-drift-stub-" + [guid]::NewGuid().ToString("N")))
    )
    $binDir = Join-Path $Root "bin"
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $azLog = Join-Path $Root "az-calls.log"
    Set-Content -LiteralPath $azLog -Value "" -NoNewline -Encoding ascii

    Set-Content -LiteralPath (Join-Path $binDir "az.cmd") -Encoding ascii -Value @'
@echo off
if not "%SQUAD_RBAC_STUB_LOG%"=="" (>>"%SQUAD_RBAC_STUB_LOG%" echo %*)
set "A1=%~1"
set "A2=%~2"
set "A3=%~3"
set "NAME="
set "SCOPE="
set "ASSIGNEE="
:rbparse
if "%~1"=="" goto rbparsed
if "%~1"=="--name" set "NAME=%~2"
if "%~1"=="--scope" set "SCOPE=%~2"
if "%~1"=="--assignee" set "ASSIGNEE=%~2"
shift
goto rbparse
:rbparsed
if "%A1%"=="account" goto rbaccount
if "%A1%"=="acr" goto rbacr
if "%A1%"=="containerapp" goto rbjob
if "%A1%"=="identity" goto rbidentity
if "%A1%"=="role" goto rbrole
>&2 echo ERROR: unhandled stub command: %*
exit /b 9

:rbaccount
echo {"id":"11111111-1111-1111-1111-111111111111","name":"CV1 Stub Subscription"}
exit /b 0

:rbacr
if "%A2%"=="list" goto rbacrlist
echo "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.ContainerRegistry/registries/acrcv1stub"
exit /b 0
:rbacrlist
echo ["acrcv1stub"]
exit /b 0

:rbjob
echo "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.App/jobs/caj-cv1stub-session"
exit /b 0

:rbidentity
if "%NAME%"=="uai-cv1stub-acrpull" goto rbidsession
if "%SQUAD_RBAC_STUB_CLEAN%"=="1" if "%NAME%"=="uai-cv1stub-gha" goto rbidgha
>&2 echo ERROR: (ResourceNotFound) The identity 'uai-cv1stub-gha' was not found.
exit /b 3
:rbidsession
echo {"principalId":"22222222-2222-2222-2222-222222222222","clientId":"33333333-3333-3333-3333-333333333333"}
exit /b 0
:rbidgha
echo {"principalId":"44444444-4444-4444-4444-444444444444","clientId":"55555555-5555-5555-5555-555555555555"}
exit /b 0

:rbrole
if not "%ASSIGNEE%"=="" goto rbroleassignee
if "%SCOPE%"=="/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.ContainerRegistry/registries/acrcv1stub" goto rbrolescoperegistry
if "%SCOPE%"=="/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.App/jobs/caj-cv1stub-session" goto rbrolescopejob
echo []
exit /b 0
:rbroleassignee
if "%ASSIGNEE%"=="44444444-4444-4444-4444-444444444444" goto rbroleassigneegha
if "%SQUAD_RBAC_STUB_CLEAN%"=="1" goto rbroleassigneesessionclean
echo [{"roleDefinitionName":"AcrPull","scope":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.ContainerRegistry/registries/acrcv1stub","name":"aaaaaaaa-0000-0000-0000-000000000001","principalId":"22222222-2222-2222-2222-222222222222"},{"roleDefinitionName":"Contributor","scope":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub","name":"aaaaaaaa-0000-0000-0000-000000000002","principalId":"22222222-2222-2222-2222-222222222222"}]
exit /b 0
:rbroleassigneesessionclean
echo [{"roleDefinitionName":"AcrPull","scope":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.ContainerRegistry/registries/acrcv1stub","name":"aaaaaaaa-0000-0000-0000-000000000001","principalId":"22222222-2222-2222-2222-222222222222"},{"roleDefinitionName":"Container Apps Jobs Operator","scope":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.App/jobs/caj-cv1stub-session","name":"aaaaaaaa-0000-0000-0000-000000000003","principalId":"22222222-2222-2222-2222-222222222222"}]
exit /b 0
:rbroleassigneegha
echo [{"roleDefinitionName":"Container Apps Jobs Operator","scope":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.App/jobs/caj-cv1stub-session","name":"aaaaaaaa-0000-0000-0000-000000000004","principalId":"44444444-4444-4444-4444-444444444444"}]
exit /b 0
:rbrolescoperegistry
echo [{"roleDefinitionName":"AcrPull","scope":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.ContainerRegistry/registries/acrcv1stub","name":"aaaaaaaa-0000-0000-0000-000000000001","principalId":"22222222-2222-2222-2222-222222222222"}]
exit /b 0
:rbrolescopejob
if "%SQUAD_RBAC_STUB_CLEAN%"=="1" goto rbrolescopejobclean
echo []
exit /b 0
:rbrolescopejobclean
echo [{"roleDefinitionName":"Container Apps Jobs Operator","scope":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.App/jobs/caj-cv1stub-session","name":"aaaaaaaa-0000-0000-0000-000000000003","principalId":"22222222-2222-2222-2222-222222222222"},{"roleDefinitionName":"Container Apps Jobs Operator","scope":"/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-cv1-stub/providers/Microsoft.App/jobs/caj-cv1stub-session","name":"aaaaaaaa-0000-0000-0000-000000000004","principalId":"44444444-4444-4444-4444-444444444444"}]
exit /b 0
'@

    return [pscustomobject]@{
        Root   = $Root
        BinDir = $binDir
        AzLog  = $azLog
    }
}

function Invoke-RbacDriftCliCapture {
    <#
    .SYNOPSIS
        Runs scripts/rbac-drift-check.ps1 as a real child process under the
        stub `az.cmd`, and captures its actual exit code, stdout, stderr, and
        the exact call log -- mirroring Invoke-SquadCliCapture in
        cli-stub-harness.ps1, but for the CV-1 live-mode path.

    .PARAMETER Stub
        The object returned by New-RbacDriftStubEnvironment.

    .PARAMETER ScriptPath
        Full path to scripts/rbac-drift-check.ps1.

    .PARAMETER Clean
        When set, drives the stub's SQUAD_RBAC_STUB_CLEAN=1 path (fully
        clean deployment). Omitted (default) drives the drifted/real-world
        shaped path.

    .PARAMETER CliArguments
        Extra arguments appended to the child invocation (e.g. -Json, or an
        explicit -AcrName to skip registry discovery).
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
    Reset-RbacDriftStubLog -Stub $Stub

    $prevPath = $env:PATH
    $prevClean = $env:SQUAD_RBAC_STUB_CLEAN
    $prevLog = $env:SQUAD_RBAC_STUB_LOG
    try {
        $env:PATH = "$($Stub.BinDir);$prevPath"
        $env:SQUAD_RBAC_STUB_CLEAN = if ($Clean) { "1" } else { "" }
        $env:SQUAD_RBAC_STUB_LOG = $Stub.AzLog

        $defaultArgs = @(
            "-ResourceGroupName", $script:RbacDriftStubResourceGroup,
            "-NamePrefix", $script:RbacDriftStubNamePrefix,
            "-SubscriptionId", $script:RbacDriftStubSubscriptionId
        )
        $argList = @("-NoProfile", "-NonInteractive", "-File", $ScriptPath) + $defaultArgs + $CliArguments
        $proc = Start-Process -FilePath $hostExe -ArgumentList $argList `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $exitCode = $proc.ExitCode
    } finally {
        $env:PATH = $prevPath
        $env:SQUAD_RBAC_STUB_CLEAN = $prevClean
        $env:SQUAD_RBAC_STUB_LOG = $prevLog
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
        AzCalls  = Get-RbacDriftStubCalls -Stub $Stub
    }
}

function Reset-RbacDriftStubLog {
    param([Parameter(Mandatory = $true)][object]$Stub)
    Set-Content -LiteralPath $Stub.AzLog -Value "" -NoNewline -Encoding ascii
}

function Get-RbacDriftStubCalls {
    param([Parameter(Mandatory = $true)][object]$Stub)
    if (-not (Test-Path -LiteralPath $Stub.AzLog)) { return @() }
    return @(Get-Content -LiteralPath $Stub.AzLog | Where-Object { $_ -ne "" })
}

function Remove-RbacDriftStubEnvironment {
    param([Parameter(Mandatory = $true)][object]$Stub)
    Remove-Item -Recurse -Force -LiteralPath $Stub.Root -ErrorAction SilentlyContinue
}
