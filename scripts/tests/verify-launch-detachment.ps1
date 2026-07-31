#requires -Version 5.1
<#
.SYNOPSIS
    Proves the worker launch command `New-SandboxLaunchCommand` emits really
    DETACHES, by running it in the shell production actually uses -- dash.

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

    ISSUE #40 -- THE SHELL THIS RUNS IN. Until now every one of those evaluations
    happened under BASH, while `aca sandbox exec` runs the command under
    `/bin/sh`, which is dash on the pinned class image. That is not a detail: it
    is the exact hole that shipped a broken cancel in #36, where `$(< file)`
    expanded to the empty string under dash with no error and no exit code, and a
    probe running the same string under bash reported everything fine. A
    behavioural probe evaluating the shipping artefact in the WRONG interpreter
    is more dangerous than a missing test, because the gate is green and looks
    meaningful.

    So every emitted command is now evaluated through `sh -c`, exactly as the
    sandbox does, and the probe REFUSES to run unless `/bin/sh` is really dash
    (SH_IMPL below) -- a bash `/bin/sh` would make every assertion prove less
    than it claims. Three things are checked that were not:

      * SYNTAX, for every command the provider emits (not just the launch):
        `dash -n` AND `bash -n`. Both, because the launch's inner wrapper is run
        by an explicit `bash -c` while the outer command is run by dash, so the
        two dialects are both live in production and a command must satisfy the
        one that will interpret it.
      * The STATIC SCREEN in scripts/lib/squad-shell-portability.ps1, applied to
        every emitted command including the inner wrapper -- the same screen
        validate.ps1 runs, from the same inventory, so the two cannot disagree
        about what ships.
      * DETACHMENT IN BOTH SHELLS. The launch is measured under dash (which is
        what production uses) and again under bash. The second run is not
        redundant: `&`-scoping is a grammar property both shells share, the
        pre-#40 probe caught a real mis-scoped `&` under bash, and keeping the
        bash measurement means this change strictly adds evidence rather than
        trading one shell's coverage for another's.

.PARAMETER Distro
    WSL distribution to use on Windows. Defaults to $env:SQUAD_DETACH_PROBE_DISTRO
    or `Ubuntu`. Ignored on Linux/macOS, where `bash` is used directly.

.PARAMETER WorkerSeconds
    How long the simulated worker runs. The launch must return well inside this.

.PARAMETER ReturnBudgetMs
    The launch must release the caller within this many milliseconds.

.OUTPUTS
    Exit 0  every assertion passed.
    Exit 1  the launch does not detach (or the wrapper's ordering is wrong, or an
            emitted command is not dash-safe).
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

$portabilityPath = Join-Path $RepoRoot (Join-Path "scripts" (Join-Path "lib" "squad-shell-portability.ps1"))
if (-not (Test-Path $portabilityPath)) {
    Write-Host "FAIL: $portabilityPath not found -- the emitted-command inventory and the bashism screen live there." -ForegroundColor Red
    exit 1
}
. $portabilityPath

if (-not $Distro) {
    $Distro = if ($env:SQUAD_DETACH_PROBE_DISTRO) { $env:SQUAD_DETACH_PROBE_DISTRO } else { "Ubuntu" }
}

# $IsWindows only exists in PowerShell 6+; 5.1 is always Windows.
$onWindows = if ($null -ne $PSVersionTable.Platform) { $PSVersionTable.Platform -eq "Win32NT" } else { $true }

# Resolve a shell that can actually run the command. On Windows that means WSL:
# Git Bash / MSYS have no `setsid`, so they would report a false FAILURE rather
# than a skip, which is worse than not running at all.
#
# The HARNESS runs under bash (it needs `date +%s%N`, functions and a stable
# heredoc, and its own dialect is not what is under test). Every command UNDER
# TEST is invoked through `sh -c`, which is what `aca sandbox exec` does -- and
# SH_IMPL below refuses to accept a `/bin/sh` that is not really dash, because a
# bash `/bin/sh` would silently restore exactly the blind spot issue #40 exists
# to close. `dash` itself must also be present, for the `dash -n` syntax checks.
$runner = $null
$runnerArgs = @()
$runnerName = ""
$skipReason = ""
$shellProbe = "command -v setsid >/dev/null && command -v dash >/dev/null && echo squad-shell-ok"

