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

$script:AcaArmApiVersion = "2026-01-01"
$script:SquadPromptUtf8ByteCap = 100000
$script:AcaJobDefinitionCache = @{}
$script:LiteralOnlySessionEnvKeys = @(
    "GITHUB_REPOSITORY",
    "GITHUB_REF",
    "SQUAD_MODE",
    "SESSION_NAME",
    "SQUAD_DEPLOYMENT_MODE",
    "SQUAD_POD_ID",
    "OTEL_SERVICE_NAME",
    "ENABLE_GITHUB_REMOTE",
    "SQUAD_PROMPT",
    "SQUAD_TEAM",
    "RUN_COPILOT_SMOKE",
    "PUSH_CHANGES",
    "OUTPUT_BRANCH",
    "PR_TITLE",
    "PR_BODY",
    "COMMIT_MESSAGE",
    "RALPH_LABELS",
    "RALPH_MAX_ISSUES",
    "SQUAD_DISPATCH_ROUTE",
    "SQUAD_DISPATCH_SOURCE",
    "SQUAD_LEASE_KEY"
)

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
    "RALPH_MAX_ISSUES",
    "SQUAD_DISPATCH_ROUTE",
    "SQUAD_DISPATCH_SOURCE",
    "SQUAD_LEASE_KEY"
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
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [string]$SubscriptionId = ""
    )

    $result = [ordered]@{}
    $job = Get-AcaJobDefinition -ResourceGroupName $ResourceGroupName -JobName $JobName -SubscriptionId $SubscriptionId
    $parsed = @()
    if ($job -and $job.properties -and $job.properties.template -and $job.properties.template.containers) {
        $parsed = @($job.properties.template.containers[0].env)
    }
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

    $tokens = @()
    foreach ($key in $EnvVars.Keys) {
        $tokens += ("{0}={1}" -f $key, $EnvVars[$key])
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
        [string]$SessionName = "",
        [string]$SubscriptionId = ""
    )

    $merged = New-RalphRunEnvMap -JobName $JobName -ResourceGroupName $ResourceGroupName -Repository $Repository -SessionName $SessionName -SubscriptionId $SubscriptionId
    return ConvertTo-EnvVarTokens -EnvVars $merged
}

function New-RalphRunEnvMap {
    param(
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [string]$Repository = "",
        [string]$SessionName = "",
        [string]$SubscriptionId = ""
    )

    $merged = Get-JobTemplateEnvVars -JobName $JobName -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId
    if ($merged.Count -eq 0) {
        throw "Could not read the env for Ralph job '$JobName' in resource group '$ResourceGroupName'. A manual Ralph run must inherit the template's Ralph config and secret refs; refusing to dispatch."
    }

    $merged["SQUAD_MODE"] = "ralph"

    if ($Repository) {
        if (-not $SessionName) {
            $SessionName = "manual-ralph-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        }
        $merged["GITHUB_REPOSITORY"] = $Repository
        $merged["SESSION_NAME"]      = $SessionName
        $merged["SQUAD_POD_ID"]      = $SessionName
        $merged["OTEL_SERVICE_NAME"] = "squad-$SessionName"
    }

    return $merged
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
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [string]$SubscriptionId = ""
    )
    $job = Get-AcaJobDefinition -ResourceGroupName $ResourceGroupName -JobName $JobName -SubscriptionId $SubscriptionId
    $container = $null
    if ($job -and $job.properties -and $job.properties.template -and $job.properties.template.containers) {
        $container = @($job.properties.template.containers)[0]
    }

    if (-not $container) {
        throw "Could not read the container template for job '$JobName' in resource group '$ResourceGroupName'. The per-execution env override requires the stored image and resources; refusing to dispatch."
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

function Get-Utf8ByteCount {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return 0 }
    return [System.Text.Encoding]::UTF8.GetByteCount($Value)
}

function Assert-SquadPromptByteCap {
    param(
        [AllowNull()][string]$Prompt,
        [string]$Context = "SQUAD_PROMPT"
    )

    if ([string]::IsNullOrEmpty($Prompt)) { return 0 }

    $bytes = Get-Utf8ByteCount -Value $Prompt
    if ($bytes -gt $script:SquadPromptUtf8ByteCap) {
        throw "$Context exceeds the $($script:SquadPromptUtf8ByteCap) UTF-8 bytes cap (actual: $bytes bytes)."
    }
    return $bytes
}

function ConvertTo-AcaEnvEntries {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$EnvVars
    )

    $entries = @()
    foreach ($key in $EnvVars.Keys) {
        $value = [string]$EnvVars[$key]
        $allowSecretRef = -not ($script:LiteralOnlySessionEnvKeys -contains $key)
        if ($allowSecretRef -and $value.StartsWith("secretref:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $entries += [ordered]@{
                name      = $key
                secretRef = $value.Substring("secretref:".Length)
            }
        } else {
            $entries += [ordered]@{
                name  = $key
                value = $value
            }
        }
    }
    return $entries
}

