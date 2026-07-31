using Squad.Aca.Agents;

namespace Squad.Aca.Agents.MAF.Tests;

/// <summary>
/// Contract values used across the adapter tests.
/// </summary>
internal static class Fixtures
{
    public const string JobHandle = "fixedjson";
    public const string SandboxHandle = "sqx1.c2FuZGJveA";

    public static SquadSessionResult AcaJobDispatch(string sessionName = "fixedjson") =>
        new(
            SessionName: sessionName,
            Dispatched: true,
            Route: SquadExecutionRoute.AcaJob,
            ExecutionMode: SquadExecutionMode.AcaJob,
            Handle: new SquadExecutionHandle(JobHandle),
            SandboxClass: null,
            FallbackReason: null,
            Status: "Requested",
            Detail: "Dispatched on 'aca-job' with status 'Requested'.");

    public static SquadSessionResult SandboxDispatch(
        string sessionName = "sbx-session",
        string sandboxClass = "sandbox-python-3-12",
        string? fallbackReason = null) =>
        new(
            SessionName: sessionName,
            Dispatched: true,
            Route: SquadExecutionRoute.Sandbox,
            ExecutionMode: SquadExecutionMode.Sandbox,
            Handle: new SquadExecutionHandle(SandboxHandle),
            SandboxClass: sandboxClass,
            FallbackReason: fallbackReason,
            Status: "Provisioning",
            Detail: $"Dispatched on 'sandbox' with status 'Provisioning' (sandbox class {sandboxClass}).");

    public static SquadSessionStatus Status(
        string status,
        string sessionName = "fixedjson",
        string handle = JobHandle,
        string route = "aca-job",
        SquadExecutionMode mode = SquadExecutionMode.AcaJob,
        string? sandboxClass = null,
        string? phase = null,
        int? exitCode = null) =>
        new(
            SessionName: sessionName,
            ExecutionName: "caj-squad-aca-session-stub01",
            Handle: new SquadExecutionHandle(handle),
            ExecutionMode: mode,
            Route: route,
            Status: status,
            SandboxClass: sandboxClass,
            Repository: "octo/demo",
            Branch: "squad/fixedjson",
            Phase: phase,
            ExitCode: exitCode);
}
