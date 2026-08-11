# Log retrieval for Squad on ACA session executions.
#
# `az containerapp job logs show` is the only command the control plane uses
# that lives in the `containerapp` Azure CLI *extension*; everything else
# (`job start`, `job stop`, `job execution list/show`, `containerapp list`) is
# core `az`. On hosts where the extension cannot be installed the old inline
# call printed an argparse traceback, blocked on an interactive install prompt,
# and still returned exit 0 (GitHub issue #13).
#
# This module fixes both halves of that:
#   * every `az` invocation runs with dynamic extension install disabled, so a
#     missing extension is a clean non-zero error instead of a stdin block;
#   * every `az` invocation has its exit code inspected, and a failure that
#     produced no logs can never be reported as success.
#
# When the extension path is unavailable, logs are read from the Log Analytics
# workspace the deployment already provisions (`law-squad-aca`). That fallback
# does require the `log-analytics` az extension; what it does not require is the
# `containerapp` extension. If neither path works the caller gets a terminating
# error with actionable guidance.

$script:AcaDefaultLogAnalyticsWorkspace = "law-squad-aca"

function Invoke-CliSafe {
    <#
    .SYNOPSIS
        Run an external CLI and capture stdout, stderr and the REAL exit code.

    .DESCRIPTION
        The single mechanism every provider uses to shell out. Two properties
        matter and both are security properties, not conveniences:

          * The exit code is the one this invocation produced. When the binary
            cannot be run at all the result is exit 127, never a stale
            $LASTEXITCODE left by an earlier command -- which is exactly how a
            teardown that never ran once read as "successfully torn down".
          * Native stderr is captured instead of surfacing as a PowerShell error
            record, so the CALLER decides what a non-zero exit means.

        Invoke-AzPromptSafe (for `az`) and the Sandboxes provider (for `aca`)
        both delegate here. There is deliberately only one implementation: a
        second one would drift, and the classification built on top of it
        (Test-AcaJobExecutionGone) would then be reasoning about differently
        shaped results.

    .PARAMETER FilePath
        The executable to run. May be a bare command name resolved from PATH or
        an absolute path.

    .PARAMETER Arguments
        Argument vector, passed through unchanged.

    .PARAMETER EnvironmentOverrides
        Environment variables set for the duration of the call only. Every
        previous value is restored afterwards, including when the call throws,
        and a variable that did not exist before is removed again rather than
        left behind as an empty string.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [System.Collections.IDictionary]$EnvironmentOverrides = @{}
    )

    $saved = @{}
    $had = @{}
    foreach ($name in @($EnvironmentOverrides.Keys)) {
        $had[$name] = (Test-Path "Env:$name")
        $saved[$name] = if ($had[$name]) { [Environment]::GetEnvironmentVariable($name, "Process") } else { $null }
    }
    $previousEap = $ErrorActionPreference

    $merged = @()
    $exitCode = -1
    try {
        foreach ($name in @($EnvironmentOverrides.Keys)) {
            [Environment]::SetEnvironmentVariable($name, [string]$EnvironmentOverrides[$name], "Process")
        }
        # Native stderr merged into the pipeline would become a terminating
        # NativeCommandError under 'Stop'. Exit codes are inspected explicitly
        # by callers, so relax the preference only around the invocation itself.
        $ErrorActionPreference = "Continue"
        $merged = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $merged = @($_.Exception.Message)
        $exitCode = 127
    } finally {
        $ErrorActionPreference = $previousEap
        foreach ($name in @($EnvironmentOverrides.Keys)) {
            if ($had[$name]) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
            } else {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }

    $stdout = @()
    $stderr = @()
    foreach ($line in @($merged)) {
        if ($null -eq $line) { continue }
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            $stderr += [string]$line
        } else {
            $stdout += [string]$line
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Invoke-CliSafeWithStdin {
    <#
    .SYNOPSIS
        Run an external CLI, feeding a SECRET to it on standard input, and
        capture stdout, stderr and the REAL exit code.

    .DESCRIPTION
        The companion to Invoke-CliSafe for the one thing Invoke-CliSafe cannot
        do: hand a credential to a process without that credential ever being an
        argument.

        Why this exists at all. An argument vector is not private. On Linux it is
        world-readable at /proc/<pid>/cmdline for the life of the process, it is
        what `ps` prints, it is what a shell writes to its history, and it is what
        every CLI wrapper in this repository renders into an error message. A
        token passed as `--token <value>` is therefore disclosed to every other
        process on the box, and redaction (Get-SandboxSafeArgv) only protects the
        rendering, not the kernel-visible argv. Standard input has none of those
        properties: it is a pipe between exactly two processes.

        `aca sandboxgroup credential create` documents that the token may be
        omitted from the command line and read from stdin, so this is the
        platform's own supported path, not a workaround.

        Implementation notes that are load-bearing:

          * PowerShell's call operator cannot write to a child's stdin, so this
            drops to System.Diagnostics.Process directly. UseShellExecute must be
            false for redirection to be possible.
          * stdout and stderr are drained CONCURRENTLY (ReadToEndAsync on both
            before waiting). Reading one to the end before the other deadlocks as
            soon as a child fills the pipe buffer it is not being drained on.
          * The stdin writer uses a UTF8 encoding with NO byte-order mark. A BOM
            would be prepended to the token and the service would reject it with
            an error that looks like a bad credential.
          * A trailing newline IS written: line-oriented readers (`read`,
            `set /p`, most CLIs) block forever without it.
          * The secret is never placed in $Arguments, never in an environment
            variable, and is not returned in the result.
          * A binary that cannot be started reports exit 127, matching
            Invoke-CliSafe, so callers classify both the same way.

    .PARAMETER StandardInput
        The text written to the child's stdin. Treated as a secret: it is not
        logged, not echoed, and not included in the returned object.

    .OUTPUTS
        The same shape Invoke-CliSafe returns: ExitCode, StdOut, StdErr.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [AllowEmptyString()][string]$StandardInput = "",
        [System.Collections.IDictionary]$EnvironmentOverrides = @{},
        [int]$TimeoutSeconds = 120
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($arg in @($Arguments)) { $psi.ArgumentList.Add([string]$arg) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($name in @($EnvironmentOverrides.Keys)) {
        $psi.Environment[[string]$name] = [string]$EnvironmentOverrides[$name]
    }

    $stdout = ""
    $stderr = ""
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        if (-not $process.Start()) {
            return [pscustomobject]@{ ExitCode = 127; StdOut = @(); StdErr = @("could not start '$FilePath'") }
        }

        # Start draining BOTH pipes before anything can block on them.
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()

        # No BOM, and a terminating newline so a line-oriented reader on the far
        # side actually returns.
        $writer = [System.IO.StreamWriter]::new($process.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($false))
        try {
            $writer.Write([string]$StandardInput)
            $writer.Write("`n")
            $writer.Flush()
        } finally {
            $writer.Dispose()
        }

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            return [pscustomobject]@{
                ExitCode = 124
                StdOut   = @()
                StdErr   = @("timed out after ${TimeoutSeconds}s")
            }
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = @(($stdout -split "`r?`n") | Where-Object { $_ -ne "" })
            StdErr   = @(($stderr -split "`r?`n") | Where-Object { $_ -ne "" })
        }
    } catch {
        return [pscustomobject]@{ ExitCode = 127; StdOut = @(); StdErr = @([string]$_.Exception.Message) }
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Invoke-AzPromptSafe {
    <#
    .SYNOPSIS
        Run `az` with dynamic extension install disabled and capture its result.

    .DESCRIPTION
        Sets AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no for the duration of the call
        so a missing extension fails fast instead of prompting on stdin (which
        blocks forever in CI, Ralph, and Watch contexts). The previous value of
        the variable is always restored, including when the call throws.

        Native stderr is captured rather than allowed to surface as a
        PowerShell error record, so callers decide what a non-zero exit means.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$AzArgs
    )

    return Invoke-CliSafe -FilePath "az" -Arguments $AzArgs -EnvironmentOverrides @{
        AZURE_EXTENSION_USE_DYNAMIC_INSTALL = "no"
    }
}

function Test-AzExtension {
    <#
    .SYNOPSIS
        Report whether an Azure CLI extension is installed, without installing it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )
    $result = Invoke-AzPromptSafe -AzArgs @("extension", "show", "--name", $Name, "--only-show-errors", "-o", "none")
    return ($result.ExitCode -eq 0)
}

function Get-AzErrorText {
    param([object]$Result, [string]$Fallback = "no error output")
    $text = (@($Result.StdErr) + @($Result.StdOut) | Where-Object { $_ -and $_.Trim() }) -join " "
    $text = $text.Trim()
    if (-not $text) { return $Fallback }
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + "..." }
    return $text
}

