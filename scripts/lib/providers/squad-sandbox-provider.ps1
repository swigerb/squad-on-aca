<#
.SYNOPSIS
    Azure Container Apps Sandboxes adapter for the Squad execution provider
    contract. Reachable ONLY when the sandbox feature flag is explicitly on.

.DESCRIPTION
    Implements create / wait / status / logs / cancel / terminate over ACA
    Sandboxes (ARM `Microsoft.App/sandboxGroups`, api-version
    2026-02-01-preview) by shelling out to the standalone `aca` binary. ACA Jobs
    remain the unconditional default and the rollback path; nothing in this file
    runs unless Test-SquadSandboxEnabled returned true.

    EVERY preview-specific detail lives behind this file. Callers hold opaque
    handles and never learn that a sandbox exists.

    ------------------------------------------------------------------------
    Why the session is launched DETACHED and driven by POLLING
    ------------------------------------------------------------------------
    `aca sandbox exec` has a hard client-side timeout of roughly 120 seconds,
    constant regardless of how long the remote command actually needs. It fails
    with "Network issue - retry policy expired" while the sandbox itself is
    completely unharmed and the remote work keeps running. A Squad session runs
    for 10-60 minutes, so a session can NEVER be a single synchronous exec.

    So `create` launches the worker with
    `setsid nohup bash -c "..." </dev/null >/dev/null 2>&1 &` -- redirecting
    stdin and BOTH output streams is what lets the exec call return at once --
    and `status` polls short execs that read a marker file and a recorded exit
    code. Terminal state comes from the completion marker PLUS the recorded exit
    code, never from an exec's own exit status: an exec that returns non-zero
    tells you about the transport, not about the session.

    A transport timeout mid-poll is therefore INCONCLUSIVE, never a failure. The
    work is almost certainly still running; the caller re-polls.

    ------------------------------------------------------------------------
    Security invariants enforced here (all live-verified as achievable)
    ------------------------------------------------------------------------
    1. The sandbox group MUST have no managed identity. Managed identity on ACA
       Sandboxes is group-scoped and reachable from inside the sandbox, so an
       identity on the group hands control-plane credentials to the code being
       run. `create` asserts `identity` is absent on the ARM resource and fails
       closed if it cannot prove that. `--identity` is never passed when
       creating a group or a disk -- private ACR pull uses an ACR refresh token
       instead -- and Assert-SandboxArgvIdentityFree rejects the flag defensively
       on every argv this file builds.
    2. Default-deny egress plus the class's allowlist is applied BEFORE any
       repository code runs. If the policy cannot be applied the worker is never
       launched and the sandbox is torn down.
    3. Tokens, egress policy values, and raw manifest values are never logged.
       Argv is redacted before it reaches an error message, and captured output
       is scrubbed of every known secret value.
    4. Only administrator-approved classes from config/sandbox-classes.json may
       be used. The class is resolved by the caller through
       Get-SquadSandboxClass, which enforces approval; nothing here accepts an
       image reference from a repository.
    5. terminate is idempotent -- already-deleted is success -- but idempotent is
       not "ignore every failure". Auth, RBAC, throttling and network failures
       say nothing about the sandbox and must surface, classified by the SAME
       Test-AcaJobExecutionGone the ACA Job adapter uses.
    6. Results durability: the worker pushes to GitHub as part of its own run,
       and the completion marker is written only after the worker process exits,
       so a caller that waits for terminal status has the push already done. The
       sandbox disk is scratch and never the sole copy.
#>

# Note: intentionally no Set-StrictMode / $ErrorActionPreference here.

$script:SandboxProviderId = "sandbox"

# ARM api-version for Microsoft.App/sandboxGroups. The GROUP is the only part of
# ACA Sandboxes that is ARM-reachable; the sandbox data plane lives on
# management.{region}.azuredevcompute.io and is driven by the `aca` binary.
$script:SquadSandboxApiVersion = "2026-02-01-preview"

# Scratch directory inside the sandbox holding the completion marker, the
# recorded exit code, the phase file and the session log. /tmp is world-writable,
# so this works for the image's unprivileged `squad` user without any chown. It
# is scratch by design: durable results go to GitHub, never here.
$script:SandboxStateDir = "/tmp/squad-session"

# Entry point of the squad-worker image. The unmodified image boots as a sandbox.
$script:SandboxWorkerEntrypoint = "/usr/local/bin/squad-on-aca"

# Auto-suspend defaults to ENABLED at 600s. That is short enough to suspend a
# real session between polls, so it is always set explicitly and the poll
# interval is kept well under it.
$script:SandboxDefaultIdleTimeoutSeconds = 1800
$script:SandboxDefaultPollSeconds = 20

# The `aca` client gives up on an exec after ~120s no matter what the remote
# command is doing. Any poll command must finish far inside that.
$script:SandboxExecClientTimeoutSeconds = 120

# Transport failures. These say nothing about the session, so they are
# INCONCLUSIVE for status (re-poll) and a hard error for terminate (we cannot
# claim we tore anything down).
$script:SandboxInconclusivePatterns = @(
    "retry policy expired",
    "Network issue",
    "connection reset",
    "connection aborted",
    "read timed out",
    "operation timed out",
    "temporary failure in name resolution",
    "EOF occurred in violation of protocol"
)

# Flags whose VALUE must never reach a log, an error message, or a test capture:
# credentials, the egress policy (readable egress rules are risk R2 in ADR 0001),
# and the exec command line (which carries session environment).
$script:SandboxRedactedFlags = @(
    "--token", "--password", "--secret",
    "--rule", "--default", "--traffic-inspection",
    "-c", "--command"
)

# ---------------------------------------------------------------------------
# Binary resolution
# ---------------------------------------------------------------------------

function Resolve-SandboxCliPath {
    <#
    .SYNOPSIS
        Locate the standalone `aca` binary.

    .DESCRIPTION
        Overridable so tests can put a stub in front of it without touching the
        developer's real installation. Resolution order:

          1. an explicit -Override (provider construction option),
          2. $env:SQUAD_ACA_SANDBOX_CLI,
          3. `aca` on PATH,
          4. the installer's default location (~/.aca/bin/aca.exe).

        When nothing resolves this returns the bare name so Invoke-CliSafe
        reports exit 127 ("could not be run at all") rather than this function
        inventing a different failure shape.
    #>
    param([string]$Override = "")

    if ($Override) { return $Override }
    if ($env:SQUAD_ACA_SANDBOX_CLI) { return $env:SQUAD_ACA_SANDBOX_CLI }
    $onPath = Get-Command "aca" -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $installed = Join-Path ([string]$HOME) ".aca\bin\aca.exe"
    if ($installed -and (Test-Path $installed)) { return $installed }
    return "aca"
}

# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------

function Get-SandboxSafeArgv {
    <#
    .SYNOPSIS
        Render an argv for human consumption with every sensitive VALUE removed.

    .DESCRIPTION
        The only argv rendering this provider is allowed to emit. A flag in
        $script:SandboxRedactedFlags keeps its name -- so an error still says
        which call failed -- and loses its value. That covers credentials, the
        egress policy (ADR 0001 risk R2: egress rule values must never be
        logged) and the exec command line.
    #>
    param([string[]]$Argv = @())

    $parts = @()
    $redactNext = $false
    foreach ($arg in @($Argv)) {
        $text = [string]$arg
        if ($redactNext) {
            $parts += "<redacted>"
            $redactNext = $false
            continue
        }
        if ($script:SandboxRedactedFlags -contains $text) {
            $parts += $text
            $redactNext = $true
            continue
        }
        # --flag=value form.
        if ($text -match "^(--[A-Za-z0-9-]+)=") {
            if ($script:SandboxRedactedFlags -contains $Matches[1]) {
                $parts += "$($Matches[1])=<redacted>"
                continue
            }
        }
        $parts += $text
    }
    return ($parts -join " ")
}

function Protect-SandboxText {
    <#
    .SYNOPSIS
        Scrub known secret values out of captured output before it is shown.

    .DESCRIPTION
        Defence in depth behind Get-SandboxSafeArgv: a CLI can echo a value back
        in its own error text. Every non-trivial secret the provider was given is
        replaced wherever it appears.

        The length floor must NOT be written `[string]$secret.Length -lt 8`.
        Member access binds tighter than the cast, so that is
        `[string]($secret.Length)` and PowerShell then coerces the right operand
        to the left operand's type -- a LEXICAL comparison. `"40" -lt "8"` is
        $true, so a 40-character PAT, a 36-character GUID and a 1200-character
        JWT were all skipped and passed through verbatim; only lengths 8, 9 and
        80-99 were ever scrubbed.
    #>
    param(
        [AllowEmptyString()][string]$Text = "",
        [string[]]$Secrets = @()
    )

    $result = [string]$Text
    foreach ($secret in @($Secrets)) {
        if (-not $secret) { continue }
        if ($secret.Length -lt 8) { continue }
        $result = $result.Replace([string]$secret, "<redacted>")
    }
    return $result
}

function Get-SandboxErrorText {
    <#
    .SYNOPSIS
        Bounded, scrubbed error text from an Invoke-CliSafe result.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [string[]]$Secrets = @(),
        [string]$Fallback = "no error output"
    )

    $text = (@($Result.StdErr) + @($Result.StdOut) | Where-Object { $_ -and $_.Trim() }) -join " "
    $text = (Protect-SandboxText -Text $text -Secrets $Secrets).Trim()
    if (-not $text) { return $Fallback }
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + "..." }
    return $text
}

# ---------------------------------------------------------------------------
# Invocation
# ---------------------------------------------------------------------------

function Assert-SandboxArgvIdentityFree {
    <#
    .SYNOPSIS
        Refuse to issue any `aca` command that attaches a managed identity.

    .DESCRIPTION
        Invariant 4 of PRD #6 holds only while the sandbox group has no managed
        identity (ADR 0001, G3/R1): identity is group-scoped and the token
        endpoint is reachable from inside every sandbox in the group. Private
        ACR pull needs an ACR refresh token, not an identity, so nothing this
        provider does has a legitimate reason to pass `--identity`.

        This is a defensive check, not the primary control -- the primary
        control is Assert-SandboxGroupIdentityFree, which inspects the live
        resource. This one makes a future edit that adds the flag fail loudly.
    #>
    param([string[]]$Argv = @())

    foreach ($arg in @($Argv)) {
        $text = [string]$arg
        if ($text -eq "--identity" -or $text -like "--identity=*" -or $text -eq "--mi-user-assigned" -or $text -eq "--system-assigned") {
            throw "Refusing to run 'aca' with '$text': a managed identity on the sandbox group is reachable from inside every sandbox in it (PRD #6 invariant 4, ADR 0001 risk R1)."
        }
    }
}

function Invoke-SandboxCli {
    <#
    .SYNOPSIS
        Run one `aca` command through the shared Invoke-CliSafe mechanism.

    .DESCRIPTION
        The SAME mechanism the ACA Job adapter uses for `az` -- one
        implementation, so the exit code is always the one this call produced
        and a missing binary reports 127 instead of a stale $LASTEXITCODE.

        Nothing is written to the pipeline or the host here. The caller decides
        what a non-zero exit means and what (redacted) text a user sees.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string[]]$Argv
    )

    Assert-SandboxArgvIdentityFree -Argv $Argv
    $result = Invoke-CliSafe -FilePath $Context.AcaPath -Arguments $Argv
    Add-Member -InputObject $result -MemberType NoteProperty -Name SafeArgv -Value (Get-SandboxSafeArgv -Argv $Argv) -Force
    return $result
}

function Test-SandboxTransportInconclusive {
    <#
    .SYNOPSIS
        Did this failure tell us nothing about the sandbox?

    .DESCRIPTION
        `aca sandbox exec` gives up after ~120s with
        "Network issue - retry policy expired" while the remote command carries
        on running. Reading that as a session failure would report a healthy
        60-minute run as failed at the two-minute mark. It is INCONCLUSIVE:
        status re-polls, and terminate refuses to claim a teardown happened.
    #>
    param([Parameter(Mandatory = $true)][object]$Result)

    if ($Result.ExitCode -eq 0) { return $false }
    $text = (@($Result.StdErr) + @($Result.StdOut) | Where-Object { $_ }) -join " "
    foreach ($pattern in $script:SandboxInconclusivePatterns) {
        if ($text -match [regex]::Escape($pattern)) { return $true }
    }
    return $false
}

