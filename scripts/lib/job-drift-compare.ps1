# CV-2 (issue #85) -- pure job/environment drift comparer.
#
# THIS FILE CONTAINS NO REFERENCE TO THE AZURE CLI, mirroring the CV-1 split
# in scripts/lib/rbac-drift-compare.ps1: snapshot in, findings out, nothing
# here reaches a network, a filesystem, or a child process.
# scripts/validate.ps1 asserts this statically (grep for a standalone Azure
# CLI command-name token) as well as functionally.
#
# Fixtures under scripts/tests/fixtures/job-drift/*.json drive this comparer
# directly: a drifted case (an extra identity, an inlined secret) is proven to
# fail without contacting the cloud and without any mutation.

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here, matching
# rbac-drift-compare.ps1 and every other dot-sourced lib in this repo.

# The environment variable names deploy.ps1's $commonEnv actually sets on the
# session job on EVERY deploy (scripts/deploy.ps1, the `$commonEnv = @(...)`
# block feeding `--set-env-vars @commonEnv` on both create and update). This
# deliberately excludes SQUAD_MODE / SESSION_NAME / SQUAD_POD_ID: those are
# baked in only at job CREATION time (the "smoke-template" values) and are
# never reasserted by `job update`, so asserting them here would fail against
# a job whose most recent execution legitimately overrode them at dispatch
# time -- a false positive this check must not produce.
$script:JobDriftExpectedEnvVarNames = @(
    "GITHUB_REPOSITORY", "GITHUB_REF", "GITHUB_BASE_BRANCH",
    "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN",
    "ASPIRE_OTLP_GRPC_ENDPOINT", "ASPIRE_OTLP_HTTP_ENDPOINT", "OTEL_EXPORTER_OTLP_HEADERS",
    "SQUAD_DEPLOYMENT_MODE", "ENABLE_GITHUB_REMOTE", "SQUAD_COPILOT_FLAGS",
    "SQUAD_HUB_URL", "SQUAD_HUB_TOKEN",
    "AZURE_SUBSCRIPTION_ID", "AZURE_RESOURCE_GROUP", "AZURE_CLIENT_ID", "ACA_SESSION_JOB_NAME"
)

# Of the names above, the subset deploy.ps1 hands `--secrets` for and wires in
# with `secretref:...` rather than a literal value. SQUAD_HUB_TOKEN is
# included even though supervision is optional: deploy.ps1 clears it to an
# EMPTY literal (never a real value) when no hub token is configured -- see
# the "SQUAD_HUB_TOKEN=$(if ($SquadHubToken) {...} else {''})" comment in
# deploy.ps1 -- so an empty value is fine, but any NON-EMPTY literal value is
# a credential deploy.ps1 never inlines: the exact CV-2 "inlined secret" case.
$script:JobDriftSecretBackedEnvVarNames = @(
    "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN", "OTEL_EXPORTER_OTLP_HEADERS", "SQUAD_HUB_TOKEN"
)

function New-JobDriftFinding {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][ValidateSet("info", "high")][string]$Severity,
        [string]$Subject = "",
        [string]$Detail = ""
    )
    return [pscustomobject]@{
        Status   = $Status
        Severity = $Severity
        Subject  = $Subject
        Detail   = $Detail
    }
}

