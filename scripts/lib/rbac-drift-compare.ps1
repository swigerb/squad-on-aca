# CV-1 (issue #85) -- pure RBAC drift comparer.
#
# THIS FILE CONTAINS NO REFERENCE TO THE AZURE CLI. It is snapshot in,
# findings out, and nothing here reaches a network, a filesystem, or a child
# process. scripts/validate.ps1 asserts this statically (grep for a standalone
# Azure CLI command-name token) as well as functionally, so the split between
# this file and scripts/lib/rbac-drift-reader.ps1 is a build-time guarantee
# rather than a convention a later edit could quietly erode (security
# contract, rule 1).
#
# Fixtures under scripts/tests/fixtures/rbac-drift/*.json drive this comparer
# directly: a drifted case is proven to fail without contacting the cloud and
# without any mutation, which is the whole point of splitting reader from
# comparer in the first place.

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here, matching
# the reader and every other dot-sourced lib in this repo.

# The expected assignment set for the session identity. This is the target
# state deploy.ps1 (scripts/deploy.ps1) actually applies today: AcrPull on the
# registry, Container Apps Jobs Operator scoped to the single session job, and
# nothing else. Anything the session identity holds beyond this set is
# broader-than-intent drift (status "unexpectedScope"), and anything in this
# set the identity does NOT hold is a missing grant (status "missingAssignment").
$script:RbacDriftExpectedSessionAssignments = @(
    [pscustomobject]@{ RoleName = "AcrPull"; ScopeType = "registry" }
    [pscustomobject]@{ RoleName = "Container Apps Jobs Operator"; ScopeType = "sessionJob" }
)

# The expected assignment set for the OPTIONAL GitHub Actions federated
# identity, when it is present at all. Absence is its own status
# ("absentOptionalPrincipal", severity info) and is asserted separately --
# see Compare-RbacDriftSnapshot below. "Absent" and "correct" must never read
# the same (security contract, ruling 1).
$script:RbacDriftExpectedGithubActionsAssignments = @(
    [pscustomobject]@{ RoleName = "Container Apps Jobs Operator"; ScopeType = "sessionJob" }
)

function New-RbacDriftFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Principal,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][ValidateSet("info", "high")][string]$Severity,
        [string]$RoleName = "",
        [string]$ScopeType = "",
        [string]$Detail = ""
    )
    return [pscustomobject]@{
        Principal = $Principal
        Status    = $Status
        Severity  = $Severity
        RoleName  = $RoleName
        ScopeType = $ScopeType
        Detail    = $Detail
    }
}

