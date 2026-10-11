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
# entrypoint.sh, and by reproducing the underlying kernel property being
# relied on between two REAL uids. That second half needs real root.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$WORKER_DIR/Dockerfile"
ENTRYPOINT="$WORKER_DIR/entrypoint.sh"

# Same re-exec as test_security_n1b_root_sealed_state.sh: with passwordless
# sudo (CI), run this whole suite as root so the real uid boundary is exercised.
if [[ "$(id -u)" -ne 0 && "${SQUAD_UID_SEP_ROOT_REEXEC:-0}" != "1" ]] \
  && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  sudo_env=("SQUAD_UID_SEP_ROOT_REEXEC=1" "PATH=${PATH:-}")
  for name in TMPDIR TEMP TMP; do
    if [[ -v "$name" ]]; then
      sudo_env+=("${name}=${!name}")
    fi
  done
  while IFS= read -r name; do
    [[ "$name" == SQUAD_UID_SEP_ROOT_REEXEC ]] && continue
    sudo_env+=("${name}=${!name}")
  done < <(compgen -e SQUAD_ | sort)

  echo "INFO: test_uid_separation.sh — re-execing under passwordless sudo to exercise the real uid boundary."
  exec sudo -n /usr/bin/env "${sudo_env[@]}" "$(command -v bash)" "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$@"
fi

echo "== UID separation between ralph and agent-running modes (PC-2 / issue #86) =="

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

# --- the mechanism, reproduced across a REAL uid boundary --------------------
#
# The PROPERTY PC-2 relies on -- Linux denies a /proc/<pid>/environ read across
# a genuine UID boundary, independent of hidepid -- demonstrated rather than
# merely asserted. That needs two different REAL uids, so it needs real root:
# directly, or through the passwordless-sudo re-exec above. A user namespace is
# NOT a substitute: `unshare --user --map-root-user` maps the namespace's root
# onto the caller's OWN uid, so its "different-uid" child kept the reader's
# real uid (and the namespace's creator holds CAP_SYS_PTRACE over it anyway);
# the read was allowed, and the old assertion measured nothing. Without root
# the cross-uid proof is reported as SKIPPED (exit 77), never as a pass.
PROBE_LIB="$WORKER_DIR/lib/proc-isolation-probe.sh"
SENTINEL_NAME="SQUAD_UID_SEP_SENTINEL"
skip_reason=""

if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
  skip_reason="this host is not Linux, so there is no kernel uid boundary to exercise"
elif [[ "$(id -u)" -ne 0 ]]; then
  # Same-uid case: a real child of THIS process, same real uid -- expected to
  # be readable (mirrors what PC-1 measured live: yes on this platform).
  same_uid_result="$(bash -c "
    source '$PROBE_LIB'
    env ${SENTINEL_NAME}=probe-value sleep 2 &
    child=\$!
    squad_proc_iso_classify_environ_readable_settled \"/proc/\$child/environ\" ${SENTINEL_NAME}
    kill \$child 2>/dev/null || true
  ")"
  check "control case: a same-uid child's /proc/<pid>/environ is readable here (got '$same_uid_result') -- the exact condition PC-2 defends against" \
    test "$same_uid_result" = "yes"
  skip_reason="this suite is not running as root and passwordless sudo is unavailable"
