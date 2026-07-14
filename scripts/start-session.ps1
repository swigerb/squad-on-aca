param(
    [string]$ResourceGroupName = "rg-squad-remote-dev-eastus",
    [string]$JobName = "caj-squad-remote-session",
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [string]$Ref = "main",
    [ValidateSet("smoke", "prompt", "loop", "shell")]
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
if (-not $SessionName) {
    $SessionName = "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

$envVars = @(
    "GITHUB_REPOSITORY=$Repository",
    "GITHUB_REF=$Ref",
    "SQUAD_MODE=$Mode",
    "SESSION_NAME=$SessionName",
    "OTEL_SERVICE_NAME=squad-$SessionName",
    "GITHUB_TOKEN=secretref:github-token",
    "COPILOT_GITHUB_TOKEN=secretref:copilot-github-token",
    "OTEL_EXPORTER_OTLP_HEADERS=secretref:otlp-headers"
)

if ($Prompt) { $envVars += "SQUAD_PROMPT=$Prompt" }
if ($SubSquad) { $envVars += "SQUAD_TEAM=$SubSquad" }
if ($RunCopilotSmoke) { $envVars += "RUN_COPILOT_SMOKE=true" }
if ($PushChanges) { $envVars += "PUSH_CHANGES=true" }
if ($OutputBranch) { $envVars += "OUTPUT_BRANCH=$OutputBranch" }

$args = @(
    "containerapp", "job", "start",
    "--name", $JobName,
    "--resource-group", $ResourceGroupName,
    "--env-vars"
) + $envVars

if ($NoWait) { $args += "--no-wait" }

az @args
