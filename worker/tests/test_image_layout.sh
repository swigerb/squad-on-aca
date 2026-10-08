#!/usr/bin/env bash
# Behavioural tests for the SHIPPED IMAGE LAYOUT.
#
# WHY THIS SUITE EXISTS
# ---------------------
# Every other routing assertion in this repository runs against the repository
# tree, and every one of them passes `--catalog "$CATALOG"` explicitly or
# exports SQUAD_DISPATCH_CLI at a repo-relative path. Production does neither.
# Ralph (`SQUAD_MODE=ralph`, an ACA cron job on */5) runs INSIDE the worker image
# and calls `squad-dispatch.js decide` with no catalog flag at all, so the only
# thing that can find the administrator catalog is
# catalogSearchPaths()[0] == <__dirname>/sandbox-classes.json.
#
# That file was not in the image. `decide` exited 70 with
# reason "catalog-unavailable" on every candidate issue, ralph-dispatch.sh logged
# "routing refused or unavailable ... skipping without labeling", and the job
# reported success having dispatched nothing. 911 assertions passed throughout.
# See docs/adr/0003-capability-manifest-future-work.md, finding 1.
#
# So this suite refuses to look at worker/lib at all. It builds a throwaway
# directory that mirrors the image and runs the shipped entry points from there.
#
# THE LAYOUT IS DERIVED FROM THE DOCKERFILE, NEVER HARD-CODED
# ----------------------------------------------------------
# The file list is parsed out of worker/Dockerfile's own COPY instructions. With
# a hard-coded list, deleting `config/sandbox-classes.json` from the COPY line
# would leave this suite green while shipping exactly the broken image it exists
# to catch -- the test would be decorative. Deriving it means the mutation
# "remove it from COPY" removes it from the layout too, and the behavioural
# assertion fails.
#
# The parser is deliberately STRICT AND LOUD. If it meets a COPY form it does not
# understand (line continuation, JSON-array form, --from= from another build
# stage) it aborts the suite non-zero. It never falls back to a built-in list: a
# silent fallback would reintroduce the very defect this suite closes.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WORKER_DIR}/.." && pwd)"
DOCKERFILE="${WORKER_DIR}/Dockerfile"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node mktemp date sed

echo "== shipped image layout =="

# Outside the repository on purpose: nothing below may resolve a repo-relative
# path by accident, which is the whole point of the suite.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/squad-image-layout.XXXXXXXX")" || {
  echo "FAIL: could not create a work directory"
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM

die() {
  # A parse failure is a SUITE failure, never a skip and never a fallback.
  echo "FAIL: image layout: ${1}"
  echo "      worker/Dockerfile could not be parsed, so the shipped file list is unknown."
  echo "      Refusing to test a guessed layout -- fix the parser or the Dockerfile."
  exit 1
}

