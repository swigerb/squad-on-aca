#!/usr/bin/env bash
# Tests for worker/lib/agent-policy.js — the shared tool-policy resolver.
#
# Issue #26 / PRD #6. This suite exists because the resolver is the ONE place
# that decides what an agent may do, on both execution planes. If it can be made
# to emit a blanket-allow flag set, or to hand an unattended run the attended
# tier, every other control in this change is decoration.
#
# The assertions are deliberately about the RESOLVED DECISION (tier, argv
# tokens, exit status) rather than about prose in the file. A test that only
# greps the source for the string "--yolo" passes just as happily when the
# resolver ships that flag as when it refuses to.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
RESOLVER="${WORKER_DIR}/lib/agent-policy.js"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== agent-policy.js =="

# policy <mode> <dispatch-source> <extra-flags> <plane> <resolver args...>
#
# GH_TOKEN/GITHUB_TOKEN/COPILOT_GITHUB_TOKEN/SQUAD_COPILOT_TOKEN_PROVENANCE/
# SQUAD_ALLOW_SHARED_COPILOT_TOKEN are explicitly unset so every existing call
# site stays deterministic regardless of what happens to be exported in the
# CI/dev shell running this suite -- resolvePolicyFromEnv now reads those
# variables (issue #84 follow-up: copilotTokenShared/copilotTokenSharedAllowed).
policy() {
  local mode="$1" source="$2" extra="$3" plane="$4"
  shift 4
  env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE \
      -u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_GITHUB_TOKEN \
      -u SQUAD_COPILOT_TOKEN_PROVENANCE -u SQUAD_ALLOW_SHARED_COPILOT_TOKEN \
    SQUAD_MODE="$mode" \
    SQUAD_DISPATCH_SOURCE="$source" \
    SQUAD_COPILOT_FLAGS="$extra" \
    SQUAD_EXECUTION_MODE="$plane" \
    node "$RESOLVER" "$@" 2>&1
}

policy_status() {
  policy "$@" >/dev/null 2>&1
  printf '%s' "$?"
}

# policy_tokens <mode> <dispatch-source> <gh-token> <copilot-token> [allow-shared]
#
# Issue #84 follow-up: exercises resolvePolicyFromEnv's live GH_TOKEN /
# COPILOT_GITHUB_TOKEN comparison directly (the credential-profile CLI path),
# rather than the design-level neutral matrix.
policy_tokens() {
  local mode="$1" source="$2" gh_token="$3" copilot_token="$4" allow="${5:-}"
  env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE \
      -u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_GITHUB_TOKEN \
      -u SQUAD_COPILOT_TOKEN_PROVENANCE -u SQUAD_ALLOW_SHARED_COPILOT_TOKEN \
    SQUAD_MODE="$mode" \
    SQUAD_DISPATCH_SOURCE="$source" \
    SQUAD_COPILOT_FLAGS="" \
    SQUAD_EXECUTION_MODE="aca-job" \
    GH_TOKEN="$gh_token" \
    COPILOT_GITHUB_TOKEN="$copilot_token" \
    SQUAD_ALLOW_SHARED_COPILOT_TOKEN="$allow" \
    node "$RESOLVER" credential-profile 2>&1
}

# ---------------------------------------------------------------------------
# 1. Tier selection
# ---------------------------------------------------------------------------
# The signal already exists in every dispatch: SQUAD_MODE says WHAT is running
# and SQUAD_DISPATCH_SOURCE says WHO started it. A run is attended only when a
# named human started this specific run; everything else is autonomous.
echo "-- tier selection --"

assert_eq "attended"   "$(policy prompt          local-cli '' aca-job tier)"  "prompt started from the local CLI is attended"
assert_eq "attended"   "$(policy new-project     local-cli '' aca-job tier)"  "new-project started from the local CLI is attended"
assert_eq "attended"   "$(policy shell           local-cli '' aca-job tier)"  "shell started from the local CLI is attended"
assert_eq "attended"   "$(policy smoke           local-cli '' aca-job tier)"  "smoke started from the local CLI is attended"
assert_eq "attended"   "$(policy telemetry-smoke local-cli '' aca-job tier)"  "telemetry-smoke started from the local CLI is attended"

# Ralph is a five-minute cron and Watch is a polling loop. Nobody is present to
# approve anything, so neither may ever be handed the attended tier.
assert_eq "autonomous" "$(policy ralph  ralph '' aca-job tier)"               "ralph is autonomous"
assert_eq "autonomous" "$(policy watch  watch '' aca-job tier)"               "watch is autonomous"
assert_eq "autonomous" "$(policy triage watch '' aca-job tier)"               "triage is autonomous"
assert_eq "autonomous" "$(policy loop   ralph '' aca-job tier)"               "loop is autonomous"

