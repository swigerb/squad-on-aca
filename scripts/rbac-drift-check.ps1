#requires -Version 5.1
<#
.SYNOPSIS
    CV-1 (issue #85): read the LIVE Azure role assignments held by this
    deployment's own principals and compare them with intent.

.DESCRIPTION
    Read-only. Nothing here creates, updates, deletes, starts, stops, or
    changes a role assignment. Every Azure read goes through
    scripts/lib/rbac-drift-reader.ps1's Invoke-AzRead chokepoint, which
    enforces a read-verb allowlist and refuses --include-inherited and
    'az account set' outright. Comparison against intent is performed by the
    pure comparer in scripts/lib/rbac-drift-compare.ps1, which never touches
    Azure.

    Anchors on the deployment's OWN principals (the session identity, and the
    optional GitHub Actions federated identity), never on scope inheritance --
    see the security contract in .squad/decisions/inbox/security-cv1-rbac-
    contract.md for why. A second, bounded layer lists assignments at the
    exact resource scopes this deployment creates (registry, session job),
    inheritance excluded, to catch an unexpected principal.

    Every identifier (subscription, tenant, principal, client, role-assignment
    GUID) is replaced with a stable alias BEFORE a snapshot object exists, so
    both a live capture and a committed fixture are always safe to print or
    attach as evidence. The alias map itself is never written to disk.

    Intent (resource group, name prefix, subscription, registry) is resolved
    from explicit parameters, then scripts/deploy.ps1's own recorded
    deploy.outputs.json, then -- for the registry only -- unambiguous
    discovery within the resource group (exactly one registry, or nothing).
    Anything left unresolved exits 2. It never exits 0 and never degrades to a
    warning.

.PARAMETER ResourceGroupName
    Overrides intent resolution for the resource group.

.PARAMETER NamePrefix
    Overrides intent resolution for the deployment's name prefix (used to
    derive the session identity name and the session job name).

.PARAMETER SubscriptionId
    Overrides intent resolution for the subscription. Every read pins this
    value explicitly; the check never falls back to the CLI's ambient
    "current" subscription.

.PARAMETER AcrName
    Overrides intent resolution for the container registry. When omitted and
    not present in deploy.outputs.json, the check performs unambiguous
    discovery within the resource group: exactly one registry, or the check
    exits 2.

.PARAMETER GitHubActionsIdentityName
    Overrides the derived name of the optional GitHub Actions federated
    identity ("uai-<prefix>-gha" by default).

