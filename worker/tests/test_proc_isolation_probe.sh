#!/usr/bin/env bash
# PC-1 (issue #86): the process-isolation probe.
#
# Every assertion here targets the REAL functions in
# worker/lib/proc-isolation-probe.sh, sourced directly -- never a
# reimplementation -- so a mutation to the real logic breaks the matching
# assertion below.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/../lib/proc-isolation-probe.sh"

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

[[ -f "$PROBE" ]] || { echo "  FAIL worker/lib/proc-isolation-probe.sh is missing"; exit 1; }

# Sourcing must have NO side effect beyond defining functions -- no probe
# line, no child process, nothing on stdout.
source_output="$(bash -c "source '$PROBE'" 2>&1)"
check "sourcing the probe library produces no output at all (got: '${source_output:-<empty>}')" \
  test -z "$source_output"

# --- T1: exactly one line, all five fields, in the documented format --------

line="$(bash -c "source '$PROBE'; squad_proc_iso_line")"
lines_count="$(printf '%s\n' "$line" | grep -c '.')"
check "the probe emits exactly one non-empty line" test "$lines_count" = "1"
check "the line matches the exact documented format" \
  bash -c "printf '%s' '$line' | grep -qE '^SQUAD-PROC-ISO v1 same-uid-environ-readable=(yes|no|unknown) proc-mounted=(yes|no|unknown) hidepid=(0|1|2|unknown) uid=[^ ]+ user=[^ ]+\$'"

# Executing the file directly (not sourcing) must ALSO produce exactly one
# matching line and exit 0 -- this is what worker/entrypoint.sh and the
# Dockerfile's shipped copy actually run.
direct_output="$(bash "$PROBE")"
direct_rc=$?
check "T6: running the probe as a script exits 0" test "$direct_rc" -eq 0
check "running the probe as a script emits exactly one matching line" \
  bash -c "printf '%s' '$direct_output' | grep -qE '^SQUAD-PROC-ISO v1 same-uid-environ-readable=(yes|no|unknown) proc-mounted=(yes|no|unknown) hidepid=(0|1|2|unknown) uid=[^ ]+ user=[^ ]+\$'"
check "running the probe as a script produces exactly one line total" \
  test "$(printf '%s\n' "$direct_output" | grep -c '.')" = "1"

# --- T5: no identity/sentinel value ever leaks -------------------------------

# The sentinel VALUE is random per-run and unknown to this test, so instead
# this proves the CLASS of thing that can never appear: the literal sentinel
# variable's value marker this suite injects, real Azure identity variable
# names, and anything that looks like a credential value (long hex/base64-ish
# token). The probe's own output is checked, and -- more importantly -- so is
# its stderr, since a leak on stderr would still land in a captured log.
full_output="$(bash "$PROBE" 2>&1 1>/dev/null)"  # stderr only
check "the probe writes nothing to stderr on a normal run (got: '${full_output:-<empty>}')" \
  test -z "$full_output"

for banned in IDENTITY_ENDPOINT IDENTITY_HEADER MSI_ENDPOINT MSI_SECRET IMDS_ENDPOINT AZURE_CLIENT_ID; do
  check "the probe's stdout never names the real identity variable '$banned'" \
    bash -c "! printf '%s' '$direct_output' | grep -q '$banned'"
done

# The probe must never even READ a real identity variable if one happens to
# be present in ITS OWN environment (it must not be reporting anything about
# the calling shell's real credentials, only its own synthetic sentinel).
leaked="$(IDENTITY_ENDPOINT='http://localhost:1/msi' IDENTITY_HEADER='REAL-SECRET-VALUE-DO-NOT-LEAK' bash "$PROBE")"
check "a real identity value present in the calling shell's environment never appears in the probe's output" \
  bash -c "! printf '%s' '$leaked' | grep -q 'REAL-SECRET-VALUE-DO-NOT-LEAK'"

# T5 (direct): squad_proc_iso_check_same_uid_readable's own stderr, called
# WITHOUT the outer 2>/dev/null the run wrapper applies -- so a leak inside the
# mechanism itself is observed here even though production always suppresses
# it.
direct_fn_stderr="$(bash -c "source '$PROBE'; squad_proc_iso_check_same_uid_readable" 2>&1 1>/dev/null)"
check "T5: squad_proc_iso_check_same_uid_readable itself writes nothing to stderr (got: '${direct_fn_stderr:-<empty>}')" \
  test -z "$direct_fn_stderr"

# --- squad_proc_iso_classify_environ_readable: the pure classifier ----------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# T4: an absent path is "unknown" -- the check could not even be attempted.
absent_result="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_readable '$WORK/does-not-exist' SQUAD_PROC_ISO_SENTINEL")"
check "T4: a path that does not exist classifies as unknown (got '$absent_result')" \
  test "$absent_result" = "unknown"

