#!/usr/bin/env bash
# PC-1 (issue #86): does THIS platform let a same-uid process read another
# process's environment through /proc?
#
# worker/entrypoint.sh drops the Azure identity from its own shell's
# environment before starting any child (squad_drop_azure_identity,
# worker/tests/test_identity_drop_order.sh). That ordering is correct whether
# or not a same-uid process on this host can read another process's
# /proc/<pid>/environ -- but it is the ONLY control if the platform allows it,
# and a second one if the platform does not. Nobody had checked which is true
# on Azure Container Apps. This script is the check.
#
# WHAT IT DOES, AND JUST AS IMPORTANTLY WHAT IT NEVER DOES
# ---------------------------------------------------------
#   * It spawns a short-lived child carrying ONLY a synthetic, per-run random
#     sentinel in its environment -- never a real credential, never
#     IDENTITY_ENDPOINT/IDENTITY_HEADER/anything squad_drop_azure_identity
#     touches. The parent (same uid) then attempts to read that child's
#     /proc/<pid>/environ.
#   * It reports whether the SENTINEL'S VARIABLE NAME was present. It never
#     prints, logs, or compares the sentinel's VALUE, and it never reads or
#     reports any real environment variable of any process.
#   * It emits exactly ONE line, to stdout, in a fixed format, and nothing
#     else -- no stack traces, no partial diagnostics, no secrets.
#   * It always reaps the child it starts, on every exit path.
#   * It exits 0 unconditionally, including when every check inside it fails,
#     so a probe failure can never fail a session or a deploy.
#   * The cost is bounded and small: the child is killed as soon as the answer
#     is in, and the fork/exec settle loop (L4, below) re-polls at most 30
#     times 0.01s apart -- 0.3s worst case, and typically one or two polls.
#     There is no unbounded wait and no open-ended polling.
#
# TESTABILITY
# -----------
# The functions below are deliberately factored so worker/tests/
# test_proc_isolation_probe.sh can call each one directly (this file is safe
# to `source`; it only runs the top-level probe when executed directly, not
# when sourced) and prove each of the three same-uid-environ-readable
# classifications without depending on a specific host's actual /proc
# restrictions:
#
#   squad_proc_iso_classify_environ_detail <path> <var-name>
#     Pure classifier, the SINGLE implementation of what an environ-shaped
#     path says: "present", "absent", "unreadable", "empty" or "missing".
#     Distinguishing "absent" (readable, non-empty, the name is genuinely not
#     there) from "unreadable" is what makes the L4 settle loop below
#     possible: only the shapes that a not-yet-exec'd child produces are worth
#     re-polling, and an unreadable path never is.
#
#   squad_proc_iso_classify_environ_readable <path> <var-name>
#     The reported three-value classification, mapped from the detail above:
#     "yes" (found), "no" (path exists but is unreadable, or is readable and
#     does not contain the name), or "unknown" (path does not exist, or is
#     readable but empty). Never reads the variable's value into anything
#     returned or printed.
#
#   squad_proc_iso_classify_environ_readable_settled <path> <var-name>
#     L4 (issue #86, third revision): the same classification, but tolerant of
#     the fork/exec race described at squad_proc_iso_check_same_uid_readable.
#     Bounded: at most SQUAD_PROC_ISO_SETTLE_ATTEMPTS (30) re-polls,
#     SQUAD_PROC_ISO_SETTLE_INTERVAL (0.01s) apart -- 0.3s worst case, no
#     unbounded wait, and it never turns a genuine "no" into a "yes": only a
#     readable-but-not-yet-populated shape is re-polled.
#
#   squad_proc_iso_parse_hidepid <mount-line>
#     Pure classifier: given a line as it would appear in /proc/mounts for the
#     proc filesystem, returns "0", "1", "2" or "unknown".
#
# Both are called by the real run exactly the way a test calls them, so a
# mutation that breaks the classification logic breaks both the real
# behaviour and the test that targets it -- there is no parallel
# reimplementation to drift.

SQUAD_PROC_ISO_SLEEP_SECONDS="${SQUAD_PROC_ISO_SLEEP_SECONDS:-2}"

