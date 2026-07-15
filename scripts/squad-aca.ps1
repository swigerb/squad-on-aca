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
  squad-aca doctor
  squad-aca sessions [--limit 10]
  squad-aca logs <session-or-execution> [--tail 100]
  squad-aca stop <session-or-execution>
  squad-aca open [session-or-execution]
  squad-aca sync [--sync-all|--dry-run]
  squad-aca watch <start|stop|status> [--repo <owner/repo>]
  squad-aca ralph <status|run|pause|resume>
  squad-aca subsquad <list|activate|run> [name] ["prompt"]
  squad-aca upgrade [--deploy]
  squad-aca telemetry smoke
  squad-aca secrets rotate [--github-token <token>] [--copilot-token <token>]
  squad-aca destroy --yes
  squad-aca export [file]
  squad-aca import <file>
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
    $origin = git remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0 -and $origin) {
        $origin = $origin.Trim()
        if ($origin -match "github\.com[:/](?<repo>[^/]+/[^/]+?)(?:\.git)?$") {
            return $Matches.repo
        }
    }

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
        aspireApp = "ca-squad-aca-aspire"
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
        aspireApp = $outputs.aspireApp
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
    gh auth status 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run 'gh auth login' and try again."
    }
    gh auth setup-git 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not configure Git to use GitHub CLI credentials. Run 'gh auth setup-git' and try again."
    }

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
    if ($LASTEXITCODE -ne 0) {
        $repo = Get-CurrentRepo
        $target = if ($repo) { $repo } else { "the origin remote" }
        throw "Could not push '$branch' to $target. Verify access with 'gh repo view' and refresh authentication with 'gh auth login'."
    }

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
    $cmdShim = Join-Path $bin "squad-aca.cmd"
    @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$shim" %*
