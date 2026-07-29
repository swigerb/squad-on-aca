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
