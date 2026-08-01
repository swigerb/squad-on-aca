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
- A **routing decision** (`worker/lib/resolve-capability-route.js`) that turns a
  manifest into deterministic, machine-readable JSON: run on the existing ACA
  job, run in an administrator-approved sandbox class, or fail closed. The
  decision is **computed and reported but not acted upon** — see
  [Capability routing](#capability-routing).
- An **administrator sandbox class catalog** (`config/sandbox-classes.json`)
  that is the only source of grantable capability — see
  [The sandbox class catalog](#the-sandbox-class-catalog).
- **Backward compatibility by default**: repositories with no manifest are
  completely unaffected. Nothing changes for existing sessions.
- Documented **extension points** for the harder, deliberately out-of-scope
  problems: per-task ACA Sandboxes/image selection, controlled egress,
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
| `egress[]` | `host`, `reason` | A network destination the task needs to reach. **Enforced on the ACA Sandboxes plane** (it narrows the approved class's default-deny template, and a destination the template does not already permit is a hard failure); **advisory on the ACA Jobs plane**, which has no per-execution network control. See [What's deliberately out of scope in this phase](#whats-deliberately-out-of-scope-in-this-phase). |
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

## Capability routing

Preflight answers "can *this* worker satisfy the manifest?" at session start.
Routing answers the earlier question: "**which** execution environment should
this repository get at all?"

```bash
node worker/lib/resolve-capability-route.js <repo-dir> \
  [--manifest-path <relative>] [--catalog <path>] [--pretty]
```

> **The decision is computed and reported, not acted upon.** Nothing in this
> phase creates a sandbox, changes dispatch, or changes the execution path. The
> in-worker preflight remains the **final** safety check no matter what the
> resolver decided earlier — a route is a hint about where to run, never a
> substitute for verifying the environment that actually booted.

The resolver consumes the manifest that `parse-capabilities.js` already parses
and validates; it never re-implements parsing or relaxes validation.

### The routing contract

The resolver writes one JSON object to stdout. Keys are emitted in a fixed
order and every array is de-duplicated and sorted by code unit, so the output is
stable enough to golden-test and to diff between runs.

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | Decision schema version. Currently `1`. |
| `route` | `aca-job` \| `sandbox` \| `fail-closed` | Where this repository should run. |
| `reason` | string | A stable code from a fixed vocabulary (below). Never interpolated from manifest input. |
| `requiredTools[]` | string[] | Sorted, de-duplicated `tools[].name` where `required: true`. |
| `requiredCredentials[]` | string[] | Sorted, de-duplicated `credentials[].name` where `required: true`. |
| `egressHosts[]` | string[] | Sorted, de-duplicated `egress[].host`. |
| `imageHint` | string \| null | **Always a catalog-owned string or `null`** — the matched `imageHintAliases` entry, never raw manifest text. |
| `defaultImageSufficient` | boolean | Whether the default worker profile already satisfies every required capability. |
| `sandboxClass` | string \| null | The selected approved class id, or `null`. |
| `manifestPresent` | boolean | Whether a manifest file exists at the configured path. |
| `manifestVersion` | integer \| null | The manifest's declared `version`, or `null` when it could not be established. |
| `imageHintPresent` | boolean | Whether the manifest declared `image.hint` at all. |
| `imageHintRecognized` | boolean | Whether that hint matched an approved class alias. |
| `unsatisfiedTools[]` | string[] | Required tools that **no** approved class provides. |
| `unsatisfiedCredentials[]` | string[] | Required credentials that **no** approved class permits. |
| `unsatisfiedEgressHosts[]` | string[] | Declared hosts that **no** approved class's egress template permits. |
| `catalogSchemaVersion` | integer \| null | Schema version of the catalog that produced this decision. |
| `catalogProvisional` | boolean | `true` while the catalog is unreviewed. Consumers must treat a provisional catalog as report-only. |
| `detail` | string | A fixed, actionable sentence for the `reason`. Never contains manifest text. |

### Routing rules

| Situation | Route | `reason` |
| --- | --- | --- |
| No manifest at the configured path | `aca-job` | `no-manifest` |
| Every required capability is in the default worker profile | `aca-job` | `default-profile-satisfies-manifest` |
| Requirements exceed the default profile and an **approved** class provides all of them | `sandbox` | `approved-sandbox-class-matched` |
| Requirements exceed the default profile and no approved class covers them | `fail-closed` | `no-approved-sandbox-class` |
| Manifest fails parsing or schema validation | `fail-closed` | `manifest-invalid` |
| Manifest exists but cannot be read | `fail-closed` | `manifest-unreadable` |
| Manifest path is absolute, escapes the repo, or is a symlink | `fail-closed` | `manifest-path-unsafe` |
| A manifest identifier is character-safe but out of bounds | `fail-closed` | `manifest-identifier-unsafe` |
| The administrator catalog is missing, unreadable, or invalid | `fail-closed` | `catalog-unavailable` |

The **no-manifest case is the overwhelmingly common one and is preserved exactly**:
it routes to the existing ACA job with no requirements, no class, and no
image hint. A malformed manifest is never quietly downgraded to `aca-job`.

Exit codes: `0` whenever a decision was produced (including `fail-closed`, since
the decision itself carries the outcome), `64` for a usage error, and `70` when
the administrator catalog is unusable — a control-plane fault rather than a
repository fault. Even on `70` a `fail-closed` decision is still written to
stdout, so a caller that ignores exit codes still fails closed.

### Security invariants

These are non-negotiable and are covered by
`worker/tests/test_capability_routing.sh`:

1. **A manifest only requests capabilities; it can never grant them.** Every
   grantable capability comes from the administrator catalog. A manifest cannot
   add a class, add an egress destination, widen a credential list, name a
   shell command, or bypass approval.
2. **`image.hint` can only select among approved classes.** It is matched
   against a class's `imageHintAliases` purely to disambiguate, and is *never*
   used as, or turned into, an image reference. Because the emitted `imageHint`
   is echoed from the catalog rather than from the manifest, a
   path-traversal-shaped or otherwise hostile hint resolves to `null` and never
   appears in the output.
3. **Repository entries may only narrow.** A declared egress host that a
   class's template does not already permit disqualifies that class; it never
   widens it.
4. **Diagnostics are redacted.** Only allowlisted identifier *names*, fixed
   reason codes, and counts are emitted. Free-form manifest text (`reason`,
   `notes`, raw key names, values) never reaches the output, logs, or errors.
   An identifier that passes the parser's character allowlist but is
   implausibly long is refused **without being echoed**
   (`manifest-identifier-unsafe`).
5. **Anything ambiguous fails closed.** Malformed manifests, unsafe manifest
   paths, unreadable manifests, and unusable catalogs all produce
   `fail-closed`, never a silent `aca-job`.

### Configuration

| Environment variable | Default | Effect |
| --- | --- | --- |
| `CAPABILITY_MANIFEST_PATH` | `squad-capabilities.yml` | Manifest path, relative to the repository root. Same variable the preflight uses. |
| `SQUAD_SANDBOX_CLASS_CATALOG` | _(unset)_ | Absolute path to the sandbox class catalog. When set (or when `--catalog` is passed) that path is **authoritative**: an unusable catalog is an error, never a silent fall back to another one. |

With neither set, the resolver looks for a catalog packaged beside the worker
libraries, then for `config/sandbox-classes.json` in this repository.

## The sandbox class catalog

`config/sandbox-classes.json` is the administrator-controlled catalog of what an
execution environment may provide. It is owned by the **Squad on ACA control
plane** (this repository) and is deliberately **not** repository-controlled: a
worked-on repository can request capabilities in its manifest, but only this
catalog can grant them.

| Key | Meaning |
| --- | --- |
| `schemaVersion` | Catalog schema version. Currently `1`. |
| `provisional` | `true` until an administrator has reviewed every entry. Consumers must treat a provisional catalog as report-only. |
| `defaultWorker` | The current fixed `squad-worker` ACA job profile: `id`, `tools[]`, `credentials[]`, `egress`. This is what "satisfied by the default image" is measured against. |
| `classes[]` | The sandbox classes. |

Each class pins:

| Key | Meaning |
| --- | --- |
| `id` | Stable class identifier — the only class-derived value the routing decision emits. |
| `approved` | Whether an administrator has approved the class. **Only `true` classes can ever be selected.** |
| `image` | Pinned image reference (`reference`, `tag`, `digest`, `pinned`). Never emitted in a decision. |
| `imageHintAliases[]` | Manifest `image.hint` values that may disambiguate *to this class*. Matching is exact. |
| `resources` | CPU / memory / ephemeral storage limits. |
| `tools[]` | Built-in tools the class provides. For an **approved** class in a reviewed catalog this is a *verified inventory*, not an aspiration — see [Image evidence](#image-evidence). |
| `allowedCredentials[]` | Credential types that may be injected into the class. |
| `egress` | The permitted-destination template (below). |
| `limits` | Concurrency and cost ceilings (`maxConcurrentSandboxes`, `maxSessionMinutes`, `maxMonthlyCostUsd`). |

### Egress templates

`egress` mirrors the real Azure Container Apps Sandboxes network policy shape
(ARM type `Microsoft.App/sandboxGroups`, api-version `2026-02-01-preview`) so a
later sprint maps onto it without translation:

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

Matching semantics, as implemented and tested:

- `*.example.com` matches any host ending in `.example.com` (one or more leading
  labels) and deliberately **does not** match the bare apex `example.com`, which
  must be listed explicitly.
- Any other pattern is an exact, case-insensitive host match. An explicit
  `:<port>` on a declared host does not defeat the host match.
- Rules are evaluated in order; the **first match wins**; `defaultAction` applies
  when nothing matches.
- No other wildcard form is supported. Suffix-smuggling hosts such as
  `github.com.evil.net` do not match `*.github.com`.

`defaultWorker` is modelled with `defaultAction: "Allow"` because the current ACA
job has unrestricted egress. That is an accurate description of today's posture,
not an endorsement of it.

### Review status

The catalog is **reviewed** (`"provisional": false`). Two classes are approved
and pinned by digest; `sandbox-container-build` remains unapproved and is kept
deliberately as the negative fixture that proves an unapproved class can never
be selected.

`provisional` still means what it always meant: `true` marks the catalog as
report-only, and consumers must refuse to act on it. `validateCatalog` enforces
the extra obligations that come with `false` — every approved class must pin an
image by digest, and (see below) every approved class's tool claims must be
backed by recorded evidence for *that* digest.

The `defaultWorker.tools` list is deliberately **conservative**: it lists only
tools guaranteed by `worker/Dockerfile`. Under-claiming routes a repository
toward review rather than toward an unchecked run, which is the fail-closed
direction.

Squad workers must run in a **dedicated, identity-free sandbox group**: managed
identity on ACA Sandboxes is group-scoped, so an identity attached to the group
would be reachable from inside the sandbox. With no identity on the group,
in-sandbox token minting fails closed.

### Image evidence

A catalog that claims tools its image does not contain is a declaration nothing
verifies — the exact defect class this programme keeps rejecting. It is not a
theoretical risk: the first reviewed catalog pinned **both** approved classes to
the same `squad-worker` image and, between them, claimed `python3`, `pip3`,
`jq`, `make` and `pnpm` that image does not carry. A live end-to-end run routed
a Python repository to `sandbox-python-3-12` exactly as designed, created the
sandbox, applied default-deny egress, launched the worker — and only then did
the in-worker preflight refuse the session for missing `python3`/`pip3`. The
defence in depth worked. The claim should never have been made.

The fix is to make the claim **falsifiable**. Every approved class in a reviewed
catalog must have a committed evidence file recording what its pinned image was
observed to provide:

```
config/image-evidence/<digest-with-':'-replaced-by-'-'>.json
```

The filename is derived from the image digest, and that is the whole mechanism:
**re-pinning a class to a new digest changes the filename the offline check
looks for**, so a re-pin without a fresh verification run fails immediately.

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

`worker/lib/verify-image-evidence.js` is the offline checker. For each approved
class in a reviewed catalog it requires that:

- an evidence file exists at the digest-derived path (**missing evidence is a
  failure, never a skip**);
- the document is well formed — schema version, strict `YYYY-MM-DDTHH:MM:SSZ`
  timestamp, non-empty `method`, non-empty `tools.present`, no tool listed as
  both present and absent, tool names matching `^[A-Za-z0-9._-]{1,64}$`;
- the digest *inside* the document matches the digest the filename encodes, so
  an evidence file cannot be copied to a new name to fake coverage;
- the image `reference` matches the class's pinned reference, so evidence for a
  different repository in the same registry does not satisfy a class;
- **every tool the class declares appears in `tools.present`.** Declaring more
  than the image provides is the failure this exists to catch.

Run it directly, or as part of `scripts/validate.ps1`:

```powershell
node worker/lib/verify-image-evidence.js            # exit 0 = every claim backed
node worker/lib/verify-image-evidence.js --json     # machine-readable findings
```

Evidence is required for approved classes only when `provisional` is `false`,
mirroring the existing digest-pinning rule. A provisional catalog is already
report-only — the route gate refuses to act on it — so requiring evidence there
would block drafting without closing a hole. Unapproved classes need no
evidence, but any evidence file they *do* carry must still be well formed.

#### What CI proves, and what it does not

Be plain about the boundary, because the failure this mechanism exists to
prevent was itself an overstated claim:

- **CI proves the bookkeeping.** GitHub Actions cannot pull a private ACR image.
  The offline check therefore proves that evidence *exists for the digest pinned
  today*, that it is well formed, that it belongs to the pinned image reference,
  and that it covers every declared tool. It proves nothing about the bytes in
  the registry.
- **A live run proves the image.** `scripts/verify-image-tools.ps1` boots the
  pinned digest as a real ACA sandbox, runs `command -v` for every declared tool
  plus a control set, captures `--version` strings, and writes/refreshes the
  evidence file. That is the only step that observes image contents, and it
  requires an operator with Azure credentials. See `docs/runbook.md`.
- **The preflight remains the final check.** Evidence is a pre-commit guard, not
  a runtime one. `squad-capability-preflight.sh` still runs inside every worker
  and still refuses a session whose required tools are absent. There is no
  "catalog says so, skip the preflight" path and none will be added: the catalog
  describes an image, the preflight observes the container actually running.


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

Always extend the published worker rather than starting from a language base
image: a sandbox worker still needs `entrypoint.sh`, the capability preflight,
and the dispatch core under `/usr/local/lib/squad-on-aca/`.

`worker/images/python/Dockerfile` is the worked example that backs the
`sandbox-python-3-12` class. It is not the naive `apt-get install python3` above,
because Debian bookworm ships Python 3.11 and the class id promises 3.12; it
multi-stage-copies CPython 3.12 from `python:3.12-slim-bookworm` (only
`libpython3.12.so`, the stdlib, headers and entry points — never all of
`/usr/local`, which would clobber the Node toolchain) and ends with a build-time
smoke test that fails the build if Python, the Node toolchain, or any Squad
library is missing.

Build and push it with `az acr build`, then point the ACA session/Ralph/watch
jobs at the new image tag (see `docs/runbook.md` for the job resource names).
Reference the custom image in `image.hint` in the manifest so the gap is
self-documenting even before automatic image selection exists (see below).

If instead you are adding the image to the **sandbox class catalog**, the tool
list you write there is a claim that must be backed by a live verification run —
see [Image evidence](#image-evidence) and the runbook procedure.

## What's deliberately out of scope in this phase

> **Corrected 2026-08-01.** This section was written in the voice of the pull
> request that introduced the manifest, and several sprints have landed since.
> Four of its claims were stale and one concealed a live defect. The findings,
> the disposition of each effort, and the evidence are in
> [ADR 0003](adr/0003-capability-manifest-future-work.md); the scheduled work and
> how each sprint will be falsified are in
> [docs/plans/capability-manifest-future-work.md](plans/capability-manifest-future-work.md).
> The original text is preserved below with corrections marked, because what was
> believed at the time is part of the record.

These are real, valuable next steps that the manifest is designed to feed,
but they need more design/security review than fits in one PR.

### Future: per-task images and Sandboxes

Azure Container Apps Sandboxes (or a fleet of prebuilt, purpose-specific worker
images) could let a task's declared `image.hint` or `tools[]` list drive
**automatic selection** of the execution environment, instead of a human
manually rebuilding and repointing jobs.

The selection *decision* now exists — see
[Capability routing](#capability-routing) — and dispatch acts on it. What
landed:

- **A provider seam.** The decision has a consumer that creates and tears down a
  sandbox, with the ACA job remaining the default provider.
- **Acting on the decision.** `squad-aca run` resolves the manifest before
  requesting compute and dispatches to the plane the decision names.
  `fail-closed` stops a session rather than only being reported — a repository
  that needs a non-default capability is refused when the sandbox plane is off,
  never quietly downgraded.
- **Catalog review.** The catalog is reviewed (`provisional: false`), every
  approved class is pinned to an immutable `sha256` digest, and each class's
  declared tools are backed by digest-keyed evidence — so a class cannot claim a
  tool its image does not provide.

Still outstanding:

- **Packaging — and this is a live defect, not deferred work.**
  `worker/lib/resolve-capability-route.js` is copied into the worker image, but
  `config/sandbox-classes.json` is not. The original text described the
  consequence as "resolution for a dispatch runs control-plane side": true of the
  PowerShell CLI and of GitHub Actions, **but not of Ralph**, which runs *inside*
  the image on a five-minute cron and calls the same resolver. In the image
  neither default catalog search path exists, so every Ralph dispatch decision
  returns `catalog-unavailable` / `refuse` and Ralph skips the issue with a log
  line indistinguishable from a legitimate capability refusal. Verified by
  running the shipped entry point from an image-shaped directory. No test caught
  it because every routing assertion passes `--catalog` explicitly or runs from
  the repository tree. Scheduled as
  [sprint 1](plans/capability-manifest-future-work.md#sprint-1-ship-the-catalog-into-the-worker-image-and-prove-the-shipped-layout-resolves-a-route).
- **One manifest-path implementation.** The resolver mirrors the preflight's
  hardened manifest-path resolution rather than sharing it. Still true; the
  original text's *reason* — "the phase that introduced it deliberately did not
  modify the shipped `squad-capability-preflight.sh`", to be unified "when Sprint
  3 introduces the provider seam" — has expired. Sprint 3 landed, the provider
  seam exists, and the two copies have already begun to drift in how they handle
  an unreadable repository directory. Scheduled as
  [sprint 2](plans/capability-manifest-future-work.md#sprint-2-one-manifest-path-implementation).

Whatever consumes the decision, the in-worker preflight stays the final safety
check: routing chooses *where* to run, and preflight still verifies the
environment that actually booted.

### Future: controlled egress

> **Stale as originally written.** The paragraph below said `egress[]` entries
> "are advisory today because the worker's network policy is not manifest-driven".
> That is no longer true on the Sandboxes plane, and it understates a different
> problem on the Jobs plane. Corrected immediately after.

`egress[]` entries are advisory today because the worker's network policy
is not manifest-driven. A follow-up could generate scoped egress rules (for
example, ACA environment network rules or a proxy allowlist) from the
declared `egress[]` hosts, so a task gets exactly the network access it
declared needing — no more, no less.

**What is actually true.** On the **ACA Sandboxes** plane the policy *is*
manifest-driven and enforced before repository code runs:
`New-SandboxEgressPolicy` in
`scripts/lib/providers/squad-sandbox-provider.ps1` generates it from the
approved class template plus the manifest's request, where the request may only
narrow; refuses a class whose `defaultAction` is not `Deny`; refuses a requested
destination the template does not already permit; and asserts that every emitted
rule has template provenance. See
[ADR 0001, G4](adr/0001-aca-sandboxes-feasibility.md#g4--invariant-3-default-deny-capability-scoped-egress--pass).

On the **ACA Jobs** plane — the unconditional default and the rollback path —
there is no egress logic at all, and the situation is worse than "advisory". The
catalog declares the default worker's egress as
`{"defaultAction": "Allow", "hostRules": []}`, so the resolver reports a declared
destination as *satisfied* by a plane that will not enforce it, with
`unsatisfiedEgressHosts: []` and no field distinguishing the two cases.

Per-task egress enforcement on the Jobs plane is **rejected, not deferred**: ACA
Jobs has no per-execution network control, and the only lever — VNet-injecting
the shared Container Apps environment — is environment-wide rather than
capability-scoped and would perturb the rollback path itself. What is scheduled
instead is honesty: the routing decision must state whether the plane it names
will enforce the declared egress, and must stop reporting an unenforced
destination as satisfied. See
[sprint 3](plans/capability-manifest-future-work.md#sprint-3-stop-asserting-egress-is-satisfied-on-a-plane-that-does-not-enforce-it).
Until that lands, `squad-capability-preflight.sh` prints
`advisory only, not enforced yet` for a declared host even when the session is
running inside a sandbox that *is* enforcing it; that message is wrong on the
sandbox plane and sprint 3 corrects it.

### Future: short-lived, least-privilege credentials

> **Partly stale.** The description of today's credentials is still accurate, but
> the *consumption* half of short-lived credentials has since been built and
> proven, and the closing sentence about Azure role assignments no longer
> describes the tree.

Today, GitHub access is a long-lived `GITHUB_TOKEN`/`COPILOT_GITHUB_TOKEN`
pair provisioned once at deploy time, and Azure access is the same
user-assigned managed identity for every session. The `credentials[]` list
is a natural input to a future design that mints **short-lived, per-task
GitHub App installation tokens** scoped to only what a task's manifest
declares needing, and/or a **per-task Azure identity** with only the
permissions that task's declared `services`/`tools` require.

**What has since been built.** Issue #32 delivered the entire consumption side:
`worker/lib/squad-git-credential-helper.sh` re-reads a `0600` token file on every
git operation, so a refreshed token is picked up with no re-clone;
`worker/lib/squad-token-preflight.sh` exercises the credential and compares its
remaining lifetime against the estimated run duration before the agent starts;
and the sandbox provider delivers and can swap that file mid-session. A GitHub
App is registered and installed on this repository, and its installation-token
TTL is measured at exactly 3600 seconds. See
[Refresh channel matrix](sandboxes.md#refresh-channel-matrix).

**What is missing is minting, and it is deferred with no sprint.** The App's
private key was generated and deleted before being stored; Key Vault is unusable
in this tenant; and a 3600-second token cannot be refreshed inside a running ACA
Job, so per-task tokens on the default plane would refuse sessions that succeed
today. Two preconditions — measuring real session durations from existing lease
records, and deciding where the private key may live — must be answered before
any sprint is written. The reasoning, the rejected alternatives, and the likely
eventual shape are in
[ADR 0003, effort 4](adr/0003-capability-manifest-future-work.md#effort-4-short-lived-least-privilege-credentials).

**Correction:** the original text ended "This PR does not change the managed
identity's permissions or introduce any new Azure role assignments." That is no
longer a true statement about the tree. `scripts/deploy.ps1` creates `AcrPull` on
the ACR and `Contributor` at **resource-group scope** for the session identity,
and separately reconciles a `Microsoft.App/jobs`-scoped grant for the Actions
identity, because deleting and recreating the session job on an image change
destroys a resource-scoped assignment.

> **The original closing paragraph, now wholly stale**, read: "None of the above
> is implemented by this PR. This PR only adds the manifest schema, the preflight
> check, and the documented seams above so future work has a concrete, tested
> foundation to extend rather than needing to retrofit one." The routing
> decision, the provider seam, dispatch acting on the decision, catalog review
> with digest pinning, and digest-keyed image evidence have all since landed.

