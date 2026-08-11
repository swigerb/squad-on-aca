#!/usr/bin/env bash
# The identity must be gone before ANY child process starts.
#
# `unset` changes the current shell. A process that was already spawned keeps
# the copy of the environment it was handed, and on Linux any process running as
# the same user can read that back out of /proc/<pid>/environ. So dropping the
# credential after starting a long-lived child does not remove it from the
# container -- it just moves it somewhere less obvious.
#
# That is exactly what happened: the lease heartbeat is a background child that
# runs for the whole session, and it was being started before the drop. An agent
# in a non-Ralph session could have read the identity endpoint and header out of
# the heartbeat's environment and asked Azure for a token with them.
#
# These assertions are about ORDER, and they check it two ways: by reading the
# script, and by reproducing the mechanism so the failure is demonstrated rather
# than asserted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$SCRIPT_DIR/../entrypoint.sh"

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

# --- the ordering, read out of the script ------------------------------------

drop_call="$(line_of '^    squad_drop_azure_identity$')"
heartbeat="$(line_of 'squad_lease_heartbeat_loop &')"

check "the identity is dropped BEFORE the lease heartbeat is spawned (drop @${drop_call:-?}, heartbeat @${heartbeat:-?})" \
  bash -c "[[ -n '${drop_call}' && -n '${heartbeat}' && ${drop_call:-0} -lt ${heartbeat:-0} ]]"

# Any other background child would have the same problem, so the drop has to
# precede all of them -- not merely the one that caused this.
first_bg="$(grep -nE '^\s*[^#]*[^&|]&\s*$' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
check "the identity is dropped before the FIRST background child of any kind (first @${first_bg:-none})" \
  bash -c "[[ -z '${first_bg}' || ${drop_call:-0} -lt ${first_bg:-999999} ]]"

# --- PC-1 (issue #86): the process-isolation probe's own ordering -----------
#
# The probe call must run (a) after the identity-drop dispatch (the `esac`
# that closes the ralph/*-mode case above squad_drop_azure_identity, T7), (b)
# before the lease heartbeat -- the first background child (T8, same
# requirement as above but re-anchored on the probe call instead of the drop
# call), and (c) UNCONDITIONALLY: outside of, and after, the mode-dispatch
# case statement, so it is not itself gated by SQUAD_MODE (T14) -- ralph and
# every other mode both reach it.

# The nearest 'esac' AFTER the drop call is the identity-drop dispatch's own
# closing esac -- entrypoint.sh has several unrelated case/esac blocks, so
# this must not just grab the first 'esac' in the file.
case_end="$(awk -v start="${drop_call:-0}" 'NR > start && /^esac$/ { print NR; exit }' "$ENTRYPOINT")"
probe_call="$(line_of 'squad_proc_iso_line')"

check "T7: the process-isolation probe call is present in entrypoint.sh" \
  bash -c "[[ -n '${probe_call:-}' ]]"

check "T7: the probe call comes AFTER the identity-drop dispatch's case/esac closes (esac @${case_end:-?}, probe @${probe_call:-?})" \
  bash -c "[[ -n '${case_end}' && -n '${probe_call}' && ${case_end:-0} -lt ${probe_call:-0} ]]"

check "the probe call comes BEFORE the lease heartbeat is spawned, same as the identity drop (probe @${probe_call:-?}, heartbeat @${heartbeat:-?})" \
  bash -c "[[ -n '${probe_call}' && -n '${heartbeat}' && ${probe_call:-0} -lt ${heartbeat:-0} ]]"

check "the probe call comes before the FIRST background child of any kind (probe @${probe_call:-?}, first @${first_bg:-none})" \
  bash -c "[[ -z '${first_bg}' || ${probe_call:-0} -lt ${first_bg:-999999} ]]"

# T14: unconditional in every mode. The probe call line must sit strictly
# AFTER the case statement's closing esac -- i.e. outside the case body
# entirely -- so no branch (including 'ralph)') can skip it. A probe call
# accidentally moved inside the case, or gated by an `if [[ "$SQUAD_MODE" ...
# ]]` of its own, would fail this.
check "T14: the probe call is unconditional -- it sits after the mode-dispatch case/esac closes, not inside any mode's branch" \
  bash -c "[[ ${case_end:-0} -lt ${probe_call:-0} ]]"

probe_guard_start=$((probe_call>6?probe_call-6:1))
probe_guard_text="$(sed -n "${probe_guard_start},${probe_call}p" "$ENTRYPOINT")"
check_probe_unconditional() { ! printf '%s' "$probe_guard_text" | grep -q 'SQUAD_MODE'; }
check "T14: the probe call is not conditioned on SQUAD_MODE (no SQUAD_MODE test guards the call site)" \
  check_probe_unconditional

# --- the mechanism, reproduced ----------------------------------------------

# A child started BEFORE the unset keeps the credential; one started after does
# not. This is the property the ordering depends on, so it is demonstrated here
# rather than taken on trust.
if [[ -r /proc/self/environ ]]; then
  probe="$(mktemp -d)"
  IDENTITY_ENDPOINT='http://localhost:42356/msi/token' \
  IDENTITY_HEADER='SECRET-HEADER-VALUE' \
  bash -c '
    sleep 30 &
    early=$!
    unset IDENTITY_ENDPOINT IDENTITY_HEADER
    sleep 30 &
    late=$!
    tr "\0" "\n" < /proc/$early/environ | grep -c "^IDENTITY_HEADER=" > '"$probe"'/early || true
    tr "\0" "\n" < /proc/$late/environ  | grep -c "^IDENTITY_HEADER=" > '"$probe"'/late  || true
    kill $early $late 2>/dev/null
  ' 2>/dev/null

  check "a child spawned BEFORE the unset still holds the credential (this is the bug)" \
    bash -c "[[ \"\$(cat '$probe/early' 2>/dev/null || echo 0)\" == '1' ]]"
  check "a child spawned AFTER the unset does not" \
    bash -c "[[ \"\$(cat '$probe/late' 2>/dev/null || echo 0)\" == '0' ]]"
  rm -rf "$probe"
else
  printf '  skip /proc is not readable here; the ordering checks above still apply\n'
fi

# --- ralph still keeps what it needs -----------------------------------------

check "ralph is still exempt, so the one mode that calls Azure keeps its identity" \
  bash -c "awk '/^case \"\\\$\{SQUAD_MODE:-smoke\}\" in\$/,/^esac\$/' '$ENTRYPOINT' | grep -q 'ralph)'"

check "every other mode is still dropped by a wildcard, so a NEW mode is safe by default" \
  bash -c "awk '/^case \"\\\$\{SQUAD_MODE:-smoke\}\" in\$/,/^esac\$/' '$ENTRYPOINT' | grep -q '\*)'"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
