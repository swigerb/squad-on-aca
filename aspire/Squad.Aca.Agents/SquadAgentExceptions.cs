namespace Squad.Aca.Agents;

/// <summary>
/// Base class for every failure this library reports.
/// </summary>
/// <remarks>
/// Every message that reaches one of these is passed through
/// <see cref="SecretRedactor"/> first. Control-plane output is not trusted to be
/// token-free: a worker log line or an <c>az</c> diagnostic can quote one, and an
/// exception message is exactly the kind of value that ends up in a CI log, a
/// bug report, or a telemetry span.
/// </remarks>
public class SquadAgentException : Exception
{
    /// <summary>Creates the exception with a redacted message.</summary>
    /// <param name="message">Message; redacted before it is stored.</param>
    public SquadAgentException(string message)
        : base(SecretRedactor.Redact(message))
    {
    }

    /// <summary>Creates the exception with a redacted message and an inner cause.</summary>
    /// <param name="message">Message; redacted before it is stored.</param>
    /// <param name="innerException">The underlying cause.</param>
    public SquadAgentException(string message, Exception innerException)
        : base(SecretRedactor.Redact(message), innerException)
    {
    }
}

/// <summary>
/// The control plane produced output this library could not interpret.
/// </summary>
/// <remarks>
/// Raised for empty stdout, malformed JSON, a missing schema, an unknown route
/// or execution mode, and a required field that is absent. All of those are
/// "the contract was not honoured", and every one of them fails loudly: a
/// half-populated result that claims a dispatch happened is worse than an
/// exception, because a caller acts on it.
/// </remarks>
public sealed class SquadContractException : SquadAgentException
{
    /// <summary>Creates the exception.</summary>
    /// <param name="message">Message; redacted before it is stored.</param>
    public SquadContractException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with an inner cause.</summary>
    /// <param name="message">Message; redacted before it is stored.</param>
    /// <param name="innerException">The underlying cause.</param>
    public SquadContractException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>
/// The control plane ran but did not dispatch the session.
/// </summary>
public class SquadDispatchFailedException : SquadAgentException
{
    /// <summary>Creates the exception.</summary>
    /// <param name="message">Message; redacted before it is stored.</param>
    /// <param name="exitCode">Control-plane process exit code.</param>
    public SquadDispatchFailedException(string message, int exitCode)
        : base(message)
    {
        ExitCode = exitCode;
    }

    /// <summary>The exit code the control plane process returned.</summary>
    public int ExitCode { get; }
}

/// <summary>
/// Capability routing failed closed: the repository requires capabilities that
/// cannot be satisfied on any approved plane, so NOTHING was started.
/// </summary>
/// <remarks>
/// This is deliberately its own type, and deliberately an exception rather than
/// a result with <c>Dispatched = false</c>. A fail-closed route that a caller
/// could mistake for a dispatch is the failure mode this whole seam exists to
/// prevent — a repository whose required capabilities cannot be met must not
/// look like work that started.
/// </remarks>
public sealed class SquadRouteFailedClosedException : SquadDispatchFailedException
{
    /// <summary>Creates the exception.</summary>
    /// <param name="message">Message; redacted before it is stored.</param>
    /// <param name="reason">The resolver's reason code, preserved verbatim.</param>
    /// <param name="sandboxClass">The requested sandbox class id, when there was one.</param>
    /// <param name="exitCode">Control-plane process exit code.</param>
    public SquadRouteFailedClosedException(string message, string? reason, string? sandboxClass, int exitCode)
        : base(message, exitCode)
    {
        Reason = reason;
        SandboxClass = sandboxClass;
    }

    /// <summary>
    /// The routing reason code, e.g. <c>capability-resolution-fail-closed</c> or
    /// <c>sandbox-feature-disabled-and-default-insufficient</c>. Preserved so a
    /// caller can act on WHY the refusal happened, not just that it did.
    /// </summary>
    public string? Reason { get; }

    /// <summary>The sandbox class the manifest asked for, when it named one.</summary>
    public string? SandboxClass { get; }
}