function Test-SandboxGone {
    <#
    .SYNOPSIS
        Decide whether a failed `aca sandbox delete` means "there was nothing
        left to delete".

    .DESCRIPTION
        Deliberately delegates the text classification to
        Test-AcaJobExecutionGone -- the deny-list-first, fail-closed classifier
        security established for the ACA Job adapter. A second classifier would
        drift from it, and drift here means reporting a false teardown.

        Two sandbox-specific adjustments, both narrowing:

          * a transport-inconclusive failure is never "gone",
          * Azure CLI's exit-code-3 == ResourceNotFoundError rule does NOT apply
            to `aca`, which documents no such convention, so the exit code is
            neutralised before delegating and only the message text decides.
    #>
    param([Parameter(Mandatory = $true)][object]$Result)

    if ($Result.ExitCode -eq 127 -or $Result.ExitCode -eq -1) { return $false }
    if (Test-SandboxTransportInconclusive -Result $Result) { return $false }

    $textOnly = [pscustomobject]@{
        ExitCode = 1
        StdOut   = @($Result.StdOut)
        StdErr   = @($Result.StdErr)
    }
    return (Test-AcaJobExecutionGone -Result $textOnly)
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

function New-SandboxLabelName {
    <#
    .SYNOPSIS
        Build the sandbox's `name` label from the session id.

    .DESCRIPTION
        Every sandbox carries the session id in its label, so a reaper can find
        orphans with `aca sandbox list` after an abnormal exit (ADR 0001 risk
        R7). The `squad-` prefix is what makes "sandboxes this control plane
        owns" a decidable question.

        The session id is sanitised, not trusted: it can come from a CLI flag,
        and it lands in a shell command line.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId)

    $clean = ($SessionId.ToLowerInvariant() -replace "[^a-z0-9-]", "-").Trim("-")
    while ($clean -match "--") { $clean = $clean -replace "--", "-" }
    if (-not $clean) { $clean = "session" }
    if ($clean.Length -gt 40) { $clean = $clean.Substring(0, 40).Trim("-") }
    return "squad-$clean"
}

function Get-SandboxSessionIdFromLabel {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Label)
    if ($Label -like "squad-*") { return $Label.Substring(6) }
    return ""
}

function New-SandboxExecutionHandle {
    <#
    .SYNOPSIS
        PROVIDER-INTERNAL. Mints the opaque handle for one sandbox session.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId,
        [AllowEmptyString()][string]$ClassId = "",
        [AllowEmptyString()][string]$SandboxGroup = ""
    )
    return New-SquadExecutionHandle -ProviderId $script:SandboxProviderId -Payload ([ordered]@{
        name    = $SandboxName
        session = $SessionId
        class   = $ClassId
        group   = $SandboxGroup
    })
}

function Resolve-SandboxHandlePayload {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Handle)
    $decoded = ConvertFrom-SquadExecutionHandle -Handle $Handle -ExpectedProviderId $script:SandboxProviderId
    if (-not $decoded.Payload.name) { throw "'$Handle' is not a valid Squad execution handle." }
    return $decoded.Payload
}

# ---------------------------------------------------------------------------
# Identity assertion (invariant 4)
# ---------------------------------------------------------------------------

function Assert-SandboxGroupIdentityFree {
    <#
    .SYNOPSIS
        Fail closed unless the sandbox group provably has NO managed identity.

    .DESCRIPTION
        The group is the only part of ACA Sandboxes that is ARM-reachable, so
        this is an `az resource show` against
        Microsoft.App/sandboxGroups (2026-02-01-preview) -- the same shape the
        feasibility work used to record "the ARM resource has no identity
        property" (ADR 0001, G3).

        Fail-closed means: an `az` failure, a missing `az`, or output we cannot
        parse all raise. "I could not check" must never read as "there is no
        identity"; that is precisely the reading that would hand a token
        endpoint to the code being run.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Context
    )

    if (-not $Context.SubscriptionId -or -not $Context.ResourceGroup -or -not $Context.SandboxGroup) {
        throw "Cannot verify that sandbox group '$($Context.SandboxGroup)' is identity-free: subscription, resource group and group name are all required. Refusing to create a sandbox (PRD #6 invariant 4)."
    }

    $armId = "/subscriptions/$($Context.SubscriptionId)/resourceGroups/$($Context.ResourceGroup)/providers/Microsoft.App/sandboxGroups/$($Context.SandboxGroup)"
    $result = Invoke-AzPromptSafe -AzArgs @(
        "resource", "show",
        "--ids", $armId,
        "--api-version", $script:SquadSandboxApiVersion,
        "--query", "identity",
        "-o", "json",
        "--only-show-errors"
    )

    if ($result.ExitCode -ne 0) {
        throw "Could not verify that sandbox group '$($Context.SandboxGroup)' is identity-free ('az resource show' exit $($result.ExitCode)): $(Get-SandboxErrorText -Result $result -Secrets $Context.Secrets). Refusing to create a sandbox (PRD #6 invariant 4)."
    }

    $raw = (@($result.StdOut) -join "`n").Trim()
    if (-not $raw -or $raw -eq "null" -or $raw -eq "{}") {
        return $true
    }

    $identity = $null
    try {
        $identity = $raw | ConvertFrom-Json
    } catch {
        throw "Could not verify that sandbox group '$($Context.SandboxGroup)' is identity-free: 'az resource show' returned output that is not valid JSON. Refusing to create a sandbox (PRD #6 invariant 4)."
    }
    if ($null -eq $identity) { return $true }

    $type = ""
    if ($identity.PSObject.Properties.Name -contains "type") { $type = [string]$identity.type }
    $hasPrincipal = ($identity.PSObject.Properties.Name -contains "principalId") -and $identity.principalId
    $hasAssigned = ($identity.PSObject.Properties.Name -contains "userAssignedIdentities") -and $identity.userAssignedIdentities

    if ((-not $type -or $type -eq "None") -and -not $hasPrincipal -and -not $hasAssigned) {
        return $true
    }

    throw "Sandbox group '$($Context.SandboxGroup)' has a managed identity (type '$type'). Managed identity on ACA Sandboxes is group-scoped and its token endpoint is reachable from inside every sandbox in the group, so control-plane credentials would be available to the code being run. Refusing to create a sandbox (PRD #6 invariant 4, ADR 0001 risk R1). Use a dedicated identity-free group."
}

# ---------------------------------------------------------------------------
# Disks
# ---------------------------------------------------------------------------

