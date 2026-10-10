#!/usr/bin/env bash
# Issue #150: the Squad role charters, routing, operative instructions and the
# after-agent Scribe spawn must all agree with the approved model assignment:
#
#   gpt-6.1-sol        lead, advisor, security, rai, fact-checker
#   claude-sonnet-5.5  engineer, reviewer, devrel, ralph   (also defaultModel)
#   claude-haiku-5.5   scribe, docs
#
# This suite reads the ACTUAL instruction map -- .squad/config.json, every
# .squad/agents/<name>/charter.md, .squad/routing.md, .squad/ralph-instructions.md,
# .github/agents/squad.agent.md, .squad/templates/after-agent-reference.md and
# .squad/decisions.md -- through worker/tests/lib/squad-model-policy.js, which owns
# the checks and the mutants. Nothing is claimed about a runtime: this proves the
# text the coordinator and spawned agents read agrees with itself and with the
# policy, not that any given spawn honoured a model.
#
# What it pins that a text grep would miss:
#   - config keys are EXACTLY the .squad/agents/<name>/ folders, case-sensitive
#     (a Rai/Scribe key never matches and silently falls through to defaultModel);
#   - each charter's ## Model equals the config, and the routing table agrees;
#   - the after-agent Scribe spawn, as the reference + the overlay actually compose,
#     runs claude-haiku-5.5 from config and keeps the FULL reference prompt duties
#     (spawn manifest, archival safety rules and size gates, orchestration and
#     session logs, permitted cross-agent history updates, history summarization
#     gate, health report) -- the overlay carries no replacement prompt;
#   - no silent downgrade: an unavailable model is reported, never replaced, and
#     `model` is never omitted for a member;
#   - superseded decisions are labelled and kept, not rewritten.
#
# NOT covered, deliberately: the generic SDK catalogs and templates
# (.squad/templates/model-selection-reference.md, skills/**), casting, history,
# runtime and state files. They are overridden by the authoritative policy in
# squad.agent.md instead of being swept.
#
# MUTATION PROOF (issue #150): the node library applies in-memory regressions to
# the real files (no file on disk is touched) and each must be REJECTED by the
# named check -- a stale lead/engineer/scribe model in config, a re-cased
# Rai/Scribe key, a stale charter or routing row, the original Scribe
# claude-haiku-4.5 hardcode, an overlay that adds a shortened prompt, a dropped
# archival gate or health report, a downgrade/omit-model allowance, a removed
# Superseded label, rewritten history. A mutation whose target text is absent
# fails loudly rather than passing as a no-op.
set -uo pipefail

echo "== Squad role model policy and complete Scribe workflow (issue #150) =="

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

output="$(node "${TEST_DIR}/lib/squad-model-policy.js" 2>&1)"
rc=$?

checks=0
mutants=0
while IFS= read -r line; do
  case "$line" in
    "ok - "*)
      assert_eq "ok" "ok" "${line#ok - }"
      case "$line" in "ok - mutant rejected"*) mutants=$((mutants + 1)) ;; *) checks=$((checks + 1)) ;; esac
      ;;
    "FAIL: "*)
      assert_eq "ok" "fail" "${line#FAIL: }"
      ;;
    "") ;;
    *)
      assert_eq "ok" "unexpected output" "$line"
      ;;
  esac
done <<<"$output"

assert_eq "0" "$rc" "policy library exited cleanly"
# A suite that silently checks nothing must not pass: the library defines 27
# checks and 51 mutants today; fail if either shrinks.
if [[ "$checks" -lt 27 ]]; then assert_eq ">=27" "$checks" "policy checks that ran"; fi
if [[ "$mutants" -lt 51 ]]; then assert_eq ">=51" "$mutants" "mutants that ran and were rejected"; fi

test_summary
