#requires -Version 5.1
<#
.SYNOPSIS
    The shell-portability contract for every command this repository sends into
    an ACA sandbox, plus the screen that enforces it.

.DESCRIPTION
    'aca sandbox exec -c <command>' runs the command under /bin/sh, and on the
    pinned class image /bin/sh is DASH, not bash. Verified on a fresh sandbox
    from that image:

        SHELL=/bin/sh
        bashism_result=[]        # $(< /tmp/t)
        posix_result=[hello]     # $(cat /tmp/t)

    '$(< file)' is the dangerous shape and the reason this file exists. Under
    dash it expands to the EMPTY STRING with no error, no diagnostic and no exit
    code -- so a command that reads a file that way does not fail, it succeeds
    with nothing. That is what shipped in the first fix for issue #36: the
    cancel's /proc scan read nothing, "nothing" was interpreted as "the worker is
    gone", and a live worker was reported as already-dead.

    Issue #40 is the generalisation. #36 closed this for the cancel command
    only. Every OTHER command the provider emits -- the launch, the poll, the
    credential-vault preparation, the log tail, and the credential file the
    launch sources -- crosses the same boundary into the same shell, and the
    behavioural probe that evaluated the launch was evaluating it under bash. A
    probe that runs the shipping artefact in the WRONG interpreter can pass while
    production fails, which is harder to notice than a missing test because the
    gate is green and looks meaningful.

    Two mechanisms live here, and they are deliberately different in kind:

      Get-SquadEmittedShellCommand  the INVENTORY. One entry per shell string the
                                    provider hands to the sandbox, produced by
                                    calling the SHIPPING generator -- never by
                                    restating the command in a test. A new
                                    emitter that is not listed here is caught by
                                    validate.ps1, which reflects over the
                                    provider's own New-Sandbox*Command functions
                                    and refuses any this inventory does not
                                    cover.

      Test-SquadShellPortability    the STATIC SCREEN. Pure text, no shell, so it
                                    runs identically on a Windows box with no WSL
                                    and cannot be skipped. It is a complement to,
                                    never a substitute for, running the command:
                                    the syntax checks (dash -n AND bash -n) and
                                    the behavioural probes under scripts/tests
                                    are what prove a command WORKS.

    WHAT THE SCREEN DOES NOT COVER. It screens the SHAPE the generators emit,
    with synthetic inputs. It says nothing about the runtime data interpolated
    into them -- a task prompt containing '$(< x)' is not a defect, because
    New-SandboxLaunchCommand single-quotes every environment value and quoting is
    the control there. Nor does it prove behaviour: a command can be perfectly
    portable and still do the wrong thing, which is exactly what issue #36 was,
    and only scripts/tests/verify-sandbox-cancel.ps1 and
    scripts/tests/verify-launch-detachment.ps1 can see that.

.NOTES
    Dot-source AFTER scripts/lib/providers/squad-sandbox-provider.ps1: the
    inventory calls that file's generators.
#>

