# dispatch-contract.ps1 -- the PowerShell face of the ONE dispatch decision.
#
# Sprint 6 of PRD #6 requires that "Ralph, Watch, and local CLI share one
# routing decision". Ralph is bash and this CLI is PowerShell, so the rule could
# not be written twice without the two copies drifting -- which is exactly the
# failure the requirement exists to prevent.
#
# So there is only ONE implementation, and it is neither of them:
#
#     worker/lib/squad-dispatch.js
#         -> worker/lib/dispatch-decision.js   (the routing decision)
#         -> worker/lib/dispatch-lease.js      (the lease protocol)
#
# Node was chosen because the Sprint 2 capability resolver that actually decides
# the route (worker/lib/resolve-capability-route.js) is already Node, Ralph
# already shells out to `node` to build its session env, and the worker image
# ships Node. Every function in this file is a thin, non-interpreting shim: it
# passes arguments through and parses one line of JSON back. No routing or lease
# rule is expressed here.
#
# FAIL CLOSED. If `node` or the dispatch core is missing, these functions throw.
# Falling back to a PowerShell-local guess would silently reintroduce the second
# implementation this design exists to remove.
#
# NOTE: no Set-StrictMode here. This file is dot-sourced into squad-aca.ps1, and
# a strict-mode change would apply to the entire CLI, not just these functions.

$script:SquadDispatchExitUsage = 64
$script:SquadDispatchExitRefused = 65
$script:SquadDispatchExitCatalog = 70

function Get-SquadDispatchCliPath {
    <#
    .SYNOPSIS
        Absolute path to the shared dispatch CLI.
    .DESCRIPTION
        SQUAD_DISPATCH_CLI overrides the location so the offline harness can run
        against a copy of the tree. Otherwise it is resolved relative to this
        file: scripts/lib/ -> worker/lib/squad-dispatch.js.
    #>
    if ($env:SQUAD_DISPATCH_CLI) { return $env:SQUAD_DISPATCH_CLI }
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    return (Join-Path $repoRoot "worker\lib\squad-dispatch.js")
}

function Invoke-SquadDispatchCli {
    <#
    .SYNOPSIS
        Run the shared dispatch CLI and capture stdout, stderr and the real exit
        code -- never a stale $LASTEXITCODE.
    .DESCRIPTION
        Mirrors Invoke-AzPromptSafe (scripts/lib/aca-logs.ps1): native stderr is
        captured instead of being allowed to become a terminating
        NativeCommandError, so the caller decides what a non-zero exit means.
        Exit 127 means node itself could not be run and is never mistaken for a
        routing or lease answer.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$StandardInput
    )

    $cli = Get-SquadDispatchCliPath
    $previousEap = $ErrorActionPreference
    $merged = @()
    $exitCode = -1
    try {
        $ErrorActionPreference = "Continue"
        if ($PSBoundParameters.ContainsKey("StandardInput")) {
            $merged = $StandardInput | & node $cli @Arguments 2>&1
        } else {
            $merged = & node $cli @Arguments 2>&1
        }
        $exitCode = $LASTEXITCODE
    } catch {
        $merged = @($_.Exception.Message)
        $exitCode = 127
    } finally {
        $ErrorActionPreference = $previousEap
    }

    $stdout = @()
    $stderr = @()
    foreach ($line in @($merged)) {
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            $stderr += [string]$line
        } else {
            $stdout += [string]$line
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = ($stdout -join "`n")
        StdErr   = ($stderr -join "`n")
    }
}

function ConvertFrom-SquadDispatchOutput {
    param([Parameter(Mandatory = $true)][object]$Result, [Parameter(Mandatory = $true)][string]$What)

    $text = [string]$Result.StdOut
    if (-not $text.Trim()) { return $null }
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        throw "Could not parse the dispatch core's response for $What."
    }
}

function Assert-SquadDispatchSucceeded {
    param([Parameter(Mandatory = $true)][object]$Result, [Parameter(Mandatory = $true)][string]$What)

    if ($Result.ExitCode -eq 0) { return }

    if ($Result.ExitCode -eq 127) {
        throw ("Cannot $What`: the shared dispatch core could not be run. " +
            "Node is required so that Ralph, Watch and this CLI resolve the SAME routing decision " +
            "(see docs/architecture.md, 'Unified dispatch contract'). Install Node 18+ and retry.")
    }

    $detail = if ($Result.StdErr) { $Result.StdErr } elseif ($Result.StdOut) { $Result.StdOut } else { "no detail" }
    throw "Cannot $What`: the shared dispatch core exited $($Result.ExitCode). $detail"
}

