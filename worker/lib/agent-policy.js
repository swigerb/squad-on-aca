#!/usr/bin/env node
'use strict';

/**
 * agent-policy.js
 *
 * Issue #26 / PRD #6: tool and MCP approval parity.
 *
 * WHAT THIS SOLVES
 * ----------------
 * Every worker session used to run Copilot with `--yolo`, which the CLI defines
 * as `--allow-all-tools --allow-all-paths --allow-all-urls`, on top of a
 * Dockerfile that also set `COPILOT_ALLOW_ALL=true`. Remote execution therefore
 * applied *weaker* policy than a developer's own machine, which is the exact
 * privilege escalation PRD #6 forbids ("changing execution substrate must not
 * escalate privilege").
 *
 * WHY THIS IS ONE FILE IN NODE
 * ----------------------------
 * There are two execution planes (ACA Jobs and ACA Sandboxes) and three
 * dispatchers (local-cli/PowerShell, ralph/bash, watch/PowerShell). A policy
 * rule implemented once per language guarantees drift, and a drifted policy is
 * invisible until the day it matters. So the rule lives HERE and every caller
 * shells out to it -- the same argument (and the same precedent) as
 * worker/lib/dispatch-decision.js. `worker/entrypoint.sh` is the only code that
 * launches an agent on either plane, so a single resolver behind it is what
 * makes "local and remote apply the same policy semantics" a structural fact
 * rather than a claim.
 *
 * WHAT THE COPILOT CLI ACTUALLY GIVES US (verified against @github/copilot
 * 1.0.69-2, the version pinned in worker/Dockerfile, via `copilot help
 * permissions`)
 * ---------------------------------------------------------------------------
 *   * `--deny-tool <pattern>` with patterns `shell(cmd)`, `write`,
 *     `<mcp-server>(tool)` and `url(...)`. "Denial rules always take precedence
 *     over allow rules, even --allow-all-tools." That is the one primitive
 *     strong enough to build a tier on.
 *   * `--allow-all-tools` is documented as "required for non-interactive mode".
 *     A container has no TTY and no approver, so it stays -- and the deny list
 *     above is what makes it survivable.
 *   * Path permissions are CWD-scoped by default; `--allow-all-paths` (which
 *     `--yolo` implies) removes that scoping entirely. Dropping it is a real
 *     reduction: `~/.copilot`, `~/.config/gh/hosts.yml` and
 *     `/usr/local/lib/squad-on-aca/*` leave the file tools' reach.
 *   * `--no-ask-user` disables the tool that would otherwise block an
 *     unattended run forever.
 *
 * WHAT IT DOES NOT GIVE US -- AND THIS IS THE FINDING
 * --------------------------------------------------
 * There is NO path-scoped write permission. `write` is all-or-nothing, and no
 * `--deny-path` exists. The CLI therefore CANNOT express "this session may
 * write to the repository but not to `.squad/policies`". Governance protection
 * is consequently NOT a CLI concern at all: it is enforced in the worker, by
 * filesystem mode bits plus a pre/post integrity check that fails the session
 * (worker/lib/squad-policy.sh). Anything that claimed to enforce governance
 * paths through Copilot flags would be decoration.
 *
 * TIERS
 * -----
 *   attended    A named human started this specific run and is watching it
 *               (`squad-aca run`, `squad-aca smoke`, an operator's sandbox
 *               dispatch). They cannot approve a tool call -- a container has
 *               no interactive stdin on either plane -- but they can stop the
 *               run, and they own the result.
 *   autonomous  Nobody is watching: Ralph's 5-minute cron, `squad watch`,
 *               `squad loop`, or any API-driven dispatch. Destructive
 *               operations are made UNAVAILABLE rather than approval-gated,
 *               because an approval gate with no approver is a hang.
 *
 * The default for anything unrecognised is `autonomous`. A tier resolver that
 * guessed "attended" on unfamiliar input would fail open.
 *
 * DETERMINISM IS THE CONTRACT. resolvePolicy() is a pure function of its input
 * object. No clock, no randomness, no filesystem, no environment read outside
 * the object it is handed -- so the policy for a given session is comparable
 * byte for byte across planes, dispatchers, and languages.
 */

// Modes that a human can plausibly be attending. Everything else is a loop.
const ATTENDED_MODES = ['prompt', 'new-project', 'shell', 'smoke', 'telemetry-smoke'];

