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
      8. Provider contract  - the execution provider seam is exercised offline
                              against the filesystem-backed fake provider
                              (state transitions, idempotent terminate, handle
                              opacity, unknown/foreign handle rejection).
     8b. ACA Job adapter   - the PRODUCTION adapter is exercised against a
                              stubbed `az`: terminate on a live, gone, and
                              already-terminal execution, terminate under auth /
                              RBAC / throttling / network / missing-`az`
                              failures (all of which must surface as errors),
                              and wait's polling and timeout.
      9. CLI regression     - `squad-aca` is driven end to end with stub `az`
                              and `gh` binaries on PATH, asserting the observable
                              output (including `stop` stdout), exit codes, and
                              az call sequences that the provider refactor must
                              not change.
     10. CLI golden gate    - the committed golden captures cover every capture
                              case, CI actually runs
                              scripts/tests/verify-cli-golden.ps1, and the
                              harness still pins the environment (time zone,
                              culture, optional-tool availability) that makes
                              those goldens verify on a machine other than the
                              one that produced them.

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
$script:Skips = @()

# $IsWindows only exists in PowerShell 6+; this file also has to run under 5.1.
$IsWindowsHost = if ($null -ne $PSVersionTable.Platform) { $PSVersionTable.Platform -eq "Win32NT" } else { $true }

function Write-Section($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Add-Pass($text) { $script:Passes += $text; Write-Host "  [PASS] $text" -ForegroundColor Green }
function Add-Fail($text) { $script:Failures += $text; Write-Host "  [FAIL] $text" -ForegroundColor Red }
# A check that could not execute is NEITHER a pass nor a failure. The worker
# suite established this (worker/tests/lib/deps.sh exits 77 and run-tests.sh
# reports it as SKIP, never as a pass); a validate.ps1 check with an external
# dependency has to be equally honest, because a skip that silently counted as
# a pass is a check that stops existing the moment the dependency goes missing.
function Add-Skip($text) { $script:Skips += $text; Write-Host "  [SKIP] $text" -ForegroundColor Yellow }

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
# 8. Execution provider contract (offline, against the fake provider)
# ---------------------------------------------------------------------------
Write-Section "Execution provider contract"
$providerLib = Join-Path $RepoRoot "scripts\lib\squad-aca-provider.ps1"
if (-not (Test-Path $providerLib)) {
    Add-Fail "scripts/lib/squad-aca-provider.ps1 is missing (execution provider seam)"
} else {
    . $providerLib

    $providerTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("squad-provider-" + [guid]::NewGuid().ToString("N"))
    try {
        $fake = New-SquadExecutionProvider -Kind "fake" -Options @{ StateRoot = $providerTmp }

        # -- structural conformance -----------------------------------------
        if (@(Test-SquadExecutionProvider -Provider $fake).Count -eq 0) {
            Add-Pass "Fake provider satisfies the execution provider contract"
        } else {
            Add-Fail "Fake provider does not satisfy the execution provider contract"
        }

        $acaProvider = New-SquadExecutionProvider -Kind "aca-job" -Options @{
            Config    = [pscustomobject]@{ resourceGroup = "rg"; sessionJob = "job"; subscriptionId = "" }
            ScriptDir = (Join-Path $RepoRoot "scripts")
        }
        if (@(Test-SquadExecutionProvider -Provider $acaProvider).Count -eq 0) {
            Add-Pass "ACA Job provider satisfies the execution provider contract"
        } else {
            Add-Fail "ACA Job provider does not satisfy the execution provider contract"
        }

        $missingOps = @($script:SquadProviderOperations | Where-Object { -not $fake.Operations.Contains($_) })
        if ($missingOps.Count -eq 0) {
            Add-Pass "Contract declares create/wait/status/logs/cancel/terminate and the fake implements all six"
        } else {
            Add-Fail "Fake provider is missing contract operations: $($missingOps -join ', ')"
        }

        try {
            Invoke-SquadProviderOperation -Provider $fake -Operation "resize" | Out-Null
            Add-Fail "Off-contract operation 'resize' was dispatched instead of rejected"
        } catch {
            Add-Pass "Off-contract operations are rejected at the dispatch choke point"
        }

        # -- dispatch request / response shape (PRD #6) ----------------------
        $request = New-SquadDispatchRequest -SessionId "sess-a" -Repository "octo/demo" -Ref "main" `
            -Prompt "do the thing" -Mode "prompt" -OutputBranch "squad/sess-a" -PushChanges $true
        $requiredRequestFields = @("schemaVersion", "sessionId", "dispatchSource", "repository", "task",
            "capabilityManifest", "capabilityResolution", "executionPreferences", "git")
        $missingReq = @($requiredRequestFields | Where-Object { $request.PSObject.Properties.Name -notcontains $_ })
        if ($missingReq.Count -eq 0) {
            Add-Pass "Dispatch request carries every PRD #6 field"
        } else {
            Add-Fail "Dispatch request is missing PRD #6 fields: $($missingReq -join ', ')"
        }

        $response = New-SquadDispatchResponse -SessionId "sess-a" -ExecutionMode "aca-job" -Status "provisioning" -SessionHandle "sqx1.abc"
        $requiredResponseFields = @("executionMode", "sandboxClass", "sessionHandle", "status", "statusPollRef", "fallbackReason")
        $missingResp = @($requiredResponseFields | Where-Object { $response.PSObject.Properties.Name -notcontains $_ })
        if ($missingResp.Count -eq 0) {
            Add-Pass "Dispatch response carries every PRD #6 field"
        } else {
            Add-Fail "Dispatch response is missing PRD #6 fields: $($missingResp -join ', ')"
        }

        # -- create ----------------------------------------------------------
        $outcome = @{}
        $created = @(Start-SquadExecution -Provider $fake -Request $request -Outcome $outcome)
        if ($created.Count -eq 0) {
            Add-Pass "create writes nothing of its own to the pipeline (substrate output passes through untouched)"
        } else {
            Add-Fail "create polluted the pipeline with $($created.Count) object(s); run/smoke output would change"
        }
        $handle = $outcome["Response"].sessionHandle
        if ($outcome["Response"] -and $handle) {
            Add-Pass "create returns the provider-neutral response through -Outcome"
        } else {
            Add-Fail "create did not return a dispatch response through -Outcome"
        }

        # -- handle opacity --------------------------------------------------
        # Convention-level opacity, and the message says exactly that: a handle
        # is base64 and trivially decodable by anyone who wants to. What this
        # asserts is that a caller cannot *accidentally* depend on the execution
        # id by string-matching a handle it was handed.
        $status = Get-SquadExecutionStatus -Provider $fake -Handle $handle
        $execId = $status.Display.Execution
        if ($handle -ne $execId -and $handle -notlike "*$execId*") {
            Add-Pass "Execution handles do not embed the execution id verbatim (no call site can string-match one out by accident)"
        } else {
            Add-Fail "Execution handle contains the underlying execution id '$execId' verbatim; a call site could string-match it out"
        }

        # -- state transitions -----------------------------------------------
        if ($status.Status -eq "Provisioning") {
            Add-Pass "create leaves the execution in Provisioning"
        } else {
            Add-Fail "create left the execution in '$($status.Status)', expected Provisioning"
        }
        $waited = Wait-SquadExecution -Provider $fake -Handle $handle
        if ($waited.Status -eq "Running") {
            Add-Pass "wait advances Provisioning -> Running"
        } else {
            Add-Fail "wait left the execution in '$($waited.Status)', expected Running"
        }
        $logResult = Get-SquadExecutionLog -Provider $fake -Handle $handle -Tail 10
        if (@($logResult.Lines).Count -gt 0 -and ($logResult.PSObject.Properties.Name -contains "Notice")) {
            Add-Pass "logs returns the contract Lines/Notice result for a known handle"
        } else {
            Add-Fail "logs did not return the contract Lines/Notice shape"
        }
        $listed = @(Get-SquadExecutionList -Provider $fake -Limit 10)
        if ($listed.Count -ge 1 -and $listed[0].PSObject.Properties.Name -contains "Display") {
            Add-Pass "status (list form) returns Handle/Status/Display records"
        } else {
            Add-Fail "status (list form) did not return contract records"
        }

        # -- cancel, twice ----------------------------------------------------
        Stop-SquadExecution -Provider $fake -Handle $handle | Out-Null
        $afterCancel = Get-SquadExecutionStatus -Provider $fake -Handle $handle
        if ($afterCancel.Status -eq "Cancelled") {
            Add-Pass "cancel moves a running execution to Cancelled"
        } else {
            Add-Fail "cancel left the execution in '$($afterCancel.Status)', expected Cancelled"
        }
        $doubleCancelOk = $true
        try { Stop-SquadExecution -Provider $fake -Handle $handle | Out-Null } catch { $doubleCancelOk = $false }
        if ($doubleCancelOk) {
            Add-Pass "cancel is safe to call twice (second cancel is a no-op success)"
        } else {
            Add-Fail "second cancel threw; cancel must tolerate an already-terminal execution"
        }

        # -- terminate: idempotent -------------------------------------------
        $t1 = Remove-SquadExecution -Provider $fake -Handle $handle
        $t2 = Remove-SquadExecution -Provider $fake -Handle $handle
        if ($t1.Terminated -and $t2.Terminated) {
            Add-Pass "terminate is idempotent (terminating an already-terminated execution succeeds)"
        } else {
            Add-Fail "terminate was not idempotent"
        }

        $outcome2 = @{}
        Start-SquadExecution -Provider $fake -Request $request -Outcome $outcome2 | Out-Null
        $handle2 = $outcome2["Response"].sessionHandle
        $id2 = (Get-SquadExecutionStatus -Provider $fake -Handle $handle2).Display.Execution
        Remove-Item -LiteralPath (Join-Path $providerTmp "$id2.json") -Force
        $externalOk = $true
        try {
            $t3 = Remove-SquadExecution -Provider $fake -Handle $handle2
            if (-not $t3.Terminated) { $externalOk = $false }
        } catch { $externalOk = $false }
        if ($externalOk) {
            Add-Pass "terminate succeeds after the execution was deleted externally"
        } else {
            Add-Fail "terminate failed for an externally-deleted execution; PRD #6 requires success"
        }

        # -- unknown / malformed / cross-provider handles ---------------------
        $unknownHandle = New-SquadExecutionHandle -ProviderId "fake" -Payload ([ordered]@{ id = "fake-exec-9999" })
        try {
            Get-SquadExecutionStatus -Provider $fake -Handle $unknownHandle | Out-Null
            Add-Fail "status accepted a well-formed handle for an execution that does not exist"
        } catch {
            Add-Pass "status rejects a well-formed handle for an unknown execution"
        }
        try {
            Get-SquadExecutionStatus -Provider $fake -Handle "not-a-handle" | Out-Null
            Add-Fail "status accepted a malformed execution handle"
        } catch {
            Add-Pass "status rejects a malformed execution handle"
        }
        $foreignHandle = New-SquadExecutionHandle -ProviderId "aca-job" -Payload ([ordered]@{ job = "j"; rg = "r"; execution = "e" })
        try {
            Remove-SquadExecution -Provider $fake -Handle $foreignHandle | Out-Null
            Add-Fail "terminate accepted a handle minted by a different provider"
        } catch {
            Add-Pass "terminate rejects a handle minted by a different provider (caller bug, not a race)"
        }
    } catch {
        Add-Fail "Execution provider contract checks threw: $($_.Exception.Message)"
    } finally {
        Remove-Item -Recurse -Force $providerTmp -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 8b. ACA Job adapter against a stubbed `az` (the PRODUCTION adapter)
# ---------------------------------------------------------------------------
# Section 8 exercises the contract against the fake provider. That proves the
# seam, not the adapter that actually ships: replacing the ACA adapter's
# terminate az call with a no-op, or its `wait` body with a throw, left section
# 8 fully green. These checks close that hole by driving
# New-AcaJobExecutionProvider itself against the fake `az` from
# scripts/tests/cli-stub-harness.ps1.
#
# The defect they exist for: terminate used to return Terminated=$true for EVERY
# non-zero `az` exit and label it AlreadyTerminal, so an auth failure, an RBAC
# denial, throttling, or a missing `az` all read as "successfully torn down".
Write-Section "ACA Job adapter (stubbed az)"
$adapterHarness = Join-Path $RepoRoot "scripts\tests\cli-stub-harness.ps1"
if (-not (Test-Path $providerLib)) {
    Add-Fail "scripts/lib/squad-aca-provider.ps1 is missing (ACA Job adapter checks)"
} elseif (-not (Test-Path $adapterHarness)) {
    Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing (ACA Job adapter checks)"
} elseif (-not $IsWindowsHost) {
    Write-Host "  [SKIP] ACA Job adapter checks require Windows (.cmd stubs)" -ForegroundColor Yellow
} else {
    . $adapterHarness
    $adapterStub = $null
    $adapterPrevPath = $env:PATH
    $adapterEnvNames = @("SQUAD_STUB_AZ_LOG", "SQUAD_STUB_GH_LOG", "SQUAD_STUB_FIXTURES",
        "SQUAD_STUB_STOP_RC", "SQUAD_STUB_START_RC", "SQUAD_STUB_STOP_ERR",
        "SQUAD_STUB_EXEC_SEQ", "SQUAD_STUB_EXEC_STUCK")
    try {
        $adapterStub = New-SquadCliStubEnvironment
        $env:PATH = "$($adapterStub.BinDir);$adapterPrevPath"
        $env:SQUAD_STUB_AZ_LOG = $adapterStub.AzLog
        $env:SQUAD_STUB_GH_LOG = $adapterStub.GhLog
        $env:SQUAD_STUB_FIXTURES = $adapterStub.FixtureDir
        $env:SQUAD_STUB_STOP_RC = "0"
        $env:SQUAD_STUB_START_RC = "0"
        $env:SQUAD_STUB_STOP_ERR = ""
        $env:SQUAD_STUB_EXEC_SEQ = ""
        $env:SQUAD_STUB_EXEC_STUCK = ""

        $resolvedAz = (Get-Command az -ErrorAction SilentlyContinue)
        if (-not $resolvedAz -or $resolvedAz.Source -ne (Join-Path $adapterStub.BinDir "az.cmd")) {
            Add-Fail "Could not stub 'az' on PATH for the ACA Job adapter checks (resolved: $($resolvedAz.Source))"
        } else {
            Add-Pass "Fake 'az' is first on PATH; ACA Job adapter checks run fully offline"
        }

        $adapterConfig = [pscustomobject]@{
            resourceGroup        = "rg-squad-stub"
            sessionJob           = "caj-squad-aca-session"
            subscriptionId       = "00000000-0000-0000-0000-000000000000"
            logAnalyticsWorkspace = "law-stub"
        }
        $acaAdapter = New-SquadExecutionProvider -Kind "aca-job" -Options @{
            Config    = $adapterConfig
            ScriptDir = (Join-Path $RepoRoot "scripts")
        }
        $acaHandle = New-AcaJobExecutionHandle -Config $adapterConfig -Name "caj-squad-aca-session-stub01"

        function Invoke-AdapterTerminate {
            param([string]$StopRc = "0", [string]$StopErr = "", [string]$Handle)
            Reset-SquadCliStubLog -Stub $adapterStub
            $env:SQUAD_STUB_STOP_RC = $StopRc
            $env:SQUAD_STUB_STOP_ERR = $StopErr
            $outcome = [pscustomobject]@{ Threw = $false; Message = ""; Result = $null }
            try {
                $outcome.Result = Remove-SquadExecution -Provider $acaAdapter -Handle $Handle
            } catch {
                $outcome.Threw = $true
                $outcome.Message = [string]$_.Exception.Message
            }
            return $outcome
        }

        # --- 1. Normal terminate ---------------------------------------------
        $t = Invoke-AdapterTerminate -StopRc "0" -Handle $acaHandle
        $stopCalls = @(Get-SquadCliStubCall -Stub $adapterStub -Tool az | Where-Object { $_ -like "containerapp job stop*" })
        if (-not $t.Threw -and $t.Result.Terminated -and -not $t.Result.AlreadyTerminal `
                -and $stopCalls.Count -eq 1 `
                -and $stopCalls[0] -like "*--name caj-squad-aca-session --resource-group rg-squad-stub --job-execution-name caj-squad-aca-session-stub01*") {
            Add-Pass "ACA adapter terminate stops a live execution with one 'az containerapp job stop' (Terminated, not AlreadyTerminal)"
        } else {
            Add-Fail "ACA adapter terminate did not stop a live execution correctly (threw=$($t.Threw) terminated=$($t.Result.Terminated) alreadyTerminal=$($t.Result.AlreadyTerminal) calls=$($stopCalls.Count) msg=$($t.Message))"
        }

        # --- 2. Already terminal / deleted out from under us => SUCCESS -------
        # Azure CLI reserves exit 3 for ResourceNotFoundError.
        $goneCases = @(
            @{ Rc = "3"; Err = "ERROR: (JobExecutionNotFound) The job execution 'caj-squad-aca-session-stub01' was not found."; Label = "not found (exit 3)" },
            @{ Rc = "1"; Err = "ERROR: (ResourceNotFound) The Resource 'Microsoft.App/jobs/caj-squad-aca-session/executions/stub01' under resource group 'rg-squad-stub' was not found."; Label = "ResourceNotFound" },
            @{ Rc = "1"; Err = "ERROR: The job execution is already stopped."; Label = "already stopped" }
        )
        $goneFailures = @()
        foreach ($case in $goneCases) {
            $g = Invoke-AdapterTerminate -StopRc $case.Rc -StopErr $case.Err -Handle $acaHandle
            if ($g.Threw -or -not $g.Result.Terminated -or -not $g.Result.AlreadyTerminal) {
                $goneFailures += "$($case.Label) (threw=$($g.Threw))"
            }
        }
        if ($goneFailures.Count -eq 0) {
            Add-Pass "ACA adapter terminate is idempotent: an already-terminal or externally-deleted execution reports Terminated + AlreadyTerminal"
        } else {
            Add-Fail "ACA adapter terminate failed for a genuinely-gone execution: $($goneFailures -join '; ') (PRD #6 requires success)"
        }

        # --- 3. Auth failure MUST surface, not become AlreadyTerminal ---------
        $auth = Invoke-AdapterTerminate -StopRc "1" -StopErr "ERROR: Please run 'az login' to setup account." -Handle $acaHandle
        if ($auth.Threw -and $auth.Message -match "az login") {
            Add-Pass "ACA adapter terminate surfaces an 'az login' auth failure as an error (never AlreadyTerminal)"
        } else {
            Add-Fail "ACA adapter terminate swallowed an auth failure (threw=$($auth.Threw) terminated=$($auth.Result.Terminated) alreadyTerminal=$($auth.Result.AlreadyTerminal)); an unauthenticated CLI proves nothing about the execution"
        }

        # --- 4. Other real failures must surface too --------------------------
        $realFailureCases = @(
            @{ Rc = "1"; Err = "ERROR: (AuthorizationFailed) The client does not have authorization to perform action 'Microsoft.App/jobs/stop/action'."; Label = "RBAC denial" },
            @{ Rc = "1"; Err = "ERROR: (TooManyRequests) The request is being throttled. Retry-After: 30"; Label = "throttling" },
            @{ Rc = "1"; Err = "ERROR: HTTPSConnectionPool: Max retries exceeded (connection timed out)"; Label = "network timeout" },
            @{ Rc = "1"; Err = "ERROR: (SubscriptionNotFound) The subscription could not be found."; Label = "wrong subscription" },
            @{ Rc = "1"; Err = "ERROR: something the CLI has never printed before"; Label = "unrecognised failure (fail closed)" }
        )
        $swallowed = @()
        foreach ($case in $realFailureCases) {
            $f = Invoke-AdapterTerminate -StopRc $case.Rc -StopErr $case.Err -Handle $acaHandle
            if (-not $f.Threw) { $swallowed += $case.Label }
        }
        if ($swallowed.Count -eq 0) {
            Add-Pass "ACA adapter terminate surfaces RBAC, throttling, network, wrong-subscription and unrecognised failures as errors (fail closed)"
        } else {
            Add-Fail "ACA adapter terminate reported success for real failure(s): $($swallowed -join ', ')"
        }

        # --- 5. `az` missing entirely must fail, not read a stale exit code ---
        # The pre-fix adapter read $LASTEXITCODE after a call that never ran, so
        # a preceding success made a missing `az` look like a completed stop.
        cmd /c "exit 0" | Out-Null   # force $LASTEXITCODE to 0 ("success")
        $env:PATH = "$($adapterStub.WorkDir)"
        $missingAz = [pscustomobject]@{ Threw = $false; Result = $null; Message = "" }
        try {
            $missingAz.Result = Remove-SquadExecution -Provider $acaAdapter -Handle $acaHandle
        } catch {
            $missingAz.Threw = $true
            $missingAz.Message = [string]$_.Exception.Message
        } finally {
            $env:PATH = "$($adapterStub.BinDir);$adapterPrevPath"
        }
        if ($missingAz.Threw) {
            Add-Pass "ACA adapter terminate fails when 'az' is not on PATH (a stale `$LASTEXITCODE cannot be read as a successful stop)"
        } else {
            Add-Fail "ACA adapter terminate reported Terminated=$($missingAz.Result.Terminated) with no 'az' on PATH; nothing ran, so nothing was terminated"
        }

        # --- 6. wait advances Provisioning -> Running -------------------------
        Reset-SquadCliStubLog -Stub $adapterStub
        $env:SQUAD_STUB_EXEC_SEQ = Join-Path $adapterStub.Root "exec-seq.marker"
        Remove-Item -LiteralPath $env:SQUAD_STUB_EXEC_SEQ -Force -ErrorAction SilentlyContinue
        $waitResult = $null
        $waitThrew = ""
        try {
            $waitResult = Wait-SquadExecution -Provider $acaAdapter -Handle $acaHandle -TimeoutSeconds 30 -PollSeconds 1
        } catch {
            $waitThrew = [string]$_.Exception.Message
        }
        $env:SQUAD_STUB_EXEC_SEQ = ""
        $showCalls = @(Get-SquadCliStubCall -Stub $adapterStub -Tool az | Where-Object { $_ -like "containerapp job execution show*" })
        if (-not $waitThrew -and $waitResult -and $waitResult.Status -eq "Running" -and $showCalls.Count -ge 2) {
            Add-Pass "ACA adapter wait polls 'az containerapp job execution show' until the execution leaves Provisioning ($($showCalls.Count) polls)"
        } else {
            Add-Fail "ACA adapter wait did not advance Provisioning -> Running (status=$($waitResult.Status) polls=$($showCalls.Count) error=$waitThrew)"
        }

        # --- 7. wait must not report a still-provisioning execution as ready --
        Reset-SquadCliStubLog -Stub $adapterStub
        $env:SQUAD_STUB_EXEC_STUCK = "1"
        $stuckThrew = $false
        $stuckError = ""
        $stuckStatus = ""
        try {
            $stuckStatus = (Wait-SquadExecution -Provider $acaAdapter -Handle $acaHandle -TimeoutSeconds 1 -PollSeconds 1).Status
        } catch {
            $stuckThrew = $true
            $stuckError = [string]$_.Exception.Message
        }
        $env:SQUAD_STUB_EXEC_STUCK = ""
        $stuckPolls = @(Get-SquadCliStubCall -Stub $adapterStub -Tool az | Where-Object { $_ -like "containerapp job execution show*" })
        if ($stuckThrew -and $stuckError -match "Timed out" -and $stuckPolls.Count -ge 1) {
            Add-Pass "ACA adapter wait polls, then times out instead of returning a still-Provisioning execution as ready"
        } else {
            Add-Fail "ACA adapter wait did not time out on a never-ready execution (status=$stuckStatus polls=$($stuckPolls.Count) error=$stuckError)"
        }
    } catch {
        Add-Fail "ACA Job adapter checks threw: $($_.Exception.Message)"
    } finally {
        $env:PATH = $adapterPrevPath
        foreach ($name in $adapterEnvNames) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        if ($adapterStub) { Remove-SquadCliStubEnvironment -Stub $adapterStub }
    }
}

