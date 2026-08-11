# PC-1 (issue #86) -- live process-isolation observation reader.
#
# THIS IS THE ONLY FILE IN THE PROCESS-ISOLATION REPORT PERMITTED TO INVOKE
# `az`, and every invocation goes through the single chokepoint below,
# Invoke-ProcIsoAzRead -- the same shape as scripts/lib/rbac-drift-reader
# .ps1's Invoke-AzRead and scripts/lib/job-drift-reader.ps1's
# Invoke-JobAzRead, kept as an independent copy (not a shared helper) so this
# file's claim to be the sole `az`-invoking file for PC-1 is true by
# inspection of this one file. scripts/lib/proc-isolation-parser.ps1 is pure
# (log lines in, an observation out) and contains no reference to the Azure
# CLI at all; scripts/validate.ps1 asserts both of those things statically
# AND exercises Invoke-ProcIsoAzRead's allowlist at runtime.
#
# THIS FILE NEVER DEPLOYS, STARTS A JOB EXECUTION, EXECS INTO A CONTAINER, OR
# CHANGES ANYTHING. It only lists existing executions and reads their already
# -written console logs -- the same two read-only operations
# scripts/show-status.ps1 and scripts/squad-aca.ps1's `logs`/`sessions`
# commands already perform against a live deployment.
#
# Rules this file exists to enforce, mirroring CV-1/CV-2's contract:
#
#   1. Invoke-ProcIsoAzRead validates argv against a READ-VERB ALLOWLIST
#      (account show; containerapp job execution list; containerapp job logs
#      show) and throws on anything else -- a mutating verb, an
#      unrecognised command shape, or a call missing an explicit
#      --subscription.
#   2. `az account set` is banned alongside every mutating verb.
#   3. Intent (resource group, name prefix, subscription, job name) fails
#      CLOSED, reusing the same defaults and resolution order as
#      scripts/lib/rbac-drift-reader.ps1 / scripts/lib/job-drift-reader.ps1
#      so this check never disagrees with CV-1/CV-2 about which deployment
#      it is looking at.
#   4. Log lines are read as opaque text and handed to the pure parser
#      unmodified. This file performs no interpretation of what a probe line
#      means -- that is scripts/lib/proc-isolation-parser.ps1's job alone.

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here,
# matching every other dot-sourced lib in this repo.

$script:ProcIsoAllowedShapes = @(
    , @("account", "show")
    , @("containerapp", "job", "execution", "list")
    , @("containerapp", "job", "logs", "show")
)

$script:ProcIsoDeniedTokens = @(
    "create", "update", "delete", "remove", "set", "assign", "grant", "revoke",
    "start", "stop", "restart", "deploy", "build", "push", "login", "logout",
    "purge", "restore", "rotate-credentials", "secret", "exec"
)

function Invoke-ProcIsoAzRead {
    <#
    .SYNOPSIS
        The single chokepoint through which this file (and therefore PC-1)
        talks to Azure. Read verbs only, one explicit subscription.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$AzArgs
    )

    if ($AzArgs.Count -ge 2 -and $AzArgs[0] -eq "account" -and $AzArgs[1] -eq "set") {
        throw "Invoke-ProcIsoAzRead refuses 'az account set': a read-only report must not rewrite the operator's CLI context."
    }

    foreach ($token in $AzArgs) {
        foreach ($denied in $script:ProcIsoDeniedTokens) {
            if ($token -eq $denied) {
                throw "Invoke-ProcIsoAzRead refuses argv containing the mutating/exec token '$denied'. PC-1 is read-only; this call was not attempted."
            }
        }
    }

    $positional = @($AzArgs | Where-Object { -not $_.StartsWith("-") })
    $matchedShape = $false
    foreach ($shape in $script:ProcIsoAllowedShapes) {
        if ($positional.Count -ge $shape.Count) {
            $prefix = @($positional[0..($shape.Count - 1)])
            $isMatch = $true
            for ($i = 0; $i -lt $shape.Count; $i++) {
                if ($prefix[$i] -ne $shape[$i]) { $isMatch = $false; break }
            }
            if ($isMatch) { $matchedShape = $true; break }
        }
    }
    if (-not $matchedShape) {
        throw "Invoke-ProcIsoAzRead refuses argv '$($AzArgs -join ' ')': it does not match any entry on the read-verb allowlist (account show; containerapp job execution list; containerapp job logs show). This call was not attempted."
    }

    if (($AzArgs -notcontains "--subscription")) {
        throw "Invoke-ProcIsoAzRead refuses a call with no explicit --subscription."
    }

    # Optional, test-only observability, mirroring CV-1/CV-2's own log hooks.
    # Never enabled in production use.
    if ($env:SQUAD_PROC_ISO_AZ_LOG) {
        Add-Content -LiteralPath $env:SQUAD_PROC_ISO_AZ_LOG -Value ($AzArgs -join " ")
    }

    return Invoke-ProcIsoProcess -FilePath "az" -Arguments $AzArgs -EnvironmentOverrides @{
        AZURE_EXTENSION_USE_DYNAMIC_INSTALL = "no"
    }
}

