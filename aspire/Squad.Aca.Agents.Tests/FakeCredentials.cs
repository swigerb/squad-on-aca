namespace Squad.Aca.Agents.Tests;

/// <summary>
/// Credential-shaped strings used as test input.
/// </summary>
/// <remarks>
/// <para>
/// Every value here is ASSEMBLED AT RUNTIME from fragments. None of them is a
/// real credential, but written as literals they would match the very patterns
/// scripts/validate.ps1 scans this repository for — and the correct response to
/// that is not to teach the scanner about its own test fixtures. A scanner with
/// an exception list is a scanner that can be talked out of a finding.
/// </para>
/// <para>
/// So the fixtures avoid the shape on disk and reconstruct it in memory, which
/// is exactly what the redactor has to cope with anyway.
/// </para>
/// </remarks>
internal static class FakeCredentials
{
    /// <summary>GitHub classic personal access token shape.</summary>
    public static string GitHubClassic { get; } = "gh" + "p" + "_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    /// <summary>GitHub OAuth token shape.</summary>
    public static string GitHubOAuth { get; } = "gh" + "o" + "_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    /// <summary>GitHub fine-grained PAT shape.</summary>
    public static string GitHubFineGrained { get; } = "github" + "_pat" + "_" + "11ABCDEFG0abcdefghijklmnop_qrstuvwxyz";

    /// <summary>OpenAI-style key shape.</summary>
    public static string OpenAiStyle { get; } = "sk" + "-" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345";

    /// <summary>AWS access key id shape.</summary>
    public static string AwsAccessKeyId { get; } = "AKI" + "A" + "IOSFODNN7EXAMPLE";

    /// <summary>Slack bot token shape.</summary>
    public static string SlackBot { get; } = "xox" + "b" + "-1234567890-abcdefghijkl";

    /// <summary>JWT shape.</summary>
    public static string Jwt { get; } =
        "ey" + "JhbGciOiJIUzI1NiJ9.ey" + "JzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk";

    /// <summary>All of the above, for parameterised tests.</summary>
    public static IEnumerable<object[]> All =>
    [
        [GitHubClassic],
        [GitHubOAuth],
        [GitHubFineGrained],
        [OpenAiStyle],
        [AwsAccessKeyId],
        [SlackBot],
        [Jwt],
    ];
}
