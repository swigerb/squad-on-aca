param(
    [string]$Command = "help",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$UserConfigDir = Join-Path $HOME ".squad-on-aca"
$UserConfigPath = Join-Path $UserConfigDir "config.json"

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
  squad-aca configure --resource-group <rg> --session-job <job> [--subscription <id>]
  squad-aca install-agent
  squad-aca install-command

Typical existing repo flow:
  cd my-existing-squad-repo
  squad-aca "Build the feature and open a PR"

Typical new repo flow:
  mkdir my-app; cd my-app
  squad-aca init --owner my-github-user --name my-app
  copilot --agent squad-aca
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
        if ($item -in @("--repo", "-Repository", "--name", "-SessionName", "--branch", "-OutputBranch", "--sub-squad", "-SubSquad", "--owner", "--description", "--subscription", "--resource-group", "--session-job", "--ralph-job", "--watch-app", "--dashboard-url")) {
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

function Get-CurrentBranch {
    $branch = git branch --show-current 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) {
        return $branch.Trim()
    }
    return "main"
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

function Read-JsonFile {
    param([string]$Path)
    if (Test-Path $Path) {
        return Get-Content $Path -Raw | ConvertFrom-Json
    }
    return $null
}

function Get-AcaConfig {
    $deployOutputs = Read-JsonFile (Join-Path $RepoRoot "deploy.outputs.json")
    $userConfig = Read-JsonFile $UserConfigPath

    $config = [ordered]@{
        subscriptionId = ""
        resourceGroup = ""
        sessionJob = "caj-squad-aca-session"
        ralphJob = "caj-squad-aca-ralph"
        watchApp = "ca-squad-aca-watch"
        aspireLoginUrl = ""
    }

    foreach ($source in @($deployOutputs, $userConfig)) {
        if (-not $source) { continue }
        foreach ($key in @($config.Keys)) {
            if ($source.PSObject.Properties.Name -contains $key -and $source.$key) {
                $config[$key] = [string]$source.$key
            }
        }
    }

    return [pscustomobject]$config
}

function Save-AcaConfig {
    param([object]$Config)
    New-Item -ItemType Directory -Force -Path $UserConfigDir | Out-Null
    $Config | ConvertTo-Json -Depth 5 | Set-Content $UserConfigPath -Encoding utf8
    Write-Output "Saved ACA config: $UserConfigPath"
}

function Assert-AcaConfigured {
    $config = Get-AcaConfig
    if (-not $config.resourceGroup -or -not $config.sessionJob) {
        throw @"
Squad on ACA is not configured.

Run one of:
  1. Deploy from the squad-on-aca repo:
     <path-to-squad-on-aca>\scripts\deploy.ps1 -SubscriptionId "<azure-subscription-id>" -DefaultRepository "<github-owner>/<repo>"

  2. Configure an existing deployment:
     squad-aca configure --resource-group <rg> --session-job <job> --subscription <azure-subscription-id>
"@
    }

    if ($config.subscriptionId) {
        az account set --subscription $config.subscriptionId
    }

    az containerapp job show --name $config.sessionJob --resource-group $config.resourceGroup --query id -o tsv 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Squad on ACA session job '$($config.sessionJob)' was not found in resource group '$($config.resourceGroup)'. Run 'squad-aca configure' or deploy the ACA stack."
    }

    return $config
}

function Sync-AcaConfigFromOutputs {
    $outputs = Read-JsonFile (Join-Path $RepoRoot "deploy.outputs.json")
    if (-not $outputs) { return }
    $config = [ordered]@{
        subscriptionId = $outputs.subscriptionId
        resourceGroup = $outputs.resourceGroup
        sessionJob = $outputs.sessionJob
        ralphJob = $outputs.ralphJob
        watchApp = $outputs.watchApp
        aspireLoginUrl = $outputs.aspireLoginUrl
    }
    Save-AcaConfig ([pscustomobject]$config)
}

function Ensure-ExistingSquad {
    if (-not (Test-Path ".squad")) {
        throw "No .squad folder found in this repo. Run 'squad-aca init' for a new Squad, or run 'squad init' first."
    }
    if (-not (Test-Path ".squad\team.md")) {
        throw "Found .squad but not .squad/team.md. Finish Squad initialization before dispatching to ACA."
    }
}

function Sync-LocalSquadState {
    param([switch]$SyncAll)

    git rev-parse --is-inside-work-tree 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw "This command must run inside a git repository." }

    $branch = Get-CurrentBranch
    if ($SyncAll) {
        git add -A
    } else {
        foreach ($path in @(".squad", ".github/agents/squad-aca.agent.md", ".mcp.json")) {
            if (Test-Path $path) {
                git add $path
            }
        }
    }

    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        git commit -m "Sync Squad state for ACA session" | Out-Null
    }

    git push -u origin $branch | Out-Null

    $dirty = git status --porcelain
    if ($dirty -and -not $SyncAll) {
        Write-Warning "You have uncommitted local changes outside Squad state. ACA sessions only see committed and pushed GitHub content. Re-run with --sync-all to include all local changes."
    }

    return $branch
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

    Sync-AcaConfigFromOutputs

    $path = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (($path -split ";") -contains $bin)) {
        [Environment]::SetEnvironmentVariable("Path", "$path;$bin", "User")
        Write-Output "Added $bin to your user PATH. Open a new terminal before running 'squad-aca'."
    }
    Write-Output "Installed command shim: $shim"
}

