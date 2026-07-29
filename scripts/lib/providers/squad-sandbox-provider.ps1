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
    7. Worker credentials NEVER appear in an argument vector. Sprint 5 shipped
       them as `env GH_TOKEN='...' <entrypoint>` inside the launch command, which
       is world-readable at /proc/<pid>/cmdline for the life of the exec. Two
       mechanisms replace that (Sprint 7):
         * the Copilot plane uses the platform's own credential brokerage --
           `aca sandboxgroup credential create --type github-copilot` with the
           token on STDIN, then `sandbox create --credential <opaque id>`;
         * the git/`gh` push plane, for which the platform exposes no
           `--type`, is delivered on the STDIN of a dedicated `sandbox exec`
           that writes a umask-077 file the launch command sources and deletes.
       Both are behaviourally testable offline: the token must be absent from
       every recorded argv and must still arrive at the worker.
    8. Blast radius is bounded before a sandbox exists: per-class concurrency is
       enforced against the live sandbox list, auto-suspend is pinned instead of
       inherited, and every failure carries a machine-readable kind so quota
       exhaustion is never mistaken for an auth or readiness problem.
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
    # Invoke-CliSafeWithStdin (scripts/lib/aca-logs.ps1) reports its OWN client
    # timeout as exit 124 with "timed out after <n>s". That is this process
    # giving up on a wait, not the service reaching a verdict, so it is
    # inconclusive for exactly the same reason as the `aca` client's ~120s
    # give-up. Without this, a timeout on the credential broker or the seed exec
    # classified as `execution` -- a definite statement nothing observed.
    "timed out after",
    "temporary failure in name resolution",
    "EOF occurred in violation of protocol"
)

