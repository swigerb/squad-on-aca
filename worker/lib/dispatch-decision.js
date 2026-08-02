#!/usr/bin/env node
'use strict';

/**
 * dispatch-decision.js
 *
 * Sprint 6 of PRD #6: ONE routing decision, shared by every dispatcher.
 *
 * Three dispatchers exist and they used to decide independently:
 *
 *   local-cli  scripts/squad-aca.ps1        (PowerShell, developer machine)
 *   ralph      worker/lib/ralph-dispatch.sh (bash, cron-triggered ACA Job)
 *   watch      scripts/start-watch.ps1 +    (PowerShell control plane driving a
 *              worker/entrypoint.sh watch    hosted Container App)
 *
 * Two of the three run bash, one runs PowerShell. Implementing the routing rule
 * in both languages guarantees drift, and a drifted route is invisible until a
 * repository is dispatched to the wrong substrate. So the rule lives HERE, in
 * one file, and every dispatcher shells out to it:
 *
 *   bash        node .../squad-dispatch.js decide ...
 *   PowerShell  node .../squad-dispatch.js decide ...   (scripts/lib/dispatch-contract.ps1)
 *
 * Node is the right host for it because the routing rule this builds on --
 * worker/lib/resolve-capability-route.js, Sprint 2 -- is already Node, and both
 * bash dispatchers already depend on `node` (ralph-dispatch.sh builds its env
 * with it). Nothing is re-implemented here: the capability decision is produced
 * by the Sprint 2 resolver and carried verbatim.
 *
 * DETERMINISM IS THE CONTRACT. The `routing` object below is a pure function of
 * (repository working tree, manifest path, catalog). It contains no timestamp,
 * no random value, and -- deliberately -- nothing that identifies the
 * dispatcher, so the three dispatchers' decisions are comparable BYTE FOR BYTE.
 * The dispatcher's identity lives outside `routing`, in `dispatchSource`.
 *
 * Route -> execution mode mapping:
 *
 *   capability aca-job      -> executionMode aca-job, dispatch
 *   capability sandbox      -> executionMode sandbox, dispatch. The Sandboxes
 *                              provider landed in Sprint 5
 *                              (scripts/lib/providers/squad-sandbox-provider.ps1)
 *                              and is wired into the CLI in issue #25, so the
 *                              route is now reachable. Acting on it ALSO
 *                              requires the control-plane feature flag
 *                              SQUAD_ACA_ENABLE_SANDBOX and an approved,
 *                              non-provisional catalog class; this file states
 *                              what the manifest asked for, and
 *                              Resolve-SquadExecutionRoute decides whether the
 *                              deployment will honour it. The in-worker
 *                              preflight remains the final gate either way.
 *   capability fail-closed  -> executionMode null, REFUSE. A repository whose
 *                              manifest cannot be resolved is not dispatched.
 *
 * Redaction: every string emitted here is either a fixed vocabulary term or a
 * value the Sprint 2 resolver already redacted. No manifest text, no prompt, no
 * token, and no secret reference passes through this file. The egress fields
 * added by the capability-manifest future-work sprint 3 keep that property: the
 * dispatch-level statement is a COUNT (`egressAdvisoryHostCount`), never a host
 * string.
 */

const fs = require('fs');

const {
  ROUTE_ACA_JOB,
  ROUTE_SANDBOX,
  ROUTE_FAIL_CLOSED,
  SandboxCatalogError,
  loadCatalog,
  locateManifest,
  loadManifest,
  resolveCapabilityRoute
} = require('./resolve-capability-route.js');

const DISPATCH_SCHEMA_VERSION = 1;
const DEFAULT_MANIFEST_RELATIVE_PATH = 'squad-capabilities.yml';

// `actions` was added by issue #32. It is a dispatch SOURCE, not a second
// dispatcher: a GitHub Actions workflow authenticates to Azure by OIDC and
// starts the same ACA job with the same decision and the same lease, so
// Actions is only the trigger transport and the control-plane logic stays in
// Azure. Adding it here rather than letting the workflow invent its own key is
// what keeps Ralph's poll and an Actions trigger from dispatching the same
// issue twice -- they contend for one lease.
const DISPATCH_SOURCES = ['local-cli', 'ralph', 'watch', 'actions'];

const ACTION_DISPATCH = 'dispatch';
const ACTION_REFUSE = 'refuse';

// Whether a sandbox execution provider exists on this build. Kept as a named
// constant rather than an inline literal so the reason a sandbox route falls
// back stays greppable and testable. Flipped on by issue #25, which wired the
// Sprint 5 Sandboxes provider into the CLI's dispatch path.
const SANDBOX_PROVIDER_AVAILABLE = true;

const ROUTING_DETAILS = {
  'aca-job':
    'Routed to the default ACA Jobs execution path.',
  'sandbox':
    'Routed to an administrator-approved ACA Sandboxes class. The dispatcher must also have the sandbox execution plane enabled and the class must be approved in a non-provisional catalog, or the dispatch fails closed rather than downgrading.',
  'sandbox-provider-unavailable':
    'The capability decision selected a sandbox class, but no sandbox execution provider is wired on this build, so the dispatch falls back to the default ACA Jobs path. The in-worker capability preflight remains the final gate.',
  'fail-closed':
    'The capability decision could not be resolved, so no execution is dispatched. Fix the capability manifest or the administrator catalog and retry.'
};

// Lease keys are path segments in the lease store, so they are restricted to a
// conservative character set. Anything else is replaced; an empty result is
// rejected by the caller rather than silently keyed as "".
function sanitizeKeyPart(value) {
  return String(value == null ? '' : value)
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 96);
}

