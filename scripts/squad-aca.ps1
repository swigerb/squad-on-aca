param(
    [string]$Command = "help",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
. (Join-Path $ScriptDir "lib\session-env.ps1")
. (Join-Path $ScriptDir "lib\sync-safety.ps1")
. (Join-Path $ScriptDir "lib\aca-logs.ps1")
. (Join-Path $ScriptDir "lib\squad-aca-provider.ps1")
. (Join-Path $ScriptDir "lib\dispatch-contract.ps1")
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
  squad-aca leases [list|sweep] [--repo owner/repo]
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
        if ($item -in @("--repo", "-Repository", "--name", "-SessionName", "--branch", "-OutputBranch", "--sub-squad", "-SubSquad", "--owner", "--description", "--subscription", "--resource-group", "--session-job", "--ralph-job", "--watch-app", "--dashboard-url", "--log-analytics-workspace")) {
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
        logAnalyticsWorkspace = "law-squad-aca"
        # ACA Sandboxes deployment settings (issue #25). Empty by default: a
        # deployment with no sandbox group configured cannot reach the sandbox
        # plane at all, which is the same posture as the feature flag being off.
        # The Sandboxes provider reads these off the config object by name, and
        # until #25 they were dropped here -- so the group name could never
        # travel from configuration to the provider, and every sandbox create
        # would have refused on the identity-free precondition.
        sandboxGroup = ""
        sandboxDiskId = ""
        sandboxDiskLabel = ""
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
        logAnalyticsWorkspace = $outputs.logAnalyticsWorkspace
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
        $unsafe = Test-SyncSafety
        if ($unsafe.Count -gt 0) {
            $detail = ($unsafe | ForEach-Object { "  - $_" }) -join "`n"
            throw @"
--sync-all blocked by the public repo secret guard. The following working-tree
changes look like secrets or credential files and will NOT be pushed:

$detail

Remove or ignore these files (see .gitignore), or sync only Squad state without
--sync-all. Override intentionally with SQUAD_ACA_ALLOW_UNSAFE_SYNC=1 only if you
are certain the repository is private and the content is safe.
"@
        }
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
        logAnalyticsWorkspace = Get-OptionValue $Items @("--log-analytics-workspace", "-LogAnalyticsWorkspace") $existing.logAnalyticsWorkspace
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

function Get-SessionSandboxCatalogPath {
    return (Join-Path $RepoRoot "config\sandbox-classes.json")
}

# Where a LOCAL dispatch finds the credentials a sandbox session needs.
#
# The ACA Jobs plane never has this problem: scripts/deploy.ps1 writes the tokens
# into the deployment's own secret store, and scripts/lib/session-env.ps1 passes
# `secretref:` POINTERS, so the dispatcher never holds a value at all. A sandbox
# is created ad hoc by whoever ran the CLI, has no deployment behind it, and no
# secret store of its own -- so the value has to come from this process.
#
# Order is deliberate: an explicit SQUAD_* override first (so a session can be
# given a narrower credential than the developer's own), then the conventional
# names, then `gh auth token` as the last resort. Brokering `gh` is not a
# shortcut: it is BY CONSTRUCTION the identity that just wrote the dispatch
# lease, so a session can never be given push rights its dispatcher lacks.
$script:SandboxGitTokenSources = @("SQUAD_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN")
$script:SandboxCopilotTokenSources = @("SQUAD_COPILOT_GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN")

function Get-EnvironmentToken {
    <#
    .SYNOPSIS
        First non-empty environment variable from an ordered candidate list.
    #>
    param([string[]]$Names)

    foreach ($name in @($Names)) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -and $value.Trim()) {
            return [pscustomobject]@{ Token = $value.Trim(); Source = $name }
        }
    }
    return $null
}

