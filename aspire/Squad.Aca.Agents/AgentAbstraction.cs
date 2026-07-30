// Agent abstraction seam for the optional .NET/Aspire integration path.
//
// (Moved here from aspire/Squad.Aca.AppHost/AgentAbstraction.cs in Sprint 1 of
// issue #33. The reasoning below is why the seam was written this way in the
// first place, and it still holds — extracting it into its own class library is
// what finally makes it enforceable rather than merely stated.)
//
// The Microsoft Agent Framework (Microsoft.Agents.AI.*) is the intended way to
// expose a Squad-on-ACA session as a first-class "agent". Those packages are
// still preview and their surface changes between releases, so this project
// does NOT take a hard dependency on them. Instead it defines a tiny,
// compile-safe seam that:
//
//   * models "run a Squad session on ACA" as an agent capability, and
//   * shows exactly where an Agent Framework AIAgent implementation would plug
//     in without destabilizing package restore for the whole solution.
//
// To adopt the real Agent Framework, add (versions are examples; pin the latest
// preview you have validated) to a SEPARATE project that references this one:
//
//   <PackageReference Include="Microsoft.Agents.AI" Version="1.0.0-preview.*" />
//
// then implement an AIAgent that wraps ISquadAgent. That project is Sprint 2's
// job, and keeping it separate is what stops a preview restore failure from
// taking this contract — and everything that depends on it — down with it.
// ACA stays the execution substrate; these types are only the
// orchestration-facing abstraction.
//
// WHAT SPRINT 1 CHANGED, AND WHY. The original SquadSessionResult was
//
//     record SquadSessionResult(string SessionName, bool Dispatched, string Detail);
//
// which predates the capability router (Sprint 2), the opaque execution handle
// (Sprint 3), and the ACA Sandboxes plane (Sprint 5). The control plane now also
// produces a route, an execution handle, a sandbox class and a fallback reason,
// and a caller that cannot see those cannot tell WHERE its work ran or poll it
// afterwards. Worse, it could not tell a fail-closed refusal from a successful
// dispatch. Those fields are therefore part of the contract now.

namespace Squad.Aca.Agents;

/// <summary>
/// Which execution plane the control plane routed a session to.
/// </summary>
/// <remarks>
/// This mirrors the control plane's own vocabulary exactly
/// (<c>Resolve-SquadExecutionRoute</c> in scripts/lib/squad-aca-provider.ps1).
/// <see cref="FailedClosed"/> is a REFUSAL: the repository's declared
/// capabilities could not be satisfied safely, so nothing was started. It is
/// never reported as a successful dispatch.
/// </remarks>
public enum SquadExecutionRoute
{
    /// <summary>Azure Container Apps Jobs — the unconditional default.</summary>
    AcaJob,

    /// <summary>ACA Sandboxes — only for an administrator-approved class.</summary>
    Sandbox,

    /// <summary>Refused. Required capabilities cannot be met; nothing was started.</summary>
    FailedClosed,
}

/// <summary>
/// The substrate that actually owns an execution.
/// </summary>
public enum SquadExecutionMode
{
    /// <summary>Azure Container Apps Jobs.</summary>
    AcaJob,

    /// <summary>ACA Sandboxes.</summary>
    Sandbox,
}

/// <summary>
/// An opaque reference to a dispatched execution.
/// </summary>
/// <remarks>
/// Treat the <see cref="Value"/> as a token: pass it back verbatim to
/// <see cref="ISquadAgent.GetSessionStatusAsync"/> and
/// <see cref="ISquadAgent.CancelSessionAsync"/> and never parse it. It already
/// names the provider that minted it, which is what lets a lifecycle call
/// recover the substrate instead of re-resolving today's routing question about
/// yesterday's session.
/// </remarks>
/// <param name="Value">The opaque handle string.</param>
public sealed record SquadExecutionHandle(string Value)
{
    /// <inheritdoc/>
    public override string ToString() => Value;
}

/// <summary>
/// A request to run one Squad session as an agent invocation.
/// </summary>
/// <param name="Repository">Target GitHub repository, e.g. "owner/repo".</param>
/// <param name="Prompt">Natural-language task for the Squad team.</param>
/// <param name="SessionName">Optional stable session/pod id; generated if null.</param>
/// <param name="Ref">Git ref/branch to operate on. Defaults to "main".</param>
/// <param name="OutputBranch">Optional branch the session pushes to.</param>
/// <param name="PushChanges">Whether the session pushes its work. Defaults to true.</param>
/// <param name="SubSquad">Optional SubSquad to activate for the session.</param>
public sealed record SquadSessionRequest(
    string Repository,
    string Prompt,
    string? SessionName = null,
    string Ref = "main",
    string? OutputBranch = null,
    bool PushChanges = true,
    string? SubSquad = null);