function Resolve-SandboxDiskId {
    <#
    .SYNOPSIS
        Turn a disk LABEL into the GUID `aca sandbox create` actually needs.

    .DESCRIPTION
        `--disk` accepts PUBLIC images only. A disk built from a private
        registry must be referenced by `--disk-id <GUID>`, and the `--name`
        given at `disk create` time is a LABEL, not a resolvable name -- so the
        id has to come from `disk list -o json`. Getting this wrong looks like a
        pull failure much later.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$DiskLabel
    )

    $result = Invoke-SandboxCli -Context $Context -Argv @("sandboxgroup", "disk", "list", "-o", "json")
    if ($result.ExitCode -ne 0) {
        throw "Could not list sandbox disks ('aca sandboxgroup disk list' exit $($result.ExitCode)): $(Get-SandboxErrorText -Result $result -Secrets $Context.Secrets)"
    }

    $raw = (@($result.StdOut) -join "`n").Trim()
    $disks = @()
    if ($raw) {
        try {
            foreach ($item in @($raw | ConvertFrom-Json)) {
                if ($null -ne $item) { $disks += $item }
            }
        } catch {
            throw "Could not list sandbox disks: 'aca sandboxgroup disk list' returned output that is not valid JSON."
        }
    }

    foreach ($disk in $disks) {
        $names = @()
        foreach ($property in @("name", "label", "displayName")) {
            if ($disk.PSObject.Properties.Name -contains $property) { $names += [string]$disk.$property }
        }
        if ($names -contains $DiskLabel) {
            foreach ($property in @("id", "diskId")) {
                if (($disk.PSObject.Properties.Name -contains $property) -and $disk.$property) {
                    return [string]$disk.$property
                }
            }
        }
    }

    throw "No sandbox disk labelled '$DiskLabel' was found. Disk labels are not resolvable names: create the disk with 'aca sandboxgroup disk create' and take its id from 'aca sandboxgroup disk list -o json'."
}

function New-SquadSandboxDisk {
    <#
    .SYNOPSIS
        ADMINISTRATOR helper: build a sandbox disk from a private ACR image.

    .DESCRIPTION
        Not part of the per-session path -- a disk is provisioned once by an
        administrator. It lives here because it is the one other place that must
        never attach an identity: private ACR pull works with the null GUID
        username and an ACR refresh token, which is what keeps invariant 4
        intact. Do NOT "simplify" this by attaching a user-assigned identity.

        The token is never logged: Get-SandboxSafeArgv redacts `--token`, and it
        is registered as a scrubbed secret for the duration of the call.

        Note also that `az acr login --expose-token` silently switches the active
        `az` subscription, which later surfaces as an unrelated-looking 403 from
        `aca`. Re-assert `az account set` after obtaining the token.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RegistryToken,
        [string]$RegistryUsername = "00000000-0000-0000-0000-000000000000"
    )

    $scoped = $Context.PSObject.Copy()
    $scoped.Secrets = @($Context.Secrets) + @($RegistryToken)

    $result = Invoke-SandboxCli -Context $scoped -Argv @(
        "sandboxgroup", "disk", "create",
        "--image", $Image,
        "--name", $Label,
        "--username", $RegistryUsername,
        "--token", $RegistryToken
    )
    if ($result.ExitCode -ne 0) {
        throw "Could not create sandbox disk '$Label' ($($result.SafeArgv), exit $($result.ExitCode)): $(Get-SandboxErrorText -Result $result -Secrets $scoped.Secrets)"
    }
    return $true
}

# ---------------------------------------------------------------------------
# Command construction
# ---------------------------------------------------------------------------

function ConvertTo-SandboxShellSingleQuoted {
    <#
    .SYNOPSIS
        POSIX single-quote a value for the remote shell.
    #>
    param([AllowEmptyString()][string]$Value = "")
    return "'" + ([string]$Value).Replace("'", "'\''") + "'"
}

function New-SandboxWorkerEnvironment {
    <#
    .SYNOPSIS
        The environment the worker entrypoint reads, built from the
        provider-neutral dispatch request.

    .DESCRIPTION
        Exactly the variables worker/entrypoint.sh consumes. Nothing here comes
        from a repository manifest: a manifest can only REQUEST capabilities,
        and everything grantable comes from the administrator catalog.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Request,
        [Parameter(Mandatory = $true)][object]$Context
    )

    $prefs = $Request.executionPreferences
    $vars = [ordered]@{
        SESSION_NAME      = [string]$Request.sessionId
        GITHUB_REPOSITORY = [string]$Request.repository.fullName
        SQUAD_MODE        = [string]$prefs.mode
        PUSH_CHANGES      = $(if ($prefs.pushChanges) { "true" } else { "false" })
        OUTPUT_BRANCH     = [string]$Request.git.outputBranch
        GIT_CLONE_DEPTH   = [string]$Request.repository.cloneDepth
        RUN_COPILOT_SMOKE = $(if ($prefs.runCopilotSmoke) { "true" } else { "false" })
        SQUAD_EXECUTION_MODE = "sandbox"
    }
    if ($Request.repository.ref) { $vars["GITHUB_REF"] = [string]$Request.repository.ref }
    if ($prefs.subSquad) { $vars["SQUAD_SUB_SQUAD"] = [string]$prefs.subSquad }
    if ($Request.task.prompt) { $vars["SQUAD_PROMPT"] = [string]$Request.task.prompt }

    # Credential delivery is deliberately minimal here: PRD #6 Sprint 7 owns
    # credential brokerage. Whatever the operator supplied is passed through and
    # is a registered secret, so it can never reach an error message or a log.
    foreach ($name in @("GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN")) {
        if ($Context.WorkerSecrets -and $Context.WorkerSecrets.Contains($name) -and $Context.WorkerSecrets[$name]) {
            $vars[$name] = [string]$Context.WorkerSecrets[$name]
        }
    }

    return $vars
}

