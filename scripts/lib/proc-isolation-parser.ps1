# PC-1 (issue #86) -- pure log-line parser for the process-isolation probe's
# output. Contains NO reference to the Azure CLI: scripts/validate.ps1 asserts
# that statically, mirroring scripts/lib/job-drift-compare.ps1 and
# scripts/lib/rbac-drift-compare.ps1 -- the code that decides what a log
# scan MEANS must never itself be able to reach Azure.
#
# The probe (worker/lib/proc-isolation-probe.sh) emits exactly one line per
# run, in the fixed format:
#
#   SQUAD-PROC-ISO v1 same-uid-environ-readable=yes|no|unknown proc-mounted=yes|no hidepid=0|1|2|unknown uid=<n> user=<name>
#
# T11/T12 (issue #86): this file's job is entirely mechanical --
#   * no matching line anywhere in the scanned logs -> "not-yet-observed"
#     (T11): the probe has never actually run in the environment these logs
#     were read from, so there is nothing to report except that absence.
#   * a matching line -> parse its four classification fields verbatim
#     (T12): yes/no/unknown for same-uid-environ-readable, 0/1/2/unknown for
#     hidepid, exactly as the probe reported them. This file never
#     upgrades/downgrades/interprets a value -- it reports what was found.
#
# Note: intentionally no Set-StrictMode / $ErrorActionPreference here,
# matching every other dot-sourced lib in this repo.

$script:ProcIsoLinePattern = '^SQUAD-PROC-ISO v1 same-uid-environ-readable=(yes|no|unknown) proc-mounted=(yes|no|unknown) hidepid=(0|1|2|unknown) uid=(\S+) user=(\S+)\s*$'

function Get-ProcIsoObservation {
    <#
    .SYNOPSIS
        Scans log lines for the probe's output and reports what was found.

    .DESCRIPTION
        Never touches Azure, a file, or a process -- pure text in, a status
        object out. The caller (scripts/lib/proc-isolation-reader.ps1) is
        responsible for ordering $Lines so that the FIRST matching line is
        the one that should be reported: most-recent execution first, and
        within an execution's own log lines, most-recent occurrence first.
        This function reports the first match it finds and stops there.

    .PARAMETER Lines
        Raw log lines, in the caller's chosen priority order. May be empty.

    .OUTPUTS
        [pscustomobject] with:
          Observed                  bool -- was a probe line found at all
          SameUidEnvironReadable    "yes" | "no" | "unknown" | "not-yet-observed"
          ProcMounted               "yes" | "no" | "unknown" | ""
          Hidepid                   "0" | "1" | "2" | "unknown" | ""
          Uid                       string, "" if not observed
          User                      string, "" if not observed
          RawLine                   the exact matched line, "" if not observed
                                     (safe to print: the probe's own contract
                                     guarantees this line never carries a
                                     sentinel, environment value, or
                                     credential)
    #>
    param(
        [AllowNull()][string[]]$Lines = @()
    )

    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $match = [regex]::Match($trimmed, $script:ProcIsoLinePattern)
        if ($match.Success) {
            return [pscustomobject]@{
                Observed               = $true
                SameUidEnvironReadable = $match.Groups[1].Value
                ProcMounted            = $match.Groups[2].Value
                Hidepid                = $match.Groups[3].Value
                Uid                    = $match.Groups[4].Value
                User                   = $match.Groups[5].Value
                RawLine                = $trimmed
            }
        }
    }

    # T11: no matching line anywhere in what was scanned.
    return [pscustomobject]@{
        Observed               = $false
        SameUidEnvironReadable = "not-yet-observed"
        ProcMounted            = ""
        Hidepid                = ""
        Uid                    = ""
        User                   = ""
        RawLine                = ""
    }
}
