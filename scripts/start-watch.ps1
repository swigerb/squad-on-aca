param(
    [string]$ResourceGroupName = "rg-squad-aca-dev-eastus2",
    [string]$WatchAppName = "ca-squad-aca-watch",
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [string]$Ref = "",
    [string]$SubSquad = "",
    [int]$IntervalMinutes = 5,
    [int]$TimeoutMinutes = 45,
    [int]$MaxConcurrent = 1,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"
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
$envVars = @(
    "GITHUB_REPOSITORY=$Repository",
    "GITHUB_REF=$Ref",
    "SQUAD_MODE=watch",
    "SESSION_NAME=$sessionName",
    "SQUAD_DEPLOYMENT_MODE=squad-per-pod",
    "SQUAD_POD_ID=$sessionName",
    "OTEL_SERVICE_NAME=squad-$sessionName",
    "WATCH_INTERVAL_MINUTES=$IntervalMinutes",
    "WATCH_TIMEOUT_MINUTES=$TimeoutMinutes",
    "WATCH_MAX_CONCURRENT=$MaxConcurrent",
    "GITHUB_TOKEN=secretref:github-token",
    "COPILOT_GITHUB_TOKEN=secretref:copilot-github-token",
    "OTEL_EXPORTER_OTLP_HEADERS=secretref:otlp-headers",
    "ENABLE_GITHUB_REMOTE=true"
)
if ($SubSquad) { $envVars += "SQUAD_TEAM=$SubSquad" }

az containerapp update `
    --name $WatchAppName `
    --resource-group $ResourceGroupName `
    --min-replicas 1 `
    --max-replicas 1 `
    --set-env-vars @envVars
