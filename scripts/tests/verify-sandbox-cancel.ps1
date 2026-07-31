#requires -Version 5.1
<#
.SYNOPSIS
    Proves the cancel command `New-SandboxCancelCommand` emits actually STOPS a
    worker, by running it in a real POSIX shell against real processes -- and
    proves it reports a FAILURE when it cannot.

.DESCRIPTION
    Issue #36. The shipped cancel was

        pkill -f <entrypoint> >/dev/null 2>&1; rm -f <creds>; \
        printf %s 143 > exit-code; printf %s cancelled > phase; \
        touch done; echo squad-cancelled

    `procps` is not in the pinned class image, so `pkill` exited 127; the
    redirection destroyed the only evidence of that; and a `;`-chain reports the
    status of its LAST statement, which was an `echo` and cannot fail. Live, the
    provider read exit 0, told the caller the session was cancelled, and the
    worker ran a further 51 seconds, completed normally, and OVERWROTE the
    `cancelled`/`143` markers with its own `done`/`0`.

    Every offline test at the time asserted that the right STRING was sent. Not
    one of them could tell the characters of a kill from a kill, because the
    offline `aca` stub never evaluates the `-c` payload in a shell. This script
    does: it takes the command from the SHIPPING generator, runs it through
    `sh -c` -- dash, the shell `aca sandbox exec` actually uses -- against
    processes it really started, and looks at what happened to them. Since issue
    #40 the LAUNCH that builds each fixture goes through `sh -c` too, so the
    state every case reads was created the way a real sandbox creates it.

    It also runs the ORIGINAL command shape (kept verbatim below) in the same
    procps-free environment as a self-check. If that control ever stops looking
    like a false success, this probe has lost the ability to detect the defect it
    exists for, and it fails rather than passing quietly.

    Cases, each in its own state directory:

      C1  kills a real worker AND its child (the process GROUP), records
          143/cancelled, and the worker cannot overwrite them afterwards
      C2  the same, with a PATH that has no pkill/pgrep/ps -- the live condition
      C2c CONTROL: the pre-#36 command in that environment reports success and
          leaves the worker running
      C3  no pid file            -> failure, nothing written, worker untouched
      C4  pid file says `1`      -> failure; `kill -TERM -1` is every process
      C5  pid file names another live process -> failure, that process untouched
      C6  pid file names a dead pid -> success (already-dead), markers written
      C7  a worker that IGNORES SIGTERM is escalated to SIGKILL and still dies
      C8  a process that never dies -> reported as survived, no markers written
      C9  a kill that is rejected  -> reported as kill-failed, no markers written
      C10 a session that already finished is reported already-terminal and its
          real exit code is NOT rewritten to 143

.PARAMETER Distro
    WSL distribution to use on Windows. Defaults to $env:SQUAD_DETACH_PROBE_DISTRO
    or `Ubuntu`. Ignored on Linux/macOS, where `bash` is used directly.

.OUTPUTS
    Exit 0  every assertion passed.
    Exit 1  the emitted cancel command does not stop a worker, or reports a
            success it cannot prove.
    Exit 77 no POSIX shell available -- the check DID NOT RUN. Mirrors
            verify-launch-detachment.ps1 and worker/tests/lib/deps.sh; callers
            must count this as a skip, never as a pass.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\tests\verify-sandbox-cancel.ps1
