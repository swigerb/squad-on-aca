#requires -Version 5.1
<#
.SYNOPSIS
    Proves the worker launch command `New-SandboxLaunchCommand` emits really
    DETACHES, by running it in a real POSIX shell.

.DESCRIPTION
    `aca sandbox exec` has a hard ~120 s client transport timeout. A launch that
    does not detach holds the exec open, times out with
    `Network issue - retry policy expired`, and `create`'s catch then TERMINATES
    a perfectly healthy 10-60 minute session two minutes in. Detachment is
    therefore an invariant, not a style preference.

    It is also a SHELL GRAMMAR property, which is why no substring assertion can
    check it. In POSIX/bash, `&` is a list terminator that binds *looser* than
    `&&`, so

        prelude && setsid nohup bash -c '...' </dev/null >/dev/null 2>&1 &

    contains every character of a detach while backgrounding the ENTIRE and-list
    and binding the three redirections to the last simple command only. The async
    subshell inherits the exec's fd 0/1/2 and holds them for the whole worker
    run. Both of these are true of that string:

        $cmd -like "*setsid nohup bash -c *"
        $cmd -like "*</dev/null >/dev/null 2>&1 &*"

    and the offline `aca` stub never evaluates the `-c` payload in a shell, so
    nothing in the stubbed suite can tell a detach from the characters of one.

    This script can. It generates the launch command from the shipping generator
    (with the entrypoint and state directory pointed at a throwaway worker that
    sleeps), runs it under `out=$( ... )` in a real shell -- command substitution
    reads the pipe until EVERY writer closes it, exactly the condition that holds
    `aca sandbox exec` open -- and asserts the caller was released while the
    worker was still running.

    It also asserts the ordering the same `&` mis-scoping breaks as a side
    effect: the prelude must run synchronously (so `phase` reads `running` at
    return rather than racing an asynchronous `mkdir`), and the detached wrapper
    must still record the exit code before touching the completion marker.

.PARAMETER Distro
    WSL distribution to use on Windows. Defaults to $env:SQUAD_DETACH_PROBE_DISTRO
    or `Ubuntu`. Ignored on Linux/macOS, where `bash` is used directly.

.PARAMETER WorkerSeconds
    How long the simulated worker runs. The launch must return well inside this.

.PARAMETER ReturnBudgetMs
    The launch must release the caller within this many milliseconds.

.OUTPUTS
    Exit 0  every assertion passed.
    Exit 1  the launch does not detach (or the wrapper's ordering is wrong).
    Exit 77 no POSIX shell available -- the check DID NOT RUN. Mirrors
            worker/tests/lib/deps.sh; callers must count this as a skip, never
            as a pass.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\tests\verify-launch-detachment.ps1
#>
[CmdletBinding()]
param(
    [string]$Distro = "",
    [int]$WorkerSeconds = 3,
    [int]$ReturnBudgetMs = 1500
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

$SKIP_EXIT_CODE = 77

$providerPath = Join-Path $RepoRoot (Join-Path "scripts" (Join-Path "lib" (Join-Path "providers" "squad-sandbox-provider.ps1")))
if (-not (Test-Path $providerPath)) {
    Write-Host "FAIL: $providerPath not found." -ForegroundColor Red
    exit 1
}
. $providerPath

if (-not $Distro) {
    $Distro = if ($env:SQUAD_DETACH_PROBE_DISTRO) { $env:SQUAD_DETACH_PROBE_DISTRO } else { "Ubuntu" }
}

# $IsWindows only exists in PowerShell 6+; 5.1 is always Windows.
$onWindows = if ($null -ne $PSVersionTable.Platform) { $PSVersionTable.Platform -eq "Win32NT" } else { $true }

# Resolve a shell that can actually run the command. On Windows that means WSL:
# Git Bash / MSYS have no `setsid`, so they would report a false FAILURE rather
# than a skip, which is worse than not running at all.
$runner = $null
$runnerArgs = @()
$runnerName = ""
$skipReason = ""

if ($onWindows) {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        $skipReason = "wsl.exe is not on PATH (Git Bash/MSYS cannot be used: no setsid)"
    } else {
        $probe = & $wsl.Source -d $Distro -e bash -c "command -v setsid >/dev/null && echo squad-shell-ok" 2>$null
        if ($LASTEXITCODE -ne 0 -or (([string[]]$probe -join "") -notmatch "squad-shell-ok")) {
            $skipReason = "'wsl -d $Distro -e bash' did not run, or the distro has no setsid (exit $LASTEXITCODE)"
        } else {
            $runner = $wsl.Source
            $runnerArgs = @("-d", $Distro, "-e", "bash", "-s")
            $runnerName = "wsl -d $Distro -e bash"
        }
    }
} else {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        $skipReason = "bash is not on PATH"
    } else {
        $probe = & $bash.Source -c "command -v setsid >/dev/null && echo squad-shell-ok" 2>$null
        if ($LASTEXITCODE -ne 0 -or (([string[]]$probe -join "") -notmatch "squad-shell-ok")) {
            $skipReason = "bash is present but has no setsid (exit $LASTEXITCODE)"
        } else {
            $runner = $bash.Source
            $runnerArgs = @("-s")
            $runnerName = "bash"
        }
    }
}

