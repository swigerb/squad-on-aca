namespace Squad.Aca.Agents.MAF;

/// <summary>
/// A <see cref="SquadLongRunMode.RunToCompletion"/> run waited its full budget
/// and the session had still not reached a terminal state.
/// </summary>
/// <remarks>
/// <para>
/// This is a terminal, actionable error rather than a hang, and it carries the
/// handle precisely because the session may well still be running: a caller can
/// resume polling it, read its logs, or stop it. Throwing a bare
/// <see cref="TimeoutException"/> would lose that.
/// </para>
/// <para>
/// It derives from <see cref="SquadAgentException"/>, so the message is redacted
/// by the same base constructor everything else in this library uses.
/// </para>
/// </remarks>
public sealed class SquadAgentRunTimeoutException : SquadAgentException
{
    /// <summary>Creates the exception.</summary>
    /// <param name="message">Message; redacted before it is stored.</param>
    /// <param name="handle">The session's opaque handle.</param>
    /// <param name="sessionName">The session / pod id.</param>
    /// <param name="elapsed">How long the run waited.</param>
    /// <param name="lastStatus">The last status observed, when one was.</param>
    /// <param name="sessionCancelled">Whether the adapter asked ACA to stop the session.</param>
    public SquadAgentRunTimeoutException(
        string message,
        SquadExecutionHandle handle,
        string sessionName,
        TimeSpan elapsed,
        string? lastStatus,
        bool sessionCancelled)
        : base(message)
    {
        Handle = handle;
        SessionName = sessionName;
        Elapsed = elapsed;
        LastStatus = lastStatus;
        SessionCancelled = sessionCancelled;
    }

    /// <summary>The opaque handle for the session that outlasted the budget.</summary>
    public SquadExecutionHandle Handle { get; }

    /// <summary>The session / pod id.</summary>
    public string SessionName { get; }

    /// <summary>How long the run waited before giving up.</summary>
    public TimeSpan Elapsed { get; }

    /// <summary>The last substrate status observed, or null if none was read.</summary>
    public string? LastStatus { get; }

    /// <summary>
    /// Whether the adapter asked ACA to stop the session on the way out (see
    /// <see cref="SquadAcaAgentOptions.CancelSessionOnTimeout"/>). When false the
    /// session is still running and <see cref="Handle"/> still addresses it.
    /// </summary>
    public bool SessionCancelled { get; }
}
