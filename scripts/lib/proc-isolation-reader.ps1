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
#      (account show; containerapp job show; containerapp job execution
#      list; containerapp job logs show) and throws on anything else -- a
#      mutating verb, an unrecognised command shape, or a call missing an
#      explicit --subscription.
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
    , @("containerapp", "job", "show")
    , @("containerapp", "job", "execution", "list")
    , @("containerapp", "job", "logs", "show")
)

# L1 (issue #86, third revision): `az containerapp job logs show --tail` is
# documented as accepting 0-300 and REJECTS anything outside that range as a
# usage error. The prior revisions' default was 500, so every live log read
# they ever made was rejected by the CLI before it reached Azure -- and the
# reader then swallowed that non-zero exit and reported the honest-sounding
# "not-yet-observed". The bound is enforced here, in the reader, and again in
# scripts/proc-isolation-report.ps1 -- in both cases BEFORE any `az` process
# is started, so an out-of-range request fails closed rather than being
# discovered as a silent empty read.
$script:ProcIsoMaxTailLines = 300
$script:ProcIsoDefaultTailLines = 300

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
        throw "Invoke-ProcIsoAzRead refuses argv '$($AzArgs -join ' ')': it does not match any entry on the read-verb allowlist (account show; containerapp job show; containerapp job execution list; containerapp job logs show). This call was not attempted."
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
    if (-not $resourceGroup) { $resourceGroup = "rg-squad-aca-dev-centralus" }

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

function Assert-ProcIsoTailLines {
    <#
    .SYNOPSIS
        L1: fail closed on an out-of-range --tail BEFORE any `az` process is
        started. `az containerapp job logs show --tail` accepts 0-300; a
        value outside that range is rejected by the CLI as a usage error,
        which the prior revisions swallowed into a silent empty read.
    #>
    param([Parameter(Mandatory = $true)][int]$TailLines)

    if ($TailLines -lt 0 -or $TailLines -gt $script:ProcIsoMaxTailLines) {
        throw "TailLines must be between 0 and $($script:ProcIsoMaxTailLines) (the range 'az containerapp job logs show --tail' accepts); got $TailLines. No Azure call was attempted -- an out-of-range request is rejected by the CLI as a usage error, and a rejected read must never be reported as 'not-yet-observed'."
    }
}

function Resolve-ProcIsoContainerName {
    <#
    .SYNOPSIS
        L3: resolve the container name `az containerapp job logs show
        --container` needs, from the LIVE job's own template, through the
        same allowlisted chokepoint.

    .DESCRIPTION
        `--container` is required and must name a container in the job's
        template. Both prior revisions passed the JOB's name, which is only
        correct if the template happens to name its container after the job
        -- otherwise every log read fails, and (before L2) failed silently.

        The live template is authoritative:
          az containerapp job show --query properties.template.containers[0].name
        If that read fails (permissions, extension missing, drift), this
        falls back to the job name -- but records Source = "assumed" so the
        caller can state the assumption explicitly in its output rather than
        presenting a guess as fact.

    .OUTPUTS
        [pscustomobject] with Name, Source ("explicit"|"resolved"|"assumed")
        and Detail (why, when assumed).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Intent,
        [string]$ContainerName = ""
    )

    if ($ContainerName) {
        return [pscustomobject]@{
            Name   = $ContainerName
            Source = "explicit"
            Detail = "supplied by the caller via -ContainerName"
        }
    }

    $showResult = Invoke-ProcIsoAzRead -AzArgs @(
        "containerapp", "job", "show",
        "--name", $Intent.JobName,
        "--resource-group", $Intent.ResourceGroup,
        "--subscription", $Intent.SubscriptionId,
        "--query", "properties.template.containers[0].name",
        "--only-show-errors",
        "-o", "tsv"
    )
    $resolved = ""
    if ($showResult.ExitCode -eq 0) {
        $resolved = ((@($showResult.StdOut) -join "`n").Trim() -split "`n" | Where-Object { $_ -ne "" } | Select-Object -First 1)
        if ($null -eq $resolved) { $resolved = "" }
        $resolved = ([string]$resolved).Trim().Trim('"')
    }

    if ($resolved) {
        return [pscustomobject]@{
            Name   = $resolved
            Source = "resolved"
            Detail = "read from the live job template (properties.template.containers[0].name)"
        }
    }

    $why = if ($showResult.ExitCode -ne 0) {
        "'az containerapp job show' failed, exit $($showResult.ExitCode): $((@($showResult.StdErr) + @($showResult.StdOut)) -join ' ')"
    } else {
        "'az containerapp job show' returned no container name"
    }
    return [pscustomobject]@{
        Name   = $Intent.JobName
        Source = "assumed"
        Detail = "the job template could not be read ($why), so the container name is ASSUMED to equal the job name '$($Intent.JobName)'. If the template names its container differently, every log read below will fail -- and will be reported as a failure, never as 'not-yet-observed'."
    }
}

