#!/usr/bin/env node
'use strict';

/**
 * dispatch-lease.js
 *
 * Sprint 6 of PRD #6: durable claim-before-compute, leases, heartbeats, and a
 * stale-lease sweeper -- in ONE implementation that bash and PowerShell both
 * call, for the same reason the routing decision is shared (see
 * dispatch-decision.js).
 *
 * WHERE LEASE STATE LIVES, AND WHY
 * --------------------------------
 * In GitHub, in the worked-on repository, on a dedicated ref
 * (`squad-aca-leases` by default), one JSON blob per lease under `leases/`.
 *
 *   * GitHub is already this project's durable system of record -- issues,
 *     labels, branches, pull requests -- and Ralph already claims work by
 *     labelling an issue. Putting the lease next to the claim keeps one source
 *     of truth instead of two that can disagree.
 *   * It adds NO infrastructure. No storage account, no table, no lock blob, no
 *     extra RBAC surface. Every dispatcher already has an authenticated `gh`.
 *   * The Contents API gives the two primitives a lease needs:
 *       - PUT without `sha` fails (422) when the file already exists, which is
 *         an ATOMIC CREATE-ONCE -- the claim primitive.
 *       - PUT with `sha` is compare-and-swap, so a heartbeat cannot clobber a
 *         concurrent terminal write.
 *   * It survives a laptop reboot, a container restart, and a Ralph job
 *     execution being reaped mid-flight. A local file would not.
 *   * The ref is dedicated and orphaned (its first commit has the empty tree
 *     and no parents), so lease churn never touches the default branch, never
 *     triggers CI, and never shows up in a pull request diff.
 *
 * IDEMPOTENT CLEANUP IS NOT "IGNORE EVERY FAILURE"
 * ------------------------------------------------
 * This file follows the exact pattern established for ACA Job teardown in
 * scripts/lib/providers/squad-aca-job-provider.ps1: a safe CLI invoker that
 * captures the real exit code plus stdout/stderr (`invokeGhSafe`, the analogue
 * of Invoke-AzPromptSafe), and a fail-closed, deny-list-first classifier
 * (`isGoneResult`, the analogue of Test-AcaJobExecutionGone).
 *
 * Already-cleaned, already-terminal, and externally-deleted are SUCCESS.
 * Authentication failures, permission denials, throttling, network faults, and
 * a missing `gh` binary are NOT: they say nothing about the lease's state, so
 * reporting them as "cleaned" would tell the sweeper that a lease it never
 * touched is safely reclaimed.
 *
 * NO SECRETS. A lease record carries identifiers, a route, a dispatcher name,
 * and timestamps. It never carries a prompt, a token, or a secret reference.
 */

const { spawnSync } = require('child_process');

const LEASE_SCHEMA_VERSION = 1;
const DEFAULT_LEASE_BRANCH = 'squad-aca-leases';
const LEASE_DIRECTORY = 'leases';
const DEFAULT_TTL_SECONDS = 3600;

// git's well-known empty tree object. Committing it with no parents produces an
// orphan commit, so the lease ref carries lease records only.
const EMPTY_TREE_SHA = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

const STATE_CLAIMED = 'claimed';
const STATE_DISPATCHED = 'dispatched';
const STATE_RUNNING = 'running';
const STATE_SUCCEEDED = 'succeeded';
const STATE_FAILED = 'failed';
const STATE_CANCELLED = 'cancelled';
const STATE_RECLAIMED = 'reclaimed';
const STATE_RELEASED = 'released';

const ACTIVE_STATES = [STATE_DISPATCHED, STATE_RUNNING];
const TERMINAL_STATES = [STATE_SUCCEEDED, STATE_FAILED, STATE_CANCELLED, STATE_RECLAIMED];

class LeaseError extends Error {}

// ---------------------------------------------------------------------------
// Safe `gh` invocation + gone-classification
// ---------------------------------------------------------------------------

function ghInvocation(args) {
  // Production always uses the real `gh` on PATH. SQUAD_GH_BIN exists so the
  // offline harnesses can point at a stand-in without a shell: a `.js` value is
  // run with this same node binary, which keeps quoting identical on Windows
  // and Linux and avoids `spawnSync` needing PATHEXT resolution for `.cmd`.
  const bin = process.env.SQUAD_GH_BIN || 'gh';
  if (/\.js$/i.test(bin)) return { command: process.execPath, argv: [bin].concat(args) };
  return { command: bin, argv: args };
}

