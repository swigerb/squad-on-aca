#requires -Version 5.1
<#
.SYNOPSIS
    Proves `squad-aca` produces byte-identical observable behaviour to another
    git revision.

.DESCRIPTION
    The execution provider seam (docs/architecture.md, "Execution provider
    boundary") is only safe if it is observably invisible. `validate.ps1`
    section 8 asserts specific properties; this script proves the stronger
    claim by *differential capture*: it materialises another revision's
    `scripts/` tree, drives both revisions through the same stubbed `az`/`gh`
    environment, and compares the recorded exit code, stdout, stderr, and every
    `az`/`gh` argv byte for byte.

    Nothing here touches Azure or GitHub. `scripts/tests/cli-stub-harness.ps1`
    puts fake `az.cmd`/`gh.cmd` on PATH, points HOME at a throwaway directory
    with a synthetic config, and gives the `run`/`sync` cases a real git repo
    whose "origin" is a local bare repo.

    KNOWN, UNAVOIDABLE DEVIATION
    PowerShell annotates an uncaught error with the *source line number* of the
    `throw`. Adding lines to squad-aca.ps1 shifts those numbers, so cases that
    end in a thrown error can never be byte-identical across revisions. The
    comparison therefore reports two numbers: a raw byte-for-byte count, and a
    count after normalising only that annotation. The exception message text,
    the exit code, and the az/gh call sequence are compared unnormalised in
    both.

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

# Every case is a full squad-aca invocation. NeedsRepo cases mutate git state,
# so they each get a pristine stub environment.
$Cases = @(
    @{ Id = "01-help";            Args = @("help") }
    @{ Id = "02-sessions";        Args = @("sessions") }
    @{ Id = "03-sessions-limit";  Args = @("sessions", "--limit", "3") }
    @{ Id = "04-logs-latest";     Args = @("logs") }
    @{ Id = "05-logs-byname";     Args = @("logs", "stub-session", "--tail", "5") }
    @{ Id = "06-logs-byexec";     Args = @("logs", "caj-squad-aca-session-stub02") }
    @{ Id = "07-stop-byexec";     Args = @("stop", "caj-squad-aca-session-stub01") }
    @{ Id = "08-stop-latest";     Args = @("stop") }
    @{ Id = "09-stop-missing";    Args = @("stop", "no-such-session") }
    @{ Id = "10-stop-azfail";     Args = @("stop", "caj-squad-aca-session-stub01"); StopRc = 3 }
    @{ Id = "11-doctor";          Args = @("doctor") }
    @{ Id = "12-smoke";           Args = @("smoke", "--repo", "octo/demo") }
    @{ Id = "13-smoke-azfail";    Args = @("smoke", "--repo", "octo/demo"); StartRc = 5 }
    @{ Id = "14-telemetry";       Args = @("telemetry", "smoke", "--repo", "octo/demo") }
    @{ Id = "15-status";          Args = @("status") }
    @{ Id = "16-sessions-limit1"; Args = @("sessions", "--limit", "1") }
    @{ Id = "17-badcmdusage";     Args = @("secrets") }
    @{ Id = "18-run";             Args = @("run", "Build the thing and open a PR", "--name", "fixedsession"); NeedsRepo = $true }
    @{ Id = "19-run-nopush";      Args = @("run", "Do the thing", "--name", "fixedtwo", "--no-push", "--sub-squad", "alpha"); NeedsRepo = $true }
    @{ Id = "20-run-noprompt";    Args = @("run", "--name", "fixedthree"); NeedsRepo = $true }
    @{ Id = "21-run-implicit";    Args = @("Implicit prompt form", "--name", "fixedfour"); NeedsRepo = $true }
    @{ Id = "22-sync-dryrun";     Args = @("sync", "--dry-run"); NeedsRepo = $true }
)

function Get-NormalizedCapture {
    <#
    .SYNOPSIS
        Removes values that legitimately differ between two runs of the SAME
        revision (timestamps, the scripts root, the stub directory GUID).
    #>
    param([AllowNull()][string]$Text, [string]$ScriptsRoot)
    if ($null -eq $Text) { return "" }
    $t = [regex]::Replace($Text, '\d{8}-\d{6}', '<TS>')
    $t = [regex]::Replace($t, [regex]::Escape($ScriptsRoot), '<SCRIPTS>')
    $t = [regex]::Replace($t, 'squad-cli-stub-[0-9a-f]{32}', '<STUB>')
    return ($t -replace "`r`n", "`n")
}

function Get-CaptureWithoutErrorLineNumbers {
    <#
    .SYNOPSIS
        Strips ONLY PowerShell's error-record source-line annotation, which
        cannot survive a refactor that changes a file's length.
    #>
    param([string]$Text)
    $t = $Text -replace "$([char]27)\[[0-9;]*m", ''       # PS7 colourises error records
    $t = $t -replace 'squad-aca\.ps1:\d+', 'squad-aca.ps1:<LINE>'
    return ($t -replace '(?m)^\s*\d+\s\|', '<LINE> |')
}

function Invoke-CaptureSet {
    param([string]$ScriptsRoot, [string]$OutDir)

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Get-ChildItem -Path $OutDir -File | Remove-Item -Force
    $cli = Join-Path $ScriptsRoot "squad-aca.ps1"
    if (-not (Test-Path $cli)) { throw "squad-aca.ps1 not found under $ScriptsRoot" }

    $shared = New-SquadCliStubEnvironment
    try {
        foreach ($case in $Cases) {
            $stub = $shared
            $fresh = $null
            if ($case.ContainsKey("NeedsRepo") -and $case.NeedsRepo) {
                $fresh = New-SquadCliStubEnvironment
                Initialize-SquadCliStubRepository -Stub $fresh | Out-Null
                $stub = $fresh
            }
            Reset-SquadCliStubLog -Stub $stub

            $stopRc = 0
            if ($case.ContainsKey("StopRc")) { $stopRc = $case.StopRc }
            $startRc = 0
            if ($case.ContainsKey("StartRc")) { $startRc = $case.StartRc }

            $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cli -CliArguments $case.Args `
                -StopExitCode $stopRc -StartExitCode $startRc

            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("### CASE $($case.Id): squad-aca $($case.Args -join ' ')")
            [void]$sb.AppendLine("### EXITCODE: $($r.ExitCode)")
            [void]$sb.AppendLine("### AZ CALLS")
            foreach ($line in $r.AzCalls) { [void]$sb.AppendLine((Get-NormalizedCapture $line $ScriptsRoot)) }
            [void]$sb.AppendLine("### GH CALLS")
            foreach ($line in $r.GhCalls) { [void]$sb.AppendLine((Get-NormalizedCapture $line $ScriptsRoot)) }
            [void]$sb.AppendLine("### STDOUT")
            [void]$sb.AppendLine((Get-NormalizedCapture $r.StdOut $ScriptsRoot))
            [void]$sb.AppendLine("### STDERR")
            [void]$sb.AppendLine((Get-NormalizedCapture $r.StdErr $ScriptsRoot))

            [System.IO.File]::WriteAllText(
                (Join-Path $OutDir "$($case.Id).txt"),
                ($sb.ToString() -replace "`r`n", "`n"))
            Write-Host ("  captured {0} (exit {1}, {2} az calls)" -f $case.Id, $r.ExitCode, $r.AzCalls.Count)
            if ($fresh) { Remove-SquadCliStubEnvironment -Stub $fresh }
        }
    } finally {
        Remove-SquadCliStubEnvironment -Stub $shared
    }
}

if (-not $WorkDir) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("squad-cli-baseline-" + [guid]::NewGuid().ToString("N"))
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

try {
    # Materialise the baseline revision's scripts/ without disturbing the worktree.
    $baselineRoot = Join-Path $WorkDir "baseline"
    New-Item -ItemType Directory -Force -Path $baselineRoot | Out-Null
    Push-Location $RepoRoot
    try {
        $archive = Join-Path $WorkDir "baseline-scripts.tar"
        git archive --format=tar --output=$archive $BaselineRef scripts
        if ($LASTEXITCODE -ne 0) { throw "git archive $BaselineRef failed" }
    } finally {
        Pop-Location
    }
    tar -xf (Join-Path $WorkDir "baseline-scripts.tar") -C $baselineRoot
    if ($LASTEXITCODE -ne 0) { throw "extracting the baseline archive failed" }

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
