using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;

namespace Squad.Aca.Agents.MAF;

/// <summary>
/// Exposes <see cref="ISquadAgent"/> — Squad on Azure Container Apps — as a
/// Microsoft Agent Framework <see cref="AIAgent"/>.
/// </summary>
/// <remarks>
/// <para>
/// <b>The long-run problem.</b> <c>RunAsync</c> is request/response and a Squad
/// session runs 10–60 minutes. This adapter reconciles the two with
/// <see cref="SquadLongRunMode"/>, and the DEFAULT is
/// <see cref="SquadLongRunMode.RunToCompletion"/>: dispatch, poll with backoff,
/// and return the finished result, bounded by
/// <see cref="SquadAcaAgentOptions.RunTimeout"/>.
/// </para>
/// <para>
/// The default is what it is because of what a MAF caller does with the answer.
/// In a workflow the response text is handed to the next node, and a dispatch
/// receipt handed to that node is not a smaller answer — it is a wrong one, read
/// as though it were the work product with nothing in the type system objecting.
/// Fire-and-forget is correct only when the caller asked for it, and MAF already
/// provides two explicit ways to ask: set
/// <c>AgentRunOptions.AllowBackgroundResponses = true</c>, or set
/// <see cref="SquadAcaAgentRunOptions.LongRunMode"/> to
/// <see cref="SquadLongRunMode.DispatchOnly"/>. Both return immediately with the
/// handle on <c>AgentResponse.ContinuationToken</c>, and passing that token back
/// on <c>AgentRunOptions.ContinuationToken</c> polls once without blocking. That
/// is MAF's own background-response protocol, not a Squad invention.
/// </para>
/// <para>
/// <b>Cancellation stops the session.</b> Cancelling the
/// <see cref="CancellationToken"/> mid-poll issues
/// <see cref="ISquadAgent.CancelSessionAsync"/> for the handle and only then
/// rethrows. That stop deliberately runs on a FRESH token with its own budget:
/// forwarding the caller's already-cancelled token would abort the stop on its
/// first await and leave a billed ACA session running with nobody watching it,
/// which is precisely the orphan the cancellation path exists to prevent.
/// </para>
/// <para>
/// <b>Fail-closed survives.</b> <see cref="SquadRouteFailedClosedException"/> is
/// never caught, wrapped or flattened into a failed <c>AgentResponse</c>. The
/// resolver's reason is the actionable part of that refusal, and a caller that
/// receives a generic "the agent failed" has lost it.
/// </para>
/// </remarks>
public sealed class SquadAcaAIAgent : AIAgent
{
    // The control plane's own vocabulary (SquadExecutionStates in
    // scripts/lib/squad-aca-provider.ps1). "Unknown" is deliberately absent: it
    // means the substrate could not tell us, not that the session finished, and
    // treating it as terminal would report an unfinished session as complete.
    // The run timeout is what bounds an execution stuck reporting it.
    private static readonly string[] TerminalStates = ["Succeeded", "Failed", "TimedOut", "Cancelled"];

    private readonly ISquadAgent _inner;
    private readonly SquadAcaAgentOptions _options;
    private readonly ISquadPollingClock _clock;
    private readonly string _id;

    /// <summary>Creates the adapter over an <see cref="ISquadAgent"/>.</summary>
    /// <param name="inner">The Squad-on-ACA agent to delegate to.</param>
    /// <param name="options">Adapter options; defaults are used when null.</param>
    public SquadAcaAIAgent(ISquadAgent inner, SquadAcaAgentOptions? options = null)
    {
        _inner = inner ?? throw new ArgumentNullException(nameof(inner));
        _options = options ?? new SquadAcaAgentOptions();
        _options.Validate();
        _clock = _options.PollingClock ?? SystemPollingClock.Instance;
        _id = string.IsNullOrWhiteSpace(_options.Id) ? Guid.NewGuid().ToString("N") : _options.Id;
    }

    /// <inheritdoc/>
    protected override string IdCore => _id;

    /// <inheritdoc/>
    public override string? Name => _options.Name;

    /// <inheritdoc/>
    public override string? Description => _options.Description;

    /// <summary>The <see cref="ISquadAgent"/> this adapter delegates to.</summary>
    public ISquadAgent InnerAgent => _inner;

