using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.DependencyInjection;
using Squad.Aca.Agents;
using Xunit;

namespace Squad.Aca.Agents.MAF.Tests;

/// <summary>
/// Contract tests for the Agent Framework adapter. Everything is offline: the
/// only seam is <see cref="ISquadAgent"/>, and the polling loop runs on a virtual
/// clock.
/// </summary>
public class SquadAcaAIAgentTests
{
    private static (SquadAcaAIAgent Agent, FakeSquadAgent Inner, FakePollingClock Clock) Build(
        Action<SquadAcaAgentOptions>? configure = null,
        FakeSquadAgent? inner = null)
    {
        FakeSquadAgent squad = inner ?? new FakeSquadAgent();
        var clock = new FakePollingClock();
        var options = new SquadAcaAgentOptions
        {
            DefaultRepository = "octo/demo",
            PollingClock = clock,
        };

        configure?.Invoke(options);
        return (new SquadAcaAIAgent(squad, options), squad, clock);
    }

    private static string? Prop(AgentResponse response, string key) =>
        response.AdditionalProperties?.TryGetValue(key, out object? value) == true ? value?.ToString() : null;

    // -----------------------------------------------------------------------
    // 1. A successful dispatch surfaces route, handle and sandbox class.
    // -----------------------------------------------------------------------

    [Fact]
    public async Task SandboxDispatch_SurfacesRouteHandleAndSandboxClassThroughTheMafResponse()
    {
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.SandboxDispatch(fallbackReason: "sandbox-feature-disabled"),
        };
        inner.Enqueue(Fixtures.Status(
            "Succeeded",
            sessionName: "sbx-session",
            handle: Fixtures.SandboxHandle,
            route: "sandbox",
            mode: SquadExecutionMode.Sandbox,
            sandboxClass: "sandbox-python-3-12",
            phase: "completed",
            exitCode: 0));

        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        AgentResponse response = await agent.RunAsync("ship the thing");

