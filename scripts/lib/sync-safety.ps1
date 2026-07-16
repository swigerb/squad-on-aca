<#
.SYNOPSIS
    Public-repo sync guard for `squad-aca sync --sync-all`.

.DESCRIPTION
    `--sync-all` runs `git add -A` and can push the entire working tree to a
    potentially public GitHub repository. Test-SyncSafety inspects every file
    that `git add -A` would stage -- modified, staged, AND untracked -- and
    blocks the sync when a file looks like a credential file or contains an
    inline secret/token.

    This helper is dot-sourced by scripts/squad-aca.ps1 and by
    scripts/validate.ps1's regression check. Dot-sourcing it has no side effects
    beyond defining Test-SyncSafety, which keeps the guard independently testable.

    Untracked enumeration MUST use `git status --porcelain -uall`. Plain
    `git status --porcelain` collapses a newly added directory to a single entry
    (for example `secrets/`), so nested secret files inside a brand-new directory
    would never be scanned even though `git add -A` would still stage them. The
    `-uall` flag forces git to list every individual untracked file so nested
    secrets cannot evade the scan.
#>

function Test-SyncSafety {
    # Returns the list of blocking reasons; an empty list means the working tree
    # is safe to sync.

    if ($env:SQUAD_ACA_ALLOW_UNSAFE_SYNC -eq '1') {
        Write-Warning "SQUAD_ACA_ALLOW_UNSAFE_SYNC=1 set; skipping public repo secret guard."
        return @()
    }

    # Candidate paths: modified/untracked working-tree files plus anything
    # already staged. --sync-all runs `git add -A`, so all of these could ship.
    # `-uall` lists every individual untracked file (not just the top-level
    # directory) so nested secrets inside a new directory are still scanned.
    $candidates = @()
    $porcelain = git status --porcelain -uall 2>$null
    foreach ($line in $porcelain) {
        if (-not $line) { continue }
        $path = $line.Substring(3).Trim().Trim('"')
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1].Trim().Trim('"') }
        if ($path) { $candidates += $path }
    }
    $candidates = $candidates | Sort-Object -Unique

    # Denylisted path patterns (leaf name or path segment based).
    $deniedPatterns = @(
        '(^|/)\.env($|\.)',
        '(^|/)deploy\.outputs\.json$',
        '(^|/)\.azure/',
        '(^|/)\.azure$',
        '\.pfx$',
        '\.pem$',
        '\.p12$',
        '(^|/)id_rsa($|\.)',
        '(^|/)id_ed25519($|\.)',
        '(^|/)id_dsa($|\.)',
        '(^|/)id_ecdsa($|\.)',
        '(^|/)appsettings[^/]*\.Development\.json$',
        '(^|/)\.npmrc$',
        '(^|/)\.pypirc$',
        '(^|/)secrets?\.(json|yaml|yml|txt)$'
    )

    # Inline token patterns scanned inside newly added/modified text content.
    $tokenPatterns = @(
        'gh[pousr]_[A-Za-z0-9]{30,}',                                   # GitHub PAT / OAuth / refresh
        'github_pat_[A-Za-z0-9_]{40,}',                                 # fine-grained PAT
        'AKIA[0-9A-Z]{16}',                                             # AWS access key id
        '-----BEGIN [A-Z ]*PRIVATE KEY-----',                          # private key blocks
        'xox[baprs]-[A-Za-z0-9-]{10,}',                                # Slack tokens
        'AccountKey=[A-Za-z0-9+/=]{40,}',                              # Azure storage key
        'sk-[A-Za-z0-9]{32,}'                                           # OpenAI-style secret key
    )

    $reasons = @()

    foreach ($path in $candidates) {
        $normalized = $path -replace '\\', '/'
        foreach ($pattern in $deniedPatterns) {
            if ($normalized -match $pattern) {
                $reasons += "Blocked file: $path (matches denylist /$pattern/)"
                break
            }
        }
    }

    # Scan text content for inline secrets. Skip binary and denylisted files
    # (already reported) and anything git ignores.
    foreach ($path in $candidates) {
        $normalized = $path -replace '\\', '/'
        $alreadyBlocked = $false
        foreach ($pattern in $deniedPatterns) {
            if ($normalized -match $pattern) { $alreadyBlocked = $true; break }
        }
        if ($alreadyBlocked) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $info = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if (-not $info -or $info.Length -gt 1MB) { continue }
        $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content.IndexOf([char]0) -ge 0) { continue }
        foreach ($pattern in $tokenPatterns) {
            if ($content -match $pattern) {
                $reasons += "Possible secret in: $path (matches token pattern /$pattern/)"
                break
            }
        }
    }

    return @($reasons | Sort-Object -Unique)
}