function Get-AcaLogAnalyticsQuery {
    <#
    .SYNOPSIS
        Build the KQL that returns the last $Tail console lines for an execution.

    .DESCRIPTION
        `top N by TimeGenerated desc` selects the MOST RECENT N rows (matching
        --tail semantics), then the rows are re-sorted ascending so the output
        reads chronologically like the native log stream.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionName,
        [int]$Tail = 100
    )
    if ($Tail -le 0) { $Tail = 100 }
    $safeExecution = $ExecutionName.Replace("'", "''")
    return "ContainerAppConsoleLogs_CL | where ContainerGroupName_s startswith '$safeExecution' | top $Tail by TimeGenerated desc | project TimeGenerated, Log_s | order by TimeGenerated asc"
}

function Get-AcaExecutionLog {
    <#
    .SYNOPSIS
        Return console log lines for one ACA job execution.

    .DESCRIPTION
        Preference order:
          1. `az containerapp job logs show` (nicer, but needs the containerapp
             extension).
          2. Log Analytics (`ContainerAppConsoleLogs_CL`) against the workspace
             the deployment provisions - requires the log-analytics extension,
             but not the containerapp extension.

        Every `az` exit code is inspected. If both paths fail the function
        throws, so the caller exits non-zero instead of reporting a silent
        success.

    .OUTPUTS
        [pscustomobject] with Source ('containerapp-extension' | 'log-analytics'),
        Workspace, and Lines.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$JobName,
        [Parameter(Mandatory = $true)][string]$ExecutionName,
        [string]$ContainerName = "",
        [int]$Tail = 100,
        [string]$WorkspaceName = ""
    )

    if (-not $ContainerName) { $ContainerName = $JobName }
    if ($Tail -le 0) { $Tail = 100 }
    if (-not $WorkspaceName) { $WorkspaceName = $script:AcaDefaultLogAnalyticsWorkspace }

    $nativeReason = ""
    if (Test-AzExtension -Name "containerapp") {
        $native = Invoke-AzPromptSafe -AzArgs @(
            "containerapp", "job", "logs", "show",
            "--name", $JobName,
            "--resource-group", $ResourceGroup,
            "--execution", $ExecutionName,
            "--container", $ContainerName,
            "--tail", ([string]$Tail),
            "--only-show-errors"
        )
        if ($native.ExitCode -eq 0) {
            return [pscustomobject]@{
                Source    = "containerapp-extension"
                Workspace = ""
                Lines     = @($native.StdOut)
            }
        }
        $nativeReason = "'az containerapp job logs show' failed (exit $($native.ExitCode)): $(Get-AzErrorText $native)"
    } else {
        $nativeReason = "the 'containerapp' Azure CLI extension is not installed"
    }

    $workspaceShow = Invoke-AzPromptSafe -AzArgs @(
        "monitor", "log-analytics", "workspace", "show",
        "--resource-group", $ResourceGroup,
        "--workspace-name", $WorkspaceName,
        "--query", "customerId",
        "-o", "tsv",
        "--only-show-errors"
    )
    $workspaceId = ""
    if ($workspaceShow.ExitCode -eq 0) {
        $workspaceId = (@($workspaceShow.StdOut) -join "").Trim()
    }
    if ($workspaceShow.ExitCode -ne 0 -or -not $workspaceId) {
        $detail = if ($workspaceShow.ExitCode -ne 0) {
            "could not resolve workspace '$WorkspaceName' in resource group '$ResourceGroup' (exit $($workspaceShow.ExitCode)): $(Get-AzErrorText $workspaceShow)"
        } else {
            "workspace '$WorkspaceName' in resource group '$ResourceGroup' returned an empty customerId"
        }
        throw (New-AcaLogFailureMessage -ExecutionName $ExecutionName -ResourceGroup $ResourceGroup -WorkspaceName $WorkspaceName -NativeReason $nativeReason -FallbackReason $detail)
    }

    $query = Get-AcaLogAnalyticsQuery -ExecutionName $ExecutionName -Tail $Tail
    $queryResult = Invoke-AzPromptSafe -AzArgs @(
        "monitor", "log-analytics", "query",
        "-w", $workspaceId,
        "--analytics-query", $query,
        "-o", "json",
        "--only-show-errors"
    )
    if ($queryResult.ExitCode -ne 0) {
        $detail = "the Log Analytics query failed (exit $($queryResult.ExitCode)): $(Get-AzErrorText $queryResult)"
        throw (New-AcaLogFailureMessage -ExecutionName $ExecutionName -ResourceGroup $ResourceGroup -WorkspaceName $WorkspaceName -NativeReason $nativeReason -FallbackReason $detail)
    }

    $rows = @()
    $raw = (@($queryResult.StdOut) -join "`n").Trim()
    if ($raw) {
        $parsed = $null
        try {
            $parsed = ConvertFrom-Json -InputObject $raw
        } catch {
            $detail = "the Log Analytics query returned output that is not valid JSON: $($_.Exception.Message)"
            throw (New-AcaLogFailureMessage -ExecutionName $ExecutionName -ResourceGroup $ResourceGroup -WorkspaceName $WorkspaceName -NativeReason $nativeReason -FallbackReason $detail)
        }
        # Windows PowerShell 5.1 emits a JSON array as ONE unenumerated object,
        # while PowerShell 7 unrolls it. squad-aca runs under 5.1 through the
        # .cmd shim, so flatten explicitly instead of relying on host behaviour.
        foreach ($item in @($parsed)) {
            if ($null -eq $item) { continue }
            $rows += $item
        }
    }

    $lines = @()
    foreach ($row in $rows) {
        if ($null -eq $row) { continue }
        if ($row.PSObject.Properties.Name -contains "Log_s") {
            $lines += [string]$row.Log_s
        } else {
            $lines += [string]$row
        }
    }

    return [pscustomobject]@{
        Source    = "log-analytics"
        Workspace = $WorkspaceName
        Lines     = $lines
    }
}