function Resolve-SessionSandboxCredential {
    <#
    .SYNOPSIS
        Resolve the credentials a sandbox-routed session needs, or REFUSE before
        anything is created.

    .DESCRIPTION
        Sprint 7 built the delivery mechanism; this is what feeds it. Without it
        a sandbox session provisioned, applied egress, cloned the repository, ran
        the capability preflight and only THEN died inside `copilot` with
        "No authentication information found" -- ninety seconds of billed compute
        for a failure the dispatcher already had every fact needed to predict.

        So every refusal here happens BEFORE the provider is constructed and
        therefore before `aca` is called even once. Start-LeasedExecution
        releases the lease when provider construction throws, so an unusable
        credential costs nothing and is reported in one sentence that names the
        fix.

        TWO PLANES (PRD #6):

          git/`gh`  -- required. Used for clone, commit, push and PR. Delivered
                       as GH_TOKEN/GITHUB_TOKEN through the stdin-staged
                       credential file.
          Copilot   -- required. Used by the Copilot CLI. Delivered as
                       COPILOT_GITHUB_TOKEN through the same file.

        A DEDICATED Copilot credential (SQUAD_COPILOT_GITHUB_TOKEN or
        COPILOT_GITHUB_TOKEN) is additionally nominated for platform brokerage,
        which accepts ONLY a fine-grained `github_pat_` token for that type. So a
        dedicated credential is validated against that rule here and a classic
        `ghp_` / OAuth `gho_` value is REFUSED up front, with a message that
        names both the problem and the fix -- never as an opaque service error
        after the token has already crossed the wire.

        With no dedicated Copilot credential the git token serves the Copilot ENV
        plane and platform brokerage is skipped. That mirrors what
        scripts/deploy.ps1 already does for the ACA Jobs plane, and it is SAID
        OUT LOUD rather than assumed: the operator is told the two planes are one
        token and how to separate them.

    .OUTPUTS
        PSCustomObject with WorkerSecrets, BrokeredCredentials and Notes.
    #>

    $git = Get-EnvironmentToken -Names $script:SandboxGitTokenSources
    if (-not $git) {
        $ghToken = ""
        try {
            $ghToken = ((& gh auth token 2>$null) | Select-Object -First 1)
            if ($LASTEXITCODE -ne 0) { $ghToken = "" }
        } catch {
            $ghToken = ""
        }
        if ($ghToken) { $git = [pscustomobject]@{ Token = ([string]$ghToken).Trim(); Source = "gh auth token" } }
    }

    if (-not $git -or -not $git.Token) {
        throw ("Refusing to dispatch this session to a sandbox: no GitHub credential is available, so the worker " +
               "could not clone, push, or open a pull request and would fail with 'No authentication information found' " +
               "after the sandbox had already been created and billed. Nothing was started. " +
               "Fix it by running 'gh auth login', or by setting one of $($script:SandboxGitTokenSources -join ', ') " +
               "in this shell. The ACA Jobs plane is unaffected: it reads the deployment's own secret store.")
    }

    # The value reaches a POSIX credential file. Anything outside the unreserved
    # set is either a mangled value or an attempt to break out of the quoting.
    if ($git.Token -notmatch "^[A-Za-z0-9_\-\.~+/=]+$") {
        throw ("Refusing to dispatch this session to a sandbox: the GitHub credential from $($git.Source) contains " +
               "characters outside the unreserved token set, so it was either truncated, wrapped, or is not a token. " +
               "The value is not echoed. Nothing was started.")
    }

    $notes = @()
    $brokered = [ordered]@{}

    $copilot = Get-EnvironmentToken -Names $script:SandboxCopilotTokenSources
    if ($copilot -and $copilot.Token) {
        # A dedicated Copilot credential is nominated for PLATFORM brokerage, so
        # it must satisfy the platform's type rule. Checked here, offline.
        $issue = Test-SandboxCredentialToken -Type "github-copilot" -Token $copilot.Token
        if ($issue) {
            throw ("Refusing to dispatch this session to a sandbox: the Copilot credential from $($copilot.Source) " +
                   "cannot be brokered because $issue Nothing was started, and the value was never sent. " +
                   "Either set $($script:SandboxCopilotTokenSources[0]) to a fine-grained PAT (github_pat_...), or " +
                   "unset COPILOT_GITHUB_TOKEN to let the GitHub credential serve both planes.")
        }
        $brokered["github-copilot"] = $copilot.Token
        $copilotToken = $copilot.Token
        $notes += "[squad-aca] Credential planes: git from $($git.Source), Copilot from $($copilot.Source) (brokered separately)."
    } else {
        $copilotToken = $git.Token
        $notes += ("[squad-aca] No dedicated Copilot credential, so the GitHub credential from $($git.Source) serves " +
                   "BOTH planes in this sandbox. Set $($script:SandboxCopilotTokenSources[0]) to a fine-grained PAT " +
                   "(github_pat_...) to separate them; see docs/runbook.md.")
    }

    return [pscustomobject]@{
        WorkerSecrets       = [ordered]@{
            GH_TOKEN             = $git.Token
            GITHUB_TOKEN         = $git.Token
            COPILOT_GITHUB_TOKEN = $copilotToken
        }
        BrokeredCredentials = $brokered
        Notes               = $notes
    }
}

# ---------------------------------------------------------------------------
# Machine-readable output (`--json`)
# ---------------------------------------------------------------------------
#
# WHY THIS EXISTS. `squad-aca` renders for humans, and 22 golden captures pin
# that rendering byte for byte. A .NET caller -- the Microsoft Agent Framework
# adapter in aspire/Squad.Aca.Agents -- needs a STABLE machine contract, and
# parsing the human tables would both be fragile and make the goldens
# load-bearing for something they were never meant to describe.
#
# So `--json` is strictly ADDITIVE and strictly OPT-IN. No existing invocation
# emits any of this, which is what keeps all 22 goldens byte-identical; the new
# `--json` invocations get goldens of their own.
#
# Three rules the shapes below obey:
#
#   1. STABLE KEY ORDER, and every key is always present. A field the substrate
#      cannot supply is emitted as null rather than omitted, so a consumer's
#      deserialiser never has to distinguish "absent" from "unknown".
#   2. NO TOKENS, EVER. Nothing here reads a credential, and the only strings
#      that reach the document are session identifiers, the opaque execution
#      handle, and the fixed route/reason vocabulary the control plane already
#      publishes.
#   3. NO RAW MANIFEST VALUES. The capability manifest is repository content;
#      only the resolver's DECISION (route, reason, sandbox class id) crosses
#      this boundary.
#
# The vocabulary is deliberately borrowed rather than invented:
#   route / reason / sandboxClassId  <- Resolve-SquadExecutionRoute
#   executionMode / sessionHandle / status / statusPollRef / fallbackReason
#                                    <- New-SquadDispatchResponse (PRD #6)
$script:SquadJsonRunSchema      = "squad-aca/run@1"
$script:SquadJsonSessionsSchema = "squad-aca/sessions@1"

# Route reasons that describe the ORDINARY outcome, not a deviation. Anything
# else is reported as a fallbackReason, because it explains why the session did
# not land where the manifest asked.
$script:SquadJsonPlainRouteReasons = @(
    "no-capability-resolution",
    "capability-resolution-aca-job",
    "approved-sandbox-class"
)

function Write-SquadJsonDocument {
    <#
    .SYNOPSIS
        Emits one JSON document on stdout.

    .DESCRIPTION
        -Depth is pinned so a nested record is never truncated to
        "System.Object[]", and -Compress is deliberately NOT used: the goldens
        for the `--json` cases are reviewed by humans too.
    #>
    param([Parameter(Mandatory = $true)][object]$Document)
    Write-Output ($Document | ConvertTo-Json -Depth 10)
}

function Get-SquadJsonFallbackReason {
    <#
    .SYNOPSIS
        The route reason, but only when it explains a DEVIATION.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Reason)
    if (-not $Reason) { return $null }
    if ($script:SquadJsonPlainRouteReasons -contains $Reason) { return $null }
    return $Reason
}

function New-SquadRunJsonDocument {
    <#
    .SYNOPSIS
        The `squad-aca run --json` contract.

    .DESCRIPTION
        `executionHandle` is null for an ACA Job dispatch and that is a truthful
        property of the substrate, not an omission: ACA names an execution
        asynchronously, so there is nothing to hand back at dispatch time.
        `statusPollRef` is therefore the field a caller addresses `stop` and
        `sessions --session` with -- the handle when there is one, the session
        id when there is not. A caller passes it back verbatim and never parses
        it.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionName,
        [AllowEmptyString()][string]$Repository = "",
        [AllowEmptyString()][string]$Ref = "",
        [AllowEmptyString()][string]$OutputBranch = "",
        [AllowNull()][object]$Route = $null,
        [AllowNull()][object]$RouteReason = $null,
        [AllowNull()][object]$ExecutionMode = $null,
        [AllowNull()][object]$ExecutionHandle = $null,
        [AllowNull()][object]$SandboxClass = $null,
        [AllowNull()][object]$FallbackReason = $null,
        [bool]$Dispatched = $false,
        [Parameter(Mandatory = $true)][string]$Status
    )

    $pollRef = $null
    if ($ExecutionHandle) { $pollRef = [string]$ExecutionHandle }
    elseif ($Dispatched -and $SessionName) { $pollRef = [string]$SessionName }

    return [pscustomobject]([ordered]@{
        schema          = $script:SquadJsonRunSchema
        sessionName     = $SessionName
        repository      = $Repository
        ref             = $Ref
        outputBranch    = $OutputBranch
        route           = $Route
        routeReason     = $RouteReason
        executionMode   = $ExecutionMode
        executionHandle = $ExecutionHandle
        statusPollRef   = $pollRef
        sandboxClass    = $SandboxClass
        fallbackReason  = $FallbackReason
        dispatched      = $Dispatched
        status          = $Status
    })
}

