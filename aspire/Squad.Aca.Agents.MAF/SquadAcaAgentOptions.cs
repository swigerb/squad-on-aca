namespace Squad.Aca.Agents.MAF;

/// <summary>
/// How the adapter reconciles a 10–60 minute Squad session with the Agent
/// Framework's request/response <c>RunAsync</c>.
/// </summary>
/// <remarks>
/// <para>
/// This is the central design decision of the MAF adapter, so it is a named,
/// documented enum rather than a boolean buried in an options object.
/// </para>
/// </remarks>
public enum SquadLongRunMode
{
    /// <summary>
    /// Dispatch, then poll until the session reaches a terminal state, and return
    /// the finished result. Bounded by
    /// <see cref="SquadAcaAgentOptions.RunTimeout"/>.
    /// </summary>
    /// <remarks>
    /// THE DEFAULT, and deliberately so. An Agent Framework caller that has not
    /// set <c>AgentRunOptions.AllowBackgroundResponses</c> is promised a completed
    /// <c>AgentResponse</c>, and in a workflow that response is fed to the next
    /// node. Handing that node a dispatch receipt is not a smaller answer, it is a
    /// WRONG one — the receipt gets read as if it were the work product, and
    /// nothing in the type system objects. Fire-and-forget is safe only when the
    /// caller asked for it, and MAF already provides two explicit ways to ask.
    /// </remarks>
    RunToCompletion,

    /// <summary>
    /// Return as soon as ACA accepts the dispatch, with the handle attached as an
    /// <c>AgentResponse.ContinuationToken</c> the caller polls with.
    /// </summary>
    /// <remarks>
    /// Selected explicitly via <see cref="SquadAcaAgentRunOptions.LongRunMode"/>,
    /// or implicitly by MAF's own protocol when the caller sets
    /// <c>AgentRunOptions.AllowBackgroundResponses = true</c>.
    /// </remarks>
    DispatchOnly,
}

/// <summary>
/// Construction options for <see cref="SquadAcaAIAgent"/>.
/// </summary>
public sealed class SquadAcaAgentOptions
{
    /// <summary>Agent name surfaced to the Agent Framework. Defaults to <c>squad-on-aca</c>.</summary>
    public string Name { get; set; } = "squad-on-aca";

    /// <summary>Agent description surfaced to the Agent Framework.</summary>
    public string Description { get; set; } =
        "Runs a Squad session on Azure Container Apps — Jobs by default, an approved ACA Sandbox class when capability routing requires one.";

    /// <summary>
    /// Stable agent id. When null a new GUID is minted per instance, which is the
    /// Agent Framework's own default behaviour.
    /// </summary>
    public string? Id { get; set; }

    /// <summary>
    /// Repository (<c>owner/repo</c>) used when a run does not name one.
    /// </summary>
    /// <remarks>
    /// A MAF <c>RunAsync(string)</c> carries only a prompt, so the repository has
    /// to come from somewhere. It is configured on the agent and overridable per
    /// run through <see cref="SquadAcaAgentRunOptions.Repository"/>. There is no
    /// invented default: a run with neither is rejected before the control plane
    /// is invoked, because guessing a repository is how an agent commits to the
    /// wrong one.
    /// </remarks>
    public string? DefaultRepository { get; set; }

    /// <summary>Git ref used when a run does not name one. Defaults to <c>main</c>.</summary>
    public string DefaultRef { get; set; } = "main";

    /// <summary>Whether sessions push their work by default.</summary>
    public bool DefaultPushChanges { get; set; } = true;

    /// <summary>Long-run behaviour when a run does not select one.</summary>
    public SquadLongRunMode DefaultLongRunMode { get; set; } = SquadLongRunMode.RunToCompletion;

    /// <summary>
    /// Upper bound on how long <see cref="SquadLongRunMode.RunToCompletion"/> waits
    /// before giving up. Defaults to 90 minutes.
    /// </summary>
    /// <remarks>
    /// Squad sessions run 10–60 minutes, so 90 leaves headroom for a slow start
    /// without being unbounded. Unbounded is not an option: a wait with no ceiling
    /// is indistinguishable from a hang, and the caller has no way to tell whether
    /// the session is working or the adapter is stuck.
    /// </remarks>
    public TimeSpan RunTimeout { get; set; } = TimeSpan.FromMinutes(90);

    /// <summary>First polling interval. Defaults to 5 seconds.</summary>
    public TimeSpan InitialPollInterval { get; set; } = TimeSpan.FromSeconds(5);

    /// <summary>Ceiling on the polling interval. Defaults to 60 seconds.</summary>
    /// <remarks>
    /// Each poll is an <c>az</c> read against ARM, and ARM throttles per
    /// subscription. Backing off to a 60-second ceiling costs at most 60 reads an
    /// hour per waiting run, which stays far below any documented read limit while
    /// still noticing a terminal state within a minute of it happening.
    /// </remarks>
    public TimeSpan MaxPollInterval { get; set; } = TimeSpan.FromSeconds(60);

    /// <summary>Multiplier applied to the interval after each poll. Defaults to 1.5.</summary>
    public double PollBackoffFactor { get; set; } = 1.5;

    /// <summary>
    /// Whether a run that exhausts <see cref="RunTimeout"/> also asks ACA to stop
    /// the session. Defaults to <see langword="true"/>.
    /// </summary>
    /// <remarks>
    /// A timed-out run has no observer left. Leaving the session running bills for
    /// compute nobody is waiting on, which is the same orphan the cancellation
    /// path exists to prevent. Callers who genuinely want the work to continue set
    /// this to <see langword="false"/>; the handle is on
    /// <see cref="SquadAgentRunTimeoutException"/> either way, so nothing is lost.
    /// </remarks>
    public bool CancelSessionOnTimeout { get; set; } = true;

    /// <summary>
    /// Time allowed for the best-effort stop issued when a run is cancelled or
    /// times out. Defaults to 30 seconds.
    /// </summary>
    /// <remarks>
    /// The stop call deliberately does NOT run under the caller's cancellation
    /// token — that token is already cancelled, so passing it would abort the stop
    /// immediately and leave the ACA session running. It gets its own budget.
    /// </remarks>
    public TimeSpan StopTimeout { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Optional diagnostic sink. Every line is passed through
    /// <see cref="SecretRedactor"/> before it is handed over.
    /// </summary>
    public Action<string>? DiagnosticSink { get; set; }

    /// <summary>
    /// Clock and delay source for the polling loop. Defaults to
    /// <see cref="SystemPollingClock.Instance"/>.
    /// </summary>
    /// <remarks>
    /// This is the seam that makes a 90-minute timeout testable in milliseconds.
    /// Without it the timeout path could only be covered by actually waiting, and
    /// a test nobody runs is not a test.
    /// </remarks>
    public ISquadPollingClock PollingClock { get; set; } = SystemPollingClock.Instance;

    internal void Validate()
    {
        if (RunTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(RunTimeout), RunTimeout, "RunTimeout must be positive.");
        }

        if (InitialPollInterval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(InitialPollInterval), InitialPollInterval, "InitialPollInterval must be positive.");
        }

        if (MaxPollInterval < InitialPollInterval)
        {
            throw new ArgumentOutOfRangeException(
                nameof(MaxPollInterval), MaxPollInterval, "MaxPollInterval must be at least InitialPollInterval.");
        }

        if (PollBackoffFactor < 1.0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(PollBackoffFactor), PollBackoffFactor, "PollBackoffFactor must be at least 1.0.");
        }
    }
}
