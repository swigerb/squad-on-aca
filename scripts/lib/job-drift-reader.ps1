# CV-2 (issue #85) -- live job/environment drift reader.
#
# THIS IS THE ONLY FILE IN THE JOB DRIFT CHECK PERMITTED TO INVOKE `az`, and
# every invocation goes through the single chokepoint below, Invoke-JobAzRead
# -- the same shape as scripts/lib/rbac-drift-reader.ps1's Invoke-AzRead, kept
# as an independent copy (not a shared helper) so this file's claim to be the
# sole `az`-invoking file for CV-2 is true by inspection of this one file.
# scripts/lib/job-drift-compare.ps1 is pure (snapshot in, findings out) and
# contains no reference to the Azure CLI at all; scripts/validate.ps1 asserts
# both of those things statically AND exercises Invoke-JobAzRead's allowlist
# at runtime.
#
# Rules this file exists to enforce (CV-2, mirroring CV-1's contract):
#
#   1. Invoke-JobAzRead validates argv against a READ-VERB ALLOWLIST and
#      throws on anything else -- a mutating verb, an unrecognised command
#      shape, or a call missing an explicit --subscription.
#   2. `az account set` is banned alongside the mutating verbs. Every read
#      pins --subscription explicitly instead.
#   3. Secret VALUES are never read. `az containerapp job show` returns
#      secret metadata (name only) and env-var entries that are either a
#      literal `.value` or a `.secretRef` name -- never the secret's actual
#      contents -- so nothing here ever has a live credential to redact in
#      the first place. Redaction still applies to identifiers: subscription,
#      tenant, principal and resource-id substrings are aliased at capture
#      time, matching CV-1's rule 4.
#   4. Intent (resource group, name prefix, subscription, expected image)
#      fails CLOSED, reusing the same defaults and resolution order as
#      scripts/lib/rbac-drift-reader.ps1's Resolve-RbacDriftIntent so the two
#      checks never disagree about which deployment they are looking at.

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here, matching
# every other dot-sourced lib in this repo.

$script:JobDriftGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

$script:JobDriftAllowedShapes = @(
    , @("containerapp", "job", "show")
    , @("identity", "show")
    , @("account", "show")
)

$script:JobDriftDeniedTokens = @(
    "create", "update", "delete", "remove", "set", "assign", "grant", "revoke",
    "start", "stop", "restart", "deploy", "build", "push", "login", "logout",
    "purge", "restore", "rotate-credentials", "secret"
)

function New-JobDriftAliasState {
    <#
    .SYNOPSIS
        A fresh, in-memory-only alias state for one snapshot capture --
        mirrors New-RbacDriftAliasState in rbac-drift-reader.ps1.
    #>
    return [pscustomobject]@{ Map = @{}; Counters = @{} }
}

function Get-JobDriftAlias {
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

function Invoke-JobAzRead {
    <#
    .SYNOPSIS
        The single chokepoint through which this file (and therefore CV-2)
        talks to Azure. Read verbs only, one explicit subscription.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$AzArgs
    )

    if ($AzArgs.Count -ge 2 -and $AzArgs[0] -eq "account" -and $AzArgs[1] -eq "set") {
        throw "Invoke-JobAzRead refuses 'az account set': a drift check must not rewrite the operator's CLI context."
    }

    foreach ($token in $AzArgs) {
        foreach ($denied in $script:JobDriftDeniedTokens) {
            if ($token -eq $denied) {
                throw "Invoke-JobAzRead refuses argv containing the mutating/secret-reading token '$denied'. CV-2 is read-only; this call was not attempted."
            }
        }
    }

    $positional = @($AzArgs | Where-Object { -not $_.StartsWith("-") })
    $matchedShape = $false
    foreach ($shape in $script:JobDriftAllowedShapes) {
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
        throw "Invoke-JobAzRead refuses argv '$($AzArgs -join ' ')': it does not match any entry on the read-verb allowlist. This call was not attempted."
    }

    if (($AzArgs -notcontains "--subscription")) {
        throw "Invoke-JobAzRead refuses a call with no explicit --subscription."
    }

    if ($env:SQUAD_JOB_DRIFT_AZ_LOG) {
        Add-Content -LiteralPath $env:SQUAD_JOB_DRIFT_AZ_LOG -Value ($AzArgs -join " ")
    }

    return Invoke-JobDriftProcess -FilePath "az" -Arguments $AzArgs -EnvironmentOverrides @{
        AZURE_EXTENSION_USE_DYNAMIC_INSTALL = "no"
    }
}