function Invoke-Configure {
    param([string[]]$Items)
    $existing = Get-AcaConfig
    $config = [ordered]@{
        subscriptionId = Get-OptionValue $Items @("--subscription", "-SubscriptionId") $existing.subscriptionId
        resourceGroup = Get-OptionValue $Items @("--resource-group", "-ResourceGroupName") $existing.resourceGroup
        sessionJob = Get-OptionValue $Items @("--session-job", "-SessionJob") $existing.sessionJob
        ralphJob = Get-OptionValue $Items @("--ralph-job", "-RalphJob") $existing.ralphJob
        watchApp = Get-OptionValue $Items @("--watch-app", "-WatchApp") $existing.watchApp
        aspireLoginUrl = Get-OptionValue $Items @("--dashboard-url", "-DashboardUrl") $existing.aspireLoginUrl
    }
    if (-not $config.resourceGroup -or -not $config.sessionJob) {
        throw "Usage: squad-aca configure --resource-group <rg> --session-job <job> [--subscription <id>]"
    }
    Save-AcaConfig ([pscustomobject]$config)
    Assert-AcaConfigured | Out-Null
    Write-Output "Configured Squad on ACA."
}

function Invoke-Init {
    param([string[]]$Items)
    Assert-AcaConfigured | Out-Null
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
    }
    git push -u origin (Get-CurrentBranch) | Out-Null
    Write-Output "Ready: $repo"
    Write-Output "Next: copilot --agent squad-aca"
}

function Invoke-Run {
    param([string[]]$Items, [string]$FirstPrompt = "")
    $config = Assert-AcaConfigured
    Ensure-ExistingSquad

    $repo = Get-OptionValue $Items @("--repo", "-Repository") (Get-CurrentRepo)
    if (-not $repo) { throw "No GitHub repo detected. Run 'squad-aca init' first or pass --repo <owner/repo>." }
    $session = Get-OptionValue $Items @("--name", "-SessionName") "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $branch = Get-OptionValue $Items @("--branch", "-OutputBranch") "squad/$session"
    $subSquad = Get-OptionValue $Items @("--sub-squad", "-SubSquad")
    $prompt = Get-PromptText $FirstPrompt $Items
    if (-not $prompt) { throw "Provide a prompt, e.g. squad-aca `"Build the API and open a PR`"." }

    $ref = Sync-LocalSquadState -SyncAll:(Has-Option $Items @("--sync-all"))
    $start = Join-Path $ScriptDir "start-session.ps1"
    & $start `
        -ResourceGroupName $config.resourceGroup `
        -JobName $config.sessionJob `
        -Repository $repo `
        -Ref $ref `
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
    "configure" { Invoke-Configure $Arguments }
    "config" { Invoke-Configure $Arguments }
    "init" { Invoke-Init $Arguments }
    "run" { Invoke-Run $Arguments }
    "new" {
        Assert-AcaConfigured | Out-Null
        $owner = Get-OptionValue $Arguments @("--owner", "-Owner")
        $name = Get-OptionValue $Arguments @("--name", "-Name")
        $description = Get-OptionValue $Arguments @("--description", "-Description") "Bootstrapped by Squad on Azure Container Apps"
        if (-not $owner -or -not $name) { throw "Usage: squad-aca new --owner <github-owner> --name <repo-name>" }
        $config = Get-AcaConfig
        & (Join-Path $ScriptDir "new-project.ps1") -ResourceGroupName $config.resourceGroup -JobName $config.sessionJob -Owner $owner -Name $name -Description $description
    }
    "smoke" {
        $config = Assert-AcaConfigured
        $repo = Get-OptionValue $Arguments @("--repo", "-Repository") (Get-CurrentRepo)
        if (-not $repo) { throw "No GitHub repo detected. Pass --repo <owner/repo>." }
        & (Join-Path $ScriptDir "start-session.ps1") -ResourceGroupName $config.resourceGroup -JobName $config.sessionJob -Repository $repo -Mode smoke -RunCopilotSmoke -SessionName "smoke-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }
    "status" {
        $config = Assert-AcaConfigured
        & (Join-Path $ScriptDir "show-status.ps1") -ResourceGroupName $config.resourceGroup -JobName $config.sessionJob -RalphJobName $config.ralphJob -WatchAppName $config.watchApp
    }
    "dashboard" {
        $config = Assert-AcaConfigured
        if (-not $config.aspireLoginUrl) { throw "No Aspire dashboard URL configured. Run 'squad-aca configure --dashboard-url <url>' or redeploy." }
        Write-Output $config.aspireLoginUrl
        Start-Process $config.aspireLoginUrl
    }
    "install-agent" { Install-CopilotAgent }
    "install-command" { Install-CommandShim }
    default { Invoke-Run $Arguments $Command }
}
