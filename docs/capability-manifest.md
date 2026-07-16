# Capability-aware execution

Squad on ACA runs every session in the same fixed `squad-worker` image and
with a scoped user-assigned managed identity. That identity buys ACR pulls,
optional Key Vault reads, and (for Ralph) permission to start ACA job
executions. **It does not, and should not, buy GitHub credentials beyond
what's already wired in, arbitrary binaries, or open egress.**

Real repositories frequently need more than that fixed image provides:
language-specific SDKs and linters, browsers for UI tests, databases for
integration tests, private package feeds, or other external services. When a
session hits one of those gaps mid-task, the failure shows up late — after
Copilot has already spent time and tokens on a task that could never
succeed in this environment.

This document describes the capability manifest and preflight validation
that catches that class of failure at session start, with a clear,
actionable error, instead of Squad and the RAI/QA loop it drives.

## What ships in this phase

- A declarative **capability manifest** (`squad-capabilities.yml`, path
  configurable) that a repository can commit to describe what it needs from
  its execution environment.
- A **preflight validation step** that runs after the repository is cloned
  and before Squad/Copilot starts working, so unsupported tools/capabilities
  fail fast with an actionable message instead of failing mid-task.
- **Backward compatibility by default**: repositories with no manifest are
  completely unaffected. Nothing changes for existing sessions.
- Documented **extension points** for the harder, deliberately out-of-scope
  problems: per-task ACA SandboxGroup/image selection, controlled egress,
  short-lived credentials, and least-privilege per-task identities. These
  are not implemented here — this phase adds the seams they will plug into.

## The manifest

Add `squad-capabilities.yml` to the root of a repository that Squad on ACA
works on:

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
| `tools[]` | `name`, `required`, `reason` | A tool identifier matched against a **built-in allowlist** of fixed preflight checks. The manifest does not carry shell commands. |
| `credentials[]` | `name`, `required`, `reason` | An allowlisted environment variable name whose **presence** is checked. Values are never printed. |
| `services[]` | `name`, `required`, `reason` | An external service the task depends on (for example a database). The worker cannot safely auto-provision or reach arbitrary services, so these are **advisory-only documented dependencies**. `required: true` is **not supported** and is rejected at validation (see below) — declare services `required: false`. |
| `egress[]` | `host`, `reason` | A network destination the task needs to reach. Advisory only today. |
| `image` | `hint`, `reason` | Advisory pointer to a worker image that would satisfy this repo's needs. Not auto-applied today. |
| `notes` | string | Free-form guidance for humans or agents. |

Validation is strict and fail-closed:

- `version` is required and must be supported.
- Duplicate keys are rejected at every mapping level (top-level and nested
  entries); the parser never allows "last one wins" overwrites.
- Top-level keys outside the schema above are rejected.
- Field types are enforced strictly (`required` must be a boolean, arrays must
  actually be arrays, strings must be strings).
- Unknown keys inside list items/maps are rejected.
- `services` are advisory-only. A service declared `required: true` is rejected
  at validation with an actionable error, because the worker cannot validate
  external service reachability without expanding network egress (which is out
  of scope for this phase). Declare service dependencies `required: false`, or
  provision and verify them out of band.
- Manifest identifiers that cross execution/logging boundaries are validated
  against safe allowlists (`tools[].name`, `credentials[].name`,
  `services[].name`, `egress[].host`, `image.hint`) so control characters and
  delimiter-smuggling payloads are rejected.
- Validation errors never echo raw manifest key names or values back to logs
  or the terminal. Unknown/duplicate keys and invalid values are reported using
  safe location info only (e.g. "unrecognized key (redacted) at line 12",
  "duplicate key (redacted) ... first seen at line 4"), and every error string
  is sanitized so control characters (ANSI escapes, CR/LF, BEL, etc.) cannot be
  used for log/terminal injection.
- A malformed manifest is a hard startup error, not a silent no-op.

The parser (`worker/lib/parse-capabilities.js`) supports a deliberately
restricted YAML subset — one level of list-of-maps or map nesting under a
top-level key — so it can be parsed reliably without a third-party YAML
dependency in the worker image. See the parser's header comment for the
exact grammar, and `worker/tests/` for coverage.

### Built-in allowlists

Current tool identifiers with built-in checks:

- `az`, `bash`, `cargo`, `curl`, `docker`, `dotnet`, `gh`, `git`, `go`,
  `java`, `javac`, `jq`, `kubectl`, `make`, `mvn`, `node`, `npm`, `pip`,
  `pip3`, `pnpm`, `python`, `python3`, `rustc`, `sh`, `terraform`, `yarn`

Current credential identifiers with built-in presence checks:

- `ACA_SESSION_JOB_NAME`, `ACR_PASSWORD`, `ACR_USERNAME`,
  `AZURE_CLIENT_ID`, `AZURE_RESOURCE_GROUP`, `AZURE_SUBSCRIPTION_ID`,
  `AZURE_TENANT_ID`, `COPILOT_GITHUB_TOKEN`, `DOCKER_PASSWORD`,
  `DOCKER_USERNAME`, `GH_TOKEN`, `GITHUB_TOKEN`, `NODE_AUTH_TOKEN`,
  `NPM_TOKEN`

Unknown tool/credential names are never executed. Required unknown names fail
preflight with an actionable error; optional unknown names are surfaced as
advisories.

## Preflight validation

`worker/lib/squad-capability-preflight.sh` runs from `entrypoint.sh`
immediately after the repository clone/checkout and before Squad/Copilot
starts:

