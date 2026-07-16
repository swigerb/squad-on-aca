param(
    [string]$ResourceGroupName = "rg-squad-aca-dev-eastus2",
    [string]$JobName = "caj-squad-aca-session",
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [string]$Ref = "",
    [ValidateSet("smoke", "telemetry-smoke", "prompt", "new-project", "loop", "shell")]
    [string]$Mode = "smoke",
    [string]$Prompt = "",
    [string]$SubSquad = "",
    [string]$SessionName = "",
    [switch]$RunCopilotSmoke,
    [switch]$PushChanges,
    [string]$OutputBranch = "",
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib\squad-aca-provider.ps1")
if (-not $Ref) {
    $Ref = gh repo view $Repository --json defaultBranchRef --jq .defaultBranchRef.name 2>$null
    if (-not $Ref) {
        throw "Could not infer the default branch for '$Repository'. Pass -Ref '<branch>'."
    }
}
if (-not $SessionName) {
    $SessionName = "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

$providerConfig = [pscustomobject]@{
    resourceGroup = $ResourceGroupName
    sessionJob = $JobName
}
$provider = Get-SquadExecutionProvider -Config $providerConfig
$request = New-SquadExecutionRequest `
    -Repository $Repository `
    -Ref $Ref `
    -Mode $Mode `
    -SessionName $SessionName `
    -Prompt $Prompt `
    -SubSquad $SubSquad `
    -RunCopilotSmoke $RunCopilotSmoke.IsPresent `
    -PushChanges $PushChanges.IsPresent `
    -OutputBranch $OutputBranch `
    -NoWait $NoWait.IsPresent
$result = Start-SquadExecution -Provider $provider -Request $request
if ($result.RawOutput) {
    Write-Output $result.RawOutput
} else {
    $result | ConvertTo-Json -Depth 10
}
