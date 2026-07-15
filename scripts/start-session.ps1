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
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "lib\session-env.ps1")

if (-not $Ref) {
    $Ref = gh repo view $Repository --json defaultBranchRef --jq .defaultBranchRef.name 2>$null
    if (-not $Ref) {
        throw "Could not infer the default branch for '$Repository'. Pass -Ref '<branch>'."
    }
}
if (-not $SessionName) {
    $SessionName = "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

# Session-scoped variables. These are supplied fresh on every dispatch so a
# stale value from a previous session can never leak in. Optional variables are
# only added when set; because we build a COMPLETE env set per execution (see
# below) any optional key not present here is simply absent from the execution.
$sessionEnv = [ordered]@{
    "GITHUB_REPOSITORY"          = $Repository
    "GITHUB_REF"                 = $Ref
    "SQUAD_MODE"                 = $Mode
    "SESSION_NAME"               = $SessionName
    "SQUAD_DEPLOYMENT_MODE"      = "squad-per-pod"
    "SQUAD_POD_ID"               = $SessionName
    "OTEL_SERVICE_NAME"          = "squad-$SessionName"
    "ENABLE_GITHUB_REMOTE"       = "true"
    "GITHUB_TOKEN"               = "secretref:github-token"
    "COPILOT_GITHUB_TOKEN"       = "secretref:copilot-github-token"
    "OTEL_EXPORTER_OTLP_HEADERS" = "secretref:otlp-headers"
}

if ($Prompt) { $sessionEnv["SQUAD_PROMPT"] = $Prompt }
if ($SubSquad) { $sessionEnv["SQUAD_TEAM"] = $SubSquad }
if ($RunCopilotSmoke) { $sessionEnv["RUN_COPILOT_SMOKE"] = "true" }
if ($PushChanges) { $sessionEnv["PUSH_CHANGES"] = "true" }
if ($OutputBranch) { $sessionEnv["OUTPUT_BRANCH"] = $OutputBranch }

# Build the full, isolated environment for THIS execution only. The shared job
# template is read (never written), stripped of any session-managed keys, and
# overlaid with the fresh session values. The result is passed to
# `az containerapp job start --env-vars`, which applies it to a single execution
# without mutating the stored template -- eliminating both cross-session leakage
# and concurrent-dispatch races on the shared template.
$envVars = New-SessionStartEnvVars -JobName $JobName -ResourceGroupName $ResourceGroupName -SessionEnv $sessionEnv

$startArgs = @(
    "containerapp", "job", "start",
    "--name", $JobName,
    "--resource-group", $ResourceGroupName,
    "--env-vars"
) + $envVars

if ($NoWait) { $startArgs += "--no-wait" }

az @startArgs
