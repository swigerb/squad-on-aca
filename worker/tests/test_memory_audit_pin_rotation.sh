#!/usr/bin/env bash
# Issue #113 (follow-up), R-CI split: the real-SDK-heavy halves of
# test_memory_audit_pin_publication.sh, in their own suite.
#
# Security's re-review (.squad/decisions/inbox/security-pin-seal-rereview.md,
# finding R-CI) measured the combined suite at 112s / 147s against
# run-tests.sh's hard 120s per-suite kill (worker/tests/run-tests.sh:~59),
# with .github/workflows/worker-tests.yml failing the job on ANY skip -- a
# guaranteed red build on a slower CI runner. The two expensive scenarios are
# both genuine 1100-call loops against the REAL @bradygaster/squad-sdk 0.13.1
# (not a mock of its rotation logic): scenario (d) runs the loop TWICE
# (hardened subject + unhardened control) and scenario (e4) runs it a third
# time after `git clean -fdx`. Splitting them into this file, rather than
# reducing the call count or raising the timeout, keeps both suites
# comfortably under budget while preserving exactly what each loop proves:
# the rotation threshold (1048576 bytes) is genuinely exceeded, and the
# control genuinely rotates.
#
# See test_memory_audit_pin_publication.sh's header for the full picture of
# what this fix does and does not guarantee. This file proves only:
#
#   (d) against the REAL @bradygaster/squad-sdk 0.13.1 shipped by worker/
#       Dockerfile: 1100 real LocalMemoryStore.audit() calls against a
#       hardened repository never produce an `audit.1.jsonl`, and the SAME
#       loop against an UNHARDENED repository (the control) DOES rotate --
#       so the hardened case's absence of rotation is evidence, not a fluke
#       of the harness.
#   (e4) Finding 3: `git clean -fdx` deletes the ignored (untracked) pin. The
#       sampler re-pins it, rotation stays off under 1100 further real SDK
#       audits, and the deletion is REPORTED (git hygiene), not a violation.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SQUAD_POLICY_SH="${WORKER_DIR}/lib/squad-policy.sh"

# shellcheck source=lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=lib/deps.sh
source "${TEST_DIR}/lib/deps.sh"
require_deps node git sha256sum

echo "== memory-audit-pin rotation under the real squad-sdk (issue #113 follow-up, R-CI split) =="

[[ -f "$SQUAD_POLICY_SH" ]] || { echo "FAIL: worker/lib/squad-policy.sh is missing"; exit 1; }

# Same posture as test_governance_guard.sh / test_memory_audit_pin_publication.sh:
# the preventive half of this fix is POSIX mode bits (squad_policy_harden's
# `chmod -R a-w`), which root ignores. A run as root cannot answer "is the
# seal real?", so it reports a skip rather than a pass.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: test_memory_audit_pin_rotation.sh — running as root, mode bits are not enforced against uid 0"
  exit 77
fi

