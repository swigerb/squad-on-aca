using Microsoft.Agents.AI;
using Microsoft.Extensions.DependencyInjection;
using Squad.Aca.Agents;
using Xunit;

namespace Squad.Aca.Agents.MAF.Tests;

/// <summary>
/// Registration tests for <c>AddSquadAcaAgent()</c>.
/// </summary>
public class SquadAcaAgentServiceCollectionExtensionsTests
{
    [Fact]
    public void AddSquadAcaAgent_RegistersBothTheConcreteTypeAndTheBaseAIAgent()
    {
        var inner = new FakeSquadAgent();
        ServiceProvider provider = new ServiceCollection()
            .AddSingleton<ISquadAgent>(inner)
            .AddSquadAcaAgent(o => o.DefaultRepository = "octo/demo")
            .BuildServiceProvider();

        var concrete = provider.GetRequiredService<SquadAcaAIAgent>();
        var abstraction = provider.GetRequiredService<AIAgent>();

        Assert.NotNull(concrete);
        Assert.IsType<SquadAcaAIAgent>(abstraction);

        // The same instance, not two adapters over one control plane. Two would
        // poll independently, time out independently, and stop each other's
        // sessions on cancellation.
        Assert.Same(concrete, abstraction);
        Assert.Same(inner, concrete.InnerAgent);
    }

    [Fact]
    public void AddSquadAcaAgent_AppliesTheConfigureCallback()
    {
        ServiceProvider provider = new ServiceCollection()
            .AddSingleton<ISquadAgent>(new FakeSquadAgent())
            .AddSquadAcaAgent(o =>
            {
                o.Name = "squad-on-aca-primary";
                o.Id = "primary";
            })
            .BuildServiceProvider();

        var agent = provider.GetRequiredService<SquadAcaAIAgent>();
        Assert.Equal("squad-on-aca-primary", agent.Name);
        Assert.Equal("primary", agent.Id);
    }

    [Fact]
    public void AddSquadAcaAgent_AcceptsAnExplicitInnerAgentFactory()
    {
        var inner = new FakeSquadAgent();
        ServiceProvider provider = new ServiceCollection()
            .AddSquadAcaAgent(_ => inner, o => o.DefaultRepository = "octo/demo")
            .BuildServiceProvider();

        var agent = provider.GetRequiredService<SquadAcaAIAgent>();
        Assert.Same(inner, agent.InnerAgent);
        Assert.Same(agent, provider.GetRequiredService<AIAgent>());
    }

    [Fact]
    public void KeyedRegistrationsResolveIndependentlyOfEachOther()
    {
        var shared = new FakeSquadAgent();
        ServiceProvider provider = new ServiceCollection()
            .AddSingleton<ISquadAgent>(shared)
            .AddKeyedSquadAcaAgent("primary", o =>
            {
                o.Id = "primary";
                o.DefaultRepository = "octo/one";
            })
            .AddKeyedSquadAcaAgent("secondary", o =>
            {
                o.Id = "secondary";
                o.DefaultRepository = "octo/two";
            })
            .BuildServiceProvider();

        var primary = provider.GetRequiredKeyedService<SquadAcaAIAgent>("primary");
        var secondary = provider.GetRequiredKeyedService<SquadAcaAIAgent>("secondary");

        Assert.NotSame(primary, secondary);
        Assert.Equal("primary", primary.Id);
        Assert.Equal("secondary", secondary.Id);

        Assert.Same(primary, provider.GetRequiredKeyedService<AIAgent>("primary"));
        Assert.Same(secondary, provider.GetRequiredKeyedService<AIAgent>("secondary"));
    }

    [Fact]
    public void AKeyedAgentPrefersAnInnerAgentRegisteredUnderTheSameKey()
    {
        var unkeyed = new FakeSquadAgent();
        var keyed = new FakeSquadAgent();

        ServiceProvider provider = new ServiceCollection()
            .AddSingleton<ISquadAgent>(unkeyed)
            .AddKeyedSingleton<ISquadAgent>("primary", keyed)
            .AddKeyedSquadAcaAgent("primary")
            .AddKeyedSquadAcaAgent("secondary")
            .BuildServiceProvider();

        Assert.Same(keyed, provider.GetRequiredKeyedService<SquadAcaAIAgent>("primary").InnerAgent);

        // No keyed inner agent under "secondary", so it falls back to the shared
        // one rather than demanding a redundant keyed copy.
        Assert.Same(unkeyed, provider.GetRequiredKeyedService<SquadAcaAIAgent>("secondary").InnerAgent);
    }

    [Fact]
    public void AKeyedRegistrationAcceptsAnExplicitInnerAgentFactory()
    {
        var inner = new FakeSquadAgent();
        ServiceProvider provider = new ServiceCollection()
            .AddKeyedSquadAcaAgent("primary", (_, key) => key is "primary" ? inner : new FakeSquadAgent())
            .BuildServiceProvider();

        Assert.Same(inner, provider.GetRequiredKeyedService<SquadAcaAIAgent>("primary").InnerAgent);
    }

    [Fact]
    public void KeyedAndUnkeyedRegistrationsCoexistWithoutShadowingEachOther()
    {
        ServiceProvider provider = new ServiceCollection()
            .AddSingleton<ISquadAgent>(new FakeSquadAgent())
            .AddSquadAcaAgent(o => o.Id = "default")
            .AddKeyedSquadAcaAgent("primary", o => o.Id = "primary")
            .BuildServiceProvider();

        Assert.Equal("default", provider.GetRequiredService<SquadAcaAIAgent>().Id);
        Assert.Equal("primary", provider.GetRequiredKeyedService<SquadAcaAIAgent>("primary").Id);
        Assert.Null(provider.GetKeyedService<SquadAcaAIAgent>("secondary"));
    }

    [Fact]
    public void RegisteringTwiceDoesNotReplaceAnExistingAgent()
    {
        ServiceProvider provider = new ServiceCollection()
            .AddSingleton<ISquadAgent>(new FakeSquadAgent())
            .AddSquadAcaAgent(o => o.Id = "first")
            .AddSquadAcaAgent(o => o.Id = "second")
            .BuildServiceProvider();

        Assert.Equal("first", provider.GetRequiredService<SquadAcaAIAgent>().Id);
    }

    [Fact]
    public void AddSquadAcaAgent_RejectsNullArguments()
    {
        IServiceCollection services = new ServiceCollection();

        Assert.Throws<ArgumentNullException>(() =>
            SquadAcaAgentServiceCollectionExtensions.AddSquadAcaAgent(null!));
        Assert.Throws<ArgumentNullException>(() =>
            services.AddSquadAcaAgent((Func<IServiceProvider, ISquadAgent>)null!));
        Assert.Throws<ArgumentNullException>(() =>
            services.AddKeyedSquadAcaAgent(null!));
    }
}
