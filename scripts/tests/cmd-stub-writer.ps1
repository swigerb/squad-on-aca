<#
.SYNOPSIS
    Shared, test-only writer for the generated `.cmd` stub shims.

.DESCRIPTION
    Every offline stub harness under scripts/tests (and the logs-fallback stub in
    scripts/validate.ps1) writes a fake `az` / `gh` / `squad` / `curl` / `aca`
    as a `.cmd` file from a PowerShell here-string. A here-string takes the line
    endings of the source file that contains it, so on an LF checkout
    (core.autocrlf off, or a worktree created that way) the shim is LF-only.
    cmd.exe reads an LF-only batch file wrongly, and `goto <label>` then fails
    with "The system cannot find the batch label specified" -- which is how the
    sandbox terminate and `squad-aca stop` checks broke on such a checkout.

    Write-SquadCliCmdStub normalises the content to CRLF before writing, so a
    shim is byte-identical whatever the checkout's line endings were. It is a
    plain function with no state: dot-source it from any harness that writes a
    .cmd stub.

    Note: intentionally no Set-StrictMode / $ErrorActionPreference here. This file
    is dot-sourced into the caller's scope and must not change its behaviour.
#>

function Write-SquadCliCmdStub {
    <#
    .SYNOPSIS
        Writes a .cmd shim as ASCII with CRLF line endings and exactly one
        trailing CRLF, whatever line endings the caller's source had.

    .PARAMETER LiteralPath
        The .cmd file to write.

    .PARAMETER Value
        The shim text (LF, CRLF or mixed).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $crlfValue = [regex]::Replace($Value, "\r\n|\r|\n", "`r`n")
    if (-not $crlfValue.EndsWith("`r`n")) { $crlfValue += "`r`n" }
    Set-Content -LiteralPath $LiteralPath -Value $crlfValue -Encoding ascii -NoNewline
}