function New-AcaLogFailureMessage {
    param(
        [string]$ExecutionName,
        [string]$ResourceGroup,
        [string]$WorkspaceName,
        [string]$NativeReason,
        [string]$FallbackReason
    )
    return @"
Could not retrieve logs for execution '$ExecutionName'. Both log paths failed.

  containerapp extension path : $NativeReason
  Log Analytics fallback      : $FallbackReason

Fix one of the following, then retry:

  1. Install the Container Apps CLI extension:
       az extension add --name containerapp

  2. Install the Log Analytics CLI extension and confirm the workspace exists:
       az extension add --name log-analytics
       az monitor log-analytics workspace show --resource-group $ResourceGroup --workspace-name $WorkspaceName

     If the deployment uses a different workspace name, point squad-aca at it:
       squad-aca configure --log-analytics-workspace <workspace-name>

Run 'squad-aca doctor' to see which log path is currently available.
"@
}

function Get-AcaLogPathStatus {
    <#
    .SYNOPSIS
        Informational summary of which log path `squad-aca logs` will use.
    #>
    param(
        [string]$WorkspaceName = ""
    )
    if (-not $WorkspaceName) { $WorkspaceName = $script:AcaDefaultLogAnalyticsWorkspace }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Status = "missing"; Detail = "az is not on PATH, so squad-aca logs cannot run" }
    }
    if (Test-AzExtension -Name "containerapp") {
        return [pscustomobject]@{ Status = "ok"; Detail = "containerapp extension present; logs uses 'az containerapp job logs show'" }
    }
    if (Test-AzExtension -Name "log-analytics") {
        return [pscustomobject]@{ Status = "fallback"; Detail = "containerapp extension missing; logs reads Log Analytics workspace '$WorkspaceName'" }
    }
    return [pscustomobject]@{ Status = "failed"; Detail = "neither the containerapp nor the log-analytics extension is installed; run 'az extension add --name log-analytics'" }
}

