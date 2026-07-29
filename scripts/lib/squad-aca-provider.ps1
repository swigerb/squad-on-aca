<#
.SYNOPSIS
    Provider-neutral execution boundary for Squad on ACA.

.DESCRIPTION
    Squad on ACA dispatches work to an execution substrate. Today that substrate
    is always an Azure Container Apps *Job* execution, and the CLI called `az`
    inline for every lifecycle operation. PRD #6 adds a second substrate later
    (ACA Sandboxes, a non-ARM data plane driven by a standalone `aca` binary),
    so the CLI must stop assuming what an execution *is*.

    This file defines that seam. It owns three things and nothing else:

      1. The provider-neutral dispatch request/response shape from PRD #6
         ("Logical dispatch contract").
      2. Opaque execution handles. A handle is an encoded token; callers get a
         string and MUST NOT parse it. Only the provider that minted a handle
         can decode it. This is what stops call sites from silently depending on
         "the handle is an ACA Job execution name".
      3. A six-operation provider contract -- create / wait / status / logs /
         cancel / terminate -- plus a factory and typed wrapper functions.

    What this file deliberately does NOT contain: any Azure, `az`, `aca`, or
    Sandboxes specifics. Providers live in scripts/lib/providers/.

.NOTES
    Extension point for PRD #6 Sprint 5: add
    scripts/lib/providers/squad-sandbox-provider.ps1 exposing
    New-SandboxExecutionProvider, dot-source it below, and add a 'sandbox' branch
    to New-SquadExecutionProvider. No call site in scripts/squad-aca.ps1 should
    need to change. Sprint 3 intentionally ships no sandbox code and no flag.
#>

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here. This file
# is dot-sourced into caller scope (scripts/squad-aca.ps1); enabling strict mode
# would change the caller's runtime behaviour.

# Schema version of the dispatch request/response contract (PRD #6).
$script:SquadDispatchSchemaVersion = "1"

# Prefix + version marker for opaque execution handles. Bumping the version
# invalidates old handles rather than silently misreading them.
$script:SquadHandlePrefix = "sqx1."

# The provider contract. Every provider MUST supply exactly these operations.
$script:SquadProviderOperations = @("create", "wait", "status", "logs", "cancel", "terminate")

# Provider-neutral execution states (subset of the PRD #6 lifecycle that a
# provider can report for a single execution).
$script:SquadExecutionStates = @(
    "Provisioning", "Running", "Succeeded", "Failed", "TimedOut", "Cancelled", "Unknown"
)

# ---------------------------------------------------------------------------
# Dispatch contract (PRD #6 "Logical dispatch contract")
# ---------------------------------------------------------------------------

function New-SquadDispatchRequest {
    <#
    .SYNOPSIS
        Builds the provider-neutral dispatch request.

    .DESCRIPTION
        Mirrors the request document in PRD #6. Every provider receives this
        same shape; nothing in it names an Azure resource, an image, a job, or a
        sandbox. `executionPreferences` additionally carries the Squad-on-ACA
        dispatch knobs that are meaningful to any substrate (worker mode, push
        behaviour, SubSquad selection) so an adapter never has to reach around
        the contract for them.

    .PARAMETER CapabilityResolution
        Optional. Sprint 2 (capability resolver) produces this; Sprint 3 does not
        consume it and passes $null. Sprint 5 wires the two together.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [ValidateSet("local-cli", "ralph", "watch", "api")]
        [string]$DispatchSource = "local-cli",
        [Parameter(Mandatory = $true)][string]$Repository,
        [string]$Ref = "",
        [int]$CloneDepth = 50,
        [string]$Prompt = "",
        [object]$IssueNumber = $null,
        [object]$PullRequestNumber = $null,
        [string]$CapabilityManifestPath = "squad-capabilities.yml",
        [string]$CapabilityManifestDigest = "",
        [object]$CapabilityResolution = $null,
        [string]$Mode = "smoke",
        [string]$SubSquad = "",
        [bool]$PushChanges = $false,
        [bool]$RunCopilotSmoke = $false,
        [bool]$AllowFallback = $true,
        [bool]$LiveStatusRequested = $true,
        [string]$OutputBranch = ""
    )

    $owner = ""
    $name = $Repository
    if ($Repository -match "^(?<owner>[^/]+)/(?<name>.+)$") {
        $owner = $Matches.owner
        $name = $Matches.name
    }

    return [pscustomobject]([ordered]@{
        schemaVersion  = $script:SquadDispatchSchemaVersion
        sessionId      = $SessionId
        dispatchSource = $DispatchSource
        repository     = [pscustomobject]([ordered]@{
            owner      = $owner
            name       = $name
            fullName   = $Repository
            ref        = $Ref
            cloneDepth = $CloneDepth
        })
        task           = [pscustomobject]([ordered]@{
            prompt            = $Prompt
            issueNumber       = $IssueNumber
            pullRequestNumber = $PullRequestNumber
        })
        capabilityManifest = [pscustomobject]([ordered]@{
            path   = $CapabilityManifestPath
            digest = $CapabilityManifestDigest
        })
        # Populated by the Sprint 2 resolver; $null means "not resolved here".
        capabilityResolution = $CapabilityResolution
        executionPreferences = [pscustomobject]([ordered]@{
            allowFallback       = $AllowFallback
            liveStatusRequested = $LiveStatusRequested
            mode                = $Mode
            subSquad            = $SubSquad
            pushChanges         = $PushChanges
            runCopilotSmoke     = $RunCopilotSmoke
        })
        git = [pscustomobject]([ordered]@{
            outputBranch = $OutputBranch
        })
    })
}