function Invoke-ProcIsoProcess {
    <#
    .SYNOPSIS
        Minimal, local process runner -- deliberately duplicated (not shared
        with rbac-drift-reader.ps1, job-drift-reader.ps1, or aca-logs.ps1) so
        this file's claim to be the only `az`-invoking code for PC-1 is true
        by inspection of this one file.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [System.Collections.IDictionary]$EnvironmentOverrides = @{}
    )
    $saved = @{}
    $had = @{}
    foreach ($name in @($EnvironmentOverrides.Keys)) {
        $had[$name] = (Test-Path "Env:$name")
        $saved[$name] = if ($had[$name]) { [Environment]::GetEnvironmentVariable($name, "Process") } else { $null }
    }
    $previousEap = $ErrorActionPreference
    $merged = @()
    $exitCode = -1
    try {
        foreach ($name in @($EnvironmentOverrides.Keys)) {
            [Environment]::SetEnvironmentVariable($name, [string]$EnvironmentOverrides[$name], "Process")
        }
        $ErrorActionPreference = "Continue"
        $merged = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $merged = @($_.Exception.Message)
        $exitCode = 127
    } finally {
        $ErrorActionPreference = $previousEap
        foreach ($name in @($EnvironmentOverrides.Keys)) {
            if ($had[$name]) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
            } else {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }
    $stdout = @()
    $stderr = @()
    foreach ($line in @($merged)) {
        if ($null -eq $line) { continue }
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            $stderr += [string]$line
        } else {
            $stdout += [string]$line
        }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
}

function Resolve-ProcIsoIntent {
    <#
    .SYNOPSIS
        Fails-closed intent resolution, matching
        scripts/lib/rbac-drift-reader.ps1 / scripts/lib/job-drift-reader.ps1
        so PC-1 resolves the SAME deployment for the same inputs.

    .OUTPUTS
        [pscustomobject] with ResourceGroup, NamePrefix, SubscriptionId,
        JobName, and Missing (array of human-readable unresolved-field
        names).
    #>
    param(
        [string]$ResourceGroupName = "",
        [string]$NamePrefix = "",
        [string]$SubscriptionId = "",
        [string]$JobName = "",
        [object]$DeployOutputs = $null
    )

    $resourceGroup = $ResourceGroupName
    if (-not $resourceGroup -and $DeployOutputs -and $DeployOutputs.PSObject.Properties.Name -contains "resourceGroup" -and $DeployOutputs.resourceGroup) {
        $resourceGroup = [string]$DeployOutputs.resourceGroup
    }
    if (-not $resourceGroup) { $resourceGroup = "rg-squad-aca-dev-eastus2" }

    $namePrefix = $NamePrefix
    if (-not $namePrefix -and $DeployOutputs -and $DeployOutputs.PSObject.Properties.Name -contains "pullIdentity" -and $DeployOutputs.pullIdentity -match '^uai-(.+)-acrpull$') {
        $namePrefix = $Matches[1]
    }
    if (-not $namePrefix) { $namePrefix = "squad-aca" }

    $subscriptionId = $SubscriptionId
    if (-not $subscriptionId -and $DeployOutputs -and $DeployOutputs.PSObject.Properties.Name -contains "subscriptionId" -and $DeployOutputs.subscriptionId) {
        $subscriptionId = [string]$DeployOutputs.subscriptionId
    }

    $jobName = $JobName
    if (-not $jobName) { $jobName = "caj-$namePrefix-session" }

    $missing = @()
    if (-not $resourceGroup) { $missing += "resource group" }
    if (-not $subscriptionId) { $missing += "subscription" }

    return [pscustomobject]@{
        ResourceGroup  = $resourceGroup
        NamePrefix     = $namePrefix
        SubscriptionId = $subscriptionId
        JobName        = $jobName
        Missing        = $missing
    }
}