// Dispatch sources that mean "a person typed a command just now". `ralph`,
// `watch` and `api` are all robots.
//
// An ABSENT source is deliberately NOT attended. "The caller did not say who
// started this" is not evidence that a human did, and treating it as attended
// would make the strict tier something a dispatcher could opt out of by simply
// omitting a variable -- fail-open, the exact shape of the defect this change
// exists to remove. Every real entry point (`squad-aca run`, `squad-aca watch`,
// ralph-dispatch.sh, start-watch.ps1) already declares its source, so nothing on
// the supported paths lands here by accident.
const ATTENDED_SOURCES = ['local-cli'];

/**
 * Deny patterns applied to EVERY tier, attended included.
 *
 * These are not "destructive operations a human might approve" -- they are the
 * primitives that would let an agent dismantle the enforcement around it, or
 * walk off with the session's credentials. There is no run in which allowing
 * them is correct, so there is no tier in which they are allowed. Keeping them
 * common is also what makes the two tiers comparable: the difference between
 * attended and autonomous is a documented delta, not a different design.
 *
 *   sudo/su                 privilege escalation
 *   chmod/chown/chattr/     the four ways to undo the read-only mode bits that
 *   setfacl                 squad-policy.sh puts on the governance paths
 *   git config              `credential.helper` is arbitrary code execution
 *                           with the session's token attached
 *   gh auth                 token disclosure / re-auth as another identity
 *   gh secret / gh variable rewriting repository secrets and CI inputs
 */
const COMMON_DENY_TOOLS = [
  'shell(sudo)',
  'shell(su)',
  'shell(chmod)',
  'shell(chown)',
  'shell(chattr)',
  'shell(setfacl)',
  'shell(git config)',
  'shell(gh auth)',
  'shell(gh secret)',
  'shell(gh variable)',
];

/**
 * Additional deny patterns for the autonomous tier.
 *
 * PRD #6 says destructive operations still require the normal human approval
 * gate. There is no gate to reach when nobody is watching, so issue #26's
 * option 1 applies: the operation is UNAVAILABLE instead.
 *
 *   az / kubectl / terraform  infrastructure control planes. The worker holds a
 *   / docker                  user-assigned managed identity; `az` from an
 *                             unattended agent is that identity's full RBAC.
 *   gh api                    the universal authenticated primitive -- DELETE
 *                             /repos/{owner}/{repo} is one call away.
 *   gh repo delete /          irreversible and remote.
 *   gh release delete
 */
const AUTONOMOUS_DENY_TOOLS = [
  'shell(az)',
  'shell(kubectl)',
  'shell(terraform)',
  'shell(docker)',
  'shell(gh api)',
  'shell(gh repo delete)',
  'shell(gh release delete)',
];

/**
 * Flags that no caller-supplied `SQUAD_COPILOT_FLAGS` may contain.
 *
 * `SQUAD_COPILOT_FLAGS` is an operator convenience, not a policy input. Before
 * this change it was the escalation: anyone who could set one environment
 * variable on a dispatch got `--yolo`. It is still honoured for flags that do
 * not touch policy (model selection, logging, effort), and REJECTED -- session
 * aborts, no blanket allow -- for anything that widens the permission surface.
 * The way to widen policy is to change this file and have the change reviewed.
 */
const FORBIDDEN_EXTRA_FLAGS = [
  '--yolo',
  '--allow-all',
  '--allow-all-paths',
  '--add-dir',
];

/**
 * Repository paths that an agent session must never be able to change.
 *
 * PRD #6: "Governance paths such as .squad/policies, .squad/agents,
 * .squad/identity, approval/audit state, config, and routing must not be
 * writable by autonomous sandboxed agents."
 *
 * This list is deliberately the SAME for both tiers. Making it laxer for
 * attended runs would reintroduce exactly the asymmetry the PRD forbids, and
 * "the human was watching" is not a reviewable audit trail for a policy
 * rewrite -- a pull request is.
 *
 * One narrow exception is carved out of this set by MUTABLE_GOVERNANCE_PATTERNS
 * below; it is also the same for both tiers.
 */
const GOVERNANCE_PATHS = [
  '.squad/policies',
  '.squad/agents',
  '.squad/identity',
  '.squad/config.json',
  '.squad/routing.md',
  '.squad/casting-policy.json',
  '.squad/casting/policy.json',
  '.squad/memory/config.json',
  '.squad/memory/audit.jsonl',
  '.squad/fact-checker/policy.md',
  '.squad/fact-checker/audit-trail.md',
  '.squad/rai/policy.md',
  '.squad/rai/audit-trail.md',
];

