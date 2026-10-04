<#
.SYNOPSIS
    Shared helpers for building complete, isolated per-execution environments for
    Azure Container Apps job dispatch.

.DESCRIPTION
    Squad on ACA dispatches every session as a single ACA Jobs execution. To avoid
    mutating the shared job template (which races under concurrent dispatch and
    lets omitted variables persist between sessions), dispatch uses
    `az containerapp job start --env-vars <complete-set>`. That start override
    replaces the container's ENTIRE env array for one execution only, and the
    stored template is never written.

    Important behavior discovered in live ACA E2E: `az containerapp job start
    --env-vars ...` on its own does NOT reliably apply the per-execution env
    override in this Azure CLI/runtime path -- the worker still observes the
    template's baked-in values (for example `SESSION_NAME=smoke-template`). ACA
    only applies the per-execution env when the start call also supplies a
    complete execution container spec. Dispatch therefore reads the image, CPU,
    memory, and container name from the immutable job template and echoes them
    back on `job start` alongside `--env-vars`. These values are read from the
    stored template and re-supplied verbatim; the shared job template itself is
    still never mutated. Get-JobStartContainerOptions performs that read.

    Because the override fully replaces env (it does not merge), the caller must
    supply every variable the worker needs. New-SessionStartEnvVars reads the job
    template's env once (an immutable read), removes any session-managed keys so
    no stale placeholder can leak, then overlays the fresh session values. The
    result is a complete, self-contained env set for a single execution.
#>

# Note: intentionally no Set-StrictMode here. This file is dot-sourced into
# caller scope (start-session.ps1, squad-aca.ps1); enabling strict mode would
# change the callers' runtime behavior.

# Keys that a dispatch owns. They are stripped from the template snapshot before
# the fresh session values are overlaid, so a value baked into the template (for
# example the `smoke-template` placeholders created at deploy time) or left over
# from any earlier tooling can never leak into a new execution.
$script:SessionManagedEnvKeys = @(
    "GITHUB_REPOSITORY",
    "GITHUB_REF",
    "GITHUB_REF_B64",
    "SQUAD_MODE",
    "SESSION_NAME",
    "SESSION_NAME_B64",
    "SQUAD_DEPLOYMENT_MODE",
    "SQUAD_POD_ID",
    "OTEL_SERVICE_NAME",
    "ENABLE_GITHUB_REMOTE",
    "GITHUB_TOKEN",
    "COPILOT_GITHUB_TOKEN",
    "OTEL_EXPORTER_OTLP_HEADERS",
    "SQUAD_PROMPT",
    "SQUAD_PROMPT_B64",
    "SQUAD_TEAM",
    "SQUAD_TEAM_B64",
    "RUN_COPILOT_SMOKE",
    "PUSH_CHANGES",
    "OUTPUT_BRANCH",
    "OUTPUT_BRANCH_B64",
    "PR_TITLE",
    "PR_TITLE_B64",
    "PR_BODY",
    "PR_BODY_B64",
    "COMMIT_MESSAGE",
    "COMMIT_MESSAGE_B64",
    "RALPH_LABELS",
    "RALPH_MAX_ISSUES",
    "SQUAD_DISPATCH_ROUTE",
    "SQUAD_DISPATCH_SOURCE",
    "SQUAD_LEASE_KEY"
)

$script:SessionTransportBase64KeyMap = [ordered]@{
    "GITHUB_REF"     = "GITHUB_REF_B64"
    "SESSION_NAME"   = "SESSION_NAME_B64"
    "SQUAD_PROMPT"   = "SQUAD_PROMPT_B64"
    "SQUAD_TEAM"     = "SQUAD_TEAM_B64"
    "OUTPUT_BRANCH"  = "OUTPUT_BRANCH_B64"
    "PR_TITLE"       = "PR_TITLE_B64"
    "PR_BODY"        = "PR_BODY_B64"
    "COMMIT_MESSAGE" = "COMMIT_MESSAGE_B64"
}

$script:SessionTransportMaxEncodedChars = 16384
$script:SessionTransportMaxUtf8Bytes = 12288

function Get-SessionTransportMaxEncodedChars {
    return $script:SessionTransportMaxEncodedChars
}

function Get-SessionTransportMaxUtf8Bytes {
    return $script:SessionTransportMaxUtf8Bytes
}

