using Xunit;

namespace Squad.Aca.Agents.Tests;

/// <summary>
/// Behavioural tests for <see cref="AcaSquadAgent"/>. Every one runs offline
/// against <see cref="FakeSquadCliInvoker"/>.
/// </summary>
public sealed class AcaSquadAgentTests
{
    private static SquadSessionRequest Request(string? name = "fixedjson") =>
        new("octo/demo", "Build the thing and open a PR", SessionName: name);

    // --- 1. Successful aca-job dispatch --------------------------------------

    [Fact]
    public async Task AcaJobDispatch_MapsEveryContractValue()
    {
        var invoker = new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(CliPayloads.AcaJobRun));
        var agent = new AcaSquadAgent(invoker);

        SquadSessionResult result = await agent.RunSessionAsync(Request());

        Assert.True(result.Dispatched);
        Assert.Equal("fixedjson", result.SessionName);
        Assert.Equal(SquadExecutionRoute.AcaJob, result.Route);
        Assert.Equal(SquadExecutionMode.AcaJob, result.ExecutionMode);
        Assert.Equal("Requested", result.Status);
        Assert.Null(result.SandboxClass);
        Assert.Null(result.FallbackReason);

        // ACA names the execution asynchronously, so a Jobs dispatch has no
        // handle yet; statusPollRef carries the session id and becomes the handle.
        Assert.Equal("fixedjson", result.Handle.Value);
    }

    [Fact]
    public async Task RunSession_RequestsJsonModeAndPassesRequestFields()
    {
        var invoker = new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(CliPayloads.AcaJobRun));
        var agent = new AcaSquadAgent(invoker);

        await agent.RunSessionAsync(new SquadSessionRequest(
            "octo/demo",
            "Build the thing and open a PR",
            SessionName: "fixedjson",
            Ref: "release",
            OutputBranch: "squad/custom",
            PushChanges: false,
            SubSquad: "docs"));

        IReadOnlyList<string> argv = invoker.LastArguments;
        Assert.Equal("run", argv[0]);
        Assert.Equal("Build the thing and open a PR", argv[1]);
        Assert.Contains("--json", argv);
        Assert.Equal("octo/demo", ValueAfter(argv, "--repo"));
        Assert.Equal("fixedjson", ValueAfter(argv, "--name"));
        Assert.Equal("release", ValueAfter(argv, "--ref"));
        Assert.Equal("squad/custom", ValueAfter(argv, "--branch"));
        Assert.Equal("docs", ValueAfter(argv, "--sub-squad"));
        Assert.Contains("--no-push", argv);
    }

    // --- 2. Sandbox dispatch --------------------------------------------------

    [Fact]
    public async Task SandboxDispatch_CarriesRouteSandboxClassAndHandle()
    {
        var invoker = new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(CliPayloads.SandboxRun));
        var agent = new AcaSquadAgent(invoker);

        SquadSessionResult result = await agent.RunSessionAsync(Request("sbx-session"));

        Assert.True(result.Dispatched);
        Assert.Equal(SquadExecutionRoute.Sandbox, result.Route);
        Assert.Equal(SquadExecutionMode.Sandbox, result.ExecutionMode);
        Assert.Equal("net-egress-restricted", result.SandboxClass);
        Assert.Equal("sqx1.SANDBOXHANDLE", result.Handle.Value);
        Assert.Equal("Provisioning", result.Status);
    }

    // --- 3. fail-closed is a FAILURE, with the reason preserved ---------------

    [Fact]
    public async Task FailClosedRoute_ThrowsAndDoesNotLookLikeADispatch()
    {
        // The control plane exits 1 on a fail-closed route, and the whole point
        // of this test is that the caller learns WHY, not merely that something
        // returned non-zero.
        var invoker = new FakeSquadCliInvoker(FakeSquadCliInvoker.Failed(1, CliPayloads.FailClosedRun));
        var agent = new AcaSquadAgent(invoker);

        SquadRouteFailedClosedException error =
            await Assert.ThrowsAsync<SquadRouteFailedClosedException>(() => agent.RunSessionAsync(Request("blocked-session")));

        Assert.Equal("sandbox-class-not-approved", error.Reason);
        Assert.Equal("gpu-unrestricted", error.SandboxClass);
        Assert.Contains("sandbox-class-not-approved", error.Message, StringComparison.Ordinal);
        Assert.Equal(1, error.ExitCode);
    }

    [Fact]
    public async Task FailClosedRoute_ThrowsEvenWhenTheControlPlaneExitsZero()
    {
        // Defence in depth: if the CLI ever reported a fail-closed route with a
        // zero exit code, the route -- not the exit code -- must still decide.
        var invoker = new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(CliPayloads.FailClosedRun));
        var agent = new AcaSquadAgent(invoker);

        SquadRouteFailedClosedException error =
            await Assert.ThrowsAsync<SquadRouteFailedClosedException>(() => agent.RunSessionAsync(Request("blocked-session")));

        Assert.Equal("sandbox-class-not-approved", error.Reason);
    }

    [Fact]
    public async Task NotDispatchedWithoutFailClosed_IsStillAFailure()
    {
        // e.g. a lease conflict: route is fine, but nothing started.
        const string leaseConflict = """
            {
              "schema": "squad-aca/run@1",
              "sessionName": "fixedjson",
              "repository": "octo/demo",
              "ref": "main",
              "outputBranch": "squad/fixedjson",
              "route": "aca-job",
              "routeReason": "capability-resolution-aca-job",
              "executionMode": "aca-job",
              "executionHandle": null,
              "statusPollRef": null,
              "sandboxClass": null,
              "fallbackReason": "lease-active",
              "dispatched": false,
              "status": "not-dispatched"
            }
            """;
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(leaseConflict)));

        SquadDispatchFailedException error =
            await Assert.ThrowsAsync<SquadDispatchFailedException>(() => agent.RunSessionAsync(Request()));

        Assert.Contains("lease-active", error.Message, StringComparison.Ordinal);
    }

    // --- 4. Malformed / empty output fails loudly ----------------------------

    [Fact]
    public async Task MalformedJson_ThrowsContractException()
    {
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok("{ this is not json")));

        SquadContractException error =
            await Assert.ThrowsAsync<SquadContractException>(() => agent.RunSessionAsync(Request()));

        Assert.Contains("unparseable", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task EmptyOutput_ThrowsContractException()
    {
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok("   ")));

        await Assert.ThrowsAsync<SquadContractException>(() => agent.RunSessionAsync(Request()));
    }

    [Fact]
    public async Task WrongSchema_ThrowsContractException()
    {
        const string wrongSchema = """
            { "schema": "squad-aca/run@99", "sessionName": "x", "route": "aca-job",
              "executionMode": "aca-job", "statusPollRef": "x", "dispatched": true, "status": "Requested" }
            """;
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(wrongSchema)));

        SquadContractException error =
            await Assert.ThrowsAsync<SquadContractException>(() => agent.RunSessionAsync(Request()));

        Assert.Contains("squad-aca/run@1", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task MissingDispatchedFlag_ThrowsInsteadOfDefaultingToTrue()
    {
        // A JSON object with no "dispatched" key must not deserialize into a
        // result that claims a dispatch happened.
        const string missingFlag = """
            {
              "schema": "squad-aca/run@1",
              "sessionName": "fixedjson",
              "route": "aca-job",
              "routeReason": "capability-resolution-aca-job",
              "executionMode": "aca-job",
              "statusPollRef": "fixedjson",
              "status": "Requested"
            }
            """;
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(missingFlag)));

        SquadContractException error =
            await Assert.ThrowsAsync<SquadContractException>(() => agent.RunSessionAsync(Request()));

        Assert.Contains("dispatched", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task UnknownRoute_ThrowsInsteadOfSilentlyFallingBack()
    {
        const string unknownRoute = """
            {
              "schema": "squad-aca/run@1",
              "sessionName": "fixedjson",
              "route": "quantum-plane",
              "executionMode": "aca-job",
              "statusPollRef": "fixedjson",
              "dispatched": true,
              "status": "Requested"
            }
            """;
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(unknownRoute)));

        SquadContractException error =
            await Assert.ThrowsAsync<SquadContractException>(() => agent.RunSessionAsync(Request()));

        Assert.Contains("quantum-plane", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task DispatchedWithNoPollReference_ThrowsRatherThanReturningAnUnpollableSession()
    {
        const string noPollRef = """
            {
              "schema": "squad-aca/run@1",
              "sessionName": "fixedjson",
              "route": "aca-job",
              "executionMode": "aca-job",
              "executionHandle": null,
              "statusPollRef": null,
              "dispatched": true,
              "status": "Requested"
            }
            """;
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(noPollRef)));

        SquadContractException error =
            await Assert.ThrowsAsync<SquadContractException>(() => agent.RunSessionAsync(Request()));

        Assert.Contains("statusPollRef", error.Message, StringComparison.Ordinal);
    }

    // --- 5. Non-zero exit is surfaced, not swallowed -------------------------

    [Fact]
    public async Task NonZeroExitWithNoOutput_IsSurfacedWithItsExitCode()
    {
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(
            FakeSquadCliInvoker.Failed(42, stdout: "", stderr: "az: could not reach the control plane")));

        SquadDispatchFailedException error =
            await Assert.ThrowsAsync<SquadDispatchFailedException>(() => agent.RunSessionAsync(Request()));

        Assert.Equal(42, error.ExitCode);
        Assert.Contains("42", error.Message, StringComparison.Ordinal);
        Assert.Contains("could not reach the control plane", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task NonZeroExitWithAnOtherwiseValidDocument_IsStillAFailure()
    {
        // The document says dispatched:true, the process says it failed. The
        // process wins: a partially-completed dispatch must not read as success.
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(
            FakeSquadCliInvoker.Failed(3, CliPayloads.AcaJobRun, "start failed after lease was written")));

        SquadDispatchFailedException error =
            await Assert.ThrowsAsync<SquadDispatchFailedException>(() => agent.RunSessionAsync(Request()));

        Assert.Equal(3, error.ExitCode);
    }

    // --- 6. No token anywhere -------------------------------------------------

    private const string LeakedTokenPrefix = "gh" + "p" + "_";
    private static readonly string LeakedToken = FakeCredentials.GitHubClassic;

    [Fact]
    public async Task TokenInControlPlaneStderr_NeverReachesAnExceptionMessage()
    {
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(
            FakeSquadCliInvoker.Failed(1, stdout: "", stderr: $"git push failed using {LeakedToken}")));

        SquadDispatchFailedException error =
            await Assert.ThrowsAsync<SquadDispatchFailedException>(() => agent.RunSessionAsync(Request()));

        Assert.DoesNotContain(LeakedToken, error.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(LeakedTokenPrefix, error.Message, StringComparison.Ordinal);
        Assert.Contains(SecretRedactor.Placeholder, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TokenInMalformedPayload_NeverReachesAnExceptionMessage()
    {
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(
            FakeSquadCliInvoker.Ok($"{{ broken GITHUB_TOKEN={LeakedToken}")));

        SquadContractException error =
            await Assert.ThrowsAsync<SquadContractException>(() => agent.RunSessionAsync(Request()));

        Assert.DoesNotContain(LeakedToken, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TokenInControlPlaneStderr_NeverReachesTheDiagnosticSink()
    {
        var sink = new List<string>();
        var options = new SquadAgentOptions { DiagnosticSink = sink.Add };
        var agent = new AcaSquadAgent(
            new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(CliPayloads.AcaJobRun, $"warning: {LeakedToken}")),
            options);

        await agent.RunSessionAsync(Request());

        Assert.NotEmpty(sink);
        Assert.All(sink, line => Assert.DoesNotContain(LeakedToken, line, StringComparison.Ordinal));
    }

    [Fact]
    public async Task TokenIsNeverPresentInAnyReturnedValue()
    {
        var agent = new AcaSquadAgent(
            new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(CliPayloads.AcaJobRun, $"warning: {LeakedToken}")));

        SquadSessionResult result = await agent.RunSessionAsync(Request());

        string everything = string.Join(
            "|",
            result.SessionName,
            result.Handle.Value,
            result.SandboxClass,
            result.FallbackReason,
            result.Status,
            result.Detail);
        Assert.DoesNotContain(LeakedToken, everything, StringComparison.Ordinal);
    }

    // --- 7. Status and cancel address the handle -----------------------------

    [Fact]
    public async Task GetSessionStatus_AddressesTheHandleAndDoesNotReResolveTheRoute()
    {
        var invoker = new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(CliPayloads.SandboxSessionsEntry));
        var agent = new AcaSquadAgent(invoker);

        SquadSessionStatus status =
            await agent.GetSessionStatusAsync(new SquadExecutionHandle("sqx1.SANDBOXHANDLE"));

        // Exactly this argv. Any --repo, --sub-squad, manifest path or route flag
        // would mean the CLI resolves routing again, which is the defect.
        Assert.Equal(new[] { "sessions", "--json", "--session", "sqx1.SANDBOXHANDLE" }, invoker.LastArguments);
        Assert.Single(invoker.Invocations);

        Assert.Equal("sbx-session", status.SessionName);
        Assert.Equal(SquadExecutionMode.Sandbox, status.ExecutionMode);
        Assert.Equal("net-egress-restricted", status.SandboxClass);
        Assert.Equal("Running", status.Status);
        Assert.Equal("Ready", status.Phase);
        Assert.Null(status.ExitCode);
    }

    [Fact]
    public async Task GetSessionStatus_ReadsTerminalAcaJobState()
    {
        var invoker = new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(CliPayloads.AcaJobSessionsEntry));
        var agent = new AcaSquadAgent(invoker);

        SquadSessionStatus status = await agent.GetSessionStatusAsync(new SquadExecutionHandle("fixedjson"));

        Assert.Equal(SquadExecutionMode.AcaJob, status.ExecutionMode);
        Assert.Equal("Succeeded", status.Status);
        Assert.Equal(0, status.ExitCode);
        Assert.Equal("caj-squad-aca-session-stub01", status.ExecutionName);
    }

    [Fact]
    public async Task GetSessionStatus_WithNoMatchingSession_FailsLoudly()
    {
        const string empty = """{ "schema": "squad-aca/sessions@1", "sessions": [] }""";
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(empty)));

        await Assert.ThrowsAsync<SquadContractException>(
            () => agent.GetSessionStatusAsync(new SquadExecutionHandle("sqx1.MISSING")));
    }

    [Fact]
    public async Task GetSessionStatus_NonZeroExit_IsSurfaced()
    {
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(
            FakeSquadCliInvoker.Failed(7, stdout: CliPayloads.SandboxSessionsEntry, stderr: "boom")));

        SquadDispatchFailedException error = await Assert.ThrowsAsync<SquadDispatchFailedException>(
            () => agent.GetSessionStatusAsync(new SquadExecutionHandle("sqx1.SANDBOXHANDLE")));

        Assert.Equal(7, error.ExitCode);
    }

    [Fact]
    public async Task CancelSession_AddressesTheHandleAndDoesNotReResolveTheRoute()
    {
        var invoker = new FakeSquadCliInvoker(FakeSquadCliInvoker.Ok(""));
        var agent = new AcaSquadAgent(invoker);

        await agent.CancelSessionAsync(new SquadExecutionHandle("sqx1.SANDBOXHANDLE"));

        Assert.Equal(new[] { "stop", "sqx1.SANDBOXHANDLE" }, invoker.LastArguments);
        Assert.Single(invoker.Invocations);
    }

    [Fact]
    public async Task CancelSession_NonZeroExit_IsSurfaced()
    {
        var agent = new AcaSquadAgent(new FakeSquadCliInvoker(
            FakeSquadCliInvoker.Failed(9, stderr: "az containerapp job stop failed")));

        SquadDispatchFailedException error = await Assert.ThrowsAsync<SquadDispatchFailedException>(
            () => agent.CancelSessionAsync(new SquadExecutionHandle("sqx1.SANDBOXHANDLE")));

        Assert.Equal(9, error.ExitCode);
        Assert.Contains("az containerapp job stop failed", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task EmptyHandle_IsRejectedBeforeTheCliIsInvoked()
    {
        var invoker = new FakeSquadCliInvoker();
        var agent = new AcaSquadAgent(invoker);

        await Assert.ThrowsAsync<ArgumentException>(
            () => agent.GetSessionStatusAsync(new SquadExecutionHandle("  ")));

        Assert.Empty(invoker.Invocations);
    }

    // --- 8. No poll-to-completion in this sprint ------------------------------

    [Fact]
    public void ISquadAgent_DoesNotExposePollToCompletion()
    {
        // Sessions run 10-60 minutes and MAF's RunAsync is request/response.
        // Reconciling those is Sprint 2's decision, so the contract must not
        // quietly acquire a blocking wait here.
        string[] methods = typeof(ISquadAgent).GetMethods().Select(m => m.Name).ToArray();

        Assert.Equal(
            new[] { "CancelSessionAsync", "GetSessionStatusAsync", "RunSessionAsync" },
            methods.OrderBy(n => n, StringComparer.Ordinal).ToArray());
    }

    private static string? ValueAfter(IReadOnlyList<string> argv, string flag)
    {
        for (int i = 0; i < argv.Count - 1; i++)
        {
            if (string.Equals(argv[i], flag, StringComparison.Ordinal))
            {
                return argv[i + 1];
            }
        }

        return null;
    }
}
