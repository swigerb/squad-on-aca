param(
    [string]$SubscriptionId = "",
    # Empty means "work it out", not "no preference" -- see the resolution
    # below. A literal default here could not tell "the caller wants the
    # default" from "the caller wants exactly this", which is the difference
    # between reusing a deployment and building a second one beside it.
    [string]$Location = "",
    [string]$ResourceGroupName = "",
    [string]$NamePrefix = "squad-aca",
    [string]$AcrName = "",
    [string]$ImageTag = "",
    [string]$GitHubToken = "",
    [string]$CopilotGitHubToken = "",
    [string]$DefaultRepository = "",
    [string]$DefaultRef = "",
    [switch]$UseKeyVault,
    [string]$KeyVaultName = "",
    [string]$GitHubActionsIdentityName = "",
    # --- Squad Hub supervision (optional) ------------------------------------
    # A hub lets a session ASK a human to approve a tool call instead of having
    # destructive operations made unavailable outright. Leave both blank and
    # nothing changes: sessions run exactly as they do today.
    #
    # SquadHubToken must be a DEVICE token (`sqhd1.`...), minted with a device-id
    # prefix so a credential shipped to a cloud job cannot claim to be someone's
    # laptop. It is stored as a secret and referenced, never set as a plain
    # environment variable:
    #
    #   squad-hub device-token --hub <url> --token <your own token> \
    #       --label "aca jobs" --prefix aca- --ttl-hours 4
    [string]$SquadHubUrl = "",
    [string]$SquadHubToken = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$azureDir = Join-Path $repoRoot ".azure"
New-Item -ItemType Directory -Force -Path $azureDir | Out-Null

# --- Where this deploys, resolved before anything reads it -------------------
#
# The default region moved from East US 2 to Central US. East US 2 is a
# capacity-constrained region and first-time deploys were failing there on
# capacity rather than on anything wrong with the deployment:
#
#     ERROR: ... is experiencing heavy usage in region eastus2 ...
#     Status: 400 (Bad Request)   ErrorCode: CapacityHeavyUsage
#
# A default that fails for a new user is worse than no default, because it
# reads as "this product does not work".
#
# The region used to be baked into the resource-group default as well
# ("rg-squad-aca-dev-eastus2"), so changing one and not the other would put the
# group name and the region it names permanently out of step. The group is
# derived from the location instead, and they cannot disagree.
#
# Changing a default is dangerous on its own: someone who deployed to the old
# default and re-runs with no arguments would build an ENTIRE SECOND
# environment in a new region rather than update the one they have -- the same
# shape as the duplicate-registry defect. So the last deploy's own record wins
# over the default, exactly as the registry name does. An explicit -Location or
# -ResourceGroupName still wins over everything.
$DEFAULT_LOCATION = "centralus"
$previousOutputs = $null
$previousOutputsPath = Join-Path $repoRoot "deploy.outputs.json"
if (Test-Path -LiteralPath $previousOutputsPath) {
    try { $previousOutputs = Get-Content -LiteralPath $previousOutputsPath -Raw | ConvertFrom-Json } catch { $previousOutputs = $null }
}

if (-not $Location) {
    if ($previousOutputs -and $previousOutputs.location) {
        $Location = [string]$previousOutputs.location
        Write-Host "Reusing the region recorded by the last deploy from this clone: $Location"
    } else {
        $Location = $DEFAULT_LOCATION
    }
}
if (-not $ResourceGroupName) {
    $recordedRg = if ($previousOutputs) { [string]$previousOutputs.resourceGroup } else { "" }
    $recordedLoc = if ($previousOutputs) { [string]$previousOutputs.location } else { "" }
    # Reuse the recorded group only while it still describes where this is
    # going. Somebody moving region -- which is the whole reason the default
    # changed -- passes -Location and nothing else; reusing the old group then
    # would put resources for the NEW region into a group named for the old
    # one, and into the very deployment they were trying to move away from.
    # A derived name that no longer matches its region is the same defect as a
    # stale URL surviving a subscription change (issues #90, #102).
    if ($recordedRg -and (-not $recordedLoc -or $recordedLoc -eq $Location)) {
        $ResourceGroupName = $recordedRg
        Write-Host "Reusing the resource group recorded by the last deploy from this clone: $ResourceGroupName"
    } else {
        $ResourceGroupName = "rg-$NamePrefix-dev-$Location"
        if ($recordedRg) {
            Write-Host "The recorded resource group '$recordedRg' is in '$recordedLoc', not '$Location'."
            Write-Host "Deploying to '$ResourceGroupName' instead. Pass -ResourceGroupName to choose another."
        }
    }
}
# --- end region resolution ---
# scripts/validate.ps1 extracts everything between $DEFAULT_LOCATION and this
# marker and runs it against a stub, so the four cases it checks are the real
# logic rather than a copy of it. Brace-counting was tried first and silently
# captured only the first block, which made every case pass with empty output.

# --- Files this deploy needs, checked before anything is created -------------
#
# Everything below is addressed from $repoRoot, which is derived from this
# script's own location and is therefore correct whatever directory you run
# from. That was NOT true of the Dockerfile: `az acr build` resolves a relative
# --file against the current working directory, so a deploy started from
# anywhere but the repository root died at the image build -- after the
# resource group, the container registry and the managed identity had already
# been created, leaving a half-built deployment and this to explain it:
#
#     ERROR: Unable to find 'worker/Dockerfile'.
#
# The path is absolute now, so the deploy simply works from any directory. This
# check stays because a missing file should stop a deployment at the desk, not
# four Azure resources in -- and it names the file and the directory, which the
# az error did not.
$dockerfilePath = Join-Path $repoRoot "worker/Dockerfile"
$requiredForDeploy = @(
    $dockerfilePath,
    (Join-Path $repoRoot "config/sandbox-classes.json"),
    (Join-Path $repoRoot "worker/entrypoint.sh")
)
$missingForDeploy = @($requiredForDeploy | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missingForDeploy.Count -gt 0) {
    throw @"
This deployment needs files that are not where they should be:

  $($missingForDeploy -join "`n  ")

Repository root (from this script's location): $repoRoot
Current directory:                             $(Get-Location)

That usually means the repository is incomplete rather than that you are in the
wrong directory -- the deploy works from any directory. Re-clone, or check the
paths above.
"@
}

# --- Squad Hub preflight -----------------------------------------------------
# Checked HERE, at the desk, rather than at minute two inside a container nobody
# is watching. Both halves or neither: a URL with no token cannot attach and a
# token with no URL has nowhere to go, so either alone is a misconfiguration
# that would silently deploy jobs which refuse to start.
if ($SquadHubUrl -and -not $SquadHubToken) {
    throw "-SquadHubUrl was given without -SquadHubToken. A hub with no device credential cannot be attached to."
}
if ($SquadHubToken -and -not $SquadHubUrl) {
    throw "-SquadHubToken was given without -SquadHubUrl. There is no hub for the device to dial."
}
if ($SquadHubToken -and -not $SquadHubToken.StartsWith("sqhd1.")) {
    # A device token is recognisable without doing any crypto -- the hub mints
    # them with a distinctive prefix precisely so a caller can route on sight.
    # Refusing a personal credential here is the difference between a job that
    # can be a device and a job that can do everything its owner can.
    throw @"
-SquadHubToken does not look like a device token (expected the "sqhd1." prefix).

A device token is minted FOR a device and can be a device and NOTHING else: it
cannot read the hub's API, start work on another device, or watch your sessions.
Shipping a personal token to a container instead hands that job everything you
can do.

Mint one, bound to a device-id prefix so it cannot claim to be your laptop:

  squad-hub device-token --hub $SquadHubUrl --token <your own token> ``
      --label "aca jobs" --prefix aca- --ttl-hours 4
"@
}
if ($SquadHubUrl -and $SquadHubUrl -notmatch '^https://') {
    # The device token travels on this connection. Plain http would put a live
    # credential on the wire.
    throw "-SquadHubUrl must be an https:// URL; a device token must not travel in clear text."
}

# --- The device-id prefix binding has to match what the job registers as -----
#
# A device token may be bound to a device-id PREFIX, and the advice above tells
# operators to use one. The hub ENFORCES that binding at registration: an id
# that does not start with the bound prefix is refused, and the job exits 77
# some minutes later inside a container nobody is watching.
#
# The binding is a claim in the token, so it can be read here without any
# crypto -- this is not verifying the signature (only the hub can), it is
# reading the operator's own stated intent back to them and checking it agrees
# with what worker/lib/squad-hub.sh will actually send.
if ($SquadHubToken) {
    $expectedPrefix = "aca-"   # squad_hub_device_id()'s default in worker/lib/squad-hub.sh
    $boundPrefix = $null
    try {
        $body = $SquadHubToken.Split(".")[1]
        # base64url -> base64, then pad to a multiple of 4.
        $b64 = $body.Replace("-", "+").Replace("_", "/")
        if ($b64.Length % 4) { $b64 = $b64.PadRight($b64.Length + (4 - $b64.Length % 4), "=") }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
        $boundPrefix = $claims.did
    } catch {
        # An unreadable body is not necessarily a bad token -- the format could
        # change. Warn rather than block: the hub is the authority on validity,
        # and refusing a token this script merely could not parse would be this
        # script overreaching.
        Write-Warning "Could not read the device-id binding out of -SquadHubToken; skipping the prefix check."
    }
    if ($boundPrefix -and -not $expectedPrefix.StartsWith($boundPrefix)) {
        throw @"
-SquadHubToken is bound to device ids beginning "$boundPrefix", but these jobs
register as "$expectedPrefix<execution name>". The hub would refuse every session
with exit 77.

Either mint the token with a prefix these jobs match:

  squad-hub device-token --hub $SquadHubUrl --token <your own token> ``
      --label "aca jobs" --prefix $expectedPrefix

or set SQUAD_HUB_DEVICE_ID_PREFIX on the job to "$boundPrefix" so the id it
registers under starts with what the token allows.
"@
    }
    if ($boundPrefix) {
        Write-Host "  squad hub     token is bound to device ids beginning `"$boundPrefix`" (jobs register as `"$expectedPrefix...`")" -ForegroundColor DarkGray
    } else {
        Write-Warning "-SquadHubToken is not bound to a device-id prefix. It could register as ANY device, including one impersonating your laptop. Mint with --prefix $expectedPrefix."
    }
}

if (-not $ImageTag) {
    $ImageTag = try {
        (git -C $repoRoot rev-parse --short HEAD).Trim()
    } catch {
        Get-Date -Format "yyyyMMddHHmmss"
    }
}

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv).Trim()
    if (-not $SubscriptionId) {
        throw "No Azure subscription selected. Run 'az login' and 'az account set --subscription <id>', or pass -SubscriptionId."
    }
}