else
  # The child runs as `nobody`; the readers are `nobody` itself (control) and a
  # different unprivileged uid (cross): the existing `daemon` account, else the
  # next uid down. Both are dropped from root with setpriv, which execs in
  # place, so the pid under test is the real process.
  victim_uid="$(id -u nobody 2>/dev/null || true)"
  reader_uid=""
  if [[ "$victim_uid" =~ ^[0-9]+$ && "$victim_uid" -gt 0 ]]; then
    reader_uid="$(id -u daemon 2>/dev/null || true)"
    if ! [[ "$reader_uid" =~ ^[0-9]+$ && "$reader_uid" -gt 0 && "$reader_uid" -ne "$victim_uid" ]]; then
      reader_uid=$(( victim_uid > 1 ? victim_uid - 1 : victim_uid + 1 ))
    fi
  fi
  missing=""
  for dep in setpriv awk mktemp; do
    command -v "$dep" >/dev/null 2>&1 || missing+=" $dep"
  done

  prereqs_ok() { [[ -z "$missing" && -n "$reader_uid" ]]; }
  same_uid_readable() { [[ "$1" == "yes/present" ]]; }
  cross_uid_denied() { [[ "$1" == "no/unreadable" ]]; }
  fixture_child_ok() { [[ "$1" == "sleep" && "$2" == "$victim_uid" ]]; }
  fixture_readers_ok() { # <same uid> <cross uid> <child uid> <same CapEff> <cross CapEff>
    [[ "$1" == "$3" && "$2" == "$reader_uid" && "$2" != "$3" && "$2" != "0" && "$4" =~ ^0+$ && "$5" =~ ^0+$ ]]
  }
  # The denial only counts when it cannot be vacuous: the child really runs as
  # nobody, the two readers are different unprivileged uids, the SAME-uid read of
  # that very child classifies 'yes' (sentinel seen), and the child outlived both.
  cross_proof_nonvacuous() {
    fixture_child_ok "${real[comm]:-}" "${real[child_uid]:-}" \
      && fixture_readers_ok "${real[same_uid]:-}" "${real[cross_uid]:-}" "${real[child_uid]:-}" "${real[same_cap]:-}" "${real[cross_cap]:-}" \
      && same_uid_readable "${real[same]:-}" \
      && [[ "${real[alive]:-}" == "sleep" ]] \
      && cross_uid_denied "${real[cross]:-}"
  }
  mutant_rejected() { # <token the mutant produced> <token it must produce> <assertion it must fail>
    [[ "$1" == "$2" ]] && ! "$3" "$1"
  }

  check "root-backed proof prerequisites are present (missing tools:${missing:- none}; 'nobody' uid: ${victim_uid:-absent})" \
    prereqs_ok

  if prereqs_ok; then
    child_pid=""
    work=""
    cleanup() {
      [[ -n "$child_pid" ]] && kill "$child_pid" 2>/dev/null
      [[ -n "$work" ]] && rm -rf "$work"
      return 0
    }
    trap cleanup EXIT
    trap 'exit 143' INT TERM

    work="$(mktemp -d)"
    chmod 0755 "$work"
    cp "$PROBE_LIB" "$work/proc-isolation-probe.sh"
    # Runs as the dropped reader uid and prints one line; nothing else.
    cat > "$work/reader.sh" <<'READER'
source "$1"
printf '%s/%s uid=%s capeff=%s\n' \
  "$(squad_proc_iso_classify_environ_readable_settled "/proc/$2/environ" "$3")" \
  "$(squad_proc_iso_classify_environ_detail "/proc/$2/environ" "$3")" \
  "$(id -u)" \
  "$(awk '/^CapEff:/ {print $2}' /proc/self/status)"
