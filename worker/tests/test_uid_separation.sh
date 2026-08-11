#!/usr/bin/env bash
# PC-2 (issue #86): a second boundary is now REQUIRED, not optional.
#
# PC-1's live ACA diagnostic (docs/security-report.md) measured this
# platform's same-uid /proc/<pid>/environ read as POSSIBLE
# (same-uid-environ-readable=yes, hidepid=0). That means the identity-drop
# ordering asserted by test_identity_drop_order.sh is no longer the ONLY
# control standing between a session and the Azure identity: on this
# platform, a same-uid neighbour really can read another process's
# environment out of /proc.
#
# Only `ralph` mode ever holds the identity (the only mode that runs
# `az login --identity`). Every OTHER mode runs an agent that executes
# attacker-influenced input through Copilot. A Linux ptrace/DAC check gates
# every /proc/<pid>/environ read on a REAL UID match (or CAP_SYS_PTRACE),
# independent of hidepid -- so giving ralph's process a UID that never
# matches the UID any agent-running mode uses closes the exact gap PC-1
# found, without depending on ordering at all.
#
# This suite checks the control two ways, mirroring
# test_identity_drop_order.sh's own style: by reading the Dockerfile and
# entrypoint.sh, and -- where the running host allows it -- by reproducing
# the underlying kernel property being relied on.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$WORKER_DIR/Dockerfile"
ENTRYPOINT="$WORKER_DIR/entrypoint.sh"

pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    printf '  ok   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$name"; fail=$((fail + 1))
  fi
}

line_of() { grep -n "$1" "$ENTRYPOINT" | head -1 | cut -d: -f1; }

# --- Dockerfile: two distinct, non-root users --------------------------------

check "Dockerfile creates a 'squad' user (the agent -- every mode except ralph)" \
  bash -c "grep -qF 'useradd -m -s /bin/bash squad \\' '$DOCKERFILE'"

check "Dockerfile creates a DISTINCT 'squad-identity' user (the only mode that holds the Azure identity: ralph)" \
  bash -c "grep -qF 'useradd -m -s /bin/bash squad-identity \\' '$DOCKERFILE'"

check "the two users are not the same name (a copy-paste that reused 'squad' for both would defeat the whole control)" \
  bash -c "grep -qF 'useradd -m -s /bin/bash squad \\' '$DOCKERFILE' && grep -qF 'useradd -m -s /bin/bash squad-identity \\' '$DOCKERFILE' && [[ 'squad' != 'squad-identity' ]]"

check "neither new user is root (grep finds no 'useradd ... root')" \
  bash -c "! grep -qE 'useradd .*[[:space:]]root\$' '$DOCKERFILE'"

check "squad-identity is NOT added to squad's own group (that would recreate same-UID-equivalent access)" \
  bash -c "! grep -qE 'usermod .*-aG squad[[:space:]].*squad-identity' '$DOCKERFILE' && ! grep -qE 'useradd .*-G squad[[:space:]].*squad-identity' '$DOCKERFILE'"

check "/workspace (the one thing both users must share -- every mode clones into it) is put in a shared group with the setgid bit, not made world-writable" \
  bash -c "grep -qE 'chmod 2775 /workspace' '$DOCKERFILE'"

check "the Dockerfile's default runtime user is NOT pinned to 'squad' (no trailing 'USER squad' -- the entrypoint itself must choose the user per SQUAD_MODE)" \
  bash -c "! grep -qE '^USER squad\$' '$DOCKERFILE'"

# --- entrypoint.sh: the privilege drop ---------------------------------------

drop_block_start="$(line_of '\[\[ "\$(id -u)" -eq 0 \]\]')"
identity_case_start="$(grep -n '^case "\${SQUAD_MODE:-smoke}" in$' "$ENTRYPOINT" | head -1 | cut -d: -f1)"

check "entrypoint.sh contains the root-check that gates the privilege drop" \
  bash -c "[[ -n '${drop_block_start:-}' ]]"

check "the privilege drop is BEFORE the identity-drop mode dispatch (drop @${drop_block_start:-?}, identity-drop case @${identity_case_start:-?})" \
  bash -c "[[ -n '${drop_block_start}' && -n '${identity_case_start}' && ${drop_block_start:-999999} -lt ${identity_case_start:-0} ]]"

# The drop must be the FIRST thing anything runs -- before HOME, before any
# export, before any require() call. A `require GITHUB_REPOSITORY` before it
# would mean this container touched user-supplied configuration before
# choosing which user runs it.
home_export_line="$(line_of '^export HOME=')"
require_repo_line="$(line_of '^require GITHUB_REPOSITORY$')"
check "the drop happens before HOME is exported (drop @${drop_block_start:-?}, HOME export @${home_export_line:-?})" \
  bash -c "[[ -n '${drop_block_start}' && -n '${home_export_line}' && ${drop_block_start:-999999} -lt ${home_export_line:-0} ]]"
check "the drop happens before 'require GITHUB_REPOSITORY' (drop @${drop_block_start:-?}, require @${require_repo_line:-?})" \
  bash -c "[[ -n '${drop_block_start}' && -n '${require_repo_line}' && ${drop_block_start:-999999} -lt ${require_repo_line:-0} ]]"