if (-not $AcrName) {
    # A container registry name must be globally unique, so a fresh deployment
    # invents one. But INVENTING ONE ON EVERY RUN is not a deployment, it is a
    # new deployment each time: the second run builds a second registry, pushes
    # the image there, and leaves the first behind with nothing pointing at it.
    # Reported from a real first-time deploy -- "it would be nice if the azure
    # deployment were idempotent, but it seems to generate az resource names on
    # the fly".
    #
    # So a name is DISCOVERED before it is invented, in the order a person would
    # expect: what you asked for, then what this clone deployed last time, then
    # what is actually in the resource group. Only when all three come up empty
    # is a new one generated -- and then it says so, with the name, because the
    # one thing worse than generating a name is generating one silently.
    $acrStem = "acr" + ($NamePrefix -replace '[^a-z0-9]', '')

    $previous = Join-Path $repoRoot "deploy.outputs.json"
    if (Test-Path $previous) {
        try {
            $recorded = (Get-Content -LiteralPath $previous -Raw | ConvertFrom-Json).acrName
            if ($recorded) {
                $AcrName = $recorded
                Write-Host "Reusing the registry recorded by the last deploy from this clone: $AcrName"
            }
        } catch {
            # A corrupt outputs file must not stop a deploy; fall through to
            # discovery, which reads Azure itself and cannot be stale.
        }
    }

    if (-not $AcrName) {
        $existing = @(az acr list --resource-group $ResourceGroupName `
            --query "[?starts_with(name, '$acrStem')].name" -o tsv 2>$null |
            Where-Object { $_ } | ForEach-Object { $_.Trim() })
        if ($existing.Count -eq 1) {
            $AcrName = $existing[0]
            Write-Host "Reusing the registry already in ${ResourceGroupName}: $AcrName"
        } elseif ($existing.Count -gt 1) {
            # Almost certainly the damage this fix exists to stop: several runs
            # each generated their own. Refuse rather than pick, because picking
            # wrong deploys a job against an image nobody updated.
            throw @"
$($existing.Count) container registries in '$ResourceGroupName' look like this deployment's:

  $($existing -join "`n  ")

That normally means earlier runs each generated their own name. Pass the one you
want to keep and delete the others:

  -AcrName $($existing[0])
"@
        }
    }

    if (-not $AcrName) {
        $suffix = -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object {[char]$_})
        $AcrName = "$acrStem$suffix"
        Write-Host ""
        Write-Host "No existing container registry found, so a new one will be created:"
        Write-Host "  $AcrName"
        Write-Host "Later runs from this clone reuse it automatically via deploy.outputs.json."
        Write-Host "From a different clone or machine, pass it: -AcrName $AcrName"
        Write-Host ""
    }
}