#>
[CmdletBinding()]
param(
    [string]$Distro = ""
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

# Same resolution rule as verify-launch-detachment.ps1: Git Bash / MSYS have no
# setsid and no usable /proc, so they would report a false FAILURE rather than a
# skip, which is worse than not running at all.
$runner = $null
$runnerArgs = @()
$runnerName = ""
$skipReason = ""

if ($onWindows) {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        $skipReason = "wsl.exe is not on PATH (Git Bash/MSYS cannot be used: no setsid, no /proc)"
    } else {
        $probe = & $wsl.Source -d $Distro -e bash -c "command -v setsid >/dev/null && [ -r /proc/self/stat ] && echo squad-shell-ok" 2>$null
        if ($LASTEXITCODE -ne 0 -or (([string[]]$probe -join "") -notmatch "squad-shell-ok")) {
            $skipReason = "'wsl -d $Distro -e bash' did not run, or the distro has no setsid / no readable /proc (exit $LASTEXITCODE)"
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
        $probe = & $bash.Source -c "command -v setsid >/dev/null && [ -r /proc/self/stat ] && echo squad-shell-ok" 2>$null
        if ($LASTEXITCODE -ne 0 -or (([string[]]$probe -join "") -notmatch "squad-shell-ok")) {
            $skipReason = "bash is present but has no setsid / no readable /proc (exit $LASTEXITCODE)"
        } else {
            $runner = $bash.Source
            $runnerArgs = @("-s")
            $runnerName = "bash"
        }
    }
}

if (-not $runner) {
    Write-Host "SKIP: sandbox cancellation is UNVERIFIED - $skipReason." -ForegroundColor Yellow
    Write-Host "      Only a real shell can distinguish a kill from a command containing the characters of one."
    Write-Host "      A skip is NOT a pass; the caller must account for it separately (exit $SKIP_EXIT_CODE)."
    exit $SKIP_EXIT_CODE
}

$homeOut = if ($onWindows) { & $runner -d $Distro -e bash -c "printf %s `$HOME" } else { & $runner -c "printf %s `$HOME" }
$shellHome = ([string[]]$homeOut -join "").Trim()
if (-not $shellHome) { $shellHome = "/var/tmp" }
$root = "$shellHome/.squad-cancel-probe-" + [guid]::NewGuid().ToString("N")

$termGrace = $script:SandboxCancelTermGraceSeconds
$killGrace = $script:SandboxCancelKillGraceSeconds

# Commands under test come from the SHIPPING generators. Only the two parameters
# they already expose (state directory, entrypoint) are pointed at throwaway
# workers; the escalation budget is left at its shipping value, so what the probe
# measures is what the sandbox will do.
function New-ProbeLaunch([string]$dir) {
    return (New-SandboxLaunchCommand -Environment ([ordered]@{ SQUAD_CANCEL_PROBE = "1" }) -StateDir $dir -Entrypoint "$dir/worker.sh")
}
function New-ProbeCancel([string]$dir) {
    return (New-SandboxCancelCommand -StateDir $dir -Entrypoint "$dir/worker.sh")
}

# `aca sandbox exec` hands the command to /bin/sh -- dash on the class image, not
# bash. The first fix for #36 passed under bash and FAILED live for exactly that
# reason: `$(< file)` is a bashism that expands to the empty string under dash,
# so the process scan saw nothing and called a live worker already-dead. Every
# case that tests SHELL behaviour therefore runs the emitted command through
# `sh -c`, the way the sandbox does. The two cases that have to replace `kill`
# itself (C8, C9) run under bash, because `kill` is a builtin and a shell
# function is the only way to make it fail on demand; they exercise the decision
# branches, not the shell dialect.
function New-ShInvocation([string]$cmd) {
    return "sh -c '" + ($cmd -replace "'", "'\''") + "'"
}

$c = @{}
foreach ($id in @("c1", "c2", "c2c", "c3", "c4", "c5", "c6", "c7", "c8", "c9", "c10", "c11", "c12", "c13")) {
    $c[$id] = @{ Dir = "$root/$id"; Launch = (New-ProbeLaunch "$root/$id"); Cancel = (New-ProbeCancel "$root/$id") }
    $c[$id].Sh = (New-ShInvocation $c[$id].Cancel)
    # The LAUNCH crosses the same boundary into the same shell (issue #40), so it
    # is set up through `sh -c` too. Every fixture below is therefore built by
    # dash, exactly as a real sandbox builds it, and a launch that only worked
    # under bash could no longer create the state a cancel case then reads.
    $c[$id].ShLaunch = (New-ShInvocation $c[$id].Launch)
    $c[$id].Esc = ($c[$id].Cancel -replace "'", "'\''")
}

# The command from issue #36, verbatim in shape. It is the CONTROL: run in the
# same procps-free shell it met in production, it must still look like a success
# while leaving the worker running. If it ever stops doing that, this probe can
# no longer see the defect and must not report a pass.
$legacyDir = $c["c2c"].Dir
$legacy = "pkill -f $legacyDir/worker.sh >/dev/null 2>&1; " +
          "rm -f $legacyDir/$($script:SandboxCredentialFileName); " +
          "printf %s 143 > $legacyDir/exit-code; " +
          "printf %s cancelled > $legacyDir/phase; " +
          "touch $legacyDir/done; echo squad-cancelled"

$script = @"
set -u
R='$root'
rm -rf "`$R"; mkdir -p "`$R"

# A PATH with coreutils but NO procps -- the pinned class image, reproduced.
BIN="`$R/nobin"
mkdir -p "`$BIN"
for t in rm sleep touch cat tr sh dash; do
  s=`$(command -v `$t 2>/dev/null)
  [ -n "`$s" ] && ln -sf "`$s" "`$BIN/`$t"
done

# mkworker <dir> <body-file-lines...> : a throwaway worker that records a child
# so a GROUP kill can be told apart from a single-process kill.
mkworker() {
  d="`$1"; shift
  mkdir -p "`$d"
  { echo '#!/usr/bin/env bash'
    echo "sleep 90 & echo \`$! > `$d/child.pid"
    for line in "`$@"; do echo "`$line"; done
  } > "`$d/worker.sh"
  chmod +x "`$d/worker.sh"
}

# alive <pid> : is that pid a live, non-zombie process? Independent of anything
# the command under test does, so it cannot be fooled by the same bug twice.
alive() {
  [ -n "`${1:-}" ] || return 1
  [ -r "/proc/`$1/stat" ] || return 1
  s=`$(cat "/proc/`$1/stat" 2>/dev/null) || return 1
  case "`$s" in *') Z '*) return 1 ;; esac
  return 0
}
groupalive() {
  for f in /proc/[0-9]*/stat; do
    s=`$(cat "`$f" 2>/dev/null) || continue
    r="`${s##*')'}"; r="`${r# }"
    case "`$r" in Z*) continue ;; esac
    r="`${r#* }"; r="`${r#* }"
    [ "`${r%% *}" = "`$1" ] && return 0
  done
  return 1
}
markers() {
  d="`$1"
  p=`$(cat "`$d/phase" 2>/dev/null); e=`$(cat "`$d/exit-code" 2>/dev/null)
  m=absent; [ -f "`$d/done" ] && m=done
  echo "phase=`$p,exit=`$e,marker=`$m"
}

