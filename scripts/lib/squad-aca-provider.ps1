$ErrorActionPreference = "Stop"

function ConvertTo-Base64Url {
    param([string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Url {
    param([string]$Value)
    $normalized = $Value.Replace('-', '+').Replace('_', '/')
    switch ($normalized.Length % 4) {
        2 { $normalized += '==' }
        3 { $normalized += '=' }
    }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($normalized))
}

function New-OpaqueExecutionId {
    param(
        [string]$Provider,
        [string]$ExecutionName,
        [string]$SessionName,
        [hashtable]$Metadata = @{}
    )
    $payload = [ordered]@{
        provider = $Provider
        executionName = $ExecutionName
        sessionName = $SessionName
        metadata = $Metadata
    }
    return ConvertTo-Base64Url (($payload | ConvertTo-Json -Compress -Depth 10))
}

function Read-OpaqueExecutionId {
    param([string]$Id)
    if (-not $Id) { throw "Execution handle is required." }
    try {
        return (ConvertFrom-Base64Url $Id) | ConvertFrom-Json -AsHashtable
    } catch {
        throw "Execution handle is invalid."
    }
}

function Get-SquadProviderMode {
    if ($env:SQUAD_ACA_PROVIDER) {
        return $env:SQUAD_ACA_PROVIDER.ToLowerInvariant()
    }
    return "aca-job"
}

function Get-FakeProviderStatePath {
    if ($env:SQUAD_ACA_FAKE_STATE_PATH) {
        return $env:SQUAD_ACA_FAKE_STATE_PATH
    }
    return (Join-Path (Join-Path $HOME ".squad-on-aca") "fake-provider-state.json")
}

function Read-FakeProviderState {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return [ordered]@{
            nextId = 1
            executions = @()
            ralphRuns = @()
        }
    }
    return (Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable)
}

function Write-FakeProviderState {
    param(
        [string]$Path,
        [hashtable]$State
    )
    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $State | ConvertTo-Json -Depth 10 | Set-Content $Path -Encoding utf8
}

function Get-SquadExecutionEnvVars {
    param([object]$Request)

    $envVars = @(
        "GITHUB_REPOSITORY=$($Request.Repository)",
        "GITHUB_REF=$($Request.Ref)",
        "SQUAD_MODE=$($Request.Mode)",
        "SESSION_NAME=$($Request.SessionName)",
        "SQUAD_DEPLOYMENT_MODE=squad-per-pod",
        "SQUAD_POD_ID=$($Request.SessionName)",
        "OTEL_SERVICE_NAME=squad-$($Request.SessionName)",
        "GITHUB_TOKEN=secretref:github-token",
        "COPILOT_GITHUB_TOKEN=secretref:copilot-github-token",
        "OTEL_EXPORTER_OTLP_HEADERS=secretref:otlp-headers",
        "ENABLE_GITHUB_REMOTE=true"
    )

    if ($Request.Prompt) { $envVars += "SQUAD_PROMPT=$($Request.Prompt)" }
    if ($Request.SubSquad) { $envVars += "SQUAD_TEAM=$($Request.SubSquad)" }
    if ($Request.RunCopilotSmoke) { $envVars += "RUN_COPILOT_SMOKE=true" }
    if ($Request.PushChanges) { $envVars += "PUSH_CHANGES=true" }
    if ($Request.OutputBranch) { $envVars += "OUTPUT_BRANCH=$($Request.OutputBranch)" }

    return $envVars
}

function New-SquadExecutionRequest {
    param(
        [string]$Repository,
        [string]$Ref,
        [string]$Mode,
        [string]$SessionName,
        [string]$Prompt,
        [string]$SubSquad,
        [bool]$RunCopilotSmoke,
        [bool]$PushChanges,
        [string]$OutputBranch,
        [bool]$NoWait
    )

    return [pscustomobject]@{
        Repository = $Repository
        Ref = $Ref
        Mode = $Mode
        SessionName = $SessionName
        Prompt = $Prompt
        SubSquad = $SubSquad
        RunCopilotSmoke = $RunCopilotSmoke
        PushChanges = $PushChanges
        OutputBranch = $OutputBranch
        NoWait = $NoWait
    }
}

function Get-SquadExecutionProvider {
    param([object]$Config)

    $mode = Get-SquadProviderMode
    if ($mode -eq "fake") {
        return [pscustomobject]@{
            Name = "fake"
            Config = $Config
            StatePath = Get-FakeProviderStatePath
        }
    }

    return [pscustomobject]@{
        Name = "aca-job"
        Config = $Config
    }
}

function Start-SquadExecution {
    param(
        [object]$Provider,
        [object]$Request
    )

    if ($Provider.Name -eq "fake") {
        $state = Read-FakeProviderState $Provider.StatePath
        $counter = [int]$state.nextId
        $executionName = "fake-exec-{0:d4}" -f $counter
        $opaqueId = New-OpaqueExecutionId -Provider $Provider.Name -ExecutionName $executionName -SessionName $Request.SessionName -Metadata @{ statePath = $Provider.StatePath }
        $state.nextId = $counter + 1
        $state.executions = @($state.executions) + @([ordered]@{
            id = $opaqueId
            executionName = $executionName
            sessionName = $Request.SessionName
            status = if ($Request.NoWait) { "Pending" } else { "Running" }
            mode = $Request.Mode
            repository = $Request.Repository
            branch = $Request.Ref
            env = Get-SquadExecutionEnvVars $Request
            createdAt = (Get-Date).ToString("o")
            endedAt = $null
            logs = @(
                "[fake-provider] created execution $executionName",
                "[fake-provider] session $($Request.SessionName)",
                "[fake-provider] mode $($Request.Mode)"
            )
        })
        Write-FakeProviderState -Path $Provider.StatePath -State $state
        return [pscustomobject]@{
            Id = $opaqueId
            Execution = $executionName
            Session = $Request.SessionName
            Repository = $Request.Repository
            Branch = $Request.Ref
            Mode = $Request.Mode
            RawOutput = (@{
                name = $executionName
                id = $opaqueId
                status = if ($Request.NoWait) { "Pending" } else { "Running" }
            } | ConvertTo-Json -Depth 5)
        }
    }

    $args = @(
        "containerapp", "job", "start",
        "--name", $Provider.Config.sessionJob,
        "--resource-group", $Provider.Config.resourceGroup,
        "--env-vars"
    ) + (Get-SquadExecutionEnvVars $Request) + @("-o", "json")

    $raw = az @args
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start ACA job execution."
    }

    $executionName = $Request.SessionName
    try {
        $parsed = $raw | ConvertFrom-Json
        if ($parsed.name) {
            $executionName = [string]$parsed.name
        } elseif ($parsed.id) {
            $executionName = [string]($parsed.id -split '/')[-1]
        }
    } catch {
        $parsed = $null
    }

    return [pscustomobject]@{
        Id = (New-OpaqueExecutionId -Provider $Provider.Name -ExecutionName $executionName -SessionName $Request.SessionName -Metadata @{ jobName = $Provider.Config.sessionJob; resourceGroup = $Provider.Config.resourceGroup })
        Execution = $executionName
        Session = $Request.SessionName
        Repository = $Request.Repository
        Branch = $Request.Ref
        Mode = $Request.Mode
        RawOutput = $raw
    }
}

