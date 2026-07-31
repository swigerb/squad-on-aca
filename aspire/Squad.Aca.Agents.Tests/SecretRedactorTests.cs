using Xunit;

namespace Squad.Aca.Agents.Tests;

/// <summary>
/// The redactor is the last line of defence for text this library did not
/// author. Each case is a shape that has actually appeared in control-plane or
/// worker output.
/// </summary>
public sealed class SecretRedactorTests
{
    [Theory]
    [MemberData(nameof(FakeCredentials.All), MemberType = typeof(FakeCredentials))]
    public void CredentialShapes_AreReplaced(string secret)
    {
        string redacted = SecretRedactor.Redact($"prefix {secret} suffix");

        Assert.DoesNotContain(secret, redacted, StringComparison.Ordinal);
        Assert.Contains(SecretRedactor.Placeholder, redacted, StringComparison.Ordinal);
        Assert.StartsWith("prefix ", redacted, StringComparison.Ordinal);
        Assert.EndsWith(" suffix", redacted, StringComparison.Ordinal);
    }

    [Fact]
    public void AuthorizationHeaders_AreReplaced()
    {
        string redacted = SecretRedactor.Redact("Authorization: Bearer AbCdEf0123456789ZyXwVu");

        Assert.DoesNotContain("AbCdEf0123456789ZyXwVu", redacted, StringComparison.Ordinal);
    }

    [Fact]
    public void AssignedSecrets_AreReplaced()
    {
        string redacted = SecretRedactor.Redact("GITHUB_TOKEN=hunter2plaintextvalue");

        Assert.DoesNotContain("hunter2plaintextvalue", redacted, StringComparison.Ordinal);
    }

    [Fact]
    public void SecretRefIndirection_IsPreserved()
    {
        // `GITHUB_TOKEN=secretref:github-token` is what the control plane actually
        // emits and what the CLI goldens pin. It names a secret without being one,
        // and redacting it would corrupt output that is deliberately safe.
        const string line = "GITHUB_TOKEN=secretref:github-token COPILOT_GITHUB_TOKEN=secretref:copilot-github-token";

        Assert.Equal(line, SecretRedactor.Redact(line));
    }

    [Fact]
    public void OrdinaryText_IsUntouched()
    {
        const string line = "Dispatched on 'aca-job' with status 'Requested'.";

        Assert.Equal(line, SecretRedactor.Redact(line));
    }

    [Fact]
    public void NullAndEmpty_AreSafe()
    {
        Assert.Equal(string.Empty, SecretRedactor.Redact(null));
        Assert.Equal(string.Empty, SecretRedactor.Redact(string.Empty));
    }

    [Fact]
    public void ExecutionHandles_AreNotMistakenForSecrets()
    {
        // A handle is base64-ish and long, but it is the value callers must pass
        // back. Redacting it would break status and cancel.
        const string handle = "sqx1.eyJ2IjoxLCJwIjoiYWNhLWpvYiIsImQiOnsiam9iIjoiY2FqIn19";

        Assert.Equal(handle, SecretRedactor.Redact(handle));
    }
}
