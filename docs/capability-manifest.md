# Capability manifest and offline resolver

`squad-capabilities.yml` lets a repository request execution capabilities without granting them. The manifest is parsed and resolved entirely offline by `worker/lib/parse-capabilities.js` and `worker/lib/resolve-capabilities.js`.

## Important guardrails

- Manifests are requests only.
- The default ACA job path is unchanged for repositories with no manifest.
- Unknown keys, duplicate keys, unsupported versions, wrong types, unknown identifiers, and unsafe control characters fail closed.
- Diagnostics are redacted. Errors never echo raw unknown keys, secret values, or unapproved image hints.
- Sandbox routing is descriptive only in Sprints 0-2. `config/sandbox-classes.json` contains design placeholders, not production-approved classes.

## Supported schema

```yaml
version: "1"
tools:
  - name: git
    required: true
credentials:
  - name: github-token
    required: true
services:
  - name: github-api
    required: true
egress:
  - name: github.com
    required: true
image:
  hint: container-build
  required: false
notes: "Optional human context"
```

Top-level keys are limited to:

- `version`
- `tools`
- `credentials`
- `services`
- `egress`
- `image`
- `notes`

`tools`, `credentials`, `services`, and `egress` accept lists of `{ name, required }` objects. `required` defaults to `true` when omitted. `image` accepts `{ hint, required }`.

See `docs/examples/squad-capabilities.example.yml` for a complete example.

## Routing outcomes

The resolver always returns machine-readable JSON with this shape:

- `schemaVersion`
- `route`: `aca-job`, `sandbox`, or `fail-closed`
- `sandboxClass`
- `requiredCapabilities`
- `optionalCapabilities`
- `unsatisfiedRequired`
- `fallbackReason`
- `manifestPresent`
- `manifestVersion`
- `defaultImageSufficient`

Routing rules:

1. No manifest -> `aca-job`
2. Manifest fully satisfied by the default worker image -> `aca-job`
3. Required capabilities not satisfied by the default worker but satisfied by an approved sandbox placeholder class -> `sandbox`
4. Optional-only gaps may still stay on `aca-job` if no approved sandbox class adds value
5. Required gaps with no approved match -> `fail-closed`

Unknown or unapproved `image.hint` values never grant execution. Required unknown hints fail closed. Optional unknown hints fall back to `aca-job` with a redacted diagnostic.

## Files and commands

- Worker preflight: `worker/lib/squad-capability-preflight.sh`
- Offline resolver: `node worker/lib/resolve-capabilities.js --cwd <repo>`
- PowerShell dry-run: `scripts/squad-aca.ps1 resolve [--manifest <path>]`
- Run-command dry-run: `scripts/squad-aca.ps1 run "prompt" --dry-run`

The worker entrypoint records the resolution before Squad starts. For Sprint 0-2 sandbox routes, the worker logs the sandbox class request but does not provision or enable SandboxGroups execution.