function Invoke-JobDriftProcess {
    <#
    .SYNOPSIS
        Minimal, local process runner -- deliberately duplicated (not shared
        with rbac-drift-reader.ps1 or aca-logs.ps1) so this file's claim to be
        the only `az`-invoking code for CV-2 is true by inspection of this
        one file.
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

function Get-JobDriftJson {
    param([Parameter(Mandatory = $true)][string[]]$AzArgs)
    $result = Invoke-JobAzRead -AzArgs (@($AzArgs) + @("--only-show-errors"))
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

function Resolve-JobDriftIntent {
    <#
    .SYNOPSIS
        Fails-closed intent resolution, matching
        scripts/lib/rbac-drift-reader.ps1's Resolve-RbacDriftIntent so CV-1
        and CV-2 resolve the SAME deployment for the same inputs. The one
        addition here is ExpectedImage, which CV-1 never needed: deploy
        .outputs.json's workerImage is the one place deploy.ps1 records the
        image it most recently intended for this job, so an unresolved image
        fails closed exactly like an unresolved subscription does.

    .OUTPUTS
        [pscustomobject] with ResourceGroup, NamePrefix, SubscriptionId,
        SessionIdentityName, SessionJobName, ExpectedImage, and Missing
        (array of human-readable unresolved-field names).
    #>
    param(
        [string]$ResourceGroupName = "",
        [string]$NamePrefix = "",
        [string]$SubscriptionId = "",
        [string]$ExpectedImage = "",
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

    $expectedImage = $ExpectedImage
    if (-not $expectedImage -and $DeployOutputs -and $DeployOutputs.PSObject.Properties.Name -contains "workerImage" -and $DeployOutputs.workerImage) {
        $expectedImage = [string]$DeployOutputs.workerImage
    }

    $missing = @()
    if (-not $resourceGroup) { $missing += "resource group" }
    if (-not $subscriptionId) { $missing += "subscription" }
    if (-not $expectedImage) { $missing += "expected image (deploy.outputs.json workerImage, or -ExpectedImage)" }

    return [pscustomobject]@{
        ResourceGroup       = $resourceGroup
        NamePrefix          = $namePrefix
        SubscriptionId      = $subscriptionId
        ExpectedImage       = $expectedImage
        SessionIdentityName = "uai-$namePrefix-acrpull"
        SessionJobName      = "caj-$namePrefix-session"
        Missing             = $missing
    }
}

function Get-JobDriftLiveSnapshot {
    <#
    .SYNOPSIS
        Captures one fully redacted snapshot of the deployed session job's
        image, environment variables, and attached identities.

    .OUTPUTS
        [pscustomobject] matching the schema
        scripts/tests/fixtures/job-drift/*.json fixtures use, so the SAME
        comparer (scripts/lib/job-drift-compare.ps1) runs against either a
        live snapshot or a committed fixture with no code path difference.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Intent
    )

    $aliasState = New-JobDriftAliasState
    $sub = $Intent.SubscriptionId

    $accountShown = Get-JobDriftJson -AzArgs @("account", "show", "--subscription", $sub, "-o", "json")
    if ($accountShown.Failed -or -not $accountShown.Value) {
        throw "Could not confirm the target subscription is reachable ('az account show --subscription <id>' failed). CV-2 stops here rather than silently checking the wrong subscription."
    }

    $sessionIdentityShown = Get-JobDriftJson -AzArgs @("identity", "show", "--name", $Intent.SessionIdentityName, "--resource-group", $Intent.ResourceGroup, "--subscription", $sub, "--query", "id", "-o", "json")
    if ($sessionIdentityShown.Failed -or -not $sessionIdentityShown.Value) {
        throw "Could not read the session identity '$($Intent.SessionIdentityName)' in resource group '$($Intent.ResourceGroup)' ('az identity show' failed)."
    }
    $expectedSessionIdentityId = [string]$sessionIdentityShown.Value

    $jobShown = Get-JobDriftJson -AzArgs @("containerapp", "job", "show", "--name", $Intent.SessionJobName, "--resource-group", $Intent.ResourceGroup, "--subscription", $sub, "-o", "json")
    if ($jobShown.Failed -or -not $jobShown.Value) {
        throw "Could not read the session job '$($Intent.SessionJobName)' in resource group '$($Intent.ResourceGroup)' ('az containerapp job show' failed)."
    }
    $job = $jobShown.Value

    $image = [string]$job.properties.template.containers[0].image

    $envVars = @()
    foreach ($ev in @($job.properties.template.containers[0].env)) {
        if (-not $ev) { continue }
        $hasValue = [bool]$ev.value
        $hasSecretRef = [bool]$ev.secretRef
        $envVars += [pscustomobject]@{
            name         = [string]$ev.name
            hasValue     = $hasValue
            hasSecretRef = $hasSecretRef
        }
    }

    $identities = @()
    $systemAssignedEnabled = $false
    if ($job.identity) {
        $identityType = [string]$job.identity.type
        if ($identityType -match "SystemAssigned") { $systemAssignedEnabled = $true }
        $userAssigned = $job.identity.userAssignedIdentities
        if ($userAssigned) {
            foreach ($resourceId in @($userAssigned.PSObject.Properties.Name)) {
                $isExpected = ($resourceId -eq $expectedSessionIdentityId)
                $identities += [pscustomobject]@{
                    alias              = Get-JobDriftAlias -AliasState $aliasState -Kind "IDENTITY" -RawValue $resourceId
                    isExpectedSession  = $isExpected
                }
            }
        }
    }

    return [pscustomobject]@{
        schema                = "squad-aca/job-drift-snapshot@1"
        capturedAt            = (Get-Date).ToUniversalTime().ToString("o")
        image                 = $image
        envVars               = $envVars
        identities            = $identities
        systemAssignedEnabled = $systemAssignedEnabled
    }
}