function invokeGhSafe(args, options) {
  const opts = options || {};
  const { command, argv } = ghInvocation(args);
  const result = spawnSync(command, argv, {
    encoding: 'utf8',
    input: opts.input === undefined ? undefined : opts.input,
    maxBuffer: 8 * 1024 * 1024
  });

  if (result.error) {
    // 127 is the marker for "gh could not be run at all". It must never be read
    // as "the lease is gone".
    const missing = result.error.code === 'ENOENT';
    return {
      exitCode: missing ? 127 : -1,
      stdout: '',
      stderr: String(result.error.message || '')
    };
  }

  return {
    exitCode: typeof result.status === 'number' ? result.status : -1,
    stdout: String(result.stdout || ''),
    stderr: String(result.stderr || '')
  };
}

// Deny-list first, exactly like Test-AcaJobExecutionGone: a failure whose text
// matches a known real-failure signature is a real failure even when it also
// mentions "not found" (a permission denial commonly reads as
// "Not Found" or "Resource not accessible").
const REAL_FAILURE_PATTERNS = [
  // Authentication
  /gh auth login/i,
  /Bad credentials/i,
  /HTTP 401/i,
  /must be authenticated/i,
  /authentication failed/i,
  /token has expired/i,
  /requires? authentication/i,
  // Authorization
  /HTTP 403/i,
  /Forbidden/i,
  /Resource not accessible/i,
  /SAML enforcement/i,
  /permission/i,
  // Throttling
  /HTTP 429/i,
  /rate limit/i,
  /Retry-After/i,
  /abuse detection/i,
  // Network / service availability
  /HTTP 5\d\d/i,
  /dial tcp/i,
  /no such host/i,
  /connection refused/i,
  /connection reset/i,
  /i\/o timeout/i,
  /timed? ?out/i,
  /TLS handshake/i,
  /EOF\b/,
  /server error/i,
  // gh itself could not run
  /command not found/i,
  /is not recognized as/i,
  /executable file not found/i
];

const GONE_PATTERNS = [
  /HTTP 404/i,
  /Not Found/i,
  /does not exist/i,
  /No commit found/i,
  /This repository is empty/i
];

function isGoneResult(result) {
  // 127 = gh missing, -1 = exit code never observed. Neither says anything
  // about the lease.
  if (result.exitCode === 127 || result.exitCode === -1) return false;
  if (result.exitCode === 0) return false;

  const text = [result.stderr, result.stdout].filter(Boolean).join(' ');
  for (const pattern of REAL_FAILURE_PATTERNS) {
    if (pattern.test(text)) return false;
  }
  for (const pattern of GONE_PATTERNS) {
    if (pattern.test(text)) return true;
  }
  return false;
}

function failureText(result) {
  const parts = [];
  if (result.stderr && result.stderr.trim()) parts.push(result.stderr.trim());
  if (result.stdout && result.stdout.trim()) parts.push(result.stdout.trim());
  return parts.join(' ').replace(/\s+/g, ' ').slice(0, 400);
}

function ghFailure(action, result) {
  return new LeaseError(
    `Lease store could not ${action}: 'gh' exited ${result.exitCode} and the failure is not ` +
      `'already gone or already terminal'. ${failureText(result)}`
  );
}

// ---------------------------------------------------------------------------
// Clock (pinnable so offline tests are deterministic)
// ---------------------------------------------------------------------------

function nowIso() {
  const pinned = process.env.SQUAD_LEASE_NOW;
  if (pinned) {
    const parsed = new Date(pinned);
    if (!Number.isNaN(parsed.getTime())) return parsed.toISOString();
    throw new LeaseError(`SQUAD_LEASE_NOW is not a valid timestamp.`);
  }
  return new Date().toISOString();
}

function ageSeconds(iso, reference) {
  const then = new Date(iso).getTime();
  const now = new Date(reference).getTime();
  if (Number.isNaN(then) || Number.isNaN(now)) return Number.POSITIVE_INFINITY;
  return (now - then) / 1000;
}

function ttlSeconds() {
  const raw = process.env.SQUAD_LEASE_TTL_SECONDS;
  if (!raw) return DEFAULT_TTL_SECONDS;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_TTL_SECONDS;
}

function leaseBranch() {
  return process.env.SQUAD_LEASE_BRANCH || DEFAULT_LEASE_BRANCH;
}

// ---------------------------------------------------------------------------
// GitHub-backed store
// ---------------------------------------------------------------------------

function parseJsonOrThrow(text, what) {
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new LeaseError(`Lease store received an unreadable ${what} response from 'gh'.`);
  }
}

function leasePath(key) {
  return `${LEASE_DIRECTORY}/${key}.json`;
}

