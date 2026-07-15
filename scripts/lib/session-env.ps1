<#
.SYNOPSIS
    Shared helpers for building complete, isolated per-execution environments for
    Azure Container Apps job dispatch.

.DESCRIPTION
    Squad on ACA dispatches every session as a single ACA Jobs execution. To avoid
    mutating the shared job template (which races under concurrent dispatch and
    lets omitted variables persist between sessions), dispatch uses
    `az containerapp job start --env-vars <complete-set>`. That start override
    replaces the container's ENTIRE env array for one execution only; image,
    resources, registry, and secrets are inherited from the stored template, and
    the stored template is never written.

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
    "SQUAD_MODE",
    "SESSION_NAME",
    "SQUAD_DEPLOYMENT_MODE",
    "SQUAD_POD_ID",
    "OTEL_SERVICE_NAME",
    "ENABLE_GITHUB_REMOTE",
    "GITHUB_TOKEN",
    "COPILOT_GITHUB_TOKEN",
    "OTEL_EXPORTER_OTLP_HEADERS",
    "SQUAD_PROMPT",
    "SQUAD_TEAM",
    "RUN_COPILOT_SMOKE",
    "PUSH_CHANGES",
    "OUTPUT_BRANCH",
    "PR_TITLE",
    "PR_BODY",
    "COMMIT_MESSAGE",
    "RALPH_LABELS",
    "RALPH_MAX_ISSUES"
)

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

    $tokens = @()
    foreach ($key in $merged.Keys) {
        $tokens += ("{0}={1}" -f $key, $merged[$key])
    }
    return $tokens
}
