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

    Candidate enumeration MUST be NUL-delimited (`-z`). Plain
    `git status --porcelain` returns human-readable paths: a newly added
    directory collapses to a single entry (so nested secrets could evade the
    scan) AND non-ASCII / special-character paths are C-quoted and octal-escaped
    (for example `"caf\303\251/secret.txt"`). A quoted, escaped path fails
    Test-Path, so its content is never scanned even though `git add -A` still
    stages the real file -- a secret-guard bypass. Using `-z` output avoids all
    quote decoding: git emits the raw path bytes terminated by NUL. We read those
    bytes as UTF-8 so PowerShell gets a real filesystem path it can Test-Path and
    Get-Content.

    Coverage of everything `git add -A` would stage is assembled from three
    NUL-delimited sources instead of a single porcelain call, which also sidesteps
    the ambiguous `old\0new` rename record shape:
      * `git diff --name-only -z`            -> unstaged tracked modifications
      * `git diff --cached --name-only -z`   -> already-staged changes
      * `git ls-files --others --exclude-standard -z` -> untracked, non-ignored
    `--exclude-standard` honors .gitignore so ignored files stay excluded, and
    ls-files --others lists every nested untracked file individually (replacing
    the old `-uall`). Renames are handled naturally: the new path is scanned and
    the deleted old path is skipped by the Test-Path/Get-Content content check.
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
    # Every source below is NUL-delimited (`-z`) so paths with spaces, brackets,
    # or non-ASCII characters arrive as real, un-escaped filesystem paths that
    # PowerShell can Test-Path/Get-Content. git emits path bytes as UTF-8; the
    # console decoder is temporarily switched to UTF-8 so those bytes round-trip.
    $candidates = @()
    $gitArgLists = @(
        @('diff', '--name-only', '-z'),                        # unstaged tracked modifications
        @('diff', '--cached', '--name-only', '-z'),            # already-staged changes
        @('ls-files', '--others', '--exclude-standard', '-z')  # untracked, non-ignored
    )
    $prevOutputEncoding = $null
    $encodingSwitched = $false
    try {
        try {
            $prevOutputEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
            $encodingSwitched = $true
        } catch {
            # No console handle (e.g. fully redirected host); fall back to the
            # existing decoder. ASCII paths are unaffected either way.
        }
        foreach ($argList in $gitArgLists) {
            $out = & git @argList 2>$null
            foreach ($chunk in @($out)) {
                if ($null -eq $chunk) { continue }
                foreach ($p in ($chunk -split "`0")) {
                    if ($p) { $candidates += $p }
                }
            }
        }
    } finally {
        if ($encodingSwitched) {
            try { [Console]::OutputEncoding = $prevOutputEncoding } catch { }
        }
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
