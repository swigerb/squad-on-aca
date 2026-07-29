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

# $IsWindows only exists in PowerShell 6+; this file also has to run under 5.1.
$IsWindowsHost = if ($null -ne $PSVersionTable.Platform) { $PSVersionTable.Platform -eq "Win32NT" } else { $true }

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
if ($script:Failures.Count -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nAll validation checks passed." -ForegroundColor Green
exit 0