function New-SessionStartEnvMap {
    param(
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$SessionEnv,
        [string]$SubscriptionId = ""
    )

    $merged = Get-JobTemplateEnvVars -JobName $JobName -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId
    foreach ($key in $script:SessionManagedEnvKeys) {
        if ($merged.Contains($key)) { $merged.Remove($key) }
    }
    foreach ($key in $SessionEnv.Keys) {
        $merged[$key] = [string]$SessionEnv[$key]
    }
    return $merged
}

function Get-JobManualTriggerConfig {
    param(
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [string]$SubscriptionId = ""
    )
    $job = Get-AcaJobDefinition -ResourceGroupName $ResourceGroupName -JobName $JobName -SubscriptionId $SubscriptionId
    if (-not $job -or -not $job.properties -or -not $job.properties.configuration) { return $null }
    return $job.properties.configuration.manualTriggerConfig
}

function Get-AcaCurrentSubscriptionId {
    $sub = az account show --query id -o tsv 2>$null
    if (-not $sub) {
        throw "Could not determine the active Azure subscription. Run 'az login' and 'az account set --subscription <id>' or pass a subscription id."
    }
    return [string]$sub
}

function Get-AcaJobResourceUrl {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$JobName
    )

    return "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/jobs/$JobName?api-version=$($script:AcaArmApiVersion)"
}

function Get-AcaJobDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$JobName,
        [string]$SubscriptionId = ""
    )

    $resolvedSubscription = if ($SubscriptionId) { $SubscriptionId } else { Get-AcaCurrentSubscriptionId }
    $cacheKey = "$resolvedSubscription|$ResourceGroupName|$JobName"
    if ($script:AcaJobDefinitionCache.ContainsKey($cacheKey)) {
        return $script:AcaJobDefinitionCache[$cacheKey]
    }

    $uri = Get-AcaJobResourceUrl -SubscriptionId $resolvedSubscription -ResourceGroupName $ResourceGroupName -JobName $JobName
    $job = Invoke-AcaArmRequest -Method GET -Uri $uri -SubscriptionId $resolvedSubscription
    if (-not $job) {
        throw "Could not read the ACA job definition for '$JobName' in resource group '$ResourceGroupName'. Refusing to dispatch without the stored template."
    }
    $script:AcaJobDefinitionCache[$cacheKey] = $job
    return $job
}

function Get-AcaJobStartRequest {
    param(
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$SessionEnv,
        [string]$SubscriptionId = ""
    )

    $job = Get-AcaJobDefinition -ResourceGroupName $ResourceGroupName -JobName $JobName -SubscriptionId $SubscriptionId
    $containerOptions = Get-JobStartContainerOptions -JobName $JobName -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId
    $manualTriggerConfig = Get-JobManualTriggerConfig -JobName $JobName -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId
    $envMap = New-SessionStartEnvMap -JobName $JobName -ResourceGroupName $ResourceGroupName -SessionEnv $SessionEnv -SubscriptionId $SubscriptionId

    $container = [ordered]@{}
    $templateContainer = $null
    if ($job -and $job.properties -and $job.properties.template -and $job.properties.template.containers) {
        $templateContainer = @($job.properties.template.containers)[0]
    }
    if (-not $templateContainer) {
        throw "Could not read the container template for job '$JobName' in resource group '$ResourceGroupName'. The per-execution env override requires the stored template; refusing to dispatch."
    }
    foreach ($property in $templateContainer.PSObject.Properties) {
        $container[$property.Name] = $property.Value
    }
    $container["name"] = $containerOptions.ContainerName
    $container["image"] = $containerOptions.Image
    $container["resources"] = [ordered]@{
        cpu    = [double]$containerOptions.Cpu
        memory = $containerOptions.Memory
    }
    $container["env"] = @(ConvertTo-AcaEnvEntries -EnvVars $envMap)

    $body = [ordered]@{
        containers = @($container)
    }
    if ($job -and $job.properties -and $job.properties.template -and $job.properties.template.initContainers) {
        $body["initContainers"] = @($job.properties.template.initContainers)
    }
    if ($manualTriggerConfig) {
        $body["manualTriggerConfig"] = $manualTriggerConfig
    }
    return $body
}

function Get-AcaJobStartUrl {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$JobName
    )

    return "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/jobs/$JobName/start?api-version=$($script:AcaArmApiVersion)"
}

function Get-SquadScratchFilePath {
    param(
        [string]$Prefix = ".squad-aca-dispatch",
        [string]$Extension = ".json"
    )

    $baseDir = Get-Location
    $name = "{0}-{1}-{2}{3}" -f $Prefix, $PID, ([guid]::NewGuid().ToString("N")), $Extension
    return (Join-Path $baseDir $name)
}

