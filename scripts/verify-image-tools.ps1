#requires -Version 5.1
<#
.SYNOPSIS
    LIVE verification: boot a catalog class's pinned image and record which of
    the tools it claims actually exist inside it.

.DESCRIPTION
    config/sandbox-classes.json declares, per class, the tools an image
    provides. Nothing used to compare that declaration with the image, and the
    declaration was wrong: two approved classes pinned the same squad-worker
    digest while claiming python3, pip3, jq, make and pnpm it does not carry.

    This script is the half of the fix that cannot run offline. It creates a
    sandbox disk from the class's PINNED DIGEST, starts a sandbox from it, runs
    `command -v` for every declared tool inside that sandbox, and writes the
    result to config/image-evidence/sha256-<hex>.json.

    worker/lib/verify-image-evidence.js then re-reads that file in CI. The
    division of labour is deliberate and is stated in docs/capability-manifest.md:

        THIS SCRIPT proves what is inside the image. It needs Azure, the `aca`
        CLI, and pull rights on a private registry.

        CI proves that evidence exists for exactly the digest pinned today, was
        recorded for the same image repository, and covers every declared tool.
        CI never sees the image.

    Because the evidence file is named after the digest, re-pinning a class to a
    new digest without re-running this script makes the offline check FAIL. That
    is the intended behaviour: no evidence means no claim.

    NOTHING here weakens the in-worker preflight. The preflight
    (worker/lib/squad-capability-preflight.sh) remains the final gate inside
    every session; this only stops the catalog making a claim the preflight then
    has to refuse.

    The registry token is never written to the evidence file, never printed, and
    is redacted from every echoed argv.

.PARAMETER ClassId
    Class id in the catalog to verify, e.g. sandbox-python-3-12. Repeatable.
    Defaults to every APPROVED class.

.PARAMETER CatalogPath
    Catalog to read. Defaults to config/sandbox-classes.json.

.PARAMETER EvidenceDir
    Directory the evidence files are written to. Defaults to
    config/image-evidence.

.PARAMETER AdditionalTools
    Extra tool names to probe beyond the class's declared list. Probing more
    than is claimed is how a class's claim gets WIDENED honestly: run with the
    candidate tool, then add it to the catalog only if the evidence says HAVE.

.PARAMETER DiskId
    Reuse an existing sandbox disk instead of creating (and deleting) one.

.PARAMETER KeepDisk
    Keep the disk this run created and print its id. Without this, every disk
    and sandbox the run created is deleted before it returns -- a leaked
    sandbox costs money.

.EXAMPLE
    ./scripts/verify-image-tools.ps1 -ClassId sandbox-python-3-12
#>
[CmdletBinding()]
param(
    [string[]]$ClassId,
    [string]$CatalogPath,
    [string]$EvidenceDir,
    [string]$AcaPath = "$env:USERPROFILE\.aca\bin\aca.exe",
    [string]$Registry = "acrsquadacah81u42kq",
    [string]$Subscription = "3898b8ea-c676-4b43-95fc-d38425627d74",
    [string]$ResourceGroup = "rg-squad-aca-dev-eastus2",
    [string]$SandboxGroup = "sbg-squad-aca",
    [string[]]$AdditionalTools = @(),
    [string]$DiskId,
    [switch]$KeepDisk
)

$ErrorActionPreference = "Stop"
# No Set-StrictMode: the aca CLI's JSON shapes are not part of this repo's
# contract, and a strict property access would turn a missing field into a
# crash in the middle of a run that has live resources to clean up.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
if (-not $CatalogPath) { $CatalogPath = Join-Path $RepoRoot "config\sandbox-classes.json" }
if (-not $EvidenceDir) { $EvidenceDir = Join-Path $RepoRoot "config\image-evidence" }

# The probe list is interpolated into a shell `for` loop inside the sandbox, and
# the tool names also become JSON keys. Anything outside this grammar is
# refused rather than escaped: the catalog is administrator-owned, so a name
# that needs escaping is a mistake to surface, not a case to handle.
$ToolNamePattern = '^[A-Za-z0-9._-]{1,64}$'
$DigestPattern = '^sha256:[0-9a-f]{64}$'
$NullGuidUser = "00000000-0000-0000-0000-000000000000"

function Write-Step($text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Note($text) { Write-Host "    $text" -ForegroundColor DarkGray }

function Get-RedactedArgv {
    param([string[]]$Argv)
    $out = @()
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        $out += $Argv[$i]
        if ($Argv[$i] -eq "--token" -and $i + 1 -lt $Argv.Count) {
            $out += "***REDACTED***"
            $i++
        }
    }
    return ($out -join " ")
}

