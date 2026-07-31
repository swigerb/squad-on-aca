using System.Globalization;

namespace Squad.Aca.Agents.MAF.Sample;

/// <summary>
/// Everything the sample host needs, resolved from command-line arguments and
/// environment variables.
/// </summary>
/// <remarks>
/// <para>
/// NOTHING IS HARD-CODED. A sample with a baked-in repository is a sample that
/// dispatches somebody else's work the first time it is run unmodified, and one
/// with a baked-in prompt cannot demonstrate the thing it exists to demonstrate.
/// Arguments win over environment variables, which is the precedence a CI job
/// (environment) and a human at a terminal (arguments) both expect.
/// </para>
/// <para>
/// NO CREDENTIAL IS READ HERE, deliberately. The control plane owns
/// authentication — <c>gh</c> for GitHub and <c>az</c> for Azure — so this host
/// never sees a token, never places one in an argument vector, and therefore
/// cannot leak one. The one thing it does relay is the control plane's stderr,
/// and that goes through <see cref="SecretRedactor"/> on the way out.
/// </para>
/// </remarks>
internal sealed record SampleOptions
{
    /// <summary>Prefix on every environment variable this sample reads.</summary>
    public const string EnvironmentPrefix = "SQUAD_ACA_SAMPLE_";

    /// <summary>The Squad prompt to dispatch.</summary>
    public required string Prompt { get; init; }

    /// <summary>Target repository, <c>owner/repo</c>.</summary>
    public required string Repository { get; init; }

    /// <summary>Git ref the session starts from.</summary>
    public string Ref { get; init; } = "main";

    /// <summary>Branch the session pushes to, or null for the control plane default.</summary>
    public string? OutputBranch { get; init; }

    /// <summary>Stable session id, or null to let the control plane mint one.</summary>
    public string? SessionName { get; init; }

    /// <summary>SubSquad to activate, or null.</summary>
    public string? SubSquad { get; init; }

    /// <summary>Whether the session pushes its work.</summary>
    public bool PushChanges { get; init; } = true;

    /// <summary>Long-run behaviour for the run.</summary>
    public SquadLongRunMode Mode { get; init; } = SquadLongRunMode.RunToCompletion;

    /// <summary>Use <c>RunStreamingAsync</c> instead of <c>RunAsync</c>.</summary>
    public bool Stream { get; init; }

    /// <summary>Upper bound on a <see cref="SquadLongRunMode.RunToCompletion"/> run.</summary>
    public TimeSpan Timeout { get; init; } = TimeSpan.FromMinutes(90);

    /// <summary>First polling interval.</summary>
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(15);

    /// <summary>
    /// Cancel the run's <see cref="CancellationToken"/> this long after it starts,
    /// or <see langword="null"/> to never cancel.
    /// </summary>
    /// <remarks>
    /// This is not padding. "Cancellation stops the ACA session rather than
    /// orphaning it" is the one adapter claim an offline test can only assert
    /// against a fake, so the sample has to be able to produce a genuinely
    /// cancelled live run for that claim to be checkable against Azure.
    /// </remarks>
    public TimeSpan? CancelAfter { get; init; }

    /// <summary>Explicit path to <c>scripts/squad-aca.ps1</c>, or null to discover it.</summary>
    public string? CliPath { get; init; }

    /// <summary>Working directory for the control-plane process.</summary>
    public string? WorkingDirectory { get; init; }

    /// <summary>Suppress the control plane's relayed diagnostics.</summary>
    public bool Quiet { get; init; }

