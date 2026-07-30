# The machine-readable agent contract (`--json`)

`squad-aca` speaks two languages. Everything it has printed until now is for a
human at a terminal, and 22 golden captures
([`scripts/tests/golden/cli`](../scripts/tests/golden/cli)) pin that output
byte-for-byte precisely so an unintended change to it fails a build.

That property is exactly what makes it the wrong thing for a program to read.
If a .NET caller parsed the human output:

- every deliberate wording improvement would become a breaking API change, and
- every accidental one would become a silent parse failure at dispatch time.

So `run`, `status` and `sessions` accept an **opt-in `--json`** flag that emits a
single JSON document on stdout instead. It is strictly additive: no existing
invocation changes, and all 22 original goldens remain byte-identical. Four new
golden cases (`23`–`26`) pin the JSON documents.

## Rules the JSON obeys

1. **Stable key order, and every key is always present.** A field that does not
   apply is `null`, never absent. A consumer that has to distinguish "missing"
   from "null" is a consumer that will eventually get it wrong.
2. **Never a token.** Not the GitHub token, not the OTLP headers, not an
   `az` credential. The control plane's `secretref:` indirection names secrets
   without carrying them, and only the reference ever appears.
3. **Never a raw manifest value.** The document reports the *resolved* route,
   reason and sandbox class — the resolver's own vocabulary — not the repository's
   declared capability requirements.
4. **Exactly one document on stdout.** Under `--json`, all pass-through output
   (`git`, `az`, provider notes) is redirected to **stderr**. It is moved, never
   dropped: PR #9 was closed for swallowing `az containerapp job stop` output.

The vocabulary is borrowed wholesale from the existing control plane —
`Resolve-SquadExecutionRoute` and `New-SquadDispatchResponse` in
[`scripts/lib/squad-aca-provider.ps1`](../scripts/lib/squad-aca-provider.ps1) —
rather than invented in parallel.

> `--json` is intentionally **not** listed in `squad-aca help`. The help text is
> pinned byte-for-byte by golden `01-help.txt`, and the hard constraint on this
> sprint was that all 22 existing goldens stay identical. The flag is documented
> here instead. Surfacing it in help is a deliberate, reviewable golden update
> for a later change.

## `squad-aca run --json` → `squad-aca/run@1`

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
| `outputBranch` | string \| null | Branch the session pushes to, when it pushes. |
| `route` | `aca-job` \| `sandbox` \| `fail-closed` | Where capability routing sent this session. |
| `routeReason` | string | Why. Always present, including for ordinary outcomes. |
| `executionMode` | `aca-job` \| `sandbox` | The substrate that owns the execution. |
| `executionHandle` | string \| null | Opaque handle, when the substrate minted one at dispatch. |
| `statusPollRef` | string \| null | **The value to pass back** to `sessions --session` and `stop`. |
| `sandboxClass` | string \| null | Approved sandbox class id; `null` on the Jobs plane. |
| `fallbackReason` | string \| null | Why the route *deviated*; `null` for ordinary outcomes. |
| `dispatched` | bool | Whether an execution was actually started. |
| `status` | string | Substrate status at dispatch time. |

### Why `statusPollRef` exists alongside `executionHandle`

ACA names a job execution **asynchronously**: at the moment
`az containerapp job start` returns, there is no execution name to mint a handle
from, so `executionHandle` is `null` for a Jobs dispatch. A sandbox dispatch,
which creates a named resource synchronously, does have one.

`statusPollRef` papers over that difference: it is the handle when there is one
and the session id when there is not. It is the single value a caller stores and
hands back verbatim. Callers must not parse it.

### Why `routeReason` and `fallbackReason` are separate

`routeReason` always reports the resolver's decision. `fallbackReason` is
populated **only** when that decision deviated from what was asked for — the
three ordinary reasons (`no-capability-resolution`,
`capability-resolution-aca-job`, `approved-sandbox-class`) map to `null`. A
caller that alerts on "did anything unexpected happen?" reads `fallbackReason`;
a caller that logs "what happened?" reads `routeReason`.

### Fail-closed

When capability routing fails closed, `run --json` emits the document **and**
exits `1`:

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

Both halves matter. The exit code alone tells a caller that the dispatch failed
but not why; the document alone could be mistaken for success by a caller that
only checks the process. Nothing was started.

## `squad-aca sessions --json` → `squad-aca/sessions@1`

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

Both plane shapes — ACA Job executions and sandboxes — project into this one key
set, so a consumer never branches on substrate to read a field.

`sessions --json --session <handle-or-name>` scopes the array to one session.
When the argument is a **handle**, the handle is decoded directly and the route
is **not** re-resolved: a handle names the provider that minted it, and
re-resolving would answer today's routing question about yesterday's session — a
session that ran on the sandbox plane must still be readable after the sandbox
feature flag is turned off.

`--session` without `--json` is a usage error, not a silently-ignored flag.

## `squad-aca status --json` → `squad-aca/status@1`

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

Each collection has a paired `…Error` field so a consumer can tell **"there is
nothing"** from **"we could not ask"**. An empty array with a null error means
the resource genuinely has no executions; an empty array with an error string
means the query failed. Collapsing those two into one empty array is how a
monitoring integration learns to report an outage as "all quiet".

## Consuming it from .NET

[`aspire/Squad.Aca.Agents`](../aspire/Squad.Aca.Agents) implements
`ISquadAgent` over this contract. It parses **strictly** — empty output,
malformed JSON, an unexpected schema, an unknown route or execution mode, and a
missing `dispatched` flag all throw:

| Situation | Type |
| --- | --- |
| Output this library cannot interpret | `SquadContractException` |
| Control plane ran but did not dispatch | `SquadDispatchFailedException` (carries `ExitCode`) |
| Capability routing failed closed | `SquadRouteFailedClosedException` (carries `Reason`, `SandboxClass`) |

A half-populated result that says `Dispatched = true` because a field happened to
be absent is worse than an exception, because a caller acts on it.

## Compatibility

The `schema` value carries the version. A breaking change to any document mints a
new one (`…@2`); consumers reject an unrecognised schema rather than
best-effort-parsing it. Adding a key is not breaking, because the rules above
already require consumers to tolerate keys they do not know.
