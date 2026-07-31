# docs History

## 2026-07-28: Reviewer-rejection fix on PR #16 (issue #13 docs)

Handled a reviewer rejection of PR #16 (branch `squad/13-logs-fallback`). The
engineer authored commit `aa7a4f0` and is locked out of this revision per the
reviewer-rejection lockout protocol, so the docs fix was routed here.

- **Blocking: joined command lines.** `docs/runbook.md` line 167 of the
  control-plane copy-paste block had `squad-aca watch start --repo
  "<github-owner>/<repo>"squad-aca watch stop` on one line. An operator
  pasting it during an incident would have sent a malformed `--repo` value and
  never run `watch stop`. Restored the line break; the fenced block is
  otherwise intact (fence markers balanced: 62 in `runbook.md`, 30 in
  `validation.md`).
- **Same defect pattern elsewhere.** `.squad/agents/engineer/history.md` lost
  the blank line between the previous entry's last paragraph and the new
  `## 2026-07-28` heading when the entry was appended. Restored it. No other
  joined lines, dropped separators, unbalanced fences, or mangled lists found
  in the branch diff for `docs/runbook.md` or `docs/validation.md`.
- **Overstated extension claim.** The module comment in
  `scripts/lib/aca-logs.ps1` and the matching runbook bullet said the Log
  Analytics fallback needed no extension. It does need the `log-analytics` az
  extension - what it avoids is the `containerapp` extension. Corrected the
  header comment, the `Get-AcaExecutionLog` doc-comment, and the runbook
  bullet to say exactly that. The runtime remediation text and the `doctor`
  `Logs path` row already got this right and were left alone.
- **Scope.** Also narrowed the runbook's "only command that lives in a CLI
  extension" claim to "the `containerapp` CLI extension", since the fallback's
  `az monitor log-analytics query` is itself an extension command.

**Evidence.** No PowerShell logic and no tests changed - comments and prose
only. `scripts/validate.ps1`: 50 passed / 0 failed. Worker suite: 5 suites,
179 assertions, 0 failed, 0 skipped.

## 2026-07-29: README coverage for the ACA Sandboxes execution plane

The PRD #6 programme shipped 8 sprints of ACA Sandboxes work into the deep docs
(`runbook.md` 89 mentions, `architecture.md` 34, `capability-manifest.md` 29,
ADR 0001 27, `rollback.md` 17) while `README.md` had **zero**. Someone landing
on the repository could not learn the feature existed, that it is off by
default, or how to enable it. Closed that gap on `docs/sandboxes-readme`.

- **README, `## What you get` table.** Added a "Second execution plane (opt-in
  preview)" row naming the flag and stating that ACA Jobs stay the default and
  the rollback path.
- **README, new `## ACA Sandboxes (opt-in preview)` section** placed directly
  after `## Capability-aware execution`, with a two-sentence bridge appended to
  that section so the routing decision and the plane it routes to read as one
  story. Subsections: what it does today, how to enable it, two independent
  fail-closed interlocks, why the plane exists, prerequisites, where to go next.
- **Accuracy over enthusiasm.** "What it does today" leads with the limitation,
  not the capability: the flag opens the route gate and nothing more, so a
  reader finishes knowing the plane is not usable for real sessions yet.

**Verified against code, not against the brief.**

- `SQUAD_ACA_ENABLE_SANDBOX` and `1`/`true`/`yes`/`on`/`enabled` -
  `scripts/lib/squad-aca-provider.ps1:50-51`, `Test-SquadSandboxEnabled:344`.
  An explicit value decides in both directions, which is what makes `0` a kill
  switch. Note the function *also* honours a `Config.sandboxEnabled` property,
  subordinate to the environment variable and written by nothing today - so
  "environment variable, not a config key" is right about the mechanism in use
  but is not the whole function. Kept the README on the env var.
- `provisional` interlock - `config/sandbox-classes.json:52` (`"provisional":
  true`, all three classes carrying `REPLACE-ME...` / `PROVISIONAL` image
  references). `Get-SquadSandboxClass:443` refuses on `$Catalog.provisional -ne
  $false`, returning `catalog-provisional`.