# The bashism class that bit us, plus the neighbours most likely to be reached
# for next. Each entry names the real defect rather than the syntax -- a screen
# that says "line 1: bashism" teaches nobody why the cancel reported a live
# worker as dead.
#
# Silent = $true marks the constructs that do NOT fail under dash, and those are
# the dangerous ones. A '[[' or a here-string is a syntax error dash reports
# loudly and 'dash -n' catches before anything runs; '$(< file)' produces a
# plausible empty value and sails on.
$script:SquadShellBashisms = @(
    @{ Pattern = '\$\(\s*<';                        Silent = $true;  Why = 'command substitution of a bare redirect ($(< file)) -- under dash this expands to NOTHING, with no error and no exit code, so a read of a file silently becomes a read of the empty string. It is the exact defect that reported a live worker as already-dead in issue #36' },
    @{ Pattern = 'read\s[^;|]*-[dpaisnNu]\b';       Silent = $false; Why = 'a bash-only flag on read (-d/-p/-a/-i/-s/-n/-N/-u); dash implements -r and little else' },
    @{ Pattern = '\[\[';                            Silent = $false; Why = 'the [[ keyword, which dash does not have' },
    @{ Pattern = '\blocal\s';                       Silent = $false; Why = 'local, which is not in POSIX sh' },
    @{ Pattern = '\bfunction\s';                    Silent = $false; Why = 'the function keyword, which dash does not have' },
    @{ Pattern = '\+=';                             Silent = $false; Why = 'the += assignment, which dash does not have' },
    @{ Pattern = '<<<';                             Silent = $false; Why = 'a here-string, which dash does not have' },
    @{ Pattern = '\$\{[A-Za-z_][A-Za-z0-9_]*\[';    Silent = $true;  Why = 'an array subscript; dash has no arrays and expands the reference to the empty string rather than refusing it' },
    @{ Pattern = '[A-Za-z_][A-Za-z0-9_]*=\(';       Silent = $false; Why = 'an array assignment, which dash does not have' },
    @{ Pattern = '\$\{[A-Za-z_][A-Za-z0-9_]*\^';    Silent = $true;  Why = 'the ${var^} / ${var^^} case-modification expansion, which dash does not have' },
    @{ Pattern = '\$\{[A-Za-z_][A-Za-z0-9_]*,';     Silent = $true;  Why = 'the ${var,} / ${var,,} case-modification expansion, which dash does not have' },
    @{ Pattern = '\$\{![A-Za-z_]';                  Silent = $true;  Why = 'indirect expansion ${!var}, which dash does not have' },
    @{ Pattern = '\$\{[A-Za-z_][A-Za-z0-9_]*:\s*[0-9$]'; Silent = $true; Why = 'substring expansion ${var:offset:length}, which dash does not have. ${var:-default} and ${var:+alt} ARE portable and are deliberately not matched' },
    @{ Pattern = '<\(|>\(';                         Silent = $false; Why = 'process substitution, which dash does not have' },
    @{ Pattern = '\bdeclare\s|\btypeset\s|\bmapfile\b|\breadarray\b|\bshopt\b|\blet\s|\bselect\s'; Silent = $false; Why = 'a bash-only builtin (declare/typeset/mapfile/readarray/shopt/let/select)' },
    @{ Pattern = '\bsource\s';                      Silent = $false; Why = 'the source builtin; POSIX sh spells it "."' },
    @{ Pattern = '\becho\s+-[neE]\b';               Silent = $false; Why = 'a flag on echo, whose behaviour is not portable -- dash''s echo interprets backslash escapes and prints -n literally; use printf' },
    @{ Pattern = '&>|>&(?![0-9])|\|&';              Silent = $false; Why = 'a bash-only redirection (&>, >&word, or |&); POSIX spells it "> file 2>&1"' },
    @{ Pattern = '\$''';                            Silent = $false; Why = 'ANSI-C quoting, which dash does not have' },
    @{ Pattern = '\bexport\s+-f|\btrap\s[^;]*\bERR\b|\bwait\s+-n\b|\bpushd\b|\bpopd\b'; Silent = $false; Why = 'a bash-only construct (export -f, trap ... ERR, wait -n, pushd/popd)' },
    @{ Pattern = '\[\s[^]]*=='; Silent = $false; Why = '== inside [ ]; dash''s test builtin spells string equality with a single "=" and errors on "=="' },
    @{ Pattern = '\{[A-Za-z0-9]+\.\.[A-Za-z0-9]+(\.\.[0-9]+)?\}'; Silent = $true; Why = 'brace-range expansion ({1..9}); dash does not expand it and passes the literal braces through, so a loop or a file list silently becomes one nonsense item instead of failing' }
)

function Test-SquadShellPortability {
    <#
    .SYNOPSIS
        Screen one emitted shell command for constructs dash does not implement.

    .DESCRIPTION
        Returns a (possibly empty) array of human-readable findings. An empty
        array is NOT a proof of correctness -- see the file header. It is a proof
        that this particular class of silent failure is absent.

    .PARAMETER Command
        The exact string that will be handed to /bin/sh inside the sandbox.

    .PARAMETER Label
        How the command is named in a finding, e.g. "launch".

    .PARAMETER Shell
        "sh" (the default) screens for every bashism. "bash" screens only for the
        constructs that fail SILENTLY, because a fragment deliberately run under
        an explicit 'bash -c' may legitimately use bash syntax -- but a
        '$(< file)' inside one is still worth naming, since such a fragment is
        one edit away from a sh context, where it would read as empty rather than
        fail.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command,
        [string]$Label = "the command",
        [ValidateSet("sh", "bash")][string]$Shell = "sh"
    )

    $findings = @()
    foreach ($bashism in $script:SquadShellBashisms) {
        if ($Shell -eq "bash" -and -not $bashism.Silent) { continue }
        if ($Command -match $bashism.Pattern) {
            $findings += "the $Label command uses $($bashism.Why)"
        }
    }

    # A failed input redirection is reported by the SHELL itself, so a trailing
    # 2>/dev/null is applied too late and the error reaches the operator's
    # output. Every read of a path that can vanish must silence stderr BEFORE it
    # opens the file. (Issue #36; C1_STDERR=0 in verify-sandbox-cancel.ps1 is the
    # behavioural half of the same check.)
    foreach ($m in [regex]::Matches($Command, 'read -r [A-Za-z_]+ < ')) {
        $findings += "the $Label command opens a file for read before redirecting stderr ('$($m.Value)'), so a path that vanishes prints a shell error into the host's output"
    }

    return $findings
}

