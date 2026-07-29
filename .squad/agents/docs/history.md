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
