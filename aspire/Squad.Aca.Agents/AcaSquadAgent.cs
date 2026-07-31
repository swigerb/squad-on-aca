using System.Text.Json;

namespace Squad.Aca.Agents;

/// <summary>
/// <see cref="ISquadAgent"/> implemented over the existing <c>squad-aca</c>
/// control plane.
/// </summary>
/// <remarks>
/// <para>
/// This talks to the control plane through its <c>--json</c> mode, NOT by parsing
/// its human-readable output. That output is pinned byte-for-byte by golden
/// captures whose purpose is to catch unintended UX changes; making it
/// load-bearing for a machine contract would mean every deliberate wording
/// change became a breaking API change, and every accidental one became a silent
/// parse failure.
/// </para>
/// <para>
/// The parsing here is strict on purpose. Every failure mode — empty output,
/// malformed JSON, a wrong schema, an unknown route, a missing field — throws.
/// The failure this design is guarding against is a half-populated result that
/// says <c>Dispatched = true</c> because the field was simply absent.
/// </para>
/// </remarks>
public sealed class AcaSquadAgent : ISquadAgent
{
    private const string RunSchema = "squad-aca/run@1";
    private const string SessionsSchema = "squad-aca/sessions@1";

    private readonly ISquadCliInvoker _invoker;
    private readonly Action<string>? _diagnostics;

    /// <summary>Creates the agent over a given invoker.</summary>
    /// <param name="invoker">The control-plane invoker; fake it in tests.</param>
    /// <param name="options">Optional options, used only for the diagnostic sink.</param>
    public AcaSquadAgent(ISquadCliInvoker invoker, SquadAgentOptions? options = null)
    {
        _invoker = invoker ?? throw new ArgumentNullException(nameof(invoker));
        _diagnostics = options?.DiagnosticSink;
    }

    /// <summary>Creates an agent backed by a real <c>pwsh</c> process.</summary>
    /// <param name="options">Invocation options.</param>
    /// <returns>An agent wired to <see cref="SquadCliProcessInvoker"/>.</returns>
    public static AcaSquadAgent CreateDefault(SquadAgentOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        return new AcaSquadAgent(new SquadCliProcessInvoker(options), options);
    }

