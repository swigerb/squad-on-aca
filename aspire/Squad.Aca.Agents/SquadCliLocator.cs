namespace Squad.Aca.Agents;

/// <summary>
/// Finds the <c>squad-aca</c> control-plane entry point.
/// </summary>
/// <remarks>
/// <para>
/// Deliberately NO hard-coded absolute path. The search order is, in decreasing
/// order of explicitness:
/// </para>
/// <list type="number">
///   <item><description><see cref="SquadAgentOptions.CliPath"/>, when set.</description></item>
///   <item><description>The <c>SQUAD_ACA_CLI</c> environment variable.</description></item>
///   <item><description>
///     <c>scripts/squad-aca.ps1</c> found by walking up from the start directory
///     (the working directory, then the assembly's base directory) — this is what
///     makes it work from a checkout, a test run and an Aspire AppHost alike.
///   </description></item>
/// </list>
/// <para>
/// When none of those resolve, this THROWS with the list of places it looked.
/// Returning a bare "squad-aca" and letting the process launch fail would report
/// the problem as a dispatch failure, which is a different and much more
/// alarming thing than "the CLI is not installed here".
/// </para>
/// </remarks>
public static class SquadCliLocator
{
    /// <summary>The environment variable that names the control-plane script.</summary>
    public const string PathEnvironmentVariable = "SQUAD_ACA_CLI";

    private const string RelativeScriptPath = "scripts/squad-aca.ps1";

    /// <summary>Resolves the control-plane script path.</summary>
    /// <param name="options">Options whose <see cref="SquadAgentOptions.CliPath"/> wins when set.</param>
    /// <param name="fileExists">File-existence probe; overridable for tests.</param>
    /// <param name="environment">Environment reader; overridable for tests.</param>
    /// <param name="startDirectories">Directories to walk upwards from.</param>
    /// <returns>An existing path to <c>squad-aca.ps1</c>.</returns>
    /// <exception cref="SquadAgentException">Nothing resolved.</exception>
    public static string Resolve(
        SquadAgentOptions options,
        Func<string, bool>? fileExists = null,
        Func<string, string?>? environment = null,
        IEnumerable<string>? startDirectories = null)
    {
        ArgumentNullException.ThrowIfNull(options);

        fileExists ??= File.Exists;
        environment ??= Environment.GetEnvironmentVariable;

        var attempted = new List<string>();

        if (!string.IsNullOrWhiteSpace(options.CliPath))
        {
            if (fileExists(options.CliPath))
            {
                return options.CliPath;
            }

            attempted.Add($"SquadAgentOptions.CliPath ('{options.CliPath}')");
        }

        string? fromEnvironment = environment(PathEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(fromEnvironment))
        {
            if (fileExists(fromEnvironment))
            {
                return fromEnvironment;
            }

            attempted.Add($"${PathEnvironmentVariable} ('{fromEnvironment}')");
        }

        IEnumerable<string> roots = startDirectories
            ?? [options.WorkingDirectory ?? Directory.GetCurrentDirectory(), AppContext.BaseDirectory];

        foreach (string root in roots)
        {
            if (string.IsNullOrWhiteSpace(root))
            {
                continue;
            }

            string? candidate = SearchUpwards(root, fileExists);
            if (candidate is not null)
            {
                return candidate;
            }

            attempted.Add($"'{RelativeScriptPath}' at or above '{root}'");
        }

        throw new SquadAgentException(
            "Could not locate the squad-aca control plane. Set SquadAgentOptions.CliPath or the " +
            $"{PathEnvironmentVariable} environment variable. Looked at: {string.Join("; ", attempted)}.");
    }

    private static string? SearchUpwards(string startDirectory, Func<string, bool> fileExists)
    {
        string? current;
        try
        {
            current = Path.GetFullPath(startDirectory);
        }
        catch (ArgumentException)
        {
            return null;
        }

        while (!string.IsNullOrEmpty(current))
        {
            string candidate = Path.Combine(current, "scripts", "squad-aca.ps1");
            if (fileExists(candidate))
            {
                return candidate;
            }

            string? parent = Path.GetDirectoryName(current);
            if (parent == current)
            {
                return null;
            }

            current = parent;
        }

        return null;
    }
}
