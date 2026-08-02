#!/usr/bin/env bash
# Behavioural-equivalence proof for the SHARED manifest-path decision.
#
# WHY THIS SUITE EXISTS
# ---------------------
# The rules that decide whether a capability manifest path is safe used to exist
# TWICE: once in worker/lib/resolve-capability-route.js (the control-plane
# routing decision) and once as an inline `node - <<'NODE'` heredoc inside
# worker/lib/squad-capability-preflight.sh (the in-worker session gate). Two
# implementations of a path-traversal boundary is the shape of a future CVE: a
# rule added to one copy and not the other applies to routing but not to the
# gate that runs in the session, and nothing fails. See
# docs/adr/0003-capability-manifest-future-work.md, finding 2.
#
# They now share worker/lib/locate-manifest.js. This suite is the proof, and the
# proof has a specific shape: ONE corpus (worker/tests/fixtures/manifest-path-corpus.txt)
# driven through BOTH entry points, asserted case by case rather than in
# aggregate. A single mutation to the shared module -- for example making the
# tree-escape check accept ".." -- must therefore fail TWO named assertions, one
# per entry point. If it only fails one, the two are not sharing code and this
# suite is decorative.
#
# A CROSS-CHECK IS NOT ENOUGH, AND THAT IS DELIBERATE
# ---------------------------------------------------
# "Assert the two copies agree" passes whether or not they share code, so it can
# never catch a rule added to one and not the other. What makes this suite
# load-bearing is that both sides reach the SAME FUNCTION: the resolver
# require()s it, and the preflight execs it as a CLI. The mutation table in
# docs/plans/capability-manifest-future-work.md records which assertion each
# deliberate breakage takes down.
#
# WHAT IS *NOT* DRIFT
# -------------------
# Three corpus rows are marked with a caller-level framing. The preflight
# refuses them somewhere other than the shared logic (its own
# "Repository directory does not exist" guard, or its `${VAR:-default}`
# fallback), and NUL cannot cross a process boundary at all. Both entry points
# still refuse; they refuse in different places, and the preflight's message is
# the better one for an operator. Those guards are deliberately not unified
# away, and are asserted here in their own right so a later reader cannot
# mistake them for disagreement.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WORKER_DIR}/.." && pwd)"

PREFLIGHT="${WORKER_DIR}/lib/squad-capability-preflight.sh"
RESOLVER_MODULE="${WORKER_DIR}/lib/resolve-capability-route.js"
LOCATOR_CLI="${WORKER_DIR}/lib/locate-manifest.js"
CATALOG="${REPO_ROOT}/config/sandbox-classes.json"
CORPUS="${TEST_DIR}/fixtures/manifest-path-corpus.txt"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node mktemp sed

echo "== shared manifest-path corpus =="

for required in "$PREFLIGHT" "$RESOLVER_MODULE" "$LOCATOR_CLI" "$CORPUS"; do
  if [[ ! -f "$required" ]]; then
    echo "FAIL: manifest-path corpus: ${required} is missing, so nothing below could run"
    exit 1
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-manifest-corpus.XXXXXXXX")" || {
  echo "FAIL: could not create a work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

# Valid AND satisfiable: a "present" verdict has to carry all the way through
# the preflight to exit 0, or the corpus could not tell "the path resolved" from
# "the path resolved and the manifest was rejected".
MANIFEST_CONTENT='version: 1
tools:
  - name: git
    required: true
'

CTRL="$(printf '\001')"

# --- Case construction -------------------------------------------------------
# Echoes the repository directory for the case (which, for the repo-* setups,
# deliberately is not a usable directory).
build_case() {
  local id="$1" setup="$2" rel="$3"
  local root="${WORK}/${id}"
  local repo="${root}/repo"
  local outside="${root}/outside"

  rm -rf "$root"
  mkdir -p "$outside"

  case "$setup" in
    repo-missing) : ;;
    repo-is-file) printf 'this is a file, not a repository\n' > "$repo" ;;
    repo-loop)    ln -s repo "$repo" ;;
    *)            mkdir -p "$repo" ;;
  esac

  case "$setup" in
    regular)
      mkdir -p "$(dirname "${repo}/${rel}")"
      printf '%s' "$MANIFEST_CONTENT" > "${repo}/${rel}"
      ;;
    dir)
      mkdir -p "${repo}/${rel}"
      ;;
    symlink-inside)
      printf '%s' "$MANIFEST_CONTENT" > "${repo}/real-manifest.yml"
      ln -s "${repo}/real-manifest.yml" "${repo}/${rel}"
      ;;
    symlink-outside)
      printf '%s' "$MANIFEST_CONTENT" > "${outside}/outside.yml"
      ln -s "${outside}/outside.yml" "${repo}/${rel}"
      ;;
    symlink-dangling)
      ln -s "${repo}/there-is-no-such-target.yml" "${repo}/${rel}"
      ;;
    escape-file)
      printf '%s' "$MANIFEST_CONTENT" > "${outside}/outside.yml"
      ;;
    none|repo-missing|repo-is-file|repo-loop)
      : ;;
    *)
      printf 'manifest-path corpus: setup %s is not implemented\n' "$setup" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$repo"
}