function ConvertTo-SquadSessionJson {
    <#
    .SYNOPSIS
        One provider execution record as the `sessions --json` element shape.

    .DESCRIPTION
        The two substrates describe an execution with different Display columns
        (ACA Jobs: Execution/Repository/Branch/Mode/Source/Started/Ended;
        Sandboxes: Sandbox/Class/Phase/ExitCode/Inconclusive). Rendering picks
        one table per shape; a machine contract cannot, so this projects BOTH
        into one key set with nulls where a substrate has no answer.

        `executionMode` comes from the HANDLE's provider id, not from the
        display, because the handle is the only authoritative statement of which
        substrate owns this execution.
    #>
    param([Parameter(Mandatory = $true)][object]$Record)

    $display = $Record.Display
    $names = @()
    if ($display) { $names = @($display.PSObject.Properties.Name) }

    $mode = ""
    try { $mode = [string](ConvertFrom-SquadExecutionHandle -Handle $Record.Handle).ProviderId } catch { $mode = "" }

    $doc = [ordered]@{
        sessionName     = ""
        executionName   = ""
        executionHandle = [string]$Record.Handle
        executionMode   = $mode
        route           = $mode
        status          = [string]$Record.Status
        sandboxClass    = $null
        repository      = $null
        branch          = $null
        mode            = $null
        source          = $null
        startedAt       = $null
        endedAt         = $null
        phase           = $null
        exitCode        = $null
        inconclusive    = $null
    }

    if ($names -contains "Session") { $doc["sessionName"] = [string]$display.Session }
    if ($names -contains "Sandbox") { $doc["executionName"] = [string]$display.Sandbox }
    elseif ($names -contains "Execution") { $doc["executionName"] = [string]$display.Execution }
    if ($names -contains "Route" -and $display.Route) { $doc["route"] = [string]$display.Route }
    if ($names -contains "Class") { $doc["sandboxClass"] = [string]$display.Class }
    if ($names -contains "Repository") { $doc["repository"] = $display.Repository }
    if ($names -contains "Branch") { $doc["branch"] = $display.Branch }
    if ($names -contains "Mode") { $doc["mode"] = $display.Mode }
    if ($names -contains "Source") { $doc["source"] = $display.Source }
    if ($names -contains "Started") { $doc["startedAt"] = $display.Started }
    if ($names -contains "Ended") { $doc["endedAt"] = $display.Ended }
    if ($names -contains "Phase") { $doc["phase"] = $display.Phase }
    if ($names -contains "ExitCode") { $doc["exitCode"] = $display.ExitCode }
    if ($names -contains "Inconclusive") { $doc["inconclusive"] = [bool]$display.Inconclusive }

    return [pscustomobject]$doc
}

