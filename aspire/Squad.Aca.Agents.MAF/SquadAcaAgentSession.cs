using Microsoft.Agents.AI;

namespace Squad.Aca.Agents.MAF;

/// <summary>
/// The Agent Framework session for <see cref="SquadAcaAIAgent"/>.
/// </summary>
/// <remarks>
/// <para>
/// A Squad session is owned by ACA, not by this object, so the only thing worth
/// keeping here is the handle of the most recent dispatch. That is enough for a
/// host to serialize the session, restart, deserialize it, and still be able to
/// poll or stop work that outlived the process — which for a 10–60 minute
/// session is the realistic case, not the exotic one.
/// </para>
/// <para>
/// It deliberately does NOT accumulate a chat transcript. The Squad session
/// keeps its own history in the repository it is working on; duplicating a
/// partial copy here would create a second, quieter source of truth.
/// </para>
/// </remarks>
public sealed class SquadAcaAgentSession : AgentSession
{
    private const string HandleKey = "squad.aca.lastHandle";
    private const string SessionNameKey = "squad.aca.lastSessionName";

    internal SquadAcaAgentSession()
    {
    }

    internal SquadAcaAgentSession(AgentSessionStateBag stateBag)
        : base(stateBag)
    {
    }

    /// <summary>
    /// Handle of the most recent dispatch made on this session, or null if none.
    /// </summary>
    public SquadExecutionHandle? LastHandle =>
        StateBag.TryGetValue(HandleKey, out string? value, SquadJson.Options)
        && !string.IsNullOrWhiteSpace(value)
            ? new SquadExecutionHandle(value)
            : null;

    /// <summary>
    /// Session / pod id of the most recent dispatch made on this session.
    /// </summary>
    public string? LastSessionName =>
        StateBag.TryGetValue(SessionNameKey, out string? value, SquadJson.Options) ? value : null;

    internal void Record(SquadExecutionHandle handle, string sessionName)
    {
        StateBag.SetValue(HandleKey, handle.Value, SquadJson.Options);
        StateBag.SetValue(SessionNameKey, sessionName, SquadJson.Options);
    }
}