# An attended MODE reached by an unattended DISPATCH is still unattended: Ralph
# dispatches `prompt` sessions, and that is the case a mode-only check misses.
assert_eq "autonomous" "$(policy prompt ralph '' aca-job tier)"               "prompt dispatched by ralph is autonomous, not attended"
assert_eq "autonomous" "$(policy prompt watch '' aca-job tier)"               "prompt dispatched by watch is autonomous"
assert_eq "autonomous" "$(policy prompt api   '' aca-job tier)"               "prompt dispatched by the API is autonomous"

# Fail closed on anything unrecognised, in both directions.
assert_eq "autonomous" "$(policy ''            local-cli '' aca-job tier)"    "an empty mode falls back to autonomous"
assert_eq "autonomous" "$(policy not-a-mode    local-cli '' aca-job tier)"    "an unknown mode falls back to autonomous"
assert_eq "autonomous" "$(policy prompt        not-a-source '' aca-job tier)" "an unknown dispatch source falls back to autonomous"
# "Nobody said who started this" is not evidence that a human did. If this ever
# resolved to attended, the strict tier would be opt-out by omitting a variable.
assert_eq "autonomous" "$(policy prompt        ''        '' aca-job tier)"    "an ABSENT dispatch source falls back to autonomous"
assert_eq "autonomous" "$(policy smoke         ''        '' aca-job tier)"    "an absent dispatch source is autonomous even for smoke"

# ---------------------------------------------------------------------------
# 2. Local / remote parity
# ---------------------------------------------------------------------------
# PRD #6: "changing execution substrate cannot escalate privilege". The two
# planes populate the worker environment differently — the ACA Jobs plane sets
# SQUAD_DISPATCH_SOURCE, the sandbox plane leaves it unset — so parity is only
# real if the SAME request resolves to the SAME policy on both.
echo "-- local/remote parity --"

for m in prompt new-project shell smoke telemetry-smoke ralph watch triage loop; do
  for s in "" local-cli ralph watch api; do
    aca="$(policy "$m" "$s" '' aca-job json)"
    sandbox="$(policy "$m" "$s" '' sandbox json)"
    # Compare the WHOLE decision, not just the tier: identical tier with a
    # different deny list would still be an escalation by substrate.
    assert_eq "${aca//\"executionPlane\": \"aca-job\"/PLANE}" \
              "${sandbox//\"executionPlane\": \"sandbox\"/PLANE}" \
              "mode '${m}' from source '${s:-<unset>}' resolves identically on both planes"
  done
done

# The plane must not be able to widen anything by itself.
assert_eq "$(policy ralph ralph '' aca-job flags)" "$(policy ralph ralph '' sandbox flags)" \
  "the execution plane alone does not change the emitted flag set"

# ---------------------------------------------------------------------------
# 3. Emitted flags — what is and is not allowed through
# ---------------------------------------------------------------------------
echo "-- emitted flags --"

attended_flags="$(policy prompt local-cli '' aca-job flags)"
autonomous_flags="$(policy ralph ralph '' aca-job flags)"

# The whole point of the issue: the blanket-allow flags must be gone from every
# tier, on every plane, for every mode.
for label in attended autonomous; do
  eval "f=\$${label}_flags"
  assert_not_contains "$f" "--yolo"            "${label}: --yolo is never emitted"
  assert_not_contains "$f" "--allow-all-paths" "${label}: --allow-all-paths is never emitted"
done
assert_not_contains "$attended_flags"   "--allow-all-urls" "attended: --allow-all-urls is never emitted"
assert_not_contains "$autonomous_flags" "--allow-all-urls" "autonomous: --allow-all-urls is never emitted"

# --allow-all-tools is retained deliberately: the pinned CLI documents it as
# "required for non-interactive mode", and there is no interactive approver in a
# container on EITHER plane. It is not the escalation — --allow-all-paths and
# --allow-all-urls were. Deny rules take precedence over it (verified against
# @github/copilot 1.0.69-2, `copilot help permissions`).
assert_contains "$autonomous_flags" "--allow-all-tools" "autonomous: --allow-all-tools is retained for non-interactive operation"

# Never prompt on an unattended run: a prompt with nobody there is a hang.
assert_contains     "$autonomous_flags" "--no-ask-user" "autonomous: --no-ask-user is set so an unattended run cannot hang on a prompt"
assert_not_contains "$attended_flags"   "--no-ask-user" "attended: --no-ask-user is not forced"

