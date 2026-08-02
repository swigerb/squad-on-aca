#!/usr/bin/env node
/**
 * Decide whether a GitHub event should start a Squad on ACA session.
 *
 * Issue #32 moves the control plane off the developer's laptop: a GitHub Action
 * fires on an event, authenticates to Azure by OIDC, and starts the ACA
 * dispatcher job. Actions is only the TRIGGER TRANSPORT -- every decision about
 * what to run lives here and in dispatch-decision.js, which is shared with the
 * local CLI, Ralph and Watch.
 *
 * This module is deliberately PURE: it takes a parsed event payload and returns
 * a verdict. It performs no network calls and reads no environment, so the
 * whole trigger surface -- including every refusal -- is testable without a
 * GitHub App, a webhook, or a live repository.
 *
 * Usage as a CLI (what the workflow calls):
 *   node actions-event.js --event-name issues --event-path "$GITHUB_EVENT_PATH" \
 *        [--trigger-label squad-aca] [--command-prefix /squad-aca] [--bot-login foo[bot]]
 *
 * Prints a single JSON object and exits 0 whether or not it decides to
 * dispatch. A non-zero exit means the INPUT was unusable, which is a different
 * thing from "this event is not for us" and must not be conflated: a workflow
 * that treats "no, thanks" as a crash will fail on every unrelated comment.
 */

'use strict';

const fs = require('fs');

// NOT 'squad'. That is Squad's own canonical TRIAGE INBOX label, defined by
// sync-squad-labels.yml as "Squad triage inbox -- Lead will assign to a member"
// and consumed by squad-triage.yml (if: github.event.label.name == 'squad').
// Reusing it meant one label carried two unrelated meanings: "Lead, please
// route this" and "spend money running a remote container". Measured on this
// repository: applying squad fired Squad's triage within TEN SECONDS, adding
// squad:lead and go:needs-research alongside the ACA dispatch.
//
// squad-aca is deliberately NOT squad:-prefixed either, because
// squad-issue-assign.yml treats every squad:* label as a member assignment --
// the same reason Ralph's marker is squad-aca:dispatched.
const DEFAULT_TRIGGER_LABEL = 'squad-aca';
// NOT '/squad'. This repository defines TWO Copilot agents in .github/agents/:
// squad ("Your AI team" -- the ordinary Squad coordinator) and squad-aca
// ("Dispatch work to an Azure Container Apps-hosted Squad session"). /squad
// names the WRONG one: it reads as "invoke Squad", and Squad is a real,
// distinct agent here that does not dispatch to ACA.
//
// It is also the obvious name for a slash command if upstream Squad ever adds
// one -- exactly the shape of the squad LABEL collision, where this project
// had squatted on Squad's canonical triage label and fired its triage workflow
// on every dispatch. Upstream has no issue_comment handler today (verified
// against bradygaster/squad), so this is pre-emptive rather than a live bug.
//
// /squad-aca matches the trigger label, so both ways of asking for a remote
// session use the same word for the same thing.
const DEFAULT_COMMAND_PREFIX = '/squad-aca';

// Reasons are named constants so a test asserts on a stable token rather than
// on prose, and so the workflow can branch on one without string-matching a
// sentence that may be reworded.
const REASON = {
  DISPATCH_LABEL: 'label-applied',
  DISPATCH_COMMAND: 'command-comment',
  DISPATCH_MANUAL: 'manual-dispatch',
  SKIP_EVENT: 'event-not-a-trigger',
  SKIP_ACTION: 'action-not-a-trigger',
  SKIP_LABEL: 'label-not-the-trigger-label',
  SKIP_NO_COMMAND: 'comment-carries-no-command',
  SKIP_SELF: 'actor-is-this-app',
  SKIP_BOT: 'actor-is-a-bot',
  SKIP_CLOSED: 'issue-is-closed'
};

/**
 * Sanitize a value for use in an ACA job execution / session name.
 *
 * Kept identical in spirit to the worker's own sanitize_name: lower case,
 * [a-z0-9-] only, collapsed dashes, trimmed. A name that sanitizes to empty is
 * an error rather than a silently empty segment.
 */
function sanitizeName(value) {
  const cleaned = String(value == null ? '' : value)
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
  return cleaned;
}

function verdict(dispatch, reason, extra) {
  return Object.assign({ dispatch, reason }, extra || {});
}

/**
 * @param {object} input
 * @param {string} input.eventName      GITHUB_EVENT_NAME
 * @param {object} input.payload        the parsed event payload
 * @param {string} [input.triggerLabel] label that means "run Squad on this"
 * @param {string} [input.commandPrefix] comment prefix that means the same
 * @param {string} [input.botLogin]     this App's bot login, for loop breaking
 * @returns {{dispatch: boolean, reason: string, ...}}
 */
