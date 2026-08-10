# Capability-aware execution

A repository can commit `squad-capabilities.yml` to declare the tools, credentials, services, and egress it needs. The worker checks the manifest before the agent starts and the control plane uses it to route to ACA Jobs, ACA Sandboxes, or fail closed.

## What you get

- A declarative manifest at `squad-capabilities.yml` by default.
- A preflight check after clone and before Squad/Copilot starts.
- Capability routing to the default ACA job, an approved sandbox class, or fail-closed.
- An administrator sandbox class catalog at `config/sandbox-classes.json`.
- No behavior change for repositories without a manifest.

## Manifest

Add `squad-capabilities.yml` to the repository root:

```yaml
version: 1

tools:
  - name: docker
    required: true
    reason: Needed to build and test the container image
  - name: pnpm
    required: false
    reason: Only needed for the monorepo build; falls back to npm

credentials:
  - name: NPM_TOKEN
    required: true
    reason: Auth for a private npm registry used by this repo

services:
  - name: postgres
    required: false
    reason: Integration tests expect a local Postgres instance

egress:
  - host: registry.npmjs.org
    reason: Package installs during build

image:
  hint: ghcr.io/example/squad-worker-python:latest
  reason: Needs a pinned Python 3.12 + Poetry toolchain

notes: Bootstrap notes for humans or agents working on this repo.
```

### Schema

| Key | Shape | Meaning |
| --- | --- | --- |
| `version` | integer | Manifest schema version. Required. Currently only literal `1` is supported. |
| `tools[]` | `name`, `required`, `reason` | Tool identifier matched against a built-in allowlist of fixed preflight checks. The manifest does not carry shell commands. |
| `credentials[]` | `name`, `required`, `reason` | Allowlisted environment variable name whose presence is checked. Values are never printed. |
| `services[]` | `name`, `required`, `reason` | External service dependency. `required: true` is rejected; declare services `required: false`. |
| `egress[]` | `host`, `reason` | Network destination. Enforced on ACA Sandboxes when allowed by the class template. Advisory on ACA Jobs. |
| `image` | `hint`, `reason` | Advisory pointer used to select among approved sandbox classes. It is not auto-applied as an image. |
| `notes` | string | Free-form guidance for humans or agents. |

Validation rules:

- `version` is required and must be supported.
- Duplicate keys are rejected at every mapping level.
- Top-level keys outside the schema are rejected.
- Field types are enforced strictly.
- Unknown keys inside list items/maps are rejected.
- `services[].required: true` is rejected.
- Manifest identifiers are validated against safe allowlists.
- Validation errors use safe location info and do not echo free-form values.
- A malformed manifest is a hard startup error.

The parser is `worker/lib/parse-capabilities.js`.

### Built-in allowlists

Current tool identifiers:

- `az`, `bash`, `cargo`, `curl`, `docker`, `dotnet`, `gh`, `git`, `go`, `java`, `javac`, `jq`, `kubectl`, `make`, `mvn`, `node`, `npm`, `pip`, `pip3`, `pnpm`, `python`, `python3`, `rustc`, `sh`, `terraform`, `yarn`

Current credential identifiers:

- `ACA_SESSION_JOB_NAME`, `ACR_PASSWORD`, `ACR_USERNAME`, `AZURE_CLIENT_ID`, `AZURE_RESOURCE_GROUP`, `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `COPILOT_GITHUB_TOKEN`, `DOCKER_PASSWORD`, `DOCKER_USERNAME`, `GH_TOKEN`, `GITHUB_TOKEN`, `NODE_AUTH_TOKEN`, `NPM_TOKEN`

Required unknown tool or credential names fail preflight. Optional unknown names are reported as advisories.

## Preflight validation

`worker/lib/squad-capability-preflight.sh` runs from `entrypoint.sh` after repository clone/checkout and before Squad/Copilot starts.

| Situation | Result |
| --- | --- |
| No manifest at `CAPABILITY_MANIFEST_PATH` | No-op |
| Manifest malformed | Exit `78` with a parser error |
| Required tool absent | Blocking failure |
| Required credential absent | Blocking failure |
| Optional tool/credential absent | Advisory |
| `services`, `egress`, `image` hints | Advisory in preflight |

On a blocking failure, preflight prints one actionable line per gap and exits `78` (`EX_CONFIG`).

### Configuration

| Environment variable | Default | Effect |
| --- | --- | --- |
| `CAPABILITY_MANIFEST_PATH` | `squad-capabilities.yml` | Path to the manifest, relative to the repository root. |
| `SKIP_CAPABILITY_PREFLIGHT` | `false` | Set to `true` to bypass validation entirely. Bypassing is logged. |
| `SQUAD_CAPABILITY_PREFLIGHT` | unset | Set to `disabled`/`off`/`false`/`0` to explicitly opt out when the packaged preflight script is absent. |

`entrypoint.sh` calls `/usr/local/lib/squad-on-aca/squad-capability-preflight.sh`. If a repository declares a manifest and the packaged script is missing or not executable, the entrypoint exits `78` unless preflight is explicitly disabled.

## Capability routing

Run the resolver directly:

```bash
node worker/lib/resolve-capability-route.js <repo-dir> \
  [--manifest-path <relative>] [--catalog <path>] [--pretty]
