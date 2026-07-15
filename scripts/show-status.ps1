param(
    [string]$ResourceGroupName = "rg-squad-aca-dev-eastus2",
    [string]$JobName = "caj-squad-aca-session",
    [string]$RalphJobName = "caj-squad-aca-ralph",
    [string]$WatchAppName = "ca-squad-aca-watch",
    [string]$AspireAppName = "ca-squad-aca-aspire",
    [switch]$Logs
)

$ErrorActionPreference = "Stop"

Write-Output "Container Apps:"
az containerapp list --resource-group $ResourceGroupName --query "[].{name:name,provisioningState:properties.provisioningState,runningStatus:properties.runningStatus,fqdn:properties.configuration.ingress.fqdn}" -o table

Write-Output "`nRecent job executions:"
az containerapp job execution list --name $JobName --resource-group $ResourceGroupName --query "[0:10].{name:name,status:properties.status,start:properties.startTime,end:properties.endTime}" -o table

Write-Output "`nRecent Ralph executions:"
az containerapp job execution list --name $RalphJobName --resource-group $ResourceGroupName --query "[0:10].{name:name,status:properties.status,start:properties.startTime,end:properties.endTime}" -o table

try {
    $aspireFqdn = az containerapp show --name $AspireAppName --resource-group $ResourceGroupName --query properties.configuration.ingress.fqdn -o tsv
    Write-Output "`nAspire dashboard: https://$aspireFqdn"
} catch {
    Write-Warning "Could not read Aspire dashboard FQDN right now: $($_.Exception.Message)"
}

if ($Logs) {
    Write-Output "`nWatcher logs:"
    try {
        az containerapp logs show --name $WatchAppName --resource-group $ResourceGroupName --tail 80
    } catch {
        Write-Warning "Could not read watcher logs right now: $($_.Exception.Message)"
    }
}
