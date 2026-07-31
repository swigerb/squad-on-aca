using Squad.Aca.Agents;

namespace Squad.Aca.Agents.MAF.Tests;

/// <summary>
/// A scriptable <see cref="ISquadAgent"/>. No Azure, no PowerShell, no network.
/// </summary>
/// <remarks>
/// It records more than the calls: for every <see cref="CancelSessionAsync"/> it
/// also records whether the token it was handed was ALREADY CANCELLED. That is
/// not bookkeeping — "a cancelled MAF call stops the session instead of orphaning
/// it" is exactly the claim that a stop issued on the caller's own cancelled
/// token would fail, and nothing else observable can tell a real stop from one
/// that aborted on its first await.
/// </remarks>
internal sealed class FakeSquadAgent : ISquadAgent
{
    private readonly Queue<SquadSessionStatus> _statuses = new();

    /// <summary>Result returned by <see cref="RunSessionAsync"/> when no exception is set.</summary>
    public SquadSessionResult? DispatchResult { get; set; }

    /// <summary>Exception thrown by <see cref="RunSessionAsync"/> instead of dispatching.</summary>
    public Exception? DispatchException { get; set; }

    /// <summary>Exception thrown by <see cref="CancelSessionAsync"/>.</summary>
    public Exception? CancelException { get; set; }

    /// <summary>Status returned once the scripted queue is exhausted.</summary>
    public SquadSessionStatus? RepeatingStatus { get; set; }

    /// <summary>Invoked before each <see cref="GetSessionStatusAsync"/> returns.</summary>
    public Action<int>? OnStatusRead { get; set; }

    /// <summary>Every dispatch request, in order.</summary>
    public List<SquadSessionRequest> DispatchRequests { get; } = [];

    /// <summary>Every handle passed to <see cref="GetSessionStatusAsync"/>, in order.</summary>
    public List<string> StatusReads { get; } = [];

    /// <summary>Every stop, with the state of the token it was given.</summary>
    public List<StopCall> StopCalls { get; } = [];

    public FakeSquadAgent Enqueue(params SquadSessionStatus[] statuses)
    {
        foreach (SquadSessionStatus status in statuses)
        {
            _statuses.Enqueue(status);
        }

        return this;
    }

    public Task<SquadSessionResult> RunSessionAsync(
        SquadSessionRequest request,
        CancellationToken cancellationToken = default)
    {
        DispatchRequests.Add(request);
        if (DispatchException is not null)
        {
            return Task.FromException<SquadSessionResult>(DispatchException);
        }

        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(
            DispatchResult ?? throw new InvalidOperationException("FakeSquadAgent has no DispatchResult."));
    }

    public Task<SquadSessionStatus> GetSessionStatusAsync(
        SquadExecutionHandle handle,
        CancellationToken cancellationToken = default)
    {
        StatusReads.Add(handle.Value);
        OnStatusRead?.Invoke(StatusReads.Count);
        cancellationToken.ThrowIfCancellationRequested();

        if (_statuses.Count > 0)
        {
            return Task.FromResult(_statuses.Dequeue());
        }

        return Task.FromResult(
            RepeatingStatus ?? throw new InvalidOperationException(
                "FakeSquadAgent ran out of scripted statuses and has no RepeatingStatus; " +
                "the adapter polled more times than the test expected."));
    }

    public Task CancelSessionAsync(SquadExecutionHandle handle, CancellationToken cancellationToken = default)
    {
        StopCalls.Add(new StopCall(handle.Value, cancellationToken.IsCancellationRequested));
        if (CancelException is not null)
        {
            return Task.FromException(CancelException);
        }

        return Task.CompletedTask;
    }

    internal sealed record StopCall(string Handle, bool TokenAlreadyCancelled);
}