if ($onWindows) {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        $skipReason = "wsl.exe is not on PATH (Git Bash/MSYS cannot be used: no setsid)"
    } else {
        $probe = & $wsl.Source -d $Distro -e bash -c $shellProbe 2>$null
        if ($LASTEXITCODE -ne 0 -or (([string[]]$probe -join "") -notmatch "squad-shell-ok")) {
            $skipReason = "'wsl -d $Distro -e bash' did not run, or the distro has no setsid / no dash (exit $LASTEXITCODE). dash is required: the sandbox runs every emitted command under it, and checking them under bash is the defect this probe exists to prevent"
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
        $probe = & $bash.Source -c $shellProbe 2>$null
        if ($LASTEXITCODE -ne 0 -or (([string[]]$probe -join "") -notmatch "squad-shell-ok")) {
            $skipReason = "bash is present but has no setsid, or dash is not installed (exit $LASTEXITCODE). dash is required: the sandbox runs every emitted command under it"
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

# `aca sandbox exec -c '<cmd>'` runs <cmd> under /bin/sh. Everything the probe
# evaluates goes through the same door (issue #40), so what is measured is what
# the sandbox will actually interpret. Same helper, same escaping rule, as
# verify-sandbox-cancel.ps1.
function New-ShInvocation([string]$cmd) {
    return "sh -c '" + ($cmd -replace "'", "'\''") + "'"
}
function New-BashInvocation([string]$cmd) {
    return "bash -c '" + ($cmd -replace "'", "'\''") + "'"
}

$settle = $WorkerSeconds + 2

# The credential-staging half of the probe. Sprint 7 delivers the worker's
# credentials on the STDIN of a staging exec, into a umask-077 file that the
# launch command sources and deletes. Every one of those claims is behavioural,
# so each is checked by running the shipping strings in a real shell:
#
#   * the tokens are written on stdin, never as an argument -- proven by the
#     command containing none of them while the worker still ends up with them;
#   * the file is 0600 from the instant it exists -- `umask 077` before the
#     redirection, not a chmod afterwards, which would leave a window;
#   * the launch sources it and REMOVES it -- so its on-disk lifetime is the
#     gap between two execs;
#   * the values survive verbatim -- `IFS= read -r` plus `printf '%s'`, so no
#     field splitting, no backslash processing, no lost trailing characters;
#   * the two PLANES stay separate -- the shipping default stages the git
#     credential and the Copilot credential from two different stdin lines, and
#     the probe feeds two DIFFERENT values so a generator that wrote one plane's
#     token under the other plane's name is caught rather than masked by using
#     the same value twice.
#
# The tokens used here are throwaway literals generated per run; they never
# leave the probe's own shell.
$probeToken = "sq-probe-" + [guid]::NewGuid().ToString("N")
$probeCopilotToken = "sq-copilot-" + [guid]::NewGuid().ToString("N")
$probeStaging = Get-SandboxCredentialStaging -WorkerSecrets @{
    GH_TOKEN             = $probeToken
    COPILOT_GITHUB_TOKEN = $probeCopilotToken
}
$vaultCommand = New-SandboxCredentialVaultCommand -StateDir $probeDir
$credFileName = $script:SandboxCredentialFileName
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
if ($launchWithCreds -match "GH_TOKEN=" -or $launchWithCreds -match "GITHUB_TOKEN=" -or $launchWithCreds -match "COPILOT_GITHUB_TOKEN=") { $staticLeaks += "the launch command still assigns a token-bearing env var" }

# The Copilot plane is a credential too. If it is not on the launch generator's
# deny list, a future change can put COPILOT_GITHUB_TOKEN back into argv.
$copilotGuardErr = ""
try {
    New-SandboxLaunchCommand `
        -Environment ([ordered]@{ SQUAD_DETACH_PROBE = "1"; COPILOT_GITHUB_TOKEN = $probeCopilotToken }) `
        -StateDir $probeDir -Entrypoint "$probeDir/worker.sh" | Out-Null
} catch { $copilotGuardErr = [string]$_.Exception.Message }
if ($copilotGuardErr -notmatch "\[squad-sandbox:capability\]") {
    $staticLeaks += "the launch generator accepted a credential-bearing env assignment (COPILOT_GITHUB_TOKEN) instead of refusing it (error was: '$copilotGuardErr')"
}

# --------------------------------------------------------------------------
# Issue #40: every emitted command, screened statically and syntax-checked in
# BOTH shells that interpret one in production.
# --------------------------------------------------------------------------
# The inventory comes from scripts/lib/squad-shell-portability.ps1 -- the same
# one validate.ps1 screens -- so the offline gate and this probe cannot end up
# disagreeing about which commands ship.
#
# The launch's INNER wrapper is added here rather than there. It is a single
# quoted word inside the launch, so neither `dash -n` nor `bash -n` looks inside
# it when they parse the launch, and it is the fragment that actually runs the
# worker. It is recovered from the shipping launch string (never restated) and
# checked with `bash -n`, because an explicit `bash -c` is what interprets it.
$emitted = @(Get-SquadEmittedShellCommand)
$shellScreen = @()
if ($emitted.Count -lt 6) {
    $shellScreen += "the emitted-command inventory has only $($emitted.Count) entries; the launch, cancel, poll, credential-vault, logs and credential-file fragments are all interpreted as shell and must all be covered"
}

$innerWrapper = ""
if ($launch -match "bash -c '(.*)' </dev/null") {
    $innerWrapper = $Matches[1] -replace "'\\''", "'"
} else {
    $shellScreen += "the launch no longer hands an inner wrapper to 'bash -c ... </dev/null', so the probe cannot recover the fragment that actually runs the worker and that fragment is now unchecked"
}
if ($innerWrapper) {
    $emitted += [pscustomobject]@{
        Id        = "launch-inner"
        Generator = ""
        Shell     = "bash"
        Command   = $innerWrapper
        Note      = "the detached wrapper, recovered from the emitted launch. Run by an explicit 'bash -c', so bash syntax is legitimate here -- but a bare-redirect substitution is still flagged, because it would read as EMPTY the moment this fragment moved to a sh context."
    }
}

foreach ($e in $emitted) {
    $shellScreen += @(Test-SquadShellPortability -Command $e.Command -Label $e.Id -Shell $e.Shell)
}

# One file per command, written with a QUOTED heredoc so the shell stores the
# bytes verbatim and does not expand anything on the way in. `dash -n` and
# `bash -n` then parse the file without executing a single line of it.
$syntaxBlocks = @()
foreach ($e in $emitted) {
    $syntaxBlocks += @"
cat > "`$SYN/$($e.Id)" <<'SQUADCMDEOF'
$($e.Command)
SQUADCMDEOF
dash -n "`$SYN/$($e.Id)" 2>"`$SYN/$($e.Id).dash.err"; echo "SYNTAX=$($e.Id):dash:`$?:`$(tr -d '\n' < "`$SYN/$($e.Id).dash.err" | cut -c1-160)"
bash -n "`$SYN/$($e.Id)" 2>"`$SYN/$($e.Id).bash.err"; echo "SYNTAX=$($e.Id):bash:`$?:`$(tr -d '\n' < "`$SYN/$($e.Id).bash.err" | cut -c1-160)"
"@
}
$syntaxScript = ($syntaxBlocks -join "`n")

$script = @"
set -u
S='$probeDir'
SYN="`$S-syntax"
rm -rf "`$SYN"; mkdir -p "`$SYN"

# Which /bin/sh is this? Every command below is evaluated through 'sh -c'
# because that is what 'aca sandbox exec' does. If /bin/sh here is bash, the
# evaluations still run -- but they stop proving anything about dash, which is
# the whole point of issue #40.
echo "SH_IMPL=`$(readlink -f "`$(command -v sh)" 2>/dev/null | sed 's#.*/##')"
printf hello > "`$SYN/canary"
echo "SH_BASHISM=[`$(sh -c "v=\`$(< `$SYN/canary); printf %s \"\`$v\"")]"
echo "SH_POSIX=[`$(sh -c "v=\`$(cat `$SYN/canary); printf %s \"\`$v\"")]"

