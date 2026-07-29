<#
.SYNOPSIS
    ACA Jobs adapter for the Squad execution provider contract.

.DESCRIPTION
    Implements create / wait / status / logs / cancel / terminate over Azure
    Container Apps Jobs, using exactly the `az` invocations the CLI made inline
    before the provider seam existed.

    BEHAVIOUR-PRESERVATION CONTRACT (the whole point of this file):

      * The `az` command lines below are byte-for-byte the ones
        scripts/squad-aca.ps1 issued on main -- same subcommands, same flag
        order, same values. scripts/validate.ps1 asserts the recorded `az`
        argv for `sessions`, `logs`, and `stop` against a stubbed `az` on PATH.
      * `logs` and `cancel` pass `az` output straight through. They never
        capture, reformat, or suppress it, and they never translate an `az`
        failure into a PowerShell error. PR #9 was closed partly for an
        observable `stop` regression; that is the exact failure mode this rule
        prevents.
      * The Display object returned by `status` has the same properties, in the
        same order, as the old Get-SessionExecutions output, so
        `Format-Table -AutoSize` renders an identical table.

    Sandboxes are NOT handled here. This adapter is only ever the `aca-job`
    execution mode.
#>

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here.

$script:AcaJobProviderId = "aca-job"

function New-AcaJobExecutionProvider {
    <#
    .SYNOPSIS
        Constructs the ACA Jobs provider.

    .PARAMETER Config
        Resolved ACA config (Get-AcaConfig output): resourceGroup, sessionJob, ...

    .PARAMETER ScriptDir
        The scripts/ directory, used to locate start-session.ps1 for dispatch.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [string]$ScriptDir = ""
    )

    $context = [pscustomobject]@{
        Config    = $Config
        ScriptDir = $ScriptDir
    }

    $operations = [ordered]@{}

    # -- create --------------------------------------------------------------
    # Delegates to start-session.ps1 exactly as the CLI did. start-session.ps1
    # owns all dispatch output; nothing is captured, so the user sees precisely
    # what `az containerapp job start` prints. Optional parameters are always
    # supplied, but their empty/false values are identical to omitting them
    # (start-session.ps1 defaults them to "" / [switch]$false).
    $operations["create"] = {
        param($Context, $Arguments)

        $request = $Arguments["Request"]
        if (-not $request) { throw "The ACA Jobs provider requires a dispatch request." }

        $start = Join-Path $Context.ScriptDir "start-session.ps1"
        $prefs = $request.executionPreferences

        & $start `
            -ResourceGroupName $Context.Config.resourceGroup `
            -JobName $Context.Config.sessionJob `
            -Repository $request.repository.fullName `
            -Ref $request.repository.ref `
            -Mode $prefs.mode `
            -SessionName $request.sessionId `
            -Prompt $request.task.prompt `
            -SubSquad $prefs.subSquad `
            -RunCopilotSmoke:$prefs.runCopilotSmoke `
            -PushChanges:$prefs.pushChanges `
            -OutputBranch $request.git.outputBranch

        # The response travels through Outcome, never the pipeline, so the
        # pass-through dispatch output above stays the only thing a caller sees.
        # ACA Jobs names an execution asynchronously, so there is no handle to
        # mint at dispatch time; callers poll by session name via `status`.
        if ($Arguments["Outcome"]) {
            $Arguments["Outcome"]["Response"] = New-SquadDispatchResponse `
                -SessionId $request.sessionId `
                -ExecutionMode "aca-job" `
                -Status "Requested" `
                -SessionHandle ""
        }
    }

    # -- status --------------------------------------------------------------
    # Two forms. Limit  -> newest-first list (what `sessions` renders).
    #            Handle -> a single execution behind an opaque handle.
    $operations["status"] = {
        param($Context, $Arguments)

        if ($Arguments.Contains("Handle") -and $Arguments["Handle"]) {
            $decoded = ConvertFrom-SquadExecutionHandle -Handle $Arguments["Handle"] -ExpectedProviderId "aca-job"
            $payload = $decoded.Payload
            $json = az containerapp job execution show --name $payload.job --resource-group $payload.rg --job-execution-name $payload.execution -o json
            $execution = $null
            if ($json) { $execution = $json | ConvertFrom-Json }
            if (-not $execution) {
                throw "Execution '$($payload.execution)' was not found in job '$($payload.job)'."
            }
            return ConvertTo-AcaJobExecutionRecord -Config $Context.Config -Name $payload.execution -Execution $execution
        }

        $limit = 10
        if ($Arguments.Contains("Limit") -and $Arguments["Limit"]) { $limit = [int]$Arguments["Limit"] }

        $config = $Context.Config
        $names = az containerapp job execution list --name $config.sessionJob --resource-group $config.resourceGroup --query "[0:$limit].name" -o json | ConvertFrom-Json
        $items = @()
        foreach ($name in $names) {
            $execution = az containerapp job execution show --name $config.sessionJob --resource-group $config.resourceGroup --job-execution-name $name -o json | ConvertFrom-Json
            $items += ConvertTo-AcaJobExecutionRecord -Config $config -Name $name -Execution $execution
        }
        return $items
    }

    # -- wait ----------------------------------------------------------------
    # Readiness polling. Not wired to any CLI command in this sprint (adding a
    # wait to `run` would be an observable change); it exists so the contract is
    # complete and Sprint 5 has a readiness primitive.
    $operations["wait"] = {
        param($Context, $Arguments)

        $handle = $Arguments["Handle"]
        $timeout = 300
        if ($Arguments.Contains("TimeoutSeconds") -and $Arguments["TimeoutSeconds"]) { $timeout = [int]$Arguments["TimeoutSeconds"] }
        $poll = 5
        if ($Arguments.Contains("PollSeconds") -and $Arguments["PollSeconds"]) { $poll = [int]$Arguments["PollSeconds"] }

        $deadline = (Get-Date).AddSeconds($timeout)
        while ($true) {
            $record = Invoke-SquadProviderOperation -Provider $Context.Self -Operation "status" -Arguments @{ Handle = $handle }
            if ($record.Status -ne "Provisioning") { return $record }
            if ((Get-Date) -ge $deadline) {
                throw "Timed out after ${timeout}s waiting for the ACA Job execution to become ready."
            }
            Start-Sleep -Seconds $poll
        }
    }

    # -- logs ----------------------------------------------------------------
    # Delegates to Get-AcaExecutionLog (scripts/lib/aca-logs.ps1), which tries
    # the containerapp extension first, falls back to Log Analytics, inspects
    # every az exit code, and throws when both paths fail (issue #13).
    #
    # The contract's shape is provider-neutral: Lines, plus an optional Notice
    # the caller prints verbatim. Which substrate produced the lines is the
    # provider's business, not the caller's.
    $operations["logs"] = {
        param($Context, $Arguments)

        $decoded = ConvertFrom-SquadExecutionHandle -Handle $Arguments["Handle"] -ExpectedProviderId "aca-job"
        $payload = $decoded.Payload
        $tail = 100
        if ($Arguments.Contains("Tail") -and $Arguments["Tail"]) { $tail = [int]$Arguments["Tail"] }

        $workspace = ""
        if ($Context.Config -and ($Context.Config.PSObject.Properties.Name -contains "logAnalyticsWorkspace")) {
            $workspace = [string]$Context.Config.logAnalyticsWorkspace
        }

        $result = Get-AcaExecutionLog `
            -ResourceGroup $payload.rg `
            -JobName $payload.job `
            -ExecutionName $payload.execution `
            -ContainerName $payload.container `
            -Tail $tail `
            -WorkspaceName $workspace

        $notice = ""
        if ($result.Source -eq "log-analytics") {
            $notice = "[squad-aca] containerapp CLI extension unavailable; read logs from Log Analytics workspace '$($result.Workspace)'."
        }
        return [pscustomobject]@{
            Lines  = @($result.Lines)
            Notice = $notice
        }
    }

    # -- cancel --------------------------------------------------------------
    # Pure pass-through, including on failure. Do NOT add error handling here:
    # swallowing an `az` failure is the exact `stop` regression that sank PR #9.
    $operations["cancel"] = {
        param($Context, $Arguments)

        $decoded = ConvertFrom-SquadExecutionHandle -Handle $Arguments["Handle"] -ExpectedProviderId "aca-job"
        $payload = $decoded.Payload

        az containerapp job stop --name $payload.job --resource-group $payload.rg --job-execution-name $payload.execution
    }

    # -- terminate -----------------------------------------------------------
    # Idempotent teardown (PRD #6). Unlike cancel, this SUPPRESSES az output and
    # never fails when there is nothing left to stop: an already-terminated or
    # externally-deleted execution is a success. Not wired to any CLI command in
    # this sprint, so `squad-aca stop` keeps its current strict semantics.
    #
    # Idempotency is NOT "ignore every failure". A non-zero `az` exit is only
    # success when the error says the execution is gone or already terminal.
    # Auth failures, RBAC denials, throttling, network errors, a wrong
    # subscription, and a missing `az` all surface as terminating errors --
    # reporting "terminated" for those would tell a Sprint 5 cleanup path that
    # an execution it never touched is safely torn down.
    $operations["terminate"] = {
        param($Context, $Arguments)

        $decoded = ConvertFrom-SquadExecutionHandle -Handle $Arguments["Handle"] -ExpectedProviderId "aca-job"
        $payload = $decoded.Payload

        # Invoke-AzPromptSafe (scripts/lib/aca-logs.ps1) captures stdout, stderr
        # and the real exit code, and reports 127 when `az` is not on PATH at all
        # -- so a stale $LASTEXITCODE from an earlier command can never be read
        # as "the stop succeeded".
        $result = Invoke-AzPromptSafe -AzArgs @(
            "containerapp", "job", "stop",
            "--name", [string]$payload.job,
            "--resource-group", [string]$payload.rg,
            "--job-execution-name", [string]$payload.execution
        )

        if ($result.ExitCode -eq 0) {
            return [pscustomobject]@{
                Terminated      = $true
                AlreadyTerminal = $false
            }
        }

        if (Test-AcaJobExecutionGone -Result $result) {
            return [pscustomobject]@{
                Terminated      = $true
                AlreadyTerminal = $true
            }
        }

        $message = "Could not terminate execution '$($payload.execution)' in job '$($payload.job)' " +
            "(resource group '$($payload.rg)'): 'az containerapp job stop' failed with exit " +
            "$($result.ExitCode), and the failure is not 'already terminated or gone'. " +
            "$(Get-AzErrorText $result)"
        throw $message
    }

    $provider = [pscustomobject]@{
        ProviderId    = $script:AcaJobProviderId
        ExecutionMode = "aca-job"
        Context       = $context
        Operations    = $operations
    }
    # Let operations re-enter the contract (wait -> status) without capturing
    # the provider in a closure.
    $context | Add-Member -MemberType NoteProperty -Name Self -Value $provider
    return $provider
}

function Test-AcaJobExecutionGone {
    <#
    .SYNOPSIS
        Decide whether a failed `az containerapp job stop` means "there was
        nothing left to stop".

    .DESCRIPTION
        PROVIDER-INTERNAL, and the whole of terminate's idempotency rule.

        PRD #6 requires terminate to be idempotent: an execution that is already
        terminal, already terminated, or was deleted out from under us is a
        SUCCESS. It does not require -- and must not be read as -- "treat every
        `az` failure as success". An auth failure, an RBAC denial, throttling, a
        network timeout, a wrong subscription, or a missing `az` binary tells us
        nothing about the execution's state, so reporting it as terminated is a
        false teardown that a cleanup path would act on.

        Classification is FAIL-CLOSED and deny-list first:

          1. A failure whose text matches a known real-failure signature is a
             real failure even if it also mentions "not found" (an RBAC denial
             can read as "... or the scope is invalid").
          2. Only then is a known not-found / already-terminal signature -- or
             the Azure CLI's ResourceNotFoundError exit code 3 -- treated as
             gone.
          3. Anything unrecognised is a real failure.

    .OUTPUTS
        [bool] $true when the execution is provably gone or already terminal.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Result
    )

    # 127 is Invoke-AzPromptSafe's marker for "az could not be run at all"
    # (CommandNotFoundException); -1 means the exit code was never observed.
    # Neither says anything about the execution.
    if ($Result.ExitCode -eq 127 -or $Result.ExitCode -eq -1) { return $false }

    $text = (@($Result.StdErr) + @($Result.StdOut) | Where-Object { $_ }) -join " "

    $realFailurePatterns = @(
        # Authentication
        "az login", "AADSTS", "ExpiredAuthenticationToken", "InvalidAuthenticationToken",
        "authentication failed", "Unauthorized", "credentials have expired", "re-authenticate",
        # Authorization / RBAC
        "AuthorizationFailed", "does not have authorization", "Forbidden", "AuthorizationPermissionMismatch",
        # Wrong subscription / tenant
        "SubscriptionNotFound", "subscription .* not found", "not registered", "set the subscription",
        # Throttling
        "TooManyRequests", "throttl", "rate limit", "Retry-After",
        # Network / service availability
        "Max retries exceeded", "Connection aborted", "ConnectionError", "ConnectTimeout",
        "timed out", "timeout", "Temporary failure in name resolution", "getaddrinfo",
        "ServiceUnavailable", "InternalServerError", "Bad Gateway",
        # az itself could not run
        "is not recognized as", "CommandNotFound", "command not found",
        "requires the extension"
    )
    foreach ($pattern in $realFailurePatterns) {
        if ($text -match $pattern) { return $false }
    }

    # Azure CLI reserves exit code 3 for ResourceNotFoundError.
    if ($Result.ExitCode -eq 3) { return $true }

    $gonePatterns = @(
        "ResourceNotFound", "NotFound", "not found", "does not exist", "no longer exists",
        "already stopped", "already terminated", "already completed", "already in a terminal",
        "is not running", "terminal state", "has already finished"
    )
    foreach ($pattern in $gonePatterns) {
        if ($text -match $pattern) { return $true }
    }

    return $false
}

function New-AcaJobExecutionHandle {
    <#
    .SYNOPSIS
        Mints the opaque handle for one ACA Job execution.

    .DESCRIPTION
        PROVIDER-INTERNAL. The payload carries everything a later operation
        needs (job, resource group, execution name, log container) so callers
        never have to reassemble Azure coordinates -- and therefore never have
        to know the handle is an ACA Job execution name.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return New-SquadExecutionHandle -ProviderId $script:AcaJobProviderId -Payload ([ordered]@{
        job       = [string]$Config.sessionJob
        rg        = [string]$Config.resourceGroup
        execution = $Name
        container = [string]$Config.sessionJob
    })
}

function ConvertTo-AcaJobExecutionRecord {
    <#
    .SYNOPSIS
        Converts one `az containerapp job execution show` payload into the
        provider-neutral record.

    .DESCRIPTION
        The Display object MUST keep the property set and order the CLI has
        always rendered (Execution, Status, Session, Mode, Repository, Branch,
        Started, Ended) so `Format-Table -AutoSize` output is unchanged.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Execution
    )

    $env = @{}
    foreach ($e in $Execution.properties.template.containers[0].env) {
        if ($e.name) { $env[$e.name] = $e.value }
    }

    $display = [pscustomobject]@{
        Execution = $Name
        Status = $Execution.properties.status
        Session = $env["SESSION_NAME"]
        Mode = $env["SQUAD_MODE"]
        Repository = $env["GITHUB_REPOSITORY"]
        Branch = $env["GITHUB_REF"]
        Started = $Execution.properties.startTime
        Ended = $Execution.properties.endTime
    }

    return New-SquadExecutionRecord `
        -Handle (New-AcaJobExecutionHandle -Config $Config -Name $Name) `
        -Status ([string]$Execution.properties.status) `
        -Display $display
}