"@ | Set-Content $cmdShim -Encoding ascii

    Sync-AcaConfigFromOutputs

    $path = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (($path -split ";") -contains $bin)) {
        [Environment]::SetEnvironmentVariable("Path", "$path;$bin", "User")
        Write-Output "Added $bin to your user PATH. Open a new terminal before running 'squad-aca'."
    }
    Write-Output "Installed command shim: $shim"
    Write-Output "Installed command shim: $cmdShim"
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
        aspireApp = Get-OptionValue $Items @("--aspire-app", "-AspireApp") $existing.aspireApp
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
        -PushChanges:(-not (Has-Option $Items @("--no-push"))) `
        -OutputBranch $branch
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Doctor {
    $checks = @()
    $config = Get-AcaConfig

    $checks += [pscustomobject]@{ Check = "git"; Status = if (Test-Command "git") { "ok" } else { "missing" }; Detail = "Required for repo and Squad state sync" }
    $checks += [pscustomobject]@{ Check = "gh"; Status = if (Test-Command "gh") { "ok" } else { "missing" }; Detail = "Required for GitHub repo/PR/issue access" }
    $checks += [pscustomobject]@{ Check = "az"; Status = if (Test-Command "az") { "ok" } else { "missing" }; Detail = "Required for ACA job control" }
    $checks += [pscustomobject]@{ Check = "squad"; Status = if (Test-Command "squad") { "ok" } else { "optional" }; Detail = "Used by init; npx fallback is available" }

    $repo = Get-CurrentRepo
    $checks += [pscustomobject]@{ Check = "GitHub repo"; Status = if ($repo) { "ok" } else { "missing" }; Detail = if ($repo) { $repo } else { "Run squad-aca init or pass --repo" } }
    $checks += [pscustomobject]@{ Check = ".squad"; Status = if (Test-Path ".squad\team.md") { "ok" } else { "missing" }; Detail = "Required for existing-repo dispatch" }

    try {
        gh auth status 1>$null 2>$null
        $checks += [pscustomobject]@{ Check = "GitHub auth"; Status = "ok"; Detail = "gh auth status succeeded" }
    } catch {
        $checks += [pscustomobject]@{ Check = "GitHub auth"; Status = "failed"; Detail = $_.Exception.Message }
    }

    try {
        if ($config.subscriptionId) { az account set --subscription $config.subscriptionId 1>$null }
        $account = az account show --query "{name:name,id:id}" -o json | ConvertFrom-Json
        $checks += [pscustomobject]@{ Check = "Azure auth"; Status = "ok"; Detail = "$($account.name)" }
    } catch {
        $checks += [pscustomobject]@{ Check = "Azure auth"; Status = "failed"; Detail = $_.Exception.Message }
    }

    try {
        Assert-AcaConfigured | Out-Null
        $checks += [pscustomobject]@{ Check = "ACA session job"; Status = "ok"; Detail = "$($config.resourceGroup)/$($config.sessionJob)" }
    } catch {
        $checks += [pscustomobject]@{ Check = "ACA session job"; Status = "failed"; Detail = $_.Exception.Message }
    }

    if ($config.ralphJob) {
        try {
            az containerapp job show --name $config.ralphJob --resource-group $config.resourceGroup --query id -o tsv 1>$null
            $checks += [pscustomobject]@{ Check = "Ralph job"; Status = "ok"; Detail = $config.ralphJob }
        } catch {
            $checks += [pscustomobject]@{ Check = "Ralph job"; Status = "warning"; Detail = "Not found or not configured" }
        }
    }

    $checks += [pscustomobject]@{ Check = "Aspire URL"; Status = if ($config.aspireLoginUrl) { "ok" } else { "missing" }; Detail = if ($config.aspireLoginUrl) { $config.aspireLoginUrl } else { "Run deploy or squad-aca configure --dashboard-url" } }
    $checks | Format-Table -AutoSize
}

function Get-SessionExecutions {
    param([object]$Config, [int]$Limit = 10)
    $names = az containerapp job execution list --name $Config.sessionJob --resource-group $Config.resourceGroup --query "[0:$Limit].name" -o json | ConvertFrom-Json
    $items = @()
    foreach ($name in $names) {
        $execution = az containerapp job execution show --name $Config.sessionJob --resource-group $Config.resourceGroup --job-execution-name $name -o json | ConvertFrom-Json
        $env = @{}
        foreach ($e in $execution.properties.template.containers[0].env) {
            if ($e.name) { $env[$e.name] = $e.value }
        }
        $items += [pscustomobject]@{
            Execution = $name
            Status = $execution.properties.status
            Session = $env["SESSION_NAME"]
            Mode = $env["SQUAD_MODE"]
            Repository = $env["GITHUB_REPOSITORY"]
            Branch = $env["GITHUB_REF"]
            Started = $execution.properties.startTime
            Ended = $execution.properties.endTime
        }
    }
    return $items
}

function Get-FirstPositional {
    param([string[]]$Items, [string[]]$OptionsWithValues = @())
    $skipNext = $false
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($skipNext) {
            $skipNext = $false
            continue
        }
        $item = $Items[$i]
        if ($OptionsWithValues -contains $item) {
            $skipNext = $true
            continue
        }
        if ($item.StartsWith("-")) { continue }
        return $item
    }
    return ""
}

function Resolve-SessionExecution {
    param([object]$Config, [string]$Session)
    if (-not $Session) {
        $latest = Get-SessionExecutions -Config $Config -Limit 1
        if ($latest) { return $latest[0] }
        throw "No session executions found."
    }
    $items = Get-SessionExecutions -Config $Config -Limit 50
    $match = $items | Where-Object { $_.Execution -eq $Session -or $_.Session -eq $Session } | Select-Object -First 1
    if (-not $match) {
        throw "Could not find session or execution '$Session'. Run 'squad-aca sessions' to list recent sessions."
    }
    return $match
}

function Invoke-Sessions {
    param([string[]]$Items)
    $config = Assert-AcaConfigured
    $limitText = Get-OptionValue $Items @("--limit", "-Limit") "10"
    $limit = [int]$limitText
    Get-SessionExecutions -Config $config -Limit $limit | Format-Table -AutoSize
}

function Invoke-Logs {
    param([string[]]$Items)
    $config = Assert-AcaConfigured
    $session = Get-FirstPositional $Items @("--tail", "-Tail")
    $tail = [int](Get-OptionValue $Items @("--tail", "-Tail") "100")
    $execution = Resolve-SessionExecution -Config $config -Session $session
    az containerapp job logs show `
        --name $config.sessionJob `
        --resource-group $config.resourceGroup `
        --execution $execution.Execution `
        --container $config.sessionJob `
        --tail $tail
}