# Both tiers deny the commands that would undo the governance lock or rewrite
# the credentials the session runs with.
for pattern in "shell(sudo)" "shell(chmod)" "shell(chown)" "shell(chattr)" "shell(setfacl)" "shell(git config)" "shell(gh auth)" "shell(gh secret)"; do
  assert_contains "$attended_flags"   "$pattern" "attended denies ${pattern}"
  assert_contains "$autonomous_flags" "$pattern" "autonomous denies ${pattern}"
done

# The autonomous tier additionally removes the infrastructure-destructive verbs.
# These are not approval-gated for an unattended run, they are UNAVAILABLE —
# there is no human to gate them with.
for pattern in "shell(az)" "shell(kubectl)" "shell(terraform)" "shell(docker)" "shell(gh repo delete)"; do
  assert_contains     "$autonomous_flags" "$pattern" "autonomous denies ${pattern}"
  assert_not_contains "$attended_flags"   "$pattern" "attended does not deny ${pattern} (a human is present)"
done

# The autonomous tier must be a strict superset of the attended denials.
missing_from_autonomous=""
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  case ",$(policy ralph ralph '' aca-job json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).denyTools.join(",")))')," in
    *",${p},"*) ;;
    *) missing_from_autonomous="${missing_from_autonomous}${p} " ;;
  esac
done < <(policy prompt local-cli '' aca-job json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>JSON.parse(s).denyTools.forEach(t=>console.log(t)))')
assert_eq "" "$missing_from_autonomous" "the autonomous deny list is a strict superset of the attended one"

# ---------------------------------------------------------------------------
# 4. Escalation through SQUAD_COPILOT_FLAGS
# ---------------------------------------------------------------------------
# SQUAD_COPILOT_FLAGS is operator-supplied and reaches the worker through the
# job template, so it is the obvious way to put `--yolo` back. It stays usable
# for genuine extras (model, log level) and REJECTS anything that widens
# permission — by aborting, not by silently dropping the flag, because a
# silently-dropped escalation attempt looks identical to a working one.
echo "-- escalation attempts --"

assert_eq "78" "$(policy_status ralph  ralph    '--yolo' aca-job flags)"                     "--yolo in SQUAD_COPILOT_FLAGS aborts (autonomous)"
assert_eq "78" "$(policy_status prompt local-cli '--yolo' aca-job flags)"                    "--yolo in SQUAD_COPILOT_FLAGS aborts (attended too — parity)"
assert_eq "78" "$(policy_status ralph  ralph    '--allow-all' aca-job flags)"                "--allow-all in SQUAD_COPILOT_FLAGS aborts"
assert_eq "78" "$(policy_status ralph  ralph    '--allow-all-paths' aca-job flags)"          "--allow-all-paths in SQUAD_COPILOT_FLAGS aborts"
assert_eq "78" "$(policy_status ralph  ralph    '--add-dir /etc' aca-job flags)"             "--add-dir in SQUAD_COPILOT_FLAGS aborts"
assert_eq "78" "$(policy_status ralph  ralph    '--add-dir=/etc' aca-job flags)"             "--add-dir=<path> aborts (the = form is not a different flag)"
assert_eq "78" "$(policy_status ralph  ralph    '--model gpt-5 --yolo' aca-job flags)"       "--yolo hidden among legitimate extras still aborts"

rejected="$(policy ralph ralph '--yolo' aca-job flags)"
assert_contains "$rejected" "--yolo" "the abort message names the flag that was rejected"

# A legitimate extra is passed through untouched — the control must not be so
# blunt that operators route around it.
ok_flags="$(policy ralph ralph '--model claude-sonnet-4.5' aca-job flags)"
assert_eq "0" "$(policy_status ralph ralph '--model claude-sonnet-4.5' aca-job flags)" "a non-permission extra is accepted"
assert_contains "$ok_flags" "--model claude-sonnet-4.5" "a non-permission extra survives into the emitted flags"
assert_contains "$ok_flags" "shell(sudo)"                "accepting an extra does not drop the deny list"

# ---------------------------------------------------------------------------
# 5. argv vs --copilot-flags: the multi-word deny pattern problem
# ---------------------------------------------------------------------------
# `squad --copilot-flags <string>` is split with .trim().split(/\s+/) in
# @bradygaster/squad-cli 0.11.0 (dist/index.js, dist/loop.js, dist/agent-spawn.js
# and six others). A deny pattern containing a space CANNOT survive that path.
# The resolver therefore publishes two surfaces and names what the lossy one
# drops, so the downgrade is visible in the session log instead of silent.
echo "-- argv vs squad --copilot-flags --"