/**
 * The ONE narrow exception to the write lock: an agent's own history file.
 *
 * WHY THIS IS EXCLUDED
 * --------------------
 * `.squad/agents/<name>/history.md` is an APPEND-ONLY WORK LOG, not policy. It
 * records what an agent did; it does not grant an agent anything. Locking it
 * therefore prevents no privilege escalation whatsoever -- it only destroys the
 * audit trail PRD #6 explicitly asks for ("Every lifecycle event is correlated
 * by one stable session/run ID", and auditability generally). A run that cannot
 * record what it did is less auditable, not more governed. Ralph and Watch are
 * autonomous by definition, so "the human can write it up afterwards" is not
 * available on the paths where the record matters most.
 *
 * WHY THE PATTERN IS THIS NARROW, AND NOT `.squad/agents/**`
 * ----------------------------------------------------------
 * `.squad/agents/<name>/charter.md` defines what an agent is PERMITTED TO DO.
 * That is squarely governance: an agent that can rewrite its own charter has
 * rewritten its own authorisation, which is the escalation this whole change
 * exists to prevent. So the exception is anchored at both ends -- exactly one
 * path segment for the agent name, and exactly the filename `history.md`. It
 * matches neither `.squad/agents/security/charter.md`, nor
 * `.squad/agents/history.md`, nor `.squad/agents/a/b/history.md`.
 *
 * EXCLUDED FROM THE LOCK IS NOT EXCLUDED FROM THE DETECTOR
 * -------------------------------------------------------
 * A path that both layers ignore is a foothold. These paths stay in the
 * manifest under a different rule: they must be APPEND-ONLY. The baseline
 * records the SHA-256 and the byte length at hardening time, and verification
 * re-hashes the first `length` bytes -- so an append passes and reports its
 * size, while a truncation or a rewrite of the existing record fails the
 * session exactly like any other governance violation. See
 * worker/lib/squad-policy.sh.
 *
 * Emitted as regular expressions, in a dialect that is simultaneously valid as
 * a JS RegExp, a POSIX ERE (bash `[[ =~ ]]`) and a .NET regex, because all
 * three consume it (this file, squad-policy.sh, scripts/validate.ps1). One
 * pattern, three readers, no restatement to drift.
 */
const MUTABLE_GOVERNANCE_PATTERNS = ['^\\.squad/agents/[^/]+/history\\.md$'];

/**
 * True when a repository-relative path is a governance path that a session is
 * permitted to APPEND to. Backslashes are normalised so a Windows-produced path
 * classifies the same way as a container-produced one.
 */
