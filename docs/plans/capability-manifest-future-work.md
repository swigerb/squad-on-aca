# Sprint plan: capability-manifest future work

**Companion to [ADR 0003](../adr/0003-capability-manifest-future-work.md)**,
which records why each of the four efforts in
`docs/capability-manifest.md` was scheduled, reduced, or deferred. Read it
first — this document assumes its findings.

**Three sprints are scheduled. The fourth effort has no sprint, deliberately**
(see [Not scheduled](#not-scheduled-short-lived-least-privilege-credentials)).

Every sprint below is sized to land as one reviewable pull request.

## The standard every sprint here is held to

This programme has rejected five pull requests and shipped several live defects,
and every one reduced to the same root cause: **a mechanism that was present,
correct, and never actually exercised.** So each sprint states a *mutation
table*: a specific change that, if made, must cause a specific named assertion
to fail. A test whose deliberate breakage cannot be described is decorative and
does not belong in the sprint.

Two mutation rules are applied throughout, because both have already cost this
repository a defect:

- **Both directions.** An assertion that a flag is `false` is satisfied by
  hard-coding `false`. Every boolean claim needs a paired case that must go the
  other way.
- **No explicit override in the test that production does not pass.** The
  packaging defect in [ADR 0003, finding 1](../adr/0003-capability-manifest-future-work.md#finding-1-the-packaging-gap-is-a-live-defect-not-deferred-work--verified)
  survived 911 assertions because every routing test passed `--catalog`
  explicitly. A test must invoke the code the way production invokes it.

## Regression contract

Unchanged and preserved by every sprint. ACA Jobs stays the unconditional
default and the rollback path; **no sprint here changes which route is chosen
for any manifest.**

| Gate | Value |
|---|---|
| `scripts/validate.ps1` | 363 / 0 / 0 (+ that sprint's new checks) |
| Worker suite (`worker/tests/run-tests.sh`, WSL) | 14 suites / 911 assertions (+ new) |
| CLI goldens | 26, byte-identical (sprint 3 regenerates deliberately) |
| .NET (`aspire/`) | 114 (47 + 67) |
| Markdown links | 0 broken |
| Probes | `verify-launch-detachment.ps1` (dash), `verify-sandbox-cancel.ps1` (14 cases) |

Environment constraints that apply to all three sprints:

- The worker bash suite needs **WSL Ubuntu**, at a destination path containing
  **no digits**. It cannot run under Git Bash or Cygwin.
- `aca sandbox exec` runs under `/bin/sh` = **dash**. `$(< file)` expands to the
  empty string with no error under dash. No new shell code may use it.
- `az containerapp job start --env-vars` **replaces** the container environment
  and applies only when a complete container spec (name, image, cpu, memory) is
  given. A partial spec is silently ignored.
- `az` silently switches the active subscription on some operations; re-assert
  it.

## Sprint ordering

```
Sprint 1 (packaging)  ──►  Sprint 2 (one path implementation)
        │
        └──────────────►  Sprint 3 (egress honesty)
```

Sprint 2 depends on sprint 1: it ships a new library file, and the assertion
that the shipped layout is complete must already exist before another file is
added to it. Sprint 3 depends on sprint 1 only for merge order (both touch the
routing decision's test surface); it does not depend on sprint 2.

---

## Sprint 1: ship the catalog into the worker image and prove the shipped layout resolves a route

> **DONE.** Landed with one correction the plan did not anticipate: `COPY`
> cannot reach above its build context, so shipping a file from `config/` also
> required moving the build context to the repository root and adding a
> `.dockerignore`. Neither the plan nor an image-shaped simulation could catch
> that, because neither builds. Verified in ACR against the real image:
> `route: aca-job`, `action: dispatch`, `catalogSchemaVersion: 1` with no
> `--catalog`; the previously deployed image fails the same probe with ACR
> reporting `exit status 70`.
>
> Mutation results: M1 fails 5 assertions by name; M4 — the control proving the
> suite can still fail — fails 2. Gates: `validate.ps1` 363 -> **375**, worker
> suite 14 suites / 911 -> **15 suites / 923**.

**Goal.** A dispatcher running inside the worker image resolves a routing
decision without being handed a catalog path.

### Scope

- `worker/Dockerfile`: add `config/sandbox-classes.json` to the `COPY` that
  populates `/usr/local/lib/squad-on-aca/`, landing it as
  `sandbox-classes.json` — the first entry `catalogSearchPaths()` already looks
  for. **The consumer side needs no change**; the search path exists and is
  labelled "packaged next to the worker libraries inside the image".
  It is not, and never has been, exercised.
- New worker suite `worker/tests/test_image_layout.sh` that builds a throwaway
  directory **from the Dockerfile's own `COPY` list** (parsed, not hard-coded)
  and exercises the shipped entry points from it.
- `scripts/validate.ps1`: a structural check that every relative `require()` in
  a shipped `.js` file resolves to a file the Dockerfile also ships, plus the
  catalog.

### Explicitly out of scope

- Changing `catalogSearchPaths()`, its order, or any resolver logic.
- Setting `SQUAD_SANDBOX_CLASS_CATALOG` anywhere.
- `worker/lib/squad-capability-preflight.sh` (sprint 2).
- Re-pinning `sandbox-node-lts` to the new image digest — see the risk note.
- Fixing `RALPH_LABELS` (open question 3 in the ADR; a separate change if it is
  a defect).

### Acceptance criteria, as observable behaviour

1. From a directory containing **only** the files `worker/Dockerfile` copies,
   with the working directory outside the repository, no `--catalog` flag and
   `SQUAD_SANDBOX_CLASS_CATALOG` unset:
   `node squad-dispatch.js decide --session-id s1 --dispatch-source ralph --repository o/r`
   exits **0** and prints `"route":"aca-job"` with `"action":"dispatch"`.
2. In that same layout, with the packaged catalog file deleted, the identical
   command exits **70** and prints `"reason":"catalog-unavailable"`.
3. In that same layout, `ralph_dispatch_issue` (the real function, with the
   existing fake `az`/`gh`) **starts compute exactly once** for a candidate
   issue and labels it exactly once — the end-to-end behaviour that is dead
   today.
4. `scripts/validate.ps1` fails if a `.js` file the Dockerfile ships
   `require()`s a relative path the Dockerfile does not ship.

### Mutation table

| # | Deliberate breakage | Named assertion that must fail |
|---|---|---|
| M1 | Remove `config/sandbox-classes.json` from the Dockerfile `COPY` | `image layout: decide resolves a route with no --catalog` — the test builds its layout from the `COPY` list, so the file simply is not there |
| M2 | Ship it as `sandbox-classes.json.txt` | same assertion (the packaged name must match `catalogSearchPaths()[0]`) |
| M3 | Delete `path.join(__dirname, 'sandbox-classes.json')` from `catalogSearchPaths()` | same assertion |
| M4 | Make `loadCatalog` return a stub catalog instead of throwing when no file is found | `image layout: a missing packaged catalog still exits 70 with catalog-unavailable` — proves criterion 1 is not passing because failure became impossible |
| M5 | Change `squad_dispatch_cli()` in `ralph-dispatch.sh` to fall back to a repo-relative path | `image layout: ralph dispatches from the shipped layout` still passes, but `validate: every shipped require() target is shipped` fails — and if it does not, the sprint has not closed the hole |
| M6 | Add `--catalog "$CATALOG"` to any invocation in the new suite | `validate: test_image_layout.sh passes no catalog override` (an *absence* grep, which is the one thing grep is reliable for) |
| M7 | Add a new `require('./something-new.js')` to `squad-dispatch.js` without adding it to `COPY` | `validate: every shipped require() target is shipped` |

M4 and M6 exist because M1–M3 alone are satisfiable by a test that cannot fail.

### Dependencies

None. This is the entry point.

### Risk note

- **The self-referential digest.** `sandbox-node-lts` pins a digest of the
  squad-worker image, and adding a file to that image changes the digest — so
  the catalog inside the image can never name the image containing it. This
  sprint deliberately does **not** re-pin: the class keeps its existing digest
  and its existing evidence, the newly built image is what the Jobs plane runs,
  and that is exactly where the catalog is needed. **This must be observed, not
  assumed** — build the image and run `verify-image-evidence.js` and
  `validate.ps1` before merging (ADR open question 1). If evidence does fail,
  the sprint stops and the two-phase re-pin is designed first.
- **CRLF.** The Dockerfile `sed -i 's/\r$//'` line lists shell scripts. JSON must
  **not** be added to it; `JSON.parse` tolerates `\r\n` as whitespace. Adding it
  to the `chmod +x` list would be worse than harmless.
- **Parsing the `COPY` line in bash.** The test's value comes entirely from
  deriving the layout from the Dockerfile. If that parse is fragile it will fail
  confusingly on an unrelated Dockerfile edit. It must fail *loudly* (refuse to
  run, non-zero) rather than fall back to a hard-coded list — a silent fallback
  reintroduces the defect this sprint exists to close.
- **Abandon condition.** If the image cannot be rebuilt and pushed in this
  window, criterion 3 can still be met (it runs against a directory, not a
  container) but the defect is not actually fixed in production. Merging the
  test without the image rebuild is acceptable and useful — it turns a silent
  defect into a failing gate — but the sprint is not *done* until a rebuilt
  image is deployed and a Ralph execution is observed dispatching.

---

## Sprint 2: one manifest-path implementation

> **DONE.** Landed as scoped, with two corrections to this plan's own mutation
> table (below) and one design change the plan did not specify: the CLI reports
> its verdict as a **distinct exit code per outcome** (`0` present, `3` absent,
> `4` unsafe) rather than the old "any non-zero means unsafe" plus an
> `__ABSENT__` stdout sentinel. That old scheme could not distinguish a module
> that failed to load (node exits `1`) from a hostile path, so criterion 3 held
> only by luck; with distinct codes every unclaimed code refuses with **69**
> (`EX_UNAVAILABLE`), which is what makes criterion 3 hold by construction.
>
> **M1 fails two assertions, one per entry point** —
> `corpus/tree-escape-etc: resolver ...` and `corpus/tree-escape-etc: preflight
> ...` — which is the sprint's premise, measured rather than assumed. It fails
> 6 by name in total.
>
> Corpus verdicts compare **output text plus exit code**, not exit code alone.
> Under M1 the preflight still exits 78 for `../../../../etc/hostname` (the
> parser rejects `/etc/hostname` as malformed *after* the path check has already
> let it through); an exit-code-only assertion would have stayed green with the
> traversal boundary gone. The second escape case, `tree-escape-controlled`,
> resolves a *valid* manifest outside the tree and exits **0** under M1.
>
> Two plan corrections, stated plainly rather than papered over:
> **M2** does not fail `corpus: symlink pointing outside the tree is unsafe`,
> because the second `isWithin` check catches an outside-pointing symlink
> independently of the symlink check. It fails `corpus/symlink-inside-tree` on
> both entry points instead, and the corpus carries both cases so this is
> visible. **M5** cannot fail `preflight: a missing shared locator refuses the
> session`, because that assertion deletes the file itself and is indifferent to
> whether it was ever shipped. Block 3 therefore derives its library layout by
> parsing the Dockerfile `COPY` list, and a positive assertion — *the layout
> worker/Dockerfile actually ships resolves a manifest path* — is what M5 breaks.
>
> Mutation results (all applied, observed, restored):
>
> | # | Mutation | Assertions failed by name |
> |---|---|---|
> | M1 | `isWithin` accepts `..` | **6** — `corpus/tree-escape-etc` **resolver + preflight**, `corpus/tree-escape-controlled` resolver + preflight, `resolver: an unsafe manifest path reports reason manifest-path-unsafe`, `test_capability_routing.sh: escaping relative manifest path: refused` |
> | M2 | Delete the `lstat().isSymbolicLink()` check | **2** — `corpus/symlink-inside-tree` resolver + preflight |
> | M3 | Delete the `isFile()` check | **2** — `corpus/directory-at-path` resolver + preflight |
> | M4 | Re-add an inline copy in the preflight | **1** — `validate: squad-capability-preflight.sh has re-grown inline path-resolution` |
> | M5 | Remove from the Dockerfile `COPY` | **4** — `validate: Every shipped require() target is shipped`, `validate: worker/Dockerfile does not ship worker/lib/locate-manifest.js`, `preflight: the layout worker/Dockerfile actually ships resolves a manifest path`, `preflight: the shipped layout finds the manifest rather than refusing` |
> | M6 | Missing-locator path exits 0 instead of 69 | **7** — including `preflight: a missing shared locator still refuses an UNSAFE manifest path` and `... is NOT reported as 'no manifest present'` |
> | M7 | Resolver treats `unsafe` as `absent` | **6** — `resolver: ... reports reason manifest-path-unsafe`, `resolver: ... fails closed`, plus 4 in `test_capability_routing.sh` |
>
> Gates: `validate.ps1` 375 -> **388 / 0 / 0**; worker suite 15 suites / 923 ->
> **16 suites / 981**; CLI goldens **26** byte-identical; `dotnet test`
> **114** (47 + 67); markdown links **94 / 0 broken**. ACA Jobs remains the
> unconditional default.
>
> Not verified: the change was **not** built in ACR. Sprint 1's ACR-verified
> layout parser is reused unchanged and the new file sits on the same `COPY`
> line as files already proven to land, but "the image builds with this file in
> the list" is asserted structurally and by an image-shaped directory, not by a
> build.

**Goal.** The routing resolver and the in-worker preflight decide whether a
manifest path is safe by running the same code.

### Scope

- New `worker/lib/locate-manifest.js`, exporting the resolution used today by
  `locateManifest()` in `resolve-capability-route.js`, and usable as a CLI so
  bash can call it.
- `resolve-capability-route.js` requires it instead of defining it.
- `squad-capability-preflight.sh` replaces its inline `node - <<'NODE'` heredoc
  (lines 177–228) with a call to that CLI.
- Added to the Dockerfile `COPY` list — which sprint 1's structural check now
  enforces.
- A shared path-case corpus (fixture file) driven through **both** entry points.

### Explicitly out of scope

- **Changing any rule.** Absolute paths, control characters, tree escapes,
  symlinks and non-regular files are rejected exactly as they are today. This is
  a refactor with a behavioural-equivalence proof, not a hardening pass.
- The preflight's tool/credential/service/egress checks, its exit-code contract,
  and its advisory messages (the egress message is sprint 3).
- The resolver's decision shape.

### Acceptance criteria, as observable behaviour

1. Each case in the shared corpus — at minimum: absolute path; `..` escape;
   embedded NUL/control character; symlink pointing inside the tree; symlink
   pointing outside; dangling symlink; a directory; an absent file; a present
   regular file; `./squad-capabilities.yml`; a nested path; a path containing a
   space — produces the **same verdict** (safe / absent / unsafe) from the
   resolver and from the preflight, case by case, asserted individually rather
   than in aggregate.
2. The preflight still exits **78** for an unsafe path and **0** for an absent
   manifest, with its existing operator-facing messages unchanged.
3. With `locate-manifest.js` **absent** from the library directory, the preflight
   **refuses the session** with a distinct, actionable message. It does not
   report "no manifest present" and does not exit 0. This failure mode does not
   exist today and is created by this sprint.
4. `squad-capability-preflight.sh` contains no path-resolution logic of its own.

### Mutation table

| # | Deliberate breakage | Named assertion that must fail |
|---|---|---|
| M1 | Make `isWithin` in the shared module accept `..` | **Two** assertions, one per entry point: `resolver: ../../../../etc/hostname is refused` **and** `preflight: ../../../../etc/hostname exits 78`. If only one fails, the two are not sharing code and the sprint's premise is false |
| M2 | Delete the symlink check from the shared module | `corpus: symlink pointing outside the tree is unsafe` in both harnesses |
| M3 | Delete the `isFile()` check | `corpus: a directory at the manifest path is unsafe` in both harnesses |
| M4 | Restore an inline copy inside the preflight (keeping the shared module) | `validate: the preflight defines no path-resolution of its own` — an absence grep for `isWithin`/`realpathSync` in that file. M1 would otherwise start passing again with one failure instead of two |
| M5 | Remove `locate-manifest.js` from the Dockerfile `COPY` | sprint 1's `validate: every shipped require() target is shipped`, **and** `preflight: a missing shared locator refuses the session` |
| M6 | Make the missing-module path `exit 0` instead of refusing | `preflight: a missing shared locator refuses the session` |
| M7 | Change the resolver to swallow the shared module's `unsafe` verdict and treat it as `absent` | `resolver: an unsafe manifest path reports reason manifest-path-unsafe` |

M1's requirement that **two** assertions fail from **one** mutation is the whole
point of the sprint. It is the only mutation here that proves unification rather
than coincidence.

### Dependencies

Sprint 1 (the structural "everything required is shipped" check must exist
before a new required file is added, and both sprints edit the same `COPY`
line).

### Risk note

- **A new failure mode is being created.** Today the preflight has no external
  dependency for path resolution. After this sprint it does. Criterion 3 is not
  a nicety; if it is skipped, a Dockerfile edit could turn "manifest is unsafe"
  into "no manifest present" — a fail-*open* on a security boundary, which is
  strictly worse than the duplication being removed. If criterion 3 cannot be
  made to hold, **abandon the sprint and keep the duplication.**
- **Shell portability.** The preflight is `#!/usr/bin/env bash`, but anything it
  hands to `aca sandbox exec` lands in dash. No `$(< file)`, no `[[ ]]` in code
  that could migrate.
- **Silent drift already exists.** The two copies differ today in how they handle
  an unreadable repository directory (the resolver catches, the preflight lets
  node throw). Both currently reach the same verdict. The corpus must include
  that case explicitly, or the refactor will "preserve behaviour" that nobody
  measured.
- **Abandon condition.** If the corpus turns up a case where the two copies
  genuinely disagree today, stop: that is a defect to fix and report on its own,
  not something to bury inside a refactor.

---

## Sprint 3: stop asserting egress is satisfied on a plane that does not enforce it

**Goal.** A routing decision states whether the plane it names will enforce the
manifest's declared egress, and never reports an unenforced destination as
satisfied.

### Scope

- Add to the capability decision (and surface through the dispatch decision):
  - `egressEnforced` — boolean, true only when the named route is a plane that
    applies a generated egress policy before repository code runs;
  - `egressAdvisoryHosts` — the declared hosts that the named plane will not
    enforce.
- When the route is `aca-job` and `egressHosts` is non-empty, those hosts appear
  in `egressAdvisoryHosts` and **not** as satisfied.
- Operator-visible surface (CLI / dispatch output) states the count — never the
  host strings, which are repository-controlled text.
- Regenerate the 26 CLI goldens and any worker goldens, deliberately.
- Correct the stale claims in `docs/capability-manifest.md`: the `egress[]` row
  in the field table, and the message in `squad-capability-preflight.sh` that
  says `advisory only, not enforced yet` — which is now wrong inside a sandbox.

### Explicitly out of scope

- **Enforcing egress on the ACA Jobs plane.** Rejected in ADR 0003, not
  deferred: ACA Jobs has no per-execution network control, and the only lever
  (VNet-injecting the shared Container Apps environment) is environment-wide,
  not per-task, and perturbs the rollback path.
- **Changing which route any manifest resolves to.** A repository declaring
  egress must still route to `aca-job` when its tools fit the default profile.
  Making it fail closed would break the unconditional default.
- Changing `defaultWorker.egress` in the catalog.
- The sandbox provider's policy generation, which already does the right thing.

### Acceptance criteria, as observable behaviour

1. A manifest declaring only `git` plus `egress: [{host: example.com}]`
   resolves to `route: aca-job` — unchanged — **and** reports
   `egressEnforced: false` with `example.com` in `egressAdvisoryHosts` and
   **not** in a satisfied set.
2. A manifest declaring the same host plus a tool that forces an approved
   sandbox class resolves to that class **and** reports `egressEnforced: true`
   with an empty `egressAdvisoryHosts`.
3. A manifest with no `egress[]` reports `egressEnforced: true` on any route and
   an empty advisory list — "nothing declared" is not "unenforced".
4. The CLI prints a warning naming the **count** of unenforced destinations and
   the route, and prints no host string. Asserted by feeding a manifest whose
   declared host is a distinctive token and asserting that token is absent from
   stdout and stderr.
5. All 26 CLI goldens are regenerated in the same commit and are byte-identical
   to the newly captured baseline on a re-run.

### Mutation table

| # | Deliberate breakage | Named assertion that must fail |
|---|---|---|
| M1 | Hard-code `egressEnforced: true` | `egress honesty: an egress-declaring manifest on the aca-job route reports egressEnforced false` |
| M2 | Hard-code `egressEnforced: false` | `egress honesty: an egress-declaring manifest routed to an approved sandbox class reports egressEnforced true` |
| M3 | Derive `egressEnforced` from the route **name** rather than from the chosen profile's `egress.defaultAction` | Flip `defaultWorker.egress.defaultAction` to `Deny` in a **test-local** catalog copy: `egress honesty: a default profile with defaultAction Deny does not report an unmatched host as advisory` must fail. This proves the flag reads the policy, not a string |
| M4 | Report the host strings instead of the count on the operator surface | `egress honesty: a declared host never appears on stdout or stderr` |
| M5 | Add the fields to the internal object but not to the emitted decision | the 26 CLI goldens fail byte-comparison, and `egress honesty: the emitted decision carries egressEnforced` fails |
| M6 | Treat an empty `egress[]` as unenforced | `egress honesty: a manifest declaring no egress reports egressEnforced true` (criterion 3) |
| M7 | Change the route for an egress-declaring manifest to `fail-closed` | `routing: a manifest declaring only advisory egress still dispatches to aca-job` — the guard on the unconditional default |

M1 and M2 must both exist. Either alone is satisfied by a constant. M7 is the
regression guard on the rollback path and is the assertion a reviewer should
look for first.

### Dependencies

Sprint 1 for merge order (both touch the routing test surface). Independent of
sprint 2.

### Risk note

- **Schema version.** This adds fields to a schema-versioned, golden-pinned
  document. Whether any consumer compares `schemaVersion` for equality is
  **unverified** (ADR open question 2) and must be checked before implementation
  — including `aspire/` and `.github/workflows/`. If a strict consumer exists,
  the sprint either bumps the version and updates that consumer, or stops.
- **Golden churn.** 26 CLI goldens plus worker goldens change in one commit.
  That is a large, low-information diff in review, and it is the kind of diff in
  which a real change hides. The commit must contain the golden regeneration
  **and nothing else** beyond the feature, and the regeneration must be
  reproducible by re-running the capture.
- **This sprint adds no enforcement.** It makes an existing gap visible. Anyone
  reading the sprint title as "controlled egress landed" has misread it, and the
  documentation change must say so in those words.
- **Abandon condition.** If it proves impossible to express `egressEnforced`
  without reading the route name (M3 cannot be made to fail), the field is a
  restatement of the route and adds nothing. Drop it and ship the documentation
  correction alone.

---

## Not scheduled: short-lived, least-privilege credentials

**No sprint is proposed, and inventing one would be dishonest.** The full
reasoning is in
[ADR 0003, effort 4](../adr/0003-capability-manifest-future-work.md#effort-4-short-lived-least-privilege-credentials).
In brief:

- The GitHub App is registered and installed (`4448714` / installation
  `150377869`, `contents:write`, `issues:write`, `pull_requests:write`,
  `metadata:read`, TTL measured at 3600 s), and the **entire consumption side**
  already exists and is proven: the credential helper, the token preflight, the
  `0600` file delivery, and mid-session refresh on the Sandboxes plane.
- What is missing is minting, and minting is blocked on a private key that was
  generated and deleted. Key Vault is unusable in this tenant
  (`HateSubWidePolicy` forces `publicNetworkAccess: Disabled` and reverts
  attempts to change it), and ACA secrets — the repository's existing pattern —
  are the wrong shape, because they are readable by the very container running
  untrusted repository code.
- Even unblocked, a 3600-second token on the **Jobs** plane cannot be refreshed
  mid-run, and Squad sessions routinely run 10–60 minutes. Per-task tokens would
  convert sessions that succeed today into sessions the token preflight
  correctly refuses to start — an availability regression on the unconditional
  default and the rollback path.

### The two preconditions, and how each is answered

1. **Measure the run-duration distribution.** Requires **no code**:
   `worker/lib/dispatch-lease.js` already stamps `startedAt` and `updatedAt` on
   every lease, and `node worker/lib/squad-dispatch.js list --repository <r>`
   prints them. If the 95th percentile plus dispatch overhead sits comfortably
   inside 3600 s, a Jobs-plane per-task token becomes arguable; if not, effort 4
   is Sandboxes-only *by measurement*.
2. **Decide where the private key lives, then regenerate it.** A decision for
   the repository owner between GitHub Actions secrets (control-plane only, no
   local `squad-aca run` support) and a split model — with the hard constraint
   that the store is never mounted into the worker.

Only after both are settled is it worth designing sprints. The likely shape,
recorded so the next planning pass does not start from zero, is: mint in the
control plane immediately before compute is requested → pass
`SQUAD_TOKEN_EXPIRES_AT` alongside the token (nothing sets it today, so the
token preflight's lifetime gate is presently dormant) → Sandboxes refresh on the
existing channel → Jobs refuses early rather than failing at push. That is three
or four sprints of work whose first line cannot be written yet.

### What was considered and rejected as a sprint

"Have the control plane set `SQUAD_TOKEN_EXPIRES_AT`" was the only candidate
needing no private key. It was rejected: with a classic PAT the control plane
has no truthful expiry to set, so the sprint would wire a variable with nothing
to put in it and assert a gate that still logs `UNKNOWN`. By this repository's
own definition that is a decorative test, and naming it as such is the correct
output of a planning pass.