function resolveEvent(input) {
  const eventName = String(input.eventName || '');
  const payload = input.payload || {};
  const triggerLabel = String(input.triggerLabel || DEFAULT_TRIGGER_LABEL).toLowerCase();
  const commandPrefix = String(input.commandPrefix || DEFAULT_COMMAND_PREFIX).toLowerCase();
  const botLogin = String(input.botLogin || '').toLowerCase();

  // ---- loop breaking, before anything else -------------------------------
  //
  // Events caused by GITHUB_TOKEN do not start new workflow runs, so Actions
  // cannot retrigger itself on its own comments. An APP token has no such
  // protection: a session that comments on an issue with an App credential
  // WOULD retrigger this workflow, and that is an unbounded loop that bills by
  // the minute. This check is what makes the App path safe, and it runs first
  // so no later branch can accidentally reach a dispatch.
  const actor = String(
    (payload.comment && payload.comment.user && payload.comment.user.login) ||
    (payload.sender && payload.sender.login) ||
    ''
  ).toLowerCase();

  if (botLogin && actor && actor === botLogin) {
    return verdict(false, REASON.SKIP_SELF, { actor });
  }

  if (eventName === 'workflow_dispatch') {
    const issue = normalizeIssue(payload.inputs && payload.inputs.issue);
    return verdict(true, REASON.DISPATCH_MANUAL, {
      issueNumber: issue,
      sessionName: buildSessionName('manual', issue, payload)
    });
  }

  if (eventName !== 'issues' && eventName !== 'issue_comment') {
    return verdict(false, REASON.SKIP_EVENT, { eventName });
  }

  const issue = payload.issue || {};
  const issueNumber = normalizeIssue(issue.number);

  if (eventName === 'issues') {
    if (payload.action !== 'labeled') {
      return verdict(false, REASON.SKIP_ACTION, { action: payload.action || '' });
    }
    const applied = String((payload.label && payload.label.name) || '').toLowerCase();
    if (applied !== triggerLabel) {
      return verdict(false, REASON.SKIP_LABEL, { label: applied });
    }
    if (issue.state === 'closed') {
      return verdict(false, REASON.SKIP_CLOSED, { issueNumber });
    }
    return verdict(true, REASON.DISPATCH_LABEL, {
      issueNumber,
      label: applied,
      requester: actor,
      sessionName: buildSessionName('issue', issueNumber, payload)
    });
  }

  // issue_comment
  if (payload.action !== 'created') {
    return verdict(false, REASON.SKIP_ACTION, { action: payload.action || '' });
  }
  const commenter = payload.comment && payload.comment.user;
  if (commenter && String(commenter.type || '').toLowerCase() === 'bot') {
    // A different bot commenting is not a loop, but it is not a human asking
    // for work either. Dispatching on it turns any noisy integration into a
    // billing event.
    return verdict(false, REASON.SKIP_BOT, { actor });
  }
  if (issue.state === 'closed') {
    return verdict(false, REASON.SKIP_CLOSED, { issueNumber });
  }

  const body = String((payload.comment && payload.comment.body) || '');
  const command = extractCommand(body, commandPrefix, botLogin);
  if (!command.found) {
    return verdict(false, REASON.SKIP_NO_COMMAND, { issueNumber });
  }

  return verdict(true, REASON.DISPATCH_COMMAND, {
    issueNumber,
    prompt: command.prompt,
    requester: actor,
    trigger: command.via,
    sessionName: buildSessionName('comment', issueNumber, payload)
  });
}

/**
 * A command must be the FIRST thing on a line, so quoting someone else's
 * comment -- which GitHub renders as "> /squad do the thing" -- cannot trigger
 * a run. Markdown quoting is the common way an unintended trigger happens.
 *
 * There is deliberately NO separate "skip lines beginning with >" guard. One
 * was written and then removed, because deleting it changed no outcome: a line
 * that starts with ">" cannot also start with the command prefix, so the guard
 * was unreachable in effect and no mutation could catch its absence. An
 * unfalsifiable guard is worse than none -- it invites a test that passes for a
 * reason unrelated to the code it claims to cover. The line-start rule below is
 * what actually makes quoting inert, and test_actions_event.sh exercises it.
 *
 * Two forms are accepted, both subject to the same line-start rule:
 *
 *   /squad <instruction>                        the slash command
 *   @squad-on-aca-control-plane <instruction>   an @mention of the App
 *
 * The mention form exists because @mentioning a bot is what people try first.
 * It is accepted ONLY when a bot login is configured; with no configured
 * identity there is nothing to mention and the form is inert rather than
 * matching some arbitrary "@" prefix.
 */
function extractCommand(body, prefix, mention) {
  const forms = [{ token: prefix, via: 'command' }];
  if (mention) {
    // GitHub renders the App's login as "name[bot]" but users type "@name".
    const bare = String(mention).replace(/\[bot\]$/i, '');
    forms.push({ token: '@' + bare, via: 'mention' });
    forms.push({ token: '@' + String(mention), via: 'mention' });
  }

  const lines = String(body).split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const lower = trimmed.toLowerCase();
    for (const form of forms) {
      const token = form.token.toLowerCase();
      if (!token) continue;
      if (lower === token || lower.startsWith(token + ' ')) {
        return { found: true, prompt: trimmed.slice(form.token.length).trim(), via: form.via };
      }
    }
  }
  return { found: false, prompt: '', via: null };
}