function New-SandboxLaunchCommand {
    <#
    .SYNOPSIS
        Build the DETACHED launch command (see the file header for why).

    .DESCRIPTION
        Shape that was proven to work: `setsid nohup bash -c "..." </dev/null
        >/dev/null 2>&1 &`. Redirecting stdin AND both output streams is what
        lets `aca sandbox exec` return immediately instead of holding the
        connection open until its ~120s client timeout kills it.

        WHERE THE `&` GOES IS THE WHOLE POINT. In POSIX/bash grammar `&` is a
        list terminator with LOWER precedence than `&&`, so

            prelude && setsid nohup bash -c '...' </dev/null >/dev/null 2>&1 &

        backgrounds the ENTIRE and-list, and the three redirections bind only to
        the last simple command in it. The async subshell keeps the exec's own
        fd 0/1/2 open for the whole worker run, so the launching exec blocks,
        hits the ~120s timeout, and `create` tears a healthy session down two
        minutes in -- the exact failure this design exists to prevent. Proven:

            bash -c "true && sleep 5 >/dev/null 2>&1 & echo x"   -> blocks 5s
            bash -c "true;   sleep 5 >/dev/null 2>&1 & echo x"   -> returns

        The launch is therefore wrapped in a brace group, `{ ... & }`, so the
        `&` terminates a list containing only the redirected `setsid` command.
        The group is a compound command with exit status 0, which keeps the
        whole line a single `&&` chain: the prelude runs SYNCHRONOUSLY and gates
        the launch (a sandbox whose state directory could not be created never
        starts a worker and never prints `squad-launched`), `phase=running` is
        written after the fork rather than racing an async `mkdir`, and the
        `rm -f` of the previous run's terminal files is ordered before any poll.

        The wrapper records terminal state so a poll never has to infer it:

          worker runs (its own run includes the git push)
            -> exit code written to <state>/exit-code
            -> phase written
            -> completion marker touched LAST

        Order matters twice. The push happens inside the worker's own run, so it
        is complete before the marker exists -- a caller that waits for terminal
        status has its results in GitHub already (invariant 9). And the marker is
        touched after the exit code is written, so "marker present" can never be
        read as terminal while the exit code is still missing.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment,
        [string]$StateDir = $script:SandboxStateDir,
        [string]$Entrypoint = $script:SandboxWorkerEntrypoint
    )

    $assignments = @()
    foreach ($name in $Environment.Keys) {
        if ($name -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") {
            throw "Refusing to launch the worker: '$name' is not a valid environment variable name."
        }
        $assignments += "$name=$(ConvertTo-SandboxShellSingleQuoted ([string]$Environment[$name]))"
    }

    $inner = "env " + ($assignments -join " ") + " $Entrypoint >> $StateDir/session.log 2>&1; " +
             "printf %s `$? > $StateDir/exit-code; " +
             "printf %s done > $StateDir/phase; " +
             "touch $StateDir/done"

    $prelude = "mkdir -p $StateDir && rm -f $StateDir/done $StateDir/exit-code && printf %s starting > $StateDir/phase"
    # `{ ... & }`: the `&` terminates a list containing only the redirected
    # `setsid`, so exactly that command is backgrounded with its fds on
    # /dev/null. The group returns 0 immediately, keeping the `&&` chain intact.
    $detach = "{ setsid nohup bash -c $(ConvertTo-SandboxShellSingleQuoted $inner) </dev/null >/dev/null 2>&1 & }"

    return "$prelude && $detach && printf %s running > $StateDir/phase && echo squad-launched"
}

function New-SandboxPollCommand {
    <#
    .SYNOPSIS
        The short exec a poll runs. Must finish far inside the client timeout.

    .DESCRIPTION
        Deliberately free of double quotes. The values it reads are single
        tokens, so nothing needs quoting, and keeping the command
        double-quote-free means it survives every layer it passes through --
        PowerShell native-argument quoting, the remote shell, and (in the
        offline tests) cmd.exe's argument parser -- without escaping games that
        would make the argv under test differ from the argv that ships.
    #>
    param([string]$StateDir = $script:SandboxStateDir)

    return "p=`$(cat $StateDir/phase 2>/dev/null || echo unknown); " +
           "e=`$(cat $StateDir/exit-code 2>/dev/null || echo none); " +
           "m=absent; [ -f $StateDir/done ] && m=done; " +
           "echo phase=`$p; echo exit=`$e; echo marker=`$m"
}

function ConvertFrom-SandboxPollOutput {
    <#
    .SYNOPSIS
        Turn a poll's stdout into a provider-neutral execution state.

    .DESCRIPTION
        THE rule of the whole execution model: terminal state requires the
        completion MARKER **and** a recorded exit code. Neither alone is enough.

          * The exec's own exit status is irrelevant -- it reports the
            transport, not the session.
          * A marker with no recorded exit code is Unknown, not Succeeded. That
            combination means the wrapper was interrupted between the two
            writes, and guessing "success" there would report an aborted session
            as a clean one.
    #>
    param([string[]]$Lines = @())

    $phase = "unknown"
    $exit = "none"
    $marker = "absent"
    foreach ($line in @($Lines)) {
        $text = ([string]$line).Trim()
        if ($text -match "^phase=(.*)$") { $phase = $Matches[1].Trim() }
        elseif ($text -match "^exit=(.*)$") { $exit = $Matches[1].Trim() }
        elseif ($text -match "^marker=(.*)$") { $marker = $Matches[1].Trim() }
    }

    $exitCode = $null
    if ($exit -and $exit -ne "none" -and $exit -match "^\d+$") { $exitCode = [int]$exit }

    $status = "Provisioning"
    if ($marker -eq "done") {
        if ($null -eq $exitCode) {
            $status = "Unknown"
        } elseif ($exitCode -eq 0) {
            $status = "Succeeded"
        } elseif ($phase -eq "cancelled") {
            $status = "Cancelled"
        } else {
            $status = "Failed"
        }
    } elseif ($phase -eq "running" -or $phase -eq "starting") {
        $status = "Running"
    }

    return [pscustomobject]@{
        Status   = $status
        Phase    = $phase
        ExitCode = $exitCode
        Marker   = $marker
    }
}

function ConvertTo-SandboxExecutionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Handle,
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][object]$State,
        [bool]$Inconclusive = $false
    )

    $display = [pscustomobject]@{
        Sandbox      = [string]$Payload.name
        Status       = [string]$State.Status
        Session      = [string]$Payload.session
        Class        = [string]$Payload.class
        Phase        = [string]$State.Phase
        ExitCode     = $State.ExitCode
        Inconclusive = $Inconclusive
    }
    $record = New-SquadExecutionRecord -Handle $Handle -Status ([string]$State.Status) -Display $display
    Add-Member -InputObject $record -MemberType NoteProperty -Name Inconclusive -Value $Inconclusive -Force
    return $record
}

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