function Invoke-Aca {
    <#
    .SYNOPSIS
        Run the `aca` CLI and return exit code plus merged output.
    .DESCRIPTION
        Native commands set $LASTEXITCODE but do not throw, so stderr is
        captured deliberately instead of being allowed to become a terminating
        NativeCommandError. The caller decides what a non-zero exit means.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Argv)

    $previousEap = $ErrorActionPreference
    $lines = @()
    $code = -1
    try {
        $ErrorActionPreference = "Continue"
        $lines = & $AcaPath @Argv 2>&1
        $code = $LASTEXITCODE
    } catch {
        $lines = @($_.Exception.Message)
        $code = 127
    } finally {
        $ErrorActionPreference = $previousEap
    }
    return [pscustomobject]@{
        ExitCode = $code
        Output   = (@($lines | ForEach-Object { [string]$_ }) -join "`n")
        SafeArgv = (Get-RedactedArgv -Argv $Argv)
    }
}

function Get-CommonAcaArgs {
    return @("-s", $Subscription, "-g", $ResourceGroup, "--sandbox-group", $SandboxGroup)
}

function New-UtcStamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Resolve-DiskIdByLabel {
    <#
    .SYNOPSIS
        Turn a disk LABEL into the GUID `aca sandbox create --disk-id` needs.
    .DESCRIPTION
        `disk create --name` sets a LABEL, not a resolvable name, and the CLI
        returns it under labels.name rather than as a top-level property. Older
        shapes exposed name/label/displayName directly, so all of them are
        accepted. Returns Id = $null when no disk carries the label, which is a
        normal "not created yet" answer, not an error.
    #>
    param([Parameter(Mandatory = $true)][string]$Label)

    $list = Invoke-Aca -Argv ((Get-CommonAcaArgs) + @("sandboxgroup", "disk", "list", "-o", "json"))
    if ($list.ExitCode -ne 0) {
        return [pscustomobject]@{ Id = $null; Error = "disk list failed (exit $($list.ExitCode)): $($list.Output)" }
    }
    $disks = @()
    $raw = $list.Output.Trim()
    if ($raw) {
        try { $disks = @($raw | ConvertFrom-Json) } catch {
            return [pscustomobject]@{ Id = $null; Error = "'disk list' returned output that is not valid JSON" }
        }
    }
    foreach ($disk in $disks) {
        if ($null -eq $disk) { continue }
        $names = @()
        foreach ($property in @("name", "label", "displayName")) {
            if ($disk.PSObject.Properties.Name -contains $property) { $names += [string]$disk.$property }
        }
        if (($disk.PSObject.Properties.Name -contains "labels") -and $disk.labels) {
            if ($disk.labels.PSObject.Properties.Name -contains "name") { $names += [string]$disk.labels.name }
        }
        if ($names -contains $Label) { return [pscustomobject]@{ Id = [string]$disk.id; Error = $null } }
    }
    return [pscustomobject]@{ Id = $null; Error = $null }
}

# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $CatalogPath)) { throw "Catalog not found: $CatalogPath" }
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json

$targets = @()
foreach ($cls in @($catalog.classes)) {
    if ($ClassId) {
        if ($ClassId -notcontains [string]$cls.id) { continue }
    } elseif ($cls.approved -ne $true) {
        continue
    }
    $targets += $cls
}
if ($targets.Count -eq 0) { throw "No matching class in $CatalogPath (requested: $($ClassId -join ', '))" }

if (-not (Test-Path -LiteralPath $EvidenceDir)) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Registry token
# ---------------------------------------------------------------------------
# `az acr login --expose-token` silently switches the active az subscription,
# which resurfaces much later as an unrelated-looking 403 from `aca`. Re-assert
# the subscription immediately afterwards. (Same hazard documented on
# New-SquadSandboxDisk in scripts/lib/providers/squad-sandbox-provider.ps1.)
Write-Step "Acquiring an ACR pull token for $Registry"
$acrToken = (az acr login --name $Registry --expose-token --query accessToken -o tsv 2>$null)
if (-not $acrToken) { throw "Could not obtain an ACR token for $Registry. Run 'az login' first." }
az account set --subscription $Subscription | Out-Null
Write-Note "token acquired (never printed, never written to evidence)"

$created = [ordered]@{ Sandboxes = @(); Disks = @() }
$failures = @()
$written = @()

