#requires -Version 5.1
<#
.SYNOPSIS
    CV-2 (issue #85): read the LIVE session job / environment configuration
    and compare it with intent.

.DESCRIPTION
    Read-only. Nothing here creates, updates, or deletes a job, a secret, or
    an identity assignment. Every Azure read goes through
    scripts/lib/job-drift-reader.ps1's Invoke-JobAzRead chokepoint, which
    enforces a read-verb allowlist and refuses any mutating or secret-value
    verb outright. Comparison against intent is performed by the pure
    comparer in scripts/lib/job-drift-compare.ps1, which never touches Azure.

    Checks the deployed session job's image, that secret-backed environment
    variables are referenced (secretRef) rather than inlined, that the
    expected environment variables are present, and that no unexpected
    identity (extra user-assigned, or a system-assigned identity) is
    attached.

.PARAMETER ResourceGroupName
    Overrides intent resolution for the resource group.

.PARAMETER NamePrefix
    Overrides intent resolution for the deployment's name prefix.

.PARAMETER SubscriptionId
    Overrides intent resolution for the subscription.

.PARAMETER ExpectedImage
    Overrides intent resolution for the image deploy.ps1 intends for this
    job. When omitted, resolved from deploy.outputs.json's workerImage field.

.PARAMETER Fixture
    Path to a committed (already redacted) snapshot JSON fixture. When
    supplied, NO Azure call is made at all.

.PARAMETER DeployOutputsPath
    Overrides the path checked for deploy.outputs.json (default: the repo
    root's deploy.outputs.json).

.PARAMETER Json
    Emit the findings as JSON instead of a human-readable table.

.OUTPUTS
    Exit 0: no high-severity finding.
    Exit 1: at least one high-severity finding (unexpectedImage,
            missingEnvVar, inlinedSecret, missingIdentity, unexpectedIdentity).
    Exit 2: intent could not be resolved, or a live read failed outright.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = "",
    [string]$NamePrefix = "",
    [string]$SubscriptionId = "",
    [string]$ExpectedImage = "",
    [string]$Fixture = "",
    [string]$DeployOutputsPath = "",
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

. (Join-Path $ScriptDir "lib\job-drift-reader.ps1")
. (Join-Path $ScriptDir "lib\job-drift-compare.ps1")

function Read-JobDriftJsonFile {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    return $null
}

function Write-JobDriftFatal {
    <#
    .SYNOPSIS
        Mirrors scripts/rbac-drift-check.ps1's Write-RbacDriftFatal: reports
        to stderr and exits 2 directly, without going through Write-Error
        (which would itself terminate under $ErrorActionPreference = "Stop"
        before the exit statement ran).
    #>
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function Write-JobDriftFindings {
    param([object[]]$Findings, [switch]$AsJson)
    if ($AsJson) {
        [pscustomobject]@{
            schema   = "squad-aca/job-drift-report@1"
            findings = $Findings
            exitCode = (Get-JobDriftExitCode -Findings $Findings)
        } | ConvertTo-Json -Depth 6 | Write-Output
        return
    }
    $Findings |
        Select-Object Status, Severity, Subject, Detail |
        Format-Table -AutoSize |
        Out-String -Width 200 |
        ForEach-Object { $_.TrimEnd() } |
        Write-Output
}

$snapshot = $null
$expectedImageForCompare = $ExpectedImage

if ($Fixture) {
    $fixtureData = Read-JobDriftJsonFile -Path $Fixture
    if (-not $fixtureData) {
        Write-JobDriftFatal "CV-2: could not read fixture '$Fixture'."
    }
    $snapshot = $fixtureData.snapshot
    if (-not $expectedImageForCompare) { $expectedImageForCompare = [string]$fixtureData.expectedImage }
    if (-not $expectedImageForCompare) {
        Write-JobDriftFatal "CV-2: fixture '$Fixture' does not carry an expectedImage and none was passed via -ExpectedImage."
    }
} else {
    $deployOutputsFile = if ($DeployOutputsPath) { $DeployOutputsPath } else { Join-Path $RepoRoot "deploy.outputs.json" }
    $deployOutputs = Read-JobDriftJsonFile -Path $deployOutputsFile

    $intent = Resolve-JobDriftIntent `
        -ResourceGroupName $ResourceGroupName `
        -NamePrefix $NamePrefix `
        -SubscriptionId $SubscriptionId `
        -ExpectedImage $ExpectedImage `
        -DeployOutputs $deployOutputs

    if ($intent.Missing.Count -gt 0) {
        Write-JobDriftFatal "CV-2 cannot resolve: $($intent.Missing -join ', '). Pass explicit parameters (-ResourceGroupName / -SubscriptionId / -ExpectedImage) or configure deploy.outputs.json. Intent fails closed -- this never guesses across a subscription boundary."
    }

    try {
        $snapshot = Get-JobDriftLiveSnapshot -Intent $intent
    } catch {
        Write-JobDriftFatal "CV-2 could not capture a live snapshot: $($_.Exception.Message)"
    }
    $expectedImageForCompare = $intent.ExpectedImage
}

$findings = @(Compare-JobDriftSnapshot -Snapshot $snapshot -ExpectedImage $expectedImageForCompare)
Write-JobDriftFindings -Findings $findings -AsJson:$Json
exit (Get-JobDriftExitCode -Findings $findings)