function Get-AcaStubArmResponse {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "PATCH")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri
    )

    if ($Method -eq "GET") {
        if ($Uri -match "/containerApps/") {
            if ($env:SQUAD_STUB_WATCH_APP_JSON) {
                return ($env:SQUAD_STUB_WATCH_APP_JSON | ConvertFrom-Json)
            }
            return [pscustomobject]@{
                properties = [pscustomobject]@{
                    template = [pscustomobject]@{
                        containers = @(
                            [pscustomobject]@{
                                name = "watcher"
                                env  = @(
                                    [pscustomobject]@{ name = "SESSION_NAME"; value = "watch-default" },
                                    [pscustomobject]@{ name = "OTEL_EXPORTER_OTLP_HEADERS"; secretRef = "otlp-headers" }
                                )
                            }
                        )
                        scale      = [pscustomobject]@{
                            minReplicas = 0
                            maxReplicas = 1
                        }
                    }
                }
            }
        }
        if ($env:SQUAD_STUB_JOB_JSON) {
            return ($env:SQUAD_STUB_JOB_JSON | ConvertFrom-Json)
        }
        return [pscustomobject]@{
            properties = [pscustomobject]@{
                configuration = [pscustomobject]@{
                    manualTriggerConfig = [pscustomobject]@{
                        parallelism            = 1
                        replicaCompletionCount = 1
                    }
                }
                template      = [pscustomobject]@{
                    containers = @(
                        [pscustomobject]@{
                            name      = "squad-worker"
                            image     = "ghcr.io/example/squad-worker:stub"
                            resources = [pscustomobject]@{ cpu = 1.0; memory = "2.0Gi" }
                            env       = @(
                                [pscustomobject]@{ name = "ASPIRE_OTLP_GRPC_ENDPOINT"; value = "http://ca-squad-aca-aspire:18889" },
                                [pscustomobject]@{ name = "OTEL_EXPORTER_OTLP_HEADERS"; secretRef = "otlp-headers" },
                                [pscustomobject]@{ name = "SESSION_NAME"; value = "stub-session" }
                            )
                        }
                    )
                }
            }
        }
    }
    if ($env:SQUAD_STUB_ARM_MALFORMED -eq "1") { return [pscustomobject]@{} }
    if ($Method -eq "PATCH") { return [pscustomobject]@{ name = "stub-watch-update" } }
    return [pscustomobject]@{ name = "stub-execution" }
}

function Invoke-AcaArmRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "PATCH")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [byte[]]$BodyBytes = @(),
        [string]$SubscriptionId = ""
    )

    if ($env:SQUAD_STUB_ARM_LOG) {
        $bodyText = [System.Text.Encoding]::UTF8.GetString($BodyBytes)
        Add-Content -LiteralPath $env:SQUAD_STUB_ARM_LOG -Value @(
            "$Method $Uri"
            $bodyText
            "---"
        ) -Encoding utf8
        if ($Method -eq "POST") {
            $startRc = 0
            if ($env:SQUAD_STUB_START_RC) { $startRc = [int]$env:SQUAD_STUB_START_RC }
            if ($startRc -ne 0) {
                throw "STUB-START-FAILED ($startRc)"
            }
        }
        return Get-AcaStubArmResponse -Method $Method -Uri $Uri
    }

    $tokenArgs = @("account", "get-access-token", "--resource", "https://management.azure.com/", "--query", "accessToken", "-o", "tsv")
    if ($SubscriptionId) {
        $tokenArgs += @("--subscription", $SubscriptionId)
    }
    $token = & az @tokenArgs 2>$null
    if (-not $token) {
        throw "Could not acquire an Azure ARM access token from the active Azure CLI login."
    }

    $authHeader = "Bearer " + $token
    $headers = @{ Authorization = $authHeader }
    try {
        $invokeArgs = @{
            Method      = $Method
            Uri         = $Uri
            Headers     = $headers
            ContentType = "application/json; charset=utf-8"
        }
        if ($BodyBytes.Length -gt 0) {
            $invokeArgs["Body"] = $BodyBytes
        }
        return Invoke-RestMethod @invokeArgs
    } catch {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            throw "ARM $Method $Uri failed with HTTP ${status}: $($_.Exception.Message)"
        }
        throw "ARM $Method $Uri failed: $($_.Exception.Message)"
    }
}

function Start-AcaJobExecution {
    param(
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$SessionEnv,
        [string]$SubscriptionId = ""
    )

    $resolvedSubscription = if ($SubscriptionId) { $SubscriptionId } else { Get-AcaCurrentSubscriptionId }
    $body = Get-AcaJobStartRequest -JobName $JobName -ResourceGroupName $ResourceGroupName -SessionEnv $SessionEnv -SubscriptionId $resolvedSubscription
    $json = $body | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $uri = Get-AcaJobStartUrl -SubscriptionId $resolvedSubscription -ResourceGroupName $ResourceGroupName -JobName $JobName
    return Invoke-AcaArmRequest -Method POST -Uri $uri -BodyBytes $bytes -SubscriptionId $resolvedSubscription
}