argv_out="$(policy ralph ralph '' aca-job argv)"
assert_contains "$argv_out" "shell(git config)" "argv carries the multi-word deny pattern"
# One token per line means a space-bearing pattern stays a single argument.
gitconfig_lines="$(printf '%s\n' "$argv_out" | grep -c '^shell(git config)$')"
assert_eq "1" "$gitconfig_lines" "the multi-word pattern is exactly one argv token, not two"

squad_out="$(policy ralph ralph '' aca-job squad-flags)"
assert_not_contains "$squad_out" "shell(git config)" "the squad flag string omits patterns it cannot carry intact"
assert_contains     "$squad_out" "shell(sudo)"        "the squad flag string keeps every pattern it CAN carry"
# The lossy surface must never contain a space-bearing pattern, or squad would
# split it into two bogus arguments and the CLI would reject the invocation.
assert_not_contains "$squad_out" " config " "the squad flag string contains no orphaned pattern fragment"

undeliverable="$(policy ralph ralph '' aca-job undeliverable)"
assert_contains "$undeliverable" "shell(git config)" "the undeliverable list names the dropped pattern"
assert_contains "$undeliverable" "shell(gh auth)"    "the undeliverable list names every dropped pattern"

# ---------------------------------------------------------------------------
# 6. Governance paths
# ---------------------------------------------------------------------------
echo "-- governance paths --"

gov="$(policy ralph ralph '' aca-job governance-paths)"
for p in ".squad/policies" ".squad/agents" ".squad/identity" ".squad/config.json" ".squad/routing.md"; do
  assert_contains "$gov" "$p" "PRD #6 governance path ${p} is protected"
done
assert_contains "$gov" ".squad/memory/audit.jsonl"        "audit state is protected"
assert_contains "$gov" ".squad/fact-checker/audit-trail.md" "approval/audit trail state is protected"

# Identical in both tiers: an attended run is not licensed to rewrite the
# policies that govern it either. If that ever diverges it must be a deliberate,
# reviewed change — this assertion is what forces the conversation.
assert_eq "$(policy prompt local-cli '' aca-job governance-paths)" "$gov" \
  "the protected set is identical for attended and autonomous runs"

# ---------------------------------------------------------------------------
# 6b. The append-only exclusion
# ---------------------------------------------------------------------------
# `.squad/agents/<name>/history.md` is an append-only WORK LOG, not policy.
# Excluding it from the write lock is what lets an autonomous run record what it
# did; the exclusion is only safe while it is anchored at BOTH ends, because one
# segment of slack re-opens `charter.md`, which is what an agent is permitted to
# do. The resolver owns the pattern, so the resolver is where it is asserted.
echo "-- append-only exclusion --"

pat="$(policy ralph ralph '' aca-job mutable-governance-patterns)"
assert_eq "^\\.squad/agents/[^/]+/history\\.md\$" "$pat" \
  "the resolver publishes exactly one, fully anchored, append-only pattern"
assert_eq "$(policy prompt local-cli '' aca-job mutable-governance-patterns)" "$pat" \
  "the append-only exclusion is identical for attended and autonomous runs"

classify_path() {
  policy ralph ralph '' aca-job classify-governance-path "$1"
}
assert_eq "append-only" "$(classify_path '.squad/agents/security/history.md')" \
  "an agent's own history file is append-only, so an autonomous run can record what it did"
assert_eq "append-only" "$(classify_path '.squad\agents\security\history.md')" \
  "a Windows-shaped path classifies the same way, so the boundary does not depend on who produced the path"
for locked in \
  '.squad/agents/security/charter.md' \
  '.squad/agents/security/history.md.bak' \
  '.squad/agents/security/sub/history.md' \
  '.squad/agents/history.md' \
  '.squad/policies/history.md' \
  '.squad/config.json'
do
  assert_eq "locked" "$(classify_path "$locked")" "${locked} stays locked"
done
assert_eq "78" "$(policy_status ralph ralph '' aca-job classify-governance-path '')" \
  "classifying an empty path exits 78 rather than answering for it"

# ---------------------------------------------------------------------------
# 7. Determinism
# ---------------------------------------------------------------------------
echo "-- determinism --"
assert_eq "$(policy ralph ralph '' aca-job json)" "$(policy ralph ralph '' aca-job json)" \
  "the same inputs resolve to byte-identical policy"

# ---------------------------------------------------------------------------
# 8. Bad usage fails closed
# ---------------------------------------------------------------------------
echo "-- bad usage --"
assert_eq "78" "$(policy ralph ralph '' aca-job no-such-mode >/dev/null 2>&1; printf '%s' $?)" \
  "an unknown resolver sub-command exits 78 rather than printing something usable"