/**
 * The lease key -- the identity a claim is made against.
 *
 * Issue-backed work keys on the ISSUE, not on the timestamped session name.
 * That is the whole idempotency mechanism: two Ralph runs for issue #10, or one
 * run that crashed between claiming and dispatching, converge on the SAME key
 * and therefore on the same lease record, instead of minting a fresh lease (and
 * a fresh execution) per attempt.
 */
function buildLeaseKey(input) {
  const issue = input.issueNumber;
  if (issue !== null && issue !== undefined && String(issue).trim() !== '') {
    const key = sanitizeKeyPart(`issue-${issue}`);
    if (key) return key;
  }
  return sanitizeKeyPart(`session-${input.sessionId}`);
}

function normalizeIssueNumber(value) {
  if (value === null || value === undefined || String(value).trim() === '') return null;
  const n = Number.parseInt(String(value), 10);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/**
 * Turns a Sprint 2 capability decision into the dispatch-level routing object.
 * Pure: same capability decision in, same bytes out.
 */
function buildRouting(capability) {
  let executionMode = null;
  let action = ACTION_REFUSE;
  let fallbackReason = null;
  let detail = ROUTING_DETAILS['fail-closed'];

  if (capability.route === ROUTE_ACA_JOB) {
    executionMode = 'aca-job';
    action = ACTION_DISPATCH;
    detail = ROUTING_DETAILS['aca-job'];
  } else if (capability.route === ROUTE_SANDBOX) {
    if (SANDBOX_PROVIDER_AVAILABLE) {
      executionMode = 'sandbox';
      action = ACTION_DISPATCH;
      detail = ROUTING_DETAILS['sandbox'];
    } else {
      executionMode = 'aca-job';
      action = ACTION_DISPATCH;
      fallbackReason = 'sandbox-provider-unavailable';
      detail = ROUTING_DETAILS['sandbox-provider-unavailable'];
    }
  }

  // Egress honesty, lifted to the dispatch level (future-work sprint 3). A
  // consumer that reads only `routing` -- the dispatchers do -- would otherwise
  // have to reach into `routing.capability` to discover that the plane it is
  // about to use will not enforce the manifest's declared destinations.
  //
  // The COUNT is surfaced, not the hosts. Host strings are repository-
  // controlled manifest text, and this object is what the operator-facing
  // dispatchers render and log. The hosts themselves stay in
  // `routing.capability.egressAdvisoryHosts` for a machine that wants them.
  const advisoryHosts = Array.isArray(capability.egressAdvisoryHosts)
    ? capability.egressAdvisoryHosts
    : [];

  return {
    route: capability.route,
    reason: capability.reason,
    action,
    executionMode,
    sandboxClass: action === ACTION_DISPATCH && executionMode === 'sandbox' ? capability.sandboxClass : null,
    fallbackReason,
    manifestPresent: capability.manifestPresent,
    egressEnforced: capability.egressEnforced === true,
    egressAdvisoryHostCount: advisoryHosts.length,
    detail,
    capability
  };
}

/**
 * Resolves the full dispatch decision.
 *
 * @param {object} input
 *   sessionId       required
 *   dispatchSource  one of DISPATCH_SOURCES
 *   repository      "owner/name" (carried, never parsed for routing)
 *   issueNumber     optional
 *   repoDir         optional working tree; absent/unreadable => no manifest
 *   manifestPath    manifest path relative to repoDir
 *   catalog         a loaded catalog object (null => fail closed)
 */
function resolveDispatchDecision(input) {
  const dispatchSource = DISPATCH_SOURCES.includes(input.dispatchSource)
    ? input.dispatchSource
    : 'local-cli';
  const issueNumber = normalizeIssueNumber(input.issueNumber);

  let capability;
  if (!input.catalog) {
    capability = resolveCapabilityRoute({ manifestPresent: false, catalog: null });
  } else if (!input.repoDir || !fs.existsSync(input.repoDir)) {
    // No working tree to read (Ralph dispatches from issue metadata and never
    // clones the target repository). "No manifest" is the same input the
    // resolver sees for a repository that simply has none, so the decision is
    // identical -- which is exactly what makes the three dispatchers agree.
    capability = resolveCapabilityRoute({ manifestPresent: false, catalog: input.catalog });
  } else {
    const relative = input.manifestPath || DEFAULT_MANIFEST_RELATIVE_PATH;
    const located = locateManifest(input.repoDir, relative);
    if (located.status === 'absent') {
      capability = resolveCapabilityRoute({ manifestPresent: false, catalog: input.catalog });
    } else if (located.status === 'unsafe') {
      capability = resolveCapabilityRoute({
        manifestPresent: true,
        manifestFailure: 'manifest-path-unsafe',
        catalog: input.catalog
      });
    } else {
      const loaded = loadManifest(located.path);
      capability = resolveCapabilityRoute({
        manifestPresent: true,
        manifest: loaded.manifest,
        manifestFailure: loaded.failure,
        catalog: input.catalog
      });
    }
  }

  const routing = buildRouting(capability);

  return {
    schemaVersion: DISPATCH_SCHEMA_VERSION,
    sessionId: String(input.sessionId || ''),
    dispatchSource,
    repository: String(input.repository || ''),
    issueNumber,
    leaseKey: buildLeaseKey({ issueNumber, sessionId: input.sessionId }),
    routing
  };
}

module.exports = {
  ACTION_DISPATCH,
  ACTION_REFUSE,
  DEFAULT_MANIFEST_RELATIVE_PATH,
  DISPATCH_SCHEMA_VERSION,
  DISPATCH_SOURCES,
  SANDBOX_PROVIDER_AVAILABLE,
  SandboxCatalogError,
  buildLeaseKey,
  buildRouting,
  loadCatalog,
  resolveDispatchDecision,
  ROUTE_ACA_JOB,
  ROUTE_SANDBOX,
  ROUTE_FAIL_CLOSED
};