function ensureLeaseRef(repository) {
  const branch = leaseBranch();
  const head = invokeGhSafe(['api', `repos/${repository}/git/ref/heads/${branch}`]);
  if (head.exitCode === 0) return 'present';
  if (!isGoneResult(head)) throw ghFailure(`read the '${branch}' ref`, head);

  // Orphan commit over the empty tree: the lease ref never carries repository
  // content, so it cannot be mistaken for a stale copy of a branch.
  const commit = invokeGhSafe(
    ['api', '--method', 'POST', `repos/${repository}/git/commits`, '--input', '-'],
    { input: JSON.stringify({ message: 'Squad on ACA lease ledger', tree: EMPTY_TREE_SHA, parents: [] }) }
  );
  if (commit.exitCode !== 0) throw ghFailure(`create the '${branch}' base commit`, commit);
  const commitJson = parseJsonOrThrow(commit.stdout, 'commit');

  const ref = invokeGhSafe(
    ['api', '--method', 'POST', `repos/${repository}/git/refs`, '--input', '-'],
    { input: JSON.stringify({ ref: `refs/heads/${branch}`, sha: commitJson.sha }) }
  );
  if (ref.exitCode === 0) return 'created';
  // A concurrent dispatcher won the race and created it first. That is success.
  if (/already exists/i.test(failureText(ref))) return 'present';
  throw ghFailure(`create the '${branch}' ref`, ref);
}

function readLeaseRecord(repository, key) {
  const branch = leaseBranch();
  const result = invokeGhSafe([
    'api',
    `repos/${repository}/contents/${leasePath(key)}?ref=${encodeURIComponent(branch)}`
  ]);
  if (result.exitCode !== 0) {
    if (isGoneResult(result)) return { found: false, lease: null, sha: null };
    throw ghFailure(`read lease '${key}'`, result);
  }
  const payload = parseJsonOrThrow(result.stdout, 'contents');
  const decoded = Buffer.from(String(payload.content || ''), 'base64').toString('utf8');
  return { found: true, lease: parseJsonOrThrow(decoded, 'lease'), sha: payload.sha };
}

function writeLeaseRecord(repository, key, lease, sha) {
  const branch = leaseBranch();
  const body = {
    message: `squad-aca lease ${lease.state}: ${key}`,
    content: Buffer.from(`${JSON.stringify(lease, null, 2)}\n`, 'utf8').toString('base64'),
    branch
  };
  if (sha) body.sha = sha;

  const result = invokeGhSafe(
    ['api', '--method', 'PUT', `repos/${repository}/contents/${leasePath(key)}`, '--input', '-'],
    { input: JSON.stringify(body) }
  );
  if (result.exitCode === 0) return parseJsonOrThrow(result.stdout, 'contents').content;

  const text = failureText(result);
  // 409/422 on a create means another dispatcher created the lease between our
  // read and our write. That is a lost race, not a failure of this process.
  if (/HTTP 409/i.test(text) || /HTTP 422/i.test(text) || /sha.*wasn't supplied/i.test(text)) {
    throw Object.assign(new LeaseError(`Lease '${key}' was written concurrently.`), { conflict: true });
  }
  throw ghFailure(`write lease '${key}'`, result);
}

function listLeaseRecords(repository) {
  const branch = leaseBranch();
  const result = invokeGhSafe([
    'api',
    `repos/${repository}/contents/${LEASE_DIRECTORY}?ref=${encodeURIComponent(branch)}`
  ]);
  if (result.exitCode !== 0) {
    // No ref or no directory yet: there is nothing to sweep. That is a success.
    if (isGoneResult(result)) return [];
    throw ghFailure('list leases', result);
  }
  const entries = parseJsonOrThrow(result.stdout, 'contents');
  if (!Array.isArray(entries)) return [];
  return entries
    .filter((e) => e && e.type === 'file' && typeof e.name === 'string' && e.name.endsWith('.json'))
    .map((e) => e.name.slice(0, -'.json'.length))
    .sort();
}

// ---------------------------------------------------------------------------
// Lease lifecycle
// ---------------------------------------------------------------------------

function newLease(decision, timestamp) {
  return {
    schemaVersion: LEASE_SCHEMA_VERSION,
    leaseKey: decision.leaseKey,
    sessionId: decision.sessionId,
    repository: decision.repository,
    issueNumber: decision.issueNumber,
    dispatchSource: decision.dispatchSource,
    route: decision.routing.route,
    executionMode: decision.routing.executionMode,
    state: STATE_CLAIMED,
    attempts: 1,
    startedAt: timestamp,
    lastHeartbeatAt: timestamp,
    updatedAt: timestamp,
    terminalReason: null,
    executionRef: null
  };
}