function New-SandboxExecutionProvider {
    <#
    .SYNOPSIS
        Constructs the ACA Sandboxes provider.

    .PARAMETER Class
        An APPROVED class object from config/sandbox-classes.json, already
        validated by Get-SquadSandboxClass. This provider never resolves a class
        itself and never accepts an image reference from a repository.

    .PARAMETER AcaCliPath
        Overrides `aca` resolution so tests can stub the binary.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Class,
        [object]$Config = $null,
        [string]$SandboxGroup = "",
        [string]$ResourceGroup = "",
        [string]$SubscriptionId = "",
        [string]$DiskId = "",
        [string]$DiskLabel = "",
        [string]$AcaCliPath = "",
        [int]$IdleTimeoutSeconds = 0,
        [int]$PollSeconds = 0,
        [System.Collections.IDictionary]$WorkerSecrets = @{},
        [string]$ScriptDir = ""
    )

    if (-not $Class) { throw "The Sandboxes provider requires an approved sandbox class." }
    if ($Class.approved -ne $true) {
        throw "Sandbox class '$($Class.id)' is not approved. Only administrator-approved classes from config/sandbox-classes.json may be used."
    }

    if ($Config) {
        if (-not $SandboxGroup -and ($Config.PSObject.Properties.Name -contains "sandboxGroup")) { $SandboxGroup = [string]$Config.sandboxGroup }
        if (-not $ResourceGroup -and ($Config.PSObject.Properties.Name -contains "resourceGroup")) { $ResourceGroup = [string]$Config.resourceGroup }
        if (-not $SubscriptionId -and ($Config.PSObject.Properties.Name -contains "subscriptionId")) { $SubscriptionId = [string]$Config.subscriptionId }
        if (-not $DiskId -and ($Config.PSObject.Properties.Name -contains "sandboxDiskId")) { $DiskId = [string]$Config.sandboxDiskId }
        if (-not $DiskLabel -and ($Config.PSObject.Properties.Name -contains "sandboxDiskLabel")) { $DiskLabel = [string]$Config.sandboxDiskLabel }
    }

    if ($IdleTimeoutSeconds -le 0) { $IdleTimeoutSeconds = $script:SandboxDefaultIdleTimeoutSeconds }
    if ($PollSeconds -le 0) { $PollSeconds = $script:SandboxDefaultPollSeconds }
    # Auto-suspend fires on idle. Polling less often than the idle timeout would
    # let a live session be suspended between two polls.
    if ($PollSeconds -ge $IdleTimeoutSeconds) {
        throw "Sandbox poll interval (${PollSeconds}s) must be well under the idle timeout (${IdleTimeoutSeconds}s), or auto-suspend can fire between polls."
    }

    $secrets = @()
    foreach ($key in @($WorkerSecrets.Keys)) {
        if ($WorkerSecrets[$key]) { $secrets += [string]$WorkerSecrets[$key] }
    }

    $context = [pscustomobject]@{
        AcaPath            = (Resolve-SandboxCliPath -Override $AcaCliPath)
        Config             = $Config
        Class              = $Class
        SandboxGroup       = $SandboxGroup
        ResourceGroup      = $ResourceGroup
        SubscriptionId     = $SubscriptionId
        DiskId             = $DiskId
        DiskLabel          = $DiskLabel
        IdleTimeoutSeconds = $IdleTimeoutSeconds
        PollSeconds        = $PollSeconds
        WorkerSecrets      = $WorkerSecrets
        Secrets            = $secrets
        ScriptDir          = $ScriptDir
        StateDir           = $script:SandboxStateDir
    }

    $operations = [ordered]@{}

    # -- create --------------------------------------------------------------
    # Ordering is a security control, not a style choice:
    #   1. prove the group is identity-free  (invariant 4)
    #   2. create the sandbox
    #   3. apply default-deny egress          (invariant 3)
    #   4. pin auto-suspend
    #   5. launch the worker DETACHED         <- the first repository code to run
    # Any failure before step 5 tears the sandbox down and throws, so repository
    # code can never run in a sandbox whose egress policy was not applied.
    $operations["create"] = {
        param($Context, $Arguments)

        $request = $Arguments["Request"]
        if (-not $request) { throw "The Sandboxes provider requires a dispatch request." }

        Assert-SandboxGroupIdentityFree -Context $Context | Out-Null

        $diskId = $Context.DiskId
        if (-not $diskId) {
            if (-not $Context.DiskLabel) {
                throw "No sandbox disk configured. Set a disk id (or a disk label to resolve) before dispatching to a sandbox; '--disk' accepts public images only, so a private image needs '--disk-id <GUID>'."
            }
            $diskId = Resolve-SandboxDiskId -Context $Context -DiskLabel $Context.DiskLabel
        }

        $name = New-SandboxLabelName -SessionId ([string]$request.sessionId)
        $class = $Context.Class
        $cpu = [int]([math]::Max(1, [double]$class.resources.cpu))
        $memory = [int]([math]::Max(1, [double]$class.resources.memoryGi))

        $created = Invoke-SandboxCli -Context $Context -Argv @(
            "sandbox", "create",
            "--disk-id", $diskId,
            "--label", "name=$name",
            "--cpu", "$($cpu * 1000)m",
            "--memory", "$($memory * 1024)Mi"
        )
        if ($created.ExitCode -ne 0) {
            throw "Could not create sandbox '$name' ($($created.SafeArgv), exit $($created.ExitCode)): $(Get-SandboxErrorText -Result $created -Secrets $Context.Secrets)"
        }

        $handle = New-SandboxExecutionHandle -SandboxName $name -SessionId ([string]$request.sessionId) `
            -ClassId ([string]$class.id) -SandboxGroup ([string]$Context.SandboxGroup)

        try {
            # --- egress FIRST, before anything from the repository runs ------
            $egressArgv = @("sandbox", "egress", "set", "-l", "name=$name",
                "--default", [string]$class.egress.defaultAction)
            foreach ($rule in @($class.egress.hostRules)) {
                $egressArgv += @("--rule", "$($rule.pattern):$($rule.action)")
            }
            $egressArgv += @("--traffic-inspection", [string]$class.egress.trafficInspection)

            $egress = Invoke-SandboxCli -Context $Context -Argv $egressArgv
            if ($egress.ExitCode -ne 0) {
                throw "Could not apply the egress policy to sandbox '$name' ($($egress.SafeArgv), exit $($egress.ExitCode)): $(Get-SandboxErrorText -Result $egress -Secrets $Context.Secrets). Refusing to run repository code without default-deny egress (PRD #6 invariant 3)."
            }

            # --- auto-suspend, pinned ----------------------------------------
            $lifecycle = Invoke-SandboxCli -Context $Context -Argv @(
                "sandbox", "lifecycle", "set", "-l", "name=$name",
                "--auto-suspend", "enable",
                "--idle-timeout-seconds", "$($Context.IdleTimeoutSeconds)"
            )
            if ($lifecycle.ExitCode -ne 0) {
                throw "Could not set the auto-suspend policy on sandbox '$name' ($($lifecycle.SafeArgv), exit $($lifecycle.ExitCode)): $(Get-SandboxErrorText -Result $lifecycle -Secrets $Context.Secrets). Auto-suspend defaults to 600s, which would suspend a running session."
            }

            # --- launch, DETACHED --------------------------------------------
            $environment = New-SandboxWorkerEnvironment -Request $request -Context $Context
            $launch = New-SandboxLaunchCommand -Environment $environment -StateDir $Context.StateDir
            $launched = Invoke-SandboxCli -Context $Context -Argv @("sandbox", "exec", "-l", "name=$name", "-c", $launch)
            if ($launched.ExitCode -ne 0) {
                throw "Could not launch the worker in sandbox '$name' ($($launched.SafeArgv), exit $($launched.ExitCode)): $(Get-SandboxErrorText -Result $launched -Secrets $Context.Secrets)"
            }
        } catch {
            # Leaving a sandbox that has no policy, or one with policy but no
            # worker, is a leak and a cost. Teardown is best-effort so the
            # ORIGINAL failure is what the caller sees.
            try { & $Context.Self.Operations["terminate"] $Context @{ Handle = $handle } | Out-Null } catch { }
            throw
        }

        Write-Host "[squad-aca] sandbox ${name}: created, default-deny egress applied, worker launched detached."

        # Same rule as every other provider: the response travels through
        # Outcome, never the pipeline.
        if ($Arguments["Outcome"]) {
            $Arguments["Outcome"]["Response"] = New-SquadDispatchResponse `
                -SessionId ([string]$request.sessionId) `
                -ExecutionMode "sandbox" `
                -SandboxClass ([string]$class.id) `
                -Status "Provisioning" `
                -SessionHandle $handle
        }
    }

    # -- status --------------------------------------------------------------
    $operations["status"] = {
        param($Context, $Arguments)

        if ($Arguments.Contains("Handle") -and $Arguments["Handle"]) {
            $payload = Resolve-SandboxHandlePayload -Handle $Arguments["Handle"]
            $poll = Invoke-SandboxCli -Context $Context -Argv @(
                "sandbox", "exec", "-l", "name=$($payload.name)", "-c", (New-SandboxPollCommand -StateDir $Context.StateDir)
            )

            # A transport failure is INCONCLUSIVE. The session is almost
            # certainly still running; reporting Failed here would kill a
            # healthy 60-minute run at the two-minute mark.
            if ($poll.ExitCode -ne 0 -and (Test-SandboxTransportInconclusive -Result $poll)) {
                return ConvertTo-SandboxExecutionRecord -Handle $Arguments["Handle"] -Payload $payload `
                    -State ([pscustomobject]@{ Status = "Unknown"; Phase = "inconclusive"; ExitCode = $null; Marker = "unknown" }) `
                    -Inconclusive $true
            }
            if ($poll.ExitCode -ne 0) {
                if (Test-SandboxGone -Result $poll) {
                    return ConvertTo-SandboxExecutionRecord -Handle $Arguments["Handle"] -Payload $payload `
                        -State ([pscustomobject]@{ Status = "Unknown"; Phase = "gone"; ExitCode = $null; Marker = "absent" })
                }
                throw "Could not poll sandbox '$($payload.name)' ($($poll.SafeArgv), exit $($poll.ExitCode)): $(Get-SandboxErrorText -Result $poll -Secrets $Context.Secrets)"
            }

            $state = ConvertFrom-SandboxPollOutput -Lines @($poll.StdOut)
            return ConvertTo-SandboxExecutionRecord -Handle $Arguments["Handle"] -Payload $payload -State $state
        }

        $limit = 10
        if ($Arguments.Contains("Limit") -and $Arguments["Limit"]) { $limit = [int]$Arguments["Limit"] }

        $listed = Invoke-SandboxCli -Context $Context -Argv @("sandbox", "list", "-o", "json")
        if ($listed.ExitCode -ne 0) {
            throw "Could not list sandboxes ($($listed.SafeArgv), exit $($listed.ExitCode)): $(Get-SandboxErrorText -Result $listed -Secrets $Context.Secrets)"
        }
        $raw = (@($listed.StdOut) -join "`n").Trim()
        $items = @()
        if ($raw) {
            $parsed = $null
            try { $parsed = $raw | ConvertFrom-Json } catch { throw "'aca sandbox list' returned output that is not valid JSON." }
            foreach ($entry in @($parsed)) {
                if ($null -eq $entry) { continue }
                $label = ""
                if ($entry.PSObject.Properties.Name -contains "labels" -and $entry.labels) {
                    if ($entry.labels.PSObject.Properties.Name -contains "name") { $label = [string]$entry.labels.name }
                } elseif ($entry.PSObject.Properties.Name -contains "name") {
                    $label = [string]$entry.name
                }
                # Only sandboxes this control plane owns. The squad- prefix plus
                # the session id is what a reaper matches on.
                if ($label -notlike "squad-*") { continue }
                $state = [pscustomobject]@{
                    Status   = $(if ($entry.PSObject.Properties.Name -contains "status") { [string]$entry.status } else { "Unknown" })
                    Phase    = ""
                    ExitCode = $null
                    Marker   = ""
                }
                $payload = [pscustomobject]@{
                    name    = $label
                    session = (Get-SandboxSessionIdFromLabel -Label $label)
                    class   = ""
                    group   = [string]$Context.SandboxGroup
                }
                $handle = New-SandboxExecutionHandle -SandboxName $label -SessionId ([string]$payload.session) -SandboxGroup ([string]$Context.SandboxGroup)
                $items += ConvertTo-SandboxExecutionRecord -Handle $handle -Payload $payload -State $state
            }
        }
        if ($items.Count -gt $limit) { $items = $items[0..($limit - 1)] }
        return $items
    }

    # -- wait ----------------------------------------------------------------
    # Readiness by default (contract), or all the way to terminal when the
    # caller asks. Either way it is a POLL LOOP of short execs -- an
    # inconclusive poll is retried, never reported.
    $operations["wait"] = {
        param($Context, $Arguments)

        $handle = $Arguments["Handle"]
        $timeout = 300
        if ($Arguments.Contains("TimeoutSeconds") -and $Arguments["TimeoutSeconds"]) { $timeout = [int]$Arguments["TimeoutSeconds"] }
        $poll = $Context.PollSeconds
        if ($Arguments.Contains("PollSeconds") -and $Arguments["PollSeconds"]) { $poll = [int]$Arguments["PollSeconds"] }
        $untilTerminal = $false
        if ($Arguments.Contains("UntilTerminal") -and $Arguments["UntilTerminal"]) { $untilTerminal = [bool]$Arguments["UntilTerminal"] }
        $terminal = @("Succeeded", "Failed", "TimedOut", "Cancelled")

        $deadline = (Get-Date).AddSeconds($timeout)
        $last = $null
        while ($true) {
            $record = Invoke-SquadProviderOperation -Provider $Context.Self -Operation "status" -Arguments @{ Handle = $handle }
            $last = $record
            if (-not $record.Inconclusive) {
                if ($untilTerminal) {
                    if ($terminal -contains $record.Status) { return $record }
                } elseif ($record.Status -ne "Provisioning") {
                    return $record
                }
            }
            if ((Get-Date) -ge $deadline) {
                $suffix = if ($last -and $last.Inconclusive) { " The last poll was inconclusive (a transport timeout), so the session may still be running." } else { "" }
                throw "Timed out after ${timeout}s waiting for the sandbox session.$suffix"
            }
            Start-Sleep -Seconds $poll
        }
    }

    # -- logs ----------------------------------------------------------------
    $operations["logs"] = {
        param($Context, $Arguments)

        $payload = Resolve-SandboxHandlePayload -Handle $Arguments["Handle"]
        $tail = 100
        if ($Arguments.Contains("Tail") -and $Arguments["Tail"]) { $tail = [int]$Arguments["Tail"] }
        if ($tail -le 0) { $tail = 100 }

        $result = Invoke-SandboxCli -Context $Context -Argv @(
            "sandbox", "exec", "-l", "name=$($payload.name)",
            "-c", "tail -n $tail $($Context.StateDir)/session.log 2>/dev/null || true"
        )
        if ($result.ExitCode -ne 0) {
            if (Test-SandboxTransportInconclusive -Result $result) {
                return [pscustomobject]@{
                    Lines  = @()
                    Notice = "[squad-aca] the log read timed out in transport; the session is unaffected. Retry."
                }
            }
            throw "Could not read logs from sandbox '$($payload.name)' ($($result.SafeArgv), exit $($result.ExitCode)): $(Get-SandboxErrorText -Result $result -Secrets $Context.Secrets)"
        }

        $lines = @()
        foreach ($line in @($result.StdOut)) {
            $lines += (Protect-SandboxText -Text ([string]$line) -Secrets $Context.Secrets)
        }
        return [pscustomobject]@{
            Lines  = $lines
            Notice = ""
        }
    }

    # -- cancel --------------------------------------------------------------
    # Stop the running session, reporting the substrate's own result. The
    # sandbox itself is left in place -- teardown is terminate's job -- so logs
    # stay readable after a cancel.
    #
    # Failure classification is the SAME mechanism terminate uses (Test-SandboxGone
    # over Test-AcaJobExecutionGone, plus the transport-inconclusive narrowing),
    # not a second one. Writing a non-zero exit to the host and returning success
    # is the softer sibling of the defect terminate was hardened against on
    # Sprint 3: an auth failure, an RBAC denial, throttling or a transport
    # timeout says nothing about whether the worker actually stopped, and a
    # caller told "cancelled" stops looking at a session that is still running
    # and still billing. Only "the sandbox is gone" is success without a cancel.
    $operations["cancel"] = {
        param($Context, $Arguments)

        $payload = Resolve-SandboxHandlePayload -Handle $Arguments["Handle"]
        $stateDir = $Context.StateDir
        $command = "pkill -f $($script:SandboxWorkerEntrypoint) >/dev/null 2>&1; " +
                   "printf %s 143 > $stateDir/exit-code; " +
                   "printf %s cancelled > $stateDir/phase; " +
                   "touch $stateDir/done; echo squad-cancelled"

        $result = Invoke-SandboxCli -Context $Context -Argv @("sandbox", "exec", "-l", "name=$($payload.name)", "-c", $command)
        foreach ($line in @($result.StdOut)) {
            Write-Host (Protect-SandboxText -Text ([string]$line) -Secrets $Context.Secrets)
        }
        if ($result.ExitCode -eq 0) {
            return [pscustomobject]@{ Cancelled = $true; AlreadyTerminal = $false }
        }
        if (Test-SandboxGone -Result $result) {
            return [pscustomobject]@{ Cancelled = $true; AlreadyTerminal = $true }
        }

        $inconclusive = Test-SandboxTransportInconclusive -Result $result
        $why = if ($inconclusive) {
            "the failure is a transport timeout, which says nothing about whether the worker stopped"
        } else {
            "the failure is not 'already deleted or gone'"
        }
        throw "Could not cancel the session in sandbox '$($payload.name)': '$($result.SafeArgv)' failed with exit $($result.ExitCode), and $why. $(Get-SandboxErrorText -Result $result -Secrets $Context.Secrets)"
    }

    # -- terminate -----------------------------------------------------------
    # Idempotent teardown. Already-deleted is SUCCESS; an auth, RBAC,
    # throttling, network or transport failure is an ERROR, because none of them
    # says anything about whether the sandbox still exists -- and a cleanup path
    # told "terminated" would stop looking for it.
    $operations["terminate"] = {
        param($Context, $Arguments)

        $payload = Resolve-SandboxHandlePayload -Handle $Arguments["Handle"]

        $result = Invoke-SandboxCli -Context $Context -Argv @(
            "sandbox", "delete", "-l", "name=$($payload.name)", "--yes"
        )

        if ($result.ExitCode -eq 0) {
            return [pscustomobject]@{ Terminated = $true; AlreadyTerminal = $false }
        }
        if (Test-SandboxGone -Result $result) {
            return [pscustomobject]@{ Terminated = $true; AlreadyTerminal = $true }
        }

        $inconclusive = Test-SandboxTransportInconclusive -Result $result
        $why = if ($inconclusive) {
            "the failure is a transport timeout, which says nothing about whether the sandbox still exists"
        } else {
            "the failure is not 'already deleted or gone'"
        }
        throw "Could not terminate sandbox '$($payload.name)': '$($result.SafeArgv)' failed with exit $($result.ExitCode), and $why. $(Get-SandboxErrorText -Result $result -Secrets $Context.Secrets)"
    }

    $provider = [pscustomobject]@{
        ProviderId    = $script:SandboxProviderId
        ExecutionMode = "sandbox"
        Context       = $context
        Operations    = $operations
    }
    $context | Add-Member -MemberType NoteProperty -Name Self -Value $provider
    return $provider
}