function Compare-RbacDriftPrincipalAssignments {
    <#
    .SYNOPSIS
        Shared logic for one principal's held assignments against its
        expected set: every expected entry is either "ok" or
        "missingAssignment"; every held entry not in the expected set is
        "unexpectedScope" (broader than intent, whatever the extra role or
        scope actually is -- the security contract's own wording for exactly
        this case, e.g. a resource-group-scoped Contributor grant).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PrincipalLabel,
        [Parameter(Mandatory = $true)][object[]]$Held,
        [Parameter(Mandatory = $true)][object[]]$Expected
    )
    $findings = @()
    foreach ($expectedEntry in $Expected) {
        $match = @($Held | Where-Object { $_.roleName -eq $expectedEntry.RoleName -and $_.scopeType -eq $expectedEntry.ScopeType })
        if ($match.Count -eq 0) {
            $findings += New-RbacDriftFinding -Principal $PrincipalLabel -Status "missingAssignment" -Severity "high" `
                -RoleName $expectedEntry.RoleName -ScopeType $expectedEntry.ScopeType `
                -Detail "expected '$($expectedEntry.RoleName)' on $($expectedEntry.ScopeType) but it is not held"
        } else {
            $findings += New-RbacDriftFinding -Principal $PrincipalLabel -Status "ok" -Severity "info" `
                -RoleName $expectedEntry.RoleName -ScopeType $expectedEntry.ScopeType -Detail "matches intent"
        }
    }
    foreach ($assignment in $Held) {
        $isExpected = @($Expected | Where-Object { $_.RoleName -eq $assignment.roleName -and $_.ScopeType -eq $assignment.scopeType }).Count -gt 0
        if (-not $isExpected) {
            $findings += New-RbacDriftFinding -Principal $PrincipalLabel -Status "unexpectedScope" -Severity "high" `
                -RoleName $assignment.roleName -ScopeType $assignment.scopeType `
                -Detail "holds '$($assignment.roleName)' at $($assignment.scopeType), broader than intent"
        }
    }
    return $findings
}

function Compare-RbacDriftSnapshot {
    <#
    .SYNOPSIS
        Pure comparison: snapshot object in, findings array out. Never touches
        the Azure CLI, the filesystem, or the network -- the SAME snapshot
        object shape (schema squad-aca/rbac-drift-snapshot@1) is produced
        either by scripts/lib/rbac-drift-reader.ps1's Get-RbacDriftLiveSnapshot
        (live) or by loading a committed fixture (offline test).

    .PARAMETER Snapshot
        A [pscustomobject] with .principals (array of {role, present,
        principalAlias, assignments}) and .scopedAssignments ({registry,
        sessionJob} arrays of {principalAlias, roleName, assignmentAlias}).

    .OUTPUTS
        [pscustomobject[]] findings, each with Principal / Status / Severity /
        RoleName / ScopeType / Detail. Feed the result to
        Get-RbacDriftExitCode for the process exit code.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    $findings = @()

    $session = $Snapshot.principals | Where-Object { $_.role -eq "session" } | Select-Object -First 1
    if (-not $session -or -not $session.present) {
        $findings += New-RbacDriftFinding -Principal "session" -Status "missingAssignment" -Severity "high" `
            -Detail "no session identity was found in the snapshot"
    } else {
        $findings += Compare-RbacDriftPrincipalAssignments -PrincipalLabel "session" `
            -Held @($session.assignments) -Expected $script:RbacDriftExpectedSessionAssignments
    }

    $gha = $Snapshot.principals | Where-Object { $_.role -eq "githubActions" } | Select-Object -First 1
    if (-not $gha -or -not $gha.present) {
        # Its own status, its own severity, exit 0 on its own. This must never
        # collapse into "ok" -- that is the distinction ruling 1 exists for.
        $findings += New-RbacDriftFinding -Principal "githubActions" -Status "absentOptionalPrincipal" -Severity "info" `
            -Detail "the GitHub Actions federated identity is not present; this is informational, not a failure"
    } else {
        $findings += Compare-RbacDriftPrincipalAssignments -PrincipalLabel "githubActions" `
            -Held @($gha.assignments) -Expected $script:RbacDriftExpectedGithubActionsAssignments
    }

    # Layer 2 (security contract, rule 2 / ruling 3): a bounded, scope-anchored
    # check for a principal that is NOT one of the deployment's own principals
    # holding a grant at a resource this deployment owns. The inherited-scope
    # expansion flag banned elsewhere in this contract is never used to
    # produce scopedAssignments (rbac-drift-reader.ps1 does not pass it,
    # ever), so this only ever reports a grant made directly at the registry
    # or the session job scope -- never an inherited one.
    $knownPrincipalAliases = @()
    if ($session -and $session.present) { $knownPrincipalAliases += $session.principalAlias }
    if ($gha -and $gha.present) { $knownPrincipalAliases += $gha.principalAlias }

    foreach ($scopeKey in @("registry", "sessionJob")) {
        $entries = @()
        if ($Snapshot.scopedAssignments -and ($Snapshot.scopedAssignments.PSObject.Properties.Name -contains $scopeKey)) {
            $entries = @($Snapshot.scopedAssignments.$scopeKey)
        }
        foreach ($entry in $entries) {
            if (-not $entry) { continue }
            if ($entry.principalAlias -notin $knownPrincipalAliases) {
                $findings += New-RbacDriftFinding -Principal "unknown" -Status "unexpectedPrincipal" -Severity "high" `
                    -RoleName $entry.roleName -ScopeType $scopeKey `
                    -Detail "a principal that is not one of the deployment's own principals holds '$($entry.roleName)' at $scopeKey"
            }
        }
    }

    return $findings
}

function Get-RbacDriftExitCode {
    <#
    .SYNOPSIS
        0 when no finding is high severity, 1 otherwise. absentOptionalPrincipal
        and ok findings are info severity and never fail the build on their
        own -- only missingAssignment, unexpectedScope and unexpectedPrincipal
        do.
    #>
    param([object[]]$Findings)
    $highSeverity = @($Findings | Where-Object { $_.Severity -eq "high" })
    if ($highSeverity.Count -gt 0) { return 1 }
    return 0
}