# ---------------------------------------------------------------------------
# Failure classification rules -- ORDERED, and exposed for exactly that reason
# ---------------------------------------------------------------------------
#
# The order of these blocks is load-bearing, so it lives in DATA a test can walk
# rather than in the control flow of a function a test can only call. Two
# properties depend on it:
#
#   * transport first  -- a failure that says nothing about the sandbox must not
#                         be read as a verdict about it;
#   * quota before auth -- several services phrase a quota rejection as a 403,
#                         and reading "you have hit your ceiling" as "your
#                         credentials are bad" sends an operator to rotate a
#                         perfectly good token.
#
# NUMERIC HTTP CODES ARE NEVER MATCHED AS BARE SUBSTRINGS. Test-AcaJobExecutionGone
# (squad-aca-job-provider.ps1) has always used only NAMED codes -- "TooManyRequests",
# "throttl", "Retry-After" -- and never "429", precisely because Azure decorates
# every auth failure with object-, subscription- and correlation-GUIDs. A bare
# "429" matched the hex of `Correlation ID: 1b8f429c-...` and, being first in an
# ordered classifier, turned every GUID-bearing AuthorizationFailed / AADSTS
# message into `quota` -- i.e. "a ceiling was hit, retry later" -- so an
# unattended dispatcher would retry a rotated-out credential forever. The
# taxonomy exists to prevent that, and a bare substring inverted it.
#
# Where a numeric code is still useful it is written with a hardened boundary:
#
#     (?<![0-9A-Za-z-])429(?![0-9A-Za-z-])
#
# The code must be delimited by something that is neither alphanumeric NOR a
# hyphen. Every GUID/trace-id occurrence is bounded by a hex digit or a hyphen
# on at least one side (`1b8f429c`, `0000429f`, `-429c-`, `4291aaaa`), so none of
# them can match; a real code -- `HTTP 429`, `(403)`, `status=401,` -- always is
# not. A plain `\b` is NOT enough: `\b` treats `-` as a boundary, so
# `Correlation ID: 1b8f-429c` would still match.
$script:SandboxFailureRules = @(
    [pscustomobject]@{
        Kind     = "transport"
        Patterns = $script:SandboxInconclusivePatterns
    },
    [pscustomobject]@{
        Kind     = "quota"
        # "quota" is case-insensitive here and therefore already covers
        # "QuotaExceeded"; the named throttling codes mirror Test-AcaJobExecutionGone.
        Patterns = @(
            "quota",
            "exceeded the limit", "limit exceeded",
            "insufficient capacity", "no capacity", "out of capacity",
            "TooManyRequests", "SubscriptionRequestsThrottled",
            "throttl", "rate limit", "Retry-After",
            "(?<![0-9A-Za-z-])429(?![0-9A-Za-z-])"
        )
    },
    [pscustomobject]@{
        Kind     = "auth"
        # "unauthorized" covers "Unauthorized" and "unauthorized_client".
        Patterns = @(
            "AADSTS", "unauthorized", "invalid_client", "Forbidden",
            "CheckAccess", "AuthorizationFailed", "AuthorizationPermissionMismatch",
            "does not have authorization", "aca login", "az login",
            "refresh token has expired", "ExpiredAuthenticationToken",
            "InvalidAuthenticationToken", "authentication failed",
            "(?<![0-9A-Za-z-])401(?![0-9A-Za-z-])",
            "(?<![0-9A-Za-z-])403(?![0-9A-Za-z-])"
        )
    },
    [pscustomobject]@{
        Kind     = "readiness"
        Patterns = @("not ready", "NotReady", "still provisioning", "Provisioning",
                     "is starting", "suspended", "Suspended")
    }
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
# Credential brokerage (PRD #6 Sprint 7)
# ---------------------------------------------------------------------------

# The platform's own credential types, live-verified. The token is validated
# HERE, before the CLI is invoked, because the platform's rejection of a classic
# `ghp_` token for the Copilot type arrives as an opaque failure after a network
# round trip -- and by then the operator has no idea which of their two tokens
# was wrong. `scripts/deploy.ps1` currently defaults -CopilotGitHubToken to the
# SAME value as -GitHubToken, so the two planes are one token in practice and a
# `gh auth token` value (classic, `ghp_`) is the likely input. That is exactly
# the footgun this table exists to catch.
$script:SandboxCredentialTypes = [ordered]@{
    "github-copilot"   = [pscustomobject]@{
        RequiredPrefix = "github_pat_"
        Description    = "a GitHub fine-grained personal access token"
        Rejected       = @(
            [pscustomobject]@{ Prefix = "ghp_"; Why = "a CLASSIC personal access token" },
            [pscustomobject]@{ Prefix = "gho_"; Why = "an OAuth token" },
            [pscustomobject]@{ Prefix = "ghs_"; Why = "a GitHub App server-to-server token" },
            [pscustomobject]@{ Prefix = "ghu_"; Why = "a GitHub App user-to-server token" }
        )
    }
    "anthropic-claude" = [pscustomobject]@{
        RequiredPrefix = "sk-ant-"
        Description    = "an Anthropic API key"
        Rejected       = @()
    }
}

# Where the git/`gh` credential lands inside the sandbox. It is written by a
# stdin-fed exec, sourced by the launch command, and deleted in the same
# breath, so its on-disk lifetime is the gap between two execs rather than the
# life of the session.
$script:SandboxCredentialFileName = ".squad-creds"

# Worker environment variables that carry a credential. These are delivered
# through the credential file, never as an `env NAME=value` assignment in the
# launch command -- an assignment is argv, and argv is world-readable inside the
# sandbox.
$script:SandboxSecretEnvNames = @("GH_TOKEN", "GITHUB_TOKEN")

# Token character allowlist. Every credential this provider handles is an opaque
# bearer string from a small alphabet; anything outside it is either an attack
# (quote-breaking out of the credential file, argv injection) or a value that was
# mangled in transit. Refusing early beats sending it and guessing at the error.
$script:SandboxTokenPattern = "^[A-Za-z0-9_\-\.~+/=]+$"

# `aca` subcommands whose OUTPUT is a credential or policy dump. ADR 0001 risk
# R2: these values are readable to anyone with group read access, and once this
# provider has them in a result object they are one Write-Host away from a CI
# log. The provider has no legitimate need for any of them -- it writes policy,
# it never reads it back -- so they are refused at the argv gate rather than
# merely redacted. `egress decisions` is deliberately NOT refused: it is the
# audit trail (allow/deny, host, matchedRule), not the policy.
$script:SandboxForbiddenReadbacks = @(
    @("sandbox", "egress", "show"),
    @("sandbox", "egress", "export"),
    @("sandboxgroup", "credential", "list"),
    @("sandboxgroup", "credential", "show")
)

# ---------------------------------------------------------------------------
# Failure taxonomy
# ---------------------------------------------------------------------------

# PRD #6 requires that quota exhaustion be separately identifiable from auth,
# capability, readiness and execution failures. A caller that cannot tell them
# apart retries the wrong thing: retrying an auth failure is noise, retrying a
# quota failure is correct, and retrying a capability failure is never correct.
# Every error this provider raises is tagged `[squad-sandbox:<kind>]`.
$script:SandboxFailureKinds = @(
    "auth",       # credentials rejected / RBAC denial -- do not retry
    "capability", # the request cannot be satisfied safely -- never retry
    "quota",      # a ceiling was hit -- retry later, or raise the ceiling
    "readiness",  # the substrate is not ready yet -- retry soon
    "execution",  # the worker itself failed -- inspect the session
    "transport",  # the call told us nothing -- re-poll
    "config"      # the control plane is misconfigured -- fix the deployment
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

function New-SandboxFailure {
    <#
    .SYNOPSIS
        Build a tagged, machine-classifiable failure message.

    .DESCRIPTION
        `[squad-sandbox:<kind>] <text>`. The tag is the whole point: PRD #6
        requires quota exhaustion to be separately identifiable from auth,
        capability, readiness and execution failures, and a caller that has to
        regex the prose to work out which one it got will get it wrong the first
        time the CLI changes its wording.

        The kind is validated, so a typo is a loud error here rather than a
        silently unclassifiable failure at 3am.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )
    if ($script:SandboxFailureKinds -notcontains $Kind) {
        throw "'$Kind' is not a recognised sandbox failure kind."
    }
    return "[squad-sandbox:$Kind] $Message"
}

function Get-SandboxFailureClassification {
    <#
    .SYNOPSIS
        Classify a raw CLI failure, and report WHICH RULE DECIDED.

    .DESCRIPTION
        Returns `Kind` (the failure kind), `DecidedBy` (the rule that produced
        it) and `Pattern` (the literal pattern that matched).

        `DecidedBy`/`Pattern` are not decoration. A precedence between two rule
        blocks is UNOBSERVABLE through the kind alone: for every input where
        only one list matches, both orderings return the same kind, so a test
        built from unambiguous fixtures passes under either. Only an input that
        matches BOTH lists distinguishes them, and only the reported rule says
        which one won. This mirrors classifyGhFailure in
        worker/lib/dispatch-lease.js, which was given the same treatment after
        Sprint 6's B3 -- the same defect class, now for the fifth time in this
        programme (PR #9's runner, Sprint 3 B1, Sprint 5 `cancel`, Sprint 6 B3,
        and this classifier).

        Ordering, and the deny-list-first discipline, live in
        $script:SandboxFailureRules; this function only walks them. Rule order
        and the presence of a genuinely ambiguous fixture for every ADJACENT
        pair of rules are both asserted in scripts/validate.ps1, so removing the
        discriminating fixtures is itself a failing change.

        DecidedBy values:
          success      exit 0; nothing to classify.
          transport    the failure said nothing about the sandbox.
          quota/auth/readiness   that rule's pattern list matched first.
          fallthrough  no rule matched -> `execution`, the last resort.
    #>
    param([Parameter(Mandatory = $true)][object]$Result)

    if ($Result.ExitCode -eq 0) {
        return [pscustomobject]@{ Kind = ""; DecidedBy = "success"; Pattern = "" }
    }
    # Same rule as Test-SandboxTransportInconclusive: exit 124 is our own
    # give-up, decided without any message text.
    if ($Result.ExitCode -eq 124) {
        return [pscustomobject]@{ Kind = "transport"; DecidedBy = "transport"; Pattern = "exit 124" }
    }
    $text = ((@($Result.StdErr) + @($Result.StdOut) | Where-Object { $_ }) -join " ")

    foreach ($rule in $script:SandboxFailureRules) {
        foreach ($pattern in $rule.Patterns) {
            if ($text -match $pattern) {
                return [pscustomobject]@{ Kind = $rule.Kind; DecidedBy = $rule.Kind; Pattern = $pattern }
            }
        }
    }

    return [pscustomobject]@{ Kind = "execution"; DecidedBy = "fallthrough"; Pattern = "" }
}

function Get-SandboxFailureKind {
    <#
    .SYNOPSIS
        Classify a raw CLI failure into one of the failure kinds.

    .DESCRIPTION
        The kind only. Use Get-SandboxFailureClassification when the rule that
        decided matters -- which is any time a precedence is being asserted.
    #>
    param([Parameter(Mandatory = $true)][object]$Result)

    return (Get-SandboxFailureClassification -Result $Result).Kind
}

function Assert-SandboxIdentifier {
    <#
    .SYNOPSIS
        Refuse a resource identifier BEFORE it is used to construct an API call.

    .DESCRIPTION
        Every identifier this provider handles ends up in at least two hostile
        contexts: a process argument vector, and a POSIX shell command line
        inside the sandbox. Three distinct injections are possible and all three
        are rejected here rather than downstream:

          * ARGUMENT injection -- a value beginning with `-` is parsed as a flag
            by the CLI, not as data. `--identity` arriving as a "disk id" would
            defeat invariant 4 without ever touching Assert-SandboxArgvIdentityFree,
            because it would be a VALUE the check walks straight past.
          * PATH traversal -- `..`, `/` and `\` in an identifier that is
            concatenated into a REST path reach a sibling resource.
          * CONTROL characters -- NUL, CR and LF split log lines, forge audit
            records, and terminate C-string parsers early. `\p{C}` covers the
            whole category (including the C1 range and unassigned code points),
            which an explicit `\x00-\x1f` list does not.

        Validation is an ALLOWLIST per kind, not a deny-list of the above: a
        deny-list is only ever as good as the last attack someone thought of.

    .PARAMETER Kind
        `label` (a sandbox label / group / disk label), `guid`, `credential`
        (an opaque brokered-credential id) or `host` (an egress pattern).
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet("label", "guid", "credential", "host")]
        [string]$Kind = "label",
        [int]$MaxLength = 128
    )

    $text = [string]$Value
    if (-not $text) {
        throw (New-SandboxFailure -Kind "config" -Message "$Name is empty, and an empty identifier cannot address a resource.")
    }
    if ($text.Length -gt $MaxLength) {
        # Deliberately NOT echoed: an over-long value is either an attack or a
        # bug, and quoting it back is how a hostile string reaches a log.
        throw (New-SandboxFailure -Kind "capability" -Message "$Name is $($text.Length) characters, over the $MaxLength limit. The value is not echoed.")
    }
    if ($text -match "\p{C}") {
        throw (New-SandboxFailure -Kind "capability" -Message "$Name contains a control character (newline, NUL or similar). The value is not echoed.")
    }
    if ($text.StartsWith("-")) {
        throw (New-SandboxFailure -Kind "capability" -Message "$Name starts with '-', which a CLI parses as a flag rather than as data. Refusing to build a command from it.")
    }

    $pattern = switch ($Kind) {
        "guid"       { "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" }
        "credential" { "^[A-Za-z0-9][A-Za-z0-9_\-\.]*$" }
        "host"       { "^(\*\.)?[A-Za-z0-9]([A-Za-z0-9_\-\.]*[A-Za-z0-9])?$" }
        default      { "^[A-Za-z0-9][A-Za-z0-9_\-\.]*$" }
    }
    if ($text -notmatch $pattern) {
        throw (New-SandboxFailure -Kind "capability" -Message "$Name is not a well-formed $Kind identifier. Only unreserved characters are accepted; the value is not echoed.")
    }
    return $true
}

function Assert-SandboxArgvNoReadback {
    <#
    .SYNOPSIS
        Refuse any `aca` command whose output would be a credential or policy
        dump (ADR 0001 risk R2).

    .DESCRIPTION
        The provider writes egress policy and creates credentials; it never
        reads either back. So the safest possible handling of a value that is
        "readable to anyone with group read access" is never to obtain it: a
        value this process never holds cannot be logged, cannot land in a
        captured golden, and cannot be echoed by an error path nobody audited.

        `sandbox egress decisions` is intentionally still allowed -- it is the
        allow/deny audit trail, not the policy.
    #>
    param([string[]]$Argv = @())

    $words = @(@($Argv) | Where-Object { -not ([string]$_).StartsWith("-") } | ForEach-Object { [string]$_ })
    foreach ($forbidden in $script:SandboxForbiddenReadbacks) {
        if ($words.Count -lt $forbidden.Count) { continue }
        $match = $true
        for ($i = 0; $i -lt $forbidden.Count; $i++) {
            if ($words[$i] -ne $forbidden[$i]) { $match = $false; break }
        }
        if ($match) {
            throw (New-SandboxFailure -Kind "capability" -Message "Refusing to run 'aca $($forbidden -join ' ')': its output is a credential or egress-policy dump, which is readable to anyone with group read access and must never enter this process (ADR 0001 risk R2).")
        }
    }
}

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
    Assert-SandboxArgvNoReadback -Argv $Argv
    $result = Invoke-CliSafe -FilePath $Context.AcaPath -Arguments $Argv
    Add-Member -InputObject $result -MemberType NoteProperty -Name SafeArgv -Value (Get-SandboxSafeArgv -Argv $Argv) -Force
    return $result
}

function Invoke-SandboxCliWithSecretStdin {
    <#
    .SYNOPSIS
        Run one `aca` command with a credential delivered on STANDARD INPUT.

    .DESCRIPTION
        The only way this provider is allowed to hand a token to `aca`. An
        argument vector is not private -- /proc/<pid>/cmdline, `ps`, shell
        history and every error renderer can see it -- so a credential that
        appears as `--token <value>` has already been disclosed no matter how
        carefully the rendering is redacted afterwards. `aca` documents that the
        token may be omitted from the command line and read from stdin, so this
        is the platform's supported path.

        Two invariants, both asserted by the caller's tests:

          * the secret is never an element of $Argv,
          * the secret is registered for scrubbing, so a CLI that echoes it back
            in its own error text still cannot reach a thrown message.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string[]]$Argv,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Secret
    )

    Assert-SandboxArgvIdentityFree -Argv $Argv
    Assert-SandboxArgvNoReadback -Argv $Argv
    foreach ($arg in @($Argv)) {
        if ($Secret -and ([string]$arg).Contains($Secret)) {
            throw (New-SandboxFailure -Kind "capability" -Message "Refusing to run 'aca': a credential was found in the argument vector, which is world-readable at /proc/<pid>/cmdline. It must be delivered on stdin.")
        }
    }
    $result = Invoke-CliSafeWithStdin -FilePath $Context.AcaPath -Arguments $Argv -StandardInput $Secret
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

        Exit 124 is Invoke-CliSafeWithStdin's own give-up marker (aca-logs.ps1).
        It is THIS process deciding to stop waiting, never a service verdict, so
        it is inconclusive by construction and does not depend on the wording of
        the message that accompanies it.
    #>
    param([Parameter(Mandatory = $true)][object]$Result)

    if ($Result.ExitCode -eq 0) { return $false }
    if ($Result.ExitCode -eq 124) { return $true }
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

    .DESCRIPTION
        The handle carries the ids of any credentials brokered for this session
        (`creds`). Those are opaque service-side references, NOT credential
        values -- but they are what `terminate` needs in order to revoke, and a
        credential nothing can name is a credential nothing can revoke. A
        brokered credential lives on the GROUP and inherits group RBAC (ADR 0001
        risk R2), so failing to revoke it is a real, lasting exposure.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SessionId,
        [AllowEmptyString()][string]$ClassId = "",
        [AllowEmptyString()][string]$SandboxGroup = "",
        [string[]]$CredentialIds = @()
    )
    return New-SquadExecutionHandle -ProviderId $script:SandboxProviderId -Payload ([ordered]@{
        name    = $SandboxName
        session = $SessionId
        class   = $ClassId
        group   = $SandboxGroup
        creds   = @(@($CredentialIds) | Where-Object { $_ })
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
# Credential brokerage
# ---------------------------------------------------------------------------

function Test-SandboxCredentialToken {
    <#
    .SYNOPSIS
        Why this token cannot be brokered as this type -- "" when it can.

    .DESCRIPTION
        Returns a reason instead of throwing so the rule is directly testable
        (and so a caller can report several planes' problems at once).
        Assert-SandboxCredentialToken is the throwing wrapper.

        The classic-token footgun this exists for: the platform accepts ONLY a
        fine-grained `github_pat_` token for `--type github-copilot` and rejects
        a classic `ghp_` one. `gh auth token` -- the thing an operator reaches
        for, and the thing `scripts/deploy.ps1` itself calls at line 61 -- yields
        a CLASSIC token, and deploy.ps1 then defaults -CopilotGitHubToken to the
        SAME value. So the single most likely real-world input is exactly the one
        the platform rejects, and its rejection arrives from the service as an
        opaque failure after a network round trip. Catching it here turns that
        into an actionable sentence naming both the prefix seen and the fix.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Token
    )

    if (-not $script:SandboxCredentialTypes.Contains($Type)) {
        return "'$Type' is not a credential type this platform brokers. Supported: $(@($script:SandboxCredentialTypes.Keys) -join ', ')."
    }
    $spec = $script:SandboxCredentialTypes[$Type]

    if (-not $Token) { return "no token was supplied for credential type '$Type'." }
    if ($Token -ne $Token.Trim()) {
        return "the token for '$Type' has leading or trailing whitespace, which the service will reject as part of the value."
    }
    if ($Token -notmatch $script:SandboxTokenPattern) {
        return "the token for '$Type' contains characters outside the unreserved set. The value is not echoed."
    }

    foreach ($bad in @($spec.Rejected)) {
        if ($Token.StartsWith($bad.Prefix)) {
            return ("the token for '$Type' starts with '$($bad.Prefix)', which is $($bad.Why). " +
                    "This platform accepts only $($spec.Description) (prefix '$($spec.RequiredPrefix)') for that type and will reject anything else. " +
                    "Note that 'gh auth token' returns a classic token, and scripts/deploy.ps1 defaults -CopilotGitHubToken to the SAME value as -GitHubToken, " +
                    "so the two credential planes are one token unless you pass -CopilotGitHubToken explicitly. Mint a fine-grained PAT for the Copilot plane.")
        }
    }
    if (-not $Token.StartsWith($spec.RequiredPrefix)) {
        return ("the token for '$Type' does not start with '$($spec.RequiredPrefix)'. This platform accepts only $($spec.Description) for that type. The value is not echoed.")
    }
    return ""
}

function Assert-SandboxCredentialToken {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Token
    )
    $issue = Test-SandboxCredentialToken -Type $Type -Token $Token
    if ($issue) {
        throw (New-SandboxFailure -Kind "capability" -Message "Refusing to broker a credential: $issue")
    }
    return $true
}

function New-SandboxBrokeredCredential {
    <#
    .SYNOPSIS
        Broker one credential on the sandbox GROUP and return its opaque id.

    .DESCRIPTION
        `aca sandboxgroup credential create --type <type>` with the token on
        stdin. The returned id is what `sandbox create --credential <id>`
        references, so the token itself is never an argument, never an
        environment variable, and never part of the sandbox's own environment.

        The id is validated with Assert-SandboxIdentifier before it is allowed
        anywhere near another command line: it is service-controlled input, and
        a service-controlled string that begins with `-` is a flag.

        LIFECYCLE. A brokered credential lives on the GROUP and inherits group
        RBAC (ADR 0001 risk R2), so it outlives the sandbox that used it unless
        something deletes it. The id therefore travels in the execution handle
        and `terminate` revokes it. Rotation is incident response, not
        housekeeping: see docs/runbook.md.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Token
    )

    Assert-SandboxCredentialToken -Type $Type -Token $Token | Out-Null

    $scoped = $Context.PSObject.Copy()
    $scoped.Secrets = @($Context.Secrets) + @($Token)

    $result = Invoke-SandboxCliWithSecretStdin -Context $scoped -Secret $Token -Argv @(
        "sandboxgroup", "credential", "create",
        "--type", $Type,
        "-o", "json"
    )
    if ($result.ExitCode -ne 0) {
        $kind = Get-SandboxFailureKind -Result $result
        if (-not $kind) { $kind = "execution" }
        throw (New-SandboxFailure -Kind $kind -Message "Could not broker a '$Type' credential ($($result.SafeArgv), exit $($result.ExitCode)): $(Get-SandboxErrorText -Result $result -Secrets $scoped.Secrets)")
    }

    $raw = (@($result.StdOut) -join "`n").Trim()
    $id = ""
    if ($raw) {
        try {
            $parsed = $raw | ConvertFrom-Json
            foreach ($property in @("id", "credentialId", "name")) {
                if (($parsed.PSObject.Properties.Name -contains $property) -and $parsed.$property) {
                    $id = [string]$parsed.$property
                    break
                }
            }
        } catch {
            throw (New-SandboxFailure -Kind "execution" -Message "Could not broker a '$Type' credential: 'aca sandboxgroup credential create' returned output that is not valid JSON.")
        }
    }
    if (-not $id) {
        throw (New-SandboxFailure -Kind "execution" -Message "Could not broker a '$Type' credential: the service returned no credential id.")
    }
    Assert-SandboxIdentifier -Value $id -Name "the brokered credential id" -Kind "credential" -MaxLength 200 | Out-Null
    return $id
}

function Remove-SandboxBrokeredCredential {
    <#
    .SYNOPSIS
        Revoke a brokered credential. Idempotent; never throws.

    .DESCRIPTION
        Called from teardown paths that already carry a more important failure,
        so it reports rather than raises -- a revocation that could not be
        completed must not mask the original error. It returns the outcome so
        the caller can surface "this credential is still live" without losing
        its own exception.

        Failing to revoke is a real exposure (the credential remains readable to
        anyone with group read access), so the outcome is not silently dropped:
        `terminate` reports it.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CredentialId
    )

    if (-not $CredentialId) { return [pscustomobject]@{ Revoked = $false; Reason = "no credential" } }
    try {
        Assert-SandboxIdentifier -Value $CredentialId -Name "the brokered credential id" -Kind "credential" -MaxLength 200 | Out-Null
    } catch {
        return [pscustomobject]@{ Revoked = $false; Reason = "malformed credential id" }
    }

    $result = $null
    try {
        $result = Invoke-SandboxCli -Context $Context -Argv @("sandboxgroup", "credential", "delete", "--id", $CredentialId, "--yes")
    } catch {
        return [pscustomobject]@{ Revoked = $false; Reason = "revocation call failed" }
    }
    if ($result.ExitCode -eq 0) { return [pscustomobject]@{ Revoked = $true; Reason = "" } }
    if (Test-SandboxGone -Result $result) { return [pscustomobject]@{ Revoked = $true; Reason = "already gone" } }
    return [pscustomobject]@{ Revoked = $false; Reason = "exit $($result.ExitCode)" }
}