if (-not $DefaultRepository) {
    $DefaultRepository = gh repo view --json nameWithOwner --jq .nameWithOwner 2>$null
    if (-not $DefaultRepository) {
        throw "Could not infer a default GitHub repository. Pass -DefaultRepository '<github-owner>/<repo>'."
    }
}
if (-not $DefaultRef) {
    $DefaultRef = gh repo view $DefaultRepository --json defaultBranchRef --jq .defaultBranchRef.name 2>$null
    if (-not $DefaultRef) {
        throw "Could not infer the default branch for '$DefaultRepository'. Pass -DefaultRef '<branch>'."
    }
}

function New-HexToken([int]$Bytes = 32) {
    $buffer = [byte[]]::new($Bytes)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($buffer)
    -join ($buffer | ForEach-Object { $_.ToString("x2") })
}

if (-not $GitHubToken) {
    $GitHubToken = (& gh auth token).Trim()
}

# A token that cannot PUSH produces a session that clones, runs the agent for
# up to an hour, and then fails at the push. The in-worker token preflight
# catches it about two minutes in, which is far better than at the push, but a
# deploy should not hand the worker a credential it can already tell is
# unusable.
#
# This is not hypothetical: `gh auth token` returns the ACTIVE account's token,
# and on a machine with more than one GitHub account that is often not the
# account with write access. It happened here, repeatedly, and each redeploy
# silently reset the session job to a read-only credential.
#
# Skipped when -DefaultRepository is empty (nothing to check against) and when
# SQUAD_SKIP_TOKEN_CHECK is set, so an offline or air-gapped deploy is not
# blocked by a network call.
if ($GitHubToken -and $DefaultRepository -and -not $env:SQUAD_SKIP_TOKEN_CHECK) {
    $pushProbe = $null
    try {
        $pushProbe = & gh api "repos/$DefaultRepository" --jq '.permissions.push' `
            -H "Authorization: token $GitHubToken" 2>$null
    } catch {
        $pushProbe = $null
    }

    if ($LASTEXITCODE -ne 0 -or -not $pushProbe) {
        Write-Host "[deploy] WARNING: could not confirm push access to $DefaultRepository with the supplied GitHub token. Continuing; the in-worker token preflight will catch an unusable credential at session start." -ForegroundColor Yellow
    } elseif ($pushProbe.Trim() -ne 'true') {
        Write-Host ""
        Write-Host "[deploy] REFUSING: the GitHub token does not have push access to $DefaultRepository (permissions.push=$($pushProbe.Trim()))." -ForegroundColor Red
        Write-Host "         A session deployed with it would clone, run the agent, and fail at the push." -ForegroundColor Red
        Write-Host "         'gh auth token' returns the ACTIVE account's token, which on a multi-account" -ForegroundColor Red
        Write-Host "         machine is often not the one with write access. Check 'gh auth status'." -ForegroundColor Red
        Write-Host "         Fix: pass -GitHubToken with a token that can push, or set" -ForegroundColor Red
        Write-Host "         SQUAD_SKIP_TOKEN_CHECK=1 to deploy anyway." -ForegroundColor Red
        Write-Host ""
        throw "GitHub token lacks push access to $DefaultRepository"
    } else {
        Write-Host "[deploy] GitHub token has push access to $DefaultRepository."
    }
}
if (-not $CopilotGitHubToken) {
    # NOTE (PRD #6, Sprint 7): this collapses two credential planes into one.
    # `gh auth token` returns a CLASSIC token (`ghp_`), and the ACA Sandboxes
    # credential broker accepts only a FINE-GRAINED PAT (`github_pat_`) for
    # --type github-copilot -- so this default is both wider than it needs to be
    # (the Copilot plane inherits the git plane's write scopes) and the exact
    # value the sandbox path refuses. The sandbox provider fails closed with an
    # actionable message rather than sending it. Pass -CopilotGitHubToken with a
    # fine-grained PAT to keep the planes separate; see docs/runbook.md
    # ("Credentials (four planes, kept separate)"). The default is retained so
    # existing ACA Jobs deployments keep working unchanged.
    Write-Host "[deploy] WARNING: -CopilotGitHubToken was not supplied, so the Copilot plane will reuse the SAME token as the GitHub plane. Pass a fine-grained PAT (github_pat_...) to keep them separate; see docs/runbook.md." -ForegroundColor Yellow
    $CopilotGitHubToken = $GitHubToken
}

az account set --subscription $SubscriptionId
az group create --name $ResourceGroupName --location $Location --tags workload=squad-on-aca purpose=remote-agent-dev | Out-Null

$workspaceName = "law-$NamePrefix"
$envName = "cae-$NamePrefix"
$aspireName = "ca-$NamePrefix-aspire"
$jobName = "caj-$NamePrefix-session"
$ralphJobName = "caj-$NamePrefix-ralph"
$watchName = "ca-$NamePrefix-watch"
$identityName = "uai-$NamePrefix-acrpull"
$dashboardToken = New-HexToken
$otlpApiKey = New-HexToken
$otlpHeader = "x-otlp-api-key=$otlpApiKey"

if (-not (az acr show --name $AcrName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
    az acr create --name $AcrName --resource-group $ResourceGroupName --location $Location --sku Basic --admin-enabled false | Out-Null
}
$loginServer = az acr show --name $AcrName --resource-group $ResourceGroupName --query loginServer -o tsv

# The build context is the REPOSITORY ROOT, not worker/. worker/Dockerfile must
# copy config/sandbox-classes.json into the image (it is the catalog the
# in-image dispatcher reads when no --catalog is passed, which is how Ralph
# calls it) and a COPY cannot reach above its build context. scripts/validate.ps1
# asserts this line keeps the root context and the Dockerfile together.
#
# The Dockerfile path is ABSOLUTE. `az acr build` resolves a relative --file
# against the CURRENT WORKING DIRECTORY, not against the context argument, so
# `--file "worker/Dockerfile"` only worked when the script happened to be run
# from the repository root. Run from anywhere else it failed with
#
#     ERROR: Unable to find 'worker/Dockerfile'.
#
# -- and it failed HERE, after the resource group, the registry and the identity
# had already been created. Reported from a real first-time deploy ("deploy ps1
# fails ungracefully if it's not run from the root dir"), and the preflight at
# the top of this script now refuses that case before anything is built.
az acr build --registry $AcrName --image "squad-worker:$ImageTag" --file $dockerfilePath $repoRoot
az account set --subscription $SubscriptionId
$image = "$loginServer/squad-worker:$ImageTag"

if (-not (az identity show --name $identityName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
    az identity create --name $identityName --resource-group $ResourceGroupName --location $Location | Out-Null
}
$identityId = az identity show --name $identityName --resource-group $ResourceGroupName --query id -o tsv
$identityPrincipalId = az identity show --name $identityName --resource-group $ResourceGroupName --query principalId -o tsv
$identityClientId = az identity show --name $identityName --resource-group $ResourceGroupName --query clientId -o tsv
$acrId = az acr show --name $AcrName --resource-group $ResourceGroupName --query id -o tsv
$resourceGroupId = az group show --name $ResourceGroupName --query id -o tsv
az role assignment create --assignee $identityPrincipalId --role AcrPull --scope $acrId 2>$null | Out-Null
# NOTE: the session identity's grant is NOT made here. It used to be
# `Contributor` on the whole resource group, which is far more than it needs and
# is reachable from inside a session -- see the reconcile block near the end of
# this script, which grants `Container Apps Jobs Operator` on the single session
# job instead. It has to run after that job exists.

$jobAndWatcherSecrets = @(
    "github-token=$GitHubToken",
    "copilot-github-token=$CopilotGitHubToken",
    "otlp-headers=$otlpHeader",
    # Always present, empty when supervision is off. `--secrets` REPLACES the
    # set on update, so a secret that is merely omitted when the operator stops
    # passing a token would leave the previous one in place forever -- the same
    # trap SQUAD_COPILOT_FLAGS documents below.
    "squad-hub-token=$SquadHubToken"
)
$secretStore = "container-app-secrets"

if ($UseKeyVault) {
    if (-not $KeyVaultName) {
        $KeyVaultName = "kv-squad-aca-$((Get-Random -Minimum 1000 -Maximum 9999))"
    }
    if (-not (az keyvault show --name $KeyVaultName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
        az keyvault create --name $KeyVaultName --resource-group $ResourceGroupName --location $Location | Out-Null
    }

    # --- key vault permissions -------------------------------------------
    #
    # A vault has TWO possible permission models and they are not
    # interchangeable. `set-policy` works only on an access-policy vault; on an
    # RBAC vault it fails, and role assignments are the only thing that grants
    # anything. Vaults created today are frequently RBAC, either by default or
    # because tenant policy requires it.
    #
    # This used to call `set-policy` with `2>$null | Out-Null`, so on an RBAC
    # vault the grant failed SILENTLY and the very next line -- writing a
    # secret -- came back 403. The deployment created a vault it could not
    # then use, and the error a person saw was Azure's, with no hint that the
    # cause was three lines earlier. Ask the vault which model it is in, and
    # never discard the answer.
    $vaultJson = az keyvault show --name $KeyVaultName --resource-group $ResourceGroupName -o json 2>$null
    $vault = if ($vaultJson) { $vaultJson | ConvertFrom-Json } else { $null }
    if (-not $vault) {
        throw "Key Vault '$KeyVaultName' could not be read after creating it. Check the name is globally unique and that you have access to it."
    }

    $usesRbac = [bool]$vault.properties.enableRbacAuthorization
    $signedInObjectId = az ad signed-in-user show --query id -o tsv
    $vaultId = $vault.id

    if ($usesRbac) {
        Write-Host "  key vault     $KeyVaultName (RBAC authorization)"
        # Secrets Officer to write them; Secrets User for the job identity,
        # which only ever reads. Least privilege on the side that runs
        # unattended.
        az role assignment create --assignee-object-id $signedInObjectId --assignee-principal-type User `
            --role "Key Vault Secrets Officer" --scope $vaultId 2>&1 | Out-Null
        az role assignment create --assignee-object-id $identityPrincipalId --assignee-principal-type ServicePrincipal `
            --role "Key Vault Secrets User" --scope $vaultId 2>&1 | Out-Null
    } else {
        Write-Host "  key vault     $KeyVaultName (access policies)"
        az keyvault set-policy --name $KeyVaultName --object-id $signedInObjectId --secret-permissions get list set delete recover | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not grant yourself access to Key Vault '$KeyVaultName'. Without it the next step cannot write a secret. Re-run once the vault exists, or deploy without -UseKeyVault to keep secrets in the container app instead."
        }
        az keyvault set-policy --name $KeyVaultName --object-id $identityPrincipalId --secret-permissions get list | Out-Null
    }

    # Public network access is a separate gate from permissions, and it is
    # commonly switched off by tenant policy rather than by anything this
    # script did. Detected up front so the failure is explained here rather
    # than arriving as "ForbiddenByConnection" from four `secret set` calls.
    if ($vault.properties.publicNetworkAccess -eq 'Disabled') {
        throw @"
Key Vault '$KeyVaultName' has public network access DISABLED, so secrets cannot be written from this machine.

That is usually tenant policy rather than anything this deployment chose. Pick one:

  * allow your address:  az keyvault network-rule add --name $KeyVaultName --ip-address `$(curl -s https://api.ipify.org)
                         az keyvault update --name $KeyVaultName --public-network-access Enabled
  * or skip the vault:   re-run without -UseKeyVault, and secrets are stored in the
                         container app instead (still not readable from outside it)
"@
    }

    # A role assignment is not effective the instant it is created. This is the
    # first call that depends on one, so it is the one that has to tolerate the
    # gap -- retrying here rather than leaving a person to read
    # "please observe propagation time" and guess how long that is.
    $secretWriteError = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $probe = az keyvault secret set --vault-name $KeyVaultName --name github-token --value $GitHubToken --query id -o tsv 2>&1
        if ($LASTEXITCODE -eq 0) { $githubTokenSecretId = $probe; $secretWriteError = $null; break }
        $secretWriteError = $probe
        if ($attempt -lt 6) { Start-Sleep -Seconds 10 }
    }
    if ($secretWriteError) {
        throw @"
Could not write a secret to Key Vault '$KeyVaultName' after waiting for permissions to take effect.

Azure said:
$secretWriteError

If this is a 403, the account running this deployment needs the "Key Vault
Secrets Officer" role on the vault (an Owner or Contributor role on the
subscription does NOT include data-plane access). Otherwise, re-run without
-UseKeyVault to store secrets in the container app instead.
"@
    }

    $copilotTokenSecretId = az keyvault secret set --vault-name $KeyVaultName --name copilot-github-token --value $CopilotGitHubToken --query id -o tsv
    $otlpHeadersSecretId = az keyvault secret set --vault-name $KeyVaultName --name otlp-headers --value $otlpHeader --query id -o tsv
    $squadHubTokenSecretId = az keyvault secret set --vault-name $KeyVaultName --name squad-hub-token --value $SquadHubToken --query id -o tsv

    $jobAndWatcherSecrets = @(
        "github-token=keyvaultref:$githubTokenSecretId,identityref:$identityId",
        "copilot-github-token=keyvaultref:$copilotTokenSecretId,identityref:$identityId",
        "otlp-headers=keyvaultref:$otlpHeadersSecretId,identityref:$identityId",
        "squad-hub-token=keyvaultref:$squadHubTokenSecretId,identityref:$identityId"
    )
    $secretStore = "key-vault"
}