    /// <inheritdoc/>
    public async Task<SquadSessionResult> RunSessionAsync(
        SquadSessionRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (string.IsNullOrWhiteSpace(request.Repository))
        {
            throw new ArgumentException("Repository is required.", nameof(request));
        }

        if (string.IsNullOrWhiteSpace(request.Prompt))
        {
            throw new ArgumentException("Prompt is required.", nameof(request));
        }

        var arguments = new List<string> { "run", request.Prompt, "--json", "--repo", request.Repository };
        if (!string.IsNullOrWhiteSpace(request.SessionName))
        {
            arguments.Add("--name");
            arguments.Add(request.SessionName);
        }

        if (!string.IsNullOrWhiteSpace(request.Ref))
        {
            arguments.Add("--ref");
            arguments.Add(request.Ref);
        }

        if (!string.IsNullOrWhiteSpace(request.OutputBranch))
        {
            arguments.Add("--branch");
            arguments.Add(request.OutputBranch);
        }

        if (!request.PushChanges)
        {
            arguments.Add("--no-push");
        }

        if (!string.IsNullOrWhiteSpace(request.SubSquad))
        {
            arguments.Add("--sub-squad");
            arguments.Add(request.SubSquad);
        }

        SquadCliResult cli = await InvokeAsync(arguments, cancellationToken).ConfigureAwait(false);
        JsonElement document = ParseDocument(cli, "run");
        RequireSchema(document, RunSchema, cli);

        string route = RequireString(document, "route", cli);

        // Route classification comes BEFORE the exit-code check on purpose. A
        // fail-closed run exits non-zero, and if the exit code were handled first
        // the caller would get "the CLI failed" and lose the reason the capability
        // resolver worked out. The reason is the actionable part.
        if (string.Equals(route, "fail-closed", StringComparison.Ordinal))
        {
            string? reason = OptionalString(document, "fallbackReason")
                ?? OptionalString(document, "routeReason");
            throw new SquadRouteFailedClosedException(
                $"Capability routing failed closed for session '{OptionalString(document, "sessionName") ?? "(unnamed)"}'" +
                $"; nothing was dispatched. Reason: {reason ?? "(not reported)"}. " +
                $"Control plane stderr: {Summarize(cli.StandardError)}",
                reason,
                OptionalString(document, "sandboxClass"),
                cli.ExitCode);
        }

        if (cli.ExitCode != 0)
        {
            throw new SquadDispatchFailedException(
                $"squad-aca run exited with code {cli.ExitCode}. " +
                $"Control plane stderr: {Summarize(cli.StandardError)}",
                cli.ExitCode);
        }

        bool dispatched = RequireBoolean(document, "dispatched", cli);
        if (!dispatched)
        {
            throw new SquadDispatchFailedException(
                $"squad-aca run did not dispatch session " +
                $"'{OptionalString(document, "sessionName") ?? "(unnamed)"}'. " +
                $"Status: {OptionalString(document, "status") ?? "(none)"}. " +
                $"Reason: {OptionalString(document, "fallbackReason") ?? "(not reported)"}.",
                cli.ExitCode);
        }

        // ACA names a job execution asynchronously, so a Jobs dispatch has no
        // handle yet -- statusPollRef carries the session id instead. Either way
        // it is the value the caller hands back to status and cancel, so that is
        // what becomes the handle. A dispatched session with neither is a broken
        // contract, not a session you simply cannot poll.
        string? pollRef = OptionalString(document, "statusPollRef")
            ?? OptionalString(document, "executionHandle");
        if (string.IsNullOrWhiteSpace(pollRef))
        {
            throw new SquadContractException(
                $"squad-aca run reported a dispatched session with no statusPollRef or executionHandle. " +
                $"Payload: {Summarize(cli.StandardOutput)}");
        }

        return new SquadSessionResult(
            SessionName: RequireString(document, "sessionName", cli),
            Dispatched: true,
            Route: ParseRoute(route, cli),
            ExecutionMode: ParseMode(RequireString(document, "executionMode", cli), cli),
            Handle: new SquadExecutionHandle(pollRef),
            SandboxClass: Clean(OptionalString(document, "sandboxClass")),
            FallbackReason: Clean(OptionalString(document, "fallbackReason")),
            Status: SecretRedactor.Redact(RequireString(document, "status", cli)),
            Detail: SecretRedactor.Redact(BuildDetail(document)));
    }

    /// <inheritdoc/>
    public async Task<SquadSessionStatus> GetSessionStatusAsync(
        SquadExecutionHandle handle,
        CancellationToken cancellationToken = default)
    {
        string value = RequireHandle(handle);

        // Addressed by handle. There is deliberately no --repo and no route
        // resolution here: re-resolving would answer today's routing question
        // about yesterday's session, and a session that ran on the sandbox plane
        // must still be read on the sandbox plane after the feature flag is
        // turned off. The handle names its own provider.
        SquadCliResult cli = await InvokeAsync(
            ["sessions", "--json", "--session", value],
            cancellationToken).ConfigureAwait(false);

        if (cli.ExitCode != 0)
        {
            throw new SquadDispatchFailedException(
                $"squad-aca sessions exited with code {cli.ExitCode}. " +
                $"Control plane stderr: {Summarize(cli.StandardError)}",
                cli.ExitCode);
        }

        JsonElement document = ParseDocument(cli, "sessions");
        RequireSchema(document, SessionsSchema, cli);

        if (!document.TryGetProperty("sessions", out JsonElement sessions)
            || sessions.ValueKind != JsonValueKind.Array)
        {
            throw new SquadContractException(
                $"squad-aca sessions returned no 'sessions' array. Payload: {Summarize(cli.StandardOutput)}");
        }

        if (sessions.GetArrayLength() == 0)
        {
            throw new SquadContractException(
                "squad-aca sessions returned no execution for the supplied handle.");
        }

        JsonElement session = sessions[0];
        string? sessionHandle = OptionalString(session, "executionHandle");

        return new SquadSessionStatus(
            SessionName: RequireString(session, "sessionName", cli),
            ExecutionName: RequireString(session, "executionName", cli),
            Handle: new SquadExecutionHandle(sessionHandle ?? value),
            ExecutionMode: ParseMode(RequireString(session, "executionMode", cli), cli),
            Route: RequireString(session, "route", cli),
            Status: RequireString(session, "status", cli),
            SandboxClass: OptionalString(session, "sandboxClass"),
            Repository: OptionalString(session, "repository"),
            Branch: OptionalString(session, "branch"),
            Phase: OptionalString(session, "phase"),
            ExitCode: OptionalInt(session, "exitCode"));
    }

