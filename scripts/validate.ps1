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
      5. Env key parity     - session-managed env keys must match between the
                              PowerShell and worker dispatch paths.
      6. Sync guard         - regression tests for the public-repo secret guard.
      7. Logs fallback      - regression tests for `squad-aca logs` (issue #13):
                              exit-code propagation, suppressed interactive
                              extension install, and the Log Analytics fallback.
                              Uses a fake `az` on PATH; no Azure access.

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
# 6. Sync guard covers every file `git add -A` would stage (NUL-delimited)
# ---------------------------------------------------------------------------
# Regression guard for the public-repo sync guard. Two historical bypasses are
# covered here:
#   1. Plain `git status --porcelain` collapses a brand-new directory to a
#      single entry, so nested secrets inside it would never be scanned even
#      though `git add -A` still stages them.
#   2. Non-ASCII / special-character paths are C-quoted and octal-escaped by
#      porcelain (e.g. "caf\303\251/config.txt"). The escaped string fails
#      Test-Path, so the file's content is never scanned -- a secret-guard
#      bypass -- even though `git add -A` stages the real file.
# Test-SyncSafety MUST enumerate with NUL-delimited git output. Assert the
# source uses `-z` (and no longer the escape-prone porcelain path), then run the
# real guard against a throwaway repo containing nested secrets AND quoted/
# escaped/non-ASCII paths to prove detection and ignored-file exclusion.
Write-Section "Sync guard secret enumeration (NUL-delimited)"
$syncSafetyFile = Join-Path $RepoRoot "scripts\lib\sync-safety.ps1"
if (-not (Test-Path $syncSafetyFile)) {
    Add-Fail "scripts/lib/sync-safety.ps1 not found"
} else {
    $syncText = Get-Content -LiteralPath $syncSafetyFile -Raw
    if ($syncText -match 'ls-files --others --exclude-standard -z' -and $syncText -match "diff', '--name-only', '-z'") {
        Add-Pass "Test-SyncSafety enumerates candidates with NUL-delimited (-z) git output"
    } else {
        Add-Fail "Test-SyncSafety does not use NUL-delimited (-z) enumeration (quoted/escaped paths could evade the scan)"
    }
    if ($syncText -match '=\s*git status --porcelain') {
        Add-Fail "Test-SyncSafety still invokes escape-prone 'git status --porcelain' (non-ASCII paths get octal-escaped and skip content scanning)"
    } else {
        Add-Pass "Test-SyncSafety no longer invokes quote-prone 'git status --porcelain'"
    }

    # Bypass #1 (root-relative coverage): enumeration must be rooted at the repo
    # top level so a nested invocation still sees the whole working tree.
    if ($syncText -match 'rev-parse --show-toplevel') {
        Add-Pass "Test-SyncSafety discovers the repo root (rev-parse --show-toplevel) so nested invocations cover the whole tree"
    } else {
        Add-Fail "Test-SyncSafety does not discover the repo root; a nested invocation could miss root-level/sibling files git add -A stages"
    }

    # Bypass #2 (byte-safe NUL parsing): git output must be read as raw bytes via
    # a redirected process stream, never line-split by the PowerShell pipeline.
    if ($syncText -match 'RedirectStandardOutput' -and $syncText -match 'BaseStream') {
        Add-Pass "Test-SyncSafety reads git output byte-safely (redirected process BaseStream), avoiding pipeline newline splitting"
    } else {
        Add-Fail "Test-SyncSafety relies on pipeline splitting of native output; filenames containing newlines could bypass content scanning"
    }

    # Bypass #3 (case-sensitive dedupe): candidates must be de-duplicated with an
    # ordinal comparer, not PowerShell's case-insensitive Sort-Object -Unique.
    if ($syncText -match 'StringComparer\]::Ordinal') {
        Add-Pass "Test-SyncSafety de-duplicates candidates with case-sensitive ordinal semantics (distinct case-only paths preserved)"
    } else {
        Add-Fail "Test-SyncSafety de-duplicates candidates case-insensitively; distinct case-only paths could collapse and leave one unscanned"
    }

    # Deterministic unit test for the raw NUL parser. A filename that contains a
    # newline is legal on Linux/macOS; the parser must split ONLY on NUL so such a
    # path survives intact rather than being torn apart the way the PowerShell
    # pipeline would tear native command output. Feed synthetic UTF-8 bytes so the
    # test is platform-independent (Windows cannot create a newline-named file).
    . $syncSafetyFile
    if (Get-Command ConvertFrom-NulDelimitedByte -ErrorAction SilentlyContinue) {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        # Two entries: "dir/we<LF>ird.txt" and "plain.txt", NUL-terminated.
        $synthetic = "dir/we`nird.txt`0plain.txt`0caf$([char]0x00E9)/x.env`0"
        $parsed = ConvertFrom-NulDelimitedByte -Bytes ($utf8.GetBytes($synthetic))
        $parsedCount = @($parsed).Count
        $keptNewline = @($parsed | Where-Object { $_ -eq "dir/we`nird.txt" }).Count -eq 1
        $keptNonAscii = @($parsed | Where-Object { $_ -eq "caf$([char]0x00E9)/x.env" }).Count -eq 1
        if ($parsedCount -eq 3 -and $keptNewline -and $keptNonAscii) {
            Add-Pass "Raw NUL parser splits only on NUL: newline-containing and non-ASCII paths survive intact"
        } else {
            Add-Fail "Raw NUL parser mishandled synthetic input (count=$parsedCount, newline kept=$keptNewline, non-ASCII kept=$keptNonAscii)"
        }
    } else {
        Add-Fail "ConvertFrom-NulDelimitedByte helper not defined; cannot unit test byte-safe NUL parsing"
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

            # Tricky path segments that git C-quotes/escapes in plain porcelain.
            # Built from char codes so the test does not depend on this file's
            # source encoding. Windows forbids " * : < > ? | in names, so we use
            # spaces, brackets, and non-ASCII (é / Cyrillic) which are the real
            # triggers for git's octal-escaped quoting.
            $eacute = [char]0x00E9          # é
            $cyrKa  = [char]0x043A          # к
            $nonAsciiDir = "caf$eacute dir [x]"   # non-ASCII + space + brackets
            $cyrDir      = "$($cyrKa)eys sub"     # Cyrillic + space
            $pat = 'ghp_' + ('A' * 36)

            # Ignored file (non-ASCII path) that would otherwise trip the guard.
            # .gitignore MUST be written UTF-8: git compares the pattern bytes
            # against UTF-8-encoded paths, so an ANSI-encoded non-ASCII pattern
            # would silently fail to match and the file would leak into the scan.
            $ignoredDir = "ignored-$eacute"
            [System.IO.File]::WriteAllText(
                (Join-Path $tmpRepo ".gitignore"),
                "$ignoredDir/`n",
                (New-Object System.Text.UTF8Encoding $false))
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo $ignoredDir) | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "$ignoredDir\secrets.json") -Value '{"token":"should-be-ignored"}'

            # Nested UNTRACKED secrets inside brand-new directories (plain
            # --porcelain would collapse these to their top-level dir).
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "nested\deep") | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "nested\deep\secrets.json") -Value '{"api":"value"}'
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "certs\sub") | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "certs\sub\server.pem") -Value "placeholder-cert-material"
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "src\app") | Out-Null
            $pat0 = 'ghp_' + ('A' * 36)
            Set-Content -LiteralPath (Join-Path $tmpRepo "src\app\config.txt") -Value "token = $pat0"

            # Root-level denylisted secret. Used by the nested-invocation test
            # below: a guard run from a deep subdirectory must still catch this
            # root file that `git add -A` stages.
            Set-Content -LiteralPath (Join-Path $tmpRepo ".env") -Value "API_KEY=root-level-secret"

            # Denylisted secret filename at a QUOTED/ESCAPED non-ASCII path.
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo $nonAsciiDir) | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "$nonAsciiDir\secrets.json") -Value '{"api":"value"}'
            # PAT-like token in a text file at a QUOTED/ESCAPED non-ASCII path
            # (filename itself is not a secret name, so only content scanning
            # catches it -- exactly the path the old escaped-string bug skipped).
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo $cyrDir) | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "$cyrDir\config.txt") -Value "token = $pat"

            $reasons = Test-SyncSafety

            $hasNestedJson = @($reasons | Where-Object { $_ -match 'nested/deep/secrets\.json' }).Count -gt 0
            $hasPem = @($reasons | Where-Object { $_ -match 'certs/sub/server\.pem' }).Count -gt 0
            $hasPat = @($reasons | Where-Object { $_ -match 'src/app/config\.txt' }).Count -gt 0
            $leakedIgnored = @($reasons | Where-Object { $_ -match 'secrets\.json' -and $_ -match [regex]::Escape($ignoredDir) }).Count -gt 0
            $hasNonAsciiDeny = @($reasons | Where-Object { $_ -match [regex]::Escape("$nonAsciiDir/secrets.json") }).Count -gt 0
            $hasNonAsciiPat  = @($reasons | Where-Object { $_ -match [regex]::Escape("$cyrDir/config.txt") }).Count -gt 0

            if ($hasNestedJson) { Add-Pass "Sync guard flags nested untracked secrets.json" }
            else { Add-Fail "Sync guard missed nested untracked secrets.json (nested-enumeration regression)" }
            if ($hasPem) { Add-Pass "Sync guard flags nested untracked .pem" }
            else { Add-Fail "Sync guard missed nested untracked .pem" }
            if ($hasPat) { Add-Pass "Sync guard flags nested source containing a PAT-like token" }
            else { Add-Fail "Sync guard missed nested source containing a PAT-like token" }
            if ($hasNonAsciiDeny) { Add-Pass "Sync guard flags denylisted secret at a quoted/escaped non-ASCII path" }
            else { Add-Fail "Sync guard missed denylisted secret at a quoted/escaped non-ASCII path (porcelain-escape regression)" }
            if ($hasNonAsciiPat) { Add-Pass "Sync guard flags PAT-like token in a text file at a quoted/escaped non-ASCII path" }
            else { Add-Fail "Sync guard missed PAT-like token at a quoted/escaped non-ASCII path (content skipped due to unescaped path)" }
            if (-not $leakedIgnored) { Add-Pass "Sync guard excludes git-ignored files (including non-ASCII paths)" }
            else { Add-Fail "Sync guard flagged a git-ignored file (should be excluded)" }

            # Bypass #1 regression: run the guard from a DEEP nested subdirectory.
            # `git add -A` stages the whole tree, but git scopes diff/ls-files
            # output to the current directory -- so a guard that enumerated from
            # cwd would only see files under nested/deep and miss the root-level
            # .env and the sibling certs/sub/server.pem. Repo-root-rooted
            # enumeration must still catch both.
            $nestedDir = Join-Path $tmpRepo "nested\deep"
            Push-Location $nestedDir
            try {
                $nestedReasons = Test-SyncSafety
                $nestedCatchesRoot = @($nestedReasons | Where-Object { $_ -match 'Blocked file: \.env ' }).Count -gt 0
                $nestedCatchesSibling = @($nestedReasons | Where-Object { $_ -match 'certs/sub/server\.pem' }).Count -gt 0
                $nestedCatchesLocal = @($nestedReasons | Where-Object { $_ -match 'nested/deep/secrets\.json' }).Count -gt 0
                if ($nestedCatchesRoot) { Add-Pass "Sync guard run from a nested dir still catches the root-level .env" }
                else { Add-Fail "Sync guard run from a nested dir missed the root-level .env (nested-cwd enumeration regression)" }
                if ($nestedCatchesSibling) { Add-Pass "Sync guard run from a nested dir still catches a sibling nested secret (certs/sub/server.pem)" }
                else { Add-Fail "Sync guard run from a nested dir missed a sibling nested secret (nested-cwd enumeration regression)" }
                if ($nestedCatchesLocal) { Add-Pass "Sync guard run from a nested dir reports paths repo-root-relative (nested/deep/secrets.json)" }
                else { Add-Fail "Sync guard run from a nested dir did not report the local nested secret repo-relative" }
            } finally {
                Pop-Location
            }
        } finally {
            Pop-Location
            $env:SQUAD_ACA_ALLOW_UNSAFE_SYNC = $prevAllow
            Remove-Item -Recurse -Force $tmpRepo -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 7. squad-aca logs: exit-code propagation, no interactive install, LA fallback
# ---------------------------------------------------------------------------
# Regression guard for GitHub issue #13. `squad-aca logs` used to call
# `az containerapp job logs show` (a `containerapp` CLI *extension* command) as
# the last statement of Invoke-Logs. On a host without the extension az printed
# an argparse traceback, blocked on an interactive install prompt, and the
# command still exited 0 -- a false green during incident response.
#
# The checks below are fully offline. A fake `az` is placed first on PATH (the
# same technique worker/tests/test_ralph_dispatch.sh uses for az/gh) and each
# scenario is driven through env vars, so no Azure call is ever made.
Write-Section "squad-aca logs fallback + exit code"
$acaLogsFile = Join-Path $RepoRoot "scripts\lib\aca-logs.ps1"
$squadAcaFile = Join-Path $RepoRoot "scripts\squad-aca.ps1"
if (-not (Test-Path $acaLogsFile)) {
    Add-Fail "scripts/lib/aca-logs.ps1 not found"
} elseif (-not (Test-Path $squadAcaFile)) {
    Add-Fail "scripts/squad-aca.ps1 not found"
} else {
    $squadAcaText = Get-Content -LiteralPath $squadAcaFile -Raw

    # Source assertions: the bare, unchecked extension call must be gone and the
    # doctor table must surface which log path `logs` will take.
    if ($squadAcaText -match 'az containerapp job logs show') {
        Add-Fail "Invoke-Logs still calls 'az containerapp job logs show' directly (exit code unchecked, extension required)"
    } else {
        Add-Pass "Invoke-Logs no longer calls 'az containerapp job logs show' directly"
    }
    if ($squadAcaText -match 'Get-AcaExecutionLog') {
        Add-Pass "Invoke-Logs delegates to Get-AcaExecutionLog (exit-code checked, Log Analytics fallback)"
    } else {
        Add-Fail "Invoke-Logs does not delegate to Get-AcaExecutionLog"
    }
    if ($squadAcaText -match 'Check = "Logs path"') {
        Add-Pass "squad-aca doctor reports the active logs path"
    } else {
        Add-Fail "squad-aca doctor has no 'Logs path' check (issue #13 asked for it)"
    }

    . $acaLogsFile

    $stubRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("aca-logs-" + [guid]::NewGuid().ToString("N"))
    $stubBin = Join-Path $stubRoot "bin"
    New-Item -ItemType Directory -Force -Path $stubBin | Out-Null

    # Fake `az`. Records one marker line per call. If dynamic extension install
    # was NOT suppressed it records PROMPT-RISK, which stands in for the real
    # CLI's interactive "install it now? (Y/n)" prompt that blocks on stdin.
    # Every branch exits from a label, never from inside a parenthesized block:
    # cmd.exe does not reliably propagate `exit /b <n>` out of nested blocks, and
    # a stub that always returned 0 would silently make these checks meaningless.
    $azStub = @'
@echo off
setlocal
if not "%AZURE_EXTENSION_USE_DYNAMIC_INSTALL%"=="no" >>"%SQUAD_TEST_AZ_LOG%" echo PROMPT-RISK %1 %2 %3
>>"%SQUAD_TEST_AZ_LOG%" echo CALL %1 %2 %3 %4

if "%1"=="extension" goto :extension
if "%1"=="containerapp" goto :containerapp
if "%1"=="monitor" goto :monitor
exit /b 0

:extension
if "%4"=="containerapp" goto :ext_containerapp
if "%4"=="log-analytics" goto :ext_loganalytics
exit /b 1

:ext_containerapp
if not "%SQUAD_TEST_AZ_EXT_CONTAINERAPP%"=="1" goto :ext_containerapp_missing
exit /b 0
:ext_containerapp_missing
echo ERROR: Extension 'containerapp' is not installed.>&2
exit /b 1

:ext_loganalytics
if not "%SQUAD_TEST_AZ_EXT_LOGANALYTICS%"=="1" goto :ext_loganalytics_missing
exit /b 0
:ext_loganalytics_missing
echo ERROR: Extension 'log-analytics' is not installed.>&2
exit /b 1

:containerapp
if not "%SQUAD_TEST_AZ_EXT_CONTAINERAPP%"=="1" goto :containerapp_noext
if "%SQUAD_TEST_AZ_LOGS_FAIL%"=="1" goto :containerapp_fail
echo native-log-line-1
echo native-log-line-2
exit /b 0
:containerapp_noext
echo ERROR: The command requires the extension containerapp.>&2
exit /b 2
:containerapp_fail
echo ERROR: simulated containerapp logs failure>&2
exit /b 1

:monitor
if not "%SQUAD_TEST_AZ_EXT_LOGANALYTICS%"=="1" goto :monitor_noext
if "%3"=="workspace" goto :monitor_workspace
if "%3"=="query" goto :monitor_query
exit /b 1
:monitor_noext
echo ERROR: The command requires the extension log-analytics.>&2
exit /b 2
:monitor_workspace
echo 00000000-0000-0000-0000-000000000000
exit /b 0
:monitor_query
if "%SQUAD_TEST_AZ_QUERY_FAIL%"=="1" goto :monitor_query_fail
echo [{"TimeGenerated":"2026-07-28T00:00:00Z","Log_s":"fallback-log-line-1"},{"TimeGenerated":"2026-07-28T00:00:01Z","Log_s":"fallback-log-line-2"}]
exit /b 0
:monitor_query_fail
echo ERROR: simulated Log Analytics query failure>&2
exit /b 1
'@
    Set-Content -LiteralPath (Join-Path $stubBin "az.cmd") -Value $azStub -Encoding ascii

    $prevPath = $env:PATH
    $prevDynamic = $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL
    $hadDynamic = Test-Path Env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL
    $env:PATH = "$stubBin;$prevPath"
    $env:SQUAD_TEST_AZ_LOG = Join-Path $stubRoot "az-calls.log"

    function Reset-AzStubState {
        param([string]$Containerapp = "0", [string]$LogAnalytics = "0", [string]$LogsFail = "0", [string]$QueryFail = "0")
        Set-Content -LiteralPath $env:SQUAD_TEST_AZ_LOG -Value "" -Encoding ascii
        $env:SQUAD_TEST_AZ_EXT_CONTAINERAPP = $Containerapp
        $env:SQUAD_TEST_AZ_EXT_LOGANALYTICS = $LogAnalytics
        $env:SQUAD_TEST_AZ_LOGS_FAIL = $LogsFail
        $env:SQUAD_TEST_AZ_QUERY_FAIL = $QueryFail
    }
    function Get-AzStubCalls {
        if (-not (Test-Path $env:SQUAD_TEST_AZ_LOG)) { return @() }
        return @(Get-Content -LiteralPath $env:SQUAD_TEST_AZ_LOG | Where-Object { $_ -and $_.Trim() })
    }

    try {
        # Guard: the fake az must actually be the one being resolved. If PATH
        # stubbing silently failed, every check below would hit the real CLI.
        $resolvedAz = (Get-Command az -ErrorAction SilentlyContinue)
        if (-not $resolvedAz -or $resolvedAz.Source -ne (Join-Path $stubBin "az.cmd")) {
            Add-Fail "Could not stub 'az' on PATH for the logs regression test (resolved: $($resolvedAz.Source))"
        } else {
            Add-Pass "Fake 'az' is first on PATH; logs regression test runs fully offline"
        }

        # --- 1. Native path is preferred when the extension is present --------
        Reset-AzStubState -Containerapp "1" -LogAnalytics "1"
        $native = Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5
        $nativeCalls = Get-AzStubCalls
        if ($native.Source -eq "containerapp-extension" -and @($native.Lines) -contains "native-log-line-2" `
                -and -not (@($nativeCalls) -match 'CALL monitor')) {
            Add-Pass "Logs use the containerapp extension path when the extension is installed"
        } else {
            Add-Fail "Logs did not use the containerapp extension path when available (source=$($native.Source))"
        }

        # --- 2. Fallback when the extension is absent -------------------------
        Reset-AzStubState -Containerapp "0" -LogAnalytics "1"
        $fallback = Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 -WorkspaceName "law-test"
        $fallbackLines = @($fallback.Lines)
        if ($fallback.Source -eq "log-analytics" -and $fallbackLines.Count -eq 2 `
                -and $fallbackLines -contains "fallback-log-line-1" -and $fallbackLines -contains "fallback-log-line-2" `
                -and $fallback.Workspace -eq "law-test") {
            Add-Pass "Logs fall back to Log Analytics when the containerapp extension is absent"
        } else {
            Add-Fail "Logs did not fall back to Log Analytics correctly (source=$($fallback.Source), lines=$($fallbackLines.Count))"
        }

        # --- 2b. Same fallback under Windows PowerShell 5.1 -------------------
        # squad-aca.ps1 runs under Windows PowerShell through the .cmd shim, and
        # 5.1 does NOT unroll a JSON array the way pwsh 7 does. Validating only
        # under the host that runs validate.ps1 would miss a row-flattening bug
        # that silently turns real log lines into blanks.
        $winPs = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path $winPs)) {
            Write-Host "  [SKIP] Windows PowerShell 5.1 not present for cross-host log parsing check"
        } else {
            Reset-AzStubState -Containerapp "0" -LogAnalytics "1"
            $winScript = ". '$acaLogsFile'; " +
                "`$r = Get-AcaExecutionLog -ResourceGroup 'rg-test' -JobName 'caj-test' -ExecutionName 'caj-test-abc' -Tail 5 -WorkspaceName 'law-test'; " +
                "foreach (`$l in @(`$r.Lines)) { Write-Output `"ROW:`$l`" }"
            $winOut = @(& $winPs -NoProfile -NonInteractive -Command $winScript 2>&1 | ForEach-Object { [string]$_ })
            $winRows = @($winOut | Where-Object { $_ -match '^ROW:' })
            if ($winRows.Count -eq 2 -and ($winRows -contains "ROW:fallback-log-line-1") -and ($winRows -contains "ROW:fallback-log-line-2")) {
                Add-Pass "Log Analytics rows survive intact under Windows PowerShell 5.1 (the host the squad-aca shim uses)"
            } else {
                Add-Fail "Log Analytics rows were mangled under Windows PowerShell 5.1 (got $($winRows.Count) row(s): $($winRows -join ' | '))"
            }
        }

        # --- 3. Fallback when the extension exists but its call fails ---------
        Reset-AzStubState -Containerapp "1" -LogAnalytics "1" -LogsFail "1"
        $afterFail = Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5
        $afterFailCalls = Get-AzStubCalls
        $triedNative = @($afterFailCalls | Where-Object { $_ -match 'CALL containerapp job logs' }).Count -gt 0
        $triedQuery = @($afterFailCalls | Where-Object { $_ -match 'CALL monitor log-analytics query' }).Count -gt 0
        if ($afterFail.Source -eq "log-analytics" -and $triedNative -and $triedQuery) {
            Add-Pass "A failing 'az containerapp job logs show' falls through to the Log Analytics query"
        } else {
            Add-Fail "A failing containerapp logs call did not fall through to Log Analytics (source=$($afterFail.Source), native=$triedNative, query=$triedQuery)"
        }

        # --- 4. Both paths unavailable => terminating, actionable error -------
        Reset-AzStubState -Containerapp "0" -LogAnalytics "0"
        $threw = $false
        $message = ""
        try {
            Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 -WorkspaceName "law-test" | Out-Null
        } catch {
            $threw = $true
            $message = [string]$_.Exception.Message
        }
        if ($threw -and $message -match 'az extension add --name containerapp' -and $message -match 'az extension add --name log-analytics' -and $message -match 'law-test') {
            Add-Pass "Both log paths unavailable produces a terminating, actionable error"
        } else {
            Add-Fail "Both log paths unavailable did not produce an actionable terminating error (threw=$threw)"
        }

        # --- 5. A failing Log Analytics query must also be fatal --------------
        Reset-AzStubState -Containerapp "0" -LogAnalytics "1" -QueryFail "1"
        $queryThrew = $false
        try {
            Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 | Out-Null
        } catch {
            $queryThrew = $true
        }
        if ($queryThrew) {
            Add-Pass "A failing Log Analytics query is fatal instead of silently returning nothing"
        } else {
            Add-Fail "A failing Log Analytics query was swallowed (false green)"
        }

        # --- 6. No az call may risk the interactive install prompt ------------
        $promptRisks = @(Get-AzStubCalls | Where-Object { $_ -match '^PROMPT-RISK' })
        Reset-AzStubState -Containerapp "0" -LogAnalytics "0"
        try { Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 | Out-Null } catch { }
        $promptRisks += @(Get-AzStubCalls | Where-Object { $_ -match '^PROMPT-RISK' })
        if ($promptRisks.Count -eq 0) {
            Add-Pass "Every az invocation runs with AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no (no interactive install prompt can block)"
        } else {
            Add-Fail "$($promptRisks.Count) az invocation(s) could trigger the interactive extension-install prompt"
        }

        # --- 7. The suppression env var must be restored ----------------------
        $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = "sentinel-value"
        Reset-AzStubState -Containerapp "1" -LogAnalytics "1"
        Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 | Out-Null
        $restoredSet = ($env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL -eq "sentinel-value")
        Remove-Item Env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL -ErrorAction SilentlyContinue
        Reset-AzStubState -Containerapp "1" -LogAnalytics "1"
        Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 | Out-Null
        $restoredUnset = -not (Test-Path Env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL)
        if ($restoredSet -and $restoredUnset) {
            Add-Pass "AZURE_EXTENSION_USE_DYNAMIC_INSTALL is restored after log retrieval (set and unset cases)"
        } else {
            Add-Fail "AZURE_EXTENSION_USE_DYNAMIC_INSTALL leaked after log retrieval (set restored=$restoredSet, unset restored=$restoredUnset)"
        }

        # --- 8. End-to-end exit code: a failed log fetch must not exit 0 ------
        # The original bug was an exit code, not a message, so assert the real
        # process exit code of a host that runs the same call path.
        Reset-AzStubState -Containerapp "0" -LogAnalytics "0"
        $psExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $childScript = ". '$acaLogsFile'; " +
            "`$ErrorActionPreference = 'Stop'; " +
            "Get-AcaExecutionLog -ResourceGroup 'rg-test' -JobName 'caj-test' -ExecutionName 'caj-test-abc' -Tail 5 -WorkspaceName 'law-test' | Out-Null"
        & $psExe -NoProfile -NonInteractive -Command $childScript 2>&1 | Out-Null
        $childExit = $LASTEXITCODE
        if ($childExit -ne 0) {
            Add-Pass "A failed log fetch exits non-zero (observed exit $childExit; issue #13 regression)"
        } else {
            Add-Fail "A failed log fetch still exits 0 (issue #13 regression: false green)"
        }

        # --- 9. --tail must reach the Log Analytics query ---------------------
        $kql = Get-AcaLogAnalyticsQuery -ExecutionName "caj-test-abc" -Tail 42
        if ($kql -match 'top 42 by TimeGenerated desc' -and $kql -match "startswith 'caj-test-abc'" -and $kql -match 'ContainerAppConsoleLogs_CL') {
            Add-Pass "--tail and the execution name are honoured by the Log Analytics query"
        } else {
            Add-Fail "Log Analytics query ignores --tail or the execution name: $kql"
        }
    } finally {
        $env:PATH = $prevPath
        foreach ($name in @("SQUAD_TEST_AZ_LOG", "SQUAD_TEST_AZ_EXT_CONTAINERAPP", "SQUAD_TEST_AZ_EXT_LOGANALYTICS", "SQUAD_TEST_AZ_LOGS_FAIL", "SQUAD_TEST_AZ_QUERY_FAIL")) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        if ($hadDynamic) {
            $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = $prevDynamic
        } else {
            Remove-Item Env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL -ErrorAction SilentlyContinue
        }
        Remove-Item -Recurse -Force $stubRoot -ErrorAction SilentlyContinue
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
