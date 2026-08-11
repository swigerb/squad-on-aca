#requires -Version 5.1
<#
.SYNOPSIS
    PC-1 (issue #86): read-only check of whether Azure Container Apps lets a
    same-uid process read another process's environment through /proc.

.DESCRIPTION
    Read-only. Nothing here creates, updates, deletes, starts, stops, or
    execs into anything. Every Azure read goes through
    scripts/lib/proc-isolation-reader.ps1's Invoke-ProcIsoAzRead chokepoint,
    which enforces a read-verb allowlist (account show; containerapp job
    execution list; containerapp job logs show) and refuses any mutating
    verb, `exec`, or `az account set` outright. Parsing what a log line means
    is performed by the pure parser in
    scripts/lib/proc-isolation-parser.ps1, which never touches Azure.

    It reads the most recent executions of the deployed session job, scans
    their already-written console logs for worker/lib/proc-isolation-
    probe.sh's one-line output (SQUAD-PROC-ISO v1 ...), and reports:

      * "yes"              same-uid-environ-readable was observed true
      * "no"                same-uid-environ-readable was observed false
      * "unknown"           the probe ran but could not determine an answer
                             (e.g. /proc itself is not mounted)
      * "not-yet-observed"  the probe's line was never found in what was
                             read -- this is the honest default until an
                             operator redeploys the image carrying the probe
                             and a session or Ralph poll actually runs

    THIS SCRIPT NEVER FABRICATES OR INFERS A RESULT. A live read failure
    (unreachable subscription, missing az/containerapp extension, no
    executions to scan) is reported as "live read unavailable", explicitly
    distinct from "not-yet-observed" -- the former means the question was
    never actually asked, the latter means it was asked and answered
    silence.

.PARAMETER ResourceGroupName
    Overrides intent resolution for the resource group.

.PARAMETER NamePrefix
    Overrides intent resolution for the deployment's name prefix.

.PARAMETER SubscriptionId
    Overrides intent resolution for the subscription.

.PARAMETER JobName
    Overrides the job whose executions are scanned (default: the session
    job, "caj-<prefix>-session").

.PARAMETER ExecutionLimit
    How many of the most recent executions to scan (default 5).

.PARAMETER TailLines
    How many trailing console lines to read per execution (default 500).

.PARAMETER Fixture
    Path to a text file of already-captured log lines (one per line). When
    supplied, NO Azure call is made at all -- this is the fully offline mode
    scripts/validate.ps1 uses to prove the parser's yes/no/unknown/
    not-yet-observed classification without contacting Azure.

.PARAMETER DeployOutputsPath
    Overrides the path checked for deploy.outputs.json (default: the repo
    root's deploy.outputs.json).

.PARAMETER Json
    Emit the finding as JSON instead of a human-readable line.

.OUTPUTS
    Exit 0: the read succeeded (or a fixture was used), regardless of what
            was observed -- including "not-yet-observed", which is an
            expected, non-error outcome.
    Exit 2: intent could not be resolved, or a live read failed outright
            (the platform question was never actually asked). Never mutates
            Azure and never guesses across a subscription boundary.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = "",
    [string]$NamePrefix = "",
    [string]$SubscriptionId = "",
    [string]$JobName = "",
    [int]$ExecutionLimit = 5,
    [int]$TailLines = 500,
    [string]$Fixture = "",
    [string]$DeployOutputsPath = "",
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

. (Join-Path $ScriptDir "lib\proc-isolation-reader.ps1")
. (Join-Path $ScriptDir "lib\proc-isolation-parser.ps1")

function Read-ProcIsoJsonFile {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    return $null
}

function Write-ProcIsoFatal {
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

function Write-ProcIsoFinding {
    param([object]$Observation, [string]$Source, [switch]$AsJson)
    if ($AsJson) {
        [pscustomobject]@{
            schema                 = "squad-aca/proc-isolation-report@1"
            source                 = $Source
            observed               = $Observation.Observed
            sameUidEnvironReadable = $Observation.SameUidEnvironReadable
            procMounted            = $Observation.ProcMounted
            hidepid                = $Observation.Hidepid
        } | ConvertTo-Json -Depth 4 | Write-Output
        return
    }
    Write-Output "PC-1 process-isolation report (source: $Source)"
    Write-Output "  same-uid-environ-readable : $($Observation.SameUidEnvironReadable)"
    if ($Observation.Observed) {
        Write-Output "  proc-mounted              : $($Observation.ProcMounted)"
        Write-Output "  hidepid                   : $($Observation.Hidepid)"
    } else {
        Write-Output "  (no SQUAD-PROC-ISO line was found in what was read; this is 'not yet observed', not a failure)"
    }
}

if ($Fixture) {
    if (-not (Test-Path -LiteralPath $Fixture)) {
        Write-ProcIsoFatal "PC-1: could not read fixture '$Fixture'."
    }
    $fixtureLines = @(Get-Content -LiteralPath $Fixture)
    $observation = Get-ProcIsoObservation -Lines $fixtureLines
    Write-ProcIsoFinding -Observation $observation -Source "fixture:$Fixture" -AsJson:$Json
    exit 0
}

$deployOutputsFile = if ($DeployOutputsPath) { $DeployOutputsPath } else { Join-Path $RepoRoot "deploy.outputs.json" }
$deployOutputs = Read-ProcIsoJsonFile -Path $deployOutputsFile

$intent = Resolve-ProcIsoIntent `
    -ResourceGroupName $ResourceGroupName `
    -NamePrefix $NamePrefix `
    -SubscriptionId $SubscriptionId `
    -JobName $JobName `
    -DeployOutputs $deployOutputs

if ($intent.Missing.Count -gt 0) {
    Write-ProcIsoFatal "PC-1 cannot resolve: $($intent.Missing -join ', '). Pass explicit parameters (-ResourceGroupName / -SubscriptionId) or configure deploy.outputs.json. Intent fails closed -- this never guesses across a subscription boundary."
}

try {
    $live = Get-ProcIsoLiveObservation -Intent $intent -ExecutionLimit $ExecutionLimit -TailLines $TailLines
} catch {
    Write-ProcIsoFatal "PC-1 live read unavailable: $($_.Exception.Message). The platform question was never actually asked -- this is NOT the same as 'not-yet-observed', and no result is reported."
}

$observation = Get-ProcIsoObservation -Lines $live.Lines
Write-ProcIsoFinding -Observation $observation -Source "live:$($intent.JobName) ($($live.ExecutionsScanned) execution(s) scanned)" -AsJson:$Json
exit 0
