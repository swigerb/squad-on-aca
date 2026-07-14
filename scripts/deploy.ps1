param(
    [string]$SubscriptionId = "3898b8ea-c676-4b43-95fc-d38425627d74",
    [string]$Location = "eastus",
    [string]$ResourceGroupName = "rg-squad-remote-dev-eastus",
    [string]$NamePrefix = "squad-remote",
    [string]$AcrName = "",
    [string]$ImageTag = "0.1.0",
    [string]$GitHubToken = "",
    [string]$CopilotGitHubToken = "",
    [string]$DefaultRepository = "swigerb/remote-squad-azure"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$azureDir = Join-Path $repoRoot ".azure"
New-Item -ItemType Directory -Force -Path $azureDir | Out-Null

function New-HexToken([int]$Bytes = 32) {
    $buffer = [byte[]]::new($Bytes)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    -join ($buffer | ForEach-Object { $_.ToString("x2") })
}

if (-not $AcrName) {
    $AcrName = "acrsquadremote$((Get-Random -Minimum 10000 -Maximum 99999))"
}

if (-not $GitHubToken) {
    $GitHubToken = (& gh auth token).Trim()
}
if (-not $CopilotGitHubToken) {
    $CopilotGitHubToken = $GitHubToken
}

az account set --subscription $SubscriptionId
az group create --name $ResourceGroupName --location $Location --tags workload=squad-remote purpose=remote-agent-dev | Out-Null

$workspaceName = "law-$NamePrefix"
$envName = "cae-$NamePrefix"
$aspireName = "ca-$NamePrefix-aspire"
$jobName = "caj-$NamePrefix-session"
$watchName = "ca-$NamePrefix-watch"
$dashboardToken = New-HexToken
$otlpApiKey = New-HexToken
$otlpHeader = "x-otlp-api-key=$otlpApiKey"

az acr create --name $AcrName --resource-group $ResourceGroupName --location $Location --sku Basic --admin-enabled false | Out-Null
$loginServer = az acr show --name $AcrName --resource-group $ResourceGroupName --query loginServer -o tsv

az acr build --registry $AcrName --image "squad-worker:$ImageTag" (Join-Path $repoRoot "worker")
$image = "$loginServer/squad-worker:$ImageTag"

az monitor log-analytics workspace create --resource-group $ResourceGroupName --workspace-name $workspaceName --location $Location | Out-Null
$workspaceId = az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $workspaceName --query customerId -o tsv
$workspaceKey = az monitor log-analytics workspace get-shared-keys --resource-group $ResourceGroupName --workspace-name $workspaceName --query primarySharedKey -o tsv

if (-not (az containerapp env show --name $envName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
    az containerapp env create --name $envName --resource-group $ResourceGroupName --location $Location --logs-workspace-id $workspaceId --logs-workspace-key $workspaceKey | Out-Null
}
$envId = az containerapp env show --name $envName --resource-group $ResourceGroupName --query id -o tsv

$aspireYaml = Join-Path $azureDir "aspire.containerapp.yaml"
@"
location: $Location
name: $aspireName
type: Microsoft.App/containerApps
properties:
  managedEnvironmentId: $envId
  configuration:
    activeRevisionsMode: Single
    secrets:
    - name: dashboard-browser-token
      value: $dashboardToken
    - name: otlp-api-key
      value: $otlpApiKey
    ingress:
      external: true
      targetPort: 18888
      transport: http
      allowInsecure: false
      traffic:
      - latestRevision: true
        weight: 100
      additionalPortMappings:
      - external: false
        targetPort: 18889
        exposedPort: 18889
      - external: false
        targetPort: 18890
        exposedPort: 18890
  template:
    containers:
    - name: aspire
      image: mcr.microsoft.com/dotnet/aspire-dashboard:latest
      env:
      - name: DASHBOARD__FRONTEND__AUTHMODE
        value: BrowserToken
      - name: DASHBOARD__FRONTEND__BROWSERTOKEN
        secretRef: dashboard-browser-token
      - name: DASHBOARD__OTLP__AUTHMODE
        value: ApiKey
      - name: DASHBOARD__OTLP__PRIMARYAPIKEY
        secretRef: otlp-api-key
      resources:
        cpu: 0.5
        memory: 1.0Gi
    scale:
      minReplicas: 1
      maxReplicas: 1
"@ | Set-Content -Path $aspireYaml -Encoding utf8

az containerapp create --resource-group $ResourceGroupName --yaml $aspireYaml | Out-Null
$aspireFqdn = az containerapp show --name $aspireName --resource-group $ResourceGroupName --query properties.configuration.ingress.fqdn -o tsv

$commonEnv = @(
    "GITHUB_REPOSITORY=$DefaultRepository",
    "GITHUB_REF=main",
    "GITHUB_TOKEN=secretref:github-token",
    "COPILOT_GITHUB_TOKEN=secretref:copilot-github-token",
    "ASPIRE_OTLP_GRPC_ENDPOINT=http://$aspireName`:18889",
    "ASPIRE_OTLP_HTTP_ENDPOINT=http://$aspireName`:18890",
    "OTEL_EXPORTER_OTLP_HEADERS=secretref:otlp-headers",
    "SQUAD_COPILOT_FLAGS=--yolo --agent squad --no-remote --no-auto-update"
)

if (-not (az containerapp job show --name $jobName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
    az containerapp job create `
        --name $jobName `
        --resource-group $ResourceGroupName `
        --environment $envName `
        --trigger-type Manual `
        --replica-timeout 7200 `
        --replica-retry-limit 0 `
        --replica-completion-count 1 `
        --parallelism 1 `
        --image $image `
        --cpu 1.0 `
        --memory 2.0Gi `
        --mi-system-assigned `
        --registry-server $loginServer `
        --registry-identity system `
        --secrets "github-token=$GitHubToken" "copilot-github-token=$CopilotGitHubToken" "otlp-headers=$otlpHeader" `
        --env-vars @commonEnv "SQUAD_MODE=smoke" "SESSION_NAME=smoke-template" | Out-Null
} else {
    az containerapp job update --name $jobName --resource-group $ResourceGroupName --image $image --set-env-vars @commonEnv | Out-Null
    az containerapp job secret set --name $jobName --resource-group $ResourceGroupName --secrets "github-token=$GitHubToken" "copilot-github-token=$CopilotGitHubToken" "otlp-headers=$otlpHeader" | Out-Null
}

$jobIdentity = az containerapp job show --name $jobName --resource-group $ResourceGroupName --query identity.principalId -o tsv
$acrId = az acr show --name $AcrName --resource-group $ResourceGroupName --query id -o tsv
az role assignment create --assignee $jobIdentity --role AcrPull --scope $acrId 2>$null | Out-Null

if (-not (az containerapp show --name $watchName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
    az containerapp create `
        --name $watchName `
        --resource-group $ResourceGroupName `
        --environment $envName `
        --image $image `
        --cpu 1.0 `
        --memory 2.0Gi `
        --min-replicas 0 `
        --max-replicas 1 `
        --mi-system-assigned `
        --registry-server $loginServer `
        --registry-identity system `
        --secrets "github-token=$GitHubToken" "copilot-github-token=$CopilotGitHubToken" "otlp-headers=$otlpHeader" `
        --env-vars @commonEnv "SQUAD_MODE=watch" "SESSION_NAME=watch-default" | Out-Null
} else {
    az containerapp update --name $watchName --resource-group $ResourceGroupName --image $image --set-env-vars @commonEnv | Out-Null
    az containerapp secret set --name $watchName --resource-group $ResourceGroupName --secrets "github-token=$GitHubToken" "copilot-github-token=$CopilotGitHubToken" "otlp-headers=$otlpHeader" | Out-Null
}

$watchIdentity = az containerapp show --name $watchName --resource-group $ResourceGroupName --query identity.principalId -o tsv
az role assignment create --assignee $watchIdentity --role AcrPull --scope $acrId 2>$null | Out-Null

$outputs = [ordered]@{
    subscriptionId = $SubscriptionId
    resourceGroup = $ResourceGroupName
    location = $Location
    containerAppsEnvironment = $envName
    acrName = $AcrName
    workerImage = $image
    aspireApp = $aspireName
    aspireUrl = "https://$aspireFqdn"
    aspireLoginUrl = "https://$aspireFqdn/login?t=$dashboardToken"
    sessionJob = $jobName
    watchApp = $watchName
    defaultRepository = $DefaultRepository
}

$outputsPath = Join-Path $repoRoot "deploy.outputs.json"
$outputs | ConvertTo-Json -Depth 5 | Set-Content -Path $outputsPath -Encoding utf8
$outputs | ConvertTo-Json -Depth 5