- Identity refusal - `scripts/lib/providers/squad-sandbox-provider.ps1`:
  `Assert-SandboxGroupIdentityFree:838` fails closed when it cannot *prove* the
  group is identity-free (`az resource show` non-zero or non-JSON both throw),
  and `Assert-SandboxArgvIdentityFree:616` rejects `--identity`,
  `--mi-user-assigned` and `--system-assigned` on every argv the file builds.
- Egress evidence - ADR 0001 lines 102-114: allowlisted 200, `example.com` 403,
  raw `/dev/tcp/1.1.1.1/53` connection refused, plus the
  `aca sandbox egress decisions` audit trail.
- Rollback steps - `docs/rollback.md:49-126`; matches what the README says.

**One correction to the brief.** It said there are "six `New-SessionExecutionProvider`
call sites in `scripts/squad-aca.ps1`". There are **four** (lines 542, 681, 749,
815), plus the definition at 401. The substantive claim is unaffected: none of
the four passes `-CapabilityResolution`, so the gate is always reached with no
decision, exactly as the function's own doc-comment (423-429) and
`docs/runbook.md:437-442` state. No doc contradicted the code.

**`docs/feature-parity.md` - changed, because it was genuinely inaccurate.** Its
`## Capability-aware execution` section still described the routing decision as
"computed and reported, but not yet acted upon" and listed as *deferred*
follow-up work three things Sprints 5-8 actually delivered: per-task Sandboxes
selection, generated egress rules, and short-lived least-privilege credentials.
Replaced that paragraph and added a short `## ACA Sandboxes execution plane`
section. Deliberately did **not** add a parity-table row - the table maps
`squad-on-aks` features to ACA equivalents and the sandbox plane has no AKS
counterpart, so a row would have invented one. The "advisory egress / long-lived
token pair" wording in `capability-manifest.md` is still true *of the ACA Jobs
plane* and was left alone; `feature-parity.md` now says which plane it is
describing.

**Links.** Twelve relative links/anchors added. Verified each resolves by
generating GitHub slugs from the target files' headings and matching:
`runbook.md#aca-sandboxes-preview-feature-flagged-off`, `#prerequisites`,
`#credentials-four-planes-kept-separate`, `#concurrency-cost-and-orphans`,
`#rollback-to-aca-jobs`, `#incident-runbook`;
`architecture.md#aca-sandboxes-provider-feature-flagged-default-off`;
`rollback.md#2-aca-sandboxes-feature-flagged-preview`;
`adr/0001-aca-sandboxes-feasibility.md`; and from `feature-parity.md`,
`../README.md#aca-sandboxes-opt-in-preview`. All resolve; the two initial
failures were my slug generator collapsing runs of whitespace, where GitHub
emits one hyphen per space - the pre-existing
`validation.md#rbac--identity-scope` links (double hyphen, from `RBAC /
identity scope`) were correct all along and were not touched. The scratch
checker was deleted.

**Evidence.** Docs only; no scripts, config, or tests changed.
`scripts/validate.ps1`: 205 passed / 0 failed / 0 skipped, before and after -
unchanged. `scripts/validate.ps1` has no markdown link check, so link
verification was done out of band as described above. No secrets, tokens, or
real subscription/tenant GUIDs added; examples use `<prompt>` and the existing
placeholder style.

## 2026-07-31: Agent-integration docs, ADR 0002, and an accuracy sweep (#33 S4)

Sprint 4 (final) of issue #33. Sprints 1-3 shipped a real .NET agent contract, a
MAF adapter, a runnable sample, 114 offline tests, and live evidence on both
execution planes. The docs still described that path as a scaffold with a preview
dependency. Closed that gap on `docs/33-s4-agent-docs`.

**README: 314 -> 353 lines (+39).** New `## Agent integration (Microsoft Agent
Framework)` section, 29 lines, placed after `## ACA Sandboxes` so the three
sibling concepts (capability routing, the second execution plane, the agent
caller) read in order. Followed the `## ACA Sandboxes` precedent set in #31
deliberately: a short what-it-is, a minimal quickstart (DI registration resolving
the **base `AIAgent`**, plus the sample-host command line), the two facts a
reader must not miss, and links onward. Everything else lives in `docs/`. Added
one `## What you get` row, "Callable as an agent (opt-in)", in the existing row
style.

