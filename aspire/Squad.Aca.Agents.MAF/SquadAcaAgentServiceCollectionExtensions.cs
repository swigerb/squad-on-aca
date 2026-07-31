using Microsoft.Agents.AI;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Squad.Aca.Agents.MAF;

/// <summary>
/// <c>AddSquadAcaAgent()</c> — registers Squad on ACA as an Agent Framework
/// <see cref="AIAgent"/>.
/// </summary>
/// <remarks>
/// <para>
/// The shape follows the upstream <c>Squad.Agents.AI</c> extension so a host that
/// already wires one Squad agent recognises this one: a configure callback, a
/// singleton registration, and — because MAF hosts routinely resolve more than
/// one agent — keyed overloads.
/// </para>
/// <para>
/// BOTH the concrete type and the base <see cref="AIAgent"/> are registered, and
/// the base resolves to the SAME instance. A second registration would build a
/// second adapter, and the two would poll independently, count timeouts
/// independently, and stop each other's sessions on cancellation.
/// </para>
/// </remarks>
public static class SquadAcaAgentServiceCollectionExtensions
{
    /// <summary>
    /// Registers <see cref="SquadAcaAIAgent"/> and <see cref="AIAgent"/> as
    /// singletons over an <see cref="ISquadAgent"/> resolved from the container.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="configure">Optional adapter configuration.</param>
    /// <returns>The same service collection, for chaining.</returns>
    public static IServiceCollection AddSquadAcaAgent(
        this IServiceCollection services,
        Action<SquadAcaAgentOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(services);

        services.TryAddSingleton<SquadAcaAIAgent>(provider =>
            new SquadAcaAIAgent(provider.GetRequiredService<ISquadAgent>(), BuildOptions(configure)));

        // Resolved through the concrete registration, never constructed again.
        services.TryAddSingleton<AIAgent>(provider => provider.GetRequiredService<SquadAcaAIAgent>());

        return services;
    }

    /// <summary>
    /// Registers the adapter over an explicitly supplied <see cref="ISquadAgent"/>
    /// factory, for hosts that do not register one in the container.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="squadAgentFactory">Factory for the inner agent.</param>
    /// <param name="configure">Optional adapter configuration.</param>
    /// <returns>The same service collection, for chaining.</returns>
    public static IServiceCollection AddSquadAcaAgent(
        this IServiceCollection services,
        Func<IServiceProvider, ISquadAgent> squadAgentFactory,
        Action<SquadAcaAgentOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(squadAgentFactory);

        services.TryAddSingleton<SquadAcaAIAgent>(provider =>
            new SquadAcaAIAgent(squadAgentFactory(provider), BuildOptions(configure)));
        services.TryAddSingleton<AIAgent>(provider => provider.GetRequiredService<SquadAcaAIAgent>());

        return services;
    }

    /// <summary>
    /// Keyed registration, so several Squad agents (different repositories,
    /// different timeouts) can coexist in one host.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="serviceKey">The DI key.</param>
    /// <param name="configure">Optional adapter configuration.</param>
    /// <returns>The same service collection, for chaining.</returns>
    /// <remarks>
    /// The inner <see cref="ISquadAgent"/> is resolved by the SAME key when one is
    /// registered under it, and falls back to the unkeyed registration otherwise.
    /// Without that fallback the common case — several MAF agents over one
    /// control plane — would need a redundant keyed copy of the inner agent.
    /// </remarks>
    public static IServiceCollection AddKeyedSquadAcaAgent(
        this IServiceCollection services,
        object serviceKey,
        Action<SquadAcaAgentOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(serviceKey);

        services.TryAddKeyedSingleton<SquadAcaAIAgent>(serviceKey, (provider, key) =>
            new SquadAcaAIAgent(ResolveInner(provider, key), BuildOptions(configure)));
        services.TryAddKeyedSingleton<AIAgent>(serviceKey, (provider, key) =>
            provider.GetRequiredKeyedService<SquadAcaAIAgent>(key));

        return services;
    }

    /// <summary>
    /// Keyed registration over an explicitly supplied <see cref="ISquadAgent"/>
    /// factory.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="serviceKey">The DI key.</param>
    /// <param name="squadAgentFactory">Factory for the inner agent.</param>
    /// <param name="configure">Optional adapter configuration.</param>
    /// <returns>The same service collection, for chaining.</returns>
    public static IServiceCollection AddKeyedSquadAcaAgent(
        this IServiceCollection services,
        object serviceKey,
        Func<IServiceProvider, object?, ISquadAgent> squadAgentFactory,
        Action<SquadAcaAgentOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(serviceKey);
        ArgumentNullException.ThrowIfNull(squadAgentFactory);

        services.TryAddKeyedSingleton<SquadAcaAIAgent>(serviceKey, (provider, key) =>
            new SquadAcaAIAgent(squadAgentFactory(provider, key), BuildOptions(configure)));
        services.TryAddKeyedSingleton<AIAgent>(serviceKey, (provider, key) =>
            provider.GetRequiredKeyedService<SquadAcaAIAgent>(key));

        return services;
    }

    private static ISquadAgent ResolveInner(IServiceProvider provider, object? serviceKey)
    {
        if (serviceKey is not null)
        {
            ISquadAgent? keyed = provider.GetKeyedService<ISquadAgent>(serviceKey);
            if (keyed is not null)
            {
                return keyed;
            }
        }

        return provider.GetRequiredService<ISquadAgent>();
    }

    private static SquadAcaAgentOptions BuildOptions(Action<SquadAcaAgentOptions>? configure)
    {
        var options = new SquadAcaAgentOptions();
        configure?.Invoke(options);
        return options;
    }
}
