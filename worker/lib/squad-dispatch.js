#!/usr/bin/env node
'use strict';

/**
 * squad-dispatch.js
 *
 * The single entry point every dispatcher calls. Ralph (bash), Watch (bash +
 * PowerShell) and the local CLI (PowerShell) all invoke THIS file, so there is
 * exactly one implementation of the routing decision (dispatch-decision.js) and
 * exactly one implementation of the lease protocol (dispatch-lease.js).
 *
 * Every subcommand writes a single-line JSON object to stdout. Human-readable
 * text goes to stderr, so a caller can always parse stdout.
 *
 * Subcommands
 *   decide      Resolve the routing decision. Deterministic; no side effects.
 *   claim       Write the lease BEFORE compute is requested. Reads the decision
 *               from stdin (the output of `decide`), so a claim can never be
 *               made against a route that was computed some other way.
 *   dispatched  Record that compute has now been requested.
 *   heartbeat   Keep an execution's lease alive.
 *   complete    Move a lease to a terminal state (succeeded/failed/cancelled).
 *   release     Hand work back after a failed compute request, so it retries.
 *   sweep       Reclaim stale leases. Idempotent.
 *   list        List lease records.
 *
 * Exit codes
 *   0   the operation succeeded (including every idempotent no-op: already
 *       claimed, already terminal, externally deleted)
 *   1   a real failure -- auth, permissions, throttling, network, missing `gh`,
 *       malformed state. Never reported as success.
 *   64  usage error
 *   65  the routing decision REFUSES to dispatch (fail-closed manifest)
 *   70  the administrator catalog is missing/unreadable/invalid
 */

const fs = require('fs');

const {
  ACTION_REFUSE,
  SandboxCatalogError,
  loadCatalog,
  resolveDispatchDecision
} = require('./dispatch-decision.js');

const lease = require('./dispatch-lease.js');

const EX_USAGE = 64;
const EX_REFUSED = 65;
const EX_CONFIG = 70;

function parseArgs(argv) {
  const parsed = { _: [], flags: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith('--')) {
      const name = arg.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        parsed.flags[name] = true;
      } else {
        parsed.flags[name] = next;
        i += 1;
      }
    } else {
      parsed._.push(arg);
    }
  }
  return parsed;
}

function emit(payload, pretty) {
  process.stdout.write(`${JSON.stringify(payload, null, pretty ? 2 : 0)}\n`);
}

function fail(message, code) {
  process.stderr.write(`squad-dispatch: ${message}\n`);
  process.exit(code === undefined ? 1 : code);
}

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch (err) {
    return '';
  }
}

function requireDecisionFromStdin() {
  const text = readStdin();
  if (!text.trim()) {
    fail("this subcommand reads a dispatch decision from stdin; pipe the output of 'decide' into it.", EX_USAGE);
  }
  let decision;
  try {
    decision = JSON.parse(text);
  } catch (err) {
    fail('the dispatch decision on stdin is not valid JSON.', EX_USAGE);
  }
  if (!decision || !decision.leaseKey || !decision.routing) {
    fail('the dispatch decision on stdin is missing leaseKey/routing.', EX_USAGE);
  }
  return decision;
}

function requireRepository(flags, decision) {
  const repository = flags.repository || (decision && decision.repository) || '';
  if (!/^[^/\s]+\/[^/\s]+$/.test(repository)) {
    fail('a repository in owner/name form is required (--repository).', EX_USAGE);
  }
  return repository;
}

function requireKey(flags) {
  const key = flags['lease-key'];
  if (!key || key === true) fail('--lease-key is required.', EX_USAGE);
  return String(key);
}

