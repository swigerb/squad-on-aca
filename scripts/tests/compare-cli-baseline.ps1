#requires -Version 5.1
<#
.SYNOPSIS
    Proves `squad-aca` produces byte-identical observable behaviour to another
    git revision.

.DESCRIPTION
    The execution provider seam (docs/architecture.md, "Execution provider
    boundary") is only safe if it is observably invisible. `validate.ps1`
    section 8 asserts specific properties; this script proves the stronger
    claim by *differential capture*: it materialises another revision's whole
    tree, drives both revisions through the same stubbed `az`/`gh`
    environment, and compares the recorded exit code, stdout, stderr, and every
    `az`/`gh` argv byte for byte.

    SELF-CHECK: `-BaselineRef HEAD` compares the working tree against itself and
    MUST report 22/22. If it does not, this tool is broken, not the CLI.

    The capture matrix and capture format live in
    scripts/tests/cli-capture-cases.ps1, shared with
    scripts/tests/verify-cli-golden.ps1 (the committed-golden gate CI runs).

    Nothing here touches Azure or GitHub. `scripts/tests/cli-stub-harness.ps1`
    puts fake `az.cmd`/`gh.cmd`/`squad.cmd` on PATH, points HOME at a throwaway
    directory with a synthetic config, and gives the `run`/`sync` cases a real
    git repo whose "origin" is a local bare repo.

    KNOWN, UNAVOIDABLE DEVIATION
    PowerShell annotates an uncaught error with the *source line number* of the
    `throw`. Adding lines to squad-aca.ps1 shifts those numbers, so cases that
    end in a thrown error can never be byte-identical across revisions. The
    comparison therefore reports two numbers: a raw byte-for-byte count, and a
    count after normalising that annotation (and the ANSI colour sequences
    PowerShell 7 wraps error records in). The exception message text, the exit
    code, and the az/gh call sequence are compared unnormalised in both.

.PARAMETER BaselineRef
    Git ref to compare against. Defaults to `main`.

.PARAMETER WorkDir
    Scratch directory for the materialised baseline and both capture sets.
    Defaults to a temp directory, removed on exit unless -Keep is passed.

.PARAMETER Keep
    Keep the scratch directory so the captures can be inspected by hand.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\tests\compare-cli-baseline.ps1
    pwsh -NoProfile -File .\scripts\tests\compare-cli-baseline.ps1 -BaselineRef origin/main -Keep
#>
[CmdletBinding()]
param(
    [string]$BaselineRef = "main",
    [string]$WorkDir = "",
    [switch]$Keep
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

. (Join-Path $ScriptDir "cli-stub-harness.ps1")
. (Join-Path $ScriptDir "cli-capture-cases.ps1")

if (-not $WorkDir) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("squad-cli-baseline-" + [guid]::NewGuid().ToString("N"))
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

try {
    # Materialise the baseline revision's WHOLE tree without disturbing the
    # worktree. Not just `scripts`: squad-aca.ps1 resolves siblings of that
    # directory -- scripts/lib/dispatch-contract.ps1 shells out to
    # worker/lib/squad-dispatch.js, resolved as <repoRoot>/worker/lib -- so a
    # scripts-only archive gives the baseline a tree where those siblings do not
    # exist. Every case that dispatches then dies with `Cannot find module` and
    # is reported as "OBSERVABLE BEHAVIOUR CHANGED", which is the tool accusing
    # the working tree of a change the baseline could not make.
    #
    # That is not hypothetical: it shipped. Sprint 6 added the worker/lib
    # dependency without widening this scope, and the tool then reported 16/22
    # for two IDENTICAL trees (-BaselineRef HEAD). A tool that cannot report
    # "unchanged" for identical trees proves nothing about a real change.
    #
    # Archiving the entire ref -- rather than adding `worker` to the pathspec --
    # is the fix that cannot recur: the next cross-directory dependency needs no
    # edit here. 296 tracked files; the cost is milliseconds.
    $baselineRoot = Join-Path $WorkDir "baseline"
    New-Item -ItemType Directory -Force -Path $baselineRoot | Out-Null
    Push-Location $RepoRoot
    try {
        $archive = Join-Path $WorkDir "baseline-tree.tar"
        git archive --format=tar --output=$archive $BaselineRef
        if ($LASTEXITCODE -ne 0) { throw "git archive $BaselineRef failed" }
    } finally {
        Pop-Location
    }
    tar -xf (Join-Path $WorkDir "baseline-tree.tar") -C $baselineRoot
    if ($LASTEXITCODE -ne 0) { throw "extracting the baseline archive failed" }
    # Fail loudly rather than silently comparing against a tree that cannot run
    # the thing under test.
    foreach ($required in @("scripts\squad-aca.ps1", "worker\lib\squad-dispatch.js")) {
        if (-not (Test-Path (Join-Path $baselineRoot $required))) {
            throw "the materialised baseline ($BaselineRef) has no $required -- the archive scope is wrong, and every capture that needs it would be reported as a behaviour change."
        }
    }

    Write-Host "Capturing baseline ($BaselineRef)..." -ForegroundColor Cyan
    Invoke-CaptureSet -ScriptsRoot (Join-Path $baselineRoot "scripts") -OutDir (Join-Path $WorkDir "out-baseline")

    Write-Host "Capturing working tree..." -ForegroundColor Cyan
    Invoke-CaptureSet -ScriptsRoot (Join-Path $RepoRoot "scripts") -OutDir (Join-Path $WorkDir "out-current")

    $rawDiff = @()
    $normDiff = @()
    foreach ($file in (Get-ChildItem (Join-Path $WorkDir "out-baseline") -File | Sort-Object Name)) {
        $a = [System.IO.File]::ReadAllText($file.FullName)
        $b = [System.IO.File]::ReadAllText((Join-Path $WorkDir "out-current\$($file.Name)"))
        if ($a -cne $b) { $rawDiff += $file.Name }
        if ((Get-CaptureWithoutErrorLineNumbers $a) -cne (Get-CaptureWithoutErrorLineNumbers $b)) {
            $normDiff += $file.Name
        }
    }

    $total = $Cases.Count
    Write-Host ""
    Write-Host ("Byte-identical:                       {0}/{1}" -f ($total - $rawDiff.Count), $total)
    if ($rawDiff.Count -gt 0) {
        Write-Host ("  differing (raw): {0}" -f ($rawDiff -join ', ')) -ForegroundColor Yellow
    }
    Write-Host ("Identical ignoring error line numbers: {0}/{1}" -f ($total - $normDiff.Count), $total)

    if ($normDiff.Count -gt 0) {
        Write-Host ""
        Write-Host "OBSERVABLE BEHAVIOUR CHANGED in: $($normDiff -join ', ')" -ForegroundColor Red
        foreach ($name in $normDiff) {
            Write-Host "`n--- $name ---" -ForegroundColor Red
            $a = (Get-CaptureWithoutErrorLineNumbers ([System.IO.File]::ReadAllText((Join-Path $WorkDir "out-baseline\$name")))) -split "`n"
            $b = (Get-CaptureWithoutErrorLineNumbers ([System.IO.File]::ReadAllText((Join-Path $WorkDir "out-current\$name")))) -split "`n"
            Compare-Object $a $b | Format-Table -AutoSize | Out-String | Write-Host
        }
        exit 1
    }

    Write-Host "`nsquad-aca observable behaviour matches $BaselineRef." -ForegroundColor Green
    exit 0
} finally {
    if ($Keep) {
        Write-Host "Captures kept in $WorkDir"
    } else {
        Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
    }
}