# ---------------------------------------------------------------------------
# 8c. Sandbox feature flag + route gate (no CLI, no stubs needed)
# ---------------------------------------------------------------------------
# The flag is the whole safety story for Sprint 5: with it unset, the sandbox
# plane must be unreachable even for a dispatch that explicitly asks for it.
# These checks pin the gate itself; section 8d drives the provider behind it.
Write-Section "Sandbox feature flag and route gate"
if (-not (Test-Path $providerLib)) {
    Add-Fail "scripts/lib/squad-aca-provider.ps1 is missing (sandbox route gate checks)"
} else {
    $gateSaved = [Environment]::GetEnvironmentVariable("SQUAD_ACA_ENABLE_SANDBOX", "Process")
    $gateCatalogDir = Join-Path $RepoRoot "scripts\tests"
    $approvedCatalog = $null
    try {
        Remove-Item "Env:SQUAD_ACA_ENABLE_SANDBOX" -ErrorAction SilentlyContinue

        # An APPROVED, non-provisional catalog. The shipped catalog is
        # provisional:true (its own header says treat it as report-only), so the
        # ON-path tests must supply their own -- which is itself the proof that
        # the provisional gate bites.
        $approvedCatalog = @'
{
  "provisional": false,
  "classes": [
    {
      "id": "sandbox-node-lts",
      "approved": true,
      "image": "acrstub.azurecr.io/squad-worker:stub",
      "resources": { "cpu": 2, "memoryGi": 4 },
      "egress": {
        "defaultAction": "Deny",
        "hostRules": [
          { "pattern": "*.github.com", "action": "Allow" },
          { "pattern": "registry.npmjs.org", "action": "Allow" }
        ],
        "trafficInspection": "Full"
      }
    },
    { "id": "sandbox-container-build", "approved": false, "resources": { "cpu": 4, "memoryGi": 8 } }
  ]
}
'@ | ConvertFrom-Json

        $sandboxDecision = [pscustomobject]@{ route = "sandbox"; sandboxClass = "sandbox-node-lts"; defaultImageSufficient = $false }

        # --- 1. Default OFF ---------------------------------------------------
        if (-not (Test-SquadSandboxEnabled)) {
            Add-Pass "Sandbox feature flag defaults OFF when SQUAD_ACA_ENABLE_SANDBOX is unset"
        } else {
            Add-Fail "Sandbox feature flag is ON by default -- ACA Jobs must be the unconditional default"
        }

        # --- 2. Flag OFF makes the sandbox route unreachable ------------------
        # Even when the resolver explicitly asked for it AND an approved,
        # non-provisional catalog is available. This is the check that a
        # "default the flag to on" mutation has to trip.
        $offRoute = Resolve-SquadExecutionRoute -Decision $sandboxDecision -Catalog $approvedCatalog
        if ($offRoute.Route -eq "fail-closed" -and -not $offRoute.FeatureEnabled -and $offRoute.Reason -like "sandbox-feature-disabled*") {
            Add-Pass "Flag OFF: an explicit 'sandbox' decision is refused, not silently downgraded (route=$($offRoute.Route))"
        } else {
            Add-Fail "Flag OFF did not make the sandbox route unreachable (route=$($offRoute.Route) reason=$($offRoute.Reason) enabled=$($offRoute.FeatureEnabled))"
        }

        # --- 3. Flag OFF: an aca-job decision is still aca-job ----------------
        $offJob = Resolve-SquadExecutionRoute -Decision ([pscustomobject]@{ route = "aca-job" }) -Catalog $approvedCatalog
        $offNone = Resolve-SquadExecutionRoute -Decision $null -Catalog $approvedCatalog
        if ($offJob.Route -eq "aca-job" -and $offNone.Route -eq "aca-job") {
            Add-Pass "Flag OFF: 'aca-job' and 'no resolution' both route to ACA Jobs (today's path, unchanged)"
        } else {
            Add-Fail "Flag OFF changed the default path (aca-job=$($offJob.Route) none=$($offNone.Route))"
        }

        # --- 4. Kill switch ---------------------------------------------------
        $env:SQUAD_ACA_ENABLE_SANDBOX = "0"
        $killed = Test-SquadSandboxEnabled -Config ([pscustomobject]@{ sandboxEnabled = $true })
        $env:SQUAD_ACA_ENABLE_SANDBOX = "1"
        $onWithConfigOff = Test-SquadSandboxEnabled -Config ([pscustomobject]@{ sandboxEnabled = $false })
        Remove-Item "Env:SQUAD_ACA_ENABLE_SANDBOX" -ErrorAction SilentlyContinue
        if (-not $killed -and $onWithConfigOff) {
            Add-Pass "An explicit SQUAD_ACA_ENABLE_SANDBOX value decides in both directions (0 overrides an opted-in config)"
        } else {
            Add-Fail "SQUAD_ACA_ENABLE_SANDBOX is not authoritative (kill switch honoured=$(-not $killed) explicit-on honoured=$onWithConfigOff)"
        }

        # --- 5. Flag ON + shipped (provisional) catalog => fail closed --------
        $env:SQUAD_ACA_ENABLE_SANDBOX = "1"
        $shippedRoute = Resolve-SquadExecutionRoute -Decision $sandboxDecision `
            -CatalogPath (Join-Path $RepoRoot "config\sandbox-classes.json")
        if ($shippedRoute.Route -eq "fail-closed" -and $shippedRoute.Reason -eq "catalog-provisional") {
            Add-Pass "Flag ON + the shipped provisional catalog fails closed (provisional classes are report-only)"
        } else {
            Add-Fail "A provisional catalog did not fail closed (route=$($shippedRoute.Route) reason=$($shippedRoute.Reason))"
        }

        # --- 6. Flag ON + approved class => sandbox ---------------------------
        $onRoute = Resolve-SquadExecutionRoute -Decision $sandboxDecision -Catalog $approvedCatalog
        if ($onRoute.Route -eq "sandbox" -and $onRoute.SandboxClass -and $onRoute.SandboxClass.id -eq "sandbox-node-lts") {
            Add-Pass "Flag ON + an approved class in a non-provisional catalog routes to the sandbox plane"
        } else {
            Add-Fail "Flag ON did not reach the sandbox plane for an approved class (route=$($onRoute.Route) reason=$($onRoute.Reason))"
        }

        # --- 7. Flag ON but the class is not administrator-approved ----------
        $unapproved = Resolve-SquadExecutionRoute -Catalog $approvedCatalog `
            -Decision ([pscustomobject]@{ route = "sandbox"; sandboxClass = "sandbox-container-build"; defaultImageSufficient = $false })
        $unknown = Resolve-SquadExecutionRoute -Catalog $approvedCatalog `
            -Decision ([pscustomobject]@{ route = "sandbox"; sandboxClass = "attacker-supplied-image"; defaultImageSufficient = $false })
        if ($unapproved.Route -eq "fail-closed" -and $unapproved.Reason -eq "class-not-approved" `
                -and $unknown.Route -eq "fail-closed" -and $unknown.Reason -eq "class-not-in-catalog") {
            Add-Pass "Only administrator-approved catalog classes are reachable (unapproved and unknown ids both fail closed)"
        } else {
            Add-Fail "An unapproved or unknown sandbox class was not refused (unapproved=$($unapproved.Reason) unknown=$($unknown.Reason))"
        }

        # --- 8. fail-closed stays fail-closed; junk routes fail closed -------
        $failClosed = Resolve-SquadExecutionRoute -Decision ([pscustomobject]@{ route = "fail-closed" }) -Catalog $approvedCatalog
        $junk = Resolve-SquadExecutionRoute -Decision ([pscustomobject]@{ route = "something-else" }) -Catalog $approvedCatalog
        if ($failClosed.Route -eq "fail-closed" -and $junk.Route -eq "fail-closed") {
            Add-Pass "A 'fail-closed' resolution, and any unrecognised route, refuse to dispatch even with the flag ON"
        } else {
            Add-Fail "fail-closed or an unrecognised route did not refuse (failClosed=$($failClosed.Route) junk=$($junk.Route))"
        }
    } catch {
        Add-Fail "Sandbox route gate checks threw: $($_.Exception.Message)"
    } finally {
        if ($null -eq $gateSaved) {
            Remove-Item "Env:SQUAD_ACA_ENABLE_SANDBOX" -ErrorAction SilentlyContinue
        } else {
            $env:SQUAD_ACA_ENABLE_SANDBOX = $gateSaved
        }
    }
}