# --- Entry point 1: the resolver, in process ---------------------------------
# Deliberately through resolve-capability-route.js's EXPORT, not through
# locate-manifest.js directly: that is what proves the resolver actually
# delegates rather than keeping a private copy.
resolver_verdict() {
  node -e '
const mod = require(process.argv[1]);
const located = mod.locateManifest(process.argv[2], process.argv[3]);
process.stdout.write(String(located && located.status));
' "$RESOLVER_MODULE" "$1" "$2"
}

# --- Entry point 2: the preflight, end to end --------------------------------
# Mapped from the operator-facing OUTPUT, not from the exit code alone. Exit 78
# is reached by several different failures (unsafe path, malformed manifest,
# missing required tool), so asserting "78" would let a mutation that turned an
# escape into "present, then malformed" keep passing. The verdict has to name
# which branch was taken.
preflight_verdict() {
  local repo="$1" rel="$2" out rc
  out="$(CAPABILITY_MANIFEST_PATH="$rel" bash "$PREFLIGHT" "$repo" 2>&1)"
  rc=$?
  case "$out" in
    *"Repository directory does not exist"*)   printf 'caller-guard|%s' "$rc" ;;
    *"Manifest path locator"*)                 printf 'locator-refused|%s' "$rc" ;;
    *"invalid or unsafe"*)                     printf 'unsafe|%s' "$rc" ;;
    *"No capability manifest at"*)             printf 'absent|%s' "$rc" ;;
    *"Found capability manifest at"*)          printf 'present|%s' "$rc" ;;
    *)                                         printf 'unmapped|%s' "$rc" ;;
  esac
}

cli_exit() {
  node "$LOCATOR_CLI" "$1" "$2" >/dev/null 2>&1
  printf '%s' "$?"
}

display_path() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '<empty>'
  else
    printf '%s' "${value//${CTRL}/<U+0001>}"
  fi
}

consequence_for() {
  case "$1" in
    unsafe)
      printf 'refusing it IS the path-traversal boundary -- if the two entry points disagree, routing and the in-session gate protect different things'
      ;;
    absent)
      printf 'a missing manifest must stay a no-op, or every repository that declares none is refused'
      ;;
    present)
      printf 'a real in-tree manifest must still be found, or the gate refuses every repository that has one'
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. THE CORPUS. Every `shared` row, both entry points, one assertion each.
# ---------------------------------------------------------------------------
corpus_rows=0
shared_rows=0
cli_exit_one=0
cli_exit_codes=""