.PARAMETER Fixture
    Path to a committed (already redacted) snapshot JSON fixture. When
    supplied, NO Azure call is made at all -- the fixture is compared directly,
    exactly the offline mode scripts/validate.ps1 and scripts/tests/fixtures/
    rbac-drift/*.json use to prove a drifted case fails without contacting
    Azure and without any mutation.

.PARAMETER DeployOutputsPath
    Overrides the path checked for deploy.outputs.json (default: the repo
    root's deploy.outputs.json). Exists so tests can point at a deliberately
    absent path and exercise the fail-closed "intent could not be resolved"
    branch deterministically, regardless of whatever a developer's own
    machine happens to have on disk.

.PARAMETER Json
    Emit the findings as JSON instead of a human-readable table.

.OUTPUTS
    Exit 0: no high-severity finding (a clean run, or informational findings
            only -- e.g. absentOptionalPrincipal).
    Exit 1: at least one high-severity finding (missingAssignment,
            unexpectedScope, or unexpectedPrincipal). This is EXPECTED against
            the live deployment today (security's CV-1 ruling): the session
            identity still holds a resource-group Contributor grant and lacks
            the job-scoped grant deploy.ps1 now applies. That is the check
            working, not a defect.
    Exit 2: intent could not be resolved, or a live read failed outright (for
            example the target subscription was unreachable). The check never
            silently inspects the wrong subscription.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = "",
    [string]$NamePrefix = "",
    [string]$SubscriptionId = "",
    [string]$AcrName = "",
    [string]$GitHubActionsIdentityName = "",
    [string]$Fixture = "",
    [string]$DeployOutputsPath = "",
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

. (Join-Path $ScriptDir "lib\rbac-drift-reader.ps1")
. (Join-Path $ScriptDir "lib\rbac-drift-compare.ps1")

function Read-RbacDriftJsonFile {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    return $null
}

function Write-RbacDriftFatal {
    <#
    .SYNOPSIS
        Reports a fail-closed condition to stderr and exits 2, WITHOUT going
        through Write-Error. Under $ErrorActionPreference = "Stop", Write-Error
        is itself a terminating statement -- the `exit 2` on the following
        line would never run, and the process would instead terminate with
        pwsh's generic uncaught-error code. Exit 2 has to be the code that is
        actually observed by a caller (this is the fail-closed contract's
        entire point), so this writes directly to the stderr stream and exits
        explicitly.
    #>
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function Write-RbacDriftFindings {
    param([object[]]$Findings, [switch]$AsJson)
    if ($AsJson) {
        [pscustomobject]@{
            schema   = "squad-aca/rbac-drift-report@1"
            findings = $Findings
            exitCode = (Get-RbacDriftExitCode -Findings $Findings)
        } | ConvertTo-Json -Depth 6 | Write-Output
        return
    }
    $Findings |
        Select-Object Principal, Status, Severity, RoleName, ScopeType, Detail |
        Format-Table -AutoSize |
        Out-String -Width 200 |
        ForEach-Object { $_.TrimEnd() } |
        Write-Output
}

$snapshot = $null

if ($Fixture) {
    # Fixture mode: fully offline. No Azure call is made at all.
    $snapshot = Read-RbacDriftJsonFile -Path $Fixture
    if (-not $snapshot) {
        Write-RbacDriftFatal "CV-1: could not read fixture '$Fixture'."
    }
} else {
    $deployOutputsFile = if ($DeployOutputsPath) { $DeployOutputsPath } else { Join-Path $RepoRoot "deploy.outputs.json" }
    $deployOutputs = Read-RbacDriftJsonFile -Path $deployOutputsFile

    $intent = Resolve-RbacDriftIntent `
        -ResourceGroupName $ResourceGroupName `
        -NamePrefix $NamePrefix `
        -SubscriptionId $SubscriptionId `
        -AcrName $AcrName `
        -GitHubActionsIdentityName $GitHubActionsIdentityName `
        -DeployOutputs $deployOutputs

    if ($intent.Missing.Count -gt 0) {
        Write-RbacDriftFatal "CV-1 cannot resolve: $($intent.Missing -join ', '). Pass explicit parameters (-ResourceGroupName / -SubscriptionId) or configure deploy.outputs.json. Intent fails closed -- this never guesses across a subscription boundary."
    }

    if (-not $intent.AcrName) {
        $discovered = @(Get-RbacDriftDiscoveredRegistry -ResourceGroup $intent.ResourceGroup -SubscriptionId $intent.SubscriptionId)
        if ($discovered.Count -eq 1) {
            $intent.AcrName = $discovered[0]
        } else {
            Write-RbacDriftFatal "CV-1 cannot resolve the container registry: found $($discovered.Count) in resource group '$($intent.ResourceGroup)' (need exactly 1 for unambiguous discovery). Pass -AcrName explicitly."
        }
    }

    try {
        $snapshot = Get-RbacDriftLiveSnapshot -Intent $intent
    } catch {
        Write-RbacDriftFatal "CV-1 could not capture a live snapshot: $($_.Exception.Message)"
    }
}

$findings = @(Compare-RbacDriftSnapshot -Snapshot $snapshot)
Write-RbacDriftFindings -Findings $findings -AsJson:$Json
exit (Get-RbacDriftExitCode -Findings $findings)