# ---------------------------------------------------------------------------
# Locate the REAL @bradygaster/squad-sdk 0.13.1. SQUAD_SDK_DIR is what CI sets
# (see .github/workflows/worker-tests.yml); locally, the nested copy
# squad-cli@0.13.1 ships is used as a fallback. Neither present, or the wrong
# major.minor, is a genuine missing dependency -- same posture as
# lib/deps.sh: report a visible SKIP, never a silent pass that proves less
# than this suite claims. (Duplicated from test_memory_audit_pin_publication.sh
# rather than shared, so each suite stays independently runnable.)
locate_sdk() {
  local candidate base
  if [[ -n "${SQUAD_SDK_DIR:-}" && -f "${SQUAD_SDK_DIR}/dist/memory/index.js" && -f "${SQUAD_SDK_DIR}/dist/storage/fs-storage-provider.js" ]]; then
    printf '%s' "$SQUAD_SDK_DIR"
    return 0
  fi
  # Issue #148: the worker image installs Squad from the release bundle at
  # /opt/squad (worker/Dockerfile), so that is the first local fallback.
  candidate="/opt/squad/app/node_modules/@bradygaster/squad-sdk"
  if [[ -f "${candidate}/dist/memory/index.js" && -f "${candidate}/dist/storage/fs-storage-provider.js" ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  base="$(npm root -g 2>/dev/null)" || base=""
  if [[ -n "$base" ]]; then
    # A Windows-style path (e.g. under Git Bash or WSL's interop npm) needs
    # translating to the path this bash actually sees.
    if [[ "$base" =~ ^[A-Za-z]: ]] && command -v wslpath >/dev/null 2>&1; then
      base="$(wslpath -u "$base" 2>/dev/null)" || base=""
    fi
    for candidate in \
      "${base}/@bradygaster/squad-cli/node_modules/@bradygaster/squad-sdk" \
      "${base}/@bradygaster/squad-sdk"
    do
      if [[ -n "$base" && -f "${candidate}/dist/memory/index.js" && -f "${candidate}/dist/storage/fs-storage-provider.js" ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  fi
  return 1
}

SDK_DIR=""
if SDK_DIR="$(locate_sdk)"; then
  SDK_VERSION="$(node -e 'console.log(require(require("path").join(process.argv[1], "package.json")).version)' "$SDK_DIR" 2>/dev/null || true)"
  # Issue #148: lockstep with what worker/Dockerfile actually ships (its
  # SQUAD_VERSION ARG), not a hard-coded version that could silently drift.
  EXPECTED_SQUAD_VERSION="$(sed -n 's/^ARG SQUAD_VERSION=//p' "${WORKER_DIR}/Dockerfile" | head -n 1)"
  if [[ -z "$EXPECTED_SQUAD_VERSION" || "$SDK_VERSION" != "$EXPECTED_SQUAD_VERSION" ]]; then
    echo "SKIP: test_memory_audit_pin_rotation.sh — @bradygaster/squad-sdk at ${SDK_DIR} is '${SDK_VERSION:-unknown}', not ${EXPECTED_SQUAD_VERSION:-<unknown>} (the version worker/Dockerfile ships); this suite needs the real rotation logic this pin relies on"
    exit 77
  fi
else
  echo "SKIP: test_memory_audit_pin_rotation.sh — the @bradygaster/squad-sdk that worker/Dockerfile ships was not found (set SQUAD_SDK_DIR to <bundle>/app/node_modules/@bradygaster/squad-sdk, or see .github/workflows/worker-tests.yml for how CI installs it)"
  exit 77
fi

WORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/squad-pin-rotation-test.XXXXXXXXXXXX")" || {
  echo "FAIL: could not create a private work directory"
  exit 1
}
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
git config --global init.defaultBranch main >/dev/null 2>&1 || true
git config --global user.name "Test" >/dev/null 2>&1 || true
git config --global user.email "test@example.com" >/dev/null 2>&1 || true

git_quiet() { git -c advice.detachedHead=false "$@" >/dev/null 2>&1; }

# A plain (no remote) repository, for the real-SDK rotation tests, neither of
# which pushes anywhere. Identical to test_memory_audit_pin_publication.sh's
# make_repo.
make_repo() {
  local repo="$1" tracked="$2"
  rm -rf "$repo"; mkdir -p "$repo"
  git_quiet init "$repo"
  (
    cd "$repo"
    mkdir -p .squad/policies src
    echo "security policy" >.squad/policies/security.md
    echo "original work" >src/app.js
    if [[ "$tracked" == 1 ]]; then
      mkdir -p .squad/memory
      printf '{\n  "policy": {\n    "auditMaxBytes": 1048576,\n    "auditMaxArchives": 3\n  }\n}\n' >.squad/memory/config.json
    fi
    git add -A
    git commit -q -m baseline
  ) >/dev/null 2>&1
}

# Run one scenario in a subshell so a squad_policy_abort (exit 78) is captured
# instead of taking the whole suite down with it. Same idiom as
# test_governance_guard.sh's / test_memory_audit_pin_publication.sh's
# scenario()/policy_scenario().
#   policy_scenario <repo> <state-dir> <shell-body>
policy_scenario() {
  local repo="$1" state="$2" body="$3"
  (
    export SQUAD_MODE="ralph" SQUAD_DISPATCH_SOURCE="ralph" SESSION_NAME="test"
    export SQUAD_POLICY_STATE_DIR="$state"
    export SQUAD_POLICY_RESOLVER="${WORKER_DIR}/lib/agent-policy.js"
    # shellcheck source=/dev/null
    source "$SQUAD_POLICY_SH"
    eval "$body"
  ) 2>&1
}

PIN=".squad/memory/config.json"
STATE_E="${WORK}/state-e"

# ===========================================================================
# (d) REAL SDK: 1100 real audit() calls against the real squad-sdk 0.13.1
#     never produce audit.1.jsonl when hardened, and DO when not (control).
# ===========================================================================
echo "-- (d) rotation stays off under the real squad-sdk (${SDK_VERSION}) -- $SDK_DIR --"

# The SDK location reaches node through the environment and pathToFileURL,
# never interpolated into JS source: a path is not a valid string literal or
# URL in general (a Windows `C:\...\npm` path turns `\n` into a newline).
export SQUAD_TEST_SDK_DIR="$SDK_DIR"
SDK_IMPORT_PRELUDE="$(cat <<'EOF'
import path from "node:path";
import { pathToFileURL } from "node:url";
const sdkUrl = (rel) => pathToFileURL(path.join(process.env.SQUAD_TEST_SDK_DIR, rel)).href;
const { LocalMemoryStore } = await import(sdkUrl("dist/memory/index.js"));
const { FSStorageProvider } = await import(sdkUrl("dist/storage/fs-storage-provider.js"));
EOF
)"

ROTATE_SCRIPT="${WORK}/rotate.mjs"
{
  printf '%s\n' "$SDK_IMPORT_PRELUDE"
  cat <<'EOF'
const repo = process.argv[2];
const count = parseInt(process.argv[3], 10);
const store = new LocalMemoryStore(new FSStorageProvider(), repo);
const pad = "x".repeat(1000);
for (let i = 0; i < count; i++) {
  await store.audit({ action: "test", seq: i, detail: pad });
}
console.log("DONE");
EOF
} >"$ROTATE_SCRIPT"

# -- hardened subject -- harden, run the 1100 real audit() calls, and verify
#    ALL inside the same policy_scenario subshell: squad_policy_verify needs
#    the SAME process's in-memory baseline that squad_policy_harden recorded,
#    and a second squad_policy_harden call on an already-hardened repo would
#    itself fail (the first call already chmod -R a-w'd the governance paths,
#    so the node pin-writer the second call needs would hit EACCES).
D="${WORK}/repo-d"
make_repo "$D" 0
# squad_policy_verify's append-only detector requires the path to have
# EXISTED at session start (an append-only file this session CREATES is
# itself a violation -- "may append to history, not create it"), so the
# fixture must commit an empty audit.jsonl up front, exactly as a real
# repository would already have one from a prior session.
mkdir -p "${D}/.squad/memory"
: >"${D}/.squad/memory/audit.jsonl"
git_quiet -C "$D" add -A
git_quiet -C "$D" commit -q -m "baseline audit.jsonl"
d_out="$(policy_scenario "$D" "${WORK}/state-d" '
  squad_policy_harden "'"$D"'"; echo "HARDEN_RC=$?"
  node "'"$ROTATE_SCRIPT"'" "'"$D"'" 1100 >/dev/null; echo "ROTATE_RC=$?"
  squad_policy_verify "'"$D"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$d_out" "HARDEN_RC=0" "(d) hardening the real-SDK subject succeeds"
assert_contains "$d_out" "ROTATE_RC=0" "(d) 1100 real audit() calls through the real squad-sdk ${SDK_VERSION} complete without error"
assert_contains "$d_out" "VERIFY_RC=0" \
  "(d) HARDENED: the real audit appends are genuine appends to an append-only path, not a governance violation"

assert_eq "0" "$([[ -f "${D}/.squad/memory/audit.1.jsonl" ]] && echo 1 || echo 0)" \
  "(d) HARDENED: 1100 real audit() calls through the real squad-sdk ${SDK_VERSION} never produce audit.1.jsonl -- the pin genuinely disables rotation, not just on paper"
d_audit_size="$(wc -c <"${D}/.squad/memory/audit.jsonl" 2>/dev/null || echo 0)"
assert_eq "1" "$([[ "$d_audit_size" -gt 1048576 ]] && echo 1 || echo 0)" \
  "(d) HARDENED: audit.jsonl itself grew past the default 1048576-byte rotation threshold with nothing rotating it away"

# -- unhardened CONTROL: same loop, no pin, proves the harness itself rotates --
CTRL="${WORK}/repo-d-control"
make_repo "$CTRL" 0
node "$ROTATE_SCRIPT" "$CTRL" 1100 >/dev/null
assert_eq "1" "$([[ -f "${CTRL}/.squad/memory/audit.1.jsonl" ]] && echo 1 || echo 0)" \
  "(d) CONTROL (no harden, no pin): the SAME 1100 real audit() calls DO rotate -- so the hardened case's absence of audit.1.jsonl is evidence of the pin working, not a fluke of the test harness"

# ===========================================================================
# (e4) Finding 3: `git clean -fdx` deletes the ignored pin. The sampler
#      re-pins it, rotation stays off under 1100 real SDK audits, and the
#      deletion is REPORTED (git hygiene), not a violation.
# ===========================================================================
echo "-- (e4) rotation stays off after 'git clean -fdx' re-pins the untracked fixture --"

E4="${WORK}/repo-e4"
make_repo "$E4" 0
mkdir -p "${E4}/.squad/memory"
: >"${E4}/.squad/memory/audit.jsonl"
git_quiet -C "$E4" add -A
git_quiet -C "$E4" commit -q -m "baseline audit.jsonl"
e4_out="$(policy_scenario "$E4" "${STATE_E}4" '
  export SQUAD_POLICY_HIGHWATER_INTERVAL_SECONDS=0.2
  squad_policy_harden "'"$E4"'"; echo "HARDEN_RC=$?"
  git -C "'"$E4"'" clean -fdxq; echo "CLEAN_RC=$?"
  sleep 1.5
  node -e "const c=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")); process.exit(c.policy.auditMaxBytes===0?0:1)" "'"$E4"'/'"$PIN"'" && echo PINNED_AFTER_CLEAN=1 || echo PINNED_AFTER_CLEAN=0
  node "'"$ROTATE_SCRIPT"'" "'"$E4"'" 1100 >/dev/null; echo "ROTATE_RC=$?"
  squad_policy_verify "'"$E4"'"; echo "VERIFY_RC=$?"
')"
assert_contains "$e4_out" "HARDEN_RC=0" "(e4) hardening succeeds"
assert_contains "$e4_out" "CLEAN_RC=0" "(e4) 'git clean -fdx' ran"
assert_contains "$e4_out" "PINNED_AFTER_CLEAN=1" "(e4) after 'git clean -fdx' the sampler has re-pinned config.json (auditMaxBytes 0)"
assert_contains "$e4_out" "ROTATE_RC=0" "(e4) 1100 real audit() calls complete"
assert_eq "0" "$([[ -f "${E4}/.squad/memory/audit.1.jsonl" ]] && echo 1 || echo 0)" \
  "(e4) rotation is STILL disabled after 'git clean -fdx' -- no audit.1.jsonl under the real squad-sdk"
assert_contains "$e4_out" "VERIFY_RC=0" "(e4) deleting the git-ignored pin is not blamed on the agent as a violation"
assert_contains "$e4_out" "deleted (e.g. git clean -x)" "(e4) the deletion is reported"

test_summary