function New-SquadDispatchResponse {
    <#
    .SYNOPSIS
        Builds the provider-neutral dispatch response (PRD #6).

    .DESCRIPTION
        `sessionHandle` and `statusPollRef` are opaque. A caller polls by handle;
        it never reconstructs a provider identifier from them.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$RequestId = ([guid]::NewGuid().ToString()),
        [Parameter(Mandatory = $true)]
        [ValidateSet("aca-job", "sandbox")]
        [string]$ExecutionMode,
        [object]$SandboxClass = $null,
        [string]$SessionHandle = "",
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$StatusPollRef = "",
        [object]$LiveLogRef = $null,
        [object]$FallbackReason = $null
    )

    if (-not $StatusPollRef) { $StatusPollRef = $SessionHandle }

    return [pscustomobject]([ordered]@{
        requestId      = $RequestId
        sessionId      = $SessionId
        executionMode  = $ExecutionMode
        sandboxClass   = $SandboxClass
        sessionHandle  = $SessionHandle
        status         = $Status
        statusPollRef  = $StatusPollRef
        liveLogRef     = $LiveLogRef
        fallbackReason = $FallbackReason
    })
}

# ---------------------------------------------------------------------------
# Opaque execution handles
# ---------------------------------------------------------------------------

function New-SquadExecutionHandle {
    <#
    .SYNOPSIS
        Mints an opaque execution handle for a provider.

    .DESCRIPTION
        PROVIDER-INTERNAL. Only a provider adapter calls this. The returned
        string is deliberately not human-parseable: callers outside the provider
        must treat it as a token and pass it back verbatim. That is what keeps a
        call site from assuming a handle is an ACA Job execution name.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Payload
    )

    $envelope = [ordered]@{
        v = 1
        p = $ProviderId
        d = $Payload
    }
    $json = ([pscustomobject]$envelope) | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $b64 = [System.Convert]::ToBase64String($bytes)
    # URL/filename-safe, unpadded: handles get embedded in state file names.
    $b64 = $b64.Replace('+', '-').Replace('/', '_').TrimEnd('=')
    return "$($script:SquadHandlePrefix)$b64"
}

function ConvertFrom-SquadExecutionHandle {
    <#
    .SYNOPSIS
        Decodes an opaque execution handle.

    .DESCRIPTION
        PROVIDER-INTERNAL. Throws a clear error for a malformed handle and for a
        handle minted by a different provider, so a handle can never be
        silently reinterpreted by the wrong substrate.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Handle,
        [string]$ExpectedProviderId = ""
    )

    if (-not $Handle -or -not $Handle.StartsWith($script:SquadHandlePrefix)) {
        throw "'$Handle' is not a valid Squad execution handle."
    }

    $b64 = $Handle.Substring($script:SquadHandlePrefix.Length).Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) {
        2 { $b64 += "==" }
        3 { $b64 += "=" }
        1 { throw "'$Handle' is not a valid Squad execution handle." }
    }

    $envelope = $null
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
        $envelope = $json | ConvertFrom-Json
    } catch {
        throw "'$Handle' is not a valid Squad execution handle."
    }
    if (-not $envelope -or -not $envelope.p) {
        throw "'$Handle' is not a valid Squad execution handle."
    }
    if ($ExpectedProviderId -and $envelope.p -ne $ExpectedProviderId) {
        throw "Execution handle belongs to provider '$($envelope.p)', not '$ExpectedProviderId'."
    }

    return [pscustomobject]@{
        ProviderId = [string]$envelope.p
        Payload    = $envelope.d
    }
}

# ---------------------------------------------------------------------------
# Provider contract
# ---------------------------------------------------------------------------

