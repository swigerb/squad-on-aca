#!/usr/bin/env bash
# Issue #148: the worker image installs Squad from the official GitHub release
# bundle, pinned to a version AND a SHA-256, instead of from npm.
#
# This suite runs the REAL install RUN block, extracted from worker/Dockerfile
# (never a reimplementation), under /bin/sh exactly as `docker build` does, in
# a throwaway sandbox: absolute image paths (/opt, /tmp, /usr/local/bin) are
# rewritten into the sandbox, `curl` is a stub that "downloads" a locally built
# fake bundle, and `chown` is a recording no-op (the suite does not run as
# root). It proves:
#
#   1. A bundle whose SHA-256 matches SQUAD_SHA256 installs: the tree lands in
#      /opt/squad-<version>, /opt/squad points at it, `squad` is on PATH via
#      /usr/local/bin/squad, and `squad --version` reports SQUAD_VERSION.
#   2. CHECKSUM FAILURE PATH: a bundle whose bytes do not match SQUAD_SHA256
#      FAILS the RUN (non-zero exit) and is never extracted -- nothing lands
#      under /opt and no `squad` is linked onto PATH.
#   3. A bundle that matches the checksum but declares a different
#      squadVersion in BUNDLE-INFO.json fails the RUN.
#   4. The installed tree has every write bit stripped and is chowned
#      root:root (recorded), so the runtime users cannot modify it.
#   5. Static: the pinned ARGs are 1.0.1 / the published checksum, the
#      download goes to a FILE (never piped into a shell or into tar), and
#      `sha256sum -c` runs before `tar`.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
DOCKERFILE="${WORKER_DIR}/Dockerfile"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps sha256sum tar sed awk

echo "== Squad release-bundle install (issue #148) =="

[[ -f "$DOCKERFILE" ]] || { echo "FAIL: worker/Dockerfile is missing"; exit 1; }

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-release-install-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

SQUAD_VERSION_PIN="$(sed -n 's/^ARG SQUAD_VERSION=//p' "$DOCKERFILE" | head -n 1)"
SQUAD_SHA256_PIN="$(sed -n 's/^ARG SQUAD_SHA256=//p' "$DOCKERFILE" | head -n 1)"

# ---------------------------------------------------------------------------
# 5. Static shape of the pin and the RUN block.
# ---------------------------------------------------------------------------
echo "-- static: pins and RUN shape --"
assert_eq "1.0.1" "$SQUAD_VERSION_PIN" "worker/Dockerfile pins ARG SQUAD_VERSION=1.0.1"
assert_eq "283a1893be9ddad11056dcc8bd0673eff6b48a789bbf523b3f7ec31994d27ac7" "$SQUAD_SHA256_PIN" \
  "worker/Dockerfile pins ARG SQUAD_SHA256 to the squad-linux-x64.tar.gz checksum published in the v1.0.1 SHA256SUMS.txt"

# The RUN instruction that installs the bundle: from the line that opens it to
# the first line that does not end in a continuation backslash.
RUN_BLOCK="$(awk '
  /^RUN set -eu/ { grab = 1 }
  grab { print; if ($0 !~ /\\$/) exit }
' "$DOCKERFILE")"
assert_ne "" "$RUN_BLOCK" "the Squad install RUN block is present in worker/Dockerfile"
assert_contains "$RUN_BLOCK" 'releases/download/v${SQUAD_VERSION}/squad-linux-x64.tar.gz' \
  "the RUN block downloads the squad-linux-x64.tar.gz asset of the pinned release"
assert_not_contains "$(printf '%s' "$RUN_BLOCK" | grep -E 'curl[^|]*\|')" "curl" \
  "the download is never piped anywhere (no curl | sh, no curl | tar)"
sum_line="$(printf '%s\n' "$RUN_BLOCK" | grep -n 'sha256sum -c' | head -n 1 | cut -d: -f1)"
tar_line="$(printf '%s\n' "$RUN_BLOCK" | grep -n 'tar -xzf' | head -n 1 | cut -d: -f1)"
if [[ -n "$sum_line" && -n "$tar_line" && "$sum_line" -lt "$tar_line" ]]; then
  assert_eq "ok" "ok" "'sha256sum -c' runs BEFORE 'tar -xzf' -- nothing is extracted until the checksum passed"
