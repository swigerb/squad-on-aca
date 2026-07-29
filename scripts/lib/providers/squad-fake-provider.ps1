<#
.SYNOPSIS
    Filesystem-backed fake execution provider. Offline, deterministic, no Azure.

.DESCRIPTION
    The production adapter can only be exercised against a live subscription, so
    the provider contract itself would be untestable without a fake. This one
    keeps all state in plain JSON files under a throwaway directory:

        <StateRoot>/<executionId>.json   lifecycle state + the dispatch request
        <StateRoot>/<executionId>.log    log lines

    Properties that matter for testing:

      * No network, no `az`, no `aca`, no clock-dependent behaviour. `wait` does
        not sleep -- it advances the state machine deterministically -- so
        contract tests are fast and cannot flake.
      * State lives on disk, not in memory, so "the execution was deleted out
        from under us" is expressible: delete the file and call terminate.
      * Handles are minted with the same New-SquadExecutionHandle used by the
        real adapter, so handle opacity and cross-provider handle rejection are
        tested on the real implementation rather than a lookalike.

    This is what lets PRD #6 Sprint 5 develop and test a Sandboxes provider
    without a live subscription.
#>

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here.

$script:FakeProviderId = "fake"

# States from which no further transition is possible.
$script:FakeTerminalStates = @("Succeeded", "Failed", "TimedOut", "Cancelled")

function New-FakeExecutionProvider {
    <#
    .SYNOPSIS
        Constructs the filesystem-backed fake provider.

    .PARAMETER StateRoot
        Directory holding execution state. Created if missing.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot
    )

    if (-not (Test-Path $StateRoot)) {
        New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
    }

    $context = [pscustomobject]@{
        StateRoot = (Resolve-Path $StateRoot).Path
        Sequence  = 0
    }

    $operations = [ordered]@{}

    # -- create --------------------------------------------------------------
    $operations["create"] = {
        param($Context, $Arguments)

        $request = $Arguments["Request"]
        if (-not $request) { throw "The fake provider requires a dispatch request." }

        $Context.Sequence = $Context.Sequence + 1
        $id = "fake-exec-{0:d4}" -f $Context.Sequence
        $handle = New-SquadExecutionHandle -ProviderId "fake" -Payload ([ordered]@{ id = $id })

        $state = [ordered]@{
            id        = $id
            sessionId = [string]$request.sessionId
            status    = "Provisioning"
            history   = @("Provisioning")
            request   = $request
        }
        Write-FakeExecutionState -Context $Context -Id $id -State $state
        Add-FakeExecutionLog -Context $Context -Id $id -Line "created $id for session $($request.sessionId)"

        # Same rule as the real adapter: the response travels through Outcome,
        # never the pipeline.
        if ($Arguments["Outcome"]) {
            $Arguments["Outcome"]["Response"] = New-SquadDispatchResponse `
                -SessionId ([string]$request.sessionId) `
                -ExecutionMode "aca-job" `
                -Status "provisioning" `
                -SessionHandle $handle
        }
    }

    # -- status --------------------------------------------------------------
    $operations["status"] = {
        param($Context, $Arguments)

        if ($Arguments.Contains("Handle") -and $Arguments["Handle"]) {
            $id = Resolve-FakeExecutionId -Handle $Arguments["Handle"]
            $state = Read-FakeExecutionState -Context $Context -Id $id
            if (-not $state) {
                throw "Unknown execution handle: no fake execution '$id' exists."
            }
            return ConvertTo-FakeExecutionRecord -Handle $Arguments["Handle"] -State $state
        }

        $limit = 10
        if ($Arguments.Contains("Limit") -and $Arguments["Limit"]) { $limit = [int]$Arguments["Limit"] }

        $files = @(Get-ChildItem -Path $Context.StateRoot -Filter "*.json" -File |
            Sort-Object Name -Descending | Select-Object -First $limit)
        $items = @()
        foreach ($file in $files) {
            $state = Read-FakeExecutionState -Context $Context -Id ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
            if (-not $state) { continue }
            $handle = New-SquadExecutionHandle -ProviderId "fake" -Payload ([ordered]@{ id = [string]$state.id })
            $items += ConvertTo-FakeExecutionRecord -Handle $handle -State $state
        }
        return $items
    }

    # -- wait ----------------------------------------------------------------
    # Deterministic: one call advances Provisioning -> Running. Never sleeps.
    $operations["wait"] = {
        param($Context, $Arguments)

        $handle = $Arguments["Handle"]
        $id = Resolve-FakeExecutionId -Handle $handle
        $state = Read-FakeExecutionState -Context $Context -Id $id
        if (-not $state) {
            throw "Unknown execution handle: no fake execution '$id' exists."
        }
        if ($state.status -eq "Provisioning") {
            $state = Set-FakeExecutionStatus -Context $Context -State $state -Status "Running"
            Add-FakeExecutionLog -Context $Context -Id $id -Line "ready"
        }
        return ConvertTo-FakeExecutionRecord -Handle $handle -State $state
    }

    # -- logs ----------------------------------------------------------------
    $operations["logs"] = {
        param($Context, $Arguments)

        $id = Resolve-FakeExecutionId -Handle $Arguments["Handle"]
        if (-not (Test-Path (Join-Path $Context.StateRoot "$id.json"))) {
            throw "Unknown execution handle: no fake execution '$id' exists."
        }
        $tail = 100
        if ($Arguments.Contains("Tail") -and $Arguments["Tail"]) { $tail = [int]$Arguments["Tail"] }

        $logPath = Join-Path $Context.StateRoot "$id.log"
        if (-not (Test-Path $logPath)) { return @() }
        $lines = @(Get-Content -LiteralPath $logPath)
        if ($lines.Count -gt $tail) { $lines = $lines[($lines.Count - $tail)..($lines.Count - 1)] }
        return $lines
    }

    # -- cancel --------------------------------------------------------------
    # Cancelling an already-terminal execution is a no-op success (a second
    # cancel must not error), but cancelling something that does not exist is a
    # caller bug and errors -- only terminate tolerates a missing execution.
    $operations["cancel"] = {
        param($Context, $Arguments)

        $id = Resolve-FakeExecutionId -Handle $Arguments["Handle"]
        $state = Read-FakeExecutionState -Context $Context -Id $id
        if (-not $state) {
            throw "Unknown execution handle: no fake execution '$id' exists."
        }
        if ($script:FakeTerminalStates -contains $state.status) {
            Add-FakeExecutionLog -Context $Context -Id $id -Line "cancel ignored (already $($state.status))"
            return
        }
        Set-FakeExecutionStatus -Context $Context -State $state -Status "Cancelled" | Out-Null
        Add-FakeExecutionLog -Context $Context -Id $id -Line "cancelled"
    }

    # -- terminate -----------------------------------------------------------
    # Idempotent per PRD #6: already-terminated or externally-deleted is SUCCESS.
    $operations["terminate"] = {
        param($Context, $Arguments)

        $id = Resolve-FakeExecutionId -Handle $Arguments["Handle"]
        $state = Read-FakeExecutionState -Context $Context -Id $id

        if (-not $state) {
            # Externally deleted, or never existed on this provider. Nothing to
            # tear down -- that is the definition of already terminated.
            return [pscustomobject]@{ Terminated = $true; AlreadyTerminal = $true }
        }
        if ($script:FakeTerminalStates -contains $state.status) {
            return [pscustomobject]@{ Terminated = $true; AlreadyTerminal = $true }
        }

        Set-FakeExecutionStatus -Context $Context -State $state -Status "Cancelled" | Out-Null
        Add-FakeExecutionLog -Context $Context -Id $id -Line "terminated"
        return [pscustomobject]@{ Terminated = $true; AlreadyTerminal = $false }
    }

    $provider = [pscustomobject]@{
        ProviderId    = $script:FakeProviderId
        ExecutionMode = "aca-job"
        Context       = $context
        Operations    = $operations
    }
    $context | Add-Member -MemberType NoteProperty -Name Self -Value $provider
    return $provider
}

