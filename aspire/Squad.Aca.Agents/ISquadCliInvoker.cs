namespace Squad.Aca.Agents;

/// <summary>
/// One completed <c>squad-aca</c> invocation.
/// </summary>
/// <param name="ExitCode">Process exit code.</param>
/// <param name="StandardOutput">Everything the process wrote to stdout.</param>
/// <param name="StandardError">Everything the process wrote to stderr.</param>
public sealed record SquadCliResult(int ExitCode, string StandardOutput, string StandardError);

/// <summary>
/// The seam between <see cref="AcaSquadAgent"/> and the <c>squad-aca</c> process.
/// </summary>
/// <remarks>
/// <para>
/// This interface exists so the agent is testable without PowerShell, without
/// Azure and without a network. Everything above it — argument construction,
/// contract parsing, route classification, redaction — is pure and is exercised
/// against a fake implementation.
/// </para>
/// <para>
/// Implementations MUST return the exit code faithfully and MUST NOT translate a
/// non-zero exit into an exception or an empty success. The agent distinguishes
/// "the CLI refused" from "the CLI could not be run" and needs the raw values to
/// do it.
/// </para>
/// </remarks>
public interface ISquadCliInvoker
{
    /// <summary>Runs <c>squad-aca</c> with the given arguments.</summary>
    /// <param name="arguments">Arguments, already split; never shell-quoted by the caller.</param>
    /// <param name="cancellationToken">Cancels the invocation.</param>
    /// <returns>Exit code, stdout and stderr.</returns>
    Task<SquadCliResult> InvokeAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default);
}
