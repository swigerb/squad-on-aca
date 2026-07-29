#requires -Version 5.1
<#
.SYNOPSIS
    Verifies `squad-aca`'s observable behaviour against committed golden
    captures. This is the CI gate for CLI output regressions.

.DESCRIPTION
    `scripts/tests/compare-cli-baseline.ps1` proves the strongest claim -- "this
    revision behaves exactly like <ref>" -- but it needs a second revision
    materialised with `git archive`, and it fails permanently once a CLI change
    is *intended*. That made it a manual developer tool, which is why the one
    class of regression that closed PR #9 (an observable `stop` output change)
    had no automated gate at all: CI ran only `worker/tests/run-tests.sh` and
    `scripts/validate.ps1`, and neither compared stdout.

    This script closes that gap with the pattern the worker suite already uses
    for routing decisions (docs/validation.md, "Golden decision fixtures"): the
    same 22 CLI invocations are driven through the stubbed `az`/`gh`/`squad`
    environment, and each capture -- exit code, every `az`/`gh`/`squad` argv,
    stdout and stderr -- is compared against a file committed under
    scripts/tests/golden/cli/.

    An intended CLI change is therefore a reviewable diff in the goldens rather
    than a silently-accepted behaviour change. Regenerate with -Update and
    review the diff before committing.

    Captures are made machine-portable in two ways, both documented in full in
    docs/validation.md ("What makes a golden portable") and in
    Get-PortableCapture. Environment dependence is PINNED at the source where
    possible -- the stub fixtures' timestamps carry no UTC offset (host time
    zone), the CLI child runs with DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 (host
    culture), and the optional `squad` CLI is stubbed onto PATH (host tool
    availability). What cannot be pinned is masked: <TS>, <SCRIPTS>, <STUB>,
    <LINE>, <TMP>, <HOME>, <SHA>, ANSI SGR sequences, PowerShell's
    console-width-truncated error-record source echo, and CRLF. Nothing else:
    exit codes, every az/gh/squad argv and all message text are compared byte
    for byte.

    Requires Windows: the `az`/`gh` stubs are .cmd shims.

.PARAMETER Update
    Regenerate the goldens from the working tree instead of verifying.

.PARAMETER GoldenDir
    Directory holding the goldens. Defaults to scripts/tests/golden/cli.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\tests\verify-cli-golden.ps1
    pwsh -NoProfile -File .\scripts\tests\verify-cli-golden.ps1 -Update
#>
[CmdletBinding()]
param(
    [switch]$Update,
    [string]$GoldenDir = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

. (Join-Path $ScriptDir "cli-stub-harness.ps1")
. (Join-Path $ScriptDir "cli-capture-cases.ps1")

if (-not $GoldenDir) { $GoldenDir = Join-Path $ScriptDir "golden\cli" }

$isWindowsHost = if ($null -ne $PSVersionTable.Platform) { $PSVersionTable.Platform -eq "Win32NT" } else { $true }
if (-not $isWindowsHost) {
    Write-Host "SKIP: the CLI golden gate needs the .cmd az/gh stubs (Windows only)." -ForegroundColor Yellow
    exit 0
}

$captureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("squad-cli-golden-" + [guid]::NewGuid().ToString("N"))
try {
    Write-Host "Capturing squad-aca behaviour from the working tree..." -ForegroundColor Cyan
    Invoke-CaptureSet -ScriptsRoot (Join-Path $RepoRoot "scripts") -OutDir $captureDir -Portable

    if ($Update) {
        New-Item -ItemType Directory -Force -Path $GoldenDir | Out-Null
        Get-ChildItem -Path $GoldenDir -Filter *.txt -File | Remove-Item -Force
        foreach ($file in (Get-ChildItem -Path $captureDir -File | Sort-Object Name)) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $GoldenDir $file.Name) -Force
        }
        Write-Host "`nWrote $((Get-ChildItem $GoldenDir -Filter *.txt).Count) golden capture(s) to $GoldenDir." -ForegroundColor Green
        Write-Host "Review the diff: every changed byte is a change a user would see." -ForegroundColor Yellow
        exit 0
    }

    if (-not (Test-Path $GoldenDir)) {
        Write-Host "No golden captures found at $GoldenDir. Generate them with -Update." -ForegroundColor Red
        exit 1
    }

    $captured = @(Get-ChildItem -Path $captureDir -File | Sort-Object Name)
    $golden = @(Get-ChildItem -Path $GoldenDir -Filter *.txt -File | Sort-Object Name)

    $differing = @()
    $missing = @()
    foreach ($file in $captured) {
        $goldenPath = Join-Path $GoldenDir $file.Name
        if (-not (Test-Path $goldenPath)) { $missing += $file.Name; continue }
        $expected = [System.IO.File]::ReadAllText($goldenPath) -replace "`r`n", "`n"
        $actual = [System.IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n"
        if ($expected -cne $actual) { $differing += $file.Name }
    }
    $extra = @($golden | Where-Object { -not (Test-Path (Join-Path $captureDir $_.Name)) } | ForEach-Object { $_.Name })

    Write-Host ""
    Write-Host ("Cases compared: {0}   matching goldens: {1}" -f $captured.Count, ($captured.Count - $differing.Count - $missing.Count))

    if ($differing.Count -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0) {
        Write-Host "`nsquad-aca observable behaviour matches the committed goldens." -ForegroundColor Green
        exit 0
    }

    if ($missing.Count -gt 0) {
        Write-Host "`nNo golden committed for: $($missing -join ', ')" -ForegroundColor Red
    }
    if ($extra.Count -gt 0) {
        Write-Host "`nGolden(s) with no matching case: $($extra -join ', ')" -ForegroundColor Red
    }
    if ($differing.Count -gt 0) {
        Write-Host "`nOBSERVABLE BEHAVIOUR CHANGED in: $($differing -join ', ')" -ForegroundColor Red
        foreach ($name in $differing) {
            Write-Host "`n--- $name ---" -ForegroundColor Red
            $a = ([System.IO.File]::ReadAllText((Join-Path $GoldenDir $name)) -replace "`r`n", "`n") -split "`n"
            $b = ([System.IO.File]::ReadAllText((Join-Path $captureDir $name)) -replace "`r`n", "`n") -split "`n"
            Compare-Object $a $b | Format-Table -AutoSize | Out-String | Write-Host
        }
    }
    Write-Host "If the change is intended, regenerate with -Update and commit the reviewed diff." -ForegroundColor Yellow
    exit 1
} finally {
    Remove-Item -Recurse -Force $captureDir -ErrorAction SilentlyContinue
}
