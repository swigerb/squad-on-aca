// Agent abstraction seam for the optional .NET/Aspire integration path.
//
// The Microsoft Agent Framework (Microsoft.Agents.AI.*) is the intended way to
// expose a Squad-on-ACA session as a first-class "agent". Those packages are
// still preview and their surface changes between releases, so this file does
// NOT take a hard dependency on them. Instead it defines a tiny, compile-safe
// seam that:
//
//   * models "run a Squad session on ACA" as an agent capability, and
//   * shows exactly where an Agent Framework AIAgent implementation would plug
//     in without destabilizing package restore for the whole solution.
//
// To adopt the real Agent Framework, add (versions are examples; pin the latest
// preview you have validated):
//
//   <PackageReference Include="Microsoft.Agents.AI" Version="1.0.0-preview.*" />
//
// then implement ISquadAgent by wrapping an AIAgent whose tool/So invocation
// shells out to the existing control plane (scripts/squad-aca.ps1) or the ACA
// management SDK. ACA stays the execution substrate; this type is only the
// orchestration-facing abstraction.

namespace Squad.Aca.AppHost;

/// <summary>
/// A request to run one Squad session as an agent invocation.
/// </summary>
/// <param name="Repository">Target GitHub repository, e.g. "owner/repo".</param>
/// <param name="Prompt">Natural-language task for the Squad team.</param>
/// <param name="SessionName">Optional stable session/pod id; generated if null.</param>
/// <param name="Ref">Git ref/branch to operate on. Defaults to "main".</param>
public sealed record SquadSessionRequest(
    string Repository,
    string Prompt,
    string? SessionName = null,
    string Ref = "main");

/// <summary>
/// Result of an agent-driven Squad session dispatch.
/// </summary>
/// <param name="SessionName">Resolved session/pod id used for telemetry.</param>
/// <param name="Dispatched">True when the ACA execution was started.</param>
/// <param name="Detail">Human-readable status or error detail.</param>
public sealed record SquadSessionResult(
    string SessionName,
    bool Dispatched,
    string Detail);

/// <summary>
/// Orchestration-facing abstraction for Squad on ACA. An Agent Framework
/// <c>AIAgent</c> adapter would implement this by dispatching to ACA Jobs; the
/// abstraction deliberately hides whether dispatch happens via the PowerShell
/// control plane or the Azure management SDK.
/// </summary>
public interface ISquadAgent
{
    /// <summary>Dispatch a Squad session and return once ACA accepts it.</summary>
    Task<SquadSessionResult> RunSessionAsync(
        SquadSessionRequest request,
        CancellationToken cancellationToken = default);
}
