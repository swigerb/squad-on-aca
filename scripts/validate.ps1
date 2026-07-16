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
      2. Bash syntax check  - `bash -n` on worker/entrypoint.sh and the
                              worker/lib/*.sh helpers when bash exists.
      3. Secret scan        - scans tracked docs/, scripts/, worker/, and
                              aspire/ for credential file patterns and inline
                              token signatures. Generated build output
                              (bin/, obj/, node_modules/) and binary files are
                              skipped.
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
Write-Section "Worker bash scripts (bash -n)"
$bashScripts = @(
    (Join-Path $RepoRoot "worker\entrypoint.sh"),
    (Join-Path $RepoRoot "worker\lib\squad-capability-preflight.sh"),
    (Join-Path $RepoRoot "worker\lib\ralph-dispatch.sh"),
    (Join-Path $RepoRoot "worker\lib\git-checkout.sh")
)
if ($SkipBash) {
    Write-Host "  [SKIP] -SkipBash specified"
} else {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        Write-Host "  [SKIP] bash not available on PATH"
    } else {
        foreach ($script in $bashScripts) {
            $rel = if ($script.StartsWith($RepoRoot)) { $script.Substring($RepoRoot.Length + 1) } else { $script }
            if (-not (Test-Path $script)) {
                Add-Fail "$rel not found"
                continue
            }
            # Pipe CRLF-normalized content to `bash -n` via stdin so we avoid any
            # Windows<->bash path translation differences (WSL vs Git Bash).
            $raw = Get-Content -LiteralPath $script -Raw
            $lf = $raw -replace "`r`n", "`n"
            $lf | & $bash.Source -n
            if ($LASTEXITCODE -eq 0) {
                Add-Pass "$rel passed bash -n"
            } else {
                Add-Fail "$rel failed bash -n (exit $LASTEXITCODE)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Secret scan of tracked docs/, scripts/, and aspire/
# ---------------------------------------------------------------------------
Write-Section "Secret scan (docs + scripts + worker + aspire)"
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

$scanRoots = @("docs", "scripts", "worker", "aspire") | ForEach-Object { Join-Path $RepoRoot $_ }
$scanFiles = foreach ($root in $scanRoots) {
    if (Test-Path $root) {
        # Skip generated build output (bin/, obj/) and installed dependencies
        # (node_modules/) so the scan stays fast and only covers
        # source-controlled, human-authored files.
        Get-ChildItem -Path $root -File -Recurse |
            Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules)\\' }
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
if ($secretHits -eq 0) { Add-Pass "No secret patterns found in docs/, scripts/, worker/, or aspire/" }

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
# 5. Session-managed env key parity (PowerShell vs worker)
# ---------------------------------------------------------------------------
# Session isolation depends on dispatch stripping the SAME set of session-managed
# keys from the job template in both dispatch paths: the PowerShell control plane
# (scripts/lib/session-env.ps1) and the in-container worker (worker/lib/
# ralph-dispatch.sh). If the two lists drift, one path could leak a stale
# template value into a new session. Fail on any drift.
Write-Section "Session-managed env key parity"
$psEnvFile = Join-Path $RepoRoot "scripts\lib\session-env.ps1"
$shEnvFile = Join-Path $RepoRoot "worker\lib\ralph-dispatch.sh"

function Get-QuotedListBlock([string]$Text, [string]$StartMarker) {
    $idx = $Text.IndexOf($StartMarker)
    if ($idx -lt 0) { return $null }
    $rest = $Text.Substring($idx + $StartMarker.Length)
    $close = $rest.IndexOf(')')
    if ($close -lt 0) { return $null }
    return $rest.Substring(0, $close)
}

if (-not (Test-Path $psEnvFile)) {
    Add-Fail "scripts/lib/session-env.ps1 not found for env parity check"
} elseif (-not (Test-Path $shEnvFile)) {
    Add-Fail "worker/lib/ralph-dispatch.sh not found for env parity check"
} else {
    $psText = Get-Content -LiteralPath $psEnvFile -Raw
    $shText = Get-Content -LiteralPath $shEnvFile -Raw

    # PowerShell: keys are double-quoted inside $script:SessionManagedEnvKeys = @( ... )
    $psBlock = Get-QuotedListBlock $psText 'SessionManagedEnvKeys = @('
    $psKeys = @()
    if ($psBlock) {
        $psKeys = [regex]::Matches($psBlock, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    }

    # Bash: keys are bare, whitespace-separated inside RALPH_MANAGED_ENV_KEYS=( ... )
    $shBlock = Get-QuotedListBlock $shText 'RALPH_MANAGED_ENV_KEYS=('
    $shKeys = @()
    if ($shBlock) {
        $shKeys = ($shBlock -split '\s+') | Where-Object { $_ -and ($_ -notmatch '^#') }
    }

    if ($psKeys.Count -eq 0) {
        Add-Fail "Could not parse SessionManagedEnvKeys from session-env.ps1"
    } elseif ($shKeys.Count -eq 0) {
        Add-Fail "Could not parse RALPH_MANAGED_ENV_KEYS from ralph-dispatch.sh"
    } else {
        $psSet = $psKeys | Sort-Object -Unique
        $shSet = $shKeys | Sort-Object -Unique
        $onlyPs = $psSet | Where-Object { $_ -notin $shSet }
        $onlySh = $shSet | Where-Object { $_ -notin $psSet }
        if ($onlyPs.Count -gt 0 -or $onlySh.Count -gt 0) {
            if ($onlyPs.Count -gt 0) {
                Add-Fail "Session-managed env keys only in session-env.ps1 (missing from ralph-dispatch.sh): $($onlyPs -join ', ')"
            }
            if ($onlySh.Count -gt 0) {
                Add-Fail "Session-managed env keys only in ralph-dispatch.sh (missing from session-env.ps1): $($onlySh -join ', ')"
            }
        } else {
            Add-Pass "Session-managed env keys match across session-env.ps1 and ralph-dispatch.sh ($($psSet.Count) keys)"
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Sync guard uses -uall (nested untracked secrets cannot evade the scan)
# ---------------------------------------------------------------------------
# Regression guard for the public-repo sync guard: `git status --porcelain`
# collapses a brand-new directory to a single entry, so nested secrets inside it
# would never be scanned even though `git add -A` (run by --sync-all) still
# stages them. Test-SyncSafety MUST enumerate with `-uall`. Assert the source
# still uses it, then run the real guard against a throwaway repo containing
# nested secrets to prove nested detection and ignored-file exclusion.
Write-Section "Sync guard secret enumeration (-uall)"
$syncSafetyFile = Join-Path $RepoRoot "scripts\lib\sync-safety.ps1"
if (-not (Test-Path $syncSafetyFile)) {
    Add-Fail "scripts/lib/sync-safety.ps1 not found"
} else {
    $syncText = Get-Content -LiteralPath $syncSafetyFile -Raw
    if ($syncText -match 'git status --porcelain -uall') {
        Add-Pass "Test-SyncSafety enumerates untracked files with -uall"
    } else {
        Add-Fail "Test-SyncSafety does not use 'git status --porcelain -uall' (nested untracked secrets could evade the scan)"
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Host "  [SKIP] git not available for functional sync-guard test"
    } else {
        . $syncSafetyFile
        $tmpRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-guard-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $tmpRepo | Out-Null
        $prevAllow = $env:SQUAD_ACA_ALLOW_UNSAFE_SYNC
        $env:SQUAD_ACA_ALLOW_UNSAFE_SYNC = $null
        Push-Location $tmpRepo
        try {
            git init -q 2>$null | Out-Null
            git config user.email "test@example.com" 2>$null | Out-Null
            git config user.name "Sync Guard Test" 2>$null | Out-Null

            # Ignored file that would otherwise trip the guard -> must be excluded.
            Set-Content -Path (Join-Path $tmpRepo ".gitignore") -Value "ignored/`n" -NoNewline
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "ignored") | Out-Null
            Set-Content -Path (Join-Path $tmpRepo "ignored\secrets.json") -Value '{"token":"should-be-ignored"}'

            # Nested UNTRACKED secrets inside brand-new directories. Plain
            # --porcelain would collapse these to their top-level dir and miss them.
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "nested\deep") | Out-Null
            Set-Content -Path (Join-Path $tmpRepo "nested\deep\secrets.json") -Value '{"api":"value"}'
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "certs\sub") | Out-Null
            Set-Content -Path (Join-Path $tmpRepo "certs\sub\server.pem") -Value "placeholder-cert-material"
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "src\app") | Out-Null
            # PAT-like token embedded in nested source (constructed so this file is not itself a secret filename).
            $pat = 'ghp_' + ('A' * 36)
            Set-Content -Path (Join-Path $tmpRepo "src\app\config.txt") -Value "token = $pat"

            $reasons = Test-SyncSafety

            $hasNestedJson = @($reasons | Where-Object { $_ -match 'nested/deep/secrets\.json' }).Count -gt 0
            $hasPem = @($reasons | Where-Object { $_ -match 'certs/sub/server\.pem' }).Count -gt 0
            $hasPat = @($reasons | Where-Object { $_ -match 'src/app/config\.txt' }).Count -gt 0
            $leakedIgnored = @($reasons | Where-Object { $_ -match 'ignored/secrets\.json' }).Count -gt 0

            if ($hasNestedJson) { Add-Pass "Sync guard flags nested untracked secrets.json" }
            else { Add-Fail "Sync guard missed nested untracked secrets.json (--porcelain -uall regression)" }
            if ($hasPem) { Add-Pass "Sync guard flags nested untracked .pem" }
            else { Add-Fail "Sync guard missed nested untracked .pem" }
            if ($hasPat) { Add-Pass "Sync guard flags nested source containing a PAT-like token" }
            else { Add-Fail "Sync guard missed nested source containing a PAT-like token" }
            if (-not $leakedIgnored) { Add-Pass "Sync guard excludes git-ignored files" }
            else { Add-Fail "Sync guard flagged a git-ignored file (should be excluded)" }
        } finally {
            Pop-Location
            $env:SQUAD_ACA_ALLOW_UNSAFE_SYNC = $prevAllow
            Remove-Item -Recurse -Force $tmpRepo -ErrorAction SilentlyContinue
        }
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