function Invoke-Open {
    param([string[]]$Items)
    $config = Assert-AcaConfigured
    $session = Get-FirstPositional $Items
    if (-not $session) {
        if ($config.aspireLoginUrl) {
            Start-Process $config.aspireLoginUrl
            Write-Output $config.aspireLoginUrl
            return
        }
        throw "No session supplied and no Aspire dashboard URL configured."
    }
    $execution = Resolve-SessionExecution -Config $config -Session $session
    $opened = $false
    if ($execution.Repository -and $execution.Branch) {
        $prs = gh pr list --repo $execution.Repository --head $execution.Branch --json url --limit 1 2>$null | ConvertFrom-Json
        if ($prs -and $prs[0].url) {
            Start-Process $prs[0].url
            Write-Output $prs[0].url
            $opened = $true
        }
    }
    if (-not $opened -and $config.aspireLoginUrl) {
        Start-Process $config.aspireLoginUrl
        Write-Output $config.aspireLoginUrl
    }
}

function Invoke-Sync {
    param([string[]]$Items)
    if (Has-Option $Items @("--dry-run")) {
        Write-Output "Files that would be considered for Squad state sync:"
        if (-not (Test-Path ".squad\team.md")) {
            Write-Warning "No .squad/team.md found in this directory."
        }
        foreach ($path in @(".squad", ".github/agents/squad-aca.agent.md", ".mcp.json")) {
            if (Test-Path $path) { Write-Output "  $path" }
        }
        Write-Output "`nCurrent git status:"
        git status --short
        return
    }
    Ensure-ExistingSquad
    $branch = Sync-LocalSquadState -SyncAll:(Has-Option $Items @("--sync-all", "--all"))
    Write-Output "Synced to branch: $branch"
}

function Invoke-Stop {
    param([string[]]$Items)
    $config = Assert-AcaConfigured
    $session = Get-FirstPositional $Items
    $execution = Resolve-SessionExecution -Config $config -Session $session
    az containerapp job stop --name $config.sessionJob --resource-group $config.resourceGroup --job-execution-name $execution.Execution
}

function Invoke-Watch {
    param([string[]]$Items)
    $config = Assert-AcaConfigured
    $sub = if ($Items.Count -gt 0) { $Items[0].ToLowerInvariant() } else { "status" }
    switch ($sub) {
        "start" {
            $repo = Get-OptionValue $Items @("--repo", "-Repository") (Get-CurrentRepo)
            if (-not $repo) { throw "No GitHub repo detected. Pass --repo <owner/repo>." }
            $ref = Get-OptionValue $Items @("--ref", "-Ref") (Get-CurrentBranch)
            $subSquad = Get-OptionValue $Items @("--sub-squad", "-SubSquad")
            & (Join-Path $ScriptDir "start-watch.ps1") -ResourceGroupName $config.resourceGroup -WatchAppName $config.watchApp -Repository $repo -Ref $ref -SubSquad $subSquad
        }
        "stop" {
            $repo = Get-OptionValue $Items @("--repo", "-Repository") (Get-CurrentRepo)
            if (-not $repo) { $repo = "unused/unused" }
            & (Join-Path $ScriptDir "start-watch.ps1") -ResourceGroupName $config.resourceGroup -WatchAppName $config.watchApp -Repository $repo -Stop
        }
        "status" {
            az containerapp show --name $config.watchApp --resource-group $config.resourceGroup --query "{name:name,provisioningState:properties.provisioningState,runningStatus:properties.runningStatus,minReplicas:properties.template.scale.minReplicas,maxReplicas:properties.template.scale.maxReplicas}" -o table
        }
        default { throw "Usage: squad-aca watch <start|stop|status> [--repo <owner/repo>]" }
    }
}

