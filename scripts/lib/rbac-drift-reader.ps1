# CV-1 (issue #85) -- live RBAC drift reader.
#
# THIS IS THE ONLY FILE IN THE RBAC DRIFT CHECK PERMITTED TO INVOKE `az`, and
# every invocation goes through the single chokepoint below, Invoke-AzRead.
# scripts/lib/rbac-drift-compare.ps1 is pure (snapshot in, findings out) and
# contains no reference to the Azure CLI at all; scripts/validate.ps1 asserts
# both of those things statically AND exercises Invoke-AzRead's allowlist at
# runtime, so read-only survives a future edit by failing the build rather than
# by convention (security's CV-1 contract, decisions/inbox).
#
# Five rules this file exists to enforce, all from the binding contract:
#
#   1. Invoke-AzRead validates argv against a READ-VERB ALLOWLIST and throws on
#      anything else -- a mutating verb, an unrecognised command shape, or a
#      call missing an explicit --subscription.
#   2. `--include-inherited` is BANNED. Measured live: a scope-anchored list
#      with it included returns dozens of platform/tenant rows a deployment of
#      this shape neither owns nor can remove -- the check nobody keeps
#      switched on. This file anchors on the deployment's own PRINCIPALS
#      (`role assignment list --assignee <id> --all`) and only uses a bounded
#      scope-anchored list (inheritance excluded) to catch an unexpected
#      principal at a resource this deployment owns.
#   3. `az account set` is banned alongside the mutating verbs. Every read pins
#      --subscription explicitly instead, so this file never rewrites the
#      caller's CLI context.
#   4. Redaction happens AT CAPTURE TIME. Subscription, tenant, principal,
#      client and role-assignment identifiers are aliased the moment they are
#      read out of `az` JSON -- before they are stored on any object that
#      becomes part of the returned snapshot -- so a live capture is always
#      safe to print or attach as evidence. The alias map lives only in the
#      local variable below and is never written to disk or returned.
#   5. Intent (resource group, name prefix, subscription, registry) fails
#      CLOSED. Resolve-RbacDriftIntent never guesses a live value across a
#      subscription boundary; anything it cannot resolve from explicit
#      parameters, the deployment config, or unambiguous single-registry
#      discovery is reported unresolved and the caller (scripts/rbac-drift-
#      check.ps1) exits 2, never 0 and never a silent pass.

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here, matching
# every other dot-sourced lib in this repo (aca-logs.ps1, sync-safety.ps1, ...).

$script:RbacDriftGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# The read-verb allowlist. Each entry is the ordered POSITIONAL command shape
# (the tokens that are not themselves flag values) that Invoke-AzRead accepts.
# Nothing outside this list is a legal call, no matter what flags accompany it.
$script:RbacDriftAllowedShapes = @(
    , @("identity", "show")
    , @("identity", "list")
    , @("role", "assignment", "list")
    , @("role", "definition", "list")
    , @("containerapp", "job", "show")
    , @("acr", "show")
    , @("acr", "list")
    , @("account", "show")
)

# Deny-list scanned across EVERY token (positional or flag value), checked
# BEFORE the allowlist shape match. This is the fail-closed half of the
# contract: an allow-shaped command that also carries a mutating token (for
# example a positional argument that happens to be "delete") is refused rather
# than reasoned about, because reasoning about intent is exactly how a mutating
# call slips through a shape-only allowlist.
$script:RbacDriftDeniedTokens = @(
    "create", "update", "delete", "remove", "set", "assign", "grant", "revoke",
    "start", "stop", "restart", "deploy", "build", "push", "login", "logout",
    "purge", "restore", "rotate-credentials"
)

function New-RbacDriftAliasState {
    <#
    .SYNOPSIS
        A fresh, in-memory-only alias state for one snapshot capture.

    .DESCRIPTION
        Never serialised, never returned from Get-RbacDriftLiveSnapshot, and
        discarded the moment the calling function returns. Read the security
        contract's rule 4 at the top of this file before touching this.
    #>
    return [pscustomobject]@{
        Map      = @{}
        Counters = @{}
    }
}