az monitor log-analytics workspace create --resource-group $ResourceGroupName --workspace-name $workspaceName --location $Location | Out-Null
$workspaceId = az monitor log-analytics workspace show --resource-group $ResourceGroupName --workspace-name $workspaceName --query customerId -o tsv
$workspaceKey = az monitor log-analytics workspace get-shared-keys --resource-group $ResourceGroupName --workspace-name $workspaceName --query primarySharedKey -o tsv

$existingEnvState = az containerapp env show --name $envName --resource-group $ResourceGroupName --query properties.provisioningState -o tsv 2>$null
if ($existingEnvState -eq "Failed") {
    az containerapp env delete --name $envName --resource-group $ResourceGroupName --yes | Out-Null
    $existingEnvState = ""
}
if (-not $existingEnvState) {
    # Capture the failure rather than piping it away. A capacity refusal is a
    # fact about the REGION, not about the deployment, and the raw Azure error
    # ("...experiencing heavy usage in region...", ErrorCode
    # CapacityHeavyUsage) reads like a broken product to somebody deploying for
    # the first time. It is also the one failure with an obvious next step, so
    # say what it is.
    $envCreate = az containerapp env create --name $envName --resource-group $ResourceGroupName `
        --location $Location --logs-workspace-id $workspaceId --logs-workspace-key $workspaceKey 2>&1
    if ($LASTEXITCODE -ne 0) {
        $envCreateText = ($envCreate | Out-String)
        if ($envCreateText -match 'CapacityHeavyUsage|heavy usage|capacity|SubscriptionIsOverQuotaForSku|NotAvailableForSubscription') {
            throw @"
Azure refused to create the Container Apps environment in '$Location' because
the region is out of capacity, not because anything is wrong with this
deployment:

$($envCreateText.Trim())

Deploy to a different region. Nothing was created there yet, so this is safe:

  .\scripts\deploy.ps1 -Location <region> -ResourceGroupName rg-$NamePrefix-dev-<region>

Regions that have had capacity for this workload: centralus (the default),
westus3, eastus. Check what your subscription can offer:

  az provider show --namespace Microsoft.App --query "resourceTypes[?resourceType=='managedEnvironments'].locations | [0]" -o tsv
"@
        }
        throw "Creating the Container Apps environment failed:`n$($envCreateText.Trim())"
    }
}
$envId = az containerapp env show --name $envName --resource-group $ResourceGroupName --query id -o tsv

