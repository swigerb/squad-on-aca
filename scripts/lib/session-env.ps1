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
