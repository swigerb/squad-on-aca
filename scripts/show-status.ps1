param(
    [string]$ResourceGroupName = "rg-squad-aca-dev-eastus2",
    [string]$JobName = "caj-squad-aca-session",
    [string]$RalphJobName = "caj-squad-aca-ralph",
    [string]$WatchAppName = "ca-squad-aca-watch",
    [string]$AspireAppName = "ca-squad-aca-aspire",
    [switch]$Logs,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

if ($Json) {
    # OPT-IN machine contract (squad-aca/status@1). Additive: the human path
    # below is untouched, which is what keeps the `15-status` golden
    # byte-identical.
    #
    # This asks `az` for the SAME facts with `-o json` instead of `-o table`,
    # and reports them under stable keys. Nothing here reads a credential; the
    # deployment coordinates it echoes are the ones the caller already passed in.
    # A query that fails is reported as null with the failure named, never as an
    # empty success -- "no container apps" and "could not ask" are different
    # answers and a poller must be able to tell them apart.
    function Invoke-AzJson {
        param([string[]]$AzArgs)
        try {
            $raw = & az @AzArgs 2>$null
            if ($LASTEXITCODE -ne 0) { return @{ Value = $null; Error = "az exited $LASTEXITCODE" } }
            $text = ($raw | Out-String).Trim()
            if (-not $text) { return @{ Value = @(); Error = $null } }
            return @{ Value = ($text | ConvertFrom-Json); Error = $null }
        } catch {
            return @{ Value = $null; Error = $_.Exception.Message }
        }
    }

    $apps = Invoke-AzJson @("containerapp", "list", "--resource-group", $ResourceGroupName,
        "--query", "[].{name:name,provisioningState:properties.provisioningState,runningStatus:properties.runningStatus,fqdn:properties.configuration.ingress.fqdn}",
        "-o", "json")
    $sessions = Invoke-AzJson @("containerapp", "job", "execution", "list", "--name", $JobName,
        "--resource-group", $ResourceGroupName,
        "--query", "[0:10].{name:name,status:properties.status,start:properties.startTime,end:properties.endTime}",
        "-o", "json")
    $ralph = Invoke-AzJson @("containerapp", "job", "execution", "list", "--name", $RalphJobName,
        "--resource-group", $ResourceGroupName,
        "--query", "[0:10].{name:name,status:properties.status,start:properties.startTime,end:properties.endTime}",
        "-o", "json")

    $dashboard = $null
    try {
        $fqdn = (& az containerapp show --name $AspireAppName --resource-group $ResourceGroupName --query properties.configuration.ingress.fqdn -o tsv 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $fqdn) { $dashboard = "https://$fqdn" }
    } catch {
        $dashboard = $null
    }

    $document = [pscustomobject]([ordered]@{
        schema            = "squad-aca/status@1"
        resourceGroup     = $ResourceGroupName
        sessionJob        = $JobName
        ralphJob          = $RalphJobName
        watchApp          = $WatchAppName
        aspireApp         = $AspireAppName
        dashboardUrl      = $dashboard
        containerApps     = $apps.Value
        containerAppsError = $apps.Error
        sessionExecutions = $sessions.Value
        sessionExecutionsError = $sessions.Error
        ralphExecutions   = $ralph.Value
        ralphExecutionsError = $ralph.Error
    })
    Write-Output ($document | ConvertTo-Json -Depth 10)
    return
}

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
