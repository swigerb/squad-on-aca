// Optional .NET Aspire AppHost for Squad on ACA.
//
// This is an OPTIONAL integration path and is intentionally separate from the
// primary ACA Jobs control plane (scripts/*.ps1 + worker/). It does NOT replace
// that architecture. Roles stay layered:
//
//   * Aspire        -> models resources (this AppHost).
//   * Agent Framework -> exposes the agent abstraction (see AgentAbstraction.cs).
//   * ACA           -> remains the production execution substrate.
//   * Squad         -> remains the orchestration system inside the worker.
//
// What this AppHost does: it runs the standalone Aspire Dashboard (the default
// OTLP sink for Squad on ACA) and, optionally, the squad-worker container wired
// to that dashboard's OTLP endpoints. This lets you validate telemetry flow and
// worker behavior locally before dispatching real work to ACA.
//
// Security notes (mirrors scripts/deploy.ps1):
//   * Dashboard UI auth  = BrowserToken (never Unsecured).
//   * Dashboard OTLP auth = ApiKey (never Unsecured).
//   * OTLP ports (18889/18890) are modeled as internal-only endpoints.
//   * No secrets are committed. Tokens are read from configuration/user-secrets
//     /environment at run time and generated when absent.

using System.Security.Cryptography;

var builder = DistributedApplication.CreateBuilder(args);

// ---------------------------------------------------------------------------
// Configuration (no secrets in source). Override via user-secrets, environment
// variables (SQUAD_*), or appsettings.Development.json which is gitignored.
// ---------------------------------------------------------------------------
var config = builder.Configuration;
string workerImage = config["Squad:WorkerImage"] ?? "squad-worker:latest";
string dashboardTag = config["Squad:AspireDashboardTag"] ?? "9.4";
string githubRepository = config["Squad:GitHubRepository"] ?? "<github-owner>/<repo>";
string githubRef = config["Squad:GitHubRef"] ?? "main";

// Generate ephemeral tokens if the operator did not provide them. These live
// only in the running process; they are never written to disk by this AppHost.
string browserToken = config["Squad:DashboardBrowserToken"] ?? NewHexToken();
string otlpApiKey = config["Squad:OtlpApiKey"] ?? NewHexToken();

// ---------------------------------------------------------------------------
// Standalone Aspire Dashboard = the default OTLP sink for Squad on ACA.
// ---------------------------------------------------------------------------
var dashboard = builder
    .AddContainer("aspire-dashboard", "mcr.microsoft.com/dotnet/aspire-dashboard", dashboardTag)
    .WithHttpEndpoint(targetPort: 18888, name: "ui")
    .WithHttpEndpoint(targetPort: 18889, name: "otlp-grpc")
    .WithHttpEndpoint(targetPort: 18890, name: "otlp-http")
    // UI auth: browser token (matches DASHBOARD__FRONTEND__AUTHMODE=BrowserToken).
    .WithEnvironment("DASHBOARD__FRONTEND__AUTHMODE", "BrowserToken")
    .WithEnvironment("DASHBOARD__FRONTEND__BROWSERTOKEN", browserToken)
    // OTLP auth: API key (matches DASHBOARD__OTLP__AUTHMODE=ApiKey). Never Unsecured.
    .WithEnvironment("DASHBOARD__OTLP__AUTHMODE", "ApiKey")
    .WithEnvironment("DASHBOARD__OTLP__PRIMARYAPIKEY", otlpApiKey);

// ---------------------------------------------------------------------------
// Optional: model the squad-worker container wired to the dashboard's OTLP
// endpoints. In production this same image runs as an ACA Job execution; here
// it is modeled as a container purely for local, telemetry-wired smoke tests.
// Enable by setting Squad:RunWorker=true (off by default so `dotnet run` just
// brings up the dashboard).
// ---------------------------------------------------------------------------
if (bool.TryParse(config["Squad:RunWorker"], out var runWorker) && runWorker)
{
    builder
        .AddContainer("squad-worker", workerImage)
        .WithReference(dashboard.GetEndpoint("otlp-grpc"))
        .WithReference(dashboard.GetEndpoint("otlp-http"))
        .WithEnvironment("GITHUB_REPOSITORY", githubRepository)
        .WithEnvironment("GITHUB_REF", githubRef)
        .WithEnvironment("SQUAD_MODE", config["Squad:Mode"] ?? "smoke")
        .WithEnvironment("SQUAD_DEPLOYMENT_MODE", "squad-per-pod")
        .WithEnvironment("ASPIRE_OTLP_GRPC_ENDPOINT", dashboard.GetEndpoint("otlp-grpc"))
        .WithEnvironment("ASPIRE_OTLP_HTTP_ENDPOINT", dashboard.GetEndpoint("otlp-http"))
        // OTLP header carries the API key. Read from config at run time; the
        // AppHost never persists it.
        .WithEnvironment("OTEL_EXPORTER_OTLP_HEADERS", $"x-otlp-api-key={otlpApiKey}");
}

builder.Build().Run();

static string NewHexToken(int bytes = 32)
{
    var buffer = RandomNumberGenerator.GetBytes(bytes);
    return Convert.ToHexString(buffer).ToLowerInvariant();
}