/// <summary>
/// Result of an agent-driven Squad session dispatch.
/// </summary>
/// <param name="SessionName">Resolved session/pod id used for telemetry.</param>
/// <param name="Dispatched">True when the ACA execution was started.</param>
/// <param name="Route">The plane the control plane routed this session to.</param>
/// <param name="ExecutionMode">The substrate that owns the execution.</param>
/// <param name="Handle">Opaque reference for status and cancellation.</param>
/// <param name="SandboxClass">Approved sandbox class id, or null on the Jobs plane.</param>
/// <param name="FallbackReason">
/// Why the route deviated from what the manifest asked for, or null when it did
/// not. Ordinary outcomes never populate this.
/// </param>
/// <param name="Status">Substrate status at dispatch time, e.g. "Requested".</param>
/// <param name="Detail">Human-readable status or error detail.</param>
public sealed record SquadSessionResult(
    string SessionName,
    bool Dispatched,
    SquadExecutionRoute Route,
    SquadExecutionMode ExecutionMode,
    SquadExecutionHandle Handle,
    string? SandboxClass,
    string? FallbackReason,
    string Status,
    string Detail);

/// <summary>
/// The observed state of one dispatched session.
/// </summary>
/// <param name="SessionName">Session/pod id.</param>
/// <param name="ExecutionName">Substrate-side execution or sandbox name.</param>
/// <param name="Handle">Opaque reference this state was read through.</param>
/// <param name="ExecutionMode">The substrate that owns the execution.</param>
/// <param name="Route">The route recorded on the execution itself.</param>
/// <param name="Status">Substrate status, e.g. "Running", "Succeeded".</param>
/// <param name="SandboxClass">Approved sandbox class id, or null on the Jobs plane.</param>
/// <param name="Repository">Repository the session is operating on, when known.</param>
/// <param name="Branch">Branch the session is operating on, when known.</param>
/// <param name="Phase">Sandbox lifecycle phase, or null on the Jobs plane.</param>
/// <param name="ExitCode">Worker exit code once known, otherwise null.</param>
public sealed record SquadSessionStatus(
    string SessionName,
    string ExecutionName,
    SquadExecutionHandle Handle,
    SquadExecutionMode ExecutionMode,
    string Route,
    string Status,
    string? SandboxClass,
    string? Repository,
    string? Branch,
    string? Phase,
    int? ExitCode);

/// <summary>
/// Orchestration-facing abstraction for Squad on ACA. An Agent Framework
/// <c>AIAgent</c> adapter would implement or wrap this; the abstraction
/// deliberately hides whether dispatch happens via the PowerShell control plane
/// or the Azure management SDK, and whether the work lands on ACA Jobs or an ACA
/// Sandbox.
/// </summary>
/// <remarks>
/// There is deliberately NO poll-to-completion operation here. Squad sessions run
/// for 10–60 minutes and the Agent Framework's <c>RunAsync</c> is
/// request/response, so how those two are reconciled — fire-and-forget plus
/// polling, with cancellation and a timeout — is an adapter decision, not a
/// control-plane one. Dispatch returns a handle; the caller decides what to do
/// with it.
/// </remarks>
public interface ISquadAgent
{
    /// <summary>Dispatch a Squad session and return once ACA accepts it.</summary>
    /// <param name="request">The session to run.</param>
    /// <param name="cancellationToken">Cancels the dispatch call itself, not the session.</param>
    /// <returns>The dispatch result, including the handle to poll with.</returns>
    /// <exception cref="SquadRouteFailedClosedException">
    /// The repository's required capabilities could not be met. Nothing was started.
    /// </exception>
    /// <exception cref="SquadDispatchFailedException">The control plane refused or failed.</exception>
    Task<SquadSessionResult> RunSessionAsync(
        SquadSessionRequest request,
        CancellationToken cancellationToken = default);

    /// <summary>Read the current state of a dispatched session.</summary>
    /// <param name="handle">The opaque handle returned by dispatch.</param>
    /// <param name="cancellationToken">Cancels the status call.</param>
    /// <returns>The observed session state.</returns>
    Task<SquadSessionStatus> GetSessionStatusAsync(
        SquadExecutionHandle handle,
        CancellationToken cancellationToken = default);

    /// <summary>Cancel a dispatched session.</summary>
    /// <param name="handle">The opaque handle returned by dispatch.</param>
    /// <param name="cancellationToken">Cancels the stop call.</param>
    Task CancelSessionAsync(
        SquadExecutionHandle handle,
        CancellationToken cancellationToken = default);
}
