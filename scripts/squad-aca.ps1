param(
    [string]$Command = "help",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

function Show-Help {
    @"
Squad on ACA

Usage:
  squad-aca init [--owner <github-owner>] [--name <repo-name>] [--public|--private]
  squad-aca run "prompt" [--repo <owner/repo>] [--name <session>] [--branch <branch>] [--no-push]
  squad-aca "prompt"
  squad-aca new --owner <github-owner> --name <repo-name> [--description "..."]
  squad-aca smoke [--repo <owner/repo>]
  squad-aca status
  squad-aca dashboard
  squad-aca install-agent
  squad-aca install-command

Typical flow:
  mkdir my-app; cd my-app
  squad-aca init --owner my-github-user --name my-app
  copilot --agent squad-aca

Or from the shell:
  squad-aca "Build a small API and open a PR"
"@
}

function Get-OptionValue {
    param([string[]]$Items, [string[]]$Names, [string]$Default = "")
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Names -contains $Items[$i] -and $i + 1 -lt $Items.Count) {
            return $Items[$i + 1]
        }
    }
    return $Default
}

function Has-Option {
    param([string[]]$Items, [string[]]$Names)
    foreach ($name in $Names) {
        if ($Items -contains $name) { return $true }
    }
    return $false
}

function Get-PromptText {
    param([string]$First, [string[]]$Rest)
    $all = @()
    if ($First) { $all += $First }
    $skipNext = $false
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        if ($skipNext) {
            $skipNext = $false
            continue
        }
        $item = $Rest[$i]
        if ($item -in @("--repo", "-Repository", "--name", "-SessionName", "--branch", "-OutputBranch", "--sub-squad", "-SubSquad", "--owner", "--description")) {
            $skipNext = $true
            continue
        }
        if ($item.StartsWith("-")) { continue }
        $all += $item
    }
    return ($all -join " ").Trim()
}

function Get-CurrentRepo {
    $repo = gh repo view --json nameWithOwner --jq .nameWithOwner 2>$null
    if ($LASTEXITCODE -eq 0 -and $repo) {
        return $repo.Trim()
    }
    return ""
}

function Ensure-GitRepository {
    git rev-parse --is-inside-work-tree 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        git init | Out-Null
    }
}

function Ensure-InitialCommit {
    if (-not (Test-Path README.md)) {
        $name = Split-Path -Leaf (Get-Location)
        "# $name`n" | Set-Content README.md -Encoding utf8
    }
    git add -A
    git rev-parse --verify HEAD 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        git commit -m "Initial commit" | Out-Null
    } else {
        git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            git commit -m "Update project bootstrap" | Out-Null
        }
    }
}

function Invoke-SquadInit {
    if (Test-Path ".squad\team.md") { return }
    $squad = Get-Command squad -ErrorAction SilentlyContinue
    if ($squad) {
        squad init --preset default --no-workflows
    } else {
        npx -y @bradygaster/squad-cli@latest init --preset default --no-workflows
    }
}

function Install-CopilotAgent {
    $agentDir = Join-Path (Get-Location) ".github\agents"
    New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
    Copy-Item (Join-Path $RepoRoot "templates\squad-aca.agent.md") (Join-Path $agentDir "squad-aca.agent.md") -Force
    Write-Output "Installed .github/agents/squad-aca.agent.md"
}