    /// <inheritdoc/>
    public async Task CancelSessionAsync(
        SquadExecutionHandle handle,
        CancellationToken cancellationToken = default)
    {
        string value = RequireHandle(handle);

        // Same rule as status: the handle selects the substrate. `stop` cancels;
        // it does not terminate, so the substrate's own result and output survive.
        SquadCliResult cli = await InvokeAsync(["stop", value], cancellationToken).ConfigureAwait(false);

        if (cli.ExitCode != 0)
        {
            throw new SquadDispatchFailedException(
                $"squad-aca stop exited with code {cli.ExitCode}. " +
                $"Control plane stderr: {Summarize(cli.StandardError)}",
                cli.ExitCode);
        }
    }

    private async Task<SquadCliResult> InvokeAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        SquadCliResult cli = await _invoker.InvokeAsync(arguments, cancellationToken).ConfigureAwait(false);
        if (cli is null)
        {
            throw new SquadContractException("The squad-aca invoker returned no result.");
        }

        if (_diagnostics is not null)
        {
            // The prompt is an argument, so the argument list is not logged. Only
            // the verb and the exit code are, and both go through redaction.
            _diagnostics(SecretRedactor.Redact(
                $"squad-aca {arguments.FirstOrDefault() ?? "(no verb)"} exited {cli.ExitCode}"));
            if (!string.IsNullOrWhiteSpace(cli.StandardError))
            {
                _diagnostics(SecretRedactor.Redact(cli.StandardError.Trim()));
            }
        }