function commandDecide(flags, pretty) {
  let catalog = null;
  try {
    catalog = loadCatalog(flags.catalog === true ? null : flags.catalog || null);
  } catch (err) {
    if (!(err instanceof SandboxCatalogError)) throw err;
    // Emit a fail-closed decision anyway so a caller that ignores exit codes
    // still fails closed, then exit non-zero.
    const decision = resolveDispatchDecision({
      sessionId: flags['session-id'] || '',
      dispatchSource: flags['dispatch-source'],
      repository: flags.repository || '',
      issueNumber: flags.issue,
      repoDir: null,
      manifestPath: null,
      catalog: null
    });
    emit(decision, pretty);
    process.stderr.write(`squad-dispatch: cannot resolve a dispatch route: ${err.message}\n`);
    process.exit(EX_CONFIG);
  }

  if (!flags['session-id'] || flags['session-id'] === true) {
    fail('--session-id is required.', EX_USAGE);
  }

  const decision = resolveDispatchDecision({
    sessionId: flags['session-id'],
    dispatchSource: flags['dispatch-source'] === true ? null : flags['dispatch-source'],
    repository: flags.repository === true ? '' : flags.repository || '',
    issueNumber: flags.issue === true ? null : flags.issue,
    repoDir: flags['repo-dir'] === true ? null : flags['repo-dir'] || null,
    manifestPath: flags['manifest-path'] === true ? null : flags['manifest-path'] || null,
    catalog
  });

  emit(decision, pretty);
  if (decision.routing.action === ACTION_REFUSE) process.exit(EX_REFUSED);
}

function run() {
  const argv = process.argv.slice(2);
  const { _, flags } = parseArgs(argv);
  const command = _[0] || '';
  const pretty = flags.pretty === true;

  if (!command) {
    fail('usage: squad-dispatch.js <decide|claim|dispatched|heartbeat|complete|release|sweep|list> [options]', EX_USAGE);
  }

  if (command === 'decide') {
    commandDecide(flags, pretty);
    return;
  }

  try {
    switch (command) {
      case 'claim': {
        const decision = requireDecisionFromStdin();
        if (decision.routing.action === ACTION_REFUSE) {
          // Never claim work the route refuses to run. A lease for work that
          // will not be dispatched is exactly the orphan the sweeper exists to
          // clean up; not creating it is better than reclaiming it later.
          emit({ outcome: 'refused', routing: decision.routing, lease: null }, pretty);
          process.exit(EX_REFUSED);
        }
        const repository = requireRepository(flags, decision);
        const result = lease.claimLease(repository, decision);
        emit({ outcome: result.outcome, lease: result.lease }, pretty);
        return;
      }
      case 'dispatched': {
        const repository = requireRepository(flags, null);
        const result = lease.markDispatched(
          repository,
          requireKey(flags),
          flags['execution-ref'] === true ? null : flags['execution-ref'] || null
        );
        emit({ outcome: result.outcome, lease: result.lease }, pretty);
        return;
      }
      case 'heartbeat': {
        const repository = requireRepository(flags, null);
        const result = lease.heartbeatLease(repository, requireKey(flags));
        emit({ outcome: result.outcome, lease: result.lease }, pretty);
        return;
      }
      case 'complete': {
        const repository = requireRepository(flags, null);
        const state = flags.state === true || !flags.state ? 'succeeded' : String(flags.state);
        const result = lease.completeLease(
          repository,
          requireKey(flags),
          state,
          flags.reason === true ? null : flags.reason || null
        );
        emit({ outcome: result.outcome, lease: result.lease }, pretty);
        return;
      }
      case 'release': {
        const repository = requireRepository(flags, null);
        const result = lease.releaseLease(
          repository,
          requireKey(flags),
          flags.reason === true ? null : flags.reason || null
        );
        emit({ outcome: result.outcome, lease: result.lease }, pretty);
        return;
      }
      case 'sweep': {
        const repository = requireRepository(flags, null);
        const result = lease.sweepLeases(repository);
        emit(result, pretty);
        return;
      }
      case 'list': {
        const repository = requireRepository(flags, null);
        const result = lease.listLeases(repository);
        emit(result, pretty);
        return;
      }
      default:
        fail(`unknown subcommand '${command}'.`, EX_USAGE);
    }
  } catch (err) {
    // Auth, permissions, throttling, network faults, a missing `gh`, and
    // malformed state all land here. None of them are reported as success.
    fail(err && err.message ? err.message : String(err), 1);
  }
}

if (require.main === module) {
  run();
}

module.exports = { parseArgs };
