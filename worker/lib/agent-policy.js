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
 * Issue #84 PI-1: every dispatch source and mode this file must have a
 * resolved policy for. This is the registry the exhaustiveness test checks a
 * live dispatcher scan against -- see worker/tests/test_agent_policy.sh,
 * "matrix exhaustiveness". A source or mode that reaches `case
 * "${SQUAD_MODE:-smoke}" in ...` (worker/entrypoint.sh) or is assigned to
 * SQUAD_DISPATCH_SOURCE by a production dispatcher WITHOUT an entry here is a
 * gap: it would fall through this file's fail-closed defaults with nobody
 * having decided whether that is correct, rather than having a reviewed,
 * tested policy.
 *
 * KNOWN_SOURCES matches worker/lib/dispatch-decision.js's DISPATCH_SOURCES
 * exactly -- one registry, not two independent lists that can drift apart.
 * `api`, used in this file's own tests as the unrecognised-source case, is
 * deliberately NOT a member: it exists to prove the fail-closed default still
 * works for a source nobody registered.
 */
const KNOWN_SOURCES = ['local-cli', 'ralph', 'watch', 'actions'];

/**
 * Every mode worker/entrypoint.sh's `case "${SQUAD_MODE:-smoke}" in` branches
 * on before its catch-all `exit 64`. `triage` is `watch`'s documented alias
 * (same case arm, `watch|triage)`).
 */
const KNOWN_MODES = [
  'smoke',
  'telemetry-smoke',
  'prompt',
  'new-project',
  'loop',
  'ralph',
  'watch',
  'triage',
  'shell',
];

/**
 * Issue #84 PI-2: an ORTHOGONAL axis to the tier.
 *
 * The tier (attended/autonomous) answers "is a human watching this specific
 * run". Trust answers a different question: "is the input that became this
 * session's prompt/task attacker-controlled". An issue or comment body is the
 * least trusted input this system takes -- anyone who can open an issue can
 * write it, whether or not they can dispatch a run -- and that is true
 * regardless of whether a human happens to be watching the resulting session.
 *
 * Today the two axes happen to agree (only `local-cli` is attended, and only
 * `local-cli` is trusted), because every non-local dispatcher's prompt
 * ultimately traces back to a repository file, an issue, or a comment. They
 * are kept as SEPARATE decisions anyway: collapsing them into one would make
 * a future attended-but-remote source (for example an authenticated API
 * caller acting on a human-typed prompt) inherit the trusted deny-list
 * relaxation by accident, rather than by a reviewed change to TRUSTED_SOURCES.
 *
 * `ralph`, `watch`, `actions`, an unrecognised source, and an absent source
 * are ALL untrusted, fail-closed -- the same "guessing attended is fail-open"
 * argument from resolveTier applies here without change.
 */
const TRUSTED_SOURCES = ['local-cli'];

const TRUST_TRUSTED = 'trusted';
const TRUST_UNTRUSTED = 'untrusted';

