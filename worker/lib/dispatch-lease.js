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
 * THE LEDGER IS BOUNDED, AND SO IS THE SWEEP
 * ------------------------------------------
 * A ledger that only ever grows is an outage waiting for a date. Ralph sweeps at
 * the top of every run on a five-minute cron, so an O(n) sweep over an append-only
 * ledger walks into GitHub's 5,000/hr REST budget; the resulting 429 is
 * correctly classified as a real failure, which makes `claimLease` throw, which
 * stops dispatch for EVERY issue. Two bounds prevent that: terminal leases are
 * DELETED past a retention window (`isPrunable` + `deleteLeaseRecord`), and one
 * sweep reads at most `sweepMaxReads()` records with a clock-derived rotating
 * offset (`sweepLeases`). The Contents API's 1,000-entry listing cap is reported
 * as `truncated` rather than silently swallowed.
 *
 * NO SECRETS. A lease record carries identifiers, a route, a dispatcher name,
 * and timestamps. It never carries a prompt, a token, or a secret reference.
 */

const { spawnSync } = require('child_process');

const LEASE_SCHEMA_VERSION = 1;
const DEFAULT_LEASE_BRANCH = 'squad-aca-leases';
const LEASE_DIRECTORY = 'leases';
const DEFAULT_TTL_SECONDS = 3600;

// A `claimed` lease and a `dispatched`/`running` lease have wildly different
// legitimate lifetimes, so they cannot share one timeout.
//
//   * A session legitimately runs for the full DEFAULT_TTL_SECONDS.
//   * A claim legitimately lives only for the claim -> compute window: in
//     ralph-dispatch.sh that is `mktemp` + `ralph_build_session_env` (which
//     shells to node) + `az containerapp job start`, i.e. seconds.
//
// Using the session TTL for a claim would pin an issue for an hour after a
// dispatcher died mid-window; using the claim TTL for a session would let the
// sweeper reclaim a healthy run. DEFAULT_CLAIM_TTL_SECONDS is two orders of
// magnitude above the real window and equals Ralph's cron period, so a crashed
// claim is recovered on the run after next at the latest.
const DEFAULT_CLAIM_TTL_SECONDS = 300;

// Terminal, reclaimed and released leases are pruned once they are older than
// this. Without it the ledger is append-only: every run, smoke, telemetry smoke
// and Ralph issue mints a blob that is never removed, the sweeper's per-run cost
// grows with it, and the Contents API directory listing silently truncates at
// MAX_DIRECTORY_ENTRIES.
const DEFAULT_RETENTION_SECONDS = 7 * 24 * 3600;

// Hard cap on the number of lease records ONE sweep may read. This is what makes
// the sweeper's per-run API cost O(1) in the size of the ledger instead of O(n):
// Ralph sweeps on a */5 cron (288 runs/day), so an O(n) sweep over a few hundred
// leases exhausts the 5,000/hr authenticated REST budget, and a 429 then makes
// `claimLease` throw -- which stops dispatch for EVERY issue.
const DEFAULT_SWEEP_MAX_READS = 50;

// The window each sweep's starting offset is derived from, so successive runs
// cover the whole ledger by rotation without persisting a cursor (which would
// itself cost API calls and add a failure mode).
const SWEEP_ROTATION_PERIOD_SECONDS = 300;

// The GitHub Contents API returns at most 1,000 entries for a directory and
// gives no continuation token. Past that the ledger stops enumerating, so the
// sweeper stops seeing leases it should reclaim. We detect it and say so rather
// than truncating silently.
const MAX_DIRECTORY_ENTRIES = 1000;

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

/**
 * classifyGhFailure -- the ONE place a `gh` result becomes "gone" or "failure".
 *
 * It returns WHICH RULE DECIDED, not just the answer, and that is the point.
 * `isGone` alone is not observable enough to guard the deny-list-FIRST ordering:
 * for every input where only one list matches, both orderings produce the same
 * boolean. Only a message that matches BOTH lists distinguishes them, and only
 * `decidedBy` says which list won. Tests assert `decidedBy`, so swapping the two
 * loops is a visible, failing change even where `isGone` happens to agree.
 *
 * This defect class (a "not found" reading beating a real failure) has now been
 * shipped three times in this programme -- Sprint 3 B1 (`terminate`), Sprint 5
 * (`cancel`), and Sprint 6 here. Every occurrence was invisible because the
 * fixtures only ever matched one list.
 *
 * decidedBy values:
 *   success               exit 0; nothing to classify.
 *   gh-unavailable        exit 127; `gh` could not be run at all.
 *   exit-code-unobserved  exit -1; the process never reported a status.
 *   real-failure          the DENY list matched. Wins over any "gone" reading.
 *   gone                  only the gone list matched.
 *   unrecognised          neither list matched -> fail closed, NOT gone.
 */
