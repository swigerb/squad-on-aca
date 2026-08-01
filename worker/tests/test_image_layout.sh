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
# (= repository root) relative sources.
COPY_RECORDS=()
COPY_SOURCES=()
parse_dockerfile_copies() {
  local line token dest
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
    for token in "${tokens[@]:1}"; do
      case "$token" in
        --from=*) die "a COPY instruction copies from another build stage (--from=); its source is not a context file" ;;
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
if [[ "${1:-}" == "containerapp" && "${2:-}" == "job" && "${3:-}" == "start" ]]; then
  echo "start" >> "${AZ_START_LOG}"
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
export GITHUB_REPOSITORY="octo/demo"
export RALPH_DISPATCH_LABEL="squad-aca:dispatched"
export RALPH_SESSION_JOB_IMAGE="example.azurecr.io/squad-worker:latest"
export RALPH_SESSION_JOB_CPU="1.0"
export RALPH_SESSION_JOB_MEMORY="2.0Gi"
export RALPH_SESSION_JOB_CONTAINER="squad-worker"
export RALPH_SESSION_JOB_ENV_JSON='[{"name":"ASPIRE_OTLP_GRPC_ENDPOINT","value":"http://ca-squad-aspire:18889"}]'

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
