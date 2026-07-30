namespace Squad.Aca.Agents;

/// <summary>
/// Construction options for <see cref="AcaSquadAgent"/> and
/// <see cref="SquadCliProcessInvoker"/>.
/// </summary>
public sealed class SquadAgentOptions
{
    /// <summary>
    /// Explicit path to <c>scripts/squad-aca.ps1</c>. When null the entry point
    /// is discovered (see <see cref="SquadCliLocator"/>).
    /// </summary>
    /// <remarks>
    /// There is deliberately no default absolute path. A hard-coded one is wrong
    /// on every machine except the author's, and it fails at dispatch time rather
    /// than at construction time.
    /// </remarks>
    public string? CliPath { get; set; }

    /// <summary>
    /// PowerShell executable used to run the control plane. Defaults to
    /// <c>pwsh</c>, resolved from PATH.
    /// </summary>
    public string PowerShellPath { get; set; } = "pwsh";

    /// <summary>
    /// Working directory for the control-plane process. Defaults to the current
    /// directory, which is what makes the capability manifest of the repository
    /// the caller is sitting in readable.
    /// </summary>
    public string? WorkingDirectory { get; set; }

    /// <summary>
    /// Optional diagnostic sink. Every line handed to it is passed through
    /// <see cref="SecretRedactor"/> first, so a sink wired to a logger cannot
    /// become a credential exfiltration path.
    /// </summary>
    public Action<string>? DiagnosticSink { get; set; }
}