        return cli;
    }

    private static string RequireHandle(SquadExecutionHandle handle)
    {
        ArgumentNullException.ThrowIfNull(handle);
        if (string.IsNullOrWhiteSpace(handle.Value))
        {
            throw new ArgumentException("Execution handle is empty.", nameof(handle));
        }

        return handle.Value;
    }

    private static JsonElement ParseDocument(SquadCliResult cli, string verb)
    {
        if (string.IsNullOrWhiteSpace(cli.StandardOutput))
        {
            // Empty stdout is never a valid answer under --json. If the process
            // also failed, say so with the exit code; otherwise it is a contract
            // breach, because a zero exit promised a document.
            if (cli.ExitCode != 0)
            {
                throw new SquadDispatchFailedException(
                    $"squad-aca {verb} exited with code {cli.ExitCode} and produced no output. " +
                    $"Control plane stderr: {Summarize(cli.StandardError)}",
                    cli.ExitCode);
            }

            throw new SquadContractException(
                $"squad-aca {verb} --json produced no output. " +
                $"Control plane stderr: {Summarize(cli.StandardError)}");
        }

        try
        {
            using var parsed = JsonDocument.Parse(cli.StandardOutput);
            JsonElement root = parsed.RootElement.Clone();
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new SquadContractException(
                    $"squad-aca {verb} --json produced a {root.ValueKind} where an object was expected. " +
                    $"Payload: {Summarize(cli.StandardOutput)}");
            }

            return root;
        }
        catch (JsonException ex)
        {
            if (cli.ExitCode != 0)
            {
                throw new SquadDispatchFailedException(
                    $"squad-aca {verb} exited with code {cli.ExitCode} and produced unparseable output. " +
                    $"Payload: {Summarize(cli.StandardOutput)}",
                    cli.ExitCode);
            }

            throw new SquadContractException(
                $"squad-aca {verb} --json produced unparseable output. Payload: {Summarize(cli.StandardOutput)}",
                ex);
        }
    }

    private static void RequireSchema(JsonElement document, string expected, SquadCliResult cli)
    {
        string? schema = OptionalString(document, "schema");
        if (!string.Equals(schema, expected, StringComparison.Ordinal))
        {
            throw new SquadContractException(
                $"Expected schema '{expected}' but got '{schema ?? "(none)"}'. " +
                $"Payload: {Summarize(cli.StandardOutput)}");
        }
    }

    private static SquadExecutionRoute ParseRoute(string route, SquadCliResult cli) => route switch
    {
        "aca-job" => SquadExecutionRoute.AcaJob,
        "sandbox" => SquadExecutionRoute.Sandbox,
        "fail-closed" => SquadExecutionRoute.FailedClosed,
        _ => throw new SquadContractException(
            $"Unknown execution route '{route}'. Payload: {Summarize(cli.StandardOutput)}"),
    };

    private static SquadExecutionMode ParseMode(string mode, SquadCliResult cli) => mode switch
    {
        "aca-job" => SquadExecutionMode.AcaJob,
        "sandbox" => SquadExecutionMode.Sandbox,
        _ => throw new SquadContractException(
            $"Unknown execution mode '{mode}'. Payload: {Summarize(cli.StandardOutput)}"),
    };

    private static string RequireString(JsonElement document, string name, SquadCliResult cli)
    {
        string? value = OptionalString(document, name);
        if (string.IsNullOrEmpty(value))
        {
            throw new SquadContractException(
                $"Required field '{name}' was missing or null. Payload: {Summarize(cli.StandardOutput)}");
        }

        return value;
    }

    private static bool RequireBoolean(JsonElement document, string name, SquadCliResult cli)
    {
        if (!document.TryGetProperty(name, out JsonElement value)
            || (value.ValueKind != JsonValueKind.True && value.ValueKind != JsonValueKind.False))
        {
            throw new SquadContractException(
                $"Required boolean field '{name}' was missing or not a boolean. " +
                $"Payload: {Summarize(cli.StandardOutput)}");
        }

        return value.GetBoolean();
    }

    private static string? OptionalString(JsonElement document, string name)
    {
        if (!document.TryGetProperty(name, out JsonElement value) || value.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        string? text = value.GetString();
        return string.IsNullOrEmpty(text) ? null : text;
    }

    private static int? OptionalInt(JsonElement document, string name)
    {
        if (!document.TryGetProperty(name, out JsonElement value)
            || value.ValueKind != JsonValueKind.Number
            || !value.TryGetInt32(out int number))
        {
            return null;
        }

        return number;
    }

    private static string BuildDetail(JsonElement document)
    {
        string route = OptionalString(document, "route") ?? "unknown";
        string status = OptionalString(document, "status") ?? "unknown";
        string? sandboxClass = OptionalString(document, "sandboxClass");
        string suffix = sandboxClass is null ? string.Empty : $" (sandbox class {sandboxClass})";
        return $"Dispatched on '{route}' with status '{status}'{suffix}.";
    }

    private static string Summarize(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return "(none)";
        }

        string redacted = SecretRedactor.Redact(text).Trim();
        const int limit = 600;
        return redacted.Length <= limit ? redacted : redacted[..limit] + "…";
    }

    // Descriptive fields carry text the control plane echoed from somewhere else,
    // so they are redacted before a caller ever sees them. IDENTITY fields --
    // sessionName, executionName, the handle -- deliberately are not: they have to
    // round-trip to `sessions --session` and `stop` byte-for-byte, and a redacted
    // identifier addresses nothing. That asymmetry is the reason the split exists.
    private static string? Clean(string? value) => value is null ? null : SecretRedactor.Redact(value);
}
