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

    Three additional bypasses are closed here:

      * Root-relative coverage. `git add -A` stages the ENTIRE working tree, but
        `git diff`/`git ls-files` scope their output to the current working
        directory when run from a subdirectory -- so running the guard from a
        nested folder would miss root-level or sibling files that `add -A` still
        stages. We discover the repository root with `git rev-parse
        --show-toplevel` and run every enumeration with the git process rooted
        there (ProcessStartInfo.WorkingDirectory), so candidates are always the
        full, repo-root-relative set regardless of the caller's directory.
        Content checks resolve each candidate to a full path under the root;
        user-facing reasons stay repo-relative.

      * Byte-safe NUL parsing. The PowerShell pipeline splits native command
        output on newlines BEFORE we ever see it, so a Linux/macOS filename that
        legitimately contains a newline byte would be torn into fragments and its
        content never scanned. We bypass the pipeline entirely: git is launched
        via System.Diagnostics.Process with a redirected StandardOutput, its raw
        bytes are read from the BaseStream, decoded as UTF-8, and split on NUL
        (see ConvertFrom-NulDelimitedByte / Invoke-GitNulEntry). Newlines inside
        a path survive intact because only the NUL byte is a separator.

      * Case-sensitive dedupe. Candidates are de-duplicated with an ordinal
        (case-sensitive) HashSet, not PowerShell's default case-insensitive
        `Sort-Object -Unique`. On case-sensitive filesystems `Secret.txt` and
        `secret.txt` are distinct files; collapsing them would leave one
        unscanned.
#>

function ConvertFrom-NulDelimitedByte {
    # Decode raw git `-z` output (UTF-8 path bytes terminated by NUL) into a
    # list of paths. Splitting is done ONLY on the NUL byte, so paths that
    # contain newlines -- legal on Linux/macOS -- are preserved intact. This is
    # the byte-safe replacement for letting the PowerShell pipeline line-split
    # native command output. Extracted as a named helper so it can be unit
    # tested with synthetic byte input.
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return @() }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = $utf8.GetString($Bytes)
    $result = @()
    foreach ($part in ($text -split "`0")) {
        if ($part -ne '') { $result += $part }
    }
    return $result
}

function Invoke-GitNulEntry {
    # Run git with the given arguments rooted at $WorkingDirectory and return the
    # NUL-delimited entries. Output bytes are read straight from the process
    # StandardOutput BaseStream so the PowerShell pipeline never gets a chance to
    # line-split them; only ConvertFrom-NulDelimitedByte does the splitting, and
    # only on NUL. StandardError is drained asynchronously to avoid a pipe-buffer
    # deadlock. WorkingDirectory is set on the process (not passed as a `-C`
    # argument) so a repo root containing spaces needs no shell quoting.
    param(
        [string]$WorkingDirectory,
        [string[]]$GitArgs
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    # Every argument here is a fixed flag with no spaces, so a plain join is safe.
    $psi.Arguments = ($GitArgs -join ' ')
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardOutput.BaseStream.CopyTo($ms)
        [void]$errTask.Wait()
        $proc.WaitForExit()
    } finally {
        $proc.Dispose()
    }
    return ConvertFrom-NulDelimitedByte -Bytes $ms.ToArray()
}

function Get-GitTopLevel {
    # Resolve the repository root (`git rev-parse --show-toplevel`) so enumeration
    # covers the whole working tree no matter which subdirectory the guard is
    # invoked from. Bytes are decoded UTF-8 for non-ASCII root paths. Returns
    # $null when not inside a git work tree.
    param([string]$StartDir)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = 'rev-parse --show-toplevel'
    $psi.WorkingDirectory = $StartDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardOutput.BaseStream.CopyTo($ms)
        [void]$errTask.Wait()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { return $null }
    } finally {
        $proc.Dispose()
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $text = $utf8.GetString($ms.ToArray()) -replace "(\r?\n)+$", ""
    if ($text) { return $text }
    return $null
}

function Test-SyncSafety {
    # Returns the list of blocking reasons; an empty list means the working tree
    # is safe to sync.

    if ($env:SQUAD_ACA_ALLOW_UNSAFE_SYNC -eq '1') {
        Write-Warning "SQUAD_ACA_ALLOW_UNSAFE_SYNC=1 set; skipping public repo secret guard."
        return @()
    }

    # Candidate paths: modified/untracked working-tree files plus anything
    # already staged. --sync-all runs `git add -A`, so all of these could ship.
    # Enumeration is rooted at the repository top level (discovered via
    # `git rev-parse --show-toplevel`) so it covers the entire working tree even
    # when the guard is invoked from a nested subdirectory -- otherwise git would
    # scope diff/ls-files output to the current directory and miss root-level or
    # sibling files that `git add -A` still stages. Every source below is
    # NUL-delimited (`-z`) and read byte-for-byte from the git process, so paths
    # with spaces, brackets, newlines, or non-ASCII characters arrive as real,
    # un-escaped filesystem paths.
    $startDir = (Get-Location).ProviderPath
    $root = Get-GitTopLevel -StartDir $startDir
    if (-not $root) {
        # Not inside a git work tree; degrade to the current directory so the
        # process still runs (git will simply return nothing useful).
        $root = $startDir
    }

    $gitArgLists = @(
        @('diff', '--name-only', '-z'),                        # unstaged tracked modifications
        @('diff', '--cached', '--name-only', '-z'),            # already-staged changes
        @('ls-files', '--others', '--exclude-standard', '-z')  # untracked, non-ignored
    )

    # De-duplicate with ORDINAL (case-sensitive) semantics. On case-sensitive
    # filesystems `Secret.txt` and `secret.txt` are distinct files; PowerShell's
    # default `Sort-Object -Unique` is case-insensitive and would collapse them,
    # leaving one path unscanned.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($argList in $gitArgLists) {
        foreach ($rel in (Invoke-GitNulEntry -WorkingDirectory $root -GitArgs $argList)) {
            if ($rel -and $seen.Add($rel)) { $candidates.Add($rel) }
        }
    }

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

    # $rel is the repo-root-relative path git reported; keep it for user-facing
    # reasons. $full resolves it against the discovered repository root so content
    # checks work no matter which subdirectory the guard was invoked from.
    foreach ($rel in $candidates) {
        $normalized = $rel -replace '\\', '/'
        foreach ($pattern in $deniedPatterns) {
            if ($normalized -match $pattern) {
                $reasons += "Blocked file: $rel (matches denylist /$pattern/)"
                break
            }
        }
    }

    # Scan text content for inline secrets. Skip binary and denylisted files
    # (already reported) and anything git ignores.
    foreach ($rel in $candidates) {
        $normalized = $rel -replace '\\', '/'
        $alreadyBlocked = $false
        foreach ($pattern in $deniedPatterns) {
            if ($normalized -match $pattern) { $alreadyBlocked = $true; break }
        }
        if ($alreadyBlocked) { continue }
        $full = [System.IO.Path]::Combine($root, ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $info = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        if (-not $info -or $info.Length -gt 1MB) { continue }
        $content = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content.IndexOf([char]0) -ge 0) { continue }
        foreach ($pattern in $tokenPatterns) {
            if ($content -match $pattern) {
                $reasons += "Possible secret in: $rel (matches token pattern /$pattern/)"
                break
            }
        }
    }

    return @($reasons | Sort-Object -Unique)
}