else
  assert_eq "sha256sum before tar" "sum=${sum_line:-none} tar=${tar_line:-none}" \
    "'sha256sum -c' runs BEFORE 'tar -xzf' -- nothing is extracted until the checksum passed"
fi
assert_not_contains "$(grep -E '^[[:space:]]*&& npm install -g' "$DOCKERFILE")" "@bradygaster/squad-cli" \
  "worker/Dockerfile no longer installs @bradygaster/squad-cli from npm"

# ---------------------------------------------------------------------------
# Sandbox: the RUN body as /bin/sh would run it, with image paths rewritten.
# ---------------------------------------------------------------------------
# Strip the leading `RUN ` and the line continuations into one shell script.
run_script() {
  local root="$1"
  printf '%s\n' "$RUN_BLOCK" \
    | sed -e '1s/^RUN //' \
    | sed -e ':a' -e '/\\$/{N' -e 's/[[:space:]]*\\\n[[:space:]]*/ /' -e 'ba' -e '}' \
    | sed -e "s#/opt/#@SANDBOX@/opt/#g" -e "s#/usr/local/bin/#@SANDBOX@/usr/local/bin/#g" -e "s#/tmp/#@SANDBOX@/tmp/#g" \
    | sed -e "s#@SANDBOX@#${root}#g"
}

# A fake release bundle with the real layout: squad-linux-x64/{squad,BUNDLE-INFO.json,app,runtime}.
make_bundle() {
  local out="$1" declared_version="$2" src
  src="$(mktemp -d "${WORK}/bundle-src.XXXXXX")"
  mkdir -p "${src}/squad-linux-x64/app/node_modules/@bradygaster/squad-cli" "${src}/squad-linux-x64/runtime/bin"
  printf '{\n  "squadVersion": "%s",\n  "target": "linux-x64"\n}\n' "$declared_version" >"${src}/squad-linux-x64/BUNDLE-INFO.json"
  cat >"${src}/squad-linux-x64/squad" <<STUB
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then echo "${declared_version}"; exit 0; fi
exit 0
STUB
  chmod 0755 "${src}/squad-linux-x64/squad"
  tar -czf "$out" -C "$src" squad-linux-x64
}

# Runs the extracted RUN block in a fresh sandbox. $1 = sandbox name,
# $2 = path of the bundle the curl stub serves, $3 = SQUAD_SHA256 to build with.
run_install() {
  local name="$1" bundle="$2" sha="$3" root bin
  root="${WORK}/${name}"
  bin="${root}/stub-bin"
  mkdir -p "${root}/opt" "${root}/usr/local/bin" "${root}/tmp" "$bin"
  # curl stub: serve the local bundle to whatever `-o` names.
  cat >"${bin}/curl" <<STUB
#!/bin/sh
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$out" ] || exit 22
cp "${bundle}" "\$out"
STUB
  # chown stub: the suite is not root; record the request instead.
  cat >"${bin}/chown" <<STUB
#!/bin/sh
echo "\$*" >>"${root}/chown.log"
STUB
  chmod 0755 "${bin}/curl" "${bin}/chown"
  run_script "$root" >"${root}/run.sh"
  SQUAD_VERSION="$SQUAD_VERSION_PIN" SQUAD_SHA256="$sha" \
    PATH="${bin}:${root}/usr/local/bin:${PATH}" \
    /bin/sh "${root}/run.sh" >"${root}/out.log" 2>&1
  echo "$?"
}