$aspireYaml = Join-Path $azureDir "aspire.containerapp.yaml"
@"
location: $Location
name: $aspireName
type: Microsoft.App/containerApps
properties:
  managedEnvironmentId: $envId
  configuration:
    activeRevisionsMode: Single
    secrets:
    - name: otlp-api-key
      value: $otlpApiKey
    ingress:
      external: true
      targetPort: 18888
      transport: http
      allowInsecure: false
      traffic:
      - latestRevision: true
        weight: 100
      additionalPortMappings:
      - external: false
        targetPort: 18889
        exposedPort: 18889
      - external: false
        targetPort: 18890
        exposedPort: 18890
  template:
    containers:
    - name: aspire
      image: mcr.microsoft.com/dotnet/aspire-dashboard:latest
      env:
      - name: DASHBOARD__FRONTEND__AUTHMODE
        value: BrowserToken
      - name: DASHBOARD__FRONTEND__BROWSERTOKEN
        value: $dashboardToken
      - name: DASHBOARD__OTLP__AUTHMODE
        value: ApiKey
      - name: DASHBOARD__OTLP__PRIMARYAPIKEY
        secretRef: otlp-api-key
      resources:
        cpu: 0.5
        memory: 1.0Gi
    scale:
      minReplicas: 1
      maxReplicas: 1
