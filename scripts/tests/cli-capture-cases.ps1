<#
.SYNOPSIS
    The shared `squad-aca` capture matrix and capture/normalisation helpers.

.DESCRIPTION
    Two guards drive the same 22 CLI invocations through the stubbed `az`/`gh`
    environment, so the matrix and the capture format live here rather than
    being duplicated (and drifting):

      * scripts/tests/compare-cli-baseline.ps1 -- differential: runs the matrix
        against ANOTHER git revision's scripts/ tree and diffs the two capture
        sets. Proves "nothing observable changed since <ref>".
      * scripts/tests/verify-cli-golden.ps1 -- golden: runs the matrix against
        the working tree and diffs it against captures committed under
        scripts/tests/golden/cli/. Needs no second revision, so it runs in CI on
        every push and pull request.

    A capture records the exit code, every recorded `az`/`gh`/`squad` argv,
    stdout and stderr for one invocation. stdout is in there deliberately: PR #9
    was closed for an observable `stop` output regression, and a guard that only
    counts az calls and checks the exit code cannot see one.

    Nothing here touches Azure, GitHub, or the network.
#>

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here; this file
# is dot-sourced by callers that set their own.

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
    # --- Machine-readable output (issue #33 S1) -----------------------------
    # `--json` is an OPT-IN, additive mode. Cases 01-22 above deliberately never
    # pass it, so those 22 goldens keep pinning the human output byte for byte;
    # these four pin the machine contract with the same rigour. A change to the
    # JSON shape is now a reviewable capture diff, exactly like a change to a
    # table.
    #
    # 23 also proves the pass-through rule under --json: `az containerapp job
    # start`'s STUB-START-ACK must appear under ### STDERR (moved so stdout can
    # carry one parseable document) and must NOT vanish.
    @{ Id = "23-run-json";        Args = @("run", "Build the thing and open a PR", "--name", "fixedjson", "--json"); NeedsRepo = $true }
    @{ Id = "24-sessions-json";   Args = @("sessions", "--json") }
    @{ Id = "25-status-json";     Args = @("status", "--json") }
    @{ Id = "26-sessions-json-session"; Args = @("sessions", "--json", "--session", "stub-session") }
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
        Strips PowerShell's error-record source-line annotation and the ANSI SGR
        colour sequences PowerShell 7 wraps error records in. Neither can
        survive a refactor that changes a file's length or a host that
        colourises differently.
    #>
    param([string]$Text)
    $t = $Text -replace "$([char]27)\[[0-9;]*m", ''       # PS7 colourises error records
    $t = $t -replace 'squad-aca\.ps1:\d+', 'squad-aca.ps1:<LINE>'
    return ($t -replace '(?m)^\s*\d+\s\|', '<LINE> |')
}