# ===================== C1: kills a real worker and its child ================
echo "SH_IMPL=`$(readlink -f "`$(command -v sh)" 2>/dev/null | sed 's#.*/##')"
mkworker "$($c['c1'].Dir)" 'sleep 4'
$($c['c1'].ShLaunch)
sleep 1
C1PID=`$(cat "$($c['c1'].Dir)/worker.pid" 2>/dev/null)
C1CHILD=`$(cat "$($c['c1'].Dir)/child.pid" 2>/dev/null)
echo "C1_PID=`$C1PID"
echo "C1_CHILD_RECORDED=`$C1CHILD"
t0=`$(date +%s%N)
C1OUT=`$($($c['c1'].Sh) 2>"`$R/c1.err")
C1RC=`$?
t1=`$(date +%s%N)
echo "C1_MS=`$(( (t1 - t0) / 1000000 ))"
echo "C1_RC=`$C1RC"
echo "C1_STDERR=`$(wc -c < "`$R/c1.err" | tr -d ' ')"
echo "C1_STATUS=`$(echo "`$C1OUT" | sed -n 's/^squad-cancel-status=//p')"
echo "C1_HUMAN=`$(echo "`$C1OUT" | sed -n 's/^\(squad-cancelled\)`$/\1/p')"
if alive "`$C1PID"; then echo "C1_WORKER=alive"; else echo "C1_WORKER=gone"; fi
if alive "`$C1CHILD"; then echo "C1_CHILDPROC=alive"; else echo "C1_CHILDPROC=gone"; fi
if groupalive "`$C1PID"; then echo "C1_GROUP=alive"; else echo "C1_GROUP=gone"; fi
echo "C1_MARKERS=`$(markers "$($c['c1'].Dir)")"
# The worker would have run to 4s and its wrapper would then have written
# done/0. Outlive it and prove nothing overwrote the cancellation.
sleep 6
echo "C1_MARKERS_LATER=`$(markers "$($c['c1'].Dir)")"
echo "C1_PIDFILE_AFTER=`$([ -f "$($c['c1'].Dir)/worker.pid" ] && echo present || echo absent)"

# ===================== C2: the live condition -- no procps ==================
echo "C2_PKILL=`$( PATH="`$BIN"; hash -r; command -v pkill 2>/dev/null || echo MISS )"
echo "C2_PS=`$( PATH="`$BIN"; hash -r; command -v ps 2>/dev/null || echo MISS )"
echo "C2_PGREP=`$( PATH="`$BIN"; hash -r; command -v pgrep 2>/dev/null || echo MISS )"

# ---- C2c CONTROL: the pre-#36 command, in exactly that environment ---------
mkworker "$($c['c2c'].Dir)" 'sleep 30'
$($c['c2c'].ShLaunch)
sleep 1
C2CPID=`$(cat "$($c['c2c'].Dir)/worker.pid" 2>/dev/null)
LEGOUT=`$( PATH="`$BIN"; hash -r; $legacy )
LEGRC=`$?
echo "C2C_RC=`$LEGRC"
echo "C2C_OUT=`$LEGOUT"
sleep 1
if alive "`$C2CPID"; then echo "C2C_WORKER=alive"; else echo "C2C_WORKER=gone"; fi
echo "C2C_MARKERS=`$(markers "$($c['c2c'].Dir)")"
kill -KILL -"`$C2CPID" 2>/dev/null
# ---- C2 the shipping command, same environment, its own live worker -------
mkworker "$($c['c2'].Dir)" 'sleep 30'
$($c['c2'].ShLaunch)
sleep 1
C2PID=`$(cat "$($c['c2'].Dir)/worker.pid" 2>/dev/null)
t0=`$(date +%s%N)
C2OUT=`$( PATH="`$BIN"; hash -r; $($c['c2'].Sh) )
C2RC=`$?
t1=`$(date +%s%N)
echo "C2_MS=`$(( (t1 - t0) / 1000000 ))"
echo "C2_RC=`$C2RC"
echo "C2_STATUS=`$(echo "`$C2OUT" | sed -n 's/^squad-cancel-status=//p')"
if alive "`$C2PID"; then echo "C2_WORKER=alive"; else echo "C2_WORKER=gone"; fi
echo "C2_MARKERS=`$(markers "$($c['c2'].Dir)")"