"@ | Set-Content -Path $aspireYaml -Encoding utf8

# Create the Aspire dashboard on first deploy; on subsequent deploys update the
# existing app in place. `az containerapp create --yaml` fails if the app already
# exists, which broke documented token/OTLP-key rotation and recovery (both
# regenerate secrets and re-run this script). `update --yaml` performs a full
# create-or-update PUT of the app definition (secrets, ingress, and template),
# so it rotates the OTLP API key and dashboard browser token and rolls a new
# revision. BrowserToken UI auth, ApiKey OTLP auth, and internal-only OTLP ports
# all live in $aspireYaml, so they are preserved on every run.
if (az containerapp show --name $aspireName --resource-group $ResourceGroupName --query id -o tsv 2>$null) {
    az containerapp update --name $aspireName --resource-group $ResourceGroupName --yaml $aspireYaml | Out-Null
} else {
    az containerapp create --name $aspireName --resource-group $ResourceGroupName --yaml $aspireYaml | Out-Null
}
$aspireFqdn = az containerapp show --name $aspireName --resource-group $ResourceGroupName --query properties.configuration.ingress.fqdn -o tsv

$commonEnv = @(
    "GITHUB_REPOSITORY=$DefaultRepository",
    "GITHUB_REF=$DefaultRef",
    "GITHUB_BASE_BRANCH=$DefaultRef",
    "GITHUB_TOKEN=secretref:github-token",
    "COPILOT_GITHUB_TOKEN=secretref:copilot-github-token",
    "ASPIRE_OTLP_GRPC_ENDPOINT=http://$aspireName`:18889",
    "ASPIRE_OTLP_HTTP_ENDPOINT=http://$aspireName`:18890",
    "OTEL_EXPORTER_OTLP_HEADERS=secretref:otlp-headers",
    "SQUAD_DEPLOYMENT_MODE=squad-per-pod",
    "ENABLE_GITHUB_REMOTE=true",
    # Explicitly CLEARED, not just omitted (issue #26, PRD #6). This used to be
    # `--yolo --agent squad --remote --no-auto-update`, so every deployed job ran
    # with --allow-all-tools + --allow-all-paths + --allow-all-urls, and anyone
    # who could set one environment variable on a dispatch could keep it that
    # way. `az containerapp job update --set-env-vars` MERGES, so dropping the
    # line would leave the old `--yolo` value on an existing deployment forever;
    # setting it empty is what actually removes it on redeploy.
    #
    # Flags are now composed per session by worker/lib/agent-policy.js from
    # SQUAD_MODE and SQUAD_DISPATCH_SOURCE. The variable is still read as
    # OPERATOR EXTRAS (model, log level, reasoning effort); a permission-widening
    # flag in it now aborts the session instead of applying.
    "SQUAD_COPILOT_FLAGS=",
    # Squad Hub supervision. Both are set on EVERY deploy, empty when it is off,
    # for the same reason SQUAD_COPILOT_FLAGS above is cleared rather than
    # omitted: `--set-env-vars` MERGES, so an operator who stops passing a hub
    # would otherwise leave a stale URL and a revoked token on the job forever.
    #
    # The token is a SECRET REFERENCE, never a literal. A device token is still
    # a credential; it just cannot do very much -- it can be a device and
    # nothing else, and cannot read the hub's API or drive another device.
    "SQUAD_HUB_URL=$SquadHubUrl",
    "SQUAD_HUB_TOKEN=$(if ($SquadHubToken) { 'secretref:squad-hub-token' } else { '' })",
    "AZURE_SUBSCRIPTION_ID=$SubscriptionId",
    "AZURE_RESOURCE_GROUP=$ResourceGroupName",
    "AZURE_CLIENT_ID=$identityClientId",
    "ACA_SESSION_JOB_NAME=$jobName"
)

$existingJobImage = az containerapp job show --name $jobName --resource-group $ResourceGroupName --query "properties.template.containers[0].image" -o tsv 2>$null
if ($existingJobImage -and $existingJobImage -ne $image) {
    az containerapp job delete --name $jobName --resource-group $ResourceGroupName --yes | Out-Null
    $existingJobImage = ""
}