**Structure: restructured the two existing pages rather than adding a third.**
`docs/agent-contract.md` (S1) and `docs/maf-adapter.md` (S2) are not
half-overlapping - they are layered: one is the `squad-aca --json` wire contract,
the other is the .NET/MAF layer over it. A third page could only have been an
index, which adds a hop and three places for the same sentence to drift. Instead
`maf-adapter.md` became the landing page: it gained an orientation opener naming
its two companions and a **Status at a glance** table (nine rows: what is
verified live, the `RunToCompletion` default, `DispatchOnly` opt-in, the null
`executionHandle`, `fallbackReason` semantics, and the broken sandbox cancel).
`agent-contract.md` gained a one-line "start at maf-adapter.md" pointer so a
reader landing on the wire reference is not stranded. No prose was duplicated
between them.

**Two claims the docs did not previously make.** Sandbox cancellation is broken
([#36](https://github.com/swigerb/squad-on-aca/issues/36)) - the existing caveat
described the symptom but never cited the issue, and the status table now states
it as a row rather than a footnote. And a new `## Lifecycle and cost` section:
**a terminal session is not a stopped bill.** Both live sandboxes were still
`Running` after their sessions reached terminal state; `cancel` leaves them up so
logs stay readable, teardown is `terminate`'s job, and no MAF surface performs
it. That was in the S3 evidence and in nobody's documentation.

**ADR 0002 - `docs/adr/0002-squad-on-aca-as-a-maf-agent.md`**, matching the
0001 house format (status/date/deciders/context header, the "historical record"
callout, Context / Decision / Consequences / Open questions / Evidence). Records:
Option B taken and Option A deferred; *why* A is deferred (the documented
`SquadAgent` sets `OnPermissionRequest = PermissionHandler.ApproveAll`, a blanket
allow and exactly what `--yolo` did before #26 removed it, with no permission
seam on `SquadAgentOptions` because `ConfigureCopilotClient` reaches
`CopilotClientOptions`, not `SessionConfig` - the `CliArgs` escape is plausible
and unverified, and the acceptance test is behavioural, not an argument); a
correction that `Microsoft.Agents.AI` was assumed preview and is GA at 1.16.0,
with the quarantine kept anyway because a stable package is not a frozen one and
`ContinuationToken` is still `[Experimental("MEAI001")]`; eight binding
consequences; and the four upstream questions from #33.

**Stale claims found and fixed.**

- `README.md` - `.\scripts\validate.ps1` documented as **285** offline checks; it
  is **307**. The `-RunDotnet` comment said "also build the optional aspire
  scaffold", but that switch turns a missing SDK into a failure rather than a
  skip - the build and tests already run whenever an SDK is present.
- `README.md` - "Agent Framework exposes the Squad session as an agent
  abstraction (a compile-safe seam; **preview packages are not referenced by
  default**)". Both halves untrue: it is a shipped adapter, and the package is
  GA and referenced.
- `README.md` - "the `aspire/` **scaffold**" in the prerequisites.
- `aspire/README.md` - predates all of S1-S3. Its layer table gave
  `Squad.Aca.Agents` the "Agent Framework" role and said "no preview dep";
  split into an **Agent contract** row and an **Agent Framework** row naming
  `Squad.Aca.Agents.MAF`. Its diagram annotated the `AIAgent` as "(sprint 2,
  isolated, **may take a preview dependency**)". Two more forward-looking
  references to "the sprint-2 adapter" and one to "a preview restore failure".
  And "the project and `AppHost.cs` remain valid, reviewable **scaffolding**",
  which is no longer what is in that directory. Its `## Package references`
  section was already correct about GA and was left alone.
- `docs/architecture.md` - "a Microsoft Agent Framework `AIAgent` adapter - which
  does take **a preview dependency**". Also the `When to use which` table sent
  "Expose a Squad session as an Agent Framework agent" to `Squad.Aca.Agents` and
  `agent-contract.md`, which is the wrong project and the wrong page: that is
  `Squad.Aca.Agents.MAF` / `maf-adapter.md`. And the layer table's agent row did
  not mention the MAF project at all.
- `docs/validation.md` - the `.NET scaffold` check row said it "keeps the agent
  contract free of the preview dependency that is **sprint 2's isolated
  problem**"; sprint 2 shipped. The `## Optional .NET/Aspire scaffold
  validation` section still allowed for "preview packages are unavailable" and
  called the projects "reviewable scaffolding", and described only
  `Squad.Aca.Agents.Tests` - `Squad.Aca.Agents.MAF.Tests` is equally offline and
  was unmentioned.
- `docs/rollback.md` section 1 - scoped to "the .NET/Aspire **AppHost**" while
  its `git checkout -- aspire/` reverts two shipped libraries, an adapter, three
  test projects, and a sample. Named what is actually in scope and dropped
  "scaffold".

**Checked and deliberately not changed.**

- `docs/feature-parity.md` - re-read in full. Nothing in it is untrue after
  S1-S3: it makes no claim about the .NET path, and the `## Capability-aware
  execution` and `## ACA Sandboxes execution plane` sections corrected in #31 are
  still accurate. I did not add an agent section. The sandbox precedent would
  have justified one, but the brief was to fix what is wrong, not to pad, and
  nothing here is wrong.
- `docs/e2e-results.md:55` says `=== .NET/Aspire scaffold ===`. That is a
  verbatim capture of what `scripts/validate.ps1` prints (`Write-Section
  ".NET/Aspire scaffold"`, line 217). Editing a recorded console transcript to
  match today's vocabulary would falsify the evidence; the script is code and
  this sprint changes none.
- `docs/runbook.md`, `docs/architecture.md`, `docs/sandboxes.md` beyond outright
  errors, per the sprint constraints. The architecture fixes above are all
  factual corrections, not rewrites.
- README's "739 assertions" and "22 golden captures" for the human-output
  goldens: both still correct. There are 26 golden files, but `23`-`26` pin the
  JSON documents, so "22" is right wherever the human output is what is being
  described - I briefly "corrected" it in `aspire/README.md` and reverted, since
  that sentence is about the human-readable output.

**Links.** Every relative link and anchor verified by generating GitHub heading
slugs from the target files, not by eye - the technique that caught a broken
anchor in #31. **108 relative links across 15 files, all resolve.** The checker
was mutation-tested first (a fabricated `docs/nope.md` and a fabricated
`maf-adapter.md#no-such-heading` were both reported) so that "all resolve" means
something; it skips fenced code blocks when harvesting headings, and was deleted
afterwards.

New or changed targets: from `README.md` - `docs/maf-adapter.md`,
`docs/agent-contract.md`, `docs/adr/0002-squad-on-aca-as-a-maf-agent.md`, and the
in-page `#agent-integration-microsoft-agent-framework`. From
`docs/maf-adapter.md` - `agent-contract.md`,
`adr/0002-squad-on-aca-as-a-maf-agent.md`, `e2e-results.md`,
`runbook.md#concurrency-cost-and-orphans`, and the in-page
`#the-long-run-problem` and `#lifecycle-and-cost`. From `docs/agent-contract.md`
- `maf-adapter.md`. From `docs/architecture.md` - `maf-adapter.md` twice, one of
which replaced a link to `agent-contract.md` that pointed at the wrong layer.
From the new ADR - `../maf-adapter.md`, `../agent-contract.md`,
`../e2e-results.md`. No inbound anchor anywhere in the repo pointed into
`maf-adapter.md` or `agent-contract.md`, so retitling and reordering broke
nothing; the one heading I renamed
(`## Optional .NET/Aspire scaffold validation` -> `## Optional .NET/Aspire
validation`) was confirmed to have zero inbound references before renaming.

**Evidence.** Documentation only - no code, test, config, or CI file changed.
`scripts/validate.ps1`: **307 passed / 0 failed / 0 skipped**, identical to the
baseline captured before any edit. No secrets, tokens, or real
subscription/tenant GUIDs; the README quickstart uses the existing
`<github-owner>/<repo>` placeholder style.