function New-SquadExecutionRecord {
    <#
    .SYNOPSIS
        Builds the record every provider returns for one execution.

    .DESCRIPTION
        PROVIDER-INTERNAL. Two fields, deliberately separated:

          Handle  - the opaque token used for every subsequent operation.
          Display - a provider-shaped object intended only for rendering to a
                    human. Callers must never take an identifier out of Display
                    and feed it back to a provider.

        Keeping Display a distinct object is also what lets the ACA Job adapter
        preserve `squad-aca sessions` output exactly: the CLI renders Display
        untouched, so the table's columns and values are unchanged even though
        the CLI now carries an opaque handle alongside them.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Handle,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Status,
        [Parameter(Mandatory = $true)][object]$Display
    )

    return [pscustomobject]@{
        Handle  = $Handle
        Status  = $Status
        Display = $Display
    }
}

function Test-SquadExecutionProvider {
    <#
    .SYNOPSIS
        Structural conformance check: does this object implement the contract?

    .OUTPUTS
        Array of problem strings. Empty means conformant.
    #>
    param([object]$Provider)

    $problems = @()
    if (-not $Provider) { return @("Provider is null.") }
    foreach ($required in @("ProviderId", "ExecutionMode", "Context", "Operations")) {
        if (-not ($Provider.PSObject.Properties.Name -contains $required)) {
            $problems += "Provider is missing required member '$required'."
        }
    }
    if ($problems.Count -gt 0) { return $problems }

    foreach ($op in $script:SquadProviderOperations) {
        if (-not $Provider.Operations.Contains($op)) {
            $problems += "Provider '$($Provider.ProviderId)' does not implement operation '$op'."
        } elseif ($Provider.Operations[$op] -isnot [scriptblock]) {
            $problems += "Provider '$($Provider.ProviderId)' operation '$op' is not a scriptblock."
        }
    }
    foreach ($op in $Provider.Operations.Keys) {
        if ($script:SquadProviderOperations -notcontains $op) {
            $problems += "Provider '$($Provider.ProviderId)' declares unknown operation '$op'."
        }
    }
    return $problems
}

function Assert-SquadExecutionProvider {
    param([object]$Provider)
    $problems = Test-SquadExecutionProvider -Provider $Provider
    if ($problems.Count -gt 0) {
        throw "Execution provider does not satisfy the contract: $($problems -join ' ')"
    }
    return $Provider
}

function New-SquadExecutionProvider {
    <#
    .SYNOPSIS
        Factory for execution providers.

    .PARAMETER Kind
        'aca-job' - the production adapter over ACA Jobs (preserves today's
                    behaviour exactly).
        'fake'    - filesystem-backed, offline, deterministic. Used by the
                    provider contract tests so the seam can be exercised with no
                    network and no Azure.

        Sprint 5 adds 'sandbox' here.

    .PARAMETER Options
        Provider-specific construction options (hashtable). For 'aca-job':
        Config (the resolved ACA config object) and ScriptDir. For 'fake':
        StateRoot.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("aca-job", "fake")]
        [string]$Kind,
        [System.Collections.IDictionary]$Options = @{}
    )

    switch ($Kind) {
        "aca-job" {
            $provider = New-AcaJobExecutionProvider `
                -Config $Options["Config"] `
                -ScriptDir $Options["ScriptDir"]
        }
        "fake" {
            $provider = New-FakeExecutionProvider -StateRoot $Options["StateRoot"]
        }
    }
    return (Assert-SquadExecutionProvider -Provider $provider)
}

function Invoke-SquadProviderOperation {
    <#
    .SYNOPSIS
        Dispatches one contract operation on a provider.

    .DESCRIPTION
        Single choke point: every operation goes through here, so the contract
        is enforced in one place and a provider can never be called for an
        operation it does not implement.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Provider,
        [Parameter(Mandatory = $true)][string]$Operation,
        [System.Collections.IDictionary]$Arguments = @{}
    )

    if ($script:SquadProviderOperations -notcontains $Operation) {
        throw "'$Operation' is not part of the Squad execution provider contract."
    }
    if (-not $Provider.Operations.Contains($Operation)) {
        throw "Provider '$($Provider.ProviderId)' does not implement operation '$Operation'."
    }
    return & $Provider.Operations[$Operation] $Provider.Context $Arguments
}

# ---------------------------------------------------------------------------
# Typed wrappers -- the surface call sites use
# ---------------------------------------------------------------------------

function Start-SquadExecution {
    <#
    .SYNOPSIS
        create: dispatch a new execution from a provider-neutral request.

    .DESCRIPTION
        create NEVER writes its dispatch response to the pipeline. Anything a
        provider emits from create is the substrate's own dispatch output,
        passed through untouched -- that is what keeps `squad-aca run` /
        `smoke` / `telemetry smoke` printing exactly what `az containerapp job
        start` printed before this seam existed.

        The provider-neutral response is handed back through the -Outcome
        hashtable instead (hashtables are reference types), so a caller that
        wants it can read $outcome.Response without capturing -- and swallowing
        -- the pass-through output.

    .PARAMETER Outcome
        Optional hashtable. On success the provider sets Outcome['Response'] to
        the PRD #6 dispatch response.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Provider,
        [Parameter(Mandatory = $true)][object]$Request,
        [System.Collections.IDictionary]$Outcome = $null
    )
    if ($null -eq $Outcome) { $Outcome = @{} }
    return Invoke-SquadProviderOperation -Provider $Provider -Operation "create" -Arguments @{
        Request = $Request
        Outcome = $Outcome
    }
}

