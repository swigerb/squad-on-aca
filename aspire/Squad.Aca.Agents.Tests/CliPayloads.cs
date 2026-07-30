namespace Squad.Aca.Agents.Tests;

/// <summary>
/// Canned <c>--json</c> documents, copied from the shapes the CLI goldens pin
/// (scripts/tests/golden/cli/23-run-json.txt and 26-sessions-json-session.txt).
/// </summary>
/// <remarks>
/// These are literal payloads rather than serialized objects on purpose. A
/// builder that produced them from the same types the agent parses back would
/// agree with itself no matter what either side did; a literal disagrees when
/// the contract changes, which is the entire point.
/// </remarks>
internal static class CliPayloads
{
    public const string AcaJobRun = """
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
          "statusPollRef": "fixedjson",
          "sandboxClass": null,
          "fallbackReason": null,
          "dispatched": true,
          "status": "Requested"
        }
        """;

    public const string SandboxRun = """
        {
          "schema": "squad-aca/run@1",
          "sessionName": "sbx-session",
          "repository": "octo/demo",
          "ref": "main",
          "outputBranch": "squad/sbx-session",
          "route": "sandbox",
          "routeReason": "approved-sandbox-class",
          "executionMode": "sandbox",
          "executionHandle": "sqx1.SANDBOXHANDLE",
          "statusPollRef": "sqx1.SANDBOXHANDLE",
          "sandboxClass": "net-egress-restricted",
          "fallbackReason": null,
          "dispatched": true,
          "status": "Provisioning"
        }
        """;

    public const string FailClosedRun = """
        {
          "schema": "squad-aca/run@1",
          "sessionName": "blocked-session",
          "repository": "octo/demo",
          "ref": "main",
          "outputBranch": "squad/blocked-session",
          "route": "fail-closed",
          "routeReason": "sandbox-class-not-approved",
          "executionMode": "aca-job",
          "executionHandle": null,
          "statusPollRef": null,
          "sandboxClass": "gpu-unrestricted",
          "fallbackReason": "sandbox-class-not-approved",
          "dispatched": false,
          "status": "FailedClosed"
        }
        """;

    public const string SandboxSessionsEntry = """
        {
          "schema": "squad-aca/sessions@1",
          "sessions": [
            {
              "sessionName": "sbx-session",
              "executionName": "sbx-session-01",
              "executionHandle": "sqx1.SANDBOXHANDLE",
              "executionMode": "sandbox",
              "route": "sandbox",
              "status": "Running",
              "sandboxClass": "net-egress-restricted",
              "repository": "octo/demo",
              "branch": "squad/sbx-session",
              "mode": "prompt",
              "source": "local-cli",
              "startedAt": "2026-01-02T03:04:05",
              "endedAt": null,
              "phase": "Ready",
              "exitCode": null
            }
          ]
        }
        """;

    public const string AcaJobSessionsEntry = """
        {
          "schema": "squad-aca/sessions@1",
          "sessions": [
            {
              "sessionName": "fixedjson",
              "executionName": "caj-squad-aca-session-stub01",
              "executionHandle": "sqx1.JOBHANDLE",
              "executionMode": "aca-job",
              "route": "aca-job",
              "status": "Succeeded",
              "sandboxClass": null,
              "repository": "octo/demo",
              "branch": "squad/fixedjson",
              "mode": "prompt",
              "source": "local-cli",
              "startedAt": "2026-01-02T03:04:05",
              "endedAt": "2026-01-02T03:44:05",
              "phase": null,
              "exitCode": 0
            }
          ]
        }
        """;
}