/**
 * Issue #84 PI-2: additional deny patterns for an UNTRUSTED session, on top of
 * COMMON_DENY_TOOLS (and AUTONOMOUS_DENY_TOOLS where the tier also applies).
 *
 * These are not a blanket deny of git/gh -- an issue-triggered session still
 * needs `git commit`, `git diff`, `gh issue view`, `gh pr view`, and so on to
 * do useful work, and `--no-remote` is not used here either (that flag
 * disables the CLI's own network tools wholesale, which is a different,
 * coarser control this change does not touch). What is removed is the narrow
 * set of primitives that let the AGENT itself publish or fetch external
 * content on an untrusted run:
 *
 *   shell(git push)  publishing is still what happens at the end of a
 *                     session (worker/entrypoint.sh's commit_and_push_if_
 *                     needed), but that runs as the ENTRYPOINT's own git
 *                     invocation, never as a tool call the agent makes. An
 *                     untrusted-input session's agent process has no business
 *                     invoking `git push` itself.
 *   shell(gh pr)      same argument for opening a pull request: entrypoint.sh
 *                     is the only thing that should ever call `gh pr create`
 *                     for this session.
 *   shell(curl)       the two general-purpose fetchers. A prompt-injected
 *   shell(wget)       instruction ("curl this URL and run what it returns",
 *                     "wget the following and post the diff to...") is exactly
 *                     the exfiltration/second-stage-fetch shape this closes.
 *                     Copilot's own web/URL tools are unaffected -- those are
 *                     already governed by their own allow/deny surface.
 *
 * `shell(git push)` and `shell(gh pr)` are MULTI-WORD patterns, exactly like
 * `shell(git config)` above. They therefore go through the same
 * undeliverable-via-`squad --copilot-flags` path documented on `resolvePolicy`
 * below: whole and enforced on the authoritative argv (direct `copilot`
 * invocation) and the hub's JSON channel, dropped (and named in
 * `undeliverableViaSquad`) on the `squad watch`/`squad loop` space-split path.
 */
const UNTRUSTED_INPUT_DENY_TOOLS = [
  'shell(git push)',
  'shell(gh pr)',
  'shell(curl)',
  'shell(wget)',
];

/**
 * Issue #84 PI-3: the two modes whose ENTRYPOINT dispatches an untrusted
 * prompt straight to the agent and then, itself, publishes the result
 * (`commit_and_push_if_needed`). Long-lived modes (`ralph`, `watch`, `triage`,
 * `loop`) are deliberately excluded: withholding a credential for the length
 * of a multi-hour polling loop is a different (and much more disruptive)
 * design than withholding it for one bounded `copilot -p` call, and the design
 * review that authorised this change scoped PI-3 to the bounded case only.
 * `smoke` and `shell` are also excluded: `smoke` never runs an
 * attacker-supplied prompt, and `shell` runs an operator-supplied command
 * (`REMOTE_SQUAD_COMMAND`), not an issue body.
 */
const CREDENTIAL_WITHHOLD_MODES = ['prompt', 'new-project'];

/**
 * Decide the trust axis. Fail-closed exactly like resolveTier: only an
 * explicitly trusted source is trusted, and an absent or unrecognised source
 * is untrusted rather than defaulting to trusted.
 */
function resolveTrust(dispatchSource) {
  const s = normalize(dispatchSource);
  if (TRUSTED_SOURCES.includes(s)) {
    return {
      trust: TRUST_TRUSTED,
      reason: `dispatch source '${s}' is a trusted local operator`,
    };
  }
  return {
    trust: TRUST_UNTRUSTED,
    reason:
      s === ''
        ? 'no dispatch source was declared, so the input provenance is not known'
        : `dispatch source '${s}' is not a trusted local operator`,
  };
}

