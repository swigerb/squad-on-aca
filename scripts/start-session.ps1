param(
    [string]$SubscriptionId = "",
    [string]$ResourceGroupName = "rg-squad-aca-dev-centralus",
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
    [string]$DispatchRoute = "",
    [ValidateSet("", "local-cli", "ralph", "watch", "api")]
    [string]$DispatchSource = "",
    [string]$LeaseKey = ""
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

[void](Assert-SquadPromptByteCap -Prompt $Prompt)

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
# Sprint 6 (PRD #6): the resolved route, the dispatcher that made the decision,
# and the lease that was claimed BEFORE this call. Stamping them into the
# execution is what makes route and source observable in `squad-aca sessions`
# and lets the worker heartbeat its own lease without being told twice.
if ($DispatchRoute) { $sessionEnv["SQUAD_DISPATCH_ROUTE"] = $DispatchRoute }
if ($DispatchSource) { $sessionEnv["SQUAD_DISPATCH_SOURCE"] = $DispatchSource }
if ($LeaseKey) { $sessionEnv["SQUAD_LEASE_KEY"] = $LeaseKey }

$response = Start-AcaJobExecution `
    -SubscriptionId $SubscriptionId `
    -JobName $JobName `
    -ResourceGroupName $ResourceGroupName `
    -SessionEnv $sessionEnv

if (-not $response -or -not ($response.PSObject.Properties.Name -contains "name") -or -not $response.name) {
    throw "ARM job start for '$JobName' returned no execution name. Refusing to treat a malformed response as a successful dispatch."
}
Write-Output ([string]$response.name)
