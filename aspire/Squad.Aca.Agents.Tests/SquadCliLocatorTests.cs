using Xunit;

namespace Squad.Aca.Agents.Tests;

/// <summary>
/// Entry-point resolution must never depend on an absolute path baked into the
/// binary, and must fail with somewhere to look rather than silently.
/// </summary>
public sealed class SquadCliLocatorTests
{
    [Fact]
    public void ExplicitCliPath_WinsOverEverythingElse()
    {
        var options = new SquadAgentOptions { CliPath = @"X:\explicit\squad-aca.ps1" };

        string resolved = SquadCliLocator.Resolve(
            options,
            fileExists: p => p == @"X:\explicit\squad-aca.ps1" || p == @"X:\env\squad-aca.ps1",
            environment: _ => @"X:\env\squad-aca.ps1",
            startDirectories: []);

        Assert.Equal(@"X:\explicit\squad-aca.ps1", resolved);
    }

    [Fact]
    public void EnvironmentVariable_IsUsedWhenNoExplicitPathIsSet()
    {
        string resolved = SquadCliLocator.Resolve(
            new SquadAgentOptions(),
            fileExists: p => p == @"X:\env\squad-aca.ps1",
            environment: name =>
                name == SquadCliLocator.PathEnvironmentVariable ? @"X:\env\squad-aca.ps1" : null,
            startDirectories: []);

        Assert.Equal(@"X:\env\squad-aca.ps1", resolved);
    }

    [Fact]
    public void UpwardSearch_FindsScriptsSquadAcaAboveTheStartDirectory()
    {
        string repoRoot = Path.Combine(Path.GetTempPath(), "squad-locator-repo");
        string expected = Path.Combine(repoRoot, "scripts", "squad-aca.ps1");
        string deep = Path.Combine(repoRoot, "aspire", "Squad.Aca.Agents.Tests", "bin", "Debug");

        string resolved = SquadCliLocator.Resolve(
            new SquadAgentOptions(),
            fileExists: p => string.Equals(p, expected, StringComparison.OrdinalIgnoreCase),
            environment: _ => null,
            startDirectories: [deep]);

        Assert.Equal(expected, resolved);
    }

    [Fact]
    public void NothingResolves_ThrowsAndNamesEveryPlaceItLooked()
    {
        SquadAgentException error = Assert.Throws<SquadAgentException>(() => SquadCliLocator.Resolve(
            new SquadAgentOptions { CliPath = @"X:\missing\squad-aca.ps1" },
            fileExists: _ => false,
            environment: _ => @"X:\also-missing\squad-aca.ps1",
            startDirectories: [Path.Combine(Path.GetTempPath(), "squad-locator-nowhere")]));

        Assert.Contains(@"X:\missing\squad-aca.ps1", error.Message, StringComparison.Ordinal);
        Assert.Contains(SquadCliLocator.PathEnvironmentVariable, error.Message, StringComparison.Ordinal);
        Assert.Contains("squad-locator-nowhere", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void MissingExplicitPath_FallsThroughToTheEnvironmentVariable()
    {
        // An options path that does not exist must not short-circuit resolution:
        // a stale configured path should degrade to discovery, not to failure.
        string resolved = SquadCliLocator.Resolve(
            new SquadAgentOptions { CliPath = @"X:\stale\squad-aca.ps1" },
            fileExists: p => p == @"X:\env\squad-aca.ps1",
            environment: _ => @"X:\env\squad-aca.ps1",
            startDirectories: []);

        Assert.Equal(@"X:\env\squad-aca.ps1", resolved);
    }
}