# L4 (issue #86, third revision): the bounded settle window for the fork/exec
# race. At most 30 re-polls, 0.01s apart -- 0.3s worst case. The child's own
# nominal lifetime (SQUAD_PROC_ISO_SLEEP_SECONDS, above) is deliberately far
# larger than this window so the child cannot exit underneath a re-poll and
# turn a real answer into "unknown"; the child is killed as soon as
# classification finishes, so that nominal lifetime is never actually waited
# out.
SQUAD_PROC_ISO_SETTLE_ATTEMPTS="${SQUAD_PROC_ISO_SETTLE_ATTEMPTS:-30}"
SQUAD_PROC_ISO_SETTLE_INTERVAL="${SQUAD_PROC_ISO_SETTLE_INTERVAL:-0.01}"

squad_proc_iso_uid() {
  id -u 2>/dev/null || printf 'unknown'
}

squad_proc_iso_user() {
  id -un 2>/dev/null || printf 'unknown'
}

# yes/no: is /proc itself mounted and usable at all? Everything else this
# script reports depends on this being "yes" first.
squad_proc_iso_proc_mounted() {
  if [[ -r /proc/self/status ]] || [[ -d /proc/self ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# Given one /proc/mounts line for the proc filesystem, returns the hidepid
# mount option value, or "0" (the platform default when proc is mounted with
# no explicit hidepid=), or "unknown" when no such line was given at all.
squad_proc_iso_parse_hidepid() {
  local mount_line="${1:-}"
  if [[ -z "$mount_line" ]]; then
    printf 'unknown'
    return 0
  fi
  if [[ "$mount_line" == *"hidepid=2"* ]]; then
    printf '2'
  elif [[ "$mount_line" == *"hidepid=1"* ]]; then
    printf '1'
  elif [[ "$mount_line" == *"hidepid=0"* ]]; then
    printf '0'
  else
    # procfs mounted with no explicit hidepid= option: the kernel default is 0.
    printf '0'
  fi
}

squad_proc_iso_hidepid() {
  if [[ "$(squad_proc_iso_proc_mounted)" != "yes" ]]; then
    printf 'unknown'
    return 0
  fi
  local mount_line
  mount_line="$(grep -E '^[^[:space:]]+[[:space:]]+/proc[[:space:]]+proc[[:space:]]' /proc/mounts 2>/dev/null | tail -1)"
  squad_proc_iso_parse_hidepid "$mount_line"
}

# Pure classifier, the single implementation. NEVER prints, compares, or
# returns the variable's VALUE -- only what the given (real or fabricated)
# environ file says about the presence of its NAME:
#
#   "present"    readable, non-empty, contains a line "<var-name>=..."
#   "absent"     readable, non-empty, does NOT contain the variable name
#   "unreadable" the path exists but could not be read
#   "empty"      the path is readable but has no content at all
#   "missing"    the path does not exist
squad_proc_iso_classify_environ_detail() {
  local environ_path="$1"
  local var_name="$2"

  if [[ ! -e "$environ_path" ]]; then
    printf 'missing'
    return 0
  fi
  if [[ ! -r "$environ_path" ]]; then
    printf 'unreadable'
    return 0
  fi

  local content
  content="$(tr '\0' '\n' < "$environ_path" 2>/dev/null)"
  if [[ -z "$content" ]]; then
    printf 'empty'
    return 0
  fi

  if printf '%s\n' "$content" | grep -q "^${var_name}="; then
    printf 'present'
  else
    printf 'absent'
  fi
}

# The reported three-value classification, mapped from the detail above so
# there is exactly one implementation of what an environ file says.
#
#   "yes"     the path is readable and contains a line "<var-name>=..."
#   "no"      the path exists but could not be read, or was read and does not
#             contain the variable name
#   "unknown" the path does not exist, or is readable but empty (nothing this
#             script can conclude either way)
squad_proc_iso_classify_environ_readable() {
  local detail
  detail="$(squad_proc_iso_classify_environ_detail "$1" "$2")"
  case "$detail" in
    present) printf 'yes' ;;
    absent | unreadable) printf 'no' ;;
    *) printf 'unknown' ;;
  esac
}

