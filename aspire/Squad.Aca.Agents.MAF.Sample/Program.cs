using System.Diagnostics;
using System.Globalization;
using Microsoft.Agents.AI;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Squad.Aca.Agents;
using Squad.Aca.Agents.MAF;
using Squad.Aca.Agents.MAF.Sample;

// -----------------------------------------------------------------------------
// squad-aca-maf-sample
// -----------------------------------------------------------------------------
// A real Microsoft Agent Framework host: build a generic host, register Squad on
// ACA with AddSquadAcaAgent(), resolve the base AIAgent from DI, call it, and
// print what came back.
//
// Resolving the BASE AIAgent is the point of the sample rather than an aesthetic
// choice. A MAF pipeline holds AIAgent; if this host resolved SquadAcaAIAgent it
// would prove the concrete type works and say nothing about whether a pipeline
// that has never heard of Squad can drive it.
//
// NOTHING PRINTED HERE CAN CARRY A TOKEN. This process reads no credential --
// `gh` and `az` supply authentication to the control plane, not to this host --
// and every line it writes goes through SecretRedactor first, including the
// control-plane stderr it relays. Redaction at the print site is the only place
// it can be applied, because the text being relayed was never ours.
// -----------------------------------------------------------------------------

SampleOptions? options;
try
{
    options = SampleOptions.Parse(args);
}
catch (SampleUsageException ex)
{
    Report.Error(ex.Message);
    Report.Line(SampleOptions.Usage);
    return 2;
}

if (options is null)
{
    Report.Line(SampleOptions.Usage);
    return 0;
}

HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);

// The inner contract. It is registered as ISquadAgent rather than constructed
// inline so the wiring below is the one a real host would copy: AddSquadAcaAgent()
// resolves ISquadAgent from the container.
builder.Services.AddSingleton<ISquadAgent>(_ => AcaSquadAgent.CreateDefault(new SquadAgentOptions
{
    CliPath = options.CliPath,
    WorkingDirectory = options.WorkingDirectory,
    DiagnosticSink = options.Quiet ? null : Report.Diagnostic,
}));

builder.Services.AddSquadAcaAgent(agent =>
{
    agent.DefaultRepository = options.Repository;
    agent.DefaultRef = options.Ref;
    agent.DefaultPushChanges = options.PushChanges;
    agent.DefaultLongRunMode = options.Mode;
    agent.RunTimeout = options.Timeout;
    agent.InitialPollInterval = options.PollInterval;
    agent.DiagnosticSink = options.Quiet ? null : Report.Diagnostic;
});

using IHost host = builder.Build();
AIAgent squad = host.Services.GetRequiredService<AIAgent>();

Report.Line($"agent      : {squad.Name} ({squad.Id})");
Report.Line($"repository : {options.Repository}");
Report.Line($"ref        : {options.Ref}");
Report.Line($"push       : {options.PushChanges}");
Report.Line($"mode       : {options.Mode}");
Report.Line($"timeout    : {options.Timeout}");
if (options.CancelAfter is TimeSpan cancelAfter)
{
    Report.Line($"cancel-after: {cancelAfter}");
}

Report.Line($"prompt     : {options.Prompt}");
Report.Line(string.Empty);

var runOptions = new SquadAcaAgentRunOptions
{
    Repository = options.Repository,
    Ref = options.Ref,
    OutputBranch = options.OutputBranch,
    SessionName = options.SessionName,
    SubSquad = options.SubSquad,
    PushChanges = options.PushChanges,
    LongRunMode = options.Mode,
    RunTimeout = options.Timeout,
};

// The cancellation source is the sample's, not the framework's: cancelling it is
// how a caller walking away is simulated, and the adapter's job is to stop the
// ACA session rather than leave it billing.
using var cancellation = new CancellationTokenSource();
if (options.CancelAfter is TimeSpan delay)
{
    cancellation.CancelAfter(delay);
}