while IFS= read -r line; do
  line="${line%$'\r'}"
  [[ -z "$line" ]] && continue
  [[ "$line" == \#* ]] && continue

  IFS='|' read -r id setup rel expected framing <<< "$line"
  corpus_rows=$((corpus_rows + 1))

  # Placeholders that cannot be written literally into the fixture.
  rel="${rel//@CTRL@/${CTRL}}"
  [[ "$rel" == "@EMPTY@" ]] && rel=""

  shown="$(display_path "$rel")"

  if [[ "$framing" == "caller-argv" ]]; then
    # NUL cannot be built in a shell variable and cannot cross execve, so this
    # row is resolver-side only, and says so.
    actual="$(node -e '
const mod = require(process.argv[1]);
const located = mod.locateManifest(process.argv[2], "caps\u0000.yml");
process.stdout.write(String(located && located.status));
' "$RESOLVER_MODULE" "$WORK")"
    assert_eq "unsafe" "$actual" \
      "corpus/${id}: resolver refuses an embedded NUL in the manifest path -- unreachable from the preflight because execve terminates argv and environ at NUL, so this rule is asserted where it can actually be delivered"
    continue
  fi

  repo="$(build_case "$id" "$setup" "$rel")" || {
    echo "FAIL: manifest-path corpus: could not build case '${id}'; refusing to test a case the harness does not build"
    exit 1
  }

  # The CLI's exit code is collected for every row (see assertion block 2). An
  # exit 1 is the signature of an uncaught throw or a module that would not
  # load, and it must never be produced by a path VERDICT -- that is what let
  # "the module is missing" masquerade as "the path is unsafe" under the old
  # non-zero-means-unsafe scheme.
  code="$(cli_exit "$repo" "$rel")"
  cli_exit_codes="${cli_exit_codes}${id}=${code} "
  [[ "$code" == "1" ]] && cli_exit_one=$((cli_exit_one + 1))

  resolver_actual="$(resolver_verdict "$repo" "$rel")"
  preflight_actual="$(preflight_verdict "$repo" "$rel")"

  case "$framing" in
    shared)
      shared_rows=$((shared_rows + 1))
      case "$expected" in
        unsafe)  expected_rc=78 ;;
        *)       expected_rc=0 ;;
      esac
      assert_eq "$expected" "$resolver_actual" \
        "corpus/${id}: resolver says '${shown}' is ${expected} -- $(consequence_for "$expected")"
      assert_eq "${expected}|${expected_rc}" "$preflight_actual" \
        "corpus/${id}: preflight says '${shown}' is ${expected} (exit ${expected_rc}) -- $(consequence_for "$expected")"
      ;;
    caller-guard)
      assert_eq "$expected" "$resolver_actual" \
        "corpus/${id}: resolver says '${shown}' is ${expected} -- the shared module catches the filesystem error rather than throwing, so no caller can ever see a stack trace instead of a verdict"
      assert_eq "caller-guard|64" "$preflight_actual" \
        "corpus/${id}: preflight refuses at its OWN 'Repository directory does not exist' guard (exit 64) BEFORE path resolution -- both refuse, and this framing is recorded so it is never misread as the two implementations disagreeing"
      ;;
    caller-env-default)
      assert_eq "$expected" "$resolver_actual" \
        "corpus/${id}: resolver refuses an explicitly empty manifest path -- the guard exists for an in-process caller, which is the only caller that can pass one"
      ;;
    *)
      echo "FAIL: manifest-path corpus: framing '${framing}' on row '${id}' is not implemented"
      exit 1
      ;;
  esac
done < "$CORPUS"

assert_eq "1" "$([[ "$corpus_rows" -ge 15 ]] && echo 1 || echo 0)" \
  "corpus: the fixture parsed to ${corpus_rows} rows -- a corpus that parsed to nothing would make every assertion above vacuous while the suite still reported green"
assert_eq "1" "$([[ "$shared_rows" -ge 12 ]] && echo 1 || echo 0)" \
  "corpus: ${shared_rows} rows reach the shared logic through BOTH entry points -- the caller-framed rows do not prove unification, so a corpus made only of those would prove nothing"

# ---------------------------------------------------------------------------
# 2. THE CLI CONTRACT the preflight depends on.
# ---------------------------------------------------------------------------
assert_eq "0" "$cli_exit_one" \
  "corpus: the shared locator never exits 1 for any corpus input (${cli_exit_codes}) -- exit 1 is reserved for 'the module is broken or missing', and if a path verdict could produce it the preflight could not tell an incomplete image from an unsafe path"