function Get-SquadExecutions {
    param(
        [object]$Provider,
        [int]$Limit = 10
    )

    if ($Provider.Name -eq "fake") {
        $state = Read-FakeProviderState $Provider.StatePath
        $items = @($state.executions)
        [array]::Reverse($items)
        return $items | Select-Object -First $Limit | ForEach-Object {
            [pscustomobject]@{
                Id = $_.id
                Execution = $_.executionName
                Status = $_.status
                Session = $_.sessionName
                Mode = $_.mode
                Repository = $_.repository
                Branch = $_.branch
                Started = $_.createdAt
                Ended = $_.endedAt
            }
        }
    }

    $names = az containerapp job execution list --name $Provider.Config.sessionJob --resource-group $Provider.Config.resourceGroup --query "[0:$Limit].name" -o json | ConvertFrom-Json
    $items = @()
    foreach ($name in $names) {
        $execution = az containerapp job execution show --name $Provider.Config.sessionJob --resource-group $Provider.Config.resourceGroup --job-execution-name $name -o json | ConvertFrom-Json
        $env = @{}
        foreach ($e in $execution.properties.template.containers[0].env) {
            if ($e.name) { $env[$e.name] = $e.value }
        }
        $items += [pscustomobject]@{
            Id = (New-OpaqueExecutionId -Provider $Provider.Name -ExecutionName $name -SessionName $env["SESSION_NAME"] -Metadata @{ jobName = $Provider.Config.sessionJob; resourceGroup = $Provider.Config.resourceGroup })
            Execution = $name
            Status = $execution.properties.status
            Session = $env["SESSION_NAME"]
            Mode = $env["SQUAD_MODE"]
            Repository = $env["GITHUB_REPOSITORY"]
            Branch = $env["GITHUB_REF"]
            Started = $execution.properties.startTime
            Ended = $execution.properties.endTime
        }
    }
    return $items
}