function Protect-SquadTextEnvForTransport {
    <#
    .SYNOPSIS
        Rewrites free-text env vars to UTF-8/base64 transport-safe companions.

    .DESCRIPTION
        Windows launches `az` through `az.cmd`, so every `--env-vars NAME=VALUE`
        token is re-parsed by cmd.exe before Azure CLI sees it. Raw prompts,
        branch names, session names, and other free-text values therefore lose
        quotes, expand `%VAR%`, and can truncate the remaining argv on embedded
        newlines. This helper keeps those values byte-for-byte by sending only a
        base64 encoding of their UTF-8 bytes (`*_B64`) across shell boundaries.

        The worker decodes these transport vars back onto their legacy names and
        still accepts the plain names for backward compatibility with older
        dispatchers.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$EnvVars
    )

    $protected = [ordered]@{}
    foreach ($key in $EnvVars.Keys) {
        $value = [string]$EnvVars[$key]
        if ($script:SessionTransportBase64KeyMap.Contains($key)) {
            $utf8 = [System.Text.Encoding]::UTF8.GetBytes($value)
            if ($utf8.Length -gt $script:SessionTransportMaxUtf8Bytes) {
                throw ("$key is $($utf8.Length) UTF-8 bytes, which exceeds the safe dispatch limit of " +
                    "$($script:SessionTransportMaxUtf8Bytes) bytes. Azure Container Apps does not document " +
                    "a larger per-env-var limit, so squad-on-aca caps free-text values at the documented " +
                    "16 KiB transport ceiling after base64 expansion (~4/3 overhead). Shorten the value " +
                    "or move large context into repository files or the GitHub issue.")
            }

            $encoded = [Convert]::ToBase64String($utf8)
            if ($encoded.Length -gt $script:SessionTransportMaxEncodedChars) {
                throw ("$key expands to $($encoded.Length) base64 characters, which exceeds the safe dispatch " +
                    "limit of $($script:SessionTransportMaxEncodedChars) characters.")
            }

            $protected[$script:SessionTransportBase64KeyMap[$key]] = $encoded
        } else {
            $protected[$key] = $value
        }
    }

    return $protected
}

function Get-JobTemplateEnvVars {
    <#
    .SYNOPSIS
        Returns the job template's container env as an ordered hashtable of
        name -> token, where token is either the literal value or
        "secretref:<name>" for secret-backed variables.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName
    )

    $json = az containerapp job show `
        --name $JobName `
        --resource-group $ResourceGroupName `
        --query "properties.template.containers[0].env" `
        -o json 2>$null

    $result = [ordered]@{}
    if (-not $json) { return $result }

    $parsed = $null
    try { $parsed = $json | ConvertFrom-Json } catch { return $result }
    if (-not $parsed) { return $result }

    foreach ($entry in @($parsed)) {
        if (-not $entry.name) { continue }
        if ($entry.PSObject.Properties.Name -contains "secretRef" -and $entry.secretRef) {
            $result[$entry.name] = "secretref:$($entry.secretRef)"
        } else {
            $result[$entry.name] = [string]$entry.value
        }
    }
    return $result
}

function ConvertTo-EnvVarTokens {
    <#
    .SYNOPSIS
        Converts an ordered dictionary of name -> value/secretref into the
        "NAME=VALUE" / "NAME=secretref:<ref>" token array expected by
        `az containerapp job start --env-vars`.

    .DESCRIPTION
        Centralizes the single formatting rule so every dispatch path (fresh
        worker session and manual Ralph run) emits identical token shapes and no
        caller has to re-implement it.

    .PARAMETER EnvVars
        Ordered hashtable/dictionary of env name -> literal value or
        "secretref:<name>" token.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$EnvVars
    )

    $safeEnvVars = Protect-SquadTextEnvForTransport -EnvVars $EnvVars
    $tokens = @()
    foreach ($key in $safeEnvVars.Keys) {
        $tokens += ("{0}={1}" -f $key, $safeEnvVars[$key])
    }
    return $tokens
}

function New-SessionStartEnvVars {
    <#
    .SYNOPSIS
        Builds the complete `--env-vars` token list for a single job execution.

    .DESCRIPTION
        Reads the job template env (immutable), strips session-managed keys, then
        overlays the supplied session values. The returned array is a list of
        "NAME=VALUE" / "NAME=secretref:<ref>" strings suitable for splatting into
        `az containerapp job start --env-vars`.

    .PARAMETER SessionEnv
        Ordered hashtable of session-scoped variables for THIS execution.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$SessionEnv
    )

    $merged = Get-JobTemplateEnvVars -JobName $JobName -ResourceGroupName $ResourceGroupName

    # Drop every session-managed key from the template snapshot so stale values
    # cannot survive into the new execution.
    foreach ($key in $script:SessionManagedEnvKeys) {
        if ($merged.Contains($key)) { $merged.Remove($key) }
    }

    # Overlay the fresh session values.
    foreach ($key in $SessionEnv.Keys) {
        $merged[$key] = [string]$SessionEnv[$key]
    }

    return ConvertTo-EnvVarTokens -EnvVars $merged
}