function Get-RbacDriftAlias {
    <#
    .SYNOPSIS
        Returns a stable, opaque alias for a raw identifier, minting one on
        first sight. The raw value is never written anywhere but this
        in-memory map.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$AliasState,
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowEmptyString()][string]$RawValue
    )
    if (-not $RawValue) { return "" }
    if ($AliasState.Map.ContainsKey($RawValue)) { return $AliasState.Map[$RawValue] }
    if (-not $AliasState.Counters.ContainsKey($Kind)) { $AliasState.Counters[$Kind] = 0 }
    $AliasState.Counters[$Kind] = $AliasState.Counters[$Kind] + 1
    $alias = "$Kind-$($AliasState.Counters[$Kind])"
    $AliasState.Map[$RawValue] = $alias
    return $alias
}

function Test-RbacDriftTextHasGuid {
    <#
    .SYNOPSIS
        True if the text contains anything GUID-shaped. Used only by tests and
        by the entrypoint's own defence-in-depth scan of its rendered output;
        the reader redacts unconditionally regardless of this check.
    #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $false }
    return [regex]::IsMatch($Text, $script:RbacDriftGuidPattern)
}

function Invoke-AzRead {
    <#
    .SYNOPSIS
        The single chokepoint through which this file (and therefore CV-1)
        talks to Azure. Read verbs only, one explicit subscription, no
        inherited-assignment expansion, ever.

    .DESCRIPTION
        Deny-list first: a token that matches a known mutating verb refuses the
        call even if the overall shape looks read-shaped, because an allow-list
        match is a shape test and a positional argument can coincidentally look
        like a shape without being one (a resource literally named "list",
        for example). Only after the deny-list passes is the command matched
        against the read-verb allowlist.

    .PARAMETER AzArgs
        The full argument vector, in order, exactly as it would be passed to
        `az`.

    .OUTPUTS
        [pscustomobject] ExitCode / StdOut / StdErr, the same shape
        scripts/lib/aca-logs.ps1's Invoke-CliSafe returns -- but implemented
        locally (not by dot-sourcing aca-logs.ps1), so this file's claim to be
        the sole `az`-invoking file for CV-1 does not depend on tracing what
        another file's generic process helper happens to be called with.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$AzArgs
    )

    if ($AzArgs -contains "--include-inherited") {
        throw "Invoke-AzRead refuses '--include-inherited': CV-1 anchors on the deployment's own principals, never on inherited scope expansion (security contract, rule 2)."
    }

    if ($AzArgs.Count -ge 2 -and $AzArgs[0] -eq "account" -and $AzArgs[1] -eq "set") {
        throw "Invoke-AzRead refuses 'az account set': a drift check must not rewrite the operator's CLI context (security contract, rule 3)."
    }

    foreach ($token in $AzArgs) {
        foreach ($denied in $script:RbacDriftDeniedTokens) {
            if ($token -eq $denied) {
                throw "Invoke-AzRead refuses argv containing the mutating token '$denied'. CV-1 is read-only; this call was not attempted."
            }
        }
    }

    $positional = @($AzArgs | Where-Object { -not $_.StartsWith("-") })
    $matchedShape = $false
    foreach ($shape in $script:RbacDriftAllowedShapes) {
        if ($positional.Count -ge $shape.Count) {
            $prefix = @($positional[0..($shape.Count - 1)])
            $isMatch = $true
            for ($i = 0; $i -lt $shape.Count; $i++) {
                if ($prefix[$i] -ne $shape[$i]) { $isMatch = $false; break }
            }
            if ($isMatch) { $matchedShape = $true; break }
        }
    }
    if (-not $matchedShape) {
        throw "Invoke-AzRead refuses argv '$($AzArgs -join ' ')': it does not match any entry on the read-verb allowlist. This call was not attempted."
    }

    if (($AzArgs -notcontains "--subscription")) {
        throw "Invoke-AzRead refuses a call with no explicit --subscription (security contract, rule 3: every read pins its subscription)."
    }

    # Optional, test-only observability: append the argv to a log file when the
    # caller asks for one, so a test can assert the EXACT sequence of read
    # calls made (and, just as importantly, that no other call was ever made).
    # Never enabled in production use; scripts/rbac-drift-check.ps1 never sets
    # this variable itself.
    if ($env:SQUAD_RBAC_DRIFT_AZ_LOG) {
        Add-Content -LiteralPath $env:SQUAD_RBAC_DRIFT_AZ_LOG -Value ($AzArgs -join " ")
    }

    return Invoke-RbacDriftProcess -FilePath "az" -Arguments $AzArgs -EnvironmentOverrides @{
        # Disable dynamic extension install so a missing extension is a clean
        # non-zero exit instead of an interactive prompt blocking on stdin --
        # the same reason aca-logs.ps1's Invoke-AzPromptSafe sets this.
        AZURE_EXTENSION_USE_DYNAMIC_INSTALL = "no"
    }
}