function classifyGhFailure(result) {
  if (result.exitCode === 127) return { isGone: false, decidedBy: 'gh-unavailable', pattern: null };
  if (result.exitCode === -1) return { isGone: false, decidedBy: 'exit-code-unobserved', pattern: null };
  if (result.exitCode === 0) return { isGone: false, decidedBy: 'success', pattern: null };

  const text = [result.stderr, result.stdout].filter(Boolean).join(' ');
  for (const pattern of REAL_FAILURE_PATTERNS) {
    if (pattern.test(text)) return { isGone: false, decidedBy: 'real-failure', pattern: String(pattern) };
  }
  for (const pattern of GONE_PATTERNS) {
    if (pattern.test(text)) return { isGone: true, decidedBy: 'gone', pattern: String(pattern) };
  }
  return { isGone: false, decidedBy: 'unrecognised', pattern: null };
}

function isGoneResult(result) {
  return classifyGhFailure(result).isGone;
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

function positiveEnvSeconds(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function claimTtlSeconds() {
  // Never longer than the session TTL: an operator who shortens the session TTL
  // has, by definition, also shortened the window a claim may occupy.
  const configured = positiveEnvSeconds('SQUAD_LEASE_CLAIM_TTL_SECONDS', DEFAULT_CLAIM_TTL_SECONDS);
  return Math.min(configured, ttlSeconds());
}

function retentionSeconds() {
  return positiveEnvSeconds('SQUAD_LEASE_RETENTION_SECONDS', DEFAULT_RETENTION_SECONDS);
}

function sweepMaxReads() {
  return positiveEnvSeconds('SQUAD_LEASE_SWEEP_MAX_READS', DEFAULT_SWEEP_MAX_READS);
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

/**
 * deleteLeaseRecord: the ONLY path that removes a blob from the ledger.
 *
 * Returns true when the blob is gone afterwards (deleted here, or already gone),
 * false when a concurrent write moved the sha out from under us -- in that case
 * the record is live again and must be left alone. Real failures still throw:
 * pruning must never report a lease removed that it could not touch.
 */
function deleteLeaseRecord(repository, key, sha) {
  const branch = leaseBranch();
  const result = invokeGhSafe(
    ['api', '--method', 'DELETE', `repos/${repository}/contents/${leasePath(key)}`, '--input', '-'],
    { input: JSON.stringify({ message: `squad-aca lease prune: ${key}`, sha, branch }) }
  );
  if (result.exitCode === 0) return true;

  const text = failureText(result);
  // Lost a compare-and-swap race with a concurrent writer. Not an error; the
  // record simply is not ours to prune this run.
  if (/HTTP 409/i.test(text) || /HTTP 422/i.test(text)) return false;
  if (isGoneResult(result)) return true;
  throw ghFailure(`prune lease '${key}'`, result);
}

function listLeaseRecords(repository) {
  const branch = leaseBranch();
  const result = invokeGhSafe([
    'api',
    `repos/${repository}/contents/${LEASE_DIRECTORY}?ref=${encodeURIComponent(branch)}`
  ]);
  if (result.exitCode !== 0) {
    // No ref or no directory yet: there is nothing to sweep. That is a success.
    if (isGoneResult(result)) return { keys: [], truncated: false };
    throw ghFailure('list leases', result);
  }
  const entries = parseJsonOrThrow(result.stdout, 'contents');
  if (!Array.isArray(entries)) return { keys: [], truncated: false };
  const keys = entries
    .filter((e) => e && e.type === 'file' && typeof e.name === 'string' && e.name.endsWith('.json'))
    .map((e) => e.name.slice(0, -'.json'.length))
    .sort();
  // The Contents API caps a directory listing at MAX_DIRECTORY_ENTRIES with no
  // continuation token, so at the cap we cannot know whether we saw everything.
  // Report it; callers surface it instead of quietly sweeping a partial ledger.
  return { keys, truncated: entries.length >= MAX_DIRECTORY_ENTRIES };
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
 * A `claimed` lease is a dispatcher sitting INSIDE the claim -> compute window.
 * That window is not a millisecond: in ralph-dispatch.sh it spans `mktemp`,
 * `ralph_build_session_env` (which shells to node) and
 * `az containerapp job start`. Until it closes, the owning dispatcher has NOT
 * yet requested compute, so nothing else may adopt the lease -- otherwise both
 * dispatchers are told "you own it, dispatch" and one issue gets two executions.
 *
 * Measured against lastHeartbeatAt, which `claim` stamps with the claim time.
 */
function isClaimStale(lease, timestamp) {
  return ageSeconds(lease.lastHeartbeatAt, timestamp) > claimTtlSeconds();
}

/** True when this lease is past its retention window and may be pruned. */
function isPrunable(lease, timestamp) {
  if (!isTerminal(lease) && lease.state !== STATE_RELEASED) return false;
  return ageSeconds(lease.updatedAt || lease.lastHeartbeatAt, timestamp) > retentionSeconds();
}

/**
 * claim: write the lease BEFORE any compute is requested.
 *
 * Outcomes:
 *   created    no lease existed; this dispatcher owns the work.
 *   repaired   an ABANDONED lease was adopted -- a claim whose owner never
 *              reached compute within the claim window, a deliberate handback
 *              (`released`), a sweeper reclaim, or an active lease whose
 *              heartbeat aged out. The SAME record is reused -- one lease, one
 *              execution.
 *   active     another dispatcher owns this work RIGHT NOW: either it is inside
 *              its claim -> compute window (`claimed`, within the claim TTL) or
 *              compute is already running (`dispatched`/`running`, heartbeat
 *              fresh). The caller MUST NOT dispatch.
 *   completed  the lease reached a terminal state. The caller MUST NOT dispatch.
 *
 * Only `created` and `repaired` mean "you own it". Callers are written as
 * "dispatch on created|repaired, otherwise do not", so a future outcome cannot
 * accidentally become a dispatch.
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

  if (lease.state === STATE_CLAIMED) {
    // THE FIX FOR THE DOUBLE-DISPATCH: a `claimed` lease is NOT automatically a
    // crashed one. It is a live claim until it has been silent past the claim
    // TTL. Adopting it unconditionally handed BOTH dispatchers a "you own it"
    // answer (`created` for the first, `repaired` for the second) and both would
    // then call `az containerapp job start` for the same issue.
    //
    // This is the same gate ACTIVE_STATES uses, with the TTL that matches what a
    // `claimed` lease is allowed to be doing.
    if (!isClaimStale(lease, timestamp)) {
      return { outcome: 'active', lease };
    }
    return adoptLease(repository, decision, existing, timestamp);
  }

  if (lease.state === STATE_RELEASED || lease.state === STATE_RECLAIMED) {
    // released  -- the previous owner's compute request failed and handed the
    //              work back DELIBERATELY, so there is no owner to race.
    // reclaimed -- the SWEEPER handed the work back. `reclaimed` is terminal for
    //              the purposes of sweeping (it is not swept again) but it must
    //              NOT block re-dispatch: a sweeper that permanently retired the
    //              work it reclaimed would turn every transient stall into lost
    //              work, which is the opposite of reclaiming it.
    return adoptLease(repository, decision, existing, timestamp);
  }

  if (ACTIVE_STATES.includes(lease.state)) {
    if (!isStale(lease, timestamp)) {
      return { outcome: 'active', lease };
    }
    return adoptLease(repository, decision, existing, timestamp);
  }

  return { outcome: 'completed', lease };
}

/**
 * Take over an abandoned lease record, in place, under compare-and-swap.
 *
 * The CAS matters as much as the staleness gate: two dispatchers can both read
 * the same abandoned record and both decide to adopt it. Exactly one PUT carries
 * the sha they read; the loser gets 409 and must be told the work is `active`,
 * not handed a second "you own it".
 */
function adoptLease(repository, decision, existing, timestamp) {
  const repaired = Object.assign({}, existing.lease, {
    sessionId: decision.sessionId,
    dispatchSource: decision.dispatchSource,
    route: decision.routing.route,
    executionMode: decision.routing.executionMode,
    state: STATE_CLAIMED,
    attempts: (Number(existing.lease.attempts) || 0) + 1,
    lastHeartbeatAt: timestamp,
    updatedAt: timestamp,
    terminalReason: null
  });

  try {
    writeLeaseRecord(repository, decision.leaseKey, repaired, existing.sha);
  } catch (err) {
    if (!err.conflict) throw err;
    const raced = readLeaseRecord(repository, decision.leaseKey);
    if (raced.found) return { outcome: 'active', lease: raced.lease };
    throw err;
  }
  return { outcome: 'repaired', lease: repaired };
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
 * sweep: reclaim leases whose heartbeat has aged out, AND prune the ledger.
 *
 * Two costs are bounded here, and both bounds are load-bearing:
 *
 *  1. LEDGER SIZE. Reclaiming without deleting made the ledger append-only:
 *     every `run`, `smoke`, `telemetry smoke` and Ralph issue minted a blob that
 *     nothing ever removed. Terminal / reclaimed / released leases older than
 *     the retention window are DELETED, so the ledger tracks work in flight
 *     rather than work ever done, and it stays well under the Contents API's
 *     1,000-entry directory listing cap.
 *
 *  2. PER-RUN API COST. The old sweep issued 1 listing + 1 read PER KEY, every
 *     run. Ralph sweeps on a five-minute cron -- 288 runs/day -- so a few hundred
 *     accumulated leases put it over the 5,000/hr authenticated REST budget.
 *     The consequence was not a slow sweep: a 429 is (correctly) classified as a
 *     real failure, so `claimLease` throws, Ralph logs "could not claim a
 *     lease ... skipping without labeling", and DISPATCH STOPS FOR EVERY ISSUE.
 *     A sweep now reads at most `sweepMaxReads()` records, so its cost is O(1)
 *     in the size of the ledger. The starting offset rotates with the clock, so
 *     successive runs still cover every key.
 *
 * Idempotent by construction: a reclaimed lease is terminal, so a second sweep
 * skips it. A lease deleted out from under the sweep counts as skipped, not as
 * an error.
 */
function sweepLeases(repository) {
  const timestamp = nowIso();
  const listing = listLeaseRecords(repository);
  const keys = listing.keys;
  const reclaimed = [];
  const pruned = [];
  const skipped = [];

  const budget = sweepMaxReads();
  const total = keys.length;
  const window = Math.min(budget, total);

  // Deterministic rotation, derived from the clock rather than from persisted
  // state: a cursor blob would cost an extra read and write per sweep and add a
  // failure mode to the one operation that must never block dispatch.
  let start = 0;
  if (total > window && window > 0) {
    const slot = Math.floor(new Date(timestamp).getTime() / 1000 / SWEEP_ROTATION_PERIOD_SECONDS);
    start = ((slot * window) % total + total) % total;
  }

  for (let i = 0; i < window; i += 1) {
    const key = keys[(start + i) % total];
    const existing = readLeaseRecord(repository, key);
    if (!existing.found) {
      skipped.push({ key, reason: 'gone' });
      continue;
    }
    const lease = existing.lease;

    if (isPrunable(lease, timestamp)) {
      if (deleteLeaseRecord(repository, key, existing.sha)) {
        pruned.push({ key, state: lease.state });
      } else {
        skipped.push({ key, reason: 'contended' });
      }
      continue;
    }
    if (isTerminal(lease) || lease.state === STATE_RELEASED) {
      skipped.push({ key, reason: 'terminal' });
      continue;
    }
    // A `claimed` lease is measured against the claim window, not the session
    // TTL, so the claimer and the sweeper agree on when a claim is abandoned.
    const stale = lease.state === STATE_CLAIMED ? isClaimStale(lease, timestamp) : isStale(lease, timestamp);
    if (!stale) {
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

  return {
    outcome: 'swept',
    reclaimed,
    pruned,
    skipped,
    examined: window,
    total,
    budget,
    truncated: listing.truncated
  };
}

function listLeases(repository) {
  const listing = listLeaseRecords(repository);
  const leases = [];
  for (const key of listing.keys) {
    const existing = readLeaseRecord(repository, key);
    if (existing.found) leases.push(existing.lease);
  }
  return { outcome: 'listed', leases, truncated: listing.truncated };
}

module.exports = {
  ACTIVE_STATES,
  DEFAULT_CLAIM_TTL_SECONDS,
  DEFAULT_LEASE_BRANCH,
  DEFAULT_RETENTION_SECONDS,
  DEFAULT_SWEEP_MAX_READS,
  DEFAULT_TTL_SECONDS,
  GONE_PATTERNS,
  LEASE_DIRECTORY,
  LEASE_SCHEMA_VERSION,
  LeaseError,
  MAX_DIRECTORY_ENTRIES,
  REAL_FAILURE_PATTERNS,
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
  claimTtlSeconds,
  classifyGhFailure,
  completeLease,
  deleteLeaseRecord,
  ensureLeaseRef,
  heartbeatLease,
  invokeGhSafe,
  isClaimStale,
  isGoneResult,
  isPrunable,
  isStale,
  isTerminal,
  leaseBranch,
  listLeaseRecords,
  listLeases,
  markDispatched,
  nowIso,
  readLeaseRecord,
  releaseLease,
  retentionSeconds,
  sweepLeases,
  sweepMaxReads,
  ttlSeconds
};