```

The resolver writes one JSON object to stdout.

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | Decision schema version. Currently `1`. |
| `route` | `aca-job`, `sandbox`, or `fail-closed` | Where this repository should run. |
| `reason` | string | Stable reason code. |
| `requiredTools[]` | string[] | Sorted, de-duplicated required tools. |
| `requiredCredentials[]` | string[] | Sorted, de-duplicated required credentials. |
| `egressHosts[]` | string[] | Sorted, de-duplicated egress hosts. |
| `imageHint` | string or null | Catalog-owned hint value or `null`. |
| `defaultImageSufficient` | boolean | Whether the default worker profile satisfies every required capability. |
| `sandboxClass` | string or null | Selected approved class id. |
| `manifestPresent` | boolean | Whether a manifest file exists. |
| `manifestVersion` | integer or null | Manifest version. |
| `imageHintPresent` | boolean | Whether `image.hint` was declared. |
| `imageHintRecognized` | boolean | Whether the hint matched an approved class alias. |
| `unsatisfiedTools[]` | string[] | Required tools no approved class provides. |
| `unsatisfiedCredentials[]` | string[] | Required credentials no approved class permits. |
| `unsatisfiedEgressHosts[]` | string[] | Declared hosts no approved class template permits. |
| `egressEnforced` | boolean | Whether the selected profile carries an egress policy the plane applies. |
| `egressAdvisoryHosts[]` | string[] | Declared hosts not enforced on the selected plane. |
| `catalogSchemaVersion` | integer or null | Catalog schema version. |
| `catalogProvisional` | boolean | `true` when the catalog is report-only. |
| `detail` | string | Fixed actionable sentence for the reason. |

### Routing rules

| Situation | Route | `reason` |
| --- | --- | --- |
| No manifest at the configured path | `aca-job` | `no-manifest` |
| Every required capability is in the default worker profile | `aca-job` | `default-profile-satisfies-manifest` |
| Requirements exceed the default profile and an approved class provides all of them | `sandbox` | `approved-sandbox-class-matched` |
| Requirements exceed the default profile and no approved class covers them | `fail-closed` | `no-approved-sandbox-class` |
| Manifest fails parsing or schema validation | `fail-closed` | `manifest-invalid` |
| Manifest exists but cannot be read | `fail-closed` | `manifest-unreadable` |
| Manifest path is absolute, escapes the repo, or is a symlink | `fail-closed` | `manifest-path-unsafe` |
| A manifest identifier is character-safe but out of bounds | `fail-closed` | `manifest-identifier-unsafe` |
| Administrator catalog is missing, unreadable, or invalid | `fail-closed` | `catalog-unavailable` |

Exit codes are `0` for a produced decision, `64` for usage errors, and `70` for an unusable administrator catalog.

### Routing configuration

| Environment variable | Default | Effect |
| --- | --- | --- |
| `CAPABILITY_MANIFEST_PATH` | `squad-capabilities.yml` | Manifest path, relative to the repository root. |
| `SQUAD_SANDBOX_CLASS_CATALOG` | unset | Absolute path to the sandbox class catalog. When set, that path is authoritative. |

With neither set, the resolver looks for a packaged catalog beside the worker libraries, then for `config/sandbox-classes.json`.
## Sandbox class catalog

`config/sandbox-classes.json` is the control-plane-owned catalog of what execution environments may provide.

| Key | Meaning |
| --- | --- |
| `schemaVersion` | Catalog schema version. Currently `1`. |
| `provisional` | `true` until the catalog is reviewed. Consumers treat a provisional catalog as report-only. |
| `defaultWorker` | The fixed `squad-worker` ACA job profile: `id`, `tools[]`, `credentials[]`, `egress`. |
| `classes[]` | The sandbox classes. |

Each class pins:

| Key | Meaning |
| --- | --- |
| `id` | Stable class identifier. |
| `approved` | Whether the class can be selected. |
| `image` | Pinned image reference: `reference`, `tag`, `digest`, `pinned`. |
| `imageHintAliases[]` | Manifest `image.hint` values that may select this class. |
| `resources` | CPU / memory / ephemeral storage limits. |
| `tools[]` | Built-in tools the class provides. |
| `allowedCredentials[]` | Credential types that may be injected into the class. |
| `egress` | Permitted-destination template. |
| `limits` | `maxConcurrentSandboxes`, `maxSessionMinutes`, `maxMonthlyCostUsd`. |

### Egress templates

```jsonc
"egress": {
  "defaultAction": "Deny",
  "trafficInspection": "Full",
  "hostRules": [
    { "pattern": "*.github.com", "action": "Allow" },
    { "pattern": "registry.npmjs.org", "action": "Allow" }
  ]
}
```

Matching semantics:

- `*.example.com` matches hosts ending in `.example.com`; list `example.com` separately for the apex.
- Any other pattern is an exact, case-insensitive host match.
- An explicit `:<port>` on a declared host does not change host matching.
- Rules are evaluated in order; the first match wins.
- `defaultAction` applies when nothing matches.
- No other wildcard form is supported.

`defaultWorker` uses `defaultAction: "Allow"` because the ACA Jobs plane has no per-execution egress policy.

### Review status and image evidence

A reviewed catalog has `"provisional": false`. Every approved class must pin an image by digest and have a committed evidence file for that digest.

Evidence path:

```text
config/image-evidence/<digest-with-':'-replaced-by-'-'>.json
```

Evidence file shape:

```jsonc
{
  "schemaVersion": 1,
  "image": {
    "reference": "acrsquadacah81u42kq.azurecr.io/squad-worker-python",
    "digest": "sha256:748bcf32..."
  },
  "verifiedAt": "2025-06-05T00:00:00Z",
  "method": "aca-sandbox-exec: command -v <tool> inside a sandbox booted from the pinned digest",
  "tools": { "present": ["bash", "..."], "absent": ["pnpm"] },
  "toolVersions": { "python3": "Python 3.12.13" }
}
```

Run the offline checker directly or through `scripts/validate.ps1`:

```powershell
node worker/lib/verify-image-evidence.js
node worker/lib/verify-image-evidence.js --json
```

Approved classes in a reviewed catalog require evidence. Provisional classes are report-only. Unapproved classes do not require evidence, but any evidence file they carry must be well formed.

## Extending the worker image

If a repository needs tools the fixed `squad-worker` image does not carry, extend the published worker image:

```dockerfile
FROM <your-acr>.azurecr.io/squad-worker:latest

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*
USER squad
```

Always extend the published worker. A sandbox worker still needs `entrypoint.sh`, the capability preflight, and the dispatch core under `/usr/local/lib/squad-on-aca/`.

`worker/images/python/Dockerfile` is the worked example for `sandbox-python-3-12`.

Build and push with `az acr build`, then point the ACA session/Ralph/watch jobs at the new image tag. Reference the custom image in `image.hint` so the requirement is visible.

If you add the image to the sandbox class catalog, run live image verification and commit the evidence file with the catalog change. See [runbook.md#add-or-re-pin-a-sandbox-class-image](runbook.md#add-or-re-pin-a-sandbox-class-image).

## Limits

| Declared | ACA Jobs (default) | ACA Sandboxes (opt-in) |
|---|---|---|
| `tools[]` | Must already be in the worker image, or the session fails preflight | An approved class whose image provides them |
| `image.hint` | Ignored by ACA Jobs | Selects among approved classes |
| `egress[]` | Reported as advisory | Enforced before repository code runs |
| `credentials[]` | The pair wired at deploy time | The subset the class permits, delivered per session |
| `services[]` | Advisory; `required: true` is rejected | Advisory; `required: true` is rejected |

A manifest requests capabilities. It cannot add a class, add an egress destination, widen a credential list, or name an image reference for execution.

If you need enforced egress, use an approved sandbox class. ACA Jobs report `egressEnforced: false` and list declared hosts as advisory.

Sessions authenticate with tokens provisioned through the deployment or per-session sandbox credential path. See [runbook.md#credentials](runbook.md#credentials).