function Invoke-RbacDriftProcess {
    <#
    .SYNOPSIS
        Minimal, local process runner: capture stdout, stderr and the real
        exit code. Deliberately duplicated (not shared with aca-logs.ps1) so
        this file's claim to be the only `az`-invoking code for CV-1 is true by
        inspection of this one file, not by tracing a shared helper's callers.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [System.Collections.IDictionary]$EnvironmentOverrides = @{}
    )
    $saved = @{}
    $had = @{}
    foreach ($name in @($EnvironmentOverrides.Keys)) {
        $had[$name] = (Test-Path "Env:$name")
        $saved[$name] = if ($had[$name]) { [Environment]::GetEnvironmentVariable($name, "Process") } else { $null }
    }
    $previousEap = $ErrorActionPreference
    $merged = @()
    $exitCode = -1
    try {
        foreach ($name in @($EnvironmentOverrides.Keys)) {
            [Environment]::SetEnvironmentVariable($name, [string]$EnvironmentOverrides[$name], "Process")
        }
        $ErrorActionPreference = "Continue"
        $merged = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $merged = @($_.Exception.Message)
        $exitCode = 127
    } finally {
        $ErrorActionPreference = $previousEap
        foreach ($name in @($EnvironmentOverrides.Keys)) {
            if ($had[$name]) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
            } else {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }
    $stdout = @()
    $stderr = @()
    foreach ($line in @($merged)) {
        if ($null -eq $line) { continue }
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            $stderr += [string]$line
        } else {
            $stdout += [string]$line
        }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
}

function Get-RbacDriftJson {
    <#
    .SYNOPSIS
        Runs one read through Invoke-AzRead and parses JSON stdout, or returns
        $null on a non-zero exit / empty output.
    #>
    param([Parameter(Mandatory = $true)][string[]]$AzArgs)
    # --only-show-errors keeps stdout to JSON only -- a stray extension-upgrade
    # banner ahead of the JSON payload would otherwise fail ConvertFrom-Json.
    $result = Invoke-AzRead -AzArgs (@($AzArgs) + @("--only-show-errors"))
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Value = $null; Failed = $true; Result = $result }
    }
    $text = (@($result.StdOut) -join "`n").Trim()
    if (-not $text) { return [pscustomobject]@{ Value = $null; Failed = $false; Result = $result } }
    try {
        return [pscustomobject]@{ Value = (ConvertFrom-Json -InputObject $text); Failed = $false; Result = $result }
    } catch {
        return [pscustomobject]@{ Value = $null; Failed = $true; Result = $result }
    }
}