function New-SandboxCredentialSeedCommand {
    <#
    .SYNOPSIS
        The exec that receives the git/`gh` token on STDIN and stages it inside
        the sandbox.

    .DESCRIPTION
        The platform brokers `github-copilot` and `anthropic-claude` natively.
        It exposes no type for a plain git push token, so that plane cannot use
        `--credential` -- but it must still stay out of every argument vector,
        because argv inside the sandbox is readable by every process in it.

        Shape, and why each piece is there:

          umask 077          the file is created 0600 from the outset; a chmod
                             after the fact leaves a window where it is not.
          IFS= read -r       preserves the value exactly: no field splitting, no
                             backslash processing, no trailing-whitespace loss.
          printf '%s'        never interprets the value (unlike `echo -e`).
          '...'             the value is single-quoted INSIDE the file, so a
                             sourcing shell treats it as a literal. Tokens are
                             validated against $script:SandboxTokenPattern first,
                             which excludes `'`, so this quoting cannot be
                             escaped from.
          unset             the variable does not survive into the environment
                             of anything this exec later spawns.

        The launch command sources this file and deletes it immediately, so its
        on-disk lifetime is the gap between two execs.
    #>
    param(
        [string]$StateDir = $script:SandboxStateDir,
        [string[]]$Names = $script:SandboxSecretEnvNames
    )

    $writes = @()
    foreach ($name in @($Names)) {
        if ($name -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") {
            throw (New-SandboxFailure -Kind "capability" -Message "Refusing to stage a credential: '$name' is not a valid environment variable name.")
        }
        $writes += "printf 'export $name=%s\n' ""'`$__squad_tok'"" >> $StateDir/$($script:SandboxCredentialFileName)"
    }

    return "umask 077; mkdir -p $StateDir && rm -f $StateDir/$($script:SandboxCredentialFileName) && " +
           "IFS= read -r __squad_tok && " + ($writes -join " && ") +
           " && unset __squad_tok && echo squad-credentials-staged"
}