function Get-SquadExecutionStatus {
    param(
        [object]$Provider,
        [string]$Id
    )

    if ($Provider.Name -eq "fake") {
        $state = Read-FakeProviderState $Provider.StatePath
        $execution = @($state.executions) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
        if (-not $execution) {
            throw "Could not find execution '$Id'."
        }
        return [pscustomobject]@{
            Id = $execution.id
            Execution = $execution.executionName
            Status = $execution.status
            Session = $execution.sessionName
            Repository = $execution.repository
            Branch = $execution.branch
            Mode = $execution.mode
            Started = $execution.createdAt
            Ended = $execution.endedAt
        }
    }

    $handle = Read-OpaqueExecutionId $Id
    $execution = az containerapp job execution show --name $Provider.Config.sessionJob --resource-group $Provider.Config.resourceGroup --job-execution-name $handle.executionName -o json | ConvertFrom-Json
    $env = @{}
    foreach ($e in $execution.properties.template.containers[0].env) {
        if ($e.name) { $env[$e.name] = $e.value }
    }
    return [pscustomobject]@{
        Id = $Id
        Execution = $handle.executionName
        Status = $execution.properties.status
        Session = $env["SESSION_NAME"]
        Repository = $env["GITHUB_REPOSITORY"]
        Branch = $env["GITHUB_REF"]
        Mode = $env["SQUAD_MODE"]
        Started = $execution.properties.startTime
        Ended = $execution.properties.endTime
    }
}

function Wait-SquadExecution {
    param(
        [object]$Provider,
        [string]$Id,
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds = 5
    )

    if ($Provider.Name -eq "fake") {
        $state = Read-FakeProviderState $Provider.StatePath
        $updated = $false
        foreach ($execution in @($state.executions)) {
            if ($execution.id -eq $Id -and $execution.status -eq "Pending") {
                $execution.status = "Running"
                $execution.logs = @($execution.logs) + "[fake-provider] transitioned to Running"
                $updated = $true
            }
        }
        if ($updated) {
            Write-FakeProviderState -Path $Provider.StatePath -State $state
        }
        return Get-SquadExecutionStatus -Provider $Provider -Id $Id
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $status = Get-SquadExecutionStatus -Provider $Provider -Id $Id
        if ($status.Status -in @("Running", "Succeeded", "Failed", "Stopped")) {
            return $status
        }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    throw "Execution did not become ready before the timeout."
}

function Get-SquadExecutionLogs {
    param(
        [object]$Provider,
        [string]$Id,
        [int]$Tail = 100
    )

    if ($Provider.Name -eq "fake") {
        $state = Read-FakeProviderState $Provider.StatePath
        $execution = @($state.executions) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
        if (-not $execution) {
            throw "Could not find execution '$Id'."
        }
        return ((@($execution.logs) | Select-Object -Last $Tail) -join [Environment]::NewLine)
    }

    $handle = Read-OpaqueExecutionId $Id
    return az containerapp job logs show --name $Provider.Config.sessionJob --resource-group $Provider.Config.resourceGroup --execution $handle.executionName --container $Provider.Config.sessionJob --tail $Tail
}

function Stop-SquadExecution {
    param(
        [object]$Provider,
        [string]$Id,
        [switch]$CancelOnly
    )

    if ($Provider.Name -eq "fake") {
        $state = Read-FakeProviderState $Provider.StatePath
        $updated = $false
        $resultStatus = if ($CancelOnly) { "cancelled" } else { "terminated" }
        foreach ($execution in @($state.executions)) {
            if ($execution.id -eq $Id) {
                if ($execution.status -in @("Cancelled", "Terminated", "Succeeded", "Failed", "Stopped")) {
                    $resultStatus = "already-stopped"
                } else {
                    $execution.status = if ($CancelOnly) { "Cancelled" } else { "Terminated" }
                    $execution.endedAt = (Get-Date).ToString("o")
                    $execution.logs = @($execution.logs) + "[fake-provider] stop requested"
                }
                $updated = $true
            }
        }
        if (-not $updated) {
            return [pscustomobject]@{ id = $Id; status = "not-found" }
        }
        Write-FakeProviderState -Path $Provider.StatePath -State $state
        return [pscustomobject]@{ id = $Id; status = $resultStatus }
    }

    $handle = Read-OpaqueExecutionId $Id
    az containerapp job stop --name $Provider.Config.sessionJob --resource-group $Provider.Config.resourceGroup --job-execution-name $handle.executionName
}

function Resolve-SquadExecution {
    param(
        [object]$Provider,
        [string]$SessionOrExecution,
        [int]$Limit = 50
    )

    if (-not $SessionOrExecution) {
        $latest = Get-SquadExecutions -Provider $Provider -Limit 1
        if ($latest) { return $latest[0] }
        throw "No session executions found."
    }

    if ($SessionOrExecution -match '^[A-Za-z0-9\-_]+$') {
        try {
            $decoded = Read-OpaqueExecutionId $SessionOrExecution
            if ($decoded.provider -eq $Provider.Name) {
                return Get-SquadExecutionStatus -Provider $Provider -Id $SessionOrExecution
            }
        } catch {
        }
    }

    $items = Get-SquadExecutions -Provider $Provider -Limit $Limit
    $match = $items | Where-Object { $_.Execution -eq $SessionOrExecution -or $_.Session -eq $SessionOrExecution -or $_.Id -eq $SessionOrExecution } | Select-Object -First 1
    if (-not $match) {
        throw "Could not find session or execution '$SessionOrExecution'. Run 'squad-aca sessions' to list recent sessions."
    }
    return $match
}