/**
 * Issue #84 PI-3: what credential material this session is wired to have.
 *
 * This describes the WIRING decision, not a live runtime fact -- it says what
 * worker/entrypoint.sh does with the credential it was handed for this
 * mode/source combination, not whether a credential was supplied at all (a
 * public-repo, no-push session legitimately has none either way).
 *
 *   ghTokenEnv        GH_TOKEN/GITHUB_TOKEN are exported in the shell the
 *                     agent inherits.
 *   gitTokenFile      the 0600 token file (squad-credentials.sh) exists on
 *                     disk.
 *   credentialHelper  git has a credential helper configured for the host, so
 *                     a `git push`/`git fetch` the agent runs itself would be
 *                     able to authenticate.
 *   azureIdentity     the Container Apps managed identity
 *                     (IDENTITY_ENDPOINT/IDENTITY_HEADER) is present. True only
 *                     for `ralph`, matching squad_drop_azure_identity in
 *                     worker/entrypoint.sh, which removes it for every other
 *                     mode before any child process starts.
 *   copilotTokenShared     COPILOT_GITHUB_TOKEN carries the SAME push-capable
 *                          value as the git token, rather than a separately
 *                          scoped Copilot credential. Computed from the live
 *                          environment by `resolvePolicyFromEnv`; a caller
 *                          (including the static matrix) that omits it gets
 *                          the honest worst-case default (`true`) rather than
 *                          an optimistic guess.
 *   copilotTokenSharedAllowed  the escape hatch (SQUAD_ALLOW_SHARED_COPILOT_TOKEN
 *                          =true) was used to explicitly accept running with a
 *                          shared Copilot token still exported. Never true
 *                          unless the session is both withheld and shared --
 *                          it is not a general "escape hatch was set" flag.
 *   copilotTokenEnv        COPILOT_GITHUB_TOKEN is present in the agent's own
 *                          environment for this call.
 *
 * For an UNTRUSTED session in a CREDENTIAL_WITHHOLD_MODES mode, ghTokenEnv/
 * gitTokenFile/credentialHelper are all false FOR THE DURATION OF THE AGENT
 * CALL ONLY: entrypoint.sh restores them before commit_and_push_if_needed
 * runs, which is why a session still ends with a branch and a pull request.
 * See squad_credential_withhold / squad_credential_restore in
 * worker/lib/squad-credentials.sh. copilotTokenEnv follows the SAME rule
 * whenever the Copilot token is the shared/derived value (Security's blocker:
 * a push-capable COPILOT_GITHUB_TOKEN must not remain visible just because
 * withholding only touched GH_TOKEN/GITHUB_TOKEN) -- `withheld: true` is never
 * reported while a shared Copilot token is still exported to the agent; see
 * `copilotTokenSharedAllowed` for the one explicit, logged exception.
 *
 * This is withholding, not separation: the agent runs under the same uid that
 * later performs the push, so a sufficiently determined agent process could
 * still go looking for the token elsewhere (a shell history, a core dump, a
 * parallel read of the file during the single write() that recreates it). The
 * design review this change implements evaluated full separation (a different
 * process identity or execution boundary publishing on the agent's behalf) and
 * declined it as disproportionate to this iteration; the credential is simply
 * not IN THE ENVIRONMENT the agent inherits, or ON DISK, or WIRED INTO GIT for
 * the window in which the agent runs, which closes the accidental-disclosure
 * and casual-exfiltration cases without pretending to be a hard boundary.
 */