if (-not $runner) {
    Write-Host "SKIP: worker-launch detachment is UNVERIFIED - $skipReason." -ForegroundColor Yellow
    Write-Host "      Only a real shell can distinguish a detach from a command containing the characters of one."
    Write-Host "      A skip is NOT a pass; the caller must account for it separately (exit $SKIP_EXIT_CODE)."
    exit $SKIP_EXIT_CODE
}

# Where the probe's throwaway state lives, inside the shell's own filesystem.
$homeOut = if ($onWindows) { & $runner -d $Distro -e bash -c "printf %s `$HOME" } else { & $runner -c "printf %s `$HOME" }
$shellHome = ([string[]]$homeOut -join "").Trim()
if (-not $shellHome) { $shellHome = "/tmp" }
$probeDir = "$shellHome/.squad-detach-probe-" + [guid]::NewGuid().ToString("N")

# The command under test comes from the SHIPPING generator; only the two
# parameters it already exposes are pointed at the throwaway worker.
$launch = New-SandboxLaunchCommand `
    -Environment ([ordered]@{ SQUAD_DETACH_PROBE = "1" }) `
    -StateDir $probeDir `
    -Entrypoint "$probeDir/worker.sh"

$settle = $WorkerSeconds + 2

# The credential-staging half of the probe. Sprint 7 delivers the git/`gh`
# token on the STDIN of a staging exec, into a umask-077 file that the launch
# command sources and deletes. Every one of those claims is behavioural, so
# each is checked by running the shipping strings in a real shell:
#
#   * the token is written on stdin, never as an argument -- proven by the
#     command containing none of it while the worker still ends up with it;
#   * the file is 0600 from the instant it exists -- `umask 077` before the
#     redirection, not a chmod afterwards, which would leave a window;
#   * the launch sources it and REMOVES it -- so its on-disk lifetime is the
#     gap between two execs;
#   * the value survives verbatim -- `IFS= read -r` plus `printf '%s'`, so no
#     field splitting, no backslash processing, no lost trailing characters.
#
# The token used here is a throwaway literal generated per run; it never
# leaves the probe's own shell.
$probeToken = "sq-probe-" + [guid]::NewGuid().ToString("N")
$seed = New-SandboxCredentialSeedCommand -StateDir $probeDir
$launchWithCreds = New-SandboxLaunchCommand `
    -Environment ([ordered]@{ SQUAD_DETACH_PROBE = "1" }) `
    -StateDir $probeDir `
    -Entrypoint "$probeDir/worker.sh"