function Invoke-Ralph {
    param([string[]]$Items)
    $config = Assert-AcaConfigured
    $sub = if ($Items.Count -gt 0) { $Items[0].ToLowerInvariant() } else { "status" }
    switch ($sub) {
        "status" {
            az containerapp job show --name $config.ralphJob --resource-group $config.resourceGroup --query "{name:name,trigger:properties.configuration.triggerType,cron:properties.configuration.scheduleTriggerConfig.cronExpression,image:properties.template.containers[0].image}" -o table
            az containerapp job execution list --name $config.ralphJob --resource-group $config.resourceGroup --query "[0:10].{name:name,status:properties.status,start:properties.startTime,end:properties.endTime}" -o table
        }
        "run" {
            $repo = Get-OptionValue $Items @("--repo", "-Repository") (Get-CurrentRepo)
            $env = @()
            if ($repo) { $env += "GITHUB_REPOSITORY=$repo" }
            if ($env.Count -gt 0) {
                az containerapp job update --name $config.ralphJob --resource-group $config.resourceGroup --set-env-vars @env | Out-Null
            }
            az containerapp job start --name $config.ralphJob --resource-group $config.resourceGroup
        }
        "pause" {
            az containerapp job update --name $config.ralphJob --resource-group $config.resourceGroup --cron-expression "0 0 1 1 *" | Out-Null
            Write-Output "Paused Ralph by moving its cron schedule to yearly."
        }
        "resume" {
            $cron = Get-OptionValue $Items @("--cron") "*/5 * * * *"
            az containerapp job update --name $config.ralphJob --resource-group $config.resourceGroup --cron-expression $cron | Out-Null
            Write-Output "Resumed Ralph with cron: $cron"
        }
        default { throw "Usage: squad-aca ralph <status|run|pause|resume>" }
    }
}