function resolveCredentialProfile(input) {
  const opts = input || {};
  const mode = normalize(opts.mode);
  const { trust } = resolveTrust(opts.dispatchSource);
  const withheld = trust === TRUST_UNTRUSTED && CREDENTIAL_WITHHOLD_MODES.includes(mode);

  // Issue #84 follow-up (Security blocker): whether COPILOT_GITHUB_TOKEN
  // carries the SAME push-capable value as the git token, rather than a
  // separately scoped Copilot credential. `worker/entrypoint.sh` defaults
  // COPILOT_GITHUB_TOKEN from GH_TOKEN when no distinct value is supplied
  // (recorded there as SQUAD_COPILOT_TOKEN_PROVENANCE), so the DEFAULT
  // deployment shape is shared. This function stays a pure function of its
  // input object (see the file-level "DETERMINISM IS THE CONTRACT" note): it
  // never reads the environment itself. `resolvePolicyFromEnv` is what
  // computes this from the live GH_TOKEN/COPILOT_GITHUB_TOKEN values; callers
  // that omit it (the static matrix included) get the honest worst-case
  // default rather than a silently optimistic one.
  const copilotTokenShared = opts.copilotTokenShared === undefined ? true : !!opts.copilotTokenShared;

  // Whether the escape hatch (SQUAD_ALLOW_SHARED_COPILOT_TOKEN=true) was used
  // to explicitly accept running an untrusted-input session with a shared
  // Copilot token still exported. Never defaults to true -- an unset/absent
  // value is "not allowed", matching the fail-closed shape everywhere else in
  // this file.
  const copilotTokenSharedAllowed = withheld && copilotTokenShared && !!opts.copilotTokenSharedAllowed;

  // Whether COPILOT_GITHUB_TOKEN is present in the agent's own environment
  // during the agent call. Withholding now covers the Copilot plane too when
  // it carries the shared/derived value (see squad_credential_withhold in
  // worker/lib/squad-credentials.sh), so it is NOT exported while withheld --
  // unless the escape hatch explicitly kept it, which is reported here rather
  // than silently folded into "withheld".  A token that is a genuinely
  // DIFFERENT, separately scoped credential is never touched by withholding
  // and stays present regardless of `withheld`.
  const copilotTokenEnv = !(withheld && copilotTokenShared && !copilotTokenSharedAllowed);

  let reason;
  if (withheld && copilotTokenShared && copilotTokenSharedAllowed) {
    reason =
      `mode '${mode}' runs an untrusted-input prompt to completion before publishing; the git push ` +
      'credential is withheld, but SQUAD_ALLOW_SHARED_COPILOT_TOKEN=true keeps the shared/derived ' +
      'COPILOT_GITHUB_TOKEN exported to the agent -- a documented, explicitly-accepted WEAKENED ' +
      'credential boundary, not full withholding';
  } else if (withheld) {
    reason =
      `mode '${mode}' runs an untrusted-input prompt to completion before publishing; the push ` +
      'credential (including a shared/derived COPILOT_GITHUB_TOKEN, when present) is withheld from ' +
      'the agent and restored before the push';
  } else if (mode === 'ralph') {
    reason = `mode '${mode}' is the only mode that calls Azure and keeps its identity`;
  } else {
    reason = 'credential wiring is unchanged for this mode/source';
  }

  return {
    ghTokenEnv: !withheld,
    gitTokenFile: !withheld,
    credentialHelper: !withheld,
    copilotTokenEnv,
    copilotTokenShared,
    copilotTokenSharedAllowed,
    azureIdentity: mode === 'ralph',
    withheld,
    reason,
  };
}

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
 * @param {boolean} [input.copilotTokenShared]        whether COPILOT_GITHUB_TOKEN
 *   equals the git token. Omit to get the honest worst-case default (`true`);
 *   see resolveCredentialProfile.
 * @param {boolean} [input.copilotTokenSharedAllowed] whether
 *   SQUAD_ALLOW_SHARED_COPILOT_TOKEN=true was set to explicitly accept a
 *   shared Copilot token remaining exported.
 */