# ---- syntax, every emitted command, in BOTH interpreters -----------------
$syntaxScript
rm -rf "`$SYN"

# ---- detachment, under DASH: the shell the sandbox really uses -----------
rm -rf "`$S"; mkdir -p "`$S"
printf '%s\n' '#!/usr/bin/env bash' 'sleep $WorkerSeconds' > "`$S/worker.sh"
chmod +x "`$S/worker.sh"
t0=`$(date +%s%N)
out=`$($(New-ShInvocation $launch))
t1=`$(date +%s%N)
echo "ELAPSED_MS=`$(( (t1 - t0) / 1000000 ))"
echo "OUT=`$out"
echo "PHASE_AT_RETURN=`$(cat "`$S/phase" 2>/dev/null)"
sleep $settle
echo "PHASE_FINAL=`$(cat "`$S/phase" 2>/dev/null)"
echo "EXIT_FILE=`$(cat "`$S/exit-code" 2>/dev/null)"
if [ -f "`$S/done" ]; then echo "MARKER=done"; else echo "MARKER=absent"; fi
rm -rf "`$S"

# ---- detachment, under BASH: kept, not replaced --------------------------
# '&'-scoping is a grammar property both shells share, and the pre-#40 probe
# caught a real mis-scoped '&' under bash. Measuring both means #40 ADDS the
# production shell rather than trading one shell's coverage for another's.
rm -rf "`$S"; mkdir -p "`$S"
printf '%s\n' '#!/usr/bin/env bash' 'sleep $WorkerSeconds' > "`$S/worker.sh"
chmod +x "`$S/worker.sh"
b0=`$(date +%s%N)
outb=`$($(New-BashInvocation $launch))
b1=`$(date +%s%N)
echo "BASH_ELAPSED_MS=`$(( (b1 - b0) / 1000000 ))"
echo "BASH_OUT=`$outb"
echo "BASH_PHASE_AT_RETURN=`$(cat "`$S/phase" 2>/dev/null)"
sleep $settle
echo "BASH_MARKER=`$([ -f "`$S/done" ] && echo done || echo absent)"
rm -rf "`$S"

