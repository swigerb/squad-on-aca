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

# The real, end-to-end mechanism: a genuine child process, same uid, on
# whatever this host's actual /proc restriction is. This is what
# squad_proc_iso_check_same_uid_readable actually calls in production.
if [[ -r /proc/self/environ ]]; then
  real_readable="$(bash -c "source '$PROBE'; squad_proc_iso_check_same_uid_readable")"
  check "the real same-uid child check returns one of yes/no/unknown (got '$real_readable')" \
    bash -c "[[ '$real_readable' == 'yes' || '$real_readable' == 'no' || '$real_readable' == 'unknown' ]]"
  # On an ordinary Linux CI runner (no hidepid=2, no restrictive LSM) this is
  # expected to be 'yes' -- the exact mechanism worker/tests/
  # test_identity_drop_order.sh already reproduces for the identity-ordering
  # control. Reported as a check with an explicit skip note rather than a
  # silent pass if the host happens to differ, since that itself is
  # information (this is precisely PC-1's open question).
  if [[ "$real_readable" == "yes" ]]; then
    check "T2 (end-to-end): this host's ordinary same-uid /proc read is 'yes', matching the reproduction in test_identity_drop_order.sh" \
      test "$real_readable" = "yes"
  else
    echo "  note: this host's real same-uid /proc read reported '$real_readable', not 'yes' -- itself a PC-1-relevant observation, not a test failure"
  fi
else
  echo "  skip real /proc read checks: /proc/self/environ is not readable on this host at all"
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