function isTerminal(lease) {
  return TERMINAL_STATES.includes(lease.state);
}

function isStale(lease, timestamp) {
  return ageSeconds(lease.lastHeartbeatAt, timestamp) > ttlSeconds();
}

/**
 * claim: write the lease BEFORE any compute is requested.
 *
 * Outcomes:
 *   created    no lease existed; this dispatcher owns the work.
 *   repaired   a lease existed but compute was never requested (a crash between
 *              claim and compute), or an active lease's heartbeat aged out.
 *              The SAME record is reused -- one lease, one execution.
 *   active     compute was already requested and the lease is alive. The caller
 *              MUST NOT dispatch. This is what stops a duplicate Ralph run from
 *              double-dispatching an issue whose label write was lost.
 *   completed  the lease reached a terminal state. The caller MUST NOT dispatch.
 */
function claimLease(repository, decision) {
  ensureLeaseRef(repository);
  const timestamp = nowIso();
  const key = decision.leaseKey;
  const existing = readLeaseRecord(repository, key);

  if (!existing.found) {
    const lease = newLease(decision, timestamp);
    try {
      writeLeaseRecord(repository, key, lease, null);
    } catch (err) {
      if (!err.conflict) throw err;
      // Someone claimed it in the gap. Re-read and fall through to the
      // existing-lease rules rather than overwriting their claim.
      const raced = readLeaseRecord(repository, key);
      if (raced.found) return decideExistingClaim(repository, decision, raced, timestamp);
      throw err;
    }
    return { outcome: 'created', lease };
  }

  return decideExistingClaim(repository, decision, existing, timestamp);
}

function decideExistingClaim(repository, decision, existing, timestamp) {
  const lease = existing.lease;

  if (lease.state === STATE_CLAIMED || lease.state === STATE_RELEASED || lease.state === STATE_RECLAIMED) {
    // claimed   -- a claim that never reached compute (crash between claim and
    //              start). Adopt it rather than minting a second lease.
    // released  -- the previous owner's compute request failed and handed the
    //              work back deliberately.
    // reclaimed -- the SWEEPER handed the work back. `reclaimed` is terminal for
    //              the purposes of sweeping (it is not swept again) but it must
    //              NOT block re-dispatch: a sweeper that permanently retired the
    //              work it reclaimed would turn every transient stall into lost
    //              work, which is the opposite of reclaiming it.
    const repaired = Object.assign({}, lease, {
      sessionId: decision.sessionId,
      dispatchSource: decision.dispatchSource,
      route: decision.routing.route,
      executionMode: decision.routing.executionMode,
      state: STATE_CLAIMED,
      attempts: (Number(lease.attempts) || 0) + 1,
      lastHeartbeatAt: timestamp,
      updatedAt: timestamp,
      terminalReason: null
    });
    writeLeaseRecord(repository, decision.leaseKey, repaired, existing.sha);
    return { outcome: 'repaired', lease: repaired };
  }

  if (ACTIVE_STATES.includes(lease.state)) {
    if (!isStale(lease, timestamp)) {
      return { outcome: 'active', lease };
    }
    const repaired = Object.assign({}, lease, {
      sessionId: decision.sessionId,
      dispatchSource: decision.dispatchSource,
      route: decision.routing.route,
      executionMode: decision.routing.executionMode,
      state: STATE_CLAIMED,
      attempts: (Number(lease.attempts) || 0) + 1,
      lastHeartbeatAt: timestamp,
      updatedAt: timestamp,
      terminalReason: null
    });
    writeLeaseRecord(repository, decision.leaseKey, repaired, existing.sha);
    return { outcome: 'repaired', lease: repaired };
  }

  return { outcome: 'completed', lease };
}

/** Records that compute HAS now been requested. Called after a confirmed start. */
function markDispatched(repository, key, executionRef) {
  const timestamp = nowIso();
  const existing = readLeaseRecord(repository, key);
  if (!existing.found) return { outcome: 'gone', lease: null };
  if (isTerminal(existing.lease)) return { outcome: 'already-terminal', lease: existing.lease };

  const lease = Object.assign({}, existing.lease, {
    state: STATE_DISPATCHED,
    executionRef: executionRef || existing.lease.executionRef || null,
    lastHeartbeatAt: timestamp,
    updatedAt: timestamp
  });
  writeLeaseRecord(repository, key, lease, existing.sha);
  return { outcome: 'dispatched', lease };
}