function normalizeIssue(value) {
  const n = Number.parseInt(String(value == null ? '' : value), 10);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/**
 * Session names end up as ACA execution names and lease key parts, so they are
 * bounded and character-restricted. The run id keeps two triggers on the same
 * issue from colliding; without it a second dispatch would reuse a name.
 */
function buildSessionName(kind, issueNumber, payload) {
  const runId = sanitizeName(
    payload.__runId || process.env.GITHUB_RUN_ID || String(Date.now())
  );
  const parts = [sanitizeName(kind)];
  if (issueNumber) parts.push(String(issueNumber));
  if (runId) parts.push(runId);
  return parts.filter(Boolean).join('-').slice(0, 60).replace(/-$/, '');
}

/**
 * Map a lease-claim OUTCOME onto what the trigger should do next.
 *
 * This exists because the workflow originally tested `.claimed`, a field the
 * claim response has never had. `jq '.claimed // false'` therefore evaluated to
 * "false" on every run, the start step was skipped by its `if:`, and the
 * workflow reported SUCCESS having dispatched nothing. A green run that did
 * nothing is the worst possible failure mode, and it survived a live end-to-end
 * test because everything it printed looked right.
 *
 * Putting the mapping here rather than in YAML is the point: a `jq` expression
 * inside a workflow is reachable by no test, exactly like the push logic that
 * had to be lifted out of entrypoint.sh in sprint 1.
 *
 * The real outcomes come from dispatch-lease.js:
 *   created         a new lease was written        -> START
 *   repaired        a crashed lease was reclaimed  -> START
 *   active          someone else holds it          -> STAND DOWN (not an error)
 *   already-terminal the work is finished          -> STAND DOWN
 *   refused         routing could not be resolved  -> ERROR
 *   gone            the lease vanished             -> ERROR
 *
 * @returns {{action: 'start'|'stand-down'|'error', reason: string}}
 */
function classifyClaim(outcome) {
  switch (String(outcome || '')) {
    case 'created':
      return { action: 'start', reason: 'lease-created' };
    case 'repaired':
      return { action: 'start', reason: 'lease-repaired' };
    case 'active':
      return { action: 'stand-down', reason: 'another-dispatcher-holds-the-lease' };
    case 'already-terminal':
      return { action: 'stand-down', reason: 'work-already-finished' };
    case 'completed':
      // The lease for this key is in a terminal SUCCESS state and the claim did
      // NOT adopt it, so there is no lease to run under. Starting anyway would
      // dispatch an unleased session, which is the double-dispatch protection
      // deleting itself.
      //
      // This is a stand-down rather than an error because nothing is broken:
      // the work this key names has already been done. It does mean a second
      // request on the SAME issue is inert until the lease is released, which
      // is a real limitation of keying leases by issue and is documented in
      // docs/actions-trigger.md rather than papered over here.
      return { action: 'stand-down', reason: 'lease-already-succeeded' };
    case 'refused':
      return { action: 'error', reason: 'routing-refused' };
    default:
      // An UNRECOGNISED outcome is an error, never a silent stand-down. A
      // default of "do nothing" is how the original defect stayed invisible:
      // the unknown case looked exactly like a polite decision not to run.
      return { action: 'error', reason: 'unrecognised-claim-outcome' };
  }
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    const next = argv[i + 1];
    out[key] = next && !next.startsWith('--') ? (i += 1, next) : 'true';
  }
  return out;
}

function main(argv) {
  const args = parseArgs(argv);

  // `--claim-outcome` is a separate verb so the workflow never has to encode
  // the lease vocabulary in a jq expression again. Exit 75 (EX_TEMPFAIL) on an
  // error verdict so the workflow step fails rather than continuing quietly.
  if (args.claimOutcome !== undefined) {
    const c = classifyClaim(args.claimOutcome);
    process.stdout.write(JSON.stringify(c) + '\n');
    return c.action === 'error' ? 75 : 0;
  }

  if (!args.eventPath) {
    process.stderr.write('actions-event: --event-path is required\n');
    return 64;
  }
  let payload;
  try {
    payload = JSON.parse(fs.readFileSync(args.eventPath, 'utf8'));
  } catch (err) {
    process.stderr.write(`actions-event: could not read the event payload: ${err.message}\n`);
    return 65;
  }
  const result = resolveEvent({
    eventName: args.eventName,
    payload,
    triggerLabel: args.triggerLabel,
    commandPrefix: args.commandPrefix,
    botLogin: args.botLogin
  });
  process.stdout.write(JSON.stringify(result) + '\n');
  return 0;
}

if (require.main === module) {
  process.exit(main(process.argv.slice(2)));
}

module.exports = {
  resolveEvent,
  classifyClaim,
  extractCommand,
  sanitizeName,
  buildSessionName,
  REASON,
  DEFAULT_TRIGGER_LABEL,
  DEFAULT_COMMAND_PREFIX
};