contract_repo="$(build_case "cli-contract" "regular" "squad-capabilities.yml")"
cli_out="$(node "$LOCATOR_CLI" "$contract_repo" "squad-capabilities.yml")"
cli_rc=$?
assert_eq "0" "$cli_rc" \
  "locator CLI: a present manifest exits 0 -- the preflight reads this exact code as 'go and validate the manifest'"
assert_eq "$(cd "$contract_repo" && pwd -P)/squad-capabilities.yml" "$cli_out" \
  "locator CLI: a present manifest prints the RESOLVED absolute path and nothing else, because the preflight hands that string straight to the parser"

node "$LOCATOR_CLI" "$contract_repo" "no-such-manifest.yml" >/dev/null 2>&1
assert_eq "3" "$?" \
  "locator CLI: an absent manifest exits 3 -- a code of its own, so 'no manifest present' can never be inferred from a failure"

node "$LOCATOR_CLI" "$contract_repo" "/etc/hostname" >/dev/null 2>&1
assert_eq "4" "$?" \
  "locator CLI: an unsafe path exits 4 -- a code of its own, so the preflight's 78 branch cannot be reached by anything except a genuine unsafe verdict"

node "$LOCATOR_CLI" "$contract_repo" >/dev/null 2>&1
assert_eq "64" "$?" \
  "locator CLI: a wrong argument count is a usage error (64), not a verdict -- an unclaimed code the preflight refuses on"

# ---------------------------------------------------------------------------
# 3. CRITERION 3: THE NEW FAILURE MODE THIS SPRINT CREATES.
#
# Before this sprint the preflight had no external dependency for path
# resolution. It has one now. If a Dockerfile edit un-ships it, the preflight
# must REFUSE THE SESSION. It must not report "no manifest present" and must not
# exit 0: that would turn "this manifest path is unsafe" into "there is no
# manifest", a fail-OPEN on a security boundary, and strictly worse than the
# duplication this sprint removed.
#
# THE LAYOUT IS DERIVED FROM THE DOCKERFILE, NEVER HARD-CODED, for the reason
# test_image_layout.sh gives at length: a hard-coded list would keep this block
# green while shipping an image whose preflight refuses every session. The
# positive assertion below is the one that fails when locate-manifest.js is
# dropped from the COPY line -- the deliberate-removal assertions cannot, since
# they remove the file themselves.
# ---------------------------------------------------------------------------
DOCKERFILE="${WORKER_DIR}/Dockerfile"
LIB_DEST="/usr/local/lib/squad-on-aca/"
SHIPPED_LIB_FILES=0

layout_die() {
  echo "FAIL: manifest-path corpus: ${1}"
  echo "      worker/Dockerfile could not be parsed, so the shipped file list is unknown."
  echo "      Refusing to test a guessed layout -- fix the parser or the Dockerfile."
  exit 1
}