function Install-CommandShim {
    $bin = Join-Path $HOME ".squad-on-aca\bin"
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $shim = Join-Path $bin "squad-aca.ps1"
    @"
param([Parameter(ValueFromRemainingArguments = `$true)][string[]]`$Args)
& "$ScriptDir\squad-aca.ps1" @Args
"@ | Set-Content $shim -Encoding utf8

    $path = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (($path -split ";") -contains $bin)) {
        [Environment]::SetEnvironmentVariable("Path", "$path;$bin", "User")
        Write-Output "Added $bin to your user PATH. Open a new terminal before running 'squad-aca'."
    }
    Write-Output "Installed command shim: $shim"
}

function Invoke-Init {
    param([string[]]$Items)
    Ensure-GitRepository
    $owner = Get-OptionValue $Items @("--owner", "-Owner")
    $name = Get-OptionValue $Items @("--name", "-Name") (Split-Path -Leaf (Get-Location))
    $visibility = if (Has-Option $Items @("--public")) { "public" } else { "private" }
    $repo = Get-CurrentRepo

    if (-not $repo) {
        if (-not $owner) {
            $owner = gh api user --jq .login
            if (-not $owner) { throw "Could not infer GitHub owner. Pass --owner <github-owner>." }
        }
        Ensure-InitialCommit
        $visibilityFlag = "--$visibility"
        gh repo create "$owner/$name" $visibilityFlag --source . --remote origin --push
        $repo = "$owner/$name"
    }

    if (-not (Has-Option $Items @("--no-squad-init"))) {
        Invoke-SquadInit
    }
    if (-not (Has-Option $Items @("--no-agent"))) {
        Install-CopilotAgent
    }
    git add -A
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        git commit -m "Configure Squad on ACA" | Out-Null
        git push | Out-Null
    }
    Write-Output "Ready: $repo"
    Write-Output "Next: copilot --agent squad-aca"
}

function Invoke-Run {
    param([string[]]$Items, [string]$FirstPrompt = "")
    $repo = Get-OptionValue $Items @("--repo", "-Repository") (Get-CurrentRepo)
    if (-not $repo) { throw "No GitHub repo detected. Run 'squad-aca init' first or pass --repo <owner/repo>." }
    $session = Get-OptionValue $Items @("--name", "-SessionName") "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $branch = Get-OptionValue $Items @("--branch", "-OutputBranch") "squad/$session"
    $subSquad = Get-OptionValue $Items @("--sub-squad", "-SubSquad")
    $prompt = Get-PromptText $FirstPrompt $Items
    if (-not $prompt) { throw "Provide a prompt, e.g. squad-aca `"Build the API and open a PR`"." }

    $start = Join-Path $ScriptDir "start-session.ps1"
    & $start `
        -Repository $repo `
        -Mode prompt `
        -SessionName $session `
        -Prompt $prompt `
        -SubSquad $subSquad `
        -PushChanges:(!$Items.Contains("--no-push")) `
        -OutputBranch $branch
}

switch ($Command.ToLowerInvariant()) {
    "help" { Show-Help }
    "--help" { Show-Help }
    "-h" { Show-Help }
    "init" { Invoke-Init $Arguments }
    "run" { Invoke-Run $Arguments }
    "new" {
        $owner = Get-OptionValue $Arguments @("--owner", "-Owner")
        $name = Get-OptionValue $Arguments @("--name", "-Name")
        $description = Get-OptionValue $Arguments @("--description", "-Description") "Bootstrapped by Squad on Azure Container Apps"
        if (-not $owner -or -not $name) { throw "Usage: squad-aca new --owner <github-owner> --name <repo-name>" }
        & (Join-Path $ScriptDir "new-project.ps1") -Owner $owner -Name $name -Description $description
    }
    "smoke" {
        $repo = Get-OptionValue $Arguments @("--repo", "-Repository") (Get-CurrentRepo)
        if (-not $repo) { throw "No GitHub repo detected. Pass --repo <owner/repo>." }
        & (Join-Path $ScriptDir "start-session.ps1") -Repository $repo -Mode smoke -RunCopilotSmoke -SessionName "smoke-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }
    "status" { & (Join-Path $ScriptDir "show-status.ps1") }
    "dashboard" {
        $outputs = Join-Path $RepoRoot "deploy.outputs.json"
        if (-not (Test-Path $outputs)) { throw "deploy.outputs.json not found. Run scripts/deploy.ps1 first." }
        $url = (Get-Content $outputs -Raw | ConvertFrom-Json).aspireLoginUrl
        Write-Output $url
        Start-Process $url
    }
    "install-agent" { Install-CopilotAgent }
    "install-command" { Install-CommandShim }
    default { Invoke-Run $Arguments $Command }
}
