namespace Squad.Aca.Agents.MAF;

/// <summary>
/// The clock and delay source the polling loop runs on.
/// </summary>
/// <remarks>
/// <para>
/// Two things are behind this seam and both matter. <see cref="UtcNow"/> is what
/// the timeout deadline is measured against, and <see cref="DelayAsync"/> is
/// what the backoff schedule is spent on. A fake supplies a virtual clock that
/// advances by exactly the requested duration and returns immediately, so the
/// 90-minute timeout, the backoff curve and the cancellation-mid-wait path are
/// all covered deterministically in milliseconds.
/// </para>
/// <para>
/// The alternative — shrinking the timeouts in tests until real waits are
/// tolerable — proves the loop terminates but never proves it waited the right
/// amount, which is the part a rate limit cares about.
/// </para>
/// </remarks>
public interface ISquadPollingClock
{
    /// <summary>Current UTC time.</summary>
    DateTimeOffset UtcNow { get; }

    /// <summary>Waits for the given duration.</summary>
    /// <param name="duration">How long to wait.</param>
    /// <param name="cancellationToken">Cancels the wait.</param>
    /// <returns>A task that completes when the wait elapses.</returns>
    Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken);
}

/// <summary>
/// <see cref="ISquadPollingClock"/> over the real system clock.
/// </summary>
public sealed class SystemPollingClock : ISquadPollingClock
{
    /// <summary>The shared instance.</summary>
    public static SystemPollingClock Instance { get; } = new();

    private SystemPollingClock()
    {
    }

    /// <inheritdoc/>
    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;

    /// <inheritdoc/>
    public Task DelayAsync(TimeSpan duration, CancellationToken cancellationToken) =>
        Task.Delay(duration, cancellationToken);
}