# ---------------------------------------------------------------------------
# Egress policy generation
# ---------------------------------------------------------------------------

function New-SandboxEgressPolicy {
    <#
    .SYNOPSIS
        Generate the egress policy from the APPROVED class template plus the
        manifest's request, where the request may only narrow.

    .DESCRIPTION
        THE enforcement point for "a repository requests, it never grants"
        (docs/capability-manifest.md, security invariant 3) at the moment policy
        is actually generated. Sprint 2 enforces the same rule when it picks a
        class; enforcing it only there means the rule holds exactly as long as
        nobody ever constructs a policy by another route -- and this provider is
        another route.

        Rules:

          1. Every emitted pattern and action is copied from the class template.
             Nothing derived from manifest text is ever emitted, which is why a
             hostile host string cannot reach the policy even in a rejected
             build: the emitted set is a subset of the template by construction,
             and the provenance assertion below proves it rather than asserting
             it in a comment.
          2. A requested host NOT covered by the template is a hard failure, not
             a silently dropped entry. Dropping it would run the session with
             less network than it asked for and blame the failure on the code.
          3. Requested hosts narrow: when the manifest declares any, the emitted
             rule set keeps only the template rules that cover a requested host
             (plus the template's own non-Allow rules, which can only tighten).
             A manifest asking for nothing gets the full template, unchanged.
          4. defaultAction and trafficInspection come from the template only.
             A class whose defaultAction is not Deny is refused outright.

    .OUTPUTS
        PSCustomObject: DefaultAction, TrafficInspection, Rules[] (pattern,
        action), Narrowed (bool), RequestedCount.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Class,
        [string[]]$RequestedHosts = @()
    )

    if (-not $Class -or -not $Class.egress) {
        throw (New-SandboxFailure -Kind "config" -Message "Sandbox class '$($Class.id)' has no egress template. Refusing to run repository code without one (PRD #6 invariant 3).")
    }
    $defaultAction = [string]$Class.egress.defaultAction
    if ($defaultAction -ne "Deny") {
        throw (New-SandboxFailure -Kind "config" -Message "Sandbox class '$($Class.id)' has egress defaultAction '$defaultAction'. Only 'Deny' is acceptable: an allow-by-default class is not a sandbox (PRD #6 invariant 3).")
    }

    $template = @()
    foreach ($rule in @($Class.egress.hostRules)) {
        $pattern = [string]$rule.pattern
        $action = [string]$rule.action
        # The catalog is administrator-owned, but it is still a file -- and a
        # malformed pattern here becomes an argv element.
        Assert-SandboxIdentifier -Value $pattern -Name "an egress pattern in class '$($Class.id)'" -Kind "host" -MaxLength 253 | Out-Null
        if ($action -ne "Allow" -and $action -ne "Deny") {
            throw (New-SandboxFailure -Kind "config" -Message "Sandbox class '$($Class.id)' has an egress rule with action '$action'. Only 'Allow' and 'Deny' are understood.")
        }
        $template += [pscustomobject]@{ Pattern = $pattern; Action = $action }
    }

    $requested = @(@($RequestedHosts) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $unsatisfied = @()
    $covered = @{}
    foreach ($host_ in $requested) {
        $hit = $null
        foreach ($rule in $template) {
            if ($rule.Action -ne "Allow") { continue }
            if (Test-SandboxHostCoveredByPattern -Host_ $host_ -Pattern $rule.Pattern) { $hit = $rule; break }
        }
        if (-not $hit) {
            # The host is NOT echoed. It is repository-controlled text, and the
            # count plus the class id is enough to act on.
            $unsatisfied += $host_
        } else {
            $covered[$hit.Pattern] = $true
        }
    }
    if ($unsatisfied.Count -gt 0) {
        throw (New-SandboxFailure -Kind "capability" -Message "The repository's capability manifest requests $($unsatisfied.Count) egress destination(s) that sandbox class '$($Class.id)' does not permit. A repository may only narrow an approved class's egress template, never widen it. The requested hosts are not echoed. Add the destination to the class in config/sandbox-classes.json, with review, or pick a class that already permits it.")
    }

    $rules = @()
    $narrowed = $false
    if ($requested.Count -gt 0) {
        foreach ($rule in $template) {
            if ($rule.Action -ne "Allow" -or $covered.ContainsKey($rule.Pattern)) { $rules += $rule }
        }
        $narrowed = ($rules.Count -lt $template.Count)
    } else {
        $rules = $template
    }

    # PROVENANCE. Every emitted rule must be object-identical in value to a
    # template rule. This is what makes "manifest text never reaches the policy"
    # a checked property rather than a claim about the code above it.
    foreach ($rule in $rules) {
        $match = @($template | Where-Object { $_.Pattern -eq $rule.Pattern -and $_.Action -eq $rule.Action })
        if ($match.Count -eq 0) {
            throw (New-SandboxFailure -Kind "capability" -Message "Refusing to apply an egress policy: a generated rule is not present in the approved class template. Only administrator-approved rules may be applied.")
        }
    }

    return [pscustomobject]@{
        DefaultAction     = $defaultAction
        TrafficInspection = [string]$Class.egress.trafficInspection
        Rules             = $rules
        Narrowed          = $narrowed
        RequestedCount    = $requested.Count
    }
}

function Test-SandboxHostCoveredByPattern {
    <#
    .SYNOPSIS
        Does an egress template pattern permit this host?

    .DESCRIPTION
        The catalog's documented semantics: an exact host, or a leading-wildcard
        suffix where `*.github.com` matches any host ending in `.github.com` and
        does NOT match the bare apex. Comparison is ordinal and case-insensitive
        (DNS is case-insensitive; ordinal keeps it culture-independent, so a
        Turkish-locale host cannot change the answer).
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Host_,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Pattern
    )

    if (-not $Host_ -or -not $Pattern) { return $false }
    $cmp = [StringComparison]::OrdinalIgnoreCase
    if ($Pattern.StartsWith("*.")) {
        $suffix = $Pattern.Substring(1)   # ".github.com"
        return ($Host_.Length -gt $suffix.Length -and $Host_.EndsWith($suffix, $cmp))
    }
    return [string]::Equals($Host_, $Pattern, $cmp)
}