function Invoke-SubSquad {
    param([string[]]$Items)
    $sub = if ($Items.Count -gt 0) { $Items[0].ToLowerInvariant() } else { "list" }
    switch ($sub) {
        "list" {
            if (Get-Command squad -ErrorAction SilentlyContinue) {
                squad subsquads list
            } elseif (Test-Path ".squad\streams.json") {
                Get-Content ".squad\streams.json" -Raw
            } else {
                Write-Output "No .squad/streams.json found."
            }
        }
        "activate" {
            $name = if ($Items.Count -gt 1) { $Items[1] } else { "" }
            if (-not $name) { throw "Usage: squad-aca subsquad activate <name>" }
            if (Get-Command squad -ErrorAction SilentlyContinue) {
                squad subsquads activate $name
            } else {
                Set-Content ".squad-workstream" "$name`n" -Encoding utf8
                Write-Output "Activated SubSquad: $name"
            }
        }
        "run" {
            $name = if ($Items.Count -gt 1) { $Items[1] } else { "" }
            if (-not $name) { throw "Usage: squad-aca subsquad run <name> `"prompt`"" }
            $remaining = @()
            if ($Items.Count -gt 2) { $remaining = $Items[2..($Items.Count - 1)] }
            $prompt = Get-PromptText "" $remaining
            if (-not $prompt) { throw "Provide a prompt for the SubSquad run." }
            Invoke-Run (@("--sub-squad", $name, $prompt))
        }
        default { throw "Usage: squad-aca subsquad <list|activate|run> [name] [prompt]" }
    }
}

function Invoke-Upgrade {
    param([string[]]$Items)
    if (Get-Command squad -ErrorAction SilentlyContinue) {
        squad upgrade
    } else {
        npx -y @bradygaster/squad-cli@latest upgrade
    }
    Install-CopilotAgent
    if (Has-Option $Items @("--deploy")) {
        & (Join-Path $ScriptDir "deploy.ps1")
    }
    Invoke-Doctor
}

function Invoke-Telemetry {
    param([string[]]$Items)
    $sub = if ($Items.Count -gt 0) { $Items[0].ToLowerInvariant() } else { "smoke" }
    if ($sub -ne "smoke") { throw "Usage: squad-aca telemetry smoke" }
    $config = Assert-AcaConfigured
    $repo = Get-OptionValue $Items @("--repo", "-Repository") (Get-CurrentRepo)
    if (-not $repo) { throw "No GitHub repo detected. Pass --repo <owner/repo>." }
    & (Join-Path $ScriptDir "start-session.ps1") -ResourceGroupName $config.resourceGroup -JobName $config.sessionJob -Repository $repo -Mode telemetry-smoke -SessionName "telemetry-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    if ($config.aspireLoginUrl) { Write-Output "Aspire: $($config.aspireLoginUrl)" }
}

function Invoke-Secrets {
    param([string[]]$Items)
    $sub = if ($Items.Count -gt 0) { $Items[0].ToLowerInvariant() } else { "" }
    if ($sub -ne "rotate") { throw "Usage: squad-aca secrets rotate [--github-token <token>] [--copilot-token <token>]" }
    $config = Assert-AcaConfigured
    $githubToken = Get-OptionValue $Items @("--github-token") (gh auth token)
    $copilotToken = Get-OptionValue $Items @("--copilot-token") $githubToken
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $otlpKey = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $dashboardToken = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    $otlpHeader = "x-otlp-api-key=$otlpKey"

    foreach ($job in @($config.sessionJob, $config.ralphJob)) {
        if ($job) {
            az containerapp job secret set --name $job --resource-group $config.resourceGroup --secrets "github-token=$githubToken" "copilot-github-token=$copilotToken" "otlp-headers=$otlpHeader" | Out-Null
        }
    }
    if ($config.watchApp) {
        az containerapp secret set --name $config.watchApp --resource-group $config.resourceGroup --secrets "github-token=$githubToken" "copilot-github-token=$copilotToken" "otlp-headers=$otlpHeader" | Out-Null
    }
    if ($config.aspireApp) {
        az containerapp secret set --name $config.aspireApp --resource-group $config.resourceGroup --secrets "otlp-api-key=$otlpKey" | Out-Null
        az containerapp update --name $config.aspireApp --resource-group $config.resourceGroup --set-env-vars "DASHBOARD__FRONTEND__BROWSERTOKEN=$dashboardToken" | Out-Null
        $fqdn = az containerapp show --name $config.aspireApp --resource-group $config.resourceGroup --query properties.configuration.ingress.fqdn -o tsv
        $config.aspireLoginUrl = "https://$fqdn/login?t=$dashboardToken"
        Save-AcaConfig $config
    }
    Write-Output "Rotated ACA secrets."
    if ($config.aspireLoginUrl) { Write-Output "Aspire: $($config.aspireLoginUrl)" }
}

function Invoke-Destroy {
    param([string[]]$Items)
    if (-not (Has-Option $Items @("--yes"))) { throw "This deletes the ACA resource group. Re-run with --yes to confirm." }
    $config = Assert-AcaConfigured
    az group delete --name $config.resourceGroup --yes --no-wait
    Write-Output "Delete started for resource group: $($config.resourceGroup)"
}

function Invoke-Export {
    param([string[]]$Items)
    Ensure-ExistingSquad
    $file = if ($Items.Count -gt 0 -and -not $Items[0].StartsWith("-")) { $Items[0] } else { "squad-export.json" }
    if (Get-Command squad -ErrorAction SilentlyContinue) {
        squad export --out $file
    } else {
        npx -y @bradygaster/squad-cli@latest export --out $file
    }
    Write-Output "Exported Squad state to $file"
}

function Invoke-Import {
    param([string[]]$Items)
    $file = if ($Items.Count -gt 0 -and -not $Items[0].StartsWith("-")) { $Items[0] } else { "" }
    if (-not $file) { throw "Usage: squad-aca import <file>" }
    if (Get-Command squad -ErrorAction SilentlyContinue) {
        squad import $file
    } else {
        npx -y @bradygaster/squad-cli@latest import $file
    }
    Sync-LocalSquadState
}

switch ($Command.ToLowerInvariant()) {
    "help" { Show-Help }
    "--help" { Show-Help }
    "-h" { Show-Help }
    "configure" { Invoke-Configure $Arguments }
    "config" { Invoke-Configure $Arguments }
    "doctor" { Invoke-Doctor }
    "init" { Invoke-Init $Arguments }
    "run" { Invoke-Run $Arguments }
    "sessions" { Invoke-Sessions $Arguments }
    "logs" { Invoke-Logs $Arguments }
    "stop" { Invoke-Stop $Arguments }
    "open" { Invoke-Open $Arguments }
    "sync" { Invoke-Sync $Arguments }
    "watch" { Invoke-Watch $Arguments }
    "ralph" { Invoke-Ralph $Arguments }
    "subsquad" { Invoke-SubSquad $Arguments }
    "subsquads" { Invoke-SubSquad $Arguments }
    "upgrade" { Invoke-Upgrade $Arguments }
    "telemetry" { Invoke-Telemetry $Arguments }
    "secrets" { Invoke-Secrets $Arguments }
    "destroy" { Invoke-Destroy $Arguments }
    "export" { Invoke-Export $Arguments }
    "import" { Invoke-Import $Arguments }
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