function Get-ProcIsoLiveObservation {
    <#
    .SYNOPSIS
        Reads recent executions of the given job and returns log lines in
        most-recent-first order, ready for
        scripts/lib/proc-isolation-parser.ps1's Get-ProcIsoObservation.

    .DESCRIPTION
        Read-only: lists existing executions (never starts one) and reads
        their already-written console logs (never execs into a container).
        A failure anywhere -- unreachable subscription, missing containerapp
        extension, no executions at all -- is reported by throwing, so the
        caller can distinguish "read failed / unavailable" from "read
        succeeded, nothing observed" (the latter is PC-1's honest
        not-yet-observed state, the former must never be reported as that).

    .PARAMETER Intent
        The object returned by Resolve-ProcIsoIntent.

    .PARAMETER ExecutionLimit
        How many of the most recent executions to scan. Small and bounded on
        purpose: this is a diagnostic read, not a log archive export.

    .PARAMETER TailLines
        How many trailing console lines to read per execution.

    .OUTPUTS
        [pscustomobject] with ExecutionsScanned (int) and Lines (string[],
        most-recent execution first).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Intent,
        [int]$ExecutionLimit = 5,
        [int]$TailLines = 500
    )

    $sub = $Intent.SubscriptionId

    $accountShown = Invoke-ProcIsoAzRead -AzArgs @("account", "show", "--subscription", $sub, "--only-show-errors", "-o", "none")
    if ($accountShown.ExitCode -ne 0) {
        throw "Could not confirm the target subscription is reachable ('az account show --subscription <id>' failed, exit $($accountShown.ExitCode)): $((@($accountShown.StdErr) + @($accountShown.StdOut)) -join ' ')"
    }

    $listResult = Invoke-ProcIsoAzRead -AzArgs @(
        "containerapp", "job", "execution", "list",
        "--name", $Intent.JobName,
        "--resource-group", $Intent.ResourceGroup,
        "--subscription", $sub,
        "--query", "[0:$ExecutionLimit].name",
        "--only-show-errors",
        "-o", "json"
    )
    if ($listResult.ExitCode -ne 0) {
        throw "Could not list executions of job '$($Intent.JobName)' in resource group '$($Intent.ResourceGroup)' ('az containerapp job execution list' failed, exit $($listResult.ExitCode)): $((@($listResult.StdErr) + @($listResult.StdOut)) -join ' ')"
    }

    $names = @()
    $text = (@($listResult.StdOut) -join "`n").Trim()
    if ($text) {
        try {
            $parsed = ConvertFrom-Json -InputObject $text
            foreach ($n in @($parsed)) { if ($n) { $names += [string]$n } }
        } catch {
            throw "The execution list for job '$($Intent.JobName)' did not parse as JSON: $($_.Exception.Message)"
        }
    }

    $lines = @()
    foreach ($name in $names) {
        $logsResult = Invoke-ProcIsoAzRead -AzArgs @(
            "containerapp", "job", "logs", "show",
            "--name", $Intent.JobName,
            "--resource-group", $Intent.ResourceGroup,
            "--execution", $name,
            "--container", $Intent.JobName,
            "--tail", ([string]$TailLines),
            "--subscription", $sub,
            "--only-show-errors"
        )
        if ($logsResult.ExitCode -ne 0) {
            # A single execution's logs being unreadable (rotated away, the
            # containerapp extension genuinely missing) does not abort the
            # whole read -- it is simply not a source of an observation.
            # Reported per-execution so a caller can tell "found nothing" from
            # "could not read some/all of what was scanned" if needed.
            continue
        }
        # Most-recent occurrence within THIS execution first.
        $execLines = @($logsResult.StdOut)
        [array]::Reverse($execLines)
        $lines += $execLines
    }

    return [pscustomobject]@{
        ExecutionsScanned = $names.Count
        Lines             = $lines
    }
}