READER
    # Classifiers that always give one answer, to prove each assertion can fail.
    printf '%s\n' \
      "squad_proc_iso_classify_environ_readable_settled() { printf 'yes'; }" \
      "squad_proc_iso_classify_environ_detail() { printf 'present'; }" > "$work/lib-always-yes.sh"
    printf '%s\n' \
      "squad_proc_iso_classify_environ_readable_settled() { printf 'no'; }" \
      "squad_proc_iso_classify_environ_detail() { printf 'unreadable'; }" > "$work/lib-always-no.sh"
    chmod 0644 "$work"/*.sh

    read_as() { # <uid> <probe-lib> <pid>
      env -i PATH="$PATH" setpriv --reuid="$1" --regid="$1" --clear-groups \
        bash "$work/reader.sh" "$2" "$3" "$SENTINEL_NAME" 2>/dev/null
    }

    measure_reads() { # <assoc array name> <probe-lib>
      local -n out="$1"
      local lib="$2" waited=0 who rd_uid line tok uid_kv cap_kv
      setpriv --reuid="$victim_uid" --regid="$victim_uid" --clear-groups \
        env "${SENTINEL_NAME}=probe-value" sleep 30 &
      child_pid=$!
      # Wait for the exec chain (setpriv -> env -> sleep) to finish, so the
      # environ under test is the final one and the pid really is a nobody sleep.
      while [[ "$(cat "/proc/$child_pid/comm" 2>/dev/null)" != "sleep" && "$waited" -lt 100 ]]; do
        sleep 0.05
        waited=$((waited + 1))
      done
      out[comm]="$(cat "/proc/$child_pid/comm" 2>/dev/null)"
      out[child_uid]="$(awk '/^Uid:/ {print $2}' "/proc/$child_pid/status" 2>/dev/null)"
      for who in same cross; do
        rd_uid="$reader_uid"
        [[ "$who" == "same" ]] && rd_uid="$victim_uid"
        line="$(read_as "$rd_uid" "$lib" "$child_pid")"
        read -r tok uid_kv cap_kv <<<"$line"
        out[$who]="$tok"
        out[${who}_uid]="${uid_kv#uid=}"
        out[${who}_cap]="${cap_kv#capeff=}"
      done
      out[alive]="$(cat "/proc/$child_pid/comm" 2>/dev/null)"
      kill "$child_pid" 2>/dev/null
      wait "$child_pid" 2>/dev/null
      child_pid=""
    }

    declare -A real=() always_yes=() always_no=()
    measure_reads real "$work/proc-isolation-probe.sh"
    measure_reads always_yes "$work/lib-always-yes.sh"
    measure_reads always_no "$work/lib-always-no.sh"

    check "fixture: the child under test runs as real uid '${real[child_uid]:-?}' ('nobody' is $victim_uid), not root, exec'd to '${real[comm]:-?}'" \
      fixture_child_ok "${real[comm]:-}" "${real[child_uid]:-}"
    check "fixture: both readers are unprivileged with no capabilities -- same-uid reader '${real[same_uid]:-?}', cross-uid reader '${real[cross_uid]:-?}' (child '${real[child_uid]:-?}'; CapEff ${real[same_cap]:-?} / ${real[cross_cap]:-?})" \
      fixture_readers_ok "${real[same_uid]:-}" "${real[cross_uid]:-}" "${real[child_uid]:-}" "${real[same_cap]:-}" "${real[cross_cap]:-}"
    check "control case: a same-uid child's /proc/<pid>/environ is readable here (got '${real[same]:-}') -- the exact condition PC-2 defends against" \
      same_uid_readable "${real[same]:-}"
    check "a DIFFERENT-uid child's /proc/<pid>/environ is NOT readable here (got '${real[cross]:-}'; real uid ${real[cross_uid]:-?} reading real uid ${real[child_uid]:-?}; child still '${real[alive]:-}' after both reads) -- the property a real squad/squad-identity UID split relies on" \
      cross_proof_nonvacuous
    check "negative proof: a classifier that always answers 'yes' fails the cross-uid assertion (got '${always_yes[cross]:-}')" \
      mutant_rejected "${always_yes[cross]:-}" "yes/present" cross_uid_denied
    check "negative proof: a classifier that always answers 'no' fails the same-uid control (got '${always_no[same]:-}')" \
      mutant_rejected "${always_no[same]:-}" "no/unreadable" same_uid_readable
  fi
fi

if [[ -n "$skip_reason" ]]; then
  echo "SKIP: test_uid_separation.sh — cross-uid proof NOT RUN: ${skip_reason}."
  echo "SKIP:   run it as real root on Linux, e.g.: wsl -d Ubuntu -u root -- bash worker/tests/test_uid_separation.sh"
  echo "SKIP:   on CI/Linux with passwordless sudo, run it normally and it will re-exec itself under sudo."
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
if [[ -n "$skip_reason" ]]; then
  exit 77
fi
exit 0
