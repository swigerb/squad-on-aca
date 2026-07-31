namespace Squad.Aca.Agents.MAF.Tests;

/// <summary>
/// Credential-shaped strings used as test input.
/// </summary>
/// <remarks>
/// Every value is ASSEMBLED AT RUNTIME from fragments, for the same reason
/// Squad.Aca.Agents.Tests does it: written as literals they would match the very
/// patterns scripts/validate.ps1 scans this repository for, and the correct
/// response to that is not to teach the scanner about its own test fixtures. A
/// scanner with an exception list is a scanner that can be talked out of a
/// finding.
/// </remarks>
internal static class FakeCredentials
{
    /// <summary>GitHub classic personal access token shape.</summary>
    public static string GitHubClassic { get; } = "gh" + "p" + "_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    /// <summary>GitHub fine-grained PAT shape.</summary>
    public static string GitHubFineGrained { get; } = "github" + "_pat" + "_" + "11ABCDEFG0abcdefghijklmnop_qrstuvwxyz";

    /// <summary>OpenAI-style key shape.</summary>
    public static string OpenAiStyle { get; } = "sk" + "-" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345";

    /// <summary>Bearer authorization header shape.</summary>
    public static string BearerHeader { get; } = "Bea" + "rer " + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    /// <summary>All of the above, so a test can prove none of them survives.</summary>
    public static IReadOnlyList<string> All { get; } =
    [
        GitHubClassic,
        GitHubFineGrained,
        OpenAiStyle,
        BearerHeader,
    ];
}
