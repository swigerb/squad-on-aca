using System.Diagnostics;
using System.Text;

namespace Squad.Aca.Agents;

/// <summary>
/// The real <see cref="ISquadCliInvoker"/>: runs
/// <c>pwsh -NoProfile -File scripts/squad-aca.ps1 …</c> and captures both streams.
/// </summary>
/// <remarks>
/// <para>
/// This type is the ONLY part of the library that touches a process, which is
/// precisely why it is behind an interface: every behavioural decision the agent
/// makes is testable without it.
/// </para>
/// <para>
/// stderr is captured but never merged into stdout. Under <c>--json</c> the
/// control plane guarantees stdout carries exactly one document and pushes all
/// pass-through output to stderr, so merging would corrupt the contract, and
/// discarding would repeat the mistake that got an earlier PR closed for
/// swallowing <c>az</c> output.
/// </para>
/// </remarks>
public sealed class SquadCliProcessInvoker : ISquadCliInvoker
{
    private readonly SquadAgentOptions _options;
    private readonly string _cliPath;

    /// <summary>Creates the invoker and resolves the control-plane script eagerly.</summary>
    /// <param name="options">Invocation options.</param>
    /// <exception cref="SquadAgentException">The control plane could not be located.</exception>
    public SquadCliProcessInvoker(SquadAgentOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _cliPath = SquadCliLocator.Resolve(options);
    }

    /// <summary>The resolved path to the control-plane script.</summary>
    public string CliPath => _cliPath;

    /// <inheritdoc/>
    public async Task<SquadCliResult> InvokeAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(arguments);

        var startInfo = new ProcessStartInfo
        {
            FileName = _options.PowerShellPath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = _options.WorkingDirectory ?? Directory.GetCurrentDirectory(),
        };

        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(_cliPath);
        foreach (string argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                stdout.AppendLine(e.Data);
            }
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                stderr.AppendLine(e.Data);
            }
        };

        try
        {
            process.Start();
        }
        catch (Exception ex)
        {
            throw new SquadAgentException(
                $"Could not start '{_options.PowerShellPath}' to run the squad-aca control plane.", ex);
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }

        return new SquadCliResult(process.ExitCode, stdout.ToString(), stderr.ToString());
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            // Already gone.
        }
    }
}
