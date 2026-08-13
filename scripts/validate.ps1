#requires -Version 5.1
<#
.SYNOPSIS
    Local validation harness for Squad on ACA.

.DESCRIPTION
    This repository is script- and infrastructure-heavy, so there is no unit
    test project to run. validate.ps1 performs the checks that are practical to
    run locally and in CI without touching live Azure resources:

      1. PowerShell parse   - every scripts/*.ps1 is parsed with the PowerShell
                              language parser (syntax + tokenization).
      2. Bash syntax check  - `bash -n` on worker/entrypoint.sh and the
                              worker/lib/*.sh helpers when bash exists.
      3. Secret scan        - scans tracked docs/, scripts/, worker/, and
                              aspire/ for credential file patterns and inline
                              token signatures. Generated build output
                              (bin/, obj/, node_modules/) and binary files are
                              skipped.
      4. .NET scaffold check- validates the optional aspire/ integration scaffold
                              structure (solution + AppHost + agent contract
                              library), asserts the contract library has zero
                              package references, and runs `dotnet build` and
                              `dotnet test` whenever a dotnet SDK is on PATH
                              (-RunDotnet makes a missing SDK a failure).
      5. Env key parity     - session-managed env keys must match between the
                              PowerShell and worker dispatch paths.
      6. Sync guard         - regression tests for the public-repo secret guard.
      7. Logs fallback      - regression tests for `squad-aca logs` (issue #13):
                              exit-code propagation, suppressed interactive
                              extension install, and the Log Analytics fallback.
                              Uses a fake `az` on PATH; no Azure access.
      8. Provider contract  - the execution provider seam is exercised offline
                              against the filesystem-backed fake provider
                              (state transitions, idempotent terminate, handle
                              opacity, unknown/foreign handle rejection).
     8b. ACA Job adapter   - the PRODUCTION adapter is exercised against a
                              stubbed `az`: terminate on a live, gone, and
                              already-terminal execution, terminate under auth /
                              RBAC / throttling / network / missing-`az`
                              failures (all of which must surface as errors),
                              and wait's polling and timeout.
      9. CLI regression     - `squad-aca` is driven end to end with stub `az`
                              and `gh` binaries on PATH, asserting the observable
                              output (including `stop` stdout), exit codes, and
                              az call sequences that the provider refactor must
                              not change.
     10. CLI golden gate    - the committed golden captures cover every capture
                              case, CI actually runs
                              scripts/tests/verify-cli-golden.ps1, and the
                              harness still pins the environment (time zone,
                              culture, optional-tool availability) that makes
                              those goldens verify on a machine other than the
                              one that produced them.

    Exit code is 0 when all checks pass, 1 otherwise. Use this before pushing
    and as the E2E "sprint gate" documented in docs/validation.md.

.PARAMETER RunDotnet
    Strict mode for the .NET gate. `dotnet build` and `dotnet test` on the aspire
    solution ALWAYS run when a dotnet SDK is on PATH; a machine without one gets a
    counted SKIP. Passing -RunDotnet turns that SKIP into a failure, which is what
    CI uses so a missing SDK cannot quietly become a green run.

.PARAMETER SkipBash
    Skip the `bash -n` worker entrypoint check (for environments without bash).
#>
[CmdletBinding()]
param(
    [switch]$RunDotnet,
    [switch]$SkipBash
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

$script:Failures = @()
$script:Passes = @()
$script:Skips = @()

# $IsWindows only exists in PowerShell 6+; this file also has to run under 5.1.
$IsWindowsHost = if ($null -ne $PSVersionTable.Platform) { $PSVersionTable.Platform -eq "Win32NT" } else { $true }

function Write-Section($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Add-Pass($text) { $script:Passes += $text; Write-Host "  [PASS] $text" -ForegroundColor Green }
function Add-Fail($text) { $script:Failures += $text; Write-Host "  [FAIL] $text" -ForegroundColor Red }
# A check that could not execute is NEITHER a pass nor a failure. The worker
# suite established this (worker/tests/lib/deps.sh exits 77 and run-tests.sh
# reports it as SKIP, never as a pass); a validate.ps1 check with an external
# dependency has to be equally honest, because a skip that silently counted as
# a pass is a check that stops existing the moment the dependency goes missing.
function Add-Skip($text) { $script:Skips += $text; Write-Host "  [SKIP] $text" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 1. PowerShell parse
# ---------------------------------------------------------------------------
Write-Section "PowerShell parse"
$psFiles = Get-ChildItem -Path (Join-Path $RepoRoot "scripts") -Filter *.ps1 -File -Recurse
foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            Add-Fail ("{0}: {1} (line {2})" -f $file.Name, $e.Message, $e.Extent.StartLineNumber)
        }
    } else {
        Add-Pass "$($file.Name) parsed clean"
    }
}

# ---------------------------------------------------------------------------
# 2. Bash syntax check for the worker entrypoint
# ---------------------------------------------------------------------------
Write-Section "Worker bash scripts (bash -n)"
$bashScripts = @(
    (Join-Path $RepoRoot "worker\entrypoint.sh"),
    (Join-Path $RepoRoot "worker\lib\squad-capability-preflight.sh"),
    (Join-Path $RepoRoot "worker\lib\ralph-dispatch.sh"),
    (Join-Path $RepoRoot "worker\lib\git-checkout.sh"),
    (Join-Path $RepoRoot "worker\lib\squad-policy.sh"),
    (Join-Path $RepoRoot "worker\tests\test_agent_policy.sh"),
    (Join-Path $RepoRoot "worker\tests\test_governance_guard.sh"),
    (Join-Path $RepoRoot "worker\tests\test_image_evidence.sh"),
    (Join-Path $RepoRoot "worker\tests\test_manifest_path_corpus.sh")
)
if ($SkipBash) {
    Write-Host "  [SKIP] -SkipBash specified"
} else {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $bash) {
        Write-Host "  [SKIP] bash not available on PATH"
    } else {
        foreach ($script in $bashScripts) {
            $rel = if ($script.StartsWith($RepoRoot)) { $script.Substring($RepoRoot.Length + 1) } else { $script }
            if (-not (Test-Path $script)) {
                Add-Fail "$rel not found"
                continue
            }
            # Pipe CRLF-normalized content to `bash -n` via stdin so we avoid any
            # Windows<->bash path translation differences (WSL vs Git Bash).
            $raw = Get-Content -LiteralPath $script -Raw
            $lf = $raw -replace "`r`n", "`n"
            $lf | & $bash.Source -n
            if ($LASTEXITCODE -eq 0) {
                Add-Pass "$rel passed bash -n"
            } else {
                Add-Fail "$rel failed bash -n (exit $LASTEXITCODE)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Secret scan of tracked docs/, scripts/, and aspire/
# ---------------------------------------------------------------------------
Write-Section "Secret scan (docs + scripts + worker + aspire)"
$secretPatterns = @(
    @{ Name = "GitHub token";        Regex = 'gh[pousr]_[A-Za-z0-9]{30,}' },
    @{ Name = "GitHub fine PAT";     Regex = 'github_pat_[A-Za-z0-9_]{40,}' },
    @{ Name = "AWS access key";      Regex = 'AKIA[0-9A-Z]{16}' },
    @{ Name = "Private key block";   Regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = "Slack token";         Regex = 'xox[baprs]-[A-Za-z0-9-]{10,}' },
    @{ Name = "Azure storage key";   Regex = 'AccountKey=[A-Za-z0-9+/=]{40,}' },
    @{ Name = "OpenAI-style key";    Regex = 'sk-[A-Za-z0-9]{32,}' }
)
# Allow-listed placeholders that legitimately look token-ish in docs.
$allowList = @('secretref:', 'keyvaultref:', 'identityref:', '<', '>')

$scanRoots = @("docs", "scripts", "worker", "aspire") | ForEach-Object { Join-Path $RepoRoot $_ }
$scanFiles = foreach ($root in $scanRoots) {
    if (Test-Path $root) {
        # Skip generated build output (bin/, obj/) and installed dependencies
        # (node_modules/) so the scan stays fast and only covers
        # source-controlled, human-authored files.
        Get-ChildItem -Path $root -File -Recurse |
            Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules)\\' }
    }
}
# Extensions that are binary/compiled and never contain reviewable secrets.
$binaryExtensions = @(
    '.png', '.jpg', '.jpeg', '.gif', '.ico', '.pfx', '.pem',
    '.dll', '.exe', '.pdb', '.nupkg', '.zip', '.snk', '.cache', '.bin'
)
$secretHits = 0
foreach ($file in $scanFiles) {
    if ($file.Extension -in $binaryExtensions) { continue }
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    foreach ($p in $secretPatterns) {
        $matches = [regex]::Matches($content, $p.Regex)
        foreach ($m in $matches) {
            $isAllowed = $false
            foreach ($a in $allowList) { if ($m.Value.Contains($a)) { $isAllowed = $true; break } }
            if (-not $isAllowed) {
                $rel = $file.FullName.Substring($RepoRoot.Length + 1)
                Add-Fail "Possible $($p.Name) in $rel : $($m.Value.Substring(0, [Math]::Min(12, $m.Value.Length)))..."
                $secretHits++
            }
        }
    }
}
# Also flag credential filenames committed under docs/scripts.
$badNames = $scanFiles | Where-Object {
    $_.Name -match '(^\.env($|\.)|deploy\.outputs\.json$|\.pfx$|id_rsa|id_ed25519|appsettings.*\.Development\.json$)'
}
foreach ($bad in $badNames) {
    $rel = $bad.FullName.Substring($RepoRoot.Length + 1)
    Add-Fail "Credential-style file tracked under docs/scripts/aspire: $rel"
    $secretHits++
}
if ($secretHits -eq 0) { Add-Pass "No secret patterns found in docs/, scripts/, worker/, or aspire/" }

# ---------------------------------------------------------------------------
# 4. Optional .NET/Aspire scaffold structure
# ---------------------------------------------------------------------------
Write-Section ".NET/Aspire scaffold"
$aspireDir = Join-Path $RepoRoot "aspire"
if (-not (Test-Path $aspireDir)) {
    Write-Host "  [SKIP] optional aspire/ scaffold not present"
} else {
    $expected = @(
        "Squad.Aca.sln",
        "Squad.Aca.AppHost\Squad.Aca.AppHost.csproj",
        "Squad.Aca.AppHost\AppHost.cs",
        "Squad.Aca.Agents\Squad.Aca.Agents.csproj",
        "Squad.Aca.Agents\AgentAbstraction.cs",
        "Squad.Aca.Agents\AcaSquadAgent.cs",
        "Squad.Aca.Agents.Tests\Squad.Aca.Agents.Tests.csproj",
        "Squad.Aca.Agents.MAF\Squad.Aca.Agents.MAF.csproj",
        "Squad.Aca.Agents.MAF\SquadAcaAIAgent.cs",
        "Squad.Aca.Agents.MAF.Tests\Squad.Aca.Agents.MAF.Tests.csproj",
        "Squad.Aca.Agents.MAF.Sample\Squad.Aca.Agents.MAF.Sample.csproj",
        "Squad.Aca.Agents.MAF.Sample\Program.cs",
        "README.md"
    )
    foreach ($rel in $expected) {
        $full = Join-Path $aspireDir $rel
        if (Test-Path $full) { Add-Pass "aspire/$rel present" }
        else { Add-Fail "aspire/$rel missing" }
    }

    # Every .csproj under aspire/ must be well-formed XML.
    $csprojs = Get-ChildItem -Path $aspireDir -Filter *.csproj -File -Recurse
    foreach ($csproj in $csprojs) {
        try {
            [void][xml](Get-Content -LiteralPath $csproj.FullName -Raw)
            Add-Pass "$($csproj.Name) is valid XML"
        } catch {
            Add-Fail "$($csproj.Name) is not valid XML: $($_.Exception.Message)"
        }
    }

    # The agent contract library must stay free of package references. That is
    # what keeps a Sprint 2 preview restore failure from taking the contract --
    # and every consumer of it -- down with it. A comment saying so is not a
    # constraint; this is.
    $agentsCsproj = Join-Path $aspireDir "Squad.Aca.Agents\Squad.Aca.Agents.csproj"
    if (Test-Path $agentsCsproj) {
        $agentsXml = [xml](Get-Content -LiteralPath $agentsCsproj -Raw)
        $pkgRefs = @($agentsXml.SelectNodes("//PackageReference"))
        if ($pkgRefs.Count -eq 0) {
            Add-Pass "Squad.Aca.Agents has zero package references (no preview dependency)"
        } else {
            $names = ($pkgRefs | ForEach-Object { $_.Include }) -join ", "
            Add-Fail "Squad.Aca.Agents must have zero package references but has: $names"
        }
    } else {
        Add-Fail "aspire/Squad.Aca.Agents/Squad.Aca.Agents.csproj missing"
    }

    # The other half of the quarantine (issue #33 sprint 2). Asserting that the
    # contract has no packages only proves half of it: the MAF dependency also has
    # to actually exist somewhere, be PINNED, and flow in one direction only.
    # Without these, "zero package references" is satisfied just as well by an
    # adapter that was never written.
    $mafCsprojPath = Join-Path $aspireDir "Squad.Aca.Agents.MAF\Squad.Aca.Agents.MAF.csproj"
    if (Test-Path $mafCsprojPath) {
        $mafRaw = Get-Content -LiteralPath $mafCsprojPath -Raw
        $mafXml = [xml]$mafRaw

        $mafPkg = @($mafXml.SelectNodes("//PackageReference")) | Where-Object { $_.Include -eq "Microsoft.Agents.AI" }
        if ($mafPkg) {
            $mafVersion = $mafPkg.Version
            # An exact version, not a floating one. A `1.*` would let a routine
            # restore change the compiled surface of a shipped adapter with no
            # diff to review -- exactly the instability the quarantine exists for.
            if ($mafVersion -match '^\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$') {
                Add-Pass "Squad.Aca.Agents.MAF pins Microsoft.Agents.AI to an exact version ($mafVersion)"
            } else {
                Add-Fail "Squad.Aca.Agents.MAF must pin Microsoft.Agents.AI to an exact version but has '$mafVersion'"
            }
        } else {
            Add-Fail "Squad.Aca.Agents.MAF does not reference Microsoft.Agents.AI; the MAF adapter has no framework to adapt to"
        }

        # MEAI001 marks the Agent Framework's experimental background-response
        # surface (AgentRunOptions/AgentResponse.ContinuationToken). The adapter
        # uses it deliberately and suppresses the diagnostic in ONE file. A
        # project-wide <NoWarn> would silently opt every future file into an
        # unstable API -- the quarantine failure mode, one level down.
        if ($mafRaw -notmatch 'MEAI001') {
            Add-Pass "Squad.Aca.Agents.MAF does not suppress MEAI001 project-wide (the experimental surface stays in one file)"
        } else {
            Add-Fail "Squad.Aca.Agents.MAF suppresses MEAI001 in the csproj; the experimental Agent Framework surface must stay confined to SquadBackgroundResponse.cs"
        }

        # One direction only. If the contract ever referenced the adapter, a MAF
        # restore failure would take the contract down with it and the whole
        # separation would be decorative.
        $agentsRaw = if (Test-Path $agentsCsproj) { Get-Content -LiteralPath $agentsCsproj -Raw } else { "" }
        if ($agentsRaw -notmatch 'Squad\.Aca\.Agents\.MAF') {
            Add-Pass "Squad.Aca.Agents does not reference the MAF adapter (the dependency flows one way)"
        } else {
            Add-Fail "Squad.Aca.Agents references Squad.Aca.Agents.MAF; the quarantine is inverted"
        }
    } else {
        Add-Fail "aspire/Squad.Aca.Agents.MAF/Squad.Aca.Agents.MAF.csproj missing"
    }

    # `dotnet build`/`dotnet test` below drive the SOLUTION, so a project that is
    # not in it is a project CI never compiles and never tests. That failure is
    # invisible -- the build stays green because the code was never looked at --
    # so membership is asserted rather than assumed.
    $slnPath = Join-Path $aspireDir "Squad.Aca.sln"
    if (Test-Path $slnPath) {
        $slnText = Get-Content -LiteralPath $slnPath -Raw
        $missingFromSln = @()
        foreach ($proj in @(
            "Squad.Aca.Agents\Squad.Aca.Agents.csproj",
            "Squad.Aca.Agents.Tests\Squad.Aca.Agents.Tests.csproj",
            "Squad.Aca.Agents.MAF\Squad.Aca.Agents.MAF.csproj",
            "Squad.Aca.Agents.MAF.Tests\Squad.Aca.Agents.MAF.Tests.csproj",
            "Squad.Aca.Agents.MAF.Sample\Squad.Aca.Agents.MAF.Sample.csproj")) {
            if ($slnText -notlike "*$proj*") { $missingFromSln += $proj }
        }
        if ($missingFromSln.Count -eq 0) {
            Add-Pass "Every agent project is in Squad.Aca.sln, so the solution build and test gate covers it"
        } else {
            Add-Fail "Not in Squad.Aca.sln (so CI never builds or tests it): $($missingFromSln -join ', ')"
        }
    } else {
        Add-Fail "aspire/Squad.Aca.sln missing"
    }

    # The sample host is the ONLY project here that prints control-plane output to
    # a terminal, and live output is exactly where a token leaks. Every Console
    # write it makes must go through SecretRedactor, so this asserts the property
    # mechanically rather than trusting a reviewer to notice a bare
    # Console.WriteLine added later.
    $sampleDir = Join-Path $aspireDir "Squad.Aca.Agents.MAF.Sample"
    if (Test-Path $sampleDir) {
        $unredacted = @()
        foreach ($file in (Get-ChildItem -Path $sampleDir -Filter *.cs -File -Recurse |
                Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' })) {
            $lineNumber = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $lineNumber++
                if ($line -match 'Console\.(Out|Error)?\.?Write' -and $line -notmatch 'SecretRedactor\.Redact') {
                    $unredacted += "$($file.Name):$lineNumber"
                }
            }
        }
        if ($unredacted.Count -eq 0) {
            Add-Pass "Every Console write in the MAF sample host passes through SecretRedactor"
        } else {
            Add-Fail "MAF sample host writes to the console without redacting: $($unredacted -join ', ')"
        }
    } else {
        Add-Fail "aspire/Squad.Aca.Agents.MAF.Sample missing"
    }

    # .NET build AND test run whenever a dotnet SDK is present -- NOT behind
    # -RunDotnet. A test that only runs when someone remembers a flag is close to
    # no test at all, and these tests are the gate for the agent contract. They
    # are also fully offline (every one fakes ISquadCliInvoker), so there is no
    # brittleness argument for hiding them.
    #
    # A machine with no SDK gets a counted, visible SKIP -- never a silent pass --
    # mirroring worker/tests/lib/deps.sh's exit-77 convention. -RunDotnet is now
    # STRICT mode: it turns a missing SDK into a failure, which is what CI uses.
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        if ($RunDotnet) {
            Add-Fail "-RunDotnet specified but dotnet is not on PATH"
        } else {
            Add-Skip "dotnet build/test (no dotnet SDK on PATH)"
        }
    } else {
        Push-Location $aspireDir
        try {
            Write-Host "  Running dotnet build..."
            & $dotnet.Source build "Squad.Aca.sln" -nologo --verbosity quiet
            $buildExit = $LASTEXITCODE
            if ($buildExit -eq 0) { Add-Pass "dotnet build succeeded" }
            else { Add-Fail "dotnet build failed (exit $buildExit) - see docs/validation.md for preview-package guidance" }

            if ($buildExit -eq 0) {
                Write-Host "  Running dotnet test..."
                & $dotnet.Source test "Squad.Aca.sln" -nologo --no-build --verbosity quiet
                if ($LASTEXITCODE -eq 0) { Add-Pass "dotnet test succeeded" }
                else { Add-Fail "dotnet test failed (exit $LASTEXITCODE)" }
            } else {
                Add-Skip "dotnet test (build failed, so the result would be meaningless)"
            }
        } finally {
            Pop-Location
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Session-managed env key parity (PowerShell vs worker)
# ---------------------------------------------------------------------------
# Session isolation depends on dispatch stripping the SAME set of session-managed
# keys from the job template in both dispatch paths: the PowerShell control plane
# (scripts/lib/session-env.ps1) and the in-container worker (worker/lib/
# ralph-dispatch.sh). If the two lists drift, one path could leak a stale
# template value into a new session. Fail on any drift.
Write-Section "Session-managed env key parity"
$psEnvFile = Join-Path $RepoRoot "scripts\lib\session-env.ps1"
$shEnvFile = Join-Path $RepoRoot "worker\lib\ralph-dispatch.sh"

function Get-QuotedListBlock([string]$Text, [string]$StartMarker) {
    $idx = $Text.IndexOf($StartMarker)
    if ($idx -lt 0) { return $null }
    $rest = $Text.Substring($idx + $StartMarker.Length)
    $close = $rest.IndexOf(')')
    if ($close -lt 0) { return $null }
    return $rest.Substring(0, $close)
}

if (-not (Test-Path $psEnvFile)) {
    Add-Fail "scripts/lib/session-env.ps1 not found for env parity check"
} elseif (-not (Test-Path $shEnvFile)) {
    Add-Fail "worker/lib/ralph-dispatch.sh not found for env parity check"
} else {
    $psText = Get-Content -LiteralPath $psEnvFile -Raw
    $shText = Get-Content -LiteralPath $shEnvFile -Raw

    # PowerShell: keys are double-quoted inside $script:SessionManagedEnvKeys = @( ... )
    $psBlock = Get-QuotedListBlock $psText 'SessionManagedEnvKeys = @('
    $psKeys = @()
    if ($psBlock) {
        $psKeys = [regex]::Matches($psBlock, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    }

    # Bash: keys are bare, whitespace-separated inside RALPH_MANAGED_ENV_KEYS=( ... )
    $shBlock = Get-QuotedListBlock $shText 'RALPH_MANAGED_ENV_KEYS=('
    $shKeys = @()
    if ($shBlock) {
        $shKeys = ($shBlock -split '\s+') | Where-Object { $_ -and ($_ -notmatch '^#') }
    }

    if ($psKeys.Count -eq 0) {
        Add-Fail "Could not parse SessionManagedEnvKeys from session-env.ps1"
    } elseif ($shKeys.Count -eq 0) {
        Add-Fail "Could not parse RALPH_MANAGED_ENV_KEYS from ralph-dispatch.sh"
    } else {
        $psSet = $psKeys | Sort-Object -Unique
        $shSet = $shKeys | Sort-Object -Unique
        $onlyPs = $psSet | Where-Object { $_ -notin $shSet }
        $onlySh = $shSet | Where-Object { $_ -notin $psSet }
        if ($onlyPs.Count -gt 0 -or $onlySh.Count -gt 0) {
            if ($onlyPs.Count -gt 0) {
                Add-Fail "Session-managed env keys only in session-env.ps1 (missing from ralph-dispatch.sh): $($onlyPs -join ', ')"
            }
            if ($onlySh.Count -gt 0) {
                Add-Fail "Session-managed env keys only in ralph-dispatch.sh (missing from session-env.ps1): $($onlySh -join ', ')"
            }
        } else {
            Add-Pass "Session-managed env keys match across session-env.ps1 and ralph-dispatch.sh ($($psSet.Count) keys)"
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Sync guard covers every file `git add -A` would stage (NUL-delimited)
# ---------------------------------------------------------------------------
# Regression guard for the public-repo sync guard. Two historical bypasses are
# covered here:
#   1. Plain `git status --porcelain` collapses a brand-new directory to a
#      single entry, so nested secrets inside it would never be scanned even
#      though `git add -A` still stages them.
#   2. Non-ASCII / special-character paths are C-quoted and octal-escaped by
#      porcelain (e.g. "caf\303\251/config.txt"). The escaped string fails
#      Test-Path, so the file's content is never scanned -- a secret-guard
#      bypass -- even though `git add -A` stages the real file.
# Test-SyncSafety MUST enumerate with NUL-delimited git output. Assert the
# source uses `-z` (and no longer the escape-prone porcelain path), then run the
# real guard against a throwaway repo containing nested secrets AND quoted/
# escaped/non-ASCII paths to prove detection and ignored-file exclusion.
Write-Section "Sync guard secret enumeration (NUL-delimited)"
$syncSafetyFile = Join-Path $RepoRoot "scripts\lib\sync-safety.ps1"
if (-not (Test-Path $syncSafetyFile)) {
    Add-Fail "scripts/lib/sync-safety.ps1 not found"
} else {
    $syncText = Get-Content -LiteralPath $syncSafetyFile -Raw
    if ($syncText -match 'ls-files --others --exclude-standard -z' -and $syncText -match "diff', '--name-only', '-z'") {
        Add-Pass "Test-SyncSafety enumerates candidates with NUL-delimited (-z) git output"
    } else {
        Add-Fail "Test-SyncSafety does not use NUL-delimited (-z) enumeration (quoted/escaped paths could evade the scan)"
    }
    if ($syncText -match '=\s*git status --porcelain') {
        Add-Fail "Test-SyncSafety still invokes escape-prone 'git status --porcelain' (non-ASCII paths get octal-escaped and skip content scanning)"
    } else {
        Add-Pass "Test-SyncSafety no longer invokes quote-prone 'git status --porcelain'"
    }

    # Bypass #1 (root-relative coverage): enumeration must be rooted at the repo
    # top level so a nested invocation still sees the whole working tree.
    if ($syncText -match 'rev-parse --show-toplevel') {
        Add-Pass "Test-SyncSafety discovers the repo root (rev-parse --show-toplevel) so nested invocations cover the whole tree"
    } else {
        Add-Fail "Test-SyncSafety does not discover the repo root; a nested invocation could miss root-level/sibling files git add -A stages"
    }

    # Bypass #2 (byte-safe NUL parsing): git output must be read as raw bytes via
    # a redirected process stream, never line-split by the PowerShell pipeline.
    if ($syncText -match 'RedirectStandardOutput' -and $syncText -match 'BaseStream') {
        Add-Pass "Test-SyncSafety reads git output byte-safely (redirected process BaseStream), avoiding pipeline newline splitting"
    } else {
        Add-Fail "Test-SyncSafety relies on pipeline splitting of native output; filenames containing newlines could bypass content scanning"
    }

    # Bypass #3 (case-sensitive dedupe): candidates must be de-duplicated with an
    # ordinal comparer, not PowerShell's case-insensitive Sort-Object -Unique.
    if ($syncText -match 'StringComparer\]::Ordinal') {
        Add-Pass "Test-SyncSafety de-duplicates candidates with case-sensitive ordinal semantics (distinct case-only paths preserved)"
    } else {
        Add-Fail "Test-SyncSafety de-duplicates candidates case-insensitively; distinct case-only paths could collapse and leave one unscanned"
    }

    # Deterministic unit test for the raw NUL parser. A filename that contains a
    # newline is legal on Linux/macOS; the parser must split ONLY on NUL so such a
    # path survives intact rather than being torn apart the way the PowerShell
    # pipeline would tear native command output. Feed synthetic UTF-8 bytes so the
    # test is platform-independent (Windows cannot create a newline-named file).
    . $syncSafetyFile
    if (Get-Command ConvertFrom-NulDelimitedByte -ErrorAction SilentlyContinue) {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        # Two entries: "dir/we<LF>ird.txt" and "plain.txt", NUL-terminated.
        $synthetic = "dir/we`nird.txt`0plain.txt`0caf$([char]0x00E9)/x.env`0"
        $parsed = ConvertFrom-NulDelimitedByte -Bytes ($utf8.GetBytes($synthetic))
        $parsedCount = @($parsed).Count
        $keptNewline = @($parsed | Where-Object { $_ -eq "dir/we`nird.txt" }).Count -eq 1
        $keptNonAscii = @($parsed | Where-Object { $_ -eq "caf$([char]0x00E9)/x.env" }).Count -eq 1
        if ($parsedCount -eq 3 -and $keptNewline -and $keptNonAscii) {
            Add-Pass "Raw NUL parser splits only on NUL: newline-containing and non-ASCII paths survive intact"
        } else {
            Add-Fail "Raw NUL parser mishandled synthetic input (count=$parsedCount, newline kept=$keptNewline, non-ASCII kept=$keptNonAscii)"
        }
    } else {
        Add-Fail "ConvertFrom-NulDelimitedByte helper not defined; cannot unit test byte-safe NUL parsing"
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Host "  [SKIP] git not available for functional sync-guard test"
    } else {
        . $syncSafetyFile
        $tmpRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("sync-guard-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $tmpRepo | Out-Null
        $prevAllow = $env:SQUAD_ACA_ALLOW_UNSAFE_SYNC
        $env:SQUAD_ACA_ALLOW_UNSAFE_SYNC = $null
        Push-Location $tmpRepo
        try {
            git init -q 2>$null | Out-Null
            git config user.email "test@example.com" 2>$null | Out-Null
            git config user.name "Sync Guard Test" 2>$null | Out-Null

            # Tricky path segments that git C-quotes/escapes in plain porcelain.
            # Built from char codes so the test does not depend on this file's
            # source encoding. Windows forbids " * : < > ? | in names, so we use
            # spaces, brackets, and non-ASCII (é / Cyrillic) which are the real
            # triggers for git's octal-escaped quoting.
            $eacute = [char]0x00E9          # é
            $cyrKa  = [char]0x043A          # к
            $nonAsciiDir = "caf$eacute dir [x]"   # non-ASCII + space + brackets
            $cyrDir      = "$($cyrKa)eys sub"     # Cyrillic + space
            $pat = 'ghp_' + ('A' * 36)

            # Ignored file (non-ASCII path) that would otherwise trip the guard.
            # .gitignore MUST be written UTF-8: git compares the pattern bytes
            # against UTF-8-encoded paths, so an ANSI-encoded non-ASCII pattern
            # would silently fail to match and the file would leak into the scan.
            $ignoredDir = "ignored-$eacute"
            [System.IO.File]::WriteAllText(
                (Join-Path $tmpRepo ".gitignore"),
                "$ignoredDir/`n",
                (New-Object System.Text.UTF8Encoding $false))
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo $ignoredDir) | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "$ignoredDir\secrets.json") -Value '{"token":"should-be-ignored"}'

            # Nested UNTRACKED secrets inside brand-new directories (plain
            # --porcelain would collapse these to their top-level dir).
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "nested\deep") | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "nested\deep\secrets.json") -Value '{"api":"value"}'
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "certs\sub") | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "certs\sub\server.pem") -Value "placeholder-cert-material"
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "src\app") | Out-Null
            $pat0 = 'ghp_' + ('A' * 36)
            Set-Content -LiteralPath (Join-Path $tmpRepo "src\app\config.txt") -Value "token = $pat0"

            # Root-level denylisted secret. Used by the nested-invocation test
            # below: a guard run from a deep subdirectory must still catch this
            # root file that `git add -A` stages.
            Set-Content -LiteralPath (Join-Path $tmpRepo ".env") -Value "API_KEY=root-level-secret"

            # Denylisted secret filename at a QUOTED/ESCAPED non-ASCII path.
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo $nonAsciiDir) | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "$nonAsciiDir\secrets.json") -Value '{"api":"value"}'
            # PAT-like token in a text file at a QUOTED/ESCAPED non-ASCII path
            # (filename itself is not a secret name, so only content scanning
            # catches it -- exactly the path the old escaped-string bug skipped).
            New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo $cyrDir) | Out-Null
            Set-Content -LiteralPath (Join-Path $tmpRepo "$cyrDir\config.txt") -Value "token = $pat"

            $reasons = Test-SyncSafety

            $hasNestedJson = @($reasons | Where-Object { $_ -match 'nested/deep/secrets\.json' }).Count -gt 0
            $hasPem = @($reasons | Where-Object { $_ -match 'certs/sub/server\.pem' }).Count -gt 0
            $hasPat = @($reasons | Where-Object { $_ -match 'src/app/config\.txt' }).Count -gt 0
            $leakedIgnored = @($reasons | Where-Object { $_ -match 'secrets\.json' -and $_ -match [regex]::Escape($ignoredDir) }).Count -gt 0
            $hasNonAsciiDeny = @($reasons | Where-Object { $_ -match [regex]::Escape("$nonAsciiDir/secrets.json") }).Count -gt 0
            $hasNonAsciiPat  = @($reasons | Where-Object { $_ -match [regex]::Escape("$cyrDir/config.txt") }).Count -gt 0

            if ($hasNestedJson) { Add-Pass "Sync guard flags nested untracked secrets.json" }
            else { Add-Fail "Sync guard missed nested untracked secrets.json (nested-enumeration regression)" }
            if ($hasPem) { Add-Pass "Sync guard flags nested untracked .pem" }
            else { Add-Fail "Sync guard missed nested untracked .pem" }
            if ($hasPat) { Add-Pass "Sync guard flags nested source containing a PAT-like token" }
            else { Add-Fail "Sync guard missed nested source containing a PAT-like token" }
            if ($hasNonAsciiDeny) { Add-Pass "Sync guard flags denylisted secret at a quoted/escaped non-ASCII path" }
            else { Add-Fail "Sync guard missed denylisted secret at a quoted/escaped non-ASCII path (porcelain-escape regression)" }
            if ($hasNonAsciiPat) { Add-Pass "Sync guard flags PAT-like token in a text file at a quoted/escaped non-ASCII path" }
            else { Add-Fail "Sync guard missed PAT-like token at a quoted/escaped non-ASCII path (content skipped due to unescaped path)" }
            if (-not $leakedIgnored) { Add-Pass "Sync guard excludes git-ignored files (including non-ASCII paths)" }
            else { Add-Fail "Sync guard flagged a git-ignored file (should be excluded)" }

            # Bypass #1 regression: run the guard from a DEEP nested subdirectory.
            # `git add -A` stages the whole tree, but git scopes diff/ls-files
            # output to the current directory -- so a guard that enumerated from
            # cwd would only see files under nested/deep and miss the root-level
            # .env and the sibling certs/sub/server.pem. Repo-root-rooted
            # enumeration must still catch both.
            $nestedDir = Join-Path $tmpRepo "nested\deep"
            Push-Location $nestedDir
            try {
                $nestedReasons = Test-SyncSafety
                $nestedCatchesRoot = @($nestedReasons | Where-Object { $_ -match 'Blocked file: \.env ' }).Count -gt 0
                $nestedCatchesSibling = @($nestedReasons | Where-Object { $_ -match 'certs/sub/server\.pem' }).Count -gt 0
                $nestedCatchesLocal = @($nestedReasons | Where-Object { $_ -match 'nested/deep/secrets\.json' }).Count -gt 0
                if ($nestedCatchesRoot) { Add-Pass "Sync guard run from a nested dir still catches the root-level .env" }
                else { Add-Fail "Sync guard run from a nested dir missed the root-level .env (nested-cwd enumeration regression)" }
                if ($nestedCatchesSibling) { Add-Pass "Sync guard run from a nested dir still catches a sibling nested secret (certs/sub/server.pem)" }
                else { Add-Fail "Sync guard run from a nested dir missed a sibling nested secret (nested-cwd enumeration regression)" }
                if ($nestedCatchesLocal) { Add-Pass "Sync guard run from a nested dir reports paths repo-root-relative (nested/deep/secrets.json)" }
                else { Add-Fail "Sync guard run from a nested dir did not report the local nested secret repo-relative" }
            } finally {
                Pop-Location
            }
        } finally {
            Pop-Location
            $env:SQUAD_ACA_ALLOW_UNSAFE_SYNC = $prevAllow
            Remove-Item -Recurse -Force $tmpRepo -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 7. squad-aca logs: exit-code propagation, no interactive install, LA fallback
# ---------------------------------------------------------------------------
# Regression guard for GitHub issue #13. `squad-aca logs` used to call
# `az containerapp job logs show` (a `containerapp` CLI *extension* command) as
# the last statement of Invoke-Logs. On a host without the extension az printed
# an argparse traceback, blocked on an interactive install prompt, and the
# command still exited 0 -- a false green during incident response.
#
# The checks below are fully offline. A fake `az` is placed first on PATH (the
# same technique worker/tests/test_ralph_dispatch.sh uses for az/gh) and each
# scenario is driven through env vars, so no Azure call is ever made.
Write-Section "squad-aca logs fallback + exit code"
$acaLogsFile = Join-Path $RepoRoot "scripts\lib\aca-logs.ps1"
$squadAcaFile = Join-Path $RepoRoot "scripts\squad-aca.ps1"
if (-not (Test-Path $acaLogsFile)) {
    Add-Fail "scripts/lib/aca-logs.ps1 not found"
} elseif (-not (Test-Path $squadAcaFile)) {
    Add-Fail "scripts/squad-aca.ps1 not found"
} else {
    $squadAcaText = Get-Content -LiteralPath $squadAcaFile -Raw

    # Source assertions: the bare, unchecked extension call must be gone and the
    # doctor table must surface which log path `logs` will take.
    if ($squadAcaText -match 'az containerapp job logs show') {
        Add-Fail "Invoke-Logs still calls 'az containerapp job logs show' directly (exit code unchecked, extension required)"
    } else {
        Add-Pass "Invoke-Logs no longer calls 'az containerapp job logs show' directly"
    }
    if ($squadAcaText -match 'Get-AcaExecutionLog') {
        Add-Pass "Invoke-Logs delegates to Get-AcaExecutionLog (exit-code checked, Log Analytics fallback)"
    } else {
        Add-Fail "Invoke-Logs does not delegate to Get-AcaExecutionLog"
    }
    if ($squadAcaText -match 'Check = "Logs path"') {
        Add-Pass "squad-aca doctor reports the active logs path"
    } else {
        Add-Fail "squad-aca doctor has no 'Logs path' check (issue #13 asked for it)"
    }

    . $acaLogsFile

    $stubRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("aca-logs-" + [guid]::NewGuid().ToString("N"))
    $stubBin = Join-Path $stubRoot "bin"
    New-Item -ItemType Directory -Force -Path $stubBin | Out-Null

    # Fake `az`. Records one marker line per call. If dynamic extension install
    # was NOT suppressed it records PROMPT-RISK, which stands in for the real
    # CLI's interactive "install it now? (Y/n)" prompt that blocks on stdin.
    # Every branch exits from a label, never from inside a parenthesized block:
    # cmd.exe does not reliably propagate `exit /b <n>` out of nested blocks, and
    # a stub that always returned 0 would silently make these checks meaningless.
    $azStub = @'
@echo off
setlocal
if not "%AZURE_EXTENSION_USE_DYNAMIC_INSTALL%"=="no" >>"%SQUAD_TEST_AZ_LOG%" echo PROMPT-RISK %1 %2 %3
>>"%SQUAD_TEST_AZ_LOG%" echo CALL %1 %2 %3 %4

if "%1"=="extension" goto :extension
if "%1"=="containerapp" goto :containerapp
if "%1"=="monitor" goto :monitor
exit /b 0

:extension
if "%4"=="containerapp" goto :ext_containerapp
if "%4"=="log-analytics" goto :ext_loganalytics
exit /b 1

:ext_containerapp
if not "%SQUAD_TEST_AZ_EXT_CONTAINERAPP%"=="1" goto :ext_containerapp_missing
exit /b 0
:ext_containerapp_missing
echo ERROR: Extension 'containerapp' is not installed.>&2
exit /b 1

:ext_loganalytics
if not "%SQUAD_TEST_AZ_EXT_LOGANALYTICS%"=="1" goto :ext_loganalytics_missing
exit /b 0
:ext_loganalytics_missing
echo ERROR: Extension 'log-analytics' is not installed.>&2
exit /b 1

:containerapp
if not "%SQUAD_TEST_AZ_EXT_CONTAINERAPP%"=="1" goto :containerapp_noext
if "%SQUAD_TEST_AZ_LOGS_FAIL%"=="1" goto :containerapp_fail
echo native-log-line-1
echo native-log-line-2
exit /b 0
:containerapp_noext
echo ERROR: The command requires the extension containerapp.>&2
exit /b 2
:containerapp_fail
echo ERROR: simulated containerapp logs failure>&2
exit /b 1

:monitor
if not "%SQUAD_TEST_AZ_EXT_LOGANALYTICS%"=="1" goto :monitor_noext
if "%3"=="workspace" goto :monitor_workspace
if "%3"=="query" goto :monitor_query
exit /b 1
:monitor_noext
echo ERROR: The command requires the extension log-analytics.>&2
exit /b 2
:monitor_workspace
echo 00000000-0000-0000-0000-000000000000
exit /b 0
:monitor_query
if "%SQUAD_TEST_AZ_QUERY_FAIL%"=="1" goto :monitor_query_fail
echo [{"TimeGenerated":"2026-07-28T00:00:00Z","Log_s":"fallback-log-line-1"},{"TimeGenerated":"2026-07-28T00:00:01Z","Log_s":"fallback-log-line-2"}]
exit /b 0
:monitor_query_fail
echo ERROR: simulated Log Analytics query failure>&2
exit /b 1
'@
    Set-Content -LiteralPath (Join-Path $stubBin "az.cmd") -Value $azStub -Encoding ascii

    $prevPath = $env:PATH
    $prevDynamic = $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL
    $hadDynamic = Test-Path Env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL
    $env:PATH = "$stubBin;$prevPath"
    $env:SQUAD_TEST_AZ_LOG = Join-Path $stubRoot "az-calls.log"

    function Reset-AzStubState {
        param([string]$Containerapp = "0", [string]$LogAnalytics = "0", [string]$LogsFail = "0", [string]$QueryFail = "0")
        Set-Content -LiteralPath $env:SQUAD_TEST_AZ_LOG -Value "" -Encoding ascii
        $env:SQUAD_TEST_AZ_EXT_CONTAINERAPP = $Containerapp
        $env:SQUAD_TEST_AZ_EXT_LOGANALYTICS = $LogAnalytics
        $env:SQUAD_TEST_AZ_LOGS_FAIL = $LogsFail
        $env:SQUAD_TEST_AZ_QUERY_FAIL = $QueryFail
    }
    function Get-AzStubCalls {
        if (-not (Test-Path $env:SQUAD_TEST_AZ_LOG)) { return @() }
        return @(Get-Content -LiteralPath $env:SQUAD_TEST_AZ_LOG | Where-Object { $_ -and $_.Trim() })
    }

    try {
        # Guard: the fake az must actually be the one being resolved. If PATH
        # stubbing silently failed, every check below would hit the real CLI.
        $resolvedAz = (Get-Command az -ErrorAction SilentlyContinue)
        if (-not $resolvedAz -or $resolvedAz.Source -ne (Join-Path $stubBin "az.cmd")) {
            Add-Fail "Could not stub 'az' on PATH for the logs regression test (resolved: $($resolvedAz.Source))"
        } else {
            Add-Pass "Fake 'az' is first on PATH; logs regression test runs fully offline"
        }

        # --- 1. Native path is preferred when the extension is present --------
        Reset-AzStubState -Containerapp "1" -LogAnalytics "1"
        $native = Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5
        $nativeCalls = Get-AzStubCalls
        if ($native.Source -eq "containerapp-extension" -and @($native.Lines) -contains "native-log-line-2" `
                -and -not (@($nativeCalls) -match 'CALL monitor')) {
            Add-Pass "Logs use the containerapp extension path when the extension is installed"
        } else {
            Add-Fail "Logs did not use the containerapp extension path when available (source=$($native.Source))"
        }

        # --- 2. Fallback when the extension is absent -------------------------
        Reset-AzStubState -Containerapp "0" -LogAnalytics "1"
        $fallback = Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 -WorkspaceName "law-test"
        $fallbackLines = @($fallback.Lines)
        if ($fallback.Source -eq "log-analytics" -and $fallbackLines.Count -eq 2 `
                -and $fallbackLines -contains "fallback-log-line-1" -and $fallbackLines -contains "fallback-log-line-2" `
                -and $fallback.Workspace -eq "law-test") {
            Add-Pass "Logs fall back to Log Analytics when the containerapp extension is absent"
        } else {
            Add-Fail "Logs did not fall back to Log Analytics correctly (source=$($fallback.Source), lines=$($fallbackLines.Count))"
        }

        # --- 2b. Same fallback under Windows PowerShell 5.1 -------------------
        # squad-aca.ps1 runs under Windows PowerShell through the .cmd shim, and
        # 5.1 does NOT unroll a JSON array the way pwsh 7 does. Validating only
        # under the host that runs validate.ps1 would miss a row-flattening bug
        # that silently turns real log lines into blanks.
        $winPs = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path $winPs)) {
            Write-Host "  [SKIP] Windows PowerShell 5.1 not present for cross-host log parsing check"
        } else {
            Reset-AzStubState -Containerapp "0" -LogAnalytics "1"
            $winScript = ". '$acaLogsFile'; " +
                "`$r = Get-AcaExecutionLog -ResourceGroup 'rg-test' -JobName 'caj-test' -ExecutionName 'caj-test-abc' -Tail 5 -WorkspaceName 'law-test'; " +
                "foreach (`$l in @(`$r.Lines)) { Write-Output `"ROW:`$l`" }"
            $winOut = @(& $winPs -NoProfile -NonInteractive -Command $winScript 2>&1 | ForEach-Object { [string]$_ })
            $winRows = @($winOut | Where-Object { $_ -match '^ROW:' })
            if ($winRows.Count -eq 2 -and ($winRows -contains "ROW:fallback-log-line-1") -and ($winRows -contains "ROW:fallback-log-line-2")) {
                Add-Pass "Log Analytics rows survive intact under Windows PowerShell 5.1 (the host the squad-aca shim uses)"
            } else {
                Add-Fail "Log Analytics rows were mangled under Windows PowerShell 5.1 (got $($winRows.Count) row(s): $($winRows -join ' | '))"
            }
        }

        # --- 3. Fallback when the extension exists but its call fails ---------
        Reset-AzStubState -Containerapp "1" -LogAnalytics "1" -LogsFail "1"
        $afterFail = Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5
        $afterFailCalls = Get-AzStubCalls
        $triedNative = @($afterFailCalls | Where-Object { $_ -match 'CALL containerapp job logs' }).Count -gt 0
        $triedQuery = @($afterFailCalls | Where-Object { $_ -match 'CALL monitor log-analytics query' }).Count -gt 0
        if ($afterFail.Source -eq "log-analytics" -and $triedNative -and $triedQuery) {
            Add-Pass "A failing 'az containerapp job logs show' falls through to the Log Analytics query"
        } else {
            Add-Fail "A failing containerapp logs call did not fall through to Log Analytics (source=$($afterFail.Source), native=$triedNative, query=$triedQuery)"
        }

        # --- 4. Both paths unavailable => terminating, actionable error -------
        Reset-AzStubState -Containerapp "0" -LogAnalytics "0"
        $threw = $false
        $message = ""
        try {
            Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 -WorkspaceName "law-test" | Out-Null
        } catch {
            $threw = $true
            $message = [string]$_.Exception.Message
        }
        if ($threw -and $message -match 'az extension add --name containerapp' -and $message -match 'az extension add --name log-analytics' -and $message -match 'law-test') {
            Add-Pass "Both log paths unavailable produces a terminating, actionable error"
        } else {
            Add-Fail "Both log paths unavailable did not produce an actionable terminating error (threw=$threw)"
        }

        # --- 5. A failing Log Analytics query must also be fatal --------------
        Reset-AzStubState -Containerapp "0" -LogAnalytics "1" -QueryFail "1"
        $queryThrew = $false
        try {
            Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 | Out-Null
        } catch {
            $queryThrew = $true
        }
        if ($queryThrew) {
            Add-Pass "A failing Log Analytics query is fatal instead of silently returning nothing"
        } else {
            Add-Fail "A failing Log Analytics query was swallowed (false green)"
        }

        # --- 6. No az call may risk the interactive install prompt ------------
        $promptRisks = @(Get-AzStubCalls | Where-Object { $_ -match '^PROMPT-RISK' })
        Reset-AzStubState -Containerapp "0" -LogAnalytics "0"
        try { Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 | Out-Null } catch { }
        $promptRisks += @(Get-AzStubCalls | Where-Object { $_ -match '^PROMPT-RISK' })
        if ($promptRisks.Count -eq 0) {
            Add-Pass "Every az invocation runs with AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no (no interactive install prompt can block)"
        } else {
            Add-Fail "$($promptRisks.Count) az invocation(s) could trigger the interactive extension-install prompt"
        }

        # --- 7. The suppression env var must be restored ----------------------
        $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = "sentinel-value"
        Reset-AzStubState -Containerapp "1" -LogAnalytics "1"
        Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 | Out-Null
        $restoredSet = ($env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL -eq "sentinel-value")
        Remove-Item Env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL -ErrorAction SilentlyContinue
        Reset-AzStubState -Containerapp "1" -LogAnalytics "1"
        Get-AcaExecutionLog -ResourceGroup "rg-test" -JobName "caj-test" -ExecutionName "caj-test-abc" -Tail 5 | Out-Null
        $restoredUnset = -not (Test-Path Env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL)
        if ($restoredSet -and $restoredUnset) {
            Add-Pass "AZURE_EXTENSION_USE_DYNAMIC_INSTALL is restored after log retrieval (set and unset cases)"
        } else {
            Add-Fail "AZURE_EXTENSION_USE_DYNAMIC_INSTALL leaked after log retrieval (set restored=$restoredSet, unset restored=$restoredUnset)"
        }

        # --- 8. End-to-end exit code: a failed log fetch must not exit 0 ------
        # The original bug was an exit code, not a message, so assert the real
        # process exit code of a host that runs the same call path.
        Reset-AzStubState -Containerapp "0" -LogAnalytics "0"
        $psExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $childScript = ". '$acaLogsFile'; " +
            "`$ErrorActionPreference = 'Stop'; " +
            "Get-AcaExecutionLog -ResourceGroup 'rg-test' -JobName 'caj-test' -ExecutionName 'caj-test-abc' -Tail 5 -WorkspaceName 'law-test' | Out-Null"
        & $psExe -NoProfile -NonInteractive -Command $childScript 2>&1 | Out-Null
        $childExit = $LASTEXITCODE
        if ($childExit -ne 0) {
            Add-Pass "A failed log fetch exits non-zero (observed exit $childExit; issue #13 regression)"
        } else {
            Add-Fail "A failed log fetch still exits 0 (issue #13 regression: false green)"
        }

        # --- 9. --tail must reach the Log Analytics query ---------------------
        $kql = Get-AcaLogAnalyticsQuery -ExecutionName "caj-test-abc" -Tail 42
        if ($kql -match 'top 42 by TimeGenerated desc' -and $kql -match "startswith 'caj-test-abc'" -and $kql -match 'ContainerAppConsoleLogs_CL') {
            Add-Pass "--tail and the execution name are honoured by the Log Analytics query"
        } else {
            Add-Fail "Log Analytics query ignores --tail or the execution name: $kql"
        }
    } finally {
        $env:PATH = $prevPath
        foreach ($name in @("SQUAD_TEST_AZ_LOG", "SQUAD_TEST_AZ_EXT_CONTAINERAPP", "SQUAD_TEST_AZ_EXT_LOGANALYTICS", "SQUAD_TEST_AZ_LOGS_FAIL", "SQUAD_TEST_AZ_QUERY_FAIL")) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        if ($hadDynamic) {
            $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = $prevDynamic
        } else {
            Remove-Item Env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL -ErrorAction SilentlyContinue
        }
        Remove-Item -Recurse -Force $stubRoot -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 8. Execution provider contract (offline, against the fake provider)
# ---------------------------------------------------------------------------
Write-Section "Execution provider contract"
$providerLib = Join-Path $RepoRoot "scripts\lib\squad-aca-provider.ps1"
if (-not (Test-Path $providerLib)) {
    Add-Fail "scripts/lib/squad-aca-provider.ps1 is missing (execution provider seam)"
} else {
    . $providerLib

    $providerTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("squad-provider-" + [guid]::NewGuid().ToString("N"))
    try {
        $fake = New-SquadExecutionProvider -Kind "fake" -Options @{ StateRoot = $providerTmp }

        # -- structural conformance -----------------------------------------
        if (@(Test-SquadExecutionProvider -Provider $fake).Count -eq 0) {
            Add-Pass "Fake provider satisfies the execution provider contract"
        } else {
            Add-Fail "Fake provider does not satisfy the execution provider contract"
        }

        $acaProvider = New-SquadExecutionProvider -Kind "aca-job" -Options @{
            Config    = [pscustomobject]@{ resourceGroup = "rg"; sessionJob = "job"; subscriptionId = "" }
            ScriptDir = (Join-Path $RepoRoot "scripts")
        }
        if (@(Test-SquadExecutionProvider -Provider $acaProvider).Count -eq 0) {
            Add-Pass "ACA Job provider satisfies the execution provider contract"
        } else {
            Add-Fail "ACA Job provider does not satisfy the execution provider contract"
        }

        $missingOps = @($script:SquadProviderOperations | Where-Object { -not $fake.Operations.Contains($_) })
        if ($missingOps.Count -eq 0) {
            Add-Pass "Contract declares create/wait/status/logs/cancel/terminate and the fake implements all six"
        } else {
            Add-Fail "Fake provider is missing contract operations: $($missingOps -join ', ')"
        }

        try {
            Invoke-SquadProviderOperation -Provider $fake -Operation "resize" | Out-Null
            Add-Fail "Off-contract operation 'resize' was dispatched instead of rejected"
        } catch {
            Add-Pass "Off-contract operations are rejected at the dispatch choke point"
        }

        # -- dispatch request / response shape (PRD #6) ----------------------
        $request = New-SquadDispatchRequest -SessionId "sess-a" -Repository "octo/demo" -Ref "main" `
            -Prompt "do the thing" -Mode "prompt" -OutputBranch "squad/sess-a" -PushChanges $true
        $requiredRequestFields = @("schemaVersion", "sessionId", "dispatchSource", "repository", "task",
            "capabilityManifest", "capabilityResolution", "executionPreferences", "git")
        $missingReq = @($requiredRequestFields | Where-Object { $request.PSObject.Properties.Name -notcontains $_ })
        if ($missingReq.Count -eq 0) {
            Add-Pass "Dispatch request carries every PRD #6 field"
        } else {
            Add-Fail "Dispatch request is missing PRD #6 fields: $($missingReq -join ', ')"
        }

        $response = New-SquadDispatchResponse -SessionId "sess-a" -ExecutionMode "aca-job" -Status "provisioning" -SessionHandle "sqx1.abc"
        $requiredResponseFields = @("executionMode", "sandboxClass", "sessionHandle", "status", "statusPollRef", "fallbackReason")
        $missingResp = @($requiredResponseFields | Where-Object { $response.PSObject.Properties.Name -notcontains $_ })
        if ($missingResp.Count -eq 0) {
            Add-Pass "Dispatch response carries every PRD #6 field"
        } else {
            Add-Fail "Dispatch response is missing PRD #6 fields: $($missingResp -join ', ')"
        }

        # -- create ----------------------------------------------------------
        $outcome = @{}
        $created = @(Start-SquadExecution -Provider $fake -Request $request -Outcome $outcome)
        if ($created.Count -eq 0) {
            Add-Pass "create writes nothing of its own to the pipeline (substrate output passes through untouched)"
        } else {
            Add-Fail "create polluted the pipeline with $($created.Count) object(s); run/smoke output would change"
        }
        $handle = $outcome["Response"].sessionHandle
        if ($outcome["Response"] -and $handle) {
            Add-Pass "create returns the provider-neutral response through -Outcome"
        } else {
            Add-Fail "create did not return a dispatch response through -Outcome"
        }

        # -- handle opacity --------------------------------------------------
        # Convention-level opacity, and the message says exactly that: a handle
        # is base64 and trivially decodable by anyone who wants to. What this
        # asserts is that a caller cannot *accidentally* depend on the execution
        # id by string-matching a handle it was handed.
        $status = Get-SquadExecutionStatus -Provider $fake -Handle $handle
        $execId = $status.Display.Execution
        if ($handle -ne $execId -and $handle -notlike "*$execId*") {
            Add-Pass "Execution handles do not embed the execution id verbatim (no call site can string-match one out by accident)"
        } else {
            Add-Fail "Execution handle contains the underlying execution id '$execId' verbatim; a call site could string-match it out"
        }

        # -- state transitions -----------------------------------------------
        if ($status.Status -eq "Provisioning") {
            Add-Pass "create leaves the execution in Provisioning"
        } else {
            Add-Fail "create left the execution in '$($status.Status)', expected Provisioning"
        }
        $waited = Wait-SquadExecution -Provider $fake -Handle $handle
        if ($waited.Status -eq "Running") {
            Add-Pass "wait advances Provisioning -> Running"
        } else {
            Add-Fail "wait left the execution in '$($waited.Status)', expected Running"
        }
        $logResult = Get-SquadExecutionLog -Provider $fake -Handle $handle -Tail 10
        if (@($logResult.Lines).Count -gt 0 -and ($logResult.PSObject.Properties.Name -contains "Notice")) {
            Add-Pass "logs returns the contract Lines/Notice result for a known handle"
        } else {
            Add-Fail "logs did not return the contract Lines/Notice shape"
        }
        $listed = @(Get-SquadExecutionList -Provider $fake -Limit 10)
        if ($listed.Count -ge 1 -and $listed[0].PSObject.Properties.Name -contains "Display") {
            Add-Pass "status (list form) returns Handle/Status/Display records"
        } else {
            Add-Fail "status (list form) did not return contract records"
        }

        # -- cancel, twice ----------------------------------------------------
        Stop-SquadExecution -Provider $fake -Handle $handle | Out-Null
        $afterCancel = Get-SquadExecutionStatus -Provider $fake -Handle $handle
        if ($afterCancel.Status -eq "Cancelled") {
            Add-Pass "cancel moves a running execution to Cancelled"
        } else {
            Add-Fail "cancel left the execution in '$($afterCancel.Status)', expected Cancelled"
        }
        $doubleCancelOk = $true
        try { Stop-SquadExecution -Provider $fake -Handle $handle | Out-Null } catch { $doubleCancelOk = $false }
        if ($doubleCancelOk) {
            Add-Pass "cancel is safe to call twice (second cancel is a no-op success)"
        } else {
            Add-Fail "second cancel threw; cancel must tolerate an already-terminal execution"
        }

        # -- terminate: idempotent -------------------------------------------
        $t1 = Remove-SquadExecution -Provider $fake -Handle $handle
        $t2 = Remove-SquadExecution -Provider $fake -Handle $handle
        if ($t1.Terminated -and $t2.Terminated) {
            Add-Pass "terminate is idempotent (terminating an already-terminated execution succeeds)"
        } else {
            Add-Fail "terminate was not idempotent"
        }

        $outcome2 = @{}
        Start-SquadExecution -Provider $fake -Request $request -Outcome $outcome2 | Out-Null
        $handle2 = $outcome2["Response"].sessionHandle
        $id2 = (Get-SquadExecutionStatus -Provider $fake -Handle $handle2).Display.Execution
        Remove-Item -LiteralPath (Join-Path $providerTmp "$id2.json") -Force
        $externalOk = $true
        try {
            $t3 = Remove-SquadExecution -Provider $fake -Handle $handle2
            if (-not $t3.Terminated) { $externalOk = $false }
        } catch { $externalOk = $false }
        if ($externalOk) {
            Add-Pass "terminate succeeds after the execution was deleted externally"
        } else {
            Add-Fail "terminate failed for an externally-deleted execution; PRD #6 requires success"
        }

        # -- unknown / malformed / cross-provider handles ---------------------
        $unknownHandle = New-SquadExecutionHandle -ProviderId "fake" -Payload ([ordered]@{ id = "fake-exec-9999" })
        try {
            Get-SquadExecutionStatus -Provider $fake -Handle $unknownHandle | Out-Null
            Add-Fail "status accepted a well-formed handle for an execution that does not exist"
        } catch {
            Add-Pass "status rejects a well-formed handle for an unknown execution"
        }
        try {
            Get-SquadExecutionStatus -Provider $fake -Handle "not-a-handle" | Out-Null
            Add-Fail "status accepted a malformed execution handle"
        } catch {
            Add-Pass "status rejects a malformed execution handle"
        }
        $foreignHandle = New-SquadExecutionHandle -ProviderId "aca-job" -Payload ([ordered]@{ job = "j"; rg = "r"; execution = "e" })
        try {
            Remove-SquadExecution -Provider $fake -Handle $foreignHandle | Out-Null
            Add-Fail "terminate accepted a handle minted by a different provider"
        } catch {
            Add-Pass "terminate rejects a handle minted by a different provider (caller bug, not a race)"
        }
    } catch {
        Add-Fail "Execution provider contract checks threw: $($_.Exception.Message)"
    } finally {
        Remove-Item -Recurse -Force $providerTmp -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 8b. ACA Job adapter against a stubbed `az` (the PRODUCTION adapter)
# ---------------------------------------------------------------------------
# Section 8 exercises the contract against the fake provider. That proves the
# seam, not the adapter that actually ships: replacing the ACA adapter's
# terminate az call with a no-op, or its `wait` body with a throw, left section
# 8 fully green. These checks close that hole by driving
# New-AcaJobExecutionProvider itself against the fake `az` from
# scripts/tests/cli-stub-harness.ps1.
#
# The defect they exist for: terminate used to return Terminated=$true for EVERY
# non-zero `az` exit and label it AlreadyTerminal, so an auth failure, an RBAC
# denial, throttling, or a missing `az` all read as "successfully torn down".
Write-Section "ACA Job adapter (stubbed az)"
$adapterHarness = Join-Path $RepoRoot "scripts\tests\cli-stub-harness.ps1"
if (-not (Test-Path $providerLib)) {
    Add-Fail "scripts/lib/squad-aca-provider.ps1 is missing (ACA Job adapter checks)"
} elseif (-not (Test-Path $adapterHarness)) {
    Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing (ACA Job adapter checks)"
} elseif (-not $IsWindowsHost) {
    Write-Host "  [SKIP] ACA Job adapter checks require Windows (.cmd stubs)" -ForegroundColor Yellow
} else {
    . $adapterHarness
    $adapterStub = $null
    $adapterPrevPath = $env:PATH
    $adapterEnvNames = @("SQUAD_STUB_AZ_LOG", "SQUAD_STUB_GH_LOG", "SQUAD_STUB_FIXTURES",
        "SQUAD_STUB_STOP_RC", "SQUAD_STUB_START_RC", "SQUAD_STUB_STOP_ERR",
        "SQUAD_STUB_EXEC_SEQ", "SQUAD_STUB_EXEC_STUCK")
    try {
        $adapterStub = New-SquadCliStubEnvironment
        $env:PATH = "$($adapterStub.BinDir);$adapterPrevPath"
        $env:SQUAD_STUB_AZ_LOG = $adapterStub.AzLog
        $env:SQUAD_STUB_GH_LOG = $adapterStub.GhLog
        $env:SQUAD_STUB_FIXTURES = $adapterStub.FixtureDir
        $env:SQUAD_STUB_STOP_RC = "0"
        $env:SQUAD_STUB_START_RC = "0"
        $env:SQUAD_STUB_STOP_ERR = ""
        $env:SQUAD_STUB_EXEC_SEQ = ""
        $env:SQUAD_STUB_EXEC_STUCK = ""

        $resolvedAz = (Get-Command az -ErrorAction SilentlyContinue)
        if (-not $resolvedAz -or $resolvedAz.Source -ne (Join-Path $adapterStub.BinDir "az.cmd")) {
            Add-Fail "Could not stub 'az' on PATH for the ACA Job adapter checks (resolved: $($resolvedAz.Source))"
        } else {
            Add-Pass "Fake 'az' is first on PATH; ACA Job adapter checks run fully offline"
        }

        $adapterConfig = [pscustomobject]@{
            resourceGroup        = "rg-squad-stub"
            sessionJob           = "caj-squad-aca-session"
            subscriptionId       = "00000000-0000-0000-0000-000000000000"
            logAnalyticsWorkspace = "law-stub"
        }
        $acaAdapter = New-SquadExecutionProvider -Kind "aca-job" -Options @{
            Config    = $adapterConfig
            ScriptDir = (Join-Path $RepoRoot "scripts")
        }
        $acaHandle = New-AcaJobExecutionHandle -Config $adapterConfig -Name "caj-squad-aca-session-stub01"

        function Invoke-AdapterTerminate {
            param([string]$StopRc = "0", [string]$StopErr = "", [string]$Handle)
            Reset-SquadCliStubLog -Stub $adapterStub
            $env:SQUAD_STUB_STOP_RC = $StopRc
            $env:SQUAD_STUB_STOP_ERR = $StopErr
            $outcome = [pscustomobject]@{ Threw = $false; Message = ""; Result = $null }
            try {
                $outcome.Result = Remove-SquadExecution -Provider $acaAdapter -Handle $Handle
            } catch {
                $outcome.Threw = $true
                $outcome.Message = [string]$_.Exception.Message
            }
            return $outcome
        }

        # --- 1. Normal terminate ---------------------------------------------
        $t = Invoke-AdapterTerminate -StopRc "0" -Handle $acaHandle
        $stopCalls = @(Get-SquadCliStubCall -Stub $adapterStub -Tool az | Where-Object { $_ -like "containerapp job stop*" })
        if (-not $t.Threw -and $t.Result.Terminated -and -not $t.Result.AlreadyTerminal `
                -and $stopCalls.Count -eq 1 `
                -and $stopCalls[0] -like "*--name caj-squad-aca-session --resource-group rg-squad-stub --job-execution-name caj-squad-aca-session-stub01*") {
            Add-Pass "ACA adapter terminate stops a live execution with one 'az containerapp job stop' (Terminated, not AlreadyTerminal)"
        } else {
            Add-Fail "ACA adapter terminate did not stop a live execution correctly (threw=$($t.Threw) terminated=$($t.Result.Terminated) alreadyTerminal=$($t.Result.AlreadyTerminal) calls=$($stopCalls.Count) msg=$($t.Message))"
        }

        # --- 2. Already terminal / deleted out from under us => SUCCESS -------
        # Azure CLI reserves exit 3 for ResourceNotFoundError.
        $goneCases = @(
            @{ Rc = "3"; Err = "ERROR: (JobExecutionNotFound) The job execution 'caj-squad-aca-session-stub01' was not found."; Label = "not found (exit 3)" },
            @{ Rc = "1"; Err = "ERROR: (ResourceNotFound) The Resource 'Microsoft.App/jobs/caj-squad-aca-session/executions/stub01' under resource group 'rg-squad-stub' was not found."; Label = "ResourceNotFound" },
            @{ Rc = "1"; Err = "ERROR: The job execution is already stopped."; Label = "already stopped" }
        )
        $goneFailures = @()
        foreach ($case in $goneCases) {
            $g = Invoke-AdapterTerminate -StopRc $case.Rc -StopErr $case.Err -Handle $acaHandle
            if ($g.Threw -or -not $g.Result.Terminated -or -not $g.Result.AlreadyTerminal) {
                $goneFailures += "$($case.Label) (threw=$($g.Threw))"
            }
        }
        if ($goneFailures.Count -eq 0) {
            Add-Pass "ACA adapter terminate is idempotent: an already-terminal or externally-deleted execution reports Terminated + AlreadyTerminal"
        } else {
            Add-Fail "ACA adapter terminate failed for a genuinely-gone execution: $($goneFailures -join '; ') (PRD #6 requires success)"
        }

        # --- 3. Auth failure MUST surface, not become AlreadyTerminal ---------
        $auth = Invoke-AdapterTerminate -StopRc "1" -StopErr "ERROR: Please run 'az login' to setup account." -Handle $acaHandle
        if ($auth.Threw -and $auth.Message -match "az login") {
            Add-Pass "ACA adapter terminate surfaces an 'az login' auth failure as an error (never AlreadyTerminal)"
        } else {
            Add-Fail "ACA adapter terminate swallowed an auth failure (threw=$($auth.Threw) terminated=$($auth.Result.Terminated) alreadyTerminal=$($auth.Result.AlreadyTerminal)); an unauthenticated CLI proves nothing about the execution"
        }

        # --- 4. Other real failures must surface too --------------------------
        $realFailureCases = @(
            @{ Rc = "1"; Err = "ERROR: (AuthorizationFailed) The client does not have authorization to perform action 'Microsoft.App/jobs/stop/action'."; Label = "RBAC denial" },
            @{ Rc = "1"; Err = "ERROR: (TooManyRequests) The request is being throttled. Retry-After: 30"; Label = "throttling" },
            @{ Rc = "1"; Err = "ERROR: HTTPSConnectionPool: Max retries exceeded (connection timed out)"; Label = "network timeout" },
            @{ Rc = "1"; Err = "ERROR: (SubscriptionNotFound) The subscription could not be found."; Label = "wrong subscription" },
            @{ Rc = "1"; Err = "ERROR: something the CLI has never printed before"; Label = "unrecognised failure (fail closed)" }
        )
        $swallowed = @()
        foreach ($case in $realFailureCases) {
            $f = Invoke-AdapterTerminate -StopRc $case.Rc -StopErr $case.Err -Handle $acaHandle
            if (-not $f.Threw) { $swallowed += $case.Label }
        }
        if ($swallowed.Count -eq 0) {
            Add-Pass "ACA adapter terminate surfaces RBAC, throttling, network, wrong-subscription and unrecognised failures as errors (fail closed)"
        } else {
            Add-Fail "ACA adapter terminate reported success for real failure(s): $($swallowed -join ', ')"
        }

        # --- 5. `az` missing entirely must fail, not read a stale exit code ---
        # The pre-fix adapter read $LASTEXITCODE after a call that never ran, so
        # a preceding success made a missing `az` look like a completed stop.
        cmd /c "exit 0" | Out-Null   # force $LASTEXITCODE to 0 ("success")
        $env:PATH = "$($adapterStub.WorkDir)"
        $missingAz = [pscustomobject]@{ Threw = $false; Result = $null; Message = "" }
        try {
            $missingAz.Result = Remove-SquadExecution -Provider $acaAdapter -Handle $acaHandle
        } catch {
            $missingAz.Threw = $true
            $missingAz.Message = [string]$_.Exception.Message
        } finally {
            $env:PATH = "$($adapterStub.BinDir);$adapterPrevPath"
        }
        if ($missingAz.Threw) {
            Add-Pass "ACA adapter terminate fails when 'az' is not on PATH (a stale `$LASTEXITCODE cannot be read as a successful stop)"
        } else {
            Add-Fail "ACA adapter terminate reported Terminated=$($missingAz.Result.Terminated) with no 'az' on PATH; nothing ran, so nothing was terminated"
        }

        # --- 6. wait advances Provisioning -> Running -------------------------
        Reset-SquadCliStubLog -Stub $adapterStub
        $env:SQUAD_STUB_EXEC_SEQ = Join-Path $adapterStub.Root "exec-seq.marker"
        Remove-Item -LiteralPath $env:SQUAD_STUB_EXEC_SEQ -Force -ErrorAction SilentlyContinue
        $waitResult = $null
        $waitThrew = ""
        try {
            $waitResult = Wait-SquadExecution -Provider $acaAdapter -Handle $acaHandle -TimeoutSeconds 30 -PollSeconds 1
        } catch {
            $waitThrew = [string]$_.Exception.Message
        }
        $env:SQUAD_STUB_EXEC_SEQ = ""
        $showCalls = @(Get-SquadCliStubCall -Stub $adapterStub -Tool az | Where-Object { $_ -like "containerapp job execution show*" })
        if (-not $waitThrew -and $waitResult -and $waitResult.Status -eq "Running" -and $showCalls.Count -ge 2) {
            Add-Pass "ACA adapter wait polls 'az containerapp job execution show' until the execution leaves Provisioning ($($showCalls.Count) polls)"
        } else {
            Add-Fail "ACA adapter wait did not advance Provisioning -> Running (status=$($waitResult.Status) polls=$($showCalls.Count) error=$waitThrew)"
        }

        # --- 7. wait must not report a still-provisioning execution as ready --
        Reset-SquadCliStubLog -Stub $adapterStub
        $env:SQUAD_STUB_EXEC_STUCK = "1"
        $stuckThrew = $false
        $stuckError = ""
        $stuckStatus = ""
        try {
            $stuckStatus = (Wait-SquadExecution -Provider $acaAdapter -Handle $acaHandle -TimeoutSeconds 1 -PollSeconds 1).Status
        } catch {
            $stuckThrew = $true
            $stuckError = [string]$_.Exception.Message
        }
        $env:SQUAD_STUB_EXEC_STUCK = ""
        $stuckPolls = @(Get-SquadCliStubCall -Stub $adapterStub -Tool az | Where-Object { $_ -like "containerapp job execution show*" })
        if ($stuckThrew -and $stuckError -match "Timed out" -and $stuckPolls.Count -ge 1) {
            Add-Pass "ACA adapter wait polls, then times out instead of returning a still-Provisioning execution as ready"
        } else {
            Add-Fail "ACA adapter wait did not time out on a never-ready execution (status=$stuckStatus polls=$($stuckPolls.Count) error=$stuckError)"
        }
    } catch {
        Add-Fail "ACA Job adapter checks threw: $($_.Exception.Message)"
    } finally {
        $env:PATH = $adapterPrevPath
        foreach ($name in $adapterEnvNames) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        if ($adapterStub) { Remove-SquadCliStubEnvironment -Stub $adapterStub }
    }
}

# ---------------------------------------------------------------------------
# 8c. Sandbox feature flag + route gate (no CLI, no stubs needed)
# ---------------------------------------------------------------------------
# The flag is the whole safety story for Sprint 5: with it unset, the sandbox
# plane must be unreachable even for a dispatch that explicitly asks for it.
# These checks pin the gate itself; section 8d drives the provider behind it.
Write-Section "Sandbox feature flag and route gate"
if (-not (Test-Path $providerLib)) {
    Add-Fail "scripts/lib/squad-aca-provider.ps1 is missing (sandbox route gate checks)"
} else {
    $gateSaved = [Environment]::GetEnvironmentVariable("SQUAD_ACA_ENABLE_SANDBOX", "Process")
    $gateCatalogDir = Join-Path $RepoRoot "scripts\tests"
    $approvedCatalog = $null
    try {
        Remove-Item "Env:SQUAD_ACA_ENABLE_SANDBOX" -ErrorAction SilentlyContinue

        # An APPROVED, non-provisional catalog. The shipped catalog is
        # provisional:true (its own header says treat it as report-only), so the
        # ON-path tests must supply their own -- which is itself the proof that
        # the provisional gate bites.
        $approvedCatalog = @'
{
  "provisional": false,
  "classes": [
    {
      "id": "sandbox-node-lts",
      "approved": true,
      "image": "acrstub.azurecr.io/squad-worker:stub",
      "resources": { "cpu": 2, "memoryGi": 4 },
      "egress": {
        "defaultAction": "Deny",
        "hostRules": [
          { "pattern": "*.github.com", "action": "Allow" },
          { "pattern": "registry.npmjs.org", "action": "Allow" }
        ],
        "trafficInspection": "Full"
      }
    },
    { "id": "sandbox-container-build", "approved": false, "resources": { "cpu": 4, "memoryGi": 8 } }
  ]
}
'@ | ConvertFrom-Json

        $sandboxDecision = [pscustomobject]@{ route = "sandbox"; sandboxClass = "sandbox-node-lts"; defaultImageSufficient = $false }

        # --- 1. Default OFF ---------------------------------------------------
        if (-not (Test-SquadSandboxEnabled)) {
            Add-Pass "Sandbox feature flag defaults OFF when SQUAD_ACA_ENABLE_SANDBOX is unset"
        } else {
            Add-Fail "Sandbox feature flag is ON by default -- ACA Jobs must be the unconditional default"
        }

        # --- 2. Flag OFF makes the sandbox route unreachable ------------------
        # Even when the resolver explicitly asked for it AND an approved,
        # non-provisional catalog is available. This is the check that a
        # "default the flag to on" mutation has to trip.
        $offRoute = Resolve-SquadExecutionRoute -Decision $sandboxDecision -Catalog $approvedCatalog
        if ($offRoute.Route -eq "fail-closed" -and -not $offRoute.FeatureEnabled -and $offRoute.Reason -like "sandbox-feature-disabled*") {
            Add-Pass "Flag OFF: an explicit 'sandbox' decision is refused, not silently downgraded (route=$($offRoute.Route))"
        } else {
            Add-Fail "Flag OFF did not make the sandbox route unreachable (route=$($offRoute.Route) reason=$($offRoute.Reason) enabled=$($offRoute.FeatureEnabled))"
        }

        # --- 3. Flag OFF: an aca-job decision is still aca-job ----------------
        $offJob = Resolve-SquadExecutionRoute -Decision ([pscustomobject]@{ route = "aca-job" }) -Catalog $approvedCatalog
        $offNone = Resolve-SquadExecutionRoute -Decision $null -Catalog $approvedCatalog
        if ($offJob.Route -eq "aca-job" -and $offNone.Route -eq "aca-job") {
            Add-Pass "Flag OFF: 'aca-job' and 'no resolution' both route to ACA Jobs (today's path, unchanged)"
        } else {
            Add-Fail "Flag OFF changed the default path (aca-job=$($offJob.Route) none=$($offNone.Route))"
        }

        # --- 4. Kill switch ---------------------------------------------------
        $env:SQUAD_ACA_ENABLE_SANDBOX = "0"
        $killed = Test-SquadSandboxEnabled -Config ([pscustomobject]@{ sandboxEnabled = $true })
        $env:SQUAD_ACA_ENABLE_SANDBOX = "1"
        $onWithConfigOff = Test-SquadSandboxEnabled -Config ([pscustomobject]@{ sandboxEnabled = $false })
        Remove-Item "Env:SQUAD_ACA_ENABLE_SANDBOX" -ErrorAction SilentlyContinue
        if (-not $killed -and $onWithConfigOff) {
            Add-Pass "An explicit SQUAD_ACA_ENABLE_SANDBOX value decides in both directions (0 overrides an opted-in config)"
        } else {
            Add-Fail "SQUAD_ACA_ENABLE_SANDBOX is not authoritative (kill switch honoured=$(-not $killed) explicit-on honoured=$onWithConfigOff)"
        }

        # --- 5. The shipped catalog is REVIEWED, and provisional still bites --
        # Issue #25 cleared the provisional interlock on config/sandbox-classes.json
        # (real digests, pinned). The interlock itself must still work, so it is
        # exercised against a synthesized provisional copy of the SAME catalog --
        # deleting the check along with the condition that triggered it would
        # leave the next unreviewed catalog unguarded.
        $env:SQUAD_ACA_ENABLE_SANDBOX = "1"
        $shippedCatalogPath = Join-Path $RepoRoot "config\sandbox-classes.json"
        $shippedCatalogText = Get-Content $shippedCatalogPath -Raw
        $shippedRoute = Resolve-SquadExecutionRoute -Decision $sandboxDecision -CatalogPath $shippedCatalogPath
        if ($shippedRoute.Route -eq "sandbox" -and $shippedRoute.SandboxClass -and $shippedRoute.SandboxClass.id -eq "sandbox-node-lts") {
            Add-Pass "Flag ON + the SHIPPED catalog reaches the sandbox plane (issue #25 cleared the provisional interlock)"
        } else {
            Add-Fail "The shipped catalog did not reach the sandbox plane (route=$($shippedRoute.Route) reason=$($shippedRoute.Reason))"
        }

        $provisionalCopy = $shippedCatalogText | ConvertFrom-Json
        $provisionalCopy.provisional = $true
        $provisionalRoute = Resolve-SquadExecutionRoute -Decision $sandboxDecision -Catalog $provisionalCopy
        if ($provisionalRoute.Route -eq "fail-closed" -and $provisionalRoute.Reason -eq "catalog-provisional") {
            Add-Pass "A provisional catalog still fails closed even when every class in it is approved and pinned (report-only means report-only)"
        } else {
            Add-Fail "A provisional catalog did not fail closed (route=$($provisionalRoute.Route) reason=$($provisionalRoute.Reason))"
        }

        # The shipped catalog's approved classes must be pinned by DIGEST. A
        # moving tag means re-tagging the registry silently changes what executes
        # repository code inside a sandbox, with nothing downstream to notice.
        $shippedCatalog = $shippedCatalogText | ConvertFrom-Json
        $shippedApproved = @($shippedCatalog.classes | Where-Object { $_.approved -eq $true })
        $unpinned = @($shippedApproved | Where-Object { -not $_.image.pinned -or $_.image.digest -notmatch '^sha256:[0-9a-f]{64}$' })
        $shippedUnapproved = @($shippedCatalog.classes | Where-Object { $_.approved -ne $true })
        $placeholders = @($shippedCatalog.classes | Where-Object { [string]$_.image.reference -like "*REPLACE-ME*" })
        if ($shippedApproved.Count -gt 0 -and $unpinned.Count -eq 0 -and $placeholders.Count -eq 0 -and $shippedUnapproved.Count -gt 0) {
            Add-Pass "Every approved class in the shipped catalog is pinned to a sha256 digest with no placeholder reference, and an unapproved class is retained as the approved-only filter's negative fixture"
        } else {
            Add-Fail "Shipped catalog pinning is wrong (approved=$($shippedApproved.Count) unpinned=$($unpinned.Count) placeholders=$($placeholders.Count) unapproved=$($shippedUnapproved.Count))"
        }

        # The shipped catalog's own unapproved class must still be unreachable.
        # Section 7 proves this against a synthetic catalog; this proves it
        # against the file that actually ships.
        $shippedUnapprovedRoute = Resolve-SquadExecutionRoute -CatalogPath $shippedCatalogPath `
            -Decision ([pscustomobject]@{ route = "sandbox"; sandboxClass = "sandbox-container-build"; defaultImageSufficient = $false })
        if ($shippedUnapprovedRoute.Route -eq "fail-closed" -and $shippedUnapprovedRoute.Reason -eq "class-not-approved") {
            Add-Pass "The shipped catalog's unapproved class is still unreachable now that the catalog is reviewed"
        } else {
            Add-Fail "The shipped unapproved class was reachable (route=$($shippedUnapprovedRoute.Route) reason=$($shippedUnapprovedRoute.Reason))"
        }

        # --- 6. Flag ON + approved class => sandbox ---------------------------
        $onRoute = Resolve-SquadExecutionRoute -Decision $sandboxDecision -Catalog $approvedCatalog
        if ($onRoute.Route -eq "sandbox" -and $onRoute.SandboxClass -and $onRoute.SandboxClass.id -eq "sandbox-node-lts") {
            Add-Pass "Flag ON + an approved class in a non-provisional catalog routes to the sandbox plane"
        } else {
            Add-Fail "Flag ON did not reach the sandbox plane for an approved class (route=$($onRoute.Route) reason=$($onRoute.Reason))"
        }

        # --- 7. Flag ON but the class is not administrator-approved ----------
        $unapproved = Resolve-SquadExecutionRoute -Catalog $approvedCatalog `
            -Decision ([pscustomobject]@{ route = "sandbox"; sandboxClass = "sandbox-container-build"; defaultImageSufficient = $false })
        $unknown = Resolve-SquadExecutionRoute -Catalog $approvedCatalog `
            -Decision ([pscustomobject]@{ route = "sandbox"; sandboxClass = "attacker-supplied-image"; defaultImageSufficient = $false })
        if ($unapproved.Route -eq "fail-closed" -and $unapproved.Reason -eq "class-not-approved" `
                -and $unknown.Route -eq "fail-closed" -and $unknown.Reason -eq "class-not-in-catalog") {
            Add-Pass "Only administrator-approved catalog classes are reachable (unapproved and unknown ids both fail closed)"
        } else {
            Add-Fail "An unapproved or unknown sandbox class was not refused (unapproved=$($unapproved.Reason) unknown=$($unknown.Reason))"
        }

        # --- 8. fail-closed stays fail-closed; junk routes fail closed -------
        $failClosed = Resolve-SquadExecutionRoute -Decision ([pscustomobject]@{ route = "fail-closed" }) -Catalog $approvedCatalog
        $junk = Resolve-SquadExecutionRoute -Decision ([pscustomobject]@{ route = "something-else" }) -Catalog $approvedCatalog
        if ($failClosed.Route -eq "fail-closed" -and $junk.Route -eq "fail-closed") {
            Add-Pass "A 'fail-closed' resolution, and any unrecognised route, refuse to dispatch even with the flag ON"
        } else {
            Add-Fail "fail-closed or an unrecognised route did not refuse (failClosed=$($failClosed.Route) junk=$($junk.Route))"
        }
    } catch {
        Add-Fail "Sandbox route gate checks threw: $($_.Exception.Message)"
    } finally {
        if ($null -eq $gateSaved) {
            Remove-Item "Env:SQUAD_ACA_ENABLE_SANDBOX" -ErrorAction SilentlyContinue
        } else {
            $env:SQUAD_ACA_ENABLE_SANDBOX = $gateSaved
        }
    }
}

# ---------------------------------------------------------------------------
# 8d. ACA Sandboxes provider against a stubbed `aca`
# ---------------------------------------------------------------------------
# Drives New-SandboxExecutionProvider itself, fully offline, through the fake
# `aca` from scripts/tests/cli-stub-harness.ps1.
#
# The two defects these exist for are the ones the live investigation actually
# hit: `aca sandbox exec` has a hard ~120s client timeout, so a session run as a
# single synchronous exec dies at two minutes; and that same timeout, read as a
# failure rather than as INCONCLUSIVE, kills a healthy 60-minute run. Both are
# invisible to any check that only asserts "the right commands were issued".
Write-Section "ACA Sandboxes provider (stubbed aca)"
$sandboxHarness = Join-Path $RepoRoot "scripts\tests\cli-stub-harness.ps1"
if (-not (Test-Path $providerLib)) {
    Add-Fail "scripts/lib/squad-aca-provider.ps1 is missing (sandbox provider checks)"
} elseif (-not (Test-Path $sandboxHarness)) {
    Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing (sandbox provider checks)"
} elseif (-not $IsWindowsHost) {
    Write-Host "  [SKIP] Sandbox provider checks require Windows (.cmd stubs)" -ForegroundColor Yellow
} else {
    . $sandboxHarness
    $sbStub = $null
    $sbPrevPath = $env:PATH
    $sbEnvNames = @("SQUAD_STUB_AZ_LOG", "SQUAD_STUB_ACA_LOG", "SQUAD_STUB_FIXTURES",
        "SQUAD_STUB_SBG_IDENTITY", "SQUAD_STUB_SBG_RC",
        "SQUAD_STUB_ACA_RC", "SQUAD_STUB_ACA_ERR", "SQUAD_STUB_ACA_EXEC_RC",
        "SQUAD_STUB_ACA_EGRESS_RC", "SQUAD_STUB_ACA_EGRESS_ERR",
        "SQUAD_STUB_ACA_DELETE_RC", "SQUAD_STUB_ACA_DELETE_ERR",
        "SQUAD_STUB_ACA_CANCEL_RC", "SQUAD_STUB_ACA_CANCEL_ERR", "SQUAD_STUB_ACA_CANCEL_STATUS",
        "SQUAD_STUB_ACA_POLL_DIR", "SQUAD_STUB_ACA_TIMEOUT_ONCE",
        "SQUAD_STUB_ACA_CRED_RC", "SQUAD_STUB_ACA_CRED_ERR", "SQUAD_STUB_ACA_CRED_ID",
        "SQUAD_STUB_ACA_CRED_STDIN", "SQUAD_STUB_ACA_CREDDEL_RC", "SQUAD_STUB_ACA_CREDDEL_ERR",
        "SQUAD_STUB_ACA_SEED_RC", "SQUAD_STUB_ACA_SEED_STDIN", "SQUAD_STUB_ACA_VAULT_MODE",
        "SQUAD_STUB_ACA_LIST_FIXTURE",
        "SQUAD_STUB_ACA_LIST_RC", "SQUAD_STUB_ACA_LIST_ERR")
    try {
        $sbStub = New-SquadCliStubEnvironment
        # Snapshot the credential staging directory before ANY scenario runs.
        # It lives under the real user profile, which no stubbed HOME
        # redirects, so it is shared with every other run on this machine --
        # see the comparison at the end of this section (issue #100).
        $sbStageDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".squad-on-aca\.credstage"
        # `@((Get-ChildItem).Name)` on an EMPTY directory is an array holding
        # one $null, not an empty array -- so an empty staging directory read
        # as "one leaked file" with a blank name. CI caught that on the first
        # run of this check; the local runs happened to have either files or no
        # directory at all. Piping to Select-Object -ExpandProperty yields
        # nothing for an empty directory, which is the intended answer.
        $sbStageBefore = @(Get-ChildItem -File -LiteralPath $sbStageDir -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name)
        $env:PATH = "$($sbStub.BinDir);$sbPrevPath"
        $env:SQUAD_STUB_AZ_LOG = $sbStub.AzLog
        $env:SQUAD_STUB_ACA_LOG = $sbStub.AcaLog
        $env:SQUAD_STUB_FIXTURES = $sbStub.FixtureDir
        $env:SQUAD_STUB_SBG_IDENTITY = ""
        $env:SQUAD_STUB_SBG_RC = "0"
        $env:SQUAD_STUB_ACA_RC = "0"
        $env:SQUAD_STUB_ACA_ERR = ""
        $env:SQUAD_STUB_ACA_EXEC_RC = "0"
        $env:SQUAD_STUB_ACA_EGRESS_RC = "0"
        $env:SQUAD_STUB_ACA_EGRESS_ERR = ""
        $env:SQUAD_STUB_ACA_DELETE_RC = "0"
        $env:SQUAD_STUB_ACA_DELETE_ERR = ""
        $env:SQUAD_STUB_ACA_CANCEL_RC = "0"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = ""
        $env:SQUAD_STUB_ACA_CANCEL_STATUS = "killed"
        $env:SQUAD_STUB_ACA_POLL_DIR = ""
        $env:SQUAD_STUB_ACA_TIMEOUT_ONCE = ""
        $env:SQUAD_STUB_ACA_CRED_RC = "0"
        $env:SQUAD_STUB_ACA_CRED_ERR = ""
        $env:SQUAD_STUB_ACA_CRED_ID = ""
        $env:SQUAD_STUB_ACA_CRED_STDIN = ""
        $env:SQUAD_STUB_ACA_CREDDEL_RC = "0"
        $env:SQUAD_STUB_ACA_CREDDEL_ERR = ""
        $env:SQUAD_STUB_ACA_SEED_RC = "0"
        $env:SQUAD_STUB_ACA_SEED_STDIN = ""
        $env:SQUAD_STUB_ACA_VAULT_MODE = "700"
        $env:SQUAD_STUB_ACA_LIST_FIXTURE = ""
        $env:SQUAD_STUB_ACA_LIST_RC = "0"
        $env:SQUAD_STUB_ACA_LIST_ERR = ""

        $sbCli = Join-Path $sbStub.BinDir "aca.cmd"
        $resolvedAca = (Get-Command aca -ErrorAction SilentlyContinue)
        if ($resolvedAca -and $resolvedAca.Source -eq $sbCli) {
            Add-Pass "Fake 'aca' is first on PATH; sandbox provider checks run fully offline"
        } else {
            Add-Fail "Could not stub 'aca' on PATH for the sandbox provider checks (resolved: $($resolvedAca.Source))"
        }

        $sbClass = @'
{
  "id": "sandbox-node-lts",
  "approved": true,
  "resources": { "cpu": 2, "memoryGi": 4 },
  "egress": {
    "defaultAction": "Deny",
    "hostRules": [
      { "pattern": "*.github.com", "action": "Allow" },
      { "pattern": "registry.npmjs.org", "action": "Allow" }
    ],
    "trafficInspection": "Full"
  },
  "limits": { "maxConcurrentSandboxes": 4, "maxSessionMinutes": 60, "maxMonthlyCostUsd": 50 }
}
'@ | ConvertFrom-Json

        $sbSecret = "ghp-stub-secret-token-value"
        # Built by concatenation so no literal that looks like a real credential
        # is ever committed -- the repository's own secret scan would reject it.
        $sbCopilotSecret = "github" + "_pat_" + "stubvalue00000000"
        function New-SandboxTestProvider {
            param(
                [string]$DiskId = "aaaaaaaa-1111-2222-3333-444444444444",
                [string]$DiskLabel = "",
                [hashtable]$Secrets = $null,
                [hashtable]$Brokered = $null
            )
            if ($null -eq $Secrets) { $Secrets = @{ GH_TOKEN = $sbSecret; COPILOT_GITHUB_TOKEN = $sbCopilotSecret } }
            if ($null -eq $Brokered) { $Brokered = @{ "github-copilot" = $sbCopilotSecret } }
            return New-SquadExecutionProvider -Kind "sandbox" -Options @{
                Class               = $sbClass
                SandboxGroup        = "sbg-squad-stub"
                ResourceGroup       = "rg-squad-stub"
                SubscriptionId      = "00000000-0000-0000-0000-000000000000"
                DiskId              = $DiskId
                DiskLabel           = $DiskLabel
                AcaCliPath          = $sbCli
                IdleTimeoutSeconds  = 1800
                PollSeconds         = 1
                WorkerSecrets       = $Secrets
                BrokeredCredentials = $Brokered
            }
        }

        $sbRequest = New-SquadDispatchRequest -SessionId "stub-session" -Repository "octo/demo" `
            -Prompt "do the thing" -Mode "prompt" -PushChanges $true -OutputBranch "squad/stub-session"

        # --- 1. create: full argv sequence, in order --------------------------
        Reset-SquadCliStubLog -Stub $sbStub
        $sbProvider = New-SandboxTestProvider
        $sbOutcome = @{}
        $sbCreateErr = ""
        try {
            Start-SquadExecution -Provider $sbProvider -Request $sbRequest -Outcome $sbOutcome 6>$null | Out-Null
        } catch {
            $sbCreateErr = [string]$_.Exception.Message
        }
        $sbCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $iCreate  = [array]::FindIndex($sbCalls, [Predicate[string]] { param($l) $l -like "sandbox create *" })
        $iEgress  = [array]::FindIndex($sbCalls, [Predicate[string]] { param($l) $l -like "sandbox egress set *" })
        $iLife    = [array]::FindIndex($sbCalls, [Predicate[string]] { param($l) $l -like "sandbox lifecycle set *" })
        $iLaunch  = [array]::FindIndex($sbCalls, [Predicate[string]] { param($l) $l -like "*squad-launched*" })

        if (-not $sbCreateErr -and $iCreate -ge 0 -and $iEgress -ge 0 -and $iLife -ge 0 -and $iLaunch -ge 0) {
            Add-Pass "Sandbox create issues create -> egress set -> lifecycle set -> detached exec (4 aca calls)"
        } else {
            Add-Fail "Sandbox create did not issue the expected aca sequence (err=$sbCreateErr calls=$($sbCalls -join ' | '))"
        }

        # THE ordering assertion: egress policy must be applied BEFORE the exec
        # that runs anything from the repository. A create that applied policy
        # afterwards would still issue every one of the calls above.
        if ($iEgress -ge 0 -and $iLaunch -ge 0 -and $iEgress -lt $iLaunch -and $iCreate -lt $iEgress) {
            Add-Pass "Egress default-deny is applied BEFORE the worker launch (egress #$iEgress precedes launch #$iLaunch)"
        } else {
            Add-Fail "Egress policy was not applied before repository code ran (create=$iCreate egress=$iEgress launch=$iLaunch)"
        }

        if ($iCreate -ge 0 -and $sbCalls[$iCreate] -like "*--disk-id aaaaaaaa-1111-2222-3333-444444444444*" `
                -and $sbCalls[$iCreate] -like "*--label name=squad-stub-session*" `
                -and $sbCalls[$iCreate] -like "*--cpu 2000m*" -and $sbCalls[$iCreate] -like "*--memory 4096Mi*") {
            Add-Pass "Sandbox create uses --disk-id (private disks are not addressable by --disk) and the class's resources"
        } else {
            Add-Fail "Sandbox create argv is wrong: $(if ($iCreate -ge 0) { $sbCalls[$iCreate] } else { '<missing>' })"
        }

        if ($iEgress -ge 0 -and $sbCalls[$iEgress] -like "*--default Deny*" `
                -and $sbCalls[$iEgress] -like "*--rule *.github.com:Allow*" `
                -and $sbCalls[$iEgress] -like "*--rule registry.npmjs.org:Allow*" `
                -and $sbCalls[$iEgress] -like "*--traffic-inspection Full*") {
            Add-Pass "Egress applies the class's default-deny action, every allowlist rule, and traffic inspection"
        } else {
            Add-Fail "Egress argv is wrong: $(if ($iEgress -ge 0) { $sbCalls[$iEgress] } else { '<missing>' })"
        }

        # Auto-suspend defaults to ENABLED at 600s, which would suspend a live
        # session; it has to be set explicitly.
        if ($iLife -ge 0 -and $sbCalls[$iLife] -like "*--auto-suspend enable*" -and $sbCalls[$iLife] -like "*--idle-timeout-seconds 1800*") {
            Add-Pass "Auto-suspend is pinned explicitly instead of inheriting the 600s default"
        } else {
            Add-Fail "Auto-suspend was not pinned: $(if ($iLife -ge 0) { $sbCalls[$iLife] } else { '<missing>' })"
        }

        # --- 2. the launch is DETACHED (proven by running it in a real shell) -
        # `aca sandbox exec` returns after ~120s no matter what the command is
        # doing, so a session held open by one exec dies at two minutes -- and
        # `create`'s catch tears the healthy sandbox down with it.
        #
        # This CANNOT be asserted by substring. In POSIX/bash grammar `&` is a
        # list terminator that binds LOOSER than `&&`, so
        #
        #   prelude && setsid nohup bash -c '...' </dev/null >/dev/null 2>&1 &
        #
        # contains every character of a detach while backgrounding the entire
        # and-list and binding the three redirections to the last simple command
        # only -- the async subshell keeps the exec's fd 0/1/2 open for the whole
        # worker run. A substring assertion passes on both shapes; the stub `aca`
        # never evaluates the `-c` payload in a shell, so nothing else in this
        # suite can tell them apart either. The only assertion that can is to
        # execute the emitted command in a real shell and time when the parent's
        # streams reach EOF.
        $launchLine = if ($iLaunch -ge 0) { $sbCalls[$iLaunch] } else { "" }
        # The launch argv is the ONE call that legitimately carries the worker
        # token, so it must be scrubbed before it can reach a failure message
        # (and from there a CI log).
        $safeLaunchLine = Protect-SandboxText -Text $launchLine -Secrets @($sbSecret)

        # (a) the command evaluated below is byte-for-byte the command that ships.
        $sbShipEnv = New-SandboxWorkerEnvironment -Request $sbRequest -Context $sbProvider.Context
        $sbShipLaunch = New-SandboxLaunchCommand -Environment $sbShipEnv -StateDir $sbProvider.Context.StateDir
        if ($launchLine.Contains($sbShipLaunch)) {
            Add-Pass "The command the detach test evaluates is byte-for-byte the command 'aca sandbox exec -c' was given"
        } else {
            Add-Fail "New-SandboxLaunchCommand no longer produces the argv that was actually issued, so the detach test would be testing a different string: $safeLaunchLine"
        }

        # (b) the behavioural test, delegated to scripts/tests/verify-launch-detachment.ps1
        #     so the same probe is a standalone CI gate on a real Linux runner
        #     rather than a check that only ever runs on a developer's WSL box.
        #     A correct implementation releases the caller while the worker is
        #     still running; the mis-scoped one blocks for the worker's full
        #     duration. Exit 77 means the probe DID NOT RUN (deps.sh convention).
        $sbDetachScript = Join-Path $RepoRoot "scripts\tests\verify-launch-detachment.ps1"
        if (-not (Test-Path $sbDetachScript)) {
            Add-Fail "scripts/tests/verify-launch-detachment.ps1 is missing -- nothing else in this suite can tell a detach from a command containing the characters of one"
        } else {
            $sbDetachOut = (& (Get-Process -Id $PID).Path -NoProfile -File $sbDetachScript 2>&1 | Out-String)
            $sbDetachRc = $LASTEXITCODE
            $sbDetachFlat = ($sbDetachOut -replace "`r?`n", " | ").Trim()
            if ($sbDetachRc -eq 0) {
                Add-Pass "The emitted launch command really detaches in a real shell (verify-launch-detachment.ps1): $sbDetachFlat"
            } elseif ($sbDetachRc -eq 77) {
                # A dependency we cannot satisfy is a SKIP, never a pass: the
                # worker suite's convention (worker/tests/lib/deps.sh -> exit 77
                # -> run-tests.sh reports SKIP) exists so a check cannot quietly
                # stop existing when its dependency goes missing.
                Add-Skip "Worker-launch detachment is UNVERIFIED: $sbDetachFlat"
            } else {
                Add-Fail "The emitted launch command does NOT detach (verify-launch-detachment.ps1 exit $sbDetachRc): $sbDetachFlat"
            }
        }

        if ($launchLine -like "*/usr/local/bin/squad-on-aca*" -and $launchLine -like "*exit-code*" -and $launchLine -like "*touch /tmp/squad-session/done*") {
            Add-Pass "The detached wrapper records an exit code and touches the completion marker last"
        } else {
            Add-Fail "The detached wrapper does not record terminal state: $safeLaunchLine"
        }

        # --- 3. secrets never reach anything the provider EMITS ---------------
        # Sprint 7 moved credential delivery off every argument vector: the
        # Copilot plane goes through the platform's own brokerage (token on
        # stdin, opaque id back), and the git/`gh` plane is written to the stdin
        # of a staging exec. So the assertion is now absolute -- NO recorded aca
        # argv may contain either token -- and it is checked below in section 12
        # against the stub's own log of what each process actually received.
        # What must also never happen is the provider REPEATING a token: into the
        # dispatch response, into an error message, or into a rendered argv.
        $sbResponseText = ($sbOutcome["Response"] | ConvertTo-Json -Depth 8)
        if ($sbResponseText -notmatch [regex]::Escape($sbSecret)) {
            Add-Pass "The worker token never appears in the dispatch response"
        } else {
            Add-Fail "The worker token leaked into the dispatch response"
        }
        $sbSafe = Get-SandboxSafeArgv -Argv @("sandbox", "egress", "set", "--default", "Deny", "--rule", "*.github.com:Allow", "-c", "GH_TOKEN=$sbSecret /usr/local/bin/squad-on-aca", "--token", $sbSecret)
        if ($sbSafe -notmatch [regex]::Escape($sbSecret) -and $sbSafe -notmatch "github\.com" -and $sbSafe -notmatch "squad-on-aca" -and $sbSafe -like "*--token <redacted>*") {
            Add-Pass "Safe argv rendering redacts tokens, egress policy values and remote commands"
        } else {
            Add-Fail "Safe argv rendering leaked a token, an egress value or a command: $sbSafe"
        }
        # And a failure of the launch itself -- the one call whose argv really
        # does carry the token -- must not quote it back.
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_ACA_EXEC_RC = "1"
        $sbLaunchMsg = ""
        try { Start-SquadExecution -Provider $sbProvider -Request $sbRequest 6>$null | Out-Null } catch { $sbLaunchMsg = [string]$_.Exception.Message }
        $env:SQUAD_STUB_ACA_EXEC_RC = "0"
        if ($sbLaunchMsg -and $sbLaunchMsg -notmatch [regex]::Escape($sbSecret) -and $sbLaunchMsg -notmatch "github\.com") {
            Add-Pass "A failed worker launch reports the failure without echoing the token-bearing command"
        } else {
            Add-Fail "A failed worker launch leaked the token or the egress policy: $sbLaunchMsg"
        }

        # Protect-SandboxText, DIRECTLY. It is the only control on captured CLI
        # OUTPUT (Get-SandboxErrorText feeds every thrown error in the provider,
        # plus `logs` line output and `cancel` host output), and until now it had
        # no test of its own: the checks above pass on Get-SandboxSafeArgv's
        # argv-side redaction alone, so the whole function body could be replaced
        # with `return $Text` and the suite still reported all green.
        #
        # The lengths are the ones that occur in practice. They also happen to be
        # exactly the lengths the defect hid behind: `[string]$secret.Length -lt 8`
        # is `[string]($secret.Length)`, so PowerShell coerced the right operand
        # to string and compared LEXICALLY -- "40" -lt "8" is $true -- and only
        # lengths 8, 9 and 80-99 were ever scrubbed.
        $sbRedactLengths = @(
            @{ Len = 27;   What = "the suite's own fixture token" },
            @{ Len = 36;   What = "a GUID" },
            @{ Len = 40;   What = "a classic GitHub PAT" },
            @{ Len = 64;   What = "a hex API key" },
            @{ Len = 93;   What = "a fine-grained PAT" },
            @{ Len = 1200; What = "an ACR refresh token / JWT" }
        )
        $sbRedactBad = @()
        foreach ($case in $sbRedactLengths) {
            $secret = "s" + ("K" * ([int]$case.Len - 1))
            $out = Protect-SandboxText -Text "aca: request failed, token=$secret was rejected" -Secrets @($secret)
            if ($out.Contains($secret) -or $out -notlike "*token=<redacted>*") {
                $sbRedactBad += "$($case.Len) ($($case.What))"
            }
        }
        if ($sbRedactBad.Count -eq 0) {
            Add-Pass "Protect-SandboxText redacts a secret at every realistic credential length (27/36/40/64/93/1200)"
        } else {
            Add-Fail "Protect-SandboxText passed a secret through verbatim at length(s): $($sbRedactBad -join ', ')"
        }

        # Multiple secrets, repeated occurrences, and the sub-8 floor (too short
        # to be a credential and too likely to shred ordinary words).
        $sbLongA = "A" * 40
        $sbLongB = "B" * 36
        $sbMulti = Protect-SandboxText -Text "first=$sbLongA second=$sbLongB again=$sbLongA short=abc" -Secrets @($sbLongA, $sbLongB, "abc")
        if ($sbMulti -eq "first=<redacted> second=<redacted> again=<redacted> short=abc") {
            Add-Pass "Protect-SandboxText replaces every occurrence of every secret and leaves sub-8 values alone"
        } else {
            Add-Fail "Protect-SandboxText mishandled multiple/repeated secrets or the length floor: $sbMulti"
        }

        # And the path that matters: a CLI echoing the secret back in its OWN
        # error text must not survive Get-SandboxErrorText into a thrown message.
        $sbEchoResult = [pscustomobject]@{
            StdErr = @("ERROR: authentication failed for token $sbSecret (40 chars)")
            StdOut = @()
        }
        $sbEchoText = Get-SandboxErrorText -Result $sbEchoResult -Secrets @($sbSecret)
        if ($sbEchoText -notmatch [regex]::Escape($sbSecret) -and $sbEchoText -like "*<redacted>*") {
            Add-Pass "A CLI that echoes the secret back in its own error text is scrubbed before the text reaches an exception"
        } else {
            Add-Fail "Get-SandboxErrorText passed a CLI-echoed secret through: $sbEchoText"
        }

        # --- 4. a long session is driven by POLLING, not by one exec ---------
        $pollDir = Join-Path $sbStub.Root "pollstate"
        New-Item -ItemType Directory -Force -Path $pollDir | Out-Null
        $env:SQUAD_STUB_ACA_POLL_DIR = $pollDir
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "running" -Encoding ascii -NoNewline

        Reset-SquadCliStubLog -Stub $sbStub
        $sbHandle = $sbOutcome["Response"].sessionHandle
        $sbRunning = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        if ($sbRunning.Status -eq "Running" -and -not $sbRunning.Inconclusive) {
            Add-Pass "A poll of a live session reports Running from the marker/phase file"
        } else {
            Add-Fail "A live session did not poll as Running (status=$($sbRunning.Status) inconclusive=$($sbRunning.Inconclusive))"
        }

        # Terminal state must come from the marker PLUS a recorded exit code.
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "done" -Encoding ascii -NoNewline
        Set-Content -LiteralPath (Join-Path $pollDir "done.txt") -Value "x" -Encoding ascii -NoNewline
        $sbMarkerOnly = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        Set-Content -LiteralPath (Join-Path $pollDir "exit.txt") -Value "0" -Encoding ascii -NoNewline
        $sbDone = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        Set-Content -LiteralPath (Join-Path $pollDir "exit.txt") -Value "1" -Encoding ascii -NoNewline
        $sbFailed = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        if ($sbMarkerOnly.Status -ne "Succeeded" -and $sbDone.Status -eq "Succeeded" -and $sbFailed.Status -eq "Failed") {
            Add-Pass "Terminal state needs the completion marker AND a recorded exit code (marker alone is not Succeeded)"
        } else {
            Add-Fail "Terminal state was derived incorrectly (markerOnly=$($sbMarkerOnly.Status) exit0=$($sbDone.Status) exit1=$($sbFailed.Status))"
        }

        # `wait` to terminal must issue MULTIPLE short execs, never rely on one.
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "running" -Encoding ascii -NoNewline
        Remove-Item -LiteralPath (Join-Path $pollDir "done.txt"), (Join-Path $pollDir "exit.txt") -Force -ErrorAction SilentlyContinue
        Reset-SquadCliStubLog -Stub $sbStub
        $sbWaitThrew = $false
        try {
            Wait-SquadExecution -Provider $sbProvider -Handle $sbHandle -TimeoutSeconds 3 -PollSeconds 1 -UntilTerminal | Out-Null
        } catch {
            $sbWaitThrew = $true
        }
        $sbPolls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca | Where-Object { $_ -like "sandbox exec *" })
        if ($sbWaitThrew -and $sbPolls.Count -ge 3) {
            Add-Pass "A long-running session is driven by repeated short polls ($($sbPolls.Count) execs), not by one synchronous exec"
        } else {
            Add-Fail "wait did not poll repeatedly (threw=$sbWaitThrew execs=$($sbPolls.Count))"
        }

        # --- 5. a transport timeout mid-poll is INCONCLUSIVE, and is re-polled -
        # `Network issue - retry policy expired` is the ~120s client timeout. The
        # work is almost certainly still running; reporting Failed here would
        # kill a healthy 60-minute session at the two-minute mark.
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "running" -Encoding ascii -NoNewline
        $timeoutMarker = Join-Path $sbStub.Root "timeout-once.txt"
        Remove-Item -LiteralPath $timeoutMarker -Force -ErrorAction SilentlyContinue
        $env:SQUAD_STUB_ACA_TIMEOUT_ONCE = $timeoutMarker
        Reset-SquadCliStubLog -Stub $sbStub
        $sbIncThrew = $false
        $sbInc = $null
        try {
            $sbInc = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        } catch {
            $sbIncThrew = $true
        }
        if (-not $sbIncThrew -and $sbInc -and $sbInc.Inconclusive -and $sbInc.Status -ne "Failed") {
            Add-Pass "A transport timeout mid-poll is reported INCONCLUSIVE, never as a failed session"
        } else {
            Add-Fail "A transport timeout was not treated as inconclusive (threw=$sbIncThrew status=$($sbInc.Status) inconclusive=$($sbInc.Inconclusive))"
        }

        # ... and the next poll (the stub's timeout fires only once) recovers.
        $sbAfter = Get-SquadExecutionStatus -Provider $sbProvider -Handle $sbHandle
        if (-not $sbAfter.Inconclusive -and $sbAfter.Status -eq "Running") {
            Add-Pass "Re-polling after an inconclusive transport timeout recovers the real state"
        } else {
            Add-Fail "Re-polling after a transport timeout did not recover (status=$($sbAfter.Status) inconclusive=$($sbAfter.Inconclusive))"
        }

        # `wait` must not return an inconclusive poll as a result either.
        Remove-Item -LiteralPath $timeoutMarker -Force -ErrorAction SilentlyContinue
        Set-Content -LiteralPath (Join-Path $pollDir "phase.txt") -Value "done" -Encoding ascii -NoNewline
        Set-Content -LiteralPath (Join-Path $pollDir "done.txt") -Value "x" -Encoding ascii -NoNewline
        Set-Content -LiteralPath (Join-Path $pollDir "exit.txt") -Value "0" -Encoding ascii -NoNewline
        $sbWaitRec = Wait-SquadExecution -Provider $sbProvider -Handle $sbHandle -TimeoutSeconds 10 -PollSeconds 1 -UntilTerminal
        $env:SQUAD_STUB_ACA_TIMEOUT_ONCE = ""
        if ($sbWaitRec.Status -eq "Succeeded" -and -not $sbWaitRec.Inconclusive) {
            Add-Pass "wait rides through an inconclusive poll and returns the real terminal state"
        } else {
            Add-Fail "wait did not ride through an inconclusive poll (status=$($sbWaitRec.Status) inconclusive=$($sbWaitRec.Inconclusive))"
        }

        # --- 6. terminate: idempotent, but only for 'already gone' -----------
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_ACA_DELETE_RC = "0"
        $sbTerm = Remove-SquadExecution -Provider $sbProvider -Handle $sbHandle
        $sbDeleteCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca | Where-Object { $_ -like "sandbox delete *" })
        if ($sbTerm.Terminated -and -not $sbTerm.AlreadyTerminal -and $sbDeleteCalls.Count -eq 1 -and $sbDeleteCalls[0] -like "*-l name=squad-stub-session --yes*") {
            Add-Pass "Sandbox terminate deletes with one labelled 'aca sandbox delete --yes'"
        } else {
            Add-Fail "Sandbox terminate did not delete correctly (terminated=$($sbTerm.Terminated) calls=$($sbDeleteCalls.Count))"
        }

        $sbGoneCases = @(
            @{ Rc = "1"; Err = "Error: sandbox with label name=squad-stub-session was not found"; Label = "not found" },
            @{ Rc = "1"; Err = "Error: ResourceNotFound: the sandbox no longer exists"; Label = "ResourceNotFound" }
        )
        $sbGoneOk = $true
        $sbGoneDetail = @()
        foreach ($case in $sbGoneCases) {
            $env:SQUAD_STUB_ACA_DELETE_RC = $case.Rc
            $env:SQUAD_STUB_ACA_DELETE_ERR = $case.Err
            $r = $null
            $threw = $false
            try { $r = Remove-SquadExecution -Provider $sbProvider -Handle $sbHandle } catch { $threw = $true }
            if ($threw -or -not $r.Terminated -or -not $r.AlreadyTerminal) {
                $sbGoneOk = $false
                $sbGoneDetail += "$($case.Label): threw=$threw terminated=$($r.Terminated) already=$($r.AlreadyTerminal)"
            }
        }
        $env:SQUAD_STUB_ACA_DELETE_RC = "0"
        $env:SQUAD_STUB_ACA_DELETE_ERR = ""
        if ($sbGoneOk) {
            Add-Pass "Sandbox terminate is idempotent: an already-deleted sandbox is success (AlreadyTerminal)"
        } else {
            Add-Fail "Sandbox terminate mishandled an already-gone sandbox ($($sbGoneDetail -join '; '))"
        }

        # The defect this exists for: returning Terminated=$true for EVERY
        # non-zero exit. A cleanup path told "terminated" stops looking, so an
        # auth failure, an RBAC denial, throttling or a transport timeout leaks
        # a running sandbox and bills for it.
        $sbFailCases = @(
            @{ Err = "ERROR: AADSTS700082: The refresh token has expired. Please run 'aca login'."; Label = "expired auth" },
            @{ Err = "Error: 403 CheckAccess: the caller does not have permission on the sandbox group"; Label = "RBAC denial" },
            @{ Err = "Error: 429 TooManyRequests: rate limit exceeded, retry after 30s"; Label = "throttling" },
            @{ Err = "Error: Network issue - retry policy expired"; Label = "transport timeout" }
        )
        $sbFailOk = $true
        $sbFailDetail = @()
        foreach ($case in $sbFailCases) {
            $env:SQUAD_STUB_ACA_DELETE_RC = "1"
            $env:SQUAD_STUB_ACA_DELETE_ERR = $case.Err
            $threw = $false
            $msg = ""
            try { Remove-SquadExecution -Provider $sbProvider -Handle $sbHandle | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
            if (-not $threw) {
                $sbFailOk = $false
                $sbFailDetail += "$($case.Label): did not throw"
            }
        }
        $env:SQUAD_STUB_ACA_DELETE_RC = "0"
        $env:SQUAD_STUB_ACA_DELETE_ERR = ""
        if ($sbFailOk) {
            Add-Pass "Sandbox terminate THROWS on auth, RBAC, throttling and transport failures (never reported as torn down)"
        } else {
            Add-Fail "Sandbox terminate swallowed a real failure ($($sbFailDetail -join '; '))"
        }

        # --- 6b. cancel classifies failures the same way terminate does -------
        # cancel is the softer sibling of the same defect: writing a non-zero
        # exit to the host and returning success tells the caller the session was
        # stopped when an auth failure, an RBAC denial, throttling or a transport
        # timeout says nothing about whether the worker is still running -- and
        # still billing. Same classifier as terminate, not a second mechanism.
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_ACA_CANCEL_RC = "0"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = ""
        $sbCancelOk = Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null
        $sbCancelCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca | Where-Object { $_ -like "*squad-cancelled*" })
        if ($sbCancelOk.Cancelled -and -not $sbCancelOk.AlreadyTerminal -and $sbCancelCalls.Count -eq 1) {
            Add-Pass "Sandbox cancel stops the worker with one labelled 'aca sandbox exec' and reports success"
        } else {
            Add-Fail "Sandbox cancel did not cancel correctly (cancelled=$($sbCancelOk.Cancelled) calls=$($sbCancelCalls.Count))"
        }

        $env:SQUAD_STUB_ACA_CANCEL_RC = "1"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = "Error: sandbox with label name=squad-stub-session was not found"
        $sbCancelGone = $null
        $sbCancelGoneThrew = $false
        try { $sbCancelGone = Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null } catch { $sbCancelGoneThrew = $true }
        if (-not $sbCancelGoneThrew -and $sbCancelGone.Cancelled -and $sbCancelGone.AlreadyTerminal) {
            Add-Pass "Sandbox cancel is idempotent: an already-gone sandbox is success (AlreadyTerminal), not an error"
        } else {
            Add-Fail "Sandbox cancel mishandled an already-gone sandbox (threw=$sbCancelGoneThrew cancelled=$($sbCancelGone.Cancelled) already=$($sbCancelGone.AlreadyTerminal))"
        }

        $sbCancelFailOk = $true
        $sbCancelFailDetail = @()
        foreach ($case in $sbFailCases) {
            $env:SQUAD_STUB_ACA_CANCEL_RC = "1"
            $env:SQUAD_STUB_ACA_CANCEL_ERR = $case.Err
            $threw = $false
            $msg = ""
            try { Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
            if (-not $threw) {
                $sbCancelFailOk = $false
                $sbCancelFailDetail += "$($case.Label): did not throw"
            } elseif ($msg -match [regex]::Escape($sbSecret)) {
                $sbCancelFailOk = $false
                $sbCancelFailDetail += "$($case.Label): leaked the token"
            }
        }
        $env:SQUAD_STUB_ACA_CANCEL_RC = "0"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = ""
        if ($sbCancelFailOk) {
            Add-Pass "Sandbox cancel THROWS on auth, RBAC, throttling and transport failures (never reported as cancelled)"
        } else {
            Add-Fail "Sandbox cancel swallowed a real failure ($($sbCancelFailDetail -join '; '))"
        }

        # --- 6c. cancel believes the SANDBOX, not the exec's exit code (#36) --
        # The Sprint 5 command was `pkill ... >/dev/null 2>&1; ...; echo
        # squad-cancelled`. `procps` is not in the pinned class image, so pkill
        # exited 127, the redirection destroyed the evidence, and the chain's
        # status was the echo's -- which cannot fail. Live, the provider reported
        # Cancelled = $true while the worker ran a further 51 seconds and then
        # OVERWROTE the cancellation markers with its own done/0.
        #
        # Every check below drives the stub to exit 0, because that is what the
        # real CLI did. A provider that reads the exec's status instead of the
        # sandbox's verdict passes none of them.
        $env:SQUAD_STUB_ACA_CANCEL_RC = "0"
        $env:SQUAD_STUB_ACA_CANCEL_ERR = ""

        $env:SQUAD_STUB_ACA_CANCEL_STATUS = "none"
        $sbSilentThrew = $false
        $sbSilentMsg = ""
        try { Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null | Out-Null } catch { $sbSilentThrew = $true; $sbSilentMsg = [string]$_.Exception.Message }
        if ($sbSilentThrew -and $sbSilentMsg -match "\[squad-sandbox:execution\]" -and $sbSilentMsg -match "still billing") {
            Add-Pass "Sandbox cancel REFUSES to report success when the exec exits 0 but the sandbox reported no outcome -- the exact shape of issue #36, where the chain ended in an echo that could not fail"
        } else {
            Add-Fail "Sandbox cancel accepted a silent exit-0 cancel (threw=$sbSilentThrew msg='$sbSilentMsg')"
        }

        $sbVerdictCases = @(
            @{ Status = "no-pidfile";  Kind = "capability"; Needle = "recorded no worker pid" },
            @{ Status = "bad-pidfile"; Kind = "capability"; Needle = "not a signalable process id" },
            @{ Status = "not-ours";    Kind = "capability"; Needle = "recycled it" },
            @{ Status = "kill-failed"; Kind = "execution";  Needle = "kill was rejected" },
            @{ Status = "survived";    Kind = "execution";  Needle = "after SIGTERM and SIGKILL" },
            @{ Status = "no-proc";     Kind = "capability"; Needle = "/proc is unreadable" },
            @{ Status = "scan-failed"; Kind = "capability"; Needle = "read no /proc entry at all" }
        )
        $sbVerdictOk = $true
        $sbVerdictDetail = @()
        foreach ($case in $sbVerdictCases) {
            $env:SQUAD_STUB_ACA_CANCEL_STATUS = $case.Status
            $threw = $false
            $msg = ""
            try { Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null | Out-Null } catch { $threw = $true; $msg = [string]$_.Exception.Message }
            if (-not $threw) {
                $sbVerdictOk = $false
                $sbVerdictDetail += "$($case.Status): reported success"
            } elseif ($msg -notmatch ("\[squad-sandbox:" + $case.Kind + "\]")) {
                $sbVerdictOk = $false
                $sbVerdictDetail += "$($case.Status): kind was not $($case.Kind) ('$msg')"
            } elseif ($msg -notmatch [regex]::Escape($case.Needle)) {
                $sbVerdictOk = $false
                $sbVerdictDetail += "$($case.Status): message did not say why ('$msg')"
            } elseif ($msg -match [regex]::Escape($sbSecret)) {
                $sbVerdictOk = $false
                $sbVerdictDetail += "$($case.Status): leaked the token"
            }
        }
        if ($sbVerdictOk) {
            Add-Pass "Every reported cancel failure (no-pidfile, bad-pidfile, not-ours, kill-failed, survived, no-proc, scan-failed) THROWS with its own kind and reason even though the exec exited 0"
        } else {
            Add-Fail "A reported cancel failure was treated as success ($($sbVerdictDetail -join '; '))"
        }

        # A sandbox launched before the pid file existed reports no-pidfile for
        # ever. The message has to name the way out, or the operator is left with
        # a session that can never be stopped and never stops billing.
        $env:SQUAD_STUB_ACA_CANCEL_STATUS = "no-pidfile"
        $sbLegacyMsg = ""
        try { Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null | Out-Null } catch { $sbLegacyMsg = [string]$_.Exception.Message }
        if ($sbLegacyMsg -match "aca sandbox delete" -and $sbLegacyMsg -match "control plane") {
            Add-Pass "A pre-existing sandbox with no pid file fails the cancel AND is told the control-plane teardown that does not need the guest's cooperation"
        } else {
            Add-Fail "The no-pidfile failure does not tell the operator how to stop the session ('$sbLegacyMsg')"
        }

        $env:SQUAD_STUB_ACA_CANCEL_STATUS = "already-dead"
        $sbDead = Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null
        $env:SQUAD_STUB_ACA_CANCEL_STATUS = "already-terminal"
        $sbTerm = Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>$null
        if ($sbDead.Cancelled -and -not $sbDead.AlreadyTerminal -and $sbDead.CancelStatus -eq "already-dead" -and
            $sbTerm.Cancelled -and $sbTerm.AlreadyTerminal -and $sbTerm.CancelStatus -eq "already-terminal") {
            Add-Pass "The three outcomes that mean the worker is NOT running (killed, already-dead, already-terminal) are success, and a finished session is reported as already terminal rather than as a fresh kill"
        } else {
            Add-Fail "cancel mis-reported a not-running worker (dead=$($sbDead.CancelStatus)/$($sbDead.AlreadyTerminal) terminal=$($sbTerm.CancelStatus)/$($sbTerm.AlreadyTerminal))"
        }

        # The machine token drives the decision; it is not part of what a user
        # reads. The human line the sandbox prints still reaches the host.
        $env:SQUAD_STUB_ACA_CANCEL_STATUS = "killed"
        $sbHostLines = @(Stop-SquadExecution -Provider $sbProvider -Handle $sbHandle 6>&1 | ForEach-Object { [string]$_ })
        if (($sbHostLines -join "`n") -match "squad-cancelled" -and ($sbHostLines -join "`n") -notmatch "squad-cancel-status") {
            Add-Pass "The cancel verdict token is consumed by the provider and kept out of host output, while the human line is still shown"
        } else {
            Add-Fail "Host output for a cancel is wrong (lines: $($sbHostLines -join ' | '))"
        }
        $env:SQUAD_STUB_ACA_CANCEL_STATUS = "killed"

        # --- 6d. the SHAPE of the emitted commands ---------------------------
        # Static checks only -- they cannot prove a kill, and the behavioural
        # proof lives in scripts/tests/verify-sandbox-cancel.ps1, which runs this
        # exact string in a real shell against real processes. What they CAN do
        # is stop a procps dependency, or a lost process-group signal, from
        # coming back unnoticed.
        $sbCancelCmd = New-SandboxCancelCommand
        $sbLaunchCmd = New-SandboxLaunchCommand -Environment ([ordered]@{ SQUAD_SHAPE_PROBE = "1" })
        $sbShape = @()
        foreach ($banned in @("pkill", "pgrep", "ps -", "ps auxw")) {
            if ($sbCancelCmd -match [regex]::Escape($banned)) { $sbShape += "names '$banned', which the pinned class image does not have" }
        }
        if ($sbCancelCmd -notmatch [regex]::Escape('kill -TERM -$p')) { $sbShape += "does not signal the process GROUP, so the entrypoint's children survive the cancel" }
        if ($sbCancelCmd -notmatch [regex]::Escape('kill -KILL')) { $sbShape += "never escalates past SIGTERM" }
        if ($sbCancelCmd -notmatch "worker\.pid") { $sbShape += "does not read the recorded worker pid" }
        if ($sbCancelCmd -notmatch "squad-cancel-status=") { $sbShape += "emits no machine-readable verdict, so the provider is back to trusting an echo" }
        if ($sbCancelCmd -notmatch [regex]::Escape('case $st in killed|already-dead)')) { $sbShape += "does not gate the marker writes on a CONFIRMED death" }
        if ($sbCancelCmd -notmatch "scan-failed") { $sbShape += "does not distinguish a process scan that read NOTHING from a worker that is gone -- the empty-scan case is exactly how the first fix reported a live worker as already-dead" }
        if ($sbCancelCmd -notmatch [regex]::Escape('/proc/self/stat')) { $sbShape += "does not self-test that this shell can read /proc before believing anything it did not find there" }
        foreach ($ch in @('"', "!", "^")) {
            if ($sbCancelCmd.Contains($ch)) { $sbShape += "contains '$ch', which does not survive cmd.exe/delayed expansion in the offline stub" }
        }
        if ($sbLaunchCmd -notmatch [regex]::Escape('printf %s $$ > /tmp/squad-session/worker.pid')) { $sbShape += "the launch does not record the worker's own pid as its first act" }
        if ($sbLaunchCmd -notmatch [regex]::Escape("rm -f /tmp/squad-session/worker.pid; touch /tmp/squad-session/done")) { $sbShape += "the launch does not clear the pid file before touching the completion marker, so a finished run leaves a signalable stale pid" }
        if ($sbShape.Count -eq 0) {
            Add-Pass "The emitted cancel command uses no procps binary, signals the whole process group, escalates, gates its marker writes on a confirmed death, and reports a machine-readable verdict"
        } else {
            Add-Fail "The emitted cancel/launch command shape regressed ($($sbShape -join '; '))"
        }

        # --- 6e. EVERY emitted command is POSIX sh, because dash runs them all -
        # `aca sandbox exec` hands the command to /bin/sh, which is dash on the
        # class image. The first fix for #36 was written in bash: `$(< file)` is
        # a bashism that expands to the EMPTY STRING under dash, so the process
        # scan saw nothing, and "saw nothing" was read as "the worker is gone".
        # It passed every bash test and reported a live worker as already-dead on
        # the first real sandbox. A bashism here is not a style question.
        #
        # Issue #40 widened this from the cancel command to ALL of them. Every
        # command below crosses the same boundary into the same shell; the cancel
        # is simply the one that has already been caught. The screen itself lives
        # in scripts/lib/squad-shell-portability.ps1 so that the behavioural
        # probe under scripts/tests uses the SAME rules and the SAME inventory --
        # a screen that disagrees with the probe about what ships is a third
        # thing to keep in sync, and this repository has already been bitten by
        # a check that quietly stopped describing production.
        $sbBashisms = @()
        $sbPortabilityLib = Join-Path $RepoRoot "scripts\lib\squad-shell-portability.ps1"
        if (-not (Test-Path $sbPortabilityLib)) {
            $sbBashisms += "scripts/lib/squad-shell-portability.ps1 is missing, so nothing screens the emitted commands for the bashism class that shipped issue #36"
        } else {
            . $sbPortabilityLib
            $sbEmitted = @(Get-SquadEmittedShellCommand)
            foreach ($sbCmd in $sbEmitted) {
                $sbBashisms += @(Test-SquadShellPortability -Command $sbCmd.Command -Label $sbCmd.Id -Shell $sbCmd.Shell)
            }

            # ANTI-DRIFT. The screen is only worth its output if the inventory is
            # complete, and an inventory maintained by hand goes stale the first
            # time somebody adds a command. So: reflect over the provider's own
            # generators and refuse any this inventory does not cover. A new
            # `New-Sandbox<X>Command` fails here until it is screened.
            $sbCovered = @($sbEmitted | ForEach-Object { $_.Generator } | Where-Object { $_ })
            $sbGenerators = @(Get-Command -CommandType Function -Name "New-Sandbox*Command" -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name } | Sort-Object -Unique)
            foreach ($sbGen in $sbGenerators) {
                if ($sbCovered -notcontains $sbGen) {
                    $sbBashisms += "$sbGen emits a shell command the portability inventory does not cover, so nothing screens it for the bashism that reported a live worker as already-dead in issue #36"
                }
            }
            if ($sbEmitted.Count -lt 7) {
                $sbBashisms += "the portability inventory shrank to $($sbEmitted.Count) command(s); the launch, cancel, poll, credential-vault, credential-refresh, logs and credential-file fragments are all run by /bin/sh and must all stay covered"
            }
            # The log tail used to be a bare literal at its call site. A command
            # that exists only inline is a command no screen can reach, so its
            # generator must keep producing exactly the text that shipped.
            if ((New-SandboxLogsCommand -StateDir "/tmp/squad-session" -Tail 100) -ne "tail -n 100 /tmp/squad-session/session.log 2>/dev/null || true") {
                $sbBashisms += "New-SandboxLogsCommand no longer emits the log-tail command verbatim, so extracting it changed behaviour instead of only making it screenable"
            }
        }
        if ($sbBashisms.Count -eq 0) {
            Add-Pass "All 7 emitted shell commands (launch, cancel, poll, credential-vault, credential-refresh, logs, credential-file) are strict POSIX sh with no bashism, and every New-Sandbox*Command generator is covered by the inventory -- 'aca sandbox exec' runs them under dash, where the first fix's `$(< file)` silently expanded to nothing and reported a live worker as already-dead"
        } else {
            Add-Fail "An emitted sandbox command is not dash-safe ($($sbBashisms -join '; '))"
        }

        # --- 7. refusal when the sandbox group carries a managed identity ----
        # Private-registry pulls use an ACR refresh token precisely so the group
        # needs no identity. An identity on the group is an escalation path out
        # of the sandbox, so the provider must refuse before creating anything.
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_SBG_IDENTITY = "1"
        $sbIdThrew = $false
        $sbIdMsg = ""
        try { Start-SquadExecution -Provider $sbProvider -Request $sbRequest 6>$null | Out-Null } catch { $sbIdThrew = $true; $sbIdMsg = [string]$_.Exception.Message }
        $sbIdCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $env:SQUAD_STUB_SBG_IDENTITY = ""
        if ($sbIdThrew -and $sbIdCalls.Count -eq 0 -and $sbIdMsg -match "identity") {
            Add-Pass "Provider refuses to use a sandbox group that has a managed identity, before creating anything"
        } else {
            Add-Fail "A sandbox group with a managed identity was not refused (threw=$sbIdThrew acaCalls=$($sbIdCalls.Count) msg=$sbIdMsg)"
        }

        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_SBG_RC = "1"
        $sbIdFailThrew = $false
        try { Start-SquadExecution -Provider $sbProvider -Request $sbRequest 6>$null | Out-Null } catch { $sbIdFailThrew = $true }
        $sbIdFailCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $env:SQUAD_STUB_SBG_RC = "0"
        if ($sbIdFailThrew -and $sbIdFailCalls.Count -eq 0) {
            Add-Pass "An identity check that cannot be completed fails closed (unknown is not treated as 'no identity')"
        } else {
            Add-Fail "A failed identity check did not fail closed (threw=$sbIdFailThrew acaCalls=$($sbIdFailCalls.Count))"
        }

        # --- 8. --identity is refused wherever it appears --------------------
        $sbIdentityArgvRefused = $false
        try { Assert-SandboxArgvIdentityFree -Argv @("sandboxgroup", "disk", "create", "--identity", "mi-squad") } catch { $sbIdentityArgvRefused = $true }
        $sbIdentityArgvRefused2 = $false
        try { Assert-SandboxArgvIdentityFree -Argv @("sandbox", "create", "--system-assigned") } catch { $sbIdentityArgvRefused2 = $true }
        if ($sbIdentityArgvRefused -and $sbIdentityArgvRefused2) {
            Add-Pass "Any argv carrying --identity / --system-assigned is refused before the process starts"
        } else {
            Add-Fail "An identity-granting flag was not refused (--identity=$sbIdentityArgvRefused --system-assigned=$sbIdentityArgvRefused2)"
        }

        # --- 9. failure between policy and launch tears the sandbox down -----
        # Otherwise a sandbox is left running, billed for, and orphaned.
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_ACA_EGRESS_RC = "1"
        $env:SQUAD_STUB_ACA_EGRESS_ERR = "Error: egress policy rejected"
        $sbEgThrew = $false
        $sbEgMsg = ""
        try { Start-SquadExecution -Provider $sbProvider -Request $sbRequest 6>$null | Out-Null } catch { $sbEgThrew = $true; $sbEgMsg = [string]$_.Exception.Message }
        $sbEgCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $sbEgLaunched = @($sbEgCalls | Where-Object { $_ -like "*squad-launched*" }).Count
        $sbEgDeleted = @($sbEgCalls | Where-Object { $_ -like "sandbox delete *" }).Count
        $env:SQUAD_STUB_ACA_EGRESS_RC = "0"
        $env:SQUAD_STUB_ACA_EGRESS_ERR = ""
        if ($sbEgThrew -and $sbEgLaunched -eq 0 -and $sbEgDeleted -eq 1) {
            Add-Pass "If the egress policy cannot be applied, no repository code is launched and the sandbox is torn down"
        } else {
            Add-Fail "A failed egress policy did not stop the launch or leaked a sandbox (threw=$sbEgThrew launches=$sbEgLaunched deletes=$sbEgDeleted)"
        }
        if ($sbEgMsg -notmatch "github\.com" -and $sbEgMsg -notmatch "npmjs" -and $sbEgMsg -notmatch [regex]::Escape($sbSecret)) {
            Add-Pass "The egress failure message carries no policy host patterns and no token"
        } else {
            Add-Fail "An egress failure message leaked policy values or a token: $sbEgMsg"
        }

        # --- 10. disk label -> GUID resolution --------------------------------
        # `--name` on `disk create` becomes a LABEL, so a private disk has to be
        # resolved to its GUID; `--disk` accepts public images only.
        Reset-SquadCliStubLog -Stub $sbStub
        $sbLabelProvider = New-SandboxTestProvider -DiskId "" -DiskLabel "squad-worker-stub"
        try { Start-SquadExecution -Provider $sbLabelProvider -Request $sbRequest 6>$null | Out-Null } catch { }
        $sbLabelCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $sbListed = @($sbLabelCalls | Where-Object { $_ -like "sandboxgroup disk list*" }).Count
        $sbUsedGuid = @($sbLabelCalls | Where-Object { $_ -like "sandbox create *--disk-id aaaaaaaa-1111-2222-3333-444444444444*" }).Count
        if ($sbListed -eq 1 -and $sbUsedGuid -eq 1) {
            Add-Pass "A disk label is resolved to its GUID via 'sandboxgroup disk list' before create"
        } else {
            Add-Fail "Disk label resolution did not happen (lists=$sbListed guidCreates=$sbUsedGuid)"
        }

        # --- 11. every sandbox is labelled with its session id ---------------
        $sbLabelled = @($sbCalls | Where-Object { $_ -like "*name=squad-stub-session*" }).Count
        if ($sbLabelled -ge 4) {
            Add-Pass "Every sandbox operation is addressed by a session-derived label, so a reaper can find orphans"
        } else {
            Add-Fail "Sandbox operations are not consistently session-labelled ($sbLabelled labelled calls)"
        }

        # =====================================================================
        # Sprint 7/8 -- credentials, egress narrowing, adversarial input,
        # quota/cost and failure taxonomy.
        # =====================================================================

        # --- 12. credentials are delivered on STDIN, not in any argv ---------
        # This is the whole point of Sprint 7 and it is asserted BEHAVIOURALLY,
        # not textually. The stub writes whatever arrived on its standard input
        # to a file; the check then requires BOTH halves to hold at once:
        #
        #   (a) the exact token value reached the process  -- proving delivery
        #       actually happened and the control is not just "we stopped
        #       passing the token at all", which a pure absence check would
        #       have called a pass; and
        #   (b) the token appears in NO recorded argv      -- proving it is not
        #       readable from /proc/<pid>/cmdline by any other process on the
        #       host, which is what an argv-borne secret means on Linux.
        #
        # A substring assertion over the emitted command could not tell those
        # two states apart.
        $sbCredStdin = Join-Path $sbStub.Root "cred-stdin.txt"
        $sbSeedStdin = Join-Path $sbStub.Root "seed-stdin.txt"
        Remove-Item $sbCredStdin, $sbSeedStdin -ErrorAction SilentlyContinue
        $env:SQUAD_STUB_ACA_CRED_STDIN = $sbCredStdin
        $env:SQUAD_STUB_ACA_SEED_STDIN = $sbSeedStdin
        $env:SQUAD_STUB_ACA_VAULT_MODE = "700"
        Reset-SquadCliStubLog -Stub $sbStub
        $sbCredProvider = New-SandboxTestProvider
        $sbCredOutcome = @{}
        $sbCredErr = ""
        try {
            Start-SquadExecution -Provider $sbCredProvider -Request $sbRequest -Outcome $sbCredOutcome 6>$null | Out-Null
        } catch { $sbCredErr = [string]$_.Exception.Message }
        $sbCredCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $sbCredAllArgv = ($sbCredCalls -join "`n")
        $sbGotCred = if (Test-Path $sbCredStdin) { (Get-Content -Raw $sbCredStdin).Trim() } else { "" }
        $sbGotSeedLines = if (Test-Path $sbSeedStdin) { @((Get-Content $sbSeedStdin) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }

        if (-not $sbCredErr -and $sbGotCred -eq $sbCopilotSecret -and $sbCredAllArgv -notmatch [regex]::Escape($sbCopilotSecret)) {
            Add-Pass "The Copilot credential reaches the platform on STDIN and appears in no process argv (received on stdin, absent from all $($sbCredCalls.Count) recorded aca argvs)"
        } else {
            Add-Fail "Copilot credential delivery is wrong (err=$sbCredErr stdinMatched=$($sbGotCred -eq $sbCopilotSecret) inArgv=$($sbCredAllArgv -match [regex]::Escape($sbCopilotSecret)))"
        }
        if ($sbGotSeedLines.Count -ge 1 -and $sbGotSeedLines[0] -eq "export GH_TOKEN='$sbSecret'" `
                -and $sbCredAllArgv -notmatch [regex]::Escape($sbSecret)) {
            Add-Pass "The git/gh push token reaches the sandbox as an UPLOADED FILE and appears in no process argv (no native --type exists for it, so it is written into a 0700 state directory)"
        } else {
            Add-Fail "Git token delivery is wrong (lines=$($sbGotSeedLines.Count) firstMatched=$($sbGotSeedLines.Count -ge 1 -and $sbGotSeedLines[0] -eq "export GH_TOKEN='$sbSecret'") inArgv=$($sbCredAllArgv -match [regex]::Escape($sbSecret)))"
        }

        # THE defect this branch exists for. A sandbox session that stages only
        # the git plane runs Copilot with no credential and dies with
        # "No authentication information found" AFTER the sandbox was created,
        # egress applied, and the repository cloned -- ninety seconds of billed
        # compute for an error the dispatcher already had the information to
        # prevent. The Copilot plane must arrive too, on its OWN file line, so
        # a distinct Copilot credential is never written under the git names.
        $sbCopilotLine = "export COPILOT_GITHUB_TOKEN='$sbCopilotSecret'"
        if ($sbGotSeedLines.Count -eq 3 -and $sbGotSeedLines[2] -eq $sbCopilotLine) {
            Add-Pass "The Copilot ENV plane is staged as its own file line, so the worker's Copilot CLI has a credential and it is not the git token"
        } else {
            Add-Fail "The Copilot env plane was not staged separately (lines=$($sbGotSeedLines.Count) thirdIsCopilot=$($sbGotSeedLines.Count -ge 3 -and $sbGotSeedLines[2] -eq $sbCopilotLine))"
        }

        # `aca sandbox fs write` uploads ROOT-OWNED 0644 and the sandbox account
        # cannot chmod it, so the CONTAINING DIRECTORY is the only access control
        # available. If the vault exec reports any mode other than 700, the
        # credential would land world-readable inside the sandbox -- so the
        # upload must be REFUSED rather than attempted.
        Reset-SquadCliStubLog -Stub $sbStub
        Remove-Item $sbSeedStdin -ErrorAction SilentlyContinue
        $env:SQUAD_STUB_ACA_VAULT_MODE = "755"
        $sbVaultErr = ""
        try {
            Start-SquadExecution -Provider (New-SandboxTestProvider) -Request $sbRequest 6>$null | Out-Null
        } catch { $sbVaultErr = [string]$_.Exception.Message }
        $sbVaultCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $sbVaultWrote = @($sbVaultCalls | Where-Object { $_ -like "sandbox fs write *" }).Count
        $sbVaultLaunched = @($sbVaultCalls | Where-Object { $_ -like "*squad-launched*" }).Count
        if ($sbVaultErr -match "not 700" -and $sbVaultWrote -eq 0 -and $sbVaultLaunched -eq 0 -and -not (Test-Path $sbSeedStdin)) {
            Add-Pass "A credential state directory that is not 0700 REFUSES the upload (no fs write, no launch), because the platform uploads root-owned 0644 and the sandbox account cannot chmod it"
        } else {
            Add-Fail "The vault-mode guard is wrong (err=$sbVaultErr writes=$sbVaultWrote launches=$sbVaultLaunched)"
        }
        $env:SQUAD_STUB_ACA_VAULT_MODE = "700"

        # The local file the upload reads from holds both plaintext tokens and
        # must not survive -- including when a call FAILS part-way, which is
        # exactly when a leftover is most likely. That is asserted ONCE, at the
        # end of this section, across every scenario: measured here it was
        # vacuous, because the vault-mode refusal above fails before anything
        # is staged (removing the cleanup from both `finally` blocks in
        # squad-sandbox-provider.ps1 left this passing).
        Reset-SquadCliStubLog -Stub $sbStub
        $sbCredCalls = @()
        $sbCredOutcome = @{}
        try {
            Start-SquadExecution -Provider (New-SandboxTestProvider) -Request $sbRequest -Outcome $sbCredOutcome 6>$null | Out-Null
        } catch { }
        $sbCredCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)

        # The generator's plane/line correspondence, directly: dropping a plane
        # with no value must drop its LINE too, or every later plane silently
        # receives the previous plane's token.
        $sbGitOnly = Get-SandboxCredentialStaging -WorkerSecrets @{ GH_TOKEN = $sbSecret }
        $sbBothPlanes = Get-SandboxCredentialStaging -WorkerSecrets @{ GH_TOKEN = $sbSecret; COPILOT_GITHUB_TOKEN = $sbCopilotSecret }
        $sbNoPlanes = Get-SandboxCredentialStaging -WorkerSecrets @{}
        if ($sbGitOnly -and @($sbGitOnly.Tokens).Count -eq 1 -and @($sbGitOnly.Planes).Count -eq 1 `
                -and $sbBothPlanes -and @($sbBothPlanes.Tokens).Count -eq 2 -and @($sbBothPlanes.Planes).Count -eq 2 `
                -and ($sbBothPlanes.Planes[1] -contains "COPILOT_GITHUB_TOKEN") -and $null -eq $sbNoPlanes) {
            Add-Pass "A credential plane with no value drops its stdin LINE as well as its names, so no plane can inherit another plane's token"
        } else {
            Add-Fail "Credential plane/line correspondence is wrong (gitOnly=$(if ($sbGitOnly) { @($sbGitOnly.Tokens).Count } else { 'null' }) both=$(if ($sbBothPlanes) { @($sbBothPlanes.Tokens).Count } else { 'null' }) none=$(if ($null -eq $sbNoPlanes) { 'null' } else { 'not-null' }))"
        }

        # The brokered id must actually be attached to the sandbox, otherwise
        # the token was uploaded and then ignored.
        $iCredCreate = [array]::FindIndex($sbCredCalls, [Predicate[string]] { param($l) $l -like "sandboxgroup credential create *" })
        $iSbCreate2  = [array]::FindIndex($sbCredCalls, [Predicate[string]] { param($l) $l -like "sandbox create *" })
        if ($iCredCreate -ge 0 -and $iSbCreate2 -gt $iCredCreate `
                -and $sbCredCalls[$iCredCreate] -like "*--type github-copilot*" `
                -and $sbCredCalls[$iSbCreate2] -like "*--credential cred-stub-0001*") {
            Add-Pass "The brokered credential is created first and referenced by opaque id on 'sandbox create --credential'"
        } else {
            Add-Fail "Credential brokerage is not wired into sandbox create (credCreate=$iCredCreate sandboxCreate=$iSbCreate2)"
        }

        # And the launch command itself -- the string that used to carry the
        # token -- must now be free of it and of the env names it travelled in.
        $iLaunch2 = [array]::FindIndex($sbCredCalls, [Predicate[string]] { param($l) $l -like "*squad-launched*" })
        if ($iLaunch2 -ge 0 -and $sbCredCalls[$iLaunch2] -notmatch [regex]::Escape($sbSecret) `
                -and $sbCredCalls[$iLaunch2] -notmatch [regex]::Escape($sbCopilotSecret) `
                -and $sbCredCalls[$iLaunch2] -notmatch "GH_TOKEN=" -and $sbCredCalls[$iLaunch2] -notmatch "GITHUB_TOKEN=") {
            Add-Pass "The launch command carries no token and no token-bearing env assignment (Sprint 5's known limitation is closed)"
        } else {
            Add-Fail "The launch command still carries a credential: $(if ($iLaunch2 -ge 0) { 'token/env assignment present' } else { '<no launch call>' })"
        }

        # Mutation guard: New-SandboxLaunchCommand must REFUSE to build a
        # command that assigns a secret env name, so a future change that
        # "helpfully" restores GH_TOKEN= cannot pass silently. COPILOT_GITHUB_TOKEN
        # is a bearer token too and is on the same deny list.
        $sbEnvGuardBad = @()
        foreach ($sbSecretName in @("GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN")) {
            $sbEnvGuard = ""
            try {
                New-SandboxLaunchCommand -Environment ([ordered]@{ $sbSecretName = "x" }) -StateDir "/squad/state" | Out-Null
            } catch { $sbEnvGuard = [string]$_.Exception.Message }
            if ($sbEnvGuard -notmatch "squad-sandbox:capability") { $sbEnvGuardBad += $sbSecretName }
        }
        if ($sbEnvGuardBad.Count -eq 0) {
            Add-Pass "New-SandboxLaunchCommand refuses to place ANY credential-bearing env name (git and Copilot planes) in the launch argv"
        } else {
            Add-Fail "Secret env name(s) accepted into the launch command: $($sbEnvGuardBad -join ', ')"
        }

        $env:SQUAD_STUB_ACA_CRED_STDIN = ""
        $env:SQUAD_STUB_ACA_SEED_STDIN = ""

        # --- 13. the classic-token footgun ------------------------------------
        # The platform rejects a classic `ghp_` token for --type github-copilot.
        # Discovering that from a service round-trip means the token has already
        # been sent over the wire and written to a service-side log. So it is
        # rejected locally, and the check proves locality by counting aca calls:
        # zero. deploy.ps1 defaults -CopilotGitHubToken to -GitHubToken, which is
        # a classic token from `gh auth token`, so this fires in practice.
        $sbClassicCases = @(
            @{ Prefix = "ghp_"; What = "a classic personal access token" },
            @{ Prefix = "gho_"; What = "an OAuth token" },
            @{ Prefix = "ghs_"; What = "a server-to-server token" }
        )
        $sbClassicBad = @()
        foreach ($case in $sbClassicCases) {
            $reason = Test-SandboxCredentialToken -Type "github-copilot" -Token ($case.Prefix + "stubvalue00000000")
            if (-not $reason) { $sbClassicBad += "$($case.Prefix) accepted" }
            elseif ($reason -match [regex]::Escape($case.Prefix + "stubvalue")) { $sbClassicBad += "$($case.Prefix) echoed the token" }
            # A generic "wrong prefix" is not good enough. The whole reason this
            # guard exists is that `gh auth token` returns a classic token and
            # deploy.ps1 defaults -CopilotGitHubToken to the SAME value, so the
            # message must name that specific trap -- otherwise an operator
            # reads "wrong prefix" and re-runs `gh auth token`.
            elseif ($reason -notmatch [regex]::Escape($case.Prefix) -or $reason -notmatch "CopilotGitHubToken") {
                $sbClassicBad += "$($case.Prefix) gave a non-actionable message"
            }
        }
        Reset-SquadCliStubLog -Stub $sbStub
        $sbClassicErr = ""
        try {
            $p = New-SandboxTestProvider -Secrets @{ GH_TOKEN = $sbSecret } `
                -Brokered @{ "github-copilot" = ("ghp_" + "stubvalue00000000") }
            Start-SquadExecution -Provider $p -Request $sbRequest 6>$null | Out-Null
        } catch { $sbClassicErr = [string]$_.Exception.Message }
        $sbClassicCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $sbClassicCreates = @($sbClassicCalls | Where-Object { $_ -like "sandbox create *" -or $_ -like "sandboxgroup credential create *" }).Count
        if ($sbClassicBad.Count -eq 0 -and $sbClassicErr -match "github_pat_" -and $sbClassicCreates -eq 0 `
                -and $sbClassicErr -notmatch "stubvalue") {
            Add-Pass "A classic ghp_/gho_/ghs_ token is refused for the Copilot plane BEFORE any CLI call (0 create calls), with an actionable message that does not echo the token"
        } else {
            Add-Fail "The classic-token guard is wrong (bad=$($sbClassicBad -join '; ') creates=$sbClassicCreates err=$sbClassicErr)"
        }
        $sbAnthropicOk = (Test-SandboxCredentialToken -Type "anthropic-claude" -Token "sk-ant-stubvalue0000") -eq "" `
            -and (Test-SandboxCredentialToken -Type "anthropic-claude" -Token ("github" + "_pat_" + "stubvalue0000")) -ne ""
        if ($sbAnthropicOk) {
            Add-Pass "Each credential type enforces its own required prefix (anthropic-claude requires sk-ant-)"
        } else {
            Add-Fail "The anthropic-claude prefix rule is not enforced"
        }

        # --- 14. egress may be NARROWED by a manifest, never widened ---------
        # Sprint 2 enforces this in the resolver. It is enforced AGAIN here, at
        # the point of policy generation, because the resolver is a different
        # process boundary: a bug, a bypass, or a future caller that builds a
        # resolution by hand must not be able to widen the sandbox's reach.
        $sbWiden = New-SquadDispatchRequest -SessionId "stub-session" -Repository "octo/demo" `
            -Prompt "p" -Mode "prompt" -CapabilityResolution ([pscustomobject]@{
                egressHosts = @("*.github.com", "evil.example.com")
            })
        Reset-SquadCliStubLog -Stub $sbStub
        $sbWidenErr = ""
        try { Start-SquadExecution -Provider (New-SandboxTestProvider) -Request $sbWiden 6>$null | Out-Null } catch { $sbWidenErr = [string]$_.Exception.Message }
        $sbWidenCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $sbWidenCreates = @($sbWidenCalls | Where-Object { $_ -like "sandbox create *" }).Count
        if ($sbWidenErr -match "squad-sandbox:capability" -and $sbWidenCreates -eq 0 -and $sbWidenErr -notmatch "evil\.example\.com") {
            Add-Pass "A manifest that requests a host outside the approved class template is refused at policy generation, before any sandbox is created or billed, without echoing the host"
        } else {
            Add-Fail "Egress widening was not refused at generation time (err=$sbWidenErr creates=$sbWidenCreates)"
        }

        $sbNarrow = New-SquadDispatchRequest -SessionId "stub-session" -Repository "octo/demo" `
            -Prompt "p" -Mode "prompt" -CapabilityResolution ([pscustomobject]@{ egressHosts = @("api.github.com") })
        Reset-SquadCliStubLog -Stub $sbStub
        $sbNarrowErr = ""
        try { Start-SquadExecution -Provider (New-SandboxTestProvider) -Request $sbNarrow 6>$null | Out-Null } catch { $sbNarrowErr = [string]$_.Exception.Message }
        $sbNarrowCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $iNarrowEgress = [array]::FindIndex($sbNarrowCalls, [Predicate[string]] { param($l) $l -like "sandbox egress set *" })
        if (-not $sbNarrowErr -and $iNarrowEgress -ge 0 `
                -and $sbNarrowCalls[$iNarrowEgress] -like "*--rule *.github.com:Allow*" `
                -and $sbNarrowCalls[$iNarrowEgress] -notlike "*registry.npmjs.org*" `
                -and $sbNarrowCalls[$iNarrowEgress] -notlike "*--rule api.github.com*") {
            Add-Pass "A narrowing manifest drops the rules it does not need and emits ONLY template-provenance patterns (the requested host is covered by *.github.com, never added as its own rule)"
        } else {
            Add-Fail "Egress narrowing is wrong (err=$sbNarrowErr argv=$(if ($iNarrowEgress -ge 0) { $sbNarrowCalls[$iNarrowEgress] } else { '<missing>' }))"
        }

        # Provenance, directly: no emitted rule may be absent from the template,
        # whatever the request said.
        $sbProv = New-SandboxEgressPolicy -Class $sbClass -RequestedHosts @()
        $sbTemplatePatterns = @($sbClass.egress.hostRules | ForEach-Object { $_.pattern })
        $sbProvBad = @($sbProv.Rules | Where-Object { $sbTemplatePatterns -notcontains $_.Pattern })
        if ($sbProvBad.Count -eq 0 -and $sbProv.DefaultAction -eq "Deny" -and -not $sbProv.Narrowed) {
            Add-Pass "Generated policy is default-deny and every rule traces to the approved class template"
        } else {
            Add-Fail "Generated policy has rules with no template provenance ($($sbProvBad.Count)) or is not default-deny"
        }

        # A class whose own template is not default-deny must be refused: the
        # catalog is administrator-owned but it is still input.
        $sbOpenClass = ($sbClass | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        $sbOpenClass.egress.defaultAction = "Allow"
        $sbOpenErr = ""
        try { New-SandboxEgressPolicy -Class $sbOpenClass -RequestedHosts @() | Out-Null } catch { $sbOpenErr = [string]$_.Exception.Message }
        if ($sbOpenErr -match "squad-sandbox:config") {
            Add-Pass "A class template that is not default-deny is refused (invariant 3 does not depend on the catalog being right)"
        } else {
            Add-Fail "A default-allow class template was accepted: $sbOpenErr"
        }

        # The suffix matcher itself, DIRECTLY. It decides whether a requested
        # host is already covered by a template pattern, so it is the function
        # that says "no new rule is needed" -- and a matcher that is too generous
        # silently widens the sandbox's reach. Only the narrowing PATH was
        # covered before, and mutating the matcher to
        # `$Host_.EndsWith($Pattern.Substring(2))` -- which makes
        # `evilgithub.com` "covered" by `*.github.com` -- left the whole suite
        # green. These are direct assertions over the value classes that matter.
        $sbHostCases = @(
            # exact
            @{ Host_ = "registry.npmjs.org"; Pattern = "registry.npmjs.org"; Want = $true },
            @{ Host_ = "REGISTRY.NPMJS.ORG"; Pattern = "registry.npmjs.org"; Want = $true },
            @{ Host_ = "registry.npmjs.org."; Pattern = "registry.npmjs.org"; Want = $false },
            # leading wildcard: a proper subdomain, and ONLY a proper subdomain
            @{ Host_ = "api.github.com";      Pattern = "*.github.com"; Want = $true },
            @{ Host_ = "a.b.github.com";      Pattern = "*.github.com"; Want = $true },
            @{ Host_ = "API.GITHUB.COM";      Pattern = "*.github.com"; Want = $true },
            @{ Host_ = "github.com";          Pattern = "*.github.com"; Want = $false },  # the bare apex
            @{ Host_ = ".github.com";         Pattern = "*.github.com"; Want = $false },  # empty label
            # the boundary attacks: the label separator must be part of the match
            @{ Host_ = "evilgithub.com";      Pattern = "*.github.com"; Want = $false },
            @{ Host_ = "xgithub.com";         Pattern = "*.github.com"; Want = $false },
            @{ Host_ = "notgithub.com";       Pattern = "*.github.com"; Want = $false },
            # the suffix attacks: the pattern must be a SUFFIX, not a substring
            @{ Host_ = "github.com.evil.net"; Pattern = "*.github.com"; Want = $false },
            @{ Host_ = "api.github.com.evil.net"; Pattern = "*.github.com"; Want = $false },
            @{ Host_ = "api.github.company.com";  Pattern = "*.github.com"; Want = $false },
            @{ Host_ = "api.github.com.";     Pattern = "*.github.com"; Want = $false },  # trailing dot
            # homograph / punycode: neither is github.com and neither may pass
            @{ Host_ = "g" + [char]0x0131 + "thub.com"; Pattern = "*.github.com"; Want = $false },
            @{ Host_ = "api.xn--gthub-jua.com";        Pattern = "*.github.com"; Want = $false },
            # degenerate patterns must never become "match anything"
            @{ Host_ = "evil.example.com"; Pattern = "*";   Want = $false },
            @{ Host_ = "evil.example.com"; Pattern = "*.";  Want = $false },
            @{ Host_ = "evil.example.com"; Pattern = "**";  Want = $false },
            @{ Host_ = "evil.example.com"; Pattern = "";    Want = $false },
            @{ Host_ = "";                 Pattern = "*.github.com"; Want = $false }
        )
        $sbHostBad = @()
        foreach ($case in $sbHostCases) {
            $got = Test-SandboxHostCoveredByPattern -Host_ $case.Host_ -Pattern $case.Pattern
            if ($got -ne $case.Want) { $sbHostBad += "'$($case.Host_)' vs '$($case.Pattern)' -> $got (wanted $($case.Want))" }
        }
        if ($sbHostBad.Count -eq 0) {
            Add-Pass "The egress suffix matcher covers only a proper subdomain of a wildcard pattern: not the bare apex, not 'evilgithub.com', not 'github.com.evil.net', not a homograph or punycode lookalike, and no degenerate pattern ('*', '*.', '**', '') matches anything"
        } else {
            Add-Fail "The egress host matcher is wrong: $($sbHostBad -join '; ')"
        }

        # --- 15. hostile identifiers are refused BEFORE API construction -----
        # Fuzz over the value classes that turn an identifier into something
        # other than data: path traversal, control characters, and a leading
        # dash (which a CLI parses as a FLAG -- `--identity` arriving as a
        # "disk id" would defeat invariant 4 without ever touching the argv
        # scanner, because the scanner walks past values).
        $sbFuzz = @(
            @{ V = "../../etc/passwd";              What = "path traversal" },
            @{ V = "ok/../other";                   What = "embedded traversal" },
            @{ V = "a`r`nX-Injected: 1";            What = "CRLF header injection" },
            @{ V = "a`0b";                          What = "NUL byte" },
            @{ V = "a`tb";                          What = "tab" },
            @{ V = "-identity";                     What = "leading dash (argument injection)" },
            @{ V = "--identity";                    What = "leading double dash" },
            @{ V = "name;rm -rf /";                 What = "shell metacharacters" },
            @{ V = "name`$(id)";                    What = "command substitution" },
            @{ V = "name|nc evil 1";                What = "pipe" },
            @{ V = ("a" * 400);                     What = "over-length" },
            @{ V = "";                              What = "empty" }
        )
        $sbFuzzBad = @()
        foreach ($case in $sbFuzz) {
            $msg = ""
            try { Assert-SandboxIdentifier -Value $case.V -Name "the sandbox label" -Kind "label" -MaxLength 63 | Out-Null }
            catch { $msg = [string]$_.Exception.Message }
            if (-not $msg) { $sbFuzzBad += "accepted: $($case.What)" }
            elseif ($case.V -and $case.V.Length -lt 200 -and $msg -match [regex]::Escape($case.V)) { $sbFuzzBad += "echoed: $($case.What)" }
        }
        if ($sbFuzzBad.Count -eq 0) {
            Add-Pass "All $($sbFuzz.Count) hostile identifier classes are refused before an API call is constructed, and none is echoed back into the error"
        } else {
            Add-Fail "Identifier validation gaps: $($sbFuzzBad -join '; ')"
        }
        # A dash-leading value must be diagnosed AS argument injection, not as a
        # generic malformed identifier. The per-kind allowlist would reject it
        # either way, so this pins the diagnosis rather than the outcome: an
        # operator who is told "not a well-formed label" goes looking for a typo,
        # and an operator who is told "a CLI parses this as a flag" goes looking
        # for where the value came from.
        $sbDashMsg = ""
        try { Assert-SandboxIdentifier -Value "--identity" -Name "the sandbox disk id" -Kind "guid" | Out-Null } catch { $sbDashMsg = [string]$_.Exception.Message }
        if ($sbDashMsg -match "flag") {
            Add-Pass "A dash-leading identifier is reported as argument injection, not as a generic malformed value"
        } else {
            Add-Fail "The argument-injection diagnosis was lost: $sbDashMsg"
        }
        # ...and it is actually WIRED: a hostile disk id from configuration must
        # stop the dispatch, not reach an argv.
        Reset-SquadCliStubLog -Stub $sbStub
        $sbHostileErr = ""
        try { Start-SquadExecution -Provider (New-SandboxTestProvider -DiskId "--identity") -Request $sbRequest 6>$null | Out-Null } catch { $sbHostileErr = [string]$_.Exception.Message }
        $sbHostileCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        if ($sbHostileErr -match "squad-sandbox:capability" -and @($sbHostileCalls | Where-Object { $_ -like "sandbox create *" }).Count -eq 0) {
            Add-Pass "A flag-shaped disk id is refused at the provider boundary and never reaches a 'sandbox create' argv"
        } else {
            Add-Fail "A flag-shaped disk id was not stopped (err=$sbHostileErr)"
        }
        # A hostile host pattern must not be able to smuggle a second --rule.
        $sbHostFuzz = @("*.github.com --identity x", "evil.com:Allow --rule *:Allow", "a`r`nb", "-evil.com", "*")
        $sbHostBad = @()
        foreach ($v in $sbHostFuzz) {
            $msg = ""
            try { Assert-SandboxIdentifier -Value $v -Name "an egress pattern" -Kind "host" -MaxLength 253 | Out-Null } catch { $msg = [string]$_.Exception.Message }
            if (-not $msg) { $sbHostBad += $v }
        }
        if ($sbHostBad.Count -eq 0) {
            Add-Pass "Egress patterns that would smuggle an extra CLI flag or split a log line are refused"
        } else {
            Add-Fail "Hostile egress patterns accepted: $($sbHostBad.Count)"
        }

        # --- 16. hostile manifest values reach neither policy nor output -----
        $sbPoison = "evil.com`r`n--identity`r`n" + $sbSecret
        $sbPoisonReq = New-SquadDispatchRequest -SessionId "stub-session" -Repository "octo/demo" `
            -Prompt "p" -Mode "prompt" -CapabilityResolution ([pscustomobject]@{ egressHosts = @($sbPoison) })
        Reset-SquadCliStubLog -Stub $sbStub
        $sbPoisonOutcome = @{}
        $sbPoisonErr = ""
        try { Start-SquadExecution -Provider (New-SandboxTestProvider) -Request $sbPoisonReq -Outcome $sbPoisonOutcome 6>$null | Out-Null } catch { $sbPoisonErr = [string]$_.Exception.Message }
        $sbPoisonCalls = (@(Get-SquadCliStubCall -Stub $sbStub -Tool aca) -join "`n")
        $sbPoisonOut = ($sbPoisonOutcome | ConvertTo-Json -Depth 8)
        if ($sbPoisonErr -and $sbPoisonCalls -notmatch "evil\.com" -and $sbPoisonErr -notmatch "evil\.com" `
                -and $sbPoisonOut -notmatch "evil\.com" -and $sbPoisonErr -notmatch [regex]::Escape($sbSecret)) {
            Add-Pass "A hostile manifest egress value reaches neither the emitted policy, nor the error text, nor the status payload"
        } else {
            Add-Fail "A hostile manifest value escaped (err=$sbPoisonErr inArgv=$($sbPoisonCalls -match 'evil\.com'))"
        }

        # --- 17. readback of credential/egress values is refused -------------
        # `credential list` and `egress show`/`export` return the VALUES, and
        # this provider echoes CLI output to the host. Anyone with group read
        # access can already run them by hand (ADR 0001 risk R2); what must not
        # happen is this tool putting them in a session log or a CI transcript.
        # `egress decisions` is deliberately still permitted -- it is the audit
        # trail and carries no secret.
        $sbReadback = @(
            @("sandboxgroup", "credential", "list"),
            @("sandboxgroup", "credential", "show", "--id", "cred-1"),
            @("sandbox", "egress", "show", "-l", "name=x"),
            @("sandbox", "egress", "export", "-l", "name=x")
        )
        $sbReadbackBad = @()
        foreach ($argv in $sbReadback) {
            $msg = ""
            try { Invoke-SandboxCli -Context $sbCredProvider.Context -Argv $argv | Out-Null } catch { $msg = [string]$_.Exception.Message }
            if ($msg -notmatch "squad-sandbox:capability") { $sbReadbackBad += ($argv -join " ") }
        }
        $sbDecisionsOk = $true
        try { Assert-SandboxArgvNoReadback -Argv @("sandbox", "egress", "decisions", "-l", "name=x", "-o", "json") | Out-Null } catch { $sbDecisionsOk = $false }
        if ($sbReadbackBad.Count -eq 0 -and $sbDecisionsOk) {
            Add-Pass "Subcommands that read back credential or egress VALUES are refused; 'egress decisions' (the audit trail) is still allowed"
        } else {
            Add-Fail "Readback refusal is wrong (allowed=$($sbReadbackBad -join '; ') decisionsBlocked=$(-not $sbDecisionsOk))"
        }

        # --- 18. concurrency ceiling and orphan reaping ----------------------
        # A leaked sandbox bills until something stops it. Two independent
        # controls: refuse to start beyond the class ceiling, and a reaper that
        # can find and delete orphans by label.
        $sbBusyClass = ($sbClass | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        $sbBusyClass.limits.maxConcurrentSandboxes = 2
        $env:SQUAD_STUB_ACA_LIST_FIXTURE = "sandbox-list-busy.json"
        Reset-SquadCliStubLog -Stub $sbStub
        $sbBusyErr = ""
        try {
            $busyProvider = New-SquadExecutionProvider -Kind "sandbox" -Options @{
                Class = $sbBusyClass; SandboxGroup = "sbg-squad-stub"; ResourceGroup = "rg-squad-stub"
                SubscriptionId = "00000000-0000-0000-0000-000000000000"
                DiskId = "aaaaaaaa-1111-2222-3333-444444444444"; AcaCliPath = $sbCli
                IdleTimeoutSeconds = 1800; PollSeconds = 1; WorkerSecrets = @{ GH_TOKEN = $sbSecret }
            }
            Start-SquadExecution -Provider $busyProvider -Request $sbRequest 6>$null | Out-Null
        } catch { $sbBusyErr = [string]$_.Exception.Message }
        $sbBusyCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        if ($sbBusyErr -match "squad-sandbox:quota" -and @($sbBusyCalls | Where-Object { $_ -like "sandbox create *" }).Count -eq 0) {
            Add-Pass "The per-class concurrency ceiling refuses a dispatch that would exceed it, tagged 'quota' and before anything bills"
        } else {
            Add-Fail "The concurrency ceiling did not hold (err=$sbBusyErr)"
        }
        # A class with no stated ceiling must be a CONFIG error, not "unlimited".
        $sbNoLimitClass = ($sbClass | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
        $sbNoLimitClass.PSObject.Properties.Remove("limits")
        $sbNoLimitErr = ""
        try {
            $nlProvider = New-SquadExecutionProvider -Kind "sandbox" -Options @{
                Class = $sbNoLimitClass; SandboxGroup = "sbg-squad-stub"; ResourceGroup = "rg-squad-stub"
                SubscriptionId = "00000000-0000-0000-0000-000000000000"
                DiskId = "aaaaaaaa-1111-2222-3333-444444444444"; AcaCliPath = $sbCli
                IdleTimeoutSeconds = 1800; PollSeconds = 1; WorkerSecrets = @{ GH_TOKEN = $sbSecret }
            }
            Start-SquadExecution -Provider $nlProvider -Request $sbRequest 6>$null | Out-Null
        } catch { $sbNoLimitErr = [string]$_.Exception.Message }
        if ($sbNoLimitErr -match "squad-sandbox:config") {
            Add-Pass "A class with no declared concurrency ceiling is a configuration error, not an unbounded budget"
        } else {
            Add-Fail "A class with no ceiling was treated as unlimited: $sbNoLimitErr"
        }

        $env:SQUAD_STUB_ACA_LIST_FIXTURE = "sandbox-list-reaper.json"
        Reset-SquadCliStubLog -Stub $sbStub
        $sbReap = Invoke-SquadSandboxReaper -Context $sbCredProvider.Context -MaxAgeMinutes 60 6>$null
        $sbReapCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        $sbReapNames = @($sbReap.Candidates)
        if ($sbReapNames -contains "squad-orphan-old" -and $sbReapNames -notcontains "squad-fresh-one" `
                -and $sbReapNames -notcontains "not-ours-orphan" -and $sbReapNames -notcontains "squad-unknown-age" `
                -and @($sbReap.UndecidableAge) -contains "squad-unknown-age" -and $sbReap.DryRun `
                -and @($sbReapCalls | Where-Object { $_ -like "sandbox delete *" }).Count -eq 0) {
            Add-Pass "The reaper finds only OUR aged orphans, never touches other tenants' sandboxes or one whose age it cannot determine, and deletes nothing without -Delete"
        } else {
            Add-Fail "Reaper selection is wrong (candidates=$($sbReapNames -join ',') undecidable=$($sbReap.UndecidableAge -join ',') dryRun=$($sbReap.DryRun))"
        }
        Reset-SquadCliStubLog -Stub $sbStub
        $sbReap2 = Invoke-SquadSandboxReaper -Context $sbCredProvider.Context -MaxAgeMinutes 60 -KeepSessionIds @("orphan-old") -Delete 6>$null
        $sbReap2Calls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        if (@($sbReap2.Deleted).Count -eq 0 -and @($sbReap2Calls | Where-Object { $_ -like "sandbox delete *" }).Count -eq 0) {
            Add-Pass "The reaper never deletes a sandbox belonging to a session it was told to keep (a live session is not an orphan)"
        } else {
            Add-Fail "The reaper deleted a kept session (deleted=$(@($sbReap2.Deleted) -join ','))"
        }
        # ...but it DOES delete a real orphan when told to, otherwise the control
        # is decorative. Same fixture, no keep list.
        Reset-SquadCliStubLog -Stub $sbStub
        $sbReap3 = Invoke-SquadSandboxReaper -Context $sbCredProvider.Context -MaxAgeMinutes 60 -Delete 6>$null
        $sbReap3Deletes = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca | Where-Object { $_ -like "sandbox delete *" })
        if (@($sbReap3.Deleted) -contains "squad-orphan-old" -and $sbReap3Deletes.Count -eq 1 `
                -and $sbReap3Deletes[0] -like "*name=squad-orphan-old*") {
            Add-Pass "The reaper deletes the aged orphan (exactly one labelled delete) when -Delete is given"
        } else {
            Add-Fail "The reaper did not delete the orphan (deleted=$(@($sbReap3.Deleted) -join ',') calls=$($sbReap3Deletes.Count))"
        }
        $env:SQUAD_STUB_ACA_LIST_FIXTURE = ""

        # A label is service-supplied input, not a value this process minted, and
        # it reaches an argv (`sandbox delete -l name=<label>`) and a log line.
        # The disk id resolved from this same service is already validated
        # "whether it came from config or from the service's own listing"; a
        # label that skipped that check was the one inconsistency left.
        $sbHostileLabels = @(
            @{ Fixture = "sandbox-list-hostile-label.json";   What = "path traversal" },
            @{ Fixture = "sandbox-list-hostile-label-2.json"; What = "an embedded newline" }
        )
        $sbLabelBad = @()
        foreach ($case in $sbHostileLabels) {
            $env:SQUAD_STUB_ACA_LIST_FIXTURE = $case.Fixture
            Reset-SquadCliStubLog -Stub $sbStub
            $sbLabelErr = ""
            try { Invoke-SquadSandboxReaper -Context $sbCredProvider.Context -MaxAgeMinutes 60 -Delete 6>$null | Out-Null } catch { $sbLabelErr = [string]$_.Exception.Message }
            $sbLabelDeletes = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca | Where-Object { $_ -like "sandbox delete *" })
            if ($sbLabelErr -notmatch "squad-sandbox:capability") { $sbLabelBad += "$($case.What) was not refused (err=$sbLabelErr)" }
            if ($sbLabelDeletes.Count -ne 0) { $sbLabelBad += "$($case.What) still produced $($sbLabelDeletes.Count) delete call(s)" }
            if ($sbLabelErr -match "other-tenant" -or $sbLabelErr -match "DELETED everything") { $sbLabelBad += "$($case.What) was echoed back into the error message" }
        }
        $env:SQUAD_STUB_ACA_LIST_FIXTURE = ""
        if ($sbLabelBad.Count -eq 0) {
            Add-Pass "A sandbox label supplied by the SERVICE's own listing is validated exactly like the disk id resolved from it: a traversal or control-character label is refused before any 'sandbox delete' is built, and is never echoed"
        } else {
            Add-Fail "Service-supplied labels bypass identifier validation: $($sbLabelBad -join '; ')"
        }

        # --- 19. failure kinds are separately identifiable -------------------
        # PRD #6 requires quota exhaustion, auth failure, capability refusal,
        # readiness and execution failure to be distinguishable, and the ORDER of
        # the rules is load-bearing: a throttling response is a 429 and several
        # services return 403 for a quota refusal, so reading "you have hit your
        # ceiling" as "your credentials are bad" sends an operator to rotate a
        # perfectly good token -- while the inverse, reading a rotated-out
        # credential as "a ceiling was hit, retry later", makes an unattended
        # dispatcher retry a credential fault forever.
        #
        # WHY THIS BLOCK LOOKS THE WAY IT DOES. The previous version asserted
        # only the kind, over fixtures that each matched exactly ONE rule list.
        # For such an input every ordering agrees, so swapping the quota and auth
        # blocks left the suite at 200/0/0 -- the label "quota is not misread as
        # auth" was a claim, not an observation. That is the fifth recurrence of
        # this defect class in this programme. Two devices stop it recurring:
        #
        #   1. AMBIGUOUS fixtures. Each `Also` fixture matches more than one rule
        #      list, and the ambiguity is PROVEN from the shipping pattern lists
        #      rather than asserted by a comment. Only such an input can tell two
        #      orderings apart.
        #   2. An ADJACENCY audit. Every neighbouring pair of rules in
        #      $script:SandboxFailureRules must have at least one ambiguous
        #      fixture spanning it. Adding a rule, or deleting a fixture, without
        #      a discriminating input is itself a failing check.
        #
        # `DecidedBy` (Get-SandboxFailureClassification) is what makes a
        # precedence assertable at all -- the same treatment classifyGhFailure
        # in worker/lib/dispatch-lease.js received after Sprint 6's B3.
        $sbKinds = @(
            @{ Err = "ERROR: QuotaExceeded: the subscription has exceeded the limit for sandboxes"; Want = "quota" },
            @{ Err = "ERROR: 429 TooManyRequests"; Want = "quota" },
            @{ Err = "ERROR: AADSTS700016 unauthorized_client"; Want = "auth" },
            @{ Err = "ERROR: (AuthorizationFailed) does not have permission"; Want = "auth" },
            @{ Err = "ERROR: sandbox is still provisioning"; Want = "readiness" },
            @{ Err = "Error: Network issue - retry policy expired"; Want = "transport" },
            @{ Err = "ERROR: the command exited with status 2"; Want = "execution" },

            # --- ambiguous: quota vs auth (the reorder mutation) -------------
            # The discriminating input class the taxonomy exists for, and which
            # no previous fixture covered: a 403 that is really a quota refusal.
            @{ Err = "ERROR: 403 Forbidden (QuotaExceeded): the subscription has no remaining sandbox capacity"
               Want = "quota"; Also = @("auth") },

            # --- ambiguous: auth vs quota by GUID (the substring mutation) ---
            # Azure decorates every auth failure with GUIDs. With "429" matched
            # as a bare substring these classified as `quota`, so a rotated-out
            # credential looked like a ceiling and got retried forever.
            @{ Err = "ERROR: (AuthorizationFailed) The client does not have authorization to perform action. Correlation ID: 1b8f429c-8f2d-4c1e-9a42-9b7f0e429a11"
               Want = "auth" },
            @{ Err = "ERROR: AADSTS700016 unauthorized_client. Trace ID: 5c429abc-1d2e-4f3a-8b6c-0d1e2f3a4b5c"
               Want = "auth" },
            @{ Err = "ERROR: 401 Unauthorized (request id 0000429f-aaaa-bbbb-cccc-ddddeeeeffff)"
               Want = "auth" },
            @{ Err = "ERROR: sandbox is still provisioning. Request ID: 4291aaaa-bbbb-cccc-dddd-eeeeffff0000"
               Want = "readiness" },

            # --- ambiguous: auth vs readiness -------------------------------
            @{ Err = "ERROR: (AuthorizationFailed) the sandbox is still provisioning and the caller is not authorized to wait for it"
               Want = "auth"; Also = @("readiness") },

            # --- ambiguous: transport vs quota ------------------------------
            # Transport wins: a reset connection tells us nothing about a ceiling.
            @{ Err = "ERROR: 429 TooManyRequests (connection reset by peer)"
               Want = "transport"; Also = @("quota") }
        )

        # Which rule lists does this text match at all? Computed from the SHIPPING
        # lists, so "this fixture is ambiguous" is an observation, not a label.
        function Get-SbMatchingRules {
            param([string]$Text)
            $hit = @()
            foreach ($rule in $script:SandboxFailureRules) {
                foreach ($pattern in $rule.Patterns) {
                    if ($Text -match $pattern) { $hit += $rule.Kind; break }
                }
            }
            return $hit
        }

        $sbKindBad = @()
        $sbAmbiguousPairs = @{}
        foreach ($case in $sbKinds) {
            $short = $case.Err.Substring(0, [math]::Min(34, $case.Err.Length))
            $cls = Get-SandboxFailureClassification -Result ([pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @($case.Err) })
            if ($cls.Kind -ne $case.Want) { $sbKindBad += "'$short' -> $($cls.Kind) (wanted $($case.Want))" }
            # The rule that decided must be the rule that was supposed to.
            $wantDecider = $(if ($case.Want -eq "execution") { "fallthrough" } else { $case.Want })
            if ($cls.DecidedBy -ne $wantDecider) { $sbKindBad += "'$short' was decided by '$($cls.DecidedBy)', wanted '$wantDecider'" }
            if ($case.Want -ne "execution" -and -not $cls.Pattern) { $sbKindBad += "'$short' reported no deciding pattern" }

            $matching = @(Get-SbMatchingRules -Text $case.Err)
            $also = @()
            if ($case.ContainsKey("Also")) { $also = @($case.Also | Where-Object { $_ }) }
            if ($also.Count -gt 0) {
                # PROVE the ambiguity from the shipping lists. If a pattern edit
                # makes this fixture match only one list, it stops discriminating
                # between the two orderings and this check says so.
                foreach ($other in $also) {
                    if ($matching -notcontains $other) {
                        $sbKindBad += "'$short' was declared ambiguous with '$other' but the shipping '$other' patterns do not match it -- it no longer discriminates between the two orderings"
                    }
                }
                if ($matching -notcontains $case.Want) {
                    $sbKindBad += "'$short' does not match the '$($case.Want)' list at all"
                }
                foreach ($other in $also) {
                    $sbAmbiguousPairs["$($case.Want)|$other"] = $true
                    $sbAmbiguousPairs["$other|$($case.Want)"] = $true
                }
            }
        }
        $sbSuccessCls = Get-SandboxFailureClassification -Result ([pscustomobject]@{ ExitCode = 0; StdOut = @(); StdErr = @() })
        if ($sbSuccessCls.Kind -ne "" -or $sbSuccessCls.DecidedBy -ne "success") { $sbKindBad += "success classified as a failure" }
        # Our own client give-up is transport whatever it says, because it is not
        # a service verdict (Invoke-CliSafeWithStdin reports exit 124).
        $sbTimeoutCls = Get-SandboxFailureClassification -Result ([pscustomobject]@{ ExitCode = 124; StdOut = @(); StdErr = @("timed out after 120s") })
        if ($sbTimeoutCls.Kind -ne "transport") { $sbKindBad += "a client timeout (exit 124, 'timed out after 120s') classified as '$($sbTimeoutCls.Kind)', not transport" }
        # ...and by TEXT alone too, so a caller that lost the exit code still gets it right.
        if ((Get-SandboxFailureKind -Result ([pscustomobject]@{ ExitCode = 1; StdOut = @(); StdErr = @("aca: timed out after 120s") })) -ne "transport") {
            $sbKindBad += "'timed out after 120s' is not matched as a transport failure by text"
        }
        if ($sbKindBad.Count -eq 0) {
            Add-Pass "Quota, auth, readiness, transport and execution failures are separately identifiable, each names the rule that decided it, and a 403-that-is-really-a-quota-refusal is classified quota while a GUID-bearing auth failure is NOT"
        } else {
            Add-Fail "Failure classification is wrong: $($sbKindBad -join '; ')"
        }

        # The anti-recurrence device: no adjacent pair of rules may be ordered
        # without a fixture that can tell the two orderings apart.
        $sbRuleKinds = @($script:SandboxFailureRules | ForEach-Object { $_.Kind })
        $sbUncovered = @()
        for ($i = 0; $i -lt ($sbRuleKinds.Count - 1); $i++) {
            $key = "$($sbRuleKinds[$i])|$($sbRuleKinds[$i + 1])"
            if (-not $sbAmbiguousPairs.ContainsKey($key)) { $sbUncovered += $key.Replace("|", " before ") }
        }
        if ($sbUncovered.Count -eq 0 -and $sbRuleKinds.Count -ge 4) {
            Add-Pass "Every adjacent pair of classification rules ($($sbRuleKinds -join ' > ')) has a fixture that matches BOTH lists, so swapping any two neighbouring rules is a visible, failing change"
        } else {
            Add-Fail "These rule orderings are unobservable -- no fixture matches both lists, so reordering them is silent: $($sbUncovered -join ', ')"
        }

        # And the ordering itself, stated once: transport, then quota, then auth.
        if ($sbRuleKinds[0] -eq "transport" -and $sbRuleKinds.IndexOf("quota") -lt $sbRuleKinds.IndexOf("auth")) {
            Add-Pass "Classification order is transport-first and quota-before-auth (docs/runbook.md: a quota refusal phrased as a 403 must not send an operator to rotate a good token)"
        } else {
            Add-Fail "Classification rule order is wrong: $($sbRuleKinds -join ' > ') -- quota must precede auth and transport must be first"
        }

        # No numeric HTTP code may be matched as a bare substring. This is the
        # discipline Test-AcaJobExecutionGone has always kept, and dropping it is
        # what let a GUID decide a credential fault was a quota ceiling.
        $sbBareCodes = @()
        foreach ($rule in $script:SandboxFailureRules) {
            foreach ($pattern in $rule.Patterns) {
                if ($pattern -match "^\d{3}$") { $sbBareCodes += "$($rule.Kind): '$pattern'" }
            }
        }
        if ($sbBareCodes.Count -eq 0) {
            Add-Pass "No classification rule matches a bare HTTP status code, so a correlation GUID can never decide a failure kind"
        } else {
            Add-Fail "Bare HTTP status codes are matched as substrings and will fire on GUIDs: $($sbBareCodes -join ', ')"
        }
        # The tag has to actually reach the caller, not just exist as a function.
        $env:SQUAD_STUB_ACA_RC = "1"
        $env:SQUAD_STUB_ACA_ERR = "ERROR: QuotaExceeded - no capacity remains in this region"
        $env:SQUAD_STUB_ACA_LIST_RC = "0"
        $sbQuotaErr = ""
        try { Start-SquadExecution -Provider (New-SandboxTestProvider) -Request $sbRequest 6>$null | Out-Null } catch { $sbQuotaErr = [string]$_.Exception.Message }
        $env:SQUAD_STUB_ACA_RC = "0"
        $env:SQUAD_STUB_ACA_ERR = ""
        if ($sbQuotaErr -match "\[squad-sandbox:quota\]") {
            Add-Pass "A quota refusal from the service surfaces to the caller tagged 'quota', not as a generic failure"
        } else {
            Add-Fail "A service quota refusal was not tagged: $sbQuotaErr"
        }

        # --- 20. brokered credentials do not outlive their session -----------
        # They live on the GROUP, so they survive the sandbox and stay readable
        # to anyone with group read access (ADR 0001 risk R2).
        Reset-SquadCliStubLog -Stub $sbStub
        $sbRevokeOutcome = @{}
        Start-SquadExecution -Provider (New-SandboxTestProvider) -Request $sbRequest -Outcome $sbRevokeOutcome 6>$null | Out-Null
        $sbRevokeHandle = $sbRevokeOutcome["Response"].sessionHandle
        Reset-SquadCliStubLog -Stub $sbStub
        $sbTermResult = Remove-SquadExecution -Provider (New-SandboxTestProvider) -Handle $sbRevokeHandle 6>$null
        $sbTermCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        if (@($sbTermCalls | Where-Object { $_ -like "sandboxgroup credential delete *cred-stub-0001*" }).Count -eq 1 `
                -and $sbTermResult.CredentialsUnrevoked -eq 0) {
            Add-Pass "terminate revokes every brokered credential recorded on the handle (a group-scoped credential must not outlive its session)"
        } else {
            Add-Fail "terminate did not revoke the brokered credential ($($sbTermCalls -join ' | '))"
        }
        # And a create that fails AFTER brokering must not leave one behind.
        Reset-SquadCliStubLog -Stub $sbStub
        $env:SQUAD_STUB_ACA_EGRESS_RC = "1"
        $env:SQUAD_STUB_ACA_EGRESS_ERR = "ERROR: policy rejected"
        try { Start-SquadExecution -Provider (New-SandboxTestProvider) -Request $sbRequest 6>$null | Out-Null } catch { }
        $env:SQUAD_STUB_ACA_EGRESS_RC = "0"
        $env:SQUAD_STUB_ACA_EGRESS_ERR = ""
        $sbFailCalls = @(Get-SquadCliStubCall -Stub $sbStub -Tool aca)
        if (@($sbFailCalls | Where-Object { $_ -like "sandboxgroup credential delete *" }).Count -ge 1 `
                -and @($sbFailCalls | Where-Object { $_ -like "sandbox delete *" }).Count -ge 1) {
            Add-Pass "A dispatch that fails after brokering tears down BOTH the sandbox and its credential (no billing leak, no live token)"
        } else {
            Add-Fail "A failed dispatch left a credential or a sandbox behind ($($sbFailCalls -join ' | '))"
        }
        # A failed revocation must be reported, never silently swallowed.
        Reset-SquadCliStubLog -Stub $sbStub
        $sbRevokeOutcome2 = @{}
        Start-SquadExecution -Provider (New-SandboxTestProvider) -Request $sbRequest -Outcome $sbRevokeOutcome2 6>$null | Out-Null
        $env:SQUAD_STUB_ACA_CREDDEL_RC = "1"
        $env:SQUAD_STUB_ACA_CREDDEL_ERR = "ERROR: could not delete credential"
        $sbTerm2 = Remove-SquadExecution -Provider (New-SandboxTestProvider) -Handle $sbRevokeOutcome2["Response"].sessionHandle 6>$null
        $env:SQUAD_STUB_ACA_CREDDEL_RC = "0"
        $env:SQUAD_STUB_ACA_CREDDEL_ERR = ""
        if ($sbTerm2.Terminated -and $sbTerm2.CredentialsUnrevoked -eq 1) {
            Add-Pass "A credential that could NOT be revoked is reported as still live rather than silently swallowed, and does not block the teardown"
        } else {
            Add-Fail "An unrevoked credential was swallowed (terminated=$($sbTerm2.Terminated) unrevoked=$($sbTerm2.CredentialsUnrevoked))"
        }

        # --- Nothing carrying a plaintext token survives this whole section ---
        #
        # The earlier check compared this directory around ONE call -- the
        # vault-mode refusal -- which turns out to fail BEFORE anything is
        # staged, so it could not have caught a leak: removing the cleanup from
        # both `finally` blocks in squad-sandbox-provider.ps1 left it passing.
        #
        # Measured across the whole section it is no longer vacuous: this run
        # stages 11 files, so a missing cleanup shows up here. The staging path
        # is the real user profile, which no stubbed HOME redirects, so the
        # comparison is before-and-after rather than "is the directory empty"
        # (issue #100) -- a file from an unrelated run must not fail this, and a
        # genuine leak must not hide behind one.
        $sbStageEnd = @(Get-ChildItem -File -LiteralPath $sbStageDir -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name)
        $sbStageLeaked = @($sbStageEnd | Where-Object { $sbStageBefore -notcontains $_ })
        if ($sbStageLeaked.Count -eq 0) {
            Add-Pass "No local staging file carrying a plaintext token survives the sandbox provider scenarios, including the ones that fail part-way"
        } else {
            Add-Fail "$($sbStageLeaked.Count) local credential staging file(s) leaked into ${sbStageDir}: $($sbStageLeaked -join ', ')"
        }
    } catch {
        Add-Fail "Sandbox provider checks threw: $($_.Exception.Message)"
    } finally {
        $env:PATH = $sbPrevPath
        foreach ($name in $sbEnvNames) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        if ($sbStub) { Remove-SquadCliStubEnvironment -Stub $sbStub }
    }
}

# ---------------------------------------------------------------------------
# 9. CLI behaviour regression (offline, stubbed az/gh)
# ---------------------------------------------------------------------------
Write-Section "CLI behaviour regression"
$harness = Join-Path $RepoRoot "scripts\tests\cli-stub-harness.ps1"
$cliScript = Join-Path $RepoRoot "scripts\squad-aca.ps1"
if (-not (Test-Path $harness)) {
    Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing (CLI regression harness)"
} elseif (-not $IsWindowsHost) {
    Write-Host "  [SKIP] CLI regression harness requires Windows (.cmd stubs)" -ForegroundColor Yellow
} else {
    . $harness
    $stub = $null
    try {
        $stub = New-SquadCliStubEnvironment

        # sessions: exact az call sequence and rendered table.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("sessions")
        if ($r.ExitCode -eq 0) { Add-Pass "squad-aca sessions exits 0" }
        else { Add-Fail "squad-aca sessions exited $($r.ExitCode), expected 0" }
        $listCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job execution list*" })
        if ($listCall.Count -eq 1 -and $listCall[0] -like "*--name caj-squad-aca-session --resource-group rg-squad-stub*") {
            Add-Pass "squad-aca sessions issues exactly one 'az containerapp job execution list' with the configured job/resource group"
        } else {
            Add-Fail "squad-aca sessions az call sequence changed: $($r.AzCalls -join ' | ')"
        }
        $headerCols = @("Execution", "Status", "Session", "Mode", "Repository", "Branch", "Started", "Ended")
        $missingCols = @($headerCols | Where-Object { $r.StdOut -notmatch [regex]::Escape($_) })
        if ($missingCols.Count -eq 0) {
            Add-Pass "squad-aca sessions renders the original eight columns (no handle column leaked into the table)"
        } else {
            Add-Fail "squad-aca sessions table lost columns: $($missingCols -join ', ')"
        }
        if ($r.StdOut -notmatch "sqx1\.") {
            Add-Pass "squad-aca sessions does not print opaque execution handles"
        } else {
            Add-Fail "squad-aca sessions leaked an opaque execution handle into user-visible output"
        }

        # logs: default tail and explicit tail must reach az unchanged.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("logs")
        $logCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job logs show*" })
        if ($r.ExitCode -eq 0 -and $logCall.Count -eq 1 -and $logCall[0] -like "*--tail 100*" -and $logCall[0] -like "*--execution *") {
            Add-Pass "squad-aca logs defaults to --tail 100 against the worker container"
        } else {
            Add-Fail "squad-aca logs default call changed: $($logCall -join ' | ')"
        }
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("logs", "--tail", "5")
        $logCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job logs show*" })
        if ($r.ExitCode -eq 0 -and $logCall.Count -eq 1 -and $logCall[0] -like "*--tail 5*") {
            Add-Pass "squad-aca logs --tail 5 is forwarded to az unchanged"
        } else {
            Add-Fail "squad-aca logs --tail 5 call changed: $($logCall -join ' | ')"
        }

        # stop: must map to az job stop (cancel), NOT to idempotent terminate.
        # The stdout assertion is the point: PR #9 was closed for a `stop`
        # output regression, and call-count + exit-code alone cannot see one.
        # The stub's `az containerapp job stop` prints STUB-STOP-ACK; appending
        # `| Out-Null` to the adapter's cancel call keeps the call count and the
        # exit code identical while the user loses every byte az printed.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("stop")
        $stopCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job stop*" })
        if ($r.ExitCode -eq 0 -and $stopCall.Count -eq 1 -and $stopCall[0] -like "*--job-execution-name *") {
            Add-Pass "squad-aca stop issues exactly one 'az containerapp job stop' for the resolved execution"
        } else {
            Add-Fail "squad-aca stop az call sequence changed: $($r.AzCalls -join ' | ')"
        }
        if ($r.StdOut -match "STUB-STOP-ACK") {
            Add-Pass "squad-aca stop passes 'az containerapp job stop' stdout through to the user (PR #9 regression class)"
        } else {
            Add-Fail "squad-aca stop swallowed az stdout; the user no longer sees what 'az containerapp job stop' printed (PR #9 regression class). stdout=$($r.StdOut)"
        }

        # Anti-regression for PR #9: a failing az stop must still surface exactly
        # one stop call, its output, and today's exit code -- no swallowing.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("stop") -StopExitCode 3
        $stopCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job stop*" })
        if ($stopCall.Count -eq 1 -and $r.ExitCode -eq 0) {
            Add-Pass "squad-aca stop preserves today's pass-through behaviour when az stop fails (no swallowing, no retry)"
        } else {
            Add-Fail "squad-aca stop changed behaviour on az failure (calls=$($stopCall.Count), exit=$($r.ExitCode))"
        }
        if ($r.StdOut -match "STUB-STOP-ACK") {
            Add-Pass "squad-aca stop still shows az output when az stop fails (the failure text is the user's only diagnostic)"
        } else {
            Add-Fail "squad-aca stop swallowed az output on failure; the user gets no diagnostic at all. stdout=$($r.StdOut)"
        }

        # Unresolvable session: message text and exit code are observable.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("stop", "no-such-session")
        if ($r.ExitCode -eq 1 -and $r.StdErr -match "Could not find session or execution 'no-such-session'") {
            Add-Pass "squad-aca stop on an unknown session keeps its error text and exit code 1"
        } else {
            Add-Fail "squad-aca stop on an unknown session changed (exit=$($r.ExitCode))"
        }

        # smoke: dispatch still goes through az containerapp job start.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("smoke", "--repo", "octo/demo")
        $startCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job start*" })
        if ($r.ExitCode -eq 0 -and $startCall.Count -eq 1 -and $startCall[0] -like "*SQUAD_MODE=smoke*" -and $startCall[0] -like "*RUN_COPILOT_SMOKE=true*") {
            Add-Pass "squad-aca smoke dispatches one 'az containerapp job start' with the smoke env-vars"
        } else {
            Add-Fail "squad-aca smoke dispatch changed: $($startCall -join ' | ')"
        }

        # doctor is not routed through the provider; assert it is still intact.
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("doctor")
        if ($r.ExitCode -eq 0 -and $r.StdOut -match "Azure auth" -and $r.StdOut -match "GitHub repo") {
            Add-Pass "squad-aca doctor output is unchanged"
        } else {
            Add-Fail "squad-aca doctor output changed (exit=$($r.ExitCode))"
        }
    } catch {
        Add-Fail "CLI behaviour regression checks threw: $($_.Exception.Message)"
    } finally {
        if ($stub) { Remove-SquadCliStubEnvironment -Stub $stub }
    }
}

# ---------------------------------------------------------------------------
# 9b. Unified dispatch contract + durable leases (Sprint 6, PRD #6)
# ---------------------------------------------------------------------------
# Two things are proven here that no other check can prove:
#   1. The PowerShell CLI does not carry its own copy of the routing rule. It is
#      compared byte-for-byte against the shared dispatch core's own output for
#      every dispatch source, so any PowerShell-side "adjustment" of the route
#      shows up as a failure rather than as drift.
#   2. The lease is written BEFORE compute is requested. Asserted by INDEX in a
#      shared, ordered call log that both the fake `az` and the lease store
#      append to -- a presence check would pass even if the order were inverted.
Write-Section "Unified dispatch contract and leases"
$dispatchCli = Join-Path $RepoRoot "worker\lib\squad-dispatch.js"
$contractLib = Join-Path $RepoRoot "scripts\lib\dispatch-contract.ps1"
$fakeGh = Join-Path $RepoRoot "worker\tests\lib\fake-gh.js"
$nodeAvailable = [bool](Get-Command node -ErrorAction SilentlyContinue)

if (-not (Test-Path $dispatchCli)) {
    Add-Fail "worker/lib/squad-dispatch.js is missing (the shared dispatch core)"
} elseif (-not (Test-Path $contractLib)) {
    Add-Fail "scripts/lib/dispatch-contract.ps1 is missing (the PowerShell face of the contract)"
} elseif (-not $nodeAvailable) {
    Add-Fail "node is required for the shared dispatch contract but is not on PATH"
} else {
    # The contract must be one implementation, not two that happen to agree.
    # Assert the PowerShell side never re-derives a route locally: strip comments
    # and look for a hard-coded route literal in executable code.
    $contractCode = (Get-Content -LiteralPath $contractLib) |
        Where-Object { $_.TrimStart() -notlike "#*" } |
        ForEach-Object { $_ -replace '\s+#.*$', '' }
    $localRoute = @($contractCode | Where-Object { $_ -match "['`"](aca-job|sandbox|fail-closed)['`"]" })
    $delegates = @($contractCode | Where-Object { $_ -match "squad-dispatch\.js" }).Count -ge 1
    if ($localRoute.Count -eq 0 -and $delegates) {
        Add-Pass "dispatch-contract.ps1 contains no PowerShell-local routing rule (it only calls the shared core)"
    } else {
        Add-Fail "dispatch-contract.ps1 appears to re-implement routing in PowerShell (delegates=$delegates, literals=$($localRoute -join ' | ')); the decision must come from worker/lib/dispatch-decision.js only"
    }

    . $contractLib
    $leaseRoot = Join-Path $RepoRoot ".validate-leases"
    $savedGhBin = $env:SQUAD_GH_BIN
    $savedState = $env:FAKE_GH_STATE
    $savedNow = $env:SQUAD_LEASE_NOW
    $savedFail = $env:FAKE_GH_FAIL_MODE
    try {
        Remove-Item -Recurse -Force $leaseRoot -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
        $env:SQUAD_GH_BIN = $fakeGh
        $env:FAKE_GH_STATE = $leaseRoot
        $env:SQUAD_LEASE_NOW = "2024-05-01T00:00:00.000Z"
        $env:FAKE_GH_FAIL_MODE = ""

        # --- 1. One decision, three dispatchers, compared byte-for-byte ------
        $routings = @{}
        foreach ($source in @("local-cli", "ralph", "watch")) {
            $psDecision = Get-SquadDispatchDecision -SessionId "s-1" -DispatchSource $source -Repository "octo/demo" -IssueNumber "7"
            $routings[$source] = ($psDecision.routing | ConvertTo-Json -Depth 20 -Compress)
        }
        if ($routings["local-cli"] -eq $routings["ralph"] -and $routings["local-cli"] -eq $routings["watch"]) {
            Add-Pass "The routing decision is identical for local-cli, ralph and watch (byte-for-byte)"
        } else {
            Add-Fail "The routing decision differs by dispatcher: $($routings.Values -join ' || ')"
        }

        # The PowerShell shim must return the core's answer unmodified. Compare
        # against the core invoked directly, not against a hand-written expectation.
        $rawJson = & node $dispatchCli decide --session-id "s-1" --dispatch-source "ralph" --repository "octo/demo" --issue 7
        $rawRouting = (($rawJson | ConvertFrom-Json).routing | ConvertTo-Json -Depth 20 -Compress)
        if ($rawRouting -eq $routings["ralph"]) {
            Add-Pass "Get-SquadDispatchDecision returns the shared core's decision unmodified"
        } else {
            Add-Fail "The PowerShell shim altered the routing decision (core=$rawRouting shim=$($routings['ralph']))"
        }

        # --- 2. Lease lifecycle from PowerShell ------------------------------
        $decision = Get-SquadDispatchDecision -SessionId "issue-7-a" -DispatchSource "local-cli" -Repository "octo/demo" -IssueNumber "7"
        $claim1 = New-SquadDispatchLease -Decision $decision -Repository "octo/demo"
        Set-SquadDispatchLeaseState -Operation "dispatched" -Repository "octo/demo" -LeaseKey $decision.leaseKey | Out-Null
        $claim2 = New-SquadDispatchLease -Decision $decision -Repository "octo/demo"
        if ($claim1.outcome -eq "created" -and $claim2.outcome -eq "active") {
            Add-Pass "A duplicate claim from PowerShell is refused while the lease is live (no double-dispatch)"
        } else {
            Add-Fail "Duplicate claim handling changed (first=$($claim1.outcome) second=$($claim2.outcome))"
        }

        # --- 3. Cleanup under auth failure THROWS ----------------------------
        $env:FAKE_GH_FAIL_MODE = "auth"
        $threw = $false
        try {
            Invoke-SquadLeaseSweep -Repository "octo/demo" | Out-Null
        } catch {
            $threw = $true
        }
        if ($threw) {
            Add-Pass "Sweeping under an auth failure throws instead of reporting a clean sweep"
        } else {
            Add-Fail "Sweeping under an auth failure reported success; a 401 must never be read as 'already clean'"
        }
        $threw = $false
        try {
            Set-SquadDispatchLeaseState -Operation "complete" -Repository "octo/demo" -LeaseKey $decision.leaseKey -State "succeeded" | Out-Null
        } catch {
            $threw = $true
        }
        if ($threw) {
            Add-Pass "Completing a lease under an auth failure throws instead of reporting success"
        } else {
            Add-Fail "Completing a lease under an auth failure reported success"
        }
        $env:FAKE_GH_FAIL_MODE = ""

        # --- 4. Externally-deleted lease is an idempotent SUCCESS ------------
        $gone = Set-SquadDispatchLeaseState -Operation "complete" -Repository "octo/demo" -LeaseKey "issue-99999" -State "succeeded"
        if ($gone.outcome -eq "gone") {
            Add-Pass "Completing a lease that no longer exists succeeds (idempotent cleanup)"
        } else {
            Add-Fail "Completing a missing lease returned '$($gone.outcome)', expected 'gone'"
        }

        # --- 5. The sweeper reclaims a stale lease and is idempotent ---------
        $env:SQUAD_LEASE_NOW = "2024-05-01T05:00:00.000Z"
        $sweep1 = Invoke-SquadLeaseSweep -Repository "octo/demo"
        $sweep2 = Invoke-SquadLeaseSweep -Repository "octo/demo"
        if (@($sweep1.reclaimed).Count -ge 1 -and @($sweep2.reclaimed).Count -eq 0) {
            Add-Pass "The sweeper reclaims a stale lease and reclaims nothing on a second run (idempotent)"
        } else {
            Add-Fail "Sweeper behaviour changed (first=$(@($sweep1.reclaimed).Count) second=$(@($sweep2.reclaimed).Count))"
        }

        # --- 6. CONCURRENT CLAIMS: a live claim is not a crashed one ---------
        # The check above proves a DISPATCHED lease refuses a second claim. That
        # is not the dangerous case. The dangerous case is back-to-back: two
        # dispatchers claim before either reaches compute, because the window
        # between claim and `az containerapp job start` spans an env build that
        # shells out to node and az -- seconds, not milliseconds. Ralph's cron
        # and a manual `squad-aca ralph run` overlap by design, so this is
        # reachable through supported operation.
        #
        # Both `created` and `repaired` mean "you own it, dispatch". A second
        # claimer must therefore see NEITHER.
        $env:SQUAD_LEASE_NOW = "2024-05-01T06:00:00.000Z"
        $decA = Get-SquadDispatchDecision -SessionId "issue-71-a" -DispatchSource "ralph" -Repository "octo/demo" -IssueNumber "71"
        $decB = Get-SquadDispatchDecision -SessionId "issue-71-b" -DispatchSource "local-cli" -Repository "octo/demo" -IssueNumber "71"
        $raceA = New-SquadDispatchLease -Decision $decA -Repository "octo/demo"
        $raceB = New-SquadDispatchLease -Decision $decB -Repository "octo/demo"
        if ($raceA.outcome -eq "created" -and $raceB.outcome -eq "active") {
            Add-Pass "Two dispatchers claiming back-to-back BEFORE compute: exactly one is told to dispatch (winner=created, loser=active)"
        } else {
            Add-Fail "Concurrent claim exclusion broken: first='$($raceA.outcome)' second='$($raceB.outcome)'; both 'created' and 'repaired' authorise a dispatch, so anything but 'active' for the loser double-dispatches"
        }
        if ($raceB.lease -and $raceB.lease.sessionId -eq "issue-71-a") {
            Add-Pass "The losing claimer is handed the CURRENT OWNER's lease record, so it can report who holds the work"
        } else {
            Add-Fail "The losing claimer did not receive the owner's lease record (sessionId='$($raceB.lease.sessionId)', expected 'issue-71-a')"
        }
        # ...and a claim that never reached compute is still self-healing once
        # its window elapses, or a crash would wedge the issue forever.
        $env:SQUAD_LEASE_NOW = "2024-05-01T06:30:00.000Z"
        $raceC = New-SquadDispatchLease -Decision $decB -Repository "octo/demo"
        if ($raceC.outcome -eq "repaired") {
            Add-Pass "An abandoned claim is adopted once its window elapses ('repaired'), so a crash between claim and compute still self-heals"
        } else {
            Add-Fail "An abandoned claim was not adoptable after its window ('$($raceC.outcome)'); a crashed dispatcher would wedge the issue permanently"
        }

        # --- 7. The ledger is BOUNDED: terminal leases are pruned ------------
        # Every run, smoke, telemetry smoke and Ralph issue mints a lease. With
        # no delete path the ledger only ever grows, the Contents API directory
        # listing silently caps at 1000 entries, and the sweeper's per-key read
        # eventually exhausts the REST budget -- at which point a 429 makes
        # claimLease throw and dispatch stops for EVERY issue.
        $env:SQUAD_LEASE_NOW = "2024-05-01T07:00:00.000Z"
        foreach ($n in 81..86) {
            $d = Get-SquadDispatchDecision -SessionId "prune-$n" -DispatchSource "ralph" -Repository "octo/demo" -IssueNumber "$n"
            New-SquadDispatchLease -Decision $d -Repository "octo/demo" | Out-Null
            Set-SquadDispatchLeaseState -Operation "complete" -Repository "octo/demo" -LeaseKey $d.leaseKey -State "succeeded" | Out-Null
        }
        $beforePrune = @(Get-SquadDispatchLease -Repository "octo/demo").Count
        $env:SQUAD_LEASE_NOW = "2024-05-01T08:00:00.000Z"
        $sweepInside = Invoke-SquadLeaseSweep -Repository "octo/demo"
        $insidePruned = @($sweepInside.pruned).Count
        $env:SQUAD_LEASE_NOW = "2024-06-01T00:00:00.000Z"
        $sweepAfter = Invoke-SquadLeaseSweep -Repository "octo/demo"
        $afterPrune = @(Get-SquadDispatchLease -Repository "octo/demo").Count
        if ($insidePruned -eq 0 -and @($sweepAfter.pruned).Count -ge 6 -and $afterPrune -lt $beforePrune) {
            Add-Pass "The lease ledger SHRINKS: terminal leases survive the retention window and are pruned past it ($beforePrune -> $afterPrune)"
        } else {
            Add-Fail "Ledger growth is unbounded (inside-window pruned=$insidePruned past-window pruned=$(@($sweepAfter.pruned).Count) before=$beforePrune after=$afterPrune); a ledger that only grows ends in a 429 that stops all dispatch"
        }

        # --- 8. Sweep cost does not scale with ledger size -------------------
        # A per-key read on a five-minute cron is 288 x N calls/day. Cap it, and
        # make the cap observable so a partial pass is never mistaken for a
        # complete one.
        $env:SQUAD_LEASE_NOW = "2024-06-01T00:00:00.000Z"
        foreach ($n in 91..98) {
            $d = Get-SquadDispatchDecision -SessionId "cost-$n" -DispatchSource "ralph" -Repository "octo/demo" -IssueNumber "$n"
            New-SquadDispatchLease -Decision $d -Repository "octo/demo" | Out-Null
        }
        $savedBudget = $env:SQUAD_LEASE_SWEEP_MAX_READS
        $env:SQUAD_LEASE_SWEEP_MAX_READS = "3"
        $bounded = Invoke-SquadLeaseSweep -Repository "octo/demo"
        $env:SQUAD_LEASE_SWEEP_MAX_READS = $savedBudget
        if ($bounded.examined -le 3 -and $bounded.total -ge 8 -and $bounded.budget -eq 3) {
            Add-Pass "One sweep reads at most SQUAD_LEASE_SWEEP_MAX_READS records (examined=$($bounded.examined) of total=$($bounded.total)), so per-run API cost is O(1) in ledger size"
        } else {
            Add-Fail "Sweep cost is unbounded (examined=$($bounded.examined) total=$($bounded.total) budget=$($bounded.budget)); 288 runs/day x N reads exhausts the 5000/hr REST budget and stops dispatch"
        }
        if ($null -ne $bounded.truncated) {
            Add-Pass "The sweep reports whether the ledger listing was truncated at the Contents API 1000-entry cap (never silently short)"
        } else {
            Add-Fail "The sweep no longer reports listing truncation; past 1000 entries the ledger would stop enumerating with no operator-visible cause"
        }
    } catch {
        Add-Fail "Dispatch contract checks threw: $($_.Exception.Message)"
    } finally {
        $env:SQUAD_GH_BIN = $savedGhBin
        $env:FAKE_GH_STATE = $savedState
        $env:SQUAD_LEASE_NOW = $savedNow
        $env:FAKE_GH_FAIL_MODE = $savedFail
        Remove-Item -Recurse -Force $leaseRoot -ErrorAction SilentlyContinue
    }

    # --- 9. Deny-list-first classification, asserted on the DECIDING rule ----
    # This defect class has now recurred three times (Sprint 3 B1, Sprint 5
    # `cancel`, Sprint 6 B1). Asserting only the boolean cannot catch it:
    # whenever a message matches just one list, both loop orders agree. So the
    # classifier reports WHICH list decided, and that is what is asserted here.
    # Swapping the two loops flips 'real-failure' to 'gone' and fails this check
    # even though every boolean would still look right.
    #
    # These four texts are the realistic shapes: GitHub masks a permission
    # denial on a private resource as a 404, so "403 ... (Not Found)" and
    # "Bad credentials (HTTP 401) - Not Found" are the MOST likely real inputs.
    $leaseModule = ((Join-Path $RepoRoot "worker\lib\dispatch-lease.js") -replace '\\', '/')
    if (-not $nodeAvailable) {
        Add-Fail "node is required to verify the gh failure classification but is not on PATH"
    } else {
        $probe = @"
const lease = require('$leaseModule');
const cases = [
  ['gh: HTTP 403: Resource not accessible by integration (Not Found)', false, 'real-failure'],
  ['gh: Bad credentials (HTTP 401) - Not Found', false, 'real-failure'],
  ['gh: HTTP 429: API rate limit exceeded; the resource does not exist', false, 'real-failure'],
  ['gh: HTTP 502: Bad gateway - Not Found', false, 'real-failure'],
  ['gh: HTTP 404: Not Found', true, 'gone'],
  ['gh: the mainframe declined politely', false, 'unrecognised']
];
const bad = [];
for (const [text, isGone, decidedBy] of cases) {
  const c = lease.classifyGhFailure({ ok: false, exitCode: 1, stderr: text, stdout: '' });
  if (c.isGone !== isGone || c.decidedBy !== decidedBy) {
    bad.push(text + ' => isGone=' + c.isGone + ' decidedBy=' + c.decidedBy);
  }
}
process.stdout.write(bad.length ? 'BAD: ' + bad.join(' | ') : 'OK');
"@
        $classifyOut = (& node -e $probe 2>&1) -join " "
        if ($LASTEXITCODE -eq 0 -and $classifyOut -eq "OK") {
            Add-Pass "gh failure classification is DENY-LIST FIRST and reports the deciding rule: a 403/401/429/5xx that also says 'Not Found' is a failure, an unrecognised failure is a failure, and only a clean 404 is 'gone'"
        } else {
            Add-Fail "gh failure classification changed: $classifyOut"
        }
    }
}

# The end-to-end ordering proof needs the CLI stub (a real `squad-aca` dispatch).
if ((Test-Path $harness) -and $IsWindowsHost -and $nodeAvailable) {
    . $harness
    $stub = $null
    try {
        $stub = New-SquadCliStubEnvironment
        Initialize-SquadCliStubRepository -Stub $stub | Out-Null

        # ORDERING BY INDEX: the lease blob must be written before the compute
        # request. Both events land in one ordered log, so this compares
        # positions -- not merely that both happened.
        Reset-SquadCliStubLog -Stub $stub
        Set-Content -LiteralPath $stub.CallLog -Value "" -NoNewline -Encoding ascii
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("smoke", "--repo", "octo/demo")
        $calls = @(Get-Content -LiteralPath $stub.CallLog -ErrorAction SilentlyContinue)
        $leaseIdx = [array]::FindIndex($calls, [Predicate[string]] { param($l) $l -like "gh lease-write*" })
        $startIdx = [array]::FindIndex($calls, [Predicate[string]] { param($l) $l -eq "az job-start" })
        if ($leaseIdx -ge 0 -and $startIdx -ge 0 -and $leaseIdx -lt $startIdx) {
            Add-Pass "squad-aca dispatch writes the lease at index $leaseIdx, BEFORE the compute request at index $startIdx"
        } else {
            Add-Fail "Claim-before-compute ordering broken (lease index=$leaseIdx, compute index=$startIdx, log=$($calls -join ' | '))"
        }

        # Route and dispatcher source must reach the execution env, or `sessions`
        # has nothing to show.
        $startCall = @($r.AzCalls | Where-Object { $_ -like "containerapp job start*" })
        if ($startCall.Count -eq 1 -and $startCall[0] -like "*SQUAD_DISPATCH_ROUTE=aca-job*" -and $startCall[0] -like "*SQUAD_DISPATCH_SOURCE=local-cli*" -and $startCall[0] -like "*SQUAD_LEASE_KEY=*") {
            Add-Pass "Dispatch stamps SQUAD_DISPATCH_ROUTE, SQUAD_DISPATCH_SOURCE and SQUAD_LEASE_KEY into the execution"
        } else {
            Add-Fail "Dispatch no longer stamps the route/source/lease env: $($startCall -join ' | ')"
        }

        # sessions surfaces both, in full (no width-dependent truncation).
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("sessions")
        if ($r.StdOut -match "Route" -and $r.StdOut -match "Source" -and $r.StdOut -match "aca-job" -and $r.StdOut -match "local-cli") {
            Add-Pass "squad-aca sessions shows the resolved Route and the dispatcher Source"
        } else {
            Add-Fail "squad-aca sessions no longer surfaces Route/Source"
        }

        # A repeat dispatch of the SAME work must not start a second execution.
        Reset-SquadCliStubLog -Stub $stub
        $first = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("run", "--repo", "octo/demo", "--name", "dupe-session", "do the thing")
        $firstStarts = @($first.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        Reset-SquadCliStubLog -Stub $stub
        $second = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("run", "--repo", "octo/demo", "--name", "dupe-session", "do the thing")
        $secondStarts = @($second.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($firstStarts -eq 1 -and $secondStarts -eq 0) {
            Add-Pass "A repeated dispatch of the same session does not start a second execution (idempotent)"
        } else {
            Add-Fail "Duplicate dispatch started $secondStarts execution(s) on the second run (first run started $firstStarts)"
        }
    } catch {
        Add-Fail "Dispatch ordering checks threw: $($_.Exception.Message)"
    } finally {
        if ($stub) { Remove-SquadCliStubEnvironment -Stub $stub }
    }
}

# ---------------------------------------------------------------------------
# Issue #25: the CLI actually REACHES the sandbox plane.
#
# Sprint 2 shipped the resolver and Sprint 5 shipped the ACA Sandboxes provider,
# but nothing ever passed a capability resolution to New-SessionExecutionProvider
# -- so every dispatch met the route gate with $null and resolved to `aca-job`.
# The sandbox plane was unreachable from the CLI, which is why the last three
# functional acceptance criteria of PRD #6 could not be demonstrated.
#
# These checks drive the REAL squad-aca through the stub environment and assert
# which substrate each dispatch reached, by argv.
# ---------------------------------------------------------------------------
Write-Section "Capability resolution reaches the execution plane (issue #25)"
if (-not ((Test-Path $harness) -and $IsWindowsHost -and $nodeAvailable)) {
    Write-Host "  [SKIP] issue #25 wiring checks require Windows + node" -ForegroundColor Yellow
} else {
    . $harness
    $stub = $null
    try {
        $stub = New-SquadCliStubEnvironment -WithSandboxConfig
        Initialize-SquadCliStubRepository -Stub $stub | Out-Null
        $manifestPath = Join-Path $stub.WorkDir "squad-capabilities.yml"

        # A manifest the DEFAULT worker image already satisfies. `node` and `git`
        # are in the default profile, so the resolver routes this to aca-job even
        # with the sandbox plane switched on.
        $defaultManifest = @(
            "version: 1"
            "tools:"
            "  - name: git"
            "    required: true"
            "  - name: node"
            "    required: true"
            "egress:"
            "  - host: registry.npmjs.org"
        ) -join "`n"

        # A manifest requiring an APPROVED non-default class. python3/pip3 plus
        # the Python index hosts match sandbox-python-3-12 in the shipped catalog.
        $sandboxManifest = @(
            "version: 1"
            "tools:"
            "  - name: git"
            "    required: true"
            "  - name: python3"
            "    required: true"
            "  - name: pip3"
            "    required: true"
            "egress:"
            "  - host: pypi.org"
            "  - host: files.pythonhosted.org"
        ) -join "`n"

        # A manifest naming an egress host NO approved class permits.
        $unapprovedManifest = @(
            "version: 1"
            "tools:"
            "  - name: python3"
            "    required: true"
            "egress:"
            "  - host: exfil.example.net"
        ) -join "`n"

        function Set-StubManifest {
            param([string]$Body)
            [System.IO.File]::WriteAllText($manifestPath, $Body + "`n")
        }
        function Clear-StubManifest {
            Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        }

        # --- 1. NO MANIFEST => ACA Jobs, and the sandbox binary is never run ---
        # This is the guarantee the 22 goldens encode. It is asserted here too,
        # with the flag ON, because "no manifest is unaffected" must hold in the
        # configuration where the sandbox plane is reachable -- the goldens only
        # ever prove it with the flag off.
        Clear-StubManifest
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-nomanifest", "do the thing")
        $jobStarts = @($r.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($r.ExitCode -eq 0 -and $jobStarts -eq 1 -and $r.AcaCalls.Count -eq 0) {
            Add-Pass "No manifest + sandbox flag ON still dispatches to ACA Jobs and never invokes the sandbox binary"
        } else {
            Add-Fail "No-manifest dispatch changed (exit=$($r.ExitCode) jobStarts=$jobStarts acaCalls=$($r.AcaCalls.Count): $($r.AcaCalls -join ' | '))"
        }

        # --- 2. MANIFEST THE DEFAULT IMAGE SATISFIES => ACA Jobs --------------
        # ACA Jobs stays the default and the rollback path. Reaching the sandbox
        # plane must not have made the sandbox the new default.
        Set-StubManifest -Body $defaultManifest
        Reset-SquadCliStubLog -Stub $stub
        $r = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-default", "do the thing")
        $jobStarts = @($r.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($r.ExitCode -eq 0 -and $jobStarts -eq 1 -and $r.AcaCalls.Count -eq 0) {
            Add-Pass "A manifest the default worker image satisfies still dispatches to ACA Jobs with the sandbox plane enabled"
        } else {
            Add-Fail "Default-satisfied manifest did not use ACA Jobs (exit=$($r.ExitCode) jobStarts=$jobStarts aca=$($r.AcaCalls -join ' | ') err=$($r.StdErr))"
        }

        # --- 3. APPROVED CLASS + FLAG ON => THE SANDBOX PLANE ----------------
        # THE acceptance criterion issue #25 exists for.
        Set-StubManifest -Body $sandboxManifest
        Reset-SquadCliStubLog -Stub $stub
        $cliCredFile = Join-Path $stub.Root "cli-cred-upload.txt"
        Remove-Item $cliCredFile -ErrorAction SilentlyContinue
        $sb = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -CredentialFileCapture $cliCredFile `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-sandbox", "do the thing")
        $jobStarts = @($sb.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        $sbCreate = @($sb.AcaCalls | Where-Object { $_ -like "sandbox create*" }).Count
        if ($sb.ExitCode -eq 0 -and $sbCreate -ge 1 -and $jobStarts -eq 0) {
            Add-Pass "A repository requiring an approved non-default capability is routed to a matching SANDBOX, and no ACA Job execution is started"
        } else {
            Add-Fail "Sandbox routing did not reach the sandbox plane (exit=$($sb.ExitCode) sandboxCreate=$sbCreate jobStarts=$jobStarts aca=$($sb.AcaCalls -join ' | ') err=$($sb.StdErr))"
        }

        # EGRESS BEFORE ANY REPOSITORY CODE, asserted BY INDEX in the ordered
        # `aca` log. Presence is not the property: a policy applied after the
        # first exec protects nothing.
        $egressIdx = [array]::FindIndex([string[]]$sb.AcaCalls, [Predicate[string]] { param($l) $l -like "sandbox egress set*" })
        $execIdx = [array]::FindIndex([string[]]$sb.AcaCalls, [Predicate[string]] { param($l) $l -like "sandbox exec*" })
        if ($egressIdx -ge 0 -and $execIdx -ge 0 -and $egressIdx -lt $execIdx) {
            Add-Pass "Egress policy is applied at aca-call index $egressIdx, BEFORE the first in-sandbox exec at index $execIdx"
        } else {
            Add-Fail "Egress-before-execution ordering broken (egress index=$egressIdx exec index=$execIdx log=$($sb.AcaCalls -join ' | '))"
        }

        # Invariant 4: the sandbox group stays identity-free. A managed identity
        # on the group would be reachable from inside a sandbox running arbitrary
        # repository code, which is the whole reason ACR pulls use a scoped
        # refresh token instead.
        $identityCalls = @($sb.AcaCalls | Where-Object { $_ -like "*--identity*" })
        if ($identityCalls.Count -eq 0) {
            Add-Pass "The wired sandbox dispatch passes no --identity on any aca call (the group stays identity-free)"
        } else {
            Add-Fail "A wired sandbox dispatch passed --identity: $($identityCalls -join ' | ')"
        }

        # --- 3b. THE DISPATCHER ACTUALLY FEEDS THE CREDENTIAL MECHANISM ------
        # Sprint 7 built credential delivery and proved it in isolation, but
        # New-SessionExecutionProvider never passed WorkerSecrets, so a live
        # sandbox session cloned the repository, applied egress, ran the
        # preflight and THEN died on `copilot` with "No authentication
        # information found". Isolation tests could not see it; only a
        # CLI-driven dispatch can. Assert the credential UPLOAD exists and lands
        # BEFORE the launch, so the launch has something to source.
        $stageIdx = [array]::FindIndex([string[]]$sb.AcaCalls, [Predicate[string]] { param($l) $l -like "sandbox fs write *" })
        $vaultIdx = [array]::FindIndex([string[]]$sb.AcaCalls, [Predicate[string]] { param($l) $l -like "*squad-credentials-vault*" })
        $launchIdx = [array]::FindIndex([string[]]$sb.AcaCalls, [Predicate[string]] { param($l) $l -like "*squad-launched*" })
        if ($stageIdx -ge 0 -and $launchIdx -ge 0 -and $vaultIdx -ge 0 -and $vaultIdx -lt $stageIdx -and $stageIdx -lt $launchIdx) {
            Add-Pass "A sandbox-routed run prepares a 0700 credential directory at aca-call index $vaultIdx, UPLOADS the credential at index $stageIdx and launches at index $launchIdx (the dispatcher feeds the delivery mechanism, not just the unit test)"
        } else {
            Add-Fail "A sandbox-routed run staged no credential before launch (vaultIdx=$vaultIdx stageIdx=$stageIdx launchIdx=$launchIdx aca=$($sb.AcaCalls -join ' | '))"
        }
        # And the launch must CONSUME it: sourcing the seed file is the only
        # way the worker sees a token, since no env assignment is permitted.
        if ($launchIdx -ge 0 -and $sb.AcaCalls[$launchIdx] -match "\.squad-creds" `
                -and $sb.AcaCalls -notmatch [regex]::Escape("ghs-stub-git-token-value")) {
            Add-Pass "The launch sources the staged credential file and no aca argv contains the token"
        } else {
            Add-Fail "The launch does not consume the staged credential, or a token reached argv (launchIdx=$launchIdx)"
        }
        # ...and the CONTENT that reached the sandbox must be the dispatcher's
        # real token under the names the worker reads. Asserting only that a
        # `fs write` happened would pass for an empty file.
        $cliCredLines = if (Test-Path $cliCredFile) { @((Get-Content $cliCredFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
        $cliCredWant = @("export GH_TOKEN='ghs-stub-git-token-value'",
                         "export GITHUB_TOKEN='ghs-stub-git-token-value'",
                         "export COPILOT_GITHUB_TOKEN='ghs-stub-git-token-value'")
        if (($cliCredLines -join "`n") -eq ($cliCredWant -join "`n")) {
            Add-Pass "The file a sandbox-routed run uploads carries the dispatcher's token under every name the worker reads (git plane and Copilot plane), which is what 'No authentication information found' meant was missing"
        } else {
            Add-Fail "The uploaded credential file content is wrong: $($cliCredLines.Count) line(s), first='$(if ($cliCredLines.Count) { ($cliCredLines[0] -replace 'ghs-stub-git-token-value', '<tok>') } else { '' })'"
        }

        # PRD #6 requires the two planes stay SEPARATE. When a dedicated Copilot
        # credential is supplied it must be the one that reaches the sandbox --
        # a resolver that quietly reuses the git token for both planes would
        # otherwise pass every check above, because they all run with a single
        # token configured.
        Reset-SquadCliStubLog -Stub $stub
        $twoPlaneFile = Join-Path $stub.Root "cli-cred-twoplane.txt"
        Remove-Item $twoPlaneFile -ErrorAction SilentlyContinue
        $twoPlaneCopilot = "github" + "_pat_" + "stubcopilotvalue0001"
        $twoPlane = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -CredentialFileCapture $twoPlaneFile -CopilotToken $twoPlaneCopilot `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-twoplane", "do the thing")
        $twoPlaneLines = if (Test-Path $twoPlaneFile) { @((Get-Content $twoPlaneFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
        $twoPlaneWant = @("export GH_TOKEN='ghs-stub-git-token-value'",
                          "export GITHUB_TOKEN='ghs-stub-git-token-value'",
                          "export COPILOT_GITHUB_TOKEN='$twoPlaneCopilot'")
        $twoPlaneBrokered = @($twoPlane.AcaCalls | Where-Object { $_ -like "sandboxgroup credential create *--type github-copilot*" }).Count
        if (($twoPlaneLines -join "`n") -eq ($twoPlaneWant -join "`n") -and $twoPlaneBrokered -eq 1 `
                -and ($twoPlane.AcaCalls -join "`n") -notmatch [regex]::Escape($twoPlaneCopilot)) {
            Add-Pass "A dedicated Copilot credential reaches the sandbox as ITSELF, not as a copy of the git token, and is also brokered natively without entering any argv (PRD #6: the planes stay separate)"
        } else {
            Add-Fail "The Copilot plane collapsed onto the git token or was not brokered (lines=$($twoPlaneLines.Count) brokered=$twoPlaneBrokered exit=$($twoPlane.ExitCode))"
        }

        # --- 3c. NO USABLE CREDENTIAL => REFUSE BEFORE ANYTHING IS PAID FOR --
        # A session that starts, provisions a sandbox and dies ninety seconds
        # later on an error the dispatcher already had the facts to predict is
        # a bad failure AND a billed one. Refuse up front: zero aca calls.
        Reset-SquadCliStubLog -Stub $stub
        $noCred = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -GitToken "" -CopilotToken "" -GhAuthToken "" `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-nocred", "do the thing")
        $noCredJobStarts = @($noCred.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($noCred.ExitCode -ne 0 -and $noCred.AcaCalls.Count -eq 0 -and $noCredJobStarts -eq 0 `
                -and ($noCred.StdErr -match "gh auth login") -and ($noCred.StdErr -match "GH_TOKEN")) {
            Add-Pass "A sandbox-routed run with NO usable credential is refused before any aca call, naming 'gh auth login' and the environment variables that would satisfy it (nothing is provisioned, nothing is billed)"
        } else {
            Add-Fail "A credential-less sandbox run was not refused up front (exit=$($noCred.ExitCode) acaCalls=$($noCred.AcaCalls.Count) jobStarts=$noCredJobStarts err=$($noCred.StdErr))"
        }

        # --- 3d. gh auth token IS the local fallback -------------------------
        # The dispatcher's gh identity is by construction the identity already
        # writing the dispatch lease, so brokering it needs no new secret store.
        Reset-SquadCliStubLog -Stub $stub
        $ghFallback = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -GitToken "" -CopilotToken "" -GhAuthToken "ghs-stub-fallback-token" `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-ghfallback", "do the thing")
        $ghFallbackCreate = @($ghFallback.AcaCalls | Where-Object { $_ -like "sandbox create*" }).Count
        if ($ghFallback.ExitCode -eq 0 -and $ghFallbackCreate -ge 1 `
                -and ($ghFallback.AcaCalls -notmatch [regex]::Escape("ghs-stub-fallback-token"))) {
            Add-Pass "With no credential environment set, the dispatcher brokers its own 'gh auth token' and the session dispatches, with the token still absent from every aca argv"
        } else {
            Add-Fail "The gh auth token fallback did not dispatch (exit=$($ghFallback.ExitCode) create=$ghFallbackCreate err=$($ghFallback.StdErr))"
        }

        # --- 3e. CLASSIC PAT WHERE A FINE-GRAINED PAT IS REQUIRED ------------
        # The platform rejects ghp_ for the github-copilot credential type. A
        # dedicated Copilot token that cannot be brokered must say so here,
        # not surface as an opaque platform error after provisioning.
        Reset-SquadCliStubLog -Stub $stub
        $classicPat = "ghp_" + "cliclassicstub000000"
        $classic = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -GitToken "ghs-stub-git-token-value" -CopilotToken $classicPat -GhAuthToken "" `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-classicpat", "do the thing")
        $classicOut = "$($classic.StdErr)`n$($classic.StdOut)"
        if ($classic.ExitCode -ne 0 -and $classic.AcaCalls.Count -eq 0 `
                -and ($classicOut -match "github_pat_") -and ($classicOut -match "COPILOT_GITHUB_TOKEN") `
                -and ($classicOut -notmatch "cliclassicstub")) {
            Add-Pass "A classic ghp_ token supplied as the Copilot credential is refused before any aca call, names the fine-grained form the platform requires, and does not echo the rejected value"
        } else {
            Add-Fail "The classic-PAT Copilot case is wrong (exit=$($classic.ExitCode) acaCalls=$($classic.AcaCalls.Count) echoed=$($classicOut -match 'cliclassicstub') out=$classicOut)"
        }

        # --- 4. SAME MANIFEST + FLAG OFF => FAIL CLOSED ----------------------
        # NOT a silent downgrade. The default worker cannot meet these
        # requirements; running there anyway is the "silently run unsafely"
        # outcome PRD #6 forbids.
        Reset-SquadCliStubLog -Stub $stub
        $off = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "" `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-flagoff", "do the thing")
        $jobStarts = @($off.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($off.ExitCode -ne 0 -and $jobStarts -eq 0 -and $off.AcaCalls.Count -eq 0 `
                -and ($off.StdErr -match "sandbox-feature-disabled-and-default-insufficient")) {
            Add-Pass "The same manifest with the sandbox flag OFF FAILS CLOSED naming the reason, and starts nothing on either plane (no silent downgrade to ACA Jobs)"
        } else {
            Add-Fail "Flag OFF silently downgraded or misreported (exit=$($off.ExitCode) jobStarts=$jobStarts aca=$($off.AcaCalls.Count) err=$($off.StdErr))"
        }

        # --- 5. UNAPPROVED CAPABILITY => FAIL CLOSED, flag ON or off ---------
        Set-StubManifest -Body $unapprovedManifest
        Reset-SquadCliStubLog -Stub $stub
        $un = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-unapproved", "do the thing")
        $jobStarts = @($un.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($un.ExitCode -ne 0 -and $jobStarts -eq 0 -and @($un.AcaCalls | Where-Object { $_ -like "sandbox create*" }).Count -eq 0) {
            Add-Pass "A manifest no approved class satisfies fails closed with the flag ON, starting nothing on either plane"
        } else {
            Add-Fail "An unapproved capability was dispatched anyway (exit=$($un.ExitCode) jobStarts=$jobStarts aca=$($un.AcaCalls -join ' | '))"
        }

        # --- 6. MANIFEST UNREADABLE => REFUSE, never a guess -----------------
        # A manifest that exists but cannot be parsed is the one case where
        # guessing is most tempting and least safe: the file states requirements
        # nobody can read. The shared resolver fails closed and the CLI refuses.
        Set-StubManifest -Body "version: 1`ntools: [ this is not"
        Reset-SquadCliStubLog -Stub $stub
        $bad = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "s25-badmanifest", "do the thing")
        $jobStarts = @($bad.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($bad.ExitCode -ne 0 -and $jobStarts -eq 0 -and $bad.AcaCalls.Count -eq 0) {
            Add-Pass "An unreadable squad-capabilities.yml refuses the dispatch outright rather than guessing a route, and starts nothing"
        } else {
            Add-Fail "An unreadable manifest was dispatched anyway (exit=$($bad.ExitCode) jobStarts=$jobStarts aca=$($bad.AcaCalls.Count))"
        }

        # --- 7. NO WORKING TREE => the documented ACA Jobs fall back, SAID ----
        # `--repo other/repo` cannot be resolved from this working tree. That is
        # the fall back the design documents, and it must be announced: an
        # operator who believes a sandbox manifest is being honoured, while no
        # manifest was ever opened, has no way to tell from silent output.
        Set-StubManifest -Body $sandboxManifest
        Reset-SquadCliStubLog -Stub $stub
        $other = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" `
            -CliArguments @("run", "--repo", "other/repo", "--name", "s25-otherrepo", "do the thing")
        $jobStarts = @($other.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($jobStarts -eq 1 -and $other.AcaCalls.Count -eq 0 -and ($other.StdOut -match "read no manifest")) {
            Add-Pass "A repository with no readable working tree falls back to ACA Jobs and SAYS SO, instead of silently pretending a manifest was consulted"
        } else {
            Add-Fail "The no-working-tree fall back is silent or wrong (jobStarts=$jobStarts aca=$($other.AcaCalls.Count) err=$($other.StdErr))"
        }

        # --- 8. LIFECYCLE FROM THE HANDLE, not from today's manifest ---------
        # status / logs / stop must address the plane a session ACTUALLY runs on.
        # Re-resolving would answer today's question about yesterday's session:
        # edit squad-capabilities.yml after dispatch and `stop` would talk to the
        # wrong substrate, reporting success while the real execution ran on.
        Clear-StubManifest
        Reset-SquadCliStubLog -Stub $stub
        $ls = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" -CliArguments @("sessions")
        if ($ls.ExitCode -eq 0 -and ($ls.AcaCalls | Where-Object { $_ -like "sandbox list*" }).Count -ge 1 -and $ls.StdOut -match "Route: sandbox") {
            Add-Pass "squad-aca sessions lists BOTH planes with the flag on, so a sandbox-routed session is visible to logs and stop"
        } else {
            Add-Fail "sessions did not list the sandbox plane (exit=$($ls.ExitCode) aca=$($ls.AcaCalls -join ' | '))"
        }

        # The stub `aca sandbox list` fixture owns exactly one squad-labelled
        # sandbox; that label is the session identifier a user would type.
        $sandboxName = "squad-stub-session"
        if ($ls.StdOut -notmatch [regex]::Escape($sandboxName)) {
            Add-Fail "The sandbox '$sandboxName' is not visible in `sessions` output; lifecycle checks cannot run"
        } else {
            Reset-SquadCliStubLog -Stub $stub
            $lg = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" -CliArguments @("logs", $sandboxName)
            $lgJobLogs = @($lg.AzCalls | Where-Object { $_ -like "containerapp job logs*" }).Count
            $lgSandbox = @($lg.AcaCalls | Where-Object { $_ -like "sandbox exec*" -or $_ -like "sandbox logs*" }).Count
            if ($lg.ExitCode -eq 0 -and $lgSandbox -ge 1 -and $lgJobLogs -eq 0) {
                Add-Pass "squad-aca logs against a SANDBOX handle reaches the Sandboxes provider and never the ACA Jobs adapter"
            } else {
                Add-Fail "logs on a sandbox handle used the wrong provider (exit=$($lg.ExitCode) sandboxCalls=$lgSandbox jobLogCalls=$lgJobLogs err=$($lg.StdErr))"
            }

            Reset-SquadCliStubLog -Stub $stub
            $st = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" -CliArguments @("stop", $sandboxName)
            $stJobStop = @($st.AzCalls | Where-Object { $_ -like "containerapp job stop*" }).Count
            $stSandbox = @($st.AcaCalls | Where-Object { $_ -like "sandbox exec*" -or $_ -like "sandbox delete*" }).Count
            if ($st.ExitCode -eq 0 -and $stSandbox -ge 1 -and $stJobStop -eq 0) {
                Add-Pass "squad-aca stop against a SANDBOX handle cancels on the Sandboxes provider and never calls 'az containerapp job stop'"
            } else {
                Add-Fail "stop on a sandbox handle used the wrong provider (exit=$($st.ExitCode) sandboxCalls=$stSandbox jobStops=$stJobStop err=$($st.StdErr))"
            }

            # ...and the Jobs plane is still addressed by the Jobs adapter. One
            # handle kind reaching the right provider proves nothing if the other
            # kind now reaches it too.
            Reset-SquadCliStubLog -Stub $stub
            $stJob = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "1" -CliArguments @("stop", "caj-squad-aca-session-stub01")
            $stJobStop = @($stJob.AzCalls | Where-Object { $_ -like "containerapp job stop*" }).Count
            $stJobSandbox = @($stJob.AcaCalls | Where-Object { $_ -like "sandbox exec*" -or $_ -like "sandbox delete*" }).Count
            if ($stJobStop -eq 1 -and $stJobSandbox -eq 0) {
                Add-Pass "squad-aca stop against an ACA JOB handle still uses the Jobs adapter even with the sandbox plane enabled"
            } else {
                Add-Fail "stop on an aca-job handle used the wrong provider (jobStops=$stJobStop sandboxCalls=$stJobSandbox err=$($stJob.StdErr))"
            }
        }

        # --- 9. A sandbox handle is INERT with the flag off ------------------
        # The kill switch promises this control plane never touches `aca` while
        # the flag is unset. Recovering a provider from a handle must not be a
        # way around that.
        Reset-SquadCliStubLog -Stub $stub
        $offList = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -SandboxFlag "" -CliArguments @("sessions")
        if ($offList.AcaCalls.Count -eq 0) {
            Add-Pass "With the flag off, sessions makes no `aca` call at all -- the kill switch still means the sandbox binary is never invoked"
        } else {
            Add-Fail "The flag-off kill switch leaked aca calls: $($offList.AcaCalls -join ' | ')"
        }
    } catch {
        Add-Fail "Issue #25 wiring checks threw: $($_.Exception.Message)"
    } finally {
        if ($stub) { Remove-SquadCliStubEnvironment -Stub $stub }
    }
}

# The golden capture matrix must NEVER enable the sandbox flag. -SandboxFlag
# exists so the checks above can reach the sandbox plane; if a golden case ever
# passed it, "flag off is byte-identical" would stop being what the 22 goldens
# prove.
$captureCases = Join-Path $RepoRoot "scripts\tests\cli-capture-cases.ps1"
if (Test-Path $captureCases) {
    $captureText = Get-Content $captureCases -Raw
    if ($captureText -notmatch "SandboxFlag" -and $captureText -notmatch "SQUAD_ACA_ENABLE_SANDBOX") {
        Add-Pass "The golden capture matrix never enables the sandbox feature flag, so all 22 goldens still pin the flag-off path"
    } else {
        Add-Fail "scripts/tests/cli-capture-cases.ps1 references the sandbox flag; the goldens no longer pin the flag-off path"
    }
}

# --- Issue #22: a 404 on a lease write must be DIAGNOSED, not just quoted -----
# GitHub answers a write to a repository the caller may only READ with
# `404 Not Found`, never `403 Forbidden`, so "this identity cannot write here"
# is invisible in the raw message. A live E2E run lost an afternoon to it. The
# classification is deliberately NOT changed: these checks pin that the failure
# is still a failure AND that the operator is now told why.
if ((Test-Path $harness) -and $IsWindowsHost -and $nodeAvailable) {
    . $harness
    $stub = $null
    try {
        $stub = New-SquadCliStubEnvironment
        Initialize-SquadCliStubRepository -Stub $stub | Out-Null

        $denied = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript `
            -CliArguments @("smoke", "--repo", "octo/demo") `
            -GhFailMode "notfound404" -GhFailPath "git/commits" `
            -GhPermissions "nopush" -GhLogin "read-only-bot"
        $deniedText = "$($denied.StdErr)`n$($denied.StdOut)"
        if ($denied.ExitCode -ne 0 -and
            $deniedText -match "has push=false on octo/demo" -and
            $deniedText -match "404 Not Found" -and
            $deniedText -match "read-only-bot") {
            Add-Pass "A lease write that fails with 404 names the gh identity and its missing push permission, and still exits $($denied.ExitCode) (the failure is diagnosed, not reclassified)"
        } else {
            Add-Fail "A 404 lease write no longer explains the push-permission cause (exit=$($denied.ExitCode)): $deniedText"
        }
        # The compute request must never happen: a diagnostic may not turn a
        # failed claim into a dispatch.
        if (@($denied.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count -eq 0) {
            Add-Pass "A failed lease claim still starts no execution, so the improved diagnostic did not weaken claim-before-compute"
        } else {
            Add-Fail "A failed lease claim started an execution; the 404 diagnosis changed the classification"
        }

        # The probe is a diagnostic, not a dependency. When it cannot answer,
        # the ORIGINAL failure must survive unchanged.
        $stubFallback = New-SquadCliStubEnvironment
        try {
            Initialize-SquadCliStubRepository -Stub $stubFallback | Out-Null
            $fallback = Invoke-SquadCliCapture -Stub $stubFallback -ScriptPath $cliScript `
                -CliArguments @("smoke", "--repo", "octo/demo") `
                -GhFailMode "notfound404" -GhFailPath "git/commits" -GhPermissions "fail"
            $fallbackText = "$($fallback.StdErr)`n$($fallback.StdOut)"
            if ($fallback.ExitCode -ne 0 -and
                $fallbackText -match "already gone or already terminal" -and
                $fallbackText -notmatch "push=false") {
                Add-Pass "When the permission probe itself fails, the original lease error is reported unchanged instead of being masked by the probe's error"
            } else {
                Add-Fail "The permission probe masked the real lease failure (exit=$($fallback.ExitCode)): $fallbackText"
            }
        } finally {
            Remove-SquadCliStubEnvironment -Stub $stubFallback
        }

        # doctor must verify push, not merely that `gh auth status` exited 0:
        # reporting "GitHub auth ok" for a read-only identity is what let this
        # reach a live run.
        $doctorOk = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("doctor")
        if ($doctorOk.StdOut -match "GitHub push\s+ok\s+octo-stub has push access to octo/demo") {
            Add-Pass "squad-aca doctor reports which gh identity is active and that it can push"
        } else {
            Add-Fail "squad-aca doctor no longer reports GitHub push access: $($doctorOk.StdOut)"
        }

        $doctorDenied = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("doctor") `
            -GhPush "false" -GhLogin "read-only-bot"
        if ($doctorDenied.StdOut -match "GitHub push\s+failed" -and
            $doctorDenied.StdOut -match "read-only-bot has push=false" -and
            $doctorDenied.StdOut -match "GitHub auth\s+ok") {
            Add-Pass "squad-aca doctor fails the push row for a read-only identity even though 'gh auth status' succeeds, which is the gap that let issue #22 reach a live run"
        } else {
            Add-Fail "squad-aca doctor still reports a read-only identity as healthy: $($doctorDenied.StdOut)"
        }

        $doctorUnknown = Invoke-SquadCliCapture -Stub $stub -ScriptPath $cliScript -CliArguments @("doctor") `
            -GhApiExitCode 1
        if ($doctorUnknown.StdOut -match "GitHub push\s+unknown") {
            Add-Pass "squad-aca doctor reports push access as 'unknown' when the permission read fails, rather than guessing either way"
        } else {
            Add-Fail "squad-aca doctor does not fail safe when the permission read fails: $($doctorUnknown.StdOut)"
        }
    } catch {
        Add-Fail "GitHub push-permission diagnosis checks threw: $($_.Exception.Message)"
    } finally {
        if ($stub) { Remove-SquadCliStubEnvironment -Stub $stub }
    }
}

# --- Operational invariants around the lease that only source can prove -----
# These three are cheap to state and expensive to lose. Each is a defect the
# reviewer found by reading, and each would otherwise be re-introducible with a
# one-line edit and no failing test.
$entrypointSh = Join-Path $RepoRoot "worker\entrypoint.sh"
if (Test-Path $entrypointSh) {
    $entryText = Get-Content -LiteralPath $entrypointSh -Raw
    # A heartbeat that fires ONCE is not a heartbeat. With a one-hour TTL, a
    # session running longer than that is swept as stale mid-flight and its
    # lease becomes re-claimable while the execution is still live.
    if ($entryText -match "squad_lease_heartbeat_loop" -and $entryText -match "SQUAD_LEASE_HEARTBEAT_SECONDS" -and $entryText -match "while\s+(true|:)") {
        Add-Pass "The worker heartbeat is PERIODIC (a background ticker), so a session outliving the lease TTL is not swept as stale mid-flight"
    } else {
        Add-Fail "worker/entrypoint.sh no longer runs a periodic heartbeat; a single beat plus a terminal write lets a long-running session's lease be reclaimed while it is still executing"
    }
}
$cliSource = Join-Path $RepoRoot "scripts\squad-aca.ps1"
if (Test-Path $cliSource) {
    $cliText = Get-Content -LiteralPath $cliSource -Raw
    # `Format-Table -AutoSize` sizes to the terminal, so the rightmost columns
    # vanish on a narrow window. The leases table has seven columns and the
    # runbook tells operators to read the last two.
    $bareAutoSize = @(
        Select-String -LiteralPath $cliSource -Pattern 'Format-Table\s+-AutoSize\s*$' -AllMatches
    )
    if ($bareAutoSize.Count -eq 0) {
        Add-Pass "No table in squad-aca.ps1 ends at 'Format-Table -AutoSize'; every one is piped through Out-String -Width so columns cannot silently vanish on a narrow terminal"
    } else {
        Add-Fail "squad-aca.ps1 has $($bareAutoSize.Count) bare 'Format-Table -AutoSize' table(s) at line(s) $(($bareAutoSize.LineNumber) -join ', '); trailing columns disappear on a narrow terminal"
    }
    # The `dispatched` write must not be able to throw AFTER compute has been
    # requested: a transient 429 would leave the lease `claimed`, and the user's
    # retry would then be told `repaired` and start a SECOND execution. Assert
    # the STRUCTURE rather than a marker comment: each write must sit inside its
    # own try, and that try must not release the lease (releasing would hand
    # live work to another dispatcher).
    $cliLines = @(Get-Content -LiteralPath $cliSource)
    $markLines = @(
        Select-String -LiteralPath $cliSource -Pattern 'Operation\s+"dispatched"' -AllMatches |
            ForEach-Object { $_.LineNumber }
    )
    $unguarded = @()
    foreach ($ln in $markLines) {
        $before = $cliLines[[Math]::Max(0, $ln - 3)..($ln - 2)] -join "`n"
        $after = $cliLines[$ln..[Math]::Min($cliLines.Count - 1, $ln + 3)] -join "`n"
        if ($before -notmatch 'try\s*\{' -or $after -notmatch '\}\s*catch' -or $after -match 'Operation\s+"release"') {
            $unguarded += $ln
        }
    }
    if ($markLines.Count -ge 2 -and $unguarded.Count -eq 0) {
        Add-Pass "All $($markLines.Count) 'dispatched' lease writes in squad-aca.ps1 sit inside a try that warns rather than throwing or releasing, so a fault after compute started cannot strand the lease as 'claimed'"
    } else {
        Add-Fail "Unguarded 'dispatched' lease write(s) in squad-aca.ps1 at line(s) $($unguarded -join ', ') (found $($markLines.Count) write(s)); a 429 there throws to the user after compute started, and the retry is told 'repaired' and starts a second execution"
    }
}

# ---------------------------------------------------------------------------
# 9e. Worker assertions must not depend on WHERE the repo is checked out
# ---------------------------------------------------------------------------
# worker/lib/parse-capabilities.js prefixes every error with the manifest path,
# so `assert_not_contains "$out" '2'` was really asserting something about the
# developer's home directory: the same commit failed from `~/verifys2` and
# passed from a digit-free path, with the parser behaving correctly both times
# (issue #17). A false negative on a security property is worse than no test at
# all, because it teaches people to distrust the suite.
#
# The suite now masks the manifest path it supplied and asserts against the
# message body. These two checks make going back to raw output a failing check
# here rather than a surprise on someone else's machine months later.
Write-Section "Environment-independent worker assertions"
$parseSuite = Join-Path $RepoRoot "worker\tests\test_parse_capabilities.sh"
if (-not (Test-Path $parseSuite)) {
    Add-Fail "worker/tests/test_parse_capabilities.sh is missing"
} else {
    $parseText = Get-Content -LiteralPath $parseSuite -Raw
    $coupled = @(Select-String -LiteralPath $parseSuite -Pattern '^\s*assert_not_contains\s+"\$out"' -AllMatches)
    if ($coupled.Count -eq 0) {
        Add-Pass "No absence assertion in test_parse_capabilities.sh runs against raw parser output; each uses the path-masked body, so a checkout path that happens to contain the needle cannot fail the suite (issue #17)"
    } else {
        Add-Fail "test_parse_capabilities.sh asserts absence against unmasked parser output at line(s) $(($coupled.LineNumber) -join ', '); the parser prefixes its errors with the manifest path, so those assertions depend on the checkout directory"
    }
    if ($parseText -match 'run_parser\(\)' -and $parseText -match '\$\{out//"\$manifest"/') {
        Add-Pass "test_parse_capabilities.sh masks the manifest path with a LITERAL (quoted) pattern, so a checkout path containing glob metacharacters cannot silently mis-mask and weaken an absence assertion"
    } else {
        Add-Fail "test_parse_capabilities.sh no longer masks the manifest path out of parser output; its absence assertions are coupled to the checkout location again"
    }
}

# ---------------------------------------------------------------------------
# 10. CLI golden gate is present AND automated
# ---------------------------------------------------------------------------
# scripts/tests/verify-cli-golden.ps1 is the only guard that compares the whole
# observable surface of `squad-aca` -- including stdout -- against a committed
# baseline. That is the exact regression class PR #9 was closed for. It is only
# a guard if CI runs it, so assert both halves: the goldens exist and cover
# every case, and the workflow actually invokes the script.
Write-Section "CLI golden gate"
$goldenScript = Join-Path $RepoRoot "scripts\tests\verify-cli-golden.ps1"
$caseFile = Join-Path $RepoRoot "scripts\tests\cli-capture-cases.ps1"
$goldenDir = Join-Path $RepoRoot "scripts\tests\golden\cli"
$workflowFile = Join-Path $RepoRoot ".github\workflows\worker-tests.yml"

if (-not (Test-Path $goldenScript)) {
    Add-Fail "scripts/tests/verify-cli-golden.ps1 is missing (no automated stdout regression gate)"
} elseif (-not (Test-Path $caseFile)) {
    Add-Fail "scripts/tests/cli-capture-cases.ps1 is missing (shared CLI capture matrix)"
} else {
    . $caseFile
    $goldenFiles = @()
    if (Test-Path $goldenDir) { $goldenFiles = @(Get-ChildItem -Path $goldenDir -Filter *.txt -File) }
    $caseIds = @($Cases | ForEach-Object { $_.Id })
    $missingGolden = @($caseIds | Where-Object { $goldenFiles.Name -notcontains "$_.txt" })
    if ($caseIds.Count -gt 0 -and $missingGolden.Count -eq 0 -and $goldenFiles.Count -eq $caseIds.Count) {
        Add-Pass "Every one of the $($caseIds.Count) CLI capture cases has a committed golden under scripts/tests/golden/cli"
    } else {
        Add-Fail "CLI goldens are out of sync with the capture matrix (cases=$($caseIds.Count), goldens=$($goldenFiles.Count), missing=$($missingGolden -join ', ')); regenerate with verify-cli-golden.ps1 -Update"
    }

    # A golden that records no stdout could never catch the PR #9 regression.
    $stopGolden = Join-Path $goldenDir "07-stop-byexec.txt"
    if ((Test-Path $stopGolden) -and ((Get-Content -LiteralPath $stopGolden -Raw) -match "### STDOUT\s*\r?\nSTUB-STOP-ACK")) {
        Add-Pass "The 'stop' golden records az stdout, so losing that output is a diff (PR #9 regression class)"
    } else {
        Add-Fail "The 'stop' golden does not record 'az containerapp job stop' stdout; the PR #9 regression class would pass unnoticed"
    }

    if (-not (Test-Path $workflowFile)) {
        Add-Fail ".github/workflows/worker-tests.yml is missing; the CLI golden gate has no automated runner"
    } else {
        $workflowText = Get-Content -LiteralPath $workflowFile -Raw
        if ($workflowText -match 'verify-cli-golden\.ps1') {
            Add-Pass "CI runs scripts/tests/verify-cli-golden.ps1, so a squad-aca stdout change fails a job (not just a manual tool)"
        } else {
            Add-Fail "No CI job runs scripts/tests/verify-cli-golden.ps1; the stdout regression guard would be developer-only again"
        }

        # Same principle for the one invariant that needs a real Linux shell.
        # The windows-latest job can only ever SKIP it (no WSL on GitHub's
        # Windows runners, and Git Bash has no setsid), so it has to run in the
        # ubuntu-latest job -- and that job must treat exit 77 as a failure,
        # because a skip is not a pass.
        if ($workflowText -match 'verify-launch-detachment\.ps1') {
            Add-Pass "CI runs scripts/tests/verify-launch-detachment.ps1, so a launch that stops detaching fails a job on a real Linux shell"
        } else {
            Add-Fail "No CI job runs scripts/tests/verify-launch-detachment.ps1; worker-launch detachment would be verified only on a developer's WSL box"
        }
        if ($workflowText -match '(?s)verify-launch-detachment\.ps1.{0,400}\brc\b.{0,200}\b77\b') {
            Add-Pass "The CI detachment step treats exit 77 (probe did not run) as a failure, not as a pass"
        } else {
            Add-Fail "The CI detachment step does not fail on exit 77; a runner that lost bash would report green while proving nothing"
        }
    }

    # The goldens are only a gate if they verify on a machine other than the one
    # that produced them. The first CI run of this gate failed because they did
    # not: timestamps rendered in the host time zone and `doctor` reported the
    # optional `squad` CLI as installed only because the capture machine had it.
    # Those are pinned in the harness now; assert the pins are still there, so
    # removing one is a failing check rather than a red CI run days later.
    if (-not (Test-Path $harness)) {
        Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing; the golden captures have no environment pins"
    } else {
        $harnessText = Get-Content -LiteralPath $harness -Raw

        if ($harnessText -notmatch '"startTime"\s*:\s*"[^"]*(?:Z|[+\-]\d{2}:\d{2})"') {
            Add-Pass "Stub execution fixtures use offset-free timestamps, so 'sessions' renders the same wall clock in every host time zone"
        } else {
            Add-Fail "A stub execution fixture carries a UTC offset in startTime; ConvertFrom-Json will render it in the host time zone and the sessions goldens stop being portable"
        }

        if ($harnessText -match 'DOTNET_SYSTEM_GLOBALIZATION_INVARIANT') {
            Add-Pass "CLI captures run under the invariant culture, so dates and numbers do not render in the capture machine's locale"
        } else {
            Add-Fail "The CLI capture child process no longer pins DOTNET_SYSTEM_GLOBALIZATION_INVARIANT; goldens would encode the capture machine's locale"
        }

        if ($harnessText -match 'squad\.cmd') {
            Add-Pass "The optional 'squad' CLI is stubbed onto PATH, so 'doctor' reports the same status on a machine that has it and one that does not"
        } else {
            Add-Fail "'squad' is no longer stubbed onto PATH; 'doctor' reports ok/optional depending on the host and re-pads every row of its table"
        }
    }
}

# ---------------------------------------------------------------------------
# Agent tool policy (issue #26, PRD #6)
# ---------------------------------------------------------------------------
# "Isolation is not authorization." Until this change every session ran Copilot
# with `--yolo` on an image that also set COPILOT_ALLOW_ALL=true, so REMOTE
# execution applied WEAKER policy than a developer's own machine. These checks
# exist so that regressing to that state fails a build rather than being noticed
# in an incident.
Write-Section "Agent tool policy"

$policyResolver = Join-Path $RepoRoot "worker\lib\agent-policy.js"
$policyLib      = Join-Path $RepoRoot "worker\lib\squad-policy.sh"
$entrypointPath = Join-Path $RepoRoot "worker\entrypoint.sh"
$workerDockerfile = Join-Path $RepoRoot "worker\Dockerfile"

if (-not (Test-Path $policyResolver)) { Add-Fail "worker/lib/agent-policy.js is missing; there is no shared policy resolver and each plane would decide for itself" }
if (-not (Test-Path $policyLib))      { Add-Fail "worker/lib/squad-policy.sh is missing; nothing applies the resolved policy" }

# --- 1. The blanket-allow switches are gone from every shipping path ---------
# Deliberately NOT a whole-repo grep: docs and this file must be able to name
# `--yolo` when explaining what was removed. The check is on the files that
# actually compose a command or an image.
$blanketTargets = @(
    @{ Path = $entrypointPath;   Name = "worker/entrypoint.sh" },
    @{ Path = $workerDockerfile; Name = "worker/Dockerfile" },
    @{ Path = (Join-Path $RepoRoot "scripts\deploy.ps1"); Name = "scripts/deploy.ps1" }
)
foreach ($t in $blanketTargets) {
    if (-not (Test-Path $t.Path)) { Add-Fail "$($t.Name) is missing"; continue }
    # Strip comment lines first: the point is what the file DOES, and every one
    # of these files explains the removal in prose that names the flag.
    $lines = Get-Content -LiteralPath $t.Path
    $code = @($lines | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($code -match '--yolo|--allow-all(?!-tools)|COPILOT_ALLOW_ALL\s*=\s*true') {
        Add-Fail "$($t.Name) still applies a blanket-allow switch (--yolo / --allow-all / COPILOT_ALLOW_ALL=true); remote execution would again be more permissive than local"
    } else {
        Add-Pass "$($t.Name) applies no blanket-allow switch"
    }
}

# `--yolo` used to be injected through the job template, which is the one place
# an operator could restore it without touching code. Omitting the line is not
# enough -- `az containerapp job update --set-env-vars` merges, so a previously
# deployed job would keep the old value forever. It must be explicitly cleared.
$deployText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\deploy.ps1") -Raw
if ($deployText -match '"SQUAD_COPILOT_FLAGS="') {
    Add-Pass "deploy.ps1 explicitly CLEARS SQUAD_COPILOT_FLAGS, so redeploying removes a previously baked-in --yolo (set-env-vars merges; omitting the line would not)"
} else {
    Add-Fail "deploy.ps1 does not clear SQUAD_COPILOT_FLAGS; an existing deployment would keep its old '--yolo ...' value through every redeploy"
}

# --- 2. The entrypoint uses the policy, and uses it safely -------------------
if (-not (Test-Path $entrypointPath)) {
    Add-Fail "worker/entrypoint.sh is missing"
} else {
    $entryText = Get-Content -LiteralPath $entrypointPath -Raw

    # Every `copilot` invocation must expand the ARRAY. An unquoted string
    # expansion word-splits `shell(git config)` into two arguments, which both
    # destroys the rule and changes what the next token means -- and it would
    # still look correct in a diff.
    $copilotCalls = @(Get-Content -LiteralPath $entrypointPath | Where-Object { $_ -match '^\s*copilot\s+-p' })
    $badCalls = @($copilotCalls | Where-Object { $_ -notmatch '"\$\{COPILOT_ARGV\[@\]\}"' })
    if ($copilotCalls.Count -gt 0 -and $badCalls.Count -eq 0) {
        Add-Pass "All $($copilotCalls.Count) direct 'copilot -p' invocations expand `"`${COPILOT_ARGV[@]}`", so a multi-word deny pattern stays one argument"
    } else {
        Add-Fail "A 'copilot -p' invocation does not expand the policy argv array (found $($badCalls.Count) of $($copilotCalls.Count)); word-splitting would silently drop every multi-word deny rule"
    }

    # The policy must be applied before anything runs an agent, and a missing
    # library must abort rather than fall through to an unpoliced session.
    if ($entryText -match '(?s)if \[\[ ! -f "\$SQUAD_POLICY_LIB" \]\].{0,400}exit 78') {
        Add-Pass "A missing policy library aborts the session (exit 78) instead of running unpoliced"
    } else {
        Add-Fail "worker/entrypoint.sh does not abort when the policy library is absent; the session would run with no tool policy at all"
    }

    # The governance verdict must gate the push. A check that runs after the
    # push protects nothing.
    if ($entryText -match '(?s)commit_and_push_if_needed\(\)\s*\{\s*(#[^\n]*\n\s*)*squad_policy_checkpoint') {
        Add-Pass "commit_and_push_if_needed verifies governance integrity BEFORE it can push, so a rewrite never reaches the remote"
    } else {
        Add-Fail "commit_and_push_if_needed does not verify governance integrity first; a governance rewrite could be pushed before anything noticed"
    }

    # Every mode that runs an agent must reach a checkpoint, or a non-pushing
    # session would report success after rewriting a policy file.
    $agentModes = @('smoke', 'prompt', 'loop', 'ralph', 'watch|triage', 'new-project', 'telemetry-smoke')
    $checkpointCount = ([regex]::Matches($entryText, 'squad_policy_checkpoint')).Count
    if ($checkpointCount -ge ($agentModes.Count + 1)) {
        Add-Pass "The governance checkpoint is reached from every agent-running mode and from the push path ($checkpointCount call sites)"
    } else {
        Add-Fail "Only $checkpointCount squad_policy_checkpoint call sites; at least $($agentModes.Count + 1) are needed for every agent-running mode plus the push path"
    }
}

# --- 3. The Dockerfile actually ships the policy files -----------------------
# A resolver that is not in the image is a resolver that aborts every session.
if (-not (Test-Path $workerDockerfile)) {
    Add-Fail "worker/Dockerfile is missing"
} else {
    $dockerText = Get-Content -LiteralPath $workerDockerfile -Raw
    foreach ($f in @('lib/agent-policy.js', 'lib/squad-policy.sh')) {
        if ($dockerText -match [regex]::Escape($f)) {
            Add-Pass "worker/Dockerfile ships $f into the image"
        } else {
            Add-Fail "worker/Dockerfile does not ship $f; every session would abort at policy resolution"
        }
    }
    if ($dockerText -match 'sed -i[^\n]*\\r[^\n]*squad-policy\.sh') {
        Add-Pass "worker/Dockerfile CRLF-strips squad-policy.sh like every other shipped shell script"
    } else {
        Add-Fail "worker/Dockerfile does not CRLF-strip squad-policy.sh; a Windows checkout would produce an unsourceable policy library"
    }
}

# --- 4. Local / remote parity, driven through the REAL env builders ----------
# This is the PRD requirement itself: "Local and sandbox execution must apply the
# same policy semantics so changing execution substrate cannot escalate
# privilege." Asserting it on hand-written env maps would prove nothing about the
# product, so both maps are produced by the functions each plane actually uses,
# then fed to the same resolver.
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Add-Skip "Cross-plane policy parity is UNVERIFIED: node is not on PATH"
} elseif (-not (Test-Path $policyResolver)) {
    Add-Fail "Cross-plane policy parity cannot be checked: worker/lib/agent-policy.js is missing"
} else {
    function Get-PolicyJsonFor {
        param([hashtable]$EnvMap)
        $prev = @{}
        foreach ($k in @('SQUAD_MODE', 'SQUAD_DISPATCH_SOURCE', 'SQUAD_EXECUTION_MODE', 'SQUAD_COPILOT_FLAGS', 'ENABLE_GITHUB_REMOTE')) {
            $prev[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $null)
        }
        foreach ($k in $EnvMap.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$EnvMap[$k]) }
        try { $out = (& node $policyResolver json 2>&1 | Out-String) } finally {
            foreach ($k in $prev.Keys) { [Environment]::SetEnvironmentVariable($k, $prev[$k]) }
        }
        return $out
    }

    # The dispatch source the ACA Jobs plane stamps must also reach the sandbox
    # plane's worker environment, or a Ralph-dispatched session would get the
    # strict tier remotely and the permissive one in a sandbox.
    $sandboxProviderText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\lib\providers\squad-sandbox-provider.ps1") -Raw
    if ($sandboxProviderText -match 'SQUAD_DISPATCH_SOURCE\s*=\s*\[string\]\$Request\.dispatchSource') {
        Add-Pass "The sandbox worker environment carries SQUAD_DISPATCH_SOURCE, so who started a run is known on both planes"
    } else {
        Add-Fail "New-SandboxWorkerEnvironment does not carry SQUAD_DISPATCH_SOURCE; a ralph-dispatched sandbox session would resolve to the ATTENDED tier -- escalation by choosing a substrate"
    }

    $parityMismatch = @()
    foreach ($case in @(
        @{ Mode = 'prompt'; Source = 'local-cli' },
        @{ Mode = 'prompt'; Source = 'ralph' },
        @{ Mode = 'ralph';  Source = 'ralph' },
        @{ Mode = 'watch';  Source = 'watch' },
        @{ Mode = 'loop';   Source = 'watch' },
        @{ Mode = 'smoke';  Source = 'local-cli' }
    )) {
        $acaJson = Get-PolicyJsonFor @{ SQUAD_MODE = $case.Mode; SQUAD_DISPATCH_SOURCE = $case.Source; SQUAD_EXECUTION_MODE = '' }
        $sbxJson = Get-PolicyJsonFor @{ SQUAD_MODE = $case.Mode; SQUAD_DISPATCH_SOURCE = $case.Source; SQUAD_EXECUTION_MODE = 'sandbox' }
        # executionPlane is reported, not acted on; everything else must match.
        $a = $acaJson -replace '"executionPlane":\s*"[^"]*"', '"executionPlane": "X"'
        $b = $sbxJson -replace '"executionPlane":\s*"[^"]*"', '"executionPlane": "X"'
        if ($a -ne $b) { $parityMismatch += "$($case.Mode)/$($case.Source)" }
    }
    if ($parityMismatch.Count -eq 0) {
        Add-Pass "ACA Jobs and sandbox execution resolve to an identical policy for all 6 mode/source pairs; changing substrate cannot escalate privilege"
    } else {
        Add-Fail "Policy differs between the ACA Jobs and sandbox planes for: $($parityMismatch -join ', ') -- changing execution substrate escalates privilege"
    }

    # An unattended dispatch must get the strict tier, and it must actually be
    # stricter -- equal tiers would pass a naive "tiers exist" check.
    $attJson = Get-PolicyJsonFor @{ SQUAD_MODE = 'prompt'; SQUAD_DISPATCH_SOURCE = 'local-cli' }
    $autJson = Get-PolicyJsonFor @{ SQUAD_MODE = 'ralph';  SQUAD_DISPATCH_SOURCE = 'ralph' }
    $att = $attJson | ConvertFrom-Json
    $aut = $autJson | ConvertFrom-Json
    if ($att.tier -eq 'attended' -and $aut.tier -eq 'autonomous') {
        Add-Pass "An attended dispatch resolves to the 'attended' tier and an unattended one to 'autonomous'"
    } else {
        Add-Fail "Tier selection is wrong: attended dispatch -> '$($att.tier)', unattended dispatch -> '$($aut.tier)'"
    }
    $extraDenied = @($aut.denyTools | Where-Object { $att.denyTools -notcontains $_ })
    $lostDenied = @($att.denyTools | Where-Object { $aut.denyTools -notcontains $_ })
    if ($extraDenied.Count -gt 0 -and $lostDenied.Count -eq 0) {
        Add-Pass "The autonomous tier is strictly stricter: it denies $($extraDenied.Count) additional tools and drops none of the attended denials"
    } else {
        Add-Fail "The autonomous tier is not strictly stricter than the attended one (extra denials: $($extraDenied.Count), denials lost: $($lostDenied.Count))"
    }

    # Fail closed: an attempt to widen permission through the environment must
    # abort with EX_CONFIG, not be silently ignored and not be applied.
    $prevFlags = [Environment]::GetEnvironmentVariable('SQUAD_COPILOT_FLAGS')
    foreach ($bad in @('--yolo', '--allow-all', '--allow-all-paths', '--add-dir /etc')) {
        [Environment]::SetEnvironmentVariable('SQUAD_MODE', 'ralph')
        [Environment]::SetEnvironmentVariable('SQUAD_DISPATCH_SOURCE', 'ralph')
        [Environment]::SetEnvironmentVariable('SQUAD_COPILOT_FLAGS', $bad)
        $null = (& node $policyResolver flags 2>&1)
        $rc = $LASTEXITCODE
        if ($rc -eq 78) {
            Add-Pass "SQUAD_COPILOT_FLAGS='$bad' aborts policy resolution (exit 78) rather than widening the session"
        } else {
            Add-Fail "SQUAD_COPILOT_FLAGS='$bad' did not abort (exit $rc); permission could be widened from the job template"
        }
    }
    [Environment]::SetEnvironmentVariable('SQUAD_COPILOT_FLAGS', $prevFlags)
    [Environment]::SetEnvironmentVariable('SQUAD_MODE', $null)
    [Environment]::SetEnvironmentVariable('SQUAD_DISPATCH_SOURCE', $null)
}

# --- 5. The new suites are wired into CI ------------------------------------
# A test nobody runs is documentation.
$workerWorkflow = Join-Path $RepoRoot ".github\workflows\worker-tests.yml"
if (-not (Test-Path $workerWorkflow)) {
    Add-Fail ".github/workflows/worker-tests.yml is missing; the policy suites have no automated runner"
} else {
    $wfText = Get-Content -LiteralPath $workerWorkflow -Raw
    if ($wfText -match 'worker/tests/run-tests\.sh') {
        Add-Pass "CI runs worker/tests/run-tests.sh, which auto-discovers the agent-policy and governance-guard suites"
    } else {
        Add-Fail "No CI job runs worker/tests/run-tests.sh; the policy enforcement suites would be developer-only"
    }
}
foreach ($suite in @('worker\tests\test_agent_policy.sh', 'worker\tests\test_governance_guard.sh', 'worker\tests\test_squad_hub.sh')) {
    if (Test-Path (Join-Path $RepoRoot $suite)) {
        Add-Pass "$($suite -replace '\\','/') exists"
    } else {
        Add-Fail "$($suite -replace '\\','/') is missing; the policy controls have no behavioural coverage"
    }
}

# --- 5b. Squad Hub supervision is a TIGHTENING, or it is not shipped ---------
# A hub lets a session ask a human instead of having destructive operations
# made unavailable outright. That is only acceptable while three things hold,
# and each is checked here as well as in worker/tests/test_squad_hub.sh --
# because this file is the gate that runs before a deploy.
$hubLib = Join-Path $RepoRoot "worker\lib\squad-hub.sh"
if (-not (Test-Path $hubLib)) {
    Add-Fail "worker/lib/squad-hub.sh is missing; a hub-configured session would have no supervision path"
} else {
    $hubText = Get-Content -LiteralPath $hubLib -Raw

    # 1. It must never fall back to the unsupervised path.
    if ($hubText -match 'must not' -and $hubText -match 'blanket tool approval') {
        Add-Pass "squad-hub.sh refuses rather than falling back to unsupervised blanket tool approval"
    } else {
        Add-Fail "squad-hub.sh does not state (or enforce) the no-fallback rule; a hub outage could silently downgrade a supervised session"
    }

    # 2. It must refuse a credential that is not a device token.
    if ($hubText -match 'sqhd1\.') {
        Add-Pass "squad-hub.sh refuses a credential that is not a device token"
    } else {
        Add-Fail "squad-hub.sh does not check the device-token prefix; a personal credential could be shipped to a job"
    }

    # 3. It must refuse a hub argv that still carries --allow-all-tools.
    if ($hubText -match '--allow-all-tools') {
        Add-Pass "squad-hub.sh guards against --allow-all-tools surviving onto the hub path"
    } else {
        Add-Fail "squad-hub.sh has no --allow-all-tools guard; supervision could raise no approval cards at all"
    }
}

# The resolver's hub variant: same policy, minus exactly one flag.
if ($nodeCmd -and (Test-Path $policyResolver)) {
    $prevMode = [Environment]::GetEnvironmentVariable('SQUAD_MODE')
    $prevSrc = [Environment]::GetEnvironmentVariable('SQUAD_DISPATCH_SOURCE')
    [Environment]::SetEnvironmentVariable('SQUAD_MODE', 'prompt')
    [Environment]::SetEnvironmentVariable('SQUAD_DISPATCH_SOURCE', 'ralph')
    $hubArgv = (& node $policyResolver hub-argv-json 2>&1) -join "`n"
    [Environment]::SetEnvironmentVariable('SQUAD_MODE', $prevMode)
    [Environment]::SetEnvironmentVariable('SQUAD_DISPATCH_SOURCE', $prevSrc)

    if ($hubArgv -match '"--allow-all-tools"') {
        Add-Fail "The hub argv still contains --allow-all-tools; a supervised session would auto-approve everything and raise no cards"
    } else {
        Add-Pass "The hub argv drops --allow-all-tools, so a supervised session actually asks"
    }
    # The hard floor. Measured against Copilot CLI 1.0.78 over ACP, a denied
    # tool raises NO permission request at all -- so these patterns are what
    # keeps a human at the hub from being able to approve something forbidden.
    if ($hubArgv -match '"--deny-tool"') {
        Add-Pass "The hub argv keeps the deny list, which a human at the hub cannot override"
    } else {
        Add-Fail "The hub argv carries no deny rules; supervision would be the only control left"
    }
    # The multi-word patterns are why the channel is JSON rather than a string.
    if ($hubArgv -match '"shell\(git config\)"') {
        Add-Pass "A multi-word deny pattern survives into the hub argv as one argument"
    } else {
        Add-Fail "A multi-word deny pattern did not survive into the hub argv; the policy would be torn in transport"
    }
}

# deploy.ps1 must set BOTH hub variables on every deploy, empty when off.
# `--set-env-vars` merges, so omitting them would leave a stale URL and a
# revoked token on an existing job forever -- the same trap SQUAD_COPILOT_FLAGS
# is cleared to avoid.
if ($deployText -match '"SQUAD_HUB_URL=') {
    Add-Pass "deploy.ps1 always sets SQUAD_HUB_URL, so turning supervision off actually removes it"
} else {
    Add-Fail "deploy.ps1 does not set SQUAD_HUB_URL; a previously configured hub would survive every redeploy"
}
if ($deployText -match 'secretref:squad-hub-token') {
    Add-Pass "deploy.ps1 passes the hub device token by secret reference, never as a literal env var"
} else {
    Add-Fail "deploy.ps1 does not reference the hub token as a secret; a credential would sit in the job template"
}
if ($deployText -match 'sqhd1\.') {
    Add-Pass "deploy.ps1 refuses a hub credential that is not a device token, at the desk rather than in a container"
} else {
    Add-Fail "deploy.ps1 does not preflight the hub token; a personal credential could be deployed to a job"
}

# The session identity's grant must stay narrow.
#
# It held `Contributor` on the resource group while needing exactly two calls
# against one job. That matters because the holder is an agent running a prompt
# and the deny list does not cover `curl`, so the instance metadata endpoint --
# and therefore this identity -- is reachable from inside a session. A scope
# that quietly widens again is precisely the thing nobody notices, so it is
# asserted rather than trusted to review.
if ($deployText -match '--role Contributor --scope \$resourceGroupId') {
    Add-Fail "deploy.ps1 grants the session identity Contributor on the whole resource group; it needs only Container Apps Jobs Operator on the session job"
} else {
    Add-Pass "deploy.ps1 does not grant the session identity Contributor on the resource group"
}
if ($deployText -match '(?s)Granting Container Apps Jobs Operator on \$jobName to') {
    Add-Pass "deploy.ps1 grants the session identity Container Apps Jobs Operator scoped to the single session job"
} else {
    Add-Fail "deploy.ps1 does not grant the session identity a job-scoped role; it would be unable to start a session"
}
if ($deployText -match 'Removing the old resource-group Contributor grant') {
    Add-Pass "deploy.ps1 removes a previously granted resource-group Contributor, so already-deployed environments are narrowed too"
} else {
    Add-Fail "deploy.ps1 does not remove an existing Contributor grant; environments deployed before the change would keep it forever"
}

# --- 6. Governance paths cover what the PRD names ---------------------------
if ($nodeCmd -and (Test-Path $policyResolver)) {
    $govOut = (& node $policyResolver governance-paths 2>&1) -join "`n"
    $required = @('.squad/policies', '.squad/agents', '.squad/identity', '.squad/config.json', '.squad/routing.md')
    $missingGov = @($required | Where-Object { $govOut -notmatch [regex]::Escape($_) })
    if ($missingGov.Count -eq 0) {
        Add-Pass "Every governance path PRD #6 names is protected (.squad/policies, .squad/agents, .squad/identity, .squad/config.json, .squad/routing.md)"
    } else {
        Add-Fail "Governance protection is missing PRD #6 paths: $($missingGov -join ', ')"
    }
    if ($govOut -match 'audit') {
        Add-Pass "Audit/approval state is included in the protected set"
    } else {
        Add-Fail "No audit state is protected; PRD #6 names approval/audit state explicitly"
    }
}

# --- 7. The append-only exclusion is narrow, and is still detected -----------
# `.squad/agents/<name>/history.md` is excluded from the WRITE LOCK because it is
# an append-only work log, not policy: locking it prevented no escalation and
# destroyed the audit trail PRD #6 asks for. The exclusion is only safe while it
# stays anchored at both ends and stays inside the integrity check, so both
# properties are asserted here against the REAL resolver rather than described.
if ($nodeCmd -and (Test-Path $policyResolver)) {
    function Get-GovernanceClass {
        param([string]$Path)
        return ((& node $policyResolver classify-governance-path $Path 2>&1) -join '').Trim()
    }

    # The thing the narrowing exists to allow.
    if ((Get-GovernanceClass '.squad/agents/security/history.md') -eq 'append-only') {
        Add-Pass "An agent history file is classified append-only, so an autonomous run can record what it did"
    } else {
        Add-Fail "An agent history file is not classified append-only; autonomous runs cannot write .squad/agents/<name>/history.md and the audit trail is lost"
    }

    # The thing it must NOT allow. A charter states what an agent is permitted to
    # do; an agent that can rewrite its charter has rewritten its authorisation.
    $mustStayLocked = @(
        @{ Path = '.squad/agents/security/charter.md';     Why = 'a charter defines what an agent is permitted to do' },
        @{ Path = '.squad/agents/security/history.md.bak'; Why = 'a lookalike filename must not inherit the exclusion' },
        @{ Path = '.squad/agents/history.md';              Why = 'the exclusion is anchored to <name>/history.md, not anything named history.md under .squad/agents' },
        @{ Path = '.squad/agents/a/b/history.md';          Why = 'exactly one path segment may stand for the agent name' },
        @{ Path = '.squad/policies/history.md';            Why = 'the exclusion is scoped to .squad/agents' },
        @{ Path = '.squad/identity/identity.md';           Why = 'identity is governance' },
        @{ Path = '.squad/config.json';                    Why = 'config is governance' },
        @{ Path = '.squad/routing.md';                     Why = 'routing is governance' },
        @{ Path = '.squad/memory/audit.jsonl';             Why = 'audit state is governance' }
    )
    $leaked = @($mustStayLocked | Where-Object { (Get-GovernanceClass $_.Path) -ne 'locked' })
    if ($leaked.Count -eq 0) {
        Add-Pass "The append-only exclusion is anchored: all $($mustStayLocked.Count) neighbouring governance paths -- charter.md included -- stay locked"
    } else {
        Add-Fail "The append-only exclusion is too wide; these should be locked but are not: $(($leaked | ForEach-Object { "$($_.Path) ($($_.Why))" }) -join '; ')"
    }

    # Widening the pattern to `.squad/agents/**` is the specific regression this
    # guards against, so assert it on the pattern itself as well as on the
    # classification -- a pattern that stopped anchoring the filename would fail
    # here even if someone also loosened the cases above.
    $patterns = @((& node $policyResolver mutable-governance-patterns 2>&1) | Where-Object { $_ -match '\S' })
    $unanchored = @($patterns | Where-Object { $_ -notmatch 'history' -or $_ -notmatch '\$$' -or $_ -notmatch '\^' })
    if ($patterns.Count -ge 1 -and $unanchored.Count -eq 0) {
        Add-Pass "Every append-only pattern is fully anchored and filename-specific ($($patterns -join ', '))"
    } else {
        Add-Fail "An append-only pattern is unanchored or not filename-specific: $($unanchored -join ', '); a wildcard here re-opens charter.md"
    }
}

# --- 8. Excluded from the LOCK is not excluded from the DETECTOR -------------
# A path that neither layer covers is a foothold: whoever can write there writes
# invisibly. These are structural checks on the enforcement library, because the
# behavioural proof lives in worker/tests/test_governance_guard.sh (which cannot
# run on Windows).
if (Test-Path $policyLib) {
    $libText = Get-Content -LiteralPath $policyLib -Raw

    if ($libText -match [regex]::Escape("printf 'append-only %s %s %s")) {
        Add-Pass "The manifest records excluded paths under an 'append-only' rule rather than dropping them, so an operator can still see what changed and by how much"
    } else {
        Add-Fail "The manifest does not record append-only entries; an excluded path would be invisible to both the lock and the integrity check"
    }

    # The prefix hash IS the append-only control. Without it the entry is a
    # comment: the file could be truncated or rewritten and still 'match'.
    if ($libText -match 'squad_policy_prefix_sha' -and $libText -match 'head -c "\$bytes"') {
        Add-Pass "Append-only is enforced by re-hashing the baseline byte prefix, so a truncation or a rewrite of existing history fails the session"
    } else {
        Add-Fail "There is no prefix-hash check; 'append-only' would be an unenforced label and an agent could rewrite its own work log"
    }

    # ORDERING IS THE CONTROL. The recursive lock must run first and the file
    # unlock second: `chmod` on a file needs ownership, not parent write, so
    # this ordering is what keeps the DIRECTORY locked against create/delete
    # while the file inside it is writable. Reversed, or expressed as an
    # exclusion from the recursive chmod, the directory would have to be
    # writable and the exclusion would open the whole agent directory.
    $lockIdx   = $libText.IndexOf('chmod -R a-w')
    $unlockIdx = $libText.IndexOf('SQUAD_POLICY_UNLOCKED_FILES=()')
    if ($lockIdx -ge 0 -and $unlockIdx -gt $lockIdx) {
        Add-Pass "Hardening locks every governance path recursively FIRST and re-opens only the append-only files afterwards, so their directories still refuse create and delete"
    } else {
        Add-Fail "The append-only files are unlocked before or instead of the recursive lock; the containing agent directory would become writable and new files could be added beside a locked charter"
    }

    if ($libText -match 'git diff --name-only "\$base_commit" HEAD') {
        Add-Pass "The committed form of an append-only path is prefix-checked too, so a truncation cannot be committed and then hidden by restoring the working tree"
    } else {
        Add-Fail "The commit detector does not check the committed form of append-only paths; a history rewrite could be committed, hidden in the working tree, and pushed"
    }
}

# ---------------------------------------------------------------------------
# Image evidence: a class may only claim tools its PINNED IMAGE actually has
# ---------------------------------------------------------------------------
# PR #28 pinned both approved classes to the same squad-worker digest without
# checking the tool claims. sandbox-node-lts claimed jq, make and pnpm;
# sandbox-python-3-12 claimed python3, pip3, jq and make. The image had none of
# them. A live session routed correctly to the Python class, created the
# sandbox, applied egress and launched the worker -- and then the in-worker
# preflight refused to run, because the tools were not there. Defence in depth
# worked; the catalog should not have lied in the first place.
#
# The check below is the OFFLINE half. It cannot pull a private ACR image, so it
# proves that evidence EXISTS for exactly the digest pinned today, was recorded
# for the same image repository, and covers every declared tool. Producing the
# evidence needs a live run (scripts/verify-image-tools.ps1). That boundary is
# stated in docs/capability-manifest.md and is not papered over here: CI does
# not claim to have seen inside the image.
Write-Section "Image evidence backs every approved class's tool claims"
$evidenceVerifier = Join-Path $RepoRoot "worker\lib\verify-image-evidence.js"
$shippedCatalogFile = Join-Path $RepoRoot "config\sandbox-classes.json"
$shippedEvidenceDir = Join-Path $RepoRoot "config\image-evidence"
if (-not (Test-Path $evidenceVerifier)) {
    Add-Fail "worker/lib/verify-image-evidence.js is missing: nothing compares a class's tool claims with its pinned image"
} elseif (-not $nodeAvailable) {
    Add-Skip "Image evidence checks require node on PATH"
} else {
    $evidenceTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("squad-evidence-" + [Guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $evidenceTmp -Force | Out-Null

        function Invoke-EvidenceVerifier {
            param([string]$Catalog, [string]$EvidenceDir)
            $previousEap = $ErrorActionPreference
            $out = @()
            $code = -1
            try {
                $ErrorActionPreference = "Continue"
                $out = & node $evidenceVerifier --catalog $Catalog --evidence-dir $EvidenceDir 2>&1
                $code = $LASTEXITCODE
            } catch {
                $out = @($_.Exception.Message)
                $code = 127
            } finally {
                $ErrorActionPreference = $previousEap
            }
            return [pscustomobject]@{
                ExitCode = $code
                Output   = (@($out | ForEach-Object { [string]$_ }) -join "`n")
            }
        }

        # --- 1. The file that SHIPS is backed -------------------------------
        $shipped = Invoke-EvidenceVerifier -Catalog $shippedCatalogFile -EvidenceDir $shippedEvidenceDir
        if ($shipped.ExitCode -eq 0) {
            Add-Pass "Every approved class in the shipped catalog claims only tools its pinned image was observed to provide"
        } else {
            Add-Fail "The shipped catalog claims tools its pinned images were not observed to provide (exit $($shipped.ExitCode)): $($shipped.Output)"
        }

        $catalogObject = Get-Content $shippedCatalogFile -Raw | ConvertFrom-Json
        $approvedClasses = @($catalogObject.classes | Where-Object { $_.approved -eq $true })

        # --- 2. Over-claiming a single tool must FAIL -----------------------
        # The mutation this check exists to catch is the original defect,
        # applied to the real file.
        $overClaim = Join-Path $evidenceTmp "over-claim.json"
        $mutated = Get-Content $shippedCatalogFile -Raw | ConvertFrom-Json
        $target = @($mutated.classes | Where-Object { $_.approved -eq $true })[0]
        $target.tools = @($target.tools) + @("definitely-not-in-the-image")
        ($mutated | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $overClaim -Encoding UTF8
        $r = Invoke-EvidenceVerifier -Catalog $overClaim -EvidenceDir $shippedEvidenceDir
        if ($r.ExitCode -ne 0 -and $r.Output -match "definitely-not-in-the-image") {
            Add-Pass "A class that claims one tool its evidence does not record is refused, and the unbacked claim is named"
        } else {
            Add-Fail "An over-claiming class was accepted (exit $($r.ExitCode)): $($r.Output)"
        }

        # --- 3. Re-pinning without re-verifying must FAIL -------------------
        # Evidence is keyed by DIGEST precisely so this cannot slide through.
        $rePinned = Join-Path $evidenceTmp "re-pinned.json"
        $mutated = Get-Content $shippedCatalogFile -Raw | ConvertFrom-Json
        $target = @($mutated.classes | Where-Object { $_.approved -eq $true })[0]
        $target.image.digest = "sha256:" + ("c" * 64)
        ($mutated | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $rePinned -Encoding UTF8
        $r = Invoke-EvidenceVerifier -Catalog $rePinned -EvidenceDir $shippedEvidenceDir
        if ($r.ExitCode -ne 0 -and $r.Output -match "no image evidence recorded for the pinned digest") {
            Add-Pass "Re-pinning an approved class to a digest nobody probed fails, because evidence is keyed by digest"
        } else {
            Add-Fail "A re-pinned class with no evidence for the new digest was accepted (exit $($r.ExitCode)): $($r.Output)"
        }

        # --- 4. Missing evidence is a FAILURE, never a skip -----------------
        $emptyEvidence = Join-Path $evidenceTmp "no-evidence"
        New-Item -ItemType Directory -Path $emptyEvidence -Force | Out-Null
        $r = Invoke-EvidenceVerifier -Catalog $shippedCatalogFile -EvidenceDir $emptyEvidence
        if ($r.ExitCode -ne 0) {
            Add-Pass "An approved, pinned class with no evidence file at all is a failure, not a silent pass"
        } else {
            Add-Fail "The evidence check passed with an empty evidence directory -- a check that passes without its input is not a check"
        }

        # --- 5. The two approved classes pin DIFFERENT images ---------------
        # One image behind both classes is what made the false claims possible:
        # whatever the second class needed, the first class's image decided.
        $digests = @($approvedClasses | ForEach-Object { [string]$_.image.digest })
        $distinct = @($digests | Sort-Object -Unique)
        if ($approvedClasses.Count -ge 2 -and $distinct.Count -eq $approvedClasses.Count) {
            Add-Pass "Each approved class pins its own image digest, so a per-language class is a real image and not a relabelled one"
        } else {
            Add-Fail "Approved classes share an image digest (classes=$($approvedClasses.Count) distinct digests=$($distinct.Count)); a class's tools list would again be a label rather than an inventory"
        }

        # --- 6. The python class actually provides Python -------------------
        # The acceptance criterion the live run failed on. Asserted against the
        # committed evidence for the digest the class pins today.
        $pyClass = @($catalogObject.classes | Where-Object { $_.id -eq "sandbox-python-3-12" })[0]
        if (-not $pyClass) {
            Add-Fail "sandbox-python-3-12 is missing from the shipped catalog"
        } else {
            $evidenceFile = Join-Path $shippedEvidenceDir ((([string]$pyClass.image.digest) -replace ':', '-') + ".json")
            if (-not (Test-Path $evidenceFile)) {
                Add-Fail "No evidence file for sandbox-python-3-12's pinned digest: $evidenceFile"
            } else {
                $pyEvidence = Get-Content $evidenceFile -Raw | ConvertFrom-Json
                $present = @($pyEvidence.tools.present)
                if ($present -contains "python3" -and $present -contains "pip3") {
                    Add-Pass "sandbox-python-3-12's pinned image was observed to provide python3 and pip3 -- the two tools the live preflight refused a session over"
                } else {
                    Add-Fail "sandbox-python-3-12's evidence does not record python3 and pip3 as present: $($present -join ', ')"
                }
            }
        }

        # --- 7. The preflight is NOT weakened by any of this ----------------
        # The evidence model stops the catalog making a claim the preflight has
        # to refuse. It must never become a reason to skip the preflight.
        $preflightPath = Join-Path $RepoRoot "worker\lib\squad-capability-preflight.sh"
        $entrypointPath = Join-Path $RepoRoot "worker\entrypoint.sh"
        if ((Test-Path $preflightPath) -and (Test-Path $entrypointPath)) {
            $entrypointText = Get-Content $entrypointPath -Raw
            $bypassPattern = '(?im)^\s*(if|\[\[).*(catalog|evidence|sandboxClass).*(skip|bypass).*preflight'
            if (($entrypointText -match 'squad-capability-preflight\.sh') -and ($entrypointText -notmatch $bypassPattern)) {
                Add-Pass "The worker entrypoint still runs the capability preflight, with no 'the catalog says so, skip it' path"
            } else {
                Add-Fail "The in-worker capability preflight is no longer unconditionally invoked by the worker entrypoint"
            }
        } else {
            Add-Fail "worker/entrypoint.sh or worker/lib/squad-capability-preflight.sh is missing"
        }
    } catch {
        Add-Fail "Image evidence checks threw: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $evidenceTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# The Actions trigger surface (issue #32 S2)
# ---------------------------------------------------------------------------
Write-Section "The Actions trigger is a transport, not a second control plane"

$dispatchWorkflow = Join-Path $RepoRoot '.github/workflows/squad-dispatch.yml'
if (-not (Test-Path $dispatchWorkflow)) {
    Add-Fail "The Actions dispatch workflow (.github/workflows/squad-dispatch.yml) is missing, so nothing triggers a session from a GitHub event"
} else {
    $wf = Get-Content -LiteralPath $dispatchWorkflow -Raw

    # OIDC is the whole reason this path needs no stored Azure credential. A
    # workflow that fell back to a client secret would still work, which is
    # exactly why the absence has to be asserted rather than assumed.
    if ($wf -match '(?m)^\s*id-token:\s*write\b') {
        Add-Pass "The dispatch workflow requests id-token: write, so it can federate to Azure without a stored credential"
    } else {
        Add-Fail "The dispatch workflow does not request id-token: write, so OIDC federation cannot work"
    }

    if ($wf -match 'client-secret|AZURE_CLIENT_SECRET|creds:\s*\$\{\{\s*secrets') {
        Add-Fail "The dispatch workflow references an Azure client secret. The federated path exists so no long-lived Azure credential is stored in GitHub"
    } else {
        Add-Pass "The dispatch workflow stores NO Azure client secret -- the only Azure credential is the federated token minted per run"
    }

    # pull_request_target runs with a writable token in the context of the BASE
    # repository while checking out attacker-controlled code. On a public
    # repository with a dispatch trigger that is a direct path to running a
    # fork's code with the App's permissions.
    if ($wf -match '(?m)^\s*pull_request_target\s*:') {
        Add-Fail "The dispatch workflow triggers on pull_request_target, which would run fork-controlled code with this repository's credentials"
    } else {
        Add-Pass "The dispatch workflow does NOT trigger on pull_request_target, so a fork cannot reach the control plane"
    }

    # The shared decision core is the only thing that keeps Ralph's poll and an
    # Actions trigger from starting the same work twice. A workflow that
    # invented its own lease key would look identical in the logs and dispatch
    # in parallel.
    if ($wf -match '--dispatch-source\s+actions' -and $wf -match 'squad-dispatch\.js\s+decide') {
        Add-Pass "The dispatch workflow routes through the SHARED decision core with dispatch source 'actions', so it contends for the same lease as Ralph rather than dispatching alongside it"
    } else {
        Add-Fail "The dispatch workflow does not use the shared decision core (squad-dispatch.js decide --dispatch-source actions), so its lease key is its own and a double dispatch is possible"
    }

    if ($wf -match "if:\s*steps\.lease\.outputs\.action\s*==\s*'start'") {
        Add-Pass "The ACA job is started ONLY when the lease classifier says 'start', so losing the race stands the trigger down instead of racing a running session"
    } else {
        Add-Fail "The dispatch workflow starts the ACA job without gating on the lease classifier's 'start' verdict"
    }

    # The workflow once tested `.claimed`, a field the claim response has never
    # had. It evaluated to false on every run, skipped the start, and reported
    # the workflow GREEN having dispatched nothing. It survived a live
    # end-to-end test because every line it printed looked correct.
    if ($wf -match '\.claimed\b') {
        Add-Fail "The dispatch workflow reads a 'claimed' field from the lease claim. That field does not exist -- the response carries an 'outcome' -- so the gate is false on every run and the workflow reports success having dispatched nothing"
    } else {
        Add-Pass "The dispatch workflow does not read a nonexistent 'claimed' field; it maps the lease OUTCOME through a tested classifier"
    }

    if ($wf -match '--claim-outcome') {
        Add-Pass "The lease vocabulary is interpreted by a tested module rather than by a jq expression in YAML that no test can reach"
    } else {
        Add-Fail "The dispatch workflow interprets the lease outcome inline instead of through worker/lib/actions-event.js --claim-outcome, so the mapping is untestable"
    }

    if ($wf -match 'MUST have produced an execution') {
        Add-Pass "A run that claims a lease and starts nothing FAILS, so 'green but dispatched nothing' -- the defect this workflow already shipped once -- cannot recur silently"
    } else {
        Add-Fail "Nothing fails the workflow when a lease is claimed but no ACA execution is started, so a silent no-op reports success and leaves the lease held by a session that does not exist"
    }

    # `--env-vars` REPLACES the container environment rather than merging it.
    # Passing only the overrides drops every secret-backed variable in the
    # template -- GITHUB_TOKEN and COPILOT_GITHUB_TOKEN among them -- and the
    # session dies with "No authentication information found" only AFTER the
    # image has pulled and the repository has cloned. Ralph already solved this
    # and its merger is covered by test_ralph_dispatch.sh.
    if ($wf -match 'ralph_build_session_env') {
        Add-Pass "The dispatch workflow merges the template environment through Ralph's tested builder, so secret-backed variables survive the per-execution override instead of being silently replaced"
    } else {
        Add-Fail "The dispatch workflow passes --env-vars without merging the job template's environment. ACA REPLACES rather than merges, so GITHUB_TOKEN and COPILOT_GITHUB_TOKEN would be dropped and the session would fail authentication after cloning"
    }

    # ralph_build_session_env SKIPS every managed key when copying the template
    # ("if (managed.has(e.name)) continue"), so the CALLER must supply each one
    # -- including the secret-backed ones as `secretref:<name>`. Using the
    # builder without them yields a session with no credential at all, which
    # only surfaces inside the worker.
    if ($wf -match 'OV_GITHUB_TOKEN="secretref:' -and $wf -match 'OV_COPILOT_GITHUB_TOKEN="secretref:') {
        Add-Pass "The dispatch workflow supplies the managed secret references explicitly, as Ralph does -- the env builder skips managed keys from the template, so omitting them yields a session with no credential"
    } else {
        Add-Fail "The dispatch workflow does not pass OV_GITHUB_TOKEN / OV_COPILOT_GITHUB_TOKEN as secretref overrides. The env builder deliberately skips managed keys from the template, so the session would start with no GitHub credential"
    }

    if ($wf -match "grep -q '\^GITHUB_TOKEN=secretref:'") {
        Add-Pass "The dispatch refuses to start when the merged environment carries no GITHUB_TOKEN reference, so a credential-less session is stopped at the dispatcher rather than two minutes into the worker"
    } else {
        Add-Fail "Nothing checks that the merged environment actually carries a GITHUB_TOKEN reference before the ACA job is started"
    }

    # Attribution. Measured empirically against a real App push: GitHub
    # attributes a commit ENTIRELY by the author email and not at all by the
    # token used to push it, so crediting the requester has to be done in the
    # commit itself.
    if ($wf -match 'Co-authored-by: \$\{REQUESTER\}') {
        Add-Pass "Commits from a triggered session credit the requester with a Co-authored-by trailer, so work dispatched on someone's behalf is not attributed to nobody"
    } else {
        Add-Fail "The dispatch workflow does not credit the requester on the session's commits"
    }

    # OV_COMMIT_MESSAGE only applies when the WORKER commits leftover changes.
    # Measured on a live run: the agent committed its own work and opened its own
    # pull request, so the worker's message -- and its trailer -- was never used.
    # Telling the AGENT who asked is the only lever that survives the agent doing
    # the whole job itself.
    if ($wf -match '(?s)prompt=.*?requested by @\$\{REQUESTER\}') {
        Add-Pass "The requester is named in the PROMPT as well as the commit message, because an agent that commits and opens its own pull request never uses the worker's commit message"
    } else {
        Add-Fail "The requester reaches only the worker's commit message. A live run showed the agent committing its own work and opening its own PR, so that lever never fires and the request is attributed to nobody"
    }

    # A requester who sees a label change and then silence cannot tell a running
    # session from a trigger that quietly refused.
    if ($wf -match 'gh issue comment' -and $wf -match 'ACA execution') {
        Add-Pass "The trigger reports back to the issue with the session and ACA execution names, so a requester can tell a running session from a silent refusal"
    } else {
        Add-Fail "The dispatch workflow never reports back to the issue, so a requester sees a label change and then silence"
    }

    # The status comment MUST be posted with GITHUB_TOKEN. Events caused by
    # GITHUB_TOKEN do not start new workflow runs; an App token would retrigger
    # this workflow and loop, billing by the minute.
    if ($wf -match '(?s)Tell the issue where its work went.*?GH_TOKEN:\s*\$\{\{\s*secrets\.GITHUB_TOKEN\s*\}\}') {
        Add-Pass "The status comment is posted with GITHUB_TOKEN, whose events cannot start new workflow runs -- an App token would retrigger this same workflow and loop"
    } else {
        Add-Fail "The status comment is not posted with GITHUB_TOKEN. Any other credential retriggers this workflow on its own comment and loops"
    }

    if ($wf -match '--bot-login') {
        Add-Pass "The dispatch workflow passes the App's bot login to the resolver, which is what breaks the retrigger loop an App token would otherwise create"
    } else {
        Add-Fail "The dispatch workflow does not pass --bot-login, so a comment made by the App itself could retrigger the workflow and loop"
    }

    # ACA applies a per-execution --env-vars override ONLY when a COMPLETE
    # container spec is supplied. Supply a partial one and the override is
    # SILENTLY ignored: the execution starts, reports success, and runs the
    # template's baked-in SQUAD_MODE=smoke instead of the work that was asked
    # for. Ralph hit this in live E2E and guards against it; this path must too.
    if ($wf -match '--cpu\b' -and $wf -match '--memory\b' -and $wf -match '--image\b' -and $wf -match '--container-name\b') {
        Add-Pass "The dispatch workflow supplies a COMPLETE container spec (image, container name, cpu, memory) on job start, without which ACA silently ignores the env override and runs the template's defaults"
    } else {
        Add-Fail "The dispatch workflow starts the ACA job without a complete container spec (needs --image, --container-name, --cpu and --memory). ACA would ignore the env override and the session would run the template's baked-in mode while reporting success"
    }

    # There is no `issue` mode in the worker; an unknown SQUAD_MODE exits 64.
    if ($wf -match 'SQUAD_MODE=prompt') {
        Add-Pass "The dispatch workflow starts sessions in 'prompt' mode, the same mode Ralph dispatches with -- the worker exits 64 on an unknown mode"
    } else {
        Add-Fail "The dispatch workflow does not use SQUAD_MODE=prompt; the worker has no 'issue' mode and exits 64 on anything it does not recognise"
    }

    # The lease prevents a CONCURRENT double dispatch. It does not prevent a
    # SEQUENTIAL one: once released, Ralph's five-minute poll finds the issue
    # still unlabelled and dispatches it again.
    # The lease prevents a CONCURRENT double dispatch. It does not prevent a
    # SEQUENTIAL one: once released, Ralph's five-minute poll finds the issue
    # still unlabelled and dispatches it again.
    if ($wf -match 'squad-aca:dispatched' -and $wf -match '--add-label') {
        Add-Pass "The dispatch workflow applies the same 'dispatched' marker Ralph uses, so Ralph's poll does not re-dispatch the issue once the lease is released"
    } else {
        Add-Fail "The dispatch workflow does not apply Ralph's dispatch marker label, so Ralph will re-dispatch the same issue on its next poll"
    }

    # Found by the first live end-to-end run, not by any offline gate: the
    # durable lease is stored IN this repository, so CLAIMING one is a write.
    # With `contents: read` the claim fails with "Resource not accessible by
    # integration" (HTTP 403) after OIDC has already succeeded, which reads like
    # an Azure problem and is not one.
    if ($wf -match '(?s)dispatch:.*?permissions:.*?contents:\s*write') {
        Add-Pass "The dispatch job holds contents: write, without which claiming the durable lease fails with a 403 that looks like an Azure fault and is not one"
    } else {
        Add-Fail "The dispatch job does not hold contents: write. The lease store writes to this repository, so the claim will fail with 'Resource not accessible by integration' after OIDC has already succeeded"
    }

    # A workflow-wide grant would hand `contents: write` to the resolve job too,
    # which only reads an event payload and decides. Per-job permissions keep
    # the write confined to the step that needs it.
    if ($wf -match '(?m)^permissions:\s*\{\s*\}' ) {
        Add-Pass "Permissions default to NOTHING at the workflow level, so each job asks for exactly what it needs and the resolver never holds a write token"
    } else {
        Add-Fail "The dispatch workflow grants permissions workflow-wide rather than per job, so the event resolver holds the same write token as the dispatcher"
    }
}

$actionsEventModule = Join-Path $RepoRoot 'worker/lib/actions-event.js'
$decisionModule = Join-Path $RepoRoot 'worker/lib/dispatch-decision.js'
if ((Test-Path $actionsEventModule) -and (Test-Path $decisionModule)) {
    $decisionText = Get-Content -LiteralPath $decisionModule -Raw
    if ($decisionText -match "DISPATCH_SOURCES\s*=\s*\[[^\]]*'actions'") {
        Add-Pass "'actions' is a first-class dispatch source in the shared core, so a lease it claims is recognised by every other dispatcher"
    } else {
        Add-Fail "'actions' is not in DISPATCH_SOURCES, so the shared core would silently fall back to a default source and the lease would not identify its owner"
    }
} else {
    Add-Fail "worker/lib/actions-event.js or worker/lib/dispatch-decision.js is missing"
}

$actionsSuite = Join-Path $RepoRoot 'worker/tests/test_actions_event.sh'
if (Test-Path $actionsSuite) {
    Add-Pass "The Actions trigger resolver has a behavioural suite (worker/tests/test_actions_event.sh), so its refusals are exercised and not merely intended"
} else {
    Add-Fail "worker/tests/test_actions_event.sh is missing, so the trigger's refusals -- including the retrigger loop break -- are untested"
}

# ---------------------------------------------------------------------------
# The trigger label must not be one of Squad's own.
#
# `squad` is Squad's canonical TRIAGE INBOX label -- sync-squad-labels.yml
# defines it as "Squad triage inbox — Lead will assign to a member", and
# squad-triage.yml fires on exactly that name. Using it as the ACA dispatch
# trigger gave one label two unrelated meanings: "Lead, please route this" and
# "spend money running a remote container". Measured on this repository:
# applying it fired Squad's triage within ten seconds.
#
# The check reads the label names out of sync-squad-labels.yml rather than
# hard-coding them, so a label added upstream is covered without editing this.
# ---------------------------------------------------------------------------
$syncLabels = Join-Path $RepoRoot '.github/workflows/sync-squad-labels.yml'
$dispatchWf = Join-Path $RepoRoot '.github/workflows/squad-dispatch.yml'
$entrypointSh = Join-Path $RepoRoot 'worker/entrypoint.sh'
$actionsModule = Join-Path $RepoRoot 'worker/lib/actions-event.js'

if ((Test-Path $syncLabels) -and (Test-Path $dispatchWf)) {
    $syncText = Get-Content -LiteralPath $syncLabels -Raw
    $squadManaged = @()
    foreach ($m in [regex]::Matches($syncText, "name:\s*'([^']+)'")) {
        $squadManaged += $m.Groups[1].Value
    }
    $squadManaged = $squadManaged | Sort-Object -Unique

    $triggerLabels = @()
    $dispatchText = Get-Content -LiteralPath $dispatchWf -Raw
    foreach ($m in [regex]::Matches($dispatchText, "SQUAD_TRIGGER_LABEL\s*\|\|\s*'([^']+)'")) {
        $triggerLabels += @{ Where = 'squad-dispatch.yml'; Label = $m.Groups[1].Value }
    }
    if (Test-Path $entrypointSh) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $entrypointSh -Raw), 'RALPH_LABELS:-([A-Za-z0-9:_.-]+)')) {
            $triggerLabels += @{ Where = 'worker/entrypoint.sh (Ralph fallback)'; Label = $m.Groups[1].Value }
        }
    }
    # deploy.ps1 sets RALPH_LABELS EXPLICITLY on the Ralph job, which OVERRIDES
    # the entrypoint fallback above. Reading only the fallback is how the first
    # version of this check passed while production disagreed: the fallback said
    # `squad-aca`, the deployed job said `squad`, and Ralph went on watching
    # Squad's triage inbox. A default is not a value -- the value is whatever
    # the deployment sets.
    $deployPs1 = Join-Path $RepoRoot 'scripts/deploy.ps1'
    if (Test-Path $deployPs1) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $deployPs1 -Raw), 'RALPH_LABELS=([A-Za-z0-9:_.-]+)')) {
            $triggerLabels += @{ Where = 'scripts/deploy.ps1 (deployed value)'; Label = $m.Groups[1].Value }
        }
    } else {
        Add-Fail "scripts/deploy.ps1 is missing, so the label Ralph is actually DEPLOYED with cannot be checked"
    }
    if (Test-Path $actionsModule) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $actionsModule -Raw), "DEFAULT_TRIGGER_LABEL\s*=\s*'([^']+)'")) {
            $triggerLabels += @{ Where = 'worker/lib/actions-event.js'; Label = $m.Groups[1].Value }
        }
    }

    if ($triggerLabels.Count -eq 0) {
        Add-Fail "No dispatch trigger label could be found to check against Squad's own labels"
    } else {
        $collisions = @()
        foreach ($t in $triggerLabels) {
            if ($squadManaged -contains $t.Label) {
                $collisions += "$($t.Where) uses '$($t.Label)', which sync-squad-labels.yml manages"
            }
            if ($t.Label -like 'squad:*') {
                $collisions += "$($t.Where) uses '$($t.Label)', and squad-issue-assign.yml treats every 'squad:*' label as a member assignment"
            }
            foreach ($prefix in @('go:', 'release:', 'type:', 'priority:')) {
                if ($t.Label -like "$prefix*") {
                    $collisions += "$($t.Where) uses '$($t.Label)', which is in the exclusive '$prefix' namespace squad-label-enforce.yml manages"
                }
            }
        }

        if ($collisions.Count -eq 0) {
            $distinct = ($triggerLabels | ForEach-Object { $_.Label } | Sort-Object -Unique) -join ', '
            Add-Pass "Every dispatch trigger label ($distinct) is clear of Squad's own labels, so applying one asks for a remote session and nothing else -- 'squad' means 'Lead, please route this' and would fire squad-triage.yml as well"
        } else {
            Add-Fail "A dispatch trigger label collides with Squad's own label scheme: $($collisions -join '; ')"
        }

        # Both dispatchers must watch the SAME label, or the shared-lease
        # contention story is fiction: they would simply never see the same work.
        $labelSet = @($triggerLabels | ForEach-Object { $_.Label } | Sort-Object -Unique)
        if ($labelSet.Count -eq 1) {
            Add-Pass "Ralph and the Actions trigger watch the SAME label, which is what makes them contend for one lease rather than covering different work"
        } else {
            Add-Fail "The dispatchers watch different trigger labels ($($labelSet -join ', ')). They would never contend for the same lease, so the duplicate-dispatch protection would never actually be exercised"
        }

        # The COMMAND PREFIX is a trigger too, and the first version of this
        # section did not check it -- which is how `/squad` survived the label
        # rename. This repository defines two Copilot agents in .github/agents/:
        # `squad` (the ordinary Squad coordinator) and `squad-aca` (the ACA
        # dispatcher). A command prefix naming the FORMER asks for a remote
        # billed session using the name of a different agent.
        $prefixes = @()
        $eventModule = Join-Path $RepoRoot 'worker/lib/actions-event.js'
        if (Test-Path $eventModule) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $eventModule -Raw), "DEFAULT_COMMAND_PREFIX\s*=\s*'([^']+)'")) {
                $prefixes += @{ Where = 'worker/lib/actions-event.js'; Prefix = $m.Groups[1].Value }
            }
        }
        foreach ($m in [regex]::Matches($dispatchText, "SQUAD_COMMAND_PREFIX\s*\|\|\s*'([^']+)'")) {
            $prefixes += @{ Where = 'squad-dispatch.yml'; Prefix = $m.Groups[1].Value }
        }

        if ($prefixes.Count -eq 0) {
            Add-Fail "No command prefix could be found to check against the repository's agent names"
        } else {
            $agentNames = @()
            $agentsDir = Join-Path $RepoRoot '.github/agents'
            if (Test-Path $agentsDir) {
                $agentNames = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.agent.md' -File |
                    ForEach-Object { $_.Name -replace '\.agent\.md$', '' })
            }

            $prefixProblems = @()
            foreach ($p in $prefixes) {
                $bare = $p.Prefix -replace '^/', ''
                # Naming ANOTHER agent in this repository is the failure. Naming
                # this one is the point.
                if ($agentNames -contains $bare -and $bare -ne 'squad-aca') {
                    $prefixProblems += "$($p.Where) uses '$($p.Prefix)', which names the '$bare' agent in .github/agents/ -- a different agent from the ACA dispatcher"
                }
                if ($squadManaged -contains $bare) {
                    $prefixProblems += "$($p.Where) uses '$($p.Prefix)', whose bare form is a label sync-squad-labels.yml manages"
                }
            }

            $prefixSet = @($prefixes | ForEach-Object { $_.Prefix } | Sort-Object -Unique)
            if ($prefixProblems.Count -gt 0) {
                Add-Fail "A dispatch command prefix collides with something else in this repository: $($prefixProblems -join '; ')"
            } elseif ($prefixSet.Count -ne 1) {
                Add-Fail "The command prefix differs between the module default and the workflow ($($prefixSet -join ', ')). One of them is dead configuration and nobody would know which"
            } else {
                Add-Pass "The dispatch command prefix ($($prefixSet -join ', ')) names the ACA dispatcher and nothing else -- '/squad' would name the ordinary Squad coordinator agent, which does not dispatch to ACA"
            }

            # The label and the prefix should refer to the same thing, or the
            # documentation has to explain two names for one action.
            $bareSet = @($prefixes | ForEach-Object { ($_.Prefix -replace '^/', '') } | Sort-Object -Unique)
            if (($bareSet.Count -eq 1) -and ($labelSet.Count -eq 1) -and ($bareSet[0] -eq $labelSet[0])) {
                Add-Pass "The trigger label and the command prefix are the same word ('$($labelSet[0])'), so both ways of asking for a remote session name the same thing"
            } else {
                Add-Fail "The trigger label ($($labelSet -join ', ')) and the command prefix ($($bareSet -join ', ')) are different words for the same action, which the documentation would have to explain away"
            }
        }
    }
} else {
    Add-Fail ".github/workflows/sync-squad-labels.yml or squad-dispatch.yml is missing, so the trigger label cannot be checked against Squad's own labels"
}

# A lease is claimed BEFORE compute is requested, so a dispatcher that dies in
# between leaves a lease held by a session that does not exist -- and the issue
# is then blocked forever, because every future trigger correctly sees `active`
# and stands down. Several such leases were produced by hand while debugging
# this sprint, and each needed a human with a CLI to release.
$sweepWorkflow = Join-Path $RepoRoot '.github/workflows/squad-lease-sweep.yml'
if (Test-Path $sweepWorkflow) {
    $sweep = Get-Content -LiteralPath $sweepWorkflow -Raw
    if ($sweep -match 'squad-dispatch\.js sweep') {
        Add-Pass "Stale leases are reconciled by a scheduled sweep using the SHARED sweep, so a dispatcher that died between claim and start cannot block an issue until a human notices"
    } else {
        Add-Fail "The lease reconciliation workflow does not call the shared 'squad-dispatch.js sweep', so it would apply its own staleness rules"
    }

    if ($sweep -match "cron:\s*'[^']*\*/[1-9]\b") {
        Add-Fail "The lease sweep runs more often than hourly. A lease heartbeats while its session lives, so a genuinely stale lease is stale for a long time -- and this repository has already had a rate-limit outage from an unbounded sweep"
    } else {
        Add-Pass "The lease sweep runs no more often than hourly, spending rate-limit budget in proportion to how rare a stale lease actually is"
    }

    if ($sweep -match '/rate_limit') {
        Add-Pass "The sweep reports the remaining rate-limit budget each run, so drift towards the ceiling is visible before it is an outage"
    } else {
        Add-Fail "Nothing reports the rate-limit budget, so the first sign of exhaustion would be a failure"
    }
} else {
    Add-Fail ".github/workflows/squad-lease-sweep.yml is missing, so a lease orphaned between claim and start blocks its issue until a human releases it by hand"
}

$deployScript = Join-Path $RepoRoot 'scripts/deploy.ps1'
if (Test-Path $deployScript) {
    $deployText = Get-Content -LiteralPath $deployScript -Raw
    # `az containerapp job delete` runs whenever the image changes, and a role
    # assignment scoped to a RESOURCE dies with that resource. Observed live:
    # the Actions identity silently lost its grant on redeploy and the next
    # triggered run failed with "No subscriptions found" -- which reads like an
    # OIDC fault and is an RBAC one.
    if ($deployText -match '--role\s+"Container Apps Jobs Operator"' -and
        $deployText -match '--assignee-object-id\s+\$ghaPrincipalId' -and
        $deployText -match 'az containerapp job show --name \$jobName[^\r\n]*--query id') {
        Add-Pass "deploy.ps1 re-grants Container Apps Jobs Operator to the GitHub Actions principal, scoped to the session job's own resource id, after recreating it -- a job delete silently destroys resource-scoped assignments and the next triggered run would fail with 'No subscriptions found', which looks like an OIDC fault and is not"
    } else {
        Add-Fail "deploy.ps1 does not assign 'Container Apps Jobs Operator' to the GitHub Actions principal scoped to the session job after recreating it. A resource-scoped role assignment dies with the resource, so every image-changing deploy would silently break the Actions trigger"
    }

    # `gh auth token` returns the ACTIVE account's token, which on a
    # multi-account machine is often not the account with write access.
    # Deploying that produces a session that clones, runs the agent for up to an
    # hour, and fails at the push. Observed here repeatedly: each redeploy
    # silently reset the session job to a read-only credential.
    if ($deployText -match 'permissions\.push' -and $deployText -match 'REFUSING') {
        Add-Pass "deploy.ps1 refuses a GitHub token that cannot push to the default repository, rather than deploying a credential it can already tell will fail at the end of a session"
    } else {
        Add-Fail "deploy.ps1 does not check that the GitHub token can push. 'gh auth token' returns the active account's token, so a multi-account machine can silently deploy a read-only credential and every session will fail at the push"
    }

    if ($deployText -match 'SQUAD_SKIP_TOKEN_CHECK') {
        Add-Pass "The deploy-time push-access check has a documented escape hatch, so an offline or air-gapped deploy is not blocked by a network call"
    } else {
        Add-Fail "The deploy-time push-access check has no opt-out, so a deploy with no network access to the GitHub API cannot proceed"
    }
} else {
    Add-Fail "scripts/deploy.ps1 is missing"
}

if ($false) {
    Add-Pass "unreachable"
} else {
    $null = $null
}

# ---------------------------------------------------------------------------
# The shipped image layout (ADR 0003 finding 1 / future-work sprint 1)
# ---------------------------------------------------------------------------
Write-Section "Shipped image layout"

# WHY THIS SECTION EXISTS.
#
# worker/lib/resolve-capability-route.js shipped in the worker image;
# config/sandbox-classes.json did not. Ralph runs INSIDE that image and calls
# `squad-dispatch.js decide` with no --catalog, so catalogSearchPaths() found
# nothing, `decide` exited 70 with reason "catalog-unavailable", and every cron
# run logged a plausible-sounding skip and dispatched nothing. 911 worker
# assertions and 363 checks here were green throughout, because every routing
# test passed --catalog explicitly and every dispatch test exported
# SQUAD_DISPATCH_CLI at a repo-relative path.
#
# worker/tests/test_image_layout.sh proves the BEHAVIOUR from a layout derived
# from the Dockerfile. The checks below generalise the defect class instead of
# fixing one instance of it: they assert that everything a shipped file needs at
# require() time is itself shipped, and that the behavioural suite has not
# quietly acquired the override that hid the bug in the first place.

$workerDockerfileLayout = Join-Path $RepoRoot "worker\Dockerfile"
$imageLayoutSuite       = Join-Path $RepoRoot "worker\tests\test_image_layout.sh"
$dockerIgnorePath       = Join-Path $RepoRoot ".dockerignore"

# --- Parse the COPY instructions --------------------------------------------
# Same rule as the bash suite: strict, and loud when it does not understand a
# form. A parser that guessed would re-open the hole it exists to close.
$copyRecords = @()
$copyParseError = $null
if (-not (Test-Path $workerDockerfileLayout)) {
    $copyParseError = "worker/Dockerfile is missing"
} else {
    foreach ($line in (Get-Content -LiteralPath $workerDockerfileLayout)) {
        if ($line -notmatch '^\s*COPY\s') { continue }
        if ($line -match '\\\s*$')  { $copyParseError = "a COPY instruction uses a line continuation, which this parser does not implement"; break }
        if ($line -match '\[')      { $copyParseError = "a COPY instruction uses the JSON-array form, which this parser does not implement"; break }
        if ($line -match '--from=') { $copyParseError = "a COPY instruction copies from another build stage, so its source is not a context file"; break }
        $operands = @(($line -split '\s+') | Where-Object { $_ -ne '' } | Select-Object -Skip 1 | Where-Object { $_ -notlike '--*' })
        if ($operands.Count -lt 2) { $copyParseError = "a COPY instruction has fewer than two path operands"; break }
        $copyRecords += ,@{
            Dest    = $operands[-1]
            Sources = @($operands[0..($operands.Count - 2)])
        }
    }
}

if ($copyParseError) {
    Add-Fail "worker/Dockerfile COPY instructions could not be parsed ($copyParseError); the shipped file list is unknown and nothing below could be checked"
    $shippedSources = @()
} else {
    $shippedSources = @($copyRecords | ForEach-Object { $_.Sources })
    if ($shippedSources.Count -ge 10) {
        Add-Pass "worker/Dockerfile COPY instructions parsed to $($shippedSources.Count) shipped source files"
    } else {
        Add-Fail "worker/Dockerfile COPY instructions parsed to only $($shippedSources.Count) source files; a parse that finds almost nothing would make every layout check below vacuous"
    }

    # --- 1. Every COPY source exists in the build context --------------------
    $missingSources = @($shippedSources | Where-Object { -not (Test-Path (Join-Path $RepoRoot ($_ -replace '/', '\'))) })
    if ($missingSources.Count -eq 0) {
        Add-Pass "Every worker/Dockerfile COPY source exists in the repository, so 'az acr build' cannot fail on a missing context file"
    } else {
        Add-Fail "worker/Dockerfile COPY names $($missingSources.Count) path(s) that do not exist ($($missingSources -join ', ')); the image build would fail"
    }

    # --- 2. The catalog is shipped, at the name the resolver looks for --------
    # catalogSearchPaths()[0] is <__dirname>/sandbox-classes.json. The packaged
    # BASENAME therefore has to be exactly that: shipping it as
    # sandbox-classes.json.txt would satisfy a "the Dockerfile mentions the
    # catalog" grep and still leave Ralph dead.
    $libRecord = $copyRecords | Where-Object { $_.Dest -eq '/usr/local/lib/squad-on-aca/' } | Select-Object -First 1
    if (-not $libRecord) {
        Add-Fail "No worker/Dockerfile COPY targets /usr/local/lib/squad-on-aca/; the worker libraries would not be in the image at all"
    } elseif ($libRecord.Sources -contains 'config/sandbox-classes.json') {
        Add-Pass "worker/Dockerfile ships config/sandbox-classes.json into /usr/local/lib/squad-on-aca/, which is catalogSearchPaths()[0]; without it Ralph's 'decide' exits 70 with catalog-unavailable on every issue"
    } else {
        Add-Fail "worker/Dockerfile does not ship config/sandbox-classes.json into /usr/local/lib/squad-on-aca/; the in-image dispatcher passes no --catalog, so every Ralph dispatch would be refused as catalog-unavailable"
    }

    $routeResolverPath = Join-Path $RepoRoot "worker\lib\resolve-capability-route.js"
    if (Test-Path $routeResolverPath) {
        $resolverText = Get-Content -LiteralPath $routeResolverPath -Raw
        if ($resolverText -match "path\.join\(__dirname,\s*'sandbox-classes\.json'\)") {
            Add-Pass "catalogSearchPaths() still looks beside the worker libraries for sandbox-classes.json, which is the path the Dockerfile ships to"
        } else {
            Add-Fail "catalogSearchPaths() no longer looks for <__dirname>/sandbox-classes.json; the file the Dockerfile ships into /usr/local/lib/squad-on-aca/ would never be read"
        }
    }

    # --- 3. Every shipped require() target is shipped ------------------------
    # THE GENERALISATION. The catalog was one instance of "a shipped file needs
    # something the image does not contain". This makes the whole class fail a
    # build: adding require('./new-thing.js') to a shipped .js without adding it
    # to COPY is a MODULE_NOT_FOUND at runtime, inside a cron job, with the same
    # quiet skip as the original defect.
    $shippedBasenames = @{}
    foreach ($rec in $copyRecords) {
        foreach ($src in $rec.Sources) {
            $leaf = if ($rec.Dest.EndsWith('/')) { Split-Path -Leaf $src } else { Split-Path -Leaf $rec.Dest }
            $shippedBasenames["$($rec.Dest)$leaf"] = $src
        }
    }
    $unshippedRequires = @()
    $checkedRequires = 0
    foreach ($rec in $copyRecords) {
        if (-not $rec.Dest.EndsWith('/')) { continue }
        foreach ($src in $rec.Sources) {
            if ($src -notlike '*.js') { continue }
            $srcPath = Join-Path $RepoRoot ($src -replace '/', '\')
            if (-not (Test-Path $srcPath)) { continue }
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $srcPath -Raw), "require\(\s*'(\./[^']+)'\s*\)")) {
                $checkedRequires++
                $target = "$($rec.Dest)$(Split-Path -Leaf $m.Groups[1].Value)"
                if (-not $shippedBasenames.ContainsKey($target)) {
                    $unshippedRequires += "$src requires $($m.Groups[1].Value)"
                }
            }
        }
    }
    if ($checkedRequires -eq 0) {
        Add-Fail "No relative require() was found in any shipped .js file; the shipped-require check would pass vacuously, so it is being treated as a failure"
    } elseif ($unshippedRequires.Count -eq 0) {
        Add-Pass "Every shipped require() target is shipped ($checkedRequires relative require(s) across the shipped .js files resolve to files the Dockerfile also copies)"
    } else {
        Add-Fail "Every shipped require() target is shipped: FAILED for $($unshippedRequires.Count) ($($unshippedRequires -join '; ')); the module would be missing inside the image and the caller would die with MODULE_NOT_FOUND at runtime"
    }

    # --- 4. The catalog is normalised the way a JSON file should be ----------
    # `chmod +x` on a JSON document is meaningless, and CRLF-stripping it is
    # unnecessary (JSON.parse treats \r as whitespace). Both would be signals
    # that someone treated the catalog as a script.
    $dockerLayoutText = Get-Content -LiteralPath $workerDockerfileLayout -Raw
    $sedLine   = @($dockerLayoutText -split "`n" | Where-Object { $_ -match 'sed -i' }) -join ' '
    $chmodLine = @($dockerLayoutText -split "`n" | Where-Object { $_ -match 'chmod \+x' }) -join ' '
    if ($chmodLine -notmatch 'sandbox-classes\.json') {
        Add-Pass "worker/Dockerfile does not chmod +x the packaged catalog; it is data the dispatcher reads, not a script"
    } else {
        Add-Fail "worker/Dockerfile chmod +x's sandbox-classes.json; an executable catalog is a signal it is being treated as a script"
    }
    if ($sedLine -notmatch 'sandbox-classes\.json') {
        Add-Pass "worker/Dockerfile does not CRLF-strip the packaged catalog; JSON.parse already treats CR as whitespace, and .gitattributes pins config/*.json to LF"
    } else {
        Add-Fail "worker/Dockerfile CRLF-strips sandbox-classes.json; that list is for shell scripts, and adding data files to it hides which files actually need it"
    }

    # --- 5. The build context can actually reach those sources ---------------
    # config/ is OUTSIDE worker/, and a COPY cannot reach above its context, so
    # the image can only be built from the repository root. Building from
    # worker/ would fail every COPY -- loudly, but at deploy time rather than
    # here.
    $deployLayoutPath = Join-Path $RepoRoot "scripts\deploy.ps1"
    if (-not (Test-Path $deployLayoutPath)) {
        Add-Fail "scripts/deploy.ps1 is missing; nothing builds the worker image"
    } else {
        $acrBuildLine = @(Get-Content -LiteralPath $deployLayoutPath | Where-Object { $_ -match 'acr build' -and $_ -match 'squad-worker' }) -join ' '
        # The property is "the Dockerfile is worker/Dockerfile and the context is
        # the repository root" -- NOT one particular spelling of the --file
        # argument. Pinning the literal string `--file "worker/Dockerfile"` made
        # this check fail on the correct fix for a relative-path bug, which is
        # the opposite of what a guard is for.
        $dockerfileArg = $acrBuildLine -match '--file\s+(\$dockerfilePath|"?[^\s"]*worker[/\\]Dockerfile"?)'
        if ($acrBuildLine -eq '') {
            Add-Fail "scripts/deploy.ps1 no longer builds squad-worker with 'az acr build'; the layout checks here describe an image nothing produces"
        } elseif ($dockerfileArg -and $acrBuildLine -match '\$repoRoot\s*$') {
            Add-Pass "scripts/deploy.ps1 builds squad-worker from worker/Dockerfile with the REPOSITORY ROOT as context, which is the only context that can reach config/sandbox-classes.json"
        } else {
            Add-Fail "scripts/deploy.ps1 does not build squad-worker from the repository root with worker/Dockerfile; a worker/-rooted context cannot reach config/sandbox-classes.json and every COPY would fail"
        }

        # `az acr build` resolves a RELATIVE --file against the current working
        # directory, not against the context argument, so a relative path here
        # only works when the deploy happens to be started from the repository
        # root -- and fails at the image build, after four Azure resources have
        # been created. Verified against a live registry: from scripts/, a
        # relative --file gives "ERROR: Unable to find 'worker/Dockerfile'."
        # while an absolute one builds.
        if ($acrBuildLine -match '--file\s+"?worker[/\\]Dockerfile"?') {
            Add-Fail "scripts/deploy.ps1 passes a RELATIVE --file to 'az acr build'; az resolves it against the working directory, so the deploy breaks unless it is run from the repository root"
        } else {
            Add-Pass "scripts/deploy.ps1 passes an absolute Dockerfile path to 'az acr build', so a deploy works from any working directory"
        }
    }

    # --- 6. .dockerignore must not exclude anything the Dockerfile copies ----
    if (Test-Path $dockerIgnorePath) {
        $ignoreLines = @(Get-Content -LiteralPath $dockerIgnorePath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $_ -notmatch '^#' })
        $fancy = @($ignoreLines | Where-Object { $_ -match '[*?!\[]' })
        if ($fancy.Count -gt 0) {
            Add-Fail ".dockerignore uses wildcard or re-include patterns ($($fancy -join ', ')); this check only understands literal path prefixes and refuses to guess whether a COPY source survives them"
        } else {
            $excluded = @()
            foreach ($src in $shippedSources) {
                foreach ($pattern in $ignoreLines) {
                    $p = $pattern.TrimEnd('/')
                    if ($src -eq $p -or $src.StartsWith("$p/")) { $excluded += "$src (by '$pattern')" }
                }
            }
            if ($excluded.Count -eq 0) {
                Add-Pass ".dockerignore excludes nothing worker/Dockerfile copies ($($ignoreLines.Count) literal prefix(es) checked against $($shippedSources.Count) COPY sources)"
            } else {
                Add-Fail ".dockerignore excludes $($excluded.Count) file(s) the Dockerfile copies ($($excluded -join ', ')); the build would fail with 'file not found in build context'"
            }
        }
    }
}

# --- 7. The behavioural suite exists, runs, and passes no override -----------
# M6 in the sprint plan. The suite's whole value is that it invokes the
# dispatcher the way PRODUCTION invokes it. One `--catalog "$CATALOG"` on any
# invocation and it goes back to proving nothing -- which is precisely how the
# original defect survived 911 assertions.
if (-not (Test-Path $imageLayoutSuite)) {
    Add-Fail "worker/tests/test_image_layout.sh is missing; nothing exercises the packaged layout and a Dockerfile edit could silently un-ship the catalog again"
} else {
    $suiteLines = Get-Content -LiteralPath $imageLayoutSuite
    Add-Pass "worker/tests/test_image_layout.sh exists and is picked up by worker/tests/run-tests.sh (test_*.sh)"

    # Command lines only: the assertion MESSAGES have to be able to say
    # "--catalog", and the setup has to be able to `unset`
    # SQUAD_SANDBOX_CLASS_CATALOG. What must never appear is the flag or the
    # variable on a line that actually invokes something.
    $invocationLines = @($suiteLines | Where-Object {
        $_ -notmatch '^\s*#' -and ($_ -match '\bnode\s' -or $_ -match 'squad_dispatch_' -or $_ -match 'ralph_dispatch_issue')
    })
    $overrides = @($invocationLines | Where-Object { $_ -match '--catalog' -or $_ -match 'SQUAD_SANDBOX_CLASS_CATALOG\s*=' })
    $exported  = @($suiteLines | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '^\s*export\s+SQUAD_(SANDBOX_CLASS_CATALOG|DISPATCH_CLI)\b' })
    if ($invocationLines.Count -eq 0) {
        Add-Fail "worker/tests/test_image_layout.sh contains no dispatcher invocation at all; there is nothing for the no-override check to be about"
    } elseif ($overrides.Count -eq 0 -and $exported.Count -eq 0) {
        Add-Pass "test_image_layout.sh passes no catalog override on any of its $($invocationLines.Count) invocation line(s), and exports neither SQUAD_SANDBOX_CLASS_CATALOG nor SQUAD_DISPATCH_CLI, so it exercises the resolution production performs"
    } else {
        Add-Fail "test_image_layout.sh passes a catalog override ($(($overrides + $exported) -join ' | ')); handing the dispatcher a catalog is exactly what let the packaging defect survive 911 assertions"
    }

    if (($suiteLines -join "`n") -match 'COPY') {
        Add-Pass "test_image_layout.sh derives its layout from the Dockerfile COPY instructions rather than a hard-coded file list, so removing a file from COPY removes it from the test"
    } else {
        Add-Fail "test_image_layout.sh no longer reads the Dockerfile COPY instructions; a hard-coded file list would keep passing after the catalog was un-shipped"
    }
}

# ---------------------------------------------------------------------------
# The manifest-path decision is defined ONCE
# (ADR 0003 finding 2 / future-work sprint 2)
# ---------------------------------------------------------------------------
Write-Section "One manifest-path implementation"

# WHY THIS SECTION EXISTS.
#
# The rules that decide whether a capability manifest path is safe -- reject
# absolute paths, control characters, escapes from the working tree, symlinks,
# and anything that is not a regular file -- used to exist TWICE: in
# worker/lib/resolve-capability-route.js (the control-plane routing decision)
# and as an inline `node - <<'NODE'` heredoc inside
# worker/lib/squad-capability-preflight.sh (the in-worker session gate). Two
# implementations of a path-traversal boundary is the shape of a future CVE: a
# rule added to one and not the other applies to routing but not to the gate
# that actually runs inside the session, and nothing fails.
#
# They now share worker/lib/locate-manifest.js.
#
# The BEHAVIOURAL proof is worker/tests/test_manifest_path_corpus.sh: one corpus
# driven through both entry points, so a single mutation to the shared module
# fails two named assertions. The checks below guard the things behaviour cannot
# see -- that the module is actually shipped, that neither consumer has quietly
# grown a private copy again, and that the corpus still drives BOTH sides. A
# restored inline copy inside the preflight would keep the corpus green with ONE
# failure per mutation instead of two, which looks identical in a summary line.
$locatorPath        = Join-Path $RepoRoot "worker\lib\locate-manifest.js"
$preflightShPath    = Join-Path $RepoRoot "worker\lib\squad-capability-preflight.sh"
$routeResolverJs    = Join-Path $RepoRoot "worker\lib\resolve-capability-route.js"
$corpusSuitePath    = Join-Path $RepoRoot "worker\tests\test_manifest_path_corpus.sh"
$corpusFixturePath  = Join-Path $RepoRoot "worker\tests\fixtures\manifest-path-corpus.txt"

if (-not (Test-Path $locatorPath)) {
    Add-Fail "worker/lib/locate-manifest.js is missing; the manifest-path rules have no shared home and both consumers would have to re-implement them"
} else {
    $locatorText = Get-Content -LiteralPath $locatorPath -Raw

    # --- 1. The shared module is SHIPPED -------------------------------------
    # Sprint 1's "every shipped require() target is shipped" check already fails
    # if the resolver requires an unshipped file, but the preflight reaches this
    # module by exec, not by require(), so that check alone would not see it.
    $libCopyRecord = $copyRecords | Where-Object { $_.Dest -eq '/usr/local/lib/squad-on-aca/' } | Select-Object -First 1
    if ($libCopyRecord -and ($libCopyRecord.Sources -contains 'worker/lib/locate-manifest.js')) {
        Add-Pass "worker/Dockerfile ships worker/lib/locate-manifest.js into /usr/local/lib/squad-on-aca/, which is the only place squad-capability-preflight.sh looks for it"
    } else {
        Add-Fail "worker/Dockerfile does not ship worker/lib/locate-manifest.js; the in-worker preflight would refuse every session with exit 69, and the routing resolver would die with MODULE_NOT_FOUND"
    }

    # --- 2. The verdicts are distinct exit codes ------------------------------
    # The preflight used to read "any non-zero" as unsafe, which meant a module
    # that failed to load (node exit 1) and a hostile path produced the same
    # branch. Distinct codes are what let the preflight refuse on an unclaimed
    # one instead of guessing.
    $hasDistinctCodes = ($locatorText -match 'EXIT_ABSENT\s*=\s*3') -and
                        ($locatorText -match 'EXIT_UNSAFE\s*=\s*4') -and
                        ($locatorText -match 'EXIT_PRESENT\s*=\s*0')
    if ($hasDistinctCodes) {
        Add-Pass "locate-manifest.js gives present/absent/unsafe three distinct exit codes (0/3/4), so a caller can refuse on any code it does not recognise instead of reading 'the module is broken' as a path verdict"
    } else {
        Add-Fail "locate-manifest.js no longer defines distinct present/absent/unsafe exit codes; collapsing them re-creates the ambiguity where a missing module and an unsafe path are indistinguishable"
    }

    # --- 3. The resolver DELEGATES ------------------------------------------
    if (-not (Test-Path $routeResolverJs)) {
        Add-Fail "worker/lib/resolve-capability-route.js is missing"
    } else {
        $routeResolverText = Get-Content -LiteralPath $routeResolverJs -Raw
        $resolverDelegates = $routeResolverText -match "require\(\s*'\./locate-manifest\.js'\s*\)"
        $resolverPrivateCopy = @(@('function isWithin', 'function realpath', 'function locateManifest') |
            Where-Object { $routeResolverText -like "*$_*" })
        if ($resolverDelegates -and $resolverPrivateCopy.Count -eq 0) {
            Add-Pass "resolve-capability-route.js requires ./locate-manifest.js and defines no manifest-path resolution of its own"
        } elseif (-not $resolverDelegates) {
            Add-Fail "resolve-capability-route.js no longer requires ./locate-manifest.js; the routing decision would be judging manifest paths by rules the in-worker gate never sees"
        } else {
            Add-Fail "resolve-capability-route.js has re-grown a private manifest-path implementation ($($resolverPrivateCopy -join ', ')); a mutation to the shared module would then fail only the preflight's assertions, and the divergence this section exists to prevent would be back"
        }
    }
}

# --- 4. The preflight defines NO path resolution of its own ------------------
# M4 in the sprint plan. This is an ABSENCE grep, which is the one thing grep is
# reliable for. It matters because restoring an inline copy while KEEPING the
# shared module leaves every behavioural assertion green: the corpus would still
# agree case by case, and a mutation to the shared module would fail one
# assertion instead of two. That difference is invisible in a summary line and
# is exactly the divergence that produced this sprint.
if (-not (Test-Path $preflightShPath)) {
    Add-Fail "worker/lib/squad-capability-preflight.sh is missing"
} else {
    $preflightText = Get-Content -LiteralPath $preflightShPath -Raw

    # Deliberately NOT a grep for "node - <<'NODE'": the preflight still uses one
    # to flatten a PARSED manifest into rows, and that is not path resolution.
    # These tokens are specific to deciding whether a path is safe.
    $pathLogicTokens = @(
        'isWithin', 'realpathSync', 'lstatSync', 'existsSync', 'statSync',
        'path.isAbsolute', 'path.resolve', 'path.relative', '__ABSENT__'
    )
    $foundPathLogic = @($pathLogicTokens | Where-Object { $preflightText -like "*$_*" })
    if ($foundPathLogic.Count -eq 0) {
        Add-Pass "squad-capability-preflight.sh defines no path-resolution of its own (none of: $($pathLogicTokens -join ', ')), so the corpus really does drive one implementation from two entry points"
    } else {
        Add-Fail "squad-capability-preflight.sh has re-grown inline path-resolution ($($foundPathLogic -join ', ')); with a second copy present a mutation to the shared module fails ONE assertion instead of two, and the sprint's unification claim is false while every test still passes"
    }

    # --- 5. The missing-locator path REFUSES ---------------------------------
    # Criterion 3, and the single most important thing this sprint had to prove.
    # A new external dependency was created; if it disappears the gate must stop
    # the session, not report "no manifest present". Turning "unsafe path" into
    # "no manifest" is a fail-OPEN on a security boundary and is strictly worse
    # than the duplication that was removed. The behavioural assertions live in
    # test_manifest_path_corpus.sh; this is the structural half.
    $referencesLocator = $preflightText -match 'locate-manifest\.js'
    $refusalCodes = @([regex]::Matches($preflightText, '(?m)^\s*exit\s+(\d+)') | ForEach-Object { $_.Groups[1].Value })
    $hasRefusalCode = $refusalCodes -contains '69'
    if ($referencesLocator -and $hasRefusalCode) {
        Add-Pass "squad-capability-preflight.sh calls locate-manifest.js and has an exit 69 refusal path, so an un-shipped locator stops the session instead of being reported as 'no manifest present'"
    } elseif (-not $referencesLocator) {
        Add-Fail "squad-capability-preflight.sh no longer calls locate-manifest.js; either it has an inline copy again or the gate is not resolving the manifest path at all"
    } else {
        Add-Fail "squad-capability-preflight.sh has no exit 69 refusal path; a missing or broken locator would have to fall through to one of the existing outcomes, and 'no manifest present' (exit 0) is the fail-open this sprint exists to rule out"
    }

    # The 78 and 0 contracts are unchanged by the refactor, and must stay that
    # way: sprint 2 was a refactor with an equivalence proof, not a hardening
    # pass.
    if (($refusalCodes -contains '78') -and ($refusalCodes -contains '0') -and ($refusalCodes -contains '64')) {
        Add-Pass "squad-capability-preflight.sh still exits 78 (unsafe/unsatisfiable), 0 (absent/passed) and 64 (usage); the shared locator changed where the decision is made, not what the gate reports"
    } else {
        Add-Fail "squad-capability-preflight.sh no longer emits its documented 0/64/78 exit codes; the unification was supposed to preserve the operator-facing contract exactly"
    }
}

# --- 6. The corpus exists and drives BOTH entry points ----------------------
# A corpus that only exercised one side would prove agreement by construction
# and could never fail twice, which is the sprint's entire premise.
if (-not (Test-Path $corpusSuitePath)) {
    Add-Fail "worker/tests/test_manifest_path_corpus.sh is missing; nothing proves the two entry points reach the same code, and a rule could be added to one consumer only"
} elseif (-not (Test-Path $corpusFixturePath)) {
    Add-Fail "worker/tests/fixtures/manifest-path-corpus.txt is missing; the corpus suite has no cases to drive"
} else {
    $corpusText = Get-Content -LiteralPath $corpusSuitePath -Raw
    $drivesPreflight = $corpusText -match 'squad-capability-preflight\.sh'
    $drivesResolver  = $corpusText -match 'resolve-capability-route\.js'
    if ($drivesPreflight -and $drivesResolver) {
        Add-Pass "test_manifest_path_corpus.sh drives the SAME corpus through squad-capability-preflight.sh and resolve-capability-route.js, so one mutation to the shared module must fail two assertions"
    } else {
        $missingSide = if (-not $drivesPreflight) { "the preflight" } else { "the routing resolver" }
        Add-Fail "test_manifest_path_corpus.sh no longer drives $missingSide; a one-sided corpus cannot distinguish 'the two share code' from 'the two happen to agree', which is the distinction this sprint exists to make"
    }

    # It must read the resolver's EXPORT, not locate-manifest.js directly: going
    # straight to the shared module would still pass if the resolver kept a
    # private copy and never called it.
    if ($corpusText -match 'RESOLVER_MODULE="\$\{WORKER_DIR\}/lib/resolve-capability-route\.js"') {
        Add-Pass "test_manifest_path_corpus.sh reaches the shared logic through resolve-capability-route.js's export rather than requiring locate-manifest.js directly, so a resolver that stopped delegating would fail rather than pass"
    } else {
        Add-Fail "test_manifest_path_corpus.sh no longer resolves its resolver entry point from worker/lib/resolve-capability-route.js; testing the shared module directly would pass even if the resolver kept a private copy"
    }

    # The missing-locator refusal must be proved against the layout the
    # Dockerfile actually ships, not a hard-coded file list. A hard-coded list
    # keeps the suite green while the image ships a preflight that refuses every
    # session -- the same shape as the packaging defect sprint 1 closed.
    if (($corpusText -match 'Dockerfile') -and ($corpusText -match 'COPY')) {
        Add-Pass "test_manifest_path_corpus.sh derives the worker library layout from the Dockerfile COPY instructions, so removing locate-manifest.js from the COPY line fails a behavioural assertion and not just a structural one"
    } else {
        Add-Fail "test_manifest_path_corpus.sh no longer derives its layout from the Dockerfile COPY instructions; un-shipping locate-manifest.js would then break only structural checks, and a hard-coded list would keep passing against an image whose preflight refuses every session"
    }

    $corpusRows = @(Get-Content -LiteralPath $corpusFixturePath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and $_ -notmatch '^#' })
    $sharedRows = @($corpusRows | Where-Object { $_ -match '\|shared$' })
    if ($sharedRows.Count -ge 12) {
        Add-Pass "manifest-path-corpus.txt declares $($corpusRows.Count) cases, $($sharedRows.Count) of which reach the shared logic from both entry points"
    } else {
        Add-Fail "manifest-path-corpus.txt declares only $($sharedRows.Count) case(s) that reach the shared logic from both entry points (of $($corpusRows.Count) rows); the acceptance criterion lists twelve, and a shrunken corpus quietly narrows the boundary being proved"
    }

    # The subtle behaviours a naive "preserve behaviour" refactor loses. Both are
    # current behaviour, both are easy to get wrong, and neither is obvious from
    # reading the code.
    foreach ($case in @(
        @{ Id = 'symlink-dangling';    Verdict = 'absent'; Why = "fs.existsSync FOLLOWS the link and returns false before the symlink check is reached, so a dangling link is absent rather than unsafe" },
        @{ Id = 'symlink-inside-tree'; Verdict = 'unsafe'; Why = "the rule is 'is this a symlink', not 'does it escape', so a symlink is refused even when it points inside the working tree" }
    )) {
        $row = $corpusRows | Where-Object { $_ -like "$($case.Id)|*" } | Select-Object -First 1
        if ($row -and $row -match "\|$($case.Verdict)\|") {
            Add-Pass "manifest-path-corpus.txt pins $($case.Id) as $($case.Verdict): $($case.Why)"
        } else {
            Add-Fail "manifest-path-corpus.txt no longer pins $($case.Id) as $($case.Verdict); $($case.Why), and a refactor that lost it would change behaviour with no test to say so"
        }
    }
}

# ---------------------------------------------------------------------------
# Egress honesty (capability-manifest future-work sprint 3)
# ---------------------------------------------------------------------------
Write-Section "Egress honesty"

# THIS SPRINT ADDED NO ENFORCEMENT. It made an existing gap visible. The
# decision used to report a declared network destination as satisfied on the ACA
# Jobs plane, which has no per-execution network control at all: `defaultWorker`
# in the catalog is {defaultAction: Allow, hostRules: []}, so egressAllows()
# returned true for any host and `unsatisfiedEgressHosts` came back empty. That
# is a machine-readable assertion of a control that does not exist.
#
# What is checked here is the OPERATOR-FACING half, which the worker bash suite
# cannot reach: what `squad-aca` prints, and what it must never print.

$egressHarness = Join-Path $RepoRoot "scripts\tests\cli-stub-harness.ps1"
$egressCli = Join-Path $RepoRoot "scripts\squad-aca.ps1"
if (-not ((Test-Path $egressHarness) -and $IsWindowsHost -and $nodeAvailable)) {
    Write-Host "  [SKIP] egress honesty CLI checks require Windows + node" -ForegroundColor Yellow
} else {
    . $egressHarness
    $egressStub = $null
    try {
        $egressStub = New-SquadCliStubEnvironment
        Initialize-SquadCliStubRepository -Stub $egressStub | Out-Null
        $egressManifestPath = Join-Path $egressStub.WorkDir "squad-capabilities.yml"

        # A DISTINCTIVE token, so its absence from the operator surface is
        # measured rather than assumed. `git` is already in the default worker
        # profile, so this is the exact reproduction from ADR 0003 finding 3:
        # tools that fit, plus a destination nothing on this plane will enforce.
        $egressToken = "advisory-token-zzz.example.net"
        [System.IO.File]::WriteAllText($egressManifestPath, (@(
            "version: 1"
            "tools:"
            "  - name: git"
            "    required: true"
            "egress:"
            "  - host: $egressToken"
            "    reason: probe"
        ) -join "`n") + "`n")

        Reset-SquadCliStubLog -Stub $egressStub
        $egressRun = Invoke-SquadCliCapture -Stub $egressStub -ScriptPath $egressCli `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "egresshonesty", "do the thing")

        # 1. THE ROUTE DOES NOT MOVE. ACA Jobs is the unconditional default and
        #    the rollback path; a repository that adds two advisory lines to its
        #    manifest must still dispatch. Failing closed here was considered and
        #    rejected in ADR 0003 -- this is the guard on that decision.
        $egressJobStarts = @($egressRun.AzCalls | Where-Object { $_ -like "containerapp job start*" }).Count
        if ($egressRun.ExitCode -eq 0 -and $egressJobStarts -eq 1) {
            Add-Pass "routing: a manifest declaring only advisory egress still dispatches to aca-job (the unconditional default and the rollback path are unchanged)"
        } else {
            Add-Fail "An advisory-egress manifest no longer dispatches: exit=$($egressRun.ExitCode) jobStarts=$egressJobStarts. ACA Jobs is the rollback path; a repository that adds two advisory lines to its manifest would now stop dispatching entirely."
        }

        # 2. THE WARNING EXISTS AND NAMES THE COUNT AND THE ROUTE.
        $egressStreams = "$($egressRun.StdOut)`n$($egressRun.StdErr)"
        if (($egressStreams -match "declares 1 network destination") -and ($egressStreams -match "'aca-job' route will NOT enforce")) {
            Add-Pass "egress honesty: the CLI warns that 1 declared destination will NOT be enforced on the 'aca-job' route"
        } else {
            Add-Fail "The CLI did not warn about unenforced egress. An operator has no way to tell 'this plane will enforce your egress' from 'this plane will ignore it'. stderr=$($egressRun.StdErr)"
        }

        # 3. AND IT PRINTS NO HOST STRING. `egress[].host` is
        #    repository-controlled text; this line lands in an operator's
        #    terminal and in session logs, so echoing it makes the manifest an
        #    injection surface into the place a human reads for reassurance.
        if (($egressRun.StdOut -notmatch [regex]::Escape($egressToken)) -and
            ($egressRun.StdErr -notmatch [regex]::Escape($egressToken))) {
            Add-Pass "egress honesty: a declared host never appears on stdout or stderr (the operator surface states the count, never repository-controlled text)"
        } else {
            Add-Fail "The declared egress host '$egressToken' reached the operator surface. Manifest text is repository-controlled; printing it into a terminal or a log is an injection surface."
        }

        # 4. BOTH DIRECTIONS. A manifest with no egress must produce NO warning:
        #    otherwise the check above is satisfied by a line that is always
        #    printed, and "nothing declared" would read as "unenforced".
        [System.IO.File]::WriteAllText($egressManifestPath, (@(
            "version: 1"
            "tools:"
            "  - name: git"
            "    required: true"
        ) -join "`n") + "`n")
        Reset-SquadCliStubLog -Stub $egressStub
        $quietRun = Invoke-SquadCliCapture -Stub $egressStub -ScriptPath $egressCli `
            -CliArguments @("run", "--repo", "octo/demo", "--name", "egressquiet", "do the thing")
        $quietStreams = "$($quietRun.StdOut)`n$($quietRun.StdErr)"
        if ($quietRun.ExitCode -eq 0 -and $quietStreams -notmatch "will NOT enforce") {
            Add-Pass "egress honesty: a manifest declaring no egress produces no unenforced-destination warning (nothing declared is not unenforced)"
        } else {
            Add-Fail "A manifest declaring NO egress still warned about unenforced destinations (exit=$($quietRun.ExitCode)); the warning is unconditional, so its presence proves nothing."
        }
        Remove-Item -LiteralPath $egressManifestPath -Force -ErrorAction SilentlyContinue
    } finally {
        if ($egressStub) { Remove-SquadCliStubEnvironment -Stub $egressStub }
    }
}

# The corrected in-worker message. The old text said "advisory only, not
# enforced yet" on BOTH planes, which is wrong inside a sandbox: the sandbox
# provider generated a default-deny policy from the approved class template and
# applied it before this script ran.
$preflightPath = Join-Path $RepoRoot "worker\lib\squad-capability-preflight.sh"
if (Test-Path $preflightPath) {
    $preflightText = [System.IO.File]::ReadAllText($preflightPath)
    if ($preflightText -notmatch "advisory only, not enforced yet") {
        Add-Pass "preflight: the stale 'advisory only, not enforced yet' egress message is gone (it contradicted the sandbox provider, which does enforce)"
    } else {
        Add-Fail "worker/lib/squad-capability-preflight.sh still prints 'advisory only, not enforced yet' for a declared egress host. That is false inside a sandbox, where New-SandboxEgressPolicy generated and applied a default-deny policy before the session started."
    }
    if (($preflightText -match "SQUAD_EXECUTION_MODE") -and ($preflightText -match "NOT ENFORCED on this plane")) {
        Add-Pass "preflight: the egress advisory is plane-aware, keyed on SQUAD_EXECUTION_MODE, and defaults to reporting NOT enforced"
    } else {
        Add-Fail "worker/lib/squad-capability-preflight.sh no longer distinguishes the enforcing plane from the non-enforcing one; one message cannot be true on both."
    }
} else {
    Add-Fail "worker/lib/squad-capability-preflight.sh is missing"
}

# The decision core itself must not derive the claim from the route name. That
# is the abandon condition in the sprint plan: a flag read off `route` is a
# restatement of `route` and adds nothing.
$resolverPath = Join-Path $RepoRoot "worker\lib\resolve-capability-route.js"
if (Test-Path $resolverPath) {
    $resolverText = [System.IO.File]::ReadAllText($resolverPath)
    if ($resolverText -match "function egressPolicyEnforced\([^)]*\)\s*\{[^}]*defaultAction === 'Deny'") {
        Add-Pass "egress honesty: egressEnforced is derived from the selected profile's egress.defaultAction, not from the route name"
    } else {
        Add-Fail "egressPolicyEnforced no longer reads the policy's defaultAction. A flag derived from the route name is a restatement of the route and backs no claim about the policy."
    }
    if ($resolverText -match "ROUTE_ACA_JOB ===|route === ROUTE_ACA_JOB\s*\?\s*false") {
        Add-Fail "The resolver derives an egress claim from the route name."
    } else {
        Add-Pass "egress honesty: the resolver contains no route-name test that could stand in for the policy check"
    }
} else {
    Add-Fail "worker/lib/resolve-capability-route.js is missing"
}

# The worker suite must actually carry the honesty corpus. Sprint 2 learned that
# a check which only counts files stays green while the cases it names are
# deleted, so the named assertions are looked for individually.
$egressSuite = Join-Path $RepoRoot "worker\tests\test_egress_honesty.sh"
if (Test-Path $egressSuite) {
    $egressSuiteText = [System.IO.File]::ReadAllText($egressSuite)
    $requiredCases = @(
        "an egress-declaring manifest on the aca-job route reports egressEnforced false",
        "an egress-declaring manifest routed to an approved sandbox class reports egressEnforced true",
        "a manifest declaring no egress reports egressEnforced true",
        "a default profile with defaultAction Deny reports egressEnforced true on the aca-job route",
        "a manifest declaring only advisory egress still dispatches to aca-job"
    )
    $missingCases = @($requiredCases | Where-Object { $egressSuiteText -notmatch [regex]::Escape($_) })
    if ($missingCases.Count -eq 0) {
        Add-Pass "worker/tests/test_egress_honesty.sh carries all $($requiredCases.Count) paired egress claims (both directions of the boolean, the policy-not-route case, and the unconditional-default guard)"
    } else {
        Add-Fail "worker/tests/test_egress_honesty.sh is missing $($missingCases.Count) named case(s): $($missingCases -join '; '). A boolean asserted in one direction only is satisfied by a constant."
    }
} else {
    Add-Fail "worker/tests/test_egress_honesty.sh is missing; the egress honesty claims have no corpus"
}

# ---------------------------------------------------------------------------
# Every workflow file must PARSE (issue #32 S4)
# ---------------------------------------------------------------------------
Write-Section "Workflow files parse as YAML"

# This gate exists because sprints 3 and 4 both merged a workflow GitHub could
# not parse, and every check in this file passed.
#
# The failure mode is unusually quiet. An unparseable workflow is not a failed
# STEP -- it is a failed RUN, named after the FILE rather than a job, with no
# jobs and no log to read. `gh run view --log-failed` answers "log not found".
# Meanwhile CI stays green, because CI runs validate.ps1 and the worker suite,
# and neither of them parsed YAML.
#
# The specific trap: inside a YAML block scalar (`run: |`), a line beginning at
# COLUMN 0 ENDS the block. A markdown table or a multi-line commit message
# written literally is all column-0 lines. Grep-based checks cannot see this --
# every string they look for is still present in the file.
$workflowDir = Join-Path $RepoRoot '.github/workflows'
if (-not (Test-Path $workflowDir)) {
    Add-Fail ".github/workflows is missing"
} else {
    $workflowFiles = @(Get-ChildItem -LiteralPath $workflowDir -Filter '*.yml' -File) +
                     @(Get-ChildItem -LiteralPath $workflowDir -Filter '*.yaml' -File)

    if ($workflowFiles.Count -eq 0) {
        Add-Fail "No workflow files found to parse"
    }

    $yamlParser = $null
    foreach ($candidate in @('python', 'python3', 'py')) {
        $probe = & $candidate -c "import yaml; print('ok')" 2>$null
        if ($LASTEXITCODE -eq 0 -and $probe -match 'ok') { $yamlParser = $candidate; break }
    }

    if (-not $yamlParser) {
        Add-Skip "No Python with PyYAML available to parse workflow files. A workflow that does not parse fails as a run with no job and no log, and nothing else here would catch it."
    } else {
        $bashExe = $null
        foreach ($candidate in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', 'bash')) {
            if (Get-Command $candidate -ErrorAction SilentlyContinue) { $bashExe = $candidate; break }
        }
        if (-not $bashExe) {
            Add-Skip "No bash available to syntax-check workflow run blocks."
        }

        foreach ($wfFile in ($workflowFiles | Sort-Object Name)) {
            $parseOutput = & $yamlParser -c @"
import sys, yaml
p = sys.argv[1]
try:
    d = yaml.safe_load(open(p, encoding='utf-8'))
except Exception as e:
    print('PARSE-ERROR ' + str(e).replace('\n', ' | '))
    sys.exit(0)
if not isinstance(d, dict):
    print('PARSE-ERROR the document is not a mapping')
    sys.exit(0)
# `on` is the YAML 1.1 boolean True, so a parsed workflow has either.
if 'jobs' not in d or not d.get('jobs'):
    print('PARSE-ERROR no jobs')
    sys.exit(0)
if ('on' not in d) and (True not in d):
    print('PARSE-ERROR no trigger')
    sys.exit(0)
print('OK')
"@ $wfFile.FullName 2>&1

            $joined = ($parseOutput -join ' ').Trim()
            if ($joined -match '^OK') {
                Add-Pass "$($wfFile.Name) parses as YAML and declares a trigger and at least one job"
            } else {
                Add-Fail "$($wfFile.Name) does not parse as a GitHub workflow ($joined). GitHub reports this as a failed RUN named after the file, with no job and no log -- and no grep-based check can see it, because a column-0 line inside a 'run: |' block ends the block while leaving every searched string in place"
            }

        # Every `run:` block is a shell script that nothing else here executes.
        # A syntax error in one is a failure that only appears at dispatch time,
        # halfway through a live run, after Azure has already been paid.
        #
        # This catches SYNTAX. It cannot catch ordering -- `set -u` finding a
        # variable used before assignment is a RUNTIME error, and the live
        # end-to-end run remains the only gate for that. Both are worth having;
        # neither replaces the other.
        if ($bashExe) {
            $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("squad-wf-run-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            try {
                $extract = & $yamlParser -c @"
import sys, os, yaml
src, outdir = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(src, encoding='utf-8'))
n = 0
for job_name, job in (d.get('jobs') or {}).items():
    default_shell = ((d.get('defaults') or {}).get('run') or {}).get('shell') or \
                    ((job.get('defaults') or {}).get('run') or {}).get('shell') or 'bash'
    for i, step in enumerate(job.get('steps') or []):
        if not isinstance(step, dict) or 'run' not in step:
            continue
        shell = step.get('shell') or default_shell
        if str(shell).lower() not in ('bash', 'sh'):
            continue
        n += 1
        path = os.path.join(outdir, '%s-%s-%d.sh' % (os.path.basename(src), job_name, i))
        open(path, 'w', encoding='utf-8', newline='\n').write(str(step['run']))
print(n)
"@ $wfFile.FullName $extractDir 2>&1

                $blockCount = 0
                [int]::TryParse((($extract -join '').Trim()), [ref]$blockCount) | Out-Null
                $scripts = @(Get-ChildItem -LiteralPath $extractDir -Filter '*.sh' -File -ErrorAction SilentlyContinue)

                if ($scripts.Count -eq 0) {
                    Add-Pass "$($wfFile.Name) has no shell run blocks to syntax-check"
                } else {
                    $bad = @()
                    foreach ($script in $scripts) {
                        $syntax = & $bashExe -n $script.FullName 2>&1
                        if ($LASTEXITCODE -ne 0) { $bad += "$($script.Name): $($syntax -join ' ')" }
                    }
                    if ($bad.Count -eq 0) {
                        Add-Pass "All $($scripts.Count) shell run block(s) in $($wfFile.Name) parse under bash -n, so a syntax error cannot wait until dispatch time to appear"
                    } else {
                        Add-Fail "A shell run block in $($wfFile.Name) does not parse: $($bad -join ' | ')"
                    }
                }
            } finally {
                Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        }
    }
}

# ---------------------------------------------------------------------------
# RBAC drift check (CV-1, issue #85)
# ---------------------------------------------------------------------------
Write-Section "RBAC drift check (CV-1)"

# CV-1's binding contract (.squad/decisions/inbox/security-cv1-rbac-contract.md)
# requires a strict reader/pure-comparer split: exactly ONE file may invoke
# `az`, through a single allowlisted chokepoint, and the comparer that decides
# pass/fail must be provably free of any Azure CLI call. This section checks
# both the static shape of that split AND its runtime behaviour: every deny
# rule actually refuses (observed as a thrown error with zero calls reaching
# the CLI), every allowed read actually reaches it, a live-mode round trip
# through a stub `az` reproduces the exact drift security's contract
# describes, and no raw identifier ever appears in the tool's rendered output.
$rbacReaderPath = Join-Path $RepoRoot "scripts\lib\rbac-drift-reader.ps1"
$rbacComparePath = Join-Path $RepoRoot "scripts\lib\rbac-drift-compare.ps1"
$rbacCheckPath = Join-Path $RepoRoot "scripts\rbac-drift-check.ps1"
$rbacStubHarnessPath = Join-Path $RepoRoot "scripts\tests\rbac-drift-stub-harness.ps1"
$rbacFixtureDir = Join-Path $RepoRoot "scripts\tests\fixtures\rbac-drift"
$rbacRequiredFiles = @(
    @{ Path = $rbacReaderPath; Label = "scripts/lib/rbac-drift-reader.ps1" },
    @{ Path = $rbacComparePath; Label = "scripts/lib/rbac-drift-compare.ps1" },
    @{ Path = $rbacCheckPath; Label = "scripts/rbac-drift-check.ps1" },
    @{ Path = $rbacStubHarnessPath; Label = "scripts/tests/rbac-drift-stub-harness.ps1" }
)
$rbacMissingFiles = @($rbacRequiredFiles | Where-Object { -not (Test-Path -LiteralPath $_.Path) })
if ($rbacMissingFiles.Count -eq 0) {
    Add-Pass "All CV-1 source files are present (reader, comparer, entrypoint, stub harness)"
} else {
    Add-Fail "CV-1 is missing file(s): $(($rbacMissingFiles | ForEach-Object { $_.Label }) -join ', ')"
}

$rbacFixtureNames = @("clean-gha-present", "clean-gha-absent", "drifted-scope", "unexpected-principal")
$rbacFixturePaths = @{}
foreach ($name in $rbacFixtureNames) { $rbacFixturePaths[$name] = Join-Path $rbacFixtureDir "$name.json" }
$rbacMissingFixtures = @($rbacFixtureNames | Where-Object { -not (Test-Path -LiteralPath $rbacFixturePaths[$_]) })
if ($rbacMissingFixtures.Count -eq 0) {
    Add-Pass "All 4 CV-1 fixtures are present (clean-gha-present, clean-gha-absent, drifted-scope, unexpected-principal)"
} else {
    Add-Fail "CV-1 is missing fixture(s): $($rbacMissingFixtures -join ', ')"
}

if ((Test-Path -LiteralPath $rbacReaderPath) -and (Test-Path -LiteralPath $rbacComparePath) -and (Test-Path -LiteralPath $rbacCheckPath)) {
    $rbacReaderText = Get-Content -LiteralPath $rbacReaderPath -Raw
    $rbacCompareText = Get-Content -LiteralPath $rbacComparePath -Raw
    $rbacCheckText = Get-Content -LiteralPath $rbacCheckPath -Raw
    # Lowercase, standalone "az" only -- deliberately excludes "Azure",
    # "AcrPull", "Invoke-AzRead" (capital A) so this does not false-positive
    # on the many legitimate prose/identifier uses of that substring.
    $rbacAzTokenPattern = '(?<![A-Za-z0-9_])az(?![A-Za-z0-9_])'

    if ($rbacCompareText -notmatch $rbacAzTokenPattern) {
        Add-Pass "scripts/lib/rbac-drift-compare.ps1 contains no standalone 'az' token -- the comparer that decides pass/fail cannot itself call Azure"
    } else {
        Add-Fail "scripts/lib/rbac-drift-compare.ps1 contains a standalone 'az' token; the pure comparer must never reference the Azure CLI"
    }

    # The single real chokepoint: Invoke-AzRead's own call to the `az`
    # executable. Asserting there is exactly one such call site in the reader,
    # and zero in the comparer/entrypoint, is the direct proof of "one file
    # invokes az, through one path" rather than an assumption about it.
    $rbacInvokeSitePattern = '-FilePath\s+"az"'
    $rbacReaderInvokeSites = @([regex]::Matches($rbacReaderText, $rbacInvokeSitePattern))
    $rbacCompareInvokeSites = @([regex]::Matches($rbacCompareText, $rbacInvokeSitePattern))
    $rbacCheckInvokeSites = @([regex]::Matches($rbacCheckText, $rbacInvokeSitePattern))
    if ($rbacReaderInvokeSites.Count -eq 1 -and $rbacCompareInvokeSites.Count -eq 0 -and $rbacCheckInvokeSites.Count -eq 0) {
        Add-Pass "Exactly one call site invokes the 'az' executable, and it lives in scripts/lib/rbac-drift-reader.ps1 (not the comparer or entrypoint)"
    } else {
        Add-Fail "CV-1's single-chokepoint claim does not hold: reader has $($rbacReaderInvokeSites.Count) az invocation site(s), comparer has $($rbacCompareInvokeSites.Count), entrypoint has $($rbacCheckInvokeSites.Count) (expected 1/0/0)"
    }

    if ($rbacReaderText -match [regex]::Escape('"--include-inherited"') -and $rbacReaderText -match [regex]::Escape('account set')) {
        Add-Pass "scripts/lib/rbac-drift-reader.ps1 names both '--include-inherited' and 'account set' as literals -- the two banned operations security's contract (rules 1 and 3) requires the reader to refuse"
    } else {
        Add-Fail "scripts/lib/rbac-drift-reader.ps1 does not reference both banned literals ('--include-inherited', 'account set'); the deny checks cannot be verified from source"
    }
    if ($rbacCompareText -notmatch [regex]::Escape('--include-inherited')) {
        Add-Pass "'--include-inherited' never appears in the pure comparer, which has no reason to reference an Azure CLI flag"
    } else {
        Add-Fail "'--include-inherited' leaked into the comparer, where it has no reason to appear"
    }
}

$rbacPsExe = (Get-Process -Id $PID).Path

# Runtime: every deny rule in Invoke-AzRead must actually refuse -- observed
# as a thrown error AND zero calls reaching the stub `az`. A rule that merely
# looks right in source but silently lets a call through would be invisible
# to every check above. The stub is a .cmd shim, so this (like the existing
# CLI regression suite) requires Windows.
if (-not $IsWindowsHost) {
    Write-Host "  [SKIP] CV-1 stub-driven Invoke-AzRead deny/allow checks require Windows (.cmd stub)" -ForegroundColor Yellow
} elseif ((Test-Path -LiteralPath $rbacReaderPath) -and (Test-Path -LiteralPath $rbacStubHarnessPath)) {
    . $rbacReaderPath
    . $rbacStubHarnessPath
    $rbacStub = $null
    $rbacPrevPath = $env:PATH
    $rbacPrevLog = $env:SQUAD_RBAC_STUB_LOG
    try {
        $rbacStub = New-RbacDriftStubEnvironment
        $env:PATH = "$($rbacStub.BinDir);$rbacPrevPath"
        $env:SQUAD_RBAC_STUB_LOG = $rbacStub.AzLog

        $rbacDenyCases = @(
            @{ Name = "a mutating 'create' verb"; Args = @("role", "assignment", "create", "--assignee", "x", "--role", "Contributor", "--scope", "y", "--subscription", $script:RbacDriftStubSubscriptionId) },
            @{ Name = "a mutating 'delete' verb"; Args = @("role", "assignment", "delete", "--ids", "x", "--subscription", $script:RbacDriftStubSubscriptionId) },
            @{ Name = "'az account set'"; Args = @("account", "set", "--subscription", $script:RbacDriftStubSubscriptionId) },
            @{ Name = "'--include-inherited'"; Args = @("role", "assignment", "list", "--scope", "y", "--include-inherited", "--subscription", $script:RbacDriftStubSubscriptionId) },
            @{ Name = "a call with no --subscription"; Args = @("identity", "show", "--name", "x", "--resource-group", "y") },
            @{ Name = "an unlisted command shape"; Args = @("storage", "account", "list", "--subscription", $script:RbacDriftStubSubscriptionId) }
        )
        $rbacDenyFailures = @()
        foreach ($case in $rbacDenyCases) {
            Reset-RbacDriftStubLog -Stub $rbacStub
            $threw = $false
            try { Invoke-AzRead -AzArgs $case.Args | Out-Null } catch { $threw = $true }
            $callsMade = @(Get-RbacDriftStubCalls -Stub $rbacStub)
            if (-not $threw -or $callsMade.Count -ne 0) {
                $rbacDenyFailures += "$($case.Name) (threw=$threw, calls reaching az=$($callsMade.Count))"
            }
        }
        if ($rbacDenyFailures.Count -eq 0) {
            Add-Pass "Invoke-AzRead refuses all $($rbacDenyCases.Count) denied shapes (mutating verbs, --include-inherited, account set, missing --subscription, an unlisted command) with zero calls ever reaching az"
        } else {
            Add-Fail "Invoke-AzRead let a denied shape through: $($rbacDenyFailures -join '; ')"
        }

        Reset-RbacDriftStubLog -Stub $rbacStub
        $rbacAllowResult = $null
        $rbacAllowThrew = $false
        try {
            $rbacAllowResult = Invoke-AzRead -AzArgs @("account", "show", "--subscription", $script:RbacDriftStubSubscriptionId, "-o", "json")
        } catch { $rbacAllowThrew = $true }
        $rbacAllowCalls = @(Get-RbacDriftStubCalls -Stub $rbacStub)
        if (-not $rbacAllowThrew -and $rbacAllowResult.ExitCode -eq 0 -and $rbacAllowCalls.Count -eq 1) {
            Add-Pass "Invoke-AzRead allows a properly-shaped, subscription-pinned read through to az (proves the chokepoint denies by rule, not by refusing everything)"
        } else {
            Add-Fail "Invoke-AzRead did not allow a legitimate read through as expected (threw=$rbacAllowThrew, calls=$($rbacAllowCalls.Count))"
        }
    } finally {
        $env:PATH = $rbacPrevPath
        if ($null -eq $rbacPrevLog) { Remove-Item Env:SQUAD_RBAC_STUB_LOG -ErrorAction SilentlyContinue } else { $env:SQUAD_RBAC_STUB_LOG = $rbacPrevLog }
        if ($rbacStub) { Remove-RbacDriftStubEnvironment -Stub $rbacStub }
    }
} else {
    Add-Fail "Cannot exercise Invoke-AzRead's deny/allow rules; reader or stub harness is missing"
}

# Runtime, child-process observed exit codes: each committed fixture must
# drive the REAL process exit code security's contract keys everything off
# of -- not just the in-process $LASTEXITCODE convention, but what a caller
# (a human, or a future CI gate) actually observes.
if ((Test-Path -LiteralPath $rbacCheckPath) -and $rbacMissingFixtures.Count -eq 0) {
    $rbacFixtureExpectedExit = @{
        "clean-gha-present"    = 0
        "clean-gha-absent"     = 0
        "drifted-scope"        = 1
        "unexpected-principal" = 1
    }
    $rbacFixtureFailures = @()
    $rbacFixtureGuidLeaks = @()
    $rbacGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    foreach ($name in $rbacFixtureNames) {
        $fixturePath = $rbacFixturePaths[$name]
        $procOut = & $rbacPsExe -NoProfile -NonInteractive -File $rbacCheckPath -Fixture $fixturePath -Json 2>&1 | Out-String
        $observedExit = $LASTEXITCODE
        if ($observedExit -ne $rbacFixtureExpectedExit[$name]) {
            $rbacFixtureFailures += "$name`: exit $observedExit, expected $($rbacFixtureExpectedExit[$name])"
        }
        if ($procOut -match $rbacGuidPattern) {
            $rbacFixtureGuidLeaks += $name
        }
    }
    if ($rbacFixtureFailures.Count -eq 0) {
        Add-Pass "All 4 committed fixtures drive the real child-process exit code security's contract keys off of (clean=0, clean-absent=0, drifted-scope=1, unexpected-principal=1)"
    } else {
        Add-Fail "A fixture's observed child-process exit code did not match the contract: $($rbacFixtureFailures -join '; ')"
    }
    if ($rbacFixtureGuidLeaks.Count -eq 0) {
        Add-Pass "Rendered JSON output for all 4 fixtures contains no GUID-shaped identifier"
    } else {
        Add-Fail "Rendered JSON output leaked a GUID-shaped identifier for fixture(s): $($rbacFixtureGuidLeaks -join ', ')"
    }
} else {
    Add-Fail "Cannot run fixture-driven child-process checks; entrypoint or a fixture is missing"
}

# Runtime, stub-harness-driven live round trip: the strongest proof available
# without touching real Azure. The stub's `az.cmd` answers with the EXACT
# shape security's contract reports the real deployment holds today (session
# identity keeps a stale Contributor grant, lacks the job-scoped grant,
# GitHub Actions identity absent) and the fully-clean counterpart. This
# proves the reader's live capture path -- discovery, redaction, scope
# classification -- end to end, not just the comparer against a canned
# fixture. Requires Windows (.cmd stub), like the deny/allow checks above.
if (-not $IsWindowsHost) {
    Write-Host "  [SKIP] CV-1 stub-driven live-mode round trip requires Windows (.cmd stub)" -ForegroundColor Yellow
} elseif ((Test-Path -LiteralPath $rbacCheckPath) -and (Test-Path -LiteralPath $rbacStubHarnessPath)) {
    . $rbacStubHarnessPath
    $rbacStub2 = $null
    try {
        $rbacStub2 = New-RbacDriftStubEnvironment
        $rbacGuidPattern2 = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

        $rbacDrifted = Invoke-RbacDriftCliCapture -Stub $rbacStub2 -ScriptPath $rbacCheckPath
        $rbacDriftedOk = ($rbacDrifted.ExitCode -eq 1) -and
            ($rbacDrifted.StdOut -match "missingAssignment") -and
            ($rbacDrifted.StdOut -match "unexpectedScope") -and
            ($rbacDrifted.StdOut -match "absentOptionalPrincipal") -and
            ($rbacDrifted.StdOut -notmatch "unexpectedPrincipal")
        if ($rbacDriftedOk) {
            Add-Pass "Live-mode round trip via the stub reproduces the exact drift security's contract reports today (Contributor unexpectedScope + missing job-scope grant + absent GitHub Actions identity) and exits 1"
        } else {
            Add-Fail "Live-mode drifted round trip did not match the expected shape (exit=$($rbacDrifted.ExitCode)): $($rbacDrifted.StdOut)"
        }

        $rbacDriftedCallChecks = @()
        foreach ($call in $rbacDrifted.AzCalls) {
            if ($call -notmatch [regex]::Escape("--subscription")) { $rbacDriftedCallChecks += "call missing --subscription: $call" }
            if ($call -match [regex]::Escape("--include-inherited")) { $rbacDriftedCallChecks += "call used --include-inherited: $call" }
            if ($call -match "^account set\b") { $rbacDriftedCallChecks += "call was 'account set': $call" }
        }
        if ($rbacDrifted.AzCalls.Count -gt 0 -and $rbacDriftedCallChecks.Count -eq 0) {
            Add-Pass "Every one of the $($rbacDrifted.AzCalls.Count) az call(s) the live round trip issued pins --subscription, and none used --include-inherited or 'account set'"
        } else {
            Add-Fail "The live round trip's az call log violates a read-only invariant: $($rbacDriftedCallChecks -join '; ')"
        }
        if ($rbacDrifted.StdOut -notmatch $rbacGuidPattern2) {
            Add-Pass "Live-mode drifted round trip's rendered output contains no GUID-shaped identifier, even though the stub's underlying data is GUID-shaped"
        } else {
            Add-Fail "Live-mode drifted round trip leaked a GUID-shaped identifier into rendered output"
        }

        $rbacClean = Invoke-RbacDriftCliCapture -Stub $rbacStub2 -ScriptPath $rbacCheckPath -Clean
        $rbacCleanOk = ($rbacClean.ExitCode -eq 0) -and
            ($rbacClean.StdOut -notmatch "missingAssignment") -and
            ($rbacClean.StdOut -notmatch "unexpectedScope") -and
            ($rbacClean.StdOut -notmatch "unexpectedPrincipal")
        if ($rbacCleanOk) {
            Add-Pass "Live-mode round trip via the stub's fully-clean deployment shape exits 0 with no high-severity finding"
        } else {
            Add-Fail "Live-mode clean round trip did not exit 0 / had a high-severity finding (exit=$($rbacClean.ExitCode)): $($rbacClean.StdOut)"
        }
        if ($rbacClean.StdOut -notmatch $rbacGuidPattern2) {
            Add-Pass "Live-mode clean round trip's rendered output contains no GUID-shaped identifier"
        } else {
            Add-Fail "Live-mode clean round trip leaked a GUID-shaped identifier into rendered output"
        }

        # Registry discovery: omitting -AcrName must still resolve the one
        # registry the stub's resource group holds and reproduce the same
        # drifted result, proving the "unambiguous discovery" fallback path
        # (not just the explicit-AcrName path every other case above uses).
        $rbacDiscovery = Invoke-RbacDriftCliCapture -Stub $rbacStub2 -ScriptPath $rbacCheckPath -CliArguments @()
        if ($rbacDiscovery.ExitCode -eq 1 -and $rbacDiscovery.StdOut -match "missingAssignment") {
            Add-Pass "Omitting -AcrName still resolves the registry via unambiguous single-registry discovery and reproduces the drifted result"
        } else {
            Add-Fail "Registry discovery path did not reproduce the expected drifted result (exit=$($rbacDiscovery.ExitCode))"
        }
    } finally {
        if ($rbacStub2) { Remove-RbacDriftStubEnvironment -Stub $rbacStub2 }
    }
} else {
    Add-Fail "Cannot run the stub-harness-driven live round trip; entrypoint or stub harness is missing"
}

# Fail-closed intent resolution: with no explicit parameters and no reachable
# deploy.outputs.json, the check must exit 2 -- never guess, never fall back
# to an ambient subscription. -DeployOutputsPath points at a guaranteed-absent
# path so this is deterministic regardless of what a developer's own machine
# happens to have on disk.
if (Test-Path -LiteralPath $rbacCheckPath) {
    $rbacAbsentOutputs = Join-Path $RepoRoot "scripts\tests\fixtures\rbac-drift\.does-not-exist.json"
    & $rbacPsExe -NoProfile -NonInteractive -File $rbacCheckPath -DeployOutputsPath $rbacAbsentOutputs 2>&1 | Out-Null
    $rbacFailClosedExit = $LASTEXITCODE
    if ($rbacFailClosedExit -eq 2) {
        Add-Pass "With no explicit parameters and no reachable deploy.outputs.json, the check exits 2 (fails closed instead of guessing a subscription)"
    } else {
        Add-Fail "Unresolved intent did not exit 2 as the fail-closed contract requires (observed exit $rbacFailClosedExit)"
    }
} else {
    Add-Fail "Cannot exercise fail-closed intent resolution; entrypoint is missing"
}

# Redaction: the 4 committed fixtures are themselves the evidence a reviewer
# would attach to a PR. None may carry a real GUID -- if one did, redaction
# would have to be trusted rather than checked.
if ($rbacMissingFixtures.Count -eq 0) {
    $rbacGuidPattern3 = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $rbacFixtureLeaks = @()
    foreach ($name in $rbacFixtureNames) {
        $text = Get-Content -LiteralPath $rbacFixturePaths[$name] -Raw
        if ($text -match $rbacGuidPattern3) { $rbacFixtureLeaks += $name }
    }
    if ($rbacFixtureLeaks.Count -eq 0) {
        Add-Pass "None of the 4 committed CV-1 fixtures contain a GUID-shaped identifier"
    } else {
        Add-Fail "Fixture(s) contain a GUID-shaped identifier: $($rbacFixtureLeaks -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# Job / environment drift check (CV-2, issue #85)
# ---------------------------------------------------------------------------
Write-Section "Job/environment drift check (CV-2)"

# CV-2 mirrors CV-1's reader/pure-comparer split: exactly ONE file may invoke
# `az`, through a single allowlisted chokepoint, and the comparer that decides
# pass/fail must be provably free of any Azure CLI call. This section checks
# both the static shape of that split AND its runtime behaviour: every deny
# rule actually refuses, a live-mode round trip through a stub `az` reproduces
# an inlined secret and an unexpected identity (the two drifted cases issue
# #85 CV-2 names explicitly), and the fully-clean counterpart passes.
$jobReaderPath = Join-Path $RepoRoot "scripts\lib\job-drift-reader.ps1"
$jobComparePath = Join-Path $RepoRoot "scripts\lib\job-drift-compare.ps1"
$jobCheckPath = Join-Path $RepoRoot "scripts\job-drift-check.ps1"
$jobStubHarnessPath = Join-Path $RepoRoot "scripts\tests\job-drift-stub-harness.ps1"
$jobFixtureDir = Join-Path $RepoRoot "scripts\tests\fixtures\job-drift"
$jobRequiredFiles = @(
    @{ Path = $jobReaderPath; Label = "scripts/lib/job-drift-reader.ps1" },
    @{ Path = $jobComparePath; Label = "scripts/lib/job-drift-compare.ps1" },
    @{ Path = $jobCheckPath; Label = "scripts/job-drift-check.ps1" },
    @{ Path = $jobStubHarnessPath; Label = "scripts/tests/job-drift-stub-harness.ps1" }
)
$jobMissingFiles = @($jobRequiredFiles | Where-Object { -not (Test-Path -LiteralPath $_.Path) })
if ($jobMissingFiles.Count -eq 0) {
    Add-Pass "All CV-2 source files are present (reader, comparer, entrypoint, stub harness)"
} else {
    Add-Fail "CV-2 is missing file(s): $(($jobMissingFiles | ForEach-Object { $_.Label }) -join ', ')"
}

$jobFixtureNames = @("clean-hub-present", "clean-hub-absent", "extra-identity", "inlined-secret", "stale-local-record", "genuine-image-drift")
$jobFixturePaths = @{}
foreach ($name in $jobFixtureNames) { $jobFixturePaths[$name] = Join-Path $jobFixtureDir "$name.json" }
$jobMissingFixtures = @($jobFixtureNames | Where-Object { -not (Test-Path -LiteralPath $jobFixturePaths[$_]) })
if ($jobMissingFixtures.Count -eq 0) {
    Add-Pass "All 6 CV-2 fixtures are present (clean-hub-present, clean-hub-absent, extra-identity, inlined-secret, stale-local-record, genuine-image-drift)"
} else {
    Add-Fail "CV-2 is missing fixture(s): $($jobMissingFixtures -join ', ')"
}

if ((Test-Path -LiteralPath $jobReaderPath) -and (Test-Path -LiteralPath $jobComparePath) -and (Test-Path -LiteralPath $jobCheckPath)) {
    $jobReaderText = Get-Content -LiteralPath $jobReaderPath -Raw
    $jobCompareText = Get-Content -LiteralPath $jobComparePath -Raw
    $jobCheckText = Get-Content -LiteralPath $jobCheckPath -Raw
    $jobAzTokenPattern = '(?<![A-Za-z0-9_])az(?![A-Za-z0-9_])'

    if ($jobCompareText -notmatch $jobAzTokenPattern) {
        Add-Pass "scripts/lib/job-drift-compare.ps1 contains no standalone 'az' token -- the comparer that decides pass/fail cannot itself call Azure"
    } else {
        Add-Fail "scripts/lib/job-drift-compare.ps1 contains a standalone 'az' token; the pure comparer must never reference the Azure CLI"
    }

    $jobInvokeSitePattern = '-FilePath\s+"az"'
    $jobReaderInvokeSites = @([regex]::Matches($jobReaderText, $jobInvokeSitePattern))
    $jobCompareInvokeSites = @([regex]::Matches($jobCompareText, $jobInvokeSitePattern))
    $jobCheckInvokeSites = @([regex]::Matches($jobCheckText, $jobInvokeSitePattern))
    if ($jobReaderInvokeSites.Count -eq 1 -and $jobCompareInvokeSites.Count -eq 0 -and $jobCheckInvokeSites.Count -eq 0) {
        Add-Pass "Exactly one call site invokes the 'az' executable, and it lives in scripts/lib/job-drift-reader.ps1 (not the comparer or entrypoint)"
    } else {
        Add-Fail "CV-2's single-chokepoint claim does not hold: reader has $($jobReaderInvokeSites.Count) az invocation site(s), comparer has $($jobCompareInvokeSites.Count), entrypoint has $($jobCheckInvokeSites.Count) (expected 1/0/0)"
    }
}

$jobPsExe = (Get-Process -Id $PID).Path

# Runtime: every deny rule in Invoke-JobAzRead must actually refuse -- observed
# as a thrown error AND zero calls reaching the stub `az`.
if (-not $IsWindowsHost) {
    Write-Host "  [SKIP] CV-2 stub-driven Invoke-JobAzRead deny/allow checks require Windows (.cmd stub)" -ForegroundColor Yellow
} elseif ((Test-Path -LiteralPath $jobReaderPath) -and (Test-Path -LiteralPath $jobStubHarnessPath)) {
    . $jobReaderPath
    . $jobStubHarnessPath
    $jobStub = $null
    $jobPrevPath = $env:PATH
    $jobPrevLog = $env:SQUAD_JOB_DRIFT_AZ_LOG
    try {
        $jobStub = New-JobDriftStubEnvironment
        $env:PATH = "$($jobStub.BinDir);$jobPrevPath"
        $env:SQUAD_JOB_DRIFT_AZ_LOG = $jobStub.AzLog

        $jobDenyCases = @(
            @{ Name = "a mutating 'create' verb"; Args = @("containerapp", "job", "create", "--name", "x", "--resource-group", "y", "--subscription", $script:JobDriftStubSubscriptionId) },
            @{ Name = "a mutating 'update' verb"; Args = @("containerapp", "job", "update", "--name", "x", "--resource-group", "y", "--subscription", $script:JobDriftStubSubscriptionId) },
            @{ Name = "'az account set'"; Args = @("account", "set", "--subscription", $script:JobDriftStubSubscriptionId) },
            @{ Name = "a secret-reading verb"; Args = @("containerapp", "job", "secret", "show", "--name", "x", "--resource-group", "y", "--subscription", $script:JobDriftStubSubscriptionId) },
            @{ Name = "a call with no --subscription"; Args = @("containerapp", "job", "show", "--name", "x", "--resource-group", "y") },
            @{ Name = "an unlisted command shape"; Args = @("storage", "account", "list", "--subscription", $script:JobDriftStubSubscriptionId) }
        )
        $jobDenyFailures = @()
        foreach ($case in $jobDenyCases) {
            Reset-JobDriftStubLog -Stub $jobStub
            $threw = $false
            try { Invoke-JobAzRead -AzArgs $case.Args | Out-Null } catch { $threw = $true }
            $callsMade = @(Get-JobDriftStubCalls -Stub $jobStub)
            if (-not $threw -or $callsMade.Count -ne 0) {
                $jobDenyFailures += "$($case.Name) (threw=$threw, calls reaching az=$($callsMade.Count))"
            }
        }
        if ($jobDenyFailures.Count -eq 0) {
            Add-Pass "Invoke-JobAzRead refuses all $($jobDenyCases.Count) denied shapes (mutating verbs, account set, a secret-reading verb, missing --subscription, an unlisted command) with zero calls ever reaching az"
        } else {
            Add-Fail "Invoke-JobAzRead let a denied shape through: $($jobDenyFailures -join '; ')"
        }

        Reset-JobDriftStubLog -Stub $jobStub
        $jobAllowResult = $null
        $jobAllowThrew = $false
        try {
            $jobAllowResult = Invoke-JobAzRead -AzArgs @("account", "show", "--subscription", $script:JobDriftStubSubscriptionId, "-o", "json")
        } catch { $jobAllowThrew = $true }
        $jobAllowCalls = @(Get-JobDriftStubCalls -Stub $jobStub)
        if (-not $jobAllowThrew -and $jobAllowResult.ExitCode -eq 0 -and $jobAllowCalls.Count -eq 1) {
            Add-Pass "Invoke-JobAzRead allows a properly-shaped, subscription-pinned read through to az (proves the chokepoint denies by rule, not by refusing everything)"
        } else {
            Add-Fail "Invoke-JobAzRead did not allow a legitimate read through as expected (threw=$jobAllowThrew, calls=$($jobAllowCalls.Count))"
        }
    } finally {
        $env:PATH = $jobPrevPath
        if ($null -eq $jobPrevLog) { Remove-Item Env:SQUAD_JOB_DRIFT_AZ_LOG -ErrorAction SilentlyContinue } else { $env:SQUAD_JOB_DRIFT_AZ_LOG = $jobPrevLog }
        if ($jobStub) { Remove-JobDriftStubEnvironment -Stub $jobStub }
    }
} else {
    Add-Fail "Cannot exercise Invoke-JobAzRead's deny/allow rules; reader or stub harness is missing"
}

# Runtime, child-process observed exit codes: each committed fixture must
# drive the REAL process exit code -- not just the in-process $LASTEXITCODE
# convention, but what a caller actually observes.
if ((Test-Path -LiteralPath $jobCheckPath) -and $jobMissingFixtures.Count -eq 0) {
    $jobFixtureExpectedExit = @{
        "clean-hub-present"    = 0
        "clean-hub-absent"     = 0
        "extra-identity"       = 1
        "inlined-secret"       = 1
        "stale-local-record"   = 0
        "genuine-image-drift"  = 1
    }
    $jobFixtureFailures = @()
    $jobFixtureGuidLeaks = @()
    $jobFixtureOutputs = @{}
    $jobGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    foreach ($name in $jobFixtureNames) {
        $fixturePath = $jobFixturePaths[$name]
        $procOut = & $jobPsExe -NoProfile -NonInteractive -File $jobCheckPath -Fixture $fixturePath -Json 2>&1 | Out-String
        $observedExit = $LASTEXITCODE
        $jobFixtureOutputs[$name] = $procOut
        if ($observedExit -ne $jobFixtureExpectedExit[$name]) {
            $jobFixtureFailures += "$name`: exit $observedExit, expected $($jobFixtureExpectedExit[$name])"
        }
        if ($procOut -match $jobGuidPattern) {
            $jobFixtureGuidLeaks += $name
        }
    }
    if ($jobFixtureFailures.Count -eq 0) {
        Add-Pass "All 6 committed fixtures drive the real child-process exit code the CV-2 contract keys off of (clean-hub-present=0, clean-hub-absent=0, extra-identity=1, inlined-secret=1, stale-local-record=0, genuine-image-drift=1)"
    } else {
        Add-Fail "A fixture's observed child-process exit code did not match the contract: $($jobFixtureFailures -join '; ')"
    }
    if ($jobFixtureGuidLeaks.Count -eq 0) {
        Add-Pass "Rendered JSON output for all 6 CV-2 fixtures contains no GUID-shaped identifier"
    } else {
        Add-Fail "Rendered JSON output leaked a GUID-shaped identifier for fixture(s): $($jobFixtureGuidLeaks -join ', ')"
    }

    # Issue #90 finding 1, named test: a stale local record must be reported
    # with its OWN status and a NON-high severity (so it does not trip
    # doctor's fail-closed exit code), while a genuine drift with a current
    # record must still be "unexpectedImage"/high. Removing/breaking the
    # staleness comparison in Compare-JobDriftSnapshot (e.g. deleting the
    # timestamp check) collapses BOTH fixtures back to "unexpectedImage"/high,
    # which this assertion catches.
    $staleOut = $jobFixtureOutputs["stale-local-record"]
    if ($staleOut -match '"[Ss]tatus"\s*:\s*"staleLocalRecord"' -and $staleOut -match '"[Ss]everity"\s*:\s*"medium"' -and $staleOut -notmatch '"[Ss]tatus"\s*:\s*"unexpectedImage"') {
        Add-Pass "stale-local-record fixture (live image newer than the recorded expectation) reports 'staleLocalRecord' at 'medium' severity, not 'unexpectedImage'/high"
    } else {
        Add-Fail "stale-local-record fixture did not report the distinct staleLocalRecord/medium finding expected for issue #90 finding 1: $staleOut"
    }
    $genuineOut = $jobFixtureOutputs["genuine-image-drift"]
    if ($genuineOut -match '"[Ss]tatus"\s*:\s*"unexpectedImage"' -and $genuineOut -match '"[Ss]everity"\s*:\s*"high"' -and $genuineOut -notmatch '"[Ss]tatus"\s*:\s*"staleLocalRecord"') {
        Add-Pass "genuine-image-drift fixture (live image older than a CURRENT recorded expectation) still reports 'unexpectedImage' at 'high' severity -- the stale-record path never downgrades real drift"
    } else {
        Add-Fail "genuine-image-drift fixture did not report unexpectedImage/high as required: $genuineOut"
    }
} else {
    Add-Fail "Cannot run fixture-driven child-process checks; entrypoint or a fixture is missing"
}

# Runtime, stub-harness-driven live round trip: the strongest proof available
# without touching real Azure. The stub's `az.cmd` answers with an inlined
# GITHUB_TOKEN and an extra user-assigned identity for the drifted case, and
# the fully-clean counterpart, proving the reader's live capture path end to
# end -- not just the comparer against a canned fixture.
if (-not $IsWindowsHost) {
    Write-Host "  [SKIP] CV-2 stub-driven live-mode round trip requires Windows (.cmd stub)" -ForegroundColor Yellow
} elseif ((Test-Path -LiteralPath $jobCheckPath) -and (Test-Path -LiteralPath $jobStubHarnessPath)) {
    . $jobStubHarnessPath
    $jobStub2 = $null
    try {
        $jobStub2 = New-JobDriftStubEnvironment
        $jobGuidPattern2 = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

        $jobDrifted = Invoke-JobDriftCliCapture -Stub $jobStub2 -ScriptPath $jobCheckPath -CliArguments @("-Json")
        $jobDriftedOk = ($jobDrifted.ExitCode -eq 1) -and
            ($jobDrifted.StdOut -match "inlinedSecret") -and
            ($jobDrifted.StdOut -match "unexpectedIdentity") -and
            ($jobDrifted.StdOut -notmatch "missingIdentity") -and
            ($jobDrifted.StdOut -notmatch "unexpectedImage")
        if ($jobDriftedOk) {
            Add-Pass "Live-mode round trip via the stub reproduces an inlined GITHUB_TOKEN and an unexpected identity (the two CV-2 drifted cases issue #85 names) and exits 1"
        } else {
            Add-Fail "Live-mode drifted round trip did not match the expected shape (exit=$($jobDrifted.ExitCode)): $($jobDrifted.StdOut)"
        }

        $jobDriftedCallChecks = @()
        foreach ($call in $jobDrifted.AzCalls) {
            if ($call -notmatch [regex]::Escape("--subscription")) { $jobDriftedCallChecks += "call missing --subscription: $call" }
            if ($call -match "^account set\b") { $jobDriftedCallChecks += "call was 'account set': $call" }
        }
        if ($jobDrifted.AzCalls.Count -gt 0 -and $jobDriftedCallChecks.Count -eq 0) {
            Add-Pass "Every one of the $($jobDrifted.AzCalls.Count) az call(s) the live round trip issued pins --subscription, and none was 'account set'"
        } else {
            Add-Fail "The live round trip's az call log violates a read-only invariant: $($jobDriftedCallChecks -join '; ')"
        }
        if ($jobDrifted.StdOut -notmatch $jobGuidPattern2) {
            Add-Pass "Live-mode drifted round trip's rendered output contains no GUID-shaped identifier, even though the stub's underlying identity resource ids are GUID-bearing"
        } else {
            Add-Fail "Live-mode drifted round trip leaked a GUID-shaped identifier into rendered output"
        }

        $jobClean = Invoke-JobDriftCliCapture -Stub $jobStub2 -ScriptPath $jobCheckPath -Clean -CliArguments @("-Json")
        $jobCleanOk = ($jobClean.ExitCode -eq 0) -and
            ($jobClean.StdOut -notmatch "inlinedSecret") -and
            ($jobClean.StdOut -notmatch "unexpectedIdentity") -and
            ($jobClean.StdOut -notmatch "missingIdentity") -and
            ($jobClean.StdOut -notmatch "unexpectedImage") -and
            ($jobClean.StdOut -notmatch "missingEnvVar")
        if ($jobCleanOk) {
            Add-Pass "Live-mode round trip via the stub's fully-clean job configuration exits 0 with no high-severity finding"
        } else {
            Add-Fail "Live-mode clean round trip did not exit 0 / had a high-severity finding (exit=$($jobClean.ExitCode)): $($jobClean.StdOut)"
        }
        if ($jobClean.StdOut -notmatch $jobGuidPattern2) {
            Add-Pass "Live-mode clean round trip's rendered output contains no GUID-shaped identifier"
        } else {
            Add-Fail "Live-mode clean round trip leaked a GUID-shaped identifier into rendered output"
        }
    } finally {
        if ($jobStub2) { Remove-JobDriftStubEnvironment -Stub $jobStub2 }
    }
} else {
    Add-Fail "Cannot run the stub-harness-driven live round trip; entrypoint or stub harness is missing"
}

# Fail-closed intent resolution: with no explicit parameters and no reachable
# deploy.outputs.json, the check must exit 2 -- never guess an image or a
# subscription. -DeployOutputsPath points at a guaranteed-absent path so this
# is deterministic regardless of what a developer's own machine has on disk.
if (Test-Path -LiteralPath $jobCheckPath) {
    $jobAbsentOutputs = Join-Path $RepoRoot "scripts\tests\fixtures\job-drift\.does-not-exist.json"
    & $jobPsExe -NoProfile -NonInteractive -File $jobCheckPath -DeployOutputsPath $jobAbsentOutputs 2>&1 | Out-Null
    $jobFailClosedExit = $LASTEXITCODE
    if ($jobFailClosedExit -eq 2) {
        Add-Pass "With no explicit parameters and no reachable deploy.outputs.json, the CV-2 check exits 2 (fails closed instead of guessing a subscription or image)"
    } else {
        Add-Fail "Unresolved CV-2 intent did not exit 2 as the fail-closed contract requires (observed exit $jobFailClosedExit)"
    }
} else {
    Add-Fail "Cannot exercise CV-2 fail-closed intent resolution; entrypoint is missing"
}

# Redaction: the 4 committed fixtures are themselves the evidence a reviewer
# would attach to a PR. None may carry a real GUID.
if ($jobMissingFixtures.Count -eq 0) {
    $jobGuidPattern3 = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $jobFixtureLeaks = @()
    foreach ($name in $jobFixtureNames) {
        $text = Get-Content -LiteralPath $jobFixturePaths[$name] -Raw
        if ($text -match $jobGuidPattern3) { $jobFixtureLeaks += $name }
    }
    if ($jobFixtureLeaks.Count -eq 0) {
        Add-Pass "None of the 4 committed CV-2 fixtures contain a GUID-shaped identifier"
    } else {
        Add-Fail "Fixture(s) contain a GUID-shaped identifier: $($jobFixtureLeaks -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# Drift folded into doctor (CV-3, issue #85)
# ---------------------------------------------------------------------------
# CV-3's requirement is a MAPPING, not a row: a high-severity live finding must
# reach the operator as "failed", never as a warning and never as "ok". The
# golden matrix's 11-doctor case cannot see that mapping -- it pins the
# fail-closed path, where both children exit 2 and doctor reports "unknown".
#
# So this section drives the REAL child checks against a deployment the stub
# `az` describes as drifted (SQUAD_STUB_DRIFT=1, plus a synthetic
# deploy.outputs.json in a throwaway mirror of scripts/ -- see
# New-SquadCliDriftDeployment), and asserts the failed rows twice:
#
#   1. at runtime, against a live capture, and
#   2. against the COMMITTED golden 27-doctor-drift.txt.
#
# The second assertion is the one that matters for regeneration: a downgrade to
# "warning" would be silently absorbed by `verify-cli-golden.ps1 -Update`,
# because a regenerated golden always matches the code that produced it. Here
# the expected text is written down independently, so blessing a warning fails
# this check.
Write-Section "Drift folded into doctor (CV-3)"

$cv3GoldenPath = Join-Path $RepoRoot "scripts\tests\golden\cli\27-doctor-drift.txt"
$cv3RbacFailedPattern = 'RBAC drift \(CV-1\)\s+failed\s+2 high-severity finding\(s\): missingAssignment, unexpectedScope'
$cv3JobFailedPattern = 'Job config drift \(CV-2\)\s+failed\s+2 high-severity finding\(s\): inlinedSecret, unexpectedIdentity'
# Anything that is not "failed" on either drift row -- "warning" above all, but
# equally "ok" or "unknown" -- is the regression this check exists to catch.
$cv3RbacNotFailedPattern = 'RBAC drift \(CV-1\)\s+(?!failed\b)\S+'
$cv3JobNotFailedPattern = 'Job config drift \(CV-2\)\s+(?!failed\b)\S+'

if (-not (Test-Path -LiteralPath $cv3GoldenPath)) {
    Add-Fail "scripts/tests/golden/cli/27-doctor-drift.txt is missing; nothing pins that simulated drift reaches the operator as a failure"
} else {
    $cv3GoldenText = Get-Content -LiteralPath $cv3GoldenPath -Raw
    if ($cv3GoldenText -match $cv3RbacFailedPattern -and $cv3GoldenText -match $cv3JobFailedPattern) {
        Add-Pass "The committed 27-doctor-drift golden reports BOTH drift rows as 'failed' with their high-severity findings, so a regenerated golden cannot quietly downgrade CV-3 to a warning"
    } else {
        Add-Fail "The committed 27-doctor-drift golden no longer reports both drift rows as 'failed' with high-severity findings; CV-3 requires simulated drift to be a failure, not a warning"
    }
    if ($cv3GoldenText -notmatch $cv3RbacNotFailedPattern -and $cv3GoldenText -notmatch $cv3JobNotFailedPattern) {
        Add-Pass "No drift row in the 27-doctor-drift golden carries any status other than 'failed'"
    } else {
        Add-Fail "A drift row in the 27-doctor-drift golden carries a status other than 'failed' (a warning/ok/unknown downgrade)"
    }

    # The golden only means something if the capture case that produces it is
    # actually the drifted one; a case that quietly stopped driving the real
    # child checks would leave a stale file passing the checks above.
    $cv3CaseFile = Join-Path $RepoRoot "scripts\tests\cli-capture-cases.ps1"
    if ((Test-Path -LiteralPath $cv3CaseFile) -and ((Get-Content -LiteralPath $cv3CaseFile -Raw) -match '27-doctor-drift[^\r\n]*Drift\s*=\s*\$true')) {
        Add-Pass "The 27-doctor-drift capture case still drives the real drift child scripts against the drifted stub deployment"
    } else {
        Add-Fail "scripts/tests/cli-capture-cases.ps1 no longer marks 27-doctor-drift as a drift case; the golden would be captured against the fail-closed path instead"
    }
}

# The runtime half: the same scenario, captured live rather than read off disk,
# so a code change that stops mapping exit 1 to "failed" fails here even before
# the golden gate runs.
if (-not $IsWindowsHost) {
    Write-Host "  [SKIP] CV-3 doctor drift scenario requires Windows (.cmd stubs)" -ForegroundColor Yellow
} elseif (-not (Test-Path -LiteralPath $harness)) {
    Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing; the CV-3 doctor drift scenario cannot run"
} else {
    . $harness
    $cv3Stub = $null
    try {
        $cv3Stub = New-SquadCliStubEnvironment
        $cv3Cli = New-SquadCliDriftDeployment -Stub $cv3Stub -ScriptsRoot (Join-Path $RepoRoot "scripts")
        $cv3Run = Invoke-SquadCliCapture -Stub $cv3Stub -ScriptPath $cv3Cli -CliArguments @("doctor") -DriftMode "1"

        if ($cv3Run.StdOut -match $cv3RbacFailedPattern) {
            Add-Pass "With live RBAC drift simulated end to end, doctor reports 'RBAC drift (CV-1)' as failed with its high-severity findings"
        } else {
            Add-Fail "Simulated live RBAC drift did not reach the doctor table as a failure: $($cv3Run.StdOut)"
        }
        if ($cv3Run.StdOut -match $cv3JobFailedPattern) {
            Add-Pass "With live job/environment drift simulated end to end, doctor reports 'Job config drift (CV-2)' as failed with its high-severity findings"
        } else {
            Add-Fail "Simulated live job/environment drift did not reach the doctor table as a failure: $($cv3Run.StdOut)"
        }
        if ($cv3Run.StdOut -notmatch $cv3RbacNotFailedPattern -and $cv3Run.StdOut -notmatch $cv3JobNotFailedPattern) {
            Add-Pass "Neither drift row is reported as a warning, ok, or unknown when the deployment is drifted"
        } else {
            Add-Fail "A drift row was reported with a status other than 'failed' against a drifted deployment: $($cv3Run.StdOut)"
        }

        # doctor must stay a child-process caller: the drift reads have to be
        # the CHILD's az calls, made against the resolved subscription, or the
        # single-chokepoint claim in each reader stops describing the process
        # that actually issued them.
        $cv3DriftCalls = @($cv3Run.AzCalls | Where-Object { $_ -match '^(role assignment list|identity show|acr show)\b' })
        $cv3Unpinned = @($cv3DriftCalls | Where-Object { $_ -notmatch [regex]::Escape("--subscription") })
        if ($cv3DriftCalls.Count -ge 6 -and $cv3Unpinned.Count -eq 0) {
            Add-Pass "The drift reads doctor triggered ($($cv3DriftCalls.Count) call(s)) all pin --subscription, so folding the checks into doctor did not loosen the read contract"
        } else {
            Add-Fail "doctor's folded-in drift reads are missing or do not pin --subscription (calls=$($cv3DriftCalls.Count), unpinned=$($cv3Unpinned.Count))"
        }
    } catch {
        Add-Fail "The CV-3 doctor drift scenario threw: $($_.Exception.Message)"
    } finally {
        if ($cv3Stub) { Remove-SquadCliStubEnvironment -Stub $cv3Stub }
    }
}

# ---------------------------------------------------------------------------
# `configure` clears stale derived URLs (issue #90 finding 2)
# ---------------------------------------------------------------------------
# aspireLoginUrl bakes in the CURRENT container apps environment's own
# randomly-generated default-domain hash and dashboard token. Neither a
# subscription id nor a resource group name can re-derive it, so it must be
# cleared -- not silently carried forward -- the moment either changes.
# Unchanged, it must survive; an explicit --dashboard-url on the SAME call
# must always win regardless of what else changed.
Write-Section "'configure' clears stale derived URLs (issue #90 finding 2)"

if (-not $IsWindowsHost) {
    Write-Host "  [SKIP] configure/aspireLoginUrl scenario requires Windows (.cmd stubs)" -ForegroundColor Yellow
} elseif (-not (Test-Path -LiteralPath $harness)) {
    Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing; the configure/aspireLoginUrl scenario cannot run"
} else {
    . $harness
    $cfgStub = $null
    try {
        $cfgStub = New-SquadCliStubEnvironment
        $cfgConfigPath = Join-Path $cfgStub.HomeDir ".squad-on-aca\config.json"
        $cfgCli = Join-Path $RepoRoot "scripts\squad-aca.ps1"
        $cfgOriginalUrl = "https://aspire.stub.invalid/login"

        # Baseline: the stub's synthetic config already carries aspireLoginUrl.
        $cfgBaseline = Get-Content -LiteralPath $cfgConfigPath -Raw | ConvertFrom-Json
        if ($cfgBaseline.aspireLoginUrl -eq $cfgOriginalUrl) {
            Add-Pass "Stub baseline config carries the expected aspireLoginUrl before any 'configure' call runs"
        } else {
            Add-Fail "Stub baseline config did not carry the expected aspireLoginUrl (got '$($cfgBaseline.aspireLoginUrl)')"
        }

        # (a) Neither subscription nor resource group changes -> preserved.
        $cfgUnchanged = Invoke-SquadCliCapture -Stub $cfgStub -ScriptPath $cfgCli -CliArguments @(
            "configure", "--resource-group", "rg-squad-stub", "--session-job", "caj-squad-aca-session"
        )
        $cfgAfterUnchanged = Get-Content -LiteralPath $cfgConfigPath -Raw | ConvertFrom-Json
        if ($cfgUnchanged.ExitCode -eq 0 -and $cfgAfterUnchanged.aspireLoginUrl -eq $cfgOriginalUrl) {
            Add-Pass "configure with neither subscription nor resource group changed PRESERVES the existing aspireLoginUrl"
        } else {
            Add-Fail "configure with no subscription/resource-group change did not preserve aspireLoginUrl (exit=$($cfgUnchanged.ExitCode), url='$($cfgAfterUnchanged.aspireLoginUrl)')"
        }

        # (b) Resource group changes -> cleared (named test: 'clears on RG change').
        $cfgRgChanged = Invoke-SquadCliCapture -Stub $cfgStub -ScriptPath $cfgCli -CliArguments @(
            "configure", "--resource-group", "rg-squad-stub-2", "--session-job", "caj-squad-aca-session"
        )
        $cfgAfterRgChanged = Get-Content -LiteralPath $cfgConfigPath -Raw | ConvertFrom-Json
        if ($cfgRgChanged.ExitCode -eq 0 -and [string]::IsNullOrEmpty($cfgAfterRgChanged.aspireLoginUrl)) {
            Add-Pass "configure with a CHANGED resource group CLEARS the stale aspireLoginUrl (named test: clears-on-rg-change)"
        } else {
            Add-Fail "configure with a changed resource group did not clear aspireLoginUrl (exit=$($cfgRgChanged.ExitCode), url='$($cfgAfterRgChanged.aspireLoginUrl)')"
        }

        # Reset the stub config back to baseline before the next scenario.
        $cfgBaseline | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfgConfigPath -Encoding utf8

        # (c) Subscription changes -> cleared (named test: 'clears on subscription change').
        $cfgSubChanged = Invoke-SquadCliCapture -Stub $cfgStub -ScriptPath $cfgCli -CliArguments @(
            "configure", "--subscription", "99999999-9999-9999-9999-999999999999",
            "--resource-group", "rg-squad-stub", "--session-job", "caj-squad-aca-session"
        )
        $cfgAfterSubChanged = Get-Content -LiteralPath $cfgConfigPath -Raw | ConvertFrom-Json
        if ($cfgSubChanged.ExitCode -eq 0 -and [string]::IsNullOrEmpty($cfgAfterSubChanged.aspireLoginUrl)) {
            Add-Pass "configure with a CHANGED subscription CLEARS the stale aspireLoginUrl (named test: clears-on-subscription-change)"
        } else {
            Add-Fail "configure with a changed subscription did not clear aspireLoginUrl (exit=$($cfgSubChanged.ExitCode), url='$($cfgAfterSubChanged.aspireLoginUrl)')"
        }
        if ($cfgSubChanged.StdOut -match "Cleared the previous Aspire dashboard URL") {
            Add-Pass "configure prints an informational message explaining why the Aspire URL was cleared"
        } else {
            Add-Fail "configure did not print the expected clear-URL explanation: $($cfgSubChanged.StdOut)"
        }

        # Reset the stub config back to baseline before the next scenario.
        $cfgBaseline | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfgConfigPath -Encoding utf8

        # (d) An explicit --dashboard-url on the SAME call always wins, even
        # though the subscription also changed on that call.
        $cfgExplicit = Invoke-SquadCliCapture -Stub $cfgStub -ScriptPath $cfgCli -CliArguments @(
            "configure", "--subscription", "88888888-8888-8888-8888-888888888888",
            "--resource-group", "rg-squad-stub", "--session-job", "caj-squad-aca-session",
            "--dashboard-url", "https://explicit.stub.invalid/login"
        )
        $cfgAfterExplicit = Get-Content -LiteralPath $cfgConfigPath -Raw | ConvertFrom-Json
        if ($cfgExplicit.ExitCode -eq 0 -and $cfgAfterExplicit.aspireLoginUrl -eq "https://explicit.stub.invalid/login") {
            Add-Pass "An explicit --dashboard-url on the same call always wins over the clear-on-change rule"
        } else {
            Add-Fail "An explicit --dashboard-url did not win (exit=$($cfgExplicit.ExitCode), url='$($cfgAfterExplicit.aspireLoginUrl)')"
        }
    } catch {
        Add-Fail "The configure/aspireLoginUrl scenario threw: $($_.Exception.Message)"
    } finally {
        if ($cfgStub) { Remove-SquadCliStubEnvironment -Stub $cfgStub }
    }
}

# ---------------------------------------------------------------------------
# `doctor` Aspire URL reachability (issue #90 finding 3)
# ---------------------------------------------------------------------------
# A configured aspireLoginUrl string is not proof the dashboard is reachable.
# doctor must distinguish not-configured ("missing") from configured (probed:
# "ok" | "failed" | "unknown"), dead DNS must never render "ok", and a
# slow/black-holed endpoint must time out as "unknown", never hang doctor.
Write-Section "'doctor' Aspire URL reachability (issue #90 finding 3)"

if (-not $IsWindowsHost) {
    Write-Host "  [SKIP] doctor Aspire URL reachability scenario requires Windows (.cmd stubs)" -ForegroundColor Yellow
} elseif (-not (Test-Path -LiteralPath $harness)) {
    Add-Fail "scripts/tests/cli-stub-harness.ps1 is missing; the doctor Aspire URL reachability scenario cannot run"
} else {
    . $harness
    $reachStub = $null
    try {
        $reachStub = New-SquadCliStubEnvironment
        # Run against a STAGED copy of the CLI, not the one in this working
        # tree.
        #
        # `Get-AcaConfig` layers `<repo>/deploy.outputs.json` underneath the
        # user config, and `$RepoRoot` comes from the script's own location --
        # so invoking the real `scripts/squad-aca.ps1` reads whatever
        # deploy.outputs.json the developer happens to have. That file is
        # gitignored and written by a deploy, which made the "missing" case
        # below pass on a fresh clone and FAIL on any machine that had
        # deployed: the blanked user-config value could not clear the URL the
        # real outputs file still supplied. CI, having never deployed, never
        # saw it (issue #100).
        #
        # Staging a root the test owns means both layers are controlled here,
        # so the result describes the code rather than the machine.
        $reachRoot = Join-Path $reachStub.Root "staged-repo"
        New-Item -ItemType Directory -Force -Path $reachRoot | Out-Null
        Copy-Item -Path (Join-Path $RepoRoot "scripts") -Destination $reachRoot -Recurse -Force
        Copy-Item -Path (Join-Path $RepoRoot "config") -Destination $reachRoot -Recurse -Force
        $reachCli = Join-Path $reachRoot "scripts\squad-aca.ps1"
        $reachOutputs = Join-Path $reachRoot "deploy.outputs.json"
        $reachOkPattern = 'Aspire URL\s+ok\s+https://aspire\.stub\.invalid/login'
        $reachFailedPattern = 'Aspire URL\s+failed\s+'
        $reachUnknownPattern = 'Aspire URL\s+unknown\s+'
        $reachMissingPattern = 'Aspire URL\s+missing\s+'

        # The staging must actually work, or every assertion below is vacuous.
        if (Test-Path -LiteralPath $reachCli) {
            Add-Pass "the Aspire reachability scenario runs against a staged repository root, so its result cannot depend on the developer's own deploy.outputs.json"
        } else {
            Add-Fail "could not stage a repository root for the Aspire reachability scenario; the checks below would silently read the real working tree"
        }

        # curl exit 0 -> "ok" with the URL, byte-shape-identical to the
        # committed golden 11-doctor.txt/27-doctor-drift.txt rows.
        $reachOk = Invoke-SquadCliCapture -Stub $reachStub -ScriptPath $reachCli -CliArguments @("doctor") -CurlExitCode 0
        if ($reachOk.StdOut -match $reachOkPattern) {
            Add-Pass "doctor reports 'Aspire URL ok <url>' when curl (probing reachability) exits 0"
        } else {
            Add-Fail "doctor did not report Aspire URL as ok for curl exit 0: $($reachOk.StdOut)"
        }
        if ($reachOk.CurlCalls.Count -ge 1) {
            Add-Pass "doctor actually invoked curl to check Aspire URL reachability ($($reachOk.CurlCalls.Count) call(s))"
        } else {
            Add-Fail "doctor's Aspire URL check made zero curl calls; a configured URL cannot be classified as reachable without a live probe"
        }

        # curl exit 6 (COULDNT_RESOLVE_HOST, i.e. dead DNS) -> "failed", never "ok".
        $reachFailed = Invoke-SquadCliCapture -Stub $reachStub -ScriptPath $reachCli -CliArguments @("doctor") -CurlExitCode 6
        if ($reachFailed.StdOut -match $reachFailedPattern -and $reachFailed.StdOut -notmatch $reachOkPattern) {
            Add-Pass "doctor reports 'Aspire URL failed' (never 'ok') when curl reports dead DNS (exit 6)"
        } else {
            Add-Fail "Dead DNS (curl exit 6) did not render as failed / rendered as ok: $($reachFailed.StdOut)"
        }

        # curl exit 28 (OPERATION_TIMEDOUT, i.e. slow/unreachable) -> "unknown", never a hang.
        $reachUnknown = Invoke-SquadCliCapture -Stub $reachStub -ScriptPath $reachCli -CliArguments @("doctor") -CurlExitCode 28
        if ($reachUnknown.StdOut -match $reachUnknownPattern -and $reachUnknown.StdOut -notmatch $reachOkPattern) {
            Add-Pass "doctor reports 'Aspire URL unknown' (never 'ok') when curl times out (exit 28), bounded rather than hanging"
        } else {
            Add-Fail "A curl timeout (exit 28) did not render as unknown / rendered as ok: $($reachUnknown.StdOut)"
        }

        # No aspireLoginUrl configured at all -> "missing", and curl is never invoked.
        $reachConfigPath = Join-Path $reachStub.HomeDir ".squad-on-aca\config.json"
        $reachConfig = Get-Content -LiteralPath $reachConfigPath -Raw | ConvertFrom-Json
        $reachConfig.aspireLoginUrl = ""
        $reachConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reachConfigPath -Encoding utf8
        Reset-SquadCliStubLog -Stub $reachStub
        $reachMissing = Invoke-SquadCliCapture -Stub $reachStub -ScriptPath $reachCli -CliArguments @("doctor") -CurlExitCode 0
        if ($reachMissing.StdOut -match $reachMissingPattern -and $reachMissing.CurlCalls.Count -eq 0) {
            Add-Pass "doctor reports 'Aspire URL missing' (not configured) and never calls curl when no URL is configured"
        } else {
            Add-Fail "doctor did not report missing correctly, or called curl with no URL configured: $($reachMissing.StdOut), curl calls=$($reachMissing.CurlCalls.Count)"
        }

        # The OTHER half of the layering, which CI could never reach before:
        # a deployed machine has a deploy.outputs.json, and `Get-AcaConfig`
        # reads it UNDERNEATH the user config. Until this was staged, CI (never
        # having deployed) only ever exercised the unconfigured path -- the one
        # nobody is actually on -- while developers who had deployed saw a red
        # run that had nothing to do with their change.
        #
        # "The user config has none" means the key is ABSENT, not present-and-
        # empty: since issue #102 those are deliberately different, an empty
        # value being an explicit clear. Removing the property is what this
        # case actually means.
        $reachConfig.PSObject.Properties.Remove('aspireLoginUrl')
        $reachConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reachConfigPath -Encoding utf8
        Set-Content -LiteralPath $reachOutputs -Encoding utf8 -Value (@{
            aspireLoginUrl = "https://outputs.stub.invalid/login?t=fromoutputs"
        } | ConvertTo-Json)
        Reset-SquadCliStubLog -Stub $reachStub
        $reachFromOutputs = Invoke-SquadCliCapture -Stub $reachStub -ScriptPath $reachCli -CliArguments @("doctor") -CurlExitCode 0
        if ($reachFromOutputs.StdOut -match 'Aspire URL\s+ok\s+https://outputs\.stub\.invalid/login') {
            Add-Pass "doctor falls back to deploy.outputs.json for the Aspire URL when the user config has none -- the path every deployed machine is on"
        } else {
            Add-Fail "doctor did not read the Aspire URL from deploy.outputs.json when the user config had none: $($reachFromOutputs.StdOut)"
        }

        $reachConfig | Add-Member -NotePropertyName aspireLoginUrl -NotePropertyValue "https://aspire.stub.invalid/login?t=fromuserconfig" -Force
        $reachConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reachConfigPath -Encoding utf8
        Reset-SquadCliStubLog -Stub $reachStub
        $reachPrecedence = Invoke-SquadCliCapture -Stub $reachStub -ScriptPath $reachCli -CliArguments @("doctor") -CurlExitCode 0
        if ($reachPrecedence.StdOut -match 'Aspire URL\s+ok\s+https://aspire\.stub\.invalid/login' -and
            $reachPrecedence.StdOut -notmatch 'outputs\.stub\.invalid') {
            Add-Pass "a user-config Aspire URL takes precedence over deploy.outputs.json, so configuring a hub does not get silently overridden by the last deploy"
        } else {
            Add-Fail "user config did not take precedence over deploy.outputs.json for the Aspire URL: $($reachPrecedence.StdOut)"
        }

        # An EXPLICIT CLEAR must clear (issue #102).
        #
        # A value present-but-empty in the user config is an instruction, not an
        # absence. It used to be ignored, so a cleared URL was restored from
        # deploy.outputs.json and could not be cleared at all on a machine that
        # had deployed -- which is exactly where #90's stale-URL fix needed to
        # work, and the reason it looked correct on a fresh clone.
        $reachConfig.aspireLoginUrl = ""
        $reachConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reachConfigPath -Encoding utf8
        Reset-SquadCliStubLog -Stub $reachStub
        $reachCleared = Invoke-SquadCliCapture -Stub $reachStub -ScriptPath $reachCli -CliArguments @("doctor") -CurlExitCode 0
        if ($reachCleared.StdOut -match $reachMissingPattern -and
            $reachCleared.StdOut -notmatch 'outputs\.stub\.invalid' -and
            $reachCleared.CurlCalls.Count -eq 0) {
            Add-Pass "clearing the Aspire URL in the user config CLEARS it, even with a deploy.outputs.json present -- an explicit empty value is an instruction, not an absence"
        } else {
            Add-Fail "a cleared user-config Aspire URL was restored from deploy.outputs.json: $($reachCleared.StdOut), curl calls=$($reachCleared.CurlCalls.Count)"
        }

        # ...and the fallback still works, so "explicit empty wins" has not
        # become "the deployment record is ignored". Removing the key entirely
        # is the ABSENCE case, which must still fall through.
        $reachConfig.PSObject.Properties.Remove('aspireLoginUrl')
        $reachConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reachConfigPath -Encoding utf8
        Reset-SquadCliStubLog -Stub $reachStub
        $reachAbsent = Invoke-SquadCliCapture -Stub $reachStub -ScriptPath $reachCli -CliArguments @("doctor") -CurlExitCode 0
        if ($reachAbsent.StdOut -match 'Aspire URL\s+ok\s+https://outputs\.stub\.invalid/login') {
            Add-Pass "a key ABSENT from the user config still falls back to deploy.outputs.json, so an explicit clear and a missing key stay different things"
        } else {
            Add-Fail "an absent user-config key no longer falls back to deploy.outputs.json: $($reachAbsent.StdOut)"
        }
    } catch {
        Add-Fail "The doctor Aspire URL reachability scenario threw: $($_.Exception.Message)"
    } finally {
        if ($reachStub) { Remove-SquadCliStubEnvironment -Stub $reachStub }
    }
}

# Named test, mutation-provable: doctor's Aspire URL row must come from an
# actual reachability probe (Test-AcaAspireReachability), not merely from
# whether the config string is non-empty. This asserts the WIRING statically:
# removing the call and reverting to the old string-presence check would make
# this fail even before any stub is involved.
Write-Section "doctor wires Test-AcaAspireReachability (named test, issue #90 finding 3)"
$acaLogsLibPath = Join-Path $RepoRoot "scripts\lib\aca-logs.ps1"
$squadAcaCliPath = Join-Path $RepoRoot "scripts\squad-aca.ps1"
if ((Test-Path -LiteralPath $acaLogsLibPath) -and (Test-Path -LiteralPath $squadAcaCliPath)) {
    $acaLogsLibText = Get-Content -LiteralPath $acaLogsLibPath -Raw
    $squadAcaCliText = Get-Content -LiteralPath $squadAcaCliPath -Raw
    if ($acaLogsLibText -match 'function\s+Test-AcaAspireReachability') {
        Add-Pass "scripts/lib/aca-logs.ps1 defines Test-AcaAspireReachability"
    } else {
        Add-Fail "scripts/lib/aca-logs.ps1 no longer defines Test-AcaAspireReachability"
    }
    if ($squadAcaCliText -match 'Test-AcaAspireReachability\s+-Url\s+\$config\.aspireLoginUrl') {
        Add-Pass "Invoke-Doctor's Aspire URL check calls Test-AcaAspireReachability against the configured URL (not a bare string-presence check)"
    } else {
        Add-Fail "Invoke-Doctor's Aspire URL check no longer calls Test-AcaAspireReachability; it may have regressed to a string-presence-only check"
    }
} else {
    Add-Fail "Cannot statically verify the Test-AcaAspireReachability wiring; a required file is missing"
}

# ---------------------------------------------------------------------------
# Process-isolation report (PC-1, issue #86)
# ---------------------------------------------------------------------------
Write-Section "Process-isolation report (PC-1)"

# PC-1's design mirrors CV-1/CV-2's reader/pure-parser split: exactly ONE file
# may invoke `az`, through a single allowlisted chokepoint, and the parser
# that decides what a log line MEANS must be provably free of any Azure CLI
# call. This section checks both halves statically AND at runtime: every deny
# rule actually refuses, every allowed read reaches the stub, the
# yes/no/unknown/not-yet-observed classification is exercised offline via
# fixtures (never contacting Azure), and docs/security-report.md is checked
# for honesty rather than a fabricated result.
$procIsoReaderPath = Join-Path $RepoRoot "scripts\lib\proc-isolation-reader.ps1"
$procIsoParserPath = Join-Path $RepoRoot "scripts\lib\proc-isolation-parser.ps1"
$procIsoReportPath = Join-Path $RepoRoot "scripts\proc-isolation-report.ps1"
$procIsoStubHarnessPath = Join-Path $RepoRoot "scripts\tests\proc-isolation-stub-harness.ps1"
$procIsoFixtureDir = Join-Path $RepoRoot "scripts\tests\fixtures\proc-isolation"
$procIsoProbePath = Join-Path $RepoRoot "worker\lib\proc-isolation-probe.sh"
$procIsoEntrypointPath = Join-Path $RepoRoot "worker\entrypoint.sh"
$procIsoRequiredFiles = @(
    @{ Path = $procIsoReaderPath; Label = "scripts/lib/proc-isolation-reader.ps1" },
    @{ Path = $procIsoParserPath; Label = "scripts/lib/proc-isolation-parser.ps1" },
    @{ Path = $procIsoReportPath; Label = "scripts/proc-isolation-report.ps1" },
    @{ Path = $procIsoStubHarnessPath; Label = "scripts/tests/proc-isolation-stub-harness.ps1" },
    @{ Path = $procIsoProbePath; Label = "worker/lib/proc-isolation-probe.sh" },
    @{ Path = $procIsoEntrypointPath; Label = "worker/entrypoint.sh" }
)
$procIsoMissingFiles = @($procIsoRequiredFiles | Where-Object { -not (Test-Path -LiteralPath $_.Path) })
if ($procIsoMissingFiles.Count -eq 0) {
    Add-Pass "All PC-1 source files are present (reader, parser, entrypoint, stub harness, worker probe)"
} else {
    Add-Fail "PC-1 is missing file(s): $(($procIsoMissingFiles | ForEach-Object { $_.Label }) -join ', ')"
}

$procIsoFixtureNames = @(
    "observed-yes", "observed-no", "observed-unknown", "not-yet-observed",
    "raw-yes", "legacy-prefixed-yes",
    "negative-embedded-prose", "negative-v2-schema", "negative-truncated", "negative-unrelated-json"
)
$procIsoFixturePaths = @{}
foreach ($name in $procIsoFixtureNames) { $procIsoFixturePaths[$name] = Join-Path $procIsoFixtureDir "$name.txt" }
$procIsoMissingFixtures = @($procIsoFixtureNames | Where-Object { -not (Test-Path -LiteralPath $procIsoFixturePaths[$_]) })
if ($procIsoMissingFixtures.Count -eq 0) {
    Add-Pass "All $($procIsoFixtureNames.Count) PC-1 fixtures are present (JSON-envelope observed-yes/no/unknown/not-yet-observed reflecting the real --format json wire shape, R2's raw and legacy-prefixed backward-compat shapes, and 4 R5 negatives: embedded prose, a v2 schema line, a truncated line, unrelated JSON)"
} else {
    Add-Fail "PC-1 is missing fixture(s): $($procIsoMissingFixtures -join ', ')"
}

if ((Test-Path -LiteralPath $procIsoReaderPath) -and (Test-Path -LiteralPath $procIsoParserPath) -and (Test-Path -LiteralPath $procIsoReportPath)) {
    $procIsoReaderText = Get-Content -LiteralPath $procIsoReaderPath -Raw
    $procIsoParserText = Get-Content -LiteralPath $procIsoParserPath -Raw
    $procIsoReportText = Get-Content -LiteralPath $procIsoReportPath -Raw
    # Lowercase, standalone "az" only, matching the CV-1/CV-2 pattern.
    $procIsoAzTokenPattern = '(?<![A-Za-z0-9_])az(?![A-Za-z0-9_])'

    if ($procIsoParserText -notmatch $procIsoAzTokenPattern) {
        Add-Pass "scripts/lib/proc-isolation-parser.ps1 contains no standalone 'az' token -- the parser that decides what a log line means cannot itself call Azure"
    } else {
        Add-Fail "scripts/lib/proc-isolation-parser.ps1 contains a standalone 'az' token; the pure parser must never reference the Azure CLI"
    }

    # L6 (issue #86, third revision): the parser's regex literals must each be
    # anchored and bounded. The previous revision asserted this by scanning
    # the WHOLE FILE for the two characters ".*" -- which is not a check on
    # the patterns at all: it fails on a comment or a doc string that happens
    # to contain those characters, and it says nothing about whether the
    # patterns are anchored. This checks the NAMED pattern literals
    # themselves: every $script:ProcIso*Pattern assignment must exist, be
    # anchored at ^, and contain no unbounded wildcard construct.
    $procIsoNamedPatternAssignments = @([regex]::Matches($procIsoParserText, '(?m)^\$script:(ProcIso\w*Pattern)\s*=\s*''([^'']*)''\s*$'))
    $procIsoExpectedPatternNames = @("ProcIsoLinePattern", "ProcIsoTimestampPrefixPattern", "ProcIsoLegacyPrefixPattern")
    $procIsoFoundPatternNames = @($procIsoNamedPatternAssignments | ForEach-Object { $_.Groups[1].Value })
    $procIsoUnboundedConstructs = @('.*', '.+', '[\s\S]', '(?s)')
    $procIsoPatternProblems = @()
    foreach ($expected in $procIsoExpectedPatternNames) {
        if ($procIsoFoundPatternNames -notcontains $expected) {
            $procIsoPatternProblems += "$expected is not defined as a single-quoted literal"
        }
    }
    foreach ($assignment in $procIsoNamedPatternAssignments) {
        $patternName = $assignment.Groups[1].Value
        $patternValue = $assignment.Groups[2].Value
        if (-not $patternValue.StartsWith('^')) {
            $procIsoPatternProblems += "$patternName is not anchored at the start of the line"
        }
        foreach ($construct in $procIsoUnboundedConstructs) {
            if ($patternValue.Contains($construct)) {
                $procIsoPatternProblems += "$patternName contains the unbounded construct '$construct'"
            }
        }
    }
    if ($procIsoPatternProblems.Count -eq 0 -and $procIsoFoundPatternNames.Count -eq $procIsoExpectedPatternNames.Count) {
        Add-Pass "L6: all $($procIsoFoundPatternNames.Count) named regex literals in scripts/lib/proc-isolation-parser.ps1 ($($procIsoFoundPatternNames -join ', ')) are anchored at ^ and free of any unbounded wildcard ('.*', '.+', '[\s\S]', '(?s)') -- checked as patterns, not as a file-wide character scan"
    } else {
        Add-Fail "L6: the PC-1 parser's named regex literals are not all anchored/bounded (found: $($procIsoFoundPatternNames -join ', ')): $($procIsoPatternProblems -join '; ')"
    }

    # L1: the --tail default and bound are pinned in BOTH the reader and the
    # CLI entrypoint. `az containerapp job logs show --tail` accepts 0-300;
    # the prior revisions' 500 was rejected by the CLI on every single live
    # read, and that rejection was then reported as "not-yet-observed".
    $procIsoTailProblems = @()
    if ($procIsoReaderText -notmatch '(?m)^\$script:ProcIsoMaxTailLines\s*=\s*300\s*$') { $procIsoTailProblems += "the reader does not pin ProcIsoMaxTailLines = 300" }
    if ($procIsoReaderText -notmatch '(?m)^\$script:ProcIsoDefaultTailLines\s*=\s*300\s*$') { $procIsoTailProblems += "the reader does not pin ProcIsoDefaultTailLines = 300" }
    if ($procIsoReaderText -notmatch '\[int\]\$TailLines\s*=\s*300') { $procIsoTailProblems += "Get-ProcIsoLiveObservation's TailLines default is not 300" }
    if ($procIsoReportText -notmatch '\[int\]\$TailLines\s*=\s*300') { $procIsoTailProblems += "proc-isolation-report.ps1's -TailLines default is not 300" }
    if ($procIsoReaderText -notmatch 'function\s+Assert-ProcIsoTailLines') { $procIsoTailProblems += "the reader defines no Assert-ProcIsoTailLines range check" }
    if ($procIsoTailProblems.Count -eq 0) {
        Add-Pass "L1: --tail defaults to 300 and is bounded to 0..300 in both scripts/lib/proc-isolation-reader.ps1 and scripts/proc-isolation-report.ps1 (the range the CLI actually accepts)"
    } else {
        Add-Fail "L1: the --tail default/bound is not pinned as required: $($procIsoTailProblems -join '; ')"
    }

    # L3: the container name is resolved from the LIVE job template through
    # the same allowlisted chokepoint, not assumed to equal the job name.
    $procIsoContainerProblems = @()
    if ($procIsoReaderText -notmatch 'function\s+Resolve-ProcIsoContainerName') { $procIsoContainerProblems += "the reader defines no Resolve-ProcIsoContainerName" }
    if ($procIsoReaderText -notmatch [regex]::Escape('properties.template.containers[0].name')) { $procIsoContainerProblems += "the reader never queries properties.template.containers[0].name" }
    if ($procIsoReaderText -notmatch '"containerapp",\s*"job",\s*"show"') { $procIsoContainerProblems += "'containerapp job show' is not on the reader's allowlist/call sites" }
    if ($procIsoReaderText -match '"--container",\s*\$Intent\.JobName') { $procIsoContainerProblems += "the logs-show call still hard-codes the JOB name as the container name" }
    if ($procIsoReportText -notmatch '\[string\]\$ContainerName\s*=\s*""') { $procIsoContainerProblems += "proc-isolation-report.ps1 exposes no -ContainerName parameter" }
    if ($procIsoContainerProblems.Count -eq 0) {
        Add-Pass "L3: the container name is resolved from the live job template ('containerapp job show --query properties.template.containers[0].name'), overridable with -ContainerName, and is never hard-coded to the job name"
    } else {
        Add-Fail "L3: container-name resolution is not wired as required: $($procIsoContainerProblems -join '; ')"
    }

    # L2: a per-execution log-read failure must be RECORDED, never silently
    # skipped. The silent `continue` is how a run in which every log read was
    # rejected still reported the reassuring "not-yet-observed".
    $procIsoFailureAccountingProblems = @()
    foreach ($field in @("ExecutionsScanned", "ExecutionsRead", "Failures")) {
        if ($procIsoReaderText -notmatch "$field\s*=") { $procIsoFailureAccountingProblems += "the reader's live result carries no $field field" }
    }
    if ($procIsoReaderText -notmatch '\$failures\s*\+=') { $procIsoFailureAccountingProblems += "the reader never records a per-execution read failure" }
    foreach ($field in @("executionsScanned", "executionsRead", "failures")) {
        if ($procIsoReportText -notmatch "$field\s+=") { $procIsoFailureAccountingProblems += "the report's JSON carries no $field field" }
    }
    if ($procIsoFailureAccountingProblems.Count -eq 0) {
        Add-Pass "L2: the reader accounts for ExecutionsScanned/ExecutionsRead/Failures explicitly and the report surfaces executionsScanned/executionsRead/failures in its JSON -- a failed log read can never be silently skipped"
    } else {
        Add-Fail "L2: explicit read-failure accounting is missing: $($procIsoFailureAccountingProblems -join '; ')"
    }

    # R3 (issue #86 security revision): the reader must explicitly pin
    # `--format json` on the one 'containerapp job logs show' call site, not
    # rely on the command's own (text) default.
    if ($procIsoReaderText -match '"containerapp",\s*"job",\s*"logs",\s*"show"[\s\S]{0,400}?"--format",\s*"json"') {
        Add-Pass "R3: scripts/lib/proc-isolation-reader.ps1 explicitly pins --format json on 'containerapp job logs show'"
    } else {
        Add-Fail "R3: scripts/lib/proc-isolation-reader.ps1 does not pin --format json on 'containerapp job logs show'; the reader would receive the unpinned text-format wire shape the parser cannot recognise"
    }

    # R1/R6 (issue #86 security revision): worker/entrypoint.sh must call the
    # RAW squad_proc_iso_run and must never route its one emitted line back
    # through this file's own log() wrapper (which prepends a fixed
    # "[squad-on-aca] " literal -- see log()'s definition at the top of the
    # file). This is the static half of worker/tests/
    # test_identity_drop_order.sh's own R1/R6 assertions, kept here too so a
    # Windows-only validate.ps1 run (no bash) still catches this class of
    # regression.
    if (Test-Path -LiteralPath $procIsoEntrypointPath) {
        $procIsoEntrypointText = Get-Content -LiteralPath $procIsoEntrypointPath -Raw
        $procIsoHasRawCall = $procIsoEntrypointText -match '(?m)^\s*squad_proc_iso_run\s*$'
        $procIsoHasLogWrap = $procIsoEntrypointText -match 'log\s+"\$\(squad_proc_iso'
        if ($procIsoHasRawCall -and -not $procIsoHasLogWrap) {
            Add-Pass "R1/R6: worker/entrypoint.sh calls the raw squad_proc_iso_run and never pipes the probe's emitted line through log() decoration"
        } else {
            Add-Fail "R1/R6: worker/entrypoint.sh does not call the bare squad_proc_iso_run (found=$procIsoHasRawCall) and/or still wraps the probe's output through log() (found=$procIsoHasLogWrap)"
        }
    } else {
        Add-Fail "R1/R6: worker/entrypoint.sh is missing; cannot check the probe call site"
    }

    # T10 (issue #86): the single real chokepoint is Invoke-ProcIsoAzRead's
    # own call to the `az` executable. Exactly one such call site must exist,
    # and it must live in the reader, not the parser or the entrypoint.
    $procIsoInvokeSitePattern = '-FilePath\s+"az"'
    $procIsoReaderInvokeSites = @([regex]::Matches($procIsoReaderText, $procIsoInvokeSitePattern))
    $procIsoParserInvokeSites = @([regex]::Matches($procIsoParserText, $procIsoInvokeSitePattern))
    $procIsoReportInvokeSites = @([regex]::Matches($procIsoReportText, $procIsoInvokeSitePattern))
    if ($procIsoReaderInvokeSites.Count -eq 1 -and $procIsoParserInvokeSites.Count -eq 0 -and $procIsoReportInvokeSites.Count -eq 0) {
        Add-Pass "T10: exactly one call site invokes the 'az' executable, and it lives in scripts/lib/proc-isolation-reader.ps1 (not the parser or entrypoint)"
    } else {
        Add-Fail "T10: PC-1's single-chokepoint claim does not hold: reader has $($procIsoReaderInvokeSites.Count) az invocation site(s), parser has $($procIsoParserInvokeSites.Count), entrypoint has $($procIsoReportInvokeSites.Count) (expected 1/0/0)"
    }

    if ($procIsoReaderText -match [regex]::Escape('account set') -and $procIsoReaderText -match [regex]::Escape('"exec"')) {
        Add-Pass "scripts/lib/proc-isolation-reader.ps1 names both 'account set' and 'exec' as literals -- the operations PC-1 refuses even though it only ever needs read verbs"
    } else {
        Add-Fail "scripts/lib/proc-isolation-reader.ps1 does not reference both banned literals ('account set', 'exec'); the deny checks cannot be verified from source"
    }
}

# T10 runtime: every deny rule in Invoke-ProcIsoAzRead must actually refuse --
# observed as a thrown error AND zero calls reaching the stub `az`.
if (-not $IsWindowsHost) {
    Write-Host "  [SKIP] PC-1 stub-driven Invoke-ProcIsoAzRead deny/allow checks require Windows (.cmd stub)" -ForegroundColor Yellow
} elseif ((Test-Path -LiteralPath $procIsoReaderPath) -and (Test-Path -LiteralPath $procIsoStubHarnessPath)) {
    . $procIsoReaderPath
    . $procIsoStubHarnessPath
    $procIsoStub = $null
    $procIsoPrevPath = $env:PATH
    $procIsoPrevLog = $env:SQUAD_PROC_ISO_AZ_LOG
    try {
        $procIsoStub = New-ProcIsoStubEnvironment
        $env:PATH = "$($procIsoStub.BinDir);$procIsoPrevPath"
        $env:SQUAD_PROC_ISO_AZ_LOG = $procIsoStub.AzLog

        $procIsoDenyCases = @(
            @{ Name = "a mutating 'create' verb"; Args = @("containerapp", "job", "create", "--name", "x", "--resource-group", "y", "--subscription", $script:ProcIsoStubSubscriptionId) },
            @{ Name = "a mutating 'delete' verb"; Args = @("containerapp", "job", "delete", "--name", "x", "--resource-group", "y", "--subscription", $script:ProcIsoStubSubscriptionId) },
            @{ Name = "an 'exec' call"; Args = @("containerapp", "exec", "--name", "x", "--resource-group", "y", "--subscription", $script:ProcIsoStubSubscriptionId) },
            @{ Name = "a 'job start' call"; Args = @("containerapp", "job", "start", "--name", "x", "--resource-group", "y", "--subscription", $script:ProcIsoStubSubscriptionId) },
            @{ Name = "'az account set'"; Args = @("account", "set", "--subscription", $script:ProcIsoStubSubscriptionId) },
            @{ Name = "a call with no --subscription"; Args = @("account", "show") },
            @{ Name = "an unlisted command shape"; Args = @("storage", "account", "list", "--subscription", $script:ProcIsoStubSubscriptionId) }
        )
        $procIsoDenyFailures = @()
        foreach ($case in $procIsoDenyCases) {
            Reset-ProcIsoStubLog -Stub $procIsoStub
            $threw = $false
            try { Invoke-ProcIsoAzRead -AzArgs $case.Args | Out-Null } catch { $threw = $true }
            $callsMade = @(Get-ProcIsoStubCalls -Stub $procIsoStub)
            if (-not $threw -or $callsMade.Count -ne 0) {
                $procIsoDenyFailures += "$($case.Name) (threw=$threw, calls reaching az=$($callsMade.Count))"
            }
        }
        if ($procIsoDenyFailures.Count -eq 0) {
            Add-Pass "T10: Invoke-ProcIsoAzRead refuses all $($procIsoDenyCases.Count) denied shapes (mutating verbs, exec, job start, account set, missing --subscription, an unlisted command) with zero calls ever reaching az"
        } else {
            Add-Fail "T10: Invoke-ProcIsoAzRead let a denied shape through: $($procIsoDenyFailures -join '; ')"
        }

        Reset-ProcIsoStubLog -Stub $procIsoStub
        $procIsoAllowResult = $null
        $procIsoAllowThrew = $false
        try {
            $procIsoAllowResult = Invoke-ProcIsoAzRead -AzArgs @("account", "show", "--subscription", $script:ProcIsoStubSubscriptionId, "-o", "json")
        } catch { $procIsoAllowThrew = $true }
        $procIsoAllowCalls = @(Get-ProcIsoStubCalls -Stub $procIsoStub)
        if (-not $procIsoAllowThrew -and $procIsoAllowResult.ExitCode -eq 0 -and $procIsoAllowCalls.Count -eq 1) {
            Add-Pass "T10: Invoke-ProcIsoAzRead allows a properly-shaped, subscription-pinned read through to az (proves the chokepoint denies by rule, not by refusing everything)"
        } else {
            Add-Fail "T10: Invoke-ProcIsoAzRead did not allow a legitimate read through as expected (threw=$procIsoAllowThrew, calls=$($procIsoAllowCalls.Count))"
        }

        # Live-mode round trip: the stub reports an execution whose log
        # carries the probe's "yes" line. The report must classify it exactly
        # that way, make exactly the 3 expected read calls (account show,
        # execution list, logs show), and never touch a mutating verb.
        if (Test-Path -LiteralPath $procIsoReportPath) {
            $procIsoYes = Invoke-ProcIsoCliCapture -Stub $procIsoStub -ScriptPath $procIsoReportPath -Mode "observed-yes" -CliArguments @("-Json")
            if ($procIsoYes.ExitCode -eq 0 -and $procIsoYes.StdOut -match '"sameUidEnvironReadable":\s*"yes"') {
                Add-Pass "Live-mode round trip via the stub's observed-yes log classifies same-uid-environ-readable as 'yes'"
            } else {
                Add-Fail "Live-mode observed-yes round trip did not classify as expected (exit=$($procIsoYes.ExitCode)): $($procIsoYes.StdOut) $($procIsoYes.StdErr)"
            }
            $procIsoYesReadOnlyCalls = @($procIsoYes.AzCalls | Where-Object { $_ -match '^(create|update|delete|remove|set|assign|grant|revoke|start|stop|restart|deploy|build|push|login|logout|purge|restore|exec)\b' -or $_ -match '\bexec\b' })
            if ($procIsoYesReadOnlyCalls.Count -eq 0) {
                Add-Pass "The live-mode round trip issued zero mutating/exec calls"
            } else {
                Add-Fail "The live-mode round trip issued a mutating/exec-shaped call: $($procIsoYesReadOnlyCalls -join '; ')"
            }

            $procIsoNo = Invoke-ProcIsoCliCapture -Stub $procIsoStub -ScriptPath $procIsoReportPath -Mode "observed-no" -CliArguments @("-Json")
            if ($procIsoNo.ExitCode -eq 0 -and $procIsoNo.StdOut -match '"sameUidEnvironReadable":\s*"no"') {
                Add-Pass "Live-mode round trip via the stub's observed-no log classifies same-uid-environ-readable as 'no'"
            } else {
                Add-Fail "Live-mode observed-no round trip did not classify as expected (exit=$($procIsoNo.ExitCode)): $($procIsoNo.StdOut) $($procIsoNo.StdErr)"
            }

            # T11: nothing in the stub's default (unset mode) log carries the
            # probe's line at all -- this must classify as not-yet-observed,
            # never fabricated as yes or no.
            $procIsoAbsent = Invoke-ProcIsoCliCapture -Stub $procIsoStub -ScriptPath $procIsoReportPath -Mode "" -CliArguments @("-Json")
            if ($procIsoAbsent.ExitCode -eq 0 -and $procIsoAbsent.StdOut -match '"sameUidEnvironReadable":\s*"not-yet-observed"' -and $procIsoAbsent.StdOut -match '"observed":\s*false') {
                Add-Pass "T11: a live read with no SQUAD-PROC-ISO line anywhere in scanned logs classifies as 'not-yet-observed', not a fabricated yes/no"
            } else {
                Add-Fail "T11: an absent probe line did not classify as not-yet-observed (exit=$($procIsoAbsent.ExitCode)): $($procIsoAbsent.StdOut) $($procIsoAbsent.StdErr)"
            }

            # L2: one of two scanned executions fails to read. Absence of the
            # probe line cannot be concluded from a partial read, so this must
            # exit 3 (inconclusive-partial-read), never 0.
            $procIsoFailOne = Invoke-ProcIsoCliCapture -Stub $procIsoStub -ScriptPath $procIsoReportPath -Mode "fail-one" -CliArguments @("-Json")
            if ($procIsoFailOne.ExitCode -eq 3 -and $procIsoFailOne.StdOut -match '"status":\s*"inconclusive-partial-read"' -and $procIsoFailOne.StdOut -match '"executionsScanned":\s*2' -and $procIsoFailOne.StdOut -match '"executionsRead":\s*1') {
                Add-Pass "L2: a partial read (1 of 2 scanned executions fails) exits 3 / inconclusive-partial-read, never 0"
            } else {
                Add-Fail "L2: a partial read did not exit 3 / inconclusive-partial-read as required (exit=$($procIsoFailOne.ExitCode)): $($procIsoFailOne.StdOut) $($procIsoFailOne.StdErr)"
            }

            # L2: both scanned executions fail to read. Nothing was read, so
            # nothing is known -- this must exit 2 (live read unavailable),
            # never 0 / not-yet-observed.
            $procIsoFailAll = Invoke-ProcIsoCliCapture -Stub $procIsoStub -ScriptPath $procIsoReportPath -Mode "fail-all" -CliArguments @("-Json")
            if ($procIsoFailAll.ExitCode -eq 2 -and $procIsoFailAll.StdErr -match "live read unavailable" -and $procIsoFailAll.StdOut -notmatch '"observed"') {
                Add-Pass "L2: a total read failure (0 of 2 scanned executions readable) exits 2 / live read unavailable, never 0 / not-yet-observed"
            } else {
                Add-Fail "L2: a total read failure did not exit 2 / live read unavailable as required (exit=$($procIsoFailAll.ExitCode)): $($procIsoFailAll.StdOut) $($procIsoFailAll.StdErr)"
            }

            # L3: the job template read itself fails, so the container name
            # cannot be resolved and must fall back to the job name as an
            # EXPLICITLY REPORTED assumption -- the read must still succeed
            # (the stub accepts the job name as --container in this mode).
            $procIsoShowFails = Invoke-ProcIsoCliCapture -Stub $procIsoStub -ScriptPath $procIsoReportPath -Mode "show-fails" -CliArguments @("-Json")
            if ($procIsoShowFails.ExitCode -eq 0 -and $procIsoShowFails.StdOut -match '"containerSource":\s*"assumed"' -and $procIsoShowFails.StdOut -match '"container":\s*"caj-pc1stub-session"') {
                Add-Pass "L3: when the live job template cannot be read, the container name falls back to the job name and the fallback is reported as an explicit assumption, not silently presented as fact"
            } else {
                Add-Fail "L3: the container-name assumption fallback did not behave/report as required (exit=$($procIsoShowFails.ExitCode)): $($procIsoShowFails.StdOut) $($procIsoShowFails.StdErr)"
            }

            # L1: an out-of-range -TailLines must fail closed BEFORE any `az`
            # call is made -- never silently clamped, never sent to the CLI
            # (which would reject it as a usage error and be swallowed into a
            # false not-yet-observed, exactly as the prior revisions' 500
            # default was).
            $procIsoOutOfRangeTail = Invoke-ProcIsoCliCapture -Stub $procIsoStub -ScriptPath $procIsoReportPath -Mode "" -CliArguments @("-Json", "-TailLines", "500")
            if ($procIsoOutOfRangeTail.ExitCode -eq 2 -and $procIsoOutOfRangeTail.AzCalls.Count -eq 0) {
                Add-Pass "L1: -TailLines 500 (out of the CLI's 0-300 range) exits 2 with zero az calls made -- rejected before Azure is ever contacted"
            } else {
                Add-Fail "L1: an out-of-range -TailLines did not fail closed before contacting az (exit=$($procIsoOutOfRangeTail.ExitCode), azCalls=$($procIsoOutOfRangeTail.AzCalls.Count)): $($procIsoOutOfRangeTail.StdOut) $($procIsoOutOfRangeTail.StdErr)"
            }
        } else {
            Add-Fail "Cannot run the stub-harness-driven live round trip; scripts/proc-isolation-report.ps1 is missing"
        }
    } finally {
        $env:PATH = $procIsoPrevPath
        if ($null -eq $procIsoPrevLog) { Remove-Item Env:SQUAD_PROC_ISO_AZ_LOG -ErrorAction SilentlyContinue } else { $env:SQUAD_PROC_ISO_AZ_LOG = $procIsoPrevLog }
        if ($procIsoStub) { Remove-ProcIsoStubEnvironment -Stub $procIsoStub }
    }
} else {
    Add-Fail "Cannot exercise Invoke-ProcIsoAzRead's deny/allow rules; reader or stub harness is missing"
}

# T12/R2/R5: the pure parser's yes/no/unknown classification against each
# committed fixture, entirely offline (no Azure call, no stub, no child
# process). Includes the R2 JSON-envelope/raw/legacy-prefixed shapes and the
# R5 negatives (embedded prose, v2 schema, truncated, unrelated JSON), all of
# which must classify as not-yet-observed -- never a fabricated yes/no.
if ((Test-Path -LiteralPath $procIsoParserPath) -and $procIsoMissingFixtures.Count -eq 0) {
    . $procIsoParserPath
    $procIsoFixtureExpectations = @{
        "observed-yes"             = "yes"
        "observed-no"              = "no"
        "observed-unknown"         = "unknown"
        "not-yet-observed"         = "not-yet-observed"
        "raw-yes"                  = "yes"
        "legacy-prefixed-yes"      = "yes"
        "negative-embedded-prose"  = "not-yet-observed"
        "negative-v2-schema"       = "not-yet-observed"
        "negative-truncated"       = "not-yet-observed"
        "negative-unrelated-json"  = "not-yet-observed"
    }
    $procIsoFixtureFailures = @()
    foreach ($name in $procIsoFixtureNames) {
        $fixtureLines = @(Get-Content -LiteralPath $procIsoFixturePaths[$name])
        $observation = Get-ProcIsoObservation -Lines $fixtureLines
        $expected = $procIsoFixtureExpectations[$name]
        if ($observation.SameUidEnvironReadable -ne $expected) {
            $procIsoFixtureFailures += "$name expected '$expected', got '$($observation.SameUidEnvironReadable)'"
        }
    }
    if ($procIsoFixtureFailures.Count -eq 0) {
        Add-Pass "T12/R2/R5: Get-ProcIsoObservation classifies all $($procIsoFixtureNames.Count) committed fixtures correctly -- JSON-envelope yes/no/unknown/not-yet-observed (R2's real wire shape), raw and legacy-prefixed yes (R2 backward compatibility), and all 4 R5 negatives (embedded prose, v2 schema, truncated, unrelated JSON) as not-yet-observed -- entirely offline"
    } else {
        Add-Fail "T12/R2/R5: parser misclassified fixture(s): $($procIsoFixtureFailures -join '; ')"
    }

    $procIsoEmptyObservation = Get-ProcIsoObservation -Lines @()
    if ($procIsoEmptyObservation.SameUidEnvironReadable -eq "not-yet-observed" -and -not $procIsoEmptyObservation.Observed) {
        Add-Pass "T11: an empty line set (nothing read at all) also classifies as not-yet-observed, not a fabricated result"
    } else {
        Add-Fail "T11: an empty line set did not classify as not-yet-observed"
    }
} else {
    Add-Fail "Cannot exercise the PC-1 parser's classification; parser or fixtures are missing"
}

# ---------------------------------------------------------------------------
# R4 (issue #86 security revision): end-to-end contract.
#
# Runs the SHIPPED probe (worker/lib/proc-isolation-probe.sh) under a real
# bash, and feeds the EXACT emitted bytes into the SHIPPED parser
# (scripts/lib/proc-isolation-parser.ps1) -- raw, wrapped in a JSON envelope,
# and legacy-prefixed. This is the contract the prior revision's live
# "not-yet-observed" result was never actually evidence for: the parser could
# never have observed the emitted shape (log()-decorated, no --format json),
# so its silence proved nothing. This check proves the CURRENT shipped pair
# can observe each other, using only the real artifacts -- no reimplemented
# probe, no reimplemented parser.
#
# Skipped (not passed) when bash is unavailable, matching the honesty rule
# worker/tests/lib/deps.sh already established (a missing dependency is
# reported as absent, never silently counted as green).
# ---------------------------------------------------------------------------
Write-Section "Process-isolation R4 end-to-end contract"
$procIsoBash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $procIsoBash) {
    Add-Skip "R4 end-to-end contract requires bash to run the shipped probe; bash was not found on PATH"
} elseif (-not (Test-Path -LiteralPath $procIsoProbePath)) {
    Add-Fail "R4: worker/lib/proc-isolation-probe.sh is missing; the end-to-end contract cannot run"
} elseif (-not (Test-Path -LiteralPath $procIsoParserPath)) {
    Add-Fail "R4: scripts/lib/proc-isolation-parser.ps1 is missing; the end-to-end contract cannot run"
} else {
    # `bash` on a Windows host is commonly WSL (which needs /mnt/<drive>/...)
    # or Git Bash/MSYS (which accepts /<drive>/... or a plain forward-slash
    # path). Try each candidate shape in turn and use whichever actually
    # produces the probe's output -- this is path-translation plumbing only,
    # not a change to what is being tested.
    $procIsoBashPathCandidates = @()
    if ($procIsoProbePath -match '^([A-Za-z]):\\(.*)$') {
        $procIsoDriveLetter = $Matches[1].ToLower()
        $procIsoRestOfPath = $Matches[2] -replace '\\', '/'
        $procIsoBashPathCandidates += "/mnt/$procIsoDriveLetter/$procIsoRestOfPath"
        $procIsoBashPathCandidates += "/$procIsoDriveLetter/$procIsoRestOfPath"
    }
    $procIsoBashPathCandidates += ($procIsoProbePath -replace '\\', '/')

    $procIsoBashProbeLine = $null
    foreach ($candidate in $procIsoBashPathCandidates) {
        try {
            $attempt = (& $procIsoBash.Source $candidate 2>$null | Select-Object -First 1)
        } catch {
            $attempt = $null
        }
        if ($attempt) { $procIsoBashProbeLine = $attempt; break }
    }
    if (-not $procIsoBashProbeLine) {
        Add-Fail "R4: running the shipped probe under bash produced no output"
    } else {
        . $procIsoParserPath

        # Shape 1: raw -- exactly what worker/entrypoint.sh now emits via the
        # bare squad_proc_iso_run (R1), and what --format json's Log field
        # carries verbatim.
        $procIsoRawObs = Get-ProcIsoObservation -Lines @($procIsoBashProbeLine)
        if ($procIsoRawObs.Observed -and $procIsoRawObs.SameUidEnvironReadable -match '^(yes|no|unknown)$' -and $procIsoRawObs.ProcMounted -match '^(yes|no)$' -and $procIsoRawObs.Uid -and $procIsoRawObs.User) {
            Add-Pass "R4: the shipped parser observes the shipped probe's RAW emitted bytes and populates every field (same-uid-environ-readable=$($procIsoRawObs.SameUidEnvironReadable), proc-mounted=$($procIsoRawObs.ProcMounted), hidepid=$($procIsoRawObs.Hidepid), uid=$($procIsoRawObs.Uid), user=$($procIsoRawObs.User))"
        } else {
            Add-Fail "R4: the shipped parser did not fully observe the shipped probe's raw output: $($procIsoBashProbeLine)"
        }

        # Shape 2: JSON envelope -- the real --format json wire shape (R3).
        $procIsoJsonLine = (@{ Log = $procIsoBashProbeLine; TimeStamp = "2026-08-11T02:30:00.000000Z" } | ConvertTo-Json -Compress)
        $procIsoJsonObs = Get-ProcIsoObservation -Lines @($procIsoJsonLine)
        if ($procIsoJsonObs.Observed -and $procIsoJsonObs.SameUidEnvironReadable -eq $procIsoRawObs.SameUidEnvironReadable -and $procIsoJsonObs.Uid -eq $procIsoRawObs.Uid) {
            Add-Pass "R4: the shipped parser observes the shipped probe's output wrapped in a {`"Log`":...} JSON envelope, identically to the raw shape"
        } else {
            Add-Fail "R4: the shipped parser did not observe the JSON-enveloped probe output: $($procIsoJsonLine)"
        }

        # Shape 3: legacy-prefixed -- an ISO timestamp plus the old log()
        # helper's literal "[squad-on-aca] " prefix, for backward
        # compatibility with logs captured before this revision shipped.
        $procIsoPrefixedLine = "2026-08-11T02:31:00.000000Z [squad-on-aca] $procIsoBashProbeLine"
        $procIsoPrefixedObs = Get-ProcIsoObservation -Lines @($procIsoPrefixedLine)
        if ($procIsoPrefixedObs.Observed -and $procIsoPrefixedObs.SameUidEnvironReadable -eq $procIsoRawObs.SameUidEnvironReadable -and $procIsoPrefixedObs.Uid -eq $procIsoRawObs.Uid) {
            Add-Pass "R4: the shipped parser observes the shipped probe's output with a legacy ISO-timestamp + '[squad-on-aca] ' prefix, identically to the raw shape"
        } else {
            Add-Fail "R4: the shipped parser did not observe the legacy-prefixed probe output: $($procIsoPrefixedLine)"
        }
    }
}

# Fail-closed intent resolution: with no explicit parameters and no reachable
# deploy.outputs.json, the report must exit 2 -- never guess a subscription.
if (Test-Path -LiteralPath $procIsoReportPath) {
    $procIsoAbsentOutputs = Join-Path $RepoRoot "scripts\tests\fixtures\proc-isolation\.does-not-exist.json"
    $procIsoPsExe = (Get-Process -Id $PID).Path
    & $procIsoPsExe -NoProfile -NonInteractive -File $procIsoReportPath -DeployOutputsPath $procIsoAbsentOutputs 2>&1 | Out-Null
    $procIsoFailClosedExit = $LASTEXITCODE
    if ($procIsoFailClosedExit -eq 2) {
        Add-Pass "With no explicit parameters and no reachable deploy.outputs.json, the PC-1 report exits 2 (fails closed instead of guessing a subscription)"
    } else {
        Add-Fail "Unresolved PC-1 intent did not exit 2 as the fail-closed contract requires (observed exit $procIsoFailClosedExit)"
    }

    # A live read failure (e.g. an unreachable subscription) must ALSO exit 2
    # and must NEVER be reported as "not-yet-observed" -- those are different
    # claims, and conflating them would let a broken read masquerade as a
    # clean absence of evidence.
    & $procIsoPsExe -NoProfile -NonInteractive -File $procIsoReportPath -ResourceGroupName "rg-does-not-exist" -SubscriptionId "00000000-0000-0000-0000-000000000000" -NamePrefix "does-not-exist" -DeployOutputsPath $procIsoAbsentOutputs 2>&1 | Out-Null
    $procIsoLiveFailExit = $LASTEXITCODE
    if ($procIsoLiveFailExit -eq 2) {
        Add-Pass "A live read against an unreachable subscription exits 2 (live-read-unavailable), never silently reported as 0 / not-yet-observed"
    } else {
        Add-Fail "A live read against an unreachable subscription did not exit 2 as expected (observed exit $procIsoLiveFailExit)"
    }
} else {
    Add-Fail "Cannot exercise PC-1 fail-closed intent resolution; entrypoint is missing"
}

# Redaction / no-fabrication hygiene: none of the 4 committed fixtures may
# carry a GUID-shaped identifier, matching CV-1/CV-2's fixture redaction bar.
if ($procIsoMissingFixtures.Count -eq 0) {
    $procIsoGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $procIsoFixtureLeaks = @()
    foreach ($name in $procIsoFixtureNames) {
        $text = Get-Content -LiteralPath $procIsoFixturePaths[$name] -Raw
        if ($text -match $procIsoGuidPattern) { $procIsoFixtureLeaks += $name }
    }
    if ($procIsoFixtureLeaks.Count -eq 0) {
        Add-Pass "None of the 4 committed PC-1 fixtures contain a GUID-shaped identifier"
    } else {
        Add-Fail "PC-1 fixture(s) contain a GUID-shaped identifier: $($procIsoFixtureLeaks -join ', ')"
    }
}

# T13: docs/security-report.md must state the PC-1 mechanism, ordering, and
# the ACTUAL observed live result honestly -- it must record the real
# same-uid-environ-readable answer this platform gave, the live diagnostic
# evidence behind it, and that PC-2 was implemented (not declined) as a
# result, per this issue's reversal trigger.
$procIsoSecurityReportPath = Join-Path $RepoRoot "docs\security-report.md"
if (Test-Path -LiteralPath $procIsoSecurityReportPath) {
    $procIsoDocsText = Get-Content -LiteralPath $procIsoSecurityReportPath -Raw

    $procIsoRequiredPhrases = @(
        "observed live in ACA",
        "same-uid-environ-readable=yes",
        "uid=1001 user=squad",
        "uid=1002 user=squad-identity"
    )
    $procIsoDocsMissingPhrases = @($procIsoRequiredPhrases | Where-Object { $procIsoDocsText -notmatch [regex]::Escape($_) })
    if ($procIsoDocsMissingPhrases.Count -eq 0) {
        Add-Pass "docs/security-report.md states PC-1's observed live result and PC-2's live dual-uid proof honestly (all $($procIsoRequiredPhrases.Count) required phrases present)"
    } else {
        Add-Fail "docs/security-report.md is missing required PC-1/PC-2 evidence phrase(s): $($procIsoDocsMissingPhrases -join '; ')"
    }

    # T13: the report must not still describe the answer as pending/unknown
    # now that a real result has been observed and recorded above.
    $procIsoStaleClaims = @("genuinely pending", "genuinely unknown", "not yet observed in ACA")
    $procIsoDocsStale = @($procIsoStaleClaims | Where-Object { $procIsoDocsText -match [regex]::Escape($_) })
    if ($procIsoDocsStale.Count -eq 0) {
        Add-Pass "T13: docs/security-report.md does not still describe PC-1's answer as pending/unknown now that a live result has been recorded"
    } else {
        Add-Fail "T13: docs/security-report.md contains stale pending/unknown language despite recording a live result: $($procIsoDocsStale -join '; ')"
    }

    if ($procIsoDocsText -match [regex]::Escape("PC-2") -and $procIsoDocsText -match [regex]::Escape("reversal trigger has fired") -and $procIsoDocsText -match [regex]::Escape("implemented")) {
        Add-Pass "docs/security-report.md records that PC-2's reversal trigger fired and PC-2 was implemented (not silently left declined)"
    } else {
        Add-Fail "docs/security-report.md does not record that PC-2 was implemented following its reversal trigger"
    }
} else {
    Add-Fail "docs/security-report.md is missing; PC-1's honesty requirements cannot be checked"
}

# ---------------------------------------------------------------------------
# PC-2 (issue #86): a second, kernel-enforced UID boundary for the identity-
# holding mode, implemented because PC-1's live result was "yes". Mirrors the
# PC-1 static-check style above: grep-based, mutation-testable assertions
# against worker/Dockerfile and worker/entrypoint.sh, plus the same test
# suite (worker/tests/test_uid_separation.sh) run via worker/tests/run-tests.sh
# elsewhere in this pipeline.
# ---------------------------------------------------------------------------
Write-Section "PC-2: separate UID for the identity-holding mode (issue #86)"

$pc2DockerfilePath = Join-Path $RepoRoot "worker\Dockerfile"
$pc2EntrypointPath = Join-Path $RepoRoot "worker\entrypoint.sh"
$pc2TestPath = Join-Path $RepoRoot "worker\tests\test_uid_separation.sh"

if ((Test-Path -LiteralPath $pc2DockerfilePath) -and (Test-Path -LiteralPath $pc2EntrypointPath)) {
    $pc2DockerfileText = Get-Content -LiteralPath $pc2DockerfilePath -Raw
    $pc2EntrypointText = Get-Content -LiteralPath $pc2EntrypointPath -Raw

    if ($pc2DockerfileText -match [regex]::Escape('useradd -m -s /bin/bash squad ') -and $pc2DockerfileText -match [regex]::Escape('useradd -m -s /bin/bash squad-identity ')) {
        Add-Pass "PC-2: worker/Dockerfile creates two distinct users, 'squad' and 'squad-identity'"
    } else {
        Add-Fail "PC-2: worker/Dockerfile does not create both the 'squad' and 'squad-identity' users"
    }

    if ($pc2DockerfileText -notmatch '(?m)^USER squad$') {
        Add-Pass "PC-2: worker/Dockerfile no longer pins the default runtime user to 'squad' (no trailing 'USER squad'); the entrypoint chooses per SQUAD_MODE"
    } else {
        Add-Fail "PC-2: worker/Dockerfile still pins a trailing 'USER squad', which would defeat entrypoint.sh's per-mode privilege drop"
    }

    if ($pc2DockerfileText -match [regex]::Escape('chmod 2775 /workspace')) {
        Add-Pass "PC-2: /workspace is shared via a setgid group directory (chmod 2775), not made world-writable, so both UIDs can still clone the repo"
    } else {
        Add-Fail "PC-2: worker/Dockerfile does not set up /workspace as a setgid-shared directory (chmod 2775) for both UIDs"
    }

    $pc2DropMatch = [regex]::Match($pc2EntrypointText, '(?ms)if \[\[ "\$\(id -u\)" -eq 0 \]\]; then.*?^fi$')
    if ($pc2DropMatch.Success) {
        $pc2DropText = $pc2DropMatch.Value
        Add-Pass "PC-2: worker/entrypoint.sh contains the root-gated privilege-drop block"

        if ($pc2DropText -match [regex]::Escape('SQUAD_RUNTIME_USER="squad"') -and $pc2DropText -match '"\$\{SQUAD_MODE:-smoke\}"\s*==\s*"ralph"' -and $pc2DropText -match [regex]::Escape('SQUAD_RUNTIME_USER="squad-identity"')) {
            Add-Pass "PC-2: the drop selects 'squad-identity' only for SQUAD_MODE=ralph, and 'squad' otherwise"
        } else {
            Add-Fail "PC-2: the drop does not select 'squad-identity' specifically (and only) for SQUAD_MODE=ralph"
        }

        if ($pc2DropText -match [regex]::Escape('exec env -u HOME runuser -p -u "$SQUAD_RUNTIME_USER"')) {
            Add-Pass "PC-2: the drop execs 'env -u HOME runuser -p' -- replaces the process (no root parent left), preserves the ACA-injected environment, and clears the stale root HOME before the switch"
        } else {
            Add-Fail "PC-2: the drop does not exec 'env -u HOME runuser -p -u \"\$SQUAD_RUNTIME_USER\"' as expected"
        }
    } else {
        Add-Fail "PC-2: worker/entrypoint.sh is missing the root-gated privilege-drop block entirely"
    }

    if ($pc2EntrypointText -match '(?m)^export HOME="\$\{HOME:-/home/squad\}"$') {
        Add-Fail "PC-2: worker/entrypoint.sh's HOME fallback is still hard-coded to /home/squad, which would break the squad-identity user PC-2 introduces"
    } else {
        Add-Pass "PC-2: worker/entrypoint.sh's HOME fallback is resolved from the actual current user (not hard-coded to /home/squad)"
    }

    # Ordering: the drop must happen before the identity-drop mode dispatch
    # (the same anchor test_identity_drop_order.sh uses) -- otherwise a
    # session or ralph process could start real work before its UID is set.
    $pc2DropLineMatch = [regex]::Match($pc2EntrypointText, '(?m)^if \[\[ "\$\(id -u\)" -eq 0 \]\]; then$')
    $pc2CaseLineMatch = [regex]::Match($pc2EntrypointText, '(?m)^case "\$\{SQUAD_MODE:-smoke\}" in$')
    if ($pc2DropLineMatch.Success -and $pc2CaseLineMatch.Success -and $pc2DropLineMatch.Index -lt $pc2CaseLineMatch.Index) {
        Add-Pass "PC-2: the privilege-drop block appears before the identity-drop mode dispatch in worker/entrypoint.sh"
    } else {
        Add-Fail "PC-2: the privilege-drop block does not appear before the identity-drop mode dispatch in worker/entrypoint.sh"
    }
} else {
    Add-Fail "PC-2: worker/Dockerfile or worker/entrypoint.sh is missing; PC-2 checks cannot run"
}

# ---------------------------------------------------------------------------
# The deploy is idempotent about its container registry
#
# Reported from a real first-time deploy: "it would be nice if the azure
# deployment were idempotent, but it seems to generate az resource names on the
# fly (at least the ACR)". It did: an unconditional Get-Random meant the second
# run built a SECOND registry, pushed the image there, and left the first with
# nothing pointing at it. The reporter only escaped it by noticing -AcrName.
#
# Behaviour, exercised rather than described: the name-resolution block is
# extracted from deploy.ps1 and run against a stub `az`, so what is checked is
# what the deploy would actually pick.
# ---------------------------------------------------------------------------
Write-Section "Deploy reuses its container registry (does not invent one per run)"

$deployIdemPath = Join-Path $RepoRoot "scripts\deploy.ps1"
if (-not (Test-Path $deployIdemPath)) {
    Add-Fail "scripts/deploy.ps1 is missing; the registry-idempotence checks cannot run"
} else {
    $deployText = Get-Content -LiteralPath $deployIdemPath -Raw

    # 1. Structural: a generated name must not be the FIRST thing tried.
    $randIdx = $deployText.IndexOf('Get-Random -Count 8')
    $reuseIdx = $deployText.IndexOf('deploy.outputs.json')
    $listIdx = $deployText.IndexOf('az acr list')
    if ($randIdx -lt 0) {
        Add-Fail "scripts/deploy.ps1 no longer generates a registry name at all; a first deploy has nothing to create"
    } elseif ($reuseIdx -ge 0 -and $listIdx -ge 0 -and $listIdx -lt $randIdx) {
        Add-Pass "scripts/deploy.ps1 looks for an existing registry (recorded, then live in the resource group) BEFORE generating a new name"
    } else {
        Add-Fail "scripts/deploy.ps1 generates a registry name without first looking for one that already exists; every run would create another registry"
    }

    # 2. Behavioural: run the real resolution block against a stub `az` and a
    #    stub outputs file, and assert which name comes out. Three cases, each
    #    of which was silently wrong before.
    $idemWork = Join-Path ([System.IO.Path]::GetTempPath()) ("squad-acr-idem-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $idemWork | Out-Null
    try {
        # Extract the block verbatim so this tests the shipped logic, not a copy.
        $blockMatch = [regex]::Match($deployText, '(?s)if \(-not \$AcrName\) \{.*?\n\}\r?\n')
        if (-not $blockMatch.Success) {
            Add-Fail "Could not extract the registry-name resolution block from scripts/deploy.ps1; its shape changed and this check is no longer reading the real logic"
        } else {
            $block = $blockMatch.Value
            $harness = @"
param([string]`$AcrName = "", [string]`$ResourceGroupName = "rg-test", [string]`$NamePrefix = "squad-aca", [string]`$repoRoot = "$idemWork")
function az {
    if (`$args -contains 'list') { if (`$env:STUB_ACRS) { `$env:STUB_ACRS -split ',' | ForEach-Object { `$_ } } ; return }
}
$block
Write-Output "RESOLVED=`$AcrName"
"@
            $harnessPath = Join-Path $idemWork "resolve.ps1"
            Set-Content -LiteralPath $harnessPath -Value $harness -Encoding UTF8

            # Case A: a previous deploy from this clone recorded a name.
            Set-Content -LiteralPath (Join-Path $idemWork "deploy.outputs.json") -Value '{"acrName":"acrsquadacarecorded"}' -Encoding UTF8
            $env:STUB_ACRS = ""
            $outA = (& pwsh -NoProfile -File $harnessPath 2>&1 | Out-String)
            if ($outA -match 'RESOLVED=acrsquadacarecorded') {
                Add-Pass "A second deploy from the same clone REUSES the registry recorded by the first, instead of creating another"
            } else {
                Add-Fail "A second deploy from the same clone did not reuse the recorded registry (got: $(($outA -split "`n" | Where-Object { $_ -match 'RESOLVED=' }) -join ''))"
            }

            # Case B: no record (a fresh clone), but the registry exists in Azure.
            Remove-Item -LiteralPath (Join-Path $idemWork "deploy.outputs.json") -Force
            $env:STUB_ACRS = "acrsquadacalive"
            $outB = (& pwsh -NoProfile -File $harnessPath 2>&1 | Out-String)
            if ($outB -match 'RESOLVED=acrsquadacalive') {
                Add-Pass "A deploy from a DIFFERENT clone discovers the registry already in the resource group, so a colleague does not create a duplicate"
            } else {
                Add-Fail "A deploy with no recorded name did not discover the existing registry (got: $(($outB -split "`n" | Where-Object { $_ -match 'RESOLVED=' }) -join ''))"
            }

            # Case C: nothing anywhere -- generate, which is correct exactly once.
            $env:STUB_ACRS = ""
            $outC = (& pwsh -NoProfile -File $harnessPath 2>&1 | Out-String)
            if ($outC -match 'RESOLVED=acrsquadaca\w{8}') {
                Add-Pass "A genuinely first deploy still generates a registry name, and prints it so it can be passed to later runs"
            } else {
                Add-Fail "A first deploy did not generate a usable registry name (got: $(($outC -split "`n" | Where-Object { $_ -match 'RESOLVED=' }) -join ''))"
            }

            # Case D: several candidates -- refuse rather than guess, because
            # picking the wrong one deploys against an image nobody updated.
            $env:STUB_ACRS = "acrsquadacaone,acrsquadacatwo"
            $outD = (& pwsh -NoProfile -File $harnessPath 2>&1 | Out-String)
            if ($outD -match 'RESOLVED=') {
                Add-Fail "With TWO candidate registries the deploy picked one silently; picking wrong deploys a job against a stale image"
            } else {
                Add-Pass "With several candidate registries the deploy refuses and names them, rather than guessing"
            }
            $env:STUB_ACRS = $null
        }
    } finally {
        Remove-Item -LiteralPath $idemWork -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path -LiteralPath $pc2TestPath) {
    Add-Pass "PC-2: worker/tests/test_uid_separation.sh (the named test for this control) is present"
} else {
    Add-Fail "PC-2: worker/tests/test_uid_separation.sh is missing; PC-2 has no named test"
}

# ---------------------------------------------------------------------------
# Where a deploy lands: the region default, and reusing an existing one
#
# East US 2 is capacity-constrained and first-time deploys were failing there
# on capacity rather than on anything wrong with the deployment. A default that
# fails for a new user reads as "this product does not work".
#
# Changing a default is dangerous on its own: somebody who deployed to the old
# one and re-runs with no arguments must UPDATE what they have, not build a
# second environment in a new region.
# ---------------------------------------------------------------------------
Write-Section "Deploy region: default, derivation, and reuse"

$regionDeployPath = Join-Path $RepoRoot "scripts\deploy.ps1"
if (-not (Test-Path $regionDeployPath)) {
    Add-Fail "scripts/deploy.ps1 is missing; the region checks cannot run"
} else {
    $regionText = Get-Content -LiteralPath $regionDeployPath -Raw

    if ($regionText -match '\$DEFAULT_LOCATION\s*=\s*"centralus"') {
        Add-Pass "the default region is centralus, not a capacity-constrained one"
    } else {
        Add-Fail "scripts/deploy.ps1 no longer defaults to centralus; a first-time deploy can fail on region capacity rather than on anything wrong with it"
    }

    if ($regionText -match 'rg-\$NamePrefix-dev-\$Location') {
        Add-Pass "the resource-group default is DERIVED from the location, so the group name and the region it names cannot disagree"
    } else {
        Add-Fail "scripts/deploy.ps1 does not derive the resource-group name from the location; changing one leaves the other naming a different region"
    }

    $regionWork = Join-Path ([System.IO.Path]::GetTempPath()) ("squad-region-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $regionWork | Out-Null
    try {
        $regionBlock = [regex]::Match($regionText, '(?s)\$DEFAULT_LOCATION = "centralus".*?# --- end region resolution ---')
        if (-not $regionBlock.Success) {
            Add-Fail "Could not extract the region resolution block from scripts/deploy.ps1 (its markers moved); this check is no longer reading the real logic"
        } else {
            $rHarness = @"
param([string]`$Location = "", [string]`$ResourceGroupName = "", [string]`$NamePrefix = "squad-aca", [string]`$repoRoot = "$regionWork")
$($regionBlock.Value)
Write-Output "LOC=`$Location RG=`$ResourceGroupName"
"@
            $rPath = Join-Path $regionWork "resolve.ps1"
            Set-Content -LiteralPath $rPath -Value $rHarness -Encoding UTF8

            $rFresh = (& pwsh -NoProfile -File $rPath 2>&1 | Out-String)
            if ($rFresh -match 'LOC=centralus RG=rg-squad-aca-dev-centralus') {
                Add-Pass "a first deploy lands in centralus, in a resource group named for it"
            } else {
                Add-Fail "a first deploy did not resolve to centralus (got: $(($rFresh -split "`n" | Where-Object { $_ -match 'LOC=' }) -join ''))"
            }

            Set-Content -LiteralPath (Join-Path $regionWork "deploy.outputs.json") -Encoding UTF8 -Value (@{
                location = "eastus2"; resourceGroup = "rg-squad-aca-dev-eastus2"
            } | ConvertTo-Json)
            $rExisting = (& pwsh -NoProfile -File $rPath 2>&1 | Out-String)
            if ($rExisting -match 'LOC=eastus2 RG=rg-squad-aca-dev-eastus2') {
                Add-Pass "an EXISTING deployment keeps its own region and resource group, so changing the default cannot silently build a second environment beside it"
            } else {
                Add-Fail "an existing deployment did not keep its recorded region/group (got: $(($rExisting -split "`n" | Where-Object { $_ -match 'LOC=' }) -join ''))"
            }

            $rExplicit = (& pwsh -NoProfile -File $rPath -Location "westus3" 2>&1 | Out-String)
            if ($rExplicit -match 'LOC=westus3 RG=rg-squad-aca-dev-westus3') {
                Add-Pass "an explicit -Location wins over both the default and the recorded value, and brings the group name with it"
            } else {
                Add-Fail "an explicit -Location did not win (got: $(($rExplicit -split "`n" | Where-Object { $_ -match 'LOC=' }) -join ''))"
            }

            $rExplicitRg = (& pwsh -NoProfile -File $rPath -Location "westus3" -ResourceGroupName "rg-mine" 2>&1 | Out-String)
            if ($rExplicitRg -match 'LOC=westus3 RG=rg-mine') {
                Add-Pass "an explicit -ResourceGroupName is honoured rather than overwritten by the derived name"
            } else {
                Add-Fail "an explicit -ResourceGroupName was not honoured (got: $(($rExplicitRg -split "`n" | Where-Object { $_ -match 'RG=' }) -join ''))"
            }
        }
    } finally {
        Remove-Item -LiteralPath $regionWork -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($regionText -match 'CapacityHeavyUsage' -and $regionText -match '-Location <region>') {
        Add-Pass "a region capacity refusal is explained as a region problem, with the command to deploy elsewhere"
    } else {
        Add-Fail "scripts/deploy.ps1 does not recognise a region capacity refusal; the raw Azure error reads as a broken product to a first-time user"
    }

    # No script may keep a region baked into a DEFAULT, or they drift apart.
    # Matches an assignment or parameter default, not prose: deploy.ps1's own
    # comments name the old region while explaining why it moved, and a check
    # that failed on an explanation would push people to delete the
    # explanation.
    $bakedIn = @(Get-ChildItem -Path (Join-Path $RepoRoot "scripts") -Filter *.ps1 -Recurse |
        Where-Object { $_.FullName -notmatch '\\tests\\' -and $_.Name -ne 'validate.ps1' } |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '=\s*"rg-squad-aca-dev-eastus2"' } |
        ForEach-Object { $_.Name })
    if ($bakedIn.Count -eq 0) {
        Add-Pass "no script still DEFAULTS to the old capacity-constrained region"
    } else {
        Add-Fail "these still default to rg-squad-aca-dev-eastus2: $($bakedIn -join ', ')"
    }
}

# --- Key Vault: a permission grant that fails must not fail quietly ---------
#
# From issue #105. `az keyvault set-policy` only works on an access-policy
# vault; on an RBAC vault it fails, and role assignments are the only thing
# that grants anything. The script used to call it with `2>$null | Out-Null`,
# so on an RBAC vault the grant failed SILENTLY and the next line -- writing a
# secret -- came back 403. The deployment created a vault it could not use, and
# the error a person saw was Azure's, four lines later, with nothing pointing
# at the cause.
#
# These read the real deploy script rather than a copy of its intent.
Write-Host "`n[key vault] a vault this creates is a vault it can write to" -ForegroundColor Cyan
$kvText = Get-Content -LiteralPath (Join-Path $RepoRoot "scripts\deploy.ps1") -Raw
# Comment lines are stripped before the "is it still discarded" check below.
# The comment there NAMES the old broken call while explaining why it changed,
# and a check that failed on the explanation would push the next person to
# delete the explanation -- the same trap the region check documents.
$kvCode = ($kvText -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

if ($kvCode -match 'set-policy[^\r\n]*2>\$null') {
    Add-Fail "scripts/deploy.ps1 still discards the output of `az keyvault set-policy` (2>`$null); a grant that fails would be invisible again"
} else {
    Add-Pass "a failed key vault grant is not discarded"
}

if ($kvText -match 'enableRbacAuthorization') {
    Add-Pass "the deploy asks the vault WHICH permission model it uses, instead of assuming"
} else {
    Add-Fail "scripts/deploy.ps1 never reads enableRbacAuthorization, so it cannot tell an RBAC vault from an access-policy one"
}

if ($kvText -match 'Key Vault Secrets Officer') {
    Add-Pass "an RBAC vault is granted the data-plane role that writing a secret actually needs"
} else {
    Add-Fail "scripts/deploy.ps1 never assigns 'Key Vault Secrets Officer'; on an RBAC vault every secret write would 403"
}

if ($kvText -match 'Key Vault Secrets User') {
    Add-Pass "the job identity gets read-only access, not the officer role it writes with"
} else {
    Add-Fail "scripts/deploy.ps1 does not grant the managed identity 'Key Vault Secrets User'"
}

if ($kvText -match 'publicNetworkAccess') {
    Add-Pass "a vault with public access switched off is explained, not left to surface as ForbiddenByConnection"
} else {
    Add-Fail "scripts/deploy.ps1 never checks publicNetworkAccess; a policy-locked vault would fail with raw Azure text and no way forward"
}

# A role assignment is not effective the moment it is created, and the first
# secret write is what runs into that. Without a retry the fix above still
# fails intermittently -- which is the worst of both, because it looks like the
# permission model was wrong after all.
$kvRetry = [regex]::Match($kvText, '(?s)for \(\$attempt = 1.{0,400}?keyvault secret set')
if ($kvRetry.Success) {
    Add-Pass "the first secret write retries while the role assignment propagates"
} else {
    Add-Fail "the first key vault secret write does not retry; a fresh role assignment needs a moment and this would 403 on a timing race"
}


Write-Host ("  Passed: {0}" -f $script:Passes.Count) -ForegroundColor Green
Write-Host ("  Failed: {0}" -f $script:Failures.Count) -ForegroundColor ($(if ($script:Failures.Count -gt 0) { 'Red' } else { 'Green' }))
Write-Host ("  Skipped: {0}" -f $script:Skips.Count) -ForegroundColor ($(if ($script:Skips.Count -gt 0) { 'Yellow' } else { 'Green' }))
if ($script:Skips.Count -gt 0) {
    Write-Host "`nSkipped (NOT passes -- the dependency was missing):" -ForegroundColor Yellow
    $script:Skips | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($script:Failures.Count -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "`nAll validation checks passed." -ForegroundColor Green
exit 0