function Resolve-FakeExecutionId {
    <#
    .SYNOPSIS
        PROVIDER-INTERNAL. Decodes a handle and returns the fake execution id.
        Throws on a malformed handle or one minted by another provider.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Handle)
    $decoded = ConvertFrom-SquadExecutionHandle -Handle $Handle -ExpectedProviderId $script:FakeProviderId
    $id = [string]$decoded.Payload.id
    if (-not $id) { throw "'$Handle' is not a valid Squad execution handle." }
    return $id
}

function Read-FakeExecutionState {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Id
    )
    $path = Join-Path $Context.StateRoot "$Id.json"
    if (-not (Test-Path $path)) { return $null }
    $raw = Get-Content -LiteralPath $path -Raw
    if (-not $raw) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Write-FakeExecutionState {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][object]$State
    )
    $path = Join-Path $Context.StateRoot "$Id.json"
    ($State | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $path -Encoding utf8
}

function Set-FakeExecutionStatus {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Status
    )
    $State.status = $Status
    $State.history = @($State.history) + @($Status)
    Write-FakeExecutionState -Context $Context -Id ([string]$State.id) -State $State
    return $State
}

function Add-FakeExecutionLog {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Line
    )
    Add-Content -LiteralPath (Join-Path $Context.StateRoot "$Id.log") -Value $Line -Encoding utf8
}

function ConvertTo-FakeExecutionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Handle,
        [Parameter(Mandatory = $true)][object]$State
    )
    $display = [pscustomobject]@{
        Execution  = [string]$State.id
        Status     = [string]$State.status
        Session    = [string]$State.sessionId
        Mode       = [string]$State.request.executionPreferences.mode
        Repository = [string]$State.request.repository.fullName
        Branch     = [string]$State.request.git.outputBranch
        Started    = $null
        Ended      = $null
    }
    return New-SquadExecutionRecord -Handle $Handle -Status ([string]$State.status) -Display $display
}