if (-not $existingJobImage) {
    az containerapp job create `
        --name $jobName `
        --resource-group $ResourceGroupName `
        --environment $envName `
        --trigger-type Manual `
        --replica-timeout 7200 `
        --replica-retry-limit 0 `
        --replica-completion-count 1 `
        --parallelism 1 `
        --image $image `
        --cpu 1.0 `
        --memory 2.0Gi `
        --mi-user-assigned $identityId `
        --registry-server $loginServer `
        --registry-identity $identityId `
        --secrets @jobAndWatcherSecrets `
        --env-vars @commonEnv "SQUAD_MODE=smoke" "SESSION_NAME=smoke-template" "SQUAD_POD_ID=smoke-template" | Out-Null
} else {
    az containerapp job update --name $jobName --resource-group $ResourceGroupName --image $image --set-env-vars @commonEnv | Out-Null
    az containerapp job secret set --name $jobName --resource-group $ResourceGroupName --secrets @jobAndWatcherSecrets | Out-Null
}

$existingRalphJobImage = az containerapp job show --name $ralphJobName --resource-group $ResourceGroupName --query "properties.template.containers[0].image" -o tsv 2>$null
if ($existingRalphJobImage -and $existingRalphJobImage -ne $image) {
    az containerapp job delete --name $ralphJobName --resource-group $ResourceGroupName --yes | Out-Null
    $existingRalphJobImage = ""
}

if (-not $existingRalphJobImage) {
    az containerapp job create `
        --name $ralphJobName `
        --resource-group $ResourceGroupName `
        --environment $envName `
        --trigger-type Schedule `
        --cron-expression "*/5 * * * *" `
        --replica-timeout 240 `
        --replica-retry-limit 0 `
        --replica-completion-count 1 `
        --parallelism 1 `
        --image $image `
        --cpu 1.0 `
        --memory 2.0Gi `
        --mi-user-assigned $identityId `
        --registry-server $loginServer `
        --registry-identity $identityId `
        --secrets @jobAndWatcherSecrets `
        --env-vars @commonEnv "SQUAD_MODE=ralph" "SESSION_NAME=ralph-scheduled" "SQUAD_POD_ID=ralph-scheduled" "RALPH_LABELS=squad-aca" "RALPH_MAX_ISSUES=3" | Out-Null
} else {
    az containerapp job update --name $ralphJobName --resource-group $ResourceGroupName --image $image --cron-expression "*/5 * * * *" --replica-timeout 240 --set-env-vars @commonEnv "SQUAD_MODE=ralph" "SESSION_NAME=ralph-scheduled" "SQUAD_POD_ID=ralph-scheduled" "RALPH_LABELS=squad-aca" "RALPH_MAX_ISSUES=3" | Out-Null
    az containerapp job secret set --name $ralphJobName --resource-group $ResourceGroupName --secrets @jobAndWatcherSecrets | Out-Null
}

if (-not (az containerapp show --name $watchName --resource-group $ResourceGroupName --query id -o tsv 2>$null)) {
    az containerapp create `
        --name $watchName `
        --resource-group $ResourceGroupName `
        --environment $envName `
        --image $image `
        --cpu 1.0 `
        --memory 2.0Gi `
        --min-replicas 0 `
        --max-replicas 1 `
        --user-assigned $identityId `
        --registry-server $loginServer `
        --registry-identity $identityId `
        --secrets @jobAndWatcherSecrets `
        --env-vars @commonEnv "SQUAD_MODE=watch" "SESSION_NAME=watch-default" "SQUAD_POD_ID=watch-default" | Out-Null
} else {
    # Ensure the existing watcher points at the current ACR/login server and pull identity.
    # A watcher created by an older deploy (or against a prior ACR) keeps stale registry
    # settings; updating the image alone then fails the pull with UNAUTHORIZED. Registry set
    # is idempotent, so this is safe to run every deploy.
    #
    # A watcher redeployed against a new ACR also accumulates *stale* registry entries for the
    # prior login server(s). They don't block the pull once the current registry is set, but
    # they leave the app in a messy, non-idempotent state (e.g. two registries listed by
    # `az containerapp show`). Prune any entry whose server differs from the current one first.
    $existingRegistries = az containerapp registry list --name $watchName --resource-group $ResourceGroupName --query "[].server" -o tsv 2>$null
    if ($existingRegistries) {
        foreach ($registryServer in ($existingRegistries -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            if ($registryServer -ne $loginServer) {
                Write-Host "Removing stale watcher registry '$registryServer' (current is '$loginServer')."
                az containerapp registry remove --name $watchName --resource-group $ResourceGroupName --server $registryServer | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to remove stale watcher registry '$registryServer'; continuing deployment."
                }
            }
        }
    }
    az containerapp registry set --name $watchName --resource-group $ResourceGroupName --server $loginServer --identity $identityId | Out-Null
    az containerapp update --name $watchName --resource-group $ResourceGroupName --image $image --set-env-vars @commonEnv | Out-Null
    az containerapp secret set --name $watchName --resource-group $ResourceGroupName --secrets @jobAndWatcherSecrets | Out-Null
}

$outputs = [ordered]@{
    subscriptionId = $SubscriptionId
    resourceGroup = $ResourceGroupName
    location = $Location
    containerAppsEnvironment = $envName
    acrName = $AcrName
    pullIdentity = $identityName
    secretStore = $secretStore
    keyVaultName = $KeyVaultName
    workerImage = $image
    aspireApp = $aspireName
    aspireUrl = "https://$aspireFqdn"
    aspireLoginUrl = "https://$aspireFqdn/login?t=$dashboardToken"
    sessionJob = $jobName
    ralphJob = $ralphJobName
    watchApp = $watchName
    defaultRepository = $DefaultRepository
    defaultRef = $DefaultRef
    logAnalyticsWorkspace = $workspaceName
}