GOOD_BUNDLE="${WORK}/good.tar.gz"
make_bundle "$GOOD_BUNDLE" "$SQUAD_VERSION_PIN"
GOOD_SHA="$(sha256sum "$GOOD_BUNDLE" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# 1 + 4. Matching checksum: installs, links, reports the version, read-only.
# ---------------------------------------------------------------------------
echo "-- matching checksum installs --"
rc="$(run_install good "$GOOD_BUNDLE" "$GOOD_SHA")"
ROOT="${WORK}/good"
assert_eq "0" "$rc" "a bundle whose SHA-256 matches SQUAD_SHA256 installs (RUN exits 0) -- $(tail -n 3 "${ROOT}/out.log" 2>/dev/null | tr '\n' ' ')"
assert_eq "yes" "$([[ -f "${ROOT}/opt/squad-${SQUAD_VERSION_PIN}/BUNDLE-INFO.json" ]] && echo yes || echo no)" \
  "the bundle is extracted into /opt/squad-<version>"
assert_eq "${ROOT}/opt/squad-${SQUAD_VERSION_PIN}" "$(readlink "${ROOT}/opt/squad")" \
  "/opt/squad points at the versioned install"
assert_eq "yes" "$([[ -L "${ROOT}/usr/local/bin/squad" ]] && echo yes || echo no)" \
  "squad is linked onto PATH at /usr/local/bin/squad"
assert_eq "$SQUAD_VERSION_PIN" "$("${ROOT}/usr/local/bin/squad" --version)" \
  "squad on PATH reports SQUAD_VERSION"
assert_eq "no" "$([[ -e "${ROOT}/tmp/squad-linux-x64.tar.gz" ]] && echo yes || echo no)" \
  "the downloaded archive is removed after a successful install"
writable="$(find "${ROOT}/opt/squad-${SQUAD_VERSION_PIN}" -perm /222 2>/dev/null | head -n 1)"
assert_eq "" "$writable" "every write bit is stripped from the installed tree (chmod -R a-w)"
assert_contains "$(cat "${ROOT}/chown.log" 2>/dev/null)" "-R root:root ${ROOT}/opt/squad-${SQUAD_VERSION_PIN}" \
  "the installed tree is chowned root:root"

# ---------------------------------------------------------------------------
# 2. Checksum failure path: refuses, extracts nothing, links nothing.
# ---------------------------------------------------------------------------
echo "-- checksum mismatch fails the build --"
TAMPERED="${WORK}/tampered.tar.gz"
cp "$GOOD_BUNDLE" "$TAMPERED"
printf 'tampered' >>"$TAMPERED"
rc="$(run_install tampered "$TAMPERED" "$GOOD_SHA")"
ROOT="${WORK}/tampered"
assert_ne "0" "$rc" "a bundle whose bytes do not match SQUAD_SHA256 FAILS the RUN (and so the image build)"
assert_contains "$(cat "${ROOT}/out.log")" "FAILED" "sha256sum reports the mismatch"
assert_eq "no" "$([[ -e "${ROOT}/opt/squad-${SQUAD_VERSION_PIN}/squad" ]] && echo yes || echo no)" \
  "a tampered bundle is never extracted"
assert_eq "no" "$([[ -e "${ROOT}/usr/local/bin/squad" || -L "${ROOT}/usr/local/bin/squad" ]] && echo yes || echo no)" \
  "a tampered bundle never puts squad on PATH"

rc="$(run_install wrongsum "$GOOD_BUNDLE" "0000000000000000000000000000000000000000000000000000000000000000")"
assert_ne "0" "$rc" "a SQUAD_SHA256 that does not match the downloaded bundle FAILS the RUN"

# ---------------------------------------------------------------------------
# 3. Checksum matches, but the bundle declares another version: refused.
# ---------------------------------------------------------------------------
echo "-- version mismatch fails the build --"
OTHER_BUNDLE="${WORK}/other.tar.gz"
make_bundle "$OTHER_BUNDLE" "9.9.9"
OTHER_SHA="$(sha256sum "$OTHER_BUNDLE" | awk '{print $1}')"
rc="$(run_install otherversion "$OTHER_BUNDLE" "$OTHER_SHA")"
assert_ne "0" "$rc" "a bundle whose BUNDLE-INFO.json declares a different squadVersion FAILS the RUN"
assert_eq "no" "$([[ -e "${WORK}/otherversion/usr/local/bin/squad" || -L "${WORK}/otherversion/usr/local/bin/squad" ]] && echo yes || echo no)" \
  "a bundle with the wrong declared version never puts squad on PATH"

test_summary