# ===================== C3: no pid file ======================================
mkworker "$($c['c3'].Dir)" 'sleep 30'
$($c['c3'].ShLaunch)
sleep 1
C3PID=`$(cat "$($c['c3'].Dir)/worker.pid" 2>/dev/null)
rm -f "$($c['c3'].Dir)/worker.pid"
C3OUT=`$($($c['c3'].Sh))
C3RC=`$?
echo "C3_RC=`$C3RC"
echo "C3_STATUS=`$(echo "`$C3OUT" | sed -n 's/^squad-cancel-status=//p')"
echo "C3_HUMAN=`$(echo "`$C3OUT" | grep -c '^squad-cancelled`$')"
if alive "`$C3PID"; then echo "C3_WORKER=alive"; else echo "C3_WORKER=gone"; fi
echo "C3_MARKERS=`$(markers "$($c['c3'].Dir)")"
kill -KILL -"`$C3PID" 2>/dev/null

# ===================== C4: pid file says 1 ==================================
mkworker "$($c['c4'].Dir)" 'sleep 30'
$($c['c4'].ShLaunch)
sleep 1
C4PID=`$(cat "$($c['c4'].Dir)/worker.pid" 2>/dev/null)
printf %s 1 > "$($c['c4'].Dir)/worker.pid"
C4OUT=`$($($c['c4'].Sh))
C4RC=`$?
echo "C4_RC=`$C4RC"
echo "C4_STATUS=`$(echo "`$C4OUT" | sed -n 's/^squad-cancel-status=//p')"
if alive "`$C4PID"; then echo "C4_WORKER=alive"; else echo "C4_WORKER=gone"; fi
if alive 1; then echo "C4_INIT=alive"; else echo "C4_INIT=gone"; fi
echo "C4_MARKERS=`$(markers "$($c['c4'].Dir)")"
kill -KILL -"`$C4PID" 2>/dev/null

# ===================== C5: pid file names an unrelated process ==============
mkworker "$($c['c5'].Dir)" 'sleep 30'
$($c['c5'].ShLaunch)
sleep 1
C5PID=`$(cat "$($c['c5'].Dir)/worker.pid" 2>/dev/null)
setsid sleep 45 >/dev/null 2>&1 &
C5OTHER=`$!
sleep 1
printf %s "`$C5OTHER" > "$($c['c5'].Dir)/worker.pid"
C5OUT=`$($($c['c5'].Sh))
C5RC=`$?
echo "C5_RC=`$C5RC"
echo "C5_STATUS=`$(echo "`$C5OUT" | sed -n 's/^squad-cancel-status=//p')"
if alive "`$C5OTHER"; then echo "C5_OTHER=alive"; else echo "C5_OTHER=gone"; fi
if alive "`$C5PID"; then echo "C5_WORKER=alive"; else echo "C5_WORKER=gone"; fi
echo "C5_MARKERS=`$(markers "$($c['c5'].Dir)")"
kill -KILL -"`$C5PID" 2>/dev/null
kill -KILL "`$C5OTHER" 2>/dev/null

# ===================== C6: pid file names a dead pid ========================
mkdir -p "$($c['c6'].Dir)"
DEAD=4194301
while alive "`$DEAD" || groupalive "`$DEAD"; do DEAD=`$(( DEAD - 1 )); done
printf %s "`$DEAD" > "$($c['c6'].Dir)/worker.pid"
printf %s running > "$($c['c6'].Dir)/phase"
C6OUT=`$($($c['c6'].Sh))
C6RC=`$?
echo "C6_RC=`$C6RC"
echo "C6_STATUS=`$(echo "`$C6OUT" | sed -n 's/^squad-cancel-status=//p')"
echo "C6_MARKERS=`$(markers "$($c['c6'].Dir)")"

# ===================== C7: a worker that ignores SIGTERM ====================
mkworker "$($c['c7'].Dir)" "trap '' TERM" 'sleep 40'
$($c['c7'].ShLaunch)
sleep 1
C7PID=`$(cat "$($c['c7'].Dir)/worker.pid" 2>/dev/null)
t0=`$(date +%s%N)
C7OUT=`$($($c['c7'].Sh))
C7RC=`$?
t1=`$(date +%s%N)
echo "C7_MS=`$(( (t1 - t0) / 1000000 ))"
echo "C7_RC=`$C7RC"
echo "C7_STATUS=`$(echo "`$C7OUT" | sed -n 's/^squad-cancel-status=//p')"
if groupalive "`$C7PID"; then echo "C7_GROUP=alive"; else echo "C7_GROUP=gone"; fi
echo "C7_MARKERS=`$(markers "$($c['c7'].Dir)")"

# ===================== C8: a process that never dies ========================
mkworker "$($c['c8'].Dir)" 'sleep 40'
$($c['c8'].ShLaunch)
sleep 1
C8PID=`$(cat "$($c['c8'].Dir)/worker.pid" 2>/dev/null)
# A shell FUNCTION shadows the `kill` builtin, so every signal this cancel sends
# is accepted and delivered nowhere. Liveness still comes from /proc, so the
# process really is alive throughout -- this is the one branch that cannot be
# produced with a cooperating process, because nothing survives SIGKILL.
kill() { return 0; }
t0=`$(date +%s%N)
C8OUT=`$($($c['c8'].Cancel))
C8RC=`$?
t1=`$(date +%s%N)
unset -f kill
echo "C8_MS=`$(( (t1 - t0) / 1000000 ))"
echo "C8_RC=`$C8RC"
echo "C8_STATUS=`$(echo "`$C8OUT" | sed -n 's/^squad-cancel-status=//p')"
echo "C8_HUMAN=`$(echo "`$C8OUT" | grep -c '^squad-cancelled`$')"
if groupalive "`$C8PID"; then echo "C8_GROUP=alive"; else echo "C8_GROUP=gone"; fi
echo "C8_MARKERS=`$(markers "$($c['c8'].Dir)")"
kill -KILL -"`$C8PID" 2>/dev/null