# ---------------------------------------------------------------------------
# Concurrency, cost and orphan control
# ---------------------------------------------------------------------------

function Get-SquadSandboxInventory {
    <#
    .SYNOPSIS
        The sandboxes THIS control plane owns, from the live list.

    .DESCRIPTION
        `squad-` prefixed labels are the ownership marker (ADR 0001 risk R7):
        without it "is this sandbox ours?" is undecidable and a reaper is either
        useless or dangerous. Anything not so labelled is ignored entirely --
        this function is used by both the concurrency ceiling and the reaper, and
        a reaper that could delete a stranger's sandbox is worse than no reaper.
    #>
    param([Parameter(Mandatory = $true)][object]$Context)

    $listed = Invoke-SandboxCli -Context $Context -Argv @("sandbox", "list", "-o", "json")
    if ($listed.ExitCode -ne 0) {
        $kind = Get-SandboxFailureKind -Result $listed
        if (-not $kind) { $kind = "execution" }
        throw (New-SandboxFailure -Kind $kind -Message "Could not list sandboxes ($($listed.SafeArgv), exit $($listed.ExitCode)): $(Get-SandboxErrorText -Result $listed -Secrets $Context.Secrets)")
    }
    $raw = (@($listed.StdOut) -join "`n").Trim()
    if (-not $raw) { return @() }
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch {
        throw (New-SandboxFailure -Kind "execution" -Message "'aca sandbox list' returned output that is not valid JSON.")
    }

    $items = @()
    foreach ($entry in @($parsed)) {
        if ($null -eq $entry) { continue }
        $label = ""
        if (($entry.PSObject.Properties.Name -contains "labels") -and $entry.labels) {
            if ($entry.labels.PSObject.Properties.Name -contains "name") { $label = [string]$entry.labels.name }
        } elseif ($entry.PSObject.Properties.Name -contains "name") {
            $label = [string]$entry.name
        }
        if ($label -notlike "squad-*") { continue }
        # The label reaches an argv: `sandbox delete -l name=<label>`. Whether it
        # came from config or from the service's own listing, an identifier this
        # process did not mint is untrusted input -- exactly the reasoning
        # already applied to the disk id resolved from this same service. A label
        # carrying a control character forges a log line; one carrying `/` or
        # `..` addresses a sibling resource. New-SandboxLabelName can never
        # produce either, so a malformed `squad-` label is a squatter or an
        # attack. Refusing loudly beats skipping it: skipping under-counts the
        # concurrency ceiling, and that spends money.
        Assert-SandboxIdentifier -Value $label -Name "a sandbox label returned by 'aca sandbox list'" -Kind "label" -MaxLength 63 | Out-Null
        $status = "Unknown"
        if ($entry.PSObject.Properties.Name -contains "status") { $status = [string]$entry.status }
        $created = $null
        foreach ($property in @("createdAt", "creationTime", "startTime")) {
            if (($entry.PSObject.Properties.Name -contains $property) -and $entry.$property) {
                try { $created = [datetime]$entry.$property } catch { }
                if ($created) { break }
            }
        }
        $items += [pscustomobject]@{
            Label     = $label
            SessionId = (Get-SandboxSessionIdFromLabel -Label $label)
            Status    = $status
            CreatedAt = $created
        }
    }
    return $items
}