function Compare-JobDriftSnapshot {
    <#
    .SYNOPSIS
        Pure comparison: snapshot object in, findings array out. Never touches
        the Azure CLI, the filesystem, or the network -- the SAME snapshot
        object shape (schema squad-aca/job-drift-snapshot@1) is produced
        either by scripts/lib/job-drift-reader.ps1's Get-JobDriftLiveSnapshot
        (live) or by loading a committed fixture (offline test).

    .PARAMETER Snapshot
        A [pscustomobject] with .image, .envVars (array of {name, hasValue,
        hasSecretRef}), .identities (array of {alias, isExpectedSession}), and
        .systemAssignedEnabled (bool).

    .PARAMETER ExpectedImage
        The image deploy.ps1 intends for this job right now (deploy.outputs
        .json's workerImage, or an explicit override). Required: comparing
        against nothing would let an image drift pass silently.

    .OUTPUTS
        [pscustomobject[]] findings, each with Status / Severity / Subject /
        Detail. Feed the result to Get-JobDriftExitCode for the process exit
        code.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ExpectedImage
    )

    $findings = @()

    if ($Snapshot.image -ne $ExpectedImage) {
        $findings += New-JobDriftFinding -Status "unexpectedImage" -Severity "high" -Subject "image" `
            -Detail "job runs '$($Snapshot.image)', expected '$ExpectedImage'"
    } else {
        $findings += New-JobDriftFinding -Status "ok" -Severity "info" -Subject "image" -Detail "matches intent"
    }

    $heldEnvVars = @{}
    foreach ($ev in @($Snapshot.envVars)) {
        if (-not $ev) { continue }
        $heldEnvVars[[string]$ev.name] = $ev
    }

    foreach ($name in $script:JobDriftExpectedEnvVarNames) {
        if (-not $heldEnvVars.ContainsKey($name)) {
            $findings += New-JobDriftFinding -Status "missingEnvVar" -Severity "high" -Subject $name `
                -Detail "expected environment variable '$name' is not present on the job"
        } else {
            $findings += New-JobDriftFinding -Status "ok" -Severity "info" -Subject $name -Detail "present"
        }
    }

    foreach ($name in $script:JobDriftSecretBackedEnvVarNames) {
        if (-not $heldEnvVars.ContainsKey($name)) { continue }
        $ev = $heldEnvVars[$name]
        if ($ev.hasValue -and -not $ev.hasSecretRef) {
            $findings += New-JobDriftFinding -Status "inlinedSecret" -Severity "high" -Subject $name `
                -Detail "'$name' carries a literal value instead of a secret reference"
        } elseif ($ev.hasSecretRef) {
            $findings += New-JobDriftFinding -Status "ok" -Severity "info" -Subject $name -Detail "referenced via secretRef, not inlined"
        }
        # hasValue = $false and hasSecretRef = $false (an intentionally empty,
        # unconfigured optional secret, e.g. SQUAD_HUB_TOKEN with no hub set)
        # is neither drift nor a pass worth reporting on its own.
    }

    $expectedSessionHeld = @($Snapshot.identities | Where-Object { $_.isExpectedSession })
    if ($expectedSessionHeld.Count -eq 0) {
        $findings += New-JobDriftFinding -Status "missingIdentity" -Severity "high" -Subject "identity" `
            -Detail "the job does not carry the expected session identity"
    } else {
        $findings += New-JobDriftFinding -Status "ok" -Severity "info" -Subject "identity" -Detail "expected session identity is attached"
    }

    $unexpectedIdentities = @($Snapshot.identities | Where-Object { -not $_.isExpectedSession })
    foreach ($extra in $unexpectedIdentities) {
        $findings += New-JobDriftFinding -Status "unexpectedIdentity" -Severity "high" -Subject $extra.alias `
            -Detail "the job carries a user-assigned identity ('$($extra.alias)') that is not the expected session identity"
    }

    if ($Snapshot.systemAssignedEnabled) {
        $findings += New-JobDriftFinding -Status "unexpectedIdentity" -Severity "high" -Subject "systemAssigned" `
            -Detail "the job has a system-assigned identity enabled; deploy.ps1 never enables one"
    }

    return $findings
}

function Get-JobDriftExitCode {
    <#
    .SYNOPSIS
        0 when no finding is high severity, 1 otherwise -- mirrors
        Get-RbacDriftExitCode in rbac-drift-compare.ps1.
    #>
    param([object[]]$Findings)
    $highSeverity = @($Findings | Where-Object { $_.Severity -eq "high" })
    if ($highSeverity.Count -gt 0) { return 1 }
    return 0
}