var stopwatch = Stopwatch.StartNew();
try
{
    AgentSession session = await squad.CreateSessionAsync(cancellation.Token).ConfigureAwait(false);

    if (options.Stream)
    {
        await foreach (AgentResponseUpdate update in squad
            .RunStreamingAsync(options.Prompt, session, runOptions, cancellation.Token)
            .ConfigureAwait(false))
        {
            Report.Line($"[{stopwatch.Elapsed:hh\\:mm\\:ss}] {update.Text}");
        }

        stopwatch.Stop();
        Report.Line(string.Empty);
        Report.Line($"elapsed    : {stopwatch.Elapsed}");
        return 0;
    }

    AgentResponse response = await squad
        .RunAsync(options.Prompt, session, runOptions, cancellation.Token)
        .ConfigureAwait(false);
    stopwatch.Stop();

    Report.Line(response.Text);
    Report.Line(string.Empty);
    Report.Properties(response.AdditionalProperties);
    Report.Line($"elapsed    : {stopwatch.Elapsed}");

    // DispatchOnly hands the handle back on MAF's own continuation token. Saying
    // so here is the difference between a sample that demonstrates the protocol
    // and one that quietly drops the only thing the caller needed to poll with.
    if (SquadBackgroundResponse.GetContinuationToken(response) is not null)
    {
        Report.Line("continuation: attached — pass it back on AgentRunOptions.ContinuationToken to poll.");
    }

    return 0;
}
catch (SquadRouteFailedClosedException ex)
{
    // Never flattened into a generic failure. The resolver's reason is the whole
    // actionable content of a refusal, and it survives the adapter unchanged.
    stopwatch.Stop();
    Report.Error("FAIL-CLOSED — capability routing refused this session. Nothing was started.");
    Report.Error($"  reason       : {ex.Reason ?? "(not reported)"}");
    Report.Error($"  sandboxClass : {ex.SandboxClass ?? "(none)"}");
    Report.Error($"  exitCode     : {ex.ExitCode.ToString(CultureInfo.InvariantCulture)}");
    Report.Error($"  message      : {ex.Message}");
    Report.Error($"  elapsed      : {stopwatch.Elapsed}");
    return 3;
}
catch (SquadAgentRunTimeoutException ex)
{
    stopwatch.Stop();
    Report.Error($"TIMED OUT after {ex.Elapsed}. Last observed status: {ex.LastStatus}.");
    Report.Error($"  session      : {ex.SessionName}");
    Report.Error($"  handle       : {ex.Handle.Value}");
    Report.Error($"  stopRequested: {ex.SessionCancelled}");
    return 4;
}
catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
{
    // The adapter has already issued the stop, on a fresh token, before the
    // exception reached here. Say what to go and verify rather than claiming it.
    stopwatch.Stop();
    Report.Error($"CANCELLED after {stopwatch.Elapsed}.");
    Report.Error("The adapter issued a stop for the session before rethrowing; confirm with " +
        "'squad-aca sessions --session <handle>'.");
    return 5;
}
catch (SquadAgentException ex)
{
    stopwatch.Stop();
    Report.Error($"FAILED after {stopwatch.Elapsed}: {ex.Message}");
    return 1;
}

/// <summary>
/// The only writer in this host, so redaction cannot be forgotten at a call site.
/// </summary>
internal static class Report
{
    /// <summary>Writes one redacted line to stdout.</summary>
    /// <param name="text">Text to write.</param>
    public static void Line(string text) => Console.Out.WriteLine(SecretRedactor.Redact(text));

    /// <summary>Writes one redacted line to stderr.</summary>
    /// <param name="text">Text to write.</param>
    public static void Error(string text) => Console.Error.WriteLine(SecretRedactor.Redact(text));

    /// <summary>Relays a control-plane diagnostic, marked as such.</summary>
    /// <param name="text">The (already redacted) diagnostic line.</param>
    public static void Diagnostic(string text) => Error($"  [squad-aca] {SecretRedactor.Redact(text)}");

    /// <summary>Prints the structured result a program would read.</summary>
    /// <param name="properties">The response's additional properties.</param>
    public static void Properties(IDictionary<string, object?>? properties)
    {
        if (properties is null || properties.Count == 0)
        {
            return;
        }

        // Text is for humans; this dictionary is the machine-readable half of the
        // response, and a sample that only printed the text would leave a reader
        // believing the route and handle were unavailable.
        foreach (KeyValuePair<string, object?> entry in properties.OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            Line($"  {entry.Key,-22} = {entry.Value ?? "(null)"}");
        }

        Line(string.Empty);
    }
}
