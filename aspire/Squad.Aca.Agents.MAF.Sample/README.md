# `squad-aca-maf-sample` — a runnable Agent Framework host

This is a real Microsoft Agent Framework host. It builds a generic host, calls
`AddSquadAcaAgent()`, resolves the base `AIAgent` from DI, invokes it, and prints
what came back — including the route the control plane chose, the execution
handle, the terminal status, and the elapsed time.

It exists because sprints 1 and 2 of [#33](https://github.com/swigerb/squad-on-aca/issues/33)
were entirely offline and faked. Everything about the adapter was asserted
against a scripted `ISquadAgent`. This is the project that made a Squad session
actually run on Azure through it.

## Five-line quickstart

The shape mirrors [`Squad.Agents.AI`](https://github.com/bradygaster/squad/blob/dev/src/Squad.Agents.AI/README.md)'s
own quickstart, so a host that already wires one Squad agent recognises this one:

```csharp
var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddSingleton<ISquadAgent>(_ => AcaSquadAgent.CreateDefault(new SquadAgentOptions()));
builder.Services.AddSquadAcaAgent(o => o.DefaultRepository = "octo/example");

using var host = builder.Build();
var squad = host.Services.GetRequiredService<AIAgent>();
var response = await squad.RunAsync("fix the flaky test");
Console.WriteLine(response.Text);
```

The base `AIAgent` is resolved deliberately, not `SquadAcaAIAgent`. A MAF
pipeline holds `AIAgent`; resolving the concrete type would prove the concrete
type works and say nothing about whether a pipeline that has never heard of Squad
can drive it.

## Run it

```powershell
dotnet run --project aspire/Squad.Aca.Agents.MAF.Sample -- `
  "Reply with a one-line summary of what this repository does. Change no files." `
  --repo owner/repo --ref my-branch --no-push
```

Every input comes from an argument or an environment variable; nothing is
hard-coded. Arguments win over environment variables, which is the precedence a
CI job (environment) and a human at a terminal (arguments) both expect.

| Argument | Environment variable | Default |
|---|---|---|
| *(first bare argument)* / `--prompt` | `SQUAD_ACA_SAMPLE_PROMPT` | *required* |
| `--repo` | `SQUAD_ACA_SAMPLE_REPOSITORY` | *required* |
| `--ref` | `SQUAD_ACA_SAMPLE_REF` | `main` |
| `--branch` | `SQUAD_ACA_SAMPLE_OUTPUT_BRANCH` | control plane default |
| `--session` | `SQUAD_ACA_SAMPLE_SESSION` | control plane mints one |
| `--sub-squad` | `SQUAD_ACA_SAMPLE_SUB_SQUAD` | none |
| `--no-push` | `SQUAD_ACA_SAMPLE_PUSH=false` | pushes |
| `--mode run-to-completion\|dispatch-only` | `SQUAD_ACA_SAMPLE_MODE` | `run-to-completion` |
| `--stream` | `SQUAD_ACA_SAMPLE_STREAM=true` | non-streaming |
| `--timeout-minutes` | `SQUAD_ACA_SAMPLE_TIMEOUT_MINUTES` | `90` |
| `--poll-seconds` | `SQUAD_ACA_SAMPLE_POLL_SECONDS` | `15` |
| `--cancel-after-seconds` | `SQUAD_ACA_SAMPLE_CANCEL_AFTER_SECONDS` | never |
| `--cli` | `SQUAD_ACA_CLI` | discovered by `SquadCliLocator` |
| `--working-directory` | `SQUAD_ACA_SAMPLE_WORKING_DIRECTORY` | current directory |
| `--quiet` | `SQUAD_ACA_SAMPLE_QUIET=true` | relays control-plane diagnostics |

There is deliberately no inferred repository. Guessing one is how a sample
dispatches work to the wrong repository the first time it is run unmodified.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | The session reached a terminal state (or was dispatched, under `dispatch-only`) |
| `1` | A Squad agent error |
| `2` | Usage error |
| `3` | `SquadRouteFailedClosedException` — capability routing refused; nothing was started |
| `4` | `SquadAgentRunTimeoutException` |
| `5` | Cancelled; the adapter issued a stop before rethrowing |

Distinct codes matter here: "the run failed" and "the repository's required
capabilities cannot be met on any approved plane" are different operational
situations, and a script that collapses them into `1` cannot tell them apart.

### `--cancel-after-seconds` is not a toy

"Cancellation stops the ACA session rather than orphaning it" is the one adapter
claim an offline test can only assert against a fake. This flag makes a genuinely
cancelled *live* run producible, so the claim can be checked against Azure —
which is where a broken version shows up as a session that is still billing.

## Prerequisites

- .NET SDK 9.0+ (validated with the 10.0 SDK targeting `net9.0`).
- `pwsh` on `PATH`, and this repository's `scripts/squad-aca.ps1` reachable
  (the locator walks upwards from the working directory; `--cli` overrides it).
- `squad-aca init` already run — `az` and `gh` authenticated, and
  `~/.squad-on-aca/config.json` present.

## No credential passes through this host

It reads none. `gh` supplies GitHub authentication and `az` supplies Azure
authentication, both to the control plane, so this process never sees a token,
never puts one in an argument vector, and cannot leak one.

The one thing it *does* relay is the control plane's stderr, which is not under
its control — a worker log line or an `az` diagnostic can quote a token that was
never ours. So every line it writes goes through `SecretRedactor` first, at the
print site, because that is the only place redaction can be applied to text whose
creation we never saw. `scripts/validate.ps1` asserts that no `Console` write in
this project skips it.

## See also

- [`docs/maf-adapter.md`](../../docs/maf-adapter.md) — the adapter, the long-run
  decision, and the polling schedule.
- [`docs/agent-contract.md`](../../docs/agent-contract.md) — the `--json`
  documents underneath it.
- [`docs/e2e-results.md`](../../docs/e2e-results.md) — the live evidence this
  host produced.