# L4 (issue #86, third revision): the same classification, made immune to the
# fork/exec race.
#
# `env VAR=v sleep N &` returns the child's pid the instant the FORK
# completes, which is before the child has exec'd `env`. In that window
# /proc/<pid>/environ is readable and carries the *parent's* environment --
# which does not contain the sentinel -- or is momentarily empty. Classifying
# once, right then, reports "no": the same answer a platform that genuinely
# forbids the read would produce. That is the most dangerous possible defect
# in this probe, because "no" is the reassuring answer.
#
# So: a readable-but-not-yet-populated shape ("absent"/"empty") is re-polled,
# BOUNDED at SQUAD_PROC_ISO_SETTLE_ATTEMPTS tries SQUAD_PROC_ISO_SETTLE_INTERVAL
# apart (30 x 0.01s = 0.3s worst case), and nothing else is. "unreadable" is
# a real platform answer and returns immediately; "missing" means the process
# is gone and returns immediately. The loop can only ever turn a transient
# "no"/"unknown" into the "yes" that was true all along -- it can never
# manufacture a "yes" from a path that never contains the name.
squad_proc_iso_classify_environ_readable_settled() {
  local environ_path="$1"
  local var_name="$2"
  local attempts=0
  local detail

  detail="$(squad_proc_iso_classify_environ_detail "$environ_path" "$var_name")"
  while [[ "$detail" == "absent" || "$detail" == "empty" ]] && [[ "$attempts" -lt "$SQUAD_PROC_ISO_SETTLE_ATTEMPTS" ]]; do
    sleep "$SQUAD_PROC_ISO_SETTLE_INTERVAL" 2>/dev/null || true
    attempts=$((attempts + 1))
    detail="$(squad_proc_iso_classify_environ_detail "$environ_path" "$var_name")"
  done

  case "$detail" in
    present) printf 'yes' ;;
    absent | unreadable) printf 'no' ;;
    *) printf 'unknown' ;;
  esac
}

# The mechanism, using a real child. Spawns a short-lived process carrying only
# the sentinel var, classifies its /proc/<pid>/environ, and ALWAYS reaps the
# child before returning -- even if classification itself failed.
squad_proc_iso_check_same_uid_readable() {
  if [[ "$(squad_proc_iso_proc_mounted)" != "yes" ]]; then
    printf 'unknown'
    return 0
  fi

  local sentinel_name="SQUAD_PROC_ISO_SENTINEL"
  # Synthetic, per-run, random -- never a real credential and never printed.
  local sentinel_value="probe-$$-${RANDOM}${RANDOM}-$(date +%s%N 2>/dev/null || date +%s)"
  local child_pid=""
  local result="unknown"

  # shellcheck disable=SC2086
  env "${sentinel_name}=${sentinel_value}" sleep "$SQUAD_PROC_ISO_SLEEP_SECONDS" &
  child_pid=$!

  # L4: settle across the fork/exec race rather than classifying once, the
  # instant after the fork, when the child has not exec'd yet.
  result="$(squad_proc_iso_classify_environ_readable_settled "/proc/${child_pid}/environ" "$sentinel_name")"

  # Always reap, regardless of what classification returned.
  kill "$child_pid" >/dev/null 2>&1 || true
  wait "$child_pid" >/dev/null 2>&1 || true

  unset sentinel_value

  printf '%s' "$result"
}

# Composes the exact, single, safe output line. Never includes anything but
# the five documented fields.
squad_proc_iso_line() {
  local readable proc_mounted hidepid uid user
  readable="$(squad_proc_iso_check_same_uid_readable 2>/dev/null || printf 'unknown')"
  proc_mounted="$(squad_proc_iso_proc_mounted 2>/dev/null || printf 'unknown')"
  hidepid="$(squad_proc_iso_hidepid 2>/dev/null || printf 'unknown')"
  uid="$(squad_proc_iso_uid 2>/dev/null || printf 'unknown')"
  user="$(squad_proc_iso_user 2>/dev/null || printf 'unknown')"

  printf 'SQUAD-PROC-ISO v1 same-uid-environ-readable=%s proc-mounted=%s hidepid=%s uid=%s user=%s\n' \
    "$readable" "$proc_mounted" "$hidepid" "$uid" "$user"
}

squad_proc_iso_run() {
  # Never let a failure anywhere above escape as a non-zero exit or a partial
  # line: the whole probe is wrapped, and a hard failure still produces the
  # safe "unknown" line rather than nothing.
  local line
  line="$(squad_proc_iso_line 2>/dev/null)"
  if [[ -z "$line" ]]; then
    line="$(printf 'SQUAD-PROC-ISO v1 same-uid-environ-readable=unknown proc-mounted=unknown hidepid=unknown uid=%s user=%s' \
      "$(squad_proc_iso_uid 2>/dev/null || printf 'unknown')" \
      "$(squad_proc_iso_user 2>/dev/null || printf 'unknown')")"
  fi
  printf '%s\n' "$line"
  return 0
}

# Only run the probe when this file is EXECUTED, not when it is sourced (tests
# and worker/entrypoint.sh both source it to call the functions/composed line
# directly).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  squad_proc_iso_run
  exit 0
fi
