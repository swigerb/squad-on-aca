using System.Text.RegularExpressions;

namespace Squad.Aca.Agents;

/// <summary>
/// Removes credential-shaped substrings from anything this library reports.
/// </summary>
/// <remarks>
/// <para>
/// This library never HANDLES a token: it builds no credential argument, sets no
/// credential environment variable, and reads none. But it does relay the
/// control plane's stderr into exception messages and diagnostics, and that text
/// is not under this library's control — a worker log line, an <c>az</c>
/// diagnostic or a git error can quote a token that was never ours.
/// </para>
/// <para>
/// So redaction is applied at the boundary where text becomes a durable artefact
/// (an exception message, a diagnostic line), not at the point a token is
/// created. That is the only place it can be applied, because we never see the
/// creation.
/// </para>
/// <para>
/// The patterns mirror the ones scripts/validate.ps1 scans the repository with,
/// so a shape that would fail the repo's secret gate is also a shape this
/// redacts.
/// </para>
/// </remarks>
public static class SecretRedactor
{
    /// <summary>The text substituted for a redacted match.</summary>
    public const string Placeholder = "[redacted]";

    private static readonly Regex[] Patterns =
    [
        // GitHub classic / OAuth / user / server / refresh tokens.
        new Regex(@"gh[pousr]_[A-Za-z0-9]{16,}", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        // GitHub fine-grained PATs.
        new Regex(@"github_pat_[A-Za-z0-9_]{20,}", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        // OpenAI-style keys.
        new Regex(@"sk-[A-Za-z0-9]{20,}", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        // AWS access key ids.
        new Regex(@"AKIA[0-9A-Z]{16}", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        // Slack tokens.
        new Regex(@"xox[baprs]-[A-Za-z0-9-]{10,}", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        // Bearer / Authorization headers.
        new Regex(@"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{16,}", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        // JWTs.
        new Regex(@"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", RegexOptions.Compiled | RegexOptions.CultureInvariant),
        // KEY=/TOKEN=/SECRET=/PASSWORD= assignments, but NOT the control plane's
        // own `secretref:` indirection, which names a secret without being one.
        new Regex(@"(?i)\b[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|APIKEY|API_KEY)\s*[=:]\s*(?!secretref:|keyvaultref:|identityref:)[^\s""',;]+", RegexOptions.Compiled | RegexOptions.CultureInvariant),
    ];

    /// <summary>Redacts every credential-shaped substring in <paramref name="text"/>.</summary>
    /// <param name="text">Text to scrub. Null and empty are returned unchanged.</param>
    /// <returns>The text with credential-shaped substrings replaced.</returns>
    public static string Redact(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return text ?? string.Empty;
        }

        string result = text;
        foreach (Regex pattern in Patterns)
        {
            result = pattern.Replace(result, Placeholder);
        }

        return result;
    }
}