function Resolve-RbacDriftIntent {
    <#
    .SYNOPSIS
        Fails-closed intent resolution (security contract, rule 5 / ruling 2).

    .DESCRIPTION
        Resolution order: explicit parameters, then the deployment config
        (deploy.outputs.json, if present and readable), then -- for the
        registry only, since it is the one value deploy.ps1 does not derive
        deterministically from a name prefix -- unambiguous discovery within
        the resource group, performed by the CALLER (scripts/rbac-drift-
        check.ps1) after this function reports the registry unresolved, since
        discovery itself requires a live read.

        Resource group and name prefix fall back to deploy.ps1's OWN
        documented defaults ("rg-squad-aca-dev-eastus2" / "squad-aca") when
        neither a parameter nor the deployment config supplies one -- the same
        default deploy.ps1 itself would have used, not a guess across
        environments. Subscription and registry get NO such default: deploy.ps1
        does not default either of them, and guessing a subscription is
        exactly the failure this rule exists to prevent.

    .OUTPUTS
        [pscustomobject] with ResourceGroup, NamePrefix, SubscriptionId,
        AcrName (may be empty -- caller resolves via discovery), 
        GitHubActionsIdentityName, SessionIdentityName, SessionJobName, and
        Missing (array of human-readable unresolved-field names; empty means
        every REQUIRED field resolved -- AcrName is allowed to be empty here).
    #>
    param(
        [string]$ResourceGroupName = "",
        [string]$NamePrefix = "",
        [string]$SubscriptionId = "",
        [string]$AcrName = "",
        [string]$GitHubActionsIdentityName = "",
        [object]$DeployOutputs = $null
    )

    $resourceGroup = $ResourceGroupName
    if (-not $resourceGroup -and $DeployOutputs -and $DeployOutputs.PSObject.Properties.Name -contains "resourceGroup" -and $DeployOutputs.resourceGroup) {
        $resourceGroup = [string]$DeployOutputs.resourceGroup
    }
    if (-not $resourceGroup) { $resourceGroup = "rg-squad-aca-dev-eastus2" }

    $namePrefix = $NamePrefix
    if (-not $namePrefix -and $DeployOutputs -and $DeployOutputs.PSObject.Properties.Name -contains "pullIdentity" -and $DeployOutputs.pullIdentity -match '^uai-(.+)-acrpull$') {
        $namePrefix = $Matches[1]
    }
    if (-not $namePrefix) { $namePrefix = "squad-aca" }

    $subscriptionId = $SubscriptionId
    if (-not $subscriptionId -and $DeployOutputs -and $DeployOutputs.PSObject.Properties.Name -contains "subscriptionId" -and $DeployOutputs.subscriptionId) {
        $subscriptionId = [string]$DeployOutputs.subscriptionId
    }

    $acrName = $AcrName
    if (-not $acrName -and $DeployOutputs -and $DeployOutputs.PSObject.Properties.Name -contains "acrName" -and $DeployOutputs.acrName) {
        $acrName = [string]$DeployOutputs.acrName
    }

    $ghaIdentityName = $GitHubActionsIdentityName
    if (-not $ghaIdentityName) { $ghaIdentityName = "uai-$namePrefix-gha" }

    $missing = @()
    if (-not $resourceGroup) { $missing += "resource group" }
    if (-not $subscriptionId) { $missing += "subscription" }

    return [pscustomobject]@{
        ResourceGroup             = $resourceGroup
        NamePrefix                = $namePrefix
        SubscriptionId            = $subscriptionId
        AcrName                   = $acrName
        GitHubActionsIdentityName = $ghaIdentityName
        SessionIdentityName       = "uai-$namePrefix-acrpull"
        SessionJobName            = "caj-$namePrefix-session"
        Missing                   = $missing
    }
}