# --- Parse the Dockerfile COPY instructions ---------------------------------
# Emits one "<dest>\t<src> [<src>...]" record per COPY, with build-context
# (= repository root) relative sources. COPY_CHOWNS is a PARALLEL array (same
# index as COPY_RECORDS) carrying that COPY's `--chown=` value, or "" when the
# instruction has none -- added for F1 (security-review-112-113.md): the
# ownership a COPY assigns is exactly what that review found broken, so this
# suite must be able to see it without guessing a layout.
COPY_RECORDS=()
COPY_SOURCES=()
COPY_CHOWNS=()
parse_dockerfile_copies() {
  local line token dest chown
  local -a tokens args srcs

  [[ -f "$DOCKERFILE" ]] || die "worker/Dockerfile is missing"

  while IFS= read -r line; do
    # Normalise a CRLF checkout so a Windows working tree parses identically.
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*COPY[[:space:]] ]] || continue
    [[ "$line" == *'\' ]] && die "a COPY instruction uses a line continuation, which this parser does not implement"
    [[ "$line" == *'['* ]] && die "a COPY instruction uses the JSON-array form, which this parser does not implement"

    read -r -a tokens <<< "$line"
    args=()
    chown=""
    for token in "${tokens[@]:1}"; do
      case "$token" in
        --from=*) die "a COPY instruction copies from another build stage (--from=); its source is not a context file" ;;
        --chown=*) chown="${token#--chown=}" ;;
        --*) continue ;;
        *) args+=("$token") ;;
      esac
    done
    (( ${#args[@]} >= 2 )) || die "a COPY instruction has fewer than two path operands"

    dest="${args[-1]}"
    srcs=("${args[@]:0:${#args[@]}-1}")
    [[ "$dest" == /* ]] || die "COPY destination '${dest}' is not absolute; the layout root would be ambiguous"
    if [[ "$dest" != */ && "${#srcs[@]}" -gt 1 ]]; then
      die "a COPY instruction has several sources but a file (not directory) destination"
    fi

    COPY_RECORDS+=("$(printf '%s\t%s' "$dest" "${srcs[*]}")")
    COPY_CHOWNS+=("$chown")
    COPY_SOURCES+=("${srcs[@]}")
  done < "$DOCKERFILE"

  (( ${#COPY_RECORDS[@]} > 0 )) || die "no COPY instruction was found at all"
}

# --- Materialise the layout --------------------------------------------------
# `root` becomes an image-shaped filesystem: root/usr/local/bin/...,
# root/usr/local/lib/squad-on-aca/...
build_layout() {
  local root="$1" record dest src target
  local -a srcs

  for record in "${COPY_RECORDS[@]}"; do
    dest="${record%%$'\t'*}"
    read -r -a srcs <<< "${record#*$'\t'}"
    for src in "${srcs[@]}"; do
      [[ -f "${REPO_ROOT}/${src}" ]] || die "COPY names '${src}', which does not exist in the build context (${REPO_ROOT}); the image build would fail"
      if [[ "$dest" == */ ]]; then
        target="${root}${dest}$(basename "$src")"
      else
        target="${root}${dest}"
      fi
      mkdir -p "$(dirname "$target")" || die "could not create $(dirname "$target")"
      cp "${REPO_ROOT}/${src}" "$target" || die "could not stage ${src}"
    done
  done

  # The Dockerfile's `sed -i 's/\r$//'` + `chmod +x` pass. Applied to every shell
  # script rather than re-parsing the RUN line: line endings and the exec bit are
  # not what this suite is testing, and a Windows checkout must not turn a
  # packaging assertion into a shell syntax error.
  find "$root" -type f -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
  find "$root" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
  if [[ -d "${root}/usr/local/bin" ]]; then
    find "${root}/usr/local/bin" -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    find "${root}/usr/local/bin" -type f -exec chmod +x {} + 2>/dev/null || true
  fi
  # worker/squad-agent (issue #112) is NOT caught by either pass above: it has
  # no `.sh` extension (it is invoked as an opaque `--agent-cmd`, the same
  # calling convention as `copilot` itself, which also carries no extension)
  # and it does not live under usr/local/bin. The real Dockerfile's
  # sed/chmod RUN line names it explicitly for exactly this reason; this
  # throwaway layout must do the same or it would silently diverge from what
  # actually ships.
  if [[ -f "${root}/usr/local/lib/squad-on-aca/squad-agent" ]]; then
    sed -i 's/\r$//' "${root}/usr/local/lib/squad-on-aca/squad-agent" 2>/dev/null || true
    chmod +x "${root}/usr/local/lib/squad-on-aca/squad-agent" 2>/dev/null || true
  fi
}

parse_dockerfile_copies

IMAGE_ROOT="${WORK}/image"
IMAGE_LIB="${IMAGE_ROOT}/usr/local/lib/squad-on-aca"
build_layout "$IMAGE_ROOT"

# A parse that silently found nothing would make every assertion below vacuous.
assert_eq "1" "$([[ "${#COPY_SOURCES[@]}" -ge 10 ]] && echo 1 || echo 0)" \
  "image layout: the Dockerfile COPY list parsed to ${#COPY_SOURCES[@]} source files (a parse that found nothing would make every assertion below vacuous)"
assert_eq "1" "$([[ -f "${IMAGE_LIB}/squad-dispatch.js" ]] && echo 1 || echo 0)" \
  "image layout: squad-dispatch.js is staged at /usr/local/lib/squad-on-aca, the path ralph-dispatch.sh resolves in the image"

# --- T9 (issue #86): the process-isolation probe is shipped in the image ----
# Derived from the same COPY-line parse as everything above -- deleting the
# probe from the Dockerfile's COPY line removes it from this throwaway layout
# too, exactly like squad-dispatch.js above.
assert_eq "1" "$([[ -f "${IMAGE_LIB}/proc-isolation-probe.sh" ]] && echo 1 || echo 0)" \
  "image layout (T9): worker/lib/proc-isolation-probe.sh is staged at /usr/local/lib/squad-on-aca, the path worker/entrypoint.sh sources in the image"
assert_eq "1" "$([[ -x "${IMAGE_LIB}/proc-isolation-probe.sh" ]] && echo 1 || echo 0)" \
  "image layout (T9): the staged proc-isolation-probe.sh has the executable bit set by the Dockerfile's chmod pass"
probe_line_endings="$(grep -c $'\r' "${IMAGE_LIB}/proc-isolation-probe.sh" || true)"
assert_eq "0" "$probe_line_endings" \
  "image layout (T9): the staged proc-isolation-probe.sh has CRLF line endings normalised away by the Dockerfile's sed pass"

# ---------------------------------------------------------------------------
# F1 (security-review-112-113.md, CRITICAL, REJECTED #112): squad-agent (and
# everything else shipped under /usr/local/lib/squad-on-aca and
# /usr/local/bin/squad-on-aca) must be ROOT-owned and NOT writable by the
# `squad` user it is executed as -- otherwise `squad` can rewrite its own
# `--agent-cmd` leash and `squad watch`/`squad loop` re-exec the rewritten
# file on every spawn for the life of the container, with no governance
# detector ever seeing it (the path is outside .squad/).
#
# This suite cannot run the Dockerfile's COPY under a real root/squad UID
# split (it is not run inside the image, by design -- see the suite header),
# so ownership is asserted the same way every other packaging fact in this
# suite is: parsed directly out of the Dockerfile text, so a regression
# (reverting to --chown=squad:squad) fails this suite rather than silently
# shipping. The write-bit removal, by contrast, IS run for real below: the
# exact `chmod -R a-w ...` command is extracted from the Dockerfile and
# applied to the materialised throwaway layout, and the resulting file modes
# are asserted with a real `stat`, not inferred from the Dockerfile text.
find_copy_chown() {
  # Finds the --chown= value of the (single) COPY_RECORDS entry whose dest
  # matches exactly, or whose dest is a directory prefix of it.
  local want="$1" i dest
  for i in "${!COPY_RECORDS[@]}"; do
    dest="${COPY_RECORDS[$i]%%$'\t'*}"
    if [[ "$dest" == "$want" ]]; then
      printf '%s' "${COPY_CHOWNS[$i]}"
      return 0
    fi
  done
  printf ''
  return 1
}

bin_chown="$(find_copy_chown "/usr/local/bin/squad-on-aca")"
lib_chown="$(find_copy_chown "/usr/local/lib/squad-on-aca/")"
assert_eq "root:root" "$bin_chown" \
  "image layout (F1): the COPY that stages /usr/local/bin/squad-on-aca uses --chown=root:root, not --chown=squad:squad -- squad must not own the entrypoint it executes"
assert_eq "root:root" "$lib_chown" \
  "image layout (F1): the COPY that stages /usr/local/lib/squad-on-aca/ uses --chown=root:root, not --chown=squad:squad -- squad must not own squad-agent, the --agent-cmd leash it is executed through on every watch/loop spawn"

# Extract the real `chmod -R a-w ...` command this Dockerfile ships (rather
# than hand-writing an equivalent one here, which could pass while the real
# RUN line regressed) and apply it to the materialised layout.
# Issue #148: the Squad release bundle has its OWN `chmod -R a-w` pass (over
# /opt/squad-<version>, asserted by test_squad_release_install.sh), so select the
# one over the shipped squad-on-aca paths rather than whichever comes first.
chmod_line="$(grep -o 'chmod -R a-w [^&]*' "$DOCKERFILE" | grep 'squad-on-aca' | head -1)"
chmod_line="${chmod_line%$'\r'}"
assert_ne "" "$chmod_line" \
  "image layout (F1): the Dockerfile's RUN block contains a 'chmod -R a-w' pass over the shipped squad-on-aca paths"
assert_contains "$chmod_line" "/usr/local/lib/squad-on-aca" \
  "image layout (F1): the chmod -R a-w pass covers /usr/local/lib/squad-on-aca"
assert_contains "$chmod_line" "/usr/local/bin/squad-on-aca" \
  "image layout (F1): the chmod -R a-w pass covers /usr/local/bin/squad-on-aca"

if [[ -n "$chmod_line" ]]; then
  # Rewrite the two absolute paths onto the throwaway root and actually run
  # the command -- this is the real chmod, not a reimplementation of it.
  real_chmod_cmd="${chmod_line//\/usr\/local\/lib\/squad-on-aca/${IMAGE_ROOT}/usr/local/lib/squad-on-aca}"
  real_chmod_cmd="${real_chmod_cmd//\/usr\/local\/bin\/squad-on-aca/${IMAGE_ROOT}/usr/local/bin/squad-on-aca}"
  bash -c "$real_chmod_cmd" || die "the extracted chmod -R a-w command failed to run against the materialised layout"
fi

no_write_bit() {
  # "no write bit for owner, group, OR other" -- true root-ownership in the
  # real image additionally means `squad` (neither the owning user nor its
  # group) only ever sees the "other" bits, but this assertion is stricter:
  # it holds regardless of who ends up owning the file, which is exactly the
  # belt-and-suspenders property the Dockerfile's comment above the RUN line
  # describes.
  local path="$1" mode
  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)"
  [[ -n "$mode" ]] || return 1
  # Any of the three write bits (0200 owner, 0020 group, 0002 other) being
  # set anywhere in the mode fails this check.
  (( (8#$mode & 8#222) == 0 ))
}

for f in "${IMAGE_LIB}/squad-agent" "${IMAGE_LIB}/sandbox-classes.json" "${IMAGE_LIB}/agent-policy.js" "${IMAGE_ROOT}/usr/local/bin/squad-on-aca"; do
  assert_eq "1" "$([[ -f "$f" ]] && no_write_bit "$f" && echo 1 || echo 0)" \
    "image layout (F1): $(basename "$f") has no write bit set for owner, group, or other after the Dockerfile's real chmod -R a-w pass runs -- squad cannot rewrite it even though it can read/execute it"
done
probe_source_output="$(bash -c "source '${IMAGE_LIB}/proc-isolation-probe.sh'; squad_proc_iso_line" 2>&1)"
assert_contains "$probe_source_output" "SQUAD-PROC-ISO v1" \
  "image layout (T9): the shipped proc-isolation-probe.sh, sourced from its staged path, actually runs and emits the documented line"

# --- The environment production actually runs in ------------------------------
# Nothing here may hand the dispatcher a catalog. Ralph does not, and that is the
# entire defect. `cd` is outside the repository so no repo-relative fallback can
# resolve either.
OUTSIDE="${WORK}/elsewhere"
mkdir -p "$OUTSIDE"
unset SQUAD_SANDBOX_CLASS_CATALOG
unset SQUAD_DISPATCH_CLI

# ONE invocation helper, used by BOTH the success case and the missing-catalog
# case. Adding an override here would make the missing-catalog case stop failing,
# so the pair is self-guarding: a decorative version of this suite cannot pass
# both assertions at once.
decide_from_layout() {
  local lib="$1"
  ( cd "$OUTSIDE" && node "${lib}/squad-dispatch.js" decide \
      --session-id s-one --dispatch-source ralph --repository octo/demo 2>&1 )
}

# ---------------------------------------------------------------------------
# 1. THE ACCEPTANCE CRITERION. The shipped layout resolves a real route with no
#    catalog flag and no SQUAD_SANDBOX_CLASS_CATALOG.
# ---------------------------------------------------------------------------
out="$(decide_from_layout "$IMAGE_LIB")"
rc=$?
assert_eq "0" "$rc" \
  "image layout: decide exits 0 from the shipped layout with no --catalog (a non-zero exit is what made every Ralph cron run skip every issue)"
assert_contains "$out" '"route":"aca-job"' \
  "image layout: decide resolves a route with no --catalog -- Ralph passes none, so without the packaged catalog every scheduled dispatch is refused and silently dropped"
assert_contains "$out" '"action":"dispatch"' \
  "image layout: the resolved decision says dispatch, not refuse, so compute is actually requested"
assert_not_contains "$out" 'catalog-unavailable' \
  "image layout: the shipped layout does not report catalog-unavailable"

# ---------------------------------------------------------------------------
# 2. THE OTHER DIRECTION. Assertion 1 is only meaningful if failure is still
#    possible: a resolver that fabricated a default catalog, or a test that
#    quietly passed one in, would satisfy assertion 1 without proving anything.
#    Same layout, same invocation helper, packaged catalog removed.
# ---------------------------------------------------------------------------
NOCAT_ROOT="${WORK}/image-without-catalog"
build_layout "$NOCAT_ROOT"
NOCAT_LIB="${NOCAT_ROOT}/usr/local/lib/squad-on-aca"
rm -f "${NOCAT_LIB}/sandbox-classes.json"
out="$(decide_from_layout "$NOCAT_LIB")"
rc=$?
assert_eq "70" "$rc" \
  "image layout: a missing packaged catalog still exits 70 with catalog-unavailable -- if this passes while assertion 1 also passes, assertion 1 is load-bearing rather than fabricated"
assert_contains "$out" 'catalog-unavailable' \
  "image layout: a layout with no packaged catalog names catalog-unavailable as the reason"

# ---------------------------------------------------------------------------
# 3. END TO END, THE BEHAVIOUR THAT IS DEAD TODAY. The real
#    ralph_dispatch_issue, sourced FROM THE SHIPPED LAYOUT so squad_dispatch_cli()
#    resolves its default the way it does in the image, with the existing fake
#    `az`/`gh`. It must start compute exactly once and label exactly once.
# ---------------------------------------------------------------------------
FAKE_BIN="${WORK}/bin"
mkdir -p "$FAKE_BIN"

cat > "${FAKE_BIN}/az" <<'AZ'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "account" && "${2:-}" == "show" ]]; then
  printf '%s\n' "${AZ_ACCOUNT_SHOW_JSON:?}"
  exit 0
fi
if [[ "${1:-}" != "rest" ]]; then
  exit 0
fi
shift
method=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method) method="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$method" == "get" ]]; then
  printf '%s' "${AZ_JOB_SHOW_JSON:?}"
  exit 0
fi
if [[ "$method" == "post" ]]; then
  echo "start" >> "${AZ_START_LOG}"
  printf '{"name":"stub-exec-001"}'
  exit 0
fi
exit 0
AZ

cat > "${FAKE_BIN}/gh" <<'GH'
#!/usr/bin/env bash
exec node "${FAKE_GH_JS}" "$@"
GH

chmod +x "${FAKE_BIN}/az" "${FAKE_BIN}/gh"
PATH="${FAKE_BIN}:${PATH}"

export FAKE_GH_JS="${TEST_DIR}/lib/fake-gh.js"
export SQUAD_GH_BIN="$FAKE_GH_JS"
export FAKE_GH_STATE="${WORK}/ghstate"
export AZ_START_LOG="${WORK}/az-start.log"
export GH_LABEL_LOG="${WORK}/gh-label.log"
export SQUAD_LEASE_NOW="2024-05-01T00:00:00.000Z"
export SQUAD_LEASE_TTL_SECONDS="3600"
mkdir -p "$FAKE_GH_STATE"
: > "$AZ_START_LOG"
: > "$GH_LABEL_LOG"

export ACA_SESSION_JOB_NAME="caj-squad-aca-session"
export AZURE_RESOURCE_GROUP="rg-squad-test"
export AZURE_SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
export GITHUB_REPOSITORY="octo/demo"
export RALPH_DISPATCH_LABEL="squad-aca:dispatched"
export RALPH_SESSION_JOB_IMAGE="example.azurecr.io/squad-worker:latest"
export RALPH_SESSION_JOB_CPU="1.0"
export RALPH_SESSION_JOB_MEMORY="2.0Gi"
export RALPH_SESSION_JOB_CONTAINER="squad-worker"
export RALPH_SESSION_JOB_ENV_JSON='[{"name":"ASPIRE_OTLP_GRPC_ENDPOINT","value":"http://ca-squad-aspire:18889"}]'
export RALPH_SESSION_JOB_DEFINITION_JSON='{"properties":{"template":{"containers":[{"name":"squad-worker","image":"example.azurecr.io/squad-worker:latest","resources":{"cpu":1,"memory":"2.0Gi"},"env":[{"name":"ASPIRE_OTLP_GRPC_ENDPOINT","value":"http://ca-squad-aspire:18889"},{"name":"SESSION_NAME","value":"smoke-template"}]}]}}}'
export AZ_JOB_SHOW_JSON="$RALPH_SESSION_JOB_DEFINITION_JSON"
export AZ_ACCOUNT_SHOW_JSON="{\"id\":\"${AZURE_SUBSCRIPTION_ID}\"}"

# Sourced from the LAYOUT, not from worker/lib. squad_dispatch_cli() falls back
# to "$(dirname "${BASH_SOURCE[0]}")/squad-dispatch.js", so this is the only way
# to exercise the resolution the image performs. SQUAD_DISPATCH_CLI stays unset
# on purpose: setting it is what let every existing suite pass while the image
# was broken.
# shellcheck source=/dev/null
source "${IMAGE_LIB}/ralph-dispatch.sh"

out="$(cd "$OUTSIDE" && ralph_dispatch_issue 7 "Ship the catalog" "https://example/seven" 2>&1)"
rc=$?
assert_eq "0" "$rc" \
  "image layout: ralph dispatches from the shipped layout (exit 0)"
assert_eq "1" "$(grep -c '^start$' "$AZ_START_LOG")" \
  "image layout: ralph dispatches from the shipped layout -- compute started exactly once, which is the end-to-end behaviour that has never fired in production"
assert_eq "1" "$(grep -c '^7$' "$GH_LABEL_LOG")" \
  "image layout: ralph labels the dispatched issue exactly once from the shipped layout"
assert_not_contains "$out" "routing refused or unavailable" \
  "image layout: ralph does not log the refusal message that a catalog-less image produced on every run"

test_summary