function New-SessionExecutionProvider {
    <#
    .SYNOPSIS
        Returns the execution provider used for Squad session dispatch.

    .DESCRIPTION
        Single place where the CLI decides which execution substrate it is
        talking to.

        ACA Jobs are the unconditional default. The very first thing this does
        is check the sandbox feature flag, and with the flag unset it returns the
        ACA Jobs adapter having touched nothing else -- no catalog read, no route
        resolution, no `aca` lookup. That is what makes "flag off" byte-identical
        to a build with no sandbox code in it, and it is what the CLI golden gate
        and compare-cli-baseline.ps1 verify.

        With the flag ON, the capability resolution the caller supplies is routed
        through Resolve-SquadExecutionRoute, which can return `sandbox` only for
        an administrator-approved class in a non-provisional catalog, and returns
        `fail-closed` rather than quietly downgrading a session whose required
        capabilities the default worker cannot satisfy.

        WHERE THE RESOLUTION COMES FROM (issue #25). Start-LeasedExecution asks
        the shared dispatch core -- worker/lib/squad-dispatch.js, the same file
        Ralph and Watch call -- for the routing decision BEFORE any compute is
        requested, and hands the Sprint 2 capability decision it carries
        (`decision.routing.capability`) to this function as
        -CapabilityResolution. The route is therefore decided by exactly one
        implementation, in Node, and this file only acts on it. Nothing here
        re-derives a route, and scripts/validate.ps1 asserts that the PowerShell
        dispatch shim contains no route literal at all.

        -CapabilityResolution is still optional and still defaults to $null,
        because the lifecycle call sites (`sessions`, `logs`, `stop`) must NOT
        re-resolve: they recover the substrate from the opaque execution handle
        they already hold, via New-SessionExecutionProviderForHandle.

    .PARAMETER RouteOutcome
        Optional hashtable (a reference type, exactly like Start-SquadExecution's
        -Outcome). When supplied it receives ['Route'] -- the
        Resolve-SquadExecutionRoute result -- INCLUDING on the fail-closed path,
        which is set before the throw so a `--json` caller can report the reason
        rather than only a stack trace. Nothing here re-derives a route to fill
        it: it is the same object the switch below acts on, so the reported route
        cannot drift from the executed one.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [object]$CapabilityResolution = $null,
        [System.Collections.IDictionary]$RouteOutcome = $null
    )

    $acaJob = {
        return New-SquadExecutionProvider -Kind "aca-job" -Options @{
            Config    = $Config
            ScriptDir = $ScriptDir
        }
    }

    # The feature flag is enforced INSIDE Resolve-SquadExecutionRoute, not by
    # short-circuiting to ACA Jobs here. Until issue #25 wired a real resolution
    # in, this function returned the Jobs provider whenever the flag was off and
    # never consulted the gate at all -- which was harmless only because
    # -CapabilityResolution was always $null. With a real decision flowing in,
    # that early return IS the silent downgrade PRD #6 forbids: a repository
    # whose required capabilities the default worker cannot meet would have been
    # run on the default worker anyway, unsafely and without a word.
    #
    # The gate distinguishes the two flag-off cases that matter:
    #   default image sufficient  -> aca-job      (a genuine, safe fall back)
    #   default image insufficient -> fail-closed (refuse; nothing is started)
    # and with no resolution at all it returns aca-job, so the no-manifest path
    # is byte-identical to what it has always been.
    $route = Resolve-SquadExecutionRoute -Decision $CapabilityResolution -Config $Config `
        -CatalogPath (Get-SessionSandboxCatalogPath)
    if ($null -ne $RouteOutcome) { $RouteOutcome["Route"] = $route }

    switch ($route.Route) {
        "sandbox" {
            # THE credential wiring. Resolved and validated HERE, before the
            # provider exists and therefore before `aca` is called even once, so
            # an unusable credential never costs a sandbox. Sprint 7 built the
            # delivery mechanism and this branch did not feed it -- which is why
            # a live session reached the Copilot invocation with no credential.
            $credentials = Resolve-SessionSandboxCredential
            foreach ($note in $credentials.Notes) { Write-Host $note }
            return New-SquadExecutionProvider -Kind "sandbox" -Options @{
                Class               = $route.SandboxClass
                Config              = $Config
                ScriptDir           = $ScriptDir
                WorkerSecrets       = $credentials.WorkerSecrets
                BrokeredCredentials = $credentials.BrokeredCredentials
            }
        }
        "fail-closed" {
            $advice = "Review the repository's squad-capabilities.yml and config/sandbox-classes.json."
            if ($route.Reason -eq "sandbox-feature-disabled-and-default-insufficient") {
                # Do NOT advise unsetting the flag here: the flag is already off,
                # and it is the manifest's requirements the default worker cannot
                # meet. Turning the sandbox plane ON is the fix, not off.
                $advice = "This repository requires capabilities the default worker image does not provide, so it cannot be run on the ACA Jobs path. Set SQUAD_ACA_ENABLE_SANDBOX=1 to use an approved sandbox class, or relax squad-capabilities.yml."
            } elseif (-not $route.FeatureEnabled) {
                $advice = "$advice Set SQUAD_ACA_ENABLE_SANDBOX=1 to use an approved sandbox class."
            } else {
                $advice = "$advice Or unset SQUAD_ACA_ENABLE_SANDBOX to return to the ACA Jobs path."
            }
            throw "Refusing to dispatch this session: capability routing failed closed ($($route.Reason)). Nothing was started. $advice"
        }
    }
    return (& $acaJob)
}

function New-SessionSandboxOperationsProvider {
    <#
    .SYNOPSIS
        A Sandboxes provider for LIFECYCLE operations (status / logs / cancel /
        terminate) -- never for create.

    .DESCRIPTION
        New-SandboxExecutionProvider requires an approved class, and that
        requirement is a security assertion that must not be relaxed. But a class
        is only ever READ by `create`: it supplies the egress template, the CPU
        and memory shape, and the concurrency ceiling. status, logs, cancel and
        terminate address a sandbox purely by the label carried in its opaque
        handle and never touch Context.Class.

        So a lifecycle call supplies the class named in the handle when there is
        one, and otherwise the first administrator-approved class in the catalog,
        purely to construct the provider. That cannot widen anything: the only
        operation that could act on a class is create, and create is never
        reached from a handle.

        Returns $null when the catalog offers no approved class, so a caller can
        decide whether that is fatal (operating a specific sandbox) or simply
        means there is nothing to list.

        DELIBERATELY CREDENTIAL-FREE. Listing, tailing and stopping a sandbox
        needs no worker credential, so none is resolved: a `squad-aca sessions`
        on a machine with no `gh` login must still list, and a lifecycle path
        that resolved credentials would refuse it for no reason.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [string]$ClassId = ""
    )

    $catalog = Get-SquadSandboxCatalog -CatalogPath (Get-SessionSandboxCatalogPath)
    if (-not $catalog) { return $null }

    $resolved = $null
    if ($ClassId) {
        $resolved = Get-SquadSandboxClass -ClassId $ClassId -Catalog $catalog
        if (-not $resolved.Class) { return $null }
    } else {
        foreach ($candidate in @($catalog.classes)) {
            $attempt = Get-SquadSandboxClass -ClassId ([string]$candidate.id) -Catalog $catalog
            if ($attempt.Class) { $resolved = $attempt; break }
        }
        if (-not $resolved) { return $null }
    }

    return New-SquadExecutionProvider -Kind "sandbox" -Options @{
        Class     = $resolved.Class
        Config    = $Config
        ScriptDir = $ScriptDir
    }
}

function New-SessionExecutionProviderForHandle {
    <#
    .SYNOPSIS
        The provider that OWNS an existing execution, recovered from its handle.

    .DESCRIPTION
        `status`, `logs` and `stop` operate on work that has already been
        dispatched, so the route is a property of that execution and must not be
        computed again. Re-resolving would read today's manifest, today's catalog
        and today's feature flag to answer a question about a session that was
        routed yesterday -- and would happily hand an ACA Job execution to the
        Sandboxes adapter after someone edited squad-capabilities.yml.

        A handle already carries the identity of the provider that minted it, so
        that is the only thing consulted here. A handle from an unknown provider
        is an error, never a guess.

        A sandbox handle still requires the feature flag: operating the sandbox
        plane with it unset would defeat the kill switch, whose whole promise is
        that unsetting it stops this control plane touching `aca` at all.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Handle
    )

    $decoded = ConvertFrom-SquadExecutionHandle -Handle $Handle
    switch ($decoded.ProviderId) {
        "aca-job" {
            return New-SquadExecutionProvider -Kind "aca-job" -Options @{
                Config    = $Config
                ScriptDir = $ScriptDir
            }
        }
        "sandbox" {
            if (-not (Test-SquadSandboxEnabled -Config $Config)) {
                throw "This session runs on the ACA Sandboxes plane, which is disabled here. Set SQUAD_ACA_ENABLE_SANDBOX=1 to inspect or stop it; nothing was contacted."
            }
            $classId = ""
            if ($decoded.Payload -and ($decoded.Payload.PSObject.Properties.Name -contains "class")) {
                $classId = [string]$decoded.Payload.class
            }
            $provider = New-SessionSandboxOperationsProvider -Config $Config -ClassId $classId
            if (-not $provider) {
                throw "This session runs on the ACA Sandboxes plane, but config/sandbox-classes.json offers no administrator-approved class to operate it with. Review the catalog; nothing was contacted."
            }
            return $provider
        }
    }
    throw "Execution handle belongs to provider '$($decoded.ProviderId)', which this CLI does not know how to operate."
}

function Get-CapabilityManifestSource {
    <#
    .SYNOPSIS
        Where the control plane reads the repository's capability manifest from,
        BEFORE anything is dispatched.

    .DESCRIPTION
        The route has to be decided before compute is requested, which means the
        manifest has to be read before the worker has cloned anything. The source
        is the LOCAL WORKING TREE, and only when that tree is provably the
        repository being dispatched.

        Why the working tree and not `gh api` against the requested ref:

          * it is what the developer is actually dispatching -- `squad-aca run`
            syncs the working tree to the branch the worker will clone
            (Sync-LocalSquadState) immediately before this runs, and already
            warns when uncommitted changes mean the two can differ;
          * it adds no network call, so a dispatch cannot fail, stall, or be
            rate-limited by a routing lookup;
          * it keeps the no-manifest path free of any new observable behaviour,
            which is what the 22 CLI goldens pin.

        Reading it can only produce a routing HINT that is re-checked: the
        in-worker preflight (worker/lib/squad-capability-preflight.sh) runs
        against the real clone before any repository code and fails closed if a
        required capability is missing. So working-tree drift can cost a refused
        session; it can never grant one.

        THE FAILURE MODE IS EXPLICIT, NOT A GUESS. Two different things can go
        wrong and they are deliberately handled differently:

          * No readable tree for THIS repository -- `--repo other/repo`, or a
            directory that is not a git work tree. There is no manifest to read,
            so the decision is the same one a repository with no manifest gets:
            the default ACA Jobs route. The caller says so out loud
            (Start-LeasedExecution warns and names the reason) and the in-worker
            preflight is the backstop. This is a documented fall back, not a
            silent guess, and it is the pre-existing behaviour of every dispatch
            before issue #25.
          * A manifest that IS present but cannot be read, parsed or validated.
            That is decided by the shared resolver, which returns `fail-closed`,
            and Get-SquadDispatchDecision throws. Nothing is dispatched.

    .OUTPUTS
        PSCustomObject with Path ("" when there is none) and Reason.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Repository,
        [AllowEmptyString()][string]$CurrentRepository = ""
    )

    $top = ""
    try {
        $top = (git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) { $top = "" }
    } catch {
        $top = ""
    }
    if (-not $top) {
        return [pscustomobject]@{ Path = ""; Reason = "this directory is not a git working tree" }
    }
    if (-not $CurrentRepository -or $CurrentRepository -ne $Repository) {
        return [pscustomobject]@{ Path = ""; Reason = "the working tree here is not '$Repository'" }
    }
    return [pscustomobject]@{ Path = ([string]$top).Trim(); Reason = "local working tree" }
}

function Invoke-Run {
    param([string[]]$Items, [string]$FirstPrompt = "")
    $config = Assert-AcaConfigured
    Ensure-ExistingSquad

    # Captured once: Get-CurrentRepo shells out to `gh`, and the capability
    # manifest source below needs to know whether the working tree IS the
    # repository being dispatched. Calling it twice would add an observable `gh`
    # invocation to every run.
    $currentRepo = Get-CurrentRepo
    $repo = Get-OptionValue $Items @("--repo", "-Repository") $currentRepo
    if (-not $repo) { throw "No GitHub repo detected. Run 'squad-aca init' first or pass --repo <owner/repo>." }
    $session = Get-OptionValue $Items @("--name", "-SessionName") "session-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $branch = Get-OptionValue $Items @("--branch", "-OutputBranch") "squad/$session"
    $subSquad = Get-OptionValue $Items @("--sub-squad", "-SubSquad")
    $prompt = Get-PromptText $FirstPrompt $Items
    if (-not $prompt) { throw "Provide a prompt, e.g. squad-aca `"Build the API and open a PR`"." }

    $ref = Sync-LocalSquadState -SyncAll:(Has-Option $Items @("--sync-all"))
    $manifestSource = Get-CapabilityManifestSource -Repository $repo -CurrentRepository $currentRepo
    $request = New-SquadDispatchRequest `
        -SessionId $session `
        -DispatchSource "local-cli" `
        -Repository $repo `
        -Ref $ref `
        -Prompt $prompt `
        -Mode "prompt" `
        -SubSquad $subSquad `
        -PushChanges (-not (Has-Option $Items @("--no-push"))) `
        -OutputBranch $branch
    Start-LeasedExecution -Config $config -Request $request -ManifestSource $manifestSource `
        -Json:(Has-Option $Items @("--json"))
}