function Get-SquadEmittedShellCommand {
    <#
    .SYNOPSIS
        Every shell string this repository sends into a sandbox, produced by the
        SHIPPING generators.

    .DESCRIPTION
        One object per emitted command:

          Id         stable identifier, used in findings and in probe output keys
          Generator  the provider function that produces it, or "" for a fragment
                     with no New-Sandbox*Command generator
          Shell      "sh"   run by 'aca sandbox exec' under /bin/sh = dash
                     "bash" interpreted by an explicit 'bash -c'
          Command    the exact text
          Note       what it is, and why its shell is what it is

        Called with the generators' own defaults wherever possible, so what is
        screened is what ships. The two inputs that cannot be defaulted -- the
        launch environment and a credential token -- are synthetic placeholders,
        because the screen checks the SHAPE the generator emits and not the
        runtime data it interpolates.
    #>
    param()

    $commands = @()

    $commands += [pscustomobject]@{
        Id        = "launch"
        Generator = "New-SandboxLaunchCommand"
        Shell     = "sh"
        Command   = (New-SandboxLaunchCommand -Environment ([ordered]@{ SQUAD_SHELL_SCREEN = "1" }))
        Note      = 'the detached worker launch, run by "aca sandbox exec" under /bin/sh. Its inner wrapper is handed to an explicit "bash -c" as a single-quoted word, so dash parses that wrapper as ONE token and never interprets it -- but the wrapper text is part of this string and is screened along with it.'
    }

    $commands += [pscustomobject]@{
        Id        = "cancel"
        Generator = "New-SandboxCancelCommand"
        Shell     = "sh"
        Command   = (New-SandboxCancelCommand)
        Note      = 'the cancel script (issue #36). Strict POSIX sh: it reads /proc with the read builtin because the bare-redirect substitution read as empty under dash and a live worker was reported as already-dead.'
    }

    $commands += [pscustomobject]@{
        Id        = "poll"
        Generator = "New-SandboxPollCommand"
        Shell     = "sh"
        Command   = (New-SandboxPollCommand)
        Note      = 'the status poll -- the one command that runs on EVERY wait iteration, so a silent empty expansion here would report phase=unknown for the life of the session.'
    }

    $commands += [pscustomobject]@{
        Id        = "credential-vault"
        Generator = "New-SandboxCredentialVaultCommand"
        Shell     = "sh"
        Command   = (New-SandboxCredentialVaultCommand)
        Note      = 'prepares the 0700 directory the credential file is uploaded into and echoes back the mode it actually achieved. A silent empty expansion of that mode reads as "not 700" and refuses the upload -- fail-closed, but only by accident.'
    }

    $commands += [pscustomobject]@{
        Id        = "logs"
        Generator = "New-SandboxLogsCommand"
        Shell     = "sh"
        Command   = (New-SandboxLogsCommand)
        Note      = 'the session log tail.'
    }

    # The credential file is not an exec argument -- it is uploaded and then
    # SOURCED by the launch wrapper, so its contents are interpreted as shell
    # too. It is screened as sh even though the wrapper sourcing it is bash: its
    # own contract calls it a POSIX shell fragment, and the launch is one edit
    # away from sourcing it under dash.
    $commands += [pscustomobject]@{
        Id        = "credential-file"
        Generator = ""
        Shell     = "sh"
        Command   = (New-SandboxCredentialFileContent -Planes @(, [string[]]@("GH_TOKEN", "GITHUB_TOKEN")) -Tokens @("squad-shell-screen-placeholder"))
        Note      = 'the staged credential file, sourced by the launch wrapper. Not an argv -- but it is shell, so it is screened like one.'
    }

    return $commands
}