function resolvePolicy(input) {
  const opts = input || {};
  const { tier, reason } = resolveTier(opts.mode, opts.dispatchSource);
  const { trust, reason: trustReason } = resolveTrust(opts.dispatchSource);
  const credentialProfile = resolveCredentialProfile({
    mode: opts.mode,
    dispatchSource: opts.dispatchSource,
    copilotTokenShared: opts.copilotTokenShared,
    copilotTokenSharedAllowed: opts.copilotTokenSharedAllowed,
  });

  const denyTools = COMMON_DENY_TOOLS.slice();
  if (tier === TIER_AUTONOMOUS) {
    for (const pattern of AUTONOMOUS_DENY_TOOLS) {
      denyTools.push(pattern);
    }
  }
  // Issue #84 PI-2: applied by TRUST, independent of tier. An attended,
  // trusted (local-cli) run never gets these; every untrusted run does, tier
  // notwithstanding -- an untrusted-input run that happens to be attended is
  // still an untrusted-input run.
  if (trust === TRUST_UNTRUSTED) {
    for (const pattern of UNTRUSTED_INPUT_DENY_TOOLS) {
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
    trust,
    trustReason,
    credentialProfile,
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
    // The SAME policy, for a session supervised by Squad Hub.
    //
    // `--allow-all-tools` exists because a container has no TTY and no
    // approver, so a prompt would hang forever. Squad Hub removes that
    // premise: it puts a human in front of the prompt, from anywhere.
    //
    // Dropping the flag is therefore a TIGHTENING, not a relaxation. Measured
    // against Copilot CLI 1.0.78 over ACP:
    //
    //   * a tool on the deny list raises NO permission request at all -- it is
    //     refused outright ("denied by policy"), so a human is never even
    //     offered the chance to approve something this policy forbids. The
    //     deny list stays a hard floor that the hub cannot lift;
    //   * a tool that is merely ungated DOES raise a request, carrying the
    //     literal command. Those are the decisions a person now makes, and
    //     which previously happened with nobody watching.
    //
    // Everything else is carried over untouched, deny patterns included, so
    // the reviewed policy is still resolved in exactly one place.
    hubArgv: flags.filter((f) => f !== '--allow-all-tools'),
  };
}

/**
 * Read the same policy out of a process environment map. Kept separate from
 * resolvePolicy so the pure function stays pure and testable.
 *
 * Issue #84 follow-up: this is the ONE place that turns the live
 * GH_TOKEN/COPILOT_GITHUB_TOKEN values into the `copilotTokenShared` fact
 * resolveCredentialProfile needs -- resolvePolicy itself never reads the
 * environment (see "DETERMINISM IS THE CONTRACT" above). A provenance of
 * `derived` (worker/entrypoint.sh defaulted COPILOT_GITHUB_TOKEN from
 * GH_TOKEN) is shared by construction even if the two values were since
 * mutated independently; otherwise shared-ness is a plain value comparison.
 * Neither token being present is NOT "not shared" -- it falls through to
 * resolveCredentialProfile's own honest-worst-case default.
 */
function resolvePolicyFromEnv(env) {
  const e = env || {};
  const gitToken = e.GH_TOKEN || e.GITHUB_TOKEN;
  const copilotToken = e.COPILOT_GITHUB_TOKEN;
  let copilotTokenShared;
  if (e.SQUAD_COPILOT_TOKEN_PROVENANCE === 'derived') {
    copilotTokenShared = true;
  } else if (copilotToken !== undefined && gitToken !== undefined) {
    copilotTokenShared = copilotToken === gitToken;
  }
  return resolvePolicy({
    mode: e.SQUAD_MODE,
    dispatchSource: e.SQUAD_DISPATCH_SOURCE,
    enableGithubRemote: e.ENABLE_GITHUB_REMOTE,
    extraFlags: e.SQUAD_COPILOT_FLAGS,
    executionPlane: e.SQUAD_EXECUTION_MODE,
    copilotTokenShared,
    copilotTokenSharedAllowed: normalize(e.SQUAD_ALLOW_SHARED_COPILOT_TOKEN) === 'true',
  });
}

/**
 * Issue #84 PI-1: "Enumerate, from the code, the tool policy actually applied
 * to each dispatch source and each mode." This builds that table by actually
 * RESOLVING every cell through resolvePolicy, rather than describing it in
 * prose that can drift from what the code does. One row per
 * KNOWN_SOURCES x KNOWN_MODES combination.
 *
 * enableGithubRemote/extraFlags/executionPlane are held at neutral defaults
 * ('true' / '' / 'aca-job') for every cell: this table is about what varies by
 * MODE and SOURCE, and holding the other inputs constant is what makes every
 * row comparable to every other row. copilotTokenShared is likewise held at
 * its honest worst-case default (`true`, the documented default deployment
 * shape) rather than an optimistic guess, so the matrix never UNDERSTATES the
 * credential exposure of a withheld cell.
 */
function buildPolicyMatrix() {
  const rows = [];
  for (const dispatchSource of KNOWN_SOURCES) {
    for (const mode of KNOWN_MODES) {
      const policy = resolvePolicy({
        mode,
        dispatchSource,
        enableGithubRemote: 'true',
        extraFlags: '',
        executionPlane: 'aca-job',
        copilotTokenShared: true,
        copilotTokenSharedAllowed: false,
      });
      rows.push({
        dispatchSource,
        mode,
        tier: policy.tier,
        trust: policy.trust,
        flags: policy.flags,
        denyTools: policy.denyTools,
        credentialsPresent: policy.credentialProfile,
      });
    }
  }
  return rows;
}

const POLICY_MATRIX = buildPolicyMatrix();

module.exports = {
  ATTENDED_MODES,
  ATTENDED_SOURCES,
  KNOWN_SOURCES,
  KNOWN_MODES,
  TRUSTED_SOURCES,
  TRUST_TRUSTED,
  TRUST_UNTRUSTED,
  CREDENTIAL_WITHHOLD_MODES,
  COMMON_DENY_TOOLS,
  AUTONOMOUS_DENY_TOOLS,
  UNTRUSTED_INPUT_DENY_TOOLS,
  FORBIDDEN_EXTRA_FLAGS,
  GOVERNANCE_PATHS,
  MUTABLE_GOVERNANCE_PATTERNS,
  TIER_ATTENDED,
  TIER_AUTONOMOUS,
  AgentPolicyError,
  resolveTier,
  resolveTrust,
  resolveCredentialProfile,
  isMutableGovernancePath,
  resolvePolicy,
  resolvePolicyFromEnv,
  buildPolicyMatrix,
  POLICY_MATRIX,
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
    // The policy as a JSON array, for Squad Hub's
    // SQUAD_HUB_AGENT_EXTRA_ARGS_JSON. JSON rather than lines because that is
    // the shape the hub's channel takes, and because it is the encoding that
    // keeps a multi-word deny pattern whole end to end.
    case 'hub-argv-json':
      process.stdout.write(`${JSON.stringify(policy.hubArgv)}\n`);
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
    // Issue #84 PI-2: the orthogonal trust axis, read the same way `tier` is.
    case 'trust':
      process.stdout.write(`${policy.trust}\n`);
      return 0;
    case 'trust-reason':
      process.stdout.write(`${policy.trustReason}\n`);
      return 0;
    // Issue #84 PI-3: what credential material this session's wiring holds,
    // as JSON -- the shape worker/entrypoint.sh and its tests both consume.
    case 'credential-profile':
      process.stdout.write(`${JSON.stringify(policy.credentialProfile)}\n`);
      return 0;
    // `1` (true) / `0` (false) on stdout, so bash can use it directly in a
    // condition without parsing JSON:
    //   [[ "$(node agent-policy.js should-withhold-credential)" == "1" ]]
    case 'should-withhold-credential':
      process.stdout.write(policy.credentialProfile.withheld ? '1\n' : '0\n');
      return 0;
    // Issue #84 follow-up (Security blocker): whether COPILOT_GITHUB_TOKEN, as
    // provisioned in THIS environment, carries the git push token's value.
    // Read by worker/entrypoint.sh's fail-closed gate for logging/diagnostics
    // only -- the gate's actual decision uses the same direct env comparison
    // squad-credentials.sh's squad_credential_withhold acts on, so a resolver
    // failure here can never suppress the gate.
    case 'copilot-token-shared':
      process.stdout.write(policy.credentialProfile.copilotTokenShared ? '1\n' : '0\n');
      return 0;
    // Issue #84 PI-1: the resolved source x mode table, as JSON. Not read by
    // any shell script -- it exists for the exhaustiveness test and for an
    // operator who wants the whole matrix in one call rather than one cell.
    case 'matrix':
      process.stdout.write(`${JSON.stringify(POLICY_MATRIX, null, 2)}\n`);
      return 0;
    default:
      process.stderr.write(
        'Usage: agent-policy.js [json|flags|argv|squad-flags|hub-argv-json|undeliverable|tier|reason|' +
          'trust|trust-reason|credential-profile|should-withhold-credential|copilot-token-shared|matrix|' +
          'governance-paths|mutable-governance-patterns|classify-governance-path <path>]\n'
      );
      return 78;
  }
}

if (require.main === module) {
  process.exit(main(process.argv.slice(2)));
}