function Start-LeasedExecution {
    <#
    .SYNOPSIS
        The local CLI's single dispatch path: one shared routing decision, a
        durable lease written BEFORE compute, then execution.

    .DESCRIPTION
        Implements the PRD #6 lifecycle invariant "claim and session state are
        written before compute is requested" for the local CLI, using exactly
        the same decision and lease code Ralph and Watch use (see
        scripts/lib/dispatch-contract.ps1).

        Ordering is the point of this function:
            1. decide   -- the shared routing decision (fail-closed routes throw)
            2. claim    -- the durable lease record is written
            3. create   -- compute is requested
            4. dispatched / release

        A claim that comes back `active` or `completed` means another dispatcher
        already owns this work, so nothing is started -- that is what stops a
        duplicate run from double-dispatching. If step 3 throws, the lease is
        released so the work retries instead of being pinned by a dead claim.

        Step 1 is also where the capability manifest is read (issue #25). The
        shared dispatch core resolves the route against -ManifestSource, and the
        capability decision it produces is what selects the execution provider in
        step 3 -- so the substrate is chosen from the manifest BEFORE compute is
        requested, using the same Node implementation Ralph and Watch use.

    .PARAMETER ManifestSource
        Optional result of Get-CapabilityManifestSource. Omitted (or carrying no
        Path) means there is no readable working tree for this repository, which
        resolves exactly like a repository with no manifest: the default ACA Jobs
        route. That is reported, not assumed silently.

    .PARAMETER Json
        Emit the machine-readable dispatch document (squad-aca/run@1) on stdout
        instead of the substrate's own dispatch output. OPT-IN and additive: with
        it unset this function behaves exactly as it always has, which is what
        keeps the 22 CLI goldens byte-identical.

        Two things change under -Json, both deliberately:

          * The substrate's pass-through dispatch output is REDIRECTED TO STDERR,
            not suppressed. stdout has to carry exactly one JSON document for a
            machine to parse it, and swallowing `az containerapp job start`'s
            output is the regression that sank PR #9 -- so it is moved, in full,
            never dropped.
          * A refusal (a fail-closed route) still exits non-zero, but ALSO emits
            the document, carrying route `fail-closed` and the resolver's reason.
            An adapter that only saw the exit code would know a dispatch failed
            but not that the repository's capabilities cannot be met.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][object]$Request,
        [string]$IssueNumber = "",
        [object]$ManifestSource = $null,
        [switch]$Json
    )

    $repo = [string]$Request.repository.fullName
    $sessionId = [string]$Request.sessionId
    $ref = [string]$Request.repository.ref
    $outputBranch = [string]$Request.git.outputBranch
    $repoDir = ""
    if ($ManifestSource -and $ManifestSource.Path) { $repoDir = [string]$ManifestSource.Path }

    $decision = Get-SquadDispatchDecision `
        -SessionId ([string]$Request.sessionId) `
        -DispatchSource ([string]$Request.dispatchSource) `
        -Repository $repo `
        -IssueNumber $IssueNumber `
        -RepoDir $repoDir

    # Say so when the route was decided WITHOUT reading a manifest. Silence here
    # is what would make the fall back a guess: an operator who believes a
    # sandbox manifest is being honoured, while the manifest was never opened,
    # has no way to tell from the output. Only warn when the sandbox plane is
    # switched on, so the default path stays byte-identical.
    if (-not $repoDir -and $ManifestSource -and (Test-SquadSandboxEnabled -Config $Config)) {
        Write-Warning ("Capability routing read no manifest for '$repo' ($($ManifestSource.Reason)), so this dispatch " +
            "uses the default ACA Jobs route. The in-worker capability preflight still applies after the clone.")
    }

    $claim = New-SquadDispatchLease -Decision $decision -Repository $repo
    # Fail-closed on the outcome vocabulary: ONLY `created` and `repaired` mean
    # "you own this work". Anything else -- including any outcome added later --
    # must not dispatch. `active` now also covers "another dispatcher is inside
    # its claim -> compute window right now", which is exactly the case that used
    # to hand two dispatchers the same lease.
    if ($claim.outcome -ne "created" -and $claim.outcome -ne "repaired") {
        Write-Warning ("Not dispatching '$($Request.sessionId)': lease '$($decision.leaseKey)' is already " +
            "$($claim.lease.state) (claimed by $($claim.lease.dispatchSource) at $($claim.lease.startedAt)). " +
            "Run 'squad-aca leases' to inspect it.")
        if ($Json) {
            # No provider was constructed, so there is no resolved route to
            # report -- and inventing one here would answer a routing question
            # nobody asked. dispatched:false is the whole statement, and it is
            # what an adapter refuses on.
            Write-SquadJsonDocument (New-SquadRunJsonDocument `
                -SessionName $sessionId -Repository $repo -Ref $ref -OutputBranch $outputBranch `
                -FallbackReason ("lease-" + [string]$claim.lease.state) `
                -Dispatched $false -Status "not-dispatched")
        }
        return
    }

    $Request.capabilityResolution = $decision

    # THE wiring issue #25 exists for. The provider is selected from the SPRINT 2
    # capability decision the shared core just produced -- `routing.capability`,
    # not `routing` -- because that object is what Resolve-SquadExecutionRoute
    # reads: it carries `route`, `sandboxClass` AND `defaultImageSufficient`, and
    # the last of those is what lets the flag-off path tell "the default worker
    # can run this anyway" apart from "the default worker cannot, so refuse".
    # `routing` deliberately omits it.
    $capability = $null
    if ($decision.routing -and ($decision.routing.PSObject.Properties.Name -contains "capability")) {
        $capability = $decision.routing.capability
    }

    $routeOutcome = @{}
    $outcome = @{}
    try {
        if ($Json) {
            # 6>&1 folds the information stream (Write-Host) into the success
            # stream so BOTH the sandbox provider's progress notes and the ACA
            # Jobs adapter's `az` pass-through are captured. They are then
            # re-emitted on stderr: moved, never dropped. Warnings and errors are
            # untouched and already go to stderr.
            $emitted = @(& {
                $provider = New-SessionExecutionProvider -Config $Config -CapabilityResolution $capability -RouteOutcome $routeOutcome
                Start-SquadExecution -Provider $provider -Request $Request -Outcome $outcome
            } 6>&1)
            foreach ($line in $emitted) { [Console]::Error.WriteLine([string]$line) }
        } else {
            Start-SquadExecution -Provider (New-SessionExecutionProvider -Config $Config -CapabilityResolution $capability) -Request $Request
        }
    } catch {
        Set-SquadDispatchLeaseState -Operation "release" -Repository $repo -LeaseKey ([string]$decision.leaseKey) -Reason "dispatch-failed" | Out-Null
        if ($Json) {
            $failedRoute = $routeOutcome["Route"]
            $failedReason = $null
            $failedRouteName = $null
            $failedClassId = $null
            if ($failedRoute) {
                $failedRouteName = [string]$failedRoute.Route
                $failedReason = [string]$failedRoute.Reason
                if ($failedRoute.SandboxClassId) { $failedClassId = [string]$failedRoute.SandboxClassId }
            }
            $failedStatus = "failed"
            if ($failedRouteName) { $failedStatus = $failedRouteName }
            Write-SquadJsonDocument (New-SquadRunJsonDocument `
                -SessionName $sessionId -Repository $repo -Ref $ref -OutputBranch $outputBranch `
                -Route $failedRouteName -RouteReason $failedReason -SandboxClass $failedClassId `
                -FallbackReason (Get-SquadJsonFallbackReason $failedReason) `
                -Dispatched $false -Status $failedStatus)
            [Console]::Error.WriteLine([string]$_.Exception.Message)
            exit 1
        }
        throw
    }

    if ($Json) {
        $route = $routeOutcome["Route"]
        $response = $outcome["Response"]
        $reason = $null
        $routeName = $null
        if ($route) {
            $routeName = [string]$route.Route
            $reason = [string]$route.Reason
        }
        $classId = $null
        if ($response -and $response.sandboxClass) { $classId = [string]$response.sandboxClass }
        elseif ($route -and $route.SandboxClassId) { $classId = [string]$route.SandboxClassId }
        $handle = $null
        if ($response -and $response.sessionHandle) { $handle = [string]$response.sessionHandle }
        $execMode = $null
        $status = "Requested"
        if ($response) {
            $execMode = [string]$response.executionMode
            $status = [string]$response.status
        }
        Write-SquadJsonDocument (New-SquadRunJsonDocument `
            -SessionName $sessionId -Repository $repo -Ref $ref -OutputBranch $outputBranch `
            -Route $routeName -RouteReason $reason `
            -ExecutionMode $execMode -ExecutionHandle $handle -SandboxClass $classId `
            -FallbackReason (Get-SquadJsonFallbackReason $reason) `
            -Dispatched $true -Status $status)
    }

    # Compute is LIVE from here on, so this call is inside the try for the same
    # reason Ralph guards its equivalent with `|| true`. A transient fault must
    # not throw to the user AFTER the execution started: the user would retry,
    # the retry would find a `claimed` lease, and a second execution would start.
    # It must also NOT release -- that would hand live work to another dispatcher.
    # The worker's periodic heartbeat moves the lease to `running` regardless.
    try {
        Set-SquadDispatchLeaseState -Operation "dispatched" -Repository $repo -LeaseKey ([string]$decision.leaseKey) | Out-Null
    } catch {
        Write-Warning ("Started '$($Request.sessionId)' but could not record the lease as dispatched: $($_.Exception.Message) " +
            "The execution is running; the lease is reconciled by the worker heartbeat.")
    }
}

function Invoke-Leases {
    <#
    .SYNOPSIS
        Inspect or sweep the durable dispatch leases.
    #>
    param([string[]]$Items)
    $config = Assert-AcaConfigured
    $repo = Get-OptionValue $Items @("--repo", "-Repository") (Get-CurrentRepo)
    if (-not $repo) { throw "No GitHub repo detected. Run 'squad-aca init' first or pass --repo <owner/repo>." }

    $sub = if ($Items.Count -gt 0 -and -not $Items[0].StartsWith("-")) { $Items[0].ToLowerInvariant() } else { "list" }
    switch ($sub) {
        "list" {
            $leases = Get-SquadDispatchLease -Repository $repo
            if (-not $leases -or @($leases).Count -eq 0) {
                Write-Output "No dispatch leases for $repo."
                return
            }
            @($leases) | ForEach-Object {
                [pscustomobject]@{
                    Lease   = $_.leaseKey
                    State   = $_.state
                    Route   = $_.route
                    Source  = $_.dispatchSource
                    Session = $_.sessionId
                    Started = $_.startedAt
                    Heartbeat = $_.lastHeartbeatAt
                }
            } | Format-Table -AutoSize | Out-String -Width 200
        }
        "sweep" {
            $result = Invoke-SquadLeaseSweep -Repository $repo
            Write-Output "Examined $($result.examined) of $($result.total) lease(s); reclaimed $(@($result.reclaimed).Count); pruned $(@($result.pruned).Count)."
            foreach ($item in @($result.reclaimed)) { Write-Output "  reclaimed $($item.key) ($($item.reason))" }
            foreach ($item in @($result.pruned)) { Write-Output "  pruned $($item.key) ($($item.state), past the retention window)" }
            if ($result.total -gt $result.examined) {
                Write-Output "  $($result.total - $result.examined) lease(s) were not examined this run (per-run read budget $($result.budget)); the next sweep continues from where this one stopped."
            }
            if ($result.truncated) {
                Write-Warning "The lease ledger exceeded the Contents API directory listing cap, so this sweep saw only part of it."
            }
        }
        default { throw "Usage: squad-aca leases [list|sweep] [--repo <owner/repo>]" }
    }
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-GitHubPushAccessCheck {
    <#
    .SYNOPSIS
        Whether the ACTIVE `gh` identity can WRITE to this repository.

    .DESCRIPTION
        `gh auth status` only proves that some account is signed in. Every
        dispatch writes a durable lease to this repository through `gh`, and
        GitHub answers a write to a repository you can only READ with
        `404 Not Found`, not `403 Forbidden` -- so a read-only identity gets a
        green "GitHub auth ok" here and an unexplained 404 at lease claim.
        That is exactly how issue #22 reached a live E2E run on a machine with
        two authenticated accounts, where `gh` uses the ACTIVE one.

        Reports the login as well as the permission, because in the
        multi-account case the useful question is not "is push allowed" but
        "which account is `gh` using right now".
    #>
    param([string]$Repository)

    if (-not $Repository) {
        return [pscustomobject]@{ Check = "GitHub push"; Status = "missing"; Detail = "No repo detected; run squad-aca init or pass --repo" }
    }

    $login = (gh api user --jq .login 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $login) { $login = "unknown identity" }

    $permissionsJson = (gh api "repos/$Repository" --jq .permissions 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not $permissionsJson.Trim()) {
        return [pscustomobject]@{ Check = "GitHub push"; Status = "unknown"; Detail = "Could not read permissions on $Repository as $login" }
    }

    $permissions = $null
    try { $permissions = $permissionsJson | ConvertFrom-Json } catch { $permissions = $null }
    if ($null -eq $permissions -or $null -eq $permissions.push) {
        return [pscustomobject]@{ Check = "GitHub push"; Status = "unknown"; Detail = "Could not read permissions on $Repository as $login" }
    }

    if ($permissions.push) {
        return [pscustomobject]@{ Check = "GitHub push"; Status = "ok"; Detail = "$login has push access to $Repository" }
    }
    return [pscustomobject]@{
        Check  = "GitHub push"
        Status = "failed"
        Detail = "$login has push=false on $Repository; GitHub reports this as 404 Not Found. Run 'gh auth status' and switch account"
    }
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
        # A native command sets $LASTEXITCODE; it does not throw, so the catch
        # below never fired and this row read "ok" for any machine that had
        # `gh` at all.
        if ($LASTEXITCODE -eq 0) {
            $checks += [pscustomobject]@{ Check = "GitHub auth"; Status = "ok"; Detail = "gh auth status succeeded" }
        } else {
            $checks += [pscustomobject]@{ Check = "GitHub auth"; Status = "failed"; Detail = "gh auth status exited $LASTEXITCODE; run 'gh auth login'" }
        }
    } catch {
        $checks += [pscustomobject]@{ Check = "GitHub auth"; Status = "failed"; Detail = $_.Exception.Message }
    }

    try {
        $checks += Get-GitHubPushAccessCheck -Repository $repo
    } catch {
        $checks += [pscustomobject]@{ Check = "GitHub push"; Status = "unknown"; Detail = $_.Exception.Message }
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

    $logPath = Get-AcaLogPathStatus -WorkspaceName $config.logAnalyticsWorkspace
    $checks += [pscustomobject]@{ Check = "Logs path"; Status = $logPath.Status; Detail = $logPath.Detail }
    $checks += [pscustomobject]@{ Check = "Aspire URL"; Status = if ($config.aspireLoginUrl) { "ok" } else { "missing" }; Detail = if ($config.aspireLoginUrl) { $config.aspireLoginUrl } else { "Run deploy or squad-aca configure --dashboard-url" } }
    # Same width rule as `sessions`: Detail carries free-form text (an Aspire
    # login URL, a resource-group/job pair) that runs well past a narrow
    # console, and Format-Table drops trailing columns that do not fit.
    $checks |
        Format-Table -AutoSize |
        Out-String -Width 200 |
        ForEach-Object { $_.TrimEnd() } |
        Write-Output
}

function Get-SessionExecutions {
    <#
    .SYNOPSIS
        Recent session executions as provider records (opaque Handle + Display).

    .DESCRIPTION
        Callers use $record.Handle for every lifecycle operation and
        $record.Display purely for rendering. Nothing here knows the handle is
        an ACA Job execution name.

        ACA Jobs are listed unconditionally and FIRST, so the flag-off path makes
        exactly the calls it always made, in the same order. With the sandbox
        plane switched on, live sandboxes are appended: a session dispatched to a
        sandbox that `sessions` could not see is a session `logs` and `stop`
        could not address either, since both resolve through this list.
    #>
    param([object]$Config, [int]$Limit = 10)
    $records = @(Get-SquadExecutionList -Provider (New-SessionExecutionProvider -Config $Config) -Limit $Limit)
    if (Test-SquadSandboxEnabled -Config $Config) {
        $sandbox = New-SessionSandboxOperationsProvider -Config $Config
        if ($sandbox) { $records += @(Get-SquadExecutionList -Provider $sandbox -Limit $Limit) }
    }
    return $records
}

function Test-SessionSandboxRecord {
    param([object]$Record)
    if (-not $Record -or -not $Record.Display) { return $false }
    return ($Record.Display.PSObject.Properties.Name -contains "Sandbox")
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
    <#
    .DESCRIPTION
        A caller may address an execution by session name, by substrate
        execution/sandbox name, or by the OPAQUE HANDLE the `--json` contract
        hands back. The handle branch is first and deliberately does not list
        anything: a handle already names the provider that minted it, so
        resolving it means decoding it, not searching for it. That is also what
        keeps `stop <handle>` from re-answering today's routing question about
        yesterday's session.
    #>
    param([object]$Config, [string]$Session)
    if ($Session -and (Test-SquadExecutionHandleString -Handle $Session)) {
        return Get-SquadExecutionStatus `
            -Provider (New-SessionExecutionProviderForHandle -Config $Config -Handle $Session) `
            -Handle $Session
    }
    if (-not $Session) {
        $latest = Get-SessionExecutions -Config $Config -Limit 1
        if ($latest) { return $latest[0] }
        throw "No session executions found."
    }
    $items = Get-SessionExecutions -Config $Config -Limit 50
    # Sandbox records name the substrate object `Sandbox`, ACA Job records name
    # it `Execution`. Both are matched so a user identifies a session the same
    # way whichever plane it landed on.
    $match = $items | Where-Object {
        $_.Display.Execution -eq $Session -or $_.Display.Session -eq $Session -or $_.Display.Sandbox -eq $Session
    } | Select-Object -First 1
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
    $json = Has-Option $Items @("--json")
    $session = Get-OptionValue $Items @("--session", "-Session")

    # --session addresses ONE execution. With a handle it is a direct, provider-
    # scoped status call (Resolve-SessionExecution decodes rather than searches),
    # which is what an agent adapter polls with. It is only meaningful alongside
    # --json today; the human table is unchanged and unreachable from here.
    if ($session) {
        if (-not $json) { throw "Usage: squad-aca sessions --session <handle-or-name> --json" }
        $record = Resolve-SessionExecution -Config $config -Session $session
        Write-SquadJsonDocument ([pscustomobject]([ordered]@{
            schema   = $script:SquadJsonSessionsSchema
            sessions = @((ConvertTo-SquadSessionJson -Record $record))
        }))
        return
    }

    $records = @(Get-SessionExecutions -Config $config -Limit $limit)

    if ($json) {
        Write-SquadJsonDocument ([pscustomobject]([ordered]@{
            schema   = $script:SquadJsonSessionsSchema
            sessions = @($records | ForEach-Object { ConvertTo-SquadSessionJson -Record $_ })
        }))
        return
    }

    # Out-String -Width pins the render width instead of inheriting the host's
    # console width. Sprint 6 appends Route and Source, which pushes the table
    # past the default 120 columns -- and Format-Table silently DROPS trailing
    # columns that do not fit, so the two values this sprint exists to surface
    # would vanish on a narrow terminal. Pinning the width also removes the last
    # implicit host dependency from this golden (docs/validation.md, "What makes
    # a golden portable").
    $records |
        Where-Object { -not (Test-SessionSandboxRecord -Record $_) } |
        ForEach-Object { $_.Display } |
        Format-Table -AutoSize |
        Out-String -Width 200 |
        ForEach-Object { $_.TrimEnd() } |
        Write-Output

    # Sandbox records carry a different, smaller column set (Sandbox, Status,
    # Session, Class, Phase, ExitCode, Inconclusive), so they get their own
    # table: Format-Table renders one shape and would blank every column the
    # first row did not have. This block emits nothing at all unless a sandbox
    # execution exists, which cannot happen with the feature flag off -- that is
    # what keeps the `sessions` golden byte-identical.
    $sandboxRecords = @($records | Where-Object { Test-SessionSandboxRecord -Record $_ })
    if ($sandboxRecords.Count -gt 0) {
        Write-Output ""
        Write-Output "Route: sandbox (ACA Sandboxes)"
        $sandboxRecords |
            ForEach-Object { $_.Display } |
            Format-Table -AutoSize |
            Out-String -Width 200 |
            ForEach-Object { $_.TrimEnd() } |
            Write-Output
    }
}

function Invoke-Logs {
    param([string[]]$Items)
    $config = Assert-AcaConfigured
    $session = Get-FirstPositional $Items @("--tail", "-Tail")
    $tail = [int](Get-OptionValue $Items @("--tail", "-Tail") "100")
    $execution = Resolve-SessionExecution -Config $config -Session $session
    # The provider owns *how* logs are fetched (issue #13: Get-AcaExecutionLog
    # inspects every az exit code and throws when both the containerapp-extension
    # path and the Log Analytics fallback fail, so a run that produced no logs
    # can never exit 0). This function owns only presentation.
    $result = Get-SquadExecutionLog `
        -Provider (New-SessionExecutionProviderForHandle -Config $config -Handle $execution.Handle) `
        -Handle $execution.Handle `
        -Tail $tail
    if ($result.Notice) { Write-Host $result.Notice }
    $lines = @($result.Lines)
    if ($lines.Count -eq 0) {
        Write-Warning "No log rows returned for execution '$($execution.Display.Execution)'. Log Analytics ingestion can lag several minutes after a session starts."
    }
    foreach ($line in $lines) { Write-Output $line }
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
    if ($execution.Display.Repository -and $execution.Display.Branch) {
        $prs = gh pr list --repo $execution.Display.Repository --head $execution.Display.Branch --json url --limit 1 2>$null | ConvertFrom-Json
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
    # cancel, not terminate: `stop` keeps the substrate's own result and output
    # verbatim, including failures. The idempotent teardown lives on the
    # provider's terminate operation and is deliberately not wired here.
    #
    # The provider comes from the HANDLE, so a sandbox session is stopped on the
    # sandbox plane and an ACA Job execution on the Jobs plane -- whatever
    # today's manifest, catalog or flag would resolve to.
    Stop-SquadExecution `
        -Provider (New-SessionExecutionProviderForHandle -Config $config -Handle $execution.Handle) `
        -Handle $execution.Handle
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

            # Watch is a long-lived dispatcher, so its lease covers the watcher
            # itself: the same decision code the CLI and Ralph use resolves the
            # route, and the lease is written BEFORE `az containerapp app update`
            # requests compute. A watcher that is already running holds an active
            # lease, which is what makes a second `watch start` a no-op instead of
            # a second dispatcher racing the first.
            $session = "watch"
            $decision = Get-SquadDispatchDecision -SessionId $session -DispatchSource "watch" -Repository $repo
            $claim = New-SquadDispatchLease -Decision $decision -Repository $repo
            # Same fail-closed rule as Start-LeasedExecution: only `created` and
            # `repaired` mean this process owns the watcher.
            if ($claim.outcome -ne "created" -and $claim.outcome -ne "repaired") {
                Write-Warning ("Watch already holds lease '$($decision.leaseKey)' (state $($claim.lease.state), started $($claim.lease.startedAt)). " +
                    "Run 'squad-aca leases' to inspect it, or 'squad-aca watch stop' first.")
                return
            }
            try {
                & (Join-Path $ScriptDir "start-watch.ps1") -ResourceGroupName $config.resourceGroup -WatchAppName $config.watchApp -Repository $repo -Ref $ref -SubSquad $subSquad -DispatchRoute ([string]$decision.routing.route) -LeaseKey ([string]$decision.leaseKey)
            } catch {
                Set-SquadDispatchLeaseState -Operation "release" -Repository $repo -LeaseKey ([string]$decision.leaseKey) -Reason "watch-start-failed" | Out-Null
                throw
            }
            # The watcher is live: recording `dispatched` must not throw to the
            # user (a retry would then race its own live watcher) and must not
            # release. See the identical guard in Start-LeasedExecution.
            try {
                Set-SquadDispatchLeaseState -Operation "dispatched" -Repository $repo -LeaseKey ([string]$decision.leaseKey) | Out-Null
            } catch {
                Write-Warning ("Started the watcher but could not record the lease as dispatched: $($_.Exception.Message)")
            }
        }
        "stop" {
            $repo = Get-OptionValue $Items @("--repo", "-Repository") (Get-CurrentRepo)
            if (-not $repo) { $repo = "unused/unused" }
            & (Join-Path $ScriptDir "start-watch.ps1") -ResourceGroupName $config.resourceGroup -WatchAppName $config.watchApp -Repository $repo -Stop
            if ($repo -ne "unused/unused") {
                $decision = Get-SquadDispatchDecision -SessionId "watch" -DispatchSource "watch" -Repository $repo
                Set-SquadDispatchLeaseState -Operation "complete" -Repository $repo -LeaseKey ([string]$decision.leaseKey) -State "cancelled" -Reason "watch-stopped" | Out-Null
            }
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
            # Dispatch as a single, self-contained execution override so the
            # shared Ralph job template is never mutated (no stale leak, no race).
            # Unlike a fresh worker session, a manual Ralph run must INHERIT the
            # template's Ralph config and secret refs (SQUAD_MODE=ralph,
            # RALPH_LABELS, RALPH_MAX_ISSUES, tokens, Azure fields, Aspire
            # endpoints). New-RalphRunEnvVars preserves them and overlays only the
            # optional repository/run-identity values.
            $envVars = New-RalphRunEnvVars -JobName $config.ralphJob -ResourceGroupName $config.resourceGroup -Repository $repo
            # ACA only applies the per-execution --env-vars override reliably when
            # the start call also supplies the stored image and resources. Read
            # them from the immutable template and echo them back; this does not
            # mutate the shared template.
            $containerOptions = Get-JobStartContainerOptions -JobName $config.ralphJob -ResourceGroupName $config.resourceGroup
            $startArgs = @(
                "containerapp", "job", "start",
                "--name", $config.ralphJob,
                "--resource-group", $config.resourceGroup,
                "--image", $containerOptions.Image,
                "--cpu", $containerOptions.Cpu,
                "--memory", $containerOptions.Memory,
                "--container-name", $containerOptions.ContainerName,
                "--env-vars"
            ) + $envVars
            az @startArgs
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
    $currentRepo = Get-CurrentRepo
    $repo = Get-OptionValue $Items @("--repo", "-Repository") $currentRepo
    if (-not $repo) { throw "No GitHub repo detected. Pass --repo <owner/repo>." }
    $request = New-SquadDispatchRequest `
        -SessionId "telemetry-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
        -DispatchSource "local-cli" `
        -Repository $repo `
        -Mode "telemetry-smoke"
    Start-LeasedExecution -Config $config -Request $request `
        -ManifestSource (Get-CapabilityManifestSource -Repository $repo -CurrentRepository $currentRepo)
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
    "leases" { Invoke-Leases $Arguments }
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
        $currentRepo = Get-CurrentRepo
        $repo = Get-OptionValue $Arguments @("--repo", "-Repository") $currentRepo
        if (-not $repo) { throw "No GitHub repo detected. Pass --repo <owner/repo>." }
        $request = New-SquadDispatchRequest `
            -SessionId "smoke-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
            -DispatchSource "local-cli" `
            -Repository $repo `
            -Mode "smoke" `
            -RunCopilotSmoke $true
        Start-LeasedExecution -Config $config -Request $request `
            -ManifestSource (Get-CapabilityManifestSource -Repository $repo -CurrentRepository $currentRepo)
    }
    "status" {
        $config = Assert-AcaConfigured
        & (Join-Path $ScriptDir "show-status.ps1") -ResourceGroupName $config.resourceGroup -JobName $config.sessionJob -RalphJobName $config.ralphJob -WatchAppName $config.watchApp -Json:(Has-Option $Arguments @("--json"))
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