# ---------------------------------------------------------------------------
# 9. Issue #84 PI-1: matrix exhaustiveness / agreement
# ---------------------------------------------------------------------------
# "a test asserts the table matches what agent-policy.js composes, and fails
# if a new source or mode is added without an entry." POLICY_MATRIX is built
# from KNOWN_SOURCES x KNOWN_MODES, so its row count is a direct function of
# the registry -- and every row is checked here against a FRESH call to
# resolvePolicy for the same cell, so the matrix cannot silently drift from the
# thing it claims to summarise.
echo "-- PI-1 matrix exhaustiveness/agreement --"

matrix_json="$(node -e "console.log(JSON.stringify(require(process.argv[1]).POLICY_MATRIX))" "$RESOLVER")"
known_sources_len="$(node -e "console.log(require(process.argv[1]).KNOWN_SOURCES.length)" "$RESOLVER")"
known_modes_len="$(node -e "console.log(require(process.argv[1]).KNOWN_MODES.length)" "$RESOLVER")"
expected_rows=$((known_sources_len * known_modes_len))

assert_eq "$expected_rows" "$(node -e "console.log(JSON.parse(process.argv[1]).length)" "$matrix_json")" \
  "the matrix has exactly one row per KNOWN_SOURCES x KNOWN_MODES cell (${known_sources_len} x ${known_modes_len})"

# MUTATION PROOF M1 target: deleting a row from POLICY_MATRIX (or from
# KNOWN_SOURCES/KNOWN_MODES so a row is never generated) makes this assertion
# fail, because the row count contract no longer holds.