# ---------------------------------------------------------------------------
# 8d. ACA Sandboxes provider against a stubbed `aca`
# ---------------------------------------------------------------------------
# Drives New-SandboxExecutionProvider itself, fully offline, through the fake
# `aca` from scripts/tests/cli-stub-harness.ps1.
#
# The two defects these exist for are the ones the live investigation actually
# hit: `aca sandbox exec` has a hard ~120s client timeout, so a session run as a
# single synchronous exec dies at two minutes; and that same timeout, read as a
# failure rather than as INCONCLUSIVE, kills a healthy 60-minute run. Both are
# invisible to any check that only asserts "the right commands were issued".
Write-Section "ACA Sandboxes provider (stubbed aca)"
$sandboxHarness = Join-Path $RepoRoot "scripts\tests\cli-stub-harness.ps1"
if (-not (Test-Path $providerLib)) {
    Add-Fail "scripts/lib/squad-aca-provider.ps1 is missing (sandbox provider checks)"
} elseif (-not (Test-Path $sandboxHarness)) {
    Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing (sandbox provider checks)"
} elseif (-not $IsWindowsHost) {
    Write-Host "  [SKIP] Sandbox provider checks require Windows (.cmd stubs)" -ForegroundColor Yellow
} else {
    . $sandboxHarness
    $sbStub = $null
    $sbPrevPath = $env:PATH
    $sbEnvNames = @("SQUAD_STUB_AZ_LOG", "SQUAD_STUB_ACA_LOG", "SQUAD_STUB_FIXTURES",
        "SQUAD_STUB_SBG_IDENTITY", "SQUAD_STUB_SBG_RC",
        "SQUAD_STUB_ACA_RC", "SQUAD_STUB_ACA_ERR", "SQUAD_STUB_ACA_EXEC_RC",
        "SQUAD_STUB_ACA_EGRESS_RC", "SQUAD_STUB_ACA_EGRESS_ERR",
        "SQUAD_STUB_ACA_DELETE_RC", "SQUAD_STUB_ACA_DELETE_ERR",
        "SQUAD_STUB_ACA_CANCEL_RC", "SQUAD_STUB_ACA_CANCEL_ERR",
        "SQUAD_STUB_ACA_POLL_DIR", "SQUAD_STUB_ACA_TIMEOUT_ONCE")
    try {
        $sbStub = New-SquadCliStubEnvironment
        $env:PATH = "$($sbStub.BinDir);$sbPrevPath"
        $env:SQUAD_STUB_AZ_LOG = $sbStub.AzLog
        $env:SQUAD_STUB_ACA_LOG = $sbStub.AcaLog
        $env:SQUAD_STUB_FIXTURES = $sbStub.FixtureDir
        $env:SQUAD_STUB_SBG_IDENTITY = ""
        $env:SQUAD_STUB_SBG_RC = "0"
        $env:SQUAD_STUB_ACA_RC = "0"
        $env:SQUAD_STUB_ACA_ERR = ""
        $env:SQUAD_STUB_ACA_EXEC_RC = "0"
        $env:SQUAD_STUB_ACA_EGRESS_RC = "0"
        $env:SQUAD_STUB_ACA_EGRESS_ERR = ""
        $env:SQUAD_STUB_ACA_DELETE_RC = "0"
        $env:SQUAD_STUB_ACA_DELETE_ERR = ""
        $env:SQUAD_STUB_ACA_CANCEL_RC = "0"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = ""
        $env:SQUAD_STUB_ACA_POLL_DIR = ""
        $env:SQUAD_STUB_ACA_TIMEOUT_ONCE = ""

        $sbCli = Join-Path $sbStub.BinDir "aca.cmd"
        $resolvedAca = (Get-Command aca -ErrorAction SilentlyContinue)
        if ($resolvedAca -and $resolvedAca.Source -eq $sbCli) {
            Add-Pass "Fake 'aca' is first on PATH; sandbox provider checks run fully offline"
        } else {
            Add-Fail "Could not stub 'aca' on PATH for the sandbox provider checks (resolved: $($resolvedAca.Source))"
        }

        $sbClass = @'
{
  "id": "sandbox-node-lts",
  "approved": true,
  "resources": { "cpu": 2, "memoryGi": 4 },
  "egress": {
    "defaultAction": "Deny",
    "hostRules": [
      { "pattern": "*.github.com", "action": "Allow" },
      { "pattern": "registry.npmjs.org", "action": "Allow" }
    ],
    "trafficInspection": "Full"
  }
}
'@ | ConvertFrom-Json

        $sbSecret = "ghp-stub-secret-token-value"
        function New-SandboxTestProvider {
            param([string]$DiskId = "aaaaaaaa-1111-2222-3333-444444444444", [string]$DiskLabel = "")
            return New-SquadExecutionProvider -Kind "sandbox" -Options @{
                Class              = $sbClass
                SandboxGroup       = "sbg-squad-stub"
                ResourceGroup      = "rg-squad-stub"
                SubscriptionId     = "00000000-0000-0000-0000-000000000000"
                DiskId             = $DiskId
                DiskLabel          = $DiskLabel
                AcaCliPath         = $sbCli
                IdleTimeoutSeconds = 1800
                PollSeconds        = 1
                WorkerSecrets      = @{ GH_TOKEN = $sbSecret }
            }
        }

        $sbRequest = New-SquadDispatchRequest -SessionId "stub-session" -Repository "octo/demo" `
            -Prompt "do the thing" -Mode "prompt" -PushChanges $true -OutputBranch "squad/stub-session"

        # --- 1. create: full argv sequence, in order --------------------------
        Reset-SquadCliStubLog -Stub $sbStub
        $sbProvider = New-SandboxTestProvider
        $sbOutcome = @{}
        $sbCreateErr = ""
        try {
            Start-SquadExecution -Provider $sbProvider -Request $sbRequest -Outcome $sbOutcome 6>$null | Out-Null
        } catch {
            $sbCreateErr = [string]$_.Exception.Message
        }
        $sbCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $iCreate  = [array]::FindIndex($sbCalls, [Predicate[string]] { param($l) $l -like "sandbox create *" })
        $iEgress  = [array]::FindIndex($sbCalls, [Predicate[string]] { param($l) $l -like "sandbox egress set *" })
        $iLife    = [array]::FindIndex($sbCalls, [Predicate[string]] { param($l) $l -like "sandbox lifecycle set *" })
        $iLaunch  = [array]::FindIndex($sbCalls, [Predicate[string]] { param($l) $l -like "*squad-launched*" })

        if (-not $sbCreateErr -and $iCreate -ge 0 -and $iEgress -ge 0 -and $iLife -ge 0 -and $iLaunch -ge 0) {
            Add-Pass "Sandbox create issues create -> egress set -> lifecycle set -> detached exec (4 aca calls)"
        } else {
            Add-Fail "Sandbox create did not issue the expected aca sequence (err=$sbCreateErr calls=$($sbCalls -join ' | '))"
        }

        # THE ordering assertion: egress policy must be applied BEFORE the exec
        # that runs anything from the repository. A create that applied policy
        # afterwards would still issue every one of the calls above.
        if ($iEgress -ge 0 -and $iLaunch -ge 0 -and $iEgress -lt $iLaunch -and $iCreate -lt $iEgress) {
            Add-Pass "Egress default-deny is applied BEFORE the worker launch (egress #$iEgress precedes launch #$iLaunch)"
        } else {
            Add-Fail "Egress policy was not applied before repository code ran (create=$iCreate egress=$iEgress launch=$iLaunch)"
        }

        if ($iCreate -ge 0 -and $sbCalls[$iCreate] -like "*--disk-id aaaaaaaa-1111-2222-3333-444444444444*" `
                -and $sbCalls[$iCreate] -like "*--label name=squad-stub-session*" `
                -and $sbCalls[$iCreate] -like "*--cpu 2000m*" -and $sbCalls[$iCreate] -like "*--memory 4096Mi*") {
            Add-Pass "Sandbox create uses --disk-id (private disks are not addressable by --disk) and the class's resources"
        } else {
            Add-Fail "Sandbox create argv is wrong: $(if ($iCreate -ge 0) { $sbCalls[$iCreate] } else { '<missing>' })"
        }

        if ($iEgress -ge 0 -and $sbCalls[$iEgress] -like "*--default Deny*" `
                -and $sbCalls[$iEgress] -like "*--rule *.github.com:Allow*" `
                -and $sbCalls[$iEgress] -like "*--rule registry.npmjs.org:Allow*" `
                -and $sbCalls[$iEgress] -like "*--traffic-inspection Full*") {
            Add-Pass "Egress applies the class's default-deny action, every allowlist rule, and traffic inspection"
        } else {
            Add-Fail "Egress argv is wrong: $(if ($iEgress -ge 0) { $sbCalls[$iEgress] } else { '<missing>' })"
        }

        # Auto-suspend defaults to ENABLED at 600s, which would suspend a live
        # session; it has to be set explicitly.
        if ($iLife -ge 0 -and $sbCalls[$iLife] -like "*--auto-suspend enable*" -and $sbCalls[$iLife] -like "*--idle-timeout-seconds 1800*") {
            Add-Pass "Auto-suspend is pinned explicitly instead of inheriting the 600s default"
        } else {
            Add-Fail "Auto-suspend was not pinned: $(if ($iLife -ge 0) { $sbCalls[$iLife] } else { '<missing>' })"
        }

        # --- 2. the launch is DETACHED (proven by running it in a real shell) -
        # `aca sandbox exec` returns after ~120s no matter what the command is
        # doing, so a session held open by one exec dies at two minutes -- and
        # `create`'s catch tears the healthy sandbox down with it.
        #
        # This CANNOT be asserted by substring. In POSIX/bash grammar `&` is a
        # list terminator that binds LOOSER than `&&`, so
        #
        #   prelude && setsid nohup bash -c '...' </dev/null >/dev/null 2>&1 &
        #
        # contains every character of a detach while backgrounding the entire
        # and-list and binding the three redirections to the last simple command
        # only -- the async subshell keeps the exec's fd 0/1/2 open for the whole
        # worker run. A substring assertion passes on both shapes; the stub `aca`
        # never evaluates the `-c` payload in a shell, so nothing else in this
        # suite can tell them apart either. The only assertion that can is to
        # execute the emitted command in a real shell and time when the parent's
        # streams reach EOF.
        $launchLine = if ($iLaunch -ge 0) { $sbCalls[$iLaunch] } else { "" }
        # The launch argv is the ONE call that legitimately carries the worker
        # token, so it must be scrubbed before it can reach a failure message
        # (and from there a CI log).
        $safeLaunchLine = Protect-SandboxText -Text $launchLine -Secrets @($sbSecret)

        # (a) the command evaluated below is byte-for-byte the command that ships.
        $sbShipEnv = New-SandboxWorkerEnvironment -Request $sbRequest -Context $sbProvider.Context
        $sbShipLaunch = New-SandboxLaunchCommand -Environment $sbShipEnv -StateDir $sbProvider.Context.StateDir
        if ($launchLine.Contains($sbShipLaunch)) {
            Add-Pass "The command the detach test evaluates is byte-for-byte the command 'aca sandbox exec -c' was given"
        } else {
            Add-Fail "New-SandboxLaunchCommand no longer produces the argv that was actually issued, so the detach test would be testing a different string: $safeLaunchLine"
        }

        # (b) the behavioural test, delegated to scripts/tests/verify-launch-detachment.ps1
        #     so the same probe is a standalone CI gate on a real Linux runner
        #     rather than a check that only ever runs on a developer's WSL box.
        #     A correct implementation releases the caller while the worker is
        #     still running; the mis-scoped one blocks for the worker's full
        #     duration. Exit 77 means the probe DID NOT RUN (deps.sh convention).
        $sbDetachScript = Join-Path $RepoRoot "scripts\tests\verify-launch-detachment.ps1"
        if (-not (Test-Path $sbDetachScript)) {
            Add-Fail "scripts/tests/verify-launch-detachment.ps1 is missing -- nothing else in this suite can tell a detach from a command containing the characters of one"
        } else {
            $sbDetachOut = (& (Get-Process -Id $PID).Path -NoProfile -File $sbDetachScript 2>&1 | Out-String)
            $sbDetachRc = $LASTEXITCODE
            $sbDetachFlat = ($sbDetachOut -replace "`r?`n", " | ").Trim()
            if ($sbDetachRc -eq 0) {
                Add-Pass "The emitted launch command really detaches in a real shell (verify-launch-detachment.ps1): $sbDetachFlat"
            } elseif ($sbDetachRc -eq 77) {
                # A dependency we cannot satisfy is a SKIP, never a pass: the
                # worker suite's convention (worker/tests/lib/deps.sh -> exit 77
                # -> run-tests.sh reports SKIP) exists so a check cannot quietly
                # stop existing when its dependency goes missing.
                Add-Skip "Worker-launch detachment is UNVERIFIED: $sbDetachFlat"
            } else {
                Add-Fail "The emitted launch command does NOT detach (verify-launch-detachment.ps1 exit $sbDetachRc): $sbDetachFlat"
            }
        }

        if ($launchLine -like "*/usr/local/bin/squad-on-aca*" -and $launchLine -like "*exit-code*" -and $launchLine -like "*touch /tmp/squad-session/done*") {
            Add-Pass "The detached wrapper records an exit code and touches the completion marker last"
        } else {
            Add-Fail "The detached wrapper does not record terminal state: $safeLaunchLine"
        }

        # --- 3. secrets never reach anything the provider EMITS ---------------
        # The token is delivered to the worker as an environment assignment in
        # the launch command, so it is present in that one process argv (PRD #6
        # Sprint 7 owns credential brokerage and replaces this). What must never
        # happen is the provider REPEATING it: into the dispatch response, into
        # an error message, or into the rendered argv it puts in one.
        $sbResponseText = ($sbOutcome["Response"] | ConvertTo-Json -Depth 8)
        if ($sbResponseText -notmatch [regex]::Escape($sbSecret)) {
            Add-Pass "The worker token never appears in the dispatch response"
        } else {
            Add-Fail "The worker token leaked into the dispatch response"
        }
        $sbSafe = Get-SandboxSafeArgv -Argv @("sandbox", "egress", "set", "--default", "Deny", "--rule", "*.github.com:Allow", "-c", "GH_TOKEN=$sbSecret /usr/local/bin/squad-on-aca", "--token", $sbSecret)
        if ($sbSafe -notmatch [regex]::Escape($sbSecret) -and $sbSafe -notmatch "github\.com" -and $sbSafe -notmatch "squad-on-aca" -and $sbSafe -like "*--token <redacted>*") {
            Add-Pass "Safe argv rendering redacts tokens, egress policy values and remote commands"
        } else {
            Add-Fail "Safe argv rendering leaked a token, an egress value or a command: $sbSafe"
        }
        # And a failure of the launch itself -- the one call whose argv really
        # does carry the token -- must not quote it back.
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_ACA_EXEC_RC = "1"
        $sbLaunchMsg = ""
        try { Start-SquadExecution -Provider $sbProvider -Request $sbRequest 6>$null | Out-Null } catch { $sbLaunchMsg = [string]$_.Exception.Message }
        $env:SQUAD_STUB_ACA_EXEC_RC = "0"
        if ($sbLaunchMsg -and $sbLaunchMsg -notmatch [regex]::Escape($sbSecret) -and $sbLaunchMsg -notmatch "github\.com") {
            Add-Pass "A failed worker launch reports the failure without echoing the token-bearing command"
        } else {
            Add-Fail "A failed worker launch leaked the token or the egress policy: $sbLaunchMsg"
        }

        # Protect-SandboxText, DIRECTLY. It is the only control on captured CLI
        # OUTPUT (Get-SandboxErrorText feeds every thrown error in the provider,
        # plus `logs` line output and `cancel` host output), and until now it had
        # no test of its own: the checks above pass on Get-SandboxSafeArgv's
        # argv-side redaction alone, so the whole function body could be replaced
        # with `return $Text` and the suite still reported all green.
        #
        # The lengths are the ones that occur in practice. They also happen to be
        # exactly the lengths the defect hid behind: `[string]$secret.Length -lt 8`
        # is `[string]($secret.Length)`, so PowerShell coerced the right operand
        # to string and compared LEXICALLY -- "40" -lt "8" is $true -- and only
        # lengths 8, 9 and 80-99 were ever scrubbed.
        $sbRedactLengths = @(
            @{ Len = 27;   What = "the suite's own fixture token" },
            @{ Len = 36;   What = "a GUID" },
            @{ Len = 40;   What = "a classic GitHub PAT" },
            @{ Len = 64;   What = "a hex API key" },
            @{ Len = 93;   What = "a fine-grained PAT" },
            @{ Len = 1200; What = "an ACR refresh token / JWT" }
        )
        $sbRedactBad = @()
        foreach ($case in $sbRedactLengths) {
            $secret = "s" + ("K" * ([int]$case.Len - 1))
            $out = Protect-SandboxText -Text "aca: request failed, token=$secret was rejected" -Secrets @($secret)
            if ($out.Contains($secret) -or $out -notlike "*token=<redacted>*") {
                $sbRedactBad += "$($case.Len) ($($case.What))"
            }
        }
        if ($sbRedactBad.Count -eq 0) {
            Add-Pass "Protect-SandboxText redacts a secret at every realistic credential length (27/36/40/64/93/1200)"
        } else {
            Add-Fail "Protect-SandboxText passed a secret through verbatim at length(s): $($sbRedactBad -join ', ')"
        }

        # Multiple secrets, repeated occurrences, and the sub-8 floor (too short
        # to be a credential and too likely to shred ordinary words).
        $sbLongA = "A" * 40
        $sbLongB = "B" * 36
        $sbMulti = Protect-SandboxText -Text "first=$sbLongA second=$sbLongB again=$sbLongA short=abc" -Secrets @($sbLongA, $sbLongB, "abc")
        if ($sbMulti -eq "first=<redacted> second=<redacted> again=<redacted> short=abc") {
            Add-Pass "Protect-SandboxText replaces every occurrence of every secret and leaves sub-8 values alone"
        } else {
            Add-Fail "Protect-SandboxText mishandled multiple/repeated secrets or the length floor: $sbMulti"
        }

        # And the path that matters: a CLI echoing the secret back in its OWN
        # error text must not survive Get-SandboxErrorText into a thrown message.
        $sbEchoResult = [pscustomobject]@{
            StdErr = @("ERROR: authentication failed for token $sbSecret (40 chars)")
            StdOut = @()
        }
        $sbEchoText = Get-SandboxErrorText -Result $sbEchoResult -Secrets @($sbSecret)
        if ($sbEchoText -notmatch [regex]::Escape($sbSecret) -and $sbEchoText -like "*<redacted>*") {
            Add-Pass "A CLI that echoes the secret back in its own error text is scrubbed before the text reaches an exception"
        } else {
            Add-Fail "Get-SandboxErrorText passed a CLI-echoed secret through: $sbEchoText"
        }

        # --- 4. a long session is driven by POLLING, not by one exec ---------
        $pollDir = Join-Path $sbStub.Root "pollstate"
        New-Item -ItemType Directory -Force -Path $pollDir | Out-Null
        $env:SQUAD_STUB_ACA_POLL_DIR = $pollDir
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "running" -Encoding ascii -NoNewline

        Reset-SquadCliStubLog -Stub $sbStub
        $sbHandle = $sbOutcome["Response"].sessionHandle
        $sbRunning = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        if ($sbRunning.Status -eq "Running" -and -not $sbRunning.Inconclusive) {
            Add-Pass "A poll of a live session reports Running from the marker/phase file"
        } else {
            Add-Fail "A live session did not poll as Running (status=$($sbRunning.Status) inconclusive=$($sbRunning.Inconclusive))"
        }

        # Terminal state must come from the marker PLUS a recorded exit code.
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "done" -Encoding ascii -NoNewline
        Set-Content -LiteralPath (Join-Path $pollDir "done.txt") -Value "x" -Encoding ascii -NoNewline
        $sbMarkerOnly = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        Set-Content -LiteralPath (Join-Path $pollDir "exit.txt") -Value "0" -Encoding ascii -NoNewline
        $sbDone = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        Set-Content -LiteralPath (Join-Path $pollDir "exit.txt") -Value "1" -Encoding ascii -NoNewline
        $sbFailed = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        if ($sbMarkerOnly.Status -ne "Succeeded" -and $sbDone.Status -eq "Succeeded" -and $sbFailed.Status -eq "Failed") {
            Add-Pass "Terminal state needs the completion marker AND a recorded exit code (marker alone is not Succeeded)"
        } else {
            Add-Fail "Terminal state was derived incorrectly (markerOnly=$($sbMarkerOnly.Status) exit0=$($sbDone.Status) exit1=$($sbFailed.Status))"
        }

        # `wait` to terminal must issue MULTIPLE short execs, never rely on one.
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "running" -Encoding ascii -NoNewline
        Remove-Item -LiteralPath (Join-Path $pollDir "done.txt"), (Join-Path $pollDir "exit.txt") -Force -ErrorAction SilentlyContinue
        Reset-SquadCliStubLog -Stub $sbStub
        $sbWaitThrew = $false
        try {
            Wait-SquadExecution -Provider $sbProvider -Handle $sbHandle -TimeoutSeconds 3 -PollSeconds 1 -UntilTerminal | Out-Null
        } catch {
            $sbWaitThrew = $true
        }
        $sbPolls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca | Where-Object { $_ -like "sandbox exec *" })
        if ($sbWaitThrew -and $sbPolls.Count -ge 3) {
            Add-Pass "A long-running session is driven by repeated short polls ($($sbPolls.Count) execs), not by one synchronous exec"
        } else {
            Add-Fail "wait did not poll repeatedly (threw=$sbWaitThrew execs=$($sbPolls.Count))"
        }

        # --- 5. a transport timeout mid-poll is INCONCLUSIVE, and is re-polled -
        # `Network issue - retry policy expired` is the ~120s client timeout. The
        # work is almost certainly still running; reporting Failed here would
        # kill a healthy 60-minute session at the two-minute mark.
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "running" -Encoding ascii -NoNewline
        $timeoutMarker = Join-Path $sbStub.Root "timeout-once.txt"
        Remove-Item -LiteralPath $timeoutMarker -Force -ErrorAction SilentlyContinue
        $env:SQUAD_STUB_ACA_TIMEOUT_ONCE = $timeoutMarker
        Reset-SquadCliStubLog -Stub $sbStub
        $sbIncThrew = $false
        $sbInc = $null
        try {
            $sbInc = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        } catch {
            $sbIncThrew = $true
        }
        if (-not $sbIncThrew -and $sbInc -and $sbInc.Inconclusive -and $sbInc.Status -ne "Failed") {
            Add-Pass "A transport timeout mid-poll is reported INCONCLUSIVE, never as a failed session"
        } else {
            Add-Fail "A transport timeout was not treated as inconclusive (threw=$sbIncThrew status=$($sbInc.Status) inconclusive=$($sbInc.Inconclusive))"
        }

        # ... and the next poll (the stub's timeout fires only once) recovers.
        $sbAfter = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        if (-not $sbAfter.Inconclusive -and $sbAfter.Status -eq "Running") {
            Add-Pass "Re-polling after an inconclusive transport timeout recovers the real state"
        } else {
            Add-Fail "Re-polling after a transport timeout did not recover (status=$($sbAfter.Status) inconclusive=$($sbAfter.Inconclusive))"
        }

        # `wait` must not return an inconclusive poll as a result either.
        Remove-Item -LiteralPath $timeoutMarker -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "done" -Encoding ascii -NoNewline
        Set-Content -LiteralPath (Join-Path $pollDir "done.txt") -Value "x" -Encoding ascii -NoNewline
        Set-Content -LiteralPath (Join-Path $pollDir "exit.txt") -Value "0" -Encoding ascii -NoNewline
        $sbWaitRec = Wait-SquadExecution -Provider $sbProvider -Handle $sbHandle -TimeoutSeconds 10 -PollSeconds 1 -UntilTerminal
        $env:SQUAD_STUB_ACA_TIMEOUT_ONCE = ""
        if ($sbWaitRec.Status -eq "Succeeded" -and -not $sbWaitRec.Inconclusive) {
            Add-Pass "wait rides through an inconclusive poll and returns the real terminal state"
        } else {
            Add-Fail "wait did not ride through an inconclusive poll (status=$($sbWaitRec.Status) inconclusive=$($sbWaitRec.Inconclusive))"
        }

        # --- 6. terminate: idempotent, but only for 'already gone' -----------
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_ACA_DELETE_RC = "0"
        $sbTerm = Remove-SquadExecution -Provider $sbProvider -Handle $sbHandle
        $sbDeleteCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca | Where-Object { $_ -like "sandbox delete *" })
        if ($sbTerm.Terminated -and -not $sbTerm.AlreadyTerminal -and $sbDeleteCalls.Count -eq 1 -and $sbDeleteCalls[0] -like "*-l name=squad-stub-session --yes*") {
            Add-Pass "Sandbox terminate deletes with one labelled 'aca sandbox delete --yes'"
        } else {
            Add-Fail "Sandbox terminate did not delete correctly (terminated=$($sbTerm.Terminated) calls=$($sbDeleteCalls.Count))"
        }

        $sbGoneCases = @(
            @{ Rc = "1"; Err = "Error: sandbox with label name=squad-stub-session was not found"; Label = "not found" },
            @{ Rc = "1"; Err = "Error: ResourceNotFound: the sandbox no longer exists"; Label = "ResourceNotFound" }
        )
        $sbGoneOk = $true
        $sbGoneDetail = @()
        foreach ($case in $sbGoneCases) {
            $env:SQUAD_STUB_ACA_DELETE_RC = $case.Rc
            $env:SQUAD_STUB_ACA_DELETE_ERR = $case.Err
            $r = $null
            $threw = $false
            try { $r = Remove-SquadExecution -Provider $sbProvider -Handle $sbHandle } catch { $threw = $true }
            if ($threw -or -not $r.Terminated -or -not $r.AlreadyTerminal) {
                $sbGoneOk = $false
                $sbGoneDetail += "$($case.Label): threw=$threw terminated=$($r.Terminated) already=$($r.AlreadyTerminal)"
            }
        }
        $env:SQUAD_STUB_ACA_DELETE_RC = "0"
        $env:SQUAD_STUB_ACA_DELETE_ERR = ""
        if ($sbGoneOk) {
            Add-Pass "Sandbox terminate is idempotent: an already-deleted sandbox is success (AlreadyTerminal)"
        } else {
            Add-Fail "Sandbox terminate mishandled an already-gone sandbox ($($sbGoneDetail -join '; '))"
        }

        # The defect this exists for: returning Terminated=$true for EVERY
        # non-zero exit. A cleanup path told "terminated" stops looking, so an
        # auth failure, an RBAC denial, throttling or a transport timeout leaks
        # a running sandbox and bills for it.
        $sbFailCases = @(
            @{ Err = "ERROR: AADSTS700082: The refresh token has expired. Please run 'aca login'."; Label = "expired auth" },
            @{ Err = "Error: 403 CheckAccess: the caller does not have permission on the sandbox group"; Label = "RBAC denial" },
            @{ Err = "Error: 429 TooManyRequests: rate limit exceeded, retry after 30s"; Label = "throttling" },
            @{ Err = "Error: Network issue - retry policy expired"; Label = "transport timeout" }
        )
        $sbFailOk = $true
        $sbFailDetail = @()
        foreach ($case in $sbFailCases) {
            $env:SQUAD_STUB_ACA_DELETE_RC = "1"
            $env:SQUAD_STUB_ACA_DELETE_ERR = $case.Err
            $threw = $false
            $msg = ""
            try { Remove-SquadExecution -Provider $sbProvider -Handle $sbHandle | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
            if (-not $threw) {
                $sbFailOk = $false
                $sbFailDetail += "$($case.Label): did not throw"
            }
        }
        $env:SQUAD_STUB_ACA_DELETE_RC = "0"
        $env:SQUAD_STUB_ACA_DELETE_ERR = ""
        if ($sbFailOk) {
            Add-Pass "Sandbox terminate THROWS on auth, RBAC, throttling and transport failures (never reported as torn down)"
        } else {
            Add-Fail "Sandbox terminate swallowed a real failure ($($sbFailDetail -join '; '))"
        }

        # --- 6b. cancel classifies failures the same way terminate does -------
        # cancel is the softer sibling of the same defect: writing a non-zero
        # exit to the host and returning success tells the caller the session was
        # stopped when an auth failure, an RBAC denial, throttling or a transport
        # timeout says nothing about whether the worker is still running -- and
        # still billing. Same classifier as terminate, not a second mechanism.
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_ACA_CANCEL_RC = "0"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = ""
        $sbCancelOk = Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null
        $sbCancelCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca | Where-Object { $_ -like "*squad-cancelled*" })
        if ($sbCancelOk.Cancelled -and -not $sbCancelOk.AlreadyTerminal -and $sbCancelCalls.Count -eq 1) {
            Add-Pass "Sandbox cancel stops the worker with one labelled 'aca sandbox exec' and reports success"
        } else {
            Add-Fail "Sandbox cancel did not cancel correctly (cancelled=$($sbCancelOk.Cancelled) calls=$($sbCancelCalls.Count))"
        }

        $env:SQUAD_STUB_ACA_CANCEL_RC = "1"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = "Error: sandbox with label name=squad-stub-session was not found"
        $sbCancelGone = $null
        $sbCancelGoneThrew = $false
        try { $sbCancelGone = Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null } catch { $sbCancelGoneThrew = $true }
        if (-not $sbCancelGoneThrew -and $sbCancelGone.Cancelled -and $sbCancelGone.AlreadyTerminal) {
            Add-Pass "Sandbox cancel is idempotent: an already-gone sandbox is success (AlreadyTerminal), not an error"
        } else {
            Add-Fail "Sandbox cancel mishandled an already-gone sandbox (threw=$sbCancelGoneThrew cancelled=$($sbCancelGone.Cancelled) already=$($sbCancelGone.AlreadyTerminal))"
        }

        $sbCancelFailOk = $true
        $sbCancelFailDetail = @()
        foreach ($case in $sbFailCases) {
            $env:SQUAD_STUB_ACA_CANCEL_RC = "1"
            $env:SQUAD_STUB_ACA_CANCEL_ERR = $case.Err
            $threw = $false
            $msg = ""
            try { Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
            if (-not $threw) {
                $sbCancelFailOk = $false
                $sbCancelFailDetail += "$($case.Label): did not throw"
            } elseif ($msg -match [regex]::Escape($sbSecret)) {
                $sbCancelFailOk = $false
                $sbCancelFailDetail += "$($case.Label): leaked the token"
            }
        }
        $env:SQUAD_STUB_ACA_CANCEL_RC = "0"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = ""
        if ($sbCancelFailOk) {
            Add-Pass "Sandbox cancel THROWS on auth, RBAC, throttling and transport failures (never reported as cancelled)"
        } else {
            Add-Fail "Sandbox cancel swallowed a real failure ($($sbCancelFailDetail -join '; '))"
        }

        # --- 7. refusal when the sandbox group carries a managed identity ----
        # Private-registry pulls use an ACR refresh token precisely so the group
        # needs no identity. An identity on the group is an escalation path out
        # of the sandbox, so the provider must refuse before creating anything.
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_SBG_IDENTITY = "1"
        $sbIdThrew = $false
        $sbIdMsg = ""
        try { Start-SquadExecution -Provider $sbProvider -Request $sbRequest 6>$null | Out-Null } catch { $sbIdThrew = $true; $sbIdMsg = [string]$_.Exception.Message }
        $sbIdCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $env:SQUAD_STUB_SBG_IDENTITY = ""
        if ($sbIdThrew -and $sbIdCalls.Count -eq 0 -and $sbIdMsg -match "identity") {
            Add-Pass "Provider refuses to use a sandbox group that has a managed identity, before creating anything"
        } else {
            Add-Fail "A sandbox group with a managed identity was not refused (threw=$sbIdThrew acaCalls=$($sbIdCalls.Count) msg=$sbIdMsg)"
        }

        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_SBG_RC = "1"
        $sbIdFailThrew = $false
        try { Start-SquadExecution -Provider $sbProvider -Request $sbRequest 6>$null | Out-Null } catch { $sbIdFailThrew = $true }
        $sbIdFailCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $env:SQUAD_STUB_SBG_RC = "0"
        if ($sbIdFailThrew -and $sbIdFailCalls.Count -eq 0) {
            Add-Pass "An identity check that cannot be completed fails closed (unknown is not treated as 'no identity')"
        } else {
            Add-Fail "A failed identity check did not fail closed (threw=$sbIdFailThrew acaCalls=$($sbIdFailCalls.Count))"
        }

        # --- 8. --identity is refused wherever it appears --------------------
        $sbIdentityArgvRefused = $false
        try { Assert-SandboxArgvIdentityFree -Argv @("sandboxgroup", "disk", "create", "--identity", "mi-squad") } catch { $sbIdentityArgvRefused = $true }
        $sbIdentityArgvRefused2 = $false
        try { Assert-SandboxArgvIdentityFree -Argv @("sandbox", "create", "--system-assigned") } catch { $sbIdentityArgvRefused2 = $true }
        if ($sbIdentityArgvRefused -and $sbIdentityArgvRefused2) {
            Add-Pass "Any argv carrying --identity / --system-assigned is refused before the process starts"
        } else {
            Add-Fail "An identity-granting flag was not refused (--identity=$sbIdentityArgvRefused --system-assigned=$sbIdentityArgvRefused2)"
        }

        # --- 9. failure between policy and launch tears the sandbox down -----
        # Otherwise a sandbox is left running, billed for, and orphaned.
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_ACA_EGRESS_RC = "1"
        $env:SQUAD_STUB_ACA_EGRESS_ERR = "Error: egress policy rejected"
        $sbEgThrew = $false
        $sbEgMsg = ""
        try { Start-SquadExecution -Provider $sbProvider -Request $sbRequest 6>$null | Out-Null } catch { $sbEgThrew = $true; $sbEgMsg = [string]$_.Exception.Message }
        $sbEgCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $sbEgLaunched = @($sbEgCalls | Where-Object { $_ -like "*squad-launched*" }).Count
        $sbEgDeleted = @($sbEgCalls | Where-Object { $_ -like "sandbox delete *" }).Count
        $env:SQUAD_STUB_ACA_EGRESS_RC = "0"
        $env:SQUAD_STUB_ACA_EGRESS_ERR = ""
        if ($sbEgThrew -and $sbEgLaunched -eq 0 -and $sbEgDeleted -eq 1) {
            Add-Pass "If the egress policy cannot be applied, no repository code is launched and the sandbox is torn down"
        } else {
            Add-Fail "A failed egress policy did not stop the launch or leaked a sandbox (threw=$sbEgThrew launches=$sbEgLaunched deletes=$sbEgDeleted)"
        }
        if ($sbEgMsg -notmatch "github\.com" -and $sbEgMsg -notmatch "npmjs" -and $sbEgMsg -notmatch [regex]::Escape($sbSecret)) {
            Add-Pass "The egress failure message carries no policy host patterns and no token"
        } else {
            Add-Fail "An egress failure message leaked policy values or a token: $sbEgMsg"
        }

        # --- 10. disk label -> GUID resolution --------------------------------
        # `--name` on `disk create` becomes a LABEL, so a private disk has to be
        # resolved to its GUID; `--disk` accepts public images only.
        Reset-SquadCliStubLog -Stub $sbStub
        $sbLabelProvider = New-SandboxTestProvider -DiskId "" -DiskLabel "squad-worker-stub"
        try { Start-SquadExecution -Provider $sbLabelProvider -Request $sbRequest 6>$null | Out-Null } catch { }
        $sbLabelCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $sbListed = @($sbLabelCalls | Where-Object { $_ -like "sandboxgroup disk list*" }).Count
        $sbUsedGuid = @($sbLabelCalls | Where-Object { $_ -like "sandbox create *--disk-id aaaaaaaa-1111-2222-3333-444444444444*" }).Count
        if ($sbListed -eq 1 -and $sbUsedGuid -eq 1) {
            Add-Pass "A disk label is resolved to its GUID via 'sandboxgroup disk list' before create"
        } else {
            Add-Fail "Disk label resolution did not happen (lists=$sbListed guidCreates=$sbUsedGuid)"
        }

        # --- 11. every sandbox is labelled with its session id ---------------
        $sbLabelled = @($sbCalls | Where-Object { $_ -like "*name=squad-stub-session*" }).Count
        if ($sbLabelled -ge 4) {
            Add-Pass "Every sandbox operation is addressed by a session-derived label, so a reaper can find orphans"
        } else {
            Add-Fail "Sandbox operations are not consistently session-labelled ($sbLabelled labelled calls)"
        }
    } catch {
        Add-Fail "Sandbox provider checks threw: $($_.Exception.Message)"
    } finally {
        $env:PATH = $sbPrevPath
        foreach ($name in $sbEnvNames) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        if ($sbStub) { Remove-SquadCliStubEnvironment -Stub $sbStub }
    }
}

