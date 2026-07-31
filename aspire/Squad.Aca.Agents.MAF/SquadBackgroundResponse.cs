using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;

namespace Squad.Aca.Agents.MAF;

/// <summary>
/// The one place this library touches the Agent Framework's <b>experimental</b>
/// background-response surface.
/// </summary>
/// <remarks>
/// <para>
/// <c>AgentRunOptions.ContinuationToken</c> and <c>AgentResponse.ContinuationToken</c>
/// are annotated <c>[Experimental("MEAI001")]</c> even in the otherwise stable
/// Microsoft.Agents.AI 1.16.0, so touching them is a compile ERROR here
/// (<c>TreatWarningsAsErrors</c>) until the diagnostic is suppressed.
/// </para>
/// <para>
/// It is suppressed in this file and nowhere else. A project-wide
/// <c>&lt;NoWarn&gt;MEAI001&lt;/NoWarn&gt;</c> would have been one line, and would
/// also have silently opted every future file into an unstable API — the exact
/// failure mode the whole quarantine exists to prevent, reproduced one level
/// down. Keeping it to a single file means "which experimental APIs does this
/// depend on?" is answered by reading one screen, and a breaking change upstream
/// lands here first.
/// </para>
/// <para>
/// These helpers are public because a consumer hits the same diagnostic: reading
/// <c>response.ContinuationToken</c> to poll a dispatched session is an ordinary
/// thing to do, and it should not force every caller to suppress MEAI001 in
/// their own build.
/// </para>
/// </remarks>
public static class SquadBackgroundResponse
{
#pragma warning disable MEAI001 // Experimental background-response surface; see the remarks above.

    /// <summary>Reads the continuation token a caller supplied on run options.</summary>
    /// <param name="options">Run options, possibly null.</param>
    /// <returns>The token, or null when there is none.</returns>
    public static ResponseContinuationToken? GetContinuationToken(AgentRunOptions? options) =>
        options?.ContinuationToken;

    /// <summary>Reads the continuation token attached to a response.</summary>
    /// <param name="response">The response.</param>
    /// <returns>The token, or null when the session is finished.</returns>
    public static ResponseContinuationToken? GetContinuationToken(AgentResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        return response.ContinuationToken;
    }

    /// <summary>Reads the continuation token attached to a streaming update.</summary>
    /// <param name="update">The update.</param>
    /// <returns>The token, or null when the session is finished.</returns>
    public static ResponseContinuationToken? GetContinuationToken(AgentResponseUpdate update)
    {
        ArgumentNullException.ThrowIfNull(update);
        return update.ContinuationToken;
    }

    /// <summary>Attaches a continuation token to run options.</summary>
    /// <param name="options">The run options to poll with.</param>
    /// <param name="token">The token from a previous response.</param>
    /// <returns>The same options, for chaining.</returns>
    public static AgentRunOptions WithContinuationToken(
        AgentRunOptions options,
        ResponseContinuationToken? token)
    {
        ArgumentNullException.ThrowIfNull(options);
        options.ContinuationToken = token;
        return options;
    }

    internal static void SetContinuationToken(AgentResponse response, ResponseContinuationToken? token) =>
        response.ContinuationToken = token;

    internal static void SetContinuationToken(AgentResponseUpdate update, ResponseContinuationToken? token) =>
        update.ContinuationToken = token;

#pragma warning restore MEAI001
}