    /// <summary>Usage text. Printed for <c>--help</c> and for a usage error.</summary>
    public static string Usage =>
        """
        squad-aca-maf-sample — run a Squad session on Azure Container Apps through a
        Microsoft Agent Framework AIAgent.

          dotnet run --project aspire/Squad.Aca.Agents.MAF.Sample -- <prompt> [options]

        Required (argument or environment variable):
          <prompt> | --prompt <text>     SQUAD_ACA_SAMPLE_PROMPT
          --repo <owner/repo>            SQUAD_ACA_SAMPLE_REPOSITORY

        Optional:
          --ref <git-ref>                SQUAD_ACA_SAMPLE_REF                (default: main)
          --branch <name>                SQUAD_ACA_SAMPLE_OUTPUT_BRANCH
          --session <name>               SQUAD_ACA_SAMPLE_SESSION
          --sub-squad <name>             SQUAD_ACA_SAMPLE_SUB_SQUAD
          --no-push                      SQUAD_ACA_SAMPLE_PUSH=false
          --mode <mode>                  SQUAD_ACA_SAMPLE_MODE               run-to-completion (default) | dispatch-only
          --stream                       SQUAD_ACA_SAMPLE_STREAM=true
          --timeout-minutes <n>          SQUAD_ACA_SAMPLE_TIMEOUT_MINUTES    (default: 90)
          --poll-seconds <n>             SQUAD_ACA_SAMPLE_POLL_SECONDS       (default: 15)
          --cancel-after-seconds <n>     SQUAD_ACA_SAMPLE_CANCEL_AFTER_SECONDS
          --cli <path>                   SQUAD_ACA_CLI
          --working-directory <path>     SQUAD_ACA_SAMPLE_WORKING_DIRECTORY
          --quiet                        SQUAD_ACA_SAMPLE_QUIET=true
          --help

        This host reads NO credential. `gh` supplies GitHub auth and `az` supplies
        Azure auth, both to the control plane; nothing printed here can contain a
        token, and everything printed is passed through the redactor regardless.

        Exit codes: 0 ok | 1 error | 2 usage | 3 fail-closed | 4 timeout | 5 cancelled
        """;

    /// <summary>Parses arguments over environment defaults.</summary>
    /// <param name="args">Raw command-line arguments.</param>
    /// <param name="environment">Environment reader; overridable for tests.</param>
    /// <returns>Parsed options, or null when <c>--help</c> was requested.</returns>
    /// <exception cref="SampleUsageException">The invocation cannot be honoured.</exception>
    public static SampleOptions? Parse(string[] args, Func<string, string?>? environment = null)
    {
        ArgumentNullException.ThrowIfNull(args);
        environment ??= Environment.GetEnvironmentVariable;

        string? prompt = Env(environment, "PROMPT");
        string? repository = Env(environment, "REPOSITORY");
        string gitRef = Env(environment, "REF") ?? "main";
        string? outputBranch = Env(environment, "OUTPUT_BRANCH");
        string? sessionName = Env(environment, "SESSION");
        string? subSquad = Env(environment, "SUB_SQUAD");
        bool push = ParseBool(Env(environment, "PUSH")) ?? true;
        SquadLongRunMode mode = ParseMode(Env(environment, "MODE")) ?? SquadLongRunMode.RunToCompletion;
        bool stream = ParseBool(Env(environment, "STREAM")) ?? false;
        bool quiet = ParseBool(Env(environment, "QUIET")) ?? false;
        double timeoutMinutes = ParseNumber(Env(environment, "TIMEOUT_MINUTES"), "SQUAD_ACA_SAMPLE_TIMEOUT_MINUTES") ?? 90;
        double pollSeconds = ParseNumber(Env(environment, "POLL_SECONDS"), "SQUAD_ACA_SAMPLE_POLL_SECONDS") ?? 15;
        double? cancelAfterSeconds = ParseNumber(
            Env(environment, "CANCEL_AFTER_SECONDS"), "SQUAD_ACA_SAMPLE_CANCEL_AFTER_SECONDS");
        string? cliPath = environment(SquadCliLocator.PathEnvironmentVariable);
        string? workingDirectory = Env(environment, "WORKING_DIRECTORY");
        bool promptFromCommandLine = false;

        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            switch (arg)
            {
                case "--help" or "-h" or "-?":
                    return null;
                case "--prompt":
                    prompt = Value(args, ref i);
                    promptFromCommandLine = true;
                    break;
                case "--repo" or "--repository":
                    repository = Value(args, ref i);
                    break;
                case "--ref":
                    gitRef = Value(args, ref i);
                    break;
                case "--branch":
                    outputBranch = Value(args, ref i);
                    break;
                case "--session" or "--name":
                    sessionName = Value(args, ref i);
                    break;
                case "--sub-squad":
                    subSquad = Value(args, ref i);
                    break;
                case "--no-push":
                    push = false;
                    break;
                case "--mode":
                    string raw = Value(args, ref i);
                    mode = ParseMode(raw)
                        ?? throw new SampleUsageException(
                            $"Unknown --mode '{raw}'. Use 'run-to-completion' or 'dispatch-only'.");
                    break;
                case "--stream":
                    stream = true;
                    break;
                case "--quiet":
                    quiet = true;
                    break;
                case "--timeout-minutes":
                    timeoutMinutes = RequireNumber(args, ref i, "--timeout-minutes");
                    break;
                case "--poll-seconds":
                    pollSeconds = RequireNumber(args, ref i, "--poll-seconds");
                    break;
                case "--cancel-after-seconds":
                    cancelAfterSeconds = RequireNumber(args, ref i, "--cancel-after-seconds");
                    break;
                case "--cli":
                    cliPath = Value(args, ref i);
                    break;
                case "--working-directory":
                    workingDirectory = Value(args, ref i);
                    break;
                default:
                    if (arg.StartsWith('-'))
                    {
                        throw new SampleUsageException($"Unknown option '{arg}'.");
                    }

                    // A bare argument is the prompt. The environment default is
                    // REPLACED by the first one rather than appended to, so
                    // `--` plus a prompt does what a reader expects even when
                    // SQUAD_ACA_SAMPLE_PROMPT is exported; further bare
                    // arguments are joined, which is how a shell that split on
                    // whitespace still produces one prompt.
                    prompt = promptFromCommandLine ? $"{prompt}\n{arg}" : arg;
                    promptFromCommandLine = true;
                    break;
            }
        }