function Get-ProcIsoLiveObservation {
    <#
    .SYNOPSIS
        Reads recent executions of the given job and returns log lines in
        most-recent-first order, ready for
        scripts/lib/proc-isolation-parser.ps1's Get-ProcIsoObservation --
        together with an explicit account of what was scanned, what was
        actually read, and what failed.

    .DESCRIPTION
        Read-only: lists existing executions (never starts one) and reads
        their already-written console logs (never execs into a container).

        L2 (issue #86, third revision): a failure is never swallowed.
        * A failure of the account or execution-list read aborts by throwing
          -- the question could not be asked at all.
        * A per-execution log read failure is RECORDED in Failures and
          counted (ExecutionsScanned vs ExecutionsRead) rather than being
          silently `continue`d past. That silent continue is exactly how a
          run in which every single log read was rejected still reported the
          reassuring "not-yet-observed".

    .PARAMETER Intent
        The object returned by Resolve-ProcIsoIntent.

    .PARAMETER ExecutionLimit
        How many of the most recent executions to scan. Small and bounded on
        purpose: this is a diagnostic read, not a log archive export.

    .PARAMETER TailLines
        How many trailing console lines to read per execution. 0-300 (L1).

    .PARAMETER ContainerName
        Overrides container resolution (L3). Empty means: resolve from the
        live job template, falling back to the job name as an explicitly
        reported assumption.

    .OUTPUTS
        [pscustomobject] with ExecutionsScanned (int), ExecutionsRead (int),
        Failures (string[]), ContainerName, ContainerNameSource,
        ContainerNameDetail, and Lines (string[], most-recent execution
        first).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Intent,
        [int]$ExecutionLimit = 5,
        [int]$TailLines = 300,
        [string]$ContainerName = ""
    )

    # L1: before ANY az process is started.
    Assert-ProcIsoTailLines -TailLines $TailLines

    $sub = $Intent.SubscriptionId

    $accountShown = Invoke-ProcIsoAzRead -AzArgs @("account", "show", "--subscription", $sub, "--only-show-errors", "-o", "none")
    if ($accountShown.ExitCode -ne 0) {
        throw "Could not confirm the target subscription is reachable ('az account show --subscription <id>' failed, exit $($accountShown.ExitCode)): $((@($accountShown.StdErr) + @($accountShown.StdOut)) -join ' ')"
    }

    $container = Resolve-ProcIsoContainerName -Intent $Intent -ContainerName $ContainerName

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
    $failures = @()
    $read = 0
    foreach ($name in $names) {
        # `--format json` is pinned explicitly rather than left to the
        # command's own default. It happens to match today's documented
        # default, and that is precisely why it is pinned: the parser's
        # unwrap step depends on the NDJSON {"Log":...} envelope, and a
        # default is not a contract.
        $logsResult = Invoke-ProcIsoAzRead -AzArgs @(
            "containerapp", "job", "logs", "show",
            "--name", $Intent.JobName,
            "--resource-group", $Intent.ResourceGroup,
            "--execution", $name,
            "--container", $container.Name,
            "--tail", ([string]$TailLines),
            "--subscription", $sub,
            "--format", "json",
            "--only-show-errors"
        )
        if ($logsResult.ExitCode -ne 0) {
            # L2: recorded, never silently skipped. An execution whose logs
            # could not be read is NOT evidence of absence -- it is an
            # unread execution, and the caller must be able to say so.
            $failures += "execution '$name': 'az containerapp job logs show' failed, exit $($logsResult.ExitCode): $(((@($logsResult.StdErr) + @($logsResult.StdOut)) -join ' ').Trim())"
            continue
        }
        $read++
        # Most-recent occurrence within THIS execution first.
        $execLines = @($logsResult.StdOut)
        [array]::Reverse($execLines)
        $lines += $execLines
    }

    return [pscustomobject]@{
        ExecutionsScanned   = $names.Count
        ExecutionsRead      = $read
        Failures            = $failures
        ContainerName       = $container.Name
        ContainerNameSource = $container.Source
        ContainerNameDetail = $container.Detail
        Lines               = $lines
    }
}