function isMutableGovernancePath(relativePath) {
  const p = String(relativePath === undefined || relativePath === null ? '' : relativePath)
    .replace(/\\/g, '/')
    .replace(/^\.\//, '');
  if (p === '') {
    return false;
  }
  return MUTABLE_GOVERNANCE_PATTERNS.some((pattern) => new RegExp(pattern).test(p));
}

const TIER_ATTENDED = 'attended';
const TIER_AUTONOMOUS = 'autonomous';

class AgentPolicyError extends Error {
  constructor(message) {
    super(message);
    this.name = 'AgentPolicyError';
  }
}

function normalize(value) {
  return String(value === undefined || value === null ? '' : value).trim().toLowerCase();
}

/**
 * Split a flag string the way `bash` word-splits an unquoted `$COPILOT_FLAGS`
 * expansion, which is how worker/entrypoint.sh has always passed it to
 * `copilot`. Quoting is NOT honoured here on purpose: pretending to support it
 * would be a lie about how the value is actually used downstream.
 */
function splitFlags(text) {
  return String(text || '')
    .split(/\s+/)
    .filter((token) => token.length > 0);
}

/**
 * Decide the tier. Fail-closed: only an explicitly attended mode dispatched
 * from an explicitly attended source is attended; everything else, including
 * every value this file has never heard of, is autonomous.
 */
function resolveTier(mode, dispatchSource) {
  // Deliberately NOT defaulted to the Dockerfile's `smoke`. An absent mode is an
  // unknown mode, and guessing an attended one for it is exactly the fail-open
  // shape this change exists to remove. worker/entrypoint.sh exports the mode it
  // actually resolved before calling here, so the real default path is unaffected.
  const m = normalize(mode);
  const s = normalize(dispatchSource);

  if (!ATTENDED_MODES.includes(m)) {
    return {
      tier: TIER_AUTONOMOUS,
      reason: m === '' ? 'no mode was declared' : `mode '${m}' runs unattended`,
    };
  }
  if (!ATTENDED_SOURCES.includes(s)) {
    return {
      tier: TIER_AUTONOMOUS,
      reason:
        s === ''
          ? 'no dispatch source was declared, so no human is known to be present'
          : `dispatch source '${s}' is automated`,
    };
  }
  return {
    tier: TIER_ATTENDED,
    reason: `mode '${m}' was started by '${s}'`,
  };
}

/**
 * Validate operator-supplied extra flags. Returns the accepted tokens; throws
 * AgentPolicyError on anything that would widen the permission surface.
 */
function validateExtraFlags(tokens) {
  const rejected = [];
  for (const token of tokens) {
    // `--add-dir /x` and `--add-dir=/x` are the same escalation.
    const bare = token.split('=')[0];
    if (FORBIDDEN_EXTRA_FLAGS.includes(bare)) {
      rejected.push(bare);
    }
  }
  if (rejected.length > 0) {
    throw new AgentPolicyError(
      `SQUAD_COPILOT_FLAGS contains permission-widening flag(s): ${rejected.join(', ')}. ` +
        'Session policy is resolved by worker/lib/agent-policy.js and cannot be widened by ' +
        'environment. Remove the flag(s), or change the policy in code and have it reviewed.'
    );
  }
  return tokens.slice();
}

/**
 * The whole policy for one session.
 *
 * @param {object} input
 * @param {string} input.mode              SQUAD_MODE
 * @param {string} input.dispatchSource    SQUAD_DISPATCH_SOURCE
 * @param {string} input.enableGithubRemote ENABLE_GITHUB_REMOTE ("true"/"false")
 * @param {string} input.extraFlags        SQUAD_COPILOT_FLAGS
 * @param {string} input.executionPlane    SQUAD_EXECUTION_MODE ("sandbox" or "")
 */
function resolvePolicy(input) {
  const opts = input || {};
  const { tier, reason } = resolveTier(opts.mode, opts.dispatchSource);

  const denyTools = COMMON_DENY_TOOLS.slice();
  if (tier === TIER_AUTONOMOUS) {
    for (const pattern of AUTONOMOUS_DENY_TOOLS) {
      denyTools.push(pattern);
    }
  }

  const remote = normalize(opts.enableGithubRemote) !== 'false';

  // `--allow-all-tools` NOT `--yolo`: the CLI documents the former as required
  // for non-interactive mode, while the latter additionally drops path and URL
  // scoping. Path scoping is the half that matters here, so it stays on.
  const flags = ['--allow-all-tools', '--agent', 'squad'];
  flags.push(remote ? '--remote' : '--no-remote');
  flags.push('--no-auto-update');
  if (tier === TIER_AUTONOMOUS) {
    // An `ask_user` call with no user is an unbounded hang on a cron job.
    flags.push('--no-ask-user');
  }
  for (const pattern of denyTools) {
    flags.push('--deny-tool', pattern);
  }

  const extras = validateExtraFlags(splitFlags(opts.extraFlags));
  for (const token of extras) {
    flags.push(token);
  }

  // `squad watch` / `squad loop` take the whole flag set as ONE string and split
  // it on /\s+/ before spawning Copilot (verified in @bradygaster/squad-cli:
  // dist/index.js, dist/loop.js, dist/agent-spawn.js and five other call sites
  // all do `options.copilotFlags.trim().split(/\s+/)`). A deny pattern that
  // contains a space -- `shell(git config)` -- is therefore torn into two
  // arguments and silently stops being a deny rule on that path.
  //
  // Rather than pretend, the resolver emits TWO surfaces: the authoritative
  // argv (used wherever the worker invokes `copilot` directly) and the subset
  // that can survive `--copilot-flags`, together with the exact list of
  // patterns that cannot. worker/entrypoint.sh prints that list, so the gap is
  // visible in the session log instead of being a quiet downgrade. See
  // docs/architecture.md: closing it belongs to the Squad runtime, not here.
  const squadFlags = [];
  const undeliverable = [];
  for (let i = 0; i < flags.length; i += 1) {
    if (flags[i] === '--deny-tool' && /\s/.test(flags[i + 1] || '')) {
      undeliverable.push(flags[i + 1]);
      i += 1;
      continue;
    }
    squadFlags.push(flags[i]);
  }

  return {
    tier,
    reason,
    mode: normalize(opts.mode) || 'smoke',
    dispatchSource: normalize(opts.dispatchSource),
    executionPlane: normalize(opts.executionPlane) || 'aca-job',
    denyTools,
    governancePaths: GOVERNANCE_PATHS.slice(),
    mutableGovernancePatterns: MUTABLE_GOVERNANCE_PATTERNS.slice(),
    flags,
    // A single shell-ready string. Only safe where the caller can hand it to a
    // process as an argv array; see squadFlagString for the other path.
    flagString: flags.join(' '),
    squadFlags,
    squadFlagString: squadFlags.join(' '),
    undeliverableViaSquad: undeliverable,
  };
}

/**
 * Read the same policy out of a process environment map. Kept separate from
 * resolvePolicy so the pure function stays pure and testable.
 */
function resolvePolicyFromEnv(env) {
  const e = env || {};
  return resolvePolicy({
    mode: e.SQUAD_MODE,
    dispatchSource: e.SQUAD_DISPATCH_SOURCE,
    enableGithubRemote: e.ENABLE_GITHUB_REMOTE,
    extraFlags: e.SQUAD_COPILOT_FLAGS,
    executionPlane: e.SQUAD_EXECUTION_MODE,
  });
}

module.exports = {
  ATTENDED_MODES,
  ATTENDED_SOURCES,
  COMMON_DENY_TOOLS,
  AUTONOMOUS_DENY_TOOLS,
  FORBIDDEN_EXTRA_FLAGS,
  GOVERNANCE_PATHS,
  MUTABLE_GOVERNANCE_PATTERNS,
  TIER_ATTENDED,
  TIER_AUTONOMOUS,
  AgentPolicyError,
  resolveTier,
  isMutableGovernancePath,
  resolvePolicy,
  resolvePolicyFromEnv,
};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
// Exit codes:
//   0   policy resolved; requested field written to stdout
//   78  EX_CONFIG -- the policy could not be applied (rejected flags, bad usage)
//
// There is no exit path that prints a permissive fallback. A caller that cannot
// get a policy out of this file must abort, and worker/lib/squad-policy.sh does.
function main(argv) {
  const what = argv[0] || 'json';
  let policy;
  try {
    policy = resolvePolicyFromEnv(process.env);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    return 78;
  }

  switch (what) {
    case 'json':
      process.stdout.write(`${JSON.stringify(policy, null, 2)}\n`);
      return 0;
    case 'flags':
      process.stdout.write(`${policy.flagString}\n`);
      return 0;
    // One token per line, so bash can build a real argv array with
    // `mapfile -t` and multi-word deny patterns survive as single arguments.
    case 'argv':
      process.stdout.write(policy.flags.length ? `${policy.flags.join('\n')}\n` : '');
      return 0;
    case 'squad-flags':
      process.stdout.write(`${policy.squadFlagString}\n`);
      return 0;
    case 'undeliverable':
      process.stdout.write(
        policy.undeliverableViaSquad.length
          ? `${policy.undeliverableViaSquad.join('\n')}\n`
          : ''
      );
      return 0;
    case 'tier':
      process.stdout.write(`${policy.tier}\n`);
      return 0;
    case 'reason':
      process.stdout.write(`${policy.reason}\n`);
      return 0;
    case 'governance-paths':
      process.stdout.write(`${policy.governancePaths.join('\n')}\n`);
      return 0;
    // One regular expression per line, matched against a repository-relative
    // path. A governance path that matches is excluded from the write lock and
    // held to the append-only rule instead -- it is NOT excluded from the
    // integrity check. worker/lib/squad-policy.sh is the only consumer that
    // acts on this; scripts/validate.ps1 reads it to assert the boundary.
    case 'mutable-governance-patterns':
      process.stdout.write(`${policy.mutableGovernancePatterns.join('\n')}\n`);
      return 0;
    // `classify-governance-path <relative-path>` -> `append-only` | `locked`.
    // Exists so a test (and an operator diagnosing a run) can ask the SAME
    // resolver the shell asks, rather than restating the pattern.
    case 'classify-governance-path': {
      const target = argv[1];
      if (target === undefined || String(target).trim() === '') {
        process.stderr.write('Usage: agent-policy.js classify-governance-path <repo-relative-path>\n');
        return 78;
      }
      process.stdout.write(`${isMutableGovernancePath(target) ? 'append-only' : 'locked'}\n`);
      return 0;
    }
    default:
      process.stderr.write(
        'Usage: agent-policy.js [json|flags|argv|squad-flags|undeliverable|tier|reason|' +
          'governance-paths|mutable-governance-patterns|classify-governance-path <path>]\n'
      );
      return 78;
  }
}

if (require.main === module) {
  process.exit(main(process.argv.slice(2)));
}