# Every cell agrees with a fresh, independent call to resolvePolicy for the
# SAME (mode, dispatchSource) pair. If POLICY_MATRIX were ever hand-maintained
# rather than derived, this is what would catch the first cell that drifted.
disagreements="$(node -e "
const policyMod = require(process.argv[1]);
const rows = policyMod.POLICY_MATRIX;
let bad = 0;
for (const row of rows) {
  const fresh = policyMod.resolvePolicy({
    mode: row.mode,
    dispatchSource: row.dispatchSource,
    enableGithubRemote: 'true',
    extraFlags: '',
    executionPlane: 'aca-job',
  });
  const sameTier = fresh.tier === row.tier;
  const sameTrust = fresh.trust === row.trust;
  const sameDeny = JSON.stringify(fresh.denyTools) === JSON.stringify(row.denyTools);
  const sameFlags = JSON.stringify(fresh.flags) === JSON.stringify(row.flags);
  const sameCreds = JSON.stringify(fresh.credentialProfile) === JSON.stringify(row.credentialsPresent);
  if (!(sameTier && sameTrust && sameDeny && sameFlags && sameCreds)) {
    bad += 1;
    console.error(\`mismatch: \${row.dispatchSource}/\${row.mode}\`);
  }
}
console.log(bad);
" "$RESOLVER")"
assert_eq "0" "$disagreements" "every matrix row agrees with a fresh resolvePolicy() call for the same cell"

# The two known unattended, untrusted dispatch sources both get the narrower
# credential and tool posture for the credential-withhold modes.
for src in ralph watch actions; do
  row_withheld="$(node -e "
    const rows = require(process.argv[1]).POLICY_MATRIX;
    const row = rows.find(r => r.dispatchSource === process.argv[2] && r.mode === 'prompt');
    console.log(row.credentialsPresent.withheld ? '1' : '0');
  " "$RESOLVER" "$src")"
  assert_eq "1" "$row_withheld" "matrix: source '${src}' + mode 'prompt' withholds the credential"
done

row_local_prompt_withheld="$(node -e "
  const rows = require(process.argv[1]).POLICY_MATRIX;
  const row = rows.find(r => r.dispatchSource === 'local-cli' && r.mode === 'prompt');
  console.log(row.credentialsPresent.withheld ? '1' : '0');
" "$RESOLVER")"
assert_eq "0" "$row_local_prompt_withheld" "matrix: local-cli + prompt does NOT withhold the credential"

# ---------------------------------------------------------------------------
# 10. Issue #84 PI-2: the orthogonal trust axis
# ---------------------------------------------------------------------------
echo "-- PI-2 trust axis --"

assert_eq "trusted"   "$(policy prompt local-cli '' aca-job trust)" "local-cli is trusted"
assert_eq "untrusted" "$(policy prompt ralph     '' aca-job trust)" "ralph is untrusted"
assert_eq "untrusted" "$(policy prompt watch     '' aca-job trust)" "watch is untrusted"
assert_eq "untrusted" "$(policy prompt actions   '' aca-job trust)" "actions is untrusted"
assert_eq "untrusted" "$(policy prompt ''        '' aca-job trust)" "an absent dispatch source is untrusted"
assert_eq "untrusted" "$(policy prompt api       '' aca-job trust)" "an unrecognised dispatch source is untrusted"

# Trust is ORTHOGONAL to tier: an autonomous, untrusted combination and an
# autonomous, still-untrusted combination for a DIFFERENT mode both land
# untrusted regardless of what the tier resolves to.
assert_eq "$(policy ralph ralph '' aca-job tier)"  "autonomous" "sanity: ralph/ralph is autonomous (tier)"
assert_eq "$(policy ralph ralph '' aca-job trust)" "untrusted"  "ralph/ralph is untrusted (trust) -- independent axis, same source"

# The untrusted deny list is present for EVERY untrusted source, on top of
# whatever the tier already denied -- and ABSENT for the trusted, attended
# local-cli path. "Remote is narrower, local is unchanged", both directions.
local_prompt_flags="$(policy prompt local-cli '' aca-job flags)"
remote_prompt_flags="$(policy prompt ralph    '' aca-job flags)"
remote_watch_flags="$(policy prompt watch     '' aca-job flags)"
remote_actions_flags="$(policy prompt actions '' aca-job flags)"

for pattern in "shell(git push)" "shell(gh pr)" "shell(curl)" "shell(wget)"; do
  assert_contains     "$remote_prompt_flags"   "$pattern" "untrusted (ralph): denies ${pattern}"
  assert_contains     "$remote_watch_flags"    "$pattern" "untrusted (watch): denies ${pattern}"
  assert_contains     "$remote_actions_flags"  "$pattern" "untrusted (actions): denies ${pattern}"
  assert_not_contains "$local_prompt_flags"    "$pattern" "trusted (local-cli): does NOT deny ${pattern} -- local is unchanged"
done

# "Do not blanket-deny git/gh/npm/pip or use --no-remote": prove the narrowing
# is exactly the four patterns above and nothing broader.
assert_not_contains "$remote_prompt_flags" "--deny-tool shell(git)" "untrusted does not deny bare shell(git)"
assert_not_contains "$remote_prompt_flags" "--deny-tool shell(gh)" "untrusted does not deny bare shell(gh) (only shell(gh pr))"
assert_not_contains "$remote_prompt_flags" "shell(npm)" "untrusted does not deny npm"
assert_not_contains "$remote_prompt_flags" "shell(pip)" "untrusted does not deny pip"
assert_not_contains "$remote_prompt_flags" "--no-remote" "untrusted narrowing does not force --no-remote"
assert_contains     "$remote_prompt_flags" "--remote" "the remote flag is governed by ENABLE_GITHUB_REMOTE, unaffected by trust"

# MUTATION PROOF M4 target: removing shell(git push) from
# UNTRUSTED_INPUT_DENY_TOOLS makes the "untrusted (ralph): denies shell(git
# push)" assertion above fail.
# MUTATION PROOF M5 target: moving shell(git push) into COMMON_DENY_TOOLS
# (rather than UNTRUSTED_INPUT_DENY_TOOLS) makes the "trusted (local-cli): does
# NOT deny shell(git push)" assertion above fail, because it would then be
# denied for local-cli too.
# MUTATION PROOF M6 target: adding 'actions' (or 'ralph'/'watch') to
# TRUSTED_SOURCES makes "ralph/ralph is untrusted (trust)" (or the
# corresponding source's assertion) fail.

# Space-bearing untrusted deny patterns go through the SAME undeliverable-via-
# squad-flags mechanism as shell(git config): whole on the authoritative argv
# and the hub's JSON channel, dropped (and named) on the squad --copilot-flags
# path that `squad watch`/`squad loop` use.
echo "-- PI-2 space-bearing deny patterns: argv/hub vs squad watch --"

untrusted_argv="$(policy watch watch '' aca-job argv)"
assert_contains "$untrusted_argv" "shell(git push)" "the authoritative argv carries shell(git push) whole"
assert_contains "$untrusted_argv" "shell(gh pr)"     "the authoritative argv carries shell(gh pr) whole"
git_push_lines="$(printf '%s\n' "$untrusted_argv" | grep -c '^shell(git push)$')"
assert_eq "1" "$git_push_lines" "shell(git push) is exactly one argv token, not two"

untrusted_hub_argv="$(policy watch watch '' aca-job hub-argv-json)"
assert_contains "$untrusted_hub_argv" "shell(git push)" "the hub JSON channel carries shell(git push) whole"
assert_contains "$untrusted_hub_argv" "shell(gh pr)"    "the hub JSON channel carries shell(gh pr) whole"

untrusted_squad_flags="$(policy watch watch '' aca-job squad-flags)"
assert_not_contains "$untrusted_squad_flags" "shell(git push)" "squad watch's space-split --copilot-flags cannot carry shell(git push) -- it is dropped, not mangled"
assert_not_contains "$untrusted_squad_flags" "shell(gh pr)"     "squad watch's space-split --copilot-flags cannot carry shell(gh pr) either"
assert_contains     "$untrusted_squad_flags" "shell(curl)"      "squad watch's --copilot-flags DOES carry the single-word untrusted patterns"
assert_contains     "$untrusted_squad_flags" "shell(wget)"      "squad watch's --copilot-flags DOES carry shell(wget)"

untrusted_undeliverable="$(policy watch watch '' aca-job undeliverable)"
assert_contains "$untrusted_undeliverable" "shell(git push)" "the undeliverable list names shell(git push) so the gap is visible in the session log"
assert_contains "$untrusted_undeliverable" "shell(gh pr)"     "the undeliverable list names shell(gh pr) too"

# MUTATION PROOF M7 target: if the multi-word deny-pattern filter in
# resolvePolicy's squadFlags/undeliverable split were removed (or broken so it
# stops recognising space-bearing patterns), shell(git push)/shell(gh pr)
# would leak into squad_out mangled into two arguments instead of being
# cleanly omitted and named -- the "cannot carry ... dropped, not mangled"
# assertions above would fail.

# ---------------------------------------------------------------------------
# 11. Issue #84 PI-3: credential profile
# ---------------------------------------------------------------------------
echo "-- PI-3 credential profile --"

cred_local_prompt="$(policy prompt local-cli '' aca-job credential-profile)"
assert_contains "$cred_local_prompt" '"ghTokenEnv":true'        "local-cli/prompt: credential env is present"
assert_contains "$cred_local_prompt" '"gitTokenFile":true'      "local-cli/prompt: token file is present"
assert_contains "$cred_local_prompt" '"credentialHelper":true'  "local-cli/prompt: credential helper is wired"
assert_contains "$cred_local_prompt" '"withheld":false'         "local-cli/prompt: not withheld -- trusted input"

for src in ralph watch actions; do
  for mode in prompt new-project; do
    cred="$(policy "$mode" "$src" '' aca-job credential-profile)"
    assert_contains "$cred" '"ghTokenEnv":false'       "${src}/${mode}: GH_TOKEN/GITHUB_TOKEN withheld from the agent"
    assert_contains "$cred" '"gitTokenFile":false'     "${src}/${mode}: token file withheld from the agent"
    assert_contains "$cred" '"credentialHelper":false' "${src}/${mode}: credential helper withheld from the agent"
    assert_contains "$cred" '"withheld":true'          "${src}/${mode}: withheld flag set"
  done
  status="$(policy "$src" "$src" '' aca-job should-withhold-credential 2>/dev/null)"
done

# MUTATION PROOF M3 target: flipping any one of ghTokenEnv/gitTokenFile/
# credentialHelper's boolean in resolveCredentialProfile for the withheld case
# makes the corresponding assertion above fail.

# Not watch/loop/ralph long-lived modes: the credential is NOT withheld for
# those, even on an untrusted source, per the design review's explicit scope.
for mode in watch triage loop ralph smoke telemetry-smoke shell; do
  cred="$(policy "$mode" watch '' aca-job credential-profile)"
  assert_contains "$cred" '"withheld":false' "mode '${mode}' (untrusted source) is NOT a credential-withhold mode"
done

# The one mode that keeps the Azure identity is `ralph`, regardless of source,
# and every other mode drops it -- restated here against the SAME resolver the
# entrypoint's squad_drop_azure_identity mirrors, so a drift between the two
# is visible as a failing assertion rather than two independently-maintained
# 'ralph is special' lists.
assert_contains "$(policy ralph ralph '' aca-job credential-profile)" '"azureIdentity":true' \
  "mode 'ralph' keeps the Azure identity"
assert_contains "$(policy prompt local-cli '' aca-job credential-profile)" '"azureIdentity":false' \
  "mode 'prompt' does not carry the Azure identity"
assert_contains "$(policy watch watch '' aca-job credential-profile)" '"azureIdentity":false' \
  "mode 'watch' does not carry the Azure identity"

# ---------------------------------------------------------------------------
# 12. Security follow-up (issue #84 blocker): copilotTokenEnv/copilotTokenShared
# ---------------------------------------------------------------------------
# Withholding GH_TOKEN/GITHUB_TOKEN alone left COPILOT_GITHUB_TOKEN visible to
# the agent whenever it was the default-deployment shared/derived value. These
# assertions prove the matrix and the live-env resolution both stay honest
# about that: `withheld: true` must never coexist with a shared Copilot token
# still exported.
echo "-- Security follow-up: copilotTokenEnv / copilotTokenShared --"

# The static matrix holds copilotTokenShared at its honest worst-case default
# (true -- the documented default deployment shape), so a withheld cell must
# ALSO show the Copilot plane withheld.
for src in ralph watch actions; do
  for mode in prompt new-project; do
    cred="$(policy "$mode" "$src" '' aca-job credential-profile)"
    assert_contains "$cred" '"copilotTokenShared":true'  "${src}/${mode}: matrix assumes the honest worst case (shared)"
    assert_contains "$cred" '"copilotTokenEnv":false'    "${src}/${mode}: shared Copilot token is ALSO withheld from the agent"
  done
done

# MUTATION PROOF M12 target: dropping the Copilot-token unset from
# squad_credential_withhold (worker/lib/squad-credentials.sh) does not change
# this JS-level assertion directly, but see test_credential_withholding.sh's
# M12 case, which scans the actual exported environment for the live value.

# A trusted local-cli session is never withheld, so its Copilot token (shared
# or not) is left alone -- consistent with "local is unchanged" everywhere
# else in this trust axis.
cred_local="$(policy prompt local-cli '' aca-job credential-profile)"
assert_contains "$cred_local" '"copilotTokenEnv":true' "local-cli/prompt: Copilot token is present -- trusted input, nothing withheld"

# Live-environment resolution (resolvePolicyFromEnv, exercised via
# `credential-profile`): derived, explicit-equal, explicit-distinct, and the
# escape hatch.
derived="$(policy_tokens prompt ralph 'shared-token-aaaa' 'shared-token-aaaa')"
assert_contains "$derived" '"copilotTokenShared":true'   "derived/equal-value token: reported shared"
assert_contains "$derived" '"copilotTokenEnv":false'     "derived/equal-value token: withheld along with the git token"

distinct="$(policy_tokens prompt ralph 'git-token-aaaa' 'copilot-token-bbbb')"
assert_contains "$distinct" '"copilotTokenShared":false' "explicit, distinct Copilot token: reported NOT shared"
assert_contains "$distinct" '"copilotTokenEnv":true'      "explicit, distinct Copilot token: preserved -- not the git push credential"

# MUTATION PROOF M13 target: inverting the equality check in
# squad_copilot_token_is_shared / the copilotTokenShared comparison (`==` ->
# `!=`) would flip these two cases: the shared case would report
# copilotTokenEnv:true (still visible) and the distinct case would report
# copilotTokenEnv:false (wrongly withheld). Either flip fails one of the four
# assertions immediately above.

escape="$(policy_tokens prompt ralph 'shared-token-cccc' 'shared-token-cccc' 'true')"
assert_contains "$escape" '"copilotTokenSharedAllowed":true' "escape hatch: reported as an explicit, weakened acceptance"
assert_contains "$escape" '"copilotTokenEnv":true'           "escape hatch: shared Copilot token stays exported (documented, not silent)"
assert_contains "$escape" '"withheld":true'                  "escape hatch: the git push credential is still withheld"

no_escape_by_default="$(policy_tokens prompt ralph 'shared-token-dddd' 'shared-token-dddd' '')"
assert_contains "$no_escape_by_default" '"copilotTokenSharedAllowed":false' "escape hatch is NOT the default -- must be explicitly 'true'"
assert_contains "$no_escape_by_default" '"copilotTokenEnv":false'           "without the escape hatch, a shared token is withheld"

# MUTATION PROOF M16 target: changing the escape-hatch default in
# resolveCredentialProfile/resolvePolicyFromEnv (or in
# squad_copilot_shared_token_gate) from "only true when explicitly 'true'" to
# "true unless explicitly 'false'" makes the "escape hatch is NOT the default"
# assertion above fail.

# Invariant across the WHOLE matrix (worst-case default inputs): never claim
# withheld while a shared Copilot token remains exported.
invariant_violations="$(node -e "
const policyMod = require(process.argv[1]);
let bad = 0;
for (const row of policyMod.POLICY_MATRIX) {
  const c = row.credentialsPresent;
  if (c.withheld && c.copilotTokenShared && c.copilotTokenEnv && !c.copilotTokenSharedAllowed) {
    bad += 1;
    console.error(\`unqualified withheld claim while shared Copilot token exported: \${row.dispatchSource}/\${row.mode}\`);
  }
}
console.log(bad);
" "$RESOLVER")"
assert_eq "0" "$invariant_violations" \
  "no matrix row claims withheld:true while a shared, non-escape-hatched Copilot token stays exported"

test_summary
