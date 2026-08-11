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
# R2 (issue #86 security revision): a scanned log line can reach this parser
# in any of THREE shapes, depending on how it was captured, and this parser
# must reduce each of them to the same content before the strict match is
# attempted:
#
#   1. Raw. worker/entrypoint.sh now calls the probe library's raw
#      squad_proc_iso_run directly (R1) -- no decoration at all. This is
#      what the reader's Azure CLI logs-show call with `--format json`'s Log
#      field actually carries once the fix ships.
#   2. JSON envelope. scripts/lib/proc-isolation-reader.ps1 (R3) requests
#      `--format json`, whose wire shape is one JSON object per scanned line,
#      e.g. {"Log":"...","TimeStamp":"..."}. This parser unwraps exactly one
#      such envelope layer, reading Log/log/Message/message (in that order,
#      first string match wins) as the actual content -- and ONLY when that
#      field's value is itself a string. A line that parses as JSON but
#      carries none of those fields (unrelated JSON, e.g. some other
#      structured log emitted by another part of the container) is treated
#      as non-matching, never as a crash and never as a false match.
#   3. Legacy-prefixed. Before this revision, worker/entrypoint.sh routed the
#      probe's line through its own log() helper, which prepends a fixed
#      "[squad-on-aca] " literal, and a log capture taken with
#      `--format text` (the format an operator may still choose; it is NOT
#      the CLI's default, which is json) prepends an ISO-8601 timestamp to
#      every line. Already-captured logs can therefore still carry either or
#      both of those, so this parser strips AT MOST ONE optional
#      leading ISO-8601 timestamp, then AT MOST ONE optional literal
#      "[squad-on-aca] " prefix -- in that order, since that is the order the
#      platform and the old log() helper actually applied them in -- before
#      attempting the match. Backward compatibility only: new output is
#      raw (case 1) and needs neither strip to match.
#
# After those reductions, the SAME full-line-anchored (^...$) strict v1
# pattern is applied as before. There is no permissive dot-star wildcard
# anywhere in this
# file: the timestamp-strip and legacy-prefix-strip patterns each match a
# fixed, bounded shape (a real ISO-8601 timestamp; the exact literal prefix),
# never an unbounded "anything before/after". A line that is mid-sentence
# prose containing the probe's text, a truncated partial line, a future
# schema version (SQUAD-PROC-ISO v2 ...), or unrelated JSON must all fail to
# match -- this is the T12 negative-fixture contract, exercised in
# scripts/validate.ps1's PC-1 section (fixture classification plus the R4
# end-to-end pass, which runs the shipped bash probe and feeds its exact
# emitted bytes through this parser).
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

# Fixed-shape, bounded strips only -- never a permissive dot-star wildcard.
# Applied at most
# once each, in this fixed order (timestamp first, legacy prefix second),
# matching the order the platform / old log() helper actually produced them.
$script:ProcIsoTimestampPrefixPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?[ \t]+'
$script:ProcIsoLegacyPrefixPattern = '^\[squad-on-aca\] '

function Get-ProcIsoUnwrappedContent {
    <#
    .SYNOPSIS
        Reduces ONE scanned log line (raw, JSON-enveloped, or
        legacy-prefixed) to the content the strict v1 pattern should be
        matched against. Never throws; a line this cannot make sense of is
        returned unchanged so the caller's strict match simply fails to find
        it -- there is no "permissive" fallback that could false-match.

    .OUTPUTS
        A [pscustomobject] with:
          Content   the reduced string to match the strict pattern against
          Skip      $true when this line was recognisably JSON but carried
                    none of Log/log/Message/message as a string -- i.e.
                    unrelated JSON that must never be matched against, even
                    accidentally, by the raw fields of its own structure.
    #>
    param([Parameter(Mandatory = $true)][string]$Trimmed)

    $content = $Trimmed
    $skip = $false

    if ($Trimmed.StartsWith("{") -and $Trimmed.EndsWith("}")) {
        $parsed = $null
        try {
            $parsed = ConvertFrom-Json -InputObject $Trimmed -ErrorAction Stop
        } catch {
            $parsed = $null
        }
        if ($null -ne $parsed) {
            $unwrapped = $null
            foreach ($fieldName in @("Log", "log", "Message", "message")) {
                if ($parsed.PSObject.Properties.Name -contains $fieldName) {
                    $fieldValue = $parsed.$fieldName
                    if ($fieldValue -is [string]) {
                        $unwrapped = $fieldValue
                        break
                    }
                }
            }
            if ($null -ne $unwrapped) {
                $content = $unwrapped.Trim()
            } else {
                # Valid JSON, but not our envelope shape at all -- unrelated
                # JSON. Never fall through to matching this object's raw text
                # representation against the strict pattern.
                return [pscustomobject]@{ Content = ""; Skip = $true }
            }
        }
        # Invalid JSON despite the brace shape: fall through and try the
        # strict match against the original trimmed text, unmodified --
        # still safe, since the strict pattern is fully anchored.
    }

    $tsMatch = [regex]::Match($content, $script:ProcIsoTimestampPrefixPattern)
    if ($tsMatch.Success) {
        $content = $content.Substring($tsMatch.Length)
    }
    $prefixMatch = [regex]::Match($content, $script:ProcIsoLegacyPrefixPattern)
    if ($prefixMatch.Success) {
        $content = $content.Substring($prefixMatch.Length)
    }

    return [pscustomobject]@{ Content = $content; Skip = $skip }
}

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
        Each line may be raw, a JSON envelope ({"Log":"...", ...} and case
        variants), or legacy-prefixed (see Get-ProcIsoUnwrappedContent).

    .OUTPUTS
        [pscustomobject] with:
          Observed                  bool -- was a probe line found at all
          SameUidEnvironReadable    "yes" | "no" | "unknown" | "not-yet-observed"
          ProcMounted               "yes" | "no" | "unknown" | ""
          Hidepid                   "0" | "1" | "2" | "unknown" | ""
          Uid                       string, "" if not observed
          User                      string, "" if not observed
          RawLine                   the exact matched (post-unwrap/strip)
                                     line, "" if not observed (safe to print:
                                     the probe's own contract guarantees this
                                     line never carries a sentinel,
                                     environment value, or credential)
    #>
    param(
        [AllowNull()][string[]]$Lines = @()
    )

    foreach ($line in @($Lines)) {
        if ($null -eq $line) { continue }
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }

        $reduced = Get-ProcIsoUnwrappedContent -Trimmed $trimmed
        if ($reduced.Skip) { continue }

        $match = [regex]::Match($reduced.Content, $script:ProcIsoLinePattern)
        if ($match.Success) {
            return [pscustomobject]@{
                Observed               = $true
                SameUidEnvironReadable = $match.Groups[1].Value
                ProcMounted            = $match.Groups[2].Value
                Hidepid                = $match.Groups[3].Value
                Uid                    = $match.Groups[4].Value
                User                   = $match.Groups[5].Value
                RawLine                = $reduced.Content.Trim()
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
