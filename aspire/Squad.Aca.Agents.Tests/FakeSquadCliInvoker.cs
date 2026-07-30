using Squad.Aca.Agents;

namespace Squad.Aca.Agents.Tests;

/// <summary>
/// Records every invocation and replays canned control-plane output.
/// </summary>
/// <remarks>
/// Recording the argument list is not incidental: several tests assert on the
/// EXACT argv, because "addresses the handle and does not re-resolve the route"
/// is a statement about which arguments are sent, and nothing else can observe
/// it from outside the process.
/// </remarks>
internal sealed class FakeSquadCliInvoker : ISquadCliInvoker
{
    private readonly Queue<SquadCliResult> _responses = new();

    public FakeSquadCliInvoker(params SquadCliResult[] responses)
    {
        foreach (SquadCliResult response in responses)
        {
            _responses.Enqueue(response);
        }
    }

    /// <summary>Every argument list this invoker was called with, in order.</summary>
    public List<IReadOnlyList<string>> Invocations { get; } = [];

    /// <summary>The argument list of the single (or first) invocation.</summary>
    public IReadOnlyList<string> LastArguments => Invocations[^1];

    public Task<SquadCliResult> InvokeAsync(
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken = default)
    {
        Invocations.Add(arguments.ToArray());
        if (_responses.Count == 0)
        {
            throw new InvalidOperationException(
                "FakeSquadCliInvoker ran out of canned responses; the agent invoked the CLI more times than the test expected.");
        }

        return Task.FromResult(_responses.Dequeue());
    }

    public static SquadCliResult Ok(string stdout, string stderr = "") => new(0, stdout, stderr);

    public static SquadCliResult Failed(int exitCode, string stdout = "", string stderr = "") =>
        new(exitCode, stdout, stderr);
}
