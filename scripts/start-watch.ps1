param(
    [string]$SubscriptionId = "",
    [string]$ResourceGroupName = "rg-squad-aca-dev-centralus",
    [string]$WatchAppName = "ca-squad-aca-watch",
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [string]$Ref = "",
    [string]$SubSquad = "",
    [int]$IntervalMinutes = 5,
    [int]$TimeoutMinutes = 45,
    [int]$MaxConcurrent = 1,
    [string]$DispatchRoute = "",
    [string]$LeaseKey = "",
    [switch]$Stop
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "lib\session-env.ps1")
if (-not $Ref) {
    $Ref = gh repo view $Repository --json defaultBranchRef --jq .defaultBranchRef.name 2>$null
    if (-not $Ref) {
        throw "Could not infer the default branch for '$Repository'. Pass -Ref '<branch>'."
    }
}

if ($Stop) {
    az containerapp update --name $WatchAppName --resource-group $ResourceGroupName --min-replicas 0 --max-replicas 1 | Out-Null
    Write-Output "Stopped watcher scale for $WatchAppName."
    return
}

$sessionName = if ($SubSquad) { "watch-$SubSquad" } else { "watch-default" }
$resolvedSubscription = if ($SubscriptionId) { $SubscriptionId } else { Get-AcaCurrentSubscriptionId }
$watchUri = "https://management.azure.com/subscriptions/$resolvedSubscription/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/$WatchAppName?api-version=$($script:AcaArmApiVersion)"
$watchApp = Invoke-AcaArmRequest -Method GET -Uri $watchUri -SubscriptionId $resolvedSubscription
if (-not $watchApp -or -not $watchApp.properties -or -not $watchApp.properties.template) {
    throw "Could not read the watcher template for app '$WatchAppName' in resource group '$ResourceGroupName'."
}

$template = $watchApp.properties.template
if (-not $template -or -not $template.containers -or @($template.containers).Count -eq 0) {
    throw "Watcher app '$WatchAppName' has no readable container template. Refusing to update it blindly."
}

$envMap = [ordered]@{}
foreach ($entry in @($template.containers[0].env)) {
    if (-not $entry.name) { continue }
    if ($entry.PSObject.Properties.Name -contains "secretRef" -and $entry.secretRef) {
        $envMap[$entry.name] = "secretref:$($entry.secretRef)"
    } else {
        $envMap[$entry.name] = [string]$entry.value
    }
}

$envMap["GITHUB_REPOSITORY"] = $Repository
$envMap["GITHUB_REF"] = $Ref
$envMap["SQUAD_MODE"] = "watch"
$envMap["SESSION_NAME"] = $sessionName
$envMap["SQUAD_DEPLOYMENT_MODE"] = "squad-per-pod"
$envMap["SQUAD_POD_ID"] = $sessionName
$envMap["OTEL_SERVICE_NAME"] = "squad-$sessionName"
$envMap["WATCH_INTERVAL_MINUTES"] = [string]$IntervalMinutes
$envMap["WATCH_TIMEOUT_MINUTES"] = [string]$TimeoutMinutes
$envMap["WATCH_MAX_CONCURRENT"] = [string]$MaxConcurrent
$envMap["GITHUB_TOKEN"] = "secretref:github-token"
$envMap["COPILOT_GITHUB_TOKEN"] = "secretref:copilot-github-token"
$envMap["OTEL_EXPORTER_OTLP_HEADERS"] = "secretref:otlp-headers"
$envMap["ENABLE_GITHUB_REMOTE"] = "true"
if ($SubSquad) {
    $envMap["SQUAD_TEAM"] = $SubSquad
} elseif ($envMap.Contains("SQUAD_TEAM")) {
    $envMap.Remove("SQUAD_TEAM")
}
$envMap["SQUAD_DISPATCH_SOURCE"] = "watch"
if ($DispatchRoute) {
    $envMap["SQUAD_DISPATCH_ROUTE"] = $DispatchRoute
} elseif ($envMap.Contains("SQUAD_DISPATCH_ROUTE")) {
    $envMap.Remove("SQUAD_DISPATCH_ROUTE")
}
if ($LeaseKey) {
    $envMap["SQUAD_LEASE_KEY"] = $LeaseKey
} elseif ($envMap.Contains("SQUAD_LEASE_KEY")) {
    $envMap.Remove("SQUAD_LEASE_KEY")
}

$template.containers[0].env = @(ConvertTo-AcaEnvEntries -EnvVars $envMap)
if (-not $template.scale) { $template | Add-Member -MemberType NoteProperty -Name scale -Value ([pscustomobject]@{}) }
$template.scale.minReplicas = 1
$template.scale.maxReplicas = 1

$body = [ordered]@{
    properties = [ordered]@{
        template = $template
    }
}
$json = $body | ConvertTo-Json -Depth 30 -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
$response = Invoke-AcaArmRequest -Method PATCH -Uri $watchUri -BodyBytes $bytes -SubscriptionId $resolvedSubscription
if (-not $response -or ((-not ($response.PSObject.Properties.Name -contains "name")) -and (-not ($response.PSObject.Properties.Name -contains "properties")))) {
    throw "ARM watcher update for '$WatchAppName' returned no resource payload. Refusing to treat a malformed response as a successful dispatch."
}
Write-Output "Started watcher scale for $WatchAppName."