# ---------------------------------------------------------------------------
# 9. CLI behaviour regression (offline, stubbed az/gh)
# ---------------------------------------------------------------------------
Write-Section "CLI behaviour regression"
$harness = Join-Path $RepoRoot "scripts\tests\cli-stub-harness.ps1"
$cliScript = Join-Path $RepoRoot "scripts\squad-aca.ps1"
if (-not (Test-Path $harness)) {
    Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing (CLI regression harness)"
} elseif (-not $IsWindowsHost) {
    Write-Host "  [SKIP] CLI regression harness requires Windows (.cmd stubs)" -ForegroundColor Yellow
} else {
    . $harness
    $stub = $null
    try {
        $stub = New-SquadCliStubEnvironment

        # sessions: exact az call sequence and rendered table.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("sessions")
        if ($r.ExitCode -eq 0) { Add-Pass "squad-aca sessions exits 0" }
        else { Add-Fail "squad-aca sessions exited $($r.ExitCode), expected 0" }
        $listCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job execution list*" })
        if ($listCall.Count -eq 1 -and $listCall[0] -like "*--name caj-squad-aca-session --resource-group rg-squad-stub*") {
            Add-Pass "squad-aca sessions issues exactly one 'az containerapp job execution list' with the configured job/resource group"
        } else {
            Add-Fail "squad-aca sessions az call sequence changed: $($r.AzCalls -join ' | ')"
        }
        $headerCols = @("Execution", "Status", "Session", "Mode", "Repository", "Branch", "Started", "Ended")
        $missingCols = @($headerCols | Where-Object { $r.StdOut -notmatch [regex]::Escape($_) })
        if ($missingCols.Count -eq 0) {
            Add-Pass "squad-aca sessions renders the original eight columns (no handle column leaked into the table)"
        } else {
            Add-Fail "squad-aca sessions table lost columns: $($missingCols -join ', ')"
        }
        if ($r.StdOut -notmatch "sqx1\.") {
            Add-Pass "squad-aca sessions does not print opaque execution handles"
        } else {
            Add-Fail "squad-aca sessions leaked an opaque execution handle into user-visible output"
        }

        # logs: default tail and explicit tail must reach az unchanged.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("logs")
        $logCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job logs show*" })
        if ($r.ExitCode -eq 0 -and $logCall.Count -eq 1 -and $logCall[0] -like "*--tail 100*" -and $logCall[0] -like "*--execution *") {
            Add-Pass "squad-aca logs defaults to --tail 100 against the worker container"
        } else {
            Add-Fail "squad-aca logs default call changed: $($logCall -join ' | ')"
        }
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("logs", "--tail", "5")
        $logCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job logs show*" })
        if ($r.ExitCode -eq 0 -and $logCall.Count -eq 1 -and $logCall[0] -like "*--tail 5*") {
            Add-Pass "squad-aca logs --tail 5 is forwarded to az unchanged"
        } else {
            Add-Fail "squad-aca logs --tail 5 call changed: $($logCall -join ' | ')"
        }

        # stop: must map to az job stop (cancel), NOT to idempotent terminate.
        # The stdout assertion is the point: PR #9 was closed for a `stop`
        # output regression, and call-count + exit-code alone cannot see one.
        # The stub's `az containerapp job stop` prints STUB-STOP-ACK; appending
        # `| Out-Null` to the adapter's cancel call keeps the call count and the
        # exit code identical while the user loses every byte az printed.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("stop")
        $stopCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job stop*" })
        if ($r.ExitCode -eq 0 -and $stopCall.Count -eq 1 -and $stopCall[0] -like "*--job-execution-name *") {
            Add-Pass "squad-aca stop issues exactly one 'az containerapp job stop' for the resolved execution"
        } else {
            Add-Fail "squad-aca stop az call sequence changed: $($r.AzCalls -join ' | ')"
        }
        if ($r.StdOut -match "STUB-STOP-ACK") {
            Add-Pass "squad-aca stop passes 'az containerapp job stop' stdout through to the user (PR #9 regression class)"
        } else {
            Add-Fail "squad-aca stop swallowed az stdout; the user no longer sees what 'az containerapp job stop' printed (PR #9 regression class). stdout=$($r.StdOut)"
        }

        # Anti-regression for PR #9: a failing az stop must still surface exactly
        # one stop call, its output, and today's exit code -- no swallowing.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("stop") -StopExitCode 3
        $stopCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job stop*" })
        if ($stopCall.Count -eq 1 -and $r.ExitCode -eq 0) {
            Add-Pass "squad-aca stop preserves today's pass-through behaviour when az stop fails (no swallowing, no retry)"
        } else {
            Add-Fail "squad-aca stop changed behaviour on az failure (calls=$($stopCall.Count), exit=$($r.ExitCode))"
        }
        if ($r.StdOut -match "STUB-STOP-ACK") {
            Add-Pass "squad-aca stop still shows az output when az stop fails (the failure text is the user's only diagnostic)"
        } else {
            Add-Fail "squad-aca stop swallowed az output on failure; the user gets no diagnostic at all. stdout=$($r.StdOut)"
        }

        # Unresolvable session: message text and exit code are observable.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("stop", "no-such-session")
        if ($r.ExitCode -eq 1 -and $r.StdErr -match "Could not find session or execution 'no-such-session'") {
            Add-Pass "squad-aca stop on an unknown session keeps its error text and exit code 1"
        } else {
            Add-Fail "squad-aca stop on an unknown session changed (exit=$($r.ExitCode))"
        }

        # smoke: dispatch still goes through az containerapp job start.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("smoke", "--repo", "octo/demo")
        $startCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job start*" })
        if ($r.ExitCode -eq 0 -and $startCall.Count -eq 1 -and $startCall[0] -like "*SQUAD_MODE=smoke*" -and $startCall[0] -like "*RUN_COPILOT_SMOKE=true*") {
            Add-Pass "squad-aca smoke dispatches one 'az containerapp job start' with the smoke env-vars"
        } else {
            Add-Fail "squad-aca smoke dispatch changed: $($startCall -join ' | ')"
        }

        # doctor is not routed through the provider; assert it is still intact.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("doctor")
        if ($r.ExitCode -eq 0 -and $r.StdOut -match "Azure auth" -and $r.StdOut -match "GitHub repo") {
            Add-Pass "squad-aca doctor output is unchanged"
        } else {
            Add-Fail "squad-aca doctor output changed (exit=$($r.ExitCode))"
        }
    } catch {
        Add-Fail "CLI behaviour regression checks threw: $($_.Exception.Message)"
    } finally {
        if ($stub) { Remove-SquadCliStubEnvironment -Stub $stub }
    }
}