# ===================== C9: the kill is rejected =============================
mkworker "$($c['c9'].Dir)" 'sleep 30'
$($c['c9'].ShLaunch)
sleep 1
C9PID=`$(cat "$($c['c9'].Dir)/worker.pid" 2>/dev/null)
kill() { return 1; }
C9OUT=`$($($c['c9'].Cancel))
C9RC=`$?
unset -f kill
echo "C9_RC=`$C9RC"
echo "C9_STATUS=`$(echo "`$C9OUT" | sed -n 's/^squad-cancel-status=//p')"
if groupalive "`$C9PID"; then echo "C9_GROUP=alive"; else echo "C9_GROUP=gone"; fi
echo "C9_MARKERS=`$(markers "$($c['c9'].Dir)")"
kill -KILL -"`$C9PID" 2>/dev/null

# ===================== C10: a session that already finished =================
mkdir -p "$($c['c10'].Dir)"
printf %s done > "$($c['c10'].Dir)/phase"
printf %s 0 > "$($c['c10'].Dir)/exit-code"
: > "$($c['c10'].Dir)/done"
C10OUT=`$($($c['c10'].Sh))
C10RC=`$?
echo "C10_RC=`$C10RC"
echo "C10_STATUS=`$(echo "`$C10OUT" | sed -n 's/^squad-cancel-status=//p')"
echo "C10_MARKERS=`$(markers "$($c['c10'].Dir)")"

