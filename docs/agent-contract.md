# Machine-readable agent contract (`--json`)

`squad-aca` emits human-readable terminal output by default. `run`, `status`, and `sessions` also accept `--json` for callers that need a stable wire contract.

The JSON mode is opt-in and additive. Existing invocations keep their human output.

## Rules

1. Stable key order. Every key is always present. A field that does not apply is `null`.
2. Tokens are never emitted. Secret references may appear as `secretref:` names.
3. Raw manifest free-form values are never emitted. The document reports resolved route vocabulary.
4. Exactly one JSON document is written to stdout. Pass-through output from `git`, `az`, and provider notes is redirected to stderr.

The vocabulary comes from `Resolve-SquadExecutionRoute` and `New-SquadDispatchResponse` in [`scripts/lib/squad-aca-provider.ps1`](../scripts/lib/squad-aca-provider.ps1).

## `squad-aca run --json` to `squad-aca/run@1`

```json
{
  "schema": "squad-aca/run@1",
  "sessionName": "fixedjson",
  "repository": "octo/demo",
  "ref": "main",
  "outputBranch": "squad/fixedjson",
  "route": "aca-job",
  "routeReason": "capability-resolution-aca-job",
  "executionMode": "aca-job",
  "executionHandle": null,
  "statusPollRef": "fixedjson",
  "sandboxClass": null,
  "fallbackReason": null,
  "dispatched": true,
  "status": "Requested"
}
```

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | string | Contract id. Consumers must reject anything else. |
| `sessionName` | string | Resolved session / pod id. |
| `repository` | string | `owner/repo` the session operates on. |
| `ref` | string | Git ref the session was started from. |
| `outputBranch` | string or null | Branch the session pushes to, when it pushes. |
| `route` | `aca-job`, `sandbox`, or `fail-closed` | Where capability routing sent this session. |
| `routeReason` | string | Resolver decision code. Always present. |
| `executionMode` | `aca-job` or `sandbox` | The substrate that owns the execution. |
| `executionHandle` | string or null | Opaque handle, when the substrate minted one at dispatch. |
| `statusPollRef` | string or null | The value to pass back to `sessions --session` and `stop`. |
| `sandboxClass` | string or null | Approved sandbox class id; `null` on the Jobs plane. |
| `fallbackReason` | string or null | Non-`null` when the route deviated. |
| `dispatched` | bool | Whether an execution was started. |
| `status` | string | Substrate status at dispatch time. |

### `statusPollRef`

ACA names a job execution asynchronously, so `executionHandle` is `null` for a fresh Jobs dispatch. A sandbox dispatch creates a named resource synchronously and has a handle. Store `statusPollRef` and pass it back verbatim.

### `routeReason` and `fallbackReason`

`routeReason` always reports the resolver's decision. `fallbackReason` is populated only when the route deviated. Ordinary reasons such as `no-capability-resolution`, `capability-resolution-aca-job`, and `approved-sandbox-class` map to `null`.

### Fail-closed result

When capability routing fails closed, `run --json` emits the document and exits `1`:

```json
{
  "schema": "squad-aca/run@1",
  "route": "fail-closed",
  "routeReason": "sandbox-class-not-approved",
  "fallbackReason": "sandbox-class-not-approved",
  "sandboxClass": "gpu-unrestricted",
  "statusPollRef": null,
  "dispatched": false,
  "status": "FailedClosed"
}
```

No execution is started.

## `squad-aca sessions --json` to `squad-aca/sessions@1`

```json
{
  "schema": "squad-aca/sessions@1",
  "sessions": [
    {
      "sessionName": "stub-session",
      "executionName": "caj-squad-aca-session-stub01",
      "executionHandle": "sqx1.…",
      "executionMode": "aca-job",
      "route": "aca-job",
      "status": "Running",
      "sandboxClass": null,
      "repository": "octo/demo",
      "branch": "squad/stub-session",
      "mode": "prompt",
      "source": "local-cli",
      "startedAt": "2026-01-02T03:04:05",
      "endedAt": null,
      "phase": null,
      "exitCode": null,
      "inconclusive": null
    }
  ]
}
```

ACA Job executions and sandboxes project into the same key set. `sessions --json --session <handle-or-name>` scopes the array to one session. A handle names the provider that minted it; lifecycle operations do not re-resolve routing.

`--session` without `--json` is a usage error.

## `squad-aca status --json` to `squad-aca/status@1`

```json
{
  "schema": "squad-aca/status@1",
  "resourceGroup": "rg-squad-stub",
  "sessionJob": "caj-squad-aca-session",
  "ralphJob": "caj-squad-aca-ralph",
  "watchApp": "ca-squad-aca-watch",
  "aspireApp": "ca-squad-aca-aspire",
  "dashboardUrl": null,
  "containerApps": [],
  "containerAppsError": null,
  "sessionExecutions": [],
  "sessionExecutionsError": null,
  "ralphExecutions": [],
  "ralphExecutionsError": null
}
```

Each collection has a paired `…Error` field. An empty array with a null error means there are no rows. An empty array with an error string means the query failed.

## Consuming it from .NET

[`aspire/Squad.Aca.Agents`](../aspire/Squad.Aca.Agents) implements `ISquadAgent` over this contract. It parses strictly.

| Situation | Type |
| --- | --- |
| Output this library cannot interpret | `SquadContractException` |
| Control plane ran but did not dispatch | `SquadDispatchFailedException` (carries `ExitCode`) |
| Capability routing failed closed | `SquadRouteFailedClosedException` (carries `Reason`, `SandboxClass`) |

## Compatibility

The `schema` value carries the version. A breaking change mints a new schema value such as `…@2`. Adding a key is not breaking because consumers must tolerate unknown keys.