    /// <inheritdoc/>
    public override object? GetService(Type serviceType, object? serviceKey = null)
    {
        ArgumentNullException.ThrowIfNull(serviceType);
        if (serviceKey is null && serviceType.IsInstanceOfType(_inner))
        {
            return _inner;
        }

        return base.GetService(serviceType, serviceKey);
    }

    /// <inheritdoc/>
    protected override ValueTask<AgentSession> CreateSessionCoreAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return new ValueTask<AgentSession>(new SquadAcaAgentSession());
    }

    /// <inheritdoc/>
    protected override ValueTask<JsonElement> SerializeSessionCoreAsync(
        AgentSession session,
        JsonSerializerOptions? jsonSerializerOptions = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        cancellationToken.ThrowIfCancellationRequested();
        return new ValueTask<JsonElement>(session.StateBag.Serialize());
    }

    /// <inheritdoc/>
    protected override ValueTask<AgentSession> DeserializeSessionCoreAsync(
        JsonElement serializedSession,
        JsonSerializerOptions? jsonSerializerOptions = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return new ValueTask<AgentSession>(
            new SquadAcaAgentSession(AgentSessionStateBag.Deserialize(serializedSession)));
    }

    /// <inheritdoc/>
    protected override async Task<AgentResponse> RunCoreAsync(
        IEnumerable<ChatMessage> messages,
        AgentSession? session = null,
        AgentRunOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(messages);

        ResponseContinuationToken? continuation = SquadBackgroundResponse.GetContinuationToken(options);
        if (continuation is not null)
        {
            return await ResumeAsync(continuation, cancellationToken).ConfigureAwait(false);
        }

        SquadRunEvent? last = null;
        await foreach (SquadRunEvent evt in ExecuteAsync(messages, session, options, cancellationToken)
            .ConfigureAwait(false))
        {
            last = evt;
        }

        // ExecuteAsync always yields at least the dispatch event before it can
        // complete normally; every other path throws.
        return BuildResponse(last!);
    }

    /// <inheritdoc/>
    protected override async IAsyncEnumerable<AgentResponseUpdate> RunCoreStreamingAsync(
        IEnumerable<ChatMessage> messages,
        AgentSession? session = null,
        AgentRunOptions? options = null,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(messages);

        // Streaming here is NOT a final string cut into pieces. Squad produces no
        // token stream to relay -- the work happens inside a container on another
        // machine -- so what is streamed is the only thing that genuinely arrives
        // incrementally: the dispatch, then each observed change of substrate
        // status, then the terminal outcome. A run whose status never changes
        // emits two updates, and that is an honest report rather than
        // manufactured progress.
        if (SquadBackgroundResponse.GetContinuationToken(options) is ResponseContinuationToken continuation)
        {
            AgentResponse resumed = await ResumeAsync(continuation, cancellationToken)
                .ConfigureAwait(false);
            foreach (AgentResponseUpdate update in resumed.ToAgentResponseUpdates())
            {
                yield return update;
            }

            yield break;
        }

        await foreach (SquadRunEvent evt in ExecuteAsync(messages, session, options, cancellationToken)
            .ConfigureAwait(false))
        {
            yield return BuildUpdate(evt);
        }
    }

    // -----------------------------------------------------------------------
    // The engine both RunCoreAsync and RunCoreStreamingAsync share.
    // -----------------------------------------------------------------------
    // Sharing it is the point: dispatch, backoff, the timeout and the
    // cancel-on-cancellation rule exist once, so a defect in any of them fails
    // both surfaces rather than only whichever one a test happened to call.
    private async IAsyncEnumerable<SquadRunEvent> ExecuteAsync(
        IEnumerable<ChatMessage> messages,
        AgentSession? session,
        AgentRunOptions? options,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var squadOptions = options as SquadAcaAgentRunOptions;
        SquadSessionRequest request = BuildRequest(messages, squadOptions);
        SquadLongRunMode mode = ResolveMode(squadOptions, options);
        TimeSpan timeout = squadOptions?.RunTimeout ?? _options.RunTimeout;
        if (timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(options), timeout, "RunTimeout must be positive.");
        }

        // No try/catch around this one on purpose. A cancelled dispatch has no
        // handle to stop, and SquadRouteFailedClosedException must leave here
        // exactly as it arrived.
        SquadSessionResult result = await _inner.RunSessionAsync(request, cancellationToken).ConfigureAwait(false);

        (session as SquadAcaAgentSession)?.Record(result.Handle, result.SessionName);
        Diagnose($"dispatched {result.SessionName} route={result.Route} mode={mode}");

        yield return SquadRunEvent.Dispatched(result, mode);

        if (mode == SquadLongRunMode.DispatchOnly)
        {
            yield break;
        }

        DateTimeOffset deadline = _clock.UtcNow + timeout;
        DateTimeOffset started = _clock.UtcNow;
        TimeSpan interval = _options.InitialPollInterval;
        string lastStatus = result.Status;

        while (true)
        {
            PollStep step;
            try
            {
                step = await PollAsync(result, lastStatus, deadline, started, interval, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                // The caller walked away. Stopping the session is the whole
                // difference between "cancelled" and "orphaned", and it happens
                // BEFORE the rethrow so a caller that awaits the throw knows the
                // stop was at least attempted.
                await StopQuietlyAsync(result.Handle).ConfigureAwait(false);
                throw;
            }

            interval = step.NextInterval;

            if (!string.Equals(step.Status.Status, lastStatus, StringComparison.Ordinal))
            {
                lastStatus = step.Status.Status;
                if (!step.Terminal)
                {
                    yield return SquadRunEvent.StatusChanged(result, step.Status, mode);
                }
            }

            if (step.Terminal)
            {
                yield return SquadRunEvent.Completed(result, step.Status, mode);
                yield break;
            }
        }
    }

    private async Task<PollStep> PollAsync(
        SquadSessionResult result,
        string lastStatus,
        DateTimeOffset deadline,
        DateTimeOffset started,
        TimeSpan interval,
        CancellationToken cancellationToken)
    {
        TimeSpan remaining = deadline - _clock.UtcNow;
        if (remaining <= TimeSpan.Zero)
        {
            throw await BuildTimeoutAsync(result, lastStatus, _clock.UtcNow - started).ConfigureAwait(false);
        }

        // Clamped so the last wait lands exactly on the deadline instead of
        // overshooting it by most of a poll interval.
        TimeSpan wait = interval < remaining ? interval : remaining;
        await _clock.DelayAsync(wait, cancellationToken).ConfigureAwait(false);

        SquadSessionStatus status = await _inner
            .GetSessionStatusAsync(result.Handle, cancellationToken)
            .ConfigureAwait(false);

        return new PollStep(status, IsTerminal(status.Status), NextInterval(interval));
    }

    private TimeSpan NextInterval(TimeSpan current)
    {
        double next = current.TotalMilliseconds * _options.PollBackoffFactor;
        double ceiling = _options.MaxPollInterval.TotalMilliseconds;
        return TimeSpan.FromMilliseconds(next < ceiling ? next : ceiling);
    }

    private static bool IsTerminal(string status) =>
        TerminalStates.Contains(status, StringComparer.OrdinalIgnoreCase);

    private async Task<SquadAgentRunTimeoutException> BuildTimeoutAsync(
        SquadSessionResult result,
        string lastStatus,
        TimeSpan elapsed)
    {
        bool cancelled = false;
        if (_options.CancelSessionOnTimeout)
        {
            cancelled = await StopQuietlyAsync(result.Handle).ConfigureAwait(false);
        }

        string tail = cancelled
            ? "The session was asked to stop."
            : _options.CancelSessionOnTimeout
                ? "The stop request did not succeed; the session may still be running."
                : "The session was left running.";

        return new SquadAgentRunTimeoutException(
            $"Squad session '{result.SessionName}' did not reach a terminal state within " +
            $"{elapsed.TotalMinutes.ToString("0.##", CultureInfo.InvariantCulture)} minute(s). " +
            // Not redacted here: the SquadAgentException base redacts every
            // message it is given, so a second call would be unreachable code
            // that no test could ever distinguish. The PROPERTY below is a
            // different matter -- nothing else redacts that one.
            $"Last observed status: {lastStatus}. {tail} " +
            $"Handle: {result.Handle.Value}",
            result.Handle,
            result.SessionName,
            elapsed,
            SecretRedactor.Redact(lastStatus),
            cancelled);
    }

    /// <summary>
    /// Best-effort stop, on its own token and its own budget.
    /// </summary>
    /// <remarks>
    /// It never propagates. The caller is already on the way out with a
    /// cancellation or a timeout, and replacing that with "the stop also failed"
    /// would hide the reason the run ended. The outcome is reported instead — as
    /// the return value, on the timeout exception, and to the diagnostic sink.
    /// </remarks>
    private async Task<bool> StopQuietlyAsync(SquadExecutionHandle handle)
    {
        using var stopTokenSource = new CancellationTokenSource(_options.StopTimeout);
        try
        {
            await _inner.CancelSessionAsync(handle, stopTokenSource.Token).ConfigureAwait(false);
            Diagnose($"stop requested for handle {handle.Value}");
            return true;
        }
        catch (Exception ex)
        {
            Diagnose($"stop request failed for handle {handle.Value}: {ex.Message}");
            return false;
        }
    }

    private async Task<AgentResponse> ResumeAsync(
        ResponseContinuationToken token,
        CancellationToken cancellationToken)
    {
        (string handleValue, string sessionName) = SquadContinuationToken.Read(token);
        var handle = new SquadExecutionHandle(handleValue);

        // A resume is a single non-blocking read on purpose. The caller already
        // holds a token and decides its own cadence; blocking here would turn the
        // poll they asked for back into the wait they opted out of.
        SquadSessionStatus status = await _inner
            .GetSessionStatusAsync(handle, cancellationToken)
            .ConfigureAwait(false);

        bool terminal = IsTerminal(status.Status);
        var properties = new AdditionalPropertiesDictionary
        {
            ["squad.sessionName"] = status.SessionName,
            ["squad.handle"] = status.Handle.Value,
            ["squad.route"] = SecretRedactor.Redact(status.Route),
            ["squad.executionMode"] = status.ExecutionMode.ToString(),
            ["squad.status"] = SecretRedactor.Redact(status.Status),
            ["squad.sandboxClass"] = Clean(status.SandboxClass),
            ["squad.phase"] = Clean(status.Phase),
            ["squad.exitCode"] = status.ExitCode,
            ["squad.terminal"] = terminal,
        };

        var response = new AgentResponse(new ChatMessage(ChatRole.Assistant, DescribeStatus(status, terminal)))
        {
            AgentId = Id,
            ResponseId = status.SessionName,
            CreatedAt = _clock.UtcNow,
            AdditionalProperties = properties,
            RawRepresentation = status,
            FinishReason = terminal ? ChatFinishReason.Stop : null,
        };

        // Re-attached while the session is unfinished so the caller can keep
        // polling with the same token, and dropped once it is terminal -- which is
        // how a caller knows to stop asking.
        SquadBackgroundResponse.SetContinuationToken(
            response,
            terminal ? null : SquadContinuationToken.Create(handleValue, sessionName));

        return response;
    }

    private SquadSessionRequest BuildRequest(IEnumerable<ChatMessage> messages, SquadAcaAgentRunOptions? options)
    {
        string prompt = ExtractPrompt(messages);
        if (string.IsNullOrWhiteSpace(prompt))
        {
            throw new ArgumentException(
                "The Agent Framework run carried no message text, so there is no Squad prompt to dispatch.",
                nameof(messages));
        }

        string? repository = options?.Repository ?? _options.DefaultRepository;
        if (string.IsNullOrWhiteSpace(repository))
        {
            throw new InvalidOperationException(
                "No repository was supplied. Set SquadAcaAgentOptions.DefaultRepository or " +
                "SquadAcaAgentRunOptions.Repository; the adapter will not guess one.");
        }

        return new SquadSessionRequest(
            Repository: repository,
            Prompt: prompt,
            SessionName: options?.SessionName,
            Ref: options?.Ref ?? _options.DefaultRef,
            OutputBranch: options?.OutputBranch,
            PushChanges: options?.PushChanges ?? _options.DefaultPushChanges,
            SubSquad: options?.SubSquad);
    }

    private static string ExtractPrompt(IEnumerable<ChatMessage> messages)
    {
        var builder = new StringBuilder();
        foreach (ChatMessage message in messages)
        {
            string text = message?.Text ?? string.Empty;
            if (string.IsNullOrWhiteSpace(text))
            {
                continue;
            }

            if (builder.Length > 0)
            {
                builder.Append('\n');
            }

            builder.Append(text);
        }

        return builder.ToString();
    }

    private SquadLongRunMode ResolveMode(SquadAcaAgentRunOptions? squadOptions, AgentRunOptions? options)
    {
        // Precedence, most specific first: the Squad-typed request, then MAF's own
        // background-response protocol, then the agent default. Honouring
        // AllowBackgroundResponses matters -- it is how a caller that has never
        // heard of this adapter still gets receipt-and-poll semantics.
        if (squadOptions?.LongRunMode is SquadLongRunMode explicitMode)
        {
            return explicitMode;
        }

        if (options?.AllowBackgroundResponses == true)
        {
            return SquadLongRunMode.DispatchOnly;
        }

        return _options.DefaultLongRunMode;
    }

    private AgentResponse BuildResponse(SquadRunEvent evt)
    {
        var properties = new AdditionalPropertiesDictionary
        {
            ["squad.sessionName"] = evt.Result.SessionName,
            ["squad.handle"] = evt.Result.Handle.Value,
            ["squad.route"] = RouteToken(evt.Result.Route),
            ["squad.executionMode"] = evt.Result.ExecutionMode.ToString(),
            ["squad.sandboxClass"] = Clean(evt.Status?.SandboxClass ?? evt.Result.SandboxClass),
            ["squad.fallbackReason"] = Clean(evt.Result.FallbackReason),
            ["squad.dispatched"] = evt.Result.Dispatched,
            ["squad.status"] = Clean(evt.Status?.Status ?? evt.Result.Status),
            ["squad.phase"] = Clean(evt.Status?.Phase),
            ["squad.exitCode"] = evt.Status?.ExitCode,
            ["squad.terminal"] = evt.Kind == SquadRunEventKind.Completed,
            ["squad.longRunMode"] = evt.Mode.ToString(),
        };

        var response = new AgentResponse(new ChatMessage(ChatRole.Assistant, Describe(evt)))
        {
            AgentId = Id,
            ResponseId = evt.Result.SessionName,
            CreatedAt = _clock.UtcNow,
            AdditionalProperties = properties,
            RawRepresentation = (object?)evt.Status ?? evt.Result,
            FinishReason = evt.Kind == SquadRunEventKind.Completed ? ChatFinishReason.Stop : null,
        };

        if (evt.Kind == SquadRunEventKind.Dispatched && evt.Mode == SquadLongRunMode.DispatchOnly)
        {
            SquadBackgroundResponse.SetContinuationToken(
                response,
                SquadContinuationToken.Create(evt.Result.Handle.Value, evt.Result.SessionName));
        }

        return response;
    }

    private AgentResponseUpdate BuildUpdate(SquadRunEvent evt)
    {
        AgentResponse response = BuildResponse(evt);
        var update = new AgentResponseUpdate(ChatRole.Assistant, Describe(evt))
        {
            AgentId = Id,
            ResponseId = evt.Result.SessionName,
            AuthorName = Name,
            CreatedAt = response.CreatedAt,
            AdditionalProperties = response.AdditionalProperties,
            RawRepresentation = response.RawRepresentation,
            FinishReason = response.FinishReason,
        };

        SquadBackgroundResponse.SetContinuationToken(
            update,
            SquadBackgroundResponse.GetContinuationToken(response));

        return update;
    }

    private static string Describe(SquadRunEvent evt) => evt.Kind switch
    {
        SquadRunEventKind.Dispatched => SecretRedactor.Redact(DescribeDispatch(evt)),
        SquadRunEventKind.StatusChanged => SecretRedactor.Redact(
            $"Squad session '{evt.Result.SessionName}' is now '{evt.Status!.Status}'" +
            $"{DescribePhase(evt.Status)}."),
        _ => SecretRedactor.Redact(DescribeCompletion(evt)),
    };

    private static string DescribeDispatch(SquadRunEvent evt)
    {
        var builder = new StringBuilder();
        builder.Append(CultureInfo.InvariantCulture, $"Dispatched Squad session '{evt.Result.SessionName}' ");
        builder.Append(CultureInfo.InvariantCulture, $"on route '{RouteToken(evt.Result.Route)}' ");
        builder.Append(CultureInfo.InvariantCulture, $"with status '{evt.Result.Status}'.");
        if (evt.Result.SandboxClass is { Length: > 0 } sandboxClass)
        {
            builder.Append(CultureInfo.InvariantCulture, $" Sandbox class: {sandboxClass}.");
        }

        if (evt.Result.FallbackReason is { Length: > 0 } fallback)
        {
            builder.Append(CultureInfo.InvariantCulture, $" Route deviated: {fallback}.");
        }

        builder.Append(CultureInfo.InvariantCulture, $" Handle: {evt.Result.Handle.Value}.");
        if (evt.Mode == SquadLongRunMode.DispatchOnly)
        {
            builder.Append(" Poll it with the continuation token on this response.");
        }

        return builder.ToString();
    }

    private static string DescribeCompletion(SquadRunEvent evt)
    {
        SquadSessionStatus status = evt.Status!;
        var builder = new StringBuilder();
        builder.Append(CultureInfo.InvariantCulture, $"Squad session '{status.SessionName}' finished ");
        builder.Append(CultureInfo.InvariantCulture, $"on route '{status.Route}' ");
        builder.Append(CultureInfo.InvariantCulture, $"with status '{status.Status}'");
        builder.Append(DescribePhase(status));
        if (status.ExitCode is int exitCode)
        {
            builder.Append(CultureInfo.InvariantCulture, $" (exit code {exitCode})");
        }

        builder.Append('.');
        if (status.SandboxClass is { Length: > 0 } sandboxClass)
        {
            builder.Append(CultureInfo.InvariantCulture, $" Sandbox class: {sandboxClass}.");
        }

        if (evt.Result.FallbackReason is { Length: > 0 } fallback)
        {
            builder.Append(CultureInfo.InvariantCulture, $" Route deviated: {fallback}.");
        }

        builder.Append(CultureInfo.InvariantCulture, $" Handle: {status.Handle.Value}.");
        return builder.ToString();
    }

    private static string DescribeStatus(SquadSessionStatus status, bool terminal)
    {
        string verb = terminal ? "finished" : "is running";
        var builder = new StringBuilder();
        builder.Append(CultureInfo.InvariantCulture, $"Squad session '{status.SessionName}' {verb} ");
        builder.Append(CultureInfo.InvariantCulture, $"on route '{status.Route}' ");
        builder.Append(CultureInfo.InvariantCulture, $"with status '{status.Status}'");
        builder.Append(DescribePhase(status));
        if (status.ExitCode is int exitCode)
        {
            builder.Append(CultureInfo.InvariantCulture, $" (exit code {exitCode})");
        }

        builder.Append(CultureInfo.InvariantCulture, $". Handle: {status.Handle.Value}.");
        return SecretRedactor.Redact(builder.ToString());
    }

    private static string DescribePhase(SquadSessionStatus status) =>
        status.Phase is { Length: > 0 } phase ? $" (phase {phase})" : string.Empty;

    private static string RouteToken(SquadExecutionRoute route) => route switch
    {
        SquadExecutionRoute.AcaJob => "aca-job",
        SquadExecutionRoute.Sandbox => "sandbox",
        _ => "fail-closed",
    };

    private static string? Clean(string? value) => value is null ? null : SecretRedactor.Redact(value);

    private void Diagnose(string message) => _options.DiagnosticSink?.Invoke(SecretRedactor.Redact(message));

    private sealed record PollStep(SquadSessionStatus Status, bool Terminal, TimeSpan NextInterval);

    private enum SquadRunEventKind
    {
        Dispatched,
        StatusChanged,
        Completed,
    }

    private sealed record SquadRunEvent(
        SquadRunEventKind Kind,
        SquadSessionResult Result,
        SquadSessionStatus? Status,
        SquadLongRunMode Mode)
    {
        internal static SquadRunEvent Dispatched(SquadSessionResult result, SquadLongRunMode mode) =>
            new(SquadRunEventKind.Dispatched, result, null, mode);

        internal static SquadRunEvent StatusChanged(
            SquadSessionResult result,
            SquadSessionStatus status,
            SquadLongRunMode mode) =>
            new(SquadRunEventKind.StatusChanged, result, status, mode);

        internal static SquadRunEvent Completed(
            SquadSessionResult result,
            SquadSessionStatus status,
            SquadLongRunMode mode) =>
            new(SquadRunEventKind.Completed, result, status, mode);
    }
}