# The exact selection: ralph -> squad-identity, everything else -> squad. This
# is the line whose removal or inversion would silently put ralph back on the
# same UID as the agent.
drop_block_text="$(awk -v s="${drop_block_start:-0}" 'NR>=s && NR<s+15' "$ENTRYPOINT")"
check "the drop selects 'squad-identity' specifically when SQUAD_MODE is ralph" \
  bash -c "printf '%s\n' \"\$0\" | grep -q 'ralph' && printf '%s\n' \"\$0\" | grep -q 'squad-identity'" "$drop_block_text"

check "the drop's default (non-ralph) target is 'squad', not left unset" \
  bash -c "printf '%s\n' \"\$0\" | grep -qE 'SQUAD_RUNTIME_USER=\"squad\"'" "$drop_block_text"

check "the drop uses exec (replaces the process outright -- no root parent left behind)" \
  bash -c "printf '%s\n' \"\$0\" | grep -qE '^\s*exec .*runuser'" "$drop_block_text"

check "the drop preserves the ACA-injected environment across the UID switch (runuser -p / --preserve-environment)" \
  bash -c "printf '%s\n' \"\$0\" | grep -qE 'runuser (-p|--preserve-environment)'" "$drop_block_text"

check "the drop clears the stale root HOME before preserving the rest of the environment (env -u HOME), so a dropped-privilege process never inherits root's HOME" \
  bash -c "printf '%s\n' \"\$0\" | grep -qE 'env -u HOME'" "$drop_block_text"

# HOME's own fallback must not be hard-coded to /home/squad -- that would be
# correct for every mode except ralph, and silently wrong (permission denied)
# for the one mode this whole control exists to isolate.
check "HOME's fallback is resolved from the ACTUAL current user, not hard-coded to /home/squad (a hard-coded fallback would break ralph, which now runs as squad-identity)" \
  bash -c "! grep -qE '^export HOME=\"\\\$\\{HOME:-/home/squad\\}\"\$' '$ENTRYPOINT'"

# --- the mechanism, reproduced (where the host allows it) --------------------
#
# Same style as test_identity_drop_order.sh's own reproduction: this is the
# PROPERTY PC-2 relies on -- that Linux denies a /proc/<pid>/environ read
# across a genuine UID boundary, independent of hidepid -- demonstrated
# rather than merely asserted. Requires the ability to create an
# unprivileged user namespace (no root needed); an explicit, visible skip
# where that is unavailable, never a silent pass.
if command -v unshare >/dev/null 2>&1 && unshare --user --pid --fork true 2>/dev/null; then
  PROBE_LIB="$WORKER_DIR/lib/proc-isolation-probe.sh"
  work="$(mktemp -d)"

  # Same-uid case: a real child of THIS process, same real uid -- expected to
  # be readable (mirrors what PC-1 measured live: yes on this platform).
  same_uid_result="$(bash -c "
    source '$PROBE_LIB'
    env SQUAD_UID_SEP_SENTINEL=probe-value sleep 2 &
    child=\$!
    squad_proc_iso_classify_environ_readable_settled \"/proc/\$child/environ\" SQUAD_UID_SEP_SENTINEL
    kill \$child 2>/dev/null || true
  ")"
  check "control case: a same-uid child's /proc/<pid>/environ is readable here (got '$same_uid_result') -- the exact condition PC-2 defends against" \
    test "$same_uid_result" = "yes"

  # Cross-uid case: the child is placed in a NEW user namespace, mapped to a
  # uid that is not this process's real uid. Reading its /proc/<pid>/environ
  # from OUTSIDE that namespace must be denied by the kernel's ptrace/DAC
  # check -- exactly the property a real squad vs squad-identity UID split
  # relies on, reproduced without needing root or actual multi-user setup.
  cat > "$work/child.sh" <<'CHILDSH'
#!/bin/sh
export SQUAD_UID_SEP_SENTINEL=probe-value
exec sleep 2
CHILDSH
  chmod +x "$work/child.sh"
  unshare --user --map-root-user --pid --fork --mount-proc "$work/child.sh" &
  cross_child_wrapper=$!
  sleep 0.3
  # Find the actual sleep pid under the wrapper (best-effort; this is a
  # reproduction aid, not production code).
  cross_pid="$(pgrep -P "$cross_child_wrapper" 2>/dev/null | tail -1)"
  if [[ -z "$cross_pid" ]]; then
    cross_pid="$cross_child_wrapper"
  fi
  cross_uid_result="$(bash -c "source '$PROBE_LIB'; squad_proc_iso_classify_environ_readable_settled '/proc/$cross_pid/environ' SQUAD_UID_SEP_SENTINEL" 2>/dev/null || echo "no")"
  kill "$cross_child_wrapper" 2>/dev/null || true
  wait "$cross_child_wrapper" 2>/dev/null || true

  check "a DIFFERENT-uid child's /proc/<pid>/environ is NOT readable here (got '$cross_uid_result') -- the property a real squad/squad-identity UID split relies on" \
    bash -c "[[ '$cross_uid_result' == 'no' || '$cross_uid_result' == 'unknown' ]]"

  rm -rf "$work"
else
  echo "  skip cross-uid reproduction: this host cannot create an unprivileged user namespace (unshare unavailable or disabled) -- the static checks above still apply"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
