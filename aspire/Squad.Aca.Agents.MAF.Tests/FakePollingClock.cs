namespace Squad.Aca.Agents.MAF.Tests;

/// <summary>
/// A virtual clock: every wait is recorded, advances the clock by exactly the
/// requested amount, and returns immediately.
/// </summary>
/// <remarks>
/// This is what makes the 90-minute timeout, the backoff curve and the
/// deadline clamp testable at all. Shrinking the real timeouts until a test can
/// afford to wait would prove the loop terminates and nothing about whether it
/// waited the right amount — which is the only property a rate limit cares
/// about.
/// </remarks>
internal sealed class FakePollingClock : ISquadPollingClock
{
    public FakePollingClock(DateTimeOffset? start = null) =>
        UtcNow = start ?? new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.Zero);

    public DateTimeOffset UtcNow { get; private set; }

    /// <summary>Every wait the polling loop asked for, in order.</summary>
    public List<TimeSpan> Delays { get; } = [];

    /// <summary>Invoked with the 1-based wait number, before cancellation is observed.</summary>
    public Action<int>? OnDelay { get; set; }

    public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken)
    {
        // A correct polling loop never asks to wait for nothing. `interval` is
        // validated positive and `remaining` is checked positive before the
        // clamp, so a non-positive wait means the deadline arithmetic broke --
        // and left unguarded it presents as an infinite zero-length spin against
        // a real control plane, which is a rate limit, not a test failure.
        if (duration <= TimeSpan.Zero)
        {
            throw new InvalidOperationException(
                $"The polling loop asked to wait {duration}, which a bounded run should never do. " +
                $"This is wait #{Delays.Count + 1}.");
        }

        Delays.Add(duration);
        UtcNow += duration;
        OnDelay?.Invoke(Delays.Count);

        // Observed AFTER the clock advances, so a test that cancels from OnDelay
        // reproduces "the caller cancelled while we were waiting" rather than
        // "the caller cancelled before we started".
        if (cancellationToken.IsCancellationRequested)
        {
            return Task.FromCanceled(cancellationToken);
        }

        return Task.CompletedTask;
    }
}