build_shipped_lib() {
  local root="$1" line token dest src found=0
  local -a tokens args srcs

  [[ -f "$DOCKERFILE" ]] || layout_die "worker/Dockerfile is missing"
  mkdir -p "$root"

  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*COPY[[:space:]] ]] || continue
    [[ "$line" == *'\' ]] && layout_die "a COPY instruction uses a line continuation, which this parser does not implement"
    [[ "$line" == *'['* ]] && layout_die "a COPY instruction uses the JSON-array form, which this parser does not implement"

    read -r -a tokens <<< "$line"
    args=()
    for token in "${tokens[@]:1}"; do
      case "$token" in
        --from=*) layout_die "a COPY instruction copies from another build stage (--from=); its source is not a context file" ;;
        --*)      continue ;;
        *)        args+=("$token") ;;
      esac
    done
    (( ${#args[@]} >= 2 )) || layout_die "a COPY instruction has fewer than two path operands"

    dest="${args[-1]}"
    [[ "$dest" == "$LIB_DEST" ]] || continue
    srcs=("${args[@]:0:${#args[@]}-1}")
    for src in "${srcs[@]}"; do
      [[ -f "${REPO_ROOT}/${src}" ]] || layout_die "COPY names '${src}', which does not exist in the build context; the image build would fail"
      cp "${REPO_ROOT}/${src}" "${root}/$(basename "$src")" || layout_die "could not stage ${src}"
      SHIPPED_LIB_FILES=$((SHIPPED_LIB_FILES + 1))
    done
    found=1
  done < "$DOCKERFILE"

  (( found == 1 )) || layout_die "no COPY instruction targets ${LIB_DEST}"

  find "$root" -type f -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
  find "$root" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

SHIPPED_LIB="${WORK}/shipped-lib"
build_shipped_lib "$SHIPPED_LIB"

assert_eq "1" "$([[ "$SHIPPED_LIB_FILES" -ge 10 ]] && echo 1 || echo 0)" \
  "preflight layout: the Dockerfile COPY list for ${LIB_DEST} parsed to ${SHIPPED_LIB_FILES} files -- a parse that found nothing would make the shipped-layout assertions below vacuous"

# (a) THE POSITIVE DIRECTION. The layout the Dockerfile actually ships must
#     resolve a manifest. This is the assertion that fails if locate-manifest.js
#     is removed from the COPY line, because the layout is derived from it.
shipped_repo="$(build_case "shipped-layout" "regular" "squad-capabilities.yml")" || {
  echo "FAIL: manifest-path corpus: could not build the shipped-layout case"
  exit 1
}
out="$(bash "${SHIPPED_LIB}/squad-capability-preflight.sh" "$shipped_repo" 2>&1)"
rc=$?
assert_eq "0" "$rc" \
  "preflight: the layout worker/Dockerfile actually ships resolves a manifest path (exit 0) -- drop locate-manifest.js from the COPY line and every session in that image refuses with 69 instead of validating anything"
assert_contains "$out" "Found capability manifest at" \
  "preflight: the shipped layout finds the manifest rather than refusing, so the locator is genuinely present in the file list the image is built from"

# (b) A repository WITH a perfectly good manifest, locator removed. The tempting
#     failure is to report "no manifest present" and exit 0.
BROKEN_LIB="${WORK}/lib-without-locator"
cp -r "$SHIPPED_LIB" "$BROKEN_LIB"
rm -f "${BROKEN_LIB}/locate-manifest.js"
BROKEN_PREFLIGHT="${BROKEN_LIB}/squad-capability-preflight.sh"

good_repo="$(build_case "missing-locator-present" "regular" "squad-capabilities.yml")" || {
  echo "FAIL: manifest-path corpus: could not build the missing-locator case"
  exit 1
}
out="$(bash "$BROKEN_PREFLIGHT" "$good_repo" 2>&1)"
rc=$?
assert_eq "69" "$rc" \
  "preflight: a missing shared locator refuses the session (exit 69) -- if a Dockerfile edit un-ships locate-manifest.js, every session must stop rather than proceed on an unverified manifest path"
assert_not_contains "$out" "No capability manifest at" \
  "preflight: a missing shared locator is NOT reported as 'no manifest present' -- that downgrade is the fail-open this sprint exists to rule out"
assert_not_contains "$out" "skipping (safe default)" \
  "preflight: a missing shared locator does not take the safe-default skip path, which is the branch that would silently disable the gate"
assert_contains "$out" "locate-manifest.js" \
  "preflight: a missing shared locator names the file that is missing, so an operator can act on it without reading the source"
assert_contains "$out" "Refusing the session" \
  "preflight: a missing shared locator says plainly that the session was refused"

# (c) The same missing module, but the manifest path is UNSAFE. This is the
#     case that matters most: the outcome must not become "absent" or 0.
unsafe_repo="$(build_case "missing-locator-unsafe" "symlink-outside" "squad-capabilities.yml")" || {
  echo "FAIL: manifest-path corpus: could not build the missing-locator-unsafe case"
  exit 1
}
out="$(bash "$BROKEN_PREFLIGHT" "$unsafe_repo" 2>&1)"
rc=$?
assert_ne "0" "$rc" \
  "preflight: a missing shared locator still refuses an UNSAFE manifest path -- an incomplete image must never convert 'unsafe' into a passing session"
assert_eq "69" "$rc" \
  "preflight: a missing shared locator reports 69 (EX_UNAVAILABLE), distinct from 78, so an operator can tell 'your image is incomplete' from 'your manifest is wrong'"

# (d) The locator is PRESENT but broken. `node` exiting 1 used to be
#     indistinguishable from an unsafe verdict, because any non-zero meant
#     unsafe. It must now be its own refusal.
THROW_LIB="${WORK}/lib-with-broken-locator"
cp -r "$SHIPPED_LIB" "$THROW_LIB"
printf 'throw new Error("deliberately broken locator");\n' > "${THROW_LIB}/locate-manifest.js"
out="$(bash "${THROW_LIB}/squad-capability-preflight.sh" "$good_repo" 2>&1)"
rc=$?
assert_eq "69" "$rc" \
  "preflight: a locator that throws refuses the session rather than being read as a verdict -- under the old 'any non-zero means unsafe' scheme a broken module and a hostile path produced the same exit"

# (e) The locator claims "present" and names nothing. The preflight must not
#     hand an empty path to the parser.
EMPTY_LIB="${WORK}/lib-with-silent-locator"
cp -r "$SHIPPED_LIB" "$EMPTY_LIB"
printf 'process.exit(0);\n' > "${EMPTY_LIB}/locate-manifest.js"
out="$(bash "${EMPTY_LIB}/squad-capability-preflight.sh" "$good_repo" 2>&1)"
rc=$?
assert_eq "69" "$rc" \
  "preflight: a locator that exits 0 naming no path refuses the session -- exit 0 with empty stdout is exactly what a silently truncated or stubbed module produces"

# ---------------------------------------------------------------------------
# 4. The preflight's own framing, asserted rather than assumed.
# ---------------------------------------------------------------------------
# CAPABILITY_MANIFEST_PATH="" is NOT an empty path: `${VAR:-default}` falls back.
# This is why "empty relative path" reads as a disagreement in a naive corpus and
# is not one.
env_repo="$(build_case "env-default" "regular" "squad-capabilities.yml")"
out="$(CAPABILITY_MANIFEST_PATH="" bash "$PREFLIGHT" "$env_repo" 2>&1)"
rc=$?
assert_eq "0" "$rc" \
  "preflight: an EMPTY CAPABILITY_MANIFEST_PATH falls back to squad-capabilities.yml rather than reaching the shared logic as an empty string -- so the module's empty-path guard is unreachable from here, and its absence from this side is framing, not drift"
assert_contains "$out" "Found capability manifest at squad-capabilities.yml" \
  "preflight: the empty-variable fallback resolves the DEFAULT manifest, which is the behaviour an operator who unsets the variable depends on"

# ---------------------------------------------------------------------------
# 5. The resolver's decision still reports the unsafe verdict as such.
#    (Mutation M7: a resolver that swallowed 'unsafe' and treated it as 'absent'
#    would route a hostile manifest path to the ordinary no-manifest path.)
# ---------------------------------------------------------------------------
route_repo="$(build_case "resolver-decision" "regular" "squad-capabilities.yml")"
out="$(node "$RESOLVER_MODULE" "$route_repo" --catalog "$CATALOG" --manifest-path "../../../../etc/hostname" --pretty 2>&1)"
assert_contains "$out" '"reason": "manifest-path-unsafe"' \
  "resolver: an unsafe manifest path reports reason manifest-path-unsafe -- a resolver that reported 'absent' instead would route a traversal attempt down the ordinary no-manifest path and never fail closed"
assert_contains "$out" '"route": "fail-closed"' \
  "resolver: an unsafe manifest path fails closed rather than choosing a plane"

test_summary
