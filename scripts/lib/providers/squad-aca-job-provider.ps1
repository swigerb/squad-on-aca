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
    # Pure pass-through: `az` renders, we do not.
    $operations["logs"] = {
        param($Context, $Arguments)

        $decoded = ConvertFrom-SquadExecutionHandle -Handle $Arguments["Handle"] -ExpectedProviderId "aca-job"
        $payload = $decoded.Payload
        $tail = 100
        if ($Arguments.Contains("Tail") -and $Arguments["Tail"]) { $tail = [int]$Arguments["Tail"] }

        az containerapp job logs show `
            --name $payload.job `
            --resource-group $payload.rg `
            --execution $payload.execution `
            --container $payload.container `
            --tail $tail
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
    $operations["terminate"] = {
        param($Context, $Arguments)

        $decoded = ConvertFrom-SquadExecutionHandle -Handle $Arguments["Handle"] -ExpectedProviderId "aca-job"
        $payload = $decoded.Payload

        az containerapp job stop --name $payload.job --resource-group $payload.rg --job-execution-name $payload.execution 1>$null 2>$null
        $alreadyTerminal = ($LASTEXITCODE -ne 0)

        return [pscustomobject]@{
            Terminated      = $true
            AlreadyTerminal = $alreadyTerminal
        }
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
