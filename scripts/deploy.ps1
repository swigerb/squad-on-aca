param(
    [string]$SubscriptionId = "3898b8ea-c676-4b43-95fc-d38425627d74",
    [string]$Location = "eastus2",
    [string]$ResourceGroupName = "rg-squad-aca-dev-eastus2",
    [string]$NamePrefix = "squad-aca",
    [string]$AcrName = "acrsquadacabrswig",
    [string]$ImageTag = "",
    [string]$GitHubToken = "",
    [string]$CopilotGitHubToken = "",
    [string]$DefaultRepository = "swigerb/squad-on-aca",
    [switch]$UseKeyVault,
    [string]$KeyVaultName = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$azureDir = Join-Path $repoRoot ".azure"
New-Item -ItemType Directory -Force -Path $azureDir | Out-Null

if (-not $ImageTag) {
    $ImageTag = try {
        (git -C $repoRoot rev-parse --short HEAD).Trim()
    } catch {
        Get-Date -Format "yyyyMMddHHmmss"
    }
}

function New-HexToken([int]$Bytes = 32) {
    $buffer = [byte[]]::new($Bytes)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    -join ($buffer | ForEach-Object { $_.ToString("x2") })
}

if (-not $GitHubToken) {
    $GitHubToken = (& gh auth token).Trim()
}
if (-not $CopilotGitHubToken) {
    $CopilotGitHubToken = $GitHubToken
}

az account set --subscription $SubscriptionId
az group create --name $ResourceGroupName --location $Location --tags workload=squad-on-aca purpose=remote-agent-dev | Out-Null

$workspaceName = "law-$NamePrefix"
$envName = "cae-$NamePrefix"
$aspireName = "ca-$NamePrefix-aspire"
$jobName = "caj-$NamePrefix-session"
$ralphJobName = "caj-$NamePrefix-ralph"
$watchName = "ca-$NamePrefix-watch"
$identityName = "uai-$NamePrefix-acrpull"
$dashboardToken = New-HexToken
$otlpApiKey = New-HexToken
$otlpHeader = "x-otlp-api-key=$otlpApiKey"

if (-not (az acr show --name $AcrName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
    az acr create --name $AcrName --resource-group $ResourceGroupName --location $Location --sku Basic --admin-enabled false | Out-Null
}
$loginServer = az acr show --name $AcrName --resource-group $ResourceGroupName --query loginServer -o tsv

az acr build --registry $AcrName --image "squad-worker:$ImageTag" (Join-Path $repoRoot "worker")
$image = "$loginServer/squad-worker:$ImageTag"

if (-not (az identity show --name $identityName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
    az identity create --name $identityName --resource-group $ResourceGroupName --location $Location | Out-Null
}
$identityId = az identity show --name $identityName --resource-group $ResourceGroupName --query id -o tsv
$identityPrincipalId = az identity show --name $identityName --resource-group $ResourceGroupName --query principalId -o tsv
$identityClientId = az identity show --name $identityName --resource-group $ResourceGroupName --query clientId -o tsv
$acrId = az acr show --name $AcrName --resource-group $ResourceGroupName --query id -o tsv
$resourceGroupId = az group show --name $ResourceGroupName --query id -o tsv
az role assignment create --assignee $identityPrincipalId --role AcrPull --scope $acrId 2>$null | Out-Null
az role assignment create --assignee $identityPrincipalId --role Contributor --scope $resourceGroupId 2>$null | Out-Null

$jobAndWatcherSecrets = @(
    "github-token=$GitHubToken",
    "copilot-github-token=$CopilotGitHubToken",
    "otlp-headers=$otlpHeader"
)
$secretStore = "container-app-secrets"

if ($UseKeyVault) {
    if (-not $KeyVaultName) {
        $KeyVaultName = "kv-squad-aca-$((Get-Random -Minimum 1000 -Maximum 9999))"
    }
    if (-not (az keyvault show --name $KeyVaultName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
        az keyvault create --name $KeyVaultName --resource-group $ResourceGroupName --location $Location | Out-Null
    }

    $signedInObjectId = az ad signed-in-user show --query id -o tsv
    az keyvault set-policy --name $KeyVaultName --object-id $signedInObjectId --secret-permissions get list set delete recover 2>$null | Out-Null
    az keyvault set-policy --name $KeyVaultName --object-id $identityPrincipalId --secret-permissions get list 2>$null | Out-Null

    $githubTokenSecretId = az keyvault secret set --vault-name $KeyVaultName --name github-token --value $GitHubToken --query id -o tsv
    $copilotTokenSecretId = az keyvault secret set --vault-name $KeyVaultName --name copilot-github-token --value $CopilotGitHubToken --query id -o tsv
    $otlpHeadersSecretId = az keyvault secret set --vault-name $KeyVaultName --name otlp-headers --value $otlpHeader --query id -o tsv

    $jobAndWatcherSecrets = @(
        "github-token=keyvaultref:$githubTokenSecretId,identityref:$identityId",
        "copilot-github-token=keyvaultref:$copilotTokenSecretId,identityref:$identityId",
        "otlp-headers=keyvaultref:$otlpHeadersSecretId,identityref:$identityId"
    )
    $secretStore = "key-vault"
}

az monitor log-analytics workspace create --resource-group $ResourceGroupName --workspace-name $workspaceName --location $Location | Out-Null
$workspaceId = az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $workspaceName --query customerId -o tsv
$workspaceKey = az monitor log-analytics workspace get-shared-keys --resource-group $ResourceGroupName --workspace-name $workspaceName --query primarySharedKey -o tsv

$existingEnvState = az containerapp env show --name $envName --resource-group $ResourceGroupName --query properties.provisioningState -o tsv 2>$null
if ($existingEnvState -eq "Failed") {
    az containerapp env delete --name $envName --resource-group $ResourceGroupName --yes | Out-Null
    $existingEnvState = ""
}
if (-not $existingEnvState) {
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

az containerapp create --name $aspireName --resource-group $ResourceGroupName --yaml $aspireYaml | Out-Null
$aspireFqdn = az containerapp show --name $aspireName --resource-group $ResourceGroupName --query properties.configuration.ingress.fqdn -o tsv

$commonEnv = @(
    "GITHUB_REPOSITORY=$DefaultRepository",
    "GITHUB_REF=main",
    "GITHUB_TOKEN=secretref:github-token",
    "COPILOT_GITHUB_TOKEN=secretref:copilot-github-token",
    "ASPIRE_OTLP_GRPC_ENDPOINT=http://$aspireName`:18889",
    "ASPIRE_OTLP_HTTP_ENDPOINT=http://$aspireName`:18890",
    "OTEL_EXPORTER_OTLP_HEADERS=secretref:otlp-headers",
    "SQUAD_DEPLOYMENT_MODE=squad-per-pod",
    "ENABLE_GITHUB_REMOTE=true",
    "SQUAD_COPILOT_FLAGS=--yolo --agent squad --remote --no-auto-update",
    "AZURE_SUBSCRIPTION_ID=$SubscriptionId",
    "AZURE_RESOURCE_GROUP=$ResourceGroupName",
    "AZURE_CLIENT_ID=$identityClientId",
    "ACA_SESSION_JOB_NAME=$jobName"
)

$existingJobImage = az containerapp job show --name $jobName --resource-group $ResourceGroupName --query "properties.template.containers[0].image" -o tsv 2>$null
if ($existingJobImage -and $existingJobImage -ne $image) {
    az containerapp job delete --name $jobName --resource-group $ResourceGroupName --yes | Out-Null
    $existingJobImage = ""
}

if (-not $existingJobImage) {
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
        --mi-user-assigned $identityId `
        --registry-server $loginServer `
        --registry-identity $identityId `
        --secrets @jobAndWatcherSecrets `
        --env-vars @commonEnv "SQUAD_MODE=smoke" "SESSION_NAME=smoke-template" "SQUAD_POD_ID=smoke-template" | Out-Null
} else {
    az containerapp job update --name $jobName --resource-group $ResourceGroupName --image $image --set-env-vars @commonEnv | Out-Null
    az containerapp job secret set --name $jobName --resource-group $ResourceGroupName --secrets @jobAndWatcherSecrets | Out-Null
}

$existingRalphJobImage = az containerapp job show --name $ralphJobName --resource-group $ResourceGroupName --query "properties.template.containers[0].image" -o tsv 2>$null
if ($existingRalphJobImage -and $existingRalphJobImage -ne $image) {
    az containerapp job delete --name $ralphJobName --resource-group $ResourceGroupName --yes | Out-Null
    $existingRalphJobImage = ""
}

if (-not $existingRalphJobImage) {
    az containerapp job create `
        --name $ralphJobName `
        --resource-group $ResourceGroupName `
        --environment $envName `
        --trigger-type Schedule `
        --cron-expression "*/5 * * * *" `
        --replica-timeout 240 `
        --replica-retry-limit 0 `
        --replica-completion-count 1 `
        --parallelism 1 `
        --image $image `
        --cpu 1.0 `
        --memory 2.0Gi `
        --mi-user-assigned $identityId `
        --registry-server $loginServer `
        --registry-identity $identityId `
        --secrets @jobAndWatcherSecrets `
        --env-vars @commonEnv "SQUAD_MODE=ralph" "SESSION_NAME=ralph-scheduled" "SQUAD_POD_ID=ralph-scheduled" "RALPH_LABELS=squad" "RALPH_MAX_ISSUES=3" | Out-Null
} else {
    az containerapp job update --name $ralphJobName --resource-group $ResourceGroupName --image $image --cron-expression "*/5 * * * *" --replica-timeout 240 --set-env-vars @commonEnv "SQUAD_MODE=ralph" "SESSION_NAME=ralph-scheduled" "SQUAD_POD_ID=ralph-scheduled" "RALPH_LABELS=squad" "RALPH_MAX_ISSUES=3" | Out-Null
    az containerapp job secret set --name $ralphJobName --resource-group $ResourceGroupName --secrets @jobAndWatcherSecrets | Out-Null
}

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
        --user-assigned $identityId `
        --registry-server $loginServer `
        --registry-identity $identityId `
        --secrets @jobAndWatcherSecrets `
        --env-vars @commonEnv "SQUAD_MODE=watch" "SESSION_NAME=watch-default" "SQUAD_POD_ID=watch-default" | Out-Null
} else {
    az containerapp update --name $watchName --resource-group $ResourceGroupName --image $image --set-env-vars @commonEnv | Out-Null
    az containerapp secret set --name $watchName --resource-group $ResourceGroupName --secrets @jobAndWatcherSecrets | Out-Null
}

$outputs = [ordered]@{
    subscriptionId = $SubscriptionId
    resourceGroup = $ResourceGroupName
    location = $Location
    containerAppsEnvironment = $envName
    acrName = $AcrName
    pullIdentity = $identityName
    secretStore = $secretStore
    keyVaultName = $KeyVaultName
    workerImage = $image
    aspireApp = $aspireName
    aspireUrl = "https://$aspireFqdn"
    aspireLoginUrl = "https://$aspireFqdn/login?t=$dashboardToken"
    sessionJob = $jobName
    ralphJob = $ralphJobName
    watchApp = $watchName
    defaultRepository = $DefaultRepository
}

$outputsPath = Join-Path $repoRoot "deploy.outputs.json"
$outputs | ConvertTo-Json -Depth 5 | Set-Content -Path $outputsPath -Encoding utf8
$outputs | ConvertTo-Json -Depth 5
