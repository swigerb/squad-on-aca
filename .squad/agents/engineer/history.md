# engineer History

## 2026-07-15: Initial charter

Created as the primary code-writing agent for Squad on ACA. Code-writing work should use `claude-opus-4.8` and should be routed here by default.

## 2026-07-28: Sprint 0 — baseline test-harness guardrails (issue #6)

Branch `squad/6-s0-baseline-guardrails`. Guardrails only — no SandboxGroups
feature work.

- **Harness self-test.** Added `worker/tests/test_run_tests.sh` (43 assertions).
  It runs the real `run-tests.sh` against a throwaway directory of synthetic
  suites via a new `SQUAD_ACA_TEST_DIR` override and asserts exit code, banner,
  and suite counts for fail / non-1 fail / pass / mixed / skip / skip+fail /
  all-skipped / empty dir / default discovery. Closes the PR #9 bug class, where
  `status=$?` was captured inside `if ! bash "$test_script"` (always 0) so a
  failing suite still printed the success banner and exited 0.
- **Runner accounting.** `run-tests.sh` now captures each suite's real exit
  code, counts passed/failed/skipped, prints a skip summary, and refuses to
  print the success banner when no suite executed (empty dir or all skipped).
  Default behaviour with the override unset is unchanged.
- **Declared dependencies.** New `worker/tests/lib/deps.sh` — `require_deps`
  emits a visible `SKIP: <suite> — missing <dep>` and exits 77 (never a pass),
  and never downloads a runtime. Existing suites declare git / node / mktemp /
  date.
- **CI.** `worker-tests.yml` path filters broadened to `scripts/**`, `config/**`
  (existing paths kept); the worker job now fails if any suite SKIPs on CI; new
  `powershell-validation` job runs `scripts/validate.ps1` on `windows-latest`
  with pre-installed pwsh (nothing downloaded).
- **Docs.** `docs/validation.md` gained a "Worker test harness guarantees"
  section: self-test, skip semantics, Linux-only constraint, and the CI
  PowerShell job rationale.

**Evidence** (WSL Ubuntu, Node 24.12.0, `bash worker/tests/run-tests.sh`):
before 4 suites / 136 assertions (11/62/40/23), after 5 suites / 179 assertions
(11/62/40/23/43) — the 136 pre-existing assertions are unchanged and green.
Re-injecting the PR #9 pattern makes `test_run_tests.sh` fail with 20+ assertion
failures and exit 1; injecting a failing assertion into `test_git_checkout.sh`
makes the runner print "One or more worker capability test suites FAILED." and
exit 1. Removing `node` from PATH produces three visible `SKIP:` lines,
`Suites: 2 passed, 0 failed, 3 skipped.`, and trips the new CI skip guard.
`scripts/validate.ps1` unchanged at 35 passed / 0 failed.

**Not done:** `scripts/validate.ps1` is still Windows-only (Windows path
separators), so the PowerShell CI job runs on `windows-latest` rather than
`ubuntu-latest`. Making it cross-platform is a control-plane change, out of
scope for a tests/CI/docs-only sprint; recorded as a follow-up in
`docs/validation.md`.

## 2026-07-28: Sprint 2 — capability routing decision (issue #6)

Branch `squad/6-s2-capability-resolution`. Routing decision only: computed and
reported, never acted upon. No sandbox is created, no dispatch changes, no
execution-path changes.

- **Resolver.** New `worker/lib/resolve-capability-route.js` builds on the
  existing `parse-capabilities.js` (requires and reuses its parser/validator;
  that file is untouched) and emits stable JSON — `schemaVersion`, `route`,
  `reason`, `requiredTools[]`, `requiredCredentials[]`, `egressHosts[]`,
  `imageHint`, `defaultImageSufficient`, `sandboxClass`, `manifestPresent`,
  `manifestVersion`, plus hint provenance, unsatisfied-requirement lists,
  catalog provenance, and a fixed `detail` string. Fixed key order, arrays
  de-duplicated and sorted by code unit, so it is golden-testable and diffable.
  Routes: no manifest → `aca-job` (preserved byte-for-byte), satisfied by the
  default profile → `aca-job`, exceeds it with an approved class → `sandbox`,
  otherwise → `fail-closed`. Malformed/invalid manifests, unsafe manifest
  paths, and unusable catalogs all fail closed, never a silent `aca-job`.