function Get-SquadExecutionList {
    <#
    .SYNOPSIS
        status (list form): most recent executions, newest first.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Provider,
        [int]$Limit = 10
    )
    return @(Invoke-SquadProviderOperation -Provider $Provider -Operation "status" -Arguments @{ Limit = $Limit })
}

function Get-SquadExecutionStatus {
    <#
    .SYNOPSIS
        status (single form): the execution behind an opaque handle.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Provider,
        [Parameter(Mandatory = $true)][string]$Handle
    )
    return Invoke-SquadProviderOperation -Provider $Provider -Operation "status" -Arguments @{ Handle = $Handle }
}

function Wait-SquadExecution {
    <#
    .SYNOPSIS
        wait: block until the execution is ready (running) or terminal.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Provider,
        [Parameter(Mandatory = $true)][string]$Handle,
        [int]$TimeoutSeconds = 300,
        [int]$PollSeconds = 5
    )
    return Invoke-SquadProviderOperation -Provider $Provider -Operation "wait" -Arguments @{
        Handle         = $Handle
        TimeoutSeconds = $TimeoutSeconds
        PollSeconds    = $PollSeconds
    }
}

function Get-SquadExecutionLog {
    <#
    .SYNOPSIS
        logs: emit the execution's logs.

    .DESCRIPTION
        Returns a result object, not rendered text, so presentation stays with
        the caller and every provider looks the same:

          Lines  - the log lines, newest last.
          Notice - an optional single line the caller prints verbatim before the
                   log body (the ACA Job adapter uses it to say it fell back to
                   Log Analytics). Empty when there is nothing to say.

        How the lines were obtained -- and from which of a substrate's several
        log paths -- is the provider's business.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Provider,
        [Parameter(Mandatory = $true)][string]$Handle,
        [int]$Tail = 100
    )
    return Invoke-SquadProviderOperation -Provider $Provider -Operation "logs" -Arguments @{
        Handle = $Handle
        Tail   = $Tail
    }
}

function Stop-SquadExecution {
    <#
    .SYNOPSIS
        cancel: ask the substrate to stop a running execution.

    .DESCRIPTION
        cancel is NOT terminate. cancel reports the substrate's own result for a
        stop request (including its failure output) and is what `squad-aca stop`
        maps to, preserving today's behaviour. terminate is the idempotent
        teardown used by cleanup paths.

        Like create, cancel writes nothing of its own to the pipeline: any
        output is the substrate's, passed through. Observe the effect with a
        follow-up status call.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Provider,
        [Parameter(Mandatory = $true)][string]$Handle
    )
    return Invoke-SquadProviderOperation -Provider $Provider -Operation "cancel" -Arguments @{ Handle = $Handle }
}

function Remove-SquadExecution {
    <#
    .SYNOPSIS
        terminate: idempotent teardown.

    .DESCRIPTION
        PRD #6 requires this to be idempotent. Terminating an execution that is
        already terminal, already terminated, or has been deleted out from under
        us is a SUCCESS, not an error. Only a malformed handle -- or a handle
        minted by a different provider -- is an error, because those indicate a
        caller bug rather than a race.

    .OUTPUTS
        PSCustomObject with Terminated (always $true on success) and
        AlreadyTerminal ($true when there was nothing left to stop).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Provider,
        [Parameter(Mandatory = $true)][string]$Handle
    )
    return Invoke-SquadProviderOperation -Provider $Provider -Operation "terminate" -Arguments @{ Handle = $Handle }
}

# The ACA Job adapter's `logs` operation calls Get-AcaExecutionLog and its
# `terminate` operation calls Invoke-AzPromptSafe / Get-AzErrorText, all from
# scripts/lib/aca-logs.ps1. Load it here rather than relying on the caller
# having dot-sourced it first: scripts/squad-aca.ps1 happens to load aca-logs
# one line earlier today, and reordering those two lines would otherwise break
# `logs` and `terminate` at runtime with no test catching it.
. (Join-Path $PSScriptRoot "aca-logs.ps1")

# Adapters. Dot-sourced at load so the factory can construct them without
# scoping surprises (dot-sourcing inside a function would scope the adapter's
# functions to that function).
. (Join-Path $PSScriptRoot "providers\squad-aca-job-provider.ps1")
. (Join-Path $PSScriptRoot "providers\squad-fake-provider.ps1")