function Test-AcaAspireReachability {
    <#
    .SYNOPSIS
        Classify whether a configured Aspire dashboard URL is actually
        reachable (issue #90 finding 3): "ok" here always means a live probe
        proved the endpoint answers, never merely that a URL string exists in
        config.

    .DESCRIPTION
        Reachability is probed with `curl`, the same "one external binary is
        the whole test seam" shape Invoke-CliSafe/Invoke-AzPromptSafe already
        use for `az` -- a test puts a stub `curl` ahead of PATH and returns a
        canned exit code, with no network-stack fake and no dependency on a
        real hostname's behaviour.

        Both --connect-timeout and --max-time are set so neither DNS
        resolution nor a slow/black-holed response can hang doctor past
        $TimeoutSeconds: a stuck endpoint is reported "unknown", never "ok"
        and never an indefinite wait.

        curl's own documented exit codes classify the result:
          0            the endpoint answered -- ANY HTTP status (even 401 or
                       404) proves DNS resolved, TCP connected, and something
                       is listening, which is what "reachable" means here.
          28           OPERATION_TIMEDOUT: slow or black-holed -> "unknown".
          6, 7, other  COULDNT_RESOLVE_HOST / COULDNT_CONNECT / any other
                       transport failure -> "failed" (unreachable), never
                       "ok". Dead DNS is explicitly in this bucket.

    .OUTPUTS
        [pscustomobject] with Status ("ok" | "failed" | "unknown") and Detail.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 5
    )

    if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Status = "unknown"; Detail = "curl is not on PATH; cannot check whether '$Url' is reachable" }
    }

    $result = Invoke-CliSafe -FilePath "curl" -Arguments @(
        "--connect-timeout", ([string]$TimeoutSeconds),
        "--max-time", ([string]$TimeoutSeconds),
        "--silent",
        "--show-error",
        "--head",
        $Url
    )

    if ($result.ExitCode -eq 0) {
        return [pscustomobject]@{ Status = "ok"; Detail = $Url }
    }
    if ($result.ExitCode -eq 28) {
        return [pscustomobject]@{ Status = "unknown"; Detail = "Aspire URL '$Url' did not respond within ${TimeoutSeconds}s (slow or unreachable); rerun 'squad-aca doctor', or check the deployment if this persists" }
    }

    $reason = Get-AzErrorText -Result $result -Fallback "curl exited $($result.ExitCode)"
    return [pscustomobject]@{ Status = "failed"; Detail = "Aspire URL '$Url' is not reachable ($reason); redeploy, or run 'squad-aca configure --dashboard-url' with a working URL" }
}