function Assert-SandboxConcurrencyBudget {
    <#
    .SYNOPSIS
        Refuse to create a sandbox that would exceed the class's concurrency
        ceiling -- BEFORE it exists.

    .DESCRIPTION
        Every sandbox bills from the moment it is created, so the cheapest place
        to enforce a ceiling is before the create call. `limits.maxConcurrentSandboxes`
        is administrator-owned per class (config/sandbox-classes.json); a class
        with no ceiling is a configuration error, not "unlimited" -- treating a
        missing ceiling as unlimited is how an unattended dispatcher runs up a
        bill nobody authorised.

        The failure is tagged `quota`, which is the whole point: PRD #6 requires
        quota exhaustion to be distinguishable from auth, capability, readiness
        and execution failures. A caller can retry a `quota` failure later; it
        must never retry a `capability` one.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [AllowEmptyString()][string]$SessionId = ""
    )

    $class = $Context.Class
    $limit = 0
    if ($class -and ($class.PSObject.Properties.Name -contains "limits") -and $class.limits) {
        if (($class.limits.PSObject.Properties.Name -contains "maxConcurrentSandboxes") -and $null -ne $class.limits.maxConcurrentSandboxes) {
            $limit = [int]$class.limits.maxConcurrentSandboxes
        }
    }
    if ($limit -le 0) {
        throw (New-SandboxFailure -Kind "config" -Message "Sandbox class '$($class.id)' declares no positive limits.maxConcurrentSandboxes. A missing ceiling is a configuration error, not 'unlimited': refusing to create a sandbox that nothing would bound.")
    }

    $live = @(Get-SquadSandboxInventory -Context $Context | Where-Object { $_.Status -ne "Deleted" -and $_.Status -ne "Terminated" })
    # A re-dispatch of the SAME session replaces its own sandbox; it must not
    # count against the ceiling twice or a retry could never succeed.
    $wanted = New-SandboxLabelName -SessionId ([string]$SessionId)
    $others = @($live | Where-Object { $_.Label -ne $wanted })

    if ($others.Count -ge $limit) {
        throw (New-SandboxFailure -Kind "quota" -Message "Sandbox class '$($class.id)' already has $($others.Count) live sandbox(es) and its ceiling is $limit. Refusing to create another. Wait for one to finish, terminate one ('squad-aca stop'), or raise limits.maxConcurrentSandboxes in config/sandbox-classes.json after a cost review.")
    }
    return $true
}