function Get-RbacDriftDiscoveredRegistry {
    <#
    .SYNOPSIS
        Unambiguous single-registry discovery within a resource group (the
        last resolution step for AcrName). Returns the list of registry names
        found; the caller (scripts/rbac-drift-check.ps1) decides that exactly
        one is required and fails closed (exit 2) otherwise -- this function
        never picks a registry itself.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$SubscriptionId
    )
    $listed = Get-RbacDriftJson -AzArgs @(
        "acr", "list",
        "--resource-group", $ResourceGroup,
        "--subscription", $SubscriptionId,
        "--query", "[].name",
        "-o", "json"
    )
    if ($listed.Failed -or -not $listed.Value) { return @() }
    return @($listed.Value)
}

function Get-RbacDriftScopeType {
    <#
    .SYNOPSIS
        Classifies a raw ARM scope id against the deployment's own resource
        ids, without ever storing the raw id anywhere but this call frame.
    #>
    param(
        [string]$ScopeId,
        [string]$RegistryScopeId,
        [string]$JobScopeId,
        [string]$ResourceGroupScopeId
    )
    if (-not $ScopeId) { return "unknown" }
    if ($RegistryScopeId -and $ScopeId -eq $RegistryScopeId) { return "registry" }
    if ($JobScopeId -and $ScopeId -eq $JobScopeId) { return "sessionJob" }
    if ($ResourceGroupScopeId -and $ScopeId -eq $ResourceGroupScopeId) { return "resourceGroup" }
    if ($ScopeId -match '^/subscriptions/[^/]+$') { return "subscription" }
    if ($ScopeId -match '/providers/Microsoft\.Management/managementGroups/') { return "managementGroup" }
    return "other"
}

function ConvertTo-RbacDriftPrincipalAssignments {
    <#
    .SYNOPSIS
        Reads every role assignment a principal holds, ANY scope
        (`--assignee <id> --all`, never --include-inherited), classifies each
        scope against the deployment's own resource ids, and aliases every
        identifier the moment it is read -- before anything is stored on the
        object this function returns.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$AliasState,
        [Parameter(Mandatory = $true)][string]$PrincipalId,
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [string]$RegistryScopeId = "",
        [string]$JobScopeId = "",
        [string]$ResourceGroupScopeId = ""
    )
    $listed = Get-RbacDriftJson -AzArgs @(
        "role", "assignment", "list",
        "--assignee", $PrincipalId,
        "--all",
        "--subscription", $SubscriptionId,
        "-o", "json"
    )
    if ($listed.Failed) {
        throw "Could not read role assignments for this principal (az role assignment list --all failed)."
    }
    $assignments = @()
    foreach ($raw in @($listed.Value)) {
        if (-not $raw) { continue }
        $scopeType = Get-RbacDriftScopeType -ScopeId ([string]$raw.scope) -RegistryScopeId $RegistryScopeId -JobScopeId $JobScopeId -ResourceGroupScopeId $ResourceGroupScopeId
        $assignmentAlias = Get-RbacDriftAlias -AliasState $AliasState -Kind "ASSIGN" -RawValue ([string]$raw.name)
        $assignments += [pscustomobject]@{
            roleName        = [string]$raw.roleDefinitionName
            scopeType       = $scopeType
            scopeAlias      = Get-RbacDriftAlias -AliasState $AliasState -Kind "SCOPE" -RawValue ([string]$raw.scope)
            assignmentAlias = $assignmentAlias
        }
    }
    return $assignments
}