# T3: a path that exists but cannot be read (permission denied) is "no" --
# this is the simulated cross-permission-boundary case; it reproduces exactly
# what hidepid=2 or a restrictive DAC would produce, without depending on this
# host actually being configured that way.
unreadable_file="$WORK/unreadable-environ"
printf 'SQUAD_PROC_ISO_SENTINEL=would-be-a-value\0' > "$unreadable_file"
chmod 000 "$unreadable_file"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip T3 direct-permission case: running as root, chmod 000 does not block root's own read"
else
  unreadable_result="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_readable '$unreadable_file' SQUAD_PROC_ISO_SENTINEL")"
  check "T3: an existing-but-unreadable path classifies as 'no' (simulated unreadable case, got '$unreadable_result')" \
    test "$unreadable_result" = "no"
fi
chmod 600 "$unreadable_file"

# T2: a real, readable environ-shaped file that DOES contain the sentinel
# name classifies as "yes".
readable_file="$WORK/readable-environ-yes"
printf 'PATH=/usr/bin\0SQUAD_PROC_ISO_SENTINEL=some-value-never-checked\0HOME=/home/x\0' > "$readable_file"
readable_result="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_readable '$readable_file' SQUAD_PROC_ISO_SENTINEL")"
check "T2: a readable path containing the sentinel name classifies as 'yes' (got '$readable_result')" \
  test "$readable_result" = "yes"

# The negative of T2: readable, but the sentinel name is genuinely absent --
# must be 'no', not 'yes'. Without this, a classifier hard-coded to "yes"
# would pass the T2 check above for the wrong reason.
readable_no_file="$WORK/readable-environ-no"
printf 'PATH=/usr/bin\0HOME=/home/x\0' > "$readable_no_file"
readable_no_result="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_readable '$readable_no_file' SQUAD_PROC_ISO_SENTINEL")"
check "a readable path that genuinely lacks the sentinel name classifies as 'no' (got '$readable_no_result')" \
  test "$readable_no_result" = "no"

# The detail classifier underneath it: the four shapes it must distinguish,
# and in particular "absent" (readable, non-empty, name genuinely not there)
# versus "unreadable" -- the distinction the L4 settle loop depends on.
detail_absent="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_detail '$readable_no_file' SQUAD_PROC_ISO_SENTINEL")"
check "L4: a readable environ without the sentinel name details as 'absent' (got '$detail_absent')" \
  test "$detail_absent" = "absent"
detail_present="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_detail '$readable_file' SQUAD_PROC_ISO_SENTINEL")"
check "L4: a readable environ containing the sentinel name details as 'present' (got '$detail_present')" \
  test "$detail_present" = "present"
empty_file="$WORK/empty-environ"
: > "$empty_file"
detail_empty="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_detail '$empty_file' SQUAD_PROC_ISO_SENTINEL")"
check "L4: a readable but empty environ details as 'empty' (got '$detail_empty')" \
  test "$detail_empty" = "empty"
detail_missing="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_detail '$WORK/does-not-exist' SQUAD_PROC_ISO_SENTINEL")"
check "L4: a path that does not exist details as 'missing' (got '$detail_missing')" \
  test "$detail_missing" = "missing"

# --- L4: the fork/exec race, deterministically ------------------------------
#
# `env VAR=v sleep N &` yields the child's pid the instant the FORK returns,
# before the child has exec'd -- a window in which /proc/<pid>/environ is
# readable but carries the parent's environment, with no sentinel in it. A
# single classification taken in that window returns "no": exactly the
# reassuring answer a platform that genuinely forbids the read would give.
#
# This reproduces that window WITHOUT depending on scheduler luck: a file
# that is readable and sentinel-free now, and gains the sentinel ~80 ms
# later. The settled classifier must report "yes"; the unsettled one, taken
# once up front, must report "no" -- which is precisely why the settle loop
# exists.
race_file="$WORK/race-environ"
printf 'PATH=/usr/bin\0' > "$race_file"
( sleep 0.08; printf 'PATH=/usr/bin\0SQUAD_PROC_ISO_SENTINEL=never-checked\0' > "$race_file.tmp"; mv "$race_file.tmp" "$race_file" ) &
race_writer=$!
race_settled="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_readable_settled '$race_file' SQUAD_PROC_ISO_SENTINEL")"
wait "$race_writer" 2>/dev/null || true
check "L4: a readable-but-not-yet-populated environ settles to 'yes' within the bounded re-poll window (got '$race_settled')" \
  test "$race_settled" = "yes"

