param(
    [string]$Owner = "swigerb",
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [ValidateSet("private", "public", "internal")]
    [string]$Visibility = "private",
    [string]$Description = "Bootstrapped by Squad on Azure Container Apps",
    [string]$ResourceGroupName = "rg-squad-aca-dev-eastus2",
    [string]$JobName = "caj-squad-aca-session",
    [string]$SessionName = "",
    [string]$Prompt = "",
    [string]$OutputBranch = "",
    [switch]$UseExisting,
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"

if (-not $SessionName) {
    $SessionName = "bootstrap-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
if (-not $OutputBranch) {
    $OutputBranch = "squad/$SessionName"
}
if (-not $Prompt) {
    $Prompt = @"
Initialize this repository as a new project using Squad on Azure Container Apps.

Create or improve the README, add a sensible .gitignore if needed, initialize Squad team state, and add any starter structure that makes sense for the project description:

$Description

Commit the bootstrap work and open a pull request. Keep the change small, clean, and easy to review.
"@
}

$repository = "$Owner/$Name"
$existing = $false
gh repo view $repository --json nameWithOwner 1>$null 2>$null
if ($LASTEXITCODE -eq 0) {
    $existing = $true
}

if ($existing -and -not $UseExisting) {
    throw "Repository $repository already exists. Re-run with -UseExisting to start a new-project session against it."
}

if (-not $existing) {
    $visibilityFlag = "--$Visibility"
    gh repo create $repository $visibilityFlag --add-readme --gitignore Node --description $Description
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$startSession = Join-Path $scriptRoot "start-session.ps1"

& $startSession `
    -ResourceGroupName $ResourceGroupName `
    -JobName $JobName `
    -Repository $repository `
    -Mode new-project `
    -SessionName $SessionName `
    -Prompt $Prompt `
    -PushChanges `
    -OutputBranch $OutputBranch `
    -NoWait:$NoWait

[pscustomobject]@{
    repository = "https://github.com/$repository"
    sessionName = $SessionName
    outputBranch = $OutputBranch
    mode = "new-project"
}