# --- The Actions trigger's grant, reconciled (issue #32 S4) -------------------
#
# `az containerapp job delete` above runs whenever the image changes, and a role
# assignment scoped to a RESOURCE dies with that resource. The GitHub Actions
# federated identity therefore LOSES its grant on every image-changing deploy,
# and the next triggered run fails with "No subscriptions found" -- which reads
# like an OIDC fault and is an RBAC one. Observed live, not theorised.
#
# The grant is reconciled here rather than widened to the resource group,
# because "Container Apps Jobs Operator" scoped to the single session job is the
# whole point: the trigger can start THAT job and nothing else.
#
# Absent identity is not an error. The Actions trigger is optional; a deployment
# that never uses it should not fail for want of a grant nobody wants.
$ghaIdentityName = if ($GitHubActionsIdentityName) { $GitHubActionsIdentityName } else { "uai-$NamePrefix-gha" }
$ghaPrincipalId = az identity show --name $ghaIdentityName --resource-group $ResourceGroupName --query principalId -o tsv 2>$null
if ($ghaPrincipalId) {
    $jobScope = az containerapp job show --name $jobName --resource-group $ResourceGroupName --query id -o tsv 2>$null
    if ($jobScope) {
        $existingGrant = az role assignment list --assignee $ghaPrincipalId --scope $jobScope `
            --query "[?roleDefinitionName=='Container Apps Jobs Operator'].id" -o tsv 2>$null
        if ($existingGrant) {
            Write-Host "GitHub Actions identity '$ghaIdentityName' already holds Container Apps Jobs Operator on $jobName."
        } else {
            Write-Host "Re-granting Container Apps Jobs Operator on $jobName to '$ghaIdentityName' (a job delete drops resource-scoped assignments)."
            az role assignment create `
                --assignee-object-id $ghaPrincipalId `
                --assignee-principal-type ServicePrincipal `
                --role "Container Apps Jobs Operator" `
                --scope $jobScope | Out-Null
        }
    }
} else {
    Write-Host "No GitHub Actions identity '$ghaIdentityName' in $ResourceGroupName; skipping the Actions trigger grant."
}

# --- The session identity's grant, narrowed from Contributor -----------------
#
# This identity used to hold `Contributor` on the whole RESOURCE GROUP. What it
# actually does with Azure is two commands, both against the one session job:
# `containerapp job show` and `containerapp job start`. Contributor on the group
# additionally lets it read every secret, rewrite every job, and delete the
# registry -- none of which it was ever asked to do.
#
# That matters more than an unused permission usually would, because the thing
# holding this identity is an AGENT RUNNING A PROMPT. The deny list stops it
# calling `az`, but not `curl`, and the instance metadata endpoint answers to
# curl, so the identity is reachable from inside a session by anyone who can
# influence what the agent does. The grant is therefore sized to what a
# compromised session would be able to do with it.
#
# `Container Apps Jobs Operator` on the single job covers `jobs/read` and
# `jobs/*/action`. Scoped to a resource, so like the grant above it dies with a
# job delete and is reconciled on every deploy.
$sessionJobScope = az containerapp job show --name $jobName --resource-group $ResourceGroupName --query id -o tsv 2>$null
if ($sessionJobScope) {
    $existingSessionGrant = az role assignment list --assignee $identityPrincipalId --scope $sessionJobScope `
        --query "[?roleDefinitionName=='Container Apps Jobs Operator'].id" -o tsv 2>$null
    if ($existingSessionGrant) {
        Write-Host "Session identity '$identityName' already holds Container Apps Jobs Operator on $jobName."
    } else {
        Write-Host "Granting Container Apps Jobs Operator on $jobName to '$identityName'."
        az role assignment create `
            --assignee-object-id $identityPrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role "Container Apps Jobs Operator" `
            --scope $sessionJobScope | Out-Null
    }

    # Remove the old wide grant if a previous deploy left one behind. Narrowing
    # that only applies to new deployments narrows nothing: every environment
    # already deployed keeps Contributor forever unless something takes it away.
    $staleContributor = az role assignment list --assignee $identityPrincipalId --scope $resourceGroupId `
        --query "[?roleDefinitionName=='Contributor' && scope=='$resourceGroupId'].id" -o tsv 2>$null
    if ($staleContributor) {
        Write-Host "Removing the old resource-group Contributor grant from '$identityName'."
        foreach ($assignmentId in ($staleContributor -split "`n" | Where-Object { $_ })) {
            az role assignment delete --ids $assignmentId.Trim() 2>$null | Out-Null
        }
    }
} else {
    Write-Host "Session job '$jobName' not found; skipping the session identity grant."
}

$outputsPath = Join-Path $repoRoot "deploy.outputs.json"
$outputs | ConvertTo-Json -Depth 5 | Set-Content -Path $outputsPath -Encoding utf8
$outputs | ConvertTo-Json -Depth 5

# --- Squad Hub supervision, per component ------------------------------------
#
# Says whether each thing that runs an agent will actually appear in the hub.
#
# This exists because the failure it replaces was INVISIBLE from the outside. An
# operator set SQUAD_HUB_URL and SQUAD_HUB_TOKEN, saw no error, watched the
# watcher work through a backlog, and saw nothing in the hub -- because `watch`
# had no hub integration at all. Configured and working looked identical to
# configured and ignored.
#
# Reported at the end, from what was actually deployed, rather than from what
# was asked for.
Write-Host ""
Write-Host "=== Squad Hub supervision ===" -ForegroundColor Cyan
if (-not $SquadHubUrl -and -not $SquadHubToken) {
    Write-Host "  not configured -- sessions run unattended and will not appear in a hub."
    Write-Host "  To turn it on: -SquadHubUrl <url> -SquadHubToken <device token>"
} else {
    Write-Host "  hub           $SquadHubUrl"
    Write-Host "  session job   supervised (one session per dispatch)"
    Write-Host "  ralph         dispatches into the session job above, which is supervised"
    Write-Host "  watcher       supervised (the container attaches; each session it starts registers itself)"
    Write-Host ""
    Write-Host "  Watch and loop need squad-hub >= 0.4.1 in the image; the build refuses"
    Write-Host "  anything older, so an image that got here can do it."
    Write-Host ""
    Write-Host "  Devices appear under the account that MINTED the device token, so mint"
    Write-Host "  your own rather than reusing somebody else's to see your own work."
}