- **Administrator catalog.** New `config/sandbox-classes.json`, control-plane
  owned and explicitly not repository-controlled. Each class pins id, image
  reference, resource limits, tools, egress host templates, allowed credential
  types, and concurrency/cost limits; `defaultWorker` captures the current ACA
  job profile so "satisfied by the default image" is data, not a hard-coded
  branch. `egress` mirrors the real ACA Sandboxes policy shape
  (`Microsoft.App/sandboxGroups`, `2026-02-01-preview`): `defaultAction` +
  ordered `hostRules[]` of `{pattern, action}` + `trafficInspection`. Ships
  `provisional: true` with a `$comment` header; every value is placeholder data
  pending administrator review, and the decision surfaces `catalogProvisional`.
- **Security invariants.** A manifest can only *request*; everything grantable
  comes from the catalog. `image.hint` only disambiguates among approved
  classes and is never used as an image reference — the emitted `imageHint` is
  always a catalog-owned string or `null`, so a path-traversal-shaped hint
  resolves to `null` and never reaches the output. Repository egress entries can
  only narrow within a class template. Output carries names/counts/fixed reason
  codes only; free-form `reason`/`notes` text never appears. An identifier that
  is character-safe but implausibly long fails closed without being echoed.
- **Preflight untouched as the final gate.** `squad-capability-preflight.sh`
  changed only in two comment/doc-anchor strings (the renamed
  `#future-per-task-images-and-sandboxes` heading and the corrected product
  name); no logic, no guard, no exit code changed.
- **Tests.** New `worker/tests/test_capability_routing.sh` (123 assertions) in
  the existing style with `lib/assert.sh` + `require_deps node`, golden JSON in
  `worker/tests/expected/` and manifests in `worker/tests/fixtures/routing-*.yml`.
  Covers no-manifest, satisfied-by-default, sandbox-matched, no-matching-class,
  egress-outside-template, malformed, unknown keys, duplicate keys, wrong types,
  control characters, oversized tool/host/hint identifiers, path-traversal and
  injection-shaped values (proving nothing leaks), symlink/absolute/escaping
  manifest paths, catalog faults (missing, unparseable, unsupported schema),
  egress wildcard semantics including suffix-smuggling, and determinism under
  reordered/duplicated entries.
- **CI/docs.** `worker-tests.yml` syntax gate now `node --check`s the resolver
  and parses the catalog. `docs/capability-manifest.md` gained the routing
  contract and catalog documentation; `docs/validation.md` gained the golden
  fixture workflow and the new suite's dependencies; terminology corrected from
  "SandboxGroups" to Azure Container Apps Sandboxes across docs.

**Evidence** (WSL Ubuntu, Node 24.12.0, `bash worker/tests/run-tests.sh`):
before 5 suites / 179 assertions (11/62/40/23/43), after 6 suites / 302
assertions (123/11/62/40/23/43) — the 179 pre-existing assertions are unchanged
and green, `Suites: 6 passed, 0 failed, 0 skipped.` Mutation-tested the new
suite: making unapproved classes selectable fails 5 assertions, echoing the raw
manifest hint fails 3, routing an invalid manifest to `aca-job` fails 32, and
removing the identifier length bound fails 3.

**Not done:** neither the resolver nor the catalog is copied into the worker
image, and nothing calls the resolver — deliberate, since Sprint 2 must not
change the execution path. The resolver mirrors rather than shares the
preflight's hardened manifest-path resolution, because modifying the shipped
preflight was out of scope; unifying them is recorded as a follow-up in
`docs/capability-manifest.md`. The catalog remains `provisional: true` and must
be reviewed before Sprint 5 acts on any decision.