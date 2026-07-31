using System.Text.Json;
using Microsoft.Extensions.AI;

namespace Squad.Aca.Agents.MAF;

/// <summary>
/// Encodes and decodes the Squad execution handle carried by a MAF
/// <see cref="ResponseContinuationToken"/>.
/// </summary>
/// <remarks>
/// <para>
/// The Agent Framework already has a protocol for "this response is not finished
/// yet": the agent returns a <see cref="ResponseContinuationToken"/> and the
/// caller hands it back on <c>AgentRunOptions.ContinuationToken</c>. That is
/// exactly the receipt-and-poll shape a 10–60 minute Squad session needs, so the
/// adapter uses it rather than inventing a parallel convention that only Squad
/// callers would know about.
/// </para>
/// <para>
/// The payload is a small JSON object, not a bare handle string, so a future
/// field (a deadline, a session name) can be added without minting a new token
/// shape. It carries NO credential — only the same opaque handle the control
/// plane already prints — and it is not signed, because it is a resume cursor
/// the caller already possessed, not a capability.
/// </para>
/// </remarks>
internal static class SquadContinuationToken
{
    private const string SchemaValue = "squad-aca/continuation@1";

    internal static ResponseContinuationToken Create(string handle, string sessionName)
    {
        var payload = new Payload
        {
            Schema = SchemaValue,
            Handle = handle,
            SessionName = sessionName,
        };

        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(payload, SquadJson.Options);
        return ResponseContinuationToken.FromBytes(bytes);
    }

    /// <summary>
    /// Reads a continuation token back. Throws rather than returning null on
    /// anything unexpected: a token this adapter cannot decode is a token from
    /// somewhere else, and polling an arbitrary string as if it were a handle is
    /// how a caller ends up reading another session's state.
    /// </summary>
    internal static (string Handle, string SessionName) Read(ResponseContinuationToken token)
    {
        ArgumentNullException.ThrowIfNull(token);

        Payload? payload;
        try
        {
            payload = JsonSerializer.Deserialize<Payload>(token.ToBytes().Span, SquadJson.Options);
        }
        catch (JsonException ex)
        {
            throw new SquadContractException(
                "The supplied AgentRunOptions.ContinuationToken is not a Squad continuation token.", ex);
        }

        if (payload is null || !string.Equals(payload.Schema, SchemaValue, StringComparison.Ordinal))
        {
            throw new SquadContractException(
                $"Expected a '{SchemaValue}' continuation token but got '{payload?.Schema ?? "(none)"}'.");
        }

        if (string.IsNullOrWhiteSpace(payload.Handle))
        {
            throw new SquadContractException("The Squad continuation token carries no execution handle.");
        }

        return (payload.Handle, payload.SessionName ?? payload.Handle);
    }

    private sealed class Payload
    {
        public string? Schema { get; set; }

        public string? Handle { get; set; }

        public string? SessionName { get; set; }
    }
}

internal static class SquadJson
{
    internal static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);
}