        if (string.IsNullOrWhiteSpace(prompt))
        {
            throw new SampleUsageException(
                "No prompt. Pass one as the first argument, as --prompt, or as SQUAD_ACA_SAMPLE_PROMPT.");
        }

        if (string.IsNullOrWhiteSpace(repository))
        {
            // Deliberately not inferred from the working directory. Guessing a
            // repository is how a sample dispatches work to the wrong one.
            throw new SampleUsageException(
                "No repository. Pass --repo <owner/repo> or set SQUAD_ACA_SAMPLE_REPOSITORY.");
        }

        if (timeoutMinutes <= 0)
        {
            throw new SampleUsageException("--timeout-minutes must be greater than zero.");
        }

        if (pollSeconds <= 0)
        {
            throw new SampleUsageException("--poll-seconds must be greater than zero.");
        }

        if (cancelAfterSeconds is <= 0)
        {
            throw new SampleUsageException("--cancel-after-seconds must be greater than zero.");
        }

        return new SampleOptions
        {
            Prompt = prompt.Trim(),
            Repository = repository.Trim(),
            Ref = string.IsNullOrWhiteSpace(gitRef) ? "main" : gitRef.Trim(),
            OutputBranch = Blank(outputBranch),
            SessionName = Blank(sessionName),
            SubSquad = Blank(subSquad),
            PushChanges = push,
            Mode = mode,
            Stream = stream,
            Quiet = quiet,
            Timeout = TimeSpan.FromMinutes(timeoutMinutes),
            PollInterval = TimeSpan.FromSeconds(pollSeconds),
            CancelAfter = cancelAfterSeconds is double seconds ? TimeSpan.FromSeconds(seconds) : null,
            CliPath = Blank(cliPath),
            WorkingDirectory = Blank(workingDirectory),
        };
    }

    private static string? Env(Func<string, string?> environment, string name) =>
        Blank(environment(EnvironmentPrefix + name));

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;

    private static string Value(string[] args, ref int index)
    {
        string name = args[index];
        if (index + 1 >= args.Length)
        {
            throw new SampleUsageException($"Option '{name}' needs a value.");
        }

        return args[++index];
    }

    private static double RequireNumber(string[] args, ref int index, string name)
    {
        string raw = Value(args, ref index);
        return ParseNumber(raw, name)
            ?? throw new SampleUsageException($"Option '{name}' needs a number, got '{raw}'.");
    }

    private static double? ParseNumber(string? raw, string name)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out double value))
        {
            throw new SampleUsageException($"'{name}' needs a number, got '{raw}'.");
        }

        return value;
    }

    private static bool? ParseBool(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        null or "" => null,
        "1" or "true" or "yes" or "on" => true,
        "0" or "false" or "no" or "off" => false,
        _ => null,
    };

    private static SquadLongRunMode? ParseMode(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        null or "" => null,
        "run-to-completion" or "runtocompletion" or "complete" => SquadLongRunMode.RunToCompletion,
        "dispatch-only" or "dispatchonly" or "dispatch" => SquadLongRunMode.DispatchOnly,
        _ => null,
    };
}

/// <summary>The invocation could not be honoured. Reported as exit code 2.</summary>
internal sealed class SampleUsageException(string message) : Exception(message);