# ---- credential delivery ------------------------------------------------
rm -rf "`$S"
printf '%s\n' '#!/usr/bin/env bash' '{ ps -ww -eo args= 2>/dev/null; cat /proc/*/cmdline 2>/dev/null | tr "\0" " "; } > "$probeDir/argv-snapshot"' 'printf %s "`${GH_TOKEN:-MISSING}" > "$probeDir/seen-token"' 'printf %s "`${GITHUB_TOKEN:-MISSING}" > "$probeDir/seen-token2"' 'printf %s "`${COPILOT_GITHUB_TOKEN:-MISSING}" > "$probeDir/seen-token3"' > /tmp/squad-probe-worker.sh
# The SHIPPING vault command, run verbatim -- and under 'sh -c', because that is
# how the provider runs it. It must create the state directory and report the
# mode it actually achieved.
VAULTOUT=`$( $(New-ShInvocation $vaultCommand) )
echo "VAULT=`$VAULTOUT"
mv /tmp/squad-probe-worker.sh "`$S/worker.sh"
chmod +x "`$S/worker.sh"
# `aca sandbox fs write` uploads as ROOT with mode 0644 and the session user
# cannot chmod a root-owned file. Reproduce that exactly -- writing the file
# 0600 here would test a permission the platform never grants and would hide the
# fact that the DIRECTORY is the only real control.
cat > "`$S/$credFileName" <<'SQUADPROBECREDS'
$($probeStaging.Content.TrimEnd("`n"))
SQUADPROBECREDS
chmod 644 "`$S/$credFileName"
echo "STAGED=`$?"
if [ -f "`$S/$credFileName" ]; then echo "CREDFILE=present"; else echo "CREDFILE=absent"; fi
echo "CREDMODE=`$(stat -c %a "`$S/$credFileName" 2>/dev/null)"
echo "VAULTMODE=`$(stat -c %a "`$S" 2>/dev/null)"
out2=`$($(New-ShInvocation $launchWithCreds))
echo "OUT2=`$out2"
sleep 2
echo "SEEN=`$(cat "`$S/seen-token" 2>/dev/null)"
echo "SEEN2=`$(cat "`$S/seen-token2" 2>/dev/null)"
echo "SEEN3=`$(cat "`$S/seen-token3" 2>/dev/null)"
# The worker held the tokens in its ENVIRONMENT at the instant of this snapshot
# (SEEN= above proves that). No process may have held either in its ARGV.
if [ ! -s "`$S/argv-snapshot" ]; then echo "ARGVLEAK=unchecked"
elif grep -qF '$probeToken' "`$S/argv-snapshot"; then echo "ARGVLEAK=present"
elif grep -qF '$probeCopilotToken' "`$S/argv-snapshot"; then echo "ARGVLEAK=present"
else echo "ARGVLEAK=absent"; fi
if [ -f "`$S/$credFileName" ]; then echo "CREDFILE_AFTER=present"; else echo "CREDFILE_AFTER=absent"; fi
rm -rf "`$S"
"@ -replace "`r`n", "`n"

Write-Host "Running every emitted command under $runnerName, evaluating each through 'sh -c' (worker sleeps ${WorkerSeconds}s)..." -ForegroundColor Cyan
$out = ($script | & $runner @runnerArgs 2>&1 | Out-String)
$elapsed = if ($out -match "ELAPSED_MS=(\d+)") { [int]$Matches[1] } else { -1 }
$bashElapsed = if ($out -match "BASH_ELAPSED_MS=(\d+)") { [int]$Matches[1] } else { -1 }
$flat = ($out -replace "`r?`n", " | ").Trim()

$failures = @()

# --- issue #40: is this really the shell production uses? ------------------
# Asserted BEFORE anything else, because if /bin/sh here is bash then every
# `sh -c` evaluation below still runs and still passes -- while proving nothing
# about dash. That is precisely the failure this probe was rewritten to remove,
# so it is a hard failure and never a quiet caveat.
$failures += $shellScreen
if ($out -notmatch "SH_IMPL=dash") {
    $failures += "/bin/sh in the probe environment is not dash (saw '$(if ($out -match 'SH_IMPL=(\S*)') { $Matches[1] } else { 'nothing' })'). 'aca sandbox exec' runs every emitted command under dash, and the whole point of evaluating them through 'sh -c' is that bash HIDES bashisms -- a bash /bin/sh makes every assertion below prove less than it claims"
}
if ($out -notmatch [regex]::Escape("SH_BASHISM=[]")) {
    $failures += "the dash canary did not behave like dash: a bare-redirect command substitution returned a VALUE in this shell, so this shell is not the one that silently returns nothing -- the evaluations below cannot detect the issue #36 defect class"
}
if ($out -notmatch [regex]::Escape("SH_POSIX=[hello]")) {
    $failures += "the POSIX control read nothing, so the canary above proves nothing (the file it reads is missing, not the expansion)"
}

# --- issue #40: syntax, every emitted command, in both interpreters --------
$syntaxSeen = @{}
foreach ($m in [regex]::Matches($out, "SYNTAX=([a-z\-]+):(dash|bash):(\d+):([^\r\n]*)")) {
    $id = $m.Groups[1].Value
    $sh = $m.Groups[2].Value
    $rc = [int]$m.Groups[3].Value
    $err = $m.Groups[4].Value.Trim()
    $syntaxSeen["$id/$sh"] = $true
    $expected = @($emitted | Where-Object { $_.Id -eq $id })
    if ($rc -ne 0) {
        # A `bash -n` failure on a command that only dash runs is still a
        # failure worth reporting: the two grammars overlap almost completely,
        # and a construct only one of them accepts is a portability trap
        # whichever direction it points.
        $failures += "the $id command failed '$sh -n' (exit $rc): $err. It is run by $(if ($expected) { $expected[0].Shell } else { 'sh' }) in production, and a command that will not parse cannot do anything it claims"
    }
}
foreach ($e in $emitted) {
    foreach ($sh in @("dash", "bash")) {
        if (-not $syntaxSeen.ContainsKey("$($e.Id)/$sh")) {
            $failures += "the $($e.Id) command was never syntax-checked with '$sh -n' -- a check that did not run is not a pass"
        }
    }
}

if ($elapsed -lt 0) {
    $failures += "the probe produced no timing at all"
} elseif ($elapsed -ge $ReturnBudgetMs) {
    $failures += ("the caller was held for ${elapsed}ms under DASH against a ${WorkerSeconds}s worker (budget ${ReturnBudgetMs}ms) -- " +
                  "a '&' scoped over the whole '&&'-list backgrounds everything and leaves fd 0/1/2 open, so " +
                  "'aca sandbox exec' blocks to its ~120s timeout and create tears the session down")
}
if ($out -notmatch "OUT=.*squad-launched") { $failures += "the launch did not report squad-launched under dash" }
if ($out -notmatch "PHASE_AT_RETURN=running") { $failures += "phase was not 'running' at return -- the prelude and the phase write are mis-ordered (an asynchronous prelude races the phase write on a fresh sandbox, where the state dir does not exist yet)" }
if ($out -notmatch "PHASE_FINAL=done") { $failures += "the detached worker never wrote phase=done" }
if ($out -notmatch "EXIT_FILE=0") { $failures += "the detached wrapper did not record the worker's exit code" }
if ($out -notmatch "MARKER=done") { $failures += "the detached wrapper never touched the completion marker" }

# --- the same launch, under bash: coverage ADDED, not traded --------------
if ($bashElapsed -lt 0) {
    $failures += "the bash cross-check produced no timing, so the mis-scoped-'&' coverage the pre-#40 probe had is now missing rather than doubled"
} elseif ($bashElapsed -ge $ReturnBudgetMs) {
    $failures += "the caller was held for ${bashElapsed}ms under BASH against a ${WorkerSeconds}s worker (budget ${ReturnBudgetMs}ms) -- the '&' is scoped over the whole '&&'-list"
}
if ($out -notmatch "BASH_OUT=.*squad-launched") { $failures += "the launch did not report squad-launched under bash" }
if ($out -notmatch "BASH_PHASE_AT_RETURN=running") { $failures += "phase was not 'running' at return under bash" }
if ($out -notmatch "BASH_MARKER=done") { $failures += "the detached wrapper never touched the completion marker under bash" }

# --- credential delivery --------------------------------------------------
$failures += $staticLeaks
if ($out -notmatch "VAULT=squad-credentials-vault-700") { $failures += "the vault command did not create the state directory at mode 700 -- the uploaded credential file is root-owned 0644 and cannot be chmod'ed by the session user, so the DIRECTORY is the only thing keeping it private" }
if ($out -notmatch "VAULTMODE=700") { $failures += "the state directory holding the credential file is not 0700 on disk" }
if ($out -notmatch "STAGED=0") { $failures += "the credential file could not be written" }
if ($out -notmatch "CREDFILE=present") { $failures += "no credential file was staged" }
if ($out -notmatch ("SEEN=" + [regex]::Escape($probeToken))) { $failures += "the worker did not receive the staged git token verbatim -- delivery is broken, or the value was mangled by field splitting" }
if ($out -notmatch ("SEEN2=" + [regex]::Escape($probeToken))) { $failures += "GITHUB_TOKEN was not staged alongside GH_TOKEN" }
if ($out -notmatch ("SEEN3=" + [regex]::Escape($probeCopilotToken))) { $failures += "the worker did not receive the staged COPILOT_GITHUB_TOKEN -- the Copilot plane is not delivered, which is exactly the 'No authentication information found' failure the sandbox plane hit in live E2E" }
if ($out -match ("SEEN3=" + [regex]::Escape($probeToken))) { $failures += "the Copilot plane received the GIT plane's token -- the planes are not mapped to their own names" }
if ($out -match ("SEEN=" + [regex]::Escape($probeCopilotToken))) { $failures += "the git plane received the COPILOT plane's token -- the planes are not mapped to their own names" }
if ($out -notmatch "CREDFILE_AFTER=absent") { $failures += "the credential file survived the launch -- it must be removed as soon as it is sourced, so its on-disk lifetime is the gap between the upload and the launch" }
if ($out -match "ARGVLEAK=present") { $failures += "a staged token appeared in a process ARGUMENT VECTOR while the worker ran -- argv is readable by every process in the sandbox, which is the exposure file delivery exists to avoid" }
if ($out -notmatch "ARGVLEAK=(present|absent)") { $failures += "the argv sweep did not run, so 'the token never reaches an argv' is UNVERIFIED (a check that cannot observe is not a pass)" }
if ($out -match [regex]::Escape($probeToken) -and $out -notmatch ("SEEN=" + [regex]::Escape($probeToken))) { $failures += "the token appeared in probe output outside the worker's own read-back" }

Write-Host ""
Write-Host "Probe output: $flat"
Write-Host ""

if ($failures.Count -eq 0) {
    Write-Host "PASS: /bin/sh in this environment is DASH (canary: a bare-redirect substitution returned nothing, the cat control returned 'hello'), so every evaluation below ran in the interpreter 'aca sandbox exec' actually uses." -ForegroundColor Green
    Write-Host "PASS: all $($emitted.Count) emitted shell commands (launch, cancel, poll, credential-vault, logs, credential-file, and the launch's inner bash wrapper) parse under BOTH 'dash -n' and 'bash -n', and none contains a bashism." -ForegroundColor Green
    Write-Host "PASS: the emitted launch command detaches - under dash the caller's streams reached EOF in ${elapsed}ms, and under bash in ${bashElapsed}ms, while a ${WorkerSeconds}s worker kept running; the wrapper recorded exit code then completion marker." -ForegroundColor Green
    Write-Host "PASS: the credentials delivered as a FILE reached the worker verbatim -- the state directory is 0700 (the only control the platform allows, since 'aca sandbox fs write' uploads root-owned 0644), the launch sourced the file and removed it, the git and Copilot planes each received their OWN value, the launch generator REFUSES a credential-bearing env assignment, and no process held either token in its argv while the worker held them in its environment." -ForegroundColor Green
    exit 0
}

Write-Host "FAIL: the emitted commands are not dash-safe, or the launch does not behave as a detached launch." -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
