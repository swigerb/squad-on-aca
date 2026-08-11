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
    (unreachable subscription, missing az/containerapp extension, an
    out-of-range --tail, or every scanned execution's logs failing to read)
    is reported as "live read unavailable" (exit 2), explicitly distinct from
    "not-yet-observed" -- the former means the question was never actually
    answered, the latter means it was asked, every scanned execution was
    genuinely read, and the answer was silence. A read that succeeded for
    some executions and failed for others is neither, and is reported as
    "inconclusive-partial-read" (exit 3).

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
    How many trailing console lines to read per execution (default 300).
    Must be 0-300: that is the range `az containerapp job logs show --tail`
    accepts, and a value outside it is rejected by the CLI as a usage error
    before Azure is ever contacted. Validated here BEFORE any `az` call, and
    again inside the reader; out of range exits 2 with zero Azure calls made.

.PARAMETER ContainerName
    The container in the job's template whose logs are read. Omitted (the
    default), it is resolved from the live job template via
    `az containerapp job show --query properties.template.containers[0].name`.
    If that read fails, the job name is used as an explicitly-reported
    ASSUMPTION -- printed in the output, never presented as fact.

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
    Exit 0: every execution that was scanned was also actually read, and the
            result is what those logs say -- an observation (yes/no/unknown)
            or a GENUINE not-yet-observed (the probe's line is absent from
            logs that were successfully read end to end).
    Exit 2: the question was never actually asked. Intent could not be
            resolved, -TailLines was out of range (no Azure call attempted),
            the account or execution-list read failed, or EVERY log read of
            every scanned execution failed. Reported as "live read
            unavailable" and never as not-yet-observed.
    Exit 3: inconclusive-partial-read. Some, but not all, of the scanned
            executions could be read. Whatever the read part says, absence of
            the probe line cannot be concluded from a partial read, so this
            is neither a clean observation nor a clean absence.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = "",
    [string]$NamePrefix = "",
    [string]$SubscriptionId = "",
    [string]$JobName = "",
    [int]$ExecutionLimit = 5,
    [int]$TailLines = 300,
    [string]$ContainerName = "",
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
    param(
        [object]$Observation,
        [string]$Source,
        [string]$Status = "complete-read",
        [int]$ExecutionsScanned = 0,
        [int]$ExecutionsRead = 0,
        [string[]]$Failures = @(),
        [string]$ContainerName = "",
        [string]$ContainerNameSource = "",
        [string]$ContainerNameDetail = "",
        [switch]$AsJson
    )
    if ($AsJson) {
        [pscustomobject]@{
            schema                 = "squad-aca/proc-isolation-report@2"
            source                 = $Source
            status                 = $Status
            observed               = $Observation.Observed
            sameUidEnvironReadable = $Observation.SameUidEnvironReadable
            procMounted            = $Observation.ProcMounted
            hidepid                = $Observation.Hidepid
            executionsScanned      = $ExecutionsScanned
            executionsRead         = $ExecutionsRead
            failures               = @($Failures)
            container              = $ContainerName
            containerSource        = $ContainerNameSource
            containerAssumption    = $ContainerNameDetail
        } | ConvertTo-Json -Depth 4 | Write-Output
        return
    }
    Write-Output "PC-1 process-isolation report (source: $Source)"
    Write-Output "  status                    : $Status"
    Write-Output "  same-uid-environ-readable : $($Observation.SameUidEnvironReadable)"
    if ($Observation.Observed) {
        Write-Output "  proc-mounted              : $($Observation.ProcMounted)"
        Write-Output "  hidepid                   : $($Observation.Hidepid)"
    } elseif ($Status -eq "complete-read") {
        Write-Output "  (no SQUAD-PROC-ISO line was found in logs that were read end to end; this is a genuine 'not yet observed', not a failure)"
    }
    if ($ContainerName) {
        Write-Output "  container                 : $ContainerName ($ContainerNameSource)"
        if ($ContainerNameSource -eq "assumed") {
            Write-Output "  ASSUMPTION                : $ContainerNameDetail"
        }
    }
    Write-Output "  executions scanned/read   : $ExecutionsScanned/$ExecutionsRead"
    if (@($Failures).Count -gt 0) {
        Write-Output "  log reads that FAILED     : $(@($Failures).Count)"
        foreach ($failure in @($Failures)) { Write-Output "    - $failure" }
    }
}