function Invoke-SquadSandboxReaper {
    <#
    .SYNOPSIS
        Delete orphaned `squad-` sandboxes (ADR 0001 risk R7).

    .DESCRIPTION
        Auto-suspend stops the meter for an idle sandbox but does not delete it,
        and an orchestrator that dies between `create` and `terminate` leaves one
        behind with nothing tracking it. The label prefix is what makes this
        decidable: only `squad-` sandboxes are ever considered, and a sandbox
        whose age cannot be established is left alone rather than guessed at.

        Defaults to a DRY RUN. A reaper that deletes by default is a footgun in
        exactly the situation you reach for it -- an incident, at speed.

    .PARAMETER MaxAgeMinutes
        Only sandboxes older than this are candidates. Defaults to twice the
        class's maxSessionMinutes (or 120), so a healthy long session is never a
        candidate.

    .PARAMETER KeepSessionIds
        Sessions the caller knows are live. Never candidates.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [int]$MaxAgeMinutes = 0,
        [string[]]$KeepSessionIds = @(),
        [switch]$Delete
    )

    if ($MaxAgeMinutes -le 0) {
        $session = 60
        if ($Context.Class -and ($Context.Class.PSObject.Properties.Name -contains "limits") -and $Context.Class.limits `
            -and ($Context.Class.limits.PSObject.Properties.Name -contains "maxSessionMinutes") -and $Context.Class.limits.maxSessionMinutes) {
            $session = [int]$Context.Class.limits.maxSessionMinutes
        }
        $MaxAgeMinutes = [math]::Max(120, $session * 2)
    }

    $cutoff = (Get-Date).AddMinutes(-1 * $MaxAgeMinutes)
    $keep = @{}
    foreach ($id in @($KeepSessionIds)) {
        if ($id) { $keep[(New-SandboxLabelName -SessionId ([string]$id))] = $true }
    }

    $candidates = @()
    $skipped = @()
    foreach ($item in @(Get-SquadSandboxInventory -Context $Context)) {
        if ($keep.ContainsKey($item.Label)) { continue }
        if ($null -eq $item.CreatedAt) {
            # Undecidable age. Report it; never delete on a guess.
            $skipped += $item.Label
            continue
        }
        if ($item.CreatedAt -le $cutoff) { $candidates += $item }
    }

    $deleted = @()
    $failed = @()
    if ($Delete) {
        foreach ($item in $candidates) {
            $result = Invoke-SandboxCli -Context $Context -Argv @("sandbox", "delete", "-l", "name=$($item.Label)", "--yes")
            if ($result.ExitCode -eq 0 -or (Test-SandboxGone -Result $result)) {
                $deleted += $item.Label
            } else {
                $failed += $item.Label
            }
        }
    }

    return [pscustomobject]@{
        MaxAgeMinutes  = $MaxAgeMinutes
        Candidates     = @($candidates | ForEach-Object { $_.Label })
        UndecidableAge = $skipped
        Deleted        = $deleted
        Failed         = $failed
        DryRun         = (-not $Delete)
    }
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

    # Credentials are DELIBERATELY absent here. An `env NAME=value` assignment in
    # the launch command is argv, and argv inside the sandbox is readable by
    # every process in it via /proc/<pid>/cmdline for the whole run. The Copilot
    # plane is brokered by the platform (`sandbox create --credential <id>`); the
    # git/`gh` plane is staged by a stdin-fed exec into a umask-077 file that the
    # launch command sources and deletes. Nothing secret belongs in this map --
    # adding a token back here silently re-opens the disclosure.
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
        if ($script:SandboxSecretEnvNames -contains $name) {
            throw (New-SandboxFailure -Kind "capability" -Message "Refusing to launch the worker: '$name' carries a credential and must not be an 'env NAME=value' assignment. Argv is readable by every process in the sandbox; credentials are staged on stdin instead.")
        }
        $assignments += "$name=$(ConvertTo-SandboxShellSingleQuoted ([string]$Environment[$name]))"
    }

    # Credentials staged by the stdin-fed seed exec are sourced here and deleted
    # in the same command, so they exist on disk only between two execs and never
    # appear in any argv. The `[ -f ]` guard keeps the launch working unchanged
    # when there is nothing to stage (and is what lets the detachment probe run
    # the shipping command with no credentials at all).
    $creds = "$StateDir/$($script:SandboxCredentialFileName)"
    $loadCreds = "if [ -f $creds ]; then . $creds; rm -f $creds; fi; "

    $inner = $loadCreds + "env " + ($assignments -join " ") + " $Entrypoint >> $StateDir/session.log 2>&1; " +
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
    #   1. prove the group is identity-free   (invariant 4)
    #   2. enforce the concurrency ceiling     <- before anything starts billing
    #   3. broker credentials on the group     (tokens on stdin, never argv)
    #   4. create the sandbox, referencing the credentials by opaque id
    #   5. apply default-deny egress           (invariant 3)
    #   6. pin auto-suspend
    #   7. stage the git credential on stdin   (never argv)
    #   8. launch the worker DETACHED          <- the first repository code to run
    # Any failure after step 3 revokes the brokered credentials and tears the
    # sandbox down, so repository code can never run in a sandbox whose egress
    # policy was not applied, and a failed dispatch never leaves a live
    # credential on the group.
    $operations["create"] = {
        param($Context, $Arguments)

        $request = $Arguments["Request"]
        if (-not $request) { throw (New-SandboxFailure -Kind "config" -Message "The Sandboxes provider requires a dispatch request.") }

        Assert-SandboxGroupIdentityFree -Context $Context | Out-Null

        $class = $Context.Class
        # Cost ceiling before anything exists. A sandbox bills from creation, so
        # this is the only place the check is free.
        Assert-SandboxConcurrencyBudget -Context $Context -SessionId ([string]$request.sessionId) | Out-Null

        $diskId = $Context.DiskId
        if (-not $diskId) {
            if (-not $Context.DiskLabel) {
                throw (New-SandboxFailure -Kind "config" -Message "No sandbox disk configured. Set a disk id (or a disk label to resolve) before dispatching to a sandbox; '--disk' accepts public images only, so a private image needs '--disk-id <GUID>'.")
            }
            $diskId = Resolve-SandboxDiskId -Context $Context -DiskLabel $Context.DiskLabel
        }
        # The disk id reaches an argv. Whether it came from config or from the
        # service's own listing, a value starting with '-' is a FLAG, not data.
        Assert-SandboxIdentifier -Value $diskId -Name "the sandbox disk id" -Kind "guid" -MaxLength 64 | Out-Null

        $name = New-SandboxLabelName -SessionId ([string]$request.sessionId)
        Assert-SandboxIdentifier -Value $name -Name "the sandbox label" -Kind "label" -MaxLength 63 | Out-Null

        # --- egress policy, generated and validated BEFORE anything exists ---
        # Generating it here means a widening attempt costs nothing: no sandbox
        # is created, no credential is brokered, nothing bills.
        $requestedHosts = @()
        if ($request.PSObject.Properties.Name -contains "capabilityResolution" -and $request.capabilityResolution) {
            if ($request.capabilityResolution.PSObject.Properties.Name -contains "egressHosts") {
                $requestedHosts = @($request.capabilityResolution.egressHosts | Where-Object { $_ })
            }
        }
        $policy = New-SandboxEgressPolicy -Class $class -RequestedHosts $requestedHosts

        $cpu = [int]([math]::Max(1, [double]$class.resources.cpu))
        $memory = [int]([math]::Max(1, [double]$class.resources.memoryGi))

        # --- credential brokerage (PRD #6 Sprint 7) --------------------------
        # The Copilot plane is a platform primitive: the token goes in on stdin,
        # an opaque id comes back, and the sandbox references the id. The token
        # never appears in an argument vector on either side of the boundary.
        $credentialIds = @()
        $copilot = ""
        if ($Context.WorkerSecrets -and $Context.WorkerSecrets.Contains("COPILOT_GITHUB_TOKEN")) {
            $copilot = [string]$Context.WorkerSecrets["COPILOT_GITHUB_TOKEN"]
        }
        if ($copilot) {
            $credentialIds += (New-SandboxBrokeredCredential -Context $Context -Type "github-copilot" -Token $copilot)
        }

        $createArgv = @(
            "sandbox", "create",
            "--disk-id", $diskId,
            "--label", "name=$name",
            "--cpu", "$($cpu * 1000)m",
            "--memory", "$($memory * 1024)Mi"
        )
        foreach ($credentialId in $credentialIds) { $createArgv += @("--credential", $credentialId) }

        $created = $null
        try {
            $created = Invoke-SandboxCli -Context $Context -Argv $createArgv
        } catch {
            foreach ($credentialId in $credentialIds) { Remove-SandboxBrokeredCredential -Context $Context -CredentialId $credentialId | Out-Null }
            throw
        }
        if ($created.ExitCode -ne 0) {
            foreach ($credentialId in $credentialIds) { Remove-SandboxBrokeredCredential -Context $Context -CredentialId $credentialId | Out-Null }
            $kind = Get-SandboxFailureKind -Result $created
            if (-not $kind) { $kind = "execution" }
            throw (New-SandboxFailure -Kind $kind -Message "Could not create sandbox '$name' ($($created.SafeArgv), exit $($created.ExitCode)): $(Get-SandboxErrorText -Result $created -Secrets $Context.Secrets)")
        }

        $handle = New-SandboxExecutionHandle -SandboxName $name -SessionId ([string]$request.sessionId) `
            -ClassId ([string]$class.id) -SandboxGroup ([string]$Context.SandboxGroup) -CredentialIds $credentialIds

        try {
            # --- egress FIRST, before anything from the repository runs ------
            $egressArgv = @("sandbox", "egress", "set", "-l", "name=$name",
                "--default", $policy.DefaultAction)
            foreach ($rule in @($policy.Rules)) {
                $egressArgv += @("--rule", "$($rule.Pattern):$($rule.Action)")
            }
            $egressArgv += @("--traffic-inspection", $policy.TrafficInspection)

            $egress = Invoke-SandboxCli -Context $Context -Argv $egressArgv
            if ($egress.ExitCode -ne 0) {
                $kind = Get-SandboxFailureKind -Result $egress
                if (-not $kind) { $kind = "execution" }
                throw (New-SandboxFailure -Kind $kind -Message "Could not apply the egress policy to sandbox '$name' ($($egress.SafeArgv), exit $($egress.ExitCode)): $(Get-SandboxErrorText -Result $egress -Secrets $Context.Secrets). Refusing to run repository code without default-deny egress (PRD #6 invariant 3).")
            }

            # --- auto-suspend, pinned ----------------------------------------
            $lifecycle = Invoke-SandboxCli -Context $Context -Argv @(
                "sandbox", "lifecycle", "set", "-l", "name=$name",
                "--auto-suspend", "enable",
                "--idle-timeout-seconds", "$($Context.IdleTimeoutSeconds)"
            )
            if ($lifecycle.ExitCode -ne 0) {
                $kind = Get-SandboxFailureKind -Result $lifecycle
                if (-not $kind) { $kind = "execution" }
                throw (New-SandboxFailure -Kind $kind -Message "Could not set the auto-suspend policy on sandbox '$name' ($($lifecycle.SafeArgv), exit $($lifecycle.ExitCode)): $(Get-SandboxErrorText -Result $lifecycle -Secrets $Context.Secrets). Auto-suspend defaults to 600s, which would suspend a running session.")
            }

            # --- stage the git/`gh` credential on STDIN ----------------------
            # The platform brokers no type for a plain push token, so it is
            # delivered on the stdin of this exec into a umask-077 file that the
            # launch command sources and deletes. It is in no argv on either
            # side of the boundary.
            $gitToken = ""
            foreach ($candidate in @("GH_TOKEN", "GITHUB_TOKEN")) {
                if ($Context.WorkerSecrets -and $Context.WorkerSecrets.Contains($candidate) -and $Context.WorkerSecrets[$candidate]) {
                    $gitToken = [string]$Context.WorkerSecrets[$candidate]
                    break
                }
            }
            if ($gitToken) {
                if ($gitToken -notmatch $script:SandboxTokenPattern) {
                    throw (New-SandboxFailure -Kind "capability" -Message "Refusing to stage the git credential: it contains characters outside the unreserved set, which could break out of the quoting in the staged credential file. The value is not echoed.")
                }
                $seed = New-SandboxCredentialSeedCommand -StateDir $Context.StateDir
                $staged = Invoke-SandboxCliWithSecretStdin -Context $Context -Secret $gitToken -Argv @(
                    "sandbox", "exec", "-l", "name=$name", "-c", $seed
                )
                if ($staged.ExitCode -ne 0) {
                    $kind = Get-SandboxFailureKind -Result $staged
                    if (-not $kind) { $kind = "execution" }
                    throw (New-SandboxFailure -Kind $kind -Message "Could not stage the git credential in sandbox '$name' ($($staged.SafeArgv), exit $($staged.ExitCode)): $(Get-SandboxErrorText -Result $staged -Secrets $Context.Secrets)")
                }
            }

            # --- launch, DETACHED --------------------------------------------
            $environment = New-SandboxWorkerEnvironment -Request $request -Context $Context
            $launch = New-SandboxLaunchCommand -Environment $environment -StateDir $Context.StateDir
            $launched = Invoke-SandboxCli -Context $Context -Argv @("sandbox", "exec", "-l", "name=$name", "-c", $launch)
            if ($launched.ExitCode -ne 0) {
                $kind = Get-SandboxFailureKind -Result $launched
                if (-not $kind) { $kind = "execution" }
                throw (New-SandboxFailure -Kind $kind -Message "Could not launch the worker in sandbox '$name' ($($launched.SafeArgv), exit $($launched.ExitCode)): $(Get-SandboxErrorText -Result $launched -Secrets $Context.Secrets)")
            }
        } catch {
            # Leaving a sandbox that has no policy, or one with policy but no
            # worker, is a leak and a cost -- and a brokered credential that
            # outlives its failed dispatch is readable to anyone with group read
            # access (ADR 0001 risk R2). Teardown is best-effort so the ORIGINAL
            # failure is what the caller sees; `terminate` revokes the
            # credentials recorded in the handle.
            try { & $Context.Self.Operations["terminate"] $Context @{ Handle = $handle } | Out-Null } catch { }
            throw
        }

        $narrowNote = if ($policy.Narrowed) { " (egress narrowed to the $($policy.Rules.Count) destination(s) the manifest requested)" } else { "" }
        Write-Host "[squad-aca] sandbox ${name}: created, default-deny egress applied$narrowNote, worker launched detached."

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
                # the session id is what a reaper matches on. The label is
                # service-supplied and lands in a handle and in later argv, so it
                # is validated here for the same reason as in
                # Get-SquadSandboxInventory.
                if ($label -notlike "squad-*") { continue }
                Assert-SandboxIdentifier -Value $label -Name "a sandbox label returned by 'aca sandbox list'" -Kind "label" -MaxLength 63 | Out-Null
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
                   "rm -f $stateDir/$($script:SandboxCredentialFileName); " +
                   "printf %s 143 > $stateDir/exit-code; " +
                   "printf %s cancelled > $stateDir/phase; " +
                   "touch $stateDir/done; echo squad-cancelled"

        $result = Invoke-SandboxCli -Context $Context -Argv @("sandbox", "exec", "-l", "name=$($payload.name)", "-c", $command)
        foreach ($line in @($result.StdOut)) {
            Write-Host (Protect-SandboxText -Text ([string]$line) -Secrets $Context.Secrets)
        }

        # The session is over, so its brokered credentials must not outlive it --
        # they live on the GROUP and are readable to anyone with group read
        # access (ADR 0001 risk R2). This runs regardless of the cancel result:
        # a cancel we could not confirm is exactly when a live credential is
        # most dangerous. Revocation never throws.
        $credentialIds = @()
        if ($payload.PSObject.Properties.Name -contains "creds" -and $payload.creds) {
            $credentialIds = @($payload.creds | Where-Object { $_ })
        }
        $unrevoked = 0
        foreach ($credentialId in $credentialIds) {
            if (-not (Remove-SandboxBrokeredCredential -Context $Context -CredentialId $credentialId).Revoked) { $unrevoked++ }
        }
        if ($unrevoked -gt 0) {
            Write-Host "[squad-aca] WARNING: $unrevoked brokered credential(s) for this session could NOT be revoked and are still live on sandbox group '$($Context.SandboxGroup)'. Revoke them by hand and treat the tokens as exposed."
        }

        if ($result.ExitCode -eq 0) {
            return [pscustomobject]@{ Cancelled = $true; AlreadyTerminal = $false; CredentialsUnrevoked = $unrevoked }
        }
        if (Test-SandboxGone -Result $result) {
            return [pscustomobject]@{ Cancelled = $true; AlreadyTerminal = $true; CredentialsUnrevoked = $unrevoked }
        }

        $inconclusive = Test-SandboxTransportInconclusive -Result $result
        $why = if ($inconclusive) {
            "the failure is a transport timeout, which says nothing about whether the worker stopped"
        } else {
            "the failure is not 'already deleted or gone'"
        }
        $kind = Get-SandboxFailureKind -Result $result
        if (-not $kind) { $kind = "execution" }
        throw (New-SandboxFailure -Kind $kind -Message "Could not cancel the session in sandbox '$($payload.name)': '$($result.SafeArgv)' failed with exit $($result.ExitCode), and $why. $(Get-SandboxErrorText -Result $result -Secrets $Context.Secrets)")
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

        # Credentials are brokered on the GROUP, so they OUTLIVE the sandbox that
        # referenced them and remain readable to anyone with group read access
        # (ADR 0001 risk R2). Revocation therefore runs whether or not the delete
        # succeeded -- a sandbox we could not delete is exactly the case where a
        # live credential matters most. Revocation never throws; an unrevoked
        # credential is reported so it can be dealt with by hand.
        $credentialIds = @()
        if ($payload.PSObject.Properties.Name -contains "creds" -and $payload.creds) {
            $credentialIds = @($payload.creds | Where-Object { $_ })
        }
        $unrevoked = @()
        foreach ($credentialId in $credentialIds) {
            $revocation = Remove-SandboxBrokeredCredential -Context $Context -CredentialId $credentialId
            if (-not $revocation.Revoked) { $unrevoked += $credentialId }
        }
        if ($unrevoked.Count -gt 0) {
            Write-Host "[squad-aca] WARNING: $($unrevoked.Count) brokered credential(s) for this session could NOT be revoked and are still live on sandbox group '$($Context.SandboxGroup)'. Revoke them by hand ('aca sandboxgroup credential delete --id <id> --yes') and treat the tokens as exposed."
        }

        if ($result.ExitCode -eq 0) {
            return [pscustomobject]@{ Terminated = $true; AlreadyTerminal = $false; CredentialsRevoked = ($credentialIds.Count - $unrevoked.Count); CredentialsUnrevoked = $unrevoked.Count }
        }
        if (Test-SandboxGone -Result $result) {
            return [pscustomobject]@{ Terminated = $true; AlreadyTerminal = $true; CredentialsRevoked = ($credentialIds.Count - $unrevoked.Count); CredentialsUnrevoked = $unrevoked.Count }
        }

        $inconclusive = Test-SandboxTransportInconclusive -Result $result
        $why = if ($inconclusive) {
            "the failure is a transport timeout, which says nothing about whether the sandbox still exists"
        } else {
            "the failure is not 'already deleted or gone'"
        }
        $kind = Get-SandboxFailureKind -Result $result
        if (-not $kind) { $kind = "execution" }
        throw (New-SandboxFailure -Kind $kind -Message "Could not terminate sandbox '$($payload.name)': '$($result.SafeArgv)' failed with exit $($result.ExitCode), and $why. $(Get-SandboxErrorText -Result $result -Secrets $Context.Secrets)")
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