1. If no manifest is present at the configured path (default:
   `squad-capabilities.yml`), preflight is a no-op. This is what keeps the
   feature fully backward compatible.
2. If a manifest is present but malformed, preflight fails fast (exit `78`)
   with a parser error pointing at the offending field.
3. For each declared item:
   - **`tools` and `credentials` marked `required: true`** are checked
     against the running worker using fixed, internally-defined checks.
     Any gap is a **blocking failure**.
   - **Everything else** — optional tools/credentials, advisory `services`,
     `egress`, and `image` hints — is **advisory only**. It's printed so the
     session log makes the gap visible, but it never blocks the session.
     The worker cannot safely guarantee network reachability or spin up
     services, so treating these as hard failures would produce false
     negatives. (A service declared `required: true` is not advisory — it is
     rejected earlier at manifest validation, per the schema rules above.)
4. On a blocking failure, preflight prints one actionable line per gap
   (what's missing and how to fix it) and exits `78` (`EX_CONFIG`).
   Free-form manifest values are not echoed back in startup errors/logs; check
   the manifest file itself for the declared rationale. `entrypoint.sh` has
   `set -e`, so this exit code becomes the ACA job execution's exit code —
   visible in `squad-aca logs` and Aspire without any additional plumbing.

Preflight never creates temp files or directories inside the repository
working tree. Its scratch workspace is a fresh, unpredictable `0700` directory
created with `mktemp -d` under `${TMPDIR:-/tmp}` (outside the repo), verified to
be a real, self-owned directory outside the working tree, and removed by a
`trap` cleanup handler on every exit path. If a secure workspace cannot be
created and verified, preflight fails (`78`) rather than falling back to any
predictable path — so a pre-planted file or symlink at a guessable in-repo path
can never be followed by a redirect.

### Configuration

| Environment variable | Default | Effect |
| --- | --- | --- |
| `CAPABILITY_MANIFEST_PATH` | `squad-capabilities.yml` | Path to the manifest, relative to the repository root. |
| `SKIP_CAPABILITY_PREFLIGHT` | `false` | Set to `true` to bypass validation entirely (for example while iterating on a manifest). Bypassing is logged. |
| `SQUAD_CAPABILITY_PREFLIGHT` | _(unset)_ | Set to `disabled`/`off`/`false`/`0` to explicitly opt out of the entrypoint's fail-closed behavior when the packaged preflight script is absent (see below). |

### Fail-closed when the preflight script is missing

`entrypoint.sh` calls the packaged preflight script at
`/usr/local/lib/squad-on-aca/squad-capability-preflight.sh`. That script is
baked into the worker image alongside the entrypoint, so its absence means the
image was built or modified incorrectly. To avoid silently skipping validation
that a repository is relying on, the entrypoint **fails closed** (exit `78`)
when *all* of the following hold:

- the packaged preflight script is missing or not executable, **and**
- the checked-out repository declares a capability manifest at
  `CAPABILITY_MANIFEST_PATH`, **and**
- preflight has not been explicitly disabled via
  `SQUAD_CAPABILITY_PREFLIGHT` (`disabled`/`off`/`false`/`0`) or
  `SKIP_CAPABILITY_PREFLIGHT=true`.

When no manifest is present, or preflight is explicitly disabled, a missing
script is logged and the session continues — preserving backward compatibility
for repositories that never adopted a manifest.

## Extending the worker image

If a repository needs tools the fixed `squad-worker` image doesn't carry
(a language SDK, a browser, a database client, a build tool), the supported
path today is a **custom worker image that extends the published one**:

```dockerfile
FROM <your-acr>.azurecr.io/squad-worker:latest

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*
USER squad
```

Build and push it with `az acr build`, then point the ACA session/Ralph/watch
jobs at the new image tag (see `docs/runbook.md` for the job resource names).
Reference the custom image in `image.hint` in the manifest so the gap is
self-documenting even before automatic image selection exists (see below).

## What's deliberately out of scope in this phase

These are real, valuable next steps that the manifest is designed to feed,
but they need more design/security review than fits in one PR:

### Future: per-task images and SandboxGroups

ACA SandboxGroups (or a fleet of prebuilt, purpose-specific worker images)
could let a task's declared `image.hint` or `tools[]` list drive **automatic
selection** of the execution environment, instead of a human manually
rebuilding and repointing jobs. The manifest's `image` field and `tools[]`
list are the intended input to that selection logic once it exists.

### Future: controlled egress

`egress[]` entries are advisory today because the worker's network policy
is not manifest-driven. A follow-up could generate scoped egress rules (for
example, ACA environment network rules or a proxy allowlist) from the
declared `egress[]` hosts, so a task gets exactly the network access it
declared needing — no more, no less.

### Future: short-lived, least-privilege credentials

Today, GitHub access is a long-lived `GITHUB_TOKEN`/`COPILOT_GITHUB_TOKEN`
pair provisioned once at deploy time, and Azure access is the same
user-assigned managed identity for every session. The `credentials[]` list
is a natural input to a future design that mints **short-lived, per-task
GitHub App installation tokens** scoped to only what a task's manifest
declares needing, and/or a **per-task Azure identity** with only the
permissions that task's declared `services`/`tools` require. This PR does
not change the managed identity's permissions or introduce any new Azure
role assignments — it only adds the declarative input those future changes
would consume.

None of the above is implemented by this PR. This PR only adds the manifest
schema, the preflight check, and the documented seams above so future work
has a concrete, tested foundation to extend rather than needing to
retrofit one.