# Anything in the shipping strings that leaks the token defeats the point --
# but `$seed` and `$launchWithCreds` are produced by generators that never
# RECEIVE the token, so "does this string contain it?" is a question whose
# answer is fixed by construction: those two checks could not fail whatever the
# generators did. They have been replaced by two that can.
#
#   1. The generator's own REFUSAL, exercised with the token. Passing a
#      credential-bearing name to New-SandboxLaunchCommand must throw, because
#      an `env NAME=value` assignment is argv and argv is readable by every
#      process in the sandbox. Delete that guard and this check fails.
#   2. A behavioural argv sweep (below, ARGVLEAK). While the worker holds the
#      staged token in its ENVIRONMENT -- which is the whole point of the
#      staging design -- no process on the machine may have it in its argv. Move
#      the token from stdin into any command line and this check fails.
$staticLeaks = @()
$guardErr = ""
try {
    New-SandboxLaunchCommand `
        -Environment ([ordered]@{ SQUAD_DETACH_PROBE = "1"; GH_TOKEN = $probeToken }) `
        -StateDir $probeDir -Entrypoint "$probeDir/worker.sh" | Out-Null
} catch { $guardErr = [string]$_.Exception.Message }
if ($guardErr -notmatch "\[squad-sandbox:capability\]") {
    $staticLeaks += "the launch generator accepted a credential-bearing env assignment (GH_TOKEN) instead of refusing it -- argv is readable by every process in the sandbox (error was: '$guardErr')"
}
if ($guardErr -match [regex]::Escape($probeToken)) {
    $staticLeaks += "the launch generator's refusal echoed the token value"
}
if ($launchWithCreds -match "GH_TOKEN=" -or $launchWithCreds -match "GITHUB_TOKEN=") { $staticLeaks += "the launch command still assigns a token-bearing env var" }

$script = @"
set -u
S='$probeDir'
rm -rf "`$S"; mkdir -p "`$S"
printf '%s\n' '#!/usr/bin/env bash' 'sleep $WorkerSeconds' > "`$S/worker.sh"
chmod +x "`$S/worker.sh"
t0=`$(date +%s%N)
out=`$($launch)
t1=`$(date +%s%N)
echo "ELAPSED_MS=`$(( (t1 - t0) / 1000000 ))"
echo "OUT=`$out"
echo "PHASE_AT_RETURN=`$(cat "`$S/phase" 2>/dev/null)"
sleep $settle
echo "PHASE_FINAL=`$(cat "`$S/phase" 2>/dev/null)"
echo "EXIT_FILE=`$(cat "`$S/exit-code" 2>/dev/null)"
if [ -f "`$S/done" ]; then echo "MARKER=done"; else echo "MARKER=absent"; fi
rm -rf "`$S"