function Get-RbacDriftScopedAssignments {
    <#
    .SYNOPSIS
        Layer 2 of the contract: lists assignments AT one exact resource scope
        the deployment creates, --include-inherited deliberately absent, to
        catch an unexpected principal at a resource this deployment owns. Never
        used to enumerate the deployment's own principals' holdings (that is
        Layer 1, ConvertTo-RbacDriftPrincipalAssignments) -- only to notice
        someone else's grant at a scope this deployment is responsible for.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$AliasState,
        [Parameter(Mandatory = $true)][string]$ScopeId,
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [hashtable]$PrincipalIdToAlias = @{}
    )
    $listed = Get-RbacDriftJson -AzArgs @(
        "role", "assignment", "list",
        "--scope", $ScopeId,
        "--subscription", $SubscriptionId,
        "-o", "json"
    )
    if ($listed.Failed) {
        throw "Could not read role assignments at scope (az role assignment list --scope failed)."
    }
    $entries = @()
    foreach ($raw in @($listed.Value)) {
        if (-not $raw) { continue }
        $principalId = [string]$raw.principalId
        $principalAlias = if ($PrincipalIdToAlias.ContainsKey($principalId)) {
            $PrincipalIdToAlias[$principalId]
        } else {
            Get-RbacDriftAlias -AliasState $AliasState -Kind "PRINCIPAL" -RawValue $principalId
        }
        $entries += [pscustomobject]@{
            principalAlias  = $principalAlias
            roleName        = [string]$raw.roleDefinitionName
            assignmentAlias = Get-RbacDriftAlias -AliasState $AliasState -Kind "ASSIGN" -RawValue ([string]$raw.name)
        }
    }
    return $entries
}