# The bound is real, and the loop can never manufacture a "yes": a file that
# NEVER gains the sentinel must still classify as "no", and must do so
# quickly (30 x 0.01s = 0.3s worst case, well under this 5s ceiling).
never_file="$WORK/never-environ"
printf 'PATH=/usr/bin\0' > "$never_file"
never_start="$(date +%s)"
never_settled="$(bash -c "source '$PROBE'; squad_proc_iso_classify_environ_readable_settled '$never_file' SQUAD_PROC_ISO_SENTINEL")"
never_elapsed=$(( $(date +%s) - never_start ))
check "L4: an environ that never gains the sentinel still classifies as 'no' (got '$never_settled')" \
  test "$never_settled" = "no"
check "L4: the settle loop is bounded -- the never-populated case returned in ${never_elapsed}s, under the 5s ceiling" \
  test "$never_elapsed" -lt 5

# The real, end-to-end mechanism: a genuine child process, same uid, on
# whatever this host's actual /proc restriction is. This is what
# squad_proc_iso_check_same_uid_readable actually calls in production.
#
# L5 (issue #86, third revision): on a host whose OWN /proc/self/environ is
# readable -- an ordinary Linux runner with no hidepid=2 and no restrictive
# LSM -- this assertion is UNCONDITIONAL and deterministic. The previous
# revision downgraded a "no" here to a printed note, which meant the single
# most alarming outcome this suite can produce (the probe reporting the
# reassuring answer on a host that demonstrably does not restrict the read)
# was silently tolerated. The ONLY case that skips is a host where /proc is
# not available to this test at all, and that skip is printed explicitly.
if [[ -r /proc/self/environ ]]; then
  real_readable="$(bash -c "source '$PROBE'; squad_proc_iso_check_same_uid_readable")"
  check "the real same-uid child check returns one of yes/no/unknown (got '$real_readable')" \
    bash -c "[[ '$real_readable' == 'yes' || '$real_readable' == 'no' || '$real_readable' == 'unknown' ]]"
  check "T2/L5 (end-to-end): on this ordinary readable-/proc host the same-uid child check is 'yes' -- never a silently-tolerated reassuring 'no' (got '$real_readable')" \
    test "$real_readable" = "yes"

  # L4 (end-to-end): the race is not merely handled once. Repeating the real
  # mechanism must give the SAME answer every time -- a flaky "no" among
  # otherwise-"yes" runs is the race, and it is exactly what would land in a
  # production log as an isolation claim.
  repeat_distinct="$(for _ in $(seq 1 20); do bash -c "source '$PROBE'; squad_proc_iso_check_same_uid_readable"; printf '\n'; done | sort -u | tr '\n' ',' )"
  check "L4 (end-to-end): 20 consecutive real same-uid checks all agree, with no race-induced flake (observed: '$repeat_distinct')" \
    test "$repeat_distinct" = "yes,"
else
  echo "  skip real /proc read checks: /proc/self/environ is not readable on this host at all (explicit skip -- NOT a pass, and never reported as a reassuring 'no')"
fi

# --- hidepid parsing ----------------------------------------------------

check "hidepid=2 mount option parses to '2'" \
  bash -c "source '$PROBE'; [[ \"\$(squad_proc_iso_parse_hidepid 'proc /proc proc rw,nosuid,nodev,noexec,relatime,hidepid=2 0 0')\" == '2' ]]"
check "hidepid=1 mount option parses to '1'" \
  bash -c "source '$PROBE'; [[ \"\$(squad_proc_iso_parse_hidepid 'proc /proc proc rw,relatime,hidepid=1 0 0')\" == '1' ]]"
check "an explicit hidepid=0 mount option parses to '0'" \
  bash -c "source '$PROBE'; [[ \"\$(squad_proc_iso_parse_hidepid 'proc /proc proc rw,relatime,hidepid=0 0 0')\" == '0' ]]"
check "a proc mount line with no explicit hidepid= parses to the platform default '0'" \
  bash -c "source '$PROBE'; [[ \"\$(squad_proc_iso_parse_hidepid 'proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0')\" == '0' ]]"
check "no mount line at all (proc not mounted) parses to 'unknown'" \
  bash -c "source '$PROBE'; [[ \"\$(squad_proc_iso_parse_hidepid '')\" == 'unknown' ]]"

# --- reaping: the child must never be left behind ---------------------------

before_children="$(pgrep -c -P $$ 2>/dev/null || echo 0)"
bash -c "source '$PROBE'; squad_proc_iso_check_same_uid_readable" >/dev/null
sleep 0.5
after_children="$(pgrep -c -P $$ 2>/dev/null || echo 0)"
check "no stray child of this test process survives the probe (before=$before_children after=$after_children)" \
  test "$after_children" -le "$before_children"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