# ---- credential staging -------------------------------------------------
rm -rf "`$S"; mkdir -p "`$S"
printf '%s\n' '#!/usr/bin/env bash' '{ ps -ww -eo args= 2>/dev/null; cat /proc/*/cmdline 2>/dev/null | tr "\0" " "; } > "$probeDir/argv-snapshot"' 'printf %s "`${GH_TOKEN:-MISSING}" > "$probeDir/seen-token"' 'printf %s "`${GITHUB_TOKEN:-MISSING}" > "$probeDir/seen-token2"' > "`$S/worker.sh"
chmod +x "`$S/worker.sh"
# The token goes in on STDIN. It is in no argument vector of anything below.
printf '%s\n' '$probeToken' | ( $seed )
echo "STAGED=`$?"
if [ -f "`$S/.squad-creds" ]; then echo "CREDFILE=present"; else echo "CREDFILE=absent"; fi
echo "CREDMODE=`$(stat -c %a "`$S/.squad-creds" 2>/dev/null)"
out2=`$($launchWithCreds)
echo "OUT2=`$out2"
sleep 2
echo "SEEN=`$(cat "`$S/seen-token" 2>/dev/null)"
echo "SEEN2=`$(cat "`$S/seen-token2" 2>/dev/null)"
# The worker held the token in its ENVIRONMENT at the instant of this snapshot
# (SEEN= above proves that). No process may have held it in its ARGV.
if [ ! -s "`$S/argv-snapshot" ]; then echo "ARGVLEAK=unchecked"
elif grep -qF '$probeToken' "`$S/argv-snapshot"; then echo "ARGVLEAK=present"
else echo "ARGVLEAK=absent"; fi
if [ -f "`$S/.squad-creds" ]; then echo "CREDFILE_AFTER=present"; else echo "CREDFILE_AFTER=absent"; fi
rm -rf "`$S"
"@ -replace "`r`n", "`n"

Write-Host "Running the emitted launch command under $runnerName (worker sleeps ${WorkerSeconds}s)..." -ForegroundColor Cyan
$out = ($script | & $runner @runnerArgs 2>&1 | Out-String)
$elapsed = if ($out -match "ELAPSED_MS=(\d+)") { [int]$Matches[1] } else { -1 }
$flat = ($out -replace "`r?`n", " | ").Trim()

$failures = @()

if ($elapsed -lt 0) {
    $failures += "the probe produced no timing at all"
} elseif ($elapsed -ge $ReturnBudgetMs) {
    $failures += ("the caller was held for ${elapsed}ms against a ${WorkerSeconds}s worker (budget ${ReturnBudgetMs}ms) -- " +
                  "a '&' scoped over the whole '&&'-list backgrounds everything and leaves fd 0/1/2 open, so " +
                  "'aca sandbox exec' blocks to its ~120s timeout and create tears the session down")
}
if ($out -notmatch "OUT=.*squad-launched") { $failures += "the launch did not report squad-launched" }
if ($out -notmatch "PHASE_AT_RETURN=running") { $failures += "phase was not 'running' at return -- the prelude and the phase write are mis-ordered (an asynchronous prelude races the phase write on a fresh sandbox, where the state dir does not exist yet)" }
if ($out -notmatch "PHASE_FINAL=done") { $failures += "the detached worker never wrote phase=done" }
if ($out -notmatch "EXIT_FILE=0") { $failures += "the detached wrapper did not record the worker's exit code" }
if ($out -notmatch "MARKER=done") { $failures += "the detached wrapper never touched the completion marker" }

# --- credential staging ---------------------------------------------------
$failures += $staticLeaks
if ($out -notmatch "STAGED=0") { $failures += "the staging command did not succeed reading the token from stdin" }
if ($out -notmatch "CREDFILE=present") { $failures += "the staging command did not create the credential file" }
if ($out -notmatch "CREDMODE=600") { $failures += "the credential file is not 0600 (umask 077 must apply at creation; a later chmod leaves a readable window)" }
if ($out -notmatch ("SEEN=" + [regex]::Escape($probeToken))) { $failures += "the worker did not receive the staged token verbatim -- delivery is broken, or the value was mangled by field splitting" }
if ($out -notmatch ("SEEN2=" + [regex]::Escape($probeToken))) { $failures += "GITHUB_TOKEN was not staged alongside GH_TOKEN" }
if ($out -notmatch "CREDFILE_AFTER=absent") { $failures += "the credential file survived the launch -- it must be removed as soon as it is sourced, so its on-disk lifetime is the gap between two execs" }
if ($out -match "ARGVLEAK=present") { $failures += "the staged token appeared in a process ARGUMENT VECTOR while the worker ran -- argv is readable by every process in the sandbox, which is the exposure stdin staging exists to avoid" }
if ($out -notmatch "ARGVLEAK=(present|absent)") { $failures += "the argv sweep did not run, so 'the token never reaches an argv' is UNVERIFIED (a check that cannot observe is not a pass)" }
if ($out -match [regex]::Escape($probeToken) -and $out -notmatch ("SEEN=" + [regex]::Escape($probeToken))) { $failures += "the token appeared in probe output outside the worker's own read-back" }

Write-Host ""
Write-Host "Probe output: $flat"
Write-Host ""

if ($failures.Count -eq 0) {
    Write-Host "PASS: the emitted launch command detaches - the caller's streams reached EOF in ${elapsed}ms while a ${WorkerSeconds}s worker kept running, and the wrapper recorded exit code then completion marker." -ForegroundColor Green
    Write-Host "PASS: the credential staged on STDIN reached the worker verbatim through a 0600 file that the launch sourced and removed, the launch generator REFUSES a credential-bearing env assignment, and no process held the token in its argv while the worker held it in its environment." -ForegroundColor Green
    exit 0
}

Write-Host "FAIL: the emitted launch command does not behave as a detached launch." -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