function Get-RbacDriftLiveSnapshot {
    <#
    .SYNOPSIS
        Captures one fully redacted snapshot of the deployment's principals and
        their live role assignments, plus the bounded scope-anchored view.
        Every identifier is aliased before this function constructs the object
        it returns; the alias map itself never leaves this call.

    .PARAMETER Intent
        Resolve-RbacDriftIntent's output, with AcrName already resolved (the
        caller performs discovery, if needed, before calling this).

    .OUTPUTS
        [pscustomobject] matching the schema
        scripts/tests/fixtures/rbac-drift/*.json fixtures use, so the SAME
        comparer (scripts/lib/rbac-drift-compare.ps1) runs against either a
        live snapshot or a committed fixture with no code path difference.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Intent
    )

    $aliasState = New-RbacDriftAliasState
    $sub = $Intent.SubscriptionId

    $accountShown = Get-RbacDriftJson -AzArgs @("account", "show", "--subscription", $sub, "-o", "json")
    if ($accountShown.Failed -or -not $accountShown.Value) {
        throw "Could not confirm the target subscription is reachable ('az account show --subscription <id>' failed). CV-1 stops here rather than silently checking the wrong subscription."
    }

    $resourceGroupScopeId = "/subscriptions/$sub/resourceGroups/$($Intent.ResourceGroup)"

    $registryScopeId = ""
    if ($Intent.AcrName) {
        $acrShown = Get-RbacDriftJson -AzArgs @("acr", "show", "--name", $Intent.AcrName, "--resource-group", $Intent.ResourceGroup, "--subscription", $sub, "--query", "id", "-o", "json")
        if ($acrShown.Failed -or -not $acrShown.Value) {
            throw "Could not read the registry '$($Intent.AcrName)' in resource group '$($Intent.ResourceGroup)' ('az acr show' failed)."
        }
        $registryScopeId = [string]$acrShown.Value
    }

    $jobShown = Get-RbacDriftJson -AzArgs @("containerapp", "job", "show", "--name", $Intent.SessionJobName, "--resource-group", $Intent.ResourceGroup, "--subscription", $sub, "--query", "id", "-o", "json")
    if ($jobShown.Failed -or -not $jobShown.Value) {
        throw "Could not read the session job '$($Intent.SessionJobName)' in resource group '$($Intent.ResourceGroup)' ('az containerapp job show' failed)."
    }
    $jobScopeId = [string]$jobShown.Value

    $sessionIdentityShown = Get-RbacDriftJson -AzArgs @("identity", "show", "--name", $Intent.SessionIdentityName, "--resource-group", $Intent.ResourceGroup, "--subscription", $sub, "-o", "json")
    if ($sessionIdentityShown.Failed -or -not $sessionIdentityShown.Value) {
        throw "Could not read the session identity '$($Intent.SessionIdentityName)' in resource group '$($Intent.ResourceGroup)' ('az identity show' failed)."
    }
    $sessionPrincipalId = [string]$sessionIdentityShown.Value.principalId
    $sessionPrincipalAlias = Get-RbacDriftAlias -AliasState $aliasState -Kind "PRINCIPAL" -RawValue $sessionPrincipalId
    $sessionClientAlias = Get-RbacDriftAlias -AliasState $aliasState -Kind "CLIENT" -RawValue ([string]$sessionIdentityShown.Value.clientId)

    $sessionAssignments = ConvertTo-RbacDriftPrincipalAssignments -AliasState $aliasState -PrincipalId $sessionPrincipalId -SubscriptionId $sub `
        -RegistryScopeId $registryScopeId -JobScopeId $jobScopeId -ResourceGroupScopeId $resourceGroupScopeId

    $principals = @(
        [pscustomobject]@{
            role           = "session"
            present        = $true
            principalAlias = $sessionPrincipalAlias
            clientAlias    = $sessionClientAlias
            assignments    = $sessionAssignments
        }
    )

    $principalIdToAlias = @{ $sessionPrincipalId = $sessionPrincipalAlias }

    # Absent optional identity (security contract, rule 5 / ruling 1): the
    # GitHub Actions federated identity may legitimately not exist. `identity
    # show` on a missing identity is a normal non-zero exit -- not a thrown
    # error -- and is reported as a distinct principal entry with present =
    # $false, never merged into the "ok" case.
    $ghaShown = Get-RbacDriftJson -AzArgs @("identity", "show", "--name", $Intent.GitHubActionsIdentityName, "--resource-group", $Intent.ResourceGroup, "--subscription", $sub, "-o", "json")
    if (-not $ghaShown.Failed -and $ghaShown.Value -and $ghaShown.Value.principalId) {
        $ghaPrincipalId = [string]$ghaShown.Value.principalId
        $ghaPrincipalAlias = Get-RbacDriftAlias -AliasState $aliasState -Kind "PRINCIPAL" -RawValue $ghaPrincipalId
        $ghaClientAlias = Get-RbacDriftAlias -AliasState $aliasState -Kind "CLIENT" -RawValue ([string]$ghaShown.Value.clientId)
        $ghaAssignments = ConvertTo-RbacDriftPrincipalAssignments -AliasState $aliasState -PrincipalId $ghaPrincipalId -SubscriptionId $sub `
            -RegistryScopeId $registryScopeId -JobScopeId $jobScopeId -ResourceGroupScopeId $resourceGroupScopeId
        $principals += [pscustomobject]@{
            role           = "githubActions"
            present        = $true
            principalAlias = $ghaPrincipalAlias
            clientAlias    = $ghaClientAlias
            assignments    = $ghaAssignments
        }
        $principalIdToAlias[$ghaPrincipalId] = $ghaPrincipalAlias
    } else {
        $principals += [pscustomobject]@{
            role           = "githubActions"
            present        = $false
            principalAlias = ""
            clientAlias    = ""
            assignments    = @()
        }
    }

    $scopedAssignments = [ordered]@{}
    if ($registryScopeId) {
        $scopedAssignments["registry"] = @(Get-RbacDriftScopedAssignments -AliasState $aliasState -ScopeId $registryScopeId -SubscriptionId $sub -PrincipalIdToAlias $principalIdToAlias)
    } else {
        $scopedAssignments["registry"] = @()
    }
    $scopedAssignments["sessionJob"] = @(Get-RbacDriftScopedAssignments -AliasState $aliasState -ScopeId $jobScopeId -SubscriptionId $sub -PrincipalIdToAlias $principalIdToAlias)

    return [pscustomobject]@{
        schema             = "squad-aca/rbac-drift-snapshot@1"
        capturedAt         = (Get-Date).ToUniversalTime().ToString("o")
        principals         = $principals
        scopedAssignments  = [pscustomobject]$scopedAssignments
    }
}