function Get-PortableCapture {
    <#
    .SYNOPSIS
        Makes a capture stable across MACHINES, so it can be committed as a
        golden and verified on a CI runner.

    .DESCRIPTION
        Get-NormalizedCapture only removes what differs between two runs on the
        same machine. A committed golden additionally has to survive a different
        user name, temp directory, checkout path, PowerShell host width and
        error colourisation.

        Environment dependence is removed by PINNING at the source wherever that
        is possible, because a pin keeps the value under comparison while a mask
        throws it away:

          * time zone   -- the stub `az` fixtures carry an offset-free
                           startTime, so `sessions` renders the same wall clock
                           in any host time zone (cli-stub-harness.ps1).
          * culture     -- the CLI child process runs with
                           DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
                           (cli-stub-harness.ps1).
          * optional tools -- `squad` is stubbed onto PATH alongside `az`/`gh`,
                           so `doctor` reports it installed everywhere
                           (cli-stub-harness.ps1).

        What is left genuinely cannot be pinned, so it is masked here and in
        Get-NormalizedCapture. The COMPLETE list of masks is:

          1. <TS>      timestamps of the form yyyyMMdd-HHmmss (generated
                       session/branch names).
          2. <SCRIPTS> the absolute path of the scripts/ tree under capture.
          3. <STUB>    the GUID in the throwaway stub root directory name.
          4. <LINE>    the line number in a "squad-aca.ps1:<n>" error header.
          5. <TMP>     the temp root (GetTempPath, %TEMP%, %TMP%, and the 8.3
                       form C:\Users\X~1\AppData\Local\Temp).
          6. <HOME>    the user profile root (%USERPROFILE%, $HOME, and any
                       C:\Users\<name> prefix).
          7. <SHA>     40-hex git object ids from the stub repo's commits.
          8. ANSI SGR colour sequences PowerShell 7 wraps error records in are
             deleted.
          9. PowerShell's error-record source-line decoration (the "Line |",
             "<LINE> |" echo of the offending source line, and its "|  ~~~~"
             caret underline) is dropped -- its content is truncated to the
             host's console width, so it is not portable. The parts that ARE
             observable -- the "Exception: <file>:<line>" header, the message
             text, and the exit code -- are kept.
         10. CRLF is folded to LF.

        Nothing else is touched. Exit codes, every recorded az/gh/squad argv,
        and all message text -- including the `az containerapp job stop` stdout
        that PR #9 lost -- are compared byte for byte.
    #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return "" }

    $t = Get-CaptureWithoutErrorLineNumbers $Text

    # Temp roots and home directories differ per machine and per user.
    foreach ($root in @([System.IO.Path]::GetTempPath(), $env:TEMP, $env:TMP)) {
        if ($root) {
            $trimmed = $root.TrimEnd('\', '/')
            if ($trimmed) { $t = [regex]::Replace($t, [regex]::Escape($trimmed), '<TMP>', 'IgnoreCase') }
        }
    }
    foreach ($userRoot in @($env:USERPROFILE, $env:HOME)) {
        if ($userRoot) {
            $trimmed = $userRoot.TrimEnd('\', '/')
            if ($trimmed) { $t = [regex]::Replace($t, [regex]::Escape($trimmed), '<HOME>', 'IgnoreCase') }
        }
    }
    # Short (8.3) temp paths, e.g. C:\Users\RUNNER~1\AppData\Local\Temp.
    $t = [regex]::Replace($t, '[A-Za-z]:\\Users\\[^\\\r\n]+\\AppData\\Local\\Temp', '<TMP>', 'IgnoreCase')
    $t = [regex]::Replace($t, '[A-Za-z]:\\Users\\[^\\\r\n]+', '<HOME>', 'IgnoreCase')

    # Git object ids from the stub repository's throwaway commits.
    $t = [regex]::Replace($t, '\b[0-9a-f]{40}\b', '<SHA>')

    # PowerShell's error-record decoration echoes the offending source line and
    # underlines it with carets, truncated to the host's console width. That
    # rendering is host- and version-dependent, so it cannot be committed. The
    # parts that are observable -- the "Exception: <file>:<line>" header, the
    # message text itself, and the exit code -- are kept and compared as-is.
    $t = (($t -split "`n") | Where-Object {
        $_ -notmatch '^\s*Line \|\s*$' -and
        $_ -notmatch '^<LINE> \|' -and
        $_ -notmatch '^\s*\|\s*[~\s]+$'
    }) -join "`n"

    return ($t -replace "`r`n", "`n")
}

function Invoke-CaptureSet {
    <#
    .SYNOPSIS
        Runs the whole matrix against one scripts/ tree and writes one capture
        file per case into $OutDir.
    #>
    param([string]$ScriptsRoot, [string]$OutDir, [switch]$Portable, [switch]$Quiet)

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
            [void]$sb.AppendLine("### SQUAD CALLS")
            foreach ($line in $r.SquadCalls) { [void]$sb.AppendLine((Get-NormalizedCapture $line $ScriptsRoot)) }
            # The `aca` shim is on PATH for every capture so that any command
            # which ever starts shelling out to it shows up as a capture diff --
            # a claim the harness makes and that only holds if the captures
            # actually RECORD the aca calls. Empty in every golden today, which
            # is the flag-off guarantee written down: the first command that
            # invokes `aca` with the flag off fails this gate.
            [void]$sb.AppendLine("### ACA CALLS")
            foreach ($line in $r.AcaCalls) { [void]$sb.AppendLine((Get-NormalizedCapture $line $ScriptsRoot)) }
            [void]$sb.AppendLine("### STDOUT")
            [void]$sb.AppendLine((Get-NormalizedCapture $r.StdOut $ScriptsRoot))
            [void]$sb.AppendLine("### STDERR")
            [void]$sb.AppendLine((Get-NormalizedCapture $r.StdErr $ScriptsRoot))

            $text = $sb.ToString() -replace "`r`n", "`n"
            if ($Portable) { $text = Get-PortableCapture $text }

            [System.IO.File]::WriteAllText((Join-Path $OutDir "$($case.Id).txt"), $text)
            if (-not $Quiet) {
                Write-Host ("  captured {0} (exit {1}, {2} az calls)" -f $case.Id, $r.ExitCode, $r.AzCalls.Count)
            }
            if ($fresh) { Remove-SquadCliStubEnvironment -Stub $fresh }
        }
    } finally {
        Remove-SquadCliStubEnvironment -Stub $shared
    }
}
