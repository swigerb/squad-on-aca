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
if (-not $Ref) {
    $Ref = gh repo view $Repository --json defaultBranchRef --jq .defaultBranchRef.name 2>$null
    if (-not $Ref) {
        throw "Could not infer the default branch for '$Repository'. Pass -Ref '<branch>'."
    }
}
if (-not $SessionName) {
    $SessionName = "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

$envVars = @(
    "GITHUB_REPOSITORY=$Repository",
    "GITHUB_REF=$Ref",
    "SQUAD_MODE=$Mode",
    "SESSION_NAME=$SessionName",
    "SQUAD_DEPLOYMENT_MODE=squad-per-pod",
    "SQUAD_POD_ID=$SessionName",
    "OTEL_SERVICE_NAME=squad-$SessionName",
    "GITHUB_TOKEN=secretref:github-token",
    "COPILOT_GITHUB_TOKEN=secretref:copilot-github-token",
    "OTEL_EXPORTER_OTLP_HEADERS=secretref:otlp-headers",
    "ENABLE_GITHUB_REMOTE=true"
)

if ($Prompt) { $envVars += "SQUAD_PROMPT=$Prompt" }
if ($SubSquad) { $envVars += "SQUAD_TEAM=$SubSquad" }
if ($RunCopilotSmoke) { $envVars += "RUN_COPILOT_SMOKE=true" }
if ($PushChanges) { $envVars += "PUSH_CHANGES=true" }
if ($OutputBranch) { $envVars += "OUTPUT_BRANCH=$OutputBranch" }

$updateArgs = @(
    "containerapp", "job", "update",
    "--name", $JobName,
    "--resource-group", $ResourceGroupName,
    "--set-env-vars"
) + $envVars

az @updateArgs | Out-Null

$args = @(
    "containerapp", "job", "start",
    "--name", $JobName,
    "--resource-group", $ResourceGroupName
)

if ($NoWait) { $args += "--no-wait" }

az @args