try {
    foreach ($cls in $targets) {
        $id = [string]$cls.id
        $reference = [string]$cls.image.reference
        $digest = [string]$cls.image.digest
        Write-Step "Class $id"

        if ($digest -notmatch $DigestPattern) {
            $failures += "$id : image.digest is not a sha256 digest, so there is nothing immutable to verify"
            continue
        }

        $declared = @()
        foreach ($t in @($cls.tools)) { $declared += [string]$t }
        $probe = @($declared + $AdditionalTools | Where-Object { $_ } | Sort-Object -Unique)
        $bad = @($probe | Where-Object { $_ -notmatch $ToolNamePattern })
        if ($bad.Count -gt 0) {
            $failures += "$id : refusing to probe tool name(s) outside $ToolNamePattern"
            continue
        }

        $imageRef = "$reference@$digest"
        $short = $digest.Substring(7, 10)
        $label = "evidence-$short"
        $probeLabel = "probe-$short"

        $diskIdForClass = $DiskId
        $diskCreatedHere = $false
        if (-not $diskIdForClass) {
            # Resolve first. A disk for this digest may already exist -- from an
            # earlier run, or because it is the disk the class is operated
            # from -- and a disk this run did not create is never deleted by it.
            $existing = Resolve-DiskIdByLabel -Label $label
            if ($existing.Error) {
                $failures += "$id : $($existing.Error)"
                continue
            }
            if ($existing.Id) {
                $diskIdForClass = $existing.Id
                Write-Note "reusing existing disk '$label' ($diskIdForClass)"
            } else {
                Write-Note "creating disk '$label' from $imageRef"
                $r = Invoke-Aca -Argv ((Get-CommonAcaArgs) + @(
                        "sandboxgroup", "disk", "create",
                        "--image", $imageRef,
                        "--name", $label,
                        "--username", $NullGuidUser,
                        "--token", $acrToken))
                if ($r.ExitCode -ne 0) {
                    $failures += "$id : disk create failed (exit $($r.ExitCode)): $($r.Output)"
                    continue
                }
                $resolved = Resolve-DiskIdByLabel -Label $label
                if ($resolved.Error) {
                    $failures += "$id : $($resolved.Error)"
                    continue
                }
                if (-not $resolved.Id) {
                    $failures += "$id : created disk '$label' but could not resolve its id from 'disk list'"
                    continue
                }
                $diskIdForClass = $resolved.Id
                $diskCreatedHere = $true
                $created.Disks += [pscustomobject]@{ Id = $diskIdForClass; Label = $label; ClassId = $id }
                Write-Note "disk id $diskIdForClass"
            }
        }

        Write-Note "creating probe sandbox '$probeLabel'"
        $r = Invoke-Aca -Argv ((Get-CommonAcaArgs) + @(
                "sandbox", "create",
                "--disk-id", $diskIdForClass,
                "--label", "name=$probeLabel",
                "--cpu", "2000m",
                "--memory", "4096Mi"))
        if ($r.ExitCode -ne 0) {
            $failures += "$id : sandbox create failed (exit $($r.ExitCode)): $($r.Output)"
            continue
        }
        $created.Sandboxes += [pscustomobject]@{ Label = $probeLabel; ClassId = $id }

        # One line per tool: "HAVE <tool>" or "MISS <tool>". A tool that reports
        # neither is treated as unobserved and fails the run rather than being
        # silently recorded as absent.
        $loop = "for t in $($probe -join ' '); do if command -v `"`$t`" >/dev/null 2>&1; then echo `"HAVE `$t`"; else echo `"MISS `$t`"; fi; done"
        $r = Invoke-Aca -Argv ((Get-CommonAcaArgs) + @("sandbox", "exec", "-l", "name=$probeLabel", "-c", $loop))
        if ($r.ExitCode -ne 0) {
            $failures += "$id : tool probe failed (exit $($r.ExitCode)): $($r.Output)"
            continue
        }

        $present = @()
        $absent = @()
        foreach ($line in ($r.Output -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^HAVE ([A-Za-z0-9._-]{1,64})$') { $present += $Matches[1] }
            elseif ($trimmed -match '^MISS ([A-Za-z0-9._-]{1,64})$') { $absent += $Matches[1] }
        }
        $observed = @($present + $absent)
        $unobserved = @($probe | Where-Object { $observed -notcontains $_ })
        if ($unobserved.Count -gt 0) {
            $failures += "$id : the probe returned no verdict for $($unobserved -join ', '); refusing to record partial evidence"
            continue
        }

        # Version strings for whatever is present, so a human can also check a
        # version claim (this class's id promises 3.12). Best effort: a tool
        # with no --version simply contributes nothing.
        $versions = [ordered]@{}
        if ($present.Count -gt 0) {
            $vcmd = "for t in $($present -join ' '); do v=`$(`"`$t`" --version 2>/dev/null | head -n 1); [ -n `"`$v`" ] && echo `"VER `$t `$v`"; done; true"
            $vr = Invoke-Aca -Argv ((Get-CommonAcaArgs) + @("sandbox", "exec", "-l", "name=$probeLabel", "-c", $vcmd))
            if ($vr.ExitCode -eq 0) {
                foreach ($line in ($vr.Output -split "`r?`n")) {
                    if ($line.Trim() -match '^VER ([A-Za-z0-9._-]{1,64}) (.{1,200})$') {
                        $versions[$Matches[1]] = ($Matches[2].Trim() -replace '[^\x20-\x7E]', '')
                    }
                }
            }
        }

        $doc = [ordered]@{
            schemaVersion = 1
            image         = [ordered]@{ reference = $reference; digest = $digest }
            verifiedAt    = (New-UtcStamp)
            method        = "aca sandbox exec: 'command -v <tool>' inside a sandbox created from this digest (scripts/verify-image-tools.ps1)"
            tools         = [ordered]@{
                present = @($present | Sort-Object)
                absent  = @($absent | Sort-Object)
            }
        }
        if ($versions.Count -gt 0) { $doc.toolVersions = $versions }

        $fileName = ($digest -replace ':', '-') + ".json"
        $target = Join-Path $EvidenceDir $fileName
        $json = ($doc | ConvertTo-Json -Depth 6)
        [System.IO.File]::WriteAllText($target, ($json -replace "`r`n", "`n") + "`n")
        $written += $target
        Write-Note "evidence written: config/image-evidence/$fileName"
        Write-Host "    HAVE: $($present -join ' ')" -ForegroundColor Green
        if ($absent.Count -gt 0) { Write-Host "    MISS: $($absent -join ' ')" -ForegroundColor Yellow }

        if ($diskCreatedHere -and $KeepDisk) {
            Write-Host "    KEEP disk id for ${id}: $diskIdForClass" -ForegroundColor Cyan
        }
    }
} finally {
    # Cleanup is unconditional. A probe sandbox that outlives the probe is a
    # bill nobody is watching.
    #
    # `sandbox delete` PROMPTS for confirmation without --yes. Under an
    # automation host there is no console to answer it, so omitting the flag
    # silently leaks the sandbox -- which is exactly what happened on the first
    # run of this script: two probe sandboxes survived and had to be swept by
    # hand. The delete is verified below rather than assumed.
    foreach ($sb in $created.Sandboxes) {
        Write-Step "Deleting probe sandbox $($sb.Label)"
        $d = Invoke-Aca -Argv ((Get-CommonAcaArgs) + @("sandbox", "delete", "-l", "name=$($sb.Label)", "--yes"))
        if ($d.ExitCode -ne 0) { Write-Warning "sandbox delete '$($sb.Label)' exit $($d.ExitCode): $($d.Output)" }
    }
    if (-not $KeepDisk) {
        foreach ($disk in $created.Disks) {
            Write-Step "Deleting probe disk $($disk.Label)"
            $d = Invoke-Aca -Argv ((Get-CommonAcaArgs) + @("sandboxgroup", "disk", "delete", "--id", $disk.Id))
            if ($d.ExitCode -ne 0) { Write-Warning "disk delete '$($disk.Label)' exit $($d.ExitCode): $($d.Output)" }
        }
    }
    # Prove the cleanup instead of trusting the exit code: a leaked sandbox
    # costs money every hour and the operator needs to know NOW, not at the
    # next invoice.
    if ($created.Sandboxes.Count -gt 0) {
        $after = Invoke-Aca -Argv ((Get-CommonAcaArgs) + @("sandbox", "list", "-o", "json"))
        if ($after.ExitCode -ne 0) {
            Write-Warning "Could not confirm probe sandbox cleanup ('sandbox list' exit $($after.ExitCode)). Check by hand."
        } else {
            $leaked = @()
            $rawAfter = $after.Output.Trim()
            if ($rawAfter) {
                try {
                    foreach ($sbx in @($rawAfter | ConvertFrom-Json)) {
                        if ($null -eq $sbx) { continue }
                        $lbl = $null
                        if (($sbx.PSObject.Properties.Name -contains "labels") -and $sbx.labels -and
                            ($sbx.labels.PSObject.Properties.Name -contains "name")) { $lbl = [string]$sbx.labels.name }
                        if ($lbl -and ($created.Sandboxes.Label -contains $lbl)) { $leaked += "$lbl ($($sbx.id))" }
                    }
                } catch {
                    Write-Warning "Could not confirm probe sandbox cleanup ('sandbox list' returned non-JSON). Check by hand."
                }
            }
            if ($leaked.Count -gt 0) {
                Write-Warning "LEAKED probe sandbox(es) still present: $($leaked -join ', '). Delete with: aca ... sandbox delete --id <id> --yes"
            } else {
                Write-Note "Confirmed: no probe sandbox from this run remains."
            }
        }
    }
}

Write-Host ""
if ($written.Count -gt 0) {
    Write-Host "Evidence files written:" -ForegroundColor Green
    $written | ForEach-Object { Write-Host "  - $_" -ForegroundColor Green }
}
if ($failures.Count -gt 0) {
    Write-Host "Failures:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Re-run the offline check to confirm the catalog now matches the evidence:" -ForegroundColor Cyan
Write-Host "  node worker/lib/verify-image-evidence.js" -ForegroundColor Cyan
exit 0
