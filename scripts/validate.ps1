#requires -Version 5.1
<#
.SYNOPSIS
    Local validation harness for Squad on ACA.

.DESCRIPTION
    This repository is script- and infrastructure-heavy, so there is no unit
    test project to run. validate.ps1 performs the checks that are practical to
    run locally and in CI without touching live Azure resources:

      1. PowerShell parse   - every scripts/*.ps1 is parsed with the PowerShell
                              language parser (syntax + tokenization).
      2. Bash syntax check  - `bash -n` on worker/entrypoint.sh when bash exists.
      3. Secret scan        - scans tracked docs/, scripts/, and aspire/ for
                              credential file patterns and inline token
                              signatures. Generated build output (bin/, obj/)
                              and binary files are skipped.
      4. .NET scaffold check- validates the optional aspire/ integration scaffold
                              structure (solution + AppHost project + README) and
                              optionally runs `dotnet build` with -RunDotnet.

    Exit code is 0 when all checks pass, 1 otherwise. Use this before pushing
    and as the E2E "sprint gate" documented in docs/validation.md.

.PARAMETER RunDotnet
    Also run `dotnet restore`/`dotnet build` on the optional aspire scaffold.
    Off by default because preview package restore can be brittle offline.

.PARAMETER SkipBash
    Skip the `bash -n` worker entrypoint check (for environments without bash).
#>
[CmdletBinding()]
param(
    [switch]$RunDotnet,
    [switch]$SkipBash
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

$script:Failures = @()
$script:Passes = @()

function Write-Section($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Add-Pass($text) { $script:Passes += $text; Write-Host "  [PASS] $text" -ForegroundColor Green }
function Add-Fail($text) { $script:Failures += $text; Write-Host "  [FAIL] $text" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. PowerShell parse
# ---------------------------------------------------------------------------
Write-Section "PowerShell parse"
$psFiles = Get-ChildItem -Path (Join-Path $RepoRoot "scripts") -Filter *.ps1 -File -Recurse
foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            Add-Fail ("{0}: {1} (line {2})" -f $file.Name, $e.Message, $e.Extent.StartLineNumber)
        }
    } else {
        Add-Pass "$($file.Name) parsed clean"
    }
}

# ---------------------------------------------------------------------------
# 2. Bash syntax check for the worker entrypoint
# ---------------------------------------------------------------------------
Write-Section "Worker entrypoint (bash -n)"
$entrypoint = Join-Path $RepoRoot "worker\entrypoint.sh"
if (-not (Test-Path $entrypoint)) {
    Add-Fail "worker/entrypoint.sh not found"
} elseif ($SkipBash) {
    Write-Host "  [SKIP] -SkipBash specified"
} else {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        Write-Host "  [SKIP] bash not available on PATH"
    } else {
        # Pipe CRLF-normalized content to `bash -n` via stdin so we avoid any
        # Windows<->bash path translation differences (WSL vs Git Bash).
        $raw = Get-Content -LiteralPath $entrypoint -Raw
        $lf = $raw -replace "`r`n", "`n"
        $lf | & $bash.Source -n
        if ($LASTEXITCODE -eq 0) {
            Add-Pass "worker/entrypoint.sh passed bash -n"
        } else {
            Add-Fail "worker/entrypoint.sh failed bash -n (exit $LASTEXITCODE)"
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Secret scan of tracked docs/, scripts/, and aspire/
# ---------------------------------------------------------------------------
Write-Section "Secret scan (docs + scripts + aspire)"
$secretPatterns = @(
    @{ Name = "GitHub token";        Regex = 'gh[pousr]_[A-Za-z0-9]{30,}' },
    @{ Name = "GitHub fine PAT";     Regex = 'github_pat_[A-Za-z0-9_]{40,}' },
    @{ Name = "AWS access key";      Regex = 'AKIA[0-9A-Z]{16}' },
    @{ Name = "Private key block";   Regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = "Slack token";         Regex = 'xox[baprs]-[A-Za-z0-9-]{10,}' },
    @{ Name = "Azure storage key";   Regex = 'AccountKey=[A-Za-z0-9+/=]{40,}' },
    @{ Name = "OpenAI-style key";    Regex = 'sk-[A-Za-z0-9]{32,}' }
)
# Allow-listed placeholders that legitimately look token-ish in docs.
$allowList = @('secretref:', 'keyvaultref:', 'identityref:', '<', '>')

$scanRoots = @("docs", "scripts", "aspire") | ForEach-Object { Join-Path $RepoRoot $_ }
$scanFiles = foreach ($root in $scanRoots) {
    if (Test-Path $root) {
        # Skip generated build output (bin/, obj/) so the scan stays fast and
        # only covers source-controlled, human-authored files.
        Get-ChildItem -Path $root -File -Recurse |
            Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
    }
}
# Extensions that are binary/compiled and never contain reviewable secrets.
$binaryExtensions = @(
    '.png', '.jpg', '.jpeg', '.gif', '.ico', '.pfx', '.pem',
    '.dll', '.exe', '.pdb', '.nupkg', '.zip', '.snk', '.cache', '.bin'
)
$secretHits = 0
foreach ($file in $scanFiles) {
    if ($file.Extension -in $binaryExtensions) { continue }
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    foreach ($p in $secretPatterns) {
        $matches = [regex]::Matches($content, $p.Regex)
        foreach ($m in $matches) {
            $isAllowed = $false
            foreach ($a in $allowList) { if ($m.Value.Contains($a)) { $isAllowed = $true; break } }
            if (-not $isAllowed) {
                $rel = $file.FullName.Substring($RepoRoot.Length + 1)
                Add-Fail "Possible $($p.Name) in $rel : $($m.Value.Substring(0, [Math]::Min(12, $m.Value.Length)))..."
                $secretHits++
            }
        }
    }
}
# Also flag credential filenames committed under docs/scripts.
$badNames = $scanFiles | Where-Object {
    $_.Name -match '(^\.env($|\.)|deploy\.outputs\.json$|\.pfx$|id_rsa|id_ed25519|appsettings.*\.Development\.json$)'
}
foreach ($bad in $badNames) {
    $rel = $bad.FullName.Substring($RepoRoot.Length + 1)
    Add-Fail "Credential-style file tracked under docs/scripts/aspire: $rel"
    $secretHits++
}
if ($secretHits -eq 0) { Add-Pass "No secret patterns found in docs/, scripts/, or aspire/" }

# ---------------------------------------------------------------------------
# 4. Optional .NET/Aspire scaffold structure
# ---------------------------------------------------------------------------
Write-Section ".NET/Aspire scaffold"
$aspireDir = Join-Path $RepoRoot "aspire"
if (-not (Test-Path $aspireDir)) {
    Write-Host "  [SKIP] optional aspire/ scaffold not present"
} else {
    $expected = @(
        "Squad.Aca.sln",
        "Squad.Aca.AppHost\Squad.Aca.AppHost.csproj",
        "Squad.Aca.AppHost\AppHost.cs",
        "README.md"
    )
    foreach ($rel in $expected) {
        $full = Join-Path $aspireDir $rel
        if (Test-Path $full) { Add-Pass "aspire/$rel present" }
        else { Add-Fail "aspire/$rel missing" }
    }

    # Every .csproj under aspire/ must be well-formed XML.
    $csprojs = Get-ChildItem -Path $aspireDir -Filter *.csproj -File -Recurse
    foreach ($csproj in $csprojs) {
        try {
            [void][xml](Get-Content -LiteralPath $csproj.FullName -Raw)
            Add-Pass "$($csproj.Name) is valid XML"
        } catch {
            Add-Fail "$($csproj.Name) is not valid XML: $($_.Exception.Message)"
        }
    }

    if ($RunDotnet) {
        $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $dotnet) {
            Add-Fail "-RunDotnet specified but dotnet is not on PATH"
        } else {
            Write-Host "  Running dotnet build (may restore preview packages)..."
            Push-Location $aspireDir
            try {
                & $dotnet.Source build "Squad.Aca.sln" -nologo --verbosity quiet
                if ($LASTEXITCODE -eq 0) { Add-Pass "dotnet build succeeded" }
                else { Add-Fail "dotnet build failed (exit $LASTEXITCODE) - see docs/validation.md for preview-package guidance" }
            } finally {
                Pop-Location
            }
        }
    } else {
        Write-Host "  [SKIP] dotnet build (pass -RunDotnet to enable)"
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Section "Summary"
Write-Host ("  Passed: {0}" -f $script:Passes.Count) -ForegroundColor Green
Write-Host ("  Failed: {0}" -f $script:Failures.Count) -ForegroundColor ($(if ($script:Failures.Count -gt 0) { 'Red' } else { 'Green' }))
if ($script:Failures.Count -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nAll validation checks passed." -ForegroundColor Green
exit 0
