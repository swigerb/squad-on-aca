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
policy() {
  local mode="$1" source="$2" extra="$3" plane="$4"
  shift 4
  env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE \
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

test_summary