# L1: the --tail bound is enforced before anything else happens -- before
# intent resolution, before the reader is entered, and therefore before any
# `az` process could be started. `az containerapp job logs show --tail`
# accepts 0-300 and rejects anything else as a usage error; both prior
# revisions defaulted to 500, so every live log read they made was rejected
# by the CLI and then reported as an honest-sounding "not-yet-observed".
if ($TailLines -lt 0 -or $TailLines -gt 300) {
    Write-ProcIsoFatal "PC-1: -TailLines must be between 0 and 300 (the range 'az containerapp job logs show --tail' accepts); got $TailLines. No Azure call was attempted. An out-of-range value is rejected by the CLI as a usage error, and a rejected read must never be reported as 'not-yet-observed'."
}

if ($Fixture) {
    if (-not (Test-Path -LiteralPath $Fixture)) {
        Write-ProcIsoFatal "PC-1: could not read fixture '$Fixture'."
    }
    $fixtureLines = @(Get-Content -LiteralPath $Fixture)
    $observation = Get-ProcIsoObservation -Lines $fixtureLines
    Write-ProcIsoFinding -Observation $observation -Source "fixture:$Fixture" -Status "fixture" -AsJson:$Json
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
    $live = Get-ProcIsoLiveObservation -Intent $intent -ExecutionLimit $ExecutionLimit -TailLines $TailLines -ContainerName $ContainerName
} catch {
    Write-ProcIsoFatal "PC-1 live read unavailable: $($_.Exception.Message). The platform question was never actually asked -- this is NOT the same as 'not-yet-observed', and no result is reported."
}

$observation = Get-ProcIsoObservation -Lines $live.Lines

# L2: what the exit code is allowed to mean.
#
#   * Every scanned execution actually read -> exit 0. Only then is an
#     absence of the probe's line a GENUINE not-yet-observed.
#   * Some read, some failed -> exit 3, inconclusive-partial-read. Absence
#     cannot be concluded from logs that were never read.
#   * Every log read failed (or there was nothing readable at all) -> exit 2,
#     live read unavailable: the question was asked and never answered.
$scanned = [int]$live.ExecutionsScanned
$read = [int]$live.ExecutionsRead
$failures = @($live.Failures)

if ($scanned -gt 0 -and $read -eq 0) {
    Write-ProcIsoFatal ("PC-1 live read unavailable: all $scanned scanned execution(s) of job '$($intent.JobName)' failed to read (container '$($live.ContainerName)', source $($live.ContainerNameSource)). " +
        "$($failures -join ' | ') " +
        "Nothing was read, so nothing is known -- this is NOT 'not-yet-observed'.")
}

$status = if ($failures.Count -gt 0) { "inconclusive-partial-read" } else { "complete-read" }

Write-ProcIsoFinding `
    -Observation $observation `
    -Source "live:$($intent.JobName)" `
    -Status $status `
    -ExecutionsScanned $scanned `
    -ExecutionsRead $read `
    -Failures $failures `
    -ContainerName $live.ContainerName `
    -ContainerNameSource $live.ContainerNameSource `
    -ContainerNameDetail $live.ContainerNameDetail `
    -AsJson:$Json

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("PC-1 inconclusive-partial-read: $($failures.Count) of $scanned scanned execution(s) could not be read. Absence of the probe's line cannot be concluded from a partial read.")
    exit 3
}
exit 0