function New-RalphRunEnvVars {
    <#
    .SYNOPSIS
        Builds the complete `--env-vars` token list for a manual `ralph run`
        execution, preserving the Ralph job template's Ralph config and secret
        refs.

    .DESCRIPTION
        A manual Ralph run is fundamentally different from a fresh worker session:
        it must INHERIT the Ralph job template's baked-in configuration
        (SQUAD_MODE=ralph, RALPH_LABELS, RALPH_MAX_ISSUES, secret refs, Azure
        fields, Aspire endpoints) rather than stripping session-managed keys.
        Stripping them (as New-SessionStartEnvVars does) drops SQUAD_MODE and the
        Ralph config, so the worker falls back to `smoke` mode and loses its
        dispatch configuration.

        This helper reads the immutable template env verbatim, guarantees
        SQUAD_MODE=ralph, and overlays only the small set of manual-run values
        (repository override and, when a repo override is supplied, refreshed run
        identity). The stored template is never mutated.

    .PARAMETER Repository
        Optional owner/repo to target. When set, overlays GITHUB_REPOSITORY and
        refreshes run identity (SESSION_NAME, SQUAD_POD_ID, OTEL_SERVICE_NAME).

    .PARAMETER SessionName
        Optional run identity label. Defaults to a timestamped manual-ralph name.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [string]$Repository = "",
        [string]$SessionName = ""
    )

    $merged = Get-JobTemplateEnvVars -JobName $JobName -ResourceGroupName $ResourceGroupName
    if ($merged.Count -eq 0) {
        throw "Could not read the env for Ralph job '$JobName' in resource group '$ResourceGroupName'. A manual Ralph run must inherit the template's Ralph config and secret refs; refusing to dispatch."
    }

    # Guard: a manual Ralph run must always start in ralph mode regardless of any
    # stray template value.
    $merged["SQUAD_MODE"] = "ralph"

    if ($Repository) {
        if (-not $SessionName) {
            $SessionName = "manual-ralph-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        }
        # Overlay only the repository and related run-identity values. Ralph
        # config (RALPH_LABELS, RALPH_MAX_ISSUES), secret refs, Azure fields, and
        # Aspire endpoints from the template are preserved untouched.
        $merged["GITHUB_REPOSITORY"] = $Repository
        $merged["SESSION_NAME"]      = $SessionName
        $merged["SQUAD_POD_ID"]      = $SessionName
        $merged["OTEL_SERVICE_NAME"] = "squad-$SessionName"
    }

    return ConvertTo-EnvVarTokens -EnvVars $merged
}

function Get-JobStartContainerOptions {
    <#
    .SYNOPSIS
        Reads properties.template.containers[0] from the job and returns the
        execution container spec (container name, image, cpu, memory) that must
        be echoed back on `az containerapp job start` so ACA reliably applies the
        per-execution `--env-vars` override.

    .DESCRIPTION
        In live ACA E2E, `az containerapp job start --env-vars ...` by itself does
        NOT apply the per-execution env override -- the worker still sees the
        template's baked-in values. Supplying the stored template's image and
        resources on the same start call forces the override to apply. This helper
        performs the immutable read of the stored template and returns those
        values; it does not mutate the template. Fails clearly when image, cpu, or
        memory cannot be read.

    .OUTPUTS
        A PSCustomObject with ContainerName, Image, Cpu, and Memory properties.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName
    )

    $json = az containerapp job show `
        --name $JobName `
        --resource-group $ResourceGroupName `
        --query "properties.template.containers[0]" `
        -o json 2>$null

    if (-not $json) {
        throw "Could not read the container template for job '$JobName' in resource group '$ResourceGroupName'. The per-execution env override requires the stored image and resources; refusing to dispatch."
    }

    $container = $null
    try { $container = $json | ConvertFrom-Json } catch {
        throw "Failed to parse the container template for job '$JobName': $($_.Exception.Message)"
    }
    if (-not $container) {
        throw "The container template for job '$JobName' was empty. Refusing to dispatch without the stored image and resources."
    }

    $image = [string]$container.image
    $cpu = if ($container.resources) { $container.resources.cpu } else { $null }
    $memory = if ($container.resources) { [string]$container.resources.memory } else { $null }
    $containerName = [string]$container.name

    $missing = @()
    if (-not $image) { $missing += "image" }
    if ($null -eq $cpu -or "$cpu" -eq "") { $missing += "cpu" }
    if (-not $memory) { $missing += "memory" }
    if ($missing.Count -gt 0) {
        throw "Job '$JobName' container template is missing required field(s): $($missing -join ', '). ACA only applies the per-execution --env-vars override when a complete execution container spec (image + resources) is supplied, so dispatch cannot proceed."
    }

    if (-not $containerName) { $containerName = $JobName }

    return [PSCustomObject]@{
        ContainerName = $containerName
        Image         = $image
        Cpu           = "$cpu"
        Memory        = $memory
    }
}