function Get-SquadDispatchDecision {
    <#
    .SYNOPSIS
        Resolve THE routing decision for one unit of work.
    .DESCRIPTION
        The returned object is byte-for-byte identical to what Ralph and Watch
        get for the same input, because it is produced by the same file. A
        fail-closed route (exit 65) throws here: the CLI must not dispatch work
        the shared decision refuses.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$DispatchSource,
        [Parameter(Mandatory = $true)][string]$Repository,
        [string]$IssueNumber,
        [string]$RepoDir
    )

    $cliArgs = @("decide", "--session-id", $SessionId, "--dispatch-source", $DispatchSource, "--repository", $Repository)
    if ($IssueNumber) { $cliArgs += @("--issue", $IssueNumber) }
    if ($RepoDir) { $cliArgs += @("--repo-dir", $RepoDir) }

    $result = Invoke-SquadDispatchCli -Arguments $cliArgs
    if ($result.ExitCode -eq $script:SquadDispatchExitRefused) {
        $decision = ConvertFrom-SquadDispatchOutput -Result $result -What "the routing decision"
        $detail = if ($decision) { [string]$decision.routing.detail } else { "the capability manifest refuses this route" }
        throw "Refusing to dispatch session '$SessionId': $detail"
    }
    Assert-SquadDispatchSucceeded -Result $result -What "resolve a dispatch route"

    $decision = ConvertFrom-SquadDispatchOutput -Result $result -What "the routing decision"
    if (-not $decision) { throw "The shared dispatch core returned no routing decision for session '$SessionId'." }
    return $decision
}

function New-SquadDispatchLease {
    <#
    .SYNOPSIS
        Write the durable lease BEFORE compute is requested.
    .DESCRIPTION
        Takes the decision object from Get-SquadDispatchDecision and hands it to
        the dispatch core on stdin, so a claim can never be made against a route
        that was computed some other way. Returns the claim outcome:
            created   a fresh lease; the caller owns the work
            repaired  an abandoned claim was adopted; the caller owns the work
            active    someone else holds a live lease; DO NOT dispatch
            completed the work already reached a terminal state; DO NOT dispatch
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [Parameter(Mandatory = $true)][string]$Repository
    )

    $json = ($Decision | ConvertTo-Json -Depth 20 -Compress)
    $result = Invoke-SquadDispatchCli -Arguments @("claim", "--repository", $Repository) -StandardInput $json
    Assert-SquadDispatchSucceeded -Result $result -What "claim a dispatch lease"
    $claim = ConvertFrom-SquadDispatchOutput -Result $result -What "the lease claim"
    if (-not $claim) { throw "The shared dispatch core returned no claim result for '$($Decision.leaseKey)'." }
    return $claim
}

function Set-SquadDispatchLeaseState {
    <#
    .SYNOPSIS
        Advance a lease: dispatched | heartbeat | complete | release.
    .DESCRIPTION
        Every one of these is idempotent in the dispatch core -- already-applied,
        already-terminal and externally-deleted are all SUCCESS -- but an auth,
        RBAC, throttling or network fault still throws. That distinction is the
        same one Test-AcaJobExecutionGone makes for `az`; it is implemented once,
        in worker/lib/dispatch-lease.js, and never re-derived here.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet("dispatched", "heartbeat", "complete", "release")][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$LeaseKey,
        [string]$State,
        [string]$Reason,
        [string]$ExecutionRef
    )

    $cliArgs = @($Operation, "--repository", $Repository, "--lease-key", $LeaseKey)
    if ($State) { $cliArgs += @("--state", $State) }
    if ($Reason) { $cliArgs += @("--reason", $Reason) }
    if ($ExecutionRef) { $cliArgs += @("--execution-ref", $ExecutionRef) }

    $result = Invoke-SquadDispatchCli -Arguments $cliArgs
    Assert-SquadDispatchSucceeded -Result $result -What "record lease state '$Operation'"
    return (ConvertFrom-SquadDispatchOutput -Result $result -What "the lease update")
}

function Invoke-SquadLeaseSweep {
    <#
    .SYNOPSIS
        Reclaim leases whose heartbeat has aged out. Idempotent.
    #>
    param([Parameter(Mandatory = $true)][string]$Repository)

    $result = Invoke-SquadDispatchCli -Arguments @("sweep", "--repository", $Repository)
    Assert-SquadDispatchSucceeded -Result $result -What "sweep stale leases"
    return (ConvertFrom-SquadDispatchOutput -Result $result -What "the sweep result")
}

function Get-SquadDispatchLease {
    <#
    .SYNOPSIS
        List lease records for a repository.
    #>
    param([Parameter(Mandatory = $true)][string]$Repository)

    $result = Invoke-SquadDispatchCli -Arguments @("list", "--repository", $Repository)
    Assert-SquadDispatchSucceeded -Result $result -What "list dispatch leases"
    $listed = ConvertFrom-SquadDispatchOutput -Result $result -What "the lease list"
    if (-not $listed) { return @() }
    return @($listed.leases)
}