# ===================== C11: the leader is an unreaped zombie ================
# A worker whose leader exited but was never reaped still has a /proc entry and
# still answers kill -0. Anything that reads liveness that way would wait out
# both grace periods and then report a survivor forever. The session IS over,
# so the honest answer is already-dead with the cancelled markers written.
# The fixture must match the real shape: the zombie is its OWN process-group
# leader (setsid, exactly as the launch does it) and its parent exec'd into a
# sleep so it can never reap -- the container PID 1 case this guards against.
mkdir -p "$($c['c11'].Dir)"
printf %s running > "$($c['c11'].Dir)/phase"
setsid bash -c 'setsid bash -c "printf %s \`$\`$ > $($c['c11'].Dir)/worker.pid" & exec sleep 40' >/dev/null 2>&1 &
C11PARENT=`$!
sleep 2
C11PID=`$(cat "$($c['c11'].Dir)/worker.pid" 2>/dev/null)
C11STATE=none
C11PGID=none
if [ -r "/proc/`$C11PID/stat" ]; then
  s=`$(cat "/proc/`$C11PID/stat"); r="`${s##*')'}"; r="`${r# }"; C11STATE="`${r%% *}"
  r="`${r#* }"; r="`${r#* }"; C11PGID="`${r%% *}"
fi
echo "C11_STATE=`$C11STATE"
echo "C11_LEADER=`$([ "`$C11PGID" = "`$C11PID" ] && echo yes || echo no)"
t0=`$(date +%s%N)
C11OUT=`$($($c['c11'].Sh))
C11RC=`$?
t1=`$(date +%s%N)
echo "C11_MS=`$(( (t1 - t0) / 1000000 ))"
echo "C11_RC=`$C11RC"
echo "C11_STATUS=`$(echo "`$C11OUT" | sed -n 's/^squad-cancel-status=//p')"
echo "C11_MARKERS=`$(markers "$($c['c11'].Dir)")"
kill -KILL -"`$C11PARENT" 2>/dev/null

# ============ C12/C13: the scan cannot see, and says so ====================
# The live failure that this whole design turns on: a scan that reads NOTHING
# must not be read as "nothing is running". /proc is masked with a tmpfs in a
# user namespace, which needs no privilege and no daemon.
UNS=no
if command -v unshare >/dev/null 2>&1 && unshare --mount --map-root-user sh -c 'mount -t tmpfs none /proc' >/dev/null 2>&1; then UNS=yes; fi
echo "C12_SUPPORTED=`$UNS"
if [ "`$UNS" = yes ]; then
  mkdir -p "$($c['c12'].Dir)"
  printf %s running > "$($c['c12'].Dir)/phase"
  printf %s 424242 > "$($c['c12'].Dir)/worker.pid"
  C12OUT=`$(unshare --mount --map-root-user sh -c 'mount -t tmpfs none /proc; $($c['c12'].Esc)' 2>/dev/null)
  C12RC=`$?
  echo "C12_RC=`$C12RC"
  echo "C12_STATUS=`$(echo "`$C12OUT" | sed -n 's/^squad-cancel-status=//p')"
  echo "C12_MARKERS=`$(markers "$($c['c12'].Dir)")"

  mkdir -p "$($c['c13'].Dir)"
  printf %s running > "$($c['c13'].Dir)/phase"
  printf %s 424242 > "$($c['c13'].Dir)/worker.pid"
  C13OUT=`$(unshare --mount --map-root-user sh -c 'mount -t tmpfs none /proc; mkdir -p /proc/self; echo 1 > /proc/self/stat; $($c['c13'].Esc)' 2>/dev/null)
  C13RC=`$?
  echo "C13_RC=`$C13RC"
  echo "C13_STATUS=`$(echo "`$C13OUT" | sed -n 's/^squad-cancel-status=//p')"
  echo "C13_MARKERS=`$(markers "$($c['c13'].Dir)")"
fi

rm -rf "`$R"
"@ -replace "`r`n", "`n"

Write-Host "Running the emitted cancel command under $runnerName against real processes (TERM grace ${termGrace}s, KILL grace ${killGrace}s)..." -ForegroundColor Cyan
$out = ($script | & $runner @runnerArgs 2>&1 | Out-String)
$flat = ((($out -split "`r?`n") | Where-Object { $_ -notmatch "setsid (nohup |sleep )" }) -join " | ").Trim()

$failures = @()
$unverified = @()
function Assert-Probe([string]$pattern, [string]$message) {
    if ($out -notmatch $pattern) { $script:failures += $message }
}

# --- C1 -------------------------------------------------------------------
Assert-Probe "SH_IMPL=dash" "/bin/sh in the probe environment is not dash. The sandbox runs the emitted command under dash, and the whole point of running these cases through 'sh -c' is that bash hides bashisms -- a bash /bin/sh makes every case below prove less than it claims"
if ($out -notmatch "C1_PID=\d+") { $failures += "the launch recorded no worker pid at all -- cancel has nothing to signal" }
Assert-Probe "C1_STATUS=killed" "the cancel did not report a confirmed kill of a real worker (C1)"
Assert-Probe "C1_RC=0" "a confirmed kill did not exit 0 (C1)"
Assert-Probe "C1_STDERR=0" "the cancel wrote to stderr. Under dash a failed input redirection is reported by the SHELL, before a trailing 2>/dev/null takes effect, so /proc entries that vanish mid-scan print 'cannot open' straight into the operator's output (C1)"
Assert-Probe "C1_WORKER=gone" "the worker process SURVIVED a cancel that reported success -- this is issue #36 (C1)"
Assert-Probe "C1_CHILDPROC=gone" "the worker's CHILD survived: the cancel signalled one process instead of the process GROUP, so a Copilot child keeps running and keeps billing (C1)"
Assert-Probe "C1_GROUP=gone" "processes remain in the worker's process group after a cancel that reported success (C1)"
Assert-Probe "C1_MARKERS=phase=cancelled,exit=143,marker=done" "the cancellation markers were not written after a confirmed kill (C1)"
Assert-Probe "C1_MARKERS_LATER=phase=cancelled,exit=143,marker=done" "the worker OVERWROTE the cancellation markers after the cancel -- measured live as done/0 replacing cancelled/143 (C1)"
Assert-Probe "C1_PIDFILE_AFTER=absent" "the pid file survived a successful cancel, leaving a stale pid for the next one to signal (C1)"
Assert-Probe "C1_HUMAN=squad-cancelled" "the cancel stopped emitting the human line the provider echoes to the host (C1)"
# The child is a plain sleep: it dies on the first TERM if -- and only if -- the
# signal went to the process GROUP. Signalling the leader alone still ends up
# killing the child, but only after the whole TERM grace has been burned, so the
# elapsed time is the only thing that distinguishes the two.
$c1ms = if ($out -match "C1_MS=(\d+)") { [int]$Matches[1] } else { -1 }
if ($c1ms -lt 0 -or $c1ms -ge ($termGrace * 1000)) {
    $failures += "a cancel against a co-operative worker took ${c1ms}ms, reaching the ${termGrace}s TERM grace -- the TERM did not reach the whole process group, so the child had to be waited out and SIGKILLed instead of shutting down cleanly (C1)"
}

# --- C2 / C2c -------------------------------------------------------------
Assert-Probe "C2_PKILL=MISS" "the probe's procps-free PATH still resolves pkill, so it is not reproducing the live condition (C2)"
Assert-Probe "C2_PS=MISS" "the probe's procps-free PATH still resolves ps (C2)"
Assert-Probe "C2_PGREP=MISS" "the probe's procps-free PATH still resolves pgrep (C2)"
Assert-Probe "C2_STATUS=killed" "the cancel could not kill the worker without procps -- the pinned class image has no pkill, pgrep or ps (C2)"
Assert-Probe "C2_RC=0" "the cancel did not exit 0 in a procps-free shell (C2)"
Assert-Probe "C2_WORKER=gone" "the worker survived a cancel run in the procps-free environment the live sandbox actually has (C2)"
Assert-Probe "C2_MARKERS=phase=cancelled,exit=143,marker=done" "the markers were not written after a confirmed kill without procps (C2)"
# The control. It must LOOK successful and BE useless; if it stops doing either,
# this probe can no longer see the defect.
if ($out -notmatch "C2C_RC=0" -or $out -notmatch "C2C_OUT=squad-cancelled") {
    $failures += "the pre-#36 control command no longer reports a false success, so this probe can no longer demonstrate the defect it exists for (C2c)"
}
if ($out -notmatch "C2C_WORKER=alive") {
    $failures += "the pre-#36 control command killed the worker, which contradicts the live evidence in docs/e2e-results.md S3-5 -- the probe environment is not reproducing the bug (C2c)"
}
if ($out -notmatch "C2C_MARKERS=phase=cancelled,exit=143,marker=done") {
    $failures += "the pre-#36 control command no longer writes cancelled markers while the worker is still alive, so the probe no longer demonstrates the marker race from #36 (C2c)"
}

# --- C3 no pid file -------------------------------------------------------
Assert-Probe "C3_STATUS=no-pidfile" "a cancel with no recorded pid did not report no-pidfile (C3)"
if ($out -match "C3_RC=0") { $failures += "a cancel that had nothing to signal exited 0 -- 'no pid file' must be a FAILED cancel, not the old lie in a new place (C3)" }
Assert-Probe "C3_WORKER=alive" "the C3 fixture did not leave a live worker, so the assertion below proves nothing (C3)"
Assert-Probe "C3_MARKERS=phase=running,exit=,marker=absent" "a cancel that could not signal anything still wrote cancellation markers over a RUNNING session (C3)"
Assert-Probe "C3_HUMAN=0" "a failed cancel still printed the success line the provider echoes to the host (C3)"

# --- C4 pid 1 -------------------------------------------------------------
Assert-Probe "C4_STATUS=bad-pidfile" "a pid file containing '1' was not refused -- 'kill -TERM -1' signals every process the user can reach (C4)"
if ($out -match "C4_RC=0") { $failures += "a refused pid file was reported as a successful cancel (C4)" }
Assert-Probe "C4_WORKER=alive" "the worker was killed via a pid file the command should have refused outright (C4)"
Assert-Probe "C4_INIT=alive" "pid 1 is gone: the cancel signalled process group -1 (C4)"
Assert-Probe "C4_MARKERS=phase=running,exit=,marker=absent" "markers were written for a cancel that refused to signal anything (C4)"

# --- C5 recycled pid ------------------------------------------------------
Assert-Probe "C5_STATUS=not-ours" "a pid that is live but is NOT this worker was signalled anyway -- pid reuse turns a cancel into an unrelated outage (C5)"
if ($out -match "C5_RC=0") { $failures += "signalling nothing was reported as a successful cancel (C5)" }
Assert-Probe "C5_OTHER=alive" "the unrelated process was KILLED by the cancel (C5)"
Assert-Probe "C5_MARKERS=phase=running,exit=,marker=absent" "markers were written although nothing was signalled (C5)"

# --- C6 already dead ------------------------------------------------------
Assert-Probe "C6_STATUS=already-dead" "a recorded pid with no live process was not reported as already-dead (C6)"
Assert-Probe "C6_RC=0" "a worker that is already gone was reported as a failed cancel (C6)"
Assert-Probe "C6_MARKERS=phase=cancelled,exit=143,marker=done" "a confirmed-dead worker did not get its cancellation markers (C6)"

# --- C7 escalation --------------------------------------------------------
Assert-Probe "C7_STATUS=killed" "a worker that ignores SIGTERM was not escalated to SIGKILL (C7)"
Assert-Probe "C7_GROUP=gone" "the SIGTERM-ignoring worker is still running after the cancel reported success (C7)"
Assert-Probe "C7_MARKERS=phase=cancelled,exit=143,marker=done" "the markers were not written after an escalated kill (C7)"
$c7ms = if ($out -match "C7_MS=(\d+)") { [int]$Matches[1] } else { -1 }
if ($c7ms -lt ($termGrace * 1000)) {
    $failures += "the SIGTERM-ignoring worker died in ${c7ms}ms, inside the ${termGrace}s TERM grace -- the escalation path was never exercised, so C7 proves nothing (C7)"
}

# --- C8 survives ----------------------------------------------------------
Assert-Probe "C8_STATUS=survived" "a process that never dies was not reported as survived (C8)"
if ($out -match "C8_RC=0") { $failures += "a worker that survived TERM and KILL was reported as a successful cancel (C8)" }
Assert-Probe "C8_GROUP=alive" "the C8 fixture did not keep the process alive, so the assertion above proves nothing (C8)"
Assert-Probe "C8_MARKERS=phase=running,exit=,marker=absent" "cancellation markers were written for a worker that is still RUNNING -- markers must follow confirmed death, never precede it (C8)"
Assert-Probe "C8_HUMAN=0" "a survived cancel still printed the success line (C8)"
$c8ms = if ($out -match "C8_MS=(\d+)") { [int]$Matches[1] } else { -1 }
if ($c8ms -lt (($termGrace + $killGrace) * 1000)) {
    $failures += "the survived verdict was reached in ${c8ms}ms, before the ${termGrace}s + ${killGrace}s escalation budget elapsed -- the cancel gave up early (C8)"
}

# --- C9 kill rejected -----------------------------------------------------
Assert-Probe "C9_STATUS=kill-failed" "a rejected kill was not reported as kill-failed (C9)"
if ($out -match "C9_RC=0") { $failures += "a kill that was never delivered was reported as a successful cancel (C9)" }
Assert-Probe "C9_GROUP=alive" "the C9 fixture did not keep the worker alive (C9)"
Assert-Probe "C9_MARKERS=phase=running,exit=,marker=absent" "markers were written although the kill was rejected (C9)"

# --- C10 already finished -------------------------------------------------
Assert-Probe "C10_STATUS=already-terminal" "a session that had already finished was not reported as already-terminal (C10)"
Assert-Probe "C10_RC=0" "cancelling a finished session was reported as a failure (C10)"
Assert-Probe "C10_MARKERS=phase=done,exit=0,marker=done" "cancelling a session that had already SUCCEEDED rewrote its real result as cancelled/143 (C10)"

# --- C11 zombie leader ----------------------------------------------------
Assert-Probe "C11_STATE=Z" "the C11 fixture did not produce an unreaped zombie leader, so the assertions below prove nothing (C11)"
Assert-Probe "C11_LEADER=yes" "the C11 zombie is not its own process-group leader, so it does not reproduce the launch's shape and the liveness scan would never look at it (C11)"
Assert-Probe "C11_STATUS=already-dead" "an unreaped zombie leader was not read as dead -- a cancel that counts a zombie as alive waits out both grace periods and then reports a survivor for a session that is already over (C11)"
Assert-Probe "C11_RC=0" "a session whose leader is a zombie was reported as a failed cancel (C11)"
Assert-Probe "C11_MARKERS=phase=cancelled,exit=143,marker=done" "a zombie-leader session did not get its cancellation markers (C11)"
$c11ms = if ($out -match "C11_MS=(\d+)") { [int]$Matches[1] } else { -1 }
if ($c11ms -ge ($termGrace * 1000)) {
    $failures += "the zombie-leader cancel took ${c11ms}ms -- it sat through the TERM grace waiting for a process that had already exited (C11)"
}

# --- C12 / C13: the scan cannot see -------------------------------------
# The live regression that broke the first fix for #36: an unreadable /proc and
# an empty process scan are NOT "the worker is gone". If the namespace trick is
# unavailable the two cases are reported as unverified rather than passed.
if ($out -match "C12_SUPPORTED=yes") {
    Assert-Probe "C12_STATUS=no-proc" "an unreadable /proc was not reported as no-proc -- a cancel that cannot read /proc cannot know anything about the worker (C12)"
    if ($out -match "C12_RC=0") { $failures += "a cancel run against an unreadable /proc was reported as a success (C12)" }
    Assert-Probe "C12_MARKERS=phase=running,exit=,marker=absent" "cancellation markers were written although /proc could not be read (C12)"
    Assert-Probe "C13_STATUS=scan-failed" "a process scan that read NOT ONE /proc entry was not reported as scan-failed. This is the exact live defect: dash made the scan return nothing and the empty result was read as 'already dead' while the worker ran on (C13)"
    if ($out -match "C13_RC=0") { $failures += "a cancel whose process scan saw nothing at all was reported as a success (C13)" }
    Assert-Probe "C13_MARKERS=phase=running,exit=,marker=absent" "cancellation markers were written although the process scan saw nothing (C13)"
} else {
    $unverified += "C12/C13 (unreadable /proc, empty process scan): this shell cannot mask /proc with 'unshare --mount --map-root-user', so the fail-closed scan is covered only by the provider-level token tests"
}

Write-Host ""
Write-Host "Probe output: $flat"
Write-Host ""

if ($failures.Count -eq 0) {
    Write-Host "PASS: the emitted cancel command really stops a worker. It ran under DASH -- the shell 'aca sandbox exec' actually uses -- and killed a live worker AND its child with no pkill, pgrep or ps present; escalated SIGTERM to SIGKILL for a worker that ignored it; wrote cancelled/143 only after confirming death, and the worker could not overwrite them." -ForegroundColor Green
    Write-Host "PASS: every case it cannot prove is a FAILED cancel -- no pid file, a pid of 1, a recycled pid, a rejected kill, a process that would not die, an unreadable /proc and a process scan that saw nothing all report their own reason, leave the session's markers untouched, and never claim success." -ForegroundColor Green
    Write-Host "PASS: the pre-#36 command shape, run in the same procps-free shell, still reports success while leaving the worker running -- so this probe demonstrably distinguishes a kill from the characters of one." -ForegroundColor Green
    $unverified | ForEach-Object { Write-Host "  UNVERIFIED: $_" -ForegroundColor Yellow }
    exit 0
}

Write-Host "FAIL: the emitted cancel command does not stop the worker, or claims a success it cannot prove." -ForegroundColor Red
$failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