# ---------------------------------------------------------------------------
# 9b. Unified dispatch contract + durable leases (Sprint 6, PRD #6)
# ---------------------------------------------------------------------------
# Two things are proven here that no other check can prove:
#   1. The PowerShell CLI does not carry its own copy of the routing rule. It is
#      compared byte-for-byte against the shared dispatch core's own output for
#      every dispatch source, so any PowerShell-side "adjustment" of the route
#      shows up as a failure rather than as drift.
#   2. The lease is written BEFORE compute is requested. Asserted by INDEX in a
#      shared, ordered call log that both the fake `az` and the lease store
#      append to -- a presence check would pass even if the order were inverted.
Write-Section "Unified dispatch contract and leases"
$dispatchCli = Join-Path $RepoRoot "worker\lib\squad-dispatch.js"
$contractLib = Join-Path $RepoRoot "scripts\lib\dispatch-contract.ps1"
$fakeGh = Join-Path $RepoRoot "worker\tests\lib\fake-gh.js"
$nodeAvailable = [bool](Get-Command node -ErrorAction SilentlyContinue)

if (-not (Test-Path $dispatchCli)) {
    Add-Fail "worker/lib/squad-dispatch.js is missing (the shared dispatch core)"
} elseif (-not (Test-Path $contractLib)) {
    Add-Fail "scripts/lib/dispatch-contract.ps1 is missing (the PowerShell face of the contract)"
} elseif (-not $nodeAvailable) {
    Add-Fail "node is required for the shared dispatch contract but is not on PATH"
} else {
    # The contract must be one implementation, not two that happen to agree.
    # Assert the PowerShell side never re-derives a route locally: strip comments
    # and look for a hard-coded route literal in executable code.
    $contractCode = (Get-Content -LiteralPath $contractLib) |
        Where-Object { $_.TrimStart() -notlike "#*" } |
        ForEach-Object { $_ -replace '\s+#.*$', '' }
    $localRoute = @($contractCode | Where-Object { $_ -match "['`"](aca-job|sandbox|fail-closed)['`"]" })
    $delegates = @($contractCode | Where-Object { $_ -match "squad-dispatch\.js" }).Count -ge 1
    if ($localRoute.Count -eq 0 -and $delegates) {
        Add-Pass "dispatch-contract.ps1 contains no PowerShell-local routing rule (it only calls the shared core)"
    } else {
        Add-Fail "dispatch-contract.ps1 appears to re-implement routing in PowerShell (delegates=$delegates, literals=$($localRoute -join ' | ')); the decision must come from worker/lib/dispatch-decision.js only"
    }

    . $contractLib
    $leaseRoot = Join-Path $RepoRoot ".validate-leases"
    $savedGhBin = $env:SQUAD_GH_BIN
    $savedState = $env:FAKE_GH_STATE
    $savedNow = $env:SQUAD_LEASE_NOW
    $savedFail = $env:FAKE_GH_FAIL_MODE
    try {
        Remove-Item -Recurse -Force $leaseRoot -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
        $env:SQUAD_GH_BIN = $fakeGh
        $env:FAKE_GH_STATE = $leaseRoot
        $env:SQUAD_LEASE_NOW = "2024-05-01T00:00:00.000Z"
        $env:FAKE_GH_FAIL_MODE = ""

        # --- 1. One decision, three dispatchers, compared byte-for-byte ------
        $routings = @{}
        foreach ($source in @("local-cli", "ralph", "watch")) {
            $psDecision = Get-SquadDispatchDecision -SessionId "s-1" -DispatchSource $source -Repository "octo/demo" -IssueNumber "7"
            $routings[$source] = ($psDecision.routing | ConvertTo-Json -Depth 20 -Compress)
        }
        if ($routings["local-cli"] -eq $routings["ralph"] -and $routings["local-cli"] -eq $routings["watch"]) {
            Add-Pass "The routing decision is identical for local-cli, ralph and watch (byte-for-byte)"
        } else {
            Add-Fail "The routing decision differs by dispatcher: $($routings.Values -join ' || ')"
        }

        # The PowerShell shim must return the core's answer unmodified. Compare
        # against the core invoked directly, not against a hand-written expectation.
        $rawJson = & node $dispatchCli decide --session-id "s-1" --dispatch-source "ralph" --repository "octo/demo" --issue 7
        $rawRouting = (($rawJson | ConvertFrom-Json).routing | ConvertTo-Json -Depth 20 -Compress)
        if ($rawRouting -eq $routings["ralph"]) {
            Add-Pass "Get-SquadDispatchDecision returns the shared core's decision unmodified"
        } else {
            Add-Fail "The PowerShell shim altered the routing decision (core=$rawRouting shim=$($routings['ralph']))"
        }

        # --- 2. Lease lifecycle from PowerShell ------------------------------
        $decision = Get-SquadDispatchDecision -SessionId "issue-7-a" -DispatchSource "local-cli" -Repository "octo/demo" -IssueNumber "7"
        $claim1 = New-SquadDispatchLease -Decision $decision -Repository "octo/demo"
        Set-SquadDispatchLeaseState -Operation "dispatched" -Repository "octo/demo" -LeaseKey $decision.leaseKey | Out-Null
        $claim2 = New-SquadDispatchLease -Decision $decision -Repository "octo/demo"
        if ($claim1.outcome -eq "created" -and $claim2.outcome -eq "active") {
            Add-Pass "A duplicate claim from PowerShell is refused while the lease is live (no double-dispatch)"
        } else {
            Add-Fail "Duplicate claim handling changed (first=$($claim1.outcome) second=$($claim2.outcome))"
        }

        # --- 3. Cleanup under auth failure THROWS ----------------------------
        $env:FAKE_GH_FAIL_MODE = "auth"
        $threw = $false
        try {
            Invoke-SquadLeaseSweep -Repository "octo/demo" | Out-Null
        } catch {
            $threw = $true
        }
        if ($threw) {
            Add-Pass "Sweeping under an auth failure throws instead of reporting a clean sweep"
        } else {
            Add-Fail "Sweeping under an auth failure reported success; a 401 must never be read as 'already clean'"
        }
        $threw = $false
        try {
            Set-SquadDispatchLeaseState -Operation "complete" -Repository "octo/demo" -LeaseKey $decision.leaseKey -State "succeeded" | Out-Null
        } catch {
            $threw = $true
        }
        if ($threw) {
            Add-Pass "Completing a lease under an auth failure throws instead of reporting success"
        } else {
            Add-Fail "Completing a lease under an auth failure reported success"
        }
        $env:FAKE_GH_FAIL_MODE = ""

        # --- 4. Externally-deleted lease is an idempotent SUCCESS ------------
        $gone = Set-SquadDispatchLeaseState -Operation "complete" -Repository "octo/demo" -LeaseKey "issue-99999" -State "succeeded"
        if ($gone.outcome -eq "gone") {
            Add-Pass "Completing a lease that no longer exists succeeds (idempotent cleanup)"
        } else {
            Add-Fail "Completing a missing lease returned '$($gone.outcome)', expected 'gone'"
        }

        # --- 5. The sweeper reclaims a stale lease and is idempotent ---------
        $env:SQUAD_LEASE_NOW = "2024-05-01T05:00:00.000Z"
        $sweep1 = Invoke-SquadLeaseSweep -Repository "octo/demo"
        $sweep2 = Invoke-SquadLeaseSweep -Repository "octo/demo"
        if (@($sweep1.reclaimed).Count -ge 1 -and @($sweep2.reclaimed).Count -eq 0) {
            Add-Pass "The sweeper reclaims a stale lease and reclaims nothing on a second run (idempotent)"
        } else {
            Add-Fail "Sweeper behaviour changed (first=$(@($sweep1.reclaimed).Count) second=$(@($sweep2.reclaimed).Count))"
        }

        # --- 6. CONCURRENT CLAIMS: a live claim is not a crashed one ---------
        # The check above proves a DISPATCHED lease refuses a second claim. That
        # is not the dangerous case. The dangerous case is back-to-back: two
        # dispatchers claim before either reaches compute, because the window
        # between claim and `az containerapp job start` spans an env build that
        # shells out to node and az -- seconds, not milliseconds. Ralph's cron
        # and a manual `squad-aca ralph run` overlap by design, so this is
        # reachable through supported operation.
        #
        # Both `created` and `repaired` mean "you own it, dispatch". A second
        # claimer must therefore see NEITHER.
        $env:SQUAD_LEASE_NOW = "2024-05-01T06:00:00.000Z"
        $decA = Get-SquadDispatchDecision -SessionId "issue-71-a" -DispatchSource "ralph" -Repository "octo/demo" -IssueNumber "71"
        $decB = Get-SquadDispatchDecision -SessionId "issue-71-b" -DispatchSource "local-cli" -Repository "octo/demo" -IssueNumber "71"
        $raceA = New-SquadDispatchLease -Decision $decA -Repository "octo/demo"
        $raceB = New-SquadDispatchLease -Decision $decB -Repository "octo/demo"
        if ($raceA.outcome -eq "created" -and $raceB.outcome -eq "active") {
            Add-Pass "Two dispatchers claiming back-to-back BEFORE compute: exactly one is told to dispatch (winner=created, loser=active)"
        } else {
            Add-Fail "Concurrent claim exclusion broken: first='$($raceA.outcome)' second='$($raceB.outcome)'; both 'created' and 'repaired' authorise a dispatch, so anything but 'active' for the loser double-dispatches"
        }
        if ($raceB.lease -and $raceB.lease.sessionId -eq "issue-71-a") {
            Add-Pass "The losing claimer is handed the CURRENT OWNER's lease record, so it can report who holds the work"
        } else {
            Add-Fail "The losing claimer did not receive the owner's lease record (sessionId='$($raceB.lease.sessionId)', expected 'issue-71-a')"
        }
        # ...and a claim that never reached compute is still self-healing once
        # its window elapses, or a crash would wedge the issue forever.
        $env:SQUAD_LEASE_NOW = "2024-05-01T06:30:00.000Z"
        $raceC = New-SquadDispatchLease -Decision $decB -Repository "octo/demo"
        if ($raceC.outcome -eq "repaired") {
            Add-Pass "An abandoned claim is adopted once its window elapses ('repaired'), so a crash between claim and compute still self-heals"
        } else {
            Add-Fail "An abandoned claim was not adoptable after its window ('$($raceC.outcome)'); a crashed dispatcher would wedge the issue permanently"
        }

        # --- 7. The ledger is BOUNDED: terminal leases are pruned ------------
        # Every run, smoke, telemetry smoke and Ralph issue mints a lease. With
        # no delete path the ledger only ever grows, the Contents API directory
        # listing silently caps at 1000 entries, and the sweeper's per-key read
        # eventually exhausts the REST budget -- at which point a 429 makes
        # claimLease throw and dispatch stops for EVERY issue.
        $env:SQUAD_LEASE_NOW = "2024-05-01T07:00:00.000Z"
        foreach ($n in 81..86) {
            $d = Get-SquadDispatchDecision -SessionId "prune-$n" -DispatchSource "ralph" -Repository "octo/demo" -IssueNumber "$n"
            New-SquadDispatchLease -Decision $d -Repository "octo/demo" | Out-Null
            Set-SquadDispatchLeaseState -Operation "complete" -Repository "octo/demo" -LeaseKey $d.leaseKey -State "succeeded" | Out-Null
        }
        $beforePrune = @(Get-SquadDispatchLease -Repository "octo/demo").Count
        $env:SQUAD_LEASE_NOW = "2024-05-01T08:00:00.000Z"
        $sweepInside = Invoke-SquadLeaseSweep -Repository "octo/demo"
        $insidePruned = @($sweepInside.pruned).Count
        $env:SQUAD_LEASE_NOW = "2024-06-01T00:00:00.000Z"
        $sweepAfter = Invoke-SquadLeaseSweep -Repository "octo/demo"
        $afterPrune = @(Get-SquadDispatchLease -Repository "octo/demo").Count
        if ($insidePruned -eq 0 -and @($sweepAfter.pruned).Count -ge 6 -and $afterPrune -lt $beforePrune) {
            Add-Pass "The lease ledger SHRINKS: terminal leases survive the retention window and are pruned past it ($beforePrune -> $afterPrune)"
        } else {
            Add-Fail "Ledger growth is unbounded (inside-window pruned=$insidePruned past-window pruned=$(@($sweepAfter.pruned).Count) before=$beforePrune after=$afterPrune); a ledger that only grows ends in a 429 that stops all dispatch"
        }

        # --- 8. Sweep cost does not scale with ledger size -------------------
        # A per-key read on a five-minute cron is 288 x N calls/day. Cap it, and
        # make the cap observable so a partial pass is never mistaken for a
        # complete one.
        $env:SQUAD_LEASE_NOW = "2024-06-01T00:00:00.000Z"
        foreach ($n in 91..98) {
            $d = Get-SquadDispatchDecision -SessionId "cost-$n" -DispatchSource "ralph" -Repository "octo/demo" -IssueNumber "$n"
            New-SquadDispatchLease -Decision $d -Repository "octo/demo" | Out-Null
        }
        $savedBudget = $env:SQUAD_LEASE_SWEEP_MAX_READS
        $env:SQUAD_LEASE_SWEEP_MAX_READS = "3"
        $bounded = Invoke-SquadLeaseSweep -Repository "octo/demo"
        $env:SQUAD_LEASE_SWEEP_MAX_READS = $savedBudget
        if ($bounded.examined -le 3 -and $bounded.total -ge 8 -and $bounded.budget -eq 3) {
            Add-Pass "One sweep reads at most SQUAD_LEASE_SWEEP_MAX_READS records (examined=$($bounded.examined) of total=$($bounded.total)), so per-run API cost is O(1) in ledger size"
        } else {
            Add-Fail "Sweep cost is unbounded (examined=$($bounded.examined) total=$($bounded.total) budget=$($bounded.budget)); 288 runs/day x N reads exhausts the 5000/hr REST budget and stops dispatch"
        }
        if ($null -ne $bounded.truncated) {
            Add-Pass "The sweep reports whether the ledger listing was truncated at the Contents API 1000-entry cap (never silently short)"
        } else {
            Add-Fail "The sweep no longer reports listing truncation; past 1000 entries the ledger would stop enumerating with no operator-visible cause"
        }
    } catch {
        Add-Fail "Dispatch contract checks threw: $($_.Exception.Message)"
    } finally {
        $env:SQUAD_GH_BIN = $savedGhBin
        $env:FAKE_GH_STATE = $savedState
        $env:SQUAD_LEASE_NOW = $savedNow
        $env:FAKE_GH_FAIL_MODE = $savedFail
        Remove-Item -Recurse -Force $leaseRoot -ErrorAction SilentlyContinue
    }

    # --- 9. Deny-list-first classification, asserted on the DECIDING rule ----
    # This defect class has now recurred three times (Sprint 3 B1, Sprint 5
    # `cancel`, Sprint 6 B1). Asserting only the boolean cannot catch it:
    # whenever a message matches just one list, both loop orders agree. So the
    # classifier reports WHICH list decided, and that is what is asserted here.
    # Swapping the two loops flips 'real-failure' to 'gone' and fails this check
    # even though every boolean would still look right.
    #
    # These four texts are the realistic shapes: GitHub masks a permission
    # denial on a private resource as a 404, so "403 ... (Not Found)" and
    # "Bad credentials (HTTP 401) - Not Found" are the MOST likely real inputs.
    $leaseModule = ((Join-Path $RepoRoot "worker\lib\dispatch-lease.js") -replace '\\', '/')
    if (-not $nodeAvailable) {
        Add-Fail "node is required to verify the gh failure classification but is not on PATH"
    } else {
        $probe = @"
const lease = require('$leaseModule');
const cases = [
  ['gh: HTTP 403: Resource not accessible by integration (Not Found)', false, 'real-failure'],
  ['gh: Bad credentials (HTTP 401) - Not Found', false, 'real-failure'],
  ['gh: HTTP 429: API rate limit exceeded; the resource does not exist', false, 'real-failure'],
  ['gh: HTTP 502: Bad gateway - Not Found', false, 'real-failure'],
  ['gh: HTTP 404: Not Found', true, 'gone'],
  ['gh: the mainframe declined politely', false, 'unrecognised']
];
const bad = [];
for (const [text, isGone, decidedBy] of cases) {
  const c = lease.classifyGhFailure({ ok: false, exitCode: 1, stderr: text, stdout: '' });
  if (c.isGone !== isGone || c.decidedBy !== decidedBy) {
    bad.push(text + ' => isGone=' + c.isGone + ' decidedBy=' + c.decidedBy);
  }
}
process.stdout.write(bad.length ? 'BAD: ' + bad.join(' | ') : 'OK');
"@
        $classifyOut = (& node -e $probe 2>&1) -join " "
        if ($LASTEXITCODE -eq 0 -and $classifyOut -eq "OK") {
            Add-Pass "gh failure classification is DENY-LIST FIRST and reports the deciding rule: a 403/401/429/5xx that also says 'Not Found' is a failure, an unrecognised failure is a failure, and only a clean 404 is 'gone'"
        } else {
            Add-Fail "gh failure classification changed: $classifyOut"
        }
    }
}

# The end-to-end ordering proof needs the CLI stub (a real `squad-aca` dispatch).
if ((Test-Path $harness) -and $IsWindowsHost -and $nodeAvailable) {
    . $harness
    $stub = $null
    try {
        $stub = New-SquadCliStubEnvironment
        Initialize-SquadCliStubRepository -Stub $stub | Out-Null

        # ORDERING BY INDEX: the lease blob must be written before the compute
        # request. Both events land in one ordered log, so this compares
        # positions -- not merely that both happened.
        Reset-SquadCliStubLog -Stub $stub
        Set-Content -LiteralPath $stub.CallLog -Value "" -NoNewline -Encoding ascii
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("smoke", "--repo", "octo/demo")
        $calls = @(Get-Content -LiteralPath $stub.CallLog -ErrorAction SilentlyContinue)
        $leaseIdx = [array]::FindIndex($calls, [Predicate[string]] { param($l) $l -like "gh lease-write*" })
        $startIdx = [array]::FindIndex($calls, [Predicate[string]] { param($l) $l -eq "az job-start" })
        if ($leaseIdx -ge 0 -and $startIdx -ge 0 -and $leaseIdx -lt $startIdx) {
            Add-Pass "squad-aca dispatch writes the lease at index $leaseIdx, BEFORE the compute request at index $startIdx"
        } else {
            Add-Fail "Claim-before-compute ordering broken (lease index=$leaseIdx, compute index=$startIdx, log=$($calls -join ' | '))"
        }

        # Route and dispatcher source must reach the execution env, or `sessions`
        # has nothing to show.
        $startCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job start*" })
        if ($startCall.Count -eq 1 -and $startCall[0] -like "*SQUAD_DISPATCH_ROUTE=aca-job*" -and $startCall[0] -like "*SQUAD_DISPATCH_SOURCE=local-cli*" -and $startCall[0] -like "*SQUAD_LEASE_KEY=*") {
            Add-Pass "Dispatch stamps SQUAD_DISPATCH_ROUTE, SQUAD_DISPATCH_SOURCE and SQUAD_LEASE_KEY into the execution"
        } else {
            Add-Fail "Dispatch no longer stamps the route/source/lease env: $($startCall -join ' | ')"
        }

        # sessions surfaces both, in full (no width-dependent truncation).
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("sessions")
        if ($r.StdOut -match "Route" -and $r.StdOut -match "Source" -and $r.StdOut -match "aca-job" -and $r.StdOut -match "local-cli") {
            Add-Pass "squad-aca sessions shows the resolved Route and the dispatcher Source"
        } else {
            Add-Fail "squad-aca sessions no longer surfaces Route/Source"
        }

        # A repeat dispatch of the SAME work must not start a second execution.
        Reset-SquadCliStubLog -Stub $stub
        $first = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("run", "--repo", "octo/demo", "--name", "dupe-session", "do the thing")
        $firstStarts = @($first.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        Reset-SquadCliStubLog -Stub $stub
        $second = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("run", "--repo", "octo/demo", "--name", "dupe-session", "do the thing")
        $secondStarts = @($second.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($firstStarts -eq 1 -and $secondStarts -eq 0) {
            Add-Pass "A repeated dispatch of the same session does not start a second execution (idempotent)"
        } else {
            Add-Fail "Duplicate dispatch started $secondStarts execution(s) on the second run (first run started $firstStarts)"
        }
    } catch {
        Add-Fail "Dispatch ordering checks threw: $($_.Exception.Message)"
    } finally {
        if ($stub) { Remove-SquadCliStubEnvironment -Stub $stub }
    }
}

# --- Operational invariants around the lease that only source can prove -----
# These three are cheap to state and expensive to lose. Each is a defect the
# reviewer found by reading, and each would otherwise be re-introducible with a
# one-line edit and no failing test.
$entrypointSh = Join-Path $RepoRoot "worker\entrypoint.sh"
if (Test-Path $entrypointSh) {
    $entryText = Get-Content -LiteralPath $entrypointSh -Raw
    # A heartbeat that fires ONCE is not a heartbeat. With a one-hour TTL, a
    # session running longer than that is swept as stale mid-flight and its
    # lease becomes re-claimable while the execution is still live.
    if ($entryText -match "squad_lease_heartbeat_loop" -and $entryText -match "SQUAD_LEASE_HEARTBEAT_SECONDS" -and $entryText -match "while\s+(true|:)") {
        Add-Pass "The worker heartbeat is PERIODIC (a background ticker), so a session outliving the lease TTL is not swept as stale mid-flight"
    } else {
        Add-Fail "worker/entrypoint.sh no longer runs a periodic heartbeat; a single beat plus a terminal write lets a long-running session's lease be reclaimed while it is still executing"
    }
}
$cliSource = Join-Path $RepoRoot "scripts\squad-aca.ps1"
if (Test-Path $cliSource) {
    $cliText = Get-Content -LiteralPath $cliSource -Raw
    # `Format-Table -AutoSize` sizes to the terminal, so the rightmost columns
    # vanish on a narrow window. The leases table has seven columns and the
    # runbook tells operators to read the last two.
    $bareAutoSize = @(
        Select-String -LiteralPath $cliSource -Pattern 'Format-Table\s+-AutoSize\s*$' -AllMatches
    )
    if ($bareAutoSize.Count -eq 0) {
        Add-Pass "No table in squad-aca.ps1 ends at 'Format-Table -AutoSize'; every one is piped through Out-String -Width so columns cannot silently vanish on a narrow terminal"
    } else {
        Add-Fail "squad-aca.ps1 has $($bareAutoSize.Count) bare 'Format-Table -AutoSize' table(s) at line(s) $(($bareAutoSize.LineNumber) -join ', '); trailing columns disappear on a narrow terminal"
    }
    # The `dispatched` write must not be able to throw AFTER compute has been
    # requested: a transient 429 would leave the lease `claimed`, and the user's
    # retry would then be told `repaired` and start a SECOND execution. Assert
    # the STRUCTURE rather than a marker comment: each write must sit inside its
    # own try, and that try must not release the lease (releasing would hand
    # live work to another dispatcher).
    $cliLines = @(Get-Content -LiteralPath $cliSource)
    $markLines = @(
        Select-String -LiteralPath $cliSource -Pattern 'Operation\s+"dispatched"' -AllMatches |
            ForEach-Object { $_.LineNumber }
    )
    $unguarded = @()
    foreach ($ln in $markLines) {
        $before = $cliLines[[Math]::Max(0, $ln - 3)..($ln - 2)] -join "`n"
        $after = $cliLines[$ln..[Math]::Min($cliLines.Count - 1, $ln + 3)] -join "`n"
        if ($before -notmatch 'try\s*\{' -or $after -notmatch '\}\s*catch' -or $after -match 'Operation\s+"release"') {
            $unguarded += $ln
        }
    }
    if ($markLines.Count -ge 2 -and $unguarded.Count -eq 0) {
        Add-Pass "All $($markLines.Count) 'dispatched' lease writes in squad-aca.ps1 sit inside a try that warns rather than throwing or releasing, so a fault after compute started cannot strand the lease as 'claimed'"
    } else {
        Add-Fail "Unguarded 'dispatched' lease write(s) in squad-aca.ps1 at line(s) $($unguarded -join ', ') (found $($markLines.Count) write(s)); a 429 there throws to the user after compute started, and the retry is told 'repaired' and starts a second execution"
    }
}

# ---------------------------------------------------------------------------
# 10. CLI golden gate is present AND automated
# ---------------------------------------------------------------------------
# scripts/tests/verify-cli-golden.ps1 is the only guard that compares the whole
# observable surface of `squad-aca` -- including stdout -- against a committed
# baseline. That is the exact regression class PR #9 was closed for. It is only
# a guard if CI runs it, so assert both halves: the goldens exist and cover
# every case, and the workflow actually invokes the script.
Write-Section "CLI golden gate"
$goldenScript = Join-Path $RepoRoot "scripts\tests\verify-cli-golden.ps1"
$caseFile = Join-Path $RepoRoot "scripts\tests\cli-capture-cases.ps1"
$goldenDir = Join-Path $RepoRoot "scripts\tests\golden\cli"
$workflowFile = Join-Path $RepoRoot ".github\workflows\worker-tests.yml"

if (-not (Test-Path $goldenScript)) {
    Add-Fail "scripts/tests/verify-cli-golden.ps1 is missing (no automated stdout regression gate)"
} elseif (-not (Test-Path $caseFile)) {
    Add-Fail "scripts/tests/cli-capture-cases.ps1 is missing (shared CLI capture matrix)"
} else {
    . $caseFile
    $goldenFiles = @()
    if (Test-Path $goldenDir) { $goldenFiles = @(Get-ChildItem -Path $goldenDir -Filter *.txt -File) }
    $caseIds = @($Cases | ForEach-Object { $_.Id })
    $missingGolden = @($caseIds | Where-Object { $goldenFiles.Name -notcontains "$_.txt" })
    if ($caseIds.Count -gt 0 -and $missingGolden.Count -eq 0 -and $goldenFiles.Count -eq $caseIds.Count) {
        Add-Pass "Every one of the $($caseIds.Count) CLI capture cases has a committed golden under scripts/tests/golden/cli"
    } else {
        Add-Fail "CLI goldens are out of sync with the capture matrix (cases=$($caseIds.Count), goldens=$($goldenFiles.Count), missing=$($missingGolden -join ', ')); regenerate with verify-cli-golden.ps1 -Update"
    }

    # A golden that records no stdout could never catch the PR #9 regression.
    $stopGolden = Join-Path $goldenDir "07-stop-byexec.txt"
    if ((Test-Path $stopGolden) -and ((Get-Content -LiteralPath $stopGolden -Raw) -match "### STDOUT\s*\r?\nSTUB-STOP-ACK")) {
        Add-Pass "The 'stop' golden records az stdout, so losing that output is a diff (PR #9 regression class)"
    } else {
        Add-Fail "The 'stop' golden does not record 'az containerapp job stop' stdout; the PR #9 regression class would pass unnoticed"
    }

    if (-not (Test-Path $workflowFile)) {
        Add-Fail ".github/workflows/worker-tests.yml is missing; the CLI golden gate has no automated runner"
    } else {
        $workflowText = Get-Content -LiteralPath $workflowFile -Raw
        if ($workflowText -match 'verify-cli-golden\.ps1') {
            Add-Pass "CI runs scripts/tests/verify-cli-golden.ps1, so a squad-aca stdout change fails a job (not just a manual tool)"
        } else {
            Add-Fail "No CI job runs scripts/tests/verify-cli-golden.ps1; the stdout regression guard would be developer-only again"
        }

        # Same principle for the one invariant that needs a real Linux shell.
        # The windows-latest job can only ever SKIP it (no WSL on GitHub's
        # Windows runners, and Git Bash has no setsid), so it has to run in the
        # ubuntu-latest job -- and that job must treat exit 77 as a failure,
        # because a skip is not a pass.
        if ($workflowText -match 'verify-launch-detachment\.ps1') {
            Add-Pass "CI runs scripts/tests/verify-launch-detachment.ps1, so a launch that stops detaching fails a job on a real Linux shell"
        } else {
            Add-Fail "No CI job runs scripts/tests/verify-launch-detachment.ps1; worker-launch detachment would be verified only on a developer's WSL box"
        }
        if ($workflowText -match '(?s)verify-launch-detachment\.ps1.{0,400}\brc\b.{0,200}\b77\b') {
            Add-Pass "The CI detachment step treats exit 77 (probe did not run) as a failure, not as a pass"
        } else {
            Add-Fail "The CI detachment step does not fail on exit 77; a runner that lost bash would report green while proving nothing"
        }
    }

    # The goldens are only a gate if they verify on a machine other than the one
    # that produced them. The first CI run of this gate failed because they did
    # not: timestamps rendered in the host time zone and `doctor` reported the
    # optional `squad` CLI as installed only because the capture machine had it.
    # Those are pinned in the harness now; assert the pins are still there, so
    # removing one is a failing check rather than a red CI run days later.
    if (-not (Test-Path $harness)) {
        Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing; the golden captures have no environment pins"
    } else {
        $harnessText = Get-Content -LiteralPath $harness -Raw

        if ($harnessText -notmatch '"startTime"\s*:\s*"[^"]*(?:Z|[+\-]\d{2}:\d{2})"') {
            Add-Pass "Stub execution fixtures use offset-free timestamps, so 'sessions' renders the same wall clock in every host time zone"
        } else {
            Add-Fail "A stub execution fixture carries a UTC offset in startTime; ConvertFrom-Json will render it in the host time zone and the sessions goldens stop being portable"
        }

        if ($harnessText -match 'DOTNET_SYSTEM_GLOBALIZATION_INVARIANT') {
            Add-Pass "CLI captures run under the invariant culture, so dates and numbers do not render in the capture machine's locale"
        } else {
            Add-Fail "The CLI capture child process no longer pins DOTNET_SYSTEM_GLOBALIZATION_INVARIANT; goldens would encode the capture machine's locale"
        }

        if ($harnessText -match 'squad\.cmd') {
            Add-Pass "The optional 'squad' CLI is stubbed onto PATH, so 'doctor' reports the same status on a machine that has it and one that does not"
        } else {
            Add-Fail "'squad' is no longer stubbed onto PATH; 'doctor' reports ok/optional depending on the host and re-pads every row of its table"
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Section "Summary"
Write-Host ("  Passed: {0}" -f $script:Passes.Count) -ForegroundColor Green
Write-Host ("  Failed: {0}" -f $script:Failures.Count) -ForegroundColor ($(if ($script:Failures.Count -gt 0) { 'Red' } else { 'Green' }))
Write-Host ("  Skipped: {0}" -f $script:Skips.Count) -ForegroundColor ($(if ($script:Skips.Count -gt 0) { 'Yellow' } else { 'Green' }))
if ($script:Skips.Count -gt 0) {
    Write-Host "`nSkipped (NOT passes -- the dependency was missing):" -ForegroundColor Yellow
    $script:Skips | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($script:Failures.Count -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nAll validation checks passed." -ForegroundColor Green
exit 0