/** Compute could not be requested: hand the work back so it is retried. */
function releaseLease(repository, key, reason) {
  const timestamp = nowIso();
  const existing = readLeaseRecord(repository, key);
  if (!existing.found) return { outcome: 'gone', lease: null };
  if (isTerminal(existing.lease)) return { outcome: 'already-terminal', lease: existing.lease };

  const lease = Object.assign({}, existing.lease, {
    state: STATE_RELEASED,
    terminalReason: reason || 'compute-request-failed',
    lastHeartbeatAt: timestamp,
    updatedAt: timestamp
  });
  writeLeaseRecord(repository, key, lease, existing.sha);
  return { outcome: 'released', lease };
}

function heartbeatLease(repository, key) {
  const timestamp = nowIso();
  const existing = readLeaseRecord(repository, key);
  // Externally deleted: nothing to keep alive, and nothing is wrong.
  if (!existing.found) return { outcome: 'gone', lease: null };
  if (isTerminal(existing.lease)) return { outcome: 'already-terminal', lease: existing.lease };

  const lease = Object.assign({}, existing.lease, {
    state: STATE_RUNNING,
    lastHeartbeatAt: timestamp,
    updatedAt: timestamp
  });
  writeLeaseRecord(repository, key, lease, existing.sha);
  return { outcome: 'heartbeat', lease };
}

function completeLease(repository, key, state, reason) {
  if (!TERMINAL_STATES.includes(state)) {
    throw new LeaseError(`'${state}' is not a terminal lease state.`);
  }
  const timestamp = nowIso();
  const existing = readLeaseRecord(repository, key);
  if (!existing.found) return { outcome: 'gone', lease: null };
  if (existing.lease.state === state) return { outcome: 'already-terminal', lease: existing.lease };
  if (isTerminal(existing.lease)) return { outcome: 'already-terminal', lease: existing.lease };

  const lease = Object.assign({}, existing.lease, {
    state,
    terminalReason: reason || null,
    lastHeartbeatAt: timestamp,
    updatedAt: timestamp
  });
  writeLeaseRecord(repository, key, lease, existing.sha);
  return { outcome: 'completed', lease };
}

/**
 * sweep: reclaim leases whose heartbeat has aged out.
 *
 * Reclaims both orphaned claims (claimed, never dispatched) and orphaned
 * executions (dispatched/running, heartbeat stale). Idempotent by construction:
 * a reclaimed lease is terminal, so a second sweep skips it. A lease deleted
 * out from under the sweep counts as skipped, not as an error.
 */
function sweepLeases(repository) {
  const timestamp = nowIso();
  const keys = listLeaseRecords(repository);
  const reclaimed = [];
  const skipped = [];

  for (const key of keys) {
    const existing = readLeaseRecord(repository, key);
    if (!existing.found) {
      skipped.push({ key, reason: 'gone' });
      continue;
    }
    const lease = existing.lease;
    if (isTerminal(lease) || lease.state === STATE_RELEASED) {
      skipped.push({ key, reason: 'terminal' });
      continue;
    }
    if (!isStale(lease, timestamp)) {
      skipped.push({ key, reason: 'alive' });
      continue;
    }
    const reason = lease.state === STATE_CLAIMED ? 'orphaned-claim' : 'heartbeat-expired';
    const updated = Object.assign({}, lease, {
      state: STATE_RECLAIMED,
      terminalReason: reason,
      updatedAt: timestamp
    });
    writeLeaseRecord(repository, key, updated, existing.sha);
    reclaimed.push({ key, reason });
  }

  return { outcome: 'swept', reclaimed, skipped, examined: keys.length };
}

function listLeases(repository) {
  const keys = listLeaseRecords(repository);
  const leases = [];
  for (const key of keys) {
    const existing = readLeaseRecord(repository, key);
    if (existing.found) leases.push(existing.lease);
  }
  return { outcome: 'listed', leases };
}

module.exports = {
  ACTIVE_STATES,
  DEFAULT_LEASE_BRANCH,
  DEFAULT_TTL_SECONDS,
  LEASE_DIRECTORY,
  LEASE_SCHEMA_VERSION,
  LeaseError,
  STATE_CANCELLED,
  STATE_CLAIMED,
  STATE_DISPATCHED,
  STATE_FAILED,
  STATE_RECLAIMED,
  STATE_RELEASED,
  STATE_RUNNING,
  STATE_SUCCEEDED,
  TERMINAL_STATES,
  claimLease,
  completeLease,
  ensureLeaseRef,
  heartbeatLease,
  invokeGhSafe,
  isGoneResult,
  isStale,
  isTerminal,
  leaseBranch,
  listLeases,
  markDispatched,
  nowIso,
  readLeaseRecord,
  releaseLease,
  sweepLeases,
  ttlSeconds
};