        Assert.Equal("sandbox", Prop(response, "squad.route"));
        Assert.Equal(Fixtures.SandboxHandle, Prop(response, "squad.handle"));
        Assert.Equal("sandbox-python-3-12", Prop(response, "squad.sandboxClass"));
        Assert.Equal("sandbox-feature-disabled", Prop(response, "squad.fallbackReason"));
        Assert.Equal("Sandbox", Prop(response, "squad.executionMode"));
        Assert.Equal("Succeeded", Prop(response, "squad.status"));
        Assert.Equal("completed", Prop(response, "squad.phase"));
        Assert.Equal("0", Prop(response, "squad.exitCode"));
        Assert.Equal("True", Prop(response, "squad.terminal"));
        Assert.Equal("sbx-session", response.ResponseId);
        Assert.Equal(ChatFinishReason.Stop, response.FinishReason);
        Assert.Contains("sandbox-python-3-12", response.Text, StringComparison.Ordinal);
        Assert.Contains(Fixtures.SandboxHandle, response.Text, StringComparison.Ordinal);
        Assert.IsType<SquadSessionStatus>(response.RawRepresentation);
    }

    [Fact]
    public async Task AcaJobDispatch_RunsToCompletionAndReportsTheTerminalStatusAndExitCode()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(
            Fixtures.Status("Running"),
            Fixtures.Status("Succeeded", exitCode: 0));

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        AgentResponse response = await agent.RunAsync("fix the flaky test");

        Assert.Equal("aca-job", Prop(response, "squad.route"));
        Assert.Equal("Succeeded", Prop(response, "squad.status"));
        Assert.Equal("0", Prop(response, "squad.exitCode"));
        Assert.Null(Prop(response, "squad.sandboxClass"));
        Assert.Equal(2, squad.StatusReads.Count);
        Assert.All(squad.StatusReads, handle => Assert.Equal(Fixtures.JobHandle, handle));
        Assert.Empty(squad.StopCalls);
    }

    [Fact]
    public async Task TheDispatchRequestCarriesEveryRunOptionAndTheAgentDefaults()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(Fixtures.Status("Succeeded", exitCode: 0));

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(
            configure: o =>
            {
                o.DefaultRef = "release";
                o.DefaultPushChanges = false;
            },
            inner: inner);

        await agent.RunAsync(
            "do the work",
            options: new SquadAcaAgentRunOptions
            {
                Repository = "octo/other",
                SessionName = "named",
                OutputBranch = "squad/named",
                SubSquad = "backend",
            });

        SquadSessionRequest request = Assert.Single(squad.DispatchRequests);
        Assert.Equal("octo/other", request.Repository);
        Assert.Equal("do the work", request.Prompt);
        Assert.Equal("named", request.SessionName);
        Assert.Equal("release", request.Ref);
        Assert.Equal("squad/named", request.OutputBranch);
        Assert.False(request.PushChanges);
        Assert.Equal("backend", request.SubSquad);
    }

    [Fact]
    public async Task EveryMessageInTheRunContributesToTheSquadPrompt()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(Fixtures.Status("Succeeded", exitCode: 0));
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        await agent.RunAsync(
        [
            new ChatMessage(ChatRole.System, "stay on the branch"),
            new ChatMessage(ChatRole.User, "fix the flaky test"),
        ]);

        Assert.Equal("stay on the branch\nfix the flaky test", squad.DispatchRequests[0].Prompt);
    }

    // -----------------------------------------------------------------------
    // 2. Fail-closed survives the adapter.
    // -----------------------------------------------------------------------

    [Fact]
    public async Task FailClosed_SurvivesAsSquadRouteFailedClosedExceptionWithItsReason()
    {
        var inner = new FakeSquadAgent
        {
            DispatchException = new SquadRouteFailedClosedException(
                "Capability routing failed closed for session 'x'; nothing was dispatched.",
                "sandbox-class-not-approved",
                "gpu-unrestricted",
                1),
        };

        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        SquadRouteFailedClosedException error =
            await Assert.ThrowsAsync<SquadRouteFailedClosedException>(() => agent.RunAsync("ship it"));

        Assert.Equal("sandbox-class-not-approved", error.Reason);
        Assert.Equal("gpu-unrestricted", error.SandboxClass);
        Assert.Equal(1, error.ExitCode);
        Assert.Contains("failed closed", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task FailClosed_SurvivesTheStreamingSurfaceToo()
    {
        var inner = new FakeSquadAgent
        {
            DispatchException = new SquadRouteFailedClosedException(
                "Capability routing failed closed.",
                "capability-resolution-fail-closed",
                null,
                1),
        };

        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        SquadRouteFailedClosedException error = await Assert.ThrowsAsync<SquadRouteFailedClosedException>(
            async () =>
            {
                await foreach (AgentResponseUpdate _ in agent.RunStreamingAsync("ship it"))
                {
                }
            });

        Assert.Equal("capability-resolution-fail-closed", error.Reason);
    }

    [Fact]
    public async Task FailClosed_NeverBecomesAResponseAndNeverStopsAnything()
    {
        var inner = new FakeSquadAgent
        {
            DispatchException = new SquadRouteFailedClosedException("refused", "reason", null, 1),
        };

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        await Assert.ThrowsAsync<SquadRouteFailedClosedException>(() => agent.RunAsync("ship it"));

        // Nothing was started, so nothing may be stopped and nothing may be polled.
        Assert.Empty(squad.StopCalls);
        Assert.Empty(squad.StatusReads);
    }

    [Fact]
    public async Task AnOrdinaryDispatchFailureIsStillItsOwnType()
    {
        var inner = new FakeSquadAgent
        {
            DispatchException = new SquadDispatchFailedException("squad-aca run exited with code 2.", 2),
        };

        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        SquadDispatchFailedException error =
            await Assert.ThrowsAsync<SquadDispatchFailedException>(() => agent.RunAsync("ship it"));
        Assert.Equal(2, error.ExitCode);
    }

    // -----------------------------------------------------------------------
    // 3. Cancellation stops the session.
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Cancellation_WhileWaitingBetweenPolls_StopsTheSession()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.RepeatingStatus = Fixtures.Status("Running");

        (SquadAcaAIAgent agent, FakeSquadAgent squad, FakePollingClock clock) = Build(inner: inner);
        using var cts = new CancellationTokenSource();
        clock.OnDelay = n =>
        {
            if (n == 2)
            {
                cts.Cancel();
            }
        };

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => agent.RunAsync("long job", cancellationToken: cts.Token));

        FakeSquadAgent.StopCall stop = Assert.Single(squad.StopCalls);
        Assert.Equal(Fixtures.JobHandle, stop.Handle);
    }

    [Fact]
    public async Task Cancellation_IssuesTheStopOnAFreshTokenSoItCannotAbortImmediately()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.RepeatingStatus = Fixtures.Status("Running");

        (SquadAcaAIAgent agent, FakeSquadAgent squad, FakePollingClock clock) = Build(inner: inner);
        using var cts = new CancellationTokenSource();
        clock.OnDelay = _ => cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => agent.RunAsync("long job", cancellationToken: cts.Token));

        // The whole anti-orphan mechanism is this: the stop must NOT run on the
        // caller's token. Forwarding it would abort the stop on its first await
        // and leave a billed ACA session running with nobody watching.
        FakeSquadAgent.StopCall stop = Assert.Single(squad.StopCalls);
        Assert.False(stop.TokenAlreadyCancelled);
    }

    [Fact]
    public async Task Cancellation_DuringTheStatusReadAlsoStopsTheSession()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.RepeatingStatus = Fixtures.Status("Running");

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);
        using var cts = new CancellationTokenSource();
        inner.OnStatusRead = _ => cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => agent.RunAsync("long job", cancellationToken: cts.Token));

        FakeSquadAgent.StopCall stop = Assert.Single(squad.StopCalls);
        Assert.Equal(Fixtures.JobHandle, stop.Handle);
        Assert.False(stop.TokenAlreadyCancelled);
    }

    [Fact]
    public async Task Cancellation_OfTheStreamingSurfaceStopsTheSessionToo()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.RepeatingStatus = Fixtures.Status("Running");

        (SquadAcaAIAgent agent, FakeSquadAgent squad, FakePollingClock clock) = Build(inner: inner);
        using var cts = new CancellationTokenSource();
        clock.OnDelay = _ => cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await foreach (AgentResponseUpdate _ in agent.RunStreamingAsync(
                "long job", cancellationToken: cts.Token))
            {
            }
        });

        Assert.Single(squad.StopCalls);
    }

    [Fact]
    public async Task CancellationDuringDispatch_StopsNothingBecauseThereIsNoHandleYet()
    {
        var inner = new FakeSquadAgent
        {
            DispatchException = new OperationCanceledException(),
        };

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => agent.RunAsync("long job", cancellationToken: cts.Token));

        Assert.Empty(squad.StopCalls);
    }

    [Fact]
    public async Task AFailedStopStillLetsTheCancellationSurface()
    {
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(),
            RepeatingStatus = Fixtures.Status("Running"),
            CancelException = new SquadDispatchFailedException("squad-aca stop exited with code 3.", 3),
        };

        (SquadAcaAIAgent agent, FakeSquadAgent squad, FakePollingClock clock) = Build(inner: inner);
        using var cts = new CancellationTokenSource();
        clock.OnDelay = _ => cts.Cancel();

        // The cancellation is the reason the run ended; replacing it with "the
        // stop also failed" would hide that.
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => agent.RunAsync("long job", cancellationToken: cts.Token));
        Assert.Single(squad.StopCalls);
    }

    // -----------------------------------------------------------------------
    // 4. The bounded timeout.
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Timeout_ProducesAClearTerminalErrorCarryingTheHandle()
    {
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(),
            RepeatingStatus = Fixtures.Status("Running"),
        };

        (SquadAcaAIAgent agent, _, _) = Build(o => o.RunTimeout = TimeSpan.FromMinutes(90), inner);

        SquadAgentRunTimeoutException error =
            await Assert.ThrowsAsync<SquadAgentRunTimeoutException>(() => agent.RunAsync("long job"));

        Assert.Equal(Fixtures.JobHandle, error.Handle.Value);
        Assert.Equal("fixedjson", error.SessionName);
        Assert.Equal("Running", error.LastStatus);
        Assert.True(error.Elapsed >= TimeSpan.FromMinutes(90));
        Assert.Contains("did not reach a terminal state", error.Message, StringComparison.Ordinal);
        Assert.Contains(Fixtures.JobHandle, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Timeout_StopsTheSessionByDefault()
    {
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(),
            RepeatingStatus = Fixtures.Status("Running"),
        };

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(o => o.RunTimeout = TimeSpan.FromMinutes(5), inner);

        SquadAgentRunTimeoutException error =
            await Assert.ThrowsAsync<SquadAgentRunTimeoutException>(() => agent.RunAsync("long job"));

        FakeSquadAgent.StopCall stop = Assert.Single(squad.StopCalls);
        Assert.Equal(Fixtures.JobHandle, stop.Handle);
        Assert.False(stop.TokenAlreadyCancelled);
        Assert.True(error.SessionCancelled);
    }

    [Fact]
    public async Task Timeout_LeavesTheSessionRunningWhenTheCallerOptedOut()
    {
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(),
            RepeatingStatus = Fixtures.Status("Running"),
        };

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(
            o =>
            {
                o.RunTimeout = TimeSpan.FromMinutes(5);
                o.CancelSessionOnTimeout = false;
            },
            inner);

        SquadAgentRunTimeoutException error =
            await Assert.ThrowsAsync<SquadAgentRunTimeoutException>(() => agent.RunAsync("long job"));

        Assert.Empty(squad.StopCalls);
        Assert.False(error.SessionCancelled);
        Assert.Contains("left running", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Timeout_ReportsThatTheStopFailedRatherThanClaimingTheSessionWasCancelled()
    {
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(),
            RepeatingStatus = Fixtures.Status("Running"),
            CancelException = new SquadDispatchFailedException("stop failed", 3),
        };

        (SquadAcaAIAgent agent, _, _) = Build(o => o.RunTimeout = TimeSpan.FromMinutes(5), inner);

        SquadAgentRunTimeoutException error =
            await Assert.ThrowsAsync<SquadAgentRunTimeoutException>(() => agent.RunAsync("long job"));

        Assert.False(error.SessionCancelled);
        Assert.Contains("may still be running", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ARunOptionsTimeoutOverridesTheAgentDefault()
    {
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(),
            RepeatingStatus = Fixtures.Status("Running"),
        };

        (SquadAcaAIAgent agent, _, FakePollingClock clock) = Build(
            o => o.RunTimeout = TimeSpan.FromHours(10), inner);

        SquadAgentRunTimeoutException error = await Assert.ThrowsAsync<SquadAgentRunTimeoutException>(
            () => agent.RunAsync(
                "long job",
                options: new SquadAcaAgentRunOptions { RunTimeout = TimeSpan.FromMinutes(2) }));

        Assert.True(error.Elapsed < TimeSpan.FromMinutes(3));
        Assert.True(clock.Delays.Sum(d => d.Ticks) <= TimeSpan.FromMinutes(2).Ticks);
    }

    // -----------------------------------------------------------------------
    // 5. The polling schedule.
    // -----------------------------------------------------------------------

    [Fact]
    public async Task PollingBacksOffAndIsCappedAtTheMaximumInterval()
    {
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(),
            RepeatingStatus = Fixtures.Status("Running"),
        };

        (SquadAcaAIAgent agent, _, FakePollingClock clock) = Build(o => o.RunTimeout = TimeSpan.FromHours(1), inner);

        await Assert.ThrowsAsync<SquadAgentRunTimeoutException>(() => agent.RunAsync("long job"));

        Assert.Equal(TimeSpan.FromSeconds(5), clock.Delays[0]);
        Assert.Equal(TimeSpan.FromSeconds(7.5), clock.Delays[1]);
        Assert.Equal(TimeSpan.FromSeconds(11.25), clock.Delays[2]);

        // Non-decreasing, and never past the ceiling: that ceiling is what keeps a
        // waiting run to at most 60 ARM reads an hour.
        for (int i = 1; i < clock.Delays.Count; i++)
        {
            Assert.True(clock.Delays[i] >= clock.Delays[i - 1] || clock.Delays[i] == clock.Delays[^1]);
        }

        Assert.All(clock.Delays, d => Assert.True(d <= TimeSpan.FromSeconds(60)));
        Assert.Contains(clock.Delays, d => d == TimeSpan.FromSeconds(60));

        // An hour of waiting at a 60-second ceiling cannot exceed ~60 reads plus
        // the ramp. A regression that stopped backing off would blow past this.
        Assert.True(clock.Delays.Count < 70, $"polled {clock.Delays.Count} times in an hour");
    }

    [Fact]
    public async Task TheLastWaitIsClampedSoItLandsOnTheDeadlineInsteadOfOvershootingIt()
    {
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(),
            RepeatingStatus = Fixtures.Status("Running"),
        };

        (SquadAcaAIAgent agent, _, FakePollingClock clock) = Build(
            o =>
            {
                o.RunTimeout = TimeSpan.FromSeconds(8);
                o.InitialPollInterval = TimeSpan.FromSeconds(5);
                o.PollBackoffFactor = 1.0;
            },
            inner);

        await Assert.ThrowsAsync<SquadAgentRunTimeoutException>(() => agent.RunAsync("long job"));

        Assert.Equal([TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(3)], clock.Delays);
    }

    [Fact]
    public async Task TheFirstPollHappensAfterAWaitSoAJustDispatchedSessionIsNotReadImmediately()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(Fixtures.Status("Succeeded", exitCode: 0));

        (SquadAcaAIAgent agent, FakeSquadAgent squad, FakePollingClock clock) = Build(inner: inner);

        await agent.RunAsync("fix it");

        Assert.Single(squad.StatusReads);
        Assert.Single(clock.Delays);
    }

    [Theory]
    [InlineData("Provisioning")]
    [InlineData("Running")]
    [InlineData("Unknown")]
    public async Task ANonTerminalStateKeepsThePollingLoopGoing(string state)
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(Fixtures.Status(state), Fixtures.Status("Succeeded", exitCode: 0));

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);
        AgentResponse response = await agent.RunAsync("fix it");

        Assert.Equal("Succeeded", Prop(response, "squad.status"));
        Assert.Equal(2, squad.StatusReads.Count);
    }

    [Theory]
    [InlineData("Succeeded")]
    [InlineData("Failed")]
    [InlineData("TimedOut")]
    [InlineData("Cancelled")]
    public async Task EveryTerminalStateEndsTheRun(string state)
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(Fixtures.Status(state));

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);
        AgentResponse response = await agent.RunAsync("fix it");

        Assert.Equal(state, Prop(response, "squad.status"));
        Assert.Single(squad.StatusReads);
        Assert.Equal(ChatFinishReason.Stop, response.FinishReason);
    }

    // -----------------------------------------------------------------------
    // 6. Fire-and-forget, and MAF's own background-response protocol.
    // -----------------------------------------------------------------------

    [Fact]
    public async Task DispatchOnly_ReturnsImmediatelyWithAContinuationTokenAndNeverPolls()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, FakeSquadAgent squad, FakePollingClock clock) = Build(inner: inner);

        AgentResponse response = await agent.RunAsync(
            "long job",
            options: new SquadAcaAgentRunOptions { LongRunMode = SquadLongRunMode.DispatchOnly });

        Assert.Empty(squad.StatusReads);
        Assert.Empty(clock.Delays);
        Assert.NotNull(SquadBackgroundResponse.GetContinuationToken(response));
        Assert.Equal("False", Prop(response, "squad.terminal"));
        Assert.Equal(Fixtures.JobHandle, Prop(response, "squad.handle"));
        Assert.Null(response.FinishReason);
        Assert.Contains("continuation token", response.Text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AllowBackgroundResponses_SelectsDispatchOnlyEvenWithoutSquadTypedOptions()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        AgentResponse response = await agent.RunAsync(
            "long job",
            options: new AgentRunOptions { AllowBackgroundResponses = true });

        Assert.Empty(squad.StatusReads);
        Assert.NotNull(SquadBackgroundResponse.GetContinuationToken(response));
    }

    [Fact]
    public async Task RunToCompletionIsTheDefaultWhenNothingAsksForABackgroundResponse()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(Fixtures.Status("Succeeded", exitCode: 0));

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);
        AgentResponse response = await agent.RunAsync("long job");

        Assert.NotEmpty(squad.StatusReads);
        Assert.Null(SquadBackgroundResponse.GetContinuationToken(response));
        Assert.Equal("Succeeded", Prop(response, "squad.status"));
    }

    [Fact]
    public async Task AnExplicitLongRunModeOutranksAllowBackgroundResponses()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(Fixtures.Status("Succeeded", exitCode: 0));

        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        AgentResponse response = await agent.RunAsync(
            "long job",
            options: new SquadAcaAgentRunOptions
            {
                AllowBackgroundResponses = true,
                LongRunMode = SquadLongRunMode.RunToCompletion,
            });

        Assert.NotEmpty(squad.StatusReads);
        Assert.Null(SquadBackgroundResponse.GetContinuationToken(response));
    }

    [Fact]
    public async Task TheAgentDefaultCanBeFlippedToDispatchOnlyForAWholeHost()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(
            o => o.DefaultLongRunMode = SquadLongRunMode.DispatchOnly, inner);

        AgentResponse response = await agent.RunAsync("long job");

        Assert.Empty(squad.StatusReads);
        Assert.NotNull(SquadBackgroundResponse.GetContinuationToken(response));
    }

    [Fact]
    public async Task AContinuationTokenPollsOnceAndComesBackWhileTheSessionIsUnfinished()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, FakeSquadAgent squad, FakePollingClock clock) = Build(inner: inner);

        AgentResponse dispatched = await agent.RunAsync(
            "long job",
            options: new SquadAcaAgentRunOptions { LongRunMode = SquadLongRunMode.DispatchOnly });

        inner.Enqueue(Fixtures.Status("Running"));
        var poll = new AgentRunOptions();
        SquadBackgroundResponse.WithContinuationToken(
            poll, SquadBackgroundResponse.GetContinuationToken(dispatched));

        AgentResponse polled = await agent.RunAsync("ignored", options: poll);

        Assert.Single(squad.StatusReads);
        Assert.Empty(clock.Delays);
        Assert.Single(squad.DispatchRequests);
        Assert.Equal("Running", Prop(polled, "squad.status"));
        Assert.Equal("False", Prop(polled, "squad.terminal"));
        Assert.NotNull(SquadBackgroundResponse.GetContinuationToken(polled));
        Assert.Null(polled.FinishReason);
    }

    [Fact]
    public async Task AContinuationTokenIsDroppedOnceTheSessionIsTerminal()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        AgentResponse dispatched = await agent.RunAsync(
            "long job",
            options: new SquadAcaAgentRunOptions { LongRunMode = SquadLongRunMode.DispatchOnly });

        inner.Enqueue(Fixtures.Status("Succeeded", exitCode: 0));
        var poll = new AgentRunOptions();
        SquadBackgroundResponse.WithContinuationToken(
            poll, SquadBackgroundResponse.GetContinuationToken(dispatched));

        AgentResponse polled = await agent.RunAsync("ignored", options: poll);

        Assert.Equal("True", Prop(polled, "squad.terminal"));
        Assert.Null(SquadBackgroundResponse.GetContinuationToken(polled));
        Assert.Equal(ChatFinishReason.Stop, polled.FinishReason);
    }

    [Fact]
    public async Task AContinuationTokenAlsoResumesTheStreamingSurface()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        AgentResponse dispatched = await agent.RunAsync(
            "long job",
            options: new SquadAcaAgentRunOptions { LongRunMode = SquadLongRunMode.DispatchOnly });

        inner.Enqueue(Fixtures.Status("Running"));
        var poll = new AgentRunOptions();
        SquadBackgroundResponse.WithContinuationToken(
            poll, SquadBackgroundResponse.GetContinuationToken(dispatched));

        List<AgentResponseUpdate> updates = [];
        await foreach (AgentResponseUpdate update in agent.RunStreamingAsync("ignored", options: poll))
        {
            updates.Add(update);
        }

        Assert.Single(squad.StatusReads);
        Assert.Single(squad.DispatchRequests);
        Assert.NotEmpty(updates);
    }

    [Fact]
    public async Task AContinuationTokenFromSomewhereElseIsRejectedRatherThanPolled()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        var poll = new AgentRunOptions();
        SquadBackgroundResponse.WithContinuationToken(
            poll,
            ResponseContinuationToken.FromBytes("{\"schema\":\"someone-else@1\"}"u8.ToArray()));

        await Assert.ThrowsAsync<SquadContractException>(() => agent.RunAsync("ignored", options: poll));
        Assert.Empty(squad.StatusReads);
    }

    [Fact]
    public async Task AGarbageContinuationTokenIsRejectedRatherThanPolled()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        var poll = new AgentRunOptions();
        SquadBackgroundResponse.WithContinuationToken(
            poll, ResponseContinuationToken.FromBytes("not json at all"u8.ToArray()));

        await Assert.ThrowsAsync<SquadContractException>(() => agent.RunAsync("ignored", options: poll));
        Assert.Empty(squad.StatusReads);
    }

    [Fact]
    public async Task AContinuationTokenWithNoHandleIsRejected()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        var poll = new AgentRunOptions();
        SquadBackgroundResponse.WithContinuationToken(
            poll,
            ResponseContinuationToken.FromBytes(
                "{\"schema\":\"squad-aca/continuation@1\",\"handle\":\"\"}"u8.ToArray()));

        await Assert.ThrowsAsync<SquadContractException>(() => agent.RunAsync("ignored", options: poll));
        Assert.Empty(squad.StatusReads);
    }

    // -----------------------------------------------------------------------
    // 7. Streaming reports real transitions.
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Streaming_EmitsTheDispatchThenEachStatusTransitionThenTheOutcome()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(
            Fixtures.Status("Provisioning"),
            Fixtures.Status("Running"),
            Fixtures.Status("Succeeded", exitCode: 0));

        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        List<string> texts = [];
        await foreach (AgentResponseUpdate update in agent.RunStreamingAsync("fix it"))
        {
            texts.Add(update.Text);
        }

        Assert.Equal(4, texts.Count);
        Assert.Contains("Dispatched", texts[0], StringComparison.Ordinal);
        Assert.Contains("Provisioning", texts[1], StringComparison.Ordinal);
        Assert.Contains("Running", texts[2], StringComparison.Ordinal);
        Assert.Contains("Succeeded", texts[3], StringComparison.Ordinal);

        // Not a final string cut into pieces: concatenating the updates does not
        // reconstruct the last one, because each is its own observation.
        Assert.NotEqual(texts[^1], string.Concat(texts));
    }

    [Fact]
    public async Task Streaming_DoesNotRepeatAStatusThatHasNotChanged()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(
            Fixtures.Status("Running"),
            Fixtures.Status("Running"),
            Fixtures.Status("Running"),
            Fixtures.Status("Succeeded", exitCode: 0));

        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        List<string> texts = [];
        await foreach (AgentResponseUpdate update in agent.RunStreamingAsync("fix it"))
        {
            texts.Add(update.Text);
        }

        // Dispatch, the one transition to Running, and the outcome. Three polls
        // reporting the same thing are not three pieces of progress.
        Assert.Equal(3, texts.Count);
    }

    [Fact]
    public async Task Streaming_OfADispatchOnlyRunEmitsExactlyTheReceipt()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build(inner: inner);

        List<AgentResponseUpdate> updates = [];
        await foreach (AgentResponseUpdate update in agent.RunStreamingAsync(
            "fix it",
            options: new SquadAcaAgentRunOptions { LongRunMode = SquadLongRunMode.DispatchOnly }))
        {
            updates.Add(update);
        }

        AgentResponseUpdate only = Assert.Single(updates);
        Assert.Contains("Dispatched", only.Text, StringComparison.Ordinal);
        Assert.NotNull(SquadBackgroundResponse.GetContinuationToken(only));
        Assert.Empty(squad.StatusReads);
    }

    [Fact]
    public async Task StreamingUpdatesCarryTheSameStructuredPropertiesAsTheResponse()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.SandboxDispatch() };
        inner.Enqueue(Fixtures.Status(
            "Succeeded",
            sessionName: "sbx-session",
            handle: Fixtures.SandboxHandle,
            route: "sandbox",
            mode: SquadExecutionMode.Sandbox,
            sandboxClass: "sandbox-python-3-12",
            exitCode: 0));

        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        List<AgentResponseUpdate> updates = [];
        await foreach (AgentResponseUpdate update in agent.RunStreamingAsync("fix it"))
        {
            updates.Add(update);
        }

        AgentResponseUpdate last = updates[^1];
        Assert.Equal("sandbox", last.AdditionalProperties!["squad.route"]?.ToString());
        Assert.Equal(Fixtures.SandboxHandle, last.AdditionalProperties["squad.handle"]?.ToString());
        Assert.Equal("sandbox-python-3-12", last.AdditionalProperties["squad.sandboxClass"]?.ToString());
        Assert.Equal("squad-on-aca", last.AuthorName);
    }

    // -----------------------------------------------------------------------
    // 8. Input validation, identity and sessions.
    // -----------------------------------------------------------------------

    [Fact]
    public async Task ARunWithNoRepositoryIsRefusedBeforeTheControlPlaneIsInvoked()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        var agent = new SquadAcaAIAgent(inner, new SquadAcaAgentOptions { PollingClock = new FakePollingClock() });

        await Assert.ThrowsAsync<InvalidOperationException>(() => agent.RunAsync("fix it"));
        Assert.Empty(inner.DispatchRequests);
    }

    [Fact]
    public async Task ARunWithNoPromptTextIsRefusedBeforeTheControlPlaneIsInvoked()
    {
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build();

        await Assert.ThrowsAsync<ArgumentException>(() => agent.RunAsync("   "));
        Assert.Empty(squad.DispatchRequests);
    }

    [Fact]
    public void NameAndDescriptionAreSurfacedToTheAgentFramework()
    {
        (SquadAcaAIAgent agent, _, _) = Build();

        Assert.Equal("squad-on-aca", agent.Name);
        Assert.Contains("Azure Container Apps", agent.Description, StringComparison.Ordinal);
        Assert.False(string.IsNullOrWhiteSpace(agent.Id));
    }

    [Fact]
    public void AnExplicitIdIsUsedVerbatimSoAHostCanCorrelateAcrossRestarts()
    {
        (SquadAcaAIAgent agent, _, _) = Build(o => o.Id = "squad-aca-primary");
        Assert.Equal("squad-aca-primary", agent.Id);
    }

    [Fact]
    public void GetServiceExposesTheInnerSquadAgent()
    {
        (SquadAcaAIAgent agent, FakeSquadAgent squad, _) = Build();

        Assert.Same(squad, agent.GetService<ISquadAgent>());
        Assert.Same(squad, agent.InnerAgent);
        Assert.Same(agent, agent.GetService<AIAgent>());
    }

    [Fact]
    public async Task ASessionRecordsTheHandleAndSurvivesSerialization()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        AgentSession session = await agent.CreateSessionAsync();
        await agent.RunAsync(
            "long job",
            session,
            new SquadAcaAgentRunOptions { LongRunMode = SquadLongRunMode.DispatchOnly });

        var typed = Assert.IsType<SquadAcaAgentSession>(session);
        Assert.Equal(Fixtures.JobHandle, typed.LastHandle?.Value);
        Assert.Equal("fixedjson", typed.LastSessionName);

        System.Text.Json.JsonElement serialized = await agent.SerializeSessionAsync(session);
        var restored = Assert.IsType<SquadAcaAgentSession>(await agent.DeserializeSessionAsync(serialized));
        Assert.Equal(Fixtures.JobHandle, restored.LastHandle?.Value);
        Assert.Equal("fixedjson", restored.LastSessionName);
    }

    [Fact]
    public void ANonPositiveTimeoutIsRefusedAtConstructionRatherThanAtDispatch()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new SquadAcaAIAgent(new FakeSquadAgent(), new SquadAcaAgentOptions { RunTimeout = TimeSpan.Zero }));

        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new SquadAcaAIAgent(
                new FakeSquadAgent(),
                new SquadAcaAgentOptions { PollBackoffFactor = 0.5 }));

        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new SquadAcaAIAgent(
                new FakeSquadAgent(),
                new SquadAcaAgentOptions
                {
                    InitialPollInterval = TimeSpan.FromSeconds(30),
                    MaxPollInterval = TimeSpan.FromSeconds(10),
                }));
    }

    [Fact]
    public void RunOptionsCloneCopiesEverySquadField()
    {
        var original = new SquadAcaAgentRunOptions
        {
            Repository = "octo/demo",
            SessionName = "named",
            Ref = "release",
            OutputBranch = "squad/named",
            PushChanges = false,
            SubSquad = "backend",
            LongRunMode = SquadLongRunMode.DispatchOnly,
            RunTimeout = TimeSpan.FromMinutes(7),
        };

        var clone = Assert.IsType<SquadAcaAgentRunOptions>(original.Clone());

        Assert.Equal(original.Repository, clone.Repository);
        Assert.Equal(original.SessionName, clone.SessionName);
        Assert.Equal(original.Ref, clone.Ref);
        Assert.Equal(original.OutputBranch, clone.OutputBranch);
        Assert.Equal(original.PushChanges, clone.PushChanges);
        Assert.Equal(original.SubSquad, clone.SubSquad);
        Assert.Equal(original.LongRunMode, clone.LongRunMode);
        Assert.Equal(original.RunTimeout, clone.RunTimeout);
    }

    // -----------------------------------------------------------------------
    // 9. No token reaches a response, an exception or a log.
    // -----------------------------------------------------------------------

    [Fact]
    public async Task NoTokenReachesTheResponseFromAnyDescriptiveControlPlaneField()
    {
        foreach (string secret in FakeCredentials.All)
        {
            var inner = new FakeSquadAgent
            {
                DispatchResult = Fixtures.SandboxDispatch(sandboxClass: secret, fallbackReason: secret),
            };
            inner.Enqueue(Fixtures.Status(
                "Succeeded",
                sessionName: "sbx-session",
                handle: Fixtures.SandboxHandle,
                route: "sandbox",
                mode: SquadExecutionMode.Sandbox,
                sandboxClass: secret,
                phase: secret,
                exitCode: 0));

            (SquadAcaAIAgent agent, _, _) = Build(inner: inner);
            AgentResponse response = await agent.RunAsync("fix it");

            Assert.DoesNotContain(secret, response.Text, StringComparison.Ordinal);
            foreach (KeyValuePair<string, object?> entry in response.AdditionalProperties!)
            {
                Assert.DoesNotContain(secret, entry.Value?.ToString() ?? string.Empty, StringComparison.Ordinal);
            }
        }
    }

    [Fact]
    public async Task NoTokenReachesAStreamingUpdate()
    {
        string secret = FakeCredentials.GitHubClassic;
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        inner.Enqueue(
            Fixtures.Status($"Running {secret}"),
            Fixtures.Status("Succeeded", exitCode: 0));

        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        await foreach (AgentResponseUpdate update in agent.RunStreamingAsync("fix it"))
        {
            Assert.DoesNotContain(secret, update.Text, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task NoTokenReachesTheTimeoutException()
    {
        string secret = FakeCredentials.OpenAiStyle;
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(),
            RepeatingStatus = Fixtures.Status($"Running {secret}"),
        };

        (SquadAcaAIAgent agent, _, _) = Build(o => o.RunTimeout = TimeSpan.FromMinutes(2), inner);

        SquadAgentRunTimeoutException error =
            await Assert.ThrowsAsync<SquadAgentRunTimeoutException>(() => agent.RunAsync("long job"));

        Assert.DoesNotContain(secret, error.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(secret, error.LastStatus ?? string.Empty, StringComparison.Ordinal);
    }

    [Fact]
    public async Task NoTokenReachesTheDiagnosticSink()
    {
        string secret = FakeCredentials.GitHubFineGrained;
        List<string> lines = [];
        var inner = new FakeSquadAgent
        {
            DispatchResult = Fixtures.AcaJobDispatch(sessionName: $"fixedjson"),
            RepeatingStatus = Fixtures.Status("Running"),
            CancelException = new InvalidOperationException($"stop refused: {secret}"),
        };

        (SquadAcaAIAgent agent, _, _) = Build(
            o =>
            {
                o.RunTimeout = TimeSpan.FromMinutes(2);
                o.DiagnosticSink = lines.Add;
            },
            inner);

        await Assert.ThrowsAsync<SquadAgentRunTimeoutException>(() => agent.RunAsync("long job"));

        Assert.NotEmpty(lines);
        Assert.All(lines, line => Assert.DoesNotContain(secret, line, StringComparison.Ordinal));
        Assert.Contains(lines, line => line.Contains("stop request failed", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TheContinuationTokenCarriesNothingButTheHandleAndSessionName()
    {
        var inner = new FakeSquadAgent { DispatchResult = Fixtures.AcaJobDispatch() };
        (SquadAcaAIAgent agent, _, _) = Build(inner: inner);

        AgentResponse response = await agent.RunAsync(
            $"a prompt mentioning {FakeCredentials.GitHubClassic}",
            options: new SquadAcaAgentRunOptions { LongRunMode = SquadLongRunMode.DispatchOnly });

        ResponseContinuationToken token = SquadBackgroundResponse.GetContinuationToken(response)!;
        string payload = System.Text.Encoding.UTF8.GetString(token.ToBytes().Span);

        Assert.DoesNotContain(FakeCredentials.GitHubClassic, payload, StringComparison.Ordinal);
        Assert.Contains(Fixtures.JobHandle, payload, StringComparison.Ordinal);
    }
}
