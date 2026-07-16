$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot "scripts\lib\squad-aca-provider.ps1")

$workDir = Join-Path $PSScriptRoot ".work\provider"
$statePath = Join-Path $workDir "fake-state.json"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
if (Test-Path $statePath) { Remove-Item $statePath -Force }

$env:SQUAD_ACA_PROVIDER = "fake"
$env:SQUAD_ACA_FAKE_STATE_PATH = $statePath
$config = [pscustomobject]@{ resourceGroup = "rg-test"; sessionJob = "job-test" }
$provider = Get-SquadExecutionProvider -Config $config

$requestOne = New-SquadExecutionRequest -Repository "owner/repo" -Ref "main" -Mode "prompt" -SessionName "session-one" -Prompt "build it" -SubSquad "eng" -RunCopilotSmoke $false -PushChanges $true -OutputBranch "squad/session-one" -NoWait $false
$resultOne = Start-SquadExecution -Provider $provider -Request $requestOne
if ($resultOne.Id -eq $resultOne.Execution) { throw "opaque execution IDs must not equal execution names" }
if ($resultOne.Id -match "fake-exec") { throw "opaque execution IDs must not leak raw execution names" }
$statusOne = Get-SquadExecutionStatus -Provider $provider -Id $resultOne.Id
if ($statusOne.Status -ne "Running") { throw "expected first fake execution to start Running" }
$logsOne = Get-SquadExecutionLogs -Provider $provider -Id $resultOne.Id -Tail 10
if (-not $logsOne.Contains("created execution")) { throw "expected create log entry" }
$cancelResult = Stop-SquadExecution -Provider $provider -Id $resultOne.Id -CancelOnly
if ($cancelResult.status -ne "cancelled") { throw "expected cancel result" }
$statusAfterCancel = Get-SquadExecutionStatus -Provider $provider -Id $resultOne.Id
if ($statusAfterCancel.Status -ne "Cancelled") { throw "expected execution status to remain Cancelled" }
$secondTerminate = Stop-SquadExecution -Provider $provider -Id $resultOne.Id
if ($secondTerminate.status -ne "already-stopped") { throw "expected terminate to be idempotent" }

$requestTwo = New-SquadExecutionRequest -Repository "owner/repo" -Ref "dev" -Mode "smoke" -SessionName "session-two" -Prompt "" -SubSquad "" -RunCopilotSmoke $false -PushChanges $false -OutputBranch "" -NoWait $true
$resultTwo = Start-SquadExecution -Provider $provider -Request $requestTwo
$statusTwo = Get-SquadExecutionStatus -Provider $provider -Id $resultTwo.Id
if ($statusTwo.Status -ne "Pending") { throw "expected second execution to start Pending" }
$waited = Wait-SquadExecution -Provider $provider -Id $resultTwo.Id -TimeoutSeconds 1 -PollSeconds 1
if ($waited.Status -ne "Running") { throw "expected fake wait to transition execution to Running" }

$executions = @(Get-SquadExecutions -Provider $provider -Limit 5)
if ($executions.Count -ne 2) { throw "expected two executions in fake provider state" }
if ($executions[0].Session -ne "session-two") { throw "expected newest execution first" }

$rawState = Get-Content $statePath -Raw
if (-not $rawState.Contains("OUTPUT_BRANCH=squad/session-one")) { throw "expected per-execution output branch override in fake state" }
if (-not $rawState.Contains("SQUAD_PROMPT=build it")) { throw "expected per-execution prompt override in fake state" }

Write-Output "provider contract tests passed"